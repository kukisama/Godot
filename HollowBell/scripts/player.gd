extends "res://scripts/actor.gd"
## Input-buffered, variable-height platforming and frame-committed sword combat.

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

var state := "idle"
var stamina := 100.0
var max_stamina := 100.0
var potions := 3
var guarding := false
var action_time := 0.0
var combo_index := 0
var combo_queued := false
var invulnerable := 0.0
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

func configure(owner_game: Node, spawn: Vector3) -> void:
	setup_actor(owner_game, "hero", 100.0, 0.0138, 2.0)
	process_mode = Node.PROCESS_MODE_PAUSABLE
	global_position = spawn
	control_lock = 0.2

func _process(delta: float) -> void:
	if not is_instance_valid(game) or game.state == "paused":
		return
	super._process(delta)
	if invulnerable > 0.0 and state != "roll":
		sprite.modulate.a = 0.6 + 0.4 * absf(sin(invulnerable * 35.0))
	if game.state == "title":
		play_animation("idle", 0, 6, 7.0, true, "hero_motion")

func _physics_process(delta: float) -> void:
	if not is_instance_valid(game) or game.state != "playing" or dead:
		return
	invulnerable = maxf(0.0, invulnerable - delta)
	control_lock = maxf(0.0, control_lock - delta)
	_regen_delay = maxf(0.0, _regen_delay - delta)
	jump_buffer = maxf(0.0, jump_buffer - delta)
	coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, coyote - delta)
	var move_axis := Input.get_axis("move_left", "move_right") if control_lock <= 0.0 else 0.0
	if control_lock <= 0.0 and Input.is_action_just_pressed("jump"):
		jump_buffer = JUMP_BUFFER
	if _regen_delay <= 0.0 and state not in ["charge", "heavy", "roll"]:
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
		squash = Vector2(1.12, 0.88)
		game.audio.play_sfx("land", 1.0)
		game.effects.burst(global_position + Vector3(0, 0.08, 0.2), Color(0.62, 0.65, 0.46), 5)
	_was_grounded = is_on_floor()
	if global_position.y < -6.0:
		game.on_player_fell()

func _read_actions(move_axis: float) -> void:
	if Input.is_action_just_pressed("dodge") and stamina >= 20.0 and state not in ["roll", "hurt", "heal"]:
		if state == "idle" or state == "charge" or (state == "attack" and action_time >= ATTACK_WINDUP[combo_index] + ATTACK_ACTIVE[combo_index]):
			if absf(move_axis) > 0.1:
				facing = 1 if move_axis > 0.0 else -1
			begin_roll()
			return
	if Input.is_action_just_pressed("light"):
		if state == "attack":
			combo_queued = true
		elif state == "idle" and stamina >= 7.0:
			begin_attack(0)
			return
	if state != "idle":
		return
	if Input.is_action_just_pressed("heavy") and stamina >= 26.0:
		state = "charge"
		charge = 0.0
		action_time = 0.0
		guarding = false
		play_animation("charge", 0, 2, 5.0, false, "hero_special")
	elif Input.is_action_just_pressed("heal") and potions > 0 and health < max_health:
		state = "heal"
		action_time = 0.0
		_committed = false
		guarding = false
		play_animation("heal", 18, 6, 6.5, false, "hero_special")

func _tick_locomotion(delta: float, move_axis: float) -> void:
	var previous_guard := guarding
	guarding = control_lock <= 0.0 and Input.is_action_pressed("guard") and stamina > 1.0
	if guarding:
		_guard_time = _guard_time + delta if previous_guard else 0.0
		play_animation("guard", 6, 4, 12.0, false, "hero_special")
	else:
		_guard_time = 0.0
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
		game.audio.play_sfx("jump", 1.0)
		play_animation("jump_rise", 13, 2, 8.0, false, "hero_motion")
	elif not is_on_floor():
		play_animation("jump_rise" if velocity.y > 1.0 else "jump_fall", 13 if velocity.y > 1.0 else 15, 2, 8.0, false, "hero_motion")
	elif not guarding:
		if absf(velocity.x) > 0.3:
			play_animation("run", 6, 6, 13.0 + absf(velocity.x) * 0.65, true, "hero_motion")
			_step_time += delta
			if _step_time > 0.30:
				_step_time = 0.0
				game.audio.play_sfx("step", 1.0 + randf_range(-0.06, 0.06))
		else:
			play_animation("idle", 0, 6, 7.0, true, "hero_motion")

func begin_attack(index: int) -> void:
	if dead or stamina < 7.0:
		return
	state = "attack"
	combo_index = clampi(index, 0, 2)
	action_time = 0.0
	_committed = false
	combo_queued = false
	guarding = false
	_hit_targets.clear()
	stamina = maxf(0.0, stamina - (10.0 if combo_index == 2 else 7.0))
	_regen_delay = 0.45
	animation_name = ""
	play_animation("attack_%d_tell" % combo_index, combo_index * 6, 2, 2.0 / ATTACK_WINDUP[combo_index], false, "hero_combat")

func begin_roll() -> void:
	state = "roll"
	action_time = 0.0
	guarding = false
	combo_queued = false
	invulnerable = 0.38
	stamina -= 20.0
	_regen_delay = 0.6
	game.audio.play_sfx("roll", 1.0)
	animation_name = ""
	play_animation("roll", 18, 6, 13.0, false, "hero_motion")

func _tick_action(delta: float, move_axis: float) -> void:
	action_time += delta
	match state:
		"attack":
			var windup: float = ATTACK_WINDUP[combo_index]
			var active: float = ATTACK_ACTIVE[combo_index]
			velocity.x = move_toward(velocity.x, 0.0, 36.0 * delta)
			if action_time >= windup and action_time < windup + active:
				if not _committed:
					_committed = true
					attack_commits += 1
					play_animation("attack_%d_hit" % combo_index, combo_index * 6 + 2, 2, 2.0 / active, false)
					game.audio.play_sfx("sword", 1.08 - combo_index * 0.12)
					game.effects.slash(global_position + Vector3(0, 1.1, 0.16), facing, Color(1.0, 0.88, 0.61), ATTACK_REACH[combo_index])
				velocity.x = float(facing) * (3.0 if combo_index == 2 else 1.65)
				_hit_nearby(ATTACK_DAMAGE[combo_index], ATTACK_REACH[combo_index], 5.0)
			elif action_time >= windup + active:
				play_animation("attack_%d_recover" % combo_index, combo_index * 6 + 4, 2, 10.0, false)
			if action_time >= windup + active + ATTACK_RECOVERY[combo_index]:
				if combo_queued and combo_index < 2 and stamina >= 7.0:
					begin_attack(combo_index + 1)
				else:
					_finish_action()
		"charge":
			charge = minf(1.2, charge + delta)
			velocity.x = move_toward(velocity.x, move_axis * 0.8, delta * 32.0)
			visual_tilt = -float(facing) * 0.05
			if charge >= 0.65:
				_ghost_time += delta
				if _ghost_time >= 0.16:
					_ghost_time = 0.0
					game.effects.burst(global_position + Vector3(facing * 0.5, 1.45, 0.12), Color(0.96, 0.71, 0.30), 2)
			if not Input.is_action_pressed("heavy") or charge >= 1.2:
				state = "heavy"
				action_time = 0.0
				_committed = false
				_hit_targets.clear()
				stamina -= 26.0
				_regen_delay = 0.8
				play_animation("heavy_tell", 2, 1, 6.0, false, "hero_special")
		"heavy":
			velocity.x = move_toward(velocity.x, 0.0, 35.0 * delta)
			if action_time >= 0.16 and action_time < 0.4:
				if not _committed:
					_committed = true
					attack_commits += 1
					play_animation("heavy_cut", 3, 2, 10.0, false)
					game.audio.play_sfx("heavy", 0.9)
					game.effects.slash(global_position + Vector3(0, 1.35, 0.2), facing, Color(1.0, 0.75, 0.32), 3.6)
				velocity.x = float(facing) * 3.8
				_hit_nearby(48.0 + charge * 36.0, 3.6, 9.0)
			elif action_time >= 0.4:
				play_animation("heavy_recover", 5, 1, 5.0, false)
			if action_time >= 0.78:
				_finish_action()
		"roll":
			velocity.x = float(facing) * (12.6 if action_time < 0.30 else 7.0)
			visual_tilt = 0.0
			if action_time >= 0.48:
				_finish_action()
		"hurt":
			velocity.x = move_toward(velocity.x, 0.0, 16.0 * delta)
			if action_time >= 0.34:
				_finish_action()
		"heal":
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
				game.hit_stop(0.045 if state == "attack" else 0.075)

func take_damage(amount: float, from_x: float, force: float = 5.0) -> bool:
	if dead or invulnerable > 0.0 or game.state != "playing":
		return false
	if guarding and (from_x - global_position.x) * facing >= -0.1:
		if _guard_time <= 0.17:
			parries += 1
			invulnerable = 0.25
			stamina = minf(max_stamina, stamina + 13.0)
			game.audio.play_sfx("parry", 1.0)
			game.effects.ring(global_position + Vector3(facing * 0.6, 1.0, 0.1), Color(1.0, 0.88, 0.48), 1.3)
			game.parry_nearby(from_x)
			game.hit_stop(0.07)
			return false
		var cost := maxf(14.0, amount * 1.25)
		if stamina >= cost:
			stamina -= cost
			_regen_delay = 0.6
			invulnerable = 0.16
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
		game.on_player_died()
	return true

func _finish_action() -> void:
	state = "idle"
	action_time = 0.0
	visual_tilt = 0.0
	guarding = false