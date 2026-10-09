extends SceneTree
## Dedicated production asset integration, no editor, .import or QA image writes.
## --headless --path HollowBell --script res://tests/test_assets.gd
## Converts ONCE between SHA snapshots, then decodes the actual saved PNGs.
## Pixel/frame differences verify content, NOT nuanced animation quality.

const Converter = preload("res://tools/prepare_assets.gd")
const SPRITES: Array[String] = ["hero_motion", "hero_combat", "hero_special", "briar", "sentinel", "lancer", "arbalist", "cantor", "gargoyle", "warden", "boss"]
const HERO_V2: Array[String] = ["hero_v2_motion", "hero_v2_blade_a", "hero_v2_blade_b", "hero_v2_defense"]
const PROPS: Array[String] = ["oak", "fir", "arch", "shrine", "ferns", "dead_tree", "torch", "banner"]
const SURFACES: Array[String] = ["moss", "stone", "earth", "flagstone", "brick", "wood"]
const BACKDROPS: Array[String] = ["vista", "forest", "abbey"]
const SIZE: Vector2i = Vector2i(1536, 1024)

var checks: int = 0
var failures: int = 0
var totals: Dictionary = {"frames": 0, "opaque_pixels": 0, "connected_key_pixels": 0,
	"gutter_pixels": 0, "empty_frames": 0, "identical_animation_pairs": 0,
	"dark_key_cleared": 0, "recovered_cross_cell_pixels": 0}


func _initialize() -> void:
	_run()
	_check(int(totals["frames"]) == 272, "suite reached every real sprite frame and prop", totals["frames"])
	print("ASSET_TEST_SUMMARY " + JSON.stringify({"checks": checks, "failures": failures, "actual": totals,
		"scope": "saved PNG pixel/matte/content tests, not a motion-quality or reimported game-render claim"}))
	quit(0 if failures == 0 else 1)


func _run() -> void:
	var sources_before: Dictionary = _hashes("res://assets/source", ".png")
	_check(sources_before.size() == 16, "exactly 16 original PNGs before conversion", sources_before.size())
	# Root-only enumeration deliberately excludes nested hero_v2_candidates.
	# V2 is already published by its own tool; never invoke that converter here.
	var v2_before: Dictionary = {}
	for name: String in HERO_V2:
		var path: String = "res://assets/sprites/" + name + ".png"
		_check(FileAccess.file_exists(path), "required published v2 sheet " + name, path)
		if FileAccess.file_exists(path):
			v2_before[name + ".png"] = FileAccess.get_sha256(path)
	for name: String in SPRITES + BACKDROPS + ["props", "surfaces"]:
		_check(sources_before.has(name + ".png"), "required original " + name, sources_before.get(name + ".png", "MISSING"))
	_test_key_fixture()
	_test_cross_cell_fixture()
	if failures > 0:
		return
	var immutable_before: Dictionary = {}
	for name: String in BACKDROPS + SURFACES:
		var path: String = "res://assets/environment/" + name + ".png"
		if FileAccess.file_exists(path):
			immutable_before[path] = FileAccess.get_sha256(path)
	var imports_before: Dictionary = _import_hashes()
	var started: int = Time.get_ticks_msec()
	var conversion: Dictionary = Converter.convert_all()
	_check(conversion["errors"].is_empty() and int(conversion["outputs"]) == 28,
		"single production conversion creates 28 expected outputs", {"outputs": conversion["outputs"],
		"errors": conversion["errors"], "elapsed_ms": Time.get_ticks_msec() - started})
	var sources_after: Dictionary = _hashes("res://assets/source", ".png")
	_check(sources_after == sources_before, "all original source bytes unchanged", {"before_count": sources_before.size(), "after_count": sources_after.size()})
	for name: String in sources_before:
		_check(sources_after.get(name) == sources_before[name], "SOURCE_SHA256 " + name,
			{"before": sources_before[name], "after": sources_after.get(name, "MISSING")})
	for path: String in immutable_before:
		_check(FileAccess.get_sha256(path) == immutable_before[path], "background/surface PNG bytes untouched " + path,
			{"before": immutable_before[path], "after": FileAccess.get_sha256(path)})
	_check(_import_hashes() == imports_before, "no .import modified or created", {"count": imports_before.size()})
	if not conversion["errors"].is_empty():
		return
	var sprite_files: Dictionary = _hashes("res://assets/sprites", ".png")
	var legacy_sprite_files: Dictionary = {}
	for name: String in sprite_files:
		if not name.begins_with("hero_v2_"):
			legacy_sprite_files[name] = sprite_files[name]
	var environment_files: Dictionary = _hashes("res://assets/environment", ".png")
	_check(legacy_sprite_files.size() == 11 and environment_files.size() == 17,
		"exact legacy generated file count", {"legacy_sprites": legacy_sprite_files.size(), "environment": environment_files.size(),
		"sprite_names": sprite_files.keys(), "environment_names": environment_files.keys()})
	_check(sprite_files.size() == 15, "11 legacy plus 4 published v2 sprite sheets", sprite_files.size())
	for name: String in SPRITES:
		_test_sprite(name, conversion["layouts"][name])
	for name: String in PROPS:
		var image: Image = _load("res://assets/environment/" + name + ".png")
		if image == null:
			continue
		_check(image.get_size() == Vector2i(384, 512), "prop dimensions " + name, image.get_size())
		_check_frame(name, 0, image, 4000)
		if name == "oak" or name == "fir":
			_test_foliage_edges(name, image)
	for name: String in BACKDROPS:
		var original: Image = _load("res://assets/source/" + name + ".png")
		var output: Image = _load("res://assets/environment/" + name + ".png")
		if original != null and output != null:
			_check(output.get_size() == SIZE and output.get_data() == original.get_data(),
				"backdrop pixel-for-pixel passthrough " + name, output.get_size())
	var surfaces: Image = _load("res://assets/source/surfaces.png")
	for index: int in range(SURFACES.size()):
		var output: Image = _load("res://assets/environment/" + SURFACES[index] + ".png")
		if surfaces == null or output == null:
			continue
		var origin: Vector2i = Vector2i(index % 3, floori(float(index) / 3.0)) * 512
		var expected: Image = surfaces.get_region(Rect2i(origin, Vector2i(512, 512)))
		_check(output.get_size() == Vector2i(512, 512) and output.get_data() == expected.get_data(),
			"surface exact source crop " + SURFACES[index], output.get_size())
	for name: String in conversion["layouts"]:
		var layout: Dictionary = conversion["layouts"][name]
		var metric: Dictionary = conversion["metrics"][name]
		var width: float = 384.0 if name == "props" else 256.0
		var height: float = 512.0 if name == "props" else 256.0
		var scale: float = float(layout["scale"])
		var limits: Array[float] = [float(layout["offset_x"]) + scale * float(layout["x_min"]),
			float(layout["offset_x"]) + scale * float(layout["x_max"]),
			float(layout["target_y"]) + scale * float(layout["y_min"]),
			float(layout["target_y"]) + scale * float(layout["y_max"])]
		_check(scale > 0.5 and scale <= 1.0 and limits[0] >= 1.999 and limits[1] <= width - 1.999
			and limits[2] >= 1.999 and limits[3] <= height - 1.999,
			"all recovered source bounds fit without crop " + name, {"scale": scale, "limits": limits})
		totals["dark_key_cleared"] += int(metric["dark_key_cleared"])
		totals["recovered_cross_cell_pixels"] += int(metric["recovered_cross_cell_pixels"])
	_check(int(totals["dark_key_cleared"]) > 1000, "actual dark halo pixels removed", totals["dark_key_cleared"])
	_check(int(conversion["metrics"]["props"]["recovered_cross_cell_pixels"]) > 500
		and int(conversion["metrics"]["boss"]["recovered_cross_cell_pixels"]) > 4000,
		"actual oak/finial and boss overflow recovered", {"props": conversion["metrics"]["props"], "boss": conversion["metrics"]["boss"]})
	var hero_layout: Dictionary = conversion["layouts"]["hero_motion"]
	for name: String in ["hero_combat", "hero_special"]:
		var other: Dictionary = conversion["layouts"][name]
		_check(hero_layout["scale"] == other["scale"] and hero_layout["offset_x"] == other["offset_x"],
			"stable hero size/anchor across sheets " + name, [other["scale"], other["offset_x"]])
	_check(hero_layout["baselines"][2] == hero_layout["baselines"][0]
		and hero_layout["baselines"][3] == hero_layout["baselines"][0],
		"jump/roll use standing reference, never per-frame bottom alignment", hero_layout["baselines"])
	_test_palette("hero_motion", hero_layout, false)
	_test_palette("cantor", conversion["layouts"]["cantor"], true)
	_test_jump_arc()
	for name: String in HERO_V2:
		_check(sprite_files.has(name + ".png") and FileAccess.get_sha256("res://assets/sprites/" + name + ".png") == v2_before.get(name + ".png", "MISSING"),
			"legacy conversion leaves published v2 bytes untouched " + name, sprite_files.get(name + ".png", "MISSING"))
	_check(_hashes("res://assets/source", ".png") == sources_before and _import_hashes() == imports_before,
		"sources and imports still unchanged after all inspections", {"sources": sources_before.size(), "imports": imports_before.size()})


func _check(ok: bool, label: String, actual: Variant) -> void:
	checks += 1
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + label + " " + JSON.stringify(actual))


func _hashes(directory: String, suffix: String) -> Dictionary:
	var result: Dictionary = {}
	var names: PackedStringArray = DirAccess.get_files_at(directory)
	names.sort()
	for name: String in names:
		if name.ends_with(suffix):
			result[name] = FileAccess.get_sha256(directory.path_join(name))
	return result


func _import_hashes() -> Dictionary:
	var result: Dictionary = {}
	for directory: String in ["source", "sprites", "environment"]:
		var hashes: Dictionary = _hashes("res://assets/" + directory, ".import")
		for name: String in hashes:
			result[directory.path_join(name)] = hashes[name]
	return result


func _load(path: String) -> Image:
	var image: Image = Image.new()
	var error: Error = image.load(ProjectSettings.globalize_path(path))
	if error != OK or image.is_empty():
		_check(false, "decode " + path, error)
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image


func _test_key_fixture() -> void:
	var image: Image = Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color.from_rgba8(248, 2, 247))
	image.fill_rect(Rect2i(0, 1, 16, 4), Color.from_rgba8(43, 1, 48))
	image.fill_rect(Rect2i(10, 12, 44, 40), Color.from_rgba8(34, 104, 59))
	image.fill_rect(Rect2i(12, 16, 12, 14), Color.from_rgba8(107, 12, 39))
	image.fill_rect(Rect2i(36, 16, 14, 14), Color.from_rgba8(73, 48, 91))
	# Magenta-ish foreground glow is disconnected from the backing by a solid
	# object. It must survive even though its hue resembles a dark screen pixel.
	image.fill_rect(Rect2i(26, 33, 6, 6), Color.from_rgba8(148, 20, 156))
	image.fill_rect(Rect2i(38, 34, 6, 6), Color.from_rgba8(248, 2, 247))
	# A known 50% backing/leaf mixture next to the transparent background.
	image.fill_rect(Rect2i(9, 35, 1, 9), Color.from_rgba8(141, 53, 153))
	var before: PackedByteArray = image.get_data()
	var metrics: Dictionary = Converter.key_image(image, Vector2i(64, 64))
	var after: PackedByteArray = image.get_data()
	_check(image.get_pixel(1, 2).a == 0.0 and image.get_pixel(0, 0).a == 0.0,
		"fixture connected bright/dark backing cleared", metrics)
	_check(image.get_pixel(40, 36).a == 0.0, "fixture enclosed flat key hole cleared", image.get_pixel(40, 36))
	for point: Vector2i in [Vector2i(16, 20), Vector2i(42, 22), Vector2i(28, 35)]:
		var i: int = (point.y * 64 + point.x) * 4
		_check(before.slice(i, i + 4) == after.slice(i, i + 4),
			"fixture burgundy/purple/object glow preserved " + str(point), image.get_pixelv(point))
	var edge: Color = image.get_pixel(9, 39)
	_check(absf(edge.a - 0.5) < 0.02 and edge.g > edge.r and edge.g > edge.b,
		"fixture transparent-neighbor spill unmixed with coverage", edge)
	# Repeat on a fixed-color interior: correction must not grow inward or
	# desaturate a dark native purple simply because it touches transparency.
	var robe: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	robe.fill(Color.from_rgba8(248, 2, 247))
	robe.fill_rect(Rect2i(7, 7, 18, 18), Color.from_rgba8(73, 48, 91))
	Converter.key_image(robe, Vector2i(32, 32))
	_check(robe.get_pixel(7, 16) == Color.from_rgba8(73, 48, 91),
		"fixture genuine purple at silhouette is not gray/desaturated", robe.get_pixel(7, 16))
	var leaf: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	leaf.fill(Color.from_rgba8(248, 2, 247))
	leaf.fill_rect(Rect2i(8, 8, 16, 16), Color.from_rgba8(238, 172, 30))
	leaf.fill_rect(Rect2i(7, 11, 1, 10), Color.from_rgba8(243, 87, 139))
	Converter.key_image(leaf, Vector2i(32, 32))
	var warm: Color = leaf.get_pixel(7, 16)
	_check(warm.r > warm.g and warm.g > warm.b * 3.0 and absf(warm.a - 0.5) < 0.02,
		"fixture warm yellow-leaf pink fringe is unmixed, not excluded by red/blue imbalance", warm)
	var needle: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	needle.fill(Color.from_rgba8(248, 2, 247))
	needle.fill_rect(Rect2i(15, 5, 1, 22), Color.from_rgba8(35, 115, 74))
	needle.fill_rect(Rect2i(14, 8, 1, 16), Color.from_rgba8(153, 61, 173))
	Converter.key_image(needle, Vector2i(32, 32))
	var thin: Color = needle.get_pixel(14, 16)
	_check(thin.g > thin.r and thin.g > thin.b and thin.a > 0.3 and thin.a < 0.8,
		"fixture single-pixel needle can use a clean adjacent needle as reference", thin)
	var foliage: Image = Image.create(96, 32, false, Image.FORMAT_RGBA8)
	foliage.fill(Color.TRANSPARENT)
	for column: int in range(3):
		foliage.fill_rect(Rect2i(column * 32 + 8, 8, 16, 16), Color.from_rgba8(158, 40, 216))
	var foliage_before: PackedByteArray = foliage.get_data()
	var corrected: int = Converter.despill_foliage_rims(foliage, Vector2i(32, 32))
	var alpha_changed: int = 0
	var foliage_after: PackedByteArray = foliage.get_data()
	for i: int in range(3, foliage_before.size(), 4):
		if foliage_before[i] != foliage_after[i]:
			alpha_changed += 1
	_check(corrected > 0 and alpha_changed == 0 and foliage.get_pixel(15, 15) == Color.from_rgba8(158, 40, 216)
		and foliage.get_pixel(72, 16) == Color.from_rgba8(158, 40, 216),
		"fixture foliage override never erodes alpha, core or other prop/actor material", {"corrected": corrected, "alpha_changed": alpha_changed})


func _test_cross_cell_fixture() -> void:
	var image: Image = Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.from_rgba8(248, 2, 247))
	image.fill_rect(Rect2i(6, 7, 21, 19), Color.from_rgba8(28, 140, 44))
	image.fill_rect(Rect2i(26, 15, 12, 3), Color.from_rgba8(28, 140, 44))
	image.fill_rect(Rect2i(39, 16, 2, 2), Color.from_rgba8(28, 140, 44))
	image.fill_rect(Rect2i(46, 7, 13, 19), Color.from_rgba8(42, 101, 178))
	var extraction: Dictionary = Converter.extract_atlas(image, Vector2i(32, 32))
	var owners: PackedInt32Array = extraction["owners"]
	_check(owners[16 * 64 + 36] == 0 and owners[16 * 64 + 39] == 0 and owners[16 * 64 + 50] == 1,
		"fixture crossing limb and detached tip assigned to original body", extraction["metrics"])
	var layout: Dictionary = Converter.plan_layout("fixture", extraction, Vector2i(32, 32))
	var output: Image = Converter.render_atlas(extraction, layout, Vector2i(32, 32))
	var contamination: int = 0
	var tips: int = 0
	for y: int in range(32):
		for x: int in range(64):
			var color: Color = output.get_pixel(x, y)
			if x >= 32 and color.a > 0.0 and color.g > color.b:
				contamination += 1
			if x < 32 and x >= 26 and color.a > 0.0:
				tips += 1
	_check(contamination == 0 and tips > 0, "fixture recovered tip is not cut or duplicated in adjacent cell",
		{"neighbor_contamination": contamination, "recovered_tip_pixels": tips, "layout": layout})
	var particles: Image = Image.create(64, 32, false, Image.FORMAT_RGBA8)
	particles.fill(Color.from_rgba8(248, 2, 247))
	particles.fill_rect(Rect2i(8, 8, 16, 16), Color.from_rgba8(28, 140, 44))
	particles.fill_rect(Rect2i(41, 12, 2, 2), Color.from_rgba8(238, 182, 43))
	particles.fill_rect(Rect2i(48, 16, 2, 2), Color.from_rgba8(238, 182, 43))
	particles.fill_rect(Rect2i(54, 22, 1, 2), Color.from_rgba8(238, 182, 43))
	var dissolved: Dictionary = Converter.extract_atlas(particles, Vector2i(32, 32))
	var particle_owners: PackedInt32Array = dissolved["owners"]
	_check(particle_owners[12 * 64 + 41] == 1 and particle_owners[16 * 64 + 48] == 1
		and particle_owners[22 * 64 + 54] == 1, "fixture all-small dissolution frame keeps its own fragments", dissolved["metrics"])
	var rows: Image = Image.create(32, 64, false, Image.FORMAT_RGBA8)
	rows.fill(Color.from_rgba8(248, 2, 247))
	rows.fill_rect(Rect2i(8, 20, 16, 10), Color.from_rgba8(28, 140, 44))
	rows.fill_rect(Rect2i(8, 58, 16, 5), Color.from_rgba8(42, 101, 178))
	rows.fill_rect(Rect2i(12, 42, 2, 2), Color.from_rgba8(238, 182, 43))
	var row_extraction: Dictionary = Converter.extract_atlas(rows, Vector2i(32, 32))
	var row_owners: PackedInt32Array = row_extraction["owners"]
	_check(row_owners[42 * 32 + 12] == 1, "fixture distant spark stays in its row despite nearer previous-frame feet",
		row_extraction["metrics"])


@warning_ignore("integer_division")
func _test_sprite(name: String, layout: Dictionary) -> void:
	var image: Image = _load("res://assets/sprites/" + name + ".png")
	if image == null:
		return
	_check(image.get_size() == SIZE, "6x4 256-cell sprite dimensions " + name, image.get_size())
	if image.get_size() != SIZE:
		return
	var frames: Array[Image] = []
	for frame: int in range(24):
		var tile: Image = image.get_region(Rect2i((frame % 6) * 256, (frame / 6) * 256, 256, 256))
		frames.append(tile)
		_check_frame(name, frame, tile, 1000)
	for row: int in range(4):
		var minimum_changed: int = 65536
		var maximum_changed: int = 0
		var minimum_silhouette: int = 65536
		var duplicates: int = 0
		for first: int in range(6):
			for second: int in range(first + 1, 6):
				var a: PackedByteArray = frames[row * 6 + first].get_data()
				var b: PackedByteArray = frames[row * 6 + second].get_data()
				var changed: int = 0
				var silhouette: int = 0
				for i: int in range(0, a.size(), 4):
					if (a[i + 3] >= 96) != (b[i + 3] >= 96):
						silhouette += 1
					if maxi(a[i + 3], b[i + 3]) >= 96 and (absi(a[i + 3] - b[i + 3]) >= 32
						or absi(a[i] - b[i]) + absi(a[i + 1] - b[i + 1]) + absi(a[i + 2] - b[i + 2]) >= 36):
						changed += 1
				minimum_changed = mini(minimum_changed, changed)
				maximum_changed = maxi(maximum_changed, changed)
				minimum_silhouette = mini(minimum_silhouette, silhouette)
				if changed == 0:
					duplicates += 1
		totals["identical_animation_pairs"] += duplicates
		_check(duplicates == 0 and minimum_changed >= 64, "ANIMATION_CONTENT " + name + " row=" + str(row),
			{"pairs": 15, "min_changed_visible_pixels": minimum_changed, "max_changed_visible_pixels": maximum_changed,
			"min_silhouette_difference": minimum_silhouette, "identical_pairs": duplicates,
			"note": "content/pose differences only; not a nuanced-motion score", "sheet_scale": layout["scale"]})


func _check_frame(name: String, frame: int, image: Image, minimum_opaque: int) -> void:
	var metrics: Dictionary = _frame_metrics(image)
	metrics["frame"] = frame
	totals["frames"] += 1
	totals["opaque_pixels"] += int(metrics["opaque"])
	totals["connected_key_pixels"] += int(metrics["connected_key"])
	totals["gutter_pixels"] += int(metrics["gutter"])
	if int(metrics["visible"]) == 0:
		totals["empty_frames"] += 1
	_check(int(metrics["opaque"]) >= minimum_opaque and int(metrics["visible"]) < image.get_width() * image.get_height() * 0.9
		and int(metrics["colors"]) >= 64 and int(metrics["gutter"]) == 0
		and int(metrics["connected_key"]) == 0 and int(metrics["flat_key"]) == 0
		and int(metrics["hidden_rgb"]) == 0, "FRAME " + name, metrics)


func _test_foliage_edges(name: String, image: Image) -> void:
	var bytes: PackedByteArray = image.get_data()
	var width: int = image.get_width()
	var height: int = image.get_height()
	var residue: int = 0
	var examples: Array[Dictionary] = []
	for y: int in range(height):
		for x: int in range(width):
			var i: int = (y * width + x) * 4
			var low: int = mini(bytes[i], bytes[i + 2])
			if bytes[i + 3] < 96 or low - bytes[i + 1] < 20 or bytes[i] > bytes[i + 2] * 2:
				continue
			var near_clear: bool = false
			for dy: int in range(-2, 3):
				for dx: int in range(-2, 3):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx >= 0 and nx < width and ny >= 0 and ny < height and bytes[(ny * width + nx) * 4 + 3] == 0:
						near_clear = true
			if near_clear:
				residue += 1
				if examples.size() < 8:
					examples.append({"x": x, "y": y, "rgba": Array(bytes.slice(i, i + 4))})
	_check(residue == 0, "foliage has no strong warm/blue magenta rim " + name,
		{"remaining_visible_rim_pixels": residue, "examples": examples})


@warning_ignore("integer_division")
func _frame_metrics(image: Image) -> Dictionary:
	var data: PackedByteArray = image.get_data()
	var width: int = image.get_width()
	var height: int = image.get_height()
	var count: int = width * height
	var visible: int = 0
	var opaque: int = 0
	var gutter: int = 0
	var flat_key: int = 0
	var hidden_rgb: int = 0
	var colors: Dictionary = {}
	var traversable: PackedByteArray = PackedByteArray()
	traversable.resize(count)
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(count)
	var queue: PackedInt32Array = PackedInt32Array()
	queue.resize(count)
	var tail: int = 0
	for pixel: int in range(count):
		var i: int = pixel * 4
		var r: int = data[i]
		var g: int = data[i + 1]
		var b: int = data[i + 2]
		var alpha: int = data[i + 3]
		var x: int = pixel % width
		var y: int = pixel / width
		if alpha > 0:
			visible += 1
			if alpha == 255:
				opaque += 1
			if x < 2 or x >= width - 2 or y < 2 or y >= height - 2:
				gutter += 1
			colors[(r << 16) | (g << 8) | b] = true
			if r >= 220 and b >= 220 and g <= 18 and absi(r - b) <= 24:
				flat_key += 1
		elif r != 0 or g != 0 or b != 0:
			hidden_rgb += 1
		# Independent, deliberately high-confidence residual-screen predicate.
		# It is not "all purple": cloth with green/blue bias is legitimate art.
		var low: int = mini(r, b)
		var high: int = maxi(r, b)
		var screen: bool = low - g >= 20 and g * 3 <= low and high - low <= maxi(8, int(high * 0.18))
		if alpha == 0 or screen:
			traversable[pixel] = 1
			if x == 0 or x == width - 1 or y == 0 or y == height - 1:
				visited[pixel] = 1
				queue[tail] = pixel
				tail += 1
	var head: int = 0
	var connected_key: int = 0
	while head < tail:
		var pixel: int = queue[head]
		head += 1
		if data[pixel * 4 + 3] > 0:
			connected_key += 1
		var x: int = pixel % width
		var y: int = pixel / width
		for ny: int in range(maxi(0, y - 1), mini(height, y + 2)):
			for nx: int in range(maxi(0, x - 1), mini(width, x + 2)):
				var other: int = ny * width + nx
				if traversable[other] == 1 and visited[other] == 0:
					visited[other] = 1
					queue[tail] = other
					tail += 1
	var bounds: Rect2i = image.get_used_rect()
	return {"visible": visible, "opaque": opaque, "colors": colors.size(), "gutter": gutter,
		"flat_key": flat_key, "connected_key": connected_key, "hidden_rgb": hidden_rgb,
		"bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y]}


@warning_ignore("integer_division")
func _test_palette(name: String, layout: Dictionary, purple: bool) -> void:
	var original: Image = _load("res://assets/source/" + name + ".png")
	var output: Image = _load("res://assets/sprites/" + name + ".png")
	if original == null or output == null:
		return
	var before: PackedByteArray = original.get_data()
	var after: PackedByteArray = output.get_data()
	var scale: float = float(layout["scale"])
	var samples: int = 0
	var changed: int = 0
	for frame: int in range(24):
		var row: int = frame / 6
		var column: int = frame % 6
		for y: int in range(2, 254):
			var sy: int = row * 256 + floori((y + 0.5 - float(layout["target_y"])) / scale + float(layout["baselines"][row]))
			if sy < row * 256 + 16 or sy >= row * 256 + 240:
				continue
			for x: int in range(2, 254):
				var sx: int = column * 256 + floori((x + 0.5 - float(layout["offset_x"])) / scale + 128.0)
				# Body-interior ROI, independently of the converter's owner mask:
				# the overflowing limb of an ADJACENT frame is not this robe/cape.
				if sx < column * 256 + 32 or sx >= column * 256 + 224:
					continue
				var i: int = (sy * 1536 + sx) * 4
				var r: int = before[i]
				var g: int = before[i + 1]
				var b: int = before[i + 2]
				var protected: bool = b >= r + 8 and r >= g + 8 and g >= 24 and b <= 165 if purple else r >= 60 and r > b * 2 and g < r * 0.45 and b >= 12
				if not protected:
					continue
				var interior: bool = true
				for dy: int in range(-3, 4):
					for dx: int in range(-3, 4):
						var j: int = ((sy + dy) * 1536 + sx + dx) * 4
						var low: int = mini(before[j], before[j + 2])
						if before[j + 3] == 0 or low - before[j + 1] >= 35 and before[j + 1] * 2 < low:
							interior = false
							break
					if not interior:
						break
				if not interior:
					continue
				samples += 1
				var j: int = ((row * 256 + y) * 1536 + column * 256 + x) * 4
				if after[j] != r or after[j + 1] != g or after[j + 2] != b or after[j + 3] != before[i + 3]:
					changed += 1
	_check(samples > 100 and changed == 0, "native foreground palette/alpha preserved " + name,
		{"protected_interior_samples": samples, "changed": changed, "palette": "purple robe" if purple else "burgundy cape"})


func _test_jump_arc() -> void:
	var image: Image = _load("res://assets/sprites/hero_motion.png")
	if image == null:
		return
	var tops: Array[int] = []
	var bottoms: Array[int] = []
	for column: int in range(6):
		var tile: Image = image.get_region(Rect2i(column * 256, 512, 256, 256))
		var bounds: Rect2i = tile.get_used_rect()
		tops.append(bounds.position.y)
		bottoms.append(bounds.end.y)
	_check(int(tops.max()) - int(tops.min()) >= 40 and int(bottoms.max()) - int(bottoms.min()) >= 12,
		"authored jump height progression survives, not six bottom-aligned poses", {"tops": tops, "bottoms": bottoms})