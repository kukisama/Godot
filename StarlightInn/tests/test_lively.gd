extends SceneTree
## Targeted live-room regression, using the actual scene and controllable clocks.

const Game = preload("res://scripts/game.gd")
const Catalog = preload("res://scripts/npc_catalog.gd")
const Cycle = preload("res://scripts/day_cycle.gd")
const Scenes = preload("res://scripts/npc_scenes.gd")
const DT := 1.0 / 30.0

var game: Game
var failed: int = 0
var passed: int = 0
var samples: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1600, 1000)
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	game.player.set_process(false)
	game.ui.set_process(false)
	game.atmosphere.set_process(false)
	for id: String in Catalog.IDS:
		game.npcs[id].set_process(false)
	game.residents.random.seed = 1791
	game.residents.chatter.connect(func(id: String, text: String) -> void: samples.append({"id": id, "text": text}))
	game.ui.toast_time = 0.0
	game.ui.toast.hide()
	for id: String in Catalog.IDS:
		game.residents.states[id].wait = 0.0
	var collisions: Array[String] = []
	for tick in range(900):
		_step(DT)
		for id: String in Catalog.IDS:
			var point: Vector2 = game.npcs[id].ground_position
			if not game.navigation.is_floor_walkable(point, game.navigation.NPC_RADIUS):
				collisions.append("%s outside floor at tick %d" % [id, tick])
			if point.distance_to(game.player.ground_position) < 42.0 - 0.01:
				collisions.append("%s overlaps player at tick %d" % [id, tick])
			for other: String in Catalog.IDS:
				if other != id and point.distance_to(game.npcs[other].ground_position) < 54.0 - 0.01:
					collisions.append("%s/%s overlap at tick %d" % [id, other, tick])
	_check(collisions.is_empty(), "residents remain on the floor and never overlap players or each other", collisions.slice(0, 5))
	for id: String in Catalog.IDS:
		_check(float(game.residents.moved_distance[id]) > 60.0, id + " really walks rather than only switching texture", game.residents.moved_distance[id])
		_check(game.navigation.npc_positions.has(game.npcs[id].ground_position), id + " obstacle position follows live actor", game.navigation.npc_positions)
	_check(not samples.is_empty() and samples.size() <= ceili(30.0 / Scenes.LINE_SECONDS) + 1, "ambient turns are delivered and limited to one per two seconds", samples)
	_check(game.dialogue.last_request.is_empty() and game.azure_session.operations.is_empty(), "ambient life never dispatches dialogue/cloud operations", game.dialogue.last_request)
	game.player.set_ground_position(Vector2(415, 910))
	var target: Vector2 = game.npcs["mira"].ground_position
	game.walk_to_npc("mira")
	_check(game.pending_npc == "mira", "clicking a distant moving resident selects her", game.pending_npc)
	for _tick in range(300):
		_step(DT)
		if game.dialogue.is_open:
			break
	_check(game.dialogue.is_open and game.dialogue.npc_id == "mira", "moving-NPC approach still opens the right dialogue", game.dialogue.npc_id)
	_check(game.npcs["mira"].ground_position.distance_to(target) < 0.01, "selected resident waits for the traveler", [target, game.npcs["mira"].ground_position])
	_step(0.2)
	_check(not game.npcs["mira"].moving, "conversation resident stays still", game.npcs["mira"].moving)
	game._close_dialogue()
	var cooldown_before: int = game.residents.chatter_count
	game.residents._room_chatter_cooldown = 0.0
	game.residents.states["mira"].greeting_cooldown = 0.0
	game.residents.states["mira"].was_near = false
	_step(DT)
	_check(game.residents.chatter_count == cooldown_before + 1, "approaching produces a local hello", game.residents.chatter_count)
	_check(game.ui.speech_bubbles["mira"].visible, "hello appears in a real follow-character bubble", game.ui.chatter_lines["mira"])
	_step(0.2)
	_check(game.residents.chatter_count == cooldown_before + 1, "standing nearby does not repeat the greeting every frame", game.residents.chatter_count)
	var youth = game.npcs["finn"]
	youth.play_gesture("celebrate", 1.7)
	youth._process(0.4)
	_check(youth.current_direction == "celebrate" and youth.sprite.position.length() > 68.0 * youth.sprite.pixel_size + 0.08,
		"young resident's cheer actually lifts his body", youth.sprite.position)
	game.npcs["oren"].play_gesture("celebrate", 1.7)
	game.npcs["oren"]._process(0.4)
	_check(game.npcs["oren"].sprite.position.length() < 70.0 * game.npcs["oren"].sprite.pixel_size,
		"elder uses grounded stretch instead of young-person jump", game.npcs["oren"].sprite.position)
	var cycle := Cycle.new()
	cycle.advance(Cycle.HOLD_SECONDS + Cycle.FADE_SECONDS * 0.5)
	_check(absf(cycle.blend - 0.5) < 0.001 and cycle.phase_index == 3, "night-to-dawn is a true intermediate fade", cycle.snapshot())
	cycle.advance(Cycle.FADE_SECONDS * 0.5)
	_check(cycle.phase_index == 0 and cycle.blend == 0.0, "fade completes into dawn without a stale overlay", cycle.snapshot())
	var seen: Array[int] = []
	for _phase in range(4):
		seen.append(cycle.phase_index)
		cycle.advance(Cycle.HOLD_SECONDS + Cycle.FADE_SECONDS)
	_check(seen == [0, 1, 2, 3], "automatic cycle reaches every time-of-day artwork", seen)
	game.day_cycle.phase_index = 3
	game.day_cycle.phase_time = 0.0
	game.day_cycle.blend = 0.0
	game.day_cycle.fade_duration = Cycle.FADE_SECONDS
	game.ui.time_button.pressed.emit()
	game._update_daylight(1.6)
	_check(game.next_floor_image.visible and absf(game.next_floor_image.modulate.a - 0.5) < 0.001,
		"HUD switch cross-fades actual painted background nodes", game.next_floor_image.modulate)
	_check(game.atmosphere.daylight > 0.0 and game.player.ambient_tint != Color.WHITE,
		"environment and player lighting follow the same clock", [game.atmosphere.daylight, game.player.ambient_tint])
	game.queue_free()
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	print("LIVELY_TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _step(delta: float) -> void:
	game._physics_process(delta)
	game.player._process(delta)
	game.ui._process(delta)
	for id: String in Catalog.IDS:
		game.npcs[id]._process(delta)


func _check(condition: bool, label: String, actual: Variant) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL LIVELY %s | actual=%s" % [label, actual])