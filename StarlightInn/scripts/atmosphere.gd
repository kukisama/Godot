extends Node2D
## Additive candle bloom and drifting dust, drawn beneath the crisp interface.

var clock: float = 0.0
var glow: ImageTexture
var motes: Array[Dictionary] = []
const LAMPS := [Vector2(201, 354), Vector2(620, 128), Vector2(800, 130), Vector2(980, 130), Vector2(1425, 405)]


func _ready() -> void:
	var blend := CanvasItemMaterial.new()
	blend.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = blend
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in range(128):
		for x in range(128):
			var d: float = Vector2((x - 63.5) / 63.5, (y - 63.5) / 63.5).length()
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, pow(maxf(0.0, 1.0 - d), 3.0)))
	glow = ImageTexture.create_from_image(image)
	var random := RandomNumberGenerator.new()
	random.seed = 1791
	for index in range(42):
		motes.append({"position": Vector2(random.randf_range(220, 1430), random.randf_range(130, 920)),
			"speed": random.randf_range(5, 13), "phase": random.randf() * TAU,
			"radius": random.randf_range(1.0, 2.4), "blue": index % 5 == 0})


func _process(delta: float) -> void:
	clock += delta
	for mote: Dictionary in motes:
		var point: Vector2 = mote.position
		point.y -= float(mote.speed) * delta
		point.x += sin(clock * 0.4 + float(mote.phase)) * delta * 5.0
		if point.y < 110.0:
			point.y = 935.0
		mote.position = point
	queue_redraw()


func _draw() -> void:
	if glow == null:
		return
	for index in range(LAMPS.size()):
		var radius: float = 140.0 if index == 0 else 82.0
		var pulse: float = 0.12 + 0.018 * sin(clock * 2.6 + index * 1.7) + 0.012 * sin(clock * 7.1)
		draw_texture_rect(glow, Rect2(LAMPS[index] - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), false, Color(1.0, 0.51, 0.14, pulse))
	draw_texture_rect(glow, Rect2(1270, 245, 160, 160), false, Color(0.13, 0.60, 1.0, 0.18))
	for mote: Dictionary in motes:
		var alpha: float = 0.08 + 0.30 * pow((sin(clock + float(mote.phase)) + 1.0) / 2.0, 2.0)
		var color: Color = Color(0.38, 0.75, 1.0, alpha) if bool(mote.blue) else Color(1.0, 0.78, 0.40, alpha)
		draw_circle(mote.position, float(mote.radius), color)