extends SceneTree
## Check visible face direction, not merely filenames or actor.facing.
## The reviewed hero palette has peach skin and dark chestnut hair.

const Actor = preload("res://scripts/actor.gd")
var passed: int = 0
var failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var actor := Actor.new()
	root.add_child(actor)
	actor.setup("traveler", true)
	actor.set_process(false)
	var headings: Dictionary = {}
	for direction: String in ["left", "right"]:
		var offsets: Array[float] = []
		for index in range(8):
			var path: String = "res://assets/sprites/traveler_%s_%d.png" % [direction, index]
			var image := Image.new()
			var decoded: Error = image.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
			if decoded != OK or image.is_empty():
				_check(false, "missing production frame " + path, "PNG", null)
				continue
			var evidence: Dictionary = _face_evidence(image)
			_check(evidence.skin_pixels >= 12, path + " has measurable face pixels", ">=12", evidence)
			var offset: float = evidence.offset
			offsets.append(offset)
			_check(offset < -2.0 if direction == "left" else offset > 2.0,
				path + " visible head faces " + direction, "negative for left; positive for right", evidence)
			headings[path] = offset
		print("FACE_EVIDENCE: ", direction, " skin center relative to head center (px)=", offsets)
	# A full set of repeated cycles must keep the image facing the travel direction.
	for direction: String in ["left", "right"]:
		var motion := Vector2.LEFT if direction == "left" else Vector2.RIGHT
		actor.set_motion(motion * 224.0 / 60.0)
		var seen: Dictionary = {}
		for index in range(120):
			actor.set_motion(motion * 224.0 / 60.0)
			actor._process(1.0 / 60.0)
			_check(actor.facing == direction, "held direction stays stable", direction, actor.facing)
			var offset: float = float(headings.get(actor.sprite.texture.resource_path, 0.0))
			_check(offset < -2.0 if direction == "left" else offset > 2.0,
				"actual displayed frame faces " + direction, direction, {"frame": actor.current_frame, "offset": offset})
			seen[actor.current_frame] = true
		_check(seen.size() == 8, "all stride phases still animate", 8, seen.keys())
		actor.set_motion(Vector2.ZERO)
		actor._process(0.5)
		_check(actor.facing == direction, "stopping keeps orientation", direction, actor.facing)
		_check(actor.current_frame == 1, "stopping selects idle frame", 1, actor.current_frame)
	actor.set_motion(Vector2.LEFT)
	_check(actor.facing == "left", "real direction change still turns left", "left", actor.facing)
	actor.set_motion(Vector2.RIGHT)
	_check(actor.facing == "right", "real direction change still turns right", "right", actor.facing)
	actor.queue_free()
	await process_frame
	await process_frame
	print("FACING_TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _face_evidence(image: Image) -> Dictionary:
	var bounds: Rect2i = image.get_used_rect()
	# Only the upper third of the figure: the head, not hands, scarf or satchel.
	var head_bottom: int = bounds.position.y + roundi(bounds.size.y * 0.34)
	var left: int = image.get_width()
	var right: int = -1
	var skin_x: float = 0.0
	var skin_count: int = 0
	for y in range(bounds.position.y, head_bottom):
		for x in range(bounds.position.x, bounds.end.x):
			var color: Color = image.get_pixel(x, y)
			if color.a < 0.8:
				continue
			left = mini(left, x)
			right = maxi(right, x)
			if color.r > 0.65 and color.g > 0.40 and color.b > 0.20 and color.r > color.g * 1.10 and color.g > color.b * 1.13:
				skin_x += x
				skin_count += 1
	var head_center: float = (left + right) / 2.0
	var face_center: float = skin_x / maxf(1.0, skin_count)
	return {"skin_pixels": skin_count, "head_center": head_center, "face_center": face_center, "offset": face_center - head_center}


func _check(condition: bool, label: String, expected: Variant, actual: Variant) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL %s expected=%s actual=%s" % [label, str(expected), str(actual)])