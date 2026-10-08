extends SceneTree
## Integration regression: real main scene, real Controls and the local provider.
## No screenshots/GPU claims: headless only checks decoded artwork and UI geometry.

const GameScript = preload("res://scripts/game.gd")
const ActorScript = preload("res://scripts/actor.gd")
const Catalog = preload("res://scripts/npc_catalog.gd")
const DemoProvider = preload("res://scripts/demo_provider.gd")
const VIEW_SIZE := Vector2i(1600, 1000)
const DT: float = 1.0 / 60.0
const MAX_ROUTE_STEPS: int = 360
const ACTIONS: Array[String] = ["inn_left", "inn_right", "inn_up", "inn_down", "inn_sprint"]
const IDS: Array[String] = ["mira", "oren", "eve", "finn"]
const MENUS: Dictionary = {
	"mira": ["guide", "residents", "legend", "goodbye"],
	"oren": ["list_running", "list_all", "shutdown_preview", "chat"],
	"eve": ["inspect", "tags", "explain_resource", "goodbye"],
	"finn": ["story", "explain_api", "free_chat", "goodbye"],
}
const SECTIONS: Array[String] = [
	"artwork", "scene_and_camera", "keyboard_and_animation", "collisions",
	"mouse_navigation", "proximity_and_close", "menus_and_routing", "text_and_busy",
	"shutdown_preview", "modals", "session_isolation",
]

var game: GameScript
var passed: int = 0
var failed: int = 0
var requests: Array[Dictionary] = []
var responses: Array[Dictionary] = []
var clicked_choices: Array[String] = []
var completed: Array[String] = []
var held_keys: Array[int] = []
var route_samples: int = 0
var layout_rects: int = 0
var route_runs: int = 0
var section: String = "startup"
var section_passed: int = 0
var section_failed: int = 0
var finishing: bool = false
var mouse_position := Vector2.ZERO


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# A single watchdog covers aborted coroutines; there is no sleep/poll loop.
	create_timer(90.0).timeout.connect(_deadline)
	_release_actions()
	_test_artwork()
	root.size = VIEW_SIZE
	var scene: PackedScene = load("res://main.tscn") as PackedScene
	if not _check(scene != null, "main scene loads", "PackedScene", scene):
		await _finish()
		return
	game = scene.instantiate() as GameScript
	if not _check(game != null, "main scene instantiates actual game", "GameScript", game):
		await _finish()
		return
	root.add_child(game)
	await _settle()
	game.set_physics_process(false)
	# Advance the actual animation implementation with the same deterministic dt.
	game.player.set_process(false)
	for id: String in IDS:
		game.npcs[id].set_process(false)
	game.dialogue.port.request_dispatched.connect(_on_request)
	game.dialogue.port.response_ready.connect(_on_response)
	game.ui.choice_selected.connect(_on_choice)
	_step(0.0)
	_test_scene_and_camera()
	_test_keyboard_and_animation()
	_test_collisions()
	await _test_mouse_navigation()
	await _test_proximity_and_close()
	await _test_menus_and_routing()
	await _test_text_and_busy()
	await _test_shutdown_preview()
	await _test_modals()
	await _test_session_isolation()
	_equal(completed, SECTIONS, "all integration sections reached their end")
	_check(passed + failed >= 50, "at least 50 assertions executed", ">= 50", passed + failed)
	await _finish()


func _test_artwork() -> void:
	_begin("artwork")
	var expected: Array[String] = [
		"res://assets/world/inn_hall.png", "res://assets/ui/dialogue_frame.png",
	]
	for id: String in IDS:
		expected.append("res://assets/ui/portrait_%s.png" % id)
		for index: int in range(2):
			expected.append("res://assets/sprites/%s_%d.png" % [id, index])
	for direction: String in ["down", "left", "right", "up"]:
		for index: int in range(4):
			expected.append("res://assets/sprites/traveler_%s_%d.png" % [direction, index])
	for prop: String in ["books", "candles", "crest", "crystal", "ivy", "lantern", "noticeboard", "sparkle"]:
		expected.append("res://assets/sprites/%s.png" % prop)
	var actual: Array[String] = []
	for directory: String in ["res://assets/world", "res://assets/ui", "res://assets/sprites"]:
		for filename: String in DirAccess.get_files_at(directory):
			if filename.ends_with(".png"):
				actual.append(directory.path_join(filename))
	expected.sort()
	actual.sort()
	_equal(actual.size(), 38, "exactly 38 production PNGs, excluding source sheets")
	_equal(actual, expected, "production PNG manifest")
	for path: String in expected:
		var texture: Texture2D = load(path) as Texture2D
		if _check(texture != null, "load texture " + path, "Texture2D", texture):
			_check(texture.get_width() > 0 and texture.get_height() > 0,
				"texture dimensions " + path, "positive width/height", texture.get_size())
		# Decode the source PNG on the CPU, not ViewportTexture.get_image() in a dummy renderer.
		var image := Image.new()
		var decode_error: Error = image.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
		if _check(decode_error == OK and not image.is_empty(), "decode PNG " + path,
			"OK and nonempty CPU image", {"error": decode_error, "size": image.get_size()}):
			_check(image.get_used_rect().has_area(), "PNG contains opaque artwork " + path,
				"nonempty used rect", image.get_used_rect())
	print("GAME_RENDERING: SKIPPED -- headless has no rendered-frame/screenshot validation; 38 CPU PNGs and UI rects only")
	_end()


func _test_scene_and_camera() -> void:
	_begin("scene_and_camera")
	_equal(DisplayServer.get_name(), "headless", "headless execution, no GUI")
	_equal(root.size, VIEW_SIZE, "root window size")
	_near_vector(root.get_visible_rect().size, Vector2(VIEW_SIZE), 0.01, "logical viewport size")
	_equal(game.npcs.size(), 4, "four actual NPC nodes")
	_equal(game.dialogue.port.provider.get_script(), DemoProvider, "real local provider, not a mock")
	_near(game.dialogue.port.latency_seconds, 0.35, 0.0001, "production port latency is unchanged")
	_equal(game.ui.model, game.dialogue, "UI uses actual dialogue instance")
	_equal(game.dialogue.port.get_parent(), game.dialogue, "port is in actual scene tree")
	_equal(game.player.actor_id, "traveler", "actual traveler")
	_equal(game.player.is_player, true, "traveler player flag")
	_equal(game.player.frames.size(), 4, "four player directions")
	for direction: String in ["down", "left", "right", "up"]:
		var strip: Array = game.player.frames.get(direction, [])
		_equal(strip.size(), 4, "four traveler frames: " + direction)
		for index: int in range(strip.size()):
			_equal(strip[index].resource_path, "res://assets/sprites/traveler_%s_%d.png" % [direction, index],
				"player frame binding %s/%d" % [direction, index])
	for id: String in IDS:
		var actor: ActorScript = game.npcs[id]
		var record: Dictionary = Catalog.get_npc(id)
		_equal(actor.actor_id, id, id + " actor identity")
		_equal(actor.ground_position, record["position"], id + " ground placement")
		_equal(actor.frames.get("idle", []).size(), 2, id + " two idle frames")
		actor.idle_clock = 0.0
		actor._process(0.0)
		_equal(actor.sprite.texture.resource_path, "res://assets/sprites/%s_0.png" % id, id + " idle first texture")
		actor._process(4.2)
		_equal(actor.sprite.texture.resource_path, "res://assets/sprites/%s_1.png" % id, id + " idle second texture")
		actor._process(0.7)
		_equal(actor.current_frame, 0, id + " idle animation wraps")
		_near_vector(game.camera.unproject_position(actor.global_position), actor.ground_position, 0.1,
			id + " camera screen == ground coordinate")
		_near_vector(game.ui.world_labels[id].get_global_rect().position,
			actor.ground_position + Vector2(-110, -210), 0.1, id + " label follows camera feet")
	_equal(game.floor_image.texture.resource_path, "res://assets/world/inn_hall.png", "actual floor artwork binding")
	for point: Vector2 in [GameScript.SPAWN, Vector2(400, 650), Vector2(1200, 670), Vector2(825, 440)]:
		var screen: Vector2 = game.camera.unproject_position(ActorScript.ground_to_world(point))
		_near_vector(screen, point, 0.1, "screen_ground forward " + str(point))
		var intersection: Variant = Plane(Vector3.UP, 0.0).intersects_ray(
			game.camera.project_ray_origin(screen), game.camera.project_ray_normal(screen))
		if _check(intersection is Vector3, "screen_ground ray intersects floor", "Vector3", intersection):
			var world: Vector3 = intersection
			var recovered := Vector2(world.x * 100.0 + 800.0, world.z * 100.0 * 0.70710678 + 500.0)
			_near_vector(recovered, point, 0.1, "screen_ground inverse " + str(point))
	_assert_layout("initial HUD and hidden panels")
	_end()


func _test_keyboard_and_animation() -> void:
	_begin("keyboard_and_animation")
	var cases: Array[Dictionary] = [
		{"key": KEY_A, "action": "inn_left", "axis": Vector2.LEFT, "facing": "left"},
		{"key": KEY_D, "action": "inn_right", "axis": Vector2.RIGHT, "facing": "right"},
		{"key": KEY_W, "action": "inn_up", "axis": Vector2.UP, "facing": "up"},
		{"key": KEY_S, "action": "inn_down", "axis": Vector2.DOWN, "facing": "down"},
		{"key": KEY_LEFT, "action": "inn_left", "axis": Vector2.LEFT, "facing": "left"},
		{"key": KEY_RIGHT, "action": "inn_right", "axis": Vector2.RIGHT, "facing": "right"},
		{"key": KEY_UP, "action": "inn_up", "axis": Vector2.UP, "facing": "up"},
		{"key": KEY_DOWN, "action": "inn_down", "axis": Vector2.DOWN, "facing": "down"},
	]
	for row: Dictionary in cases:
		_fixture(Vector2(800, 750))
		var code: int = row["key"]
		var label: String = OS.get_keycode_string(code)
		_check(InputMap.action_has_event(row["action"], _key_event(code, true)), label + " real binding",
			row["action"], InputMap.action_get_events(row["action"]))
		var before: Vector2 = game.player.ground_position
		# parse_input_event also updates Input's key/action state, unlike Viewport.push_input.
		_physical_key(code, true)
		_equal(Input.is_action_pressed(row["action"]), true, label + " physical event activates action")
		for index: int in range(6):
			_step(DT)
			_assert_walkable(label + " step %d" % index)
		_near_vector(game.player.ground_position, before + row["axis"] * GameScript.SPEED * DT * 6.0,
			0.02, label + " actual movement")
		_equal(game.player.facing, row["facing"], label + " facing")
		_equal(game.player.moving, true, label + " walking animation enabled")
		_physical_key(code, false)
		_step(0.0)
		_equal(game.player.moving, false, label + " key release stops walking")
		_equal(game.player.current_frame, 1, label + " standing uses frame 1")
	for row: Dictionary in cases.slice(0, 4):
		_fixture(Vector2(800, 750))
		var seen: Dictionary = {}
		_physical_key(row["key"], true)
		for index: int in range(27):
			_step(DT)
			_assert_walkable("animated %s step %d" % [row["facing"], index])
			seen[game.player.current_frame] = true
			_equal(game.player.sprite.texture.resource_path,
				"res://assets/sprites/traveler_%s_%d.png" % [row["facing"], game.player.current_frame],
				"actual animation texture %s step %d" % [row["facing"], index])
		var frame_ids: Array = seen.keys()
		frame_ids.sort()
		_equal(frame_ids, [0, 1, 2, 3], "all walking frames visited: " + str(row["facing"]))
		_physical_key(row["key"], false)
	for sprint: bool in [false, true]:
		_fixture(Vector2(800, 750))
		_physical_key(KEY_D, true)
		_physical_key(KEY_W, true)
		if sprint:
			_physical_key(KEY_SHIFT, true)
		_equal(Input.is_action_pressed("inn_sprint"), sprint, "Shift binding state")
		_near(Input.get_vector("inn_left", "inn_right", "inn_up", "inn_down").length(), 1.0, 0.0001,
			"diagonal input is normalized")
		var before: Vector2 = game.player.ground_position
		var speed: float = GameScript.SPEED * (1.5 if sprint else 1.0)
		for index: int in range(20):
			var previous: Vector2 = game.player.ground_position
			_step(DT)
			_assert_walkable("diagonal sprint=%s step=%d" % [sprint, index])
			_near(game.player.ground_position.distance_to(previous), speed * DT, 0.01,
				"diagonal per-step speed sprint=%s step=%d" % [sprint, index])
		_near_vector(game.player.ground_position, before + Vector2(1, -1).normalized() * speed * DT * 20.0,
			0.03, "diagonal displacement sprint=" + str(sprint))
		_release_actions()
	_fixture(Vector2(800, 750))
	Input.action_press("inn_left")
	Input.action_press("inn_right")
	var still: Vector2 = game.player.ground_position
	_step(DT)
	_equal(game.player.ground_position, still, "opposite horizontal actions cancel")
	_release_actions()
	_end()


func _test_collisions() -> void:
	_begin("collisions")
	# These blocked points are the bar, bottom edge and the two side furniture bays.
	var cases: Array[Dictionary] = [
		{"name": "north bar", "start": Vector2(950, 430), "action": "inn_up", "blocked": Vector2(950, 335)},
		{"name": "south scene edge", "start": Vector2(1000, 885), "action": "inn_down", "blocked": Vector2(1000, 980)},
		{"name": "right furniture bay", "start": Vector2(1100, 800), "action": "inn_right", "blocked": Vector2(1370, 800)},
		{"name": "left furniture bay", "start": Vector2(480, 885), "action": "inn_left", "blocked": Vector2(260, 885)},
	]
	for row: Dictionary in cases:
		_fixture(row["start"])
		_equal(game.navigation.is_walkable(row["blocked"]), false, str(row["name"]) + " furniture/outside point blocked")
		Input.action_press(row["action"])
		for index: int in range(100):
			_step(DT)
			_assert_walkable("%s collision step %d" % [row["name"], index])
		var stopped: Vector2 = game.player.ground_position
		for index: int in range(5):
			_step(DT)
			_assert_walkable("%s held at obstacle %d" % [row["name"], index])
		_near_vector(game.player.ground_position, stopped, 0.001, str(row["name"]) + " cannot tunnel through barrier")
		var traveled: float = stopped.distance_to(row["start"])
		_check(traveled > 5.0 and traveled < GameScript.SPEED * DT * 100.0 - 5.0,
			str(row["name"]) + " movement starts then is stopped by collision", "5 < distance < unobstructed - 5", traveled)
		_release_actions()
	for id: String in IDS:
		var npc_position: Vector2 = game.npcs[id].ground_position
		_fixture(npc_position + Vector2(0, 90))
		Input.action_press("inn_up")
		for index: int in range(35):
			_step(DT)
			_assert_walkable(id + " NPC collision step %d" % index)
		var distance: float = game.player.ground_position.distance_to(npc_position)
		_check(distance >= 42.0 - 0.01 and distance < 48.0, id + " NPC radius plus player radius",
			"42 <= separation < 48 pixels", distance)
		_equal(game.dialogue.is_open, false, id + " walking into NPC alone does not open dialogue")
		_release_actions()
	_end()


func _test_mouse_navigation() -> void:
	_begin("mouse_navigation")
	_fixture(GameScript.SPAWN)
	await _settle()
	var target := Vector2(1050, 750)
	_click_at(target)
	_check(not game.route.is_empty(), "ground click creates actual route", "nonempty route", game.route)
	_near_vector(game.destination, target, 0.01, "click coordinates reach game destination")
	var trip: Dictionary = _walk_route("open-floor click")
	_near_vector(game.player.ground_position, target, 2.0, "ground click arrives")
	_equal(game.dialogue.is_open, false, "ground arrival does not talk")
	_check(trip["steps"] > 0, "ground click actually walked", "> 0 steps", trip)
	_fixture(Vector2(417, 905))
	await _settle()
	# The gap between Oren's sprite (ends at 527) and Finn's label (starts at 575).
	target = Vector2(417, 560)
	_equal(game.npc_at_screen(target), "", "detour target really is ground, not a name tag")
	_click_at(target)
	_check(game.route.size() >= 2, "blocked straight line produces a detour", ">= 2 waypoints", game.route)
	trip = _walk_route("ground detour around Finn")
	_near_vector(game.player.ground_position, target, 2.0, "detour arrives at exact clicked ground")
	_check(trip["max_x_deviation"] >= 42.0, "detour visibly skirts NPC collision circle", ">= 42 px lateral displacement", trip)
	_fixture(GameScript.SPAWN)
	await _settle()
	target = Vector2(1400, 820)
	_click_at(target)
	_check(not game.route.is_empty(), "clicking furniture snaps to a reachable route", "nonempty route", game.route)
	_walk_route("furniture click")
	_check(game.player.ground_position.distance_to(target) > 42.0, "furniture click never enters furniture",
		"> 42 px from blocked click", game.player.ground_position)
	for id: String in IDS:
		for hit: String in ["sprite", "label"]:
			_fixture(GameScript.SPAWN)
			await _settle()
			var feet: Vector2 = game.camera.unproject_position(game.npcs[id].global_position)
			var point: Vector2 = feet + Vector2(0, -70 if hit == "sprite" else -180)
			_click_at(point)
			_equal(game.pending_npc, id, "%s %s click selects pending NPC" % [id, hit])
			_check(not game.route.is_empty(), id + " click routes before talking", "nonempty route", game.route)
			_equal(game.dialogue.is_open, false, id + " far mouse selection cannot talk immediately")
			trip = _walk_route(id + " " + hit + " approach")
			await _settle()
			_equal(game.dialogue.is_open, true, id + " arrival opens actual dialogue")
			_equal(game.dialogue.npc_id, id, id + " arrival opens correct NPC")
			_check(game.player.ground_position.distance_to(game.npcs[id].ground_position) <= 120.01,
				id + " auto-dialogue requires real proximity", "distance <= 120", game.player.ground_position)
			_equal(game.route.size(), 0, id + " conversation clears remaining route")
			_equal(game.pending_npc, "", id + " conversation clears pending NPC")
			_equal(game.player.moving, false, id + " stops on conversation open")
			_equal(game.ui.portrait.texture.resource_path, "res://assets/ui/portrait_%s.png" % id, id + " actual portrait")
			_assert_layout(id + " mouse arrival " + hit)
	_fixture(GameScript.SPAWN)
	await _settle()
	_click_at(game.camera.unproject_position(game.npcs["mira"].global_position) + Vector2(0, -70))
	_step(DT)
	Input.action_press("inn_left")
	_step(DT)
	_equal(game.route.size(), 0, "manual input cancels mouse route")
	_equal(game.pending_npc, "", "manual input cancels auto-talk target")
	_equal(game.dialogue.is_open, false, "canceled destination does not talk")
	_release_actions()
	_end()


func _test_proximity_and_close() -> void:
	_begin("proximity_and_close")
	_fixture(GameScript.SPAWN)
	await _settle()
	for code: int in [KEY_E, KEY_ENTER]:
		_tap(code)
		_equal(game.dialogue.is_open, false, "far interaction key does not open: " + OS.get_keycode_string(code))
	for id: String in IDS:
		await _open_near(id)
		_equal(game.nearest_npc, id, id + " nearest interaction candidate")
		_equal(game.ui.prompt.visible, false, id + " world prompt hidden during dialogue")
		var before: Vector2 = game.player.ground_position
		Input.action_press("inn_right")
		for index: int in range(12):
			_step(DT)
		_equal(game.player.ground_position, before, id + " dialogue pauses movement")
		_release_actions()
		_click_at(Vector2(1040, 820))
		_equal(game.route.size(), 0, id + " dialogue blocks world click-through")
		_equal(game.pending_npc, "", id + " dialogue blocks NPC click-through")
		await _click_control(_find_button(game.ui.dialog_panel, "×"), id + " close button")
		_assert_closed(id + " close button")
	_fixture(game.npcs["mira"].ground_position + Vector2(0, 131))
	await _settle()
	_tap(KEY_E)
	_equal(game.dialogue.is_open, false, "E outside 130-pixel proximity is rejected")
	_fixture(game.npcs["mira"].ground_position + Vector2(0, 129))
	await _settle()
	_tap(KEY_E)
	_equal(game.dialogue.npc_id, "mira", "E inside proximity opens Mira")
	_tap(KEY_ESCAPE)
	_assert_closed("Escape from proximity dialogue")
	_fixture(game.npcs["eve"].ground_position + Vector2(0, 95))
	await _settle()
	_tap(KEY_ENTER)
	_equal(game.dialogue.npc_id, "eve", "Enter also interacts when near")
	_tap(KEY_ESCAPE)
	_assert_closed("Enter interaction cleanup")
	_end()


func _test_menus_and_routing() -> void:
	_begin("menus_and_routing")
	# Exercise every root choice twice: actual Button click and the 1..4 key route.
	for mode: String in ["mouse", "number"]:
		for id: String in IDS:
			for index: int in range(4):
				await _open_near(id)
				_equal(_choice_ids(), MENUS[id], id + " complete four-option menu")
				_equal(game.ui.choice_box.get_child_count(), 4, id + " four actual option Buttons")
				_equal(game.ui.npc_name.text, "%s  ·  %s" % [Catalog.get_npc(id)["name"], Catalog.get_npc(id)["title"]], id + " UI identity")
				_equal(game.ui.input_line.visible, id == "finn", id + " input visibility")
				for option_index: int in range(4):
					var button: Button = game.ui.choice_box.get_child(option_index) as Button
					_equal(button.text, "%02d   %s" % [option_index + 1, game.dialogue.choices[option_index]["label"]],
						id + " visible button label %d" % option_index)
				var choice: String = MENUS[id][index]
				var before_requests: int = requests.size()
				var label: String = "%s/%s/%s" % [mode, id, choice]
				if mode == "mouse":
					await _click_choice(choice)
				else:
					_tap(KEY_1 + index)
					await _settle()
				var action: String = ""
				var capability: String = ""
				if id == "oren" and choice in ["list_running", "list_all"]:
					action = choice
					capability = "azure.vm"
				elif id == "eve" and choice in ["inspect", "tags"]:
					action = choice
					capability = "azure.resource"
				elif id == "finn" and choice in ["story", "explain_api"]:
					action = "story" if choice == "story" else "explain"
					capability = "ai.chat"
				if not action.is_empty():
					_equal(requests.size(), before_requests + 1, label + " dispatch count")
					_assert_request(id, capability, action, label)
					await _await_reply(label)
					_assert_menu_result(id, action, label)
					_equal(_choice_ids(), ["back"], label + " result offers back")
				elif choice == "goodbye":
					_assert_closed(label)
					_equal(requests.size(), before_requests, label + " no capability request")
				else:
					var page: String = "targets" if choice == "shutdown_preview" else ("input" if choice == "free_chat" else choice)
					_equal(game.dialogue.page, page, label + " exact local branch")
					_equal(requests.size(), before_requests, label + " remains local without request")
					_equal(game.ui.body.text, game.dialogue.text, label + " actual body tracks model")
					_check(not game.ui.body.text.is_empty(), label + " branch is not blank", "nonempty body", game.ui.body.text)
					if choice == "free_chat":
						_equal(game.ui.input_line.has_focus(), true, label + " automatically focuses text entry")
				_assert_layout(label)
				if game.dialogue.is_open:
					await _click_choice("back")
					_equal(game.dialogue.page, "root", label + " real back Button returns to menu")
					_equal(game.dialogue.is_open, true, label + " back does not close")
	_equal(game.dialogue.visited.size(), 4, "all four NPCs visited through input")
	_equal(game.ui.progress_text.text, "四位住客，都记得你了  ✓", "actual HUD visit completion")
	_end()


func _test_text_and_busy() -> void:
	_begin("text_and_busy")
	await _open_near("finn")
	_tap(KEY_3)
	await _settle()
	_click_at(game.ui.input_line.get_global_rect().get_center())
	_equal(game.ui.input_line.has_focus(), true, "actual LineEdit receives mouse focus")
	var stationary: Vector2 = game.player.ground_position
	for character: String in ["w", "a", "s", "d", "j"]:
		var code: int = character.to_upper().unicode_at(0)
		_physical_key(code, true, character.unicode_at(0))
		_step(DT)
		_equal(game.player.ground_position, stationary, "focused " + character + " does not move traveler")
		_equal(game.ui.modal.visible, false, "focused " + character + " cannot open journal")
		_physical_key(code, false)
	await _settle()
	_equal(game.ui.input_line.text, "wasdj", "WASD/J characters actually enter LineEdit")
	_equal(game.ui.input_counter.text, "5 / 280", "actual text_changed updates counter")
	_tap(KEY_ESCAPE)
	_assert_closed("Escape still closes focused text input")
	await _open_near("finn")
	await _click_choice("free_chat")
	var before_requests: int = requests.size()
	_tap(KEY_ENTER)
	_equal(requests.size(), before_requests, "blank Return does not dispatch")
	_check("空白" in game.dialogue.text, "blank input feedback reaches UI", "contains 空白", game.ui.body.text)
	await _settle()
	# LineEdit ends its editing session on Return; a real click starts the next one.
	_click_at(game.ui.input_line.get_global_rect().get_center())
	_equal(game.ui.input_line.has_focus(), true, "payload has actual text-entry focus")
	var message: String = "[b]星灯[/b][color=red]你好，旅店[/color]"
	await _type_text(message)
	_equal(game.ui.input_line.text, message, "full Unicode/BBCode payload enters through key events")
	_equal(game.ui.input_counter.text, "%d / 280" % message.length(), "payload counter")
	_tap(KEY_ENTER)
	_equal(requests.size(), before_requests + 1, "LineEdit Return reaches local port.request exactly once")
	_assert_request("finn", "ai.chat", "chat", "free text Return")
	_equal(game.dialogue.last_request.get("arguments", {}), {"message": message}, "port receives exact text")
	_equal(game.dialogue.busy, true, "real asynchronous busy state")
	_equal(game.ui.input_line.text, "", "accepted message clears actual input")
	_equal(game.ui.input_line.editable, false, "busy text control is read-only")
	_equal(game.ui.send_button.disabled, true, "busy send Button disabled")
	await _settle()
	_assert_busy_blocks("free text")
	await _await_reply("free text")
	_equal(_data().get("input"), message, "local response quotes exact input")
	_equal(_data().get("source"), "local_template", "real local template provider")
	_equal(game.ui.body.bbcode_enabled, false, "dialogue RichTextLabel disables BBCode")
	_equal(game.ui.body.get_parsed_text(), game.dialogue.text, "response is displayed literally, not markup")
	_check(message in game.ui.body.get_parsed_text(), "markup remains visible in actual UI", message, game.ui.body.get_parsed_text())
	_equal(game.ui.input_line.editable, true, "reply re-enables text input")
	_equal(game.ui.send_button.disabled, false, "reply re-enables send Button")
	await _click_control(game.ui.history_button, "actual dialogue history Button")
	_equal(game.ui.modal_kind, "journal", "history Button routes to journal")
	_equal(game.ui.modal_body.bbcode_enabled, false, "journal disables BBCode")
	_equal(game.ui.modal_body.get_parsed_text(), game.ui.modal_body.text, "journal history remains plain text")
	_check(message in game.ui.modal_body.get_parsed_text(), "journal contains literal user message", message, game.ui.modal_body.get_parsed_text())
	_assert_layout("journal containing literal markup")
	_tap(KEY_ESCAPE)
	_tap(KEY_ESCAPE)
	_assert_closed("text/history cleanup")
	await _open_near("finn")
	await _click_choice("free_chat")
	await _type_text("星".repeat(281))
	_equal(game.ui.input_line.text.length(), 280, "real LineEdit caps typed input at 280 characters")
	_equal(game.ui.input_counter.text, "280 / 280", "limit counter follows accepted text")
	_tap(KEY_ESCAPE)
	_assert_closed("long unsent text cleanup")
	_end()


func _test_shutdown_preview() -> void:
	_begin("shutdown_preview")
	await _open_near("oren")
	var before: int = requests.size()
	await _click_choice("shutdown_preview")
	_equal(game.dialogue.page, "targets", "shutdown opens target selection")
	_equal(_choice_ids(), ["target_lantern", "target_library", "back"], "only running preview targets offered")
	_equal(requests.size(), before, "opening targets sends no request")
	await _click_choice("target_lantern")
	_equal(game.dialogue.page, "confirm", "selection opens separate confirmation")
	_equal(_choice_ids(), ["confirm_preview", "back"], "confirmation has distinct explicit action")
	_equal(requests.size(), before, "target selection alone sends no request")
	_check("inn-lantern-01" in game.ui.body.text, "confirmation names selected target", "inn-lantern-01", game.ui.body.text)
	_assert_layout("separate shutdown confirmation")
	await _click_choice("back")
	_equal(game.dialogue.page, "root", "cancel returns to root")
	_equal(requests.size(), before, "cancel never requests preview")
	await _click_choice("shutdown_preview")
	await _click_choice("target_library")
	_equal(requests.size(), before, "second selection still requires confirmation")
	await _click_choice("confirm_preview")
	_equal(requests.size(), before + 1, "only explicit confirmation dispatches")
	_assert_request("oren", "azure.vm", "preview_shutdown", "confirmed preview")
	_equal(game.dialogue.last_request.get("arguments", {}), {"target_id": "inn-library-02"}, "confirmation preserves selected VM")
	_assert_busy_blocks("confirmed preview")
	await _await_reply("confirmed preview")
	_equal(_data().get("executed"), false, "preview executed=false")
	_equal(_data().get("state_changed"), false, "preview state_changed=false")
	_equal(_data().get("status"), "running", "preview target still running")
	_equal(game.dialogue.last_response.get("side_effects"), false, "preview has no side effects")
	_check("未执行任何真实操作" in game.ui.body.text, "UI explicitly says no real execution", "未执行任何真实操作", game.ui.body.text)
	await _click_choice("back")
	await _click_choice("list_running")
	await _await_reply("re-query running samples after preview")
	var items: Array = _data().get("items", [])
	_equal(items.size(), 2, "both running samples remain after preview")
	var statuses: Dictionary = {}
	for item: Dictionary in items:
		statuses[item.get("id", "")] = item.get("status")
	_equal(statuses, {"inn-lantern-01": "running", "inn-library-02": "running"}, "fresh actual port query proves samples unchanged")
	_tap(KEY_ESCAPE)
	_assert_closed("preview cleanup")
	_end()


func _test_modals() -> void:
	_begin("modals")
	for kind: String in ["guide", "journal"]:
		var key: int = KEY_F1 if kind == "guide" else KEY_J
		_fixture(GameScript.SPAWN)
		await _settle()
		_click_at(Vector2(1060, 760))
		_check(not game.route.is_empty(), kind + " starts with world route", "nonempty", game.route)
		_step(DT)
		_tap(key)
		await _settle()
		_equal(game.ui.modal.visible, true, kind + " shortcut opens modal")
		_equal(game.ui.modal_kind, kind, kind + " correct modal content")
		_equal(game.route.size(), 0, kind + " opening clears route")
		_equal(game.pending_npc, "", kind + " opening clears pending interaction")
		var before: Vector2 = game.player.ground_position
		Input.action_press("inn_up")
		for index: int in range(20):
			_step(DT)
		_equal(game.player.ground_position, before, kind + " pauses held movement")
		_release_actions()
		for code: int in [KEY_E, KEY_1, KEY_ENTER]:
			_tap(code)
		_equal(game.dialogue.is_open, false, kind + " blocks world interaction keys")
		_click_at(Vector2(1080, 850))
		_click_at(game.camera.unproject_position(game.npcs["mira"].global_position) + Vector2(0, -70))
		_equal(game.route.size(), 0, kind + " blocks ground mouse click-through")
		_equal(game.dialogue.is_open, false, kind + " blocks NPC mouse click-through")
		var underlying: Button = _find_button(game.ui, "J  旅人手记" if kind == "guide" else "F1  旅店指南")
		if underlying != null:
			_click_at(underlying.get_global_rect().get_center())
		_equal(game.ui.modal_kind, kind, kind + " blocks underlying HUD Button")
		_assert_layout(kind + " modal")
		_tap(key)
		_equal(game.ui.modal.visible, false, kind + " same shortcut toggles closed")
		_equal(game.ui.modal_kind, "", kind + " toggle clears modal state")
		await _click_control(_find_button(game.ui, "F1  旅店指南" if kind == "guide" else "J  旅人手记"), kind + " HUD Button")
		_equal(game.ui.modal_kind, kind, kind + " actual HUD Button opens modal")
		await _click_control(_find_button(game.ui.modal, "×"), kind + " modal close Button")
		_equal(game.ui.modal.visible, false, kind + " actual X closes modal")
		_tap(key)
		await _settle()
		await _click_control(_find_button(game.ui.modal, "Esc  ·  返回旅店"), kind + " return Button")
		_equal(game.ui.modal.visible, false, kind + " actual return Button closes modal")
		# A focused underlying Button is the important keyboard click-through case.
		# Acquire it by real Tab navigation, not by invoking its callback directly.
		await _open_near("oren")
		var first_choice: Control = game.ui.choice_box.get_child(0) as Control
		await _focus_by_tab(first_choice, kind + " underlying option")
		var choice_rect: Rect2 = first_choice.get_global_rect()
		var old_page: String = game.dialogue.page
		var old_history: Array = game.dialogue.history.duplicate(true)
		var old_requests: int = requests.size()
		_tap(key)
		await _settle()
		var focused: Control = root.gui_get_focus_owner()
		_check(focused == null or game.ui.modal.is_ancestor_of(focused), kind + " focus must not remain behind modal",
			"none or modal descendant", _focus_description())
		_tap(KEY_1)
		_equal(game.dialogue.page, old_page, kind + " numeric shortcut cannot activate underlying option")
		_tap(KEY_ENTER if kind == "guide" else KEY_SPACE)
		_equal(requests.size(), old_requests, kind + " keyboard accept cannot dispatch behind modal")
		_equal(game.dialogue.page, old_page, kind + " keyboard accept cannot change underlying page")
		_assert_history_unchanged(old_history, kind + " keyboard accept cannot alter underlying history")
		if game.dialogue.busy:
			# Drain a genuinely leaked request, but keep every failing assertion above.
			await _await_reply(kind + " leaked-request cleanup")
		var page_before_mouse: String = game.dialogue.page
		var requests_before_mouse: int = requests.size()
		_click_at(choice_rect.get_center())
		_equal(game.dialogue.page, page_before_mouse, kind + " mouse cannot activate underlying option")
		_equal(requests.size(), requests_before_mouse, kind + " mouse cannot dispatch behind modal")
		_tap(KEY_ESCAPE)
		_equal(game.dialogue.is_open, true, kind + " Escape closes only top modal")
		_equal(game.ui.modal.visible, false, kind + " Escape hides modal")
		_tap(KEY_ESCAPE)
		_assert_closed(kind + " dialogue cleanup")
	_end()


func _test_session_isolation() -> void:
	_begin("session_isolation")
	await _open_near("finn")
	await _click_choice("free_chat")
	var marker: String = "[b]只属于菲恩的未回信[/b]"
	await _type_text(marker)
	_tap(KEY_ENTER)
	var old_id: String = game.dialogue.pending_request_id
	_check(not old_id.is_empty(), "old session has actual pending request", "nonempty request id", old_id)
	var saved_finn: Array = game.dialogue.history.duplicate(true)
	var response_start: int = responses.size()
	_tap(KEY_ESCAPE)
	_assert_closed("close busy Finn")
	await _open_near("eve")
	_equal(game.dialogue.last_request, {}, "NPC switch clears last request")
	_equal(game.dialogue.last_response, {}, "NPC switch clears last response")
	_equal(game.ui.input_line.text, "", "NPC switch clears unsent input")
	await _click_choice("inspect")
	var new_id: String = game.dialogue.pending_request_id
	_check(new_id != old_id and not new_id.is_empty(), "new NPC receives independent request ID", "new nonempty id", [old_id, new_id])
	await _await_reply("Eve after canceled Finn")
	_equal(game.dialogue.npc_id, "eve", "late old session does not replace NPC")
	_equal(game.dialogue.last_response.get("request_id"), new_id, "only current session response is adopted")
	_equal(game.ui.portrait.texture.resource_path, "res://assets/ui/portrait_eve.png", "switched UI portrait stays Eve")
	_equal(game.dialogue.history_by_npc.get("finn"), saved_finn, "old NPC history is preserved, not polluted")
	_check(not marker in game.ui.body.text, "old user text cannot enter new NPC body", "marker absent", game.ui.body.text)
	var delivered: Array[String] = []
	for response: Dictionary in responses.slice(response_start):
		delivered.append(str(response.get("request_id", "")))
	_equal(delivered, [new_id], "canceled old request emits no late response")
	await _open_near("finn")
	_equal(game.dialogue.history, saved_finn, "reopening Finn restores only his history")
	_equal(game.ui.input_line.text, "", "reopening clears editor text")
	_click_at(game.ui.input_line.get_global_rect().get_center())
	await _type_text("同一住客重新打开也不能收到旧回包")
	_tap(KEY_ENTER)
	old_id = game.dialogue.pending_request_id
	response_start = responses.size()
	_tap(KEY_ESCAPE)
	await _open_near("finn")
	var reopening_text: String = game.ui.body.text
	await _drain_latency()
	_equal(responses.size(), response_start, "same-NPC reopen cancels old response")
	_equal(game.dialogue.last_response, {}, "same-NPC reopen has no stale response")
	_equal(game.dialogue.last_request, {}, "same-NPC reopen has no stale request")
	_equal(game.ui.body.text, reopening_text, "same-NPC old reply cannot replace new greeting")
	_equal(game.dialogue.page, "root", "same-NPC reopened session stays at root")
	_tap(KEY_ESCAPE)
	_assert_closed("session cleanup")
	await _settle()
	_assert_layout("final HUD and retained hidden UI")
	_end()


func _assert_menu_result(id: String, action: String, label: String) -> void:
	_equal(game.dialogue.page, "result", label + " result page")
	_equal(game.ui.body.text, game.dialogue.text, label + " response reaches actual body")
	if id == "oren":
		_equal(_data().get("count"), 2 if action == "list_running" else 3, label + " VM count")
	elif id == "eve" and action == "inspect":
		var resource: Dictionary = _data().get("resource", {})
		_equal(resource.get("id"), "inn-lantern-01", label + " resource target")
		_equal(resource.get("status"), "running", label + " resource status")
	elif id == "eve":
		var tags: Dictionary = _data().get("tags", {})
		_equal(tags.get("environment"), "local-demo", label + " resource tags")
	else:
		_equal(_data().get("topic"), "story" if action == "story" else "api", label + " reply topic")
		_check("未调用 AI" in game.ui.body.text, label + " offline disclaimer", "未调用 AI", game.ui.body.text)


func _assert_request(id: String, capability: String, action: String, label: String) -> void:
	_equal(game.dialogue.last_request.get("npc_id"), id, label + " request NPC")
	_equal(game.dialogue.last_request.get("capability"), capability, label + " request capability")
	_equal(game.dialogue.last_request.get("action"), action, label + " request action")
	_equal(game.dialogue.last_request, game.dialogue.port.last_request, label + " actual port envelope")
	_check(not requests.is_empty() and requests.back() == game.dialogue.last_request,
		label + " request_dispatched observed", game.dialogue.last_request, requests.back() if not requests.is_empty() else null)


func _assert_busy_blocks(label: String) -> void:
	_equal(game.dialogue.busy, true, label + " busy before blocked inputs")
	var pending: String = game.dialogue.pending_request_id
	var count: int = requests.size()
	var history: Array = game.dialogue.history.duplicate(true)
	var text: String = game.dialogue.text
	for child: Node in game.ui.choice_box.get_children():
		var button: Button = child as Button
		_equal(button.disabled, true, label + " actual busy choice is disabled")
		_click_at(button.get_global_rect().get_center())
	_tap(KEY_1)
	_tap(KEY_2)
	if game.ui.send_button.is_visible_in_tree():
		_click_at(game.ui.send_button.get_global_rect().get_center())
	_tap(KEY_ENTER)
	_equal(requests.size(), count, label + " busy click/key/Return cannot dispatch twice")
	_equal(game.dialogue.pending_request_id, pending, label + " busy inputs preserve correlation")
	_equal(game.dialogue.page, "waiting", label + " busy inputs cannot navigate away")
	_assert_history_unchanged(history, label + " busy inputs cannot change history")
	_equal(game.dialogue.text, text, label + " busy inputs cannot change response body")


func _assert_history_unchanged(before: Array, label: String) -> void:
	var after: Array = game.dialogue.history
	var differences: Array[Dictionary] = []
	for index: int in range(maxi(before.size(), after.size())):
		var old_entry: Variant = before[index] if index < before.size() else null
		var new_entry: Variant = after[index] if index < after.size() else null
		if old_entry != new_entry:
			differences.append({"index": index, "before": old_entry, "after": new_entry})
	_check(after == before, label, "no history differences", differences)


func _await_reply(label: String) -> void:
	var request_id: String = game.dialogue.pending_request_id
	_check(not request_id.is_empty(), label + " pending before awaiting timer", "nonempty id", request_id)
	var count: int = responses.size()
	await _drain_latency()
	_equal(game.dialogue.busy, false, label + " bounded timer completes real reply")
	_equal(game.dialogue.pending_request_id, "", label + " completion clears pending ID")
	_equal(responses.size(), count + 1, label + " one actual response_ready")
	_equal(game.dialogue.last_response.get("request_id"), request_id, label + " response correlation")
	_equal(game.dialogue.last_response.get("npc_id"), game.dialogue.npc_id, label + " response NPC")
	_equal(game.dialogue.last_response.get("ok"), true, label + " local request succeeded")
	_equal(game.dialogue.last_response.get("mode"), "demo", label + " demo envelope")
	_equal(game.dialogue.last_response.get("side_effects"), false, label + " no side effects")
	_equal(game.ui.body.text, game.dialogue.last_response.get("message"), label + " response connected to UI")
	_assert_layout(label + " response")


func _drain_latency() -> void:
	# Let the port's deferred dispatcher create its timer first; wait once, never poll.
	await process_frame
	await create_timer(game.dialogue.port.latency_seconds + 0.12).timeout
	await _settle()


func _open_near(id: String) -> void:
	_fixture(game.npcs[id].ground_position + Vector2(0, 95))
	await _settle()
	_tap(KEY_E)
	await _settle()
	_equal(game.dialogue.is_open, true, id + " near E opens actual dialogue")
	_equal(game.dialogue.npc_id, id, id + " near E chooses correct NPC")


func _fixture(point: Vector2) -> void:
	# Only position/time are fixtures. All opens, closes, choices and text use input.
	_release_actions()
	if game.ui.modal.visible:
		_tap(KEY_ESCAPE)
	if game.dialogue.is_open:
		_tap(KEY_ESCAPE)
	_tap(KEY_ESCAPE)
	game.player.set_ground_position(point)
	game.player.set_motion(Vector2.ZERO)
	_step(0.0)
	_assert_walkable("fixture " + str(point))


func _walk_route(label: String) -> Dictionary:
	var origin: Vector2 = game.player.ground_position
	var goal: Vector2 = game.route[game.route.size() - 1] if not game.route.is_empty() else origin
	var steps: int = 0
	var max_x_deviation: float = 0.0
	for index: int in range(MAX_ROUTE_STEPS):
		if game.route.is_empty() or game.dialogue.is_open:
			break
		var before: Vector2 = game.player.ground_position
		var next_point: Vector2 = game.route[0]
		var budget: float = GameScript.SPEED * DT
		var wanted: Vector2 = (next_point - before).normalized() * minf(before.distance_to(next_point), budget)
		_step(DT)
		steps = index + 1
		route_samples += 1
		_assert_walkable(label + " step %d" % steps)
		_check(game.player.ground_position.distance_to(before) <= GameScript.SPEED * DT + 0.02,
			label + " bounded per-step motion %d" % steps, "<= SPEED/60", [before, game.player.ground_position])
		max_x_deviation = maxf(max_x_deviation, absf(game.player.ground_position.x - origin.x))
		if game.route.is_empty() and not game.dialogue.is_open and game.player.ground_position.distance_to(goal) > 2.0:
			var residual: float = budget - wanted.length()
			var tiny: Vector2 = (next_point - game.player.ground_position).normalized() * maxf(residual, 0.0)
			print("GAME_ROUTE_ABORT: %s %s" % [label, {
				"before": before, "after": game.player.ground_position, "waypoint": next_point, "goal": goal,
				"input_axis": Input.get_vector("inn_left", "inn_right", "inn_up", "inn_down"),
				"residual_budget_px": "%.12f" % residual,
				"tiny_step_actual_px": "%.12f" % game.navigation.slide_move(game.player.ground_position, tiny).distance_to(game.player.ground_position),
			}])
	var result: Dictionary = {"steps": steps, "position": game.player.ground_position,
		"remaining": game.route.size(), "pending": game.pending_npc, "max_x_deviation": max_x_deviation}
	_check(game.route.is_empty(), label + " completes within 360 samples", "route empty by step 360", result)
	_check(game.dialogue.is_open or game.player.ground_position.distance_to(goal) <= 2.0,
		label + " route finished rather than prematurely discarded", {"goal": goal, "tolerance_px": 2.0}, result)
	route_runs += 1
	print("GAME_ROUTE: %s %s" % [label, result])
	return result


func _assert_walkable(label: String) -> void:
	var point: Vector2 = game.player.ground_position
	var violations: Array[String] = []
	if not Geometry2D.is_point_in_polygon(point, game.navigation.walk_polygon):
		violations.append("center outside floor")
	for index: int in range(8):
		var edge: Vector2 = point + Vector2.from_angle(index * TAU / 8.0) * 15.0
		if not Geometry2D.is_point_in_polygon(edge, game.navigation.walk_polygon):
			violations.append("player-radius sample %d outside floor: %s" % [index, edge])
	for id: String in IDS:
		var distance: float = point.distance_to(game.npcs[id].ground_position)
		if distance < 42.0 - 0.001:
			violations.append("%s separation=%f < 42" % [id, distance])
	if not game.navigation.is_walkable(point):
		violations.append("navigation.is_walkable=false")
	_check(violations.is_empty(), label + " stays in walkable area", "floor + radius margin + NPC separation",
		{"point": point, "violations": violations})


func _step(delta: float) -> void:
	game._physics_process(delta)
	game.player._process(delta)
	for id: String in IDS:
		game.npcs[id]._process(delta)


func _key_event(code: int, pressed: bool, unicode_value: int = 0) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.unicode = unicode_value if pressed else 0
	event.pressed = pressed
	event.echo = false
	return event


func _physical_key(code: int, pressed: bool, unicode_value: int = 0) -> void:
	Input.parse_input_event(_key_event(code, pressed, unicode_value))
	Input.flush_buffered_events()
	if pressed and not held_keys.has(code):
		held_keys.append(code)
	elif not pressed:
		held_keys.erase(code)


func _tap(code: int, unicode_value: int = 0) -> void:
	root.push_input(_key_event(code, true, unicode_value), true)
	root.push_input(_key_event(code, false), true)


func _type_text(value: String) -> void:
	for index: int in range(value.length()):
		var unicode_value: int = value.unicode_at(index)
		var code: int = unicode_value if unicode_value < 128 else 0
		if code >= 97 and code <= 122:
			code -= 32
		_tap(code, unicode_value)
	# LineEdit coalesces text_changed into a deferred notification.
	await _settle()


func _click_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	motion.relative = point - mouse_position
	root.push_input(motion, true)
	mouse_position = point
	for pressed: bool in [true, false]:
		var click := InputEventMouseButton.new()
		click.position = point
		click.global_position = point
		click.button_index = MOUSE_BUTTON_LEFT
		click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		click.pressed = pressed
		root.push_input(click, true)


func _click_choice(id: String) -> bool:
	var ids: Array[String] = _choice_ids()
	var index: int = ids.find(id)
	if not _check(index >= 0 and index < game.ui.choice_box.get_child_count(), "find actual choice " + id, id, ids):
		return false
	var button: Button = game.ui.choice_box.get_child(index) as Button
	if not _check(button != null and not button.disabled, "choice clickable " + id, "enabled Button", button):
		return false
	var count: int = clicked_choices.size()
	await _click_control(button, "choice " + id)
	_equal(clicked_choices.size(), count + 1, id + " actual Button emits one choice signal")
	if clicked_choices.size() > count:
		_equal(clicked_choices.back(), id, id + " Button signal carries correct route ID")
	return clicked_choices.size() == count + 1


func _click_control(control: Control, label: String) -> bool:
	if not _check(is_instance_valid(control), label + " exists", "valid Control", control):
		return false
	var rect: Rect2 = control.get_global_rect()
	if not _check(control.is_visible_in_tree() and rect.has_area(), label + " visible hit rect", "visible nonempty rect", rect):
		return false
	_click_at(rect.get_center())
	await _settle()
	return true


func _find_button(start: Node, text: String) -> Button:
	if start is Button and start.text == text:
		return start as Button
	for child: Node in start.get_children():
		var found: Button = _find_button(child, text)
		if found != null:
			return found
	return null


func _focus_by_tab(target: Control, label: String) -> void:
	_equal(InputMap.event_is_action(_key_event(KEY_TAB, true), "ui_focus_next"), true, "Tab matches built-in focus action")
	# With no focus owner, Tab has no starting Control in this headless viewport.
	# A genuine press focuses the Button; drag outside before release to cancel
	# activation. Opening/closing a modal now intentionally clears this focus.
	var center: Vector2 = game.ui.history_button.get_global_rect().get_center()
	var down := InputEventMouseButton.new()
	down.position = center
	down.global_position = center
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.pressed = true
	root.push_input(down, true)
	var away := Vector2(990, 850)
	var motion := InputEventMouseMotion.new()
	motion.position = away
	motion.global_position = away
	motion.relative = away - center
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	var up := InputEventMouseButton.new()
	up.position = away
	up.global_position = away
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	root.push_input(up, true)
	mouse_position = away
	await _settle()
	_equal(game.ui.modal.visible, false, label + " canceled press does not open a modal")
	_equal(root.gui_get_focus_owner(), game.ui.history_button, label + " click established initial focus")
	for _index: int in range(40):
		if root.gui_get_focus_owner() == target:
			break
		_tap(KEY_TAB)
		await process_frame
	_equal(root.gui_get_focus_owner(), target, label + " acquired by bounded Tab navigation")


func _focus_description() -> String:
	var control: Control = root.gui_get_focus_owner()
	if control == null:
		return "none"
	return "%s (%s)" % [control.get_path(), control.text if control is Button else control.get_class()]


func _choice_ids() -> Array[String]:
	var result: Array[String] = []
	for choice: Dictionary in game.dialogue.choices:
		result.append(str(choice["id"]))
	return result


func _data() -> Dictionary:
	var data: Variant = game.dialogue.last_response.get("data", {})
	return data if data is Dictionary else {}


func _assert_closed(label: String) -> void:
	_equal(game.dialogue.is_open, false, label + " model closed")
	_equal(game.ui.dialog_panel.visible, false, label + " actual panel hidden")
	_equal(game.route.size(), 0, label + " route empty")
	_equal(game.pending_npc, "", label + " pending NPC empty")
	_equal(game.dialogue.pending_request_id, "", label + " pending request canceled")
	_equal(game.dialogue.busy, false, label + " not busy")
	_equal(game.ui.input_line.has_focus(), false, label + " text focus released")
	_equal(root.gui_get_focus_owner(), null, label + " viewport focus released")


func _assert_layout(label: String) -> void:
	var pending: Array[Node] = [game.ui]
	var invalid: Array[String] = []
	var count: int = 0
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is Control:
			var control: Control = node as Control
			var rect: Rect2 = control.get_global_rect()
			count += 1
			# Includes authored hidden controls, but not engine-internal scrollbars.
			if not rect.has_area() or rect.position.x < -0.5 or rect.position.y < -0.5 or rect.end.x > 1600.5 or rect.end.y > 1000.5:
				invalid.append("%s visible=%s rect=%s" % [node.get_path(), control.is_visible_in_tree(), rect])
		for child: Node in node.get_children():
			pending.append(child)
	layout_rects += count
	_check(invalid.is_empty(), "layout " + label, "%d positive UI rects inside 1600x1000" % count, invalid)


func _settle() -> void:
	await process_frame
	await process_frame
	if is_instance_valid(game) and not game.is_physics_processing() and game.ui != null:
		# The real game updates prompt/tags in physics. Refresh them with no movement budget.
		game._physics_process(0.0)


func _release_actions() -> void:
	for code: int in held_keys.duplicate():
		Input.parse_input_event(_key_event(code, false))
	held_keys.clear()
	Input.flush_buffered_events()
	for action: StringName in InputMap.get_actions():
		Input.action_release(action)


func _on_request(request: Dictionary) -> void:
	requests.append(request.duplicate(true))


func _on_response(response: Dictionary) -> void:
	responses.append(response.duplicate(true))


func _on_choice(id: String) -> void:
	clicked_choices.append(id)


func _begin(name: String) -> void:
	section = name
	section_passed = passed
	section_failed = failed
	print("GAME_SECTION_BEGIN: " + name)


func _end() -> void:
	completed.append(section)
	print("GAME_SECTION: %s %d passed, %d failed" % [section, passed - section_passed, failed - section_failed])


func _check(condition: bool, label: String, expected: Variant, actual: Variant) -> bool:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL [%s] %s | expected=%s | actual=%s" % [section, label, str(expected), str(actual)])
	return condition


func _equal(actual: Variant, expected: Variant, label: String) -> bool:
	return _check(actual == expected, label, expected, actual)


func _near(actual: float, expected: float, tolerance: float, label: String) -> bool:
	return _check(absf(actual - expected) <= tolerance, label,
		"%f +/- %f" % [expected, tolerance], actual)


func _near_vector(actual: Vector2, expected: Vector2, tolerance: float, label: String) -> bool:
	return _check(actual.distance_to(expected) <= tolerance, label,
		"%s within %f px" % [expected, tolerance], {"position": actual, "error_px": actual.distance_to(expected)})


func _deadline() -> void:
	if finishing:
		return
	_check(false, "90-second watchdog (aborted coroutine or missing completion)", SECTIONS, completed)
	await _finish()


func _finish() -> void:
	if finishing:
		return
	finishing = true
	_release_actions()
	var pressed: Array[String] = []
	for action: StringName in InputMap.get_actions():
		if Input.is_action_pressed(action):
			pressed.append(str(action))
	_equal(pressed, [], "cleanup releases all Input actions")
	var instance: WeakRef = weakref(game) if is_instance_valid(game) else null
	if is_instance_valid(game):
		game.queue_free()
	game = null
	await process_frame
	await process_frame
	_check(instance == null or instance.get_ref() == null, "scene freed after two frames", "no surviving game", instance.get_ref() if instance != null else null)
	print("GAME_COVERAGE: sections=%d/%d; production_pngs=38; route_runs=%d; route_samples=%d; layout_rects=%d; requests=%d; responses=%d; actual_choice_clicks=%d" % [
		completed.size(), SECTIONS.size(), route_runs, route_samples, layout_rects, requests.size(), responses.size(), clicked_choices.size()])
	print("GAME_TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)