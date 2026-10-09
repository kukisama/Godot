extends SceneTree
## Reproducible production conversion; original generated images stay untouched.

const SPRITES: Array[String] = ["hero_motion", "hero_combat", "hero_special", "briar", "sentinel", "lancer", "arbalist", "cantor", "gargoyle", "warden", "boss"]
const PROPS: Array[String] = ["oak", "fir", "arch", "shrine", "ferns", "dead_tree", "torch", "banner"]
const SURFACES: Array[String] = ["moss", "stone", "earth", "flagstone", "brick", "wood"]
const BACKDROPS: Array[String] = ["vista", "forest", "abbey"]
const ATLAS_SIZE: Vector2i = Vector2i(1536, 1024)
const SPRITE_CELL: Vector2i = Vector2i(256, 256)
const PROP_CELL: Vector2i = Vector2i(384, 512)
const GUTTER: int = 2
# Contact lines measured in the ORIGINALS, exclusive of the last boot pixel.
# One offset per grounded animation, never one per frame. Motion rows 2/3
# deliberately keep the idle reference: their jump/roll displacement is art.
# Death/pounce rows likewise retain the standing reference; hovering actors
# have no ground correction. No pose is stretched to match a bounding box.
const CONTACT_ROWS: Dictionary = {
	"hero_motion": [246, 242, 246, 246],
	"hero_combat": [242, 246, 246, 242],
	"hero_special": [250, 242, 234, 237],
	"briar": [225, 222, 225, 225],
	"sentinel": [245, 243, 241, 245],
	"lancer": [243, 245, 238, 243],
	"arbalist": [250, 236, 230, 250],
	"warden": [247, 247, 249, 247],
	"boss": [249, 247, 249, 249],
	"props": [480, 480],
}


func _initialize() -> void:
	var result: Dictionary = convert_all()
	for message: String in result["errors"]:
		push_error(message)
	print("ASSET_CONVERSION outputs=%d failures=%d" % [result["outputs"], result["errors"].size()])
	quit(0 if result["errors"].is_empty() else 1)


static func convert_all() -> Dictionary:
	var errors: Array[String] = []
	var originals: Dictionary = {}
	var prepared: Dictionary = {}
	var layouts: Dictionary = {}
	var metrics: Dictionary = {}
	var result: Dictionary = {"errors": errors, "outputs": 0, "layouts": layouts, "metrics": metrics}
	# Validate every input BEFORE replacing any output. Image reads bypass .import
	# and ResourceLoader caches; neither conversion nor tests need an editor.
	for name: String in SPRITES + BACKDROPS + ["props", "surfaces"]:
		var image: Image = _source(name, errors)
		if image != null:
			originals[name] = image
	if not errors.is_empty():
		return result
	for name: String in SPRITES + ["props"]:
		var cell: Vector2i = PROP_CELL if name == "props" else SPRITE_CELL
		var image: Image = originals[name]
		var extraction: Dictionary = extract_atlas(image, cell)
		prepared[name] = extraction
		layouts[name] = plan_layout(name, extraction, cell)
		metrics[name] = extraction["metrics"]
		print("EXTRACT " + name + " " + JSON.stringify(extraction["metrics"]))
		for frame: int in range(extraction["bounds"].size()):
			var bounds: Rect2i = extraction["bounds"][frame]
			if not bounds.has_area():
				errors.append("Empty source foreground: %s frame %d" % [name, frame])
	if not errors.is_empty():
		return result
	# The three hero sheets represent the SAME person. Use one affine X mapping
	# and one scale across them, including the recovered, formerly clipped sword.
	var hero_min: float = INF
	var hero_max: float = -INF
	var hero_scale: float = 1.0
	for name: String in ["hero_motion", "hero_combat", "hero_special"]:
		hero_min = minf(hero_min, float(layouts[name]["x_min"]))
		hero_max = maxf(hero_max, float(layouts[name]["x_max"]))
		hero_scale = minf(hero_scale, float(layouts[name]["scale"]))
	hero_scale = minf(hero_scale, float(SPRITE_CELL.x - 2 * GUTTER) / (hero_max - hero_min))
	for name: String in ["hero_motion", "hero_combat", "hero_special"]:
		layouts[name]["scale"] = hero_scale
		layouts[name]["offset_x"] = clampf(128.0, GUTTER - hero_scale * hero_min,
			SPRITE_CELL.x - GUTTER - hero_scale * hero_max)
	for name: String in layouts:
		if float(layouts[name]["scale"]) <= 0.5:
			errors.append("Unsafe foreground extent/scale for %s: %s" % [name, layouts[name]])
	if not errors.is_empty():
		return result
	DirAccess.make_dir_recursive_absolute("res://assets/sprites")
	DirAccess.make_dir_recursive_absolute("res://assets/environment")
	for name: String in SPRITES:
		var atlas: Image = render_atlas(prepared[name], layouts[name], SPRITE_CELL)
		_save(atlas, "res://assets/sprites/" + name + ".png", errors)
		result["outputs"] += 1
	var props: Image = render_atlas(prepared["props"], layouts["props"], PROP_CELL)
	metrics["props"]["foliage_rim_despilled"] = despill_foliage_rims(props, PROP_CELL)
	for index: int in range(PROPS.size()):
		var origin: Vector2i = Vector2i(index % 4, floori(float(index) / 4.0)) * PROP_CELL
		_save(props.get_region(Rect2i(origin, PROP_CELL)),
			"res://assets/environment/" + PROPS[index] + ".png", errors)
		result["outputs"] += 1
	# Backgrounds/surfaces are NOT matted, resized, normalized or re-encoded if
	# already correct. Their existing PNG bytes therefore remain untouched.
	for name: String in BACKDROPS:
		_save(originals[name], "res://assets/environment/" + name + ".png", errors)
		result["outputs"] += 1
	var surfaces: Image = originals["surfaces"]
	for index: int in range(SURFACES.size()):
		var origin: Vector2i = Vector2i(index % 3, floori(float(index) / 3.0)) * 512
		_save(surfaces.get_region(Rect2i(origin, Vector2i(512, 512))),
			"res://assets/environment/" + SURFACES[index] + ".png", errors)
		result["outputs"] += 1
	for name: String in metrics:
		print("MATTE " + name + " " + JSON.stringify(metrics[name]))
		print("LAYOUT " + name + " " + JSON.stringify(layouts[name]))
	return result


static func _source(name: String, errors: Array[String]) -> Image:
	var path: String = "res://assets/source/" + name + ".png"
	if not FileAccess.file_exists(path):
		errors.append("Missing required source: " + path)
		return null
	var image: Image = Image.new()
	if image.load(ProjectSettings.globalize_path(path)) != OK or image.is_empty():
		errors.append("Could not decode source: " + path)
		return null
	if image.get_size() != ATLAS_SIZE:
		errors.append("Unexpected atlas dimensions for %s: %s" % [name, image.get_size()])
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image


static func _key_color(r: int, g: int, b: int) -> bool:
	var low: int = mini(r, b)
	var high: int = maxi(r, b)
	# Hue/saturation, NOT a brightness cutoff. The measured backing is near
	# (248,2,247); its dark fringes include (43,1,48). Burgundy is red-biased;
	# the cantor's purple cloth has appreciable green and a blue-biased hue.
	# Mixed edge coverage (e.g. a half-covered green leaf) is left for unmixing.
	return low - g >= 18 and g * 3 <= low and high - low <= maxi(12, int(high * 0.22))


@warning_ignore("integer_division")
static func key_image(image: Image, cell: Vector2i) -> Dictionary:
	image.convert(Image.FORMAT_RGBA8)
	var bytes: PackedByteArray = image.get_data()
	var width: int = image.get_width()
	var height: int = image.get_height()
	var count: int = width * height
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(count)
	var queue: PackedInt32Array = PackedInt32Array()
	queue.resize(count)
	var tail: int = 0
	for pixel: int in range(count):
		var i: int = pixel * 4
		var r: int = bytes[i]
		var g: int = bytes[i + 1]
		var b: int = bytes[i + 2]
		var candidate: bool = _key_color(r, g, b)
		var x: int = pixel % width
		var y: int = pixel / width
		var local_x: int = x % cell.x
		var local_y: int = y % cell.y
		var border: bool = local_x == 0 or local_x == cell.x - 1 or local_y == 0 or local_y == cell.y - 1
		# Flat, very pure backing also seeds enclosed leaf/weapon holes. A dark
		# or shaded purple island inside opaque foreground is NOT a seed.
		var flat_key: bool = r >= 220 and b >= 220 and g <= 18 and absi(r - b) <= 24
		if bytes[i + 3] == 0 or (candidate and (border or flat_key)):
			mask[pixel] = 2
			queue[tail] = pixel
			tail += 1
		elif candidate:
			mask[pixel] = 1
	var head: int = 0
	while head < tail:
		var pixel: int = queue[head]
		head += 1
		var x: int = pixel % width
		var y: int = pixel / width
		for ny: int in range(maxi(0, y - 1), mini(height, y + 2)):
			for nx: int in range(maxi(0, x - 1), mini(width, x + 2)):
				var other: int = ny * width + nx
				if mask[other] == 1:
					mask[other] = 2
					queue[tail] = other
					tail += 1
	# Every cell border is seeded. Crossing a grid line during this flood is
	# equivalent to two separate cell floods, but does not split a dark fringe.
	var cleared: int = 0
	var dark: int = 0
	var distance: PackedByteArray = PackedByteArray()
	distance.resize(count)
	distance.fill(255)
	for pixel: int in range(count):
		if mask[pixel] != 2:
			continue
		distance[pixel] = 0
		var i: int = pixel * 4
		if bytes[i + 3] > 0:
			cleared += 1
			if bytes[i] < 138 or bytes[i + 2] < 138:
				dark += 1
		bytes[i] = 0
		bytes[i + 1] = 0
		bytes[i + 2] = 0
		bytes[i + 3] = 0
	# A fixed, two-pixel edge band; edits must not recursively eat inward.
	var steps: PackedInt32Array = PackedInt32Array([-1, 1, -width, width])
	head = 0
	tail = 0
	for pixel: int in range(count):
		if mask[pixel] == 2:
			continue
		for step: int in steps:
			var other: int = pixel + step
			if other < 0 or other >= count or absi(other % width - pixel % width) > 1:
				continue
			if mask[other] == 2:
				distance[pixel] = 1
				queue[tail] = pixel
				tail += 1
				break
	while head < tail:
		var pixel: int = queue[head]
		head += 1
		if distance[pixel] >= 3:
			continue
		for step: int in steps:
			var other: int = pixel + step
			if other < 0 or other >= count or absi(other % width - pixel % width) > 1:
				continue
			if distance[other] == 255:
				distance[other] = distance[pixel] + 1
				queue[tail] = other
				tail += 1
	var original: PackedByteArray = bytes.duplicate()
	var despilled: int = 0
	for pixel: int in range(count):
		if distance[pixel] < 1 or distance[pixel] > 2:
			continue
		if _despill(original, bytes, distance, pixel, width, height):
			despilled += 1
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, bytes)
	return {"background_cleared": cleared, "dark_key_cleared": dark, "edge_despilled": despilled}


@warning_ignore("integer_division")
static func _despill(source: PackedByteArray, output: PackedByteArray,
		distance: PackedByteArray, pixel: int, width: int, height: int) -> bool:
	var i: int = pixel * 4
	var r: float = source[i]
	var g: float = source[i + 1]
	var b: float = source[i + 2]
	var excess: float = minf(r, b) - g
	if excess < 8.0:
		return false
	var x: int = pixel % width
	var y: int = pixel / width
	var observed: Vector3 = Vector3(r, g, b)
	var key: Vector3 = Vector3(248.0, 2.0, 247.0)
	var from_key: Vector3 = observed - key
	var best_score: float = INF
	var coverage: float = 1.0
	var key_norm: float = key.length_squared()
	for ny: int in range(maxi(0, y - 5), mini(height, y + 6)):
		for nx: int in range(maxi(0, x - 5), mini(width, x + 6)):
			var travel: int = absi(nx - x) + absi(ny - y)
			if travel == 0 or travel > 5:
				continue
			var other: int = ny * width + nx
			if source[other * 4 + 3] == 0:
				continue
			var j: int = other * 4
			var foreground: Vector3 = Vector3(source[j], source[j + 1], source[j + 2])
			var foreground_excess: float = minf(foreground.x, foreground.z) - foreground.y
			# Thin leaves/needles may have NO thicker interior. A neighboring
			# non-magenta leaf is a valid reference; another pink edge is not.
			if distance[other] <= distance[pixel] and foreground_excess > 0.0:
				continue
			# Native purple can be its own reference; its fitted coverage is 1.
			if foreground_excess > excess:
				continue
			var direction: Vector3 = foreground - key
			var denominator: float = direction.length_squared()
			if denominator < 1.0:
				continue
			var alpha: float = clampf(from_key.dot(direction) / denominator, 0.02, 1.0)
			var error: float = (observed - key.lerp(foreground, alpha)).length_squared()
			var score: float = error + float(travel * travel) * 2.0
			if score < best_score:
				best_score = score
				coverage = alpha
			# The generated matte is also darkened/textured at the edge. Fit
			# C = a*F + c*K, allowing F's luminance to vary, not its hue. This
			# handles warm pink yellow-leaf rims and dark blue needle fringes.
			# Restrict this extra freedom to genuinely non-magenta references.
			if foreground_excess > 0.0 or excess < 16.0:
				continue
			var foreground_norm: float = foreground.length_squared()
			var product: float = foreground.dot(key)
			var determinant: float = foreground_norm * key_norm - product * product
			if determinant < 1.0:
				continue
			var a: float = (observed.dot(foreground) * key_norm - observed.dot(key) * product) / determinant
			var c: float = (observed.dot(key) * foreground_norm - observed.dot(foreground) * product) / determinant
			var remaining: float = 1.0 - c
			if c < 0.02 or remaining < 0.08 or a < remaining * 0.2 or a > remaining * 1.6:
				continue
			var modeled: Vector3 = foreground * a + key * c
			var shadow_score: float = (observed - modeled).length_squared() + float(travel * travel) * 2.0 + 4.0
			if shadow_score < best_score:
				best_score = shadow_score
				coverage = remaining
	if best_score > 1200.0 or coverage >= 0.98:
		return false
	# Unmix the observed backing instead of painting an arbitrary gray border.
	var clean: Vector3 = key + from_key / coverage
	output[i] = clampi(roundi(clean.x), 0, 255)
	output[i + 1] = clampi(roundi(clean.y), 0, 255)
	output[i + 2] = clampi(roundi(clean.z), 0, 255)
	output[i + 3] = clampi(roundi(float(source[i + 3]) * coverage), 0, source[i + 3])
	return true


static func despill_foliage_rims(image: Image, cell: Vector2i) -> int:
	# Reviewed material exception, AFTER correct component ownership: only the
	# gold oak and teal fir cells. Never apply this to actors, purple robes,
	# flowers, banners or magic/torch glow. Their local unmixing is above.
	var width: int = image.get_width()
	var height: int = mini(image.get_height(), cell.y)
	var bytes: PackedByteArray = image.get_data()
	var original: PackedByteArray = bytes.duplicate()
	var corrected: int = 0
	for y: int in range(height):
		for x: int in range(mini(width, cell.x * 2)):
			var i: int = (y * width + x) * 4
			var r: int = original[i]
			var g: int = original[i + 1]
			var b: int = original[i + 2]
			# Red/amber pigment is intentionally preserved. These measured blue
			# and warm-magenta rims have both R/B excess, even at low luminance.
			if original[i + 3] == 0 or mini(r, b) - g < 16 or r > b * 2:
				continue
			var distance: int = 7
			for ny: int in range(maxi(0, y - 6), mini(height, y + 7)):
				for nx: int in range(maxi(0, x - 6), mini(width, x + 7)):
					var travel: int = absi(nx - x) + absi(ny - y)
					if travel <= 6 and original[(ny * width + nx) * 4 + 3] == 0:
						distance = mini(distance, travel)
			if distance > 6:
				continue
			# Cap ONLY the screen excess at this transparent-neighbor rim. Do
			# not erode alpha, blur needles or flatten the untouched leaf core.
			if x < cell.x:
				bytes[i + 2] = mini(b, g + 8)
			else:
				bytes[i] = mini(r, g + 8)
			corrected += 1
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, bytes)
	return corrected


@warning_ignore("integer_division")
static func extract_atlas(image: Image, cell: Vector2i) -> Dictionary:
	var metrics: Dictionary = key_image(image, cell)
	var bytes: PackedByteArray = image.get_data()
	var width: int = image.get_width()
	var height: int = image.get_height()
	var count: int = width * height
	var columns: int = width / cell.x
	var frames: int = columns * (height / cell.y)
	var labels: PackedInt32Array = PackedInt32Array()
	labels.resize(count)
	labels.fill(-1)
	var queue: PackedInt32Array = PackedInt32Array()
	queue.resize(count)
	var components: Array[Dictionary] = []
	# Label foreground BEFORE cutting nominal cells. This recovers oak leaves,
	# the banner finial, long swords and the boss's hammer from adjacent cells.
	for start: int in range(count):
		if bytes[start * 4 + 3] == 0 or labels[start] != -1:
			continue
		var label: int = components.size()
		var votes: PackedInt32Array = PackedInt32Array()
		votes.resize(frames)
		var head: int = 0
		var tail: int = 1
		queue[0] = start
		labels[start] = label
		while head < tail:
			var pixel: int = queue[head]
			head += 1
			var x: int = pixel % width
			var y: int = pixel / width
			votes[(y / cell.y) * columns + x / cell.x] += 1
			for ny: int in range(maxi(0, y - 1), mini(height, y + 2)):
				for nx: int in range(maxi(0, x - 1), mini(width, x + 2)):
					var other: int = ny * width + nx
					if bytes[other * 4 + 3] > 0 and labels[other] == -1:
						labels[other] = label
						queue[tail] = other
						tail += 1
		components.append({"pixels": tail, "owner": _most_votes(votes)})
	# Attach detached leaf tips/sparks to nearby actual bodies, not whichever
	# nominal cell their centroid happens to fall in. Never discard small art.
	var core_limit: int = maxi(8, mini(512, cell.x * cell.y / 128))
	var largest: PackedInt32Array = PackedInt32Array()
	largest.resize(frames)
	for component: Dictionary in components:
		var owner: int = int(component["owner"])
		largest[owner] = maxi(largest[owner], int(component["pixels"]))
	var core: PackedByteArray = PackedByteArray()
	core.resize(components.size())
	for label: int in range(components.size()):
		var owner: int = int(components[label]["owner"])
		# A dissolving death frame (briar 23) has no >=512-pixel body. Use
		# its own substantial fragments as seeds, never the previous pose.
		var threshold: int = mini(core_limit, maxi(1, largest[owner] / 8))
		if int(components[label]["pixels"]) >= threshold:
			core[label] = 1
	var nearest: PackedInt32Array = PackedInt32Array()
	nearest.resize(count)
	nearest.fill(-1)
	var travel: PackedByteArray = PackedByteArray()
	travel.resize(count)
	var head: int = 0
	var tail: int = 0
	for pixel: int in range(count):
		if labels[pixel] >= 0 and core[labels[pixel]] == 1:
			nearest[pixel] = int(components[labels[pixel]]["owner"])
			queue[tail] = pixel
			tail += 1
	var steps: PackedInt32Array = PackedInt32Array([-1, 1, -width, width])
	while head < tail:
		var pixel: int = queue[head]
		head += 1
		# Only nearby detached tips belong to a crossing body. An unbounded
		# Voronoi fill steals distant sparks from the NEXT animation row and
		# creates fictitious below-ground bounds, shrinking an entire atlas.
		if travel[pixel] >= 12:
			continue
		for step: int in steps:
			var other: int = pixel + step
			if other < 0 or other >= count or absi(other % width - pixel % width) > 1:
				continue
			if nearest[other] == -1:
				nearest[other] = nearest[pixel]
				travel[other] = travel[pixel] + 1
				queue[tail] = other
				tail += 1
	var small_votes: Dictionary = {}
	for pixel: int in range(count):
		var label: int = labels[pixel]
		if label < 0 or core[label] == 1:
			continue
		if not small_votes.has(label):
			var votes: PackedInt32Array = PackedInt32Array()
			votes.resize(frames)
			small_votes[label] = votes
		var owner: int = nearest[pixel] if nearest[pixel] >= 0 else int(components[label]["owner"])
		small_votes[label][owner] += 1
	for label: int in small_votes:
		var votes: PackedInt32Array = small_votes[label]
		components[label]["owner"] = _most_votes(votes)
	var left: PackedInt32Array = PackedInt32Array()
	var top: PackedInt32Array = PackedInt32Array()
	var right: PackedInt32Array = PackedInt32Array()
	var bottom: PackedInt32Array = PackedInt32Array()
	left.resize(frames)
	top.resize(frames)
	right.resize(frames)
	bottom.resize(frames)
	left.fill(width)
	top.fill(height)
	right.fill(-1)
	bottom.fill(-1)
	var recovered: int = 0
	var visible: int = 0
	for pixel: int in range(count):
		if labels[pixel] < 0:
			continue
		var owner: int = int(components[labels[pixel]]["owner"])
		labels[pixel] = owner
		var x: int = pixel % width
		var y: int = pixel / width
		left[owner] = mini(left[owner], x)
		right[owner] = maxi(right[owner], x)
		top[owner] = mini(top[owner], y)
		bottom[owner] = maxi(bottom[owner], y)
		visible += 1
		if owner != (y / cell.y) * columns + x / cell.x:
			recovered += 1
	var bounds: Array[Rect2i] = []
	for frame: int in range(frames):
		bounds.append(Rect2i(left[frame], top[frame], maxi(0, right[frame] - left[frame] + 1),
			maxi(0, bottom[frame] - top[frame] + 1)))
	metrics["foreground_pixels"] = visible
	metrics["components"] = components.size()
	metrics["recovered_cross_cell_pixels"] = recovered
	return {"image": image, "owners": labels, "bounds": bounds, "metrics": metrics}


static func _most_votes(votes: PackedInt32Array) -> int:
	var winner: int = 0
	for index: int in range(1, votes.size()):
		if votes[index] > votes[winner]:
			winner = index
	return winner


@warning_ignore("integer_division")
static func plan_layout(name: String, extraction: Dictionary, cell: Vector2i) -> Dictionary:
	var image: Image = extraction["image"]
	var columns: int = image.get_width() / cell.x
	var rows: int = image.get_height() / cell.y
	var baselines: PackedInt32Array = PackedInt32Array()
	baselines.resize(rows)
	baselines.fill(cell.y / 2)
	var target_y: float = float(cell.y) * 0.5
	if CONTACT_ROWS.has(name):
		baselines = PackedInt32Array(CONTACT_ROWS[name])
		# Actor Sprite3D is centered at 104 px above the floor: 128+104=232.
		target_y = 480.0 if name == "props" else 232.0
	var x_min: float = INF
	var x_max: float = -INF
	var y_min: float = INF
	var y_max: float = -INF
	for frame: int in range(extraction["bounds"].size()):
		var bounds: Rect2i = extraction["bounds"][frame]
		if not bounds.has_area():
			continue
		var origin: Vector2i = Vector2i((frame % columns) * cell.x, (frame / columns) * cell.y)
		x_min = minf(x_min, float(bounds.position.x - origin.x) - float(cell.x) * 0.5)
		x_max = maxf(x_max, float(bounds.end.x - origin.x) - float(cell.x) * 0.5)
		y_min = minf(y_min, float(bounds.position.y - origin.y - baselines[frame / columns]))
		y_max = maxf(y_max, float(bounds.end.y - origin.y - baselines[frame / columns]))
	var scale: float = minf(1.0, float(cell.x - 2 * GUTTER) / maxf(1.0, x_max - x_min))
	if y_min < 0.0:
		scale = minf(scale, (target_y - GUTTER) / -y_min)
	if y_max > 0.0:
		scale = minf(scale, (cell.y - GUTTER - target_y) / y_max)
	var offset_x: float = clampf(float(cell.x) * 0.5,
		GUTTER - scale * x_min, cell.x - GUTTER - scale * x_max)
	return {"scale": scale, "offset_x": offset_x, "target_y": target_y,
		"baselines": Array(baselines), "x_min": x_min, "x_max": x_max,
		"y_min": y_min, "y_max": y_max, "gutter": GUTTER}


@warning_ignore("integer_division")
static func render_atlas(extraction: Dictionary, layout: Dictionary, cell: Vector2i) -> Image:
	var image: Image = extraction["image"]
	var width: int = image.get_width()
	var height: int = image.get_height()
	var columns: int = width / cell.x
	var source: PackedByteArray = image.get_data()
	var owners: PackedInt32Array = extraction["owners"]
	var output: PackedByteArray = PackedByteArray()
	output.resize(source.size())
	var scale: float = float(layout["scale"])
	# Nearest-neighbor sampling preserves the authored pixel palette. One mapping
	# for a sheet (shared across heroes), not independent tight-box resizes.
	var sample_x: PackedInt32Array = PackedInt32Array()
	sample_x.resize(cell.x)
	for x: int in range(cell.x):
		sample_x[x] = floori((float(x) + 0.5 - float(layout["offset_x"])) / scale + float(cell.x) * 0.5)
	for frame: int in range(columns * (height / cell.y)):
		var column: int = frame % columns
		var row: int = frame / columns
		for y: int in range(GUTTER, cell.y - GUTTER):
			var sy: int = row * cell.y + floori((float(y) + 0.5 - float(layout["target_y"])) / scale
				+ float(layout["baselines"][row]))
			if sy < 0 or sy >= height:
				continue
			for x: int in range(GUTTER, cell.x - GUTTER):
				var sx: int = column * cell.x + sample_x[x]
				if sx < 0 or sx >= width or owners[sy * width + sx] != frame:
					continue
				var i: int = (sy * width + sx) * 4
				var j: int = ((row * cell.y + y) * width + column * cell.x + x) * 4
				output[j] = source[i]
				output[j + 1] = source[i + 1]
				output[j + 2] = source[i + 2]
				output[j + 3] = source[i + 3]
	# Nearest sampling can expose previously enclosed single key-colored pixels.
	# Clear only newly background-connected screen color; do NOT despill twice.
	layout["resampled_key_cleared"] = _clear_exposed_key(output, width, height)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, output)


@warning_ignore("integer_division")
static func _clear_exposed_key(bytes: PackedByteArray, width: int, height: int) -> int:
	var count: int = width * height
	var candidates: PackedByteArray = PackedByteArray()
	candidates.resize(count)
	var queue: PackedInt32Array = PackedInt32Array()
	queue.resize(count)
	var tail: int = 0
	for pixel: int in range(count):
		var i: int = pixel * 4
		if bytes[i + 3] > 0 and _key_color(bytes[i], bytes[i + 1], bytes[i + 2]):
			candidates[pixel] = 1
	for pixel: int in range(count):
		if candidates[pixel] != 1:
			continue
		var x: int = pixel % width
		var y: int = pixel / width
		var exposed: bool = false
		for ny: int in range(maxi(0, y - 1), mini(height, y + 2)):
			for nx: int in range(maxi(0, x - 1), mini(width, x + 2)):
				if bytes[(ny * width + nx) * 4 + 3] == 0:
					exposed = true
		if exposed:
			candidates[pixel] = 2
			queue[tail] = pixel
			tail += 1
	var head: int = 0
	while head < tail:
		var pixel: int = queue[head]
		head += 1
		var x: int = pixel % width
		var y: int = pixel / width
		for ny: int in range(maxi(0, y - 1), mini(height, y + 2)):
			for nx: int in range(maxi(0, x - 1), mini(width, x + 2)):
				var other: int = ny * width + nx
				if candidates[other] == 1:
					candidates[other] = 2
					queue[tail] = other
					tail += 1
	for index: int in range(tail):
		var i: int = queue[index] * 4
		bytes[i] = 0
		bytes[i + 1] = 0
		bytes[i + 2] = 0
		bytes[i + 3] = 0
	return tail


static func _save(image: Image, path: String, errors: Array[String]) -> void:
	if FileAccess.file_exists(path):
		var existing: Image = Image.new()
		if existing.load(ProjectSettings.globalize_path(path)) == OK:
			existing.convert(Image.FORMAT_RGBA8)
			if existing.get_size() == image.get_size() and existing.get_data() == image.get_data():
				print("UNCHANGED " + path)
				return
	var result: Error = image.save_png(path)
	if result != OK:
		errors.append("Could not save %s: %s" % [path, error_string(result)])
	else:
		print("PREPARED %s %s" % [path, image.get_size()])