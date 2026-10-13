extends Node
## Separate from CapabilityPort: real ARM state never enters demo envelopes.
signal changed
signal journal_changed
signal request_finished(response: Dictionary)

var bridge: Node
var context: Dictionary = {"generation": 0, "account": "", "tenant_id": "", "tenant_name": "", "subscription_id": "", "subscription_name": ""}
var settings: Dictionary = {"client_id": "", "initial_tenant": "organizations"}
var config_path: String = ""
var profile_path: String = ""
var preferences: Dictionary = {"auto_login": true, "has_identity": false, "restoring": false, "notice": "请首次手动登录。"}
var restoring: bool = false
var message: String = "真实 Azure 未配置 · 本地演示仍可试玩"
var busy: bool = false
var tenants: Array = []
var subscriptions: Array = []
var vms: Array = []
var resource_groups: Array = []
var selected: Dictionary = {}
var confirmation: Dictionary = {}
var operations: Array = []
var more: Dictionary = {"tenants": false, "subscriptions": false, "vms": false, "resource_groups": false}
var _sequence: int = 0
var _pending: Dictionary = {}
var _view_generation: int = 0


func setup(value: Node) -> void:
	if bridge != null:
		if bridge.is_connected("Reply", _reply):
			bridge.disconnect("Reply", _reply)
		if bridge.is_connected("JournalChanged", _journal):
			bridge.disconnect("JournalChanged", _journal)
		if bridge.has_signal("Initialized") and bridge.is_connected("Initialized", _initialized):
			bridge.disconnect("Initialized", _initialized)
	_pending.clear()
	busy = false
	restoring = false
	bridge = value
	bridge.connect("Reply", _reply)
	bridge.connect("JournalChanged", _journal)
	if bridge.has_signal("Initialized"):
		bridge.connect("Initialized", _initialized)
	var initial: Variant = JSON.parse_string(bridge.call("GetSettings"))
	if initial is Dictionary:
		settings = initial.get("settings", settings)
		config_path = initial.get("path", "")
		profile_path = initial.get("profile_path", "")
		preferences = initial.get("preferences", preferences)
		if not str(settings.get("client_id", "")).is_empty():
			message = str(preferences.get("notice", "请首次手动登录。"))
		if not str(initial.get("error", "")).is_empty():
			message = initial.error
	context = JSON.parse_string(bridge.call("GetContext"))
	changed.emit()
	if preferences.get("auto_login", true) and preferences.get("has_identity", false) and not str(settings.get("client_id", "")).is_empty():
		request("restore")


func _initialized() -> void:
	# Bootstrap must not discard a user request already queued on the pipe.
	var initial: Dictionary = JSON.parse_string(bridge.call("GetSettings"))
	settings = initial.get("settings", settings)
	preferences = initial.get("preferences", preferences)
	profile_path = initial.get("profile_path", "")
	config_path = initial.get("path", config_path)
	if not busy:
		message = initial.get("error", "")
		if message.is_empty():
			message = preferences.get("notice", "请首次手动登录。")
		if preferences.get("auto_login", true) and preferences.get("has_identity", false) and not str(settings.get("client_id", "")).is_empty():
			request("restore")
	changed.emit()


func connected() -> bool:
	return not str(context.get("account", "")).is_empty()


func sync_context() -> void:
	if bridge == null:
		return
	var incoming: Variant = JSON.parse_string(bridge.call("GetContext"))
	if incoming is Dictionary and incoming.get("generation") != context.get("generation"):
		context = incoming
		confirmation = {}
		selected = {}
		vms = []
		resource_groups = []
		more.vms = false
		more.resource_groups = false
		if not connected():
			tenants = []
			subscriptions = []


func context_text() -> String:
	if not connected():
		return "真实 Azure / 未连接%s" % (" · 未配置 ClientId" if str(settings.get("client_id", "")).is_empty() else "")
	return "真实 Azure / %s\n目录：%s\n订阅：%s" % [context.account, context.get("tenant_name", ""), context.get("subscription_name", "未选择") if not str(context.get("subscription_id", "")).is_empty() else "未选择"]


func request(action: String, args: Dictionary = {}, request_id: String = "") -> String:
	if bridge == null:
		return ""
	if busy:
		if restoring and action in ["login", "logout", "configure", "auto_login"]:
			bridge.call("CancelLogin")
			_view_generation += 1
			_pending.clear()
			busy = false
			restoring = false
		else:
			return ""
	if action in ["vms", "resource_groups", "inspect", "prepare"] and (not connected() or str(context.get("subscription_id", "")).is_empty()):
		message = "请先在米拉登记簿登录并选择订阅；此处没有演示资源。"
		changed.emit()
		return ""
	if action in ["inspect", "prepare"] and selected.is_empty():
		message = "请先在奥伦账簿选择真实 VM。"
		changed.emit()
		return ""
	if action == "execute" and confirmation.is_empty():
		return ""
	if action in ["login", "logout", "select_subscription", "configure", "restore"]:
		_view_generation += 1
		confirmation = {}
		selected = {}
		vms = []
		resource_groups = []
		more.vms = false
		more.resource_groups = false
		if action in ["login", "logout", "configure"]:
			subscriptions = []
			more = {"tenants": false, "subscriptions": false, "vms": false, "resource_groups": false}
		if action == "logout" or args.get("select_account", false):
			tenants = []
	_sequence += 1
	var id: String = "azure-%d" % _sequence if request_id.is_empty() else request_id
	_pending[id] = {"action": action, "view": _view_generation, "generation": context.get("generation", 0), "more": args.get("more", false)}
	busy = true
	restoring = action == "restore"
	message = "静默恢复上次明确账户……（不弹登录框，可取消）" if restoring else ("等待微软授权……（可取消，3 分钟限时）" if action == "login" else "真实 Azure 请求处理中……")
	# Clear before dispatch, so reentrant/double clicks cannot reuse a nonce.
	if action == "execute":
		confirmation = {}
	bridge.call("Request", id, action, JSON.stringify(args))
	changed.emit()
	return id


func set_auto_login(enabled: bool) -> void:
	request("auto_login", {"enabled": enabled})


func save_config(client_id: String, tenant: String) -> void:
	var guid := RegEx.new()
	guid.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	client_id = client_id.strip_edges()
	tenant = tenant.strip_edges()
	if tenant.is_empty():
		tenant = "organizations"
	if guid.search(client_id) == null or client_id == "00000000-0000-0000-0000-000000000000" or (tenant != "organizations" and guid.search(tenant) == null):
		message = "ClientId 必须是有效 GUID；初始目录填 TenantId 或留空（organizations）。不填写任何 secret。"
		changed.emit()
		return
	request("configure", {"client_id": client_id, "initial_tenant": tenant})


func select_vm(id: String) -> void:
	if busy:
		return
	cancel_confirmation()
	selected = {}
	for vm: Dictionary in vms:
		if vm.get("resource_id") == id:
			selected = vm.duplicate(true)
			break
	changed.emit()


func inspect() -> void:
	request("inspect", {"resource_id": selected.get("resource_id", "")})


func prepare(action: String) -> void:
	if not action in ["start", "deallocate"]:
		return
	request("prepare", {"resource_id": selected.get("resource_id", ""), "action": action})


func execute() -> void:
	if not confirmation.is_empty():
		request("execute", {"nonce": confirmation.get("nonce", "")})


func cancel_confirmation() -> void:
	confirmation = {}
	if bridge != null:
		bridge.call("CancelConfirmation")


func close_view() -> void:
	_view_generation += 1
	# Submitted jobs remain in the bridge/journal; only UI/query correlation drops.
	_pending.clear()
	busy = false
	restoring = false
	cancel_confirmation()
	if bridge != null:
		bridge.call("CancelLogin")
		bridge.call("CancelQueries")
	sync_context()
	changed.emit()


func _reply(json: String) -> void:
	var raw: Variant = JSON.parse_string(json)
	if not raw is Dictionary or not _pending.has(raw.get("id", "")):
		return
	var entry: Dictionary = _pending[raw.id]
	_pending.erase(raw.id)
	if entry.view != _view_generation or raw.get("action") != entry.action:
		return
	busy = false
	restoring = false
	var incoming: Dictionary = raw.get("context", context)
	if incoming.get("generation", 0) < context.get("generation", 0):
		_finish_reply(raw, "上下文已变化，请重新查询。")
		changed.emit()
		return
	if not entry.action in ["login", "logout", "select_subscription", "configure", "restore", "auto_login", "execute", "operations", "resume"] and incoming.get("generation") != entry.generation:
		_finish_reply(raw, "上下文已变化，请重新查询。")
		changed.emit()
		return
	if incoming.get("generation") != context.get("generation"):
		confirmation = {}
		selected = {}
		vms = []
		resource_groups = []
		more.vms = false
		more.resource_groups = false
	context = incoming
	preferences = raw.get("preferences", preferences)
	message = str(raw.get("message", ""))
	if not raw.get("ok", false):
		message = "%s：%s" % [raw.get("code", "REQUEST_FAILED"), message]
		confirmation = {}
		_finish_reply(raw)
		changed.emit()
		return
	var data: Variant = raw.get("data")
	match entry.action:
		"login", "restore":
			message = "已登录：%s。下一步请与米拉读取订阅，并明确选择订阅。" % context.get("account", "")
		"select_subscription":
			message = "已选择订阅：%s。可找奥伦查询并选择真实 VM、伊芙读取属性、菲恩查询资源组。" % context.get("subscription_name", "")
		"logout":
			message = "已注销本应用，四位云端话题住客恢复本地演示；莱拉始终保持本地故事。"
		"configure":
			settings = data
		"tenants", "subscriptions", "vms", "resource_groups":
			var items: Array = data.get("items", [])
			var destination: Array = {"tenants": tenants, "subscriptions": subscriptions, "vms": vms, "resource_groups": resource_groups}[entry.action]
			if not entry.more:
				destination.clear()
			destination.append_array(items)
			more[entry.action] = data.get("has_more", false)
			message = "%s · 已加载 %d 项%s" % [data.get("notice", ""), destination.size(), "，还有下一页" if more[entry.action] else ""]
		"inspect":
			if data.get("resource_id") == selected.get("resource_id"):
				selected = data
				message = "伊芙已读取真实 VM 属性、标签与实例状态。"
		"prepare":
			if data.get("target", {}).get("resource_id") == selected.get("resource_id") and data.get("context", {}).get("generation") == context.get("generation"):
				confirmation = data
				message = "请核对下面的真实目标；这不是原离线关机预览。"
		"execute":
			message = "%s：%s" % [data.get("state", "unknown"), data.get("message", "")]
		"operations", "resume":
			operations = data
	_finish_reply(raw)
	changed.emit()


func _finish_reply(raw: Dictionary, error_message: String = "") -> void:
	var response: Dictionary = raw.duplicate(true)
	response.message = message if error_message.is_empty() else error_message
	if not error_message.is_empty():
		response.ok = false
	request_finished.emit(response)


func _journal(json: String) -> void:
	var raw: Variant = JSON.parse_string(json)
	if raw is Array:
		operations = raw
		journal_changed.emit()