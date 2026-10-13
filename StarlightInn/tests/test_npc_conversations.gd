extends SceneTree
## Actual scene and Controls; controlled clocks, no authentication or cloud calls.

const Game = preload("res://scripts/game.gd")
const Catalog = preload("res://scripts/npc_catalog.gd")
const Scenes = preload("res://scripts/npc_scenes.gd")
const DT := 1.0 / 30.0

var game: Game
var samples: Array = []
var passed: int = 0
var failed: int = 0


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
	game.residents.chatter.connect(func(id: String, text: String) -> void: samples.append([id, text]))
	_test_walk_into_range()
	for scene: Dictionary in Scenes.SCENES:
		_test_scene(scene)
	_test_cooldown()
	_test_interruptions()
	_test_sight_and_distance()
	_test_natural_walking()
	_check(game.dialogue.last_request.is_empty() and game.azure_session.operations.is_empty(), "ambient scenes never dispatch player/provider/cloud operations")
	game.queue_free()
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	print("NPC_CONVERSATION_TESTS: %d passed, %d failed; proximity, pairs/trios/quartets, two-second bubbles, interruption" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _prepare(participants: Array) -> void:
	game.dialogue.close()
	game.ui.hide_modal()
	game.ui.toast.hide()
	game.ui.toast_time = 0.0
	game.route.clear()
	game.pending_npc = ""
	game.residents.cancel_conversation()
	game.residents._scene_cooldowns.clear()
	game.residents._last_scene_id = ""
	game.residents._room_chatter_cooldown = 0.0
	game.residents._scan_time = 0.0
	game.residents.random.seed = 1791
	game.player.set_ground_position(Vector2(600, 910))
	var slots: Array[Vector2] = [Vector2(740, 680), Vector2(855, 680), Vector2(740, 795), Vector2(855, 795)]
	var distant: Array[Vector2] = [Vector2(400, 410), Vector2(1100, 410), Vector2(450, 910), Vector2(1150, 900)]
	for index in range(Catalog.IDS.size()):
		var id: String = Catalog.IDS[index]
		var actor = game.npcs[id]
		actor.set_conversation(false)
		actor.set_ground_position(slots[participants.find(id)] if id in participants else distant[index])
		var state: Dictionary = game.residents.states[id]
		state.route = PackedVector2Array()
		state.wait = 1000.0
		state.speech_timer = 1000.0
		state.greeting_cooldown = 1000.0
		state.was_near = false
		state.stuck = 0.0
	samples.clear()


func _step(delta: float) -> void:
	# Age the previous bubble first, then dispatch the next turn as a real frame does.
	game.ui._process(delta)
	for id: String in Catalog.IDS:
		game.npcs[id]._process(delta)
	game._physics_process(delta)


func _test_walk_into_range() -> void:
	_prepare(["mira", "oren"])
	game.npcs["oren"].set_ground_position(Vector2(1050, 680))
	game.residents.states["oren"].route = PackedVector2Array([Vector2(855, 680)])
	_step(0.1)
	_check(game.residents.conversation_snapshot().id.is_empty(), "distant residents do not begin a conversation")
	for _tick in range(80):
		_step(0.1)
		if not game.residents.conversation_snapshot().id.is_empty():
			break
	_check(game.residents.conversation_snapshot().id == "tea_excuses" and game.residents.moved_distance["oren"] > 0.0,
		"actually walking into speaking distance automatically starts the matching scene")


func _test_scene(scene: Dictionary) -> void:
	_prepare(scene.participants)
	# Exercise both quartet scripts instead of reseeding into the same one twice.
	for candidate: Dictionary in Scenes.SCENES:
		if candidate.participants == scene.participants and candidate.id != scene.id:
			game.residents._scene_cooldowns[candidate.id] = 1000.0
	var positions: Dictionary = {}
	for id: String in scene.participants:
		positions[id] = game.npcs[id].ground_position
	_step(0.01)
	var active: Dictionary = game.residents.conversation_snapshot()
	_check(active.id == scene.id and active.participants == scene.participants, str(scene.id) + " selects the largest nearby group")
	var selected: Dictionary = {}
	for candidate: Dictionary in Scenes.SCENES:
		if candidate.id == active.id:
			selected = candidate
	if selected.is_empty():
		_check(false, str(scene.id) + " actually starts")
		return
	for index in range(selected.lines.size()):
		var line: Array = selected.lines[index]
		var speaker: String = line[0]
		var visible: int = 0
		for id: String in Catalog.IDS:
			if game.ui.speech_bubbles[id].visible:
				visible += 1
		_check(visible == 1 and game.ui.speech_bubbles[speaker].visible and game.ui.speech_labels[speaker].text == line[1],
			str(selected.id) + " bubble belongs to the actual speaker, turn " + str(index))
		_check(is_equal_approx(float(game.ui.chatter_lines[speaker].ttl), Scenes.LINE_SECONDS), str(selected.id) + " gives each line two seconds")
		var stable: bool = true
		for id: String in scene.participants:
			var actor = game.npcs[id]
			stable = stable and not actor.moving and actor.conversing and actor.current_direction == actor.facing and actor.ground_position == positions[id]
		_check(stable, str(selected.id) + " participants stay put in visible directional listening poses")
		var count: int = samples.size()
		_step(1.9)
		_check(samples.size() == count and game.ui.speech_bubbles[speaker].visible, "does not advance or hide a line before two seconds")
		_step(0.1)
	_check(samples == selected.lines, str(selected.id) + " delivers every turn in order without unrelated chatter")
	var released: bool = game.residents.conversation_snapshot().id.is_empty()
	for id: String in scene.participants:
		released = released and not game.npcs[id].conversing
	_check(released, str(selected.id) + " releases all participants after the last line")


func _test_cooldown() -> void:
	_prepare(["mira", "oren"])
	_step(0.01)
	for _line in range(5):
		_step(Scenes.LINE_SECONDS)
	var count: int = samples.size()
	game.residents._room_chatter_cooldown = 0.0
	game.residents._scan_time = 0.0
	_step(0.1)
	_check(samples.size() == count and game.residents.conversation_snapshot().id.is_empty(), "staying close does not restart the same scene every frame")
	_step(4.5)
	var moving: bool = game.npcs["mira"].moving or game.npcs["oren"].moving
	_step(0.5)
	moving = moving or game.npcs["mira"].moving or game.npcs["oren"].moving
	_check(moving, "finished participants resume their normal random walks")


func _test_interruptions() -> void:
	_prepare(["mira", "oren", "eve", "finn"])
	_step(0.01)
	game._open_dialogue("mira")
	var cleared: bool = game.residents.conversation_snapshot().id.is_empty()
	for id: String in Catalog.IDS:
		cleared = cleared and not game.npcs[id].conversing and game.ui.chatter_lines[id].ttl == 0.0
	_check(cleared and game.dialogue.npc_id == "mira", "player dialogue immediately cancels the play and clears all old bubbles")
	var count: int = samples.size()
	_step(3.0)
	_check(samples.size() == count, "ambient lines never intrude into player dialogue")
	game._close_dialogue()
	_step(0.1)
	_check(samples.size() == count, "closing dialogue does not replay a stale theater line")
	_prepare(["mira", "oren", "eve"])
	_step(0.01)
	game._show_guide()
	_check(game.ui.modal.visible and game.residents.conversation_snapshot().id.is_empty(), "guide overlay interrupts the play")
	_prepare(["mira", "oren"])
	_step(0.01)
	game.pending_npc = "oren"
	_step(0.01)
	_check(game.residents.conversation_snapshot().id.is_empty() and not game.npcs["oren"].moving, "clicked participant leaves the play and waits for the player")


func _test_sight_and_distance() -> void:
	_prepare(["mira", "oren"])
	game.npcs["mira"].set_ground_position(Vector2(1180, 520))
	game.npcs["oren"].set_ground_position(Vector2(1300, 610))
	_step(0.01)
	_check(game.residents.conversation_snapshot().id.is_empty(), "nearby residents across the non-floor corner do not call through it")
	_prepare(["mira", "oren"])
	_step(0.01)
	game.npcs["oren"].set_ground_position(Vector2(1150, 680))
	_step(0.01)
	_check(game.residents.conversation_snapshot().id.is_empty() and samples.size() == 1, "a separated participant cancels the scene instead of calling across the hall")


func _test_natural_walking() -> void:
	_prepare([])
	for id: String in Catalog.IDS:
		game.npcs[id].set_ground_position(Catalog.get_npc(id).position)
		game.residents.states[id].wait = 0.0
	var before: int = game.residents.scene_count
	for _tick in range(1800):
		_step(DT)
		if game.residents.scene_count > before:
			break
	_check(game.residents.scene_count > before, "ordinary seeded random walks naturally produce an encounter without gathering or teleporting")
	print("NPC_NATURAL_ENCOUNTER: ", game.residents.conversation_snapshot())


func _check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL NPC_CONVERSATION: " + label)