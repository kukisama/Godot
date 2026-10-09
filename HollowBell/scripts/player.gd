extends "res://scripts/actor.gd"
## Continuous authored 12-pose clips, physics-clocked hits and buffered movement.

const SPEED := 6.7
const GRAVITY := 26.0
const JUMP_SPEED := 11.0
const COYOTE_TIME := 0.13
const JUMP_BUFFER := 0.14
const ATTACK_WINDUP := [0.12, 0.16, 0.23]
const ATTACK_ACTIVE := [0.15, 0.16, 0.19]
const ATTACK_RECOVERY := [0.15, 0.14, 0.24]
const ATTACK_DAMAGE := [23.0, 27.0, 38.0]
const ATTACK_REACH := [2.35, 2.60, 2.95]
const HEAVY_WINDUP := 0.16
const HEAVY_ACTIVE := 0.24
const HEAVY_RECOVERY := 0.38
const QUICK_DURATION := 0.30
const QUICK_IFRAMES := 0.22
const QUICK_COST := 14.0
const ROLL_BUFFER_TIME := 0.16
const QUICK_CANCEL_TIME := 0.22
const PARRY_WINDOW := 0.17
const PARRY_PROTECTION := 1.0
const PARRY_RECOVERY := 0.24
const BLOCK_RECOVERY := 0.16

var state := "idle"
var stamina := 100.0
var max_stamina := 100.0
var potions := 3
var guarding := false
var action_time := 0.0
var combo_index := 0
var combo_queued := false
var invulnerable := 0.0
var parry_invulnerable := 0.0
var control_lock := 0.0
var coyote := 0.0
var jump_buffer := 0.0
var charge := 0.0
var attack_commits := 0
var parries := 0
var _committed := false
var _guard_time := 0.0
var _regen_delay := 0.0
var _step_time := 0.0
var _was_grounded := false
var _hit_targets: Dictionary = {}
var _ghost_time := 0.0
var _roll_buffer := 0.0
var _buffered_quick := false
var _roll_cooldown := 0.0
var _guard_held_last := false
var _loop_phase := 0.0
var _jump_elapsed := 0.0
var _landing_time := 0.0
var _heavy_release_pose := 0

func configure(owner_game: Node, spawn: Vector3) -> void:
	setup_actor(owner_game, "hero", 100.0, 0.0138, 2.0)
	process_mode = Node.PROCESS_MODE_PAUSABLE
	animation_external_clock = true
	global_position = spawn
	control_lock = 0.2
	animation_name = ""
	play_animation("idle", 0, 6, 8.0, true, "hero_v2_motion")
	reset_physics_interpolation()

func _process(delta: float) -> void:
	if not is_instance_valid(game) or game.state == "paused":
		return
	super._process(delta)
	if parry_invulnerable > 0.0:
		# A stable warm outline/color cue, not the injured blinking silhouette.
		sprite.modulate = Color(1.14, 1.08, 0.87)
	elif invulnerable > 0.0 and state not in ["roll", "quick_roll"]:
		sprite.modulate.a = 0.6 + 0.4 * absf(sin(invulnerable * 35.0))

func _physics_process(delta: float) -> void:
	if not is_instance_valid(game) or game.state == "paused":
		return
	if game.state in ["title", "victory"]:
		_advance_loop("idle" if game.state == "title" else "ending", 0, 6, 8.0, delta, "hero_v2_motion")
		return
	if game.state != "playing" or dead:
		return
	parry_invulnerable = _countdown(parry_invulnerable, delta)
	invulnerable = maxf(_countdown(invulnerable, delta), parry_invulnerable)
	control_lock = maxf(0.0, control_lock - delta)
	_regen_delay = maxf(0.0, _regen_delay - delta)
	_roll_buffer = _countdown(_roll_buffer, delta)
	_roll_cooldown = _countdown(_roll_cooldown, delta)
	_landing_time = _countdown(_landing_time, delta)
	jump_buffer = maxf(0.0, jump_buffer - delta)
	coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, coyote - delta)
	_update_guard_clock(delta)
	var move_axis := Input.get_axis("move_left", "move_right") if control_lock <= 0.0 else 0.0
	if control_lock <= 0.0 and Input.is_action_just_pressed("jump"):
		jump_buffer = JUMP_BUFFER
	if _regen_delay <= 0.0 and state not in ["charge", "heavy", "roll", "quick_roll"]:
		stamina = minf(max_stamina, stamina + delta * (7.0 if guarding else 28.0))
	if control_lock <= 0.0:
		_read_actions(move_axis)
	if state == "idle":
		_tick_locomotion(delta, move_axis)
	else:
		_tick_action(delta, move_axis)
	if not is_on_floor():
		var fall_multiplier := 1.6 if velocity.y > 0.0 and not Input.is_action_pressed("jump") else 1.0
		velocity.y -= GRAVITY * fall_multiplier * delta
	elif velocity.y < 0.0:
		velocity.y = -0.5
	velocity.z = 0.0
	move_and_slide()
	global_position.z = 0.0
	global_position.x = maxf(-6.0, global_position.x)
	if not _was_grounded and is_on_floor():
		squash = Vector2(1.07, 0.94)
		_landing_time = 0.09
		if state == "idle" and animation_name == "jump":
			seek_animation_pose(5)
		game.audio.play_sfx("land", 1.0)
		game.effects.burst(global_position + Vector3(0, 0.08, 0.2), Color(0.62, 0.65, 0.46), 5)
	_was_grounded = is_on_floor()
	if global_position.y < -6.0:
		game.on_player_fell()

static func _countdown(value: float, delta: float) -> float:
	var remaining := value - delta
	return remaining if remaining > 0.0000001 else 0.0

func _update_guard_clock(delta: float) -> void:
	var held := Input.is_action_pressed("guard") and control_lock <= 0.0
	if held:
		_guard_time = _guard_time + delta if _guard_held_last else 0.0
	else:
		_guard_time = 0.0
	_guard_held_last = held

func _read_actions(move_axis: float) -> void:
	var quick_pressed := Input.is_action_just_pressed("quick_roll")
	var roll_pressed := Input.is_action_just_pressed("dodge")
	if (quick_pressed or roll_pressed) and _roll_cooldown <= 0.0 and state not in ["hurt", "heal", "dead"]:
		var cost := QUICK_COST if quick_pressed else 20.0
		if stamina >= cost:
			_buffered_quick = quick_pressed
			_roll_buffer = ROLL_BUFFER_TIME
	if _roll_buffer > 0.0 and _roll_cooldown <= 0.0:
		var cost := QUICK_COST if _buffered_quick else 20.0
		if _can_roll(_buffered_quick) and stamina >= cost:
			if absf(move_axis) > 0.1:
				facing = 1 if move_axis > 0.0 else -1
			begin_roll(_buffered_quick)
			return
	if Input.is_action_just_pressed("light"):
		if state == "attack":
			combo_queued = true
		elif (state == "idle" or (state == "parry" and action_time >= 0.12) or (state == "quick_roll" and action_time >= QUICK_CANCEL_TIME)) and stamina >= 7.0:
			begin_attack(0)
			return
	if state != "idle":
		return
	if Input.is_action_just_pressed("heavy") and stamina >= 26.0:
		state = "charge"
		charge = 0.0
		action_time = 0.0
		guarding = false
		play_animation("charge", 12, 4, 20.0, false, "hero_v2_blade_b")
	elif Input.is_action_just_pressed("heal") and potions > 0 and health < max_health:
		state = "heal"
		action_time = 0.0
		_committed = false
		guarding = false
		play_animation("heal", 18, 6, 6.5, false, "hero_special")

func _can_roll(quick: bool) -> bool:
	if state in ["idle", "charge"]:
		return true
	if state == "parry":
		return action_time >= 0.12
	if state == "attack":
		return action_time >= (QUICK_CANCEL_TIME if quick else ATTACK_WINDUP[combo_index] + ATTACK_ACTIVE[combo_index])
	if state == "heavy":
		return action_time >= HEAVY_WINDUP + HEAVY_ACTIVE
	return false

func _advance_loop(label: String, first: int, count: int, fps: float, delta: float, sheet: String) -> void:
	if animation_name != label:
		_loop_phase = 0.0
	play_animation(label, first, count, fps, true, sheet)
	_loop_phase += delta * fps
	seek_animation_pose(int(_loop_phase) % count)

func _seek_clip(time: float, duration: float, count: int) -> void:
	seek_animation_pose(clampi(int(time / duration * count), 0, count - 1))

func _seek_sword(time: float, windup: float, active: float, recovery: float, windup_pose: int = 0) -> void:
	# Twelve unique authored poses: four anticipation, four strike, four follow-through.
	# No label/clock resets at the damage boundary and no render-FPS dependency.
	var pose: int
	if time < windup:
		# Charging has already shown part of the heavy anticipation. On release
		# continue from that pose instead of visibly winding the body back again.
		var first := clampi(windup_pose, 0, 3)
		pose = first + clampi(int(time * float(4 - first) / windup), 0, 3 - first)
	elif time < windup + active:
		pose = 4 + clampi(int((time - windup) * 4.0 / active), 0, 3)
	else:
		pose = 8 + clampi(int((time - windup - active) * 4.0 / recovery), 0, 3)
	seek_animation_pose(pose)

func _tick_locomotion(delta: float, move_axis: float) -> void:
	guarding = control_lock <= 0.0 and Input.is_action_pressed("guard") and stamina > 1.0
	if guarding:
		play_animation("guard", 12, 6, 30.0, false, "hero_v2_defense")
		_seek_clip(_guard_time, 0.18, 6)
	var target := move_axis * SPEED * (0.28 if guarding else 1.0)
	velocity.x = move_toward(velocity.x, target, delta * (48.0 if is_on_floor() else 26.0))
	if absf(move_axis) > 0.1:
		facing = 1 if move_axis > 0.0 else -1
	visual_tilt = -float(facing) * 0.018 if absf(velocity.x) > 2.0 else 0.0
	if jump_buffer > 0.0 and coyote > 0.0:
		velocity.y = JUMP_SPEED
		jump_buffer = 0.0
		coyote = 0.0
		guarding = false
		squash = Vector2(0.91, 1.1)
		_jump_elapsed = 0.0
		_landing_time = 0.0
		game.audio.play_sfx("jump", 1.0)
		play_animation("jump", 6, 6, 12.0, false, "hero_v2_motion")
		seek_animation_pose(0)
	elif not is_on_floor():
		_jump_elapsed += delta
		play_animation("jump", 6, 6, 12.0, false, "hero_v2_motion")
		var pose := 1 if _jump_elapsed < 0.13 else (2 if velocity.y > 3.0 else (3 if absf(velocity.y) <= 3.0 else 4))
		seek_animation_pose(pose)
	elif _landing_time > 0.0 and animation_name == "jump":
		seek_animation_pose(5)
	elif not guarding:
		if absf(velocity.x) > 0.3:
			_advance_loop("run", 12, 12, 15.0 + absf(velocity.x), delta, "hero_v2_motion")
			_step_time += delta
			if _step_time > 0.30:
				_step_time = 0.0
				game.audio.play_sfx("step", 1.0 + randf_range(-0.06, 0.06))
		else:
			_advance_loop("idle", 0, 6, 8.0, delta, "hero_v2_motion")

func begin_attack(index: int) -> void:
	if dead or stamina < 7.0:
		return
	state = "attack"
	combo_index = clampi(index, 0, 2)
	action_time = 0.0
	_committed = false
	combo_queued = false
	guarding = false
	_roll_buffer = 0.0
	_hit_targets.clear()
	stamina = maxf(0.0, stamina - (10.0 if combo_index == 2 else 7.0))
	_regen_delay = 0.45
	animation_name = ""
	var sheet := "hero_v2_blade_a" if combo_index < 2 else "hero_v2_blade_b"
	var first := 12 if combo_index == 1 else 0
	var duration: float = ATTACK_WINDUP[combo_index] + ATTACK_ACTIVE[combo_index] + ATTACK_RECOVERY[combo_index]
	play_animation("attack_%d" % combo_index, first, 12, 12.0 / duration, false, sheet)

func begin_roll(quick: bool = false) -> void:
	var cost := QUICK_COST if quick else 20.0
	if dead or stamina < cost:
		return
	state = "quick_roll" if quick else "roll"
	action_time = 0.0
	guarding = false
	combo_queued = false
	_roll_buffer = 0.0
	_roll_cooldown = 0.08
	invulnerable = maxf(invulnerable, QUICK_IFRAMES if quick else 0.38)
	stamina -= cost
	_regen_delay = 0.45 if quick else 0.6
	game.audio.play_sfx("roll", 1.16 if quick else 1.0)
	animation_name = ""
	play_animation(state, 0, 12, 12.0 / (QUICK_DURATION if quick else 0.48), false, "hero_v2_defense")

func _tick_action(delta: float, move_axis: float) -> void:
	action_time += delta
	match state:
		"attack":
			var windup: float = ATTACK_WINDUP[combo_index]
			var active: float = ATTACK_ACTIVE[combo_index]
			_seek_sword(action_time, windup, active, ATTACK_RECOVERY[combo_index])
			velocity.x = move_toward(velocity.x, 0.0, 36.0 * delta)
			if action_time >= windup and action_time < windup + active:
				if not _committed:
					_committed = true
					attack_commits += 1
					game.audio.play_sfx("sword", 1.08 - combo_index * 0.12)
					game.effects.slash(global_position + Vector3(0, 1.1, 0.16), facing, Color(1.0, 0.88, 0.61), ATTACK_REACH[combo_index], combo_index == 1)
				var progress := (action_time - windup) / active
				velocity.x = float(facing) * (3.0 if combo_index == 2 else 1.65) * (1.0 - 0.25 * smoothstep(0.55, 1.0, progress))
				_hit_nearby(ATTACK_DAMAGE[combo_index], ATTACK_REACH[combo_index], 5.0)
			if action_time >= windup + active + ATTACK_RECOVERY[combo_index]:
				if combo_queued and combo_index < 2 and stamina >= 7.0:
					begin_attack(combo_index + 1)
				else:
					_finish_action()
		"charge":
			charge = minf(1.2, charge + delta)
			_seek_clip(minf(charge, 0.3), 0.3, 4)
			velocity.x = move_toward(velocity.x, move_axis * 0.8, delta * 32.0)
			visual_tilt = -float(facing) * 0.05
			if charge >= 0.65:
				_ghost_time += delta
				if _ghost_time >= 0.16:
					_ghost_time = 0.0
					game.effects.burst(global_position + Vector3(facing * 0.5, 1.45, 0.12), Color(0.96, 0.71, 0.30), 2)
			if not Input.is_action_pressed("heavy") or charge >= 1.2:
				_heavy_release_pose = clampi(animation_frame, 0, 3)
				state = "heavy"
				action_time = 0.0
				_committed = false
				_hit_targets.clear()
				stamina -= 26.0
				_regen_delay = 0.8
				play_animation("heavy", 12, 12, 12.0 / (HEAVY_WINDUP + HEAVY_ACTIVE + HEAVY_RECOVERY), false, "hero_v2_blade_b")
				seek_animation_pose(_heavy_release_pose)
		"heavy":
			_seek_sword(action_time, HEAVY_WINDUP, HEAVY_ACTIVE, HEAVY_RECOVERY, _heavy_release_pose)
			velocity.x = move_toward(velocity.x, 0.0, 35.0 * delta)
			if action_time >= HEAVY_WINDUP and action_time < HEAVY_WINDUP + HEAVY_ACTIVE:
				if not _committed:
					_committed = true
					attack_commits += 1
					game.audio.play_sfx("heavy", 0.9)
					game.effects.slash(global_position + Vector3(0, 1.35, 0.2), facing, Color(1.0, 0.75, 0.32), 3.6)
				velocity.x = float(facing) * 3.8
				_hit_nearby(48.0 + charge * 36.0, 3.6, 9.0)
			if action_time >= HEAVY_WINDUP + HEAVY_ACTIVE + HEAVY_RECOVERY:
				_finish_action()
		"roll", "quick_roll":
			var quick := state == "quick_roll"
			var duration := QUICK_DURATION if quick else 0.48
			_seek_clip(action_time, duration, 12)
			velocity.x = float(facing) * (lerpf(15.0, 7.0, smoothstep(0.0, duration, action_time)) if quick else (12.6 if action_time < 0.30 else 7.0))
			visual_tilt = 0.0
			if action_time >= duration:
				_finish_action()
		"parry", "block":
			var duration := PARRY_RECOVERY if state == "parry" else BLOCK_RECOVERY
			guarding = Input.is_action_pressed("guard") and stamina > 1.0
			_seek_clip(action_time, duration, 6)
			velocity.x = move_toward(velocity.x, 0.0, delta * 32.0)
			if action_time >= duration:
				_finish_action()
		"hurt":
			_seek_clip(action_time, 0.34, 6)
			velocity.x = move_toward(velocity.x, 0.0, 16.0 * delta)
			if action_time >= 0.34:
				_finish_action()
		"heal":
			_seek_clip(action_time, 0.94, 6)
			velocity.x = move_toward(velocity.x, 0.0, delta * 36.0)
			if action_time >= 0.5 and not _committed:
				_committed = true
				potions -= 1
				health = minf(max_health, health + 48.0)
				game.audio.play_sfx("heal", 1.0)
				game.effects.burst(global_position + Vector3(0, 1.1, 0.14), Color(0.71, 1.0, 0.69), 18)
			if action_time >= 0.94:
				_finish_action()

func _hit_nearby(damage: float, reach: float, force: float) -> void:
	for enemy in game.enemies.duplicate():
		if not is_instance_valid(enemy) or enemy.dead or _hit_targets.has(enemy.get_instance_id()):
			continue
		if is_ahead(enemy.global_position, reach, 2.75):
			_hit_targets[enemy.get_instance_id()] = true
			if enemy.take_damage(damage, global_position.x, force):
				game.effects.burst(enemy.global_position + Vector3(0, minf(1.4, enemy.body_height * 0.6), 0.2), Color(1.0, 0.80, 0.43), 9)
				game.shake(0.075 if state == "attack" else 0.17)
				game.hit_stop(0.024 if state == "attack" else 0.05)

func take_damage(amount: float, from_x: float, force: float = 5.0) -> bool:
	if dead or invulnerable > 0.0 or game.state != "playing":
		return false
	if guarding and (from_x - global_position.x) * facing >= -0.1:
		if _guard_time <= PARRY_WINDOW:
			parries += 1
			parry_invulnerable = PARRY_PROTECTION
			invulnerable = maxf(invulnerable, parry_invulnerable)
			state = "parry"
			action_time = 0.0
			combo_queued = false
			play_animation("parry", 18, 6, 6.0 / PARRY_RECOVERY, false, "hero_v2_defense")
			stamina = minf(max_stamina, stamina + 13.0)
			game.audio.play_sfx("parry", 1.0)
			game.effects.ring(global_position + Vector3(facing * 0.6, 1.0, 0.1), Color(1.0, 0.88, 0.48), 1.3)
			game.parry_nearby(from_x)
			game.hit_stop(0.045)
			return false
		var cost := maxf(14.0, amount * 1.25)
		if stamina >= cost:
			stamina -= cost
			_regen_delay = 0.6
			invulnerable = 0.16
			state = "block"
			action_time = 0.0
			play_animation("block", 12, 6, 6.0 / BLOCK_RECOVERY, false, "hero_v2_defense")
			velocity.x = -facing * 1.5
			game.audio.play_sfx("parry", 0.65)
			game.effects.burst(global_position + Vector3(facing * 0.5, 1.0, 0.1), Color(0.85, 0.85, 0.70), 5)
			return false
		stamina = 0.0
		guarding = false
	if not apply_damage(amount, from_x, force):
		return false
	guarding = false
	combo_queued = false
	_roll_buffer = 0.0
	invulnerable = 0.78
	action_time = 0.0
	state = "hurt"
	game.audio.play_sfx("hit", 0.8)
	game.hud.hit_flash()
	game.shake(0.15)
	animation_name = ""
	play_animation("hurt", 12, 6, 15.0, false, "hero_special")
	if dead:
		state = "dead"
		parry_invulnerable = 0.0
		game.on_player_died()
	return true

func _finish_action() -> void:
	var held_defense := state in ["parry", "block"] and Input.is_action_pressed("guard")
	state = "idle"
	action_time = 0.0
	visual_tilt = 0.0
	guarding = held_defense and stamina > 1.0