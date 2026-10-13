extends Node3D
## Pixel billboards standing on a real orthographic 3D stage.

const CAMERA_UP := Vector3(0.0, 0.70710678, -0.70710678)
const SCREEN_CENTER := Vector2(800.0, 500.0)
const PIXELS_PER_UNIT := 100.0

var actor_id: String = ""
var ground_position := Vector2.ZERO
var facing: String = "down"
var moving: bool = false
var conversing: bool = false
var is_player: bool = false
var sprite: Sprite3D
var shadow: Sprite3D
var frames: Dictionary = {}
var animation_clock: float = 0.0
var idle_clock: float = 0.0
var animation_rate: float = 14.0
var gesture: String = ""
var gesture_time: float = 0.0
var gesture_clock: float = 0.0
var ambient_tint := Color.WHITE
var highlighted: bool = false
var current_frame: int = -1
var current_direction: String = ""


static func ground_to_world(point: Vector2) -> Vector3:
	return Vector3((point.x - SCREEN_CENTER.x) / PIXELS_PER_UNIT, 0.0,
		(point.y - SCREEN_CENTER.y) / (PIXELS_PER_UNIT * 0.70710678))


func setup(id: String, player: bool = false) -> void:
	actor_id = id
	is_player = player
	name = id.capitalize()
	shadow = Sprite3D.new()
	shadow.texture = _shadow_texture()
	shadow.pixel_size = 0.0075
	shadow.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shadow.shaded = false
	shadow.position = CAMERA_UP * 0.02
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)
	sprite = Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.shaded = false
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sprite.pixel_size = 0.0115 if player else 0.0105
	sprite.position = CAMERA_UP * (56.0 if player else 68.0) * sprite.pixel_size
	add_child(sprite)
	if player:
		for direction: String in ["down", "left", "right", "up"]:
			var strip: Array[Texture2D] = []
			for index in range(8):
				strip.append(load("res://assets/sprites/traveler_%s_%d.png" % [direction, index]))
			frames[direction] = strip
	else:
		for direction: String in ["down", "left", "right", "up"]:
			var strip: Array[Texture2D] = []
			for index in range(8):
				strip.append(load("res://assets/sprites/%s_%s_%d.png" % [id, direction, index]))
			frames[direction] = strip
		for action: String in ["idle", "wave", "celebrate"]:
			var strip: Array[Texture2D] = []
			var first: int = 0 if action == "idle" else (4 if action == "wave" else 6)
			var count: int = 4 if action == "idle" else 2
			for index in range(count):
				strip.append(load("res://assets/sprites/%s_%d.png" % [id, first + index]))
			frames[action] = strip
		idle_clock = float(posmod(id.hash(), 100)) / 25.0
	_update_frame()


func set_ground_position(point: Vector2) -> void:
	ground_position = point
	position = ground_to_world(point)


func set_motion(motion: Vector2, delta: float = 1.0 / 60.0) -> void:
	var was_moving: bool = moving
	moving = motion.length_squared() > 0.001
	if moving:
		conversing = false
		gesture_time = 0.0
		var speed: float = motion.length() / maxf(delta, 0.001)
		var stride: float = 128.0 if is_player else 90.0
		animation_rate = clampf(speed / stride * 8.0, 6.0, 24.0)
		if absf(motion.x) > absf(motion.y):
			facing = "right" if motion.x > 0.0 else "left"
		else:
			facing = "down" if motion.y > 0.0 else "up"
	if moving != was_moving:
		animation_clock = 0.0
	_update_frame()


func set_conversation(active: bool, look_at: Vector2 = Vector2.ZERO) -> void:
	conversing = active
	set_motion(Vector2.ZERO)
	gesture_time = 0.0
	if active:
		var direction: Vector2 = look_at - ground_position
		if direction.length_squared() > 0.001:
			if absf(direction.x) > absf(direction.y):
				facing = "right" if direction.x > 0.0 else "left"
			else:
				facing = "down" if direction.y > 0.0 else "up"
	_update_frame()


func set_highlight(active: bool) -> void:
	highlighted = active
	_refresh_tint()


func set_ambient_tint(value: Color) -> void:
	ambient_tint = value
	_refresh_tint()


func _refresh_tint() -> void:
	if sprite != null:
		sprite.modulate = ambient_tint * (Color(1.12, 1.10, 1.0) if highlighted else Color.WHITE)


func play_gesture(action: String, duration: float = 1.7) -> void:
	if is_player or not frames.has(action):
		return
	set_motion(Vector2.ZERO)
	gesture = action
	gesture_time = duration
	gesture_clock = 0.0
	_update_frame()


func _process(delta: float) -> void:
	animation_clock += delta
	idle_clock += delta
	gesture_clock += delta
	gesture_time = maxf(0.0, gesture_time - delta)
	_update_frame()
	if sprite != null:
		var lift: float = 0.6 * sin(idle_clock * 2.0)
		if moving:
			lift = absf(sin(animation_clock * animation_rate * TAU / 8.0)) * 1.2
		elif gesture_time > 0.0 and gesture == "celebrate" and actor_id in ["eve", "finn"]:
			lift = maxf(0.0, sin(gesture_clock * PI / 0.8)) * (14.0 if actor_id == "finn" else 9.0)
		sprite.position = CAMERA_UP * ((56.0 if is_player else 68.0) + lift) * sprite.pixel_size
		shadow.scale = Vector3.ONE * (1.0 - maxf(0.0, lift) * 0.012)
		shadow.modulate.a = 1.0 - maxf(0.0, lift) * 0.02


func _update_frame() -> void:
	if sprite == null or frames.is_empty():
		return
	var direction: String = facing if moving or is_player or conversing else (gesture if gesture_time > 0.0 else "idle")
	var frame: int = 1 if is_player or conversing else 0
	if moving:
		frame = int(animation_clock * animation_rate) % frames[direction].size()
	elif not is_player and not conversing:
		if gesture_time > 0.0:
			frame = int(gesture_clock * 7.0) % frames[direction].size()
		else:
			var phase: float = fmod(idle_clock, 7.2)
			frame = 0 if phase < 5.0 else (1 if phase < 5.18 else (2 if phase < 6.25 else 3))
	if current_frame != frame or current_direction != direction:
		current_frame = frame
		current_direction = direction
		sprite.texture = frames[direction][frame]


static func _shadow_texture() -> ImageTexture:
	var image := Image.create(128, 48, false, Image.FORMAT_RGBA8)
	for y in range(48):
		for x in range(128):
			var distance: float = Vector2((x - 63.5) / 63.5, (y - 23.5) / 23.5).length()
			image.set_pixel(x, y, Color(0.015, 0.012, 0.02, pow(maxf(0.0, 1.0 - distance), 1.4) * 0.48))
	return ImageTexture.create_from_image(image)