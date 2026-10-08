extends Node3D
## Pixel billboards standing on a real orthographic 3D stage.

const CAMERA_UP := Vector3(0.0, 0.70710678, -0.70710678)
const SCREEN_CENTER := Vector2(800.0, 500.0)
const PIXELS_PER_UNIT := 100.0

var actor_id: String = ""
var ground_position := Vector2.ZERO
var facing: String = "down"
var moving: bool = false
var is_player: bool = false
var sprite: Sprite3D
var shadow: Sprite3D
var frames: Dictionary = {}
var animation_clock: float = 0.0
var idle_clock: float = 0.0
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
			for index in range(4):
				strip.append(load("res://assets/sprites/traveler_%s_%d.png" % [direction, index]))
			frames[direction] = strip
	else:
		var strip: Array[Texture2D] = []
		for index in range(2):
			strip.append(load("res://assets/sprites/%s_%d.png" % [id, index]))
		frames["idle"] = strip
		idle_clock = float(id.hash() % 100) / 25.0
	_update_frame()


func set_ground_position(point: Vector2) -> void:
	ground_position = point
	position = ground_to_world(point)


func set_motion(motion: Vector2) -> void:
	var was_moving: bool = moving
	moving = motion.length_squared() > 0.001
	if moving:
		if absf(motion.x) > absf(motion.y):
			facing = "right" if motion.x > 0.0 else "left"
		else:
			facing = "down" if motion.y > 0.0 else "up"
	if moving != was_moving:
		animation_clock = 0.0
	_update_frame()


func set_highlight(active: bool) -> void:
	if sprite != null:
		sprite.modulate = Color(1.12, 1.10, 1.0) if active else Color.WHITE


func _process(delta: float) -> void:
	animation_clock += delta
	idle_clock += delta
	_update_frame()


func _update_frame() -> void:
	if sprite == null or frames.is_empty():
		return
	var direction: String = facing if is_player else "idle"
	var frame: int = (int(animation_clock * 9.0) % 4 if moving else 1) if is_player else (1 if fmod(idle_clock, 4.8) > 4.1 else 0)
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