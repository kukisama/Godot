extends SceneTree
## Full-main-scene integration tests, not a mock game or a render acceptance test.
## --headless --path HollowBell --fixed-fps 60 --script res://tests/test_game.gd
## Fixtures may relocate actors and disable enemy AI; these are NOT a playthrough.
## The route case never relocates the hero after x=5, but disables enemy AI.
## The final, separately reported bot attempt changes INPUT ONLY after BEGIN.

const MainScene: PackedScene = preload("res://main.tscn")
const EnemyScript = preload("res://scripts/enemy.gd")
const Catalog = preload("res://scripts/catalog.gd")
const DT: float = 1.0 / 60.0
const SEED_VALUE: int = 0x48424954
const RESULT_PATH: String = "res://qa/gameplay-results.json"
const KEYS: Array[int] = [KEY_ENTER, KEY_ESCAPE, KEY_A, KEY_D, KEY_LEFT,
	KEY_RIGHT, KEY_SPACE, KEY_J, KEY_K, KEY_SHIFT, KEY_L, KEY_C, KEY_Q, KEY_E]

class FrameFence extends Node:
	signal settled

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1000000

	func _process(_delta: float) -> void:
		settled.emit()

var fence: FrameFence
var frame_fault: bool = false
var game
var checks: Array[Dictionary] = []
var failures: Array[Dictionary] = []
var fixtures: Array[Dictionary] = []
var traces: Dictionary = {}
var bot_result: Dictionary = {"attempted": false, "achieved": false}
var held: Dictionary = {}
var section: String = "boot"
var steps: int = 0
var input_events: int = 0
var started_ms: int = 0
var loop_frames: int = 0
var running: bool = false
var source_hashes: Dictionary = {}
var begin_callbacks: int = 0
var retry_callbacks: int = 0


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	Input.use_accumulated_input = false
	seed(SEED_VALUE)
	_run.call_deferred()


func _process(_delta: float) -> bool:
	loop_frames += 1
	# A script error must not leave a silent, forever-running SceneTree coroutine.
	if running and (loop_frames > 60000 or Time.get_ticks_msec() - started_ms > 240000):
		running = false
		_check(false, "suite watchdog: coroutine completed within bounded budget",
			{"section": section, "frames": loop_frames, "ms": Time.get_ticks_msec() - started_ms},
			"<60000 frames and <240000 ms")
		_save(false)
		quit(2)
	return false


func _run() -> void:
	running = true
	fence = FrameFence.new()
	root.add_child(fence)
	for path: String in ["scripts/game.gd", "scripts/player.gd", "scripts/actor.gd",
			"scripts/catalog.gd", "scripts/enemy.gd", "scripts/world.gd", "scripts/hud.gd",
			"scripts/audio.gd", "scripts/effects.gd", "tests/test_enemy_contract.gd",
			"tests/render_capture.gd", "main.tscn", "project.godot"]:
		source_hashes[path] = FileAccess.get_sha256("res://" + path)
	_save(false)
	await _test_boot_and_input()
	await _test_locomotion()
	await _test_jump_height_and_buffer()
	await _test_coyote()
	await _test_combo()
	await _test_heavy()
	await _test_dodge()
	await _test_guard_and_parry()
	await _test_heal()
	await _test_stamina()
	await _test_projectiles()
	await _test_pause_and_volume()
	await _test_checkpoint_fall_death_retry()
	await _test_boss_threshold()
	await _test_continuous_route()
	await _attempt_input_only_playthrough()
	section = "finish"
	var changed: Array[String] = []
	for path: String in source_hashes:
		if FileAccess.get_sha256("res://" + path) != str(source_hashes[path]):
			changed.append(path)
	_check(changed.is_empty(), "production/contract sources unchanged during this run", changed, [])
	_release_all()
	paused = false
	Engine.time_scale = 1.0
	if is_instance_valid(game):
		game.queue_free()
		await process_frame
	running = false
	_save(true)
	print("GAME INTEGRATION: %d checks, %d failures" % [checks.size(), failures.size()])
	print("INPUT_ONLY_PLAYTHROUGH: " + JSON.stringify(bot_result))
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, label: String, actual: Variant, expected: Variant) -> void:
	var record: Dictionary = {"id": checks.size() + 1, "section": section,
		"label": label, "passed": ok, "actual": actual, "expected": expected,
		"step": steps, "physics_frame": Engine.get_physics_frames()}
	checks.append(record)
	if not ok:
		failures.append(record)
		printerr("FAIL " + JSON.stringify(record))
	else:
		print("PASS " + JSON.stringify(record))


func _save(completed: bool) -> void:
	var report: Dictionary = {"suite": "HollowBell full-main integration", "completed": completed,
		"seed": SEED_VALUE, "engine": Engine.get_version_info(), "fixed_fps": 60,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"checks": checks.size(), "passed": checks.size() - failures.size(),
		"failed": failures.size(), "failures": failures, "results": checks,
		"fixtures": fixtures, "traces": traces, "input_events": input_events,
		"sampled_steps": steps, "wall_ms": Time.get_ticks_msec() - started_ms,
		"source_sha256": source_hashes, "input_only_playthrough": bot_result,
		"scope": ["Real main.tscn, world collisions, player, enemies, HUD, audio and effects",
			"test_mode is set before add_child: no preference writes, focus pause or hit-stop",
			"Isolated fixtures may change starting resources/positions and enemy processing",
			"Continuous route: AI disabled, checkpoint resource deficits injected; NOT no-cheat",
			"Final bot: normal HP/damage/stamina/AI; only parsed physical key events after BEGIN",
			"Headless functional tests do NOT establish visual or audible quality"]}
	var output: FileAccess = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if output == null:
		printerr("FAIL: cannot write " + RESULT_PATH + " error=" + str(FileAccess.get_open_error()))
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t") + "\n")
	output.close()


func _frames(count: int) -> void:
	for index in range(count):
		# Both SceneTree signals precede their node callbacks. The late-process
		# fence puts every assertion after physics AND actual sprite animation.
		var before: int = Engine.get_physics_frames()
		await physics_frame
		await process_frame
		await fence.settled
		steps += 1
		var difference: int = Engine.get_physics_frames() - before
		if difference != 1 and not frame_fault:
			frame_fault = true
			_check(false, "each frame barrier advances exactly one physics tick", difference, 1)


func _key(code: int, down: bool) -> void:
	if bool(held.get(code, false)) == down:
		return
	held[code] = down
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	event.echo = false
	Input.parse_input_event(event)
	input_events += 1


func _release_all() -> void:
	for code: int in KEYS:
		_key(code, false)


func _tap(code: int, duration: int = 1) -> void:
	_key(code, true)
	await _frames(duration)
	_key(code, false)


func _ticks(duration: float) -> int:
	# Independent fixed-delta reference, including IEEE accumulation at e.g. .5s.
	var elapsed: float = 0.0
	var count: int = 0
	while elapsed < duration and count < 600:
		elapsed += DT
		count += 1
	return count


func _v(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _hero_snapshot() -> Dictionary:
	return {"pos": _v(game.hero.global_position), "velocity": _v(game.hero.velocity),
		"floor": game.hero.is_on_floor(), "state": game.hero.state,
		"health": game.hero.health, "stamina": game.hero.stamina, "potions": game.hero.potions,
		"facing": game.hero.facing, "action_time": game.hero.action_time,
		"invulnerable": game.hero.invulnerable, "parry_invulnerable": game.hero.parry_invulnerable,
		"guard_time": game.hero._guard_time, "buffer": game.hero.jump_buffer,
		"coyote": game.hero.coyote, "animation": game.hero.animation_name,
		"atlas_frame": game.hero.sprite.frame, "game_state": game.state}


func _setup(label: String, location: Vector3 = Vector3(10, 0.1, 0)) -> void:
	section = label
	_release_all()
	paused = false
	seed(SEED_VALUE)
	game.start_game()
	game.effects._rng.seed = SEED_VALUE
	for enemy in game.enemies:
		enemy.ai_enabled = false
		enemy.set_physics_process(false)
	game.hero.global_position = location
	fixtures.append({"section": label, "setup_position": _v(location),
		"enemy_ai": false, "enemy_physics": false, "type": "isolated full-main fixture"})
	await _frames(18)
	_check(game.state == "playing" and game.hero.is_on_floor() and game.hero.control_lock == 0.0,
		"fixture settled on real terrain; control lock expired", _hero_snapshot(), "playing / grounded / unlocked")


func _place_setup(location: Vector3, why: String) -> void:
	_release_all()
	game.hero.global_position = location
	game.hero.velocity = Vector3.ZERO
	fixtures.append({"section": section, "setup_position": _v(location), "reason": why})
	await _frames(10)


func _target(kind: String, x: float, frozen: bool = true):
	var enemy = EnemyScript.new()
	game.add_child(enemy)
	enemy.configure(game, kind, Vector3(x, 0.02, 0))
	game.enemies.append(enemy)
	enemy.ai_enabled = false
	enemy.set_physics_process(not frozen)
	fixtures.append({"section": section, "target": kind, "x": x,
		"target_ai": false, "target_physics": not frozen, "real_enemy_script": true})
	return enemy


func _until(predicate: Callable, limit: int, label: String) -> bool:
	for index in range(limit):
		if predicate.call():
			return true
		await _frames(1)
	_check(false, label + ": bounded wait", _hero_snapshot(), "condition within %d ticks" % limit)
	return false


func _dispatch_ready() -> void:
	# HUD debouncing is real wall time, NOT simulated fixed-fps time. Do not
	# rewrite its timestamp or incorrectly treat 11 headless ticks as 180ms.
	for index in range(12000):
		if Time.get_ticks_msec() - int(game.hud._last_action_ms) >= 180:
			return
		await _frames(1)
	_check(false, "HUD dispatch debounce elapsed", Time.get_ticks_msec() - int(game.hud._last_action_ms), ">=180ms")


func _test_boot_and_input() -> void:
	game = MainScene.instantiate()
	game.test_mode = true
	root.add_child(game)
	current_scene = game
	game.effects._rng.seed = SEED_VALUE
	game.hud.buttons["begin"].pressed.connect(func(): begin_callbacks += 1)
	game.hud.buttons["retry"].pressed.connect(func(): retry_callbacks += 1)
	await _frames(3)
	_check(game.test_mode and game.scene_file_path == "res://main.tscn", "real main scene in test mode before ready",
		{"path": game.scene_file_path, "test_mode": game.test_mode}, "main.tscn / true")
	_check(Engine.physics_ticks_per_second == 60 and is_equal_approx(Engine.time_scale, 1.0),
		"60Hz physics, no test time-scale acceleration", [Engine.physics_ticks_per_second, Engine.time_scale], [60, 1])
	_check(game.state == "title" and game.hud.menu_panel.visible, "initial title menu", game.state, "title")
	_check(root.gui_get_focus_owner() == game.hud.buttons["begin"], "BEGIN has actual keyboard focus",
		str(root.gui_get_focus_owner()), str(game.hud.buttons["begin"]))
	_check(game.enemies.size() == 15 and is_instance_valid(game.boss), "real catalog encounters instantiated",
		game.enemies.size(), 15)
	var bindings: Dictionary = {"move_left": KEY_A, "move_right": KEY_D, "jump": KEY_SPACE,
		"light": KEY_J, "heavy": KEY_K, "dodge": KEY_SHIFT, "quick_roll": KEY_C, "guard": KEY_Q, "heal": KEY_E}
	for action: String in bindings:
		var event: InputEventKey = InputEventKey.new()
		event.physical_keycode = int(bindings[action])
		_check(InputMap.action_has_event(action, event), "actual InputMap: " + action,
			InputMap.action_get_events(action).map(func(item): return item.as_text()), OS.get_keycode_string(int(bindings[action])))
	await _tap(KEY_ENTER)
	await _frames(18)
	_check(game.state == "playing" and begin_callbacks == 1 and not game.hud.menu_panel.visible,
		"parsed ENTER activates BEGIN callback once", {"state": game.state, "callbacks": begin_callbacks}, "playing / 1")
	_check(game.hero.is_on_floor() and absf(game.hero.global_position.y) < 0.02,
		"hero capsule contacts real 3D floor", _hero_snapshot(), "on_floor and |y|<.02")
	_check(game.hero.collision_layer == 2 and game.hero.collision_mask == 1,
		"real Player collision filtering", [game.hero.collision_layer, game.hero.collision_mask], [2, 1])
	for x: float in [5.0, 40.5, 62.0, 83.5, 105.0, 123.0, 133.0, 175.0]:
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(Vector3(x, 2, 0), Vector3(x, -2, 0), 1)
		var hit: Dictionary = game.get_world_3d().direct_space_state.intersect_ray(query)
		var hole: bool = x in [40.5, 83.5, 123.0]
		_check(hit.is_empty() if hole else not hit.is_empty(), "real world terrain ray x=%.1f" % x,
			{"hit": not hit.is_empty(), "collider": str(hit.get("collider", "none"))}, "empty hole" if hole else "solid floor")


func _test_locomotion() -> void:
	await _setup("locomotion")
	var start_x: float = game.hero.global_position.x
	var start_elapsed: float = game.elapsed
	_key(KEY_D, true)
	await _frames(1)
	_check(Input.is_action_pressed("move_right") and is_equal_approx(game.hero.velocity.x, 0.8),
		"D produces first grounded acceleration tick", _hero_snapshot(), "vx=48/60=.8")
	await _frames(8)
	_check(is_equal_approx(game.hero.velocity.x, 6.7) and game.hero.facing == 1,
		"run reaches speed cap at ninth tick", _hero_snapshot(), "vx=6.7 / facing=1")
	_check(absf(game.elapsed - start_elapsed - 9.0 * DT) < 0.00001,
		"post-physics sampling advances exactly nine fixed ticks", game.elapsed - start_elapsed, 9.0 * DT)
	await _frames(30)
	_check(game.hero.global_position.x > start_x + 3.8 and game.hero.animation_name == "run",
		"input-driven run displacement and animation", _hero_snapshot(), "dx>3.8 / run")
	_key(KEY_D, false)
	await _frames(1)
	_check(absf(game.hero.velocity.x - 5.9) < 0.00001, "release decelerates rather than snapping", game.hero.velocity.x, 5.9)
	await _frames(8)
	_check(game.hero.velocity.x == 0.0 and game.hero.facing == 1, "stop after nine ticks preserves facing", _hero_snapshot(), "vx=0 / facing=1")
	await _tap(KEY_A, 9)
	_check(is_equal_approx(game.hero.velocity.x, -6.7) and game.hero.facing == -1,
		"A accelerates left and flips facing", _hero_snapshot(), "vx=-6.7 / facing=-1")
	await _frames(10)
	_check(game.hero.sprite.flip_h and game.hero.velocity.x == 0.0, "sprite reflects left-facing stopped player", _hero_snapshot(), "flip_h / stopped")


func _jump_arc(hold_ticks: int) -> Dictionary:
	_key(KEY_SPACE, true)
	var peak: float = 0.0
	var samples: Array[Dictionary] = []
	var left_floor: bool = false
	for tick in range(1, 100):
		await _frames(1)
		peak = maxf(peak, game.hero.global_position.y)
		samples.append({"tick": tick, "y": game.hero.global_position.y, "vy": game.hero.velocity.y,
			"floor": game.hero.is_on_floor()})
		left_floor = left_floor or not game.hero.is_on_floor()
		if tick == hold_ticks:
			_key(KEY_SPACE, false)
		if left_floor and game.hero.is_on_floor():
			_key(KEY_SPACE, false)
			return {"peak": peak, "ticks": tick, "samples": samples, "landed": true}
	_key(KEY_SPACE, false)
	return {"peak": peak, "ticks": 99, "samples": samples, "landed": false}


func _test_jump_height_and_buffer() -> void:
	await _setup("variable_height_jump")
	var full: Dictionary = await _jump_arc(90)
	await _frames(4)
	var short: Dictionary = await _jump_arc(1)
	traces["jump_full"] = full
	traces["jump_tap"] = short
	_check(full.landed and short.landed, "both real input jumps land", [full.ticks, short.ticks], "<100 ticks each")
	_check(float(full.peak) > 2.1 and float(full.peak) < 2.6,
		"held jump reaches authored 11m/s arc", full.peak, "2.1..2.6 m")
	_check(float(short.peak) > 1.3 and float(short.peak) < 1.8 and float(full.peak) - float(short.peak) > 0.65,
		"early release gives materially shorter jump", [full.peak, short.peak], "tap 1.3..1.8m; difference>.65m")
	_check(absf(float(full.samples[0].vy) - 11.0) < 0.00001,
		"first jump tick uses authored impulse", full.samples[0], "vy=11")
	_check(absf(float(full.samples[0].vy) - float(full.samples[1].vy) - 26.0 * DT) < 0.00001,
		"held ascending gravity", [full.samples[0].vy, full.samples[1].vy], "26/60 decrement")
	_check(absf(float(short.samples[0].vy) - float(short.samples[1].vy) - 41.6 * DT) < 0.00001,
		"released ascending gravity multiplier", [short.samples[0].vy, short.samples[1].vy], "41.6/60 decrement")
	await _setup("buffered_jump")
	await _tap(KEY_SPACE, 15)
	if not await _until(func(): return game.hero.velocity.y < 0 and game.hero.global_position.y < 0.65,
			90, "descend into buffer window"):
		return
	var before: Dictionary = _hero_snapshot()
	_key(KEY_SPACE, true)
	await _frames(1)
	_key(KEY_SPACE, false)
	_check(not bool(before.floor) and float(before.coyote) == 0.0 and game.hero.jump_buffer > 0.0,
		"SPACE buffered while airborne, not a coyote jump", {"before": before, "after": _hero_snapshot()}, "airborne / coyote=0 / buffer>0")
	var saw_floor: bool = game.hero.is_on_floor()
	var bounced: bool = false
	var delay: int = 0
	for tick in range(1, 10):
		await _frames(1)
		delay = tick
		if game.hero.velocity.y > 8.0:
			bounced = true
			break
		saw_floor = saw_floor or game.hero.is_on_floor()
	_check(bounced and saw_floor and game.hero.jump_buffer == 0.0,
		"buffer consumes once on real landing", {"delay_ticks": delay, "saw_floor": saw_floor, "hero": _hero_snapshot()}, "landing then vy>8 within 8 ticks")
	await _setup("expired_jump_buffer")
	await _tap(KEY_SPACE, 25)
	await _until(func(): return game.hero.velocity.y < 0.0, 30, "jump apex")
	await _tap(KEY_SPACE)
	await _frames(9)
	_check(not game.hero.is_on_floor() and game.hero.jump_buffer == 0.0 and game.hero.velocity.y < 0.0,
		"early buffer expires before landing", _hero_snapshot(), "airborne descending / buffer=0")
	await _until(func(): return game.hero.is_on_floor(), 60, "expired buffer landing")
	await _frames(4)
	_check(game.hero.is_on_floor() and game.hero.velocity.y <= 0.0, "expired request does not bounce later", _hero_snapshot(), "grounded")


func _test_coyote() -> void:
	await _setup("coyote_jump", Vector3(37.6, 0.1, 0))
	_key(KEY_D, true)
	if not await _until(func(): return not game.hero.is_on_floor(), 50, "walk off actual first ledge"):
		return
	await _frames(3)
	var before: Dictionary = _hero_snapshot()
	_key(KEY_SPACE, true)
	await _frames(1)
	_check(not bool(before.floor) and float(before.coyote) > 0.0 and game.hero.velocity.y > 10.0,
		"SPACE three ticks after ledge uses coyote grace", {"before": before, "after": _hero_snapshot()}, "airborne coyote>0 then upward impulse")
	await _until(func(): return game.hero.is_on_floor() and game.hero.global_position.x > 42.0, 100, "coyote jump crosses first real hole")
	_release_all()
	_check(game.hero.health == 100.0 and game.hero.global_position.x > 42.0,
		"coyote traversal did not fall/respawn", _hero_snapshot(), "x>42 / hp=100")
	await _setup("expired_coyote", Vector3(37.6, 0.1, 0))
	_key(KEY_D, true)
	await _until(func(): return not game.hero.is_on_floor(), 50, "walk off ledge for expiry")
	await _frames(9)
	before = _hero_snapshot()
	await _tap(KEY_SPACE)
	_check(float(before.coyote) == 0.0 and game.hero.velocity.y < 0.0,
		"SPACE after grace expiry cannot jump in midair", {"before": before, "after": _hero_snapshot()}, "coyote=0 / vy<0")
	_release_all()


func _test_combo() -> void:
	await _setup("J_three_hit_combo")
	var front = _target("warden", 11.8)
	var behind = _target("warden", 8.0)
	var changes: Array[Dictionary] = []
	var samples: Array[Dictionary] = []
	var old_hp: float = front.health
	var commit_start: int = game.hero.attack_commits
	var correct_windows: bool = true
	for tick in range(1, 106):
		if tick in [1, 16, 42]:
			_key(KEY_J, true)
		elif tick in [2, 17, 43]:
			_key(KEY_J, false)
		await _frames(1)
		var row: Dictionary = {"tick": tick, "state": game.hero.state, "combo": game.hero.combo_index,
			"action_time": game.hero.action_time, "frame": game.hero.sprite.frame,
			"animation": game.hero.animation_name,
			"hp": front.health, "commits": game.hero.attack_commits - commit_start}
		samples.append(row)
		if front.health != old_hp:
			row = row.duplicate()
			row["damage"] = old_hp - front.health
			changes.append(row)
			var i: int = game.hero.combo_index
			var first: int = 12 if i == 1 else 0
			correct_windows = correct_windows and game.hero.state == "attack" \
				and game.hero.action_time >= game.hero.ATTACK_WINDUP[i] \
				and game.hero.action_time < game.hero.ATTACK_WINDUP[i] + DT \
				and game.hero.animation_name == "attack_%d" % i \
				and game.hero.sprite.frame in [first + 4, first + 5, first + 6, first + 7]
			old_hp = front.health
	traces["combo"] = samples
	_check(changes.size() == 3, "three parsed J presses cause exactly three HP changes", changes, "3 hits")
	_check(changes.map(func(row): return row.tick) == [8, 36, 68],
		"combo impacts occur at exact fixed ticks", changes, [8, 36, 68])
	_check(changes.map(func(row): return row.damage) == [23.0, 27.0, 38.0],
		"combo applies each authored damage exactly once", changes, [23, 27, 38])
	_check(correct_windows, "all combo damage is first active tick and correct atlas pose", changes, "tell ended / active pose")
	_check(front.health == 42.0 and behind.health == 130.0,
		"repeated active frames do not re-hit; behind target untouched", [front.health, behind.health], [42, 130])
	_check(game.hero.attack_commits - commit_start == 3 and game.hero.state == "idle",
		"third hit recovers without fourth combo", _hero_snapshot(), "3 commits / idle")
	await _setup("held_J_does_not_repeat")
	front = _target("warden", 11.8)
	await _tap(KEY_J, 110)
	_check(front.health == 107.0 and game.hero.attack_commits == 1 and game.hero.state == "idle",
		"holding J is not three fabricated just-presses", [front.health, game.hero.attack_commits, game.hero.state], [107, 1, "idle"])


func _test_heavy() -> void:
	await _setup("charged_heavy")
	var target = _target("warden", 11.8)
	_key(KEY_K, true)
	await _frames(60)
	_check(game.hero.state == "charge" and target.health == 130.0 and game.hero.stamina == 100.0,
		"held K charges without early damage or resource consumption", _hero_snapshot(), "charge / target hp=130 / stamina=100")
	var charge: float = game.hero.charge
	_check(absf(charge - 1.0) < 0.00001, "60 input-held ticks charge for one second", charge, 1.0)
	_key(KEY_K, false)
	await _frames(1)
	_check(game.hero.state == "heavy" and game.hero.stamina == 74.0 and game.hero.action_time == 0.0,
		"release commits 26 stamina, starts fresh heavy tell", _hero_snapshot(), "heavy / stamina=74 / action_time=0")
	# The charge branch integrates delta BEFORE inspecting the released K state.
	# Sixty held ticks plus the release-processing tick commit 61/60 seconds.
	var release_charge: float = game.hero.charge
	_check(absf(release_charge - 61.0 * DT) < 0.00001,
		"release-processing tick contributes to committed charge", release_charge, 61.0 * DT)
	var hits: Array[Dictionary] = []
	var prior_hp: float = target.health
	for tick in range(1, 51):
		await _frames(1)
		if target.health != prior_hp:
			hits.append({"tick_after_release": tick, "damage": prior_hp - target.health,
				"time": game.hero.action_time, "pose": game.hero.sprite.frame})
			prior_hp = target.health
	_check(hits.size() == 1 and int(hits[0].tick_after_release) == 10,
		"charged heavy hits once at tenth post-release tick", hits, "1 hit / tick 10")
	var expected_damage: float = 48.0 + 36.0 * (61.0 * DT)
	_check(absf(target.health - (130.0 - expected_damage)) < 0.00001,
		"61-tick committed charge deals 48+36*(61/60)=84.6", {"hp": target.health,
			"held_charge": charge, "committed_charge": release_charge, "hits": hits}, 130.0 - expected_damage)
	_check(game.hero.attack_commits == 1 and game.hero.state == "idle", "heavy recovers without repeated damage", _hero_snapshot(), "1 commit / idle")
	await _setup("heavy_auto_release_cap")
	_key(KEY_K, true)
	await _frames(74)
	_check(game.hero.state == "heavy" and game.hero.charge == 1.2 and game.hero.stamina == 74.0,
		"maximum charge auto-releases and costs only once", _hero_snapshot(), "heavy / charge=1.2 / stamina=74")
	_key(KEY_K, false)


func _test_dodge() -> void:
	await _setup("dodge_cost_invulnerability")
	await _tap(KEY_SHIFT)
	_check(game.hero.state == "roll" and game.hero.stamina == 80.0 and absf(game.hero.invulnerable - 0.38) < 0.00001,
		"real SHIFT begins roll with exact cost and i-frames", _hero_snapshot(), "roll / stamina=80 / i=.38")
	var accepted: bool = game.hurt_player(25, game.hero.global_position.x + 1, 0)
	_check(not accepted and game.hero.health == 100.0, "damage rejected during roll invulnerability", [accepted, game.hero.health], [false, 100])
	await _frames(22)
	_check(game.hero.state == "roll" and game.hero.invulnerable > 0.0,
		"roll remains invulnerable before .38s expiry", _hero_snapshot(), "roll / i>0")
	await _frames(1)
	_check(game.hero.state == "roll" and game.hero.invulnerable == 0.0,
		"last roll recovery frames are vulnerable", _hero_snapshot(), "roll / i=0")
	accepted = game.hurt_player(25, game.hero.global_position.x + 1, 0)
	_check(accepted and game.hero.health == 75.0 and game.hero.state == "hurt",
		"damage lands during vulnerable roll tail", _hero_snapshot(), "hp=75 / hurt")
	await _setup("dodge_natural_recovery")
	var x: float = game.hero.global_position.x
	await _tap(KEY_L)
	await _frames(27)
	_check(game.hero.state == "roll", "L alias roll has not recovered at tick 28", _hero_snapshot(), "roll")
	await _frames(1)
	_check(game.hero.state == "idle" and game.hero.stamina == 80.0,
		"roll recovers at tick 29 without second cost", _hero_snapshot(), "idle / stamina=80")
	_check(game.hero.global_position.x - x > 4.7 and game.hero.global_position.x - x < 5.5,
		"dodge traverses real body through acceleration profile", game.hero.global_position.x - x, "4.7..5.5 m")


func _test_guard_and_parry() -> void:
	await _setup("actual_enemy_parry")
	var enemy = _target("sentinel", 11.6, false)
	await _frames(4)
	enemy.start_attack()
	await _frames(31)
	_key(KEY_Q, true)
	await _frames(15)
	_check(game.hero.parries == 1 and game.hero.health == 100.0,
		"real sentinel strike meets input-timed Q parry", {"hero": _hero_snapshot(), "parries": game.hero.parries,
			"enemy_hp": enemy.health, "enemy_events": enemy.attack_events_count}, "1 parry / hp=100")
	_check(enemy.health == 68.0 and enemy.attack_events_count == 1 and enemy.attack_name.is_empty(),
		"parry callback damages and cancels sentinel second cut", [enemy.health, enemy.attack_events_count, enemy.attack_name], [68, 1, ""])
	# Keep Q held through recoil; wait beyond the new 1.0s parry protection.
	# Otherwise an immune hit would spend nothing and never exercise mature block.
	await _frames(70)
	_check(game.hero.parry_invulnerable == 0.0 and game.hero.invulnerable == 0.0
		and game.hero._guard_time > 0.17 and game.hero.guarding,
		"held guard is mature after full parry protection expires", _hero_snapshot(), "p=0 / i=0 / guard_time>.17 / held guard")
	game.hero.stamina = 80.0
	game.hero._regen_delay = 1.0
	var blocked: bool = game.hurt_player(20, game.hero.global_position.x + 2, 0)
	_check(not blocked and game.hero.health == 100.0 and game.hero.stamina == 55.0,
		"mature forward guard spends 1.25*damage instead of HP", _hero_snapshot(), "hp=100 / stamina=55")
	await _frames(12)
	var rear: bool = game.hurt_player(17, game.hero.global_position.x - 2, 0)
	_check(rear and game.hero.health == 83.0 and not game.hero.guarding,
		"rear strike bypasses right-facing block", _hero_snapshot(), "hp=83 / hurt / not guarding")
	await _setup("left_facing_block")
	await _tap(KEY_A)
	await _frames(9)
	_key(KEY_Q, true)
	await _frames(14)
	game.hero.stamina = 80.0
	game.hero._regen_delay = 1.0
	blocked = game.hurt_player(20, game.hero.global_position.x - 2, 0)
	_check(game.hero.facing == -1 and not blocked and game.hero.stamina == 55.0,
		"left-facing block mirrors its protected side", _hero_snapshot(), "facing=-1 / hp=100 / stamina=55")
	await _frames(12)
	rear = game.hurt_player(17, game.hero.global_position.x + 2, 0)
	_check(rear and game.hero.health == 83.0, "right-side hit bypasses left-facing guard", _hero_snapshot(), "hp=83")
	await _setup("parry_resource_reward")
	game.hero.stamina = 60.0
	game.hero._regen_delay = 1.0
	await _tap(KEY_Q)
	_check(game.hero._guard_time == 0.0, "fresh guard starts at zero on first input tick", _hero_snapshot(), "guard_time=0")
	blocked = game.hurt_player(20, game.hero.global_position.x + 1, 0)
	_check(not blocked and game.hero.parries == 1 and game.hero.stamina == 73.0
		and game.hero.parry_invulnerable == 1.0 and game.hero.invulnerable == 1.0 and game.hero.state == "parry",
		"fresh guard parry rewards exactly 13 stamina and 1.0s protection", _hero_snapshot(), "stamina=73 / p=1.0 / i=1.0 / parries=1 / parry")
	await _setup("guard_break_floor")
	_key(KEY_Q, true)
	await _frames(14)
	game.hero.stamina = 6.0
	game.hero._regen_delay = 1.0
	var broken: bool = game.hurt_player(20, game.hero.global_position.x + 1, 0)
	_check(broken and game.hero.stamina == 0.0 and game.hero.health == 80.0,
		"insufficient guard stamina floors at zero and takes damage", _hero_snapshot(), "stamina=0 / hp=80")


func _test_heal() -> void:
	await _setup("healing_delayed_commit")
	game.hero.health = 31.0
	var changes: Array[Dictionary] = []
	var early_unchanged: bool = true
	var old_hp: float = game.hero.health
	_key(KEY_E, true)
	for tick in range(1, 63):
		await _frames(1)
		if tick == 1:
			_key(KEY_E, false)
		if tick < _ticks(0.5):
			early_unchanged = early_unchanged and game.hero.health == 31.0 and game.hero.potions == 3
		if old_hp != game.hero.health:
			changes.append({"tick": tick, "hp": game.hero.health, "potions": game.hero.potions, "time": game.hero.action_time})
			old_hp = game.hero.health
	_check(early_unchanged, "E reserves, but does not consume/heal during first .5s", changes, "hp=31 and potions=3 before .5s")
	_check(changes.size() == 1 and int(changes[0].tick) == _ticks(0.5),
		"heal commits on exact first eligible physics tick", changes, _ticks(0.5))
	_check(game.hero.health == 79.0 and game.hero.potions == 2 and game.hero.state == "idle",
		"one potion heals 48 and completes recovery", _hero_snapshot(), "hp=79 / potions=2 / idle")
	await _setup("healing_interrupt_before_commit")
	game.hero.health = 40.0
	game.hero.potions = 2
	await _tap(KEY_E, 12)
	var damaged: bool = game.hurt_player(9, game.hero.global_position.x + 2, 0)
	_check(damaged and game.hero.state == "hurt" and game.hero.potions == 2,
		"pre-commit damage interrupts heal without consuming bottle", _hero_snapshot(), "hurt / potions=2")
	await _frames(85)
	_check(game.hero.health == 31.0 and game.hero.potions == 2 and game.hero.state == "idle",
		"interrupted heal has no deferred healing callback", _hero_snapshot(), "hp=31 / potions=2 / idle")
	await _setup("healing_interrupt_after_commit")
	game.hero.health = 31.0
	game.hero.potions = 2
	await _tap(KEY_E, 32)
	game.hurt_player(9, game.hero.global_position.x + 2, 0)
	await _frames(75)
	_check(game.hero.health == 70.0 and game.hero.potions == 1,
		"post-commit interruption neither refunds nor consumes twice", _hero_snapshot(), "hp=70 / potions=1")
	game.hero.health = 100.0
	await _tap(KEY_E)
	_check(game.hero.state == "idle" and game.hero.potions == 1, "full HP refuses potion action", _hero_snapshot(), "idle / potions=1")
	game.hero.health = 20.0
	game.hero.potions = 0
	await _frames(1)
	await _tap(KEY_E)
	_check(game.hero.state == "idle" and game.hero.health == 20.0, "no bottle refuses healing", _hero_snapshot(), "idle / hp=20")


func _test_stamina() -> void:
	await _setup("stamina_affordability")
	for sample: Dictionary in [{"key": KEY_J, "stamina": 6.0}, {"key": KEY_K, "stamina": 25.0},
			{"key": KEY_SHIFT, "stamina": 19.0}]:
		game.hero.stamina = float(sample.stamina)
		game.hero._regen_delay = 10.0
		await _tap(int(sample.key))
		_check(game.hero.state == "idle" and game.hero.stamina == float(sample.stamina),
			"unaffordable input rejected: " + OS.get_keycode_string(int(sample.key)), _hero_snapshot(), sample.stamina)
		await _frames(1)
	game.hero.stamina = 7.0
	await _tap(KEY_J)
	_check(game.hero.stamina == 0.0 and game.hero.state == "attack", "exact-cost light attack reaches zero, never negative", _hero_snapshot(), "stamina=0 / attack")
	var regen_tick: int = -1
	var floor_ok: bool = true
	for tick in range(1, 62):
		await _frames(1)
		floor_ok = floor_ok and game.hero.stamina >= 0.0 and game.hero.stamina <= 100.0
		if game.hero.stamina > 0.0 and regen_tick < 0:
			regen_tick = tick
	_check(floor_ok and regen_tick == _ticks(0.45), "natural action regeneration delay and resource floor",
		{"first_regen_tick_after_start": regen_tick, "stamina": game.hero.stamina, "bounded": floor_ok}, _ticks(0.45))
	await _setup("stamina_regen_rates")
	game.hero.stamina = 0.0
	game.hero._regen_delay = 0.0
	await _frames(60)
	_check(absf(game.hero.stamina - 28.0) < 0.00001, "unguarded regeneration is 28 per second", game.hero.stamina, 28.0)
	_key(KEY_Q, true)
	await _frames(1)
	var before: float = game.hero.stamina
	await _frames(60)
	_check(absf(game.hero.stamina - before - 7.0) < 0.00001,
		"held guard regeneration is 7 per second", game.hero.stamina - before, 7.0)
	_key(KEY_Q, false)
	await _frames(240)
	_check(game.hero.stamina == 100.0, "regeneration clamps to maximum", game.hero.stamina, 100.0)


func _test_projectiles() -> void:
	for kind: String in ["bolt", "orb"]:
		for direction: float in [-1.0, 1.0]:
			await _setup("CCD_%s_%d" % [kind, int(direction)])
			var owner = game.enemies[0]
			var x: float = game.hero.global_position.x
			game.spawn_projectile(Vector3(x - direction * 4.0, 0.92, 0), Vector3(direction, 0, 0), kind, 17.0, 480.0, owner, Color.GOLD)
			await _frames(1)
			_check(game.hero.health == 83.0 and game.projectiles.is_empty(),
				"segment CCD hits when BOTH endpoints miss hero", {"hero": _hero_snapshot(),
					"start_x": x - direction * 4, "end_x": x + direction * 4, "remaining": game.projectiles.size()}, "hp=83 / projectile consumed")
			await _frames(3)
			_check(game.hero.health == 83.0, "CCD contact is consumed exactly once", game.hero.health, 83.0)
	await _setup("projectile_terrain_collision")
	game.spawn_projectile(Vector3(14, 3, 0), Vector3.DOWN, "bolt", 17, 360, game.enemies[0], Color.GOLD)
	await _frames(1)
	_check(game.projectiles.is_empty() and game.hero.health == 100.0,
		"projectile ray collides with real floor", {"remaining": game.projectiles.size(), "hp": game.hero.health}, "0 / 100")
	await _setup("real_arbalist_release")
	var arbalist = _target("arbalist", 16, false)
	await _frames(4)
	arbalist.start_attack()
	await _frames(100)
	_check(arbalist.attack_events_count == 1 and game.hero.health == 86.0,
		"real arbalist -> real projectile update -> real Player damage", {"events": arbalist.attack_events_count,
			"hero": _hero_snapshot(), "projectiles": game.projectiles.size()}, "1 bolt / hp=86")
	await _setup("groundwave_ground_contact")
	game.spawn_wave(8, 1, 12, game.enemies[0])
	await _frames(25)
	_check(game.hero.health == 88.0 and game.projectiles.is_empty(),
		"grounded hero is hit once by real wave", _hero_snapshot(), "hp=88 / no projectile")
	await _setup("input_jump_evades_groundwave")
	_key(KEY_SPACE, true)
	await _frames(8)
	game.spawn_wave(8, 1, 12, game.enemies[0])
	var passed_hero: bool = false
	var crossing_heights: Array[float] = []
	for tick in range(30):
		await _frames(1)
		if not game.projectiles.is_empty():
			var wave_x: float = game.projectiles[0].node.position.x
			if absf(wave_x - game.hero.global_position.x) < 0.56:
				crossing_heights.append(game.hero.global_position.y)
			passed_hero = passed_hero or wave_x > game.hero.global_position.x + 0.7
	_key(KEY_SPACE, false)
	await _frames(30)
	_check(passed_hero and not crossing_heights.is_empty() and crossing_heights.min() >= 0.8 and game.hero.health == 100.0,
		"SPACE jump evades wave crossing, not a missing projectile", {"passed": passed_hero, "heights": crossing_heights,
			"hero": _hero_snapshot()}, "wave crosses at y>=.8 / hp=100")
	await _setup("projectile_owner_cleanup")
	var owner = _target("arbalist", 15)
	game.spawn_projectile(Vector3(15, 4, 0), Vector3.RIGHT, "orb", 12, 2, owner, Color.GOLD)
	owner.queue_free()
	await _frames(3)
	_check(game.projectiles.is_empty(), "freed real owner removes orphan projectile", game.projectiles.size(), 0)
	await _setup("projectile_reentrant_death")
	game.hero.health = 10.0
	game.spawn_projectile(Vector3(6, 0.92, 0), Vector3.RIGHT, "bolt", 12, 480, game.enemies[0], Color.GOLD)
	game.spawn_projectile(Vector3(14, 0.92, 0), Vector3.LEFT, "orb", 12, 480, game.enemies[1], Color.GOLD)
	await _frames(1)
	_check(game.state == "dying" and game.death_count == 1 and game.projectiles.is_empty(),
		"death reentrantly clears projectile collection safely", {"state": game.state, "deaths": game.death_count, "remaining": game.projectiles.size()},
		"dying / 1 death / 0 projectiles")


func _frozen_snapshot(enemy) -> Dictionary:
	var projectile: Dictionary = game.projectiles[0]
	var effect_ages: Array = []
	for slot in game.effects._active:
		effect_ages.append(slot.age)
	return {"elapsed": game.elapsed, "game_clock": game._clock, "world_clock": game.world._clock,
		"camera": _v(game.camera.position), "hero_pos": _v(game.hero.global_position),
		"hero_velocity": _v(game.hero.velocity), "hero_action": game.hero.action_time,
		"charge": game.hero.charge, "hero_animation": game.hero.animation_clock,
		"hero_pose": game.hero.sprite.frame, "enemy_pos": _v(enemy.global_position),
		"enemy_stage": enemy._stage_elapsed, "enemy_animation": enemy.animation_clock,
		"enemy_pose": enemy.sprite.frame, "projectile_pos": _v(projectile.node.position),
		"projectile_age": projectile.age, "effects": effect_ages}


func _test_pause_and_volume() -> void:
	await _setup("pause_resume_volume")
	var enemy = _target("cantor", 16, false)
	await _frames(4)
	enemy.start_attack()
	_key(KEY_K, true)
	await _frames(10)
	game.spawn_projectile(Vector3(14, 4, 0), Vector3.LEFT, "orb", 12, 2, enemy, Color.GOLD)
	game.effects.burst(Vector3(11, 1, 0), Color.GOLD, 3)
	await _frames(2)
	_key(KEY_ESCAPE, true)
	await _frames(1)
	_key(KEY_ESCAPE, false)
	_check(paused and game.state == "paused" and game.hud.menu_panel.visible,
		"actual Escape pauses whole game and opens menu", {"tree_paused": paused, "state": game.state}, "true / paused")
	var before: Dictionary = _frozen_snapshot(enemy)
	_key(KEY_D, true)
	# Space is the HUD's confirm key and legitimately activates ResumeButton.
	# D/J exercise gameplay input without requesting a menu action.
	_key(KEY_J, true)
	await _frames(120)
	_key(KEY_D, false)
	_key(KEY_J, false)
	var after: Dictionary = _frozen_snapshot(enemy)
	_check(paused and game.state == "paused" and before == after, "pause freezes game/world/player/enemy/animations/projectile/effects/elapsed",
		{"before": before, "after": after}, "all values exactly equal after 120 ticks and gameplay inputs")
	var master_bus: float = AudioServer.get_bus_volume_db(0)
	var slider: HSlider = game.hud.volume_slider
	_check(slider.is_visible_in_tree(), "master-volume UI available while paused", slider.is_visible_in_tree(), true)
	slider.grab_focus()
	var initial: float = slider.value
	await _tap(KEY_LEFT)
	await _frames(1)
	_check(absf(game.volume - (initial - 0.05)) < 0.00001 and is_equal_approx(game.audio._master, game.volume),
		"Left key changes actual slider -> game -> audio volume", {"before": initial, "slider": slider.value,
			"game": game.volume, "audio": game.audio._master, "label": game.hud.volume_value_label.text}, initial - 0.05)
	for tick in range(20):
		await _tap(KEY_LEFT)
		await _frames(1)
	var silent: bool = true
	for player in game.audio._music_players + game.audio._sfx_players:
		silent = silent and player.volume_db == -INF
	_check(game.volume == 0.0 and slider.value == 0.0 and silent and game.hud.volume_value_label.text == "0%",
		"UI minimum mutes all music and SFX voices", {"game": game.volume, "silent": silent, "label": game.hud.volume_value_label.text}, "0 / all -INF / 0%")
	for tick in range(8):
		await _tap(KEY_RIGHT)
		await _frames(1)
	_check(is_equal_approx(game.volume, 0.4) and is_equal_approx(game.audio._master, 0.4),
		"UI Right key unmutes to 40 percent", [game.volume, game.audio._master, game.hud.volume_value_label.text], [0.4, 0.4, "40%"])
	_check(AudioServer.get_bus_volume_db(0) == master_bus, "master slider does not mutate global audio bus", AudioServer.get_bus_volume_db(0), master_bus)
	_check(_frozen_snapshot(enemy) == before, "paused menu interaction cannot advance gameplay", _frozen_snapshot(enemy), before)
	await _dispatch_ready()
	await _tap(KEY_ESCAPE)
	await _frames(10)
	_check(not paused and game.state == "playing" and game.elapsed > float(before.elapsed),
		"actual Escape callback resumes gameplay", {"paused": paused, "state": game.state, "elapsed": game.elapsed}, "playing / elapsed increases")
	_check(game.hero.charge > float(before.charge) and enemy._stage_elapsed > float(before.enemy_stage)
		and game.projectiles[0].age > float(before.projectile_age), "resume advances pending action and projectile, no restart",
		{"charge": game.hero.charge, "enemy_stage": enemy._stage_elapsed, "projectile_age": game.projectiles[0].age}, before)
	_key(KEY_K, false)


func _test_checkpoint_fall_death_retry() -> void:
	await _setup("checkpoint_fall_death_retry", Vector3(59, 0.1, 0))
	_key(KEY_D, true)
	await _until(func(): return game.checkpoint_index == 1, 90, "automatic checkpoint at x62")
	_release_all()
	await _place_setup(Vector3(80, 0.1, 0), "fall test starts BEFORE gap; no teleport across it")
	var hp_before: float = game.hero.health
	_key(KEY_D, true)
	var lowest: float = 0.0
	var returned: bool = false
	for tick in range(160):
		await _frames(1)
		lowest = minf(lowest, game.hero.global_position.y)
		if game.hero.global_position.x < 70.0:
			returned = true
			break
	_release_all()
	_check(returned and lowest < -5.5 and absf(game.hero.global_position.x - 62.0) < 0.001,
		"real fall below kill plane returns to latest checkpoint", {"lowest_sampled_y": lowest, "hero": _hero_snapshot()}, "y<-5.5 then x=62")
	_check(game.hero.health == hp_before - 18.0 and game.hero.invulnerable > 1.4 and game.death_count == 0,
		"nonlethal fall costs 18, grants grace, no death", _hero_snapshot(), "hp=82 / invulnerable>1.4 / deaths=0")
	await _frames(100)
	await _place_setup(Vector3(69.2, 0.1, 0), "isolated persistent-kill fixture after checkpoint")
	var target
	for enemy in game.enemies:
		if is_instance_valid(enemy) and int(enemy.get_meta("spawn_id", -1)) == 5:
			target = enemy
	var target_id: int = 5
	await _tap(KEY_K, 60)
	await _frames(52)
	_check(game.defeated_ids.has(target_id) and game.kills == 1,
		"input heavy kill records real encounter ID", {"defeated_ids": game.defeated_ids, "kills": game.kills,
			"target_dead": is_instance_valid(target) and target.dead}, "ID 5 / 1 kill")
	var old_hero_id: int = game.hero.get_instance_id()
	game.spawn_projectile(Vector3(72, 4, 0), Vector3.RIGHT, "orb", 12, 2, game.enemies[0], Color.GOLD)
	var lethal: bool = game.hurt_player(1000, game.hero.global_position.x + 2, 0)
	_check(lethal and game.state == "dying" and game.hero.dead and game.death_count == 1 and game.projectiles.is_empty(),
		"lethal damage enters dying and clears projectiles", {"hero": _hero_snapshot(), "deaths": game.death_count, "projectiles": game.projectiles.size()}, "dying / dead hero / 1 death / cleared")
	await _frames(20)
	_check(game.state == "dying" and not game.hud.menu_panel.visible,
		"death animation precedes menu", {"state": game.state, "menu": game.hud.menu_panel.visible}, "dying / hidden")
	if not await _until(func(): return game.state == "dead", 70, "dead menu after .8s"):
		return
	await _frames(2)
	var retry: Button = game.hud.buttons["retry"]
	_check(retry.is_visible_in_tree() and root.gui_get_focus_owner() == retry,
		"dead menu focuses real RetryButton", {"visible": retry.is_visible_in_tree(), "focus": str(root.gui_get_focus_owner())}, "RetryButton")
	await _dispatch_ready()
	var callbacks_before: int = retry_callbacks
	await _tap(KEY_ENTER)
	await _frames(18)
	_check(retry_callbacks == callbacks_before + 1 and game.state == "playing" and game.hero.get_instance_id() != old_hero_id,
		"actual RetryButton callback respawns rather than calling retry directly", {"callback_delta": retry_callbacks - callbacks_before,
			"state": game.state, "old_id": old_hero_id, "new_id": game.hero.get_instance_id()}, "1 callback / new Player / playing")
	_check(absf(game.hero.global_position.x - 62.0) < 0.001 and game.hero.health == 100.0
		and game.hero.stamina == 100.0 and game.hero.potions == 3, "retry restores checkpoint resources", _hero_snapshot(), "x62 / 100 HP / 100 stamina / 3 bottles")
	var respawned_ids: Array[int] = []
	for enemy in game.enemies:
		respawned_ids.append(int(enemy.get_meta("spawn_id", -1)))
	_check(not respawned_ids.has(5) and game.kills == 1 and game.death_count == 1,
		"retry preserves defeated IDs and run counters", {"ids": respawned_ids, "kills": game.kills, "deaths": game.death_count}, "no ID5 / kills=1 / deaths=1")
	_check(not game.boss_started and not game.world._gate_closed,
		"retry resets encounter gate state", [game.boss_started, game.world._gate_closed], [false, false])


func _test_boss_threshold() -> void:
	await _setup("boss_exact_threshold", Vector3(160, 0.1, 0))
	game.boss.set_physics_process(true)
	await _frames(2)
	_check(not game.boss_started and game.boss.state == "dormant", "x=160 exactly does not start boss",
		[game.hero.global_position.x, game.boss_started, game.boss.state], [160, false, "dormant"])
	var protected: bool = game.boss.take_damage(1, 159, 0)
	_check(not protected and game.boss.health == 760.0, "pre-trigger boss refuses damage", [protected, game.boss.health], [false, 760])
	_key(KEY_D, true)
	await _frames(5)
	_release_all()
	await _frames(10)
	_check(game.boss_started and game.world._gate_closed and game.audio._requested_music == "boss",
		"input crosses trigger and engages gates/music", [game.boss_started, game.world._gate_closed, game.audio._requested_music], [true, true, "boss"])
	game.boss.take_damage(380, game.hero.global_position.x, 0)
	_check(game.boss.phase == 1 and game.boss.health == 380.0, "exactly half HP stays phase one", [game.boss.phase, game.boss.health], [1, 380])
	game.boss.take_damage(1, game.hero.global_position.x, 0)
	_check(game.boss.phase == 2 and game.boss.state == "transition", "below half HP starts phase two", [game.boss.phase, game.boss.state], [2, "transition"])
	await _frames(72)
	_check(game.boss.state == "transition" and game.boss.attack_events_count == 0,
		"phase transition is harmless for first 1.2s", [game.boss.state, game.boss.attack_events_count], ["transition", 0])
	await _frames(6)
	_check(game.boss.state == "idle" and game.boss.phase == 2,
		"transition recovers after 1.25s", [game.boss.state, game.boss.phase], ["idle", 2])
	game.complete_level()
	_check(game.state == "playing", "victory API refuses completion before boss defeat", game.state, "playing")


func _walk_to(x: float, limit: int = 180) -> bool:
	# Closed-loop movement; no position or velocity assignment in route/bot.
	for tick in range(limit):
		var dx: float = x - game.hero.global_position.x
		if absf(dx) < 0.20 and absf(game.hero.velocity.x) < 0.5:
			_key(KEY_A, false)
			_key(KEY_D, false)
			return true
		var braking: float = game.hero.velocity.x * absf(game.hero.velocity.x) / (2.0 * 48.0)
		var drive: float = dx - braking
		_key(KEY_A, drive < -0.08)
		_key(KEY_D, drive > 0.08)
		await _frames(1)
	_release_all()
	_check(false, "walk_to bounded input movement", _hero_snapshot(), "x=%.2f within .20" % x)
	return false


func _test_continuous_route() -> void:
	await _setup("continuous_route_AI_disabled", Vector3(5, 0.1, 0))
	var route: Dictionary = {"scope": "continuous input traversal; AI disabled, not no-cheat playthrough",
		"start_x": game.hero.global_position.x, "hero_teleports_after_start": 0,
		"gaps": [], "checkpoints": [], "resource_deficits": []}
	var next_gap: int = 0
	var jumping: bool = false
	var gap_record: Dictionary = {}
	var injected: Dictionary = {}
	var last_checkpoint: int = 0
	var continuous: bool = true
	var previous_x: float = game.hero.global_position.x
	_key(KEY_D, true)
	for tick in range(2200):
		var x: float = game.hero.global_position.x
		for index in [1, 2]:
			if not injected.has(index) and x > Catalog.CHECKPOINTS[index].x - 4.0:
				game.hero.health = 43.0
				game.hero.stamina = 12.0
				game.hero._regen_delay = 5.0
				game.hero.potions = 1
				injected[index] = true
				route.resource_deficits.append({"x": x, "checkpoint": index, "hp": 43, "stamina": 12, "potions": 1})
		if next_gap < Catalog.GAPS.size() and not jumping and x >= Catalog.GAPS[next_gap].x - 0.8:
			_key(KEY_SPACE, true)
			jumping = true
			gap_record = {"index": next_gap, "takeoff_x": x, "start_tick": tick,
				"hp_before": game.hero.health, "airborne_over_hole": false, "peak": 0.0}
		await _frames(1)
		x = game.hero.global_position.x
		continuous = continuous and absf(x - previous_x) <= 6.7 * DT + 0.005
		previous_x = x
		if jumping:
			var gap: Vector2 = Catalog.GAPS[next_gap]
			gap_record.peak = maxf(float(gap_record.peak), game.hero.global_position.y)
			if x > gap.x and x < gap.y and not game.hero.is_on_floor() and game.hero.global_position.y > 0.0:
				gap_record.airborne_over_hole = true
			if game.hero.is_on_floor() and x > gap.y:
				gap_record["landing_x"] = x
				gap_record["landing_tick"] = tick
				gap_record["hp_after"] = game.hero.health
				route.gaps.append(gap_record.duplicate())
				_check(bool(gap_record.airborne_over_hole) and float(gap_record.hp_before) == game.hero.health,
					"continuous input jump crosses real gap %d without teleport/fall" % (next_gap + 1), gap_record, "airborne over actual hole, same HP")
				next_gap += 1
				jumping = false
				_key(KEY_SPACE, false)
		if game.checkpoint_index != last_checkpoint:
			var entry: Dictionary = {"index": game.checkpoint_index, "trigger_x": x,
				"hp": game.hero.health, "stamina": game.hero.stamina, "potions": game.hero.potions}
			route.checkpoints.append(entry)
			_check(game.hero.health == 100.0 and game.hero.stamina == 100.0 and game.hero.potions == 3,
				"automatic x%d checkpoint replenishes all resources" % int(Catalog.CHECKPOINTS[game.checkpoint_index].x), entry, "100 / 100 / 3")
			_check(bool(game.world.shrine_nodes[game.checkpoint_index].get_meta("active")),
				"automatic checkpoint activates real shrine", game.checkpoint_index, "active shrine")
			last_checkpoint = game.checkpoint_index
		if game.boss_started:
			break
		if game.hero.dead or game.hero.global_position.y < -2.0:
			break
	_release_all()
	await _frames(10)
	_check(continuous and next_gap == 3 and route.checkpoints.size() == 2 and game.boss_started,
		"x5 to arena: continuous locomotion, all three gaps and both checkpoints", route, "3 gaps / 2 checkpoints / boss trigger / no position discontinuity")
	traces["continuous_route"] = route
	if not game.boss_started:
		return
	var gates_enabled: bool = true
	for shape in game.world._gate_shapes:
		gates_enabled = gates_enabled and not shape.disabled
	_check(gates_enabled, "both real arena gate collision shapes close", game.world._gate_shapes.map(func(shape): return shape.disabled), [false, false])
	_key(KEY_A, true)
	await _frames(65)
	_release_all()
	_check(game.hero.global_position.x > 158.5 and game.hero.global_position.x < 158.65,
		"closed entrance blocks actual leftward running", _hero_snapshot(), "capsule stops at x158.56")
	_key(KEY_D, true)
	await _frames(310)
	_release_all()
	_check(game.hero.global_position.x < 186.5 and game.hero.global_position.x > 186.3 and game.state == "playing",
		"exit gate physically blocks run before boss defeat", _hero_snapshot(), "x186.44 / playing")
	game.complete_level()
	_check(game.state == "playing" and not game.boss_defeated, "reaching exit side is not victory while boss lives", game.state, "playing")
	# Same continuous run: return by input, defeat full-HP boss with real attacks.
	# Only AI is disabled; no direct boss damage, health edits or invulnerability.
	game.boss.set_physics_process(true)
	var phase_two_seen: bool = false
	var blows: int = 0
	for attempt in range(12):
		if game.boss_defeated:
			break
		if not await _walk_to(game.boss.global_position.x - 2.0, 220):
			break
		await _tap(KEY_D)
		await _frames(3)
		if not await _until(func(): return game.hero.stamina >= 26.0 and game.hero.state == "idle", 150, "heavy stamina recovery"):
			break
		await _tap(KEY_K, 60)
		await _frames(51)
		blows += 1
		if is_instance_valid(game.boss):
			phase_two_seen = phase_two_seen or game.boss.phase == 2
	_check(game.boss_defeated and phase_two_seen, "input heavy attacks defeat real 760-HP boss through phase two",
		{"defeated": game.boss_defeated, "phase_two_seen": phase_two_seen, "heavy_attacks": blows,
			"remaining_hp": game.boss.health if is_instance_valid(game.boss) else 0}, "boss defeated / phase2 / no direct damage fixture")
	await _frames(2)
	_check(not game.world._gate_closed and game.world._gate_shapes.all(func(shape): return shape.disabled),
		"boss defeat callback opens both physical gates", game.world._gate_shapes.map(func(shape): return shape.disabled), [true, true])
	_check(game.state == "playing" and game.hero.global_position.x < 191.0,
		"boss kill alone does not prematurely complete chapter", _hero_snapshot(), "playing until x>=191")
	if not game.boss_defeated:
		return
	_key(KEY_D, true)
	await _until(func(): return game.state == "victory", 240, "input walks through opened exit to x191")
	_release_all()
	await _frames(3)
	_check(game.state == "victory" and game.hero.global_position.x >= 191.0 and game.hero.animation_name == "ending",
		"crossing x191 after boss defeat reaches victory", _hero_snapshot(), "victory / x>=191 / ending animation")
	_check(game.hud.menu_panel.visible and game.hud.buttons["replay"].is_visible_in_tree() and game.audio._requested_music == "victory",
		"victory menu, replay callback and victory music are wired", {"menu": game.hud.menu_panel.visible,
			"replay_connections": game.hud.buttons["replay"].pressed.get_connections().size(), "music": game.audio._requested_music}, "menu / replay connected / victory")
	var elapsed: float = game.elapsed
	await _frames(30)
	_check(game.elapsed == elapsed and game.projectiles.is_empty(), "victory stops gameplay timer/projectiles", [game.elapsed, game.projectiles.size()], [elapsed, 0])
	route["victory"] = game.state == "victory"
	route["end_x"] = game.hero.global_position.x
	route["boss_heavy_attacks"] = blows
	traces["continuous_route"] = route


func _attempt_input_only_playthrough() -> void:
	section = "optional_input_only_playthrough"
	_release_all()
	game.return_to_title()
	seed(SEED_VALUE)
	game.effects._rng.seed = SEED_VALUE
	await _frames(3)
	await _dispatch_ready()
	await _tap(KEY_ENTER)
	await _frames(18)
	var ready: bool = game.state == "playing" and game.hero.health == 100.0 and game.hero.stamina == 100.0 \
		and game.enemies.size() == 15 and game.enemies.all(func(enemy): return enemy.ai_enabled and enemy.is_physics_processing())
	_check(ready, "no-cheat bot starts at x5 with every real enemy AI enabled", _hero_snapshot(), "normal run / all 15 AIs enabled")
	if not ready:
		bot_result = {"attempted": false, "achieved": false, "reason": "normal-start precondition failed"}
		return
	var start_inputs: int = input_events
	var events: Array[Dictionary] = []
	var peak_x: float = game.hero.global_position.x
	var previous_hp: float = game.hero.health
	var previous_kills: int = game.kills
	var previous_checkpoint: int = game.checkpoint_index
	var gap_index: int = 0
	var airborne_gap: bool = false
	var gap_start: float = 0.0
	var gap_records: Array[Dictionary] = []
	var ticks_used: int = 0
	var heal_cooldown: int = 0
	for tick in range(12000):
		ticks_used = tick + 1
		if game.state != "playing" or game.hero.dead:
			break
		var hero = game.hero
		var target
		var distance: float = INF
		for enemy in game.enemies:
			if not is_instance_valid(enemy) or enemy.dead or enemy.global_position.x < hero.global_position.x - 6.0:
				continue
			var candidate: float = absf(enemy.global_position.x - hero.global_position.x)
			if candidate < distance:
				target = enemy
				distance = candidate
		var move: int = 1
		var light: bool = false
		var guard: bool = false
		var jump: bool = false
		var dodge: bool = false
		var heal: bool = false
		heal_cooldown = maxi(0, heal_cooldown - 1)
		if is_instance_valid(target) and distance < 12.0:
			var direction: int = 1 if target.global_position.x > hero.global_position.x else -1
			move = direction if distance > 1.85 else 0
			if distance <= 2.25:
				if hero.facing != direction and hero.state == "idle":
					move = direction
				else:
					light = tick % 6 == 0 and hero.stamina >= 7.0
			if target.kind == "boss":
				var remaining: float = 10.0
				if not target._stages.is_empty() and target._stage_index >= 0:
					remaining = float(target._stages[target._stage_index].duration) - target._stage_elapsed
				if target.state == "windup":
					# A single .42s cut fits early tells; late tells must leave idle
					# frames for a genuine guard press, not set guarding directly.
					light = light and hero.state == "idle" and remaining > 0.55
					guard = target.attack_name == "sweep" and remaining <= 0.12
					jump = target.attack_name == "bell" and remaining <= 0.16 and hero.is_on_floor()
				elif target.state == "active":
					light = false
				elif target.state == "airborne":
					light = false
					move = -1 if hero.global_position.x > 166.0 else 1
					jump = target.velocity.y < 0.0 and target.global_position.y < 1.4 and hero.is_on_floor()
				elif target.state == "recovery" and remaining < 0.3:
					light = false
				if guard:
					move = 0
					if hero.state == "attack" and hero.action_time >= hero.ATTACK_WINDUP[hero.combo_index] + hero.ATTACK_ACTIVE[hero.combo_index]:
						dodge = hero.stamina >= 20.0
		if hero.health <= 48.0 and hero.potions > 0 and hero.state == "idle" and heal_cooldown == 0:
			var safe: bool = not is_instance_valid(target) or distance > 5.0 or target.state in ["hurt", "recovery", "transition"]
			if safe:
				heal = true
				light = false
				move = 0
				heal_cooldown = 65
		# Real holes take precedence over pursuit. Hold Space through the arc.
		if gap_index < Catalog.GAPS.size():
			var gap: Vector2 = Catalog.GAPS[gap_index]
			if not airborne_gap and hero.global_position.x >= gap.x - 0.8 and hero.global_position.x < gap.y:
				if hero.state == "idle":
					airborne_gap = true
					gap_start = hero.global_position.x
			if airborne_gap:
				jump = true
				move = 1
				light = false
				guard = false
				heal = false
				if hero.is_on_floor() and hero.global_position.x > gap.y:
					gap_records.append({"gap": gap_index + 1, "takeoff_x": gap_start,
						"landed_x": hero.global_position.x, "hp": hero.health})
					gap_index += 1
					airborne_gap = false
					jump = false
		if hero.state == "heal":
			move = 0
			light = false
		_key(KEY_A, move < 0)
		_key(KEY_D, move > 0)
		_key(KEY_J, light)
		_key(KEY_Q, guard)
		_key(KEY_SPACE, jump)
		_key(KEY_L, dodge)
		_key(KEY_E, heal)
		await _frames(1)
		peak_x = maxf(peak_x, game.hero.global_position.x)
		if game.hero.health != previous_hp or game.kills != previous_kills or game.checkpoint_index != previous_checkpoint or tick % 300 == 0:
			events.append({"tick": tick, "hero": _hero_snapshot(), "kills": game.kills,
				"checkpoint": game.checkpoint_index, "boss_phase": game.boss.phase if is_instance_valid(game.boss) else 0,
				"boss_hp": game.boss.health if is_instance_valid(game.boss) else 0})
		previous_hp = game.hero.health
		previous_kills = game.kills
		previous_checkpoint = game.checkpoint_index
	_release_all()
	bot_result = {"attempted": true, "achieved": game.state == "victory", "attempts": 1,
		"reason": "victory" if game.state == "victory" else ("player died" if game.hero.dead else "12000-tick budget exhausted"),
		"ticks": ticks_used, "budget_ticks": 12000, "highest_x": peak_x, "hero": _hero_snapshot(),
		"kills": game.kills, "deaths": game.death_count, "checkpoint": game.checkpoint_index,
		"gaps_crossed": gap_records, "boss_started": game.boss_started, "boss_defeated": game.boss_defeated,
		"boss_hp": game.boss.health if is_instance_valid(game.boss) else 0,
		"boss_phase": game.boss.phase if is_instance_valid(game.boss) else 0,
		"parsed_input_events": input_events - start_inputs, "hp_damage_or_invulnerability_cheats": false,
		"actor_teleports_after_BEGIN": 0, "ai_disabled_after_BEGIN": false, "event_trace": events,
		"note": "A single bounded exploratory bot attempt; failure is not rewritten as a successful playthrough."}
	print("BOT_ATTEMPT_END achieved=%s reason=%s peak_x=%.3f kills=%d hp=%.1f" % [bot_result.achieved,
		bot_result.reason, peak_x, game.kills, game.hero.health])
	_save(false)