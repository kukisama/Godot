extends "res://scripts/actor.gd"
## Chapter I's eight enemies. Every tell, strike and recovery owns its atlas range.
## Timings are minimum durations, rounded UP to a physics tick: a long frame must
## never consume an unseen tell and its strike together. No asynchronous timers.

const Catalog = preload("res://scripts/catalog.gd")
const WAKE_DISTANCE: float = 20.0
const GRAVITY: float = 24.0
const MIN_TELL: float = 0.45
const ARENA_LEFT: float = 161.0
const ARENA_RIGHT: float = 185.0
const DEATH_DURATION: float = 0.9
const PHASE_DURATION: float = 1.25
const DISSOLVE_TINT: Color = Color(1.0, 0.76, 0.35)
const BOSS_CYCLE: Array[String] = ["sweep", "jump_slam", "bell"]
const ATTACKS: Dictionary = {
	"briar": "pounce", "sentinel": "double_cut", "lancer": "thrust",
	"arbalist": "bolt", "cantor": "fan", "gargoyle": "dive", "warden": "slam"
}

var state: String = "idle"
var attack_name: String = ""
var phase: int = 1
var ai_enabled: bool = true
## Monotonic count of committed strike/release/pulse segments, including misses.
## A two-direction ground wave is ONE attack event, not two melee swings.
var attack_events_count: int = 0

var _configured: bool = false
var _stats: Dictionary = {}
var _tint: Color = Color.WHITE
var _home: Vector3 = Vector3.ZERO
var _flight_home: Vector3 = Vector3.ZERO
var _locked_target: Vector3 = Vector3.ZERO
var _dive_velocity: Vector3 = Vector3.ZERO
var _jump_target: Vector3 = Vector3.ZERO
var _ground_y: float = 0.0
var _last_safe_position: Vector3 = Vector3.ZERO
var _radius: float = 0.34
var _cooldown: float = 0.35
var _hurt_left: float = 0.0
var _phase_left: float = 0.0
var _death_elapsed: float = 0.0
var _death_started: bool = false
var _motion_clock: float = 0.0
var _step_clock: float = 0.0
var _boss_cycle_index: int = 0
var _stages: Array[Dictionary] = []
var _stage_index: int = -1
var _stage_elapsed: float = 0.0
var _attack_epoch: int = 0
var _swing_spent: bool = false
var _aim_line: MeshInstance3D
var _target_marker: MeshInstance3D


func configure(world: Node, enemy_kind: String, spawn: Vector3) -> void:
	if _configured:
		push_warning("Enemy.configure may only be called once per instance.")
		return
	if not Catalog.ENEMIES.has(enemy_kind) or not is_instance_valid(world):
		push_warning("Enemy requires a game and one of Catalog.ENEMIES' eight kinds.")
		return
	_stats = Catalog.ENEMIES[enemy_kind]
	_tint = _stats["tint"]
	setup_actor(world, enemy_kind, float(_stats["hp"]), float(_stats["pixel_size"]), float(_stats["height"]))
	global_position = Vector3(spawn.x, spawn.y, 0.0)
	if kind == "boss":
		global_position.x = clampf(global_position.x, ARENA_LEFT, ARENA_RIGHT)
		_radius = 0.75
	_ground_y = global_position.y
	_last_safe_position = global_position
	_home = global_position
	if kind == "gargoyle":
		_home.y += 2.6
		global_position = _home
		floor_snap_length = 0.0
	_flight_home = global_position
	_make_target_visuals()
	_configured = true
	_locomotion_animation(false)
	if not _can_wake(_hero()):
		_sleep()


func _process(delta: float) -> void:
	if not _playing() or state == "dormant":
		return
	super._process(delta)
	if dead and is_instance_valid(sprite):
		# The base resets modulate each render frame; apply our death alpha AFTER it.
		sprite.modulate.a = 1.0 - clampf((_death_elapsed - 0.35) / 0.55, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	if not _playing() or delta <= 0.0:
		return
	if dead:
		_death_elapsed += delta
		if _death_elapsed >= DEATH_DURATION:
			queue_free()
		return
	var hero: Node3D = _hero()
	if not _can_wake(hero):
		_sleep()
		return
	if state == "dormant":
		state = "idle"
		_cooldown = maxf(_cooldown, 0.35)
	_motion_clock += delta
	_cooldown = maxf(0.0, _cooldown - delta)
	if kind == "boss" and phase == 1 and health < max_health * 0.5:
		_begin_phase_two()
	if state == "transition":
		_phase_left = maxf(0.0, _phase_left - delta)
		velocity.x = 0.0
		_move_body(delta)
		if _phase_left <= 0.0:
			state = "idle"
			telegraph_strength = 0.0
			_cooldown = 0.35
			_locomotion_animation(false)
		return
	if state == "hurt":
		_hurt_left = maxf(0.0, _hurt_left - delta)
		velocity.x = move_toward(velocity.x, 0.0, delta * 14.0)
		if kind == "gargoyle":
			velocity.y = 0.0
		_move_body(delta)
		if _hurt_left <= 0.0:
			state = "idle"
			_locomotion_animation(false)
		return
	if not _stages.is_empty():
		_tick_attack(delta)
		return
	_tick_locomotion(delta, hero)


func start_attack(forced: String = "") -> void:
	if not _playing() or dead or not _can_wake(_hero()):
		return
	if not _stages.is_empty() or state == "hurt" or state == "transition":
		return
	var selected: String = _select_attack(forced)
	if selected.is_empty():
		return
	attack_name = selected
	_attack_epoch += 1
	velocity.x = 0.0
	_build_attack()
	_stage_index = -1
	_next_stage()


func take_damage(amount: float, from_x: float, force: float = 4.0) -> bool:
	if not _playing() or dead or not is_finite(amount) or amount <= 0.0:
		return false
	if kind == "boss" and not _boss_allowed(_hero()):
		return false
	var prior_velocity: Vector3 = velocity
	var safe_force: float = maxf(0.0, force) if is_finite(force) else 0.0
	var source_x: float = from_x if is_finite(from_x) else global_position.x - facing
	if not apply_damage(amount, source_x, 0.0 if kind == "boss" else safe_force):
		return false
	squash = Vector2(1.035, 0.97)
	if dead:
		_begin_death()
		return true
	_sfx("hit", 0.8 if kind == "boss" else 1.0)
	_burst(global_position + Vector3(0, body_height * 0.55, 0.1), 5)
	if kind == "boss":
		# Ordinary hits neither stagger the boss nor erase an in-flight jump.
		velocity = prior_velocity
		if phase == 1 and health < max_health * 0.5:
			_begin_phase_two()
	else:
		_cancel_attack()
		state = "hurt"
		_hurt_left = 0.28
		_cooldown = maxf(_cooldown, 0.65)
		visual_tilt = -float(facing) * 0.035
		play_animation("hurt_%d" % _attack_epoch, 18, 3, 12.0, false)
	return true


func _select_attack(forced: String) -> String:
	if kind != "boss":
		var expected: String = str(ATTACKS[kind])
		return expected if forced.is_empty() or forced == expected or forced == kind else ""
	if forced.is_empty():
		var selected: String = BOSS_CYCLE[_boss_cycle_index % BOSS_CYCLE.size()]
		_boss_cycle_index += 1
		return selected
	if forced == "slam":
		return "jump_slam"
	if forced == "bells" or forced == "bell_pulses":
		return "bell"
	return forced if BOSS_CYCLE.has(forced) else ""


func _tell_stage(duration: float) -> Dictionary:
	return {"state": "windup", "duration": maxf(MIN_TELL, duration), "first": 12, "count": 2}


func _strike_stage(duration: float, event: String, reach: float = 0.0, vertical: float = 1.8,
		speed: float = 0.0, scale: float = 1.0, index: int = 0) -> Dictionary:
	return {"state": "active", "duration": duration, "first": 14, "count": 2,
		"event": event, "reach": reach, "vertical": vertical, "speed": speed,
		"damage_scale": scale, "index": index}


func _recovery_stage(duration: float, speed: float = 0.0) -> Dictionary:
	return {"state": "recovery", "duration": duration, "first": 16, "count": 2, "speed": speed}


func _build_attack() -> void:
	_stages.clear()
	var windup: float = float(_stats["windup"])
	var recovery: float = float(_stats["recovery"])
	match attack_name:
		"pounce":
			_stages.append(_tell_stage(windup))
			_stages.append(_strike_stage(0.30, "pounce", 1.3, 0.95, 10.5))
			_stages.append(_recovery_stage(recovery))
		"double_cut":
			_stages.append(_tell_stage(windup))
			_stages.append(_strike_stage(0.16, "cut", 2.15, 1.9, 1.2))
			_stages.append(_recovery_stage(0.18))
			_stages.append(_tell_stage(0.50))
			_stages.append(_strike_stage(0.18, "cut", 2.35, 1.9, 1.5))
			_stages.append(_recovery_stage(recovery))
		"thrust":
			_stages.append(_tell_stage(windup))
			_stages.append(_strike_stage(0.24, "thrust", 4.2, 1.05, 7.2))
			_stages.append(_recovery_stage(recovery))
		"bolt":
			_stages.append(_tell_stage(windup))
			_stages.append(_strike_stage(0.10, "bolt"))
			_stages.append(_recovery_stage(0.18, -1.8))
			_stages.append(_recovery_stage(recovery - 0.18))
		"fan":
			_stages.append(_tell_stage(windup))
			for index in range(3):
				_stages.append(_strike_stage(0.08, "orb", 0.0, 1.8, 0.0, 1.0, index))
				if index < 2:
					# The same telegraphed cast, not three fresh, shortened windups.
					_stages.append({"state": "casting", "duration": 0.16, "first": 15, "count": 1})
			_stages.append(_recovery_stage(recovery))
		"dive":
			_stages.append(_tell_stage(windup))
			_stages.append(_strike_stage(0.46, "dive", 1.2, 1.25))
			_stages.append(_recovery_stage(recovery))
		"slam":
			_stages.append(_tell_stage(windup))
			_stages.append(_strike_stage(0.20, "hammer", 3.2, 1.35))
			_stages.append(_recovery_stage(recovery))
		"sweep":
			var cuts: int = 3 if phase == 2 else 1
			for index in range(cuts):
				_stages.append(_tell_stage((0.78 if phase == 2 else windup) if index == 0 else 0.50))
				_stages.append(_strike_stage(0.22, "sweep", 4.7, 2.65, 1.35))
				if index < cuts - 1:
					_stages.append(_recovery_stage(0.18))
			_stages.append(_recovery_stage(recovery))
		"jump_slam":
			var jumps: int = 2 if phase == 2 else 1
			for index in range(jumps):
				_stages.append(_tell_stage((0.85 if phase == 2 else 1.20) if index == 0 else 0.55))
				_stages.append({"state": "airborne", "duration": 0.70, "first": 13, "count": 1})
				_stages.append(_strike_stage(0.20, "landing", 3.8, 1.4, 0.0, 1.2))
				if index < jumps - 1:
					_stages.append(_recovery_stage(0.30))
			_stages.append(_recovery_stage(recovery))
		"bell":
			for index in range(3):
				var tell_time: float = (0.90 if phase == 2 else 1.30) if index == 0 else (0.50 if phase == 2 else 0.72)
				_stages.append(_tell_stage(tell_time))
				_stages.append(_strike_stage(0.12, "bell", 0.0, 1.8, 0.0, 0.8, index))
			_stages.append(_recovery_stage(recovery))


func _next_stage() -> void:
	_stage_index += 1
	_stage_elapsed = 0.0
	_swing_spent = false
	_hide_targets()
	if _stage_index >= _stages.size():
		_finish_attack()
		return
	var stage: Dictionary = _stages[_stage_index]
	state = str(stage["state"])
	telegraph_strength = 1.0 if state == "windup" else 0.0
	visual_tilt = 0.0
	velocity.x = 0.0
	var count: int = int(stage["count"])
	play_animation("%s_%d_%d" % [attack_name, _attack_epoch, _stage_index],
		int(stage["first"]), count, float(count) / float(stage["duration"]), false)
	if state == "windup":
		_lock_target()
		visual_tilt = -float(facing) * (0.065 if kind == "briar" else 0.035)
		squash = Vector2(1.035, 0.96) if kind == "briar" else Vector2(0.985, 1.02)
		if kind == "gargoyle":
			_sfx("wing", 0.8)
	elif state == "airborne":
		velocity.y = 8.4
		_sfx("jump", 0.65)
	elif state == "active":
		visual_tilt = float(facing) * (0.055 if kind != "gargoyle" else 0.09)
		_commit_event(stage)


func _tick_attack(delta: float) -> void:
	var epoch: int = _attack_epoch
	var stage: Dictionary = _stages[_stage_index]
	_stage_elapsed += delta
	velocity.x = float(stage.get("speed", 0.0)) * float(facing)
	if kind == "gargoyle":
		velocity = Vector3.ZERO
		if state == "active":
			var offset: Vector3 = _locked_target - global_position
			velocity = _dive_velocity
			if offset.dot(_dive_velocity) <= 0.0:
				velocity = Vector3.ZERO
			elif offset.length() < _dive_velocity.length() * delta:
				velocity = offset / delta
		elif state == "recovery":
			var offset: Vector3 = _flight_home - global_position
			velocity = offset.normalized() * minf(8.5, offset.length() / delta)
	elif state == "airborne":
		velocity.x = clampf((_jump_target.x - global_position.x) / delta, -6.9, 6.9)
	_move_body(delta)
	if state == "active":
		_try_melee(stage)
	# A parry can call take_damage synchronously from game.hurt_player.
	if not _event_live(epoch):
		return
	if state == "airborne":
		# A jump slam commits only AFTER real terrain contact, never on a timer in air.
		if is_on_floor() and _stage_elapsed >= 0.10:
			_next_stage()
		return
	if _stage_elapsed + 0.000001 < float(stage["duration"]):
		return
	if kind == "gargoyle" and state == "recovery" and global_position.distance_to(_flight_home) > 0.12:
		return
	_next_stage()


func _commit_event(stage: Dictionary) -> void:
	var epoch: int = _attack_epoch
	if not _event_live(epoch):
		return
	attack_events_count += 1
	var event: String = str(stage["event"])
	match event:
		"bolt", "orb":
			var origin: Vector3 = _muzzle()
			var direction: Vector3 = (_locked_target - origin).normalized()
			if direction.length_squared() < 0.01:
				direction = Vector3(facing, 0, 0)
			var speed: float = 19.5
			var projectile_kind: String = "bolt"
			if event == "orb":
				var index: int = int(stage["index"])
				direction = direction.rotated(Vector3(0, 0, 1), float(index - 1) * 0.24)
				speed = 4.8 + float(index) * 1.6
				projectile_kind = "orb"
			game.call("spawn_projectile", origin, direction, projectile_kind, float(_stats["damage"]), speed, self, _tint)
			_sfx("bow" if event == "bolt" else "magic", 1.0)
			_burst(origin, 4)
		"bell":
			_sfx("bell", 0.85 + float(int(stage["index"])) * 0.12)
			_burst(global_position + Vector3(0, body_height * 0.8, 0), 14)
			_wave_pair(float(_stats["damage"]) * float(stage["damage_scale"]), epoch)
			_shake(0.17)
		_:
			var sound: String = "sword"
			if event == "pounce" or event == "dive":
				sound = "wing" if event == "dive" else "heavy"
			elif event == "hammer" or event == "landing":
				sound = "slam"
			_sfx(sound, 0.75 if kind == "boss" else 1.0)
			_slash(float(stage["reach"]))
			_try_melee(stage)
			if not _event_live(epoch):
				return
			if event == "hammer" or event == "landing":
				squash = Vector2(1.055, 0.94)
				_burst(global_position + Vector3(float(facing), 0.15, 0), 18)
				_wave_pair(float(_stats["damage"]) * 0.7, epoch)
				_shake(0.3 if kind == "boss" else 0.2)


func _try_melee(stage: Dictionary) -> void:
	if dead or state != "active" or _swing_spent or not _playing():
		return
	# Projectile releases and bell pulses have no invisible contact hitbox.
	var reach: float = float(stage.get("reach", 0.0))
	if reach <= 0.0 or sprite.frame < 14 or sprite.frame > 15:
		return
	var hero: Node3D = _hero()
	if not _hero_alive(hero) or not is_ahead(hero.global_position, reach, float(stage["vertical"])):
		return
	if absf(hero.global_position.z - global_position.z) > 1.0:
		return
	# Spend on CONTACT, not on success: a guard, roll or parry is not retried.
	_swing_spent = true
	game.call("hurt_player", float(_stats["damage"]) * float(stage["damage_scale"]),
		global_position.x, 7.0 if kind == "boss" or kind == "warden" else 4.5)


func _wave_pair(damage: float, epoch: int) -> void:
	if _event_live(epoch):
		game.call("spawn_wave", global_position.x, -1.0, damage, self)
	if _event_live(epoch):
		game.call("spawn_wave", global_position.x, 1.0, damage, self)


func _lock_target() -> void:
	var hero: Node3D = _hero()
	if not _hero_alive(hero):
		return
	_face_target(hero.global_position.x)
	_locked_target = Vector3(hero.global_position.x, hero.global_position.y, 0.0)
	if kind == "arbalist" or kind == "cantor":
		_locked_target.y += 0.95
	if kind == "gargoyle":
		_flight_home = global_position
		_locked_target.y += 0.12
		_dive_velocity = (_locked_target - global_position) / 0.46
	if attack_name == "jump_slam":
		_jump_target = Vector3(clampf(_locked_target.x, global_position.x - 4.8, global_position.x + 4.8), _ground_y, 0)
		_jump_target.x = clampf(_jump_target.x, ARENA_LEFT + _radius, ARENA_RIGHT - _radius)
	if is_instance_valid(_aim_line):
		var mesh: ImmediateMesh = _aim_line.mesh as ImmediateMesh
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_add_vertex(to_local(_muzzle()))
		mesh.surface_add_vertex(to_local(_locked_target))
		mesh.surface_end()
		_aim_line.visible = true
	if is_instance_valid(_target_marker) and (kind == "gargoyle" or attack_name == "jump_slam"):
		_target_marker.global_position = (_jump_target if kind == "boss" else _locked_target) + Vector3(0, 0.035, 0)
		_target_marker.visible = true


func _tick_locomotion(delta: float, hero: Node3D) -> void:
	var offset: float = hero.global_position.x - global_position.x
	var distance: float = absf(offset)
	var speed: float = float(_stats["speed"])
	var reach: float = float(_stats["range"])
	velocity.x = 0.0
	visual_tilt = 0.0
	if ai_enabled:
		_face_target(hero.global_position.x)
		if kind == "arbalist" or kind == "cantor":
			if distance < 3.8:
				velocity.x = -float(facing) * speed
			elif distance > reach * 0.88:
				velocity.x = float(facing) * speed
		else:
			var stopping_distance: float = reach * (0.72 if kind != "gargoyle" else 0.65)
			if distance > stopping_distance:
				velocity.x = float(facing) * speed
	if kind == "gargoyle":
		# Authored 6..11 wing poses carry the motion; only a tiny hover displacement.
		var hover_y: float = _home.y + sin(_motion_clock * 2.2) * 0.10
		velocity.y = clampf((hover_y - global_position.y) * 3.0, -2.6, 2.6)
		visual_tilt = sin(_motion_clock * 2.2) * 0.018
	_move_body(delta)
	_locomotion_animation(absf(velocity.x) > 0.05)
	if ai_enabled and (absf(velocity.x) > 0.1 or kind == "gargoyle"):
		_step_clock += delta
		var interval: float = 0.70 if kind == "gargoyle" or kind == "warden" or kind == "boss" else 0.46
		if _step_clock >= interval:
			_step_clock = 0.0
			_sfx("wing" if kind == "gargoyle" else "step", 0.8 if kind == "warden" else 1.0)
	if ai_enabled and _cooldown <= 0.0 and distance <= reach:
		if kind == "gargoyle" or (is_on_floor() and absf(hero.global_position.y - global_position.y) < 3.0):
			start_attack()


func _locomotion_animation(moving: bool) -> void:
	if kind == "gargoyle":
		play_animation("hover", 6, 6, 9.0)
		return
	var fps: float = 8.0
	match kind:
		"briar": fps = 15.0
		"sentinel": fps = 8.0
		"lancer": fps = 6.5
		"arbalist": fps = 7.5
		"cantor": fps = 5.5
		"warden": fps = 4.5
		"boss": fps = 5.0
	play_animation("move" if moving else "idle", 6 if moving else 0, 6, fps if moving else 6.0)


func _move_body(delta: float) -> void:
	velocity.z = 0.0
	if kind != "gargoyle":
		velocity.y = -0.5 if is_on_floor() and velocity.y <= 0.0 else velocity.y - GRAVITY * delta
		if absf(velocity.x) > 0.001 and not _ground_path_safe(velocity.x * delta):
			velocity.x = 0.0
	if kind == "boss":
		velocity.x = clampf(velocity.x, (ARENA_LEFT - global_position.x) / delta, (ARENA_RIGHT - global_position.x) / delta)
	move_and_slide()
	global_position.z = 0.0
	if kind == "boss":
		global_position.x = clampf(global_position.x, ARENA_LEFT, ARENA_RIGHT)
	if kind != "gargoyle":
		if is_on_floor():
			_ground_y = global_position.y
			_last_safe_position = global_position
		elif global_position.y < _last_safe_position.y - 1.1:
			# Solver/contact loss fails closed, without teleporting across a known gap.
			global_position = _last_safe_position
			velocity = Vector3.ZERO


func _ground_path_safe(displacement: float) -> bool:
	var direction: float = signf(displacement)
	var length: float = absf(displacement) + _radius + 0.18
	var samples: int = maxi(1, int(ceil(length / 0.35)))
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	for index in range(1, samples + 1):
		var x: float = global_position.x + direction * length * float(index) / float(samples)
		# These are the authored open gaps; also ray-test arbitrary terrain ledges.
		for gap: Vector2 in Catalog.GAPS:
			if x > gap.x and x < gap.y:
				return false
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			Vector3(x, _ground_y + 0.65, 0), Vector3(x, _ground_y - 0.70, 0), 1)
		query.exclude = [get_rid()]
		var result: Dictionary = space.intersect_ray(query)
		if result.is_empty():
			return false
		var normal: Vector3 = result["normal"]
		if normal.y < 0.65:
			return false
	return true


func _begin_phase_two() -> void:
	_cancel_attack()
	phase = 2
	state = "transition"
	_phase_left = PHASE_DURATION
	_boss_cycle_index = 0
	velocity.x = 0.0
	telegraph_strength = 1.0
	visual_tilt = 0.0
	play_animation("phase_two", 12, 2, 2.0 / PHASE_DURATION, false)
	_burst(global_position + Vector3(0, body_height * 0.6, 0), 24)
	_sfx("bell", 0.65)
	_shake(0.2)


func _begin_death() -> void:
	if _death_started:
		return
	_death_started = true
	_cancel_attack()
	state = "dead"
	ai_enabled = false
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	for child: Node in get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", true)
	tell.visible = false
	hp_fill.visible = false
	hp_back.visible = false
	visual_tilt = float(facing) * 0.04
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	play_animation("death", 21, 3, 5.0, false)
	_burst(global_position + Vector3(0, body_height * 0.5, 0), 32 if kind == "boss" else 16)
	_sfx("death", 0.7 if kind == "boss" else 1.0)
	# Immediate notification, before the physics-driven dissolve frees this node.
	game.call("on_enemy_defeated", self)


func _cancel_attack() -> void:
	_attack_epoch += 1
	_stages.clear()
	_stage_index = -1
	_stage_elapsed = 0.0
	_swing_spent = true
	attack_name = ""
	telegraph_strength = 0.0
	_hide_targets()


func _finish_attack() -> void:
	_cancel_attack()
	state = "idle"
	velocity.x = 0.0
	visual_tilt = 0.0
	_cooldown = float(_stats["cooldown"]) * (0.85 if kind == "boss" and phase == 2 else 1.0)
	_locomotion_animation(false)


func _sleep() -> void:
	if state != "dormant":
		_cancel_attack()
		state = "dormant"
		velocity = Vector3.ZERO
		visual_tilt = 0.0
		tell.visible = false
		_locomotion_animation(false)


func _playing() -> bool:
	return _configured and is_instance_valid(game) and str(game.get("state")) == "playing"


func _hero() -> Node3D:
	if not is_instance_valid(game):
		return null
	var candidate = game.get("hero")
	return candidate as Node3D if is_instance_valid(candidate) and candidate is Node3D else null


func _hero_alive(hero: Node3D) -> bool:
	return is_instance_valid(hero) and not bool(hero.get("dead")) and float(hero.get("health")) > 0.0


func _boss_allowed(hero: Node3D) -> bool:
	return is_instance_valid(game) and (bool(game.get("boss_started")) or (is_instance_valid(hero) and hero.global_position.x > 160.0))


func _can_wake(hero: Node3D) -> bool:
	if not _hero_alive(hero) or absf(hero.global_position.x - global_position.x) > WAKE_DISTANCE:
		return false
	return kind != "boss" or _boss_allowed(hero)


func _event_live(epoch: int) -> bool:
	return _attack_epoch == epoch and not dead and _playing() and _can_wake(_hero())


func _face_target(x: float) -> void:
	if absf(x - global_position.x) > 0.05:
		facing = 1 if x > global_position.x else -1


func _muzzle() -> Vector3:
	return global_position + Vector3(float(facing) * 0.55, body_height * 0.65, 0)


func _make_target_visuals() -> void:
	if kind == "arbalist":
		_aim_line = MeshInstance3D.new()
		_aim_line.mesh = ImmediateMesh.new()
		_aim_line.material_override = flat_material(Color(_tint, 0.7))
		_aim_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_aim_line)
	if kind == "gargoyle" or kind == "boss":
		_target_marker = MeshInstance3D.new()
		var ring: ImmediateMesh = ImmediateMesh.new()
		ring.surface_begin(Mesh.PRIMITIVE_LINES)
		for index in range(32):
			var a: float = TAU * float(index) / 32.0
			var b: float = TAU * float(index + 1) / 32.0
			ring.surface_add_vertex(Vector3(cos(a), 0, sin(a)) * 0.7)
			ring.surface_add_vertex(Vector3(cos(b), 0, sin(b)) * 0.7)
		ring.surface_end()
		_target_marker.mesh = ring
		_target_marker.material_override = flat_material(Color(_tint, 0.8))
		_target_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_target_marker)
		_target_marker.top_level = true
	_hide_targets()


func _hide_targets() -> void:
	if is_instance_valid(_aim_line):
		_aim_line.visible = false
	if is_instance_valid(_target_marker):
		_target_marker.visible = false


func _sfx(sound: String, pitch: float = 1.0) -> void:
	var audio = game.get("audio")
	if is_instance_valid(audio) and audio.has_method("play_sfx"):
		audio.call("play_sfx", sound, pitch)


func _burst(at: Vector3, count: int) -> void:
	var effects = game.get("effects")
	if is_instance_valid(effects) and effects.has_method("burst"):
		effects.call("burst", at, DISSOLVE_TINT if dead else _tint, count)


func _slash(radius: float) -> void:
	var effects = game.get("effects")
	if is_instance_valid(effects) and effects.has_method("slash"):
		effects.call("slash", global_position + Vector3(0, body_height * 0.45, 0.1), facing, _tint, radius)


func _shake(strength: float) -> void:
	if game.has_method("shake"):
		game.call("shake", strength)