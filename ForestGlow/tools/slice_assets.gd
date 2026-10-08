extends SceneTree
## Rebuild six transparent sprites directly from the generated 3-by-2 sheet.

func _initialize() -> void:
	var source := Image.load_from_file("res://assets/source/sprites.png")
	if source == null:
		push_error("Generated sprites.png is missing.")
		quit(1)
		return
	source.convert(Image.FORMAT_RGBA8)
	DirAccess.make_dir_recursive_absolute("res://assets/sprites")
	var names := ["amber", "blue", "star", "spore", "sparkle", "leaf"]
	for index in range(6):
		var col := index % 3
		var row := index / 3
		var x0 := roundi(col * source.get_width() / 3.0)
		var x1 := roundi((col + 1) * source.get_width() / 3.0)
		var y0 := roundi(row * source.get_height() / 2.0)
		var y1 := roundi((row + 1) * source.get_height() / 2.0)
		var cell := source.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))
		for y in range(cell.get_height()):
			for x in range(cell.get_width()):
				var color := cell.get_pixel(x, y)
				# Magenta is deliberately absent from the illustrated objects.
				var spill := minf(color.r, color.b) - color.g
				if spill > 0.12:
					color.a *= 1.0 - smoothstep(0.12, 0.48, spill)
					# Remove the pink fringe on anti-aliased silhouette pixels.
					if color.a > 0.0 and color.a < 1.0:
						color.r = minf(color.r, color.g + 0.10)
						color.b = minf(color.b, color.g + 0.10)
				cell.set_pixel(x, y, color)
		var bounds := cell.get_used_rect()
		if bounds.size.x < 24 or bounds.size.y < 24:
			push_error("Empty sprite cell: " + names[index])
			quit(1)
			return
		var cropped := cell.get_region(bounds)
		var scale_factor := 220.0 / maxf(bounds.size.x, bounds.size.y)
		cropped.resize(maxi(1, roundi(bounds.size.x * scale_factor)), maxi(1, roundi(bounds.size.y * scale_factor)), Image.INTERPOLATE_LANCZOS)
		var result := Image.create(256, 256, false, Image.FORMAT_RGBA8)
		result.fill(Color.TRANSPARENT)
		result.blit_rect(cropped, Rect2i(Vector2i.ZERO, cropped.get_size()), (Vector2i(256, 256) - cropped.get_size()) / 2)
		var path: String = "res://assets/sprites/" + names[index] + ".png"
		if result.save_png(path) != OK:
			push_error("Could not save " + path)
			quit(1)
			return
		print("SLICED ", names[index], " bounds=", bounds, " output=256x256 RGBA")
	print("SPRITE_SLICING_OK: 6 transparent PNGs")
	quit()