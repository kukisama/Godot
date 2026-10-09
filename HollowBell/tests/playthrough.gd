extends SceneTree
## Standalone, full-main, INPUT-ONLY Chapter I playthrough, not a fixture.
## --headless --fixed-fps 60 --script res://tests/playthrough.gd -- --label=attempt1
## The only gameplay property this test writes is test_mode BEFORE _ready.
## AI, terrain, combat, healing, checkpoint rewards and retries are production code.
## White-box observation of attack stages/projectiles is intentional, not human AI.

const MainScene: PackedScene = preload("res://main.tscn")
const Catalog = preload("res://scripts/catalog.gd")
const DT: float = 1.0 / 60.0
const MAX_TICKS: int = 60 * 60 * 15
const MAX_RETRIES: int = 5
const SEED_VALUE: int = 0x48425054
const KEYS: Array[int] = [KEY_ENTER, KEY_A, KEY_D, KEY_SPACE, KEY_J,
	KEY_K, KEY_L, KEY_Q, KEY_E]
const IMMUTABLE_PATHS: Array[String] = ["scripts/player.gd", "scripts/actor.gd",
	"scripts/game.gd", "scripts/enemy.gd", "scripts/catalog.gd",
	"tests/test_game.gd", "tests/test_enemy_contract.gd", "tests/render_capture.gd"]

class FrameFence extends Node:
	signal settled

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1000000

	func _process(_delta: float) -> void:
		settled.emit()

var game
var fence: FrameFence
var running: bool = false
var finished: bool = false
var ticks: int = 0
var loop_frames: int = 0
var started_ms: int = 0
var label: String = ""
var held: Dictionary = {}
var inputs: Array[Dictionary] = []
var events: Array[Dictionary] = []
var violations: Array[String] = []
var source_hashes: Dictionary = {}
var begin_callbacks: int = 0
var retry_callbacks: int = 0
var retries: int = 0
var native_start: Dictionary = {}
var retry_records: Array[Dictionary] = []
var checkpoints: Array[Dictionary] = []
var gaps: Array[Dictionary] = []
var fall_records: Array[Dictionary] = []
var enemy_records: Dictionary = {}
var enemy_attack_events: Dictionary = {}
var enemy_attack_names: Dictionary = {}
var kinds_met: Dictionary = {}
var defeated: Dictionary = {}
var player_attacks: Array[Dictionary] = []
var total_parries: int = 0
var previous_hero_id: int = 0
var previous_hero: Dictionary = {}
var previous_commits: int = 0
var previous_parries: int = 0
var previous_checkpoint: int = 0
var previous_deaths: int = 0
var previous_boss_stage: String = ""
var boss_phase_seen: int = 1
var boss_start_health: float = 0.0
var peak_x: float = 5.0
var last_progress: int = 0
var next_gap: int = 0
var gap_active: bool = false
var gap_trace: Dictionary = {}
var ledge_retreat: float = INF
var heavy_goal: float = 0.70
var boss_evade_key: String = ""
var boss_evade_x: float = 0.0
var policy_reason: String = "boot"


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	Input.use_accumulated_input = false
	seed(SEED_VALUE)
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--label="):
			var candidate: String = argument.trim_prefix("--label=")
			if not candidate.is_empty() and candidate.length() <= 40 and candidate.is_valid_filename() \
					and not candidate.contains("."):
				label = "-" + candidate
	_run.call_deferred()


func _process(_delta: float) -> bool:
	loop_frames += 1
	if running and (loop_frames > MAX_TICKS + 2000 or Time.get_ticks_msec() - started_ms > 240000):
		_finish(false, "watchdog: 15-minute simulation/frame or 240-second wall budget")
	return false


func _run() -> void:
	running = true
	for path: String in IMMUTABLE_PATHS + ["scripts/world.gd", "scripts/hud.gd", "project.godot", "main.tscn"]:
		source_hashes[path] = FileAccess.get_sha256("res://" + path)
	for kind: String in Catalog.ENEMIES:
		enemy_attack_events[kind] = 0
	fence = FrameFence.new()
	root.add_child(fence)
	game = MainScene.instantiate()
	game.test_mode = true
	root.add_child(game)
	current_scene = game
	game.hud.buttons["begin"].pressed.connect(func(): begin_callbacks += 1)
	game.hud.buttons["retry"].pressed.connect(func(): retry_callbacks += 1)
	await _frames(3)
	if game.state != "title" or root.gui_get_focus_owner() != game.hud.buttons["begin"]:
		_finish(false, "actual title/BEGIN focus precondition failed")
		return
	native_start = {"state_before": game.state, "focused_button": str(root.gui_get_focus_owner().name),
		"spawn_x": game.hero.global_position.x, "boss_hp": game.boss.health}
	_key(KEY_ENTER, true)
	await _frames(1)
	_key(KEY_ENTER, false)
	await _frames(18)
	native_start["state_after"] = game.state
	native_start["begin_callbacks"] = begin_callbacks
	native_start["hero"] = _hero_snapshot()
	var all_ai: bool = game.enemies.all(func(enemy): return enemy.ai_enabled and enemy.is_physics_processing())
	if game.state != "playing" or begin_callbacks != 1 or not all_ai or game.enemies.size() != 15 \
			or not is_equal_approx(game.hero.global_position.x, 5.0) or game.hero.health != 100.0 \
			or game.hero.stamina != 100.0 or game.hero.potions != 3 or game.boss.health != 760.0:
		_finish(false, "normal x5 / full resources / all 15 AIs / 760-HP boss precondition failed")
		return
	_log("BEGIN_INPUT_CONFIRMED", native_start)
	_observe()
	while running and ticks < MAX_TICKS:
		if game.state == "victory":
			_finish(true, "native boss defeat and x191 exit reached")
			return
		if not violations.is_empty():
			_finish(false, "input-only invariant violation")
			return
		if game.state == "dead":
			if retries >= MAX_RETRIES:
				_finish(false, "five native checkpoint retries exhausted")
				return
			await _retry_native()
			continue
		if game.state == "dying":
			_release_all()
			await _frames(1)
			_observe()
			continue
		if game.state != "playing":
			_finish(false, "unexpected game state: " + str(game.state))
			return
		if ticks - last_progress > 3600:
			_finish(false, "60 simulated seconds without route/kill/boss-damage progress")
			return
		var plan: Dictionary = _decide()
		policy_reason = str(plan.reason)
		_apply_input(plan)
		await _frames(1)
		_observe()
	_finish(false, "15-minute simulated playthrough budget exhausted")


func _frames(count: int) -> void:
	for index in range(count):
		var before: int = Engine.get_physics_frames()
		await physics_frame
		await process_frame
		await fence.settled
		ticks += 1
		if Engine.get_physics_frames() - before != 1 and not violations.has("non-60Hz frame barrier"):
			violations.append("non-60Hz frame barrier")


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
	inputs.append({"tick": ticks, "key": OS.get_keycode_string(code), "down": down})


func _release_all() -> void:
	for code: int in KEYS:
		_key(code, false)


func _apply_input(plan: Dictionary) -> void:
	_key(KEY_A, int(plan.move) < 0)
	_key(KEY_D, int(plan.move) > 0)
	_key(KEY_SPACE, bool(plan.jump))
	_key(KEY_J, bool(plan.light))
	_key(KEY_K, bool(plan.heavy))
	_key(KEY_L, bool(plan.dodge))
	_key(KEY_Q, bool(plan.guard))
	_key(KEY_E, bool(plan.heal))


func _blank(reason: String = "route") -> Dictionary:
	return {"move": 0, "jump": false, "light": false, "heavy": false,
		"dodge": false, "guard": false, "heal": false, "reason": reason}


func _nearest():
	var target = null
	var distance: float = INF
	for enemy in game.enemies:
		if not is_instance_valid(enemy) or enemy.dead:
			continue
		var dx: float = enemy.global_position.x - game.hero.global_position.x
		if enemy.kind == "boss" and not game.boss_started:
			continue
		if absf(dx) < distance:
			target = enemy
			distance = absf(dx)
	return target


func _remaining(enemy) -> float:
	if enemy._stage_index < 0 or enemy._stages.is_empty():
		return 0.0
	return maxf(0.0, float(enemy._stages[enemy._stage_index].duration) - float(enemy._stage_elapsed))


func _direction(dx: float) -> int:
	return 1 if dx >= 0.0 else -1


func _seek(x: float) -> int:
	var hero = game.hero
	var braking: float = hero.velocity.x * absf(hero.velocity.x) / 96.0
	var drive: float = x - hero.global_position.x - braking
	return 0 if absf(drive) < 0.10 else _direction(drive)


func _decide() -> Dictionary:
	var hero = game.hero
	var target = _nearest()
	var plan: Dictionary = _blank()
	if game.boss_defeated:
		plan.move = 1
		plan.reason = "walk through genuinely opened exit"
		return plan
	if _gap_policy(plan, target):
		return plan
	if hero.state == "heal":
		plan.reason = "finish native flask animation"
		return plan
	if is_instance_valid(target) and target.kind == "boss" and game.boss_started:
		return _boss_policy(target)
	plan.move = 1
	if not is_instance_valid(target) or absf(target.global_position.x - hero.global_position.x) > 15.0:
		if hero.state == "idle" and hero.health <= 48.0 and hero.potions > 0:
			plan.move = 0
			plan.heal = true
			plan.reason = "native E flask on clear route"
		return plan
	var dx: float = target.global_position.x - hero.global_position.x
	var distance: float = absf(dx)
	var direction: int = _direction(dx)
	plan.move = direction if distance > 1.95 else 0
	plan.reason = "close on " + str(target.kind)
	# A flier can dive back over the hole while our forward roll is landing.
	# Wait for its return from the solid bank, not by following it into the gap.
	for cleared_gap: Vector2 in Catalog.GAPS:
		if hero.global_position.x > cleared_gap.y and target.global_position.x < cleared_gap.y + 0.45 \
				and hero.global_position.x < cleared_gap.y + 12.0:
			if hero.global_position.x < cleared_gap.y + 1.45:
				plan.move = 1
				plan.reason = "leave room behind a left-facing strike at cleared gap"
				return plan
			if distance > 2.28:
				plan.move = _seek(cleared_gap.y + 1.95)
				plan.reason = "wait on solid far bank for flier recovery"
				return plan
	if hero.state == "charge":
		plan.move = 0
		plan.heavy = hero.charge < heavy_goal
		if target.state == "windup" and _remaining(target) <= 0.24:
			plan.heavy = false
		plan.reason = "release K before warden impact"
		return plan
	if hero.state == "attack":
		# Do not queue attacks near a ledge: an already queued combo cannot be
		# cancelled by simply releasing J when the takeoff point is reached.
		var ledge_room: bool = next_gap >= Catalog.GAPS.size() or hero.global_position.x < Catalog.GAPS[next_gap].x - 3.0
		for cleared_gap: Vector2 in Catalog.GAPS:
			if hero.facing < 0 and hero.global_position.x > cleared_gap.y and hero.global_position.x < cleared_gap.y + 3.0:
				ledge_room = false
		plan.light = ledge_room and distance < 3.0 and hero.combo_index < 2 \
			and hero.stamina >= 10.0 and not bool(held.get(KEY_J, false))
		return plan
	if hero.state != "idle":
		return plan
	if hero.facing != direction:
		plan.move = direction
		plan.reason = "turn by movement input before striking"
		return plan
	if hero.health <= 42.0 and hero.potions > 0 and distance > 5.5:
		plan.move = 0
		plan.heal = true
		plan.reason = "native E flask at safe distance"
		return plan
	if target.kind == "warden" and distance <= 3.0 and hero.stamina >= 26.0:
		if target.state != "active" and (target.state != "windup" or _remaining(target) > 0.42):
			heavy_goal = clampf((float(target.health) - 48.0) / 36.0 + 0.03, 0.08, 0.70)
			plan.move = 0
			plan.heavy = not bool(held.get(KEY_K, false))
			plan.reason = "K heavy against warden, normal damage"
			return plan
	if target.state == "windup" and _remaining(target) < 0.16 and distance < float(Catalog.ENEMIES[target.kind].range) + 0.3:
		plan.move = 0
		plan.guard = true
		plan.reason = "fresh Q in late ordinary tell"
	elif distance <= 2.28 and absf(target.global_position.y - hero.global_position.y) < 2.74 and hero.stamina >= 7.0:
		plan.move = 0
		plan.light = not bool(held.get(KEY_J, false))
		plan.reason = "J interrupts ordinary windup/hurt/recovery"
	return plan


func _gap_policy(plan: Dictionary, target) -> bool:
	if next_gap >= Catalog.GAPS.size():
		return false
	var hero = game.hero
	var gap: Vector2 = Catalog.GAPS[next_gap]
	var x: float = hero.global_position.x
	if gap_active:
		if bool(gap_trace.airborne) and hero.is_on_floor() and x > gap.y + 0.12:
			gap_trace["landed_x"] = x
			gap_trace["landing_tick"] = ticks
			gap_trace["hp_after"] = hero.health
			gaps.append(gap_trace.duplicate(true))
			_log("GAP_LANDED", {"gap": next_gap + 1, "takeoff_x": gap_trace.get("takeoff_x", 0),
				"landed_x": x, "peak_y": gap_trace.peak_y, "air_samples": gap_trace.samples.size()})
			next_gap += 1
			gap_active = false
			gap_trace = {}
			return false
		plan.move = 1
		plan.reason = "gap %d: uninterrupted forward input through landing" % (next_gap + 1)
		if str(gap_trace.mode) == "backstep":
			plan.move = -1
			if x <= gap.x - 2.5:
				gap_trace.mode = "runup"
		elif str(gap_trace.mode) == "runup":
			if x >= gap.x - 0.85 and hero.state == "idle":
				if hero.velocity.x < 6.3 and hero.is_on_floor():
					gap_trace.mode = "backstep"
					plan.move = -1
				else:
					gap_trace.mode = "flight"
					gap_trace["takeoff_x"] = x
					gap_trace["takeoff_tick"] = ticks
					gap_trace["takeoff_vx"] = hero.velocity.x
					plan.jump = true
		else:
			plan.jump = true
			# Normal roll i-frames preserve forward motion; do not turn toward,
			# attack, block or stop for the far-bank gargoyle during this arc.
			if is_instance_valid(target) and target.kind == "gargoyle" and target.state == "windup" \
					and _remaining(target) <= 0.12 and absf(target.global_position.x - x) < 3.2 \
					and hero.state == "idle" and hero.stamina >= 20.0:
				plan.dodge = not bool(held.get(KEY_L, false))
				plan.reason = "forward roll through telegraphed dive; D and Space stay held"
		return true
	# Fight enemies still on this bank, but backstep before their knockback
	# tempts a committed combo off the edge. Never pursue a far-bank flier in air.
	var same_bank: bool = is_instance_valid(target) and target.global_position.x < gap.x - 0.45 \
		and absf(target.global_position.x - x) < 7.0
	if ledge_retreat != INF:
		plan.move = -1
		plan.reason = "make room for a grounded ledge fight"
		if x <= ledge_retreat:
			ledge_retreat = INF
		return true
	if same_bank and x >= gap.x - 1.4:
		ledge_retreat = gap.x - 3.0
		plan.move = -1
		plan.reason = "backstep, not an attack off the ledge"
		return true
	if x >= gap.x - 2.5 and x < gap.y and not same_bank:
		gap_active = true
		gap_trace = {"gap": next_gap + 1, "bounds": [gap.x, gap.y], "mode": "runup",
			"hp_before": hero.health, "airborne": false, "over_hole": false, "peak_y": 0.0, "samples": []}
		plan.move = 1
		plan.reason = "reserve jump runway; forbid light/heavy/guard/heal/roll"
		return true
	return false


func _wave_threat() -> Dictionary:
	var hero = game.hero
	var result: Dictionary = {"eta": INF, "source_x": 0.0}
	for item: Dictionary in game.projectiles:
		if str(item.kind) != "wave" or not is_instance_valid(item.node):
			continue
		var dx: float = item.node.position.x - hero.global_position.x
		var speed: float = item.velocity.x
		if dx * speed > 0.0:
			continue
		var eta: float = maxf(0.0, (absf(dx) - 0.56) / maxf(0.01, absf(speed)))
		if eta < float(result.eta):
			result = {"eta": eta, "source_x": item.node.position.x}
	return result


func _boss_policy(boss) -> Dictionary:
	var hero = game.hero
	var plan: Dictionary = _blank("observe boss")
	var dx: float = boss.global_position.x - hero.global_position.x
	var distance: float = absf(dx)
	var direction: int = _direction(dx)
	var remaining: float = _remaining(boss)
	var stage_duration: float = remaining + float(boss._stage_elapsed)
	var threat: Dictionary = _wave_threat()
	var wave_eta: float = float(threat.eta)
	var future_wave_eta: float = INF
	var safe_to_cut: bool = false
	var safe_to_heal: bool = false
	if boss.attack_name == "jump_slam" and boss.state in ["windup", "airborne", "active"]:
		var evade_key: String = "%d:%d:%d" % [boss.get_instance_id(), boss._attack_epoch,
			boss._stage_index - (1 if boss.state == "airborne" else (2 if boss.state == "active" else 0))]
		if evade_key != boss_evade_key:
			boss_evade_key = evade_key
			var landing_x: float = boss._jump_target.x
			var away: int = -1 if hero.global_position.x <= landing_x else 1
			if (landing_x - 159.4 if away < 0 else 185.5 - landing_x) < 5.5:
				away = -away
			boss_evade_x = clampf(landing_x + float(away) * 5.5, 159.4, 185.5)
		plan.move = _seek(boss_evade_x)
		plan.reason = "leave locked jump-slam landing point"
		if boss.state == "airborne":
			var y: float = maxf(0.0, boss.global_position.y)
			var vy: float = boss.velocity.y
			var landing_eta: float = (vy + sqrt(vy * vy + 48.0 * y)) / 24.0
			future_wave_eta = landing_eta + maxf(0.0, (absf(boss._jump_target.x - hero.global_position.x) - 1.21) / 7.0)
	elif boss.attack_name == "bell" and boss.state != "recovery":
		plan.reason = "three bell pulses: short jump cycles, no committed attack"
		if boss.state == "windup":
			future_wave_eta = remaining + maxf(0.0, (distance - 1.21) / 7.0)
	elif boss.attack_name == "sweep" and boss.state in ["windup", "active"]:
		plan.move = direction if distance > 2.12 else 0
		safe_to_cut = boss.state == "windup" and remaining > 0.64
		if distance < 5.0 and ((boss.state == "windup" and remaining <= 0.12) or boss.state == "active"):
			plan.move = direction if hero.facing != direction else 0
			plan.guard = true
			plan.reason = "fresh Q parry for real 4.7m sweep"
			if hero.state == "attack" and hero.action_time >= hero.ATTACK_WINDUP[hero.combo_index] + hero.ATTACK_ACTIVE[hero.combo_index] \
					and hero.stamina >= 20.0:
				plan.dodge = not bool(held.get(KEY_L, false))
				plan.move = direction
				plan.guard = false
				plan.reason = "roll through sweep if still in attack recovery"
	else:
		plan.move = direction if distance > 2.12 else 0
		safe_to_cut = boss.state in ["idle", "transition"] or (boss.state == "recovery" and remaining > 0.55)
		safe_to_heal = boss.state == "transition" and boss._phase_left > 1.0 \
			or (boss.state == "recovery" and stage_duration > 1.0 and remaining > 0.99)
		plan.reason = "punish final recovery / cooldown without queuing boss combos"
	if hero.state == "idle" and hero.health <= 50.0 and hero.potions > 0 \
			and safe_to_heal and wave_eta > 1.1:
		plan.move = 0
		plan.heal = true
		plan.reason = "E: one real flask in long harmless recovery"
		return plan
	var eta: float = minf(wave_eta, future_wave_eta)
	if hero.state == "idle" and hero.is_on_floor() and eta <= 0.30 and eta >= 0.12:
		plan.jump = not bool(held.get(KEY_SPACE, false))
		plan.reason = "SPACE short hop above 0.8m ground-wave hit plane"
		safe_to_cut = false
	# If a pulse reaches a landing earlier than a fresh jump can clear .8m,
	# face its source and use an actual fresh guard rather than taking a free hit.
	if hero.state == "idle" and wave_eta <= 0.12 and hero.global_position.y < 1.0:
		var wave_direction: int = _direction(float(threat.source_x) - hero.global_position.x)
		plan.move = wave_direction if hero.facing != wave_direction else 0
		plan.guard = true
		plan.jump = false
		plan.reason = "Q catches a wave arriving during landing"
		safe_to_cut = false
	if safe_to_cut and hero.state == "idle" and not plan.guard and not plan.jump and eta > 0.60 \
			and distance <= 2.28 and absf(boss.global_position.y - hero.global_position.y) < 2.7 and hero.stamina >= 18.0:
		if hero.facing != direction:
			plan.move = direction
		else:
			plan.move = 0
			plan.light = not bool(held.get(KEY_J, false))
	return plan


func _retry_native() -> void:
	_release_all()
	var old_id: int = game.hero.get_instance_id()
	var saved_kills: int = game.kills
	var saved_ids: Array = game.defeated_ids.keys()
	# Honour real HUD wall-clock debounce, without sleep or timestamp mutation.
	while running and Time.get_ticks_msec() - int(game.hud._last_action_ms) < 180:
		await _frames(1)
	if root.gui_get_focus_owner() != game.hud.buttons["retry"]:
		_finish(false, "native RetryButton is not focused")
		return
	var callback_before: int = retry_callbacks
	retries += 1
	_key(KEY_ENTER, true)
	await _frames(1)
	_key(KEY_ENTER, false)
	await _frames(18)
	var record: Dictionary = {"tick": ticks, "checkpoint": game.checkpoint_index,
		"focused_button": "RetryButton", "callback_delta": retry_callbacks - callback_before,
		"old_hero_id": old_id, "new_hero_id": game.hero.get_instance_id(),
		"kills_before": saved_kills, "kills_after": game.kills, "retained_ids": saved_ids,
		"hero": _hero_snapshot()}
	retry_records.append(record)
	_log("NATIVE_RETRY", record)
	if game.state != "playing" or retry_callbacks != callback_before + 1 or old_id == game.hero.get_instance_id() \
			or game.kills != saved_kills or not saved_ids.all(func(id): return game.defeated_ids.has(id)):
		_finish(false, "native retry/persistent-kills contract failed")
		return
	_reset_route_observer()
	last_progress = ticks
	_observe()


func _reset_route_observer() -> void:
	next_gap = 0
	while next_gap < Catalog.GAPS.size() and Catalog.GAPS[next_gap].y < game.hero.global_position.x:
		next_gap += 1
	gap_active = false
	gap_trace = {}
	ledge_retreat = INF
	boss_evade_key = ""


func _hero_snapshot() -> Dictionary:
	var hero = game.hero
	return {"x": hero.global_position.x, "y": hero.global_position.y,
		"vx": hero.velocity.x, "vy": hero.velocity.y, "floor": hero.is_on_floor(),
		"health": hero.health, "stamina": hero.stamina, "potions": hero.potions,
		"state": hero.state, "facing": hero.facing, "action_time": hero.action_time,
		"invulnerable": hero.invulnerable, "guarding": hero.guarding}


func _boss_snapshot() -> Dictionary:
	if not is_instance_valid(game.boss):
		return {"defeated": game.boss_defeated, "phase": boss_phase_seen, "health": 0.0 if game.boss_defeated else -1.0}
	var boss = game.boss
	return {"x": boss.global_position.x, "y": boss.global_position.y, "health": boss.health,
		"state": boss.state, "attack": boss.attack_name, "stage": boss._stage_index,
		"stage_elapsed": boss._stage_elapsed, "remaining": _remaining(boss),
		"phase": boss.phase, "attack_events": boss.attack_events_count, "defeated": boss.dead}


func _observe() -> void:
	var hero = game.hero
	var snapshot: Dictionary = _hero_snapshot()
	var hero_id: int = hero.get_instance_id()
	if Engine.physics_ticks_per_second != 60 or not is_equal_approx(Engine.time_scale, 1.0) or paused:
		violations.append("physics/time-scale/pause changed")
	if hero.health < 0.0 or hero.health > 100.0 or hero.stamina < -0.001 or hero.stamina > 100.001:
		violations.append("hero resource outside production bounds")
	if hero_id != previous_hero_id:
		previous_hero_id = hero_id
		previous_commits = 0
		previous_parries = 0
		previous_hero = {}
	if hero.attack_commits > previous_commits:
		var attack: Dictionary = {"tick": ticks, "elapsed": game.elapsed, "state": hero.state,
			"combo": hero.combo_index, "charge": hero.charge, "hero": snapshot,
			"reason": policy_reason}
		player_attacks.append(attack)
		previous_commits = hero.attack_commits
	if hero.parries > previous_parries:
		total_parries += hero.parries - previous_parries
		previous_parries = hero.parries
		_log("PARRY", {"hero": snapshot, "boss": _boss_snapshot(), "total": total_parries})
	if not previous_hero.is_empty():
		if absf(float(snapshot.x) - float(previous_hero.x)) > 1.0:
			if float(previous_hero.y) < -5.0 and absf(float(snapshot.x) - Catalog.CHECKPOINTS[game.checkpoint_index].x) < 0.1:
				var fall: Dictionary = {"tick": ticks, "before": previous_hero.duplicate(), "after": snapshot,
					"gap_attempt": gap_trace.duplicate(true)}
				fall_records.append(fall)
				_log("NATIVE_FALL_RETURN", fall)
				_reset_route_observer()
			else:
				violations.append("unexplained position discontinuity at tick %d" % ticks)
		if snapshot.health != previous_hero.health or snapshot.potions != previous_hero.potions:
			_log("PLAYER_RESOURCE", {"before": previous_hero, "after": snapshot,
				"reason": policy_reason, "boss": _boss_snapshot()})
	previous_hero = snapshot
	if hero.global_position.x > peak_x + 0.15:
		peak_x = hero.global_position.x
		last_progress = ticks
	if gap_active:
		gap_trace.peak_y = maxf(float(gap_trace.peak_y), hero.global_position.y)
		gap_trace.airborne = bool(gap_trace.airborne) or not hero.is_on_floor()
		var gap: Vector2 = Catalog.GAPS[next_gap]
		if hero.global_position.x > gap.x and hero.global_position.x < gap.y and hero.global_position.y > 0.0:
			gap_trace.over_hole = true
		gap_trace.samples.append({"tick": ticks, "x": snapshot.x, "y": snapshot.y, "vx": snapshot.vx,
			"vy": snapshot.vy, "state": snapshot.state, "floor": snapshot.floor,
			"D": bool(held.get(KEY_D, false)), "Space": bool(held.get(KEY_SPACE, false)),
			"J": bool(held.get(KEY_J, false)), "K": bool(held.get(KEY_K, false)),
			"L": bool(held.get(KEY_L, false)), "Q": bool(held.get(KEY_Q, false))})
		if str(gap_trace.mode) == "flight" and not hero.is_on_floor() \
				and (not bool(held.get(KEY_D, false)) or not bool(held.get(KEY_SPACE, false)) \
				or bool(held.get(KEY_J, false)) or bool(held.get(KEY_K, false))):
			violations.append("gap flight inputs interrupted at tick %d" % ticks)
	if game.checkpoint_index != previous_checkpoint:
		previous_checkpoint = game.checkpoint_index
		var checkpoint: Dictionary = {"index": previous_checkpoint, "tick": ticks,
			"elapsed": game.elapsed, "hero": snapshot}
		checkpoints.append(checkpoint)
		_log("CHECKPOINT_OBSERVED", checkpoint)
	if game.death_count != previous_deaths:
		previous_deaths = game.death_count
		_log("DEATH_OBSERVED", {"deaths": previous_deaths, "checkpoint": game.checkpoint_index,
			"hero": snapshot, "boss": _boss_snapshot()})
	for enemy in game.enemies:
		if not is_instance_valid(enemy):
			continue
		var id: String = str(enemy.get_instance_id())
		var spawn_id: int = int(enemy.get_meta("spawn_id", -1))
		if not enemy_records.has(id):
			enemy_records[id] = {"spawn_id": spawn_id, "kind": enemy.kind, "initial_hp": enemy.health,
				"last_hp": enemy.health, "events": 0, "damage_received": 0.0, "dead": false}
		var record: Dictionary = enemy_records[id]
		if not enemy.dead:
			if not enemy.ai_enabled or not enemy.is_physics_processing():
				violations.append("living enemy AI disabled: " + str(enemy.name))
			if enemy.state != "dormant":
				kinds_met[enemy.kind] = true
		var delta_events: int = enemy.attack_events_count - int(record.events)
		if delta_events > 0:
			enemy_attack_events[enemy.kind] = int(enemy_attack_events[enemy.kind]) + delta_events
			var attack_key: String = str(enemy.kind) + ":" + str(enemy.attack_name)
			enemy_attack_names[attack_key] = int(enemy_attack_names.get(attack_key, 0)) + delta_events
			record.events = enemy.attack_events_count
			_log("ENEMY_ATTACK", {"spawn_id": spawn_id, "kind": enemy.kind, "attack": enemy.attack_name,
				"count": enemy.attack_events_count, "hero": snapshot})
		if enemy.health < float(record.last_hp):
			var damage: float = float(record.last_hp) - float(enemy.health)
			record.damage_received = float(record.damage_received) + damage
			_log("ENEMY_DAMAGE", {"spawn_id": spawn_id, "kind": enemy.kind, "damage": damage,
				"health": enemy.health, "player_state": hero.state, "hero_x": snapshot.x,
				"enemy_x": enemy.global_position.x, "parries": total_parries})
			if enemy.kind == "boss":
				last_progress = ticks
		record.last_hp = enemy.health
		record.dead = enemy.dead
		if enemy.kind == "boss":
			boss_phase_seen = maxi(boss_phase_seen, enemy.phase)
			if game.boss_started and boss_start_health == 0.0:
				boss_start_health = enemy.health
			var stage_key: String = "%s:%s:%d:%d:%d" % [id, enemy.attack_name, enemy._attack_epoch, enemy._stage_index, enemy.phase]
			if game.boss_started and stage_key != previous_boss_stage:
				previous_boss_stage = stage_key
				_log("BOSS_STAGE", {"hero": snapshot, "boss": _boss_snapshot(), "reason": policy_reason})
	for id: int in game.defeated_ids:
		if not defeated.has(id):
			defeated[id] = {"tick": ticks, "kind": Catalog.SPAWNS[id].kind, "hero": snapshot}
			last_progress = ticks
			_log("KILL_OBSERVED", {"spawn_id": id, "kind": Catalog.SPAWNS[id].kind, "kills": game.kills})
	if ticks % 300 == 0:
		_log("PROGRESS", {"elapsed": game.elapsed, "hero": snapshot, "kills": game.kills,
			"deaths": game.death_count, "checkpoint": game.checkpoint_index, "boss": _boss_snapshot(), "reason": policy_reason})


func _log(event: String, data: Dictionary) -> void:
	var row: Dictionary = {"event": event, "tick": ticks, "data": data}
	events.append(row)
	print("PLAYTHROUGH " + JSON.stringify(row))


func _finish(won: bool, reason: String) -> void:
	if finished:
		return
	finished = true
	running = false
	_release_all()
	var final_hashes: Dictionary = {}
	var presentation_changes: Array[String] = []
	for path: String in source_hashes:
		final_hashes[path] = FileAccess.get_sha256("res://" + path)
		if final_hashes[path] != source_hashes[path]:
			if IMMUTABLE_PATHS.has(path):
				violations.append("immutable logic/existing test source changed during run: " + path)
			else:
				presentation_changes.append(path)
	var crossed: Dictionary = {}
	for gap: Dictionary in gaps:
		if bool(gap.over_hole) and gap.has("landed_x"):
			crossed[int(gap.gap)] = true
	var checkpoint_ids: Dictionary = {}
	for checkpoint: Dictionary in checkpoints:
		checkpoint_ids[int(checkpoint.index)] = true
	var full_route: bool = crossed.size() == 3 and checkpoint_ids.size() == 2
	var actual_victory: bool = is_instance_valid(game) and game.state == "victory" \
		and game.boss_defeated and game.hero.global_position.x >= 191.0
	var coverage: bool = actual_victory and full_route and game.kills >= 14 and kinds_met.size() == 8 \
		and boss_start_health == 760.0 and boss_phase_seen == 2 and begin_callbacks == 1
	var achieved: bool = won and coverage and violations.is_empty()
	var report: Dictionary = {"suite": "HollowBell standalone input-only first-level completion", "completed": true,
		"achieved": achieved, "actual_victory": actual_victory, "reason": reason,
		"coverage_passed": coverage, "seed": SEED_VALUE, "engine": Engine.get_version_info(),
		"test_sha256": FileAccess.get_sha256("res://tests/playthrough.gd"),
		"fixed_fps": 60, "physics_ticks_per_second": Engine.physics_ticks_per_second,
		"ticks": ticks, "budget_ticks": MAX_TICKS, "simulated_seconds": ticks * DT,
		"elapsed": game.elapsed, "wall_ms": Time.get_ticks_msec() - started_ms,
		"x": game.hero.global_position.x, "health": game.hero.health, "hero": _hero_snapshot(),
		"highest_x": maxf(peak_x, game.hero.global_position.x), "kills": game.kills,
		"deaths": game.death_count, "retries": retries, "max_retries": MAX_RETRIES,
		"falls": fall_records, "checkpoint": game.checkpoint_index, "checkpoints": checkpoints,
		"gaps": gaps, "unfinished_gap": gap_trace, "player_attack_count": player_attacks.size(),
		"player_attacks": player_attacks, "parries": total_parries,
		"enemy_attack_events": enemy_attack_events, "enemy_attack_names": enemy_attack_names,
		"enemy_instances": enemy_records, "kinds_met": kinds_met.keys(), "defeated_ids": defeated,
		"boss_initial_hp": boss_start_health, "boss_phase": boss_phase_seen, "boss": _boss_snapshot(),
		"native_start": native_start, "native_retries": retry_records,
		"input_event_count": inputs.size(), "input_events": inputs, "event_trace": events,
		"audit": {"violations": violations, "gameplay_writes": ["initial game.test_mode = true before add_child"],
			"hero_stat_writes": 0, "actor_position_writes": 0, "direct_damage_calls": 0,
			"ai_disable_calls": 0, "direct_start_retry_or_victory_calls": 0,
			"live_enemy_ai_checked_each_tick": true,
			"dead_enemy_ai_note": "Production Enemy._begin_death naturally disables its own AI; the bot never changes it.",
			"normal_rewards_note": "All healing, kill rewards, checkpoint resources and fall returns are production mechanics.",
			"observation_note": "Deterministic white-box bot reads stage elapsed/target/projectiles; only physical key events control play.",
			"source_sha256_before": source_hashes, "source_sha256_after": final_hashes,
			"concurrent_presentation_changes": presentation_changes},
		"scope": "Real main.tscn and all gameplay systems. Headless functional evidence, not visual/audio acceptance."}
	var path: String = "res://qa/playthrough%s.json" % label
	var output: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		printerr("PLAYTHROUGH_REPORT_WRITE_FAILED " + path)
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t") + "\n")
	output.close()
	print("PLAYTHROUGH_RESULT " + JSON.stringify({"achieved": achieved, "actual_victory": actual_victory,
		"reason": reason, "elapsed": game.elapsed, "x": report.x, "health": report.health,
		"kills": game.kills, "deaths": game.death_count, "retries": retries, "falls": fall_records.size(),
		"gaps": crossed.size(), "checkpoints": checkpoint_ids.size(), "player_attack_count": player_attacks.size(),
		"parries": total_parries, "enemy_attack_events": enemy_attack_events, "boss_phase": boss_phase_seen,
		"kinds_met": kinds_met.keys(), "violations": violations, "report": path}))
	quit(0 if achieved else 1)