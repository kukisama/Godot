extends Node3D
## Chapter I orchestration. Gameplay is offline; no accounts or service keys.

const Catalog = preload("res://scripts/catalog.gd")
const Player = preload("res://scripts/player.gd")
const Enemy = preload("res://scripts/enemy.gd")
const World = preload("res://scripts/world.gd")
const HUD = preload("res://scripts/hud.gd")
const Audio = preload("res://scripts/audio.gd")
const Effects = preload("res://scripts/effects.gd")
const GOLD := Color(1.0, 0.76, 0.38)

var state := "title"
var hero: CharacterBody3D
var enemies: Array = []
var boss: CharacterBody3D
var world: Node3D
var audio: Node
var effects: Node3D
var hud: CanvasLayer
var camera: Camera3D
var boss_started := false
var boss_defeated := false
var checkpoint_index := 0
var kills := 0
var death_count := 0
var elapsed := 0.0
var volume := 0.75
var defeated_ids: Dictionary = {}
var projectiles: Array[Dictionary] = []
var test_mode := false
var _camera_x := 1.8
var _shake := 0.0
var _death_timer := 0.0
var _hit_stop_until := 0
var _clock := 0.0
var _last_checkpoint := 0
var _has_started := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	test_mode = test_mode or "--qa" in OS.get_cmdline_user_args()
	_install_input()
	if not test_mode:
		var preferences := ConfigFile.new()
		if preferences.load("user://settings.cfg") == OK:
			volume = clampf(float(preferences.get_value("audio", "master", volume)), 0.0, 1.0)
	audio = Audio.new()
	add_child(audio)
	audio.set_volume(volume)
	effects = Effects.new()
	effects.game = self
	effects.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(effects)
	world = World.new()
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	world.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(world)
	world.build()
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.5
	camera.near = 0.1
	camera.far = 180.0
	camera.current = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	_spawn_actors()
	hud = HUD.new()
	add_child(hud)
	hud.setup(self)
	audio.set_music("explore")
	_update_camera(1.0)
	print("HOLLOW_BELL_READY state=title enemy_kinds=%d encounters=%d" % [Catalog.ENEMIES.size(), enemies.size()])

func _install_input() -> void:
	var bindings := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE], "light": [KEY_J], "heavy": [KEY_K],
		"dodge": [KEY_SHIFT, KEY_L], "guard": [KEY_Q], "heal": [KEY_E],
		"quick_roll": [KEY_C],
		"pause_game": [KEY_ESCAPE], "fullscreen": [KEY_F11]
	}
	for action: String in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.22)
		for key: int in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			if not InputMap.action_has_event(action, event):
				InputMap.action_add_event(action, event)
	var mouse_bindings := {"light": MOUSE_BUTTON_LEFT, "heavy": MOUSE_BUTTON_RIGHT, "quick_roll": MOUSE_BUTTON_MIDDLE}
	for action: String in mouse_bindings:
		var event := InputEventMouseButton.new()
		event.button_index = mouse_bindings[action]
		InputMap.action_add_event(action, event)
	var pad_bindings := {
		"move_left": JOY_BUTTON_DPAD_LEFT, "move_right": JOY_BUTTON_DPAD_RIGHT,
		"jump": JOY_BUTTON_A, "light": JOY_BUTTON_X, "heavy": JOY_BUTTON_Y,
		"dodge": JOY_BUTTON_B, "guard": JOY_BUTTON_LEFT_SHOULDER,
		"heal": JOY_BUTTON_RIGHT_SHOULDER, "pause_game": JOY_BUTTON_START
	}
	for action: String in pad_bindings:
		var event := InputEventJoypadButton.new()
		event.button_index = pad_bindings[action]
		InputMap.action_add_event(action, event)
	for action: String in ["move_left", "move_right"]:
		var event := InputEventJoypadMotion.new()
		event.axis = JOY_AXIS_LEFT_X
		event.axis_value = -1.0 if action == "move_left" else 1.0
		InputMap.action_add_event(action, event)
	var quick_trigger := InputEventJoypadMotion.new()
	quick_trigger.axis = JOY_AXIS_TRIGGER_RIGHT
	quick_trigger.axis_value = 1.0
	InputMap.action_add_event("quick_roll", quick_trigger)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause_game") and not event.is_echo():
		if state == "playing":
			pause_game()
		elif state == "paused":
			resume_game()
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and state == "playing" and not test_mode:
		pause_game()

func _process(delta: float) -> void:
	if _hit_stop_until > 0 and Time.get_ticks_msec() >= _hit_stop_until:
		_hit_stop_until = 0
		Engine.time_scale = 1.0
	if state != "paused":
		_clock += delta
		world.update_world(delta, hero.global_position.x if is_instance_valid(hero) else _camera_x)
		_update_camera(delta)
	if state == "dying":
		_death_timer -= delta
		if _death_timer <= 0.0:
			_set_state("dead")

func _physics_process(delta: float) -> void:
	if state != "playing" or not is_instance_valid(hero) or hero.dead:
		return
	elapsed += delta
	_update_projectiles(delta)
	if state != "playing":
		return
	for index in range(1, Catalog.CHECKPOINTS.size()):
		if index > checkpoint_index and absf(hero.global_position.x - Catalog.CHECKPOINTS[index].x) < 1.4 and hero.global_position.y < 1.0:
			activate_checkpoint(index)
	if not boss_started and not boss_defeated and hero.global_position.x > 160.0:
		boss_started = true
		world.close_boss_gate()
		audio.set_music("boss")
		audio.play_sfx("bell", 0.8)
		hud.show_toast("守钟者苏醒了。观察前摇，留出反击的时机。", 3.5)
	if boss_defeated and hero.global_position.x >= 191.0:
		complete_level()

func _update_camera(delta: float) -> void:
	if not is_instance_valid(camera) or not is_instance_valid(hero):
		return
	var desired := 1.8 if state == "title" else clampf(hero.global_position.x + hero.facing * 2.0, 3.0, 189.0)
	if boss_started and not boss_defeated:
		desired = clampf(desired, 164.0, 181.0)
	_camera_x = lerpf(_camera_x, desired, 1.0 - exp(-delta * 4.8))
	_shake = maxf(0.0, _shake - delta * 0.9)
	var offset := Vector3(sin(_clock * 143.0), sin(_clock * 101.0), 0.0) * _shake
	camera.position = Vector3(_camera_x, 7.8, 24.0) + offset
	camera.look_at(Vector3(_camera_x, 3.2, 0.0) + offset, Vector3.UP)

func _spawn_actors() -> void:
	if is_instance_valid(hero):
		hero.collision_layer = 0
		hero.queue_free()
	for enemy in enemies:
		if is_instance_valid(enemy):
			enemy.collision_layer = 0
			enemy.queue_free()
	enemies.clear()
	boss = null
	_clear_projectiles()
	hero = Player.new()
	hero.name = "Pilgrim"
	add_child(hero)
	hero.configure(self, Catalog.CHECKPOINTS[checkpoint_index])
	for index in range(Catalog.SPAWNS.size()):
		var data: Dictionary = Catalog.SPAWNS[index]
		if defeated_ids.has(index) or float(data.x) < Catalog.CHECKPOINTS[checkpoint_index].x - 5.0:
			continue
		var enemy := Enemy.new()
		enemy.name = "Encounter%d_%s" % [index, data.kind]
		enemy.process_mode = Node.PROCESS_MODE_PAUSABLE
		enemy.set_meta("spawn_id", index)
		add_child(enemy)
		enemy.configure(self, data.kind, Vector3(float(data.x), 0.05, 0.0))
		enemies.append(enemy)
		if data.kind == "boss":
			boss = enemy

func start_game() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	_hit_stop_until = 0
	kills = 0
	death_count = 0
	elapsed = 0.0
	checkpoint_index = 0
	defeated_ids.clear()
	boss_started = false
	boss_defeated = false
	world.open_boss_gate()
	effects.clear()
	_spawn_actors()
	for i in range(world.shrine_nodes.size()):
		world.shrine_nodes[i].set_meta("active", i == 0)
	_camera_x = 3.0
	_has_started = true
	_set_state("playing")
	audio.set_music("explore")
	audio.play_sfx("ui")
	print("RUN_STARTED")

func pause_game() -> void:
	if state != "playing":
		return
	Engine.time_scale = 1.0
	_hit_stop_until = 0
	_set_state("paused")
	get_tree().paused = true

func resume_game() -> void:
	if state != "paused":
		return
	get_tree().paused = false
	hero.control_lock = 0.12
	_set_state("playing")

func retry_checkpoint() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	_hit_stop_until = 0
	boss_started = false
	world.open_boss_gate()
	effects.clear()
	_spawn_actors()
	_camera_x = hero.global_position.x + 2.0
	_set_state("playing")
	audio.set_music("explore")
	hud.show_toast("祈灯仍亮着。生命、气力与琥珀瓶已恢复。")
	print("CHECKPOINT_RETRY index=%d" % checkpoint_index)

func return_to_title() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	_hit_stop_until = 0
	checkpoint_index = 0
	defeated_ids.clear()
	boss_started = false
	boss_defeated = false
	world.open_boss_gate()
	effects.clear()
	_set_state("title")
	_spawn_actors()
	_camera_x = 1.8
	hud.on_state_changed()
	audio.set_music("explore")

func quit_game() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false
	get_tree().quit()

func set_volume(value: float) -> void:
	volume = clampf(value, 0.0, 1.0)
	audio.set_volume(volume)
	if not test_mode:
		var config := ConfigFile.new()
		config.set_value("audio", "master", volume)
		config.save("user://settings.cfg")

func _set_state(next: String) -> void:
	state = next
	audio.set_paused(next == "paused")
	if is_instance_valid(hud):
		hud.on_state_changed()

func activate_checkpoint(index: int) -> void:
	checkpoint_index = clampi(index, 0, 2)
	_last_checkpoint = checkpoint_index
	hero.health = hero.max_health
	hero.stamina = hero.max_stamina
	hero.potions = 3
	for i in range(world.shrine_nodes.size()):
		world.shrine_nodes[i].set_meta("active", i <= checkpoint_index)
	effects.burst(hero.global_position + Vector3(0, 1.0, 0.1), GOLD, 22)
	audio.play_sfx("checkpoint")
	hud.show_toast("祈灯已点亮  ·  检查点保存，生命与琥珀瓶已恢复。", 3.2)
	print("CHECKPOINT_ACTIVE index=%d" % checkpoint_index)

func hurt_player(damage: float, from_x: float, knockback: float = 5.0) -> bool:
	if not is_instance_valid(hero) or state != "playing":
		return false
	return hero.take_damage(damage, from_x, knockback)

func parry_nearby(from_x: float) -> void:
	for enemy in enemies.duplicate():
		if is_instance_valid(enemy) and not enemy.dead and absf(enemy.global_position.x - from_x) < 1.8 and enemy.global_position.distance_to(hero.global_position) < 5.5:
			enemy.take_damage(10.0, hero.global_position.x, 7.0)
	shake(0.10)

func on_player_fell() -> void:
	if state != "playing" or hero.dead:
		return
	hero.invulnerable = 0.0
	hero.parry_invulnerable = 0.0
	hero.guarding = false
	hero.take_damage(18.0, hero.global_position.x - 1.0, 0.0)
	if hero.dead:
		return
	hero.global_position = Catalog.CHECKPOINTS[checkpoint_index]
	hero.reset_physics_interpolation()
	hero.velocity = Vector3.ZERO
	hero._finish_action()
	hero.invulnerable = 1.5
	hero.control_lock = 0.3
	_camera_x = hero.global_position.x + 2.0
	hud.show_toast("小心断桥。已回到最近祈灯，损失少量生命。", 2.5)

func on_player_died() -> void:
	if state != "playing":
		return
	death_count += 1
	_death_timer = 0.8
	_hit_stop_until = 0
	Engine.time_scale = 1.0
	audio.play_sfx("death", 0.8)
	_set_state("dying")
	_clear_projectiles()
	print("PLAYER_DEFEATED checkpoint=%d deaths=%d" % [checkpoint_index, death_count])

func on_enemy_defeated(enemy: Node) -> void:
	var id: int = int(enemy.get_meta("spawn_id", -1))
	if id >= 0 and defeated_ids.has(id):
		return
	if id >= 0:
		defeated_ids[id] = true
	kills += 1
	if is_instance_valid(hero) and not hero.dead:
		hero.health = minf(hero.max_health, hero.health + (12.0 if enemy.kind == "warden" else 5.0))
		hero.stamina = minf(hero.max_stamina, hero.stamina + 12.0)
	for index in range(projectiles.size() - 1, -1, -1):
		if is_instance_valid(projectiles[index].owner) and projectiles[index].owner == enemy:
			_remove_projectile(index)
	if enemy.kind == "boss":
		boss_defeated = true
		world.open_boss_gate()
		_clear_projectiles()
		audio.set_music("explore")
		audio.play_sfx("checkpoint", 0.8)
		hud.show_toast("守钟者已安息。向右前行，让钟声穿过雾隘。", 5.0)
		shake(0.28)
		print("BOSS_DEFEATED phase=%d" % enemy.phase)

func complete_level() -> void:
	if state != "playing" or not boss_defeated:
		return
	hero.velocity = Vector3.ZERO
	hero.play_animation("ending", 0, 6, 8.0, true, "hero_v2_motion")
	_clear_projectiles()
	audio.set_music("victory")
	audio.play_sfx("bell", 1.0)
	_set_state("victory")
	print("LEVEL_COMPLETE elapsed=%.2f kills=%d deaths=%d" % [elapsed, kills, death_count])

func shake(strength: float) -> void:
	_shake = maxf(_shake, clampf(strength, 0.0, 0.35))

func hit_stop(seconds: float) -> void:
	if test_mode or state != "playing":
		return
	_hit_stop_until = maxi(_hit_stop_until, Time.get_ticks_msec() + int(seconds * 1000.0))
	Engine.time_scale = 0.13

func spawn_projectile(origin: Vector3, direction: Vector3, projectile_kind: String, damage: float, speed: float, owner: Node, tint: Color) -> void:
	if state != "playing" or projectiles.size() >= 80:
		return
	var visual := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = tint
	material.emission_enabled = true
	material.emission = tint
	material.emission_energy_multiplier = 1.7
	if projectile_kind == "bolt":
		var arrow := CylinderMesh.new()
		arrow.height = 0.68
		arrow.top_radius = 0.02
		arrow.bottom_radius = 0.045
		visual.mesh = arrow
		visual.quaternion = Quaternion(Vector3.UP, direction.normalized())
	else:
		var orb := SphereMesh.new()
		orb.radius = 0.16 if projectile_kind == "orb" else 0.22
		orb.height = orb.radius * 2.0
		orb.radial_segments = 10
		orb.rings = 5
		visual.mesh = orb
	visual.material_override = material
	visual.position = origin
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)
	projectiles.append({"node": visual, "velocity": direction.normalized() * speed, "damage": damage, "owner": owner, "kind": projectile_kind, "age": 0.0, "trail": 0.0, "tint": tint})

func spawn_wave(x: float, direction: float, damage: float, owner: Node) -> void:
	spawn_projectile(Vector3(x + direction * 0.65, 0.28, 0.0), Vector3(direction, 0, 0), "wave", damage, 7.0, owner, GOLD)
	if not projectiles.is_empty():
		var item: Dictionary = projectiles.back()
		if item.kind == "wave":
			item.node.scale = Vector3(0.7, 1.6, 0.7)

func _update_projectiles(delta: float) -> void:
	for index in range(projectiles.size() - 1, -1, -1):
		if index >= projectiles.size():
			continue
		var item: Dictionary = projectiles[index]
		var node: MeshInstance3D = item.node
		item.age += delta
		item.trail += delta
		if item.age > 5.5 or not is_instance_valid(item.owner) or absf(node.position.x - hero.global_position.x) > 30.0:
			_remove_projectile(index)
			continue
		var previous := node.position
		node.position += (item.velocity as Vector3) * delta
		if item.kind == "orb":
			node.scale = Vector3.ONE * (1.0 + 0.09 * sin(item.age * 17.0))
		if item.trail > 0.075:
			item.trail = 0.0
			effects.burst(node.position, item.tint, 1)
		var centre := hero.global_position + Vector3(0, 0.92, 0)
		var closest := Geometry3D.get_closest_point_to_segment(centre, previous, node.position)
		var diff := centre - closest
		var hit := absf(diff.x) < 0.5 and absf(diff.y) < 0.95 and absf(diff.z) < 0.7
		if item.kind == "wave":
			hit = absf(node.position.x - hero.global_position.x) < 0.56 and hero.global_position.y < 0.8
		if hit and item.owner != hero:
			# Remove BEFORE damage: a parry/death callback can mutate the collection.
			var amount: float = item.damage
			var source_x: float = previous.x - signf(item.velocity.x) * 0.5
			_remove_projectile(index)
			hurt_player(amount, source_x, 4.5)
			if state != "playing":
				break
			continue
		var query := PhysicsRayQueryParameters3D.create(previous, node.position, 1)
		if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			effects.burst(node.position, item.tint, 4)
			_remove_projectile(index)

func _remove_projectile(index: int) -> void:
	if index < 0 or index >= projectiles.size():
		return
	var node: Node = projectiles[index].node
	if is_instance_valid(node):
		node.queue_free()
	projectiles.remove_at(index)

func _clear_projectiles() -> void:
	for item: Dictionary in projectiles:
		if is_instance_valid(item.node):
			item.node.queue_free()
	projectiles.clear()

func _exit_tree() -> void:
	Engine.time_scale = 1.0