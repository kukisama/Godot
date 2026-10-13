extends SceneTree
## Real game + real Controls; only the Azure bridge replaced with a TEST fixture.
const FakeBridge = preload("res://tests/fake_azure_bridge.gd")
var game: Node
var fake: Node
var session: Node
var panel: Control
var passed: int = 0
var failed: int = 0
var clicks: int = 0
var finishing: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(45).timeout.connect(func() -> void: if not finishing: check(false, "watchdog"); _finish())
	root.size = Vector2i(1600, 1000)
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	await settle()
	game.set_physics_process(false)
	session = game.azure_session
	panel = game.azure_panel
	check(game.azure_bridge.get_script().resource_path == "res://scripts/azure_bridge.gd", "production main uses pure GDScript native pipe bridge")
	check(not session.connected(), "default unconfigured, no automatic login")
	var public_config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://azure-settings.json"))
	check(session.settings.client_id == public_config.client_id, "existing public ClientId preserved (empty template or configured)")
	if DisplayServer.get_name() == "headless":
		check(not session.preferences.has_identity and not session.restoring, "headless uses empty in-memory profile, never personal metadata")
		var offline_replies: Array[Dictionary] = []
		var capture: Callable = func(json: String) -> void: offline_replies.append(JSON.parse_string(json))
		game.azure_bridge.connect("Reply", capture)
		for action: String in ["restore", "login", "vms", "configure"]:
			game.azure_bridge.call("Request", "offline-" + action, action, "{}")
			await settle()
			check(offline_replies.back().code == "HEADLESS_OFFLINE" and not offline_replies.back().ok, "headless refuses real " + action + " before side effects")
		game.azure_bridge.disconnect("Reply", capture)
		check(not session.connected() and session.settings.client_id == public_config.client_id, "rejected headless requests preserve config and disconnected context")
	game.azure_bridge.disconnect("Reply", session._reply)
	game.azure_bridge.disconnect("JournalChanged", session._journal)
	fake = FakeBridge.new()
	game.add_child(fake)
	fake.settings.client_id = FakeBridge.SUB
	fake.preferences.has_identity = true
	fake.hold = true
	session.setup(fake)
	check(session.busy and session.restoring and fake.calls.back().action == "restore", "startup automatically dispatches silent-only restore for remembered metadata")
	panel.open_for("mira")
	await settle()
	check(not find_button(panel, "登录 / 继续授权（WAM 首选）").disabled and not panel.auto_check.disabled, "manual login and checkbox remain available during startup restore")
	check("不弹登录框" in session.message and "不能也不会保存密码" in content_text(), "startup status and plain-text password boundary visible")
	var position_start: Vector2 = game.player.ground_position
	var muted_start: bool = game.sound.muted
	await click(panel.client_edit)
	key(KEY_M, 109)
	Input.action_press("inn_right")
	game._physics_process(0.1)
	Input.action_release("inn_right")
	check(game.player.ground_position == position_start and game.sound.muted == muted_start and panel.client_edit.text.ends_with("m"), "typing and held movement do not leak during startup restore")
	var old_restore: Dictionary = fake.calls.back().duplicate(true)
	await click(panel.auto_check)
	check(not session.restoring and fake.calls.back().action == "auto_login" and fake.cancelled > 0, "checkbox off cancels startup before preference request")
	fake.complete()
	check(not session.preferences.auto_login and not session.connected(), "disabled auto preference saved without inventing connection")
	late_restore(old_restore)
	check(not session.connected() and not session.restoring, "late restore reply after checkbox off discarded")
	fake.preferences.auto_login = true
	fake.preferences.has_identity = true
	session.setup(fake)
	panel.refresh()
	await settle()
	old_restore = fake.calls.back().duplicate(true)
	await click(find_button(panel, "登录 / 继续授权（WAM 首选）"))
	check(fake.calls.back().action == "login" and not session.restoring, "manual button supersedes in-flight startup restore")
	fake.complete()
	late_restore(old_restore)
	check(session.connected() and not session.busy, "late startup reply cannot replace manual session")
	session.request("logout")
	fake.complete()
	fake.preferences.has_identity = true
	session.setup(fake)
	panel.refresh()
	await settle()
	old_restore = fake.calls.back().duplicate(true)
	await click(find_button(panel, "注销本应用（不会退出 Windows / 撤销云操作）"))
	fake.complete()
	late_restore(old_restore)
	check(not session.connected() and not session.preferences.has_identity and not session.busy, "logout during startup clears metadata and rejects late restore")
	check(fake.writes == 0, "startup and its interruptions perform no VM writes")
	fake.hold = false
	fake.settings.client_id = ""
	fake.preferences.has_identity = false
	session.setup(fake)
	panel.hide_panel()
	panel._config_draft = {}
	fake.calls.clear()
	# All new entry buttons use genuine viewport mouse input.
	for id: String in ["mira", "oren", "eve", "finn"]:
		game._open_dialogue(id)
		await settle()
		check(game.ui.choice_box.get_child_count() == 4, id + " original 4 choices preserved")
		check(game.ui.azure_npc_button.visible == (id != "finn"), id + " separate real entry visibility")
		if id != "finn":
			await click(game.ui.azure_npc_button)
			check(panel.visible and panel.page == "mira", id + " entry opens registration only")
			check_registration_read_only()
			key(KEY_ESCAPE)
			check(not panel.visible and game.dialogue.is_open, "Escape closes only Azure panel")
		game._close_dialogue()
	await click(game.ui.azure_button)
	check(panel.visible and panel.page == "mira", "HUD opens real registration")
	check_registration_read_only()
	var before: int = fake.calls.size()
	panel.client_edit.text = "not-a-guid"
	await click(find_button(panel, "保存公开应用配置"))
	check(fake.calls.size() == before and "GUID" in session.message, "invalid configuration blocks bridge request")
	panel.client_edit.text = FakeBridge.SUB
	panel.tenant_edit.text = "organizations"
	await click(find_button(panel, "保存公开应用配置"))
	check(session.settings.client_id == FakeBridge.SUB and not session.busy, "valid public configuration saved via contract (fake no disk)")
	await click(find_button(panel, "登录 / 继续授权（WAM 首选）"))
	check(session.connected(), "login success visible")
	check(fake.calls.back().args.browser == false, "WAM button not browser")
	check("fixture@example.invalid" in game.ui.azure_button.text, "HUD displays selected real account")
	check("未选择" in panel.context_label.text, "logged in but subscription not auto-picked")
	await click(find_button(panel, "读取目录"))
	check(session.tenants.size() == 1, "directory response listed")
	await click(find_button(panel, "读取当前目录订阅"))
	check(session.subscriptions.size() == 1, "subscription response listed")
	check(session.context.subscription_id.is_empty(), "reading subscriptions never automatically selects one")
	await click(find_button_prefix(panel, "选择订阅："))
	check(session.context.subscription_id == FakeBridge.SUB, "explicit subscription selection")
	check("Fixture subscription" in game.ui.azure_button.text, "HUD current subscription")
	# Held movement and ordinary keys must not reach the inn under the panel.
	var position: Vector2 = game.player.ground_position
	var muted: bool = game.sound.muted
	Input.action_press("inn_right")
	game._physics_process(0.1)
	Input.action_release("inn_right")
	check(game.player.ground_position == position, "panel blocks held WASD movement")
	await click(panel.client_edit)
	key(KEY_END)
	for code: int in [KEY_J, KEY_M, KEY_E, KEY_1]:
		key(code, code + 32 if code in [KEY_J, KEY_M, KEY_E] else 49)
	await settle()
	check(game.sound.muted == muted and not game.ui.modal.visible and not game.dialogue.is_open, "J/M/E/1 typing cannot trigger underlying shortcuts")
	check(panel.client_edit.text.ends_with("jme1"), "letters actually enter top field")
	check_registration_read_only()
	# Existing background jobs are fixture metadata, never submitted by this UI.
	var record := {"id": "fixture-operation", "context": session.context.duplicate(true), "target": fake.vm, "action": "start", "state": "pending", "message": "FAKE cloud pending", "updated": "fixture time"}
	fake.JournalChanged.emit(JSON.stringify([record]))
	check(session.operations.size() == 1 and session.operations[0].target.resource_id == FakeBridge.VM_ID, "background journal retains original full target without a journal tab")
	# A late read response after close cannot revive UI or change its lists.
	fake.hold = true
	await click(find_button(panel, "读取当前目录订阅"))
	check(session.busy and find_button(panel, "米拉 · Azure 登记簿").disabled, "registration tab disabled during in-flight read")
	before = fake.calls.size()
	session.request("subscriptions")
	check(fake.calls.size() == before, "busy repeat query blocked")
	var subscriptions_before: Array = session.subscriptions.duplicate(true)
	key(KEY_ESCAPE)
	check(not panel.visible and not session.busy, "Escape releases local waiting state")
	check(session.operations.size() == 1, "close does not remove submitted job")
	fake.complete()
	check(not panel.visible and session.subscriptions == subscriptions_before and session.confirmation.is_empty(), "late response after close discarded")
	fake.hold = false
	await click(game.ui.azure_button)
	await click(panel.client_edit)
	var field: LineEdit = panel.client_edit
	fake.JournalChanged.emit(JSON.stringify([record]))
	await settle()
	check(panel.client_edit == field and root.gui_get_focus_owner() == field, "background operation journal does not rebuild focused configuration field")
	check(find_button(panel, "浏览器备用（明确选择）") == null, "browser fallback removed")
	check("不监听 localhost" in content_text(), "WAM-only boundary visible")
	await click(find_button(panel, "换账户（明确选择）"))
	check(fake.calls.back().args.browser == false and fake.calls.back().args.select_account, "native explicit account selection without browser")
	check(session.context.subscription_id.is_empty() and session.subscriptions.is_empty(), "account selection clears prior subscription and requires explicit reselection")
	fake.hold = true
	var context_before_cancel: Dictionary = session.context.duplicate(true)
	session.request("login", {"select_account": true})
	var cancellations_before: int = fake.cancelled
	await click(find_button(panel, "取消登录"))
	check(fake.cancelled == cancellations_before + 1 and not session.busy and not session.restoring, "cancel button cancels this auth request and immediately unlocks UI")
	var message_after_cancel: String = session.message
	var context_after_cancel: Dictionary = session.context.duplicate(true)
	check(session.connected() and context_after_cancel.account == context_before_cancel.account, "cancelling account switch preserves the existing account")
	fake.complete(false, "CANCELLED_OR_TIMEOUT")
	check(not session.busy and session.context == context_after_cancel and session.message == message_after_cancel, "late cancelled auth reply cannot change session or UI status")
	for diagnostic: Array in [["AUTH_NATIVE_FAILED", "原生认证/初始化未完成；未输出原始异常或凭据。 阶段: request_token; HRESULT: 0x80070005; ProviderError: 3400138760 (0xCAA20008)"], ["WAM_PROVIDER_MISSING", "阶段: find_provider; HRESULT: 0x00000000"], ["HELPER_BOOT_FAILED", "阶段: winrt_init; HRESULT: 0x80004005"], ["WAM_WINDOW_REQUIRED", "阶段: parent_window; HRESULT: 0x80070578"]]:
		session.request("login", {"select_account": true})
		var pending: Dictionary = fake.pending.duplicate(true)
		fake.pending = {}
		fake.Reply.emit(JSON.stringify({"id": pending.id, "action": "login", "ok": false, "code": diagnostic[0], "message": diagnostic[1], "context": session.context, "data": null}))
		await settle()
		check(not session.busy and diagnostic[0] in session.message and diagnostic[1] in session.message, "safe native diagnostics preserved by session " + diagnostic[0])
		check(panel.content.get_child(0) is Label and panel.content.get_child(0).text == session.message, "real status Label displays complete safe phase/code " + diagnostic[0])
		var status: Label = panel.content.get_child(0)
		check(status.autowrap_mode == TextServer.AUTOWRAP_ARBITRARY and status.size.x <= panel.content.get_parent().size.x, "safe diagnostics stay within scrolling viewport " + diagnostic[0])
		if diagnostic[0] == "AUTH_NATIVE_FAILED":
			check(status.get_line_count() > 1 and status.get_visible_line_count() == status.get_line_count(), "long native diagnostics wrap without losing lines")
	fake.hold = false
	await click(find_button(panel, "注销本应用（不会退出 Windows / 撤销云操作）"))
	check(not session.connected() and session.selected.is_empty() and session.vms.is_empty(), "logout clears real session targets")
	check(session.operations.size() == 1, "logout preserves operation journal")
	check(find_button(panel, "读取目录").disabled and find_button(panel, "读取当前目录订阅").disabled, "disconnected registration disables real reads")
	before = fake.calls.size()
	session.request("vms")
	check(fake.calls.size() == before and "登录" in session.message, "unconnected real list not demo fallback")
	check_registration_read_only()
	check(fake.writes == 0, "entire registration flow performs zero VM writes")
	for request: Dictionary in fake.calls:
		check(request.action in ["restore", "auto_login", "configure", "login", "logout", "tenants", "subscriptions", "select_subscription"], "registration dispatches only configuration/authentication/directory/subscription: " + request.action)
	# Observe an actual GL render only in graphical run, never headless claim.
	if DisplayServer.get_name() != "headless":
		panel.open_for("mira")
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		check(image.save_png("res://qa/azure-panel.png") == OK and image.get_used_rect().has_area(), "actual graphical panel captured")
	print("AZURE_UI_TESTS: %d passed, %d failed; real scene, %d viewport clicks; FAKE auth/ARM only" % [passed, failed, clicks])
	await _finish()


func content_text() -> String:
	var result: String = ""
	for node: Node in panel.content.get_children():
		if node is Label:
			result += node.text + "\n"
	return result


func check_registration_read_only() -> void:
	for caption: String in ["奥伦 · 云务账簿", "伊芙 · 真实资源鉴定", "真实操作记录", "刷新真实 VM", "启动…（下一步核对真实目标）", "停止并解除分配…（下一步核对）", "确认启动", "确认停止并解除分配"]:
		check(find_button(panel, caption) == null, "registration has no removed tab/write control: " + caption)
	check(session.confirmation.is_empty() and fake.writes == 0, "registration neither prepares nor executes cloud writes")


func late_restore(request: Dictionary) -> void:
	var stale: Dictionary = fake.context.duplicate(true)
	stale.account = "late-fixture@example.invalid"
	stale.generation += 100
	fake.Reply.emit(JSON.stringify({"id": request.id, "action": "restore", "ok": true, "context": stale, "data": stale, "message": "FAKE late restore"}))


func find_button(node: Node, value: String) -> Button:
	if node is Button and node.text == value:
		return node
	for child: Node in node.get_children():
		var found: Button = find_button(child, value)
		if found != null:
			return found
	return null


func find_button_prefix(node: Node, value: String) -> Button:
	if node is Button and node.text.begins_with(value):
		return node
	for child: Node in node.get_children():
		var found: Button = find_button_prefix(child, value)
		if found != null:
			return found
	return null


func click(button: Control) -> void:
	if button == null:
		check(false, "button exists")
		return
	# Newly rebuilt registration controls have no final rect until layout settles.
	await settle()
	var scroll: Node = button.get_parent()
	while scroll != null and not scroll is ScrollContainer:
		scroll = scroll.get_parent()
	if scroll is ScrollContainer:
		scroll.ensure_control_visible(button)
	await settle()
	check(button.is_visible_in_tree() and (not button is Button or not button.disabled), "control visible/enabled: " + button.text)
	if scroll is ScrollContainer:
		if not scroll.get_global_rect().encloses(button.get_global_rect()):
			print("AZURE_CLIP_ACTUAL: viewport=", scroll.get_global_rect(), " control=", button.get_global_rect(), " scroll=", scroll.scroll_vertical, " caption=", button.text)
		check(scroll.get_global_rect().encloses(button.get_global_rect()), "control not clipped by scrolling viewport: " + button.text)
	var point: Vector2 = button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event, true)
	clicks += 1
	await settle()


func key(code: int, unicode_value: int = 0) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode_value if pressed else 0
		event.pressed = pressed
		root.push_input(event, true)


func settle() -> void:
	for _index: int in range(4):
		await process_frame


func check(ok: bool, name: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL AZURE_UI " + name)


func _finish() -> void:
	if finishing:
		return
	finishing = true
	Input.action_release("inn_right")
	if is_instance_valid(game):
		game.queue_free()
	game = null
	session = null
	panel = null
	fake = null
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	quit(0 if failed == 0 else 1)