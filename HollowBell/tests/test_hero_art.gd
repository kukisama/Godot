extends SceneTree
## Isolated, read-only fixtures. Does NOT run the shared production converter.
const Prep = preload("res://tools/prepare_hero_v2.gd")
const Converter = preload("res://tools/prepare_assets.gd")
var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	var before: Dictionary = Prep.protected_hashes()
	_check(bool(Prep.parse_args(PackedStringArray())["compare"]), "default is QA-only compare")
	_check(not Prep.parse_args(PackedStringArray(["--ab", "edit_flow_ab_flare"]))["errors"].is_empty(), "partial selection rejected")
	_check(not Prep.parse_args(PackedStringArray(["--compare", "--attack", "flow"]))["errors"].is_empty(), "compare cannot select")
	var full: Dictionary = Prep.parse_args(PackedStringArray(["--attack", "flow", "--motion", "motion_grounded",
		"--defense", "defense_compact", "--ab", "edit_flow_ab_flare"]))
	_check(full["errors"].is_empty() and full["selection"].size() == 4
		and full["selection"]["blade_b"] == "flow_finish", "family resolves four sheets and edit override")
	var rejected: Dictionary = Prep.execute(Prep.parse_args(PackedStringArray(["--attack", "../../hero"])), false)
	_check(not rejected["errors"].is_empty() and rejected["production_paths"].is_empty(), "invalid input fails before writes")
	for kind: String in ["blade_a", "blade_b", "defense", "motion"]:
		var count: int = 0
		for seq: Dictionary in Prep.sequences(kind):
			count += int(seq["count"])
		_check(count == 24, "24 distinct authored frame slots: " + kind)
	_matte_fixture()
	_mapping_fixture()
	_head_fixture()
	_check(Prep.protected_hashes() == before, "originals/environment/enemies/shared scripts unchanged")
	print("HERO_ART_TEST checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + label)


func _matte_fixture() -> void:
	var image: Image = Image.create(512, 256, false, Image.FORMAT_RGBA8)
	image.fill(Color.from_rgba8(248, 2, 247))
	image.fill_rect(Rect2i(0, 3, 20, 3), Color.from_rgba8(43, 1, 48))
	image.fill_rect(Rect2i(90, 60, 120, 160), Color.from_rgba8(34, 104, 59))
	image.fill_rect(Rect2i(110, 80, 25, 25), Color.from_rgba8(73, 48, 91))
	image.fill_rect(Rect2i(140, 80, 25, 25), Color.from_rgba8(107, 12, 39))
	image.fill_rect(Rect2i(180, 140, 100, 4), Color.from_rgba8(34, 104, 59))
	image.fill_rect(Rect2i(282, 140, 2, 3), Color.from_rgba8(34, 104, 59))
	image.fill_rect(Rect2i(370, 60, 80, 160), Color.from_rgba8(42, 101, 178))
	var extraction: Dictionary = Converter.extract_atlas(image, Vector2i(256, 256))
	_check(image.get_pixel(0, 4).a == 0.0, "connected dark matte cleared")
	_check(image.get_pixel(120, 90) == Color.from_rgba8(73, 48, 91)
		and image.get_pixel(150, 90) == Color.from_rgba8(107, 12, 39), "native purple and burgundy preserved")
	_check(extraction["owners"][140 * 512 + 278] == 0
		and extraction["owners"][141 * 512 + 282] == 0, "crossing blade/limb and detached tip recovered")


func _mapping_fixture() -> void:
	var bounds: Array[Rect2i] = []
	var features: Array[Dictionary] = []
	for frame: int in range(24):
		var row: int = floori(float(frame) / 6.0)
		bounds.append(Rect2i((frame % 6) * 256 + 60, row * 256 + (30 if row == 1 else 58), 150, 174))
		features.append({"standing_probe_valid": true, "body_height": 174.0,
			"body_axis_x": 116.0, "boot_contact_y": 232.0 if row != 1 else 202.0,
			"boot_color_samples": 400})
	var reference: Dictionary = {"standing_height": 154.0, "target_pivot_x": 116.0}
	var mapped: Dictionary = Prep.plan_mapping("motion", {"bounds": bounds}, features, reference)
	_check(not mapped.has("error") and absf(float(mapped["layout"]["scale"]) - 154.0 / 174.0) < 0.00001,
		"measured body scale, not per-frame bbox stretch")
	_check(mapped["layout"]["baselines"][0] == mapped["layout"]["baselines"][1], "jump inherits idle, preserving authored elevation")
	var defense: Dictionary = Prep.plan_mapping("defense", {"bounds": bounds}, features, reference)
	_check(defense["layout"]["baselines"][0] == defense["layout"]["baselines"][1], "12-frame roll shares one standing mapping")
	var pose: Image = Image.create(256, 256, false, Image.FORMAT_RGBA8)
	pose.fill(Color.TRANSPARENT)
	pose.fill_rect(Rect2i(80, 50, 80, 174), Color.from_rgba8(40, 70, 100))
	var same: Dictionary = Prep.pose_difference(pose.get_data(), pose.get_data())
	_check(same["changed_visible_pixels"] == 0 and same["silhouette_iou"] == 1.0, "identical pose metric is explicit, not called smooth")
	var atlas: Image = Image.create(1536, 1024, false, Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	var output_features: Array = []
	for frame: int in range(24):
		var x: int = (frame % 6) * 256 + (84 if frame == 2 else 80)
		var y: int = floori(float(frame) / 6.0) * 256 + 50
		atlas.fill_rect(Rect2i(x, y, 80, 174), Color.from_rgba8(40 if frame < 3 else 40 + frame, 70, 100))
		output_features.append({"boot_contact_y": 224.0, "head_top_y": 50.0, "facing_proxy": "right"})
	var measured: Array[Dictionary] = Prep.sequence_metrics(atlas, "blade_a", output_features)
	_check(measured[0]["exact_duplicate_pairs"] == [[0, 1]], "exact copies detected separately")
	_check(measured[0]["translation_only_pairs"] == [[1, 2]], "only translated copy classified as translation-only")


func _head_fixture() -> void:
	var image: Image = Image.create(256, 256, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(90, 75, 40, 100), Color.from_rgba8(40, 68, 100))
	image.fill_rect(Rect2i(109, 40, 24, 16), Color.from_rgba8(185, 185, 170))
	image.fill_rect(Rect2i(122, 52, 12, 14), Color.from_rgba8(194, 137, 91))
	image.fill_rect(Rect2i(140, 96, 30, 42), Color.from_rgba8(133, 95, 50))
	image.fill_rect(Rect2i(90, 190, 16, 42), Color.from_rgba8(106, 65, 30))
	image.fill_rect(Rect2i(135, 190, 16, 42), Color.from_rgba8(106, 65, 30))
	var feature: Dictionary = Prep.frame_features(image.get_data(), 256, image.get_used_rect(), Vector2i.ZERO)
	_check(feature["head_top_y"] == 40.0 and feature["body_height"] == 192.0,
		"large bronze buckler cannot replace the head/standing-height anchor")
	_check(feature["facing_proxy"] == "right", "face-to-cap direction survives warm shield contamination")
	var errors: Array = []
	var reference: Dictionary = Prep.reference_baseline(errors)
	_check(errors.is_empty() and reference["standing_height"] == 156.0,
		"actual production idle cap/sole localization agrees with its saved silhouette")