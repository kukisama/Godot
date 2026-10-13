extends Node2D
## Additive candle bloom and drifting dust, drawn beneath the crisp interface.

var clock: float = 0.0
var glow: ImageTexture
var motes: Array[Dictionary] = []
var daylight: float = 0.0
var light_color := Color(1.0, 0.92, 0.80)
const LAMPS := [Vector2(201, 354), Vector2(620, 128), Vector2(800, 130), Vector2(980, 130), Vector2(1425, 405)]
const WINDOWS := [Vector2(460, 119), Vector2(1119, 119)]
const TEA_CUPS := [Vector2(171, 786), Vector2(1432, 789), Vector2(570, 240)]


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


func set_daylight(value: float, tint: Color) -> void:
	daylight = clampf(value, 0.0, 1.0)
	light_color = tint


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
	_draw_window_light()
	for index in range(LAMPS.size()):
		var radius: float = 140.0 if index == 0 else 82.0
		var pulse: float = 0.12 + 0.018 * sin(clock * 2.6 + index * 1.7) + 0.012 * sin(clock * 7.1)
		pulse *= lerpf(1.0, 0.38, daylight)
		draw_texture_rect(glow, Rect2(LAMPS[index] - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), false, Color(1.0, 0.51, 0.14, pulse))
	draw_texture_rect(glow, Rect2(1270, 245, 160, 160), false, Color(0.13, 0.60, 1.0, 0.18))
	_draw_steam()
	# Tiny embers rise from the painted fireplace, rather than across the room.
	for index in range(12):
		var rise: float = fmod(clock * (15.0 + index * 1.2) + index * 7.0, 72.0)
		var point := Vector2(203.0 + sin(clock * 1.1 + index) * 19.0, 371.0 - rise)
		draw_circle(point, 0.8 + float(index % 3) * 0.35, Color(1.0, 0.47, 0.12, (1.0 - rise / 72.0) * 0.45))
	for mote: Dictionary in motes:
		var alpha: float = 0.08 + 0.30 * pow((sin(clock + float(mote.phase)) + 1.0) / 2.0, 2.0)
		alpha *= lerpf(1.0, 0.7, daylight)
		var color: Color = Color(0.38, 0.75, 1.0, alpha) if bool(mote.blue) else Color(1.0, 0.78, 0.40, alpha)
		draw_circle(mote.position, float(mote.radius), color)


func _draw_window_light() -> void:
	for index in range(WINDOWS.size()):
		var source: Vector2 = WINDOWS[index]
		var landing := Vector2(660 if index == 0 else 985, 715)
		var breathe: float = 0.94 + 0.06 * sin(clock * 0.23 + index)
		# Nested low-opacity cones feather the edges without hiding floor detail.
		for band in range(5):
			var width: float = 54.0 + band * 20.0
			var points := PackedVector2Array([source + Vector2(-28, 0), source + Vector2(28, 0),
				landing + Vector2(width, 0), landing - Vector2(width, 0)])
			var color := Color(light_color.r, light_color.g, light_color.b, lerpf(0.003, 0.012, daylight) * breathe)
			draw_colored_polygon(points, color)
		draw_texture_rect(glow, Rect2(landing - Vector2(160, 66), Vector2(320, 132)), false,
			Color(light_color.r, light_color.g, light_color.b, daylight * 0.075))


func _draw_steam() -> void:
	for cup_index in range(TEA_CUPS.size()):
		for strand in range(3):
			var phase: float = fmod(clock * 0.22 + strand / 3.0 + cup_index * 0.17, 1.0)
			var points := PackedVector2Array()
			for segment in range(9):
				var height: float = segment * 3.7 + phase * 15.0
				var sway: float = sin(height * 0.18 - clock * 1.3 + strand) * (2.0 + height * 0.09)
				points.append(TEA_CUPS[cup_index] + Vector2(sway + strand * 3.0, -height))
			draw_polyline(points, Color(0.91, 0.86, 0.77, sin(phase * PI) * 0.13), 1.7, true)