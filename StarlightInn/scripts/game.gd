extends Node3D

const Actor = preload("res://scripts/actor.gd")
const Navigation = preload("res://scripts/navigation.gd")
const Catalog = preload("res://scripts/npc_catalog.gd")
const Dialogue = preload("res://scripts/dialogue.gd")
const InnUI = preload("res://scripts/inn_ui.gd")
const Atmosphere = preload("res://scripts/atmosphere.gd")
const SPEED := 224.0
const INTERACT_DISTANCE := 130.0
const SPAWN := Vector2(799, 817)
const CAMERA_NORMAL := Vector3(0.0, 0.70710678, 0.70710678)

var player: Actor
var npcs: Dictionary = {}
var navigation := Navigation.new()
var dialogue := Dialogue.new()
var ui: InnUI
var camera: Camera3D
var floor_image: Sprite3D
var route := PackedVector2Array()
var pending_npc: String = ""
var nearest_npc: String = ""
var destination: Vector2 = Vector2.ZERO
var elapsed: float = 0.0
var footsteps: int = 0
var _walked: float = 0.0
var _qa_path: String = ""
var _qa_accumulator: float = 0.0
var _last_input: String = "none"


func _ready() -> void:
	_setup_input()
	_setup_world()
	add_child(dialogue)
	var hud := CanvasLayer.new()
	hud.layer = 10
	add_child(hud)
	ui = InnUI.new()
	hud.add_child(ui)
	ui.setup(dialogue)
	ui.choice_selected.connect(_choose)
	ui.message_submitted.connect(_send_message)
	ui.close_requested.connect(_close_dialogue)
	ui.guide_requested.connect(_show_guide)
	ui.journal_requested.connect(_show_journal)
	ui.fullscreen_requested.connect(_toggle_fullscreen)
	dialogue.changed.connect(_on_dialogue_changed)
	dialogue.closed.connect(_on_dialogue_closed)
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--qa-state="):
			_qa_path = argument.trim_prefix("--qa-state=")
	_write_qa_state()
	print("STARLIGHT_INN_READY: four residents, offline capability interfaces, no network services")


func _setup_input() -> void:
	var bindings: Dictionary = {
		"inn_left": [KEY_A, KEY_LEFT], "inn_right": [KEY_D, KEY_RIGHT],
		"inn_up": [KEY_W, KEY_UP], "inn_down": [KEY_S, KEY_DOWN],
		"inn_sprint": [KEY_SHIFT]
	}
	for action: String in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for code: int in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = code
			if not InputMap.action_has_event(action, event):
				InputMap.action_add_event(action, event)


func _setup_world() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 10.0
	camera.position = Vector3(0, 14, 14)
	camera.rotation_degrees.x = -45.0
	camera.near = 0.1
	camera.far = 80.0
	add_child(camera)
	camera.current = true
	floor_image = Sprite3D.new()
	floor_image.name = "PaintedDioramaBackdrop"
	floor_image.texture = load("res://assets/world/inn_hall.png")
	floor_image.pixel_size = 16.0 / 1024.0
	floor_image.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	floor_image.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	floor_image.shaded = false
	floor_image.position = -CAMERA_NORMAL * 8.0
	floor_image.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_image)
	var positions: Array[Vector2] = []
	for id: String in Catalog.IDS:
		var npc: Dictionary = Catalog.get_npc(id)
		var actor := Actor.new()
		add_child(actor)
		actor.setup(id)
		actor.set_ground_position(npc.position)
		npcs[id] = actor
		positions.append(npc.position)
	navigation.setup(positions)
	player = Actor.new()
	add_child(player)
	player.setup("traveler", true)
	player.set_ground_position(SPAWN)
	# Independent foreground plane: the generated ivy subtly frames the entry.
	_add_prop("ivy", Vector2(1550, 771), 0.0052)
	var effects_layer := CanvasLayer.new()
	effects_layer.layer = 1
	add_child(effects_layer)
	effects_layer.add_child(Atmosphere.new())
	var post_layer := CanvasLayer.new()
	post_layer.layer = 2
	add_child(post_layer)
	var grade := ColorRect.new()
	grade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/cinematic.gdshader")
	grade.material = material
	post_layer.add_child(grade)


func _add_prop(id: String, point: Vector2, pixel_size: float) -> void:
	var prop := Sprite3D.new()
	prop.texture = load("res://assets/sprites/%s.png" % id)
	prop.pixel_size = pixel_size
	prop.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	prop.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	prop.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	prop.position = Actor.ground_to_world(point)
	prop.shaded = false
	prop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(prop)


func _physics_process(delta: float) -> void:
	if player == null or ui == null:
		return
	elapsed += delta
	var before: Vector2 = player.ground_position
	if not dialogue.is_open and not ui.modal.visible:
		var axis: Vector2 = Input.get_vector("inn_left", "inn_right", "inn_up", "inn_down")
		if axis.length_squared() > 0.01:
			route.clear()
			pending_npc = ""
			_last_input = "keyboard_move"
			var speed: float = SPEED * (1.5 if Input.is_action_pressed("inn_sprint") else 1.0)
			player.set_ground_position(navigation.slide_move(before, axis * speed * delta))
		elif not route.is_empty():
			_follow_route(delta)
	var motion: Vector2 = player.ground_position - before
	player.set_motion(motion)
	_walked += motion.length()
	if _walked >= 35.0:
		footsteps += 1
		_walked = fmod(_walked, 35.0)
	_update_nearest()
	if not pending_npc.is_empty() and player.ground_position.distance_to(npcs[pending_npc].ground_position) <= INTERACT_DISTANCE - 10.0:
		var reached: String = pending_npc
		pending_npc = ""
		_open_dialogue(reached)
	var tag_positions: Dictionary = {}
	for id: String in npcs:
		tag_positions[id] = camera.unproject_position(npcs[id].position)
	ui.update_world_tags(tag_positions, nearest_npc)
	_qa_accumulator += delta
	if _qa_accumulator >= 0.25:
		_qa_accumulator = 0.0
		_write_qa_state()


func _follow_route(delta: float) -> void:
	var budget: float = SPEED * delta
	# Sub-pixel roundoff is not a collision; leave the path for the next frame.
	while budget > 0.01 and not route.is_empty():
		var point: Vector2 = route[0]
		var distance: float = player.ground_position.distance_to(point)
		if distance < 2.0:
			route.remove_at(0)
			continue
		var wanted: Vector2 = (point - player.ground_position).normalized() * minf(distance, budget)
		var result: Vector2 = navigation.slide_move(player.ground_position, wanted)
		if result.distance_to(player.ground_position) < 0.01:
			route.clear()
			pending_npc = ""
			break
		player.set_ground_position(result)
		budget -= wanted.length()
		if player.ground_position.distance_to(point) < 2.0:
			route.remove_at(0)


func _update_nearest() -> void:
	nearest_npc = ""
	var nearest_distance: float = INTERACT_DISTANCE
	for id: String in npcs:
		var actor: Actor = npcs[id]
		var distance: float = actor.ground_position.distance_to(player.ground_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_npc = id
	for id: String in npcs:
		npcs[id].set_highlight(id == nearest_npc and not dialogue.is_open)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if dialogue.is_open or ui.modal.visible:
			return
		_last_input = "mouse_click"
		var npc: String = npc_at_screen(event.position)
		if not npc.is_empty():
			walk_to_npc(npc)
		else:
			walk_to(event.position)
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or ui == null:
		return
	# Escape is global; typing letters never triggers movement or shortcuts.
	if event.keycode == KEY_ESCAPE:
		if ui.modal.visible:
			ui.hide_modal()
		elif dialogue.is_open:
			_close_dialogue()
		else:
			route.clear()
			pending_npc = ""
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F11:
		_toggle_fullscreen()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F1:
		_show_guide()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_J and not ui.input_line.has_focus():
		_show_journal()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F12 and not _qa_path.is_empty():
		_capture_qa_frame.call_deferred()
		get_viewport().set_input_as_handled()
	elif ui.modal.visible:
		# A focused control beneath the modal must not receive Enter/Space/Tab.
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if ui.modal.visible or ui.input_line.has_focus():
		return
	if dialogue.is_open:
		if event.keycode >= KEY_1 and event.keycode <= KEY_4:
			var index: int = event.keycode - KEY_1
			if index < dialogue.choices.size():
				_choose(dialogue.choices[index].id)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_E:
			ui.reveal_all()
			get_viewport().set_input_as_handled()
	elif event.keycode == KEY_E or event.keycode == KEY_ENTER:
		if not nearest_npc.is_empty():
			_open_dialogue(nearest_npc)
		get_viewport().set_input_as_handled()


func walk_to(point: Vector2) -> void:
	if dialogue.is_open or ui.modal.visible:
		return
	pending_npc = ""
	destination = point
	route = navigation.find_path(player.ground_position, point)


func walk_to_npc(id: String) -> void:
	if not npcs.has(id) or dialogue.is_open or ui.modal.visible:
		return
	if player.ground_position.distance_to(npcs[id].ground_position) <= INTERACT_DISTANCE:
		_open_dialogue(id)
		return
	var target: Vector2 = npcs[id].ground_position + Vector2(0, 70)
	walk_to(target)
	if not route.is_empty():
		pending_npc = id


func npc_at_screen(point: Vector2) -> String:
	# Reverse draw order selects the closest sprite if hit rectangles overlap.
	var selected: String = ""
	var foremost: float = -INF
	for id: String in npcs:
		var actor: Actor = npcs[id]
		var feet: Vector2 = camera.unproject_position(actor.position)
		var sprite_hit := Rect2(feet + Vector2(-70, -153), Vector2(140, 175))
		var label_hit := Rect2(feet + Vector2(-110, -210), Vector2(220, 61))
		if (sprite_hit.has_point(point) or label_hit.has_point(point)) and feet.y > foremost:
			selected = id
			foremost = feet.y
	return selected


func _open_dialogue(id: String) -> void:
	route.clear()
	pending_npc = ""
	player.set_motion(Vector2.ZERO)
	dialogue.open_for(id)
	_write_qa_state()


func _close_dialogue() -> void:
	dialogue.close()


func _choose(id: String) -> void:
	if ui.modal.visible:
		return
	_last_input = "dialogue_choice"
	dialogue.choose(id)


func _send_message(message: String) -> void:
	if ui.modal.visible:
		return
	_last_input = "text_submit"
	dialogue.send_message(message)
	if dialogue.busy:
		ui.input_line.text = ""
		ui.input_counter.text = "0 / 280"


func _on_dialogue_changed() -> void:
	_write_qa_state()


func _on_dialogue_closed() -> void:
	player.set_motion(Vector2.ZERO)
	if get_viewport().gui_get_focus_owner() != null:
		get_viewport().gui_get_focus_owner().release_focus()
	_write_qa_state()


func _show_guide() -> void:
	route.clear()
	pending_npc = ""
	if ui.modal.visible and ui.modal_kind == "guide":
		ui.hide_modal()
	else:
		ui.show_guide()


func _show_journal() -> void:
	route.clear()
	pending_npc = ""
	if ui.modal.visible and ui.modal_kind == "journal":
		ui.hide_modal()
	else:
		ui.show_journal()


func _toggle_fullscreen() -> void:
	var mode: int = DisplayServer.window_get_mode()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if mode == DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		route.clear()
		pending_npc = ""
		for action: String in ["inn_left", "inn_right", "inn_up", "inn_down", "inn_sprint"]:
			Input.action_release(action)


func _capture_qa_frame() -> void:
	# Opt-in only: capture the real rendered viewport, never a synthetic canvas.
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _qa_path.get_basename() + ".png"
	var result: Error = image.save_png(path)
	if result == OK:
		print("QA_RENDERED_FRAME: ", path)
	else:
		push_error("Could not save QA rendered frame: %s (error %d)" % [path, result])


func _write_qa_state() -> void:
	if _qa_path.is_empty() or player == null:
		return
	var state: Dictionary = {
		"mode": "demo", "network_enabled": false,
		"position": {"x": player.ground_position.x, "y": player.ground_position.y},
		"facing": player.facing, "moving": player.moving, "footsteps": footsteps,
		"nearest_npc": nearest_npc, "pending_npc": pending_npc,
		"dialogue_open": dialogue.is_open, "npc_id": dialogue.npc_id,
		"page": dialogue.page, "busy": dialogue.busy, "text": dialogue.text,
		"choices": dialogue.choices, "visited": dialogue.visited.keys(),
		"last_request": dialogue.last_request, "last_response": dialogue.last_response,
		"input_text": ui.input_line.text, "input_focused": ui.input_line.has_focus(),
		"modal": ui.modal_kind, "last_input": _last_input,
		"dialogue_bounds": {"x": ui.dialog_panel.position.x, "y": ui.dialog_panel.position.y,
			"width": ui.dialog_panel.size.x, "height": ui.dialog_panel.size.y}
	}
	var file := FileAccess.open(_qa_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(state, "  "))