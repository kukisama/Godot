extends Node3D

const Actor = preload("res://scripts/actor.gd")
const Navigation = preload("res://scripts/navigation.gd")
const Catalog = preload("res://scripts/npc_catalog.gd")
const Dialogue = preload("res://scripts/dialogue.gd")
const InnUI = preload("res://scripts/inn_ui.gd")
const Atmosphere = preload("res://scripts/atmosphere.gd")
const Residents = preload("res://scripts/residents.gd")
const DayCycle = preload("res://scripts/day_cycle.gd")
const Soundscape = preload("res://scripts/soundscape.gd")
const AzureSession = preload("res://scripts/azure_session.gd")
const AzurePanel = preload("res://scripts/azure_panel.gd")
const AzureBridgeScript = preload("res://scripts/azure_bridge.gd")
const SPEED := 224.0
const INTERACT_DISTANCE := 130.0
const SPAWN := Vector2(799, 817)
const CAMERA_NORMAL := Vector3(0.0, 0.70710678, 0.70710678)

var player: Actor
var npcs: Dictionary = {}
var navigation := Navigation.new()
var dialogue := Dialogue.new()
var sound := Soundscape.new()
var ui: InnUI
var azure_session := AzureSession.new()
var azure_panel: AzurePanel
var azure_bridge: Node
var camera: Camera3D
var floor_image: Sprite3D
var next_floor_image: Sprite3D
var atmosphere: Atmosphere
var grade_material: ShaderMaterial
var residents := Residents.new()
var day_cycle := DayCycle.new()
var _backgrounds: Array[Texture2D] = []
var _backdrop_phase: int = -1
var _route_retry_delay: float = 0.0
var route := PackedVector2Array()
var pending_npc: String = ""
var nearest_npc: String = ""
var destination: Vector2 = Vector2.ZERO
var elapsed: float = 0.0
var footsteps: int = 0
var _walked: float = 0.0
var _qa_path: String = ""
var _qa_exit_after: float = 0.0
var _quitting: bool = false
var _qa_accumulator: float = 0.0
var _last_input: String = "none"
var _last_response_id: String = ""


func _ready() -> void:
	get_tree().auto_accept_quit = false
	_setup_input()
	_setup_world()
	add_child(dialogue)
	add_child(sound)
	var hud := CanvasLayer.new()
	hud.layer = 10
	add_child(hud)
	ui = InnUI.new()
	hud.add_child(ui)
	ui.setup(dialogue)
	residents.chatter.connect(ui.show_chatter)
	residents.chatter_cleared.connect(ui.clear_chatter)
	ui.time_requested.connect(day_cycle.request_next)
	azure_bridge = AzureBridgeScript.new()
	add_child(azure_bridge)
	add_child(azure_session)
	azure_session.setup(azure_bridge)
	dialogue.setup_azure(azure_session)
	var azure_layer := CanvasLayer.new()
	azure_layer.layer = 20
	add_child(azure_layer)
	azure_panel = AzurePanel.new()
	azure_panel.theme = ui.theme
	azure_layer.add_child(azure_panel)
	azure_panel.setup(azure_session)
	ui.azure_requested.connect(_open_azure)
	azure_session.changed.connect(func() -> void: ui.set_azure_status(azure_session.context_text()))
	ui.set_azure_status(azure_session.context_text())
	ui.choice_selected.connect(_choose)
	ui.message_submitted.connect(_send_message)
	ui.close_requested.connect(_close_dialogue)
	ui.guide_requested.connect(_show_guide)
	ui.journal_requested.connect(_show_journal)
	ui.fullscreen_requested.connect(_toggle_fullscreen)
	ui.audio_requested.connect(_toggle_audio)
	ui.modal_closed.connect(func() -> void: sound.play_cue("dialogue_close", -16.0))
	sound.mute_changed.connect(ui.set_muted)
	dialogue.changed.connect(_on_dialogue_changed)
	dialogue.closed.connect(_on_dialogue_closed)
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--qa-state="):
			_qa_path = argument.trim_prefix("--qa-state=")
		elif argument.begins_with("--qa-exit-after="):
			_qa_exit_after = maxf(0.0, argument.trim_prefix("--qa-exit-after=").to_float())
	_write_qa_state()
	print("STARLIGHT_INN_READY: four lively residents, eight-frame walks, four daylight scenes; offline demo and real Azure bridge retained; no automatic login dialogs")


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
	for phase: String in DayCycle.PHASES:
		_backgrounds.append(load("res://assets/world/inn_hall_%s.png" % phase))
	floor_image = Sprite3D.new()
	floor_image.name = "PaintedDioramaBackdrop"
	floor_image.texture = _backgrounds[day_cycle.phase_index]
	floor_image.pixel_size = 16.0 / float(floor_image.texture.get_width())
	floor_image.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	floor_image.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	floor_image.shaded = false
	floor_image.position = -CAMERA_NORMAL * 8.0
	floor_image.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_image)
	next_floor_image = Sprite3D.new()
	next_floor_image.name = "NextDaylightBackdrop"
	next_floor_image.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	next_floor_image.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	next_floor_image.shaded = false
	next_floor_image.position = -CAMERA_NORMAL * 7.99
	next_floor_image.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(next_floor_image)
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
	residents.setup(npcs)
	player = Actor.new()
	add_child(player)
	player.setup("traveler", true)
	player.set_ground_position(SPAWN)
	# Independent foreground plane: the generated ivy subtly frames the entry.
	_add_prop("ivy", Vector2(1550, 771), 0.0052)
	var effects_layer := CanvasLayer.new()
	effects_layer.layer = 1
	add_child(effects_layer)
	atmosphere = Atmosphere.new()
	effects_layer.add_child(atmosphere)
	var post_layer := CanvasLayer.new()
	post_layer.layer = 2
	add_child(post_layer)
	var grade := ColorRect.new()
	grade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade_material = ShaderMaterial.new()
	grade_material.shader = load("res://shaders/cinematic.gdshader")
	grade.material = grade_material
	post_layer.add_child(grade)
	_update_daylight(0.0)


func _update_daylight(delta: float) -> void:
	day_cycle.advance(delta)
	if _backdrop_phase != day_cycle.phase_index:
		_backdrop_phase = day_cycle.phase_index
		floor_image.texture = _backgrounds[_backdrop_phase]
		floor_image.pixel_size = 16.0 / float(floor_image.texture.get_width())
		next_floor_image.texture = _backgrounds[day_cycle.next_index()]
		next_floor_image.pixel_size = 16.0 / float(next_floor_image.texture.get_width())
	next_floor_image.modulate.a = day_cycle.blend
	next_floor_image.visible = day_cycle.blend > 0.001
	var tint: Color = day_cycle.ambient_tint()
	player.set_ambient_tint(tint)
	for id: String in npcs:
		npcs[id].set_ambient_tint(tint)
	atmosphere.set_daylight(day_cycle.daylight(), tint)
	grade_material.set_shader_parameter("daylight", day_cycle.daylight())
	if ui != null:
		ui.set_time_of_day(day_cycle.label())


func _sync_navigation() -> void:
	var positions: Array[Vector2] = []
	for id: String in Catalog.IDS:
		positions.append(npcs[id].ground_position)
	navigation.set_npc_positions(positions)


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
	_route_retry_delay = maxf(0.0, _route_retry_delay - delta)
	_update_daylight(delta)
	_sync_navigation()
	var before: Vector2 = player.ground_position
	if not dialogue.is_open and not ui.modal.visible and not azure_panel.visible:
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
	player.set_motion(motion, delta)
	var held_id: String = dialogue.npc_id if dialogue.is_open else pending_npc
	var overlay_open: bool = ui.modal.visible or azure_panel.visible
	residents.update(delta, player.ground_position, navigation, held_id, dialogue.is_open or overlay_open or ui.toast.visible, overlay_open)
	_sync_navigation()
	ui.chatter_suppressed = overlay_open
	_walked += motion.length()
	if _walked >= 35.0:
		footsteps += 1
		_walked = fmod(_walked, 35.0)
		sound.footstep()
	sound.update_listener(player.ground_position, dialogue.is_open)
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
	if _qa_exit_after > 0.0 and elapsed >= _qa_exit_after:
		_request_quit()


func _follow_route(delta: float) -> void:
	if _route_retry_delay > 0.0:
		return
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
			# A resident may have crossed the route. Replan against current positions.
			var goal: Vector2 = route[route.size() - 1]
			route = navigation.find_path(player.ground_position, goal)
			_route_retry_delay = 0.3
			if route.is_empty():
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
		if dialogue.is_open or ui.modal.visible or azure_panel.visible:
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
	if azure_panel != null and azure_panel.visible:
		if event.keycode == KEY_ESCAPE:
			azure_panel.hide_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F11:
			_toggle_fullscreen()
			get_viewport().set_input_as_handled()
		# Let top-panel text fields / buttons receive normal keys, never game shortcuts.
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
	elif event.keycode == KEY_M and not ui.input_line.has_focus():
		_toggle_audio()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_T and not ui.input_line.has_focus() and not ui.modal.visible and not dialogue.is_open:
		day_cycle.request_next()
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
	if ui.modal.visible or ui.input_line.has_focus() or azure_panel.visible:
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
	if dialogue.is_open or ui.modal.visible or azure_panel.visible:
		return
	pending_npc = ""
	_route_retry_delay = 0.0
	destination = point
	route = navigation.find_path(player.ground_position, point)


func walk_to_npc(id: String) -> void:
	if not npcs.has(id) or dialogue.is_open or ui.modal.visible or azure_panel.visible:
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
	if azure_panel.visible:
		return
	residents.cancel_conversation()
	route.clear()
	pending_npc = ""
	player.set_motion(Vector2.ZERO)
	npcs[id].play_gesture("wave", 1.4)
	dialogue.open_for(id)
	sound.play_cue("dialogue_open", -12.0)
	if id == "finn":
		sound.play_cue("lute")
	_write_qa_state()


func _close_dialogue() -> void:
	dialogue.close()


func _choose(id: String) -> void:
	if ui.modal.visible or azure_panel.visible:
		return
	_last_input = "dialogue_choice"
	if not dialogue.busy and id != "goodbye":
		for choice: Dictionary in dialogue.choices:
			if choice.id == id:
				sound.play_cue("select", -17.0)
				break
	dialogue.choose(id)


func _send_message(message: String) -> void:
	if ui.modal.visible or azure_panel.visible:
		return
	_last_input = "text_submit"
	dialogue.send_message(message)
	if dialogue.busy:
		sound.play_cue("select", -17.0)
		ui.input_line.text = ""
		ui.input_counter.text = "0 / 280"


func _on_dialogue_changed() -> void:
	var response_id: String = str(dialogue.last_response.get("request_id", ""))
	if not response_id.is_empty() and response_id != _last_response_id:
		_last_response_id = response_id
		sound.play_cue("reply", -14.0)
		if dialogue.last_response.get("ok", false) and npcs.has(dialogue.npc_id):
			npcs[dialogue.npc_id].play_gesture("celebrate", 1.3)
	_write_qa_state()


func _on_dialogue_closed() -> void:
	sound.play_cue("dialogue_close", -14.0)
	player.set_motion(Vector2.ZERO)
	if get_viewport().gui_get_focus_owner() != null:
		get_viewport().gui_get_focus_owner().release_focus()
	_write_qa_state()


func _show_guide() -> void:
	if azure_panel.visible:
		return
	route.clear()
	pending_npc = ""
	if ui.modal.visible and ui.modal_kind == "guide":
		ui.hide_modal()
	else:
		residents.cancel_conversation()
		ui.show_guide()
		sound.play_cue("select", -17.0)


func _show_journal() -> void:
	if azure_panel.visible:
		return
	route.clear()
	pending_npc = ""
	if ui.modal.visible and ui.modal_kind == "journal":
		ui.hide_modal()
	else:
		residents.cancel_conversation()
		ui.show_journal()
		sound.play_cue("select", -17.0)


func _open_azure(id: String = "mira") -> void:
	if id == "finn":
		return
	residents.cancel_conversation()
	route.clear()
	pending_npc = ""
	player.set_motion(Vector2.ZERO)
	azure_panel.open_for(id)


func _toggle_audio() -> void:
	sound.toggle_mute()
	if not sound.muted:
		sound.play_cue("select", -17.0)
	_write_qa_state()


func _toggle_fullscreen() -> void:
	var mode: int = DisplayServer.window_get_mode()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if mode == DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		route.clear()
		pending_npc = ""
		for action: String in ["inn_left", "inn_right", "inn_up", "inn_down", "inn_sprint"]:
			Input.action_release(action)
		if is_instance_valid(sound) and sound.is_inside_tree():
			sound.set_suspended(true)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if is_instance_valid(sound) and sound.is_inside_tree():
			sound.set_suspended(false)


func _request_quit() -> void:
	if _quitting:
		return
	_quitting = true
	_write_qa_state()
	var tree: SceneTree = get_tree()
	# AudioServer consumes stop/remove on its own thread. Free the scene first,
	# then let that thread release the looping playback before engine shutdown.
	tree.create_timer(0.3).timeout.connect(tree.quit)
	queue_free()


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
		"mode": "demo_with_real_azure", "network_enabled": azure_session.connected(),
		"azure_bridge_available": true, "azure_panel": azure_panel.visible,
		"azure_connected": azure_session.connected(), "azure_configured": not str(azure_session.settings.get("client_id", "")).is_empty(),
		"azure_context_generation": azure_session.context.get("generation", 0),
		"azure_config_path": azure_session.config_path,
		"azure_profile_path": azure_session.profile_path,
		"azure_auto_login": azure_session.preferences.get("auto_login", true),
		"azure_has_identity": azure_session.preferences.get("has_identity", false),
		"azure_restoring": azure_session.restoring,
		"azure_busy": azure_session.busy, "azure_operation_count": azure_session.operations.size(),
		"audio_muted": sound.muted, "audio_suspended": sound.suspended,
		"audio_cues": sound.played_counts, "last_audio_cue": sound.last_cue,
		"fireplace_playing": sound.fireplace.playing,
		"position": {"x": player.ground_position.x, "y": player.ground_position.y},
		"facing": player.facing, "moving": player.moving, "footsteps": footsteps,
		"residents": residents.snapshot(), "ambient_chatter_count": residents.chatter_count,
		"ambient_scene": residents.conversation_snapshot(), "ambient_bubbles": ui.chatter_lines,
		"light_cycle": day_cycle.snapshot(),
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