extends Control
## A scrollable, plain-text ledger above the original dialogue. Theme inherited.
signal closed
var session: Node
var page: String = "mira"
var title: Label
var context_label: Label
var content: VBoxContainer
var client_edit: LineEdit
var tenant_edit: LineEdit
var auto_check: CheckBox
var filter_name: String = ""
var filter_group: String = ""
var filter_state: String = "all"
var _config_draft: Dictionary = {}
var _tabs: Array[Button] = []


func setup(model: Node) -> void:
	session = model
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.005, 0.015, 0.025, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var card := PanelContainer.new()
	card.position = Vector2(140, 115)
	card.size = Vector2(1320, 770)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("0c2129")
	style.border_color = Color("e5bb70")
	style.set_border_width_all(2)
	style.set_content_margin_all(22)
	card.add_theme_stylebox_override("panel", style)
	add_child(card)
	var layout := VBoxContainer.new()
	card.add_child(layout)
	var header := HBoxContainer.new()
	layout.add_child(header)
	title = Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	button(header, "返回旅店 ×", hide_panel)
	context_label = Label.new()
	context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(context_label)
	var tabs := HBoxContainer.new()
	layout.add_child(tabs)
	for row: Array in [["mira", "米拉 · Azure 登记簿"]]:
		var target: String = row[0]
		_tabs.append(button(tabs, row[1], func() -> void: open_for(target)))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)
	session.changed.connect(refresh)
	session.journal_changed.connect(func() -> void: if visible and page == "operations" and session.confirmation.is_empty(): refresh())
	visible = false


func open_for(npc: String) -> void:
	if not npc in ["mira", "oren", "eve", "operations"]:
		return
	session.cancel_confirmation()
	session.sync_context()
	page = "mira"
	visible = true
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()
	refresh()


func hide_panel() -> void:
	visible = false
	session.close_view()
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()
	closed.emit()


func refresh() -> void:
	if not visible:
		return
	for tab: Button in _tabs:
		tab.disabled = session.busy
	if is_instance_valid(client_edit) and is_instance_valid(tenant_edit):
		_config_draft = {"client_id": client_edit.text, "initial_tenant": tenant_edit.text}
	client_edit = null
	tenant_edit = null
	for child: Node in content.get_children():
		content.remove_child(child)
		child.queue_free()
	title.text = {"mira": "米拉的 Azure 登记簿", "oren": "奥伦的云务账簿", "eve": "伊芙的真实资源鉴定", "operations": "真实操作记录 · 独立于当前订阅"}[page]
	context_label.text = session.context_text()
	text(session.message)
	_registration()


func _registration() -> void:
	text("仅国际 Azure。只填写本应用公开 ClientId / TenantId，不填密码、token、secret。密码与 MFA 只在微软框中输入。")
	client_edit = edit(content, "应用 ClientId（GUID）", str(_config_draft.get("client_id", session.settings.get("client_id", ""))))
	tenant_edit = edit(content, "初始 TenantId；留空为 organizations", str(_config_draft.get("initial_tenant", session.settings.get("initial_tenant", "organizations"))))
	button(content, "保存公开应用配置", func() -> void: session.save_config(client_edit.text, tenant_edit.text), (session.busy and not session.restoring) or session.connected())
	text("保存位置：" + session.config_path)
	auto_check = CheckBox.new()
	auto_check.text = "记住账户与自动登录（仅静默，不自动弹窗）"
	auto_check.button_pressed = session.preferences.get("auto_login", true)
	auto_check.disabled = session.busy and not session.restoring
	auto_check.custom_minimum_size.y = 42
	auto_check.toggled.connect(session.set_auto_login)
	content.add_child(auto_check)
	var remember_notice: String = "已记住设置／下次启动静默登录；组织要求时重新验证。" if session.preferences.get("auto_login", true) else "自动登录已关闭；公开设置仍保存，当前账户不会因此注销。"
	if str(session.settings.get("client_id", "")).is_empty():
		remember_notice = "保存公开应用配置一次即可，无需重复输入 ClientId。"
	text("账户档案：" + session.profile_path + "\n" + remember_notice + "首次仍需手动选择微软账户。只通过微软认证；本应用不能也不会保存密码。")
	var row := HFlowContainer.new()
	content.add_child(row)
	button(row, "登录 / 继续授权（WAM 首选）", func() -> void: session.request("login", {"browser": false, "select_account": false}), session.busy and not session.restoring)
	button(row, "换账户（明确选择）", func() -> void: session.request("login", {"browser": false, "select_account": true}), session.busy and not session.restoring)
	text("仅使用原生 Windows WAM；此版本不提供浏览器备用，也不监听 localhost。")
	button(row, "取消登录", session.close_view, not session.busy)
	button(content, "注销本应用（不会退出 Windows / 撤销云操作）", func() -> void: session.request("logout"), (session.busy and not session.restoring) or not (session.connected() or session.restoring or session.preferences.get("has_identity", false)))
	var reads := HBoxContainer.new()
	content.add_child(reads)
	button(reads, "读取目录", func() -> void: session.request("tenants"), session.busy or not session.connected())
	button(reads, "更多目录", func() -> void: session.request("tenants", {"more": true}), session.busy or not session.more.tenants)
	button(reads, "读取当前目录订阅", func() -> void: session.request("subscriptions"), session.busy or not session.connected())
	button(reads, "更多订阅", func() -> void: session.request("subscriptions", {"more": true}), session.busy or not session.more.subscriptions)
	text("切目录先尝试同一选定账户的静默授权，仅用户点击时必要交互。guest/多租户同意策略可能限制目录列表。")
	for tenant: Dictionary in session.tenants:
		var id: String = tenant.id
		button(content, "目录：%s · %s" % [tenant.name, id], func() -> void: session.request("login", {"tenant": id, "browser": false, "select_account": false}), session.busy)
	for sub: Dictionary in session.subscriptions:
		var id: String = sub.id
		button(content, "选择订阅：%s · %s" % [sub.name, id], func() -> void: session.request("select_subscription", {"id": id}), session.busy)


func _ledger() -> void:
	text("真实 VM 清单 · 无示例目标。筛选仅覆盖已加载页，继续读取可加载下一页。状态 unknown 不是 stopped。")
	var row := HBoxContainer.new()
	content.add_child(row)
	button(row, "刷新真实 VM", func() -> void: session.request("vms"), session.busy)
	button(row, "继续读取下一页", func() -> void: session.request("vms", {"more": true}), session.busy or not session.more.vms)
	var names := edit(content, "名称包含…（Enter 应用）", filter_name)
	names.text_submitted.connect(func(value: String) -> void: filter_name = value; refresh())
	var groups := edit(content, "资源组包含…（Enter 应用）", filter_group)
	groups.text_submitted.connect(func(value: String) -> void: filter_group = value; refresh())
	var states := OptionButton.new()
	for value: String in ["all", "running", "stopped", "deallocated", "starting", "deallocating", "unknown"]:
		states.add_item(value)
		if value == filter_state:
			states.select(states.item_count - 1)
	states.item_selected.connect(func(index: int) -> void: filter_state = states.get_item_text(index); refresh())
	content.add_child(states)
	for vm: Dictionary in session.vms:
		if not matches(vm):
			continue
		var id: String = vm.resource_id
		button(content, "%s | RG %s | %s | %s | %s\n刷新 %s" % [vm.name, vm.resource_group, vm.region, vm.size, vm.get("power_state", "unknown"), vm.last_refresh], func() -> void: session.select_vm(id), session.busy)
	_inspection()


func matches(vm: Dictionary) -> bool:
	return str(vm.get("name", "")).to_lower().contains(filter_name.to_lower()) and str(vm.get("resource_group", "")).to_lower().contains(filter_group.to_lower()) and (filter_state == "all" or vm.get("power_state", "unknown") == filter_state)


func _inspection() -> void:
	if session.selected.is_empty():
		text("尚未选中真实 VM。请到奥伦账簿选择；伊芙不会拿演示 VM 查询 Azure。")
		return
	var vm: Dictionary = session.selected
	text("当前真实目标：%s\nResourceId：%s\n资源组：%s · 区域：%s · 规格：%s\n状态：%s · Provisioning：%s · OS：%s\n刷新：%s\n标签：%s" % [vm.name, vm.resource_id, vm.resource_group, vm.region, vm.size, vm.get("power_state", "unknown"), vm.get("provisioning_state", ""), vm.get("os_type", ""), vm.last_refresh, JSON.stringify(vm.get("tags", {}))])
	button(content, "伊芙：读取真实属性 / 标签 / 实例状态", session.inspect, session.busy)


func _confirmation() -> void:
	var c: Dictionary = session.confirmation
	var identity: Dictionary = c.context
	var vm: Dictionary = c.target
	text("真实操作确认（不是离线预览）\n账户：%s\n目录：%s · %s\n订阅：%s · %s\n资源组：%s\nVM：%s\nResourceId：%s\n动作：%s · 当前状态：%s\n%s\n确认有效至：%s\nAzure 受理后，关闭对话、切订阅或退出游戏都不撤销云操作。" % [identity.account, identity.tenant_name, identity.tenant_id, identity.subscription_name, identity.subscription_id, vm.resource_group, vm.name, vm.resource_id, c.action, vm.power_state, c.impact, c.expires])
	button(content, "取消：不提交真实操作", func() -> void: session.cancel_confirmation(); refresh())


func _journal() -> void:
	text("这些记录保留原账户/目录/订阅/资源，不随当前选择改变。submitted/pending 不等于成功。记录只在本次运行内；退出仅停止本地等待，已受理云操作不撤销。")
	if session.operations.is_empty():
		text("尚无真实操作记录。")
	for record: Dictionary in session.operations:
		var id: String = record.id
		var c: Dictionary = record.context
		text("%s · %s\n账户 %s\n目录 %s · %s\n订阅 %s · %s\n%s\n%s\n%s" % [record.action, record.state, c.account, c.tenant_name, c.tenant_id, c.subscription_name, c.subscription_id, record.target.resource_id, record.message, record.updated])
		if record.state in ["unknown", "deferred", "pending", "submitted"]:
			button(content, "继续只读核对原操作（不重发）", func() -> void: session.request("resume", {"id": id}), session.busy)


func text(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.custom_minimum_size.x = 0
	content.add_child(label)
	return label


func button(parent: Node, caption: String, callback: Callable, disabled: bool = false) -> Button:
	var control := Button.new()
	control.text = caption
	control.add_theme_font_size_override("font_size", 17)
	control.custom_minimum_size.y = 42
	control.disabled = disabled
	control.pressed.connect(callback)
	parent.add_child(control)
	return control


func edit(parent: Node, placeholder: String, value: String) -> LineEdit:
	var control := LineEdit.new()
	control.placeholder_text = placeholder
	control.text = value
	control.max_length = 100
	control.custom_minimum_size.y = 42
	parent.add_child(control)
	return control