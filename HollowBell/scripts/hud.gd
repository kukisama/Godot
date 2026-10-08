extends CanvasLayer
## Self-driven, pause-safe HUD. The game alone owns state and SceneTree.paused.
## setup(game) may run before or after add_child(); calling it again is safe.
## Public controls and labels are intentionally available to integration/QA.

const Catalog = preload("res://scripts/catalog.gd")
const SCREEN_SHADER: Shader = preload("res://shaders/screen.gdshader")
const REFERENCE_SIZE: Vector2 = Vector2(1440, 810)
const CREAM: Color = Color("eee5cf")
const GOLD: Color = Color("c4a570")
const MUTED: Color = Color("b5b8aa")
const INK: Color = Color("101e23")
const ROUTE_NAMES: Array[String] = ["雾林", "断桥", "修道院", "钟楼"]
const CHECKPOINT_NAMES: Array[String] = ["雾林路碑", "断桥祈灯", "修道院祈灯"]
const HELP_ROWS: Array[Array] = [
	["移动", "A / D · ← / →", "左摇杆 / 方向键"],
	["跳跃", "Space", "A"],
	["三段连击", "J / 鼠标左键 · 连按", "X · 连按"],
	["蓄力重击", "按住 K / 鼠标右键", "按住 Y"],
	["闪避", "Shift / L", "B"],
	["格挡 / 弹反", "Q · 起手可弹反", "LB"],
	["回复", "E", "RB"],
	["暂停", "Esc", "Start"],
	["全屏", "F11", "—"],
]


class Filigree extends Control:
	var color: Color = Color("c4a570")
	var centered: bool = false

	func _draw() -> void:
		var cy: float = size.y * 0.5
		var cx: float = size.x * 0.5 if centered else 9.0
		var diamond: PackedVector2Array = PackedVector2Array([
			Vector2(cx, cy - 4.0), Vector2(cx + 4.0, cy),
			Vector2(cx, cy + 4.0), Vector2(cx - 4.0, cy), Vector2(cx, cy - 4.0),
		])
		draw_polyline(diamond, Color(color, 0.8), 1.0, true)
		if centered:
			draw_line(Vector2(0, cy), Vector2(cx - 16, cy), Color(color, 0.36), 1.0, true)
		draw_line(Vector2(cx + 16, cy), Vector2(size.x, cy), Color(color, 0.36), 1.0, true)


class Meter extends Control:
	var ratio: float = 1.0
	var trail: float = 1.0
	var fill: Color = Color("a65f55")
	var _hold: float = 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_ratio(value: float, immediate: bool = false) -> void:
		var next: float = clampf(value, 0.0, 1.0)
		if is_equal_approx(next, ratio) and not immediate:
			return
		if next < ratio:
			_hold = 0.25
		ratio = next
		if immediate or trail < ratio:
			trail = ratio
		queue_redraw()

	func advance(delta: float) -> void:
		_hold = maxf(0.0, _hold - delta)
		if _hold <= 0.0 and not is_equal_approx(trail, ratio):
			trail = move_toward(trail, ratio, delta * 0.7)
			queue_redraw()

	func _draw() -> void:
		var bar: Rect2 = Rect2(12, 3, maxf(1, size.x - 24), maxf(2, size.y - 6))
		draw_rect(bar.grow(2.0), Color(0.02, 0.05, 0.06, 0.84))
		draw_rect(bar.grow(2.0), Color(0.77, 0.65, 0.44, 0.50), false, 1.0)
		if trail > ratio:
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * trail, bar.size.y)), Color(0.81, 0.64, 0.39, 0.6))
		if ratio > 0.0:
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), fill)
			draw_line(bar.position, bar.position + Vector2(bar.size.x * ratio, 0), Color(fill.lightened(0.32), 0.8))
		for index: int in range(1, 5):
			var x: float = bar.position.x + bar.size.x * float(index) / 5.0
			draw_line(Vector2(x, bar.position.y), Vector2(x, bar.end.y), Color(0.04, 0.09, 0.10, 0.36))
		for x: float in [3.0, size.x - 3.0]:
			var cy: float = size.y * 0.5
			draw_colored_polygon(PackedVector2Array([Vector2(x, cy - 3), Vector2(x + 3, cy),
				Vector2(x, cy + 3), Vector2(x - 3, cy)]), Color(0.77, 0.65, 0.44, 0.8))


class RouteLine extends Control:
	var current: int = 0
	var completed: bool = false

	func _draw() -> void:
		var step: float = size.x / 4.0
		var y: float = size.y * 0.5
		draw_line(Vector2(step * 0.5, y), Vector2(size.x - step * 0.5, y), Color(0.77, 0.65, 0.44, 0.30))
		if current > 0 or completed:
			draw_line(Vector2(step * 0.5, y), Vector2(step * (3.5 if completed else float(current) + 0.5), y),
				Color(0.77, 0.65, 0.44, 0.86))
		for index: int in range(4):
			var x: float = step * (float(index) + 0.5)
			var color: Color = Color("e8ce93") if index <= current or completed else Color("707a76")
			var diamond: PackedVector2Array = PackedVector2Array([Vector2(x, y - 4), Vector2(x + 4, y),
				Vector2(x, y + 4), Vector2(x - 4, y), Vector2(x, y - 4)])
			if index < current or completed:
				draw_colored_polygon(diamond, color)
			else:
				draw_polyline(diamond, color, 1.2, true)
			if index == current and not completed:
				draw_circle(Vector2(x, y), 7.0, Color(color, 0.45), false, 1.0, true)


var game: Node
var root: Control
var menu_panel: PanelContainer
var buttons: Dictionary = {}
var menu_controls: Array[Control] = []
var volume_slider: HSlider
var volume_value_label: Label
var title_label: Label
var english_title_label: Label
var menu_heading_label: Label
var health_label: Label
var stamina_label: Label
var potion_label: Label
var guard_label: Label
var health_bar: Meter
var stamina_bar: Meter
var route_label: Label
var checkpoint_label: Label
var tutorial_label: Label
var boss_panel: Control
var boss_name_label: Label
var boss_phase_label: Label
var boss_health_label: Label
var boss_bar: Meter
var toast_label: Label
var zone_title_label: Label
var zone_subtitle_label: Label
var time_label: Label
var deaths_label: Label
var kills_label: Label

var _built: bool = false
var _state: String = ""
var _page: String = "home"
var _pad_mode: bool = false
var _stick_direction: int = 0
var _stick_axis: int = -1
var _stick_repeat: float = 0.0
var _flash_left: float = 0.0
var _toast_left: float = 0.0
var _toast_duration: float = 3.0
var _zone_left: float = 0.0
var _zone_duration: float = 3.8
var _zone_index: int = -1
var _last_action_ms: int = -1000
var _refresh_clock: float = 0.0
var _property_cache: Dictionary = {}
var _body_font: SystemFont
var _serif_font: SystemFont
var _chinese_font: SystemFont
var _canvas: Control
var _screen: ColorRect
var _screen_material: ShaderMaterial
var _chapter_badge: Label
var _footer: Label
var _hud: Control
var _vitals: Control
var _route: Control
var _route_line: RouteLine
var _route_names: Array[Label] = []
var _tutorial: VBoxContainer
var _tutorial_kicker: Label
var _tutorial_detail: Label
var _pause_button: Button
var _menu_scroll: ScrollContainer
var _menu_content: VBoxContainer
var _menu_kicker: Label
var _menu_description: Label
var _chapter_subtitle: Label
var _menu_rule: Filigree
var _button_stack: VBoxContainer
var _secondary_actions: GridContainer
var _volume_box: VBoxContainer
var _help_box: VBoxContainer
var _stats_box: HBoxContainer
var _navigation_hint: Label
var _toast_panel: PanelContainer
var _zone_panel: VBoxContainer
var _focus_return: String = "begin"


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 20


func setup(owner_game: Node) -> void:
	game = owner_game
	_property_cache.clear()
	if not _built:
		_build()
	on_state_changed()
	if is_inside_tree():
		_layout()


func _ready() -> void:
	if not _built:
		_build()
	_layout()
	on_state_changed()


func _process(delta: float) -> void:
	update_ui(delta)


func update_ui(delta: float) -> void:
	if not _built:
		return
	var step: float = maxf(delta, 0.0) if is_finite(delta) else 0.0
	var current: String = str(_read(game, &"state", "title"))
	if current != _state:
		on_state_changed()
	_flash_left = maxf(0.0, _flash_left - step)
	_screen_material.set_shader_parameter("hit_strength", 0.16 * pow(_flash_left / 0.18, 2.0))
	_update_notices(step)
	_update_stick(step)
	if _state == "playing" or _state == "dead":
		health_bar.advance(step)
		stamina_bar.advance(step)
		boss_bar.advance(step)
	# Text/property reflection does not need to run at the render frame rate.
	_refresh_clock -= step
	if _refresh_clock <= 0.0:
		_refresh_clock = 0.05
		_refresh_data()


func show_toast(text: String, duration: float = 3.0) -> void:
	if not _built:
		_build()
	toast_label.text = text.strip_edges()
	_toast_duration = clampf(duration, 0.25, 15.0) if is_finite(duration) else 3.0
	_toast_left = _toast_duration if not toast_label.text.is_empty() else 0.0
	_update_notices(0.0)


func show_zone(title: String, subtitle: String) -> void:
	if not _built:
		_build()
	zone_title_label.text = title
	zone_subtitle_label.text = subtitle
	_zone_left = _zone_duration if not title.is_empty() else 0.0
	_update_notices(0.0)


func hit_flash() -> void:
	_flash_left = 0.18


func on_state_changed() -> void:
	if not _built:
		return
	var previous: String = _state
	_state = str(_read(game, &"state", "title"))
	_page = "home"
	_stick_direction = 0
	_stick_axis = -1
	_refresh_clock = 0.0
	if _state == "title":
		_zone_index = -1
		_toast_left = 0.0
		_zone_left = 0.0
		_flash_left = 0.0
	elif _state == "playing" and (previous == "title" or previous == "dead" or previous == "victory"):
		_zone_index = -1
		_toast_left = 0.0
		_zone_left = 0.0
		_flash_left = 0.0
		health_bar.set_ratio(1.0, true)
		stamina_bar.set_ratio(1.0, true)
		boss_bar.set_ratio(1.0, true)
	_refresh_menu()
	_refresh_data()
	_update_notices(0.0)
	if _state == "playing" and previous != "paused":
		# Automatic initial/checkpoint chapter reveal; main can override via show_zone.
		var hero: Node = _node(_read(game, &"hero", null))
		if hero is Node3D:
			var index: int = _zone_for_x((hero as Node3D).global_position.x)
			show_zone(str(Catalog.ZONES[index]["name"]), str(Catalog.ZONES[index]["subtitle"]))


func _build() -> void:
	_built = true
	_body_font = SystemFont.new()
	_body_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Noto Sans CJK SC", "Arial"])
	_serif_font = SystemFont.new()
	_serif_font.font_names = PackedStringArray(["Georgia", "Palatino Linotype", "Times New Roman"])
	_chinese_font = SystemFont.new()
	_chinese_font.font_names = PackedStringArray(["Noto Serif CJK SC", "SimSun", "Microsoft YaHei UI"])
	var theme: Theme = Theme.new()
	theme.default_font = _body_font
	theme.default_font_size = 18
	root = Control.new()
	root.name = "HollowBellHUD"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme
	root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.resized.connect(_layout)
	_screen = ColorRect.new()
	_screen.name = "AtmosphericEdges"
	_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_material = ShaderMaterial.new()
	_screen_material.shader = SCREEN_SHADER
	_screen.material = _screen_material
	root.add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas = Control.new()
	_canvas.name = "ResponsiveCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_canvas)
	_chapter_badge = _label(_canvas, "I   /   雾鸦隘口     ·     CHAPTER I", 15, GOLD)
	_footer = _label(_canvas, "第一关 · 雾鸦隘口                                      F11  全屏", 14, MUTED)
	_build_hud()
	_build_menu()
	_build_notices()
	_layout()


func _build_hud() -> void:
	_hud = _control(_canvas, "InGameHUD")
	_vitals = _control(_hud, "PilgrimVitals")
	_label_at(_vitals, "誓约者", 17, CREAM, Rect2(12, 0, 120, 26))
	health_label = _label_at(_vitals, "— / —", 17, CREAM, Rect2(152, 0, 180, 26))
	health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	health_bar = Meter.new()
	health_bar.name = "HealthMeter"
	health_bar.fill = Color("ac625b")
	_vitals.add_child(health_bar)
	_rect(health_bar, Rect2(0, 34, 344, 19))
	stamina_label = _label_at(_vitals, "气力  —", 14, MUTED, Rect2(12, 61, 188, 22))
	guard_label = _label_at(_vitals, "", 14, GOLD, Rect2(200, 61, 132, 22))
	guard_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stamina_bar = Meter.new()
	stamina_bar.name = "StaminaMeter"
	stamina_bar.fill = Color("81a58a")
	_vitals.add_child(stamina_bar)
	_rect(stamina_bar, Rect2(0, 90, 344, 11))
	potion_label = _label_at(_vitals, "琥珀瓶  —", 16, GOLD, Rect2(12, 115, 320, 28))
	_route = _control(_hud, "ChapterRoute")
	_label_at(_route, "CHAPTER I  /  雾鸦隘口", 14, GOLD, Rect2(0, 0, 292, 23))
	route_label = _label_at(_route, "雾林古道", 19, CREAM, Rect2(0, 29, 292, 30))
	_route_line = RouteLine.new()
	_route_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_route.add_child(_route_line)
	_rect(_route_line, Rect2(0, 68, 292, 18))
	for index: int in range(4):
		var label: Label = _label_at(_route, ROUTE_NAMES[index], 14, MUTED,
			Rect2(float(index) * 73.0, 92, 73, 22))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_route_names.append(label)
	checkpoint_label = _label_at(_route, "祈灯  0 / 2", 14, MUTED, Rect2(0, 128, 292, 22))
	_tutorial = VBoxContainer.new()
	_tutorial.name = "ContextualTutorial"
	_tutorial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tutorial.add_theme_constant_override("separation", 6)
	_hud.add_child(_tutorial)
	_tutorial_kicker = _label(_tutorial, "旅途札记", 14, GOLD)
	tutorial_label = _label(_tutorial, "", 19, CREAM)
	tutorial_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_detail = _label(_tutorial, "", 15, MUTED)
	_tutorial_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pause_button = _make_button("pause", "暂停 · Esc", _request_pause)
	_pause_button.focus_mode = Control.FOCUS_NONE
	_hud.add_child(_pause_button)
	boss_panel = _control(_hud, "AuldenBossHealth")
	boss_name_label = _label_at(boss_panel, "守钟巨像 · 奥尔登", 23, CREAM, Rect2(0, 0, 520, 36))
	boss_name_label.add_theme_font_override("font", _chinese_font)
	boss_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_bar = Meter.new()
	boss_bar.name = "BossHealthMeter"
	boss_bar.fill = Color("bc8b58")
	boss_panel.add_child(boss_bar)
	_rect(boss_bar, Rect2(0, 44, 520, 15))
	boss_phase_label = _label_at(boss_panel, "I  ·  守钟之誓", 14, GOLD, Rect2(12, 69, 326, 23))
	boss_health_label = _label_at(boss_panel, "", 14, MUTED, Rect2(340, 69, 168, 23))
	boss_health_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	boss_panel.hide()


func _build_menu() -> void:
	menu_panel = PanelContainer.new()
	menu_panel.name = "LeftMenu"
	menu_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style: StyleBoxFlat = _panel_style(Color(INK, 0.30), 16.0)
	panel_style.border_width_left = 1
	panel_style.border_color = Color(GOLD, 0.20)
	menu_panel.add_theme_stylebox_override("panel", panel_style)
	_canvas.add_child(menu_panel)
	_menu_scroll = ScrollContainer.new()
	_menu_scroll.name = "MenuScroll"
	_menu_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_menu_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_menu_scroll.follow_focus = true
	menu_panel.add_child(_menu_scroll)
	_menu_content = VBoxContainer.new()
	_menu_content.name = "MenuContent"
	_menu_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_content.add_theme_constant_override("separation", 10)
	_menu_scroll.add_child(_menu_content)
	_menu_kicker = _label(_menu_content, "A PILGRIM'S OATH", 14, GOLD)
	english_title_label = _label(_menu_content, "HOLLOW BELL", 54, CREAM)
	english_title_label.add_theme_font_override("font", _serif_font)
	english_title_label.custom_minimum_size.y = 68
	title_label = _label(_menu_content, "钟誓", 52, CREAM)
	title_label.add_theme_font_override("font", _chinese_font)
	title_label.custom_minimum_size.y = 68
	menu_heading_label = _label(_menu_content, "旅途暂歇", 40, CREAM)
	menu_heading_label.add_theme_font_override("font", _chinese_font)
	menu_heading_label.custom_minimum_size.y = 60
	_chapter_subtitle = _label(_menu_content, "Chapter I    /    雾鸦隘口", 19, GOLD)
	_menu_rule = Filigree.new()
	_menu_rule.custom_minimum_size.y = 22
	_menu_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_content.add_child(_menu_rule)
	_menu_description = _label(_menu_content, "雾中仍有一盏灯，在等最后的钟声。", 17, MUTED)
	_menu_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_description.custom_minimum_size.y = 38
	_stats_box = HBoxContainer.new()
	_stats_box.add_theme_constant_override("separation", 20)
	_stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_content.add_child(_stats_box)
	time_label = _stat("旅途用时", "00:00")
	deaths_label = _stat("倒下次数", "0")
	kills_label = _stat("击败敌人", "0")
	_build_volume()
	_build_help()
	_button_stack = VBoxContainer.new()
	_button_stack.name = "MenuActions"
	_button_stack.add_theme_constant_override("separation", 4)
	_menu_content.add_child(_button_stack)
	_secondary_actions = GridContainer.new()
	_secondary_actions.name = "SecondaryActions"
	_secondary_actions.columns = 2
	_secondary_actions.add_theme_constant_override("h_separation", 12)
	_secondary_actions.add_theme_constant_override("v_separation", 4)
	_menu_content.add_child(_secondary_actions)
	var actions: Array[Array] = [
		["begin", "启程  /  BEGIN", "start_game"],
		["resume", "继续旅途", "resume_game"],
		["retry", "从检查点重试", "retry_checkpoint"],
		["new_run", "重新启程", "start_game"],
		["replay", "再走一程", "start_game"],
		["settings", "设置", ""], ["help", "操作指引", ""],
		["menu", "返回标题", "return_to_title"], ["quit", "退出游戏", "quit_game"],
		["back", "返回", ""],
	]
	for entry: Array in actions:
		var key: String = str(entry[0])
		var callback: Callable = _dispatch.bind(StringName(entry[2]))
		if key == "settings" or key == "help":
			callback = _open_page.bind(key)
		elif key == "back":
			callback = _close_page
		var button: Button = _make_button(key, str(entry[1]), callback)
		_button_stack.add_child(button)
	_navigation_hint = _label(_menu_content, "↑ ↓  选择    Enter  确认", 14, MUTED)
	_navigation_hint.custom_minimum_size.y = 34
	_navigation_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_navigation_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _build_volume() -> void:
	_volume_box = VBoxContainer.new()
	_volume_box.name = "MasterVolume"
	_volume_box.add_theme_constant_override("separation", 8)
	_menu_content.add_child(_volume_box)
	var row: HBoxContainer = HBoxContainer.new()
	_volume_box.add_child(row)
	var caption: Label = _label(row, "主音量", 16, CREAM)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	volume_value_label = _label(row, "100%", 16, GOLD)
	volume_slider = HSlider.new()
	volume_slider.name = "MasterVolumeSlider"
	volume_slider.min_value = 0.0
	volume_slider.max_value = 1.0
	volume_slider.step = 0.05
	volume_slider.custom_minimum_size = Vector2(0, 34)
	volume_slider.focus_mode = Control.FOCUS_ALL
	volume_slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# HSlider takes its track height from the background style's minimum size.
	# Zero content margins make an otherwise valid custom track invisible.
	var background: StyleBoxFlat = _panel_style(Color(0.09, 0.15, 0.16, 0.95), 0.0)
	background.content_margin_top = 2
	background.content_margin_bottom = 2
	background.border_width_bottom = 1
	background.border_color = Color(GOLD, 0.24)
	volume_slider.add_theme_stylebox_override("slider", background)
	var track: StyleBoxFlat = _panel_style(Color(GOLD, 0.78), 0.0)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	volume_slider.add_theme_stylebox_override("grabber_area", track)
	volume_slider.add_theme_stylebox_override("grabber_area_highlight", track)
	volume_slider.add_theme_icon_override("grabber", _slider_thumb(GOLD))
	volume_slider.add_theme_icon_override("grabber_highlight", _slider_thumb(CREAM))
	var slider_focus: StyleBoxFlat = _panel_style(Color(0, 0, 0, 0), 0.0)
	slider_focus.set_border_width_all(1)
	slider_focus.border_color = Color(GOLD, 0.8)
	volume_slider.add_theme_stylebox_override("focus", slider_focus)
	volume_slider.value_changed.connect(_on_volume_changed)
	_volume_box.add_child(volume_slider)


func _build_help() -> void:
	_help_box = VBoxContainer.new()
	_help_box.name = "ControlGuide"
	_help_box.add_theme_constant_override("separation", 8)
	_menu_content.add_child(_help_box)
	var rows: Array[Array] = [["动作", "键鼠", "手柄"]]
	rows.append_array(HELP_ROWS)
	for index: int in range(rows.size()):
		var entry: Array = rows[index]
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_help_box.add_child(row)
		var action: Label = _label(row, str(entry[0]), 14, GOLD if index == 0 else CREAM)
		action.custom_minimum_size.x = 94
		var keys: Label = _label(row, str(entry[1]), 14, GOLD if index == 0 else MUTED)
		keys.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var pad: Label = _label(row, str(entry[2]), 14, GOLD if index == 0 else MUTED)
		pad.custom_minimum_size.x = 112


func _build_notices() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.name = "Toast"
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.add_theme_stylebox_override("panel", _panel_style(Color(INK, 0.76), 12.0))
	_canvas.add_child(_toast_panel)
	toast_label = _label(_toast_panel, "", 18, CREAM)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_panel.hide()
	_zone_panel = VBoxContainer.new()
	_zone_panel.name = "ZoneReveal"
	_zone_panel.add_theme_constant_override("separation", 6)
	_zone_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_zone_panel)
	zone_subtitle_label = _label(_zone_panel, "", 15, GOLD)
	zone_subtitle_label.add_theme_font_override("font", _serif_font)
	zone_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zone_title_label = _label(_zone_panel, "", 33, CREAM)
	zone_title_label.add_theme_font_override("font", _chinese_font)
	zone_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zone_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var ornament: Filigree = Filigree.new()
	ornament.custom_minimum_size = Vector2(180, 16)
	ornament.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ornament.centered = true
	ornament.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zone_panel.add_child(ornament)
	_zone_panel.hide()


func _layout() -> void:
	if not _built or not is_instance_valid(_canvas) or not is_instance_valid(menu_panel):
		return
	var viewport_size: Vector2 = root.size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		viewport_size = REFERENCE_SIZE
	# Control resizes, rather than fixed screen coordinates, drive every region.
	# On a 4:3 window preserve font scale and reflow the boss below the vitals.
	var ui_scale: float = minf(viewport_size.y / REFERENCE_SIZE.y, viewport_size.x / 1120.0)
	ui_scale = maxf(0.1, ui_scale)
	var logical: Vector2 = viewport_size / ui_scale
	_canvas.scale = Vector2.ONE * ui_scale
	_canvas.size = logical
	_hud.size = logical
	var margin: float = 44.0
	_rect(_chapter_badge, Rect2(120, 44, minf(520, logical.x - 160), 28))
	_rect(_footer, Rect2(margin, logical.y - 38, logical.x - margin * 2.0, 25))
	_rect(_vitals, Rect2(margin, 38, 344, 148))
	_rect(_route, Rect2(logical.x - 292 - margin, 38, 292, 154))
	_rect(_tutorial, Rect2(margin + 12, logical.y - 166, minf(520, logical.x * 0.48), 108))
	_rect(_pause_button, Rect2(logical.x - 180, logical.y - 83, 136, 43))
	_rect(boss_panel, Rect2((logical.x - 520) * 0.5, 38 if logical.x >= 1320 else 203, 520, 96))
	var menu_x: float = lerpf(42.0, 104.0, clampf((logical.x - 1120) / 320.0, 0.0, 1.0))
	var top: float = maxf(108, (logical.y - 620) * 0.5)
	_rect(menu_panel, Rect2(menu_x, top, 500, maxf(280, logical.y - top - 78)))
	_rect(_toast_panel, Rect2((logical.x - 540) * 0.5, logical.y - 83, 540, 44))
	_rect(_zone_panel, Rect2((logical.x - 700) * 0.5, logical.y * 0.275, 700, 110))
	_screen_material.set_shader_parameter("menu_edge", clampf((menu_x + 665.0) / logical.x, 0.40, 0.73))


func _refresh_menu() -> void:
	var open: bool = _state in ["title", "paused", "dead", "victory"]
	menu_panel.visible = open
	_hud.visible = _state == "playing"
	_chapter_badge.visible = open
	_footer.visible = true
	_screen_material.set_shader_parameter("menu_shade", 1.0 if open else 0.0)
	if not open:
		menu_controls.clear()
		if is_inside_tree():
			var focused: Control = get_viewport().gui_get_focus_owner()
			if is_instance_valid(focused) and root.is_ancestor_of(focused):
				focused.release_focus()
		return
	var title_home: bool = _state == "title" and _page == "home"
	english_title_label.visible = title_home
	title_label.visible = title_home
	menu_heading_label.visible = not title_home
	_chapter_subtitle.visible = _page == "home"
	_stats_box.visible = _state == "victory" and _page == "home"
	_volume_box.visible = _page == "settings" or (_state == "paused" and _page == "home")
	_help_box.visible = _page == "help"
	_menu_scroll.follow_focus = _page != "help"
	_secondary_actions.visible = _state == "paused" and _page == "home"
	var wanted: Array[String] = []
	var initial: String = ""
	if _page == "settings":
		_menu_kicker.text = "SETTINGS  /  旅途偏好"
		menu_heading_label.text = "听见钟声"
		_menu_description.text = "主音量同时控制音乐与音效。\n调整立即生效；0% 为静音。"
		wanted = ["back"]
	elif _page == "help":
		_menu_kicker.text = "FIELD NOTES  /  操作指引"
		menu_heading_label.text = "守住你的节奏"
		_menu_description.text = "观察前摇，再出手。祈灯是沿途的检查点。"
		wanted = ["back"]
	else:
		match _state:
			"title":
				_menu_kicker.text = "A PILGRIM'S OATH"
				_menu_description.text = "雾中仍有一盏灯，在等最后的钟声。"
				wanted = ["begin", "settings", "help", "quit"]
				initial = "begin"
			"paused":
				_menu_kicker.text = "INTERLUDE  /  祈灯未熄"
				menu_heading_label.text = "旅途暂歇"
				_menu_description.text = "喘息片刻，再把誓言带向钟楼。"
				wanted = ["resume", "retry", "new_run", "settings", "help", "menu", "quit"]
				initial = "resume"
			"dead":
				_menu_kicker.text = "THE OATH REMAINS"
				menu_heading_label.text = "钟声未尽"
				_menu_description.text = "祈灯记得你的来路。\n从最近的检查点，再试一次。"
				wanted = ["retry", "new_run", "help", "menu", "quit"]
				initial = "retry"
			"victory":
				_menu_kicker.text = "CHAPTER COMPLETE"
				menu_heading_label.text = "第一关 · 已完成"
				_menu_description.text = "奥尔登归于寂静。\n你让最后一声钟鸣，穿过了雾鸦隘口。"
				wanted = ["replay", "menu", "quit"]
				initial = "replay"
	for key: Variant in buttons:
		if str(key) == "pause":
			continue
		var button: Button = buttons[key] as Button
		button.visible = wanted.has(str(key))
	menu_controls.clear()
	if _volume_box.visible:
		menu_controls.append(volume_slider)
	for key: String in wanted:
		var button: Button = buttons[key] as Button
		var secondary: bool = _secondary_actions.visible and key in ["settings", "help", "menu", "quit"]
		var target: Container = _secondary_actions if secondary else _button_stack
		if button.get_parent() != target:
			button.reparent(target, false)
		target.move_child(button, target.get_child_count() - 1)
		button.custom_minimum_size.y = 40 if secondary else 43
		button.add_theme_font_size_override("font_size", 17 if secondary else 19)
		menu_controls.append(button)
	_sync_volume()
	_wire_focus()
	_menu_scroll.scroll_vertical = 0
	_update_navigation_hint()
	if initial.is_empty() and not wanted.is_empty():
		initial = wanted[0]
	if _page == "settings":
		_focus_control.call_deferred(volume_slider)
	elif not initial.is_empty():
		_focus_control.call_deferred(buttons[initial] as Control)


func _refresh_data() -> void:
	var hero: Node = _node(_read(game, &"hero", null))
	if is_instance_valid(hero):
		var maximum: float = maxf(0.0, _number(hero, &"max_health", 0.0))
		var health: float = clampf(_number(hero, &"health", 0.0), 0.0, maximum)
		var stamina_max: float = maxf(0.0, _number(hero, &"max_stamina", 0.0))
		var stamina: float = clampf(_number(hero, &"stamina", 0.0), 0.0, stamina_max)
		health_label.text = "%d / %d" % [int(ceil(health)), int(ceil(maximum))]
		stamina_label.text = "气力  %d / %d" % [int(ceil(stamina)), int(ceil(stamina_max))]
		health_bar.set_ratio(health / maximum if maximum > 0.0 else 0.0)
		stamina_bar.set_ratio(stamina / stamina_max if stamina_max > 0.0 else 0.0)
		var potions: int = maxi(0, int(_number(hero, &"potions", 0.0)))
		potion_label.text = "琥珀瓶  %d     %s" % [potions, "RB  回复" if _pad_mode else "E  回复"]
		potion_label.modulate = Color.WHITE if potions > 0 else Color(0.7, 0.73, 0.72)
		guard_label.text = "誓约未散" if bool(_read(hero, &"dead", false)) else ("格挡中" if bool(_read(hero, &"guarding", false)) else "")
		if hero is Node3D:
			var x: float = (hero as Node3D).global_position.x
			var index: int = _zone_for_x(x)
			if index != _zone_index:
				var prior: int = _zone_index
				_zone_index = index
				if _state == "playing" and prior >= 0:
					show_zone(str(Catalog.ZONES[index]["name"]), str(Catalog.ZONES[index]["subtitle"]))
			_update_route(index)
			_update_tutorial(x, health, maximum, stamina, stamina_max, potions)
	else:
		health_label.text = "— / —"
		stamina_label.text = "气力  —"
		potion_label.text = "琥珀瓶  —"
		guard_label.text = ""
		health_bar.set_ratio(0.0, true)
		stamina_bar.set_ratio(0.0, true)
		_tutorial.visible = false
	var checkpoint: int = clampi(int(_number(game, &"checkpoint_index", 0)), 0, 2)
	checkpoint_label.text = "祈灯  %d / 2   ·   %s" % [checkpoint, CHECKPOINT_NAMES[checkpoint]]
	if _state == "dead" and _page == "home":
		_menu_description.text = "祈灯记得你的来路。\n重试地点：%s" % CHECKPOINT_NAMES[checkpoint]
	_update_boss()
	if _state == "victory":
		time_label.text = _format_time(_number(game, &"elapsed", 0.0))
		deaths_label.text = str(maxi(0, int(_number(game, &"death_count", 0.0))))
		kills_label.text = str(maxi(0, int(_number(game, &"kills", 0.0))))
	if _volume_box.visible:
		_sync_volume()


func _update_route(index: int) -> void:
	var finished: bool = bool(_read(game, &"boss_defeated", false))
	route_label.text = "钟声已归 · 前往出口" if finished else str(Catalog.ZONES[index]["name"])
	if _route_line.current != index or _route_line.completed != finished:
		_route_line.current = index
		_route_line.completed = finished
		_route_line.queue_redraw()
	for route_index: int in range(_route_names.size()):
		_route_names[route_index].add_theme_color_override("font_color",
			CREAM if route_index == index or finished else MUTED)


func _update_boss() -> void:
	var boss: Node = _node(_read(game, &"boss", null))
	boss_panel.visible = _state == "playing" and is_instance_valid(boss) \
		and bool(_read(game, &"boss_started", false)) and not bool(_read(game, &"boss_defeated", false)) \
		and not bool(_read(boss, &"dead", false))
	if not boss_panel.visible:
		return
	var maximum: float = maxf(0.0, _number(boss, &"max_health", 0.0))
	var health: float = clampf(_number(boss, &"health", 0.0), 0.0, maximum)
	var ratio: float = health / maximum if maximum > 0.0 else 0.0
	boss_bar.set_ratio(ratio)
	boss_health_label.text = "%d / %d" % [int(ceil(health)), int(ceil(maximum))]
	# phase is an optional enemy field; verified property lookup avoids errors.
	var phase: int = int(_number(boss, &"phase", 2.0 if ratio < 0.5 else 1.0))
	boss_phase_label.text = "II  ·  二阶段 / 钟鸣不息" if phase >= 2 else "I  ·  守钟之誓"
	boss_bar.fill = Color("d2a26a") if phase >= 2 else Color("bc8b58")
	boss_bar.queue_redraw()


func _update_tutorial(x: float, health: float, maximum: float, stamina: float,
		stamina_max: float, potions: int) -> void:
	_tutorial.visible = _state == "playing"
	_tutorial_kicker.text = "旅途札记"
	var move: String = "左摇杆 / 方向键" if _pad_mode else "A / D · ← / →"
	var jump: String = "A" if _pad_mode else "Space"
	var light: String = "X" if _pad_mode else "J / 鼠标左键"
	var heavy: String = "Y" if _pad_mode else "K / 鼠标右键"
	var dodge: String = "B" if _pad_mode else "Shift / L"
	var guard: String = "LB" if _pad_mode else "Q"
	var heal: String = "RB" if _pad_mode else "E"
	if bool(_read(game, &"boss_defeated", false)):
		tutorial_label.text = "向右前行，抵达最后的钟亭。"
		_tutorial_detail.text = "出口已开启。"
	elif maximum > 0 and health <= maximum * 0.45 and potions > 0:
		_tutorial_kicker.text = "琥珀祈愿"
		tutorial_label.text = "%s  回复生命" % heal
		_tutorial_detail.text = "拉开距离，留一瞬给自己。"
	elif stamina_max > 0 and stamina < stamina_max * 0.18:
		tutorial_label.text = "气力将尽，留出喘息。"
		_tutorial_detail.text = "松开格挡、暂缓连续出招。"
	elif x < 12:
		tutorial_label.text = "%s  移动    ·    %s  跳跃" % [move, jump]
		_tutorial_detail.text = "沿着祈灯向右，走入雾林。"
	elif x < 25:
		tutorial_label.text = "连按 %s  三段连击" % light
		_tutorial_detail.text = "按住 %s 可蓄力重击。" % heavy
	elif x < 38:
		tutorial_label.text = "%s  闪避    ·    %s  格挡 / 弹反" % [dodge, guard]
		_tutorial_detail.text = "敌人亮出前摇时，抓住格挡起手的瞬间。"
	elif x < 87:
		tutorial_label.text = "%s  越过缺口    ·    %s  回复" % [jump, heal]
		_tutorial_detail.text = "留意断桥；祈灯点亮后可从这里重试。"
	elif x < 133:
		tutorial_label.text = "按住 %s  蓄力破局" % heavy
		_tutorial_detail.text = "灯笼亮起时打断吟唱；石翼俯冲前先离开落点。"
	elif x < 157:
		tutorial_label.text = "%s  跳过地波" % jump
		_tutorial_detail.text = "重锤落地之后，才是反击的时机。"
	else:
		_tutorial_kicker.text = "守钟者"
		tutorial_label.text = "%s  闪避横扫    ·    %s  跃过钟波" % [dodge, jump]
		_tutorial_detail.text = "不要急于连击，等奥尔登收招。"
	_pause_button.text = "暂停 · Start" if _pad_mode else "暂停 · Esc"


func _update_notices(delta: float) -> void:
	if _state != "paused":
		_toast_left = maxf(0.0, _toast_left - delta)
		_zone_left = maxf(0.0, _zone_left - delta)
	_toast_panel.visible = _toast_left > 0.0 and _state == "playing"
	_zone_panel.visible = _zone_left > 0.0 and _state == "playing"
	_toast_panel.modulate.a = _notice_alpha(_toast_left, _toast_duration, 0.12, 0.35)
	_zone_panel.modulate.a = _notice_alpha(_zone_left, _zone_duration, 0.45, 0.85)


func _notice_alpha(left: float, total: float, fade_in: float, fade_out: float) -> float:
	return smoothstep(0.0, fade_in, total - left) * smoothstep(0.0, fade_out, left)


func _open_page(page: String) -> void:
	_focus_return = page
	_page = page
	_stick_direction = 0
	_refresh_menu()


func _close_page() -> void:
	_page = "home"
	_stick_direction = 0
	_refresh_menu()
	if buttons.has(_focus_return):
		_focus_control.call_deferred(buttons[_focus_return] as Control)


func _dispatch(method: StringName) -> void:
	if not is_instance_valid(game) or not game.has_method(method):
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_action_ms < 180:
		return
	_last_action_ms = now
	game.call(method)


func _request_pause() -> void:
	# Pause is not part of the HUD -> game method contract. Dispatch the same
	# Escape input as the keyboard instead; do not invent a pause_game() method.
	if _state != "playing" or not is_inside_tree():
		return
	var press: InputEventKey = InputEventKey.new()
	press.keycode = KEY_ESCAPE
	press.physical_keycode = KEY_ESCAPE
	press.pressed = true
	Input.parse_input_event(press)
	var release: InputEventKey = InputEventKey.new()
	release.keycode = KEY_ESCAPE
	release.physical_keycode = KEY_ESCAPE
	release.pressed = false
	Input.parse_input_event(release)


func _on_volume_changed(value: float) -> void:
	var safe: float = clampf(value, 0.0, 1.0)
	volume_value_label.text = "%d%%" % int(round(safe * 100.0))
	if is_instance_valid(game) and game.has_method("set_volume"):
		game.call("set_volume", safe)


func _sync_volume() -> void:
	var value: float = clampf(_number(game, &"volume", 1.0), 0.0, 1.0)
	volume_slider.set_value_no_signal(value)
	volume_value_label.text = "%d%%" % int(round(value * 100.0))


func _input(event: InputEvent) -> void:
	if not _built:
		return
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.4):
		_set_pad_mode(true)
	elif event is InputEventKey or event is InputEventMouseButton or (event is InputEventMouseMotion and event.relative.length() > 2.0):
		_set_pad_mode(false)
	if not menu_panel.visible:
		return
	if event is InputEventJoypadMotion:
		_handle_stick_event(event)
		return
	if event is InputEventKey:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key == KEY_F11:
			return
		if not event.pressed:
			if key in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_TAB, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_ESCAPE]:
				get_viewport().set_input_as_handled()
			return
		match key:
			KEY_UP: _move_focus(-1)
			KEY_DOWN: _move_focus(1)
			KEY_TAB: _move_focus(-1 if event.shift_pressed else 1)
			KEY_LEFT: _horizontal(-1)
			KEY_RIGHT: _horizontal(1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				if not event.echo:
					_activate_focused()
			KEY_ESCAPE:
				if not event.echo:
					_menu_back()
			_:
				return
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton:
		if not event.pressed:
			get_viewport().set_input_as_handled()
			return
		match event.button_index:
			JOY_BUTTON_DPAD_UP: _move_focus(-1)
			JOY_BUTTON_DPAD_DOWN: _move_focus(1)
			JOY_BUTTON_DPAD_LEFT: _horizontal(-1)
			JOY_BUTTON_DPAD_RIGHT: _horizontal(1)
			JOY_BUTTON_A: _activate_focused()
			JOY_BUTTON_B, JOY_BUTTON_START: _menu_back()
			_: return
		get_viewport().set_input_as_handled()


func _set_pad_mode(enabled: bool) -> void:
	if _pad_mode == enabled:
		return
	_pad_mode = enabled
	_refresh_clock = 0.0
	_update_navigation_hint()


func _update_navigation_hint() -> void:
	_navigation_hint.text = "方向键 / 左摇杆  选择    A  确认    B  返回" if _pad_mode \
		else "↑ ↓  选择    Enter  确认    Esc  返回"
	if _page == "help":
		_navigation_hint.text += "\n滚轮 / 左摇杆上下：翻阅"
	elif _volume_box.visible:
		_navigation_hint.text += "\n聚焦音量时，← → 调整"


func _handle_stick_event(event: InputEventJoypadMotion) -> void:
	if event.axis != JOY_AXIS_LEFT_X and event.axis != JOY_AXIS_LEFT_Y:
		return
	if absf(event.axis_value) < 0.3:
		if _stick_axis == event.axis:
			_stick_direction = 0
			_stick_axis = -1
		return
	if absf(event.axis_value) < 0.6:
		return
	var direction: int = 1 if event.axis_value > 0 else -1
	if _stick_axis != event.axis or _stick_direction != direction:
		_stick_axis = event.axis
		_stick_direction = direction
		_stick_repeat = 0.34
		_stick_step()
	get_viewport().set_input_as_handled()


func _update_stick(delta: float) -> void:
	if _stick_direction == 0 or not menu_panel.visible:
		return
	# A disconnected pad must not leave a synthetic key repeating forever.
	if Input.get_connected_joypads().is_empty():
		_stick_direction = 0
		return
	_stick_repeat -= delta
	if _stick_repeat <= 0:
		_stick_repeat = 0.12
		_stick_step()


func _stick_step() -> void:
	if _stick_axis == JOY_AXIS_LEFT_Y:
		if _page == "help":
			_menu_scroll.scroll_vertical += _stick_direction * 42
		else:
			_move_focus(_stick_direction)
	else:
		_horizontal(_stick_direction)


func _menu_back() -> void:
	if _page != "home":
		_close_page()
	elif _state == "paused":
		_dispatch(&"resume_game")
	# Esc never silently abandons a run or quits from title/death/victory.


func _move_focus(direction: int) -> void:
	if menu_controls.is_empty():
		return
	if _page == "help":
		_menu_scroll.scroll_vertical += direction * 42
		return
	var index: int = menu_controls.find(get_viewport().gui_get_focus_owner())
	index = posmod(index + direction, menu_controls.size()) if index >= 0 else 0
	_focus_control(menu_controls[index])


func _horizontal(direction: int) -> void:
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused == volume_slider:
		volume_slider.value = clampf(volume_slider.value + float(direction) * 0.05, 0.0, 1.0)
	else:
		_move_focus(direction)


func _activate_focused() -> void:
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused is Button and menu_controls.has(focused) and not (focused as Button).disabled:
		(focused as Button).pressed.emit()
	elif focused == volume_slider:
		_move_focus(1)
	elif not menu_controls.is_empty():
		_focus_control(menu_controls[0])


func _wire_focus() -> void:
	for index: int in range(menu_controls.size()):
		var control: Control = menu_controls[index]
		var prior: Control = menu_controls[posmod(index - 1, menu_controls.size())]
		var next: Control = menu_controls[(index + 1) % menu_controls.size()]
		control.focus_neighbor_top = control.get_path_to(prior)
		control.focus_neighbor_bottom = control.get_path_to(next)
		control.focus_previous = control.get_path_to(prior)
		control.focus_next = control.get_path_to(next)
		control.focus_neighbor_left = control.get_path_to(control if control == volume_slider else prior)
		control.focus_neighbor_right = control.get_path_to(control if control == volume_slider else next)


func _focus_control(control: Control) -> void:
	if is_instance_valid(control) and control.is_inside_tree() and control.is_visible_in_tree() \
			and menu_panel.visible and menu_controls.has(control):
		control.grab_focus()
		if _page != "help":
			_menu_scroll.ensure_control_visible(control)


func _hover_button(button: Button) -> void:
	if menu_panel.visible and menu_controls.has(button):
		_focus_control(button)


func _make_button(key: String, text: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.name = key.to_pascal_case() + "Button"
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0, 43)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", 19 if key != "pause" else 15)
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", Color("fff2d5"))
	button.add_theme_color_override("font_focus_color", Color("fff2d5"))
	button.add_theme_color_override("font_pressed_color", GOLD)
	var normal: StyleBoxFlat = _panel_style(Color(0.035, 0.07, 0.08, 0.18), 12.0)
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	var hover: StyleBoxFlat = normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.72, 0.58, 0.33, 0.15)
	hover.border_width_left = 2
	hover.border_color = GOLD
	var pressed: StyleBoxFlat = hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.72, 0.58, 0.33, 0.24)
	var focus: StyleBoxFlat = _panel_style(Color(0, 0, 0, 0), 0.0)
	focus.border_width_left = 2
	focus.border_width_bottom = 1
	focus.border_color = Color(GOLD, 0.86)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", focus)
	button.pressed.connect(callback)
	button.mouse_entered.connect(_hover_button.bind(button))
	buttons[key] = button
	return button


func _label(parent: Node, text: String, font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0.015, 0.035, 0.04, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 0)
	label.add_theme_constant_override("shadow_offset_y", 1)
	parent.add_child(label)
	return label


func _label_at(parent: Node, text: String, font_size: int, color: Color, rect: Rect2) -> Label:
	var label: Label = _label(parent, text, font_size, color)
	_rect(label, rect)
	return label


func _stat(caption: String, initial: String) -> Label:
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 7)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats_box.add_child(box)
	_label(box, caption, 14, MUTED)
	var value: Label = _label(box, initial, 27, CREAM)
	value.add_theme_font_override("font", _serif_font)
	return value


func _control(parent: Node, node_name: String) -> Control:
	var control: Control = Control.new()
	control.name = node_name
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(control)
	return control


func _panel_style(color: Color, padding: float) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = color
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style


func _slider_thumb(tint: Color) -> GradientTexture2D:
	# A tiny in-memory ornament, with no imported/system-file dependency.
	var gradient: Gradient = Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.75, 1.0])
	gradient.colors = PackedColorArray([tint, tint, Color(tint, 0.0)])
	var texture: GradientTexture2D = GradientTexture2D.new()
	texture.width = 14
	texture.height = 14
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.gradient = gradient
	return texture


func _rect(control: Control, value: Rect2) -> void:
	control.position = value.position
	control.size = value.size


func _read(source: Object, key: StringName, fallback: Variant) -> Variant:
	if not is_instance_valid(source):
		return fallback
	var id: int = source.get_instance_id()
	if not _property_cache.has(id):
		# Only game, hero and boss are expected; bound stale respawn cache entries.
		if _property_cache.size() >= 12:
			_property_cache.clear()
		var properties: Dictionary = {}
		for info: Dictionary in source.get_property_list():
			properties[StringName(info["name"])] = true
		_property_cache[id] = properties
	var known: Dictionary = _property_cache[id]
	if not known.has(key):
		return fallback
	var value: Variant = source.get(key)
	return fallback if value == null else value


func _number(source: Object, key: StringName, fallback: float) -> float:
	var value: Variant = _read(source, key, fallback)
	if value is float or value is int:
		var number: float = float(value)
		return number if is_finite(number) else fallback
	return fallback


func _node(value: Variant) -> Node:
	return value as Node if is_instance_valid(value) and value is Node else null


func _zone_for_x(x: float) -> int:
	var result: int = 0
	for index: int in range(Catalog.ZONES.size()):
		if x >= float(Catalog.ZONES[index]["x"]):
			result = index
	return result


func _format_time(seconds: float) -> String:
	var whole: int = maxi(0, int(seconds))
	if whole >= 3600:
		return "%02d:%02d:%02d" % [whole / 3600, (whole / 60) % 60, whole % 60]
	return "%02d:%02d" % [whole / 60, whole % 60]