extends Node2D
## All gameplay goes through mouse input; no keyboard is required.

const ROUND_TIME := 45.0
const GOAL := 36
const CREAM := Color("f8edce")
const MINT := Color("91d4c7")
const GOLD := Color("ffd783")
const INK := Color("102c32")
const SLOTS := [Vector2(492, 337), Vector2(766, 316), Vector2(1036, 347), Vector2(525, 545), Vector2(800, 540), Vector2(1064, 558)]
const KINDS := ["amber", "blue", "star", "spore"]

var state := "menu"
var score := 0
var combo := 0
var best_combo := 0
var best_score := 0
var remaining := ROUND_TIME
var elapsed := 0.0
var spawn_clock := 0.0
var world_clock := 0.0
var muted := false
var test_mode := false
var targets: Array[Dictionary] = []
var particles: Array[Dictionary] = []
var floaters: Array[Dictionary] = []
var textures: Dictionary = {}
var sounds: Dictionary = {}
var rng := RandomNumberGenerator.new()
var background: Texture2D
var font := SystemFont.new()
var ui: Control
var overlay: Control
var labels: Dictionary = {}
var pause_button: Button
var sound_button: Button
var toast := "让微光在你的指尖聚拢。"
var toast_clock := 0.0
var flash := 0.0

func _ready() -> void:
	test_mode = "--test-mode" in OS.get_cmdline_user_args()
	rng.randomize()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC"])
	background = load("res://assets/source/forest.png")
	for kind in ["amber", "blue", "star", "spore", "sparkle", "leaf"]:
		textures[kind] = load("res://assets/sprites/" + kind + ".png")
	if not test_mode:
		var save := ConfigFile.new()
		if save.load("user://best.cfg") == OK:
			best_score = int(save.get_value("record", "score", 0))
	_make_sounds()
	_build_ui()
	_show_menu()

func _box(rect: Rect2, fill: Color, border: Color, radius: int = 22) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	draw_style_box(style, rect)

func _draw() -> void:
	if background:
		draw_texture_rect(background, Rect2(0, 0, 1280, 800), false)
	draw_rect(Rect2(0, 0, 1280, 800), Color(0.015, 0.065, 0.085, 0.20))
	# Tiny ambient fireflies, separate from clickable collectibles.
	for i in range(30):
		var p := Vector2(fmod(i * 137.7 + sin(world_clock * 0.25 + i) * 35.0, 1280.0), 145.0 + fmod(i * 83.2, 580.0))
		p.y += sin(world_clock * 0.7 + i * 2.0) * 16.0
		var alpha := 0.22 + 0.24 * (0.5 + 0.5 * sin(world_clock * 1.6 + i))
		draw_circle(p, 6.0, Color(1.0, 0.83, 0.42, alpha * 0.12))
		draw_circle(p, 1.6, Color(1.0, 0.91, 0.62, alpha))
	_box(Rect2(28, 24, 1224, 90), Color(0.025, 0.10, 0.13, 0.94), Color(0.65, 0.83, 0.73, 0.22))
	_box(Rect2(28, 146, 316, 536), Color(0.035, 0.13, 0.15, 0.91), Color(0.65, 0.83, 0.73, 0.22))
	_box(Rect2(374, 705, 878, 65), Color(0.025, 0.10, 0.13, 0.92), Color(0.65, 0.83, 0.73, 0.22), 18)
	# A physical ring marks each spawn point even while empty.
	for slot in SLOTS:
		draw_set_transform(slot + Vector2(0, 39), 0.0, Vector2(1.0, 0.31))
		draw_circle(Vector2.ZERO, 71, Color(0.01, 0.055, 0.055, 0.43))
		draw_arc(Vector2.ZERO, 65, 0, TAU, 64, Color(0.69, 0.84, 0.64, 0.30), 3, true)
		draw_set_transform(Vector2.ZERO)
	for target in targets:
		_draw_target(target)
	for particle in particles:
		var color: Color = particle.color
		color.a *= clampf(particle.life / particle.max_life, 0.0, 1.0)
		if int(particle.shape) == 0:
			draw_texture_rect(textures.sparkle, Rect2(particle.pos - Vector2.ONE * particle.size, Vector2.ONE * particle.size * 2), false, color)
		else:
			draw_circle(particle.pos, particle.size * color.a, color)
	for floater in floaters:
		var color: Color = floater.color
		color.a *= minf(1.0, floater.life * 2.0)
		draw_string(font, floater.pos, floater.text, HORIZONTAL_ALIGNMENT_CENTER, 180, 25, color)
	# The progress bar is always the same scale as the score label.
	_box(Rect2(55, 573, 262, 13), Color("213f43"), Color.TRANSPARENT, 6)
	if score > 0:
		_box(Rect2(55, 573, 262 * minf(float(score) / GOAL, 1.0), 13), GOLD, Color.TRANSPARENT, 6)
	for index in range(3):
		var kind: String = ["amber", "star", "spore"][index]
		draw_texture_rect(textures[kind], Rect2(46, 314 + index * 73, 65, 65), false)
	if flash > 0.0:
		draw_rect(Rect2(0, 0, 1280, 800), Color(0.90, 0.43, 0.25, flash * 0.12))

func _draw_target(target: Dictionary) -> void:
	var pos := target_position(target)
	var entrance := clampf(target.age / 0.20, 0.0, 1.0)
	var size := 144.0 * lerpf(0.5, 1.0, ease(entrance, 0.5))
	var hovered := state == "playing" and get_global_mouse_position().distance_to(pos) < 66.0
	if hovered:
		size *= 1.10
	var color := GOLD if target.kind != "spore" else Color("88a4a1")
	draw_circle(pos, size * 0.45, Color(color, 0.08))
	draw_circle(pos, size * 0.35, Color(color, 0.09))
	var ratio := clampf(target.life / target.max_life, 0.0, 1.0)
	draw_arc(pos, 66, -PI / 2, -PI / 2 + TAU * ratio, 52, Color(color, 0.75 if hovered else 0.40), 2.5, true)
	var angle := sin(target.age * 3.0 + target.slot) * 0.07
	draw_set_transform(pos, angle)
	draw_texture_rect(textures[target.kind], Rect2(-Vector2.ONE * size / 2, Vector2.ONE * size), false)
	draw_set_transform(Vector2.ZERO)

func target_position(target: Dictionary) -> Vector2:
	return SLOTS[target.slot] + Vector2(0, sin(target.age * 3.1 + target.slot) * 6.0 - 6.0)

func _label(parent: Control, text: String, rect: Rect2, size: int, color: Color = CREAM, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(parent: Control, text: String, rect: Rect2, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.position = rect.position
	button.size = rect.size
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 21 if primary else 17)
	button.add_theme_color_override("font_color", INK if primary else CREAM)
	button.add_theme_color_override("font_hover_color", INK if primary else Color.WHITE)
	button.add_theme_color_override("font_pressed_color", INK if primary else GOLD)
	for variant in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = GOLD if primary else Color("244348")
		if variant == "hover":
			style.bg_color = Color("ffebad") if primary else Color("365d61")
		if variant == "pressed":
			style.bg_color = Color("e6b960") if primary else Color("19373d")
		if variant == "disabled":
			style.bg_color = Color("183137")
		style.set_corner_radius_all(14)
		style.border_color = Color(0.7, 0.85, 0.77, 0.2)
		style.set_border_width_all(1)
		button.add_theme_stylebox_override(variant, style)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _build_ui() -> void:
	ui = Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui)
	_label(ui, "FOREST GLOW", Rect2(56, 36, 275, 21), 13, MINT)
	_label(ui, "林间拾光", Rect2(54, 57, 275, 42), 30)
	_label(ui, "收集微光", Rect2(387, 39, 150, 25), 14, MINT)
	labels.score = _label(ui, "0 / 36", Rect2(387, 61, 160, 37), 27, GOLD)
	_label(ui, "剩余时间", Rect2(602, 39, 150, 25), 14, MINT)
	labels.time = _label(ui, "45 秒", Rect2(602, 61, 150, 37), 27)
	_label(ui, "连续采集", Rect2(790, 39, 150, 25), 14, MINT)
	labels.combo = _label(ui, "× 0", Rect2(790, 61, 150, 37), 27)
	pause_button = _button(ui, "暂停", Rect2(990, 47, 98, 45), _toggle_pause)
	sound_button = _button(ui, "声音：开", Rect2(1100, 47, 127, 45), _toggle_sound)
	_label(ui, "一场小小的森林漫游", Rect2(55, 173, 265, 27), 14, MINT)
	_label(ui, "把微光\n带回家。", Rect2(52, 211, 270, 93), 35)
	_label(ui, "点击果实", Rect2(117, 321, 190, 30), 20)
	_label(ui, "橙果 +1  /  蓝果 +2", Rect2(117, 351, 199, 24), 14, MINT)
	_label(ui, "别错过金星", Rect2(117, 394, 190, 30), 20)
	_label(ui, "一颗就有 5 点微光", Rect2(117, 424, 195, 24), 14, MINT)
	_label(ui, "让灰孢子休息", Rect2(117, 467, 199, 30), 20)
	_label(ui, "误点扣 4 秒，并打断连击", Rect2(117, 497, 210, 24), 13, MINT)
	labels.goal = _label(ui, "微光收集进度  0 / 36", Rect2(55, 539, 268, 29), 16)
	_label(ui, "每连续采集 5 次，额外 +2", Rect2(55, 598, 270, 27), 15, GOLD)
	labels.best = _label(ui, "最佳记录  %d" % best_score, Rect2(55, 634, 265, 25), 14, MINT)
	labels.toast = _label(ui, toast, Rect2(400, 719, 826, 34), 17, CREAM)
	_label(ui, "鼠标左键即可游玩", Rect2(31, 714, 311, 26), 17, CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_label(ui, "45 秒 · 36 点微光 · 一片好心情", Rect2(31, 744, 311, 24), 12, MINT, HORIZONTAL_ALIGNMENT_CENTER)
	_refresh_ui()

func _clear_overlay() -> void:
	if is_instance_valid(overlay):
		overlay.visible = false
		overlay.queue_free()
		overlay = null

func _modal(eyebrow: String, title: String, body: String) -> void:
	_clear_overlay()
	overlay = Control.new()
	overlay.size = Vector2(1280, 800)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(overlay)
	var shade := ColorRect.new()
	shade.color = Color(0.008, 0.035, 0.045, 0.70)
	shade.size = Vector2(1280, 800)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(shade)
	var panel := Panel.new()
	panel.position = Vector2(354, 139)
	panel.size = Vector2(572, 522)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("102e35")
	style.border_color = Color("668a76")
	style.set_border_width_all(1)
	style.set_corner_radius_all(30)
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 20
	panel.add_theme_stylebox_override("panel", style)
	overlay.add_child(panel)
	var icon := TextureRect.new()
	icon.texture = textures.leaf
	icon.position = Vector2(599, 163)
	icon.size = Vector2(82, 82)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(icon)
	_label(overlay, eyebrow, Rect2(388, 250, 504, 26), 13, MINT, HORIZONTAL_ALIGNMENT_CENTER)
	_label(overlay, title, Rect2(380, 288, 520, 68), 43, CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	_label(overlay, body, Rect2(390, 378, 500, 106), 19, MINT, HORIZONTAL_ALIGNMENT_CENTER)

func _show_menu() -> void:
	state = "menu"
	_modal("A TINY WOODLAND ADVENTURE", "林间拾光", "森林把星光藏进了果实里。\n用鼠标轻轻点一点，45 秒收集 36 点微光。\n记得绕开贪睡的灰孢子。")
	_button(overlay, "出发，收集微光  →", Rect2(432, 517, 416, 62), start_round, true)
	_label(overlay, "只需鼠标左键  ·  随时可以暂停", Rect2(391, 597, 498, 25), 14, MINT, HORIZONTAL_ALIGNMENT_CENTER)
	_refresh_ui()

func start_round() -> void:
	_clear_overlay()
	state = "playing"
	score = 0
	combo = 0
	best_combo = 0
	remaining = ROUND_TIME
	elapsed = 0.0
	spawn_clock = 0.65
	targets.clear()
	particles.clear()
	floaters.clear()
	flash = 0.0
	_spawn_target(0, "amber")
	_spawn_target(4, "blue")
	_set_toast("出发！点击发光的果实，灰孢子不要碰。", 3.0)
	_refresh_ui()

func _spawn_target(slot: int = -1, kind: String = "") -> void:
	var free_slots: Array[int] = []
	for i in range(SLOTS.size()):
		var occupied := false
		for target in targets:
			if target.slot == i:
				occupied = true
		if not occupied:
			free_slots.append(i)
	if free_slots.is_empty():
		return
	if slot == -1:
		slot = free_slots[rng.randi_range(0, free_slots.size() - 1)]
	elif slot not in free_slots:
		return
	if kind.is_empty():
		var roll := rng.randf()
		kind = "amber" if roll < 0.46 else ("blue" if roll < 0.73 else ("star" if roll < 0.84 else "spore"))
	var lifetime := lerpf(3.1, 2.0, clampf(elapsed / ROUND_TIME, 0.0, 1.0))
	targets.append({"slot": slot, "kind": kind, "life": lifetime, "max_life": lifetime, "age": 0.0})

func _process(delta: float) -> void:
	world_clock += delta
	if state == "playing":
		remaining = maxf(0.0, remaining - delta)
		elapsed += delta
		if remaining <= 0.0:
			_finish(false)
		else:
			_update_targets(delta)
			spawn_clock -= delta
			if spawn_clock <= 0.0:
				_spawn_target()
				spawn_clock = lerpf(0.79, 0.53, clampf(elapsed / ROUND_TIME, 0.0, 1.0))
			if toast_clock > 0.0:
				toast_clock -= delta
			else:
				toast = "小窍门：连点 5 个果实有奖励；错过果实会中断连击。"
	if state != "paused":
		_update_effects(delta)
	var hovering := false
	if state == "playing":
		for target in targets:
			if target_position(target).distance_to(get_global_mouse_position()) < 66:
				hovering = true
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if hovering else Input.CURSOR_ARROW)
	_refresh_ui()
	queue_redraw()

func _update_targets(delta: float) -> void:
	for i in range(targets.size() - 1, -1, -1):
		targets[i].age += delta
		targets[i].life -= delta
		if targets[i].life <= 0.0:
			if targets[i].kind != "spore":
				combo = 0
			targets.remove_at(i)

func _update_effects(delta: float) -> void:
	flash = maxf(0.0, flash - delta * 2.5)
	for i in range(particles.size() - 1, -1, -1):
		particles[i].life -= delta
		particles[i].pos += particles[i].velocity * delta
		particles[i].velocity.y += 90.0 * delta
		if particles[i].life <= 0.0:
			particles.remove_at(i)
	for i in range(floaters.size() - 1, -1, -1):
		floaters[i].life -= delta
		floaters[i].pos.y -= 44.0 * delta
		if floaters[i].life <= 0.0:
			floaters.remove_at(i)

func _unhandled_input(event: InputEvent) -> void:
	if state != "playing":
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# The event owns its click position; the live OS pointer may have moved
		# already (and does not move at all for injected/headless input).
		var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		for i in range(targets.size() - 1, -1, -1):
			if point.distance_to(target_position(targets[i])) <= 66.0:
				_collect(i)
				get_viewport().set_input_as_handled()
				return

func _collect(index: int) -> void:
	var target := targets[index]
	var pos := target_position(target)
	targets.remove_at(index)
	if target.kind == "spore":
		remaining = maxf(0.0, remaining - 4.0)
		combo = 0
		flash = 1.0
		_burst(pos, Color("a9bec0"), 12)
		_float(pos, "−4 秒", Color("ffbca0"))
		_set_toast("嘘……别吵醒灰孢子！时间 −4 秒。", 2.4)
		_sound("oops")
		if remaining <= 0.0:
			_finish(false)
	else:
		var value: int = {"amber": 1, "blue": 2, "star": 5}[target.kind]
		combo += 1
		best_combo = maxi(best_combo, combo)
		var bonus := 2 if combo % 5 == 0 else 0
		score += value + bonus
		_burst(pos, MINT if target.kind == "blue" else GOLD, 18 if bonus == 0 else 30)
		_float(pos, "+%d" % (value + bonus), GOLD)
		if bonus > 0:
			_set_toast("%d 连击！额外收到 2 点微光。" % combo, 2.0)
		elif target.kind == "star":
			_set_toast("捡到一颗小星星，微光 +5！", 1.6)
		_sound("star" if target.kind == "star" or bonus > 0 else "pick")
		if score >= GOAL:
			_finish(true)
	_refresh_ui()

func _burst(pos: Vector2, color: Color, count: int) -> void:
	for i in range(count):
		var velocity := Vector2.from_angle(rng.randf_range(0, TAU)) * rng.randf_range(42, 170)
		var life := rng.randf_range(0.45, 0.95)
		particles.append({"pos": pos, "velocity": velocity, "life": life, "max_life": life, "color": color, "size": rng.randf_range(3, 11), "shape": i % 3})

func _float(pos: Vector2, text: String, color: Color) -> void:
	floaters.append({"pos": pos + Vector2(-90, -58), "text": text, "color": color, "life": 1.0})

func _set_toast(text: String, duration: float) -> void:
	toast = text
	toast_clock = duration

func _refresh_ui() -> void:
	if labels.is_empty():
		return
	labels.score.text = "%d / %d" % [score, GOAL]
	labels.time.text = "%02d 秒" % ceili(remaining)
	labels.time.add_theme_color_override("font_color", Color("ffb59b") if remaining <= 10.0 else CREAM)
	labels.combo.text = "× %d" % combo
	labels.goal.text = "微光收集进度  %d / %d" % [score, GOAL]
	labels.best.text = "最佳记录  %d" % best_score
	labels.toast.text = toast
	pause_button.disabled = state not in ["playing", "paused"]
	pause_button.text = "继续" if state == "paused" else "暂停"
	sound_button.text = "声音：关" if muted else "声音：开"

func _toggle_pause() -> void:
	if state == "playing":
		state = "paused"
		_modal("TAKE A LITTLE BREATH", "森林替你等一会儿", "时间已经停下来了。\n准备好，就继续收集那一点点光。")
		_button(overlay, "继续采集  →", Rect2(432, 517, 416, 62), _toggle_pause, true)
		_button(overlay, "返回首页", Rect2(543, 598, 194, 39), _return_menu)
	elif state == "paused":
		state = "playing"
		_clear_overlay()
	_refresh_ui()

func _toggle_sound() -> void:
	muted = not muted
	_refresh_ui()

func _return_menu() -> void:
	targets.clear()
	_show_menu()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and state == "playing" and not test_mode:
		_toggle_pause()

func _finish(won: bool) -> void:
	if state != "playing":
		return
	state = "won" if won else "lost"
	best_score = maxi(best_score, score)
	if not test_mode:
		var save := ConfigFile.new()
		save.set_value("record", "score", best_score)
		if save.save("user://best.cfg") != OK:
			push_warning("Best score could not be saved; gameplay is unaffected.")
	var title := "微光满载，回家！" if won else "今晚，也有收获。"
	var body := "收集 %d 点微光    ·    最长 %d 连击\n%s" % [score, best_combo, ("还剩 %d 秒，森林为你亮起了灯。" % ceili(remaining)) if won else "再来一次？金星和连续采集会帮上忙。"]
	_modal("A POCKET FULL OF LIGHT" if won else "THE FOREST WILL WAIT", title, body)
	_button(overlay, "再玩一局  →", Rect2(432, 517, 416, 62), start_round, true)
	_button(overlay, "返回首页", Rect2(543, 598, 194, 39), _return_menu)
	if won:
		for i in range(6):
			_burst(Vector2(180 + i * 190, 190), GOLD, 18)
		_sound("win")
	_refresh_ui()

func _make_sounds() -> void:
	# Original short synthesized chimes; no external audio dependency.
	var notes := {"pick": [880.0, 1320.0], "star": [1046.5, 1318.5, 1568.0], "oops": [196.0, 146.8], "win": [523.25, 659.25, 783.99, 1046.5]}
	for key in notes:
		var tones: Array = notes[key]
		var length := 0.16 * tones.size() + 0.20
		var count := int(length * 22050)
		var bytes := PackedByteArray()
		bytes.resize(count * 2)
		for i in range(count):
			var t := float(i) / 22050.0
			var sample := 0.0
			for j in range(tones.size()):
				var local := t - j * 0.105
				if local >= 0.0:
					var envelope := minf(local / 0.008, 1.0) * exp(-local * 13.0)
					sample += (sin(TAU * tones[j] * local) + 0.2 * sin(TAU * tones[j] * 2.0 * local)) * envelope * 0.20
			bytes.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767))
		var audio := AudioStreamWAV.new()
		audio.format = AudioStreamWAV.FORMAT_16_BITS
		audio.mix_rate = 22050
		audio.data = bytes
		sounds[key] = audio

func _sound(key: String) -> void:
	if muted or test_mode:
		return
	var player := AudioStreamPlayer.new()
	player.stream = sounds[key]
	player.volume_db = -9.0
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()