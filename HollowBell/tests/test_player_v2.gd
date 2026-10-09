extends SceneTree
## TEST ONLY; --check-only executes no assertions. Run AFTER production + published art are ready:
## --headless --path HollowBell --script res://tests/test_player_v2.gd (forks all 60/120Hz pairs).
## Real MainScene/Player/Enemy/CCD; AI-disabled, relocated/resource-injected fixtures, not a playthrough.
## seek_animation_pose uses LOCAL index; metadata clock=index/fps. Labels attack_0..2 stay continuous.
## ATTACK_* arrays drive 4+4+4 poses. Heavy keeps the charge pose on release,
## then completes remaining anticipation + four strike + four recovery poses.
## Buffer TTL .16 starts on input-processing tick; .08 cooldown prevents restart/double-spend.
## Manual callbacks ONLY in frozen seek/timer-boundary fixtures; never Player begin_* shortcuts.
## Published-pixel content and headless render-callback sampling do NOT prove artistic/GPU quality.

const MainScene: PackedScene = preload("res://main.tscn")
const EnemyScript = preload("res://scripts/enemy.gd")
const RESULT: String = "res://qa/player-v2-results.json"
const EPS: float = 0.000001
const MARKER: String = "PLAYER_V2_CHILD_JSON="
const SHEETS: Dictionary = {"hero_v2_motion": [[0, 6], [6, 6], [12, 12]],
	"hero_v2_blade_a": [[0, 12], [12, 12]], "hero_v2_blade_b": [[0, 12], [12, 12]],
	"hero_v2_defense": [[0, 12], [12, 6], [18, 6]]}
const KEYS: Dictionary = {"enter": KEY_ENTER, "escape": KEY_ESCAPE, "left": KEY_A,
	"right": KEY_D, "jump": KEY_SPACE, "light": KEY_J, "heavy": KEY_K,
	"normal": KEY_SHIFT, "alias": KEY_L, "guard": KEY_Q, "quick": KEY_C, "heal": KEY_E}

class FrameFence extends Node:
	signal settled
	var suite
	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1000000; process_physics_priority = 1000000
	func _physics_process(delta: float) -> void:
		suite._sample_physics(delta)
	func _process(delta: float) -> void:
		suite._sample_render(delta)
		settled.emit()

var game; var fence: FrameFence
var physics_hz: int = 60; var render_hz: int = 60; var dt: float = 1.0 / 60.0
var physical_time: float = 0.0; var started_ms: int = 0
var section: String = "boot"; var running: bool = false
var checks: Array[Dictionary] = []; var failures: Array[Dictionary] = []
var history: Array[Dictionary] = []; var rendered: Array[Dictionary] = []
var fixtures: Array[Dictionary] = []; var watched: Array = []; var initial_hp: Array = []
var held: Dictionary = {}; var properties: Dictionary = {}
var profiles: Dictionary = {}; var traces: Dictionary = {}
var render_metrics: Dictionary = {"compared": 0, "mismatches": [], "bad_delta": [], "bad_physics_delta": [], "frames": 0}
var input_events: int = 0
func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	Input.use_accumulated_input = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--physics-hz="): physics_hz = int(arg.get_slice("=", 1))
		if arg.begins_with("--render-hz="): render_hz = int(arg.get_slice("=", 1))
	if "--v2-child" in OS.get_cmdline_user_args(): _child.call_deferred()
	else: _matrix.call_deferred()
func _process(_delta: float) -> bool:
	if running and Time.get_ticks_msec() - started_ms > 180000:
		running = false
		_check(false, "bounded coroutine watchdog", section, "finish within 180s")
		print(MARKER + JSON.stringify(_report(false)))
		quit(2)
	return false
func _check(ok: bool, label: String, actual: Variant, expected: Variant) -> void:
	var row: Dictionary = {"section": section, "label": label, "passed": ok,
		"actual": actual, "expected": expected, "physics_frame": Engine.get_physics_frames()}
	checks.append(row)
	if not ok:
		failures.append(row)
		printerr("FAIL " + JSON.stringify(row))
func _report(completed: bool) -> Dictionary:
	return {"completed": completed, "physics_hz": physics_hz, "render_hz": render_hz,
		"checks": checks.size(), "failed": failures.size(), "results": checks, "failures": failures,
		"profiles": profiles, "traces": traces, "fixtures": fixtures, "render_metrics": render_metrics,
		"parsed_input_events": input_events, "wall_ms": Time.get_ticks_msec() - started_ms}
func _matrix() -> void:
	var hashes: Dictionary = {}
	for path: String in ["scripts/player.gd", "scripts/actor.gd", "scripts/game.gd", "main.tscn", "project.godot"]:
		hashes[path] = FileAccess.get_sha256("res://" + path)
	_test_sheets()
	var runs: Array[Dictionary] = []
	for pair: Array in [[60, 60], [60, 120], [120, 60], [120, 120]]:
		section = "matrix_%d_%d" % pair
		var output: Array = []
		var args: PackedStringArray = ["--headless", "--audio-driver", "Dummy", "--path",
			ProjectSettings.globalize_path("res://"), "--fixed-fps", str(pair[1]), "--script",
			"res://tests/test_player_v2.gd", "--", "--v2-child", "--physics-hz=" + str(pair[0]), "--render-hz=" + str(pair[1])]
		var code: int = OS.execute(OS.get_executable_path(), args, output, true)
		var report: Dictionary = {}
		for block: Variant in output:
			for line: String in str(block).split("\n"):
				if line.begins_with(MARKER):
					var parsed: Variant = JSON.parse_string(line.substr(MARKER.length()))
					if parsed is Dictionary: report = parsed
		_check(not report.is_empty() and bool(report.get("completed", false)) and code == 0,
			"real child completed", {"exit": code, "checks": report.get("checks", 0), "failures": report.get("failures", []),
			"log_tail": str(output).right(2000) if report.is_empty() else ""}, "completed / exit 0 / no failed checks")
		runs.append(report)
	for indices: Array in [[0, 1], [2, 3]]:
		var a: Dictionary = runs[indices[0]].get("profiles", {})
		var b: Dictionary = runs[indices[1]].get("profiles", {})
		for key: String in ["attack_0", "attack_1", "attack_2", "heavy", "normal", "quick"]:
			_check(a.has(key) and b.has(key) and a[key].signature == b[key].signature,
				"render 60/120 preserves every physics pose: " + key,
				[a.get(key, {}), b.get(key, {})], "same physical-time/frame/label sequence")
	section = "sources"
	for path: String in hashes:
		_check(FileAccess.get_sha256("res://" + path) == hashes[path], "production unchanged: " + path,
			FileAccess.get_sha256("res://" + path), hashes[path])
	var report: Dictionary = _report(true)
	report.merge({"suite": "HollowBell Player v2", "matrix": runs, "source_sha256": hashes,
		"scope": "Real main fixtures, parsed physical inputs, late physics/render fences; no mocks, no playthrough or artistic-quality claim."})
	var file: FileAccess = FileAccess.open(RESULT, FileAccess.WRITE)
	if file == null:
		printerr("Cannot write " + RESULT + ": " + str(FileAccess.get_open_error()))
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n"); file.close()
	print("PLAYER V2: matrix children=%d, parent checks=%d, failures=%d; %s" % [runs.size(), checks.size(), failures.size(), RESULT])
	quit(0 if failures.is_empty() else 1)
func _child() -> void:
	running = true
	Engine.physics_ticks_per_second = physics_hz
	dt = 1.0 / float(physics_hz)
	seed(0x485632)
	fence = FrameFence.new()
	fence.suite = self
	root.add_child(fence)
	game = MainScene.instantiate()
	game.test_mode = true
	root.add_child(game)
	current_scene = game
	await _wait(3.0 * dt)
	await _tap("enter")
	await _wait(0.30)
	_check(game.state == "playing" and game.test_mode, "parsed BEGIN in real MainScene", game.state, "playing / test_mode")
	_check(Engine.physics_ticks_per_second == physics_hz and Engine.time_scale == 1.0, "real physics rate / no time acceleration", [Engine.physics_ticks_per_second, Engine.time_scale], [physics_hz, 1.0])
	var ready: bool = _contract()
	if ready:
		await _test_motion_and_seek()
		await _test_combat()
		for control: String in ["normal", "alias", "quick", "middle", "trigger"]: await _test_roll(control)
		await _test_buffers_and_denials()
		await _test_defense()
		await _test_parry_boundaries()
		await _test_pause()
	_check(int(render_metrics.compared) > 12 and render_metrics.mismatches.is_empty(),
		"render never advances externally clocked poses", render_metrics, "positive samples / zero mismatches")
	_check(render_metrics.bad_delta.is_empty(), "actual fixed render delta", render_metrics.bad_delta, 1.0 / render_hz)
	_check(render_metrics.bad_physics_delta.is_empty(), "every late physics sample uses actual quantum", render_metrics.bad_physics_delta, dt)
	_release()
	paused = false
	game.queue_free()
	await fence.settled
	running = false
	print(MARKER + JSON.stringify(_report(ready)))
	quit(0 if ready and failures.is_empty() else 1)
func _value(object: Object, key: String, fallback: Variant) -> Variant:
	var id: int = object.get_instance_id()
	if not properties.has(id):
		var names: Dictionary = {}
		for info: Dictionary in object.get_property_list(): names[str(info.name)] = true
		properties[id] = names
	return object.get(key) if properties[id].has(key) else fallback
func _event(control: String, down: bool) -> InputEvent:
	if control == "middle":
		var mouse: InputEventMouseButton = InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_MIDDLE; mouse.pressed = down
		return mouse
	if control == "trigger":
		var pad: InputEventJoypadMotion = InputEventJoypadMotion.new()
		pad.axis = JOY_AXIS_TRIGGER_RIGHT; pad.axis_value = 1.0 if down else 0.0
		return pad
	var key: InputEventKey = InputEventKey.new()
	key.physical_keycode = int(KEYS[control]); key.keycode = int(KEYS[control]); key.pressed = down
	return key
func _input(control: String, down: bool) -> void:
	if bool(held.get(control, false)) == down: return
	held[control] = down
	Input.parse_input_event(_event(control, down)); input_events += 1
func _release() -> void:
	for control: String in held: _input(control, false)
func _tap(control: String) -> void:
	_input(control, true)
	await _wait(dt)
	_input(control, false)
func _wait(seconds: float) -> void:
	var end: float = physical_time + seconds
	while physical_time + EPS < end: await fence.settled
func _snapshot() -> Dictionary:
	var h = game.hero
	return {"clock": physical_time, "state": h.state, "t": h.action_time, "combo": h.combo_index,
		"frame": h.sprite.frame, "index": h.animation_frame, "start": h.animation_start, "count": h.animation_count, "finished": h.animation_finished,
		"label": h.animation_name, "animation_clock": h.animation_clock, "hp": h.health, "stamina": h.stamina,
		"i": h.invulnerable, "p": _value(h, "parry_invulnerable", -1.0), "guard_time": h._guard_time,
		"x": h.global_position.x, "y": h.global_position.y, "vx": h.velocity.x, "commits": h.attack_commits,
		"sheet": h.sprite.texture.resource_path.get_file().get_basename() if h.sprite.texture != null else "MISSING",
		"targets": watched.map(func(e): return e.health if is_instance_valid(e) else -1.0)}
func _sample_physics(delta: float) -> void:
	physical_time += delta
	if absf(delta - dt) > EPS and render_metrics.bad_physics_delta.size() < 5: render_metrics.bad_physics_delta.append(delta)
	if is_instance_valid(game) and is_instance_valid(game.hero): history.append(_snapshot())
func _sample_render(delta: float) -> void:
	render_metrics.frames += 1
	if absf(delta - 1.0 / render_hz) > EPS and render_metrics.bad_delta.size() < 5: render_metrics.bad_delta.append(delta)
	if not is_instance_valid(game) or not is_instance_valid(game.hero): return
	var row: Dictionary = _snapshot(); rendered.append(row)
	if history.is_empty() or not game.hero.is_physics_processing(): return
	var last: Dictionary = history.back()
	if last.label == row.label and last.state == row.state and last.t == row.t:
		render_metrics.compared += 1
		if [last.frame, last.index, last.animation_clock] != [row.frame, row.index, row.animation_clock] and render_metrics.mismatches.size() < 5:
			render_metrics.mismatches.append({"physics": last, "render": row})
func _reset(label: String, settle: bool = true) -> void:
	section = label
	_release()
	paused = false
	game.start_game()
	game.set_physics_process(true) # Restore shared Main after isolated boundary callbacks.
	for enemy in game.enemies:
		enemy.ai_enabled = false; enemy.set_physics_process(false)
	game.hero.global_position = Vector3(10, 0.1, 0)
	watched.clear(); initial_hp.clear(); history.clear(); rendered.clear(); properties.clear()
	fixtures.append({"section": label, "start": [10, 0.1, 0], "ai": false, "real_main": true, "regen_delay_fixture": 100.0})
	if settle:
		await _wait(0.30) # 18 ticks at 60Hz / 36 at 120Hz, not 18 ticks mistaken for .30s at 120Hz.
		_check(game.hero.is_on_floor() and game.hero.control_lock == 0.0, "real terrain settled / .2s lock expired", _snapshot(), "grounded / unlocked")
	game.hero._regen_delay = 100.0
func _target(x: float, kind: String = "warden", frozen: bool = true):
	var enemy = EnemyScript.new()
	game.add_child(enemy)
	enemy.configure(game, kind, Vector3(x, 0.02, 0))
	game.enemies.append(enemy)
	enemy.ai_enabled = false; enemy.set_physics_process(not frozen)
	watched.append(enemy)
	initial_hp.append(enemy.health)
	return enemy
func _contract() -> bool:
	var before: int = failures.size()
	var h = game.hero
	_check(typeof(_value(h, "animation_external_clock", null)) == TYPE_BOOL and _value(h, "animation_external_clock", null) == true, "hero owns external physics animation clock", _value(h, "animation_external_clock", null), true)
	_check(_value(h, "parry_invulnerable", null) is float, "separate floating parry protection timer exists", _value(h, "parry_invulnerable", null), "float")
	_check(h.has_method("seek_animation_pose"), "Actor seek API exists", h.has_method("seek_animation_pose"), true)
	var roll: Dictionary = {}
	for method: Dictionary in h.get_method_list():
		if method.name == "begin_roll": roll = method
	_check(not roll.is_empty() and roll.args.size() >= 1 and roll.args[0].type == TYPE_BOOL and roll.default_args.size() >= 1 and typeof(roll.default_args[0]) == TYPE_BOOL and roll.default_args[0] == false,
		"begin_roll preserves no-argument API with optional quick=false", roll, "optional boolean / false")
	for control: String in ["quick", "middle", "trigger"]:
		var event: InputEvent = _event(control, true)
		_check(InputMap.has_action("quick_roll") and InputMap.action_has_event("quick_roll", event)
			and not InputMap.action_has_event("dodge", event), "independent quick_roll binding: " + control,
			InputMap.action_get_events("quick_roll").map(func(e): return e.as_text()) if InputMap.has_action("quick_roll") else [], "C / middle mouse / right trigger; not dodge")
	return failures.size() == before
func _test_sheets() -> void:
	section = "published_art_content"
	for name: String in SHEETS:
		var image: Image = Image.new()
		var error: Error = image.load(ProjectSettings.globalize_path("res://assets/sprites/" + name + ".png"))
		_check(error == OK and image.get_size() == Vector2i(1536, 1024), "published 6x4 sheet: " + name, {"error": error, "size": str(image.get_size())}, "1536x1024")
		if error != OK or image.get_size() != Vector2i(1536, 1024): continue
		image.convert(Image.FORMAT_RGBA8)
		var digests: Array[String] = []
		var empty: Array[int] = []
		for index in range(24):
			var tile: Image = image.get_region(Rect2i((index % 6) * 256, floori(index / 6.0) * 256, 256, 256))
			var bounds: Rect2i = tile.get_used_rect()
			if not bounds.has_area() or bounds.size == Vector2i(256, 256): empty.append(index)
			var hash: HashingContext = HashingContext.new()
			hash.start(HashingContext.HASH_SHA256); hash.update(str(bounds.size).to_utf8_buffer())
			hash.update(tile.get_region(bounds).get_data() if bounds.has_area() else PackedByteArray())
			digests.append(hash.finish().hex_encode())
		_check(empty.is_empty(), "24 nonempty transparent-backed cells: " + name, empty, [])
		for clip: Array in SHEETS[name]:
			var unique: Dictionary = {}
			for index in range(clip[0], clip[0] + clip[1]): unique[digests[index]] = true
			_check(unique.size() == clip[1], "distinct cropped poses, not body translation: %s %s" % [name, clip], unique.size(), clip[1])
		if name == "hero_v2_defense": _check(digests.slice(18, 24).any(func(d): return not d in digests.slice(12, 18)), "parry art is not recycled guard poses", digests.slice(12, 24), "distinct defense gestures")
func _rows(state: String, combo: int = -1, source: Variant = null) -> Array:
	var data: Array = history if source == null else source
	return data.filter(func(r): return r.state == state and (combo < 0 or r.combo == combo))
func _phase_pose(time: float, phases: Array, windup_pose: int = 0) -> int:
	var start: float = 0.0
	for index in range(3):
		if time < start + float(phases[index]):
			var first: int = clampi(windup_pose, 0, 3) if index == 0 else 0
			return index * 4 + first + clampi(floori((time - start) * float(4 - first) / float(phases[index])), 0, 3 - first)
		start += float(phases[index])
	return 11
func _clip(rows: Array, sheet: String, start: int, count: int, phases: Array = [], label: String = "", render_rows: Array = [], windup_pose: int = 0) -> Dictionary:
	var unique: Dictionary = {}; var labels: Dictionary = {}
	var bad: Array = []; var signature: Array = []
	var prior: int = -1; var previous_clock: float = -1.0
	for row: Dictionary in rows:
		unique[row.frame] = true; labels[row.label] = true
		signature.append([snappedf(float(row.t), EPS), row.frame, row.label])
		var valid: bool = row.sheet == sheet and row.start == start and row.count == count and row.index == row.frame - start
		valid = valid and row.frame >= start and row.frame < start + count and (label.is_empty() or row.label == label)
		if not phases.is_empty(): valid = valid and row.frame == start + _phase_pose(float(row.t), phases, windup_pose)
		if not row.label in ["idle", "run"]: valid = valid and row.frame >= prior and row.animation_clock + EPS >= previous_clock
		if not valid and bad.size() < 5: bad.append(row)
		prior = int(row.frame)
		previous_clock = float(row.animation_clock)
	var visible: Dictionary = {}
	for row: Dictionary in render_rows: visible[row.frame] = true
	var metrics: Dictionary = {"frames": unique.keys(), "labels": labels.keys(), "bad": bad, "render_frames": visible.keys(), "signature": signature}
	_check(not rows.is_empty() and bad.is_empty(), "clip metadata / phase seek: " + sheet + "/" + label, metrics, [start, count, "4+4+4" if not phases.is_empty() else "bounded"])
	var expected_count: int = count - windup_pose if not phases.is_empty() else count
	_check(unique.size() == expected_count and visible.size() == expected_count, "every remaining pose sampled after physics AND render callbacks", metrics, expected_count)
	_check(labels.size() == 1, "one label, no mid-action phase resets", labels.keys(), "one continuous clip")
	return metrics
func _hits(index: int = 0) -> Array:
	var hits: Array = []; var hp: float = float(initial_hp[index])
	for row: Dictionary in history:
		if row.targets.size() > index and float(row.targets[index]) != hp:
			var hit: Dictionary = row.duplicate()
			hit["damage"] = hp - float(row.targets[index])
			hits.append(hit)
			hp = float(row.targets[index])
	return hits
func _test_motion_and_seek() -> void:
	await _reset("raw_control_lock", false)
	_check(absf(game.hero.control_lock - 0.2) < EPS, "raw first-frame .2s control lock", game.hero.control_lock, 0.2)
	_input("quick", true)
	await _wait(0.30)
	_check(game.hero.control_lock == 0.0 and game.hero.state == "idle" and game.hero.stamina == 100.0, "locked request never spends or fires later", _snapshot(), "unlocked / idle / 100")
	await _reset("motion")
	await _wait(1.0)
	_clip(history, "hero_v2_motion", 0, 6, [], "idle", rendered)
	history.clear(); rendered.clear()
	_input("right", true)
	await _wait(0.85)
	var run: Array = history.filter(func(r): return r.label == "run")
	_clip(run, "hero_v2_motion", 12, 12, [], "run", rendered.filter(func(r): return r.label == "run"))
	_check(game.hero.velocity.x > 6.6 and game.hero.facing == 1, "parsed run accelerates real body", _snapshot(), "vx~6.7 / facing right")
	_input("right", false); await _wait(0.20)
	history.clear(); rendered.clear()
	_input("jump", true)
	await _wait(1.05)
	var jump: Array = history.filter(func(r): return r.frame >= 6 and r.frame <= 11 and r.sheet == "hero_v2_motion")
	var poses: Dictionary = {}
	for row: Dictionary in jump: poses[row.frame] = true
	_check(poses.size() == 6 and game.hero.is_on_floor(), "parsed jump uses all six airborne poses and lands", {"poses": poses.keys(), "floor": game.hero.is_on_floor()}, "6..11 / grounded")
	await _reset("isolated_external_seek")
	game.hero.set_physics_process(false)
	game.hero.play_animation("seek_fixture", 12, 12, 40.0, false, "hero_v2_blade_a")
	for index in [0, 5, 11]:
		game.hero.call("seek_animation_pose", index)
		var before: Dictionary = _snapshot()
		_check(before.frame == 12 + index and before.index == index and absf(before.animation_clock - index / 40.0) < EPS, "seek synchronizes local-index metadata", before, [12 + index, index, index / 40.0])
		await _wait(0.20)
		_check([game.hero.sprite.frame, game.hero.animation_frame, game.hero.animation_clock] == [before.frame, before.index, before.animation_clock], "render-only callbacks cannot advance seek", _snapshot(), before)
func _test_combat() -> void:
	await _reset("input_combo_and_damage")
	var front = _target(11.8); var second = _target(12.0); var behind = _target(8.0)
	await _tap("light")
	await _tap("light") # Genuine second edge buffers the next cut, not another begin_attack call.
	var h = game.hero
	var first_total: float = h.ATTACK_WINDUP[0] + h.ATTACK_ACTIVE[0] + h.ATTACK_RECOVERY[0]
	await _wait(first_total + 0.03 - h.action_time)
	await _tap("light")
	await _wait(h.ATTACK_WINDUP[1] + h.ATTACK_ACTIVE[1] + h.ATTACK_RECOVERY[1] + h.ATTACK_WINDUP[2] + h.ATTACK_ACTIVE[2] + h.ATTACK_RECOVERY[2] + 0.05)
	for index in range(3):
		var phases: Array = [h.ATTACK_WINDUP[index], h.ATTACK_ACTIVE[index], h.ATTACK_RECOVERY[index]]
		var key: String = "attack_%d" % index
		profiles[key] = _clip(_rows("attack", index), "hero_v2_blade_a" if index < 2 else "hero_v2_blade_b", 12 if index == 1 else 0, 12, phases, key, _rows("attack", index, rendered))
	var hits: Array = _hits()
	_check(hits.size() == 3 and _hits(1).size() == 3, "one damage per target per active cut", [hits, _hits(1)], "3 / 3")
	for hit: Dictionary in hits:
		var index: int = clampi(int(hit.combo), 0, 2)
		_check(index == int(hit.combo) and hit.state == "attack" and hit.t >= h.ATTACK_WINDUP[index] and hit.t < h.ATTACK_WINDUP[index] + dt + EPS and hit.damage == h.ATTACK_DAMAGE[index], "zero pre-damage / first active tick / authored damage", hit, h.ATTACK_DAMAGE[index])
	_check(h.attack_commits == 3 and h.state == "idle" and front.health == second.health and behind.health == 130.0, "combo counted once, front-only, no fourth cut", _snapshot(), "3 commits / idle / rear untouched")
	traces[section] = history.duplicate()
	await _reset("held_light")
	_input("light", true)
	await _wait(1.2)
	_check(game.hero.attack_commits == 1 and game.hero.state == "idle", "held J does not synthesize combo presses", _snapshot(), "1 commit / idle")
	await _reset("charged_heavy")
	front = _target(11.8)
	_input("heavy", true); await _wait(0.50)
	_check(game.hero.state == "charge" and front.health == 130.0 and game.hero.attack_commits == 0, "charge has zero pre-damage", _snapshot(), "charge / 130 / 0")
	var held_pose: int = game.hero.animation_frame
	_input("heavy", false); await _wait(dt)
	h = game.hero; var charge: float = h.charge
	_check(h.state == "heavy" and absf(h.stamina - 74.0) < EPS, "release commits heavy cost once", _snapshot(), "heavy / 74 stamina")
	_check(h._heavy_release_pose == held_pose and h.animation_frame >= held_pose, "release continues the held pose without rewinding anticipation", _snapshot(), held_pose)
	var constants: Dictionary = h.get_script().get_script_constant_map()
	var phases: Array = [constants.get("HEAVY_WINDUP", 0.16), constants.get("HEAVY_ACTIVE", 0.24), constants.get("HEAVY_RECOVERY", 0.38)]
	await _wait(float(phases[0]) + float(phases[1]) + float(phases[2]) + 0.04)
	profiles.heavy = _clip(_rows("heavy"), "hero_v2_blade_b", 12, 12, phases, "heavy", _rows("heavy", -1, rendered), held_pose)
	hits = _hits()
	_check(hits.size() == 1 and absf(130.0 - front.health - (48.0 + charge * 36.0)) < EPS and h.attack_commits == 1, "heavy damage once, from committed charge", hits, 48.0 + charge * 36.0)
	_check(hits.size() == 1 and hits[0].t >= phases[0] and hits[0].t < phases[0] + dt + EPS and hits[0].frame in [16, 17, 18, 19], "heavy has zero windup damage and active-only contact", hits, "first active tick / poses 16..19")
func _test_roll(control: String) -> void:
	var quick: bool = control in ["quick", "middle", "trigger"]
	var duration: float = 0.30 if quick else 0.48; var iframe: float = 0.22 if quick else 0.38
	var cost: float = 14.0 if quick else 20.0; var state: String = "quick_roll" if quick else "roll"
	await _reset("roll_" + control)
	var x: float = game.hero.global_position.x
	await _tap(control)
	_check(game.hero.state == state and game.hero.stamina == 100.0 - cost, "parsed roll state and one exact cost", _snapshot(), [state, 100.0 - cost])
	await _wait(duration + 0.05)
	var rows: Array = _rows(state)
	var metrics: Dictionary = _clip(rows, "hero_v2_defense", 0, 12, [], "", _rows(state, -1, rendered))
	if rows.is_empty(): return
	var end: Dictionary = {}; var expiry: Dictionary = {}; var speeds: Dictionary = {}
	var tapered: bool = true
	for row: Dictionary in history:
		if row.clock > rows[0].clock and row.state != state and end.is_empty(): end = row
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		if row.i <= EPS and expiry.is_empty(): expiry = row
		speeds[snappedf(absf(row.vx), 0.001)] = true
		if index > 0: tapered = tapered and absf(row.vx) <= absf(rows[index - 1].vx) + EPS
	var elapsed: float = float(end.get("clock", -100.0)) - float(rows[0].clock) + float(rows[0].t)
	var distance: float = float(end.get("x", x)) - x
	var immune_age: float = float(expiry.get("clock", -100.0)) - float(rows[0].clock) + iframe - float(rows[0].i)
	_check(absf(elapsed - duration) <= dt + EPS, "roll total duration within one physics quantum", elapsed, duration)
	_check(absf(immune_age - iframe) <= dt + EPS and not expiry.is_empty(), "iframe expires independently before vulnerable tail", {"age": immune_age, "tail": expiry}, iframe)
	_check(distance >= (2.8 if quick else 4.7) and distance <= (4.3 if quick else 5.5), "actual collision-body displacement", distance, "2.8..4.3" if quick else "4.7..5.5")
	if quick: _check(tapered and speeds.size() >= 6 and absf(rows[0].vx) >= 14.4 and absf(rows[0].vx) <= 15.1 and absf(rows.back().vx) >= 6.8 and absf(rows.back().vx) <= 8.0, "quick speed smoothly tapers ~15 to ~7", {"speeds": speeds.keys(), "monotonic": tapered}, ">=6 distinct descending speeds")
	metrics.merge({"duration": elapsed, "distance": distance, "iframe": immune_age}); profiles[control] = metrics
	await _reset("tail_" + control); await _tap(control)
	await _wait(iframe + 0.025 - game.hero.action_time)
	_check(game.hero.state == state and game.hero.invulnerable == 0.0 and game.hurt_player(17.0, game.hero.global_position.x + 1, 0), "unprotected roll tail accepts real melee", _snapshot(), "17 HP damage while tail still rolling")
	_check(game.hero.health == 83.0, "tail damage applied once", game.hero.health, 83.0)
func _test_buffers_and_denials() -> void:
	for control: String in ["normal", "quick", "middle", "trigger"]:
		await _reset("unaffordable_" + control)
		var cost: float = 20.0 if control == "normal" else 14.0
		game.hero.stamina = cost - 0.1
		await _tap(control)
		_check(game.hero.state == "idle" and game.hero.stamina == cost - 0.1, "unaffordable request spends nothing", _snapshot(), cost - 0.1)
		await _wait(0.20)
		game.hero.stamina = cost
		await _wait(0.20)
		_check(game.hero.state == "idle" and game.hero.stamina == cost, "expired request cannot revive when stamina returns", _snapshot(), "idle / no spend")
		await _tap(control)
		_check(game.hero.stamina == 0.0 and game.hero.state == ("roll" if control == "normal" else "quick_roll"), "exact-cost boundary is accepted", _snapshot(), "0 stamina / correct roll")
	await _reset("expired_attack_quick_buffer")
	await _tap("light")
	await _tap("quick") # Processed before .05s; .16 TTL ends strictly before .22 cancel permission.
	await _wait(0.25 - game.hero.action_time)
	_check(_rows("quick_roll").is_empty() and game.hero.stamina == 93.0, "early quick TTL expires, no unauthorised cost/cancel", _snapshot(), "attack / no quick / stamina 93")
	await _reset("deferred_cancel_and_light_clear")
	_target(11.8)
	await _tap("light")
	await _wait(0.12 - game.hero.action_time)
	await _tap("light")
	await _tap("quick")
	_check(game.hero.state == "attack" and game.hero.stamina == 93.0, "deferred quick waits without pre-spending", _snapshot(), "attack / 93")
	await _wait(0.65)
	var quick_rows: Array = _rows("quick_roll")
	var attack_rows: Array = _rows("attack", 0)
	var age: float = -1.0 if quick_rows.is_empty() or attack_rows.is_empty() else quick_rows[0].clock - attack_rows[0].clock + attack_rows[0].t
	_check(age >= 0.22 - EPS and age <= 0.22 + 2.0 * dt + EPS, "buffered attack cancel begins only after .22s", {"age": age, "first": quick_rows.front() if not quick_rows.is_empty() else {}}, ".22.. .22+2 physics quanta")
	_check(not quick_rows.is_empty() and quick_rows[0].stamina == 79.0 and game.hero.attack_commits == 1 and _hits().size() == 1 and not game.hero.combo_queued, "one deferred cost / no stale light or damage after cancel", _snapshot(), "79 at start / one hit / no queued combo")
	# Bracket .16 against observed eligibility; account for render barriers batching two physics ticks.
	for margin: float in [-0.1 * dt, 0.9 * maxf(dt, 1.0 / render_hz)]:
		await _reset("quick_TTL_boundary_%s" % margin); await _tap("light")
		await _wait(maxf(0.0, age - 0.16 - margin - dt - game.hero.action_time))
		var processed_at: float = game.hero.action_time + dt
		await _tap("quick"); await _wait(maxf(0.0, age + 2.0 * dt - game.hero.action_time))
		var lifetime: float = age - processed_at
		var eligible: bool = lifetime <= 0.16 + EPS and lifetime >= 0.0
		var rolled: Array = _rows("quick_roll")
		_check(eligible == (margin < 0.0), "TTL fixture straddles .16s, not a vacuous probe", {"required_lifetime": lifetime, "eligible_age": age}, margin < 0.0)
		_check(not rolled.is_empty() if eligible else rolled.is_empty(), "quick buffer retains <=.16 and expires >.16", {"lifetime": lifetime, "rows": rolled}, eligible)
		_check((not rolled.is_empty() and rolled[0].stamina == 79.0) if eligible else game.hero.stamina == 93.0, "TTL boundary consumes stamina ONLY on authorised start", _snapshot(), 79.0 if eligible else 93.0)
	await _reset("busy_quick_cooldown")
	_input("quick", true)
	await _wait(dt)
	_input("middle", true); _input("trigger", true)
	await _wait(0.09)
	var rows: Array = _rows("quick_roll")
	_check(not rows.is_empty() and game.hero.stamina == 86.0 and game.hero.action_time >= 0.08, ".08s anti-stack: simultaneous aliases neither restart nor spend twice", _snapshot(), "86 / uninterrupted action_time>=.08")
	var resets: Array = []
	for index in range(1, rows.size()):
		if absf(rows[index].t - rows[index - 1].t - dt) > EPS: resets.append([rows[index - 1], rows[index]])
	_check(resets.is_empty(), "busy quick timer advances every quantum without restart", resets, [])
	await _wait(0.55)
	_check(game.hero.state == "idle" and _rows("quick_roll").size() <= ceili(0.30 / dt) + 1, "held input and expired busy buffer cannot chain another roll", _snapshot(), "one roll only")
	for busy: String in ["hurt", "heal"]:
		await _reset("denied_" + busy)
		if busy == "hurt": game.hurt_player(5.0, game.hero.global_position.x + 1, 0)
		else:
			game.hero.health = 50.0; await _tap("heal")
		await _tap("quick")
		await _wait(0.50)
		_check(_rows("quick_roll").is_empty() and game.hero.stamina == 100.0, "busy " + busy + " never spends unauthorised quick stamina", _snapshot(), "no quick / 100")
	await _reset("death_cancels_pending_actions")
	var target = _target(11.8)
	await _tap("light"); await _tap("light"); await _tap("quick")
	_check(game.hurt_player(1000.0, game.hero.global_position.x + 1, 0), "lethal pre-active contact accepted", _snapshot(), true)
	await _wait(1.1)
	_check(game.hero.dead and game.death_count == 1 and target.health == 130.0 and game.hero.attack_commits == 0 and _rows("quick_roll").is_empty(), "death cancels damage, buffered combo and quick request", _snapshot(), "dead / 1 death / zero commits / target untouched")
func _parry(label: String) -> void:
	await _reset(label); game.hero.stamina = 60.0
	_input("guard", true); await _wait(dt)
	var accepted: bool = game.hurt_player(20.0, game.hero.global_position.x + 1, 0)
	_check(not accepted and game.hero.health == 100.0 and game.hero.stamina == 73.0 and game.hero.parries == 1, "fresh Q parry: zero HP cost, exactly +13 stamina", _snapshot(), "100 HP / 73 stamina / 1 parry")
	_check(game.hero.state == "parry" and absf(game.hero.parry_invulnerable - 1.0) < EPS and game.hero.invulnerable + EPS >= game.hero.parry_invulnerable, "successful call grants exactly separate 1.0s protection", _snapshot(), "parry / p=1 / i>=p")
func _test_defense() -> void:
	for instant: float in [0.17, 0.17001]:
		await _reset("isolated_guard_window_%s" % instant); game.hero.stamina = 60.0
		_input("guard", true); await _wait(dt)
		game.hero.set_physics_process(false); fixtures.back()["manual_guard_timer_callback"] = true
		game.hero.call("_physics_process", instant - game.hero._guard_time)
		var prior: Dictionary = _snapshot(); var accepted: bool = game.hurt_player(20.0, game.hero.global_position.x + 1, 0)
		var fresh: bool = instant <= 0.17
		_check(not accepted and game.hero.state == ("parry" if fresh else "block") and game.hero.parries == (1 if fresh else 0) and game.hero.stamina == (73.0 if fresh else 35.0), "exact .17 guard-startup boundary / no mature reward", {"before": prior, "after": _snapshot()}, "parry at .17, ordinary block after .17")
	await _parry("parry_pose_and_recoil")
	await _wait(0.27)
	_clip(_rows("parry"), "hero_v2_defense", 18, 6, [], "", _rows("parry", -1, rendered))
	_check(_rows("parry").size() * dt >= 0.24 - dt - EPS and _rows("parry").size() * dt <= 0.24 + dt + EPS, "parry recoil persists ~.24s, not overwritten next process", _rows("parry").size() * dt, 0.24)
	var before: Dictionary = _snapshot()
	game.hurt_player(20.0, game.hero.global_position.x + 1, 0)
	_check(game.hero.parries == 1 and game.hero.stamina == before.stamina and game.hero.parry_invulnerable == before.p, "immune contact grants no reward, block cost or renewed second", _snapshot(), before)
	await _parry("parry_attack_cancel")
	_input("guard", false)
	await _wait(0.13)
	await _tap("light")
	_check(game.hero.state == "attack" and game.hero.parry_invulnerable > 0.80 and game.hero.parry_invulnerable < 0.89, "J cancels parry after ~.12s without resetting protection", _snapshot(), "attack / original timer continues")
	await _reset("mature_block_hold_continuity")
	game.hero.stamina = 80.0; _input("guard", true); await _wait(0.19 + dt)
	var guard_time: float = game.hero._guard_time; game.hurt_player(20.0, game.hero.global_position.x + 1, 0)
	_check(game.hero.state == "block" and game.hero.health == 100.0 and game.hero.stamina == 55.0 and game.hero.parries == 0 and game.hero.parry_invulnerable == 0.0, "mature actual block costs 25, never gives parry reward", _snapshot(), "block / 100 / 55 / 0 parries / p=0")
	await _wait(0.18)
	_clip(_rows("block"), "hero_v2_defense", 12, 6, [], "", _rows("block", -1, rendered))
	_check(absf(_rows("block").size() * dt - 0.16) <= dt + EPS and game.hero.guarding and game.hero._guard_time >= guard_time, "~.16s block retains held guard startup history", _snapshot(), "guard held / no fresh .17s startup")
	game.hurt_player(20.0, game.hero.global_position.x + 1, 0)
	_check(game.hero.parries == 0 and game.hero.stamina == 30.0 and game.hero.parry_invulnerable == 0.0, "held Q recoil cannot turn second block into parry", _snapshot(), "30 / 0 parries / p=0")
	await _reset("real_sentinel_parry")
	var enemy = _target(11.6, "sentinel", false)
	enemy.start_attack(); await _wait(float(enemy._stages[0].duration) - 0.10)
	_input("guard", true)
	await _wait(0.18)
	_check(game.hero.health == 100.0 and game.hero.parries == 1 and enemy.attack_events_count == 1 and enemy.attack_name.is_empty(), "real front-facing sentinel contact parries and cancels second cut", {"hero": _snapshot(), "events": enemy.attack_events_count, "attack": enemy.attack_name}, "1 parry / zero HP loss / one canceled strike")
	for control: String in ["normal", "quick"]:
		await _parry("protected_tail_" + control)
		_input("guard", false)
		await _wait(0.27)
		var original: float = game.hero.parry_invulnerable
		await _tap(control)
		_check(game.hero.invulnerable + EPS >= game.hero.parry_invulnerable and game.hero.parry_invulnerable <= original, "roll max-keeps existing parry protection", _snapshot(), "i>=remaining p / p not renewed")
		var first: Array = _rows("roll" if control == "normal" else "quick_roll")
		_check(not first.is_empty() and absf(first[0].i - maxf(original - dt, 0.38 if control == "normal" else 0.22)) <= dt + EPS, "roll neither shortens nor extends the existing protection deadline", first.front() if not first.is_empty() else {}, original - dt)
		await _wait((0.405 if control == "normal" else 0.245) - game.hero.action_time)
		_check(game.hero.state == ("roll" if control == "normal" else "quick_roll") and not game.hurt_player(17.0, game.hero.global_position.x + 1, 0) and game.hero.health == 100.0, "same vulnerable tail is protected ONLY by surviving parry timer", _snapshot(), "rolling / p>0 / no HP loss")
func _test_parry_boundaries() -> void:
	for kind: String in ["melee", "bolt"]:
		await _parry("isolated_exact_timer_" + kind)
		_input("guard", false)
		game.hero.set_physics_process(false); game.hero.set_process(false); game.set_physics_process(false)
		fixtures.back()["manual_timer_and_CCD_callbacks"] = true
		# Explicit pure boundary fixture: real Player callbacks, no SceneTree ticks or mock timer.
		game.hero.call("_physics_process", 0.999)
		_check(absf(game.hero.parry_invulnerable - 0.001) < EPS and game.hero.invulnerable + EPS >= 0.001, ".999s still protected, guard released before damage", _snapshot(), "p=.001 / i>=.001")
		var accepted: bool = game.hurt_player(17.0, game.hero.global_position.x + 1, 0) if kind == "melee" else _boundary_bolt()
		_check(not accepted and game.hero.health == 100.0 and game.hero.parries == 1, "immune at .999: " + kind, _snapshot(), "100 HP / no re-parry")
		game.hero.call("_physics_process", 0.001 + EPS)
		_check(game.hero.parry_invulnerable == 0.0 and game.hero.invulnerable == 0.0 and not game.hero.guarding, "protection expires after exactly 1.0, no guard refresh", _snapshot(), "p=0 / i=0 / guard off")
		accepted = game.hurt_player(17.0, game.hero.global_position.x + 1, 0) if kind == "melee" else _boundary_bolt()
		_check(accepted and game.hero.health == 83.0, "real damage accepted after 1.0: " + kind, _snapshot(), "83 HP")
	await _parry("real_physics_one_second_expiry")
	_input("guard", false)
	var origin: float = physical_time
	await _wait(1.08)
	var zero: Array = history.filter(func(r): return r.clock > origin and r.p == 0.0)
	var bad: Array = history.filter(func(r): return r.clock > origin and r.i + EPS < r.p)
	var age: float = -1.0 if zero.is_empty() else zero[0].clock - origin
	_check(absf(age - 1.0) <= dt + EPS and bad.is_empty(), "natural 1-second parry expiry within ONE 60/120Hz quantum", {"age": age, "quantum": dt, "i_below_p": bad}, 1.0)
	profiles.parry_expiry = age
	_check(game.hurt_player(17.0, game.hero.global_position.x + 1, 0) and game.hero.health == 83.0, "natural expiry permits damage, not a new held-guard parry", _snapshot(), "83 HP")
func _boundary_bolt() -> bool:
	var before: float = game.hero.health
	game.spawn_projectile(game.hero.global_position + Vector3(4, 0.92, 0), Vector3.LEFT, "bolt", 17.0, 8.0 / dt, game.enemies[0], Color.GOLD)
	game.call("_update_projectiles", dt) # Real swept CCD with hero timer frozen ONLY in boundary fixture.
	_check(game.projectiles.is_empty(), "boundary bolt actually contacts and is consumed", game.projectiles.size(), 0)
	return game.hero.health < before
func _test_pause() -> void:
	for protected: bool in [true, false]:
		if protected:
			await _parry("pause_remaining_timer")
			_input("guard", false)
			await _wait(0.13)
		else: await _reset("pause_zero_timer")
		await _tap("light")
		await _tap("escape")
		_check(paused and game.state == "paused", "parsed Escape pauses real MainScene", game.state, "paused")
		var before: Dictionary = _snapshot(); var elapsed: float = game.elapsed
		_input("quick", true); await _wait(1.10)
		_check(_frozen_values(_snapshot()) == _frozen_values(before), "pause freezes exact zero/remaining timer, action and pose", {"before": before, "after": _snapshot()}, "same values; wall/physics fence clocks may advance")
		_check(game.elapsed == elapsed and (game.hero.parry_invulnerable > 0.0 if protected else game.hero.parry_invulnerable == 0.0), "paused time is legitimate, not an expired/restarted timer", _snapshot(), "elapsed unchanged / original remaining or zero")
		_input("quick", false)
		if protected:
			await _tap("escape")
			_check(not paused and game.state == "playing", "parsed Escape resumes", game.state, "playing")
			if paused: game.resume_game() # Failure recorded; cleanup only, never a substitute pass.
			await _wait(2.0 * dt)
			_check(game.hero.parry_invulnerable < before.p and game.hero.parry_invulnerable > 0.0, "resume continues remaining protection instead of renewing 1s", _snapshot(), "0<p<paused remaining")
func _frozen_values(row: Dictionary) -> Array:
	return [row.state, row.t, row.frame, row.index, row.animation_clock, row.finished, row.label, row.hp,
		row.stamina, row.i, row.p, row.guard_time, row.x, row.y, row.vx, row.commits]