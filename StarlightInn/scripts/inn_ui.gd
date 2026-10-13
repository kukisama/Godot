extends Control
## Presentation only: all conversations and capability state live in Dialogue.

signal choice_selected(id: String)
signal message_submitted(message: String)
signal close_requested
signal guide_requested
signal journal_requested
signal fullscreen_requested
signal audio_requested
signal time_requested
signal modal_closed
signal azure_requested(npc: String)

const Catalog = preload("res://scripts/npc_catalog.gd")
const Dialogue = preload("res://scripts/dialogue.gd")
const Scenes = preload("res://scripts/npc_scenes.gd")
const GOLD := Color("e5bb70")
const CREAM := Color("f6ecd6")
const MUTED := Color("b8c4c5")
const INK := Color("0d2027")

var model: Dialogue
var prompt: Panel
var prompt_text: Label
var progress_text: Label
var toast: Panel
var toast_time: float = 12.0
var world_labels: Dictionary = {}
var speech_bubbles: Dictionary = {}
var speech_labels: Dictionary = {}
var chatter_lines: Dictionary = {}
var chatter_suppressed: bool = false
var time_button: Button
var dialog_panel: Control
var dialog_shade: ColorRect
var portrait: TextureRect
var npc_name: Label
var npc_title: Label
var capability_label: Label
var body: RichTextLabel
var choice_box: VBoxContainer
var input_line: LineEdit
var send_button: Button
var history_button: Button
var input_counter: Label
var request_hint: Label
var audio_button: Button
var azure_button: Button
var azure_npc_button: Button
var modal: Control
var modal_body: RichTextLabel
var modal_title: Label
var modal_kind: String = ""
var _displayed_npc: String = ""
var _last_text: String = ""
var _reveal: float = 0.0


func setup(dialogue: Dialogue) -> void:
	model = dialogue
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC"])
	var common := Theme.new()
	common.default_font = font
	common.default_font_size = 22
	common.set_color("font_color", "Label", CREAM)
	common.set_color("font_color", "Button", CREAM)
	common.set_color("font_hover_color", "Button", Color.WHITE)
	common.set_color("font_focus_color", "Button", CREAM)
	common.set_color("font_disabled_color", "Button", Color("768385"))
	common.set_stylebox("normal", "Button", _box(Color("142c33"), Color("577075"), 7))
	common.set_stylebox("hover", "Button", _box(Color("28414a"), GOLD, 7))
	common.set_stylebox("pressed", "Button", _box(Color("304950"), CREAM, 7))
	common.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), GOLD, 7))
	common.set_stylebox("disabled", "Button", _box(Color("14262c"), Color("354349"), 7))
	common.set_stylebox("normal", "LineEdit", _box(Color("07181e"), Color("647578"), 6))
	common.set_stylebox("focus", "LineEdit", _box(Color("102930"), GOLD, 6))
	common.set_color("font_color", "LineEdit", CREAM)
	common.set_color("caret_color", "LineEdit", GOLD)
	theme = common
	_build_hud()
	_build_dialogue()
	_build_modal()
	model.changed.connect(refresh)
	refresh()


func _build_hud() -> void:
	var title := _panel(self, Rect2(28, 24, 366, 105), Color(0.025, 0.068, 0.08, 0.90), Color("8a6b3d"))
	_texture(title, "res://assets/sprites/crest.png", Rect2(14, 7, 80, 86))
	_label(title, "星 灯 旅 店", Rect2(104, 15, 250, 40), 30, GOLD)
	_label(title, "STARLIGHT INN  /  昼夜拾光", Rect2(106, 61, 250, 22), 15, MUTED)
	var status := _panel(self, Rect2(1134, 28, 438, 51), Color(0.025, 0.068, 0.08, 0.92), Color("426c69"))
	_label(status, "●  离线演示保留 · AI 未连接", Rect2(18, 10, 408, 32), 19, Color("9cdfcd"))
	azure_button = _button(self, "真实 Azure / 未连接", Rect2(1134, 149, 438, 70), func() -> void: azure_requested.emit("mira"), 17)
	azure_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_button(self, "F1  旅店指南", Rect2(1150, 94, 205, 44), func() -> void: guide_requested.emit(), 18)
	_button(self, "J  旅人手记", Rect2(1365, 94, 207, 44), func() -> void: journal_requested.emit(), 18)
	var quest := _panel(self, Rect2(29, 151, 288, 88), Color(0.025, 0.068, 0.08, 0.78), Color("485c5a"))
	_label(quest, "今夜的小小约定", Rect2(16, 10, 260, 29), 20, GOLD)
	progress_text = _label(quest, "认识四位住客    0 / 4", Rect2(16, 46, 260, 25), 18, MUTED)
	time_button = _button(self, "夜泊 · 星灯长明  /  T", Rect2(29, 249, 288, 43), func() -> void: time_requested.emit(), 17)
	time_button.tooltip_text = "时段会自动流转；点击或按 T，平滑切换到下一种光景。"
	for id: String in Catalog.IDS:
		var npc: Dictionary = Catalog.get_npc(id)
		var tag := _panel(self, Rect2(0, 0, 220, 61), Color(0.03, 0.08, 0.095, 0.91), npc.accent)
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_tag := _label(tag, "%s · %s" % [npc.name, npc.title], Rect2(4, 5, 212, 27), 19, npc.accent)
		name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var subtitle := _label(tag, "点选或靠近交谈", Rect2(4, 32, 212, 22), 14, MUTED)
		subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		world_labels[id] = tag
		var bubble := _panel(self, Rect2(0, 0, 310, 76), Color(0.035, 0.085, 0.10, 0.93), npc.accent)
		bubble.z_index = 2
		var line := _label(bubble, "", Rect2(12, 8, 286, 56), 17, CREAM)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bubble.visible = false
		speech_bubbles[id] = bubble
		speech_labels[id] = line
		chatter_lines[id] = {"text": "", "ttl": 0.0}
	prompt = _panel(self, Rect2(535, 882, 530, 50), Color(0.035, 0.09, 0.10, 0.96), GOLD)
	prompt_text = _label(prompt, "", Rect2(8, 6, 514, 38), 21, CREAM)
	prompt_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.visible = false
	toast = _panel(self, Rect2(442, 157, 716, 90), Color(0.035, 0.085, 0.09, 0.94), Color("8a784c"))
	var greeting := _label(toast, "夜色已深，星灯为你留了一盏。", Rect2(12, 11, 692, 29), 23, GOLD)
	greeting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var invitation := _label(toast, "走近一位住客，按 E 聊聊；也可以直接点击他。", Rect2(12, 49, 692, 26), 18, CREAM)
	invitation.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var footer := _panel(self, Rect2(355, 950, 890, 36), Color(0.02, 0.05, 0.065, 0.88), Color("45524a"))
	var hints := _label(footer, "WASD / 方向键 移动  ·  E 交谈  ·  鼠标点选行走  ·  T 光景  ·  Esc 返回", Rect2(10, 3, 870, 30), 17, CREAM)
	hints.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	audio_button = _button(self, "M  声音：开", Rect2(1261, 950, 157, 36), func() -> void: audio_requested.emit(), 16)
	_button(self, "F11  全屏", Rect2(1436, 950, 137, 36), func() -> void: fullscreen_requested.emit(), 16)


func _build_dialogue() -> void:
	dialog_shade = ColorRect.new()
	dialog_shade.color = Color(0.0, 0.018, 0.028, 0.23)
	dialog_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialog_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dialog_shade)
	dialog_panel = Control.new()
	dialog_panel.position = Vector2(36, 582)
	dialog_panel.size = Vector2(1528, 375)
	dialog_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dialog_panel)
	var backdrop := NinePatchRect.new()
	backdrop.texture = load("res://assets/ui/dialogue_frame.png")
	backdrop.patch_margin_left = 50
	backdrop.patch_margin_right = 50
	backdrop.patch_margin_top = 46
	backdrop.patch_margin_bottom = 42
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialog_panel.add_child(backdrop)
	portrait = _texture(dialog_panel, "res://assets/ui/portrait_mira.png", Rect2(26, 92, 213, 254))
	var portrait_plinth := _panel(dialog_panel, Rect2(41, 327, 183, 24), Color("192e33"), Color("695938"))
	var plinth_text := _label(portrait_plinth, "星灯旅店 · 今夜的住客", Rect2(3, 1, 177, 22), 12, GOLD)
	plinth_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	npc_name = _label(dialog_panel, "", Rect2(257, 29, 460, 42), 30, GOLD)
	npc_title = _label(dialog_panel, "", Rect2(258, 76, 640, 27), 18, MUTED)
	capability_label = _label(dialog_panel, "", Rect2(1080, 37, 356, 34), 19, Color("8ed7c5"))
	capability_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_button(dialog_panel, "×", Rect2(1457, 29, 40, 38), func() -> void: close_requested.emit(), 24)
	body = RichTextLabel.new()
	body.position = Vector2(260, 126)
	body.size = Vector2(724, 207)
	body.bbcode_enabled = false
	body.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	body.scroll_active = true
	body.selection_enabled = true
	body.add_theme_color_override("default_color", CREAM)
	body.add_theme_font_size_override("normal_font_size", 23)
	body.add_theme_constant_override("line_separation", 9)
	dialog_panel.add_child(body)
	choice_box = VBoxContainer.new()
	choice_box.position = Vector2(1020, 117)
	choice_box.size = Vector2(478, 233)
	choice_box.add_theme_constant_override("separation", 10)
	dialog_panel.add_child(choice_box)
	input_line = LineEdit.new()
	input_line.position = Vector2(258, 278)
	input_line.size = Vector2(605, 49)
	input_line.placeholder_text = "说点什么吧……（本地预设回复）"
	input_line.max_length = 280
	input_line.add_theme_font_size_override("font_size", 20)
	input_line.text_submitted.connect(func(message: String) -> void: message_submitted.emit(message))
	input_line.text_changed.connect(func(message: String) -> void: input_counter.text = "%d / 280" % message.length())
	dialog_panel.add_child(input_line)
	send_button = _button(dialog_panel, "发送", Rect2(877, 278, 109, 49), func() -> void: message_submitted.emit(input_line.text), 20)
	input_counter = _label(dialog_panel, "0 / 280", Rect2(866, 332, 120, 21), 13, MUTED)
	input_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	history_button = _button(dialog_panel, "对话记录", Rect2(263, 334, 115, 24), func() -> void: journal_requested.emit(), 13)
	request_hint = _label(dialog_panel, "", Rect2(401, 335, 453, 23), 13, MUTED)
	azure_npc_button = _button(dialog_panel, "", Rect2(735, 33, 330, 38), func() -> void: azure_requested.emit(model.npc_id), 17)
	azure_npc_button.visible = false


func _build_modal() -> void:
	modal = Control.new()
	modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(modal)
	var dim := ColorRect.new()
	dim.color = Color(0.005, 0.015, 0.025, 0.73)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	modal.add_child(dim)
	var card := _panel(modal, Rect2(290, 151, 1020, 692), Color("0c2129"), GOLD)
	_texture(card, "res://assets/sprites/books.png", Rect2(37, 22, 75, 75))
	modal_title = _label(card, "", Rect2(133, 34, 760, 56), 32, GOLD)
	_button(card, "×", Rect2(950, 29, 40, 40), hide_modal, 24)
	modal_body = RichTextLabel.new()
	modal_body.position = Vector2(51, 121)
	modal_body.size = Vector2(915, 482)
	modal_body.bbcode_enabled = false
	modal_body.selection_enabled = true
	modal_body.add_theme_color_override("default_color", CREAM)
	modal_body.add_theme_font_size_override("normal_font_size", 23)
	modal_body.add_theme_constant_override("line_separation", 11)
	card.add_child(modal_body)
	_button(card, "Esc  ·  返回旅店", Rect2(358, 628, 304, 43), hide_modal, 19)
	modal.visible = false


func refresh() -> void:
	dialog_panel.visible = model.is_open
	dialog_shade.visible = model.is_open
	progress_text.text = "认识四位住客    %d / 4" % model.visited.size()
	if model.visited.size() == 4:
		progress_text.text = "四位住客，都记得你了  ✓"
	if not model.is_open:
		input_line.release_focus()
		_displayed_npc = ""
		_last_text = ""
		return
	toast.visible = false
	var npc: Dictionary = Catalog.get_npc(model.npc_id)
	if _displayed_npc != model.npc_id:
		input_line.text = ""
		input_counter.text = "0 / 280"
		_displayed_npc = model.npc_id
		portrait.texture = load("res://assets/ui/portrait_%s.png" % model.npc_id)
	npc_name.text = "%s  ·  %s" % [npc.name, npc.title]
	npc_name.add_theme_color_override("font_color", npc.accent)
	npc_title.text = ("正在读取真实 Azure……" if model.busy else "真实 Azure · 只读查询 · 未调用 AI") if model.real_mode() else ("正在整理本地回信……" if model.busy else "聊一个话题，或把故事留到下一次。")
	capability_label.text = {"mira": "目录 / 订阅 · 只读", "oren": "VM 查询 / 选择 · 只读", "eve": "VM 属性 / 标签 · 只读", "finn": "资源组 · 只读"}[model.npc_id] if model.real_mode() else npc.capability
	azure_npc_button.visible = model.npc_id in ["mira", "oren", "eve"]
	azure_npc_button.text = "Azure 登录 / 公开配置"
	if _last_text != model.text:
		_last_text = model.text
		body.text = model.text
		body.scroll_to_line(0)
		_reveal = 0.0
		body.visible_characters = -1 if model.real_mode() or model.last_response.get("mode") == "real" else 0
	body.size.y = 140.0 if model.allow_input else 207.0
	for child: Node in choice_box.get_children():
		choice_box.remove_child(child)
		child.queue_free()
	var index: int = 0
	for choice: Dictionary in model.choices:
		index += 1
		var choice_id: String = choice.id
		var option := Button.new()
		option.text = "%02d   %s" % [index, choice.label]
		option.alignment = HORIZONTAL_ALIGNMENT_LEFT
		option.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		option.tooltip_text = choice.label
		option.custom_minimum_size = Vector2(478, 50)
		option.add_theme_font_size_override("font_size", 19)
		option.disabled = model.busy and not (model.real_mode() and choice_id == "back")
		option.pressed.connect(func() -> void: choice_selected.emit(choice_id))
		choice_box.add_child(option)
	input_line.visible = model.allow_input
	send_button.visible = model.allow_input
	input_counter.visible = model.allow_input
	input_line.editable = not model.busy
	send_button.disabled = model.busy
	request_hint.text = "1–4  选择话题  ·  Esc  告别  ·  所有返回均为本地演示"
	if model.real_mode():
		request_hint.text = "1–4  选择  ·  Esc  告别  ·  真实只读 / 无 AI"
	if not model.last_request.is_empty():
		request_hint.text = "%s / %s · %s" % [model.last_request.capability, model.last_request.action, "准备中" if model.busy else ("真实回执" if model.last_response.get("mode") == "real" else "演示回执")]
	if model.page == "input" and model.allow_input and not modal.visible:
		input_line.grab_focus()
	if modal.visible and modal_kind == "journal":
		show_journal()


func update_world_tags(points: Dictionary, nearest: String) -> void:
	for id: String in world_labels:
		var tag: Panel = world_labels[id]
		var feet: Vector2 = points[id]
		tag.position = feet + Vector2(-110.0, -210.0)
		tag.modulate.a = 1.0 if nearest == id else 0.83
		tag.visible = not modal.visible and (not model.is_open or model.npc_id == id)
		var bubble: Panel = speech_bubbles[id]
		bubble.position = Vector2(clampf(feet.x - 155.0, 16.0, 1274.0), clampf(feet.y - 296.0, 92.0, 838.0))
		var ttl: float = float(chatter_lines[id].ttl)
		bubble.modulate.a = clampf(ttl / 0.2, 0.0, 1.0)
		bubble.visible = ttl > 0.0 and not model.is_open and not modal.visible and not chatter_suppressed and not toast.visible
	prompt.visible = not nearest.is_empty() and not model.is_open and not modal.visible
	if prompt.visible:
		var npc: Dictionary = Catalog.get_npc(nearest)
		prompt_text.text = "[ E / Enter ]  与 %s · %s 交谈" % [npc.name, npc.title]


func show_chatter(id: String, text: String) -> void:
	if not chatter_lines.has(id):
		return
	# One turn at a time: the next speaker replaces, rather than covers, the last.
	clear_chatter()
	chatter_lines[id] = {"text": text, "ttl": Scenes.LINE_SECONDS}
	speech_labels[id].text = text


func clear_chatter() -> void:
	for id: String in chatter_lines:
		chatter_lines[id].ttl = 0.0
		speech_bubbles[id].hide()


func set_time_of_day(value: String) -> void:
	if time_button != null:
		time_button.text = value + "  /  T"


func show_guide() -> void:
	modal_kind = "guide"
	modal_title.text = "旅店指南"
	modal_body.text = "在星灯下，自由走走\n\nWASD / 方向键：移动。Shift：走快一点。\n鼠标点地面：绕开家具走过去；点住客：走近后自动交谈。\nE / Enter：与最近的住客交谈。1–4：选择当前话题。\nEsc：关闭手记或对话。J：查看手记。F11：切换全屏。\n\n米拉 · 旅店主人——旅店向导与小故事。\n奥伦 · 云务管家——示例虚拟机清单与关机流程预览。\n伊芙 · 星术鉴定师——示例资源属性与标签。\n菲恩 · 吟游诗人——故事、API 讲解与自由输入。\n\n本版仅预留能力接口，所有回复都在本机生成。\n没有连接 AI / Azure，也不会执行任何真实操作。"
	modal_body.scroll_to_line(0)
	modal_body.text = modal_body.text.replace("本版仅预留能力接口，所有回复都在本机生成。\n没有连接 AI / Azure，也不会执行任何真实操作。", "未登录时，上面的四话题为完整离线演示，菲恩自由输入是本地模板、未接 AI。\n右上角 Azure 登记簿用于公开配置和 WAM 登录。登录后直接与四位住客交谈：米拉查询目录并明确选择订阅；奥伦查询并选择真实 VM；伊芙读取同一 VM 属性和标签；菲恩查询真实资源组。返回在原对话框显示，可翻页和取消。\n真实模式没有自由聊天，也没有启动/停止按钮。详见 AAD_SETUP.md。")
	modal_body.text += "\n\n声音默认开启。M：一键静音 / 恢复；输入文字时不会触发。\n木地板脚步、炉火、回信铃与鲁特琴短句均为原创合成。"
	modal_body.text += "\n\n住客会散步、挥手和自言自语，靠近彼此时会停下来接话。\n两人闲聊、三人和四人小剧场逐句在说话者头顶显示，每句约两秒。\n开始交谈或打开界面会中断小剧场，点选的住客会停下来等你。\n这些日常台词只在本地发生，不调用 AI 或 Azure。\n初晓、白昼、夕照、夜泊会自动流转；T 或左上光景按钮可提前切换。"
	modal.visible = true
	_release_focus()


func show_journal() -> void:
	modal_kind = "journal"
	modal_title.text = "旅人手记  ·  %d / 4 位住客" % model.visited.size()
	var notes: String = "今夜的交谈，只留在这次旅途中。\n演示与真实查询在各条回信中明确标注；历史不代表当前实时状态。\n"
	for id: String in Catalog.IDS:
		var npc: Dictionary = Catalog.get_npc(id)
		notes += "\n━━━━━━━━━━━━━━━━━━━━\n%s · %s%s\n" % [npc.name, npc.title, "" if model.visited.has(id) else "  [尚未拜访]"]
		var entries: Array = model.history_by_npc.get(id, [])
		if entries.is_empty():
			notes += "还没有交谈记录。走近他，打个招呼吧。\n"
		else:
			for entry: Dictionary in entries:
				notes += "\n%s：%s\n" % [entry.speaker, entry.text]
	modal_body.text = notes
	modal.visible = true
	_release_focus()


func _release_focus() -> void:
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()


func hide_modal() -> void:
	var was_visible: bool = modal.visible
	modal.visible = false
	modal_kind = ""
	if was_visible:
		modal_closed.emit()


func set_muted(value: bool) -> void:
	audio_button.text = "M  声音：关" if value else "M  声音：开"


func set_azure_status(value: String) -> void:
	azure_button.text = value
	azure_button.tooltip_text = value


func _process(delta: float) -> void:
	for id: String in chatter_lines:
		chatter_lines[id].ttl = maxf(0.0, float(chatter_lines[id].ttl) - delta)
	if toast_time > 0.0:
		toast_time -= delta
		if toast_time < 1.0:
			toast.modulate.a = maxf(0.0, toast_time)
		if toast_time <= 0.0:
			toast.visible = false
	if model != null and model.is_open:
		if model.real_mode() or model.last_response.get("mode") == "real":
			body.visible_characters = -1
		else:
			_reveal += delta * 90.0
			body.visible_characters = int(_reveal)


func reveal_all() -> void:
	_reveal = 100000.0
	body.visible_characters = -1


func _panel(parent: Node, rect: Rect2, fill: Color, border: Color) -> Panel:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", _box(fill, border, 7))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)
	return panel


func _label(parent: Node, value: String, rect: Rect2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _texture(parent: Node, path: String, rect: Rect2) -> TextureRect:
	var image := TextureRect.new()
	image.texture = load(path)
	image.position = rect.position
	image.size = rect.size
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(image)
	return image


func _button(parent: Node, value: String, rect: Rect2, callback: Callable, font_size: int) -> Button:
	var button := Button.new()
	button.text = value
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", font_size)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _box(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 12.0
	box.content_margin_right = 12.0
	box.content_margin_top = 5.0
	box.content_margin_bottom = 5.0
	return box