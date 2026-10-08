extends SceneTree
## Reproducible production conversion; original generated images stay untouched.

const SPRITES := ["hero_motion", "hero_combat", "hero_special", "briar", "sentinel", "lancer", "arbalist", "cantor", "gargoyle", "warden", "boss"]
const PROPS := ["oak", "fir", "arch", "shrine", "ferns", "dead_tree", "torch", "banner"]
const SURFACES := ["moss", "stone", "earth", "flagstone", "brick", "wood"]
var failures := 0

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sprites")
	DirAccess.make_dir_recursive_absolute("res://assets/environment")
	for name: String in SPRITES:
		var image := _source(name)
		if image == null:
			continue
		_key(image)
		_save(image, "res://assets/sprites/" + name + ".png")
	for name: String in ["vista", "forest", "abbey"]:
		var image := _source(name)
		if image != null:
			_save(image, "res://assets/environment/" + name + ".png")
	var props := _source("props")
	if props != null:
		_key(props)
		for i in range(PROPS.size()):
			var tile := props.get_region(Rect2i((i % 4) * 384, (i / 4) * 512, 384, 512))
			_save(tile, "res://assets/environment/" + PROPS[i] + ".png")
	var surfaces := _source("surfaces")
	if surfaces != null:
		for i in range(SURFACES.size()):
			var tile := surfaces.get_region(Rect2i((i % 3) * 512, (i / 3) * 512, 512, 512))
			_save(tile, "res://assets/environment/" + SURFACES[i] + ".png")
	print("ASSET_CONVERSION failures=%d" % failures)
	quit(0 if failures == 0 else 1)

func _source(name: String) -> Image:
	var path := "res://assets/source/" + name + ".png"
	if not FileAccess.file_exists(path):
		push_error("Missing required source: " + path)
		failures += 1
		return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		failures += 1
		return null
	if image.get_size() != Vector2i(1536, 1024):
		push_error("Unexpected atlas dimensions for %s: %s" % [name, image.get_size()])
		failures += 1
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image

func _key(image: Image) -> void:
	# Work on packed bytes, preserving antialias coverage and removing key spill.
	var bytes := image.get_data()
	for i in range(0, bytes.size(), 4):
		var r := float(bytes[i]) / 255.0
		var g := float(bytes[i + 1]) / 255.0
		var b := float(bytes[i + 2]) / 255.0
		var excess := minf(r, b) - g
		if excess > 0.24 and r > 0.54 and b > 0.54:
			var coverage := 1.0 - smoothstep(0.24, 0.55, excess)
			bytes[i + 3] = int(float(bytes[i + 3]) * coverage)
			if coverage < 0.99:
				bytes[i] = int(minf(r, g + 0.16) * 255.0)
				bytes[i + 2] = int(minf(b, g + 0.19) * 255.0)
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, bytes)

func _save(image: Image, path: String) -> void:
	var result := image.save_png(path)
	if result != OK:
		failures += 1
		push_error("Could not save %s: %s" % [path, error_string(result)])
	else:
		print("PREPARED %s %s" % [path, image.get_size()])