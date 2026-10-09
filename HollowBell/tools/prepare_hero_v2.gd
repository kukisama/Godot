extends SceneTree
## Standalone, Image-only preparation. No editor import, game load or generation.
## Default / --compare: all currently available known candidates -> QA only.
## Selection: --attack flow --motion motion_grounded --defense defense_compact
## Optional --ab edit_flow_ab_flare / --finish flow_finish override the family.
## All four inputs are validated in memory BEFORE any production PNG is written.

const Converter = preload("res://tools/prepare_assets.gd")
const CELL: Vector2i = Vector2i(256, 256)
const SIZE: Vector2i = Vector2i(1536, 1024)
const SOURCE: String = "res://assets/source/hero_v2_candidates"
const QA: String = "res://qa/hero-v2-art"
const TARGET_Y: float = 232.0
const CANDIDATES: Dictionary = {
	"flow_ab": "blade_a", "flow_finish": "blade_b",
	"stride_ab": "blade_a", "stride_finish": "blade_b",
	"counter_ab": "blade_a", "counter_finish": "blade_b",
	"defense_compact": "defense", "defense_agile": "defense",
	"motion_grounded": "motion", "motion_agile": "motion",
	"edit_flow_ab_sunburst": "blade_a", "edit_flow_ab_flare": "blade_a",
}
const OUTPUTS: Dictionary = {
	"motion": "res://assets/sprites/hero_v2_motion.png",
	"blade_a": "res://assets/sprites/hero_v2_blade_a.png",
	"blade_b": "res://assets/sprites/hero_v2_blade_b.png",
	"defense": "res://assets/sprites/hero_v2_defense.png",
}


func _initialize() -> void:
	var options: Dictionary = parse_args(OS.get_cmdline_user_args())
	if bool(options.get("help", false)):
		print("HERO_V2 --compare | --attack flow|stride|counter --motion NAME --defense NAME [--ab NAME] [--finish NAME]")
		quit(0)
		return
	var result: Dictionary = execute(options)
	for message: String in result["errors"]:
		push_error(message)
	print("HERO_V2_RESULT " + JSON.stringify({"mode": result["mode"],
		"ready": result["ready"], "errors": result["errors"], "production_paths": result["production_paths"],
		"analysis": result.get("analysis_path", ""), "human_selection_pending": result["mode"] == "compare"}))
	quit(0 if result["errors"].is_empty() else 1)


static func parse_args(args: PackedStringArray) -> Dictionary:
	var result: Dictionary = {"compare": false, "errors": [], "selection": {}}
	var values: Dictionary = {}
	var index: int = 0
	while index < args.size():
		var key: String = args[index]
		if key == "--help":
			result["help"] = true
		elif key == "--compare":
			result["compare"] = true
		elif key in ["--attack", "--motion", "--defense", "--ab", "--finish"]:
			if values.has(key) or index + 1 >= args.size() or args[index + 1].begins_with("--"):
				result["errors"].append("Missing/repeated selection argument: " + key)
				break
			index += 1
			values[key] = args[index].trim_suffix(".png")
		else:
			result["errors"].append("Unknown argument: " + key)
		index += 1
	if values.is_empty():
		result["compare"] = true
		return result
	if bool(result["compare"]):
		result["errors"].append("--compare cannot be combined with production selection arguments")
	var family: String = str(values.get("--attack", ""))
	if family not in ["flow", "stride", "counter"]:
		result["errors"].append("Selection requires --attack flow|stride|counter")
	var selection: Dictionary = {
		"blade_a": str(values.get("--ab", family + "_ab")),
		"blade_b": str(values.get("--finish", family + "_finish")),
		"motion": str(values.get("--motion", "")),
		"defense": str(values.get("--defense", "")),
	}
	for role: String in OUTPUTS:
		var name: String = selection[role]
		if not CANDIDATES.has(name) or CANDIDATES.get(name, "") != role:
			result["errors"].append("Missing/wrong-layout %s selection: %s" % [role, name])
	result["selection"] = selection
	return result


static func sequences(kind: String) -> Array[Dictionary]:
	if kind == "blade_a":
		return [{"name": "attack1", "start": 0, "count": 12, "grounded": true},
			{"name": "attack2", "start": 12, "count": 12, "grounded": true}]
	if kind == "blade_b":
		return [{"name": "finisher", "start": 0, "count": 12, "grounded": true},
			{"name": "heavy", "start": 12, "count": 12, "grounded": true}]
	if kind == "defense":
		return [{"name": "roll", "start": 0, "count": 12, "grounded": false},
			{"name": "guard", "start": 12, "count": 6, "grounded": true},
			{"name": "parry", "start": 18, "count": 6, "grounded": true}]
	return [{"name": "idle", "start": 0, "count": 6, "grounded": true},
		{"name": "jump", "start": 6, "count": 6, "grounded": false},
		{"name": "run", "start": 12, "count": 12, "grounded": true}]


static func execute(options: Dictionary, write_outputs: bool = true) -> Dictionary:
	var errors: Array = options.get("errors", []).duplicate()
	var compare: bool = bool(options.get("compare", true))
	var result: Dictionary = {"mode": "compare" if compare else "select", "errors": errors,
		"ready": [], "production_paths": {}, "prepared": {}}
	if not errors.is_empty():
		return result
	var protected_before: Dictionary = protected_hashes()
	var baseline: Dictionary = reference_baseline(errors)
	if not errors.is_empty():
		return result
	var requested: Array = CANDIDATES.keys() if compare else options["selection"].values()
	requested.sort()
	var entries: Dictionary = {}
	var missing: Array[String] = []
	for value: Variant in requested:
		var name: String = str(value)
		var path: String = SOURCE.path_join(name + ".png")
		if not FileAccess.file_exists(path):
			missing.append(name)
			if not compare:
				errors.append("Selected source is not available: " + path)
			continue
		var entry: Dictionary = prepare_candidate(name, baseline)
		entries[name] = entry
		if entry["errors"].is_empty():
			result["ready"].append(name)
		elif not compare:
			errors.append_array(entry["errors"])
		print("HERO_V2_CANDIDATE " + JSON.stringify({"name": name, "errors": entry["errors"],
			"standing_height": entry.get("standing_height", 0), "mapping": entry.get("layout", {}),
			"flags": entry.get("flags", [])}))
	# An image added by the existing generation queue is not an immutable violation.
	# Hash only old originals/environment/sprites and each candidate actually read.
	var integrity: Dictionary = hash_integrity(protected_before, protected_hashes())
	if not bool(integrity["unchanged"]):
		errors.append("Protected original/environment/sprite files changed during preparation")
	for name: String in entries:
		var entry: Dictionary = entries[name]
		entry["source_sha256_after"] = FileAccess.get_sha256(entry["source_path"])
		if entry["source_sha256_after"] != entry["source_sha256"]:
			errors.append("Candidate source bytes changed while processing: " + name)
	if not compare:
		if entries.size() != 4 or result["ready"].size() != 4:
			errors.append("Production selection requires FOUR validated, distinct 24-frame sheets")
		for name: String in entries:
			if not bool(entries[name].get("selection_safe", false)):
				errors.append("Unsafe selection; inspect measured flags first: " + name)
	if not errors.is_empty() and not compare:
		return result # fail closed: no QA or production writes on invalid selection
	if write_outputs:
		var directory_error: Error = DirAccess.make_dir_recursive_absolute(QA)
		if directory_error != OK:
			errors.append("Cannot create QA directory: " + error_string(directory_error))
			return result
		_save(contact(baseline["image"], 0, 6, float(baseline["target_pivot_x"])),
			QA.path_join("reference-idle-contact.png"), errors)
		for name: String in entries:
			var entry: Dictionary = entries[name]
			if not entry.has("image"):
				continue
			_save(entry["keyed"], QA.path_join(name + "-keyed.png"), errors)
			_save(entry["image"], QA.path_join(name + "-normalized.png"), errors)
			for seq: Dictionary in entry["sequences"]:
				var contact_path: String = QA.path_join(name + "-" + str(seq["name"]) + "-contact.png")
				_save(contact(entry["image"], int(seq["start"]), int(seq["count"]),
					float(baseline["target_pivot_x"])), contact_path, errors)
				seq["contact_path"] = contact_path
		if not compare and errors.is_empty():
			_write_selection(options["selection"], entries, errors, result["production_paths"])
	var report: Dictionary = {"schema": 1, "mode": result["mode"],
		"created_utc": Time.get_datetime_string_from_system(true), "ready_candidates": result["ready"],
		"missing_candidates": missing, "errors": errors, "production_paths": result["production_paths"],
		"reference": _public_reference(baseline), "integrity": integrity, "candidates": {},
		"human_selection_pending": compare,
		"scope": "PNG/matte/affine/content measurements and contacts, NOT a nuanced-motion quality score",
		"normalization": "One uniform scale and body-axis X pivot per sheet, boot-contact median per grounded cut sequence; jump inherits idle and roll inherits standing. Never frame-wise stretch, translation or bottom alignment.",
		"contact_legend": "Left-to-right authored frames; upper 128px tiles are whole-frame nearest previews on dark teal with y=232 guide, lower tiles are fixed native-resolution 128px head/torso crops. No duplicated frames.",
		"identity_limit": "Material/head/torso measurements are heuristics, not proof of character identity, anatomy, smoothness, a complete weapon drawing or orientation of a tucked roll."}
	for name: String in entries:
		var public_entry: Dictionary = entries[name].duplicate()
		public_entry.erase("image")
		public_entry.erase("keyed")
		report["candidates"][name] = public_entry
		result["prepared"][name] = entries[name]
	if write_outputs:
		# Check again AFTER saves; comparisons never touch existing production PNGs.
		report["integrity"] = hash_integrity(protected_before, protected_hashes())
		if not bool(report["integrity"]["unchanged"]):
			errors.append("Protected hashes differ after QA writes")
		var analysis_path: String = QA.path_join("analysis.json")
		var file: FileAccess = FileAccess.open(analysis_path, FileAccess.WRITE)
		if file == null:
			errors.append("Cannot write QA analysis: " + str(FileAccess.get_open_error()))
		else:
			file.store_string(JSON.stringify(report, "\t") + "\n")
			result["analysis_path"] = analysis_path
	result["report"] = report
	return result


static func _load(path: String) -> Image:
	var image: Image = Image.new()
	if image.load(ProjectSettings.globalize_path(path)) != OK or image.is_empty():
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image


static func median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var middle: int = floori(float(sorted.size()) * 0.5)
	return float(sorted[middle]) if sorted.size() % 2 else (float(sorted[middle - 1]) + float(sorted[middle])) * 0.5


static func reference_baseline(errors: Array) -> Dictionary:
	var path: String = "res://assets/sprites/hero_motion.png"
	var image: Image = _load(path)
	if image == null or image.get_size() != SIZE:
		errors.append("Existing normalized hero_motion.png is required as the actual-size reference")
		return {}
	var heights: Array = []
	var pivots: Array = []
	var contacts: Array = []
	var bounds: Array = []
	var features: Array[Dictionary] = []
	for frame: int in range(6):
		var tile: Image = image.get_region(Rect2i(frame * 256, 0, 256, 256))
		var rect: Rect2i = tile.get_used_rect()
		if not rect.has_area():
			errors.append("Empty existing idle reference: " + str(frame))
			continue
		var feature: Dictionary = frame_features(tile.get_data(), 256, rect, Vector2i.ZERO)
		if absf(float(feature["head_top_y"]) - float(rect.position.y)) > 6.0:
			errors.append("Existing idle cap localization does not match actual silhouette: " + str(frame))
		features.append(feature)
		bounds.append(_rect(rect))
		heights.append(rect.size.y)
		contacts.append(rect.end.y)
		pivots.append(feature["body_axis_x"])
	var baseline: Dictionary = {"path": path, "sha256": FileAccess.get_sha256(path), "image": image,
		"idle_frame_ids": [0, 1, 2, 3, 4, 5], "idle_used_rects": bounds,
		"standing_height": median(heights), "actual_idle_contact_y": median(contacts),
		"target_contact_y": TARGET_Y, "target_pivot_x": median(pivots), "features": features,
		"height_basis": "median get_used_rect height of the SIX existing production idle frames, not the generator's promised 174px"}
	if float(baseline["standing_height"]) < 100.0 or float(baseline["target_pivot_x"]) == 0.0:
		errors.append("Could not measure a safe existing standing size/body axis")
	print("HERO_V2_REFERENCE " + JSON.stringify({"standing_height": baseline["standing_height"],
		"actual_idle_contact_y": baseline["actual_idle_contact_y"], "target_pivot_x": baseline["target_pivot_x"],
		"target_contact_y": TARGET_Y, "idle_used_rects": bounds}))
	return baseline


static func _public_reference(baseline: Dictionary) -> Dictionary:
	var result: Dictionary = baseline.duplicate()
	result.erase("image")
	return result


@warning_ignore("integer_division")
static func prepare_candidate(name: String, reference: Dictionary) -> Dictionary:
	var path: String = SOURCE.path_join(name + ".png")
	var result: Dictionary = {"name": name, "kind": CANDIDATES[name], "source_path": path,
		"source_sha256": FileAccess.get_sha256(path), "errors": [], "flags": [], "selection_safe": false}
	var source: Image = _load(path)
	if source == null or source.get_size() != SIZE:
		result["errors"].append("Candidate must decode as 1536x1024 RGBA: " + name)
		return result
	var extraction: Dictionary = Converter.extract_atlas(source, CELL)
	var data: PackedByteArray = source.get_data()
	var features: Array[Dictionary] = []
	for frame: int in range(24):
		var rect: Rect2i = extraction["bounds"][frame]
		var origin: Vector2i = Vector2i(frame % 6, frame / 6) * CELL
		var feature: Dictionary = frame_features(data, SIZE.x, rect, origin, extraction["owners"], frame)
		features.append(feature)
		if int(feature["visible"]) < 100:
			result["errors"].append("Empty/insubstantial authored frame %s:%d" % [name, frame])
	if not result["errors"].is_empty():
		return result
	var mapping: Dictionary = plan_mapping(str(result["kind"]), extraction, features, reference)
	if mapping.has("error"):
		result["errors"].append(name + ": " + str(mapping["error"]))
		return result
	var layout: Dictionary = mapping["layout"]
	var image: Image = Converter.render_atlas(extraction, layout, CELL)
	var audit: Dictionary = sampling_audit(extraction, layout, image)
	var metrics: Dictionary = atlas_metrics(image)
	var seq_metrics: Array[Dictionary] = sequence_metrics(image, str(result["kind"]), metrics["frames"])
	result["keyed"] = source
	result["image"] = image
	result["matte"] = extraction["metrics"]
	result["source_frames"] = features
	result["standing_height"] = mapping["standing_height"]
	result["calibration"] = mapping["calibration"]
	result["layout"] = layout
	result["normalized_standing_height"] = float(mapping["standing_height"]) * float(layout["scale"])
	result["normalized_path"] = QA.path_join(name + "-normalized.png")
	result["keyed_path"] = QA.path_join(name + "-keyed.png")
	result["metrics"] = metrics
	result["source_pixel_alpha_progression"] = audit
	result["sequences"] = seq_metrics
	result["identity_head_torso"] = identity_summary(features, reference["features"])
	var outer: int = 0
	for frame: int in range(24):
		outer += int(features[frame]["atlas_outer_edge_pixels"])
	result["closed_weapon_extent"] = {"source_atlas_outer_edge_pixels": outer,
		"recovered_cross_cell_pixels": extraction["metrics"]["recovered_cross_cell_pixels"],
		"normalized_gutter_pixels": metrics["gutter_pixels"], "all_transformed_bounds_fit": mapping["bounds_fit"],
		"limit": "No source outer-edge truncation or affine crop; does not certify weapon/hand anatomy."}
	if outer > 0:
		result["flags"].append("source_outer_edge_truncation_risk:%d" % outer)
	if float(mapping["fit_ratio"]) < 0.98:
		result["flags"].append("cannot_reach_reference_body_size_without_crop:ratio=%.4f" % float(mapping["fit_ratio"]))
	for seq: Dictionary in seq_metrics:
		if not seq["exact_duplicate_pairs"].is_empty():
			result["flags"].append(str(seq["name"]) + ":EXACT_COPIED_FRAMES")
		if not seq["near_held_pose_pairs"].is_empty():
			result["flags"].append(str(seq["name"]) + ":near_repeated_pose_proxy_review_contacts")
		if not seq["translation_only_pairs"].is_empty():
			result["flags"].append(str(seq["name"]) + ":TRANSLATION_ONLY_POSES")
		if not seq["left_facing_frames"].is_empty():
			result["flags"].append(str(seq["name"]) + ":left_facing_proxy_review_contacts")
	if int(metrics["empty_cells"]) != 0 or int(metrics["connected_key_pixels"]) != 0 \
			or int(metrics["flat_key_pixels"]) != 0 or int(metrics["gutter_pixels"]) != 0 \
			or int(audit["rgba_mismatches"]) != 0 or not bool(mapping["bounds_fit"]):
		result["errors"].append("Failed saved-image matte/extent/source-sampling contract: " + name)
	var copied: bool = false
	var orientation_review: bool = false
	for seq: Dictionary in seq_metrics:
		copied = copied or not seq["exact_duplicate_pairs"].is_empty() or not seq["translation_only_pairs"].is_empty()
		orientation_review = orientation_review or not seq["left_facing_frames"].is_empty()
	# Face/cap occlusion is only a proxy (a raised hand/blade can fool it).
	# Keep the evidence, NEVER mirror art or veto an explicit human selection
	# using it. Structural errors and exact copies still fail closed.
	result["orientation_requires_visual_review"] = orientation_review
	result["selection_validation_scope"] = "Structural PNG/matte/affine/source-pixel/size/duplicate checks only. Explicit four-sheet selection acknowledges advisory pose/orientation contacts; NOT automatic artistic approval."
	result["selection_safe"] = result["errors"].is_empty() and outer == 0 \
		and float(mapping["fit_ratio"]) >= 0.98 and not copied
	return result


static func frame_features(data: PackedByteArray, width: int, bounds: Rect2i, origin: Vector2i,
		owners: PackedInt32Array = PackedInt32Array(), owner: int = -1) -> Dictionary:
	var visible: int = 0
	var opaque: int = 0
	var partial: int = 0
	var outer: int = 0
	var palette: Dictionary = {"burgundy": 0, "navy_blue": 0, "bronze": 0, "neutral_metal": 0}
	var blue_x: Array = []
	var boots: Array[Vector2i] = []
	var skin: Array[Vector2i] = []
	var metal: Array[Vector2i] = []
	var histogram: Array[int] = [0, 0, 0]
	var height: int = floori(float(data.size()) / (4.0 * width))
	for y: int in range(maxi(0, bounds.position.y), mini(height, bounds.end.y)):
		for x: int in range(maxi(0, bounds.position.x), mini(width, bounds.end.x)):
			var pixel: int = y * width + x
			if not owners.is_empty() and owners[pixel] != owner:
				continue
			var i: int = pixel * 4
			var alpha: int = data[i + 3]
			if alpha == 0:
				continue
			visible += 1
			if alpha == 255:
				opaque += 1
			else:
				partial += 1
			histogram[2 if alpha == 255 else (1 if alpha >= 96 else 0)] += 1
			if x == 0 or x == width - 1 or y == 0 or y == height - 1:
				outer += 1
			if alpha < 96:
				continue
			var r: int = data[i]
			var g: int = data[i + 1]
			var b: int = data[i + 2]
			var local: Vector2i = Vector2i(x, y) - origin
			if r >= 55 and r > b * 1.6 and g < r * 0.55 and b >= 12:
				palette["burgundy"] += 1
			if b >= 30 and b > r * 1.15 and g >= r * 0.85:
				palette["navy_blue"] += 1
				if local.y > 45 and local.y < 205 and local.x > 45 and local.x < 215:
					blue_x.append(local.x)
			if r >= 65 and r > g * 1.15 and g > b * 1.5:
				palette["bronze"] += 1
			if mini(r, mini(g, b)) >= 70 and maxi(r, maxi(g, b)) - mini(r, mini(g, b)) <= 65:
				palette["neutral_metal"] += 1
				metal.append(local)
			if local.y >= 145 and r >= 35 and r <= 180 and r > g * 1.13 and g > b * 1.2 and g >= 17:
				boots.append(local)
			if local.y < 160 and r >= 105 and g >= 60 and b >= 38 \
					and r > g * 1.1 and r < g * 2.0 and g > b * 1.15 and g < b * 2.3:
				skin.append(local)
	var body_x: float = median(blue_x)
	var face_xs: Array = []
	var face_ys: Array = []
	for point: Vector2i in skin:
		if point.x >= body_x - 6 and point.x <= body_x + 56:
			face_xs.append(point.x)
			face_ys.append(point.y)
	# Bronze buckler/hilt pixels also resemble skin. Anchor the upper skin band,
	# then isolate a connected cap, instead of using the entire warm ROI median.
	if not face_ys.is_empty():
		face_ys.sort()
		var upper_skin_y: float = float(face_ys[floori(float(face_ys.size()) * 0.10)])
		face_xs.clear()
		face_ys.clear()
		for point: Vector2i in skin:
			if point.x >= body_x - 6 and point.x <= body_x + 56 \
					and point.y >= upper_skin_y - 8 and point.y <= upper_skin_y + 20:
				face_xs.append(point.x)
				face_ys.append(point.y)
	var face_x: float = median(face_xs)
	var face_y: float = median(face_ys)
	var cap_xs: Array = []
	var cap_ys: Array = []
	for point: Vector2i in _cap_component(metal, Vector2(face_x, face_y)):
		cap_xs.append(point.x)
		cap_ys.append(point.y)
	var boot_bottom: int = -1
	var boot_floor_xs: Array = []
	for point: Vector2i in boots:
		boot_bottom = maxi(boot_bottom, point.y)
	for point: Vector2i in boots:
		if point.y >= boot_bottom - 8:
			boot_floor_xs.append(point.x)
	# Include the boot's dark sole just below the warm leather, not cape/sword bbox.
	if not boot_floor_xs.is_empty():
		var left: int = int(boot_floor_xs.min()) - 1
		var right: int = int(boot_floor_xs.max()) + 2
		var warm_bottom: int = boot_bottom
		for local_y: int in range(warm_bottom + 1, warm_bottom + 4):
			for local_x: int in range(left, right):
				var sx: int = origin.x + local_x
				var sy: int = origin.y + local_y
				if sx < 0 or sx >= width or sy < 0 or sy >= height:
					continue
				var pixel: int = sy * width + sx
				if data[pixel * 4 + 3] >= 96 and (owners.is_empty() or owners[pixel] == owner):
					boot_bottom = maxi(boot_bottom, local_y)
	var head_top: float = float(cap_ys.min()) if not cap_ys.is_empty() else 0.0
	var contact_y: float = float(boot_bottom + 1) if boot_bottom >= 0 else 0.0
	var delta: float = face_x - median(cap_xs)
	var valid_head: bool = cap_xs.size() >= 12 and face_xs.size() >= 8
	return {"visible": visible, "opaque": opaque, "partial_alpha": partial,
		"visible_alpha_histogram_1to95_96to254_255": histogram, "bounds": _rect(Rect2i(bounds.position - origin, bounds.size)),
		"body_axis_x": body_x, "boot_contact_y": contact_y, "boot_color_samples": boots.size(),
		"head_top_y": head_top, "body_height": contact_y - head_top,
		"head_samples": cap_xs.size(), "face_samples": face_xs.size(),
		"head_width": float(cap_xs.max()) - float(cap_xs.min()) + 1.0 if valid_head else 0.0,
		"face_anchor_xy": [face_x, face_y],
		"face_minus_cap_center_x": delta, "facing_proxy": ("right" if delta >= 1.5 else ("left" if delta <= -1.5 else "uncertain")) if valid_head else "unmeasurable",
		"standing_probe_valid": valid_head and boots.size() >= 20 and body_x > 0.0,
		"palette_pixels": palette, "atlas_outer_edge_pixels": outer}


static func _cap_component(points: Array[Vector2i], face: Vector2) -> Array[Vector2i]:
	var mask: Dictionary = {}
	for point: Vector2i in points:
		if point.x >= face.x - 32 and point.x <= face.x + 18 and point.y >= face.y - 35 and point.y <= face.y + 2:
			mask[point] = false
	var best: Array[Vector2i] = []
	var best_score: float = -1.0
	for seed: Vector2i in mask:
		if bool(mask[seed]):
			continue
		var component: Array[Vector2i] = [seed]
		mask[seed] = true
		var head: int = 0
		var center: Vector2 = Vector2.ZERO
		while head < component.size():
			var point: Vector2i = component[head]
			head += 1
			center += Vector2(point)
			for dy: int in range(-1, 2):
				for dx: int in range(-1, 2):
					var neighbor: Vector2i = point + Vector2i(dx, dy)
					if mask.has(neighbor) and not bool(mask[neighbor]):
						mask[neighbor] = true
						component.append(neighbor)
		center /= component.size()
		var score: float = component.size() / (1.0 + absf(center.x - face.x + 10.0) * 0.08
			+ absf(center.y - face.y + 10.0) * 0.04)
		if score > best_score:
			best = component
			best_score = score
	return best


@warning_ignore("integer_division")
static func plan_mapping(kind: String, extraction: Dictionary, features: Array[Dictionary], reference: Dictionary) -> Dictionary:
	var probes: Array = range(6) if kind == "motion" else ([0, 11, 12, 17, 18, 23] if kind == "defense" else [0, 1, 4, 5, 10, 11, 12, 13, 18, 19, 22, 23])
	var max_height: float = 0.0
	for frame: int in probes:
		if bool(features[frame]["standing_probe_valid"]):
			max_height = maxf(max_height, float(features[frame]["body_height"]))
	var heights: Array = []
	var contacts: Array = []
	var pivots: Array = []
	var used: Array[int] = []
	for frame: int in probes:
		var feature: Dictionary = features[frame]
		if bool(feature["standing_probe_valid"]) and float(feature["body_height"]) >= max_height * 0.85:
			used.append(frame)
			heights.append(feature["body_height"])
			contacts.append(feature["boot_contact_y"])
			pivots.append(feature["body_axis_x"])
	if used.is_empty() or median(heights) < 100.0:
		return {"error": "No reliable upright cap/face/boot standing probe; refusing bbox-stretch fallback"}
	var body_height: float = median(heights)
	var standing_contact: float = median(contacts)
	var desired: float = float(reference["standing_height"]) / body_height
	var source_pivot: float = median(pivots)
	var baselines: Array = [standing_contact, standing_contact, standing_contact, standing_contact]
	var sequence_contacts: Dictionary = {}
	for seq: Dictionary in sequences(kind):
		var values: Array = []
		if bool(seq["grounded"]):
			for frame: int in range(int(seq["start"]), int(seq["start"]) + int(seq["count"])):
				var feature: Dictionary = features[frame]
				if int(feature["boot_color_samples"]) >= 20:
					values.append(feature["boot_contact_y"])
		var baseline: float = median(values) if not values.is_empty() else standing_contact
		sequence_contacts[seq["name"]] = {"contact_y": baseline, "samples": values,
			"basis": "standing reference, displacement preserved" if not bool(seq["grounded"]) else "median boot/sole contact of the entire cut sequence"}
		for row: int in range(int(seq["start"]) / 6, (int(seq["start"]) + int(seq["count"])) / 6):
			baselines[row] = baseline
	var x_min: float = INF
	var x_max: float = -INF
	var y_min: float = INF
	var y_max: float = -INF
	for frame: int in range(24):
		var rect: Rect2i = extraction["bounds"][frame]
		var origin: Vector2i = Vector2i(frame % 6, frame / 6) * CELL
		x_min = minf(x_min, float(rect.position.x - origin.x) - source_pivot)
		x_max = maxf(x_max, float(rect.end.x - origin.x) - source_pivot)
		y_min = minf(y_min, float(rect.position.y - origin.y) - float(baselines[frame / 6]))
		y_max = maxf(y_max, float(rect.end.y - origin.y) - float(baselines[frame / 6]))
	var target_x: float = float(reference["target_pivot_x"])
	var scale: float = desired
	if x_min < 0.0:
		scale = minf(scale, (target_x - 2.0) / -x_min)
	if x_max > 0.0:
		scale = minf(scale, (254.0 - target_x) / x_max)
	if y_min < 0.0:
		scale = minf(scale, (TARGET_Y - 2.0) / -y_min)
	if y_max > 0.0:
		scale = minf(scale, (254.0 - TARGET_Y) / y_max)
	var offset_x: float = target_x + scale * (128.0 - source_pivot)
	var fit: bool = target_x + scale * x_min >= 1.999 and target_x + scale * x_max <= 254.001 \
		and TARGET_Y + scale * y_min >= 1.999 and TARGET_Y + scale * y_max <= 254.001
	return {"standing_height": body_height, "fit_ratio": scale / desired, "bounds_fit": fit,
		"calibration": {"probe_frame_ids": used, "body_heights": heights, "standing_contacts": contacts,
			"source_body_axis_x": source_pivot, "requested_scale": desired, "sequence_contacts": sequence_contacts},
		"layout": {"scale": scale, "offset_x": offset_x, "target_y": TARGET_Y, "baselines": baselines,
			"gutter": 2, "source_body_axis_x": source_pivot, "target_body_axis_x": target_x,
			"target_standing_height": reference["standing_height"], "x_min": x_min + source_pivot - 128.0,
			"x_max": x_max + source_pivot - 128.0, "y_min": y_min, "y_max": y_max}}


@warning_ignore("integer_division")
static func sampling_audit(extraction: Dictionary, layout: Dictionary, image: Image) -> Dictionary:
	var before: PackedByteArray = extraction["image"].get_data()
	var after: PackedByteArray = image.get_data()
	var owners: PackedInt32Array = extraction["owners"]
	var exact: int = 0
	var mismatch: int = 0
	var alpha_mismatch: int = 0
	var cleared: int = 0
	var scale: float = float(layout["scale"])
	for frame: int in range(24):
		var row: int = frame / 6
		var column: int = frame % 6
		for y: int in range(2, 254):
			var sy: int = row * 256 + floori((y + 0.5 - float(layout["target_y"])) / scale + float(layout["baselines"][row]))
			for x: int in range(2, 254):
				var sx: int = column * 256 + floori((x + 0.5 - float(layout["offset_x"])) / scale + 128.0)
				var j: int = ((row * 256 + y) * SIZE.x + column * 256 + x) * 4
				if sy < 0 or sy >= SIZE.y or sx < 0 or sx >= SIZE.x or owners[sy * SIZE.x + sx] != frame:
					if after[j + 3] > 0:
						mismatch += 1
					continue
				var i: int = (sy * SIZE.x + sx) * 4
				if before[i + 3] > 0 and after[j + 3] == 0:
					cleared += 1
					continue
				if after[j + 3] == 0:
					continue
				exact += 1
				if after[j] != before[i] or after[j + 1] != before[i + 1] or after[j + 2] != before[i + 2] or after[j + 3] != before[i + 3]:
					mismatch += 1
				if after[j + 3] != before[i + 3]:
					alpha_mismatch += 1
	if cleared != int(layout["resampled_key_cleared"]):
		mismatch += absi(cleared - int(layout["resampled_key_cleared"]))
	return {"exact_source_rgba_pixels": exact, "rgba_mismatches": mismatch,
		"alpha_mismatches": alpha_mismatch, "only_post_resample_connected_key_removed": cleared,
		"method": "Independent inverse affine lookup into keyed source + original connected-component frame owner. Nearest neighbor; no old poses, fabricated pixels or alpha interpolation."}


@warning_ignore("integer_division")
static func atlas_metrics(image: Image) -> Dictionary:
	var result: Dictionary = {"nonempty_cells": 0, "empty_cells": 0, "connected_key_pixels": 0,
		"flat_key_pixels": 0, "gutter_pixels": 0, "frames": []}
	for frame: int in range(24):
		var tile: Image = image.get_region(Rect2i((frame % 6) * 256, (frame / 6) * 256, 256, 256))
		var data: PackedByteArray = tile.get_data()
		var feature: Dictionary = frame_features(data, 256, tile.get_used_rect(), Vector2i.ZERO)
		var key: Dictionary = key_metrics(data)
		feature.merge(key)
		feature["frame"] = frame
		result["frames"].append(feature)
		result["nonempty_cells"] += 1 if int(feature["visible"]) > 0 else 0
		result["empty_cells"] += 1 if int(feature["visible"]) == 0 else 0
		for field: String in ["connected_key_pixels", "flat_key_pixels", "gutter_pixels"]:
			result[field] += int(key[field])
	return result


static func key_metrics(data: PackedByteArray) -> Dictionary:
	var candidates: PackedByteArray = PackedByteArray()
	candidates.resize(65536)
	var queue: Array[int] = []
	var flat: int = 0
	var gutter: int = 0
	for pixel: int in range(65536):
		var i: int = pixel * 4
		if data[i + 3] == 0:
			continue
		var r: int = data[i]
		var g: int = data[i + 1]
		var b: int = data[i + 2]
		if pixel % 256 < 2 or pixel % 256 >= 254 or pixel < 512 or pixel >= 65024:
			gutter += 1
		if r >= 220 and b >= 220 and g <= 18 and absi(r - b) <= 24:
			flat += 1
		var low: int = mini(r, b)
		var high: int = maxi(r, b)
		if low - g >= 20 and g * 3 <= low and high - low <= maxi(8, int(high * 0.18)):
			candidates[pixel] = 1
	for pixel: int in range(65536):
		if candidates[pixel] != 1:
			continue
		for delta: int in [-257, -256, -255, -1, 1, 255, 256, 257]:
			var other: int = pixel + delta
			if other >= 0 and other < 65536 and absi(other % 256 - pixel % 256) <= 1 and data[other * 4 + 3] == 0:
				candidates[pixel] = 2
				queue.append(pixel)
				break
	var head: int = 0
	while head < queue.size():
		var pixel: int = queue[head]
		head += 1
		for delta: int in [-257, -256, -255, -1, 1, 255, 256, 257]:
			var other: int = pixel + delta
			if other >= 0 and other < 65536 and absi(other % 256 - pixel % 256) <= 1 and candidates[other] == 1:
				candidates[other] = 2
				queue.append(other)
	return {"connected_key_pixels": queue.size(), "flat_key_pixels": flat, "gutter_pixels": gutter}


@warning_ignore("integer_division")
static func sequence_metrics(image: Image, kind: String, features: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for spec: Dictionary in sequences(kind):
		var seq: Dictionary = spec.duplicate()
		seq.merge({"adjacency": [], "exact_duplicate_pairs": [], "near_held_pose_pairs": [],
			"translation_only_pairs": [], "left_facing_frames": [], "uncertain_facing_frames": [], "frame_ids": []})
		var hashes: Dictionary = {}
		var silhouettes: Dictionary = {}
		var previous: PackedByteArray = PackedByteArray()
		var contacts: Array = []
		var head_tops: Array = []
		for frame: int in range(int(spec["start"]), int(spec["start"]) + int(spec["count"])):
			seq["frame_ids"].append(frame)
			var tile: Image = image.get_region(Rect2i((frame % 6) * 256, (frame / 6) * 256, 256, 256))
			var data: PackedByteArray = tile.get_data()
			var hash: String = _bytes_sha256(data)
			if hashes.has(hash):
				seq["exact_duplicate_pairs"].append([hashes[hash], frame])
			hashes[hash] = frame
			var rect: Rect2i = tile.get_used_rect()
			var tight_hash: String = _bytes_sha256(tile.get_region(rect).get_data()) + str(rect.size)
			if silhouettes.has(tight_hash) and silhouettes[tight_hash]["position"] != rect.position:
				seq["translation_only_pairs"].append([silhouettes[tight_hash]["frame"], frame])
			silhouettes[tight_hash] = {"frame": frame, "position": rect.position}
			if not previous.is_empty():
				var difference: Dictionary = pose_difference(previous, data)
				difference["from"] = frame - 1
				difference["to"] = frame
				seq["adjacency"].append(difference)
				# Texture/palette jitter must not hide an almost unchanged pose.
				if float(difference["silhouette_iou"]) >= 0.90:
					seq["near_held_pose_pairs"].append([frame - 1, frame])
			previous = data
			contacts.append(features[frame]["boot_contact_y"])
			head_tops.append(features[frame]["head_top_y"])
			# Inverted/tucked rolls have no reliable left/right face proxy.
			if str(spec["name"]) != "roll":
				if features[frame]["facing_proxy"] == "left":
					seq["left_facing_frames"].append(frame)
				elif features[frame]["facing_proxy"] in ["uncertain", "unmeasurable"]:
					seq["uncertain_facing_frames"].append(frame)
		seq["boot_contact_progression"] = contacts
		seq["head_top_progression"] = head_tops
		seq["quality_limit"] = "Adjacency/duplicate/face proxies require visual review; high IoU can be a held pose OR a small legitimate animation step. No automatic winner."
		result.append(seq)
	return result


static func pose_difference(a: PackedByteArray, b: PackedByteArray) -> Dictionary:
	var changed: int = 0
	var union_count: int = 0
	var intersection: int = 0
	for i: int in range(0, a.size(), 4):
		var visible_a: bool = a[i + 3] >= 96
		var visible_b: bool = b[i + 3] >= 96
		if not visible_a and not visible_b:
			continue
		union_count += 1
		if visible_a and visible_b:
			intersection += 1
		if absi(a[i + 3] - b[i + 3]) >= 32 or absi(a[i] - b[i]) + absi(a[i + 1] - b[i + 1]) + absi(a[i + 2] - b[i + 2]) >= 36:
			changed += 1
	return {"visible_union": union_count, "changed_visible_pixels": changed,
		"changed_visible_ratio": float(changed) / maxi(1, union_count),
		"silhouette_iou": float(intersection) / maxi(1, union_count), "silhouette_xor": union_count - intersection}


static func identity_summary(features: Array[Dictionary], original: Array) -> Dictionary:
	var head_widths: Array = []
	var blue_pixels: Array = []
	var heights: Array = []
	var original_heads: Array = []
	var palette: Dictionary = {"burgundy": [], "navy_blue": [], "bronze": [], "neutral_metal": []}
	for feature: Dictionary in features:
		if bool(feature["standing_probe_valid"]):
			head_widths.append(feature["head_width"])
			heights.append(feature["body_height"])
		blue_pixels.append(feature["palette_pixels"]["navy_blue"])
		for material: String in palette:
			palette[material].append(float(feature["palette_pixels"][material]) / maxi(1, int(feature["visible"])))
	for feature: Dictionary in original:
		original_heads.append(feature["head_width"])
	var fractions: Dictionary = {}
	for material: String in palette:
		fractions[material] = median(palette[material])
	return {"head_width": distribution(head_widths), "standing_body_height": distribution(heights),
		"torso_navy_pixel_count": distribution(blue_pixels), "palette_visible_fraction_medians": fractions,
		"original_head_width_median": median(original_heads),
		"limit": "Unscaled source feature variation includes foreshortening/occlusion; not a biometric or anatomy score."}


static func distribution(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var total: float = 0.0
	for value: Variant in values:
		total += float(value)
	var mean: float = total / values.size()
	var variance: float = 0.0
	for value: Variant in values:
		variance += pow(float(value) - mean, 2.0)
	return {"count": values.size(), "min": values.min(), "median": median(values), "max": values.max(),
		"coefficient_of_variation": sqrt(variance / values.size()) / maxf(1.0, mean)}


@warning_ignore("integer_division")
static func contact(image: Image, start: int, count: int, pivot_x: float) -> Image:
	var canvas: Image = Image.create(count * 128, 256, false, Image.FORMAT_RGBA8)
	canvas.fill(Color.from_rgba8(15, 36, 42))
	for index: int in range(count):
		var frame: int = start + index
		var tile: Image = image.get_region(Rect2i((frame % 6) * 256, (frame / 6) * 256, 256, 256))
		var crop_x: int = clampi(roundi(pivot_x) - 64, 0, 128)
		var detail: Image = tile.get_region(Rect2i(crop_x, 64, 128, 128))
		tile.resize(128, 128, Image.INTERPOLATE_NEAREST)
		canvas.fill_rect(Rect2i(index * 128, 116, 128, 1), Color.from_rgba8(40, 77, 78))
		canvas.fill_rect(Rect2i(index * 128 + roundi(pivot_x * 0.5), 0, 1, 128), Color.from_rgba8(25, 51, 57))
		canvas.blend_rect(tile, Rect2i(0, 0, 128, 128), Vector2i(index * 128, 0))
		canvas.blend_rect(detail, Rect2i(0, 0, 128, 128), Vector2i(index * 128, 128))
		canvas.fill_rect(Rect2i(index * 128, 0, 1, 256), Color.from_rgba8(44, 63, 67))
	return canvas


static func protected_hashes() -> Dictionary:
	var result: Dictionary = {}
	for directory: String in ["res://assets/source", "res://assets/environment", "res://assets/sprites"]:
		for name: String in DirAccess.get_files_at(directory):
			if name.ends_with(".png") and not name.begins_with("hero_v2_"):
				var path: String = directory.path_join(name)
				result[path] = FileAccess.get_sha256(path)
	for path: String in ["res://tools/prepare_assets.gd", "res://tests/test_assets.gd"]:
		result[path] = FileAccess.get_sha256(path)
	return result


static func hash_integrity(before: Dictionary, after: Dictionary) -> Dictionary:
	var changed: Array[String] = []
	for path: String in before:
		if before[path] != after.get(path, "MISSING"):
			changed.append(path)
	for path: String in after:
		if not before.has(path):
			changed.append(path)
	return {"unchanged": changed.is_empty(), "protected_file_count": before.size(),
		"changed_paths": changed, "before_sha256": before, "after_sha256": after,
		"scope": "All original top-level source PNGs, ALL environment PNGs, existing hero/enemy sprites and shared preparation/test scripts; candidate additions from the live queue excluded."}


static func _rect(rect: Rect2i) -> Array[int]:
	return [rect.position.x, rect.position.y, rect.size.x, rect.size.y]


static func _bytes_sha256(data: PackedByteArray) -> String:
	var hashing: HashingContext = HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(data)
	return hashing.finish().hex_encode()


static func _save(image: Image, path: String, errors: Array) -> void:
	var error: Error = image.save_png(path)
	if error != OK:
		errors.append("Cannot save %s: %s" % [path, error_string(error)])
		return
	var saved: Image = _load(path)
	if saved == null or saved.get_size() != image.get_size() or saved.get_data() != image.get_data():
		errors.append("Saved PNG did not round-trip exact RGBA pixels: " + path)


static func _write_selection(selection: Dictionary, entries: Dictionary, errors: Array, paths: Dictionary) -> void:
	# Only these four explicit production names, with in-memory rollback on I/O failure.
	var previous: Dictionary = {}
	var written: Array[String] = []
	for role: String in OUTPUTS:
		var path: String = OUTPUTS[role]
		previous[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	for role: String in OUTPUTS:
		var path: String = OUTPUTS[role]
		written.append(path)
		_save(entries[selection[role]]["image"], path, errors)
		if not errors.is_empty():
			for restore_path: String in written:
				if previous[restore_path] == null:
					if FileAccess.file_exists(restore_path):
						DirAccess.remove_absolute(restore_path)
				else:
					var file: FileAccess = FileAccess.open(restore_path, FileAccess.WRITE)
					if file != null:
						file.store_buffer(previous[restore_path])
			paths.clear()
			return
		paths[role] = {"path": path, "source": entries[selection[role]]["source_path"],
			"frames": 24, "size": [1536, 1024], "mapping": entries[selection[role]]["layout"]}