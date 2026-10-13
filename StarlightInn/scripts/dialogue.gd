extends Node

signal changed
signal closed

const NpcCatalog = preload("res://scripts/npc_catalog.gd")
const CapabilityPort = preload("res://scripts/capability_port.gd")
const MAX_HISTORY: int = 60
const MAX_MESSAGE_LENGTH: int = 280
const PREVIEW_TARGETS: Dictionary = {
	"target_lantern": "inn-lantern-01", "target_library": "inn-library-02",
}

var npc_id: String = ""
var is_open: bool = false
var busy: bool = false
var page: String = "root"
var text: String = ""
var choices: Array[Dictionary] = []
var allow_input: bool = false
var history: Array[Dictionary] = []
var visited: Dictionary = {}
var last_request: Dictionary = {}
var last_response: Dictionary = {}
var pending_request_id: String = ""
var history_by_npc: Dictionary = {}
var port: CapabilityPort = CapabilityPort.new()

var _selected_target: String = ""
var _session_generation: int = 0
var azure: Node
var _azure_pending: String = ""
var _azure_action: String = ""
var _azure_sequence: int = 0
var _azure_generation: int = -1
var _list_action: String = ""
var _list_index: int = 0


func setup_azure(session: Node) -> void:
	azure = session
	_azure_generation = int(azure.context.get("generation", 0))
	azure.changed.connect(_on_azure_changed)
	azure.request_finished.connect(_on_azure_response)
	_on_azure_changed()


func real_mode() -> bool:
	return npc_id != "lyra" and azure != null and azure.connected()


func _ready() -> void:
	if port.get_parent() == null:
		add_child(port)
	if not port.response_ready.is_connected(_on_response):
		port.response_ready.connect(_on_response)


func _exit_tree() -> void:
	_cancel_pending()


func open_for(id: String) -> bool:
	var npc: Dictionary = NpcCatalog.get_npc(id)
	if npc.is_empty():
		return false
	_cancel_pending()
	_save_history()
	_session_generation += 1
	npc_id = id
	is_open = true
	visited[id] = true
	last_request = {}
	last_response = {}
	history = []
	var saved: Array = history_by_npc.get(id, [])
	for entry: Dictionary in saved:
		history.append(entry.duplicate(true))
	_show_root()
	if history.is_empty():
		_record(npc["name"], text)
	changed.emit()
	return true


func choose(choice_id: String) -> void:
	if not is_open or (busy and not (real_mode() and choice_id == "back")):
		return
	var selected: Dictionary = {}
	for choice: Dictionary in choices:
		if choice["id"] == choice_id:
			selected = choice
			break
	if selected.is_empty():
		return
	if choice_id == "goodbye":
		close()
		return
	if choice_id == "back":
		if not _azure_pending.is_empty():
			_cancel_pending()
		_selected_target = ""
		_show_root()
		changed.emit()
		return
	_record("旅人", selected["label"])
	if real_mode():
		_choose_azure(choice_id)
		return
	if npc_id == "oren" and page == "targets" and PREVIEW_TARGETS.has(choice_id):
		_selected_target = PREVIEW_TARGETS[choice_id]
		page = "confirm"
		text = "【本地演示数据】嗯，名字再看一眼：%s（running）。下一步仅预览关机步骤：未执行任何真实操作，也不会改变示例状态。确认要看预览吗？返回话题会取消这个选择。" % _selected_target
		choices = [{"id": "confirm_preview", "label": "确认：仅看关机预览"}, {"id": "back", "label": "取消选择，返回话题"}]
		_record_npc(text)
		changed.emit()
		return
	if npc_id == "oren" and page == "confirm" and choice_id == "confirm_preview":
		if not PREVIEW_TARGETS.values().has(_selected_target):
			_show_page("result", "【本地演示】目标已失效，请返回话题重新选择；未执行任何操作。")
			return
		var target: String = _selected_target
		_selected_target = ""
		_begin_request("azure.vm", "preview_shutdown", {"target_id": target})
		return
	match npc_id:
		"mira":
			match choice_id:
				"guide":
					_show_page("guide", "先认认路，不急着把所有事记住。用 WASD 或方向键慢慢走，也可以点地面走近。靠近住客后按 E 或 Enter 交谈，鼠标也能选择话题。聊天时旅人会停下脚步；返回话题不会告别，Esc 由大厅界面处理。没想好先找谁，在我这儿坐一会儿也不算白来。")
				"residents":
					_show_page("residents", "想把事情理清楚，找炉边的奥伦；想问个明白，找书桌边的伊芙。只是想有人接话，就去找菲恩——夸他的时候小心，夸早了能唱到明天。未登录时三人的能力都是本地演示，没有真实 AI 或 Azure 连接。想歇歇的话，我就在吧台。")
				"legend":
					_show_page("legend", "据说第一盏星灯，是一位迷路的制灯匠留下的。他找不到回家的星，就造了一盏等人回来的灯。后来这里成了旅店。我们不问谁走得最远，只问汤还要不要添一点。")
		"oren":
			match choice_id:
				"list_running", "list_all":
					_begin_request("azure.vm", choice_id)
				"shutdown_preview":
					page = "targets"
					_selected_target = ""
					text = "【本地演示数据】慢一点，是为了少重来一遍。先从两盏 running 的虚构云灯里挑一盏。此页只做选择，尚未发送请求；停止的 inn-sleeping-03 不在预览目标中。"
					choices = [{"id": "target_lantern", "label": "inn-lantern-01 · running"}, {"id": "target_library", "label": "inn-library-02 · running"}, {"id": "back", "label": "返回话题"}]
					_record_npc(text)
					changed.emit()
				"chat":
					_show_page("chat", "【本地预设对话】管家最喜欢的时刻？是晚饭后，一切都各得其所，炉火却还醒着。至于账簿里的云灯，只是离线演示样本；真正的灯要灭，得先问问还在读书的人。")
		"eve":
			match choice_id:
				"inspect", "tags":
					_begin_request("azure.resource", choice_id, {"target_id": "inn-lantern-01"})
				"explain_resource":
					_show_page("explain_resource", "【本地预设讲解】我换个好懂的说法！把资源想成一间有编号的客房：区域是它所在的街区，规格像房间大小，状态是门上的挂牌，标签则是你自己贴的便签。听不懂就叫停，是我一下说太多，不是你的问题。这里讲的是虚构样本，不是任何真实资源的鉴定结果。")
		"finn":
			match choice_id:
				"story":
					_begin_request("ai.chat", "story")
				"explain_api":
					_begin_request("ai.chat", "explain")
				"free_chat":
					_show_page("input", "【本地预设对话 · 未调用 AI】写一句想说的话吧，最多 280 字。我的回答来自关键词和预设模板，不会离开这间电脑里的旅店。")
		"lyra":
			match choice_id:
				"road_story":
					_show_page("road_story", "【本地旅途故事】南边旧桥少了一块木板，路人都绕着走。后来有人在旁边摆了盏小灯，谁也没署名。第二天桥还没修好，但每个人都知道该在哪一步放慢脚。")
				"satchel":
					_show_page("satchel", "【本地旅途故事】防水信袋、短绳、粉笔、针线和一小包盐。地图会过时，绳结和补丁不会。真正重要的信放在贴近心口的内层，雨先淋到我。")
				"storm":
					_show_page("storm", "【本地旅途故事】最险的不是雷，是雨里看不清下一块落脚石。我停下来等了很久，直到听见山羊铃。慢一点让我错过晚饭，却没有错过回来的路。")


func send_message(message: String) -> void:
	if real_mode() or not is_open or busy or npc_id != "finn" or not allow_input:
		return
	var trimmed: String = message.strip_edges()
	if trimmed.is_empty():
		_show_page("input", "【本地输入提示】先写一点想说的话吧，空白没有提交，也没有调用 AI。")
		return
	if message.length() > MAX_MESSAGE_LENGTH:
		_show_page("input", "【本地输入提示】这一页最多容纳 280 字。这段话尚未提交，请稍稍收短；没有调用 AI。")
		return
	_record("旅人", trimmed)
	_begin_request("ai.chat", "chat", {"message": trimmed})


func close() -> void:
	if not is_open:
		return
	_cancel_pending()
	_save_history()
	_session_generation += 1
	is_open = false
	npc_id = ""
	page = "root"
	text = ""
	choices = []
	allow_input = false
	history = []
	changed.emit()
	closed.emit()


func _show_root() -> void:
	page = "root"
	_selected_target = ""
	if real_mode():
		allow_input = false
		text = "【真实 Azure · 只读 · 未调用 AI】\n" + _voice("real_greeting") + "\n" + azure.context_text()
		match npc_id:
			"mira":
				choices = [{"id": "tenants", "label": "读取真实目录"}, {"id": "subscriptions", "label": "读取并选择订阅"}, {"id": "logout", "label": "注销本应用，恢复演示"}, {"id": "goodbye", "label": "告别"}]
			"oren":
				choices = [{"id": "vms", "label": "读取真实 VM"}, {"id": "choose_vm", "label": "翻阅并选择已加载 VM"}, {"id": "goodbye", "label": "告别"}]
			"eve":
				choices = [{"id": "inspect", "label": "读取真实 VM 属性"}, {"id": "tags", "label": "读取真实 VM 标签"}, {"id": "target", "label": "查看当前选中目标"}, {"id": "goodbye", "label": "告别"}]
			"finn":
				choices = [{"id": "resource_groups", "label": "读取真实资源组"}, {"id": "goodbye", "label": "告别"}]
		return
	allow_input = npc_id == "finn"
	text = NpcCatalog.get_npc(npc_id)["greeting"]
	match npc_id:
		"mira":
			choices = [{"id": "guide", "label": "旅店向导"}, {"id": "residents", "label": "认识住客"}, {"id": "legend", "label": "旅店传说"}, {"id": "goodbye", "label": "先告别，晚些再聊"}]
		"oren":
			choices = [{"id": "list_running", "label": "看看运行中的示例虚拟机"}, {"id": "list_all", "label": "翻阅全部示例虚拟机"}, {"id": "shutdown_preview", "label": "仅预览关机流程"}, {"id": "chat", "label": "聊聊旅店里的日常"}]
		"eve":
			choices = [{"id": "inspect", "label": "查看演示属性"}, {"id": "tags", "label": "看看演示标签"}, {"id": "explain_resource", "label": "资源是什么？"}, {"id": "goodbye", "label": "道别，留一点星砂"}]
		"finn":
			choices = [{"id": "story", "label": "讲一个星灯故事"}, {"id": "explain_api", "label": "说说 API 是什么"}, {"id": "free_chat", "label": "我想随意说几句"}, {"id": "goodbye", "label": "道别，把故事留到明天"}]
		"lyra":
			choices = [{"id": "road_story", "label": "听一段路上的故事"}, {"id": "satchel", "label": "看看巡路信使的行囊"}, {"id": "storm", "label": "问问那场山雨"}, {"id": "goodbye", "label": "祝下一段路平安"}]


func _show_page(next_page: String, message: String) -> void:
	page = next_page
	text = message
	choices = [{"id": "back", "label": "返回话题"}]
	allow_input = npc_id == "finn" and not real_mode()
	_record_npc(message)
	changed.emit()


func _begin_request(capability: String, action: String, arguments: Dictionary = {}) -> void:
	var generation: int = _session_generation
	busy = true
	page = "waiting"
	text = "【本地演示】" + _voice("waiting") + "\n正在准备本地演示数据或预设回复……"
	choices = [{"id": "back", "label": "返回话题（等待回复中）"}]
	last_response = {}
	var issued_id: String = port.request(npc_id, capability, action, arguments)
	# A signal listener may close/switch during request_dispatched.
	if generation != _session_generation or not is_open:
		port.cancel(issued_id)
		return
	pending_request_id = issued_id
	last_request = port.last_request.duplicate(true)
	changed.emit()


func _on_response(response: Dictionary) -> void:
	if not is_open or not busy or pending_request_id.is_empty():
		return
	if response.get("request_id") != pending_request_id or response.get("npc_id") != npc_id:
		return
	last_response = response.duplicate(true)
	pending_request_id = ""
	busy = false
	_selected_target = ""
	_show_page("result", response["message"])


func _cancel_pending() -> void:
	if not _azure_pending.is_empty():
		_azure_pending = ""
		azure.close_view()
	if not pending_request_id.is_empty():
		port.cancel(pending_request_id)
	pending_request_id = ""
	busy = false
	_selected_target = ""


func _choose_azure(id: String) -> void:
	if page == "azure_list":
		match id:
			"previous":
				_list_index = maxi(0, _list_index - 1)
				_show_azure_list()
			"next":
				_list_index += 1
				_show_azure_list()
			"load_more":
				_list_index = _azure_items().size()
				_begin_azure(_list_action, {"more": true})
			"select_item":
				var items: Array = _azure_items()
				if _list_index < 0 or _list_index >= items.size():
					return
				var item: Dictionary = items[_list_index]
				match _list_action:
					"tenants":
						_begin_azure("login", {"tenant": item.id, "browser": false, "select_account": false})
					"subscriptions":
						_begin_azure("select_subscription", {"id": item.id})
					"vms":
						azure.select_vm(str(item.resource_id))
						_show_page("result", "【真实 Azure · 只读】已选择 VM，未执行云操作。\n" + _voice("selected") + "\n" + _vm_text(azure.selected))
		return
	match id:
		"tenants", "subscriptions", "vms", "resource_groups":
			_list_action = id
			_list_index = 0
			_begin_azure(id)
		"choose_vm":
			_list_action = "vms"
			_list_index = 0
			_show_azure_list()
		"inspect", "tags":
			_begin_azure("inspect", {"resource_id": azure.selected.get("resource_id", "")})
		"target":
			_show_page("result", "【真实 Azure · 只读】\n" + _voice("result") + "\n" + _vm_text(azure.selected))
		"logout":
			_begin_azure("logout")


func _begin_azure(action: String, args: Dictionary = {}) -> void:
	if azure.busy:
		_show_page("result", "【真实 Azure】已有请求处理中，请稍后重试；没有使用演示数据。")
		return
	if action in ["vms", "resource_groups", "inspect"] and str(azure.context.get("subscription_id", "")).is_empty():
		_show_page("result", "【真实 Azure】" + _voice("subscription_required") + "\n没有使用演示数据。")
		return
	if action == "inspect" and azure.selected.is_empty():
		_show_page("result", "【真实 Azure】" + _voice("target_required") + "\n没有使用演示数据。")
		return
	_azure_sequence += 1
	_azure_pending = "npc-%d-%d" % [_session_generation, _azure_sequence]
	_azure_action = action
	pending_request_id = _azure_pending
	last_request = {"request_id": _azure_pending, "npc_id": npc_id, "capability": "azure.read", "action": action, "arguments": args.duplicate(true)}
	last_response = {}
	busy = true
	page = "waiting"
	allow_input = false
	text = "【真实 Azure · 只读】" + _voice("waiting") + "\n请求处理中，可返回取消本次等待。"
	choices = [{"id": "back", "label": "取消等待，返回话题"}]
	changed.emit()
	if not is_open or _azure_pending.is_empty():
		return
	var issued: String = azure.request(action, args, _azure_pending)
	if issued.is_empty():
		_azure_pending = ""
		pending_request_id = ""
		busy = false
		_show_page("result", "【真实 Azure】" + _voice("failure") + "\n" + azure.message)


func _azure_items() -> Array:
	return {"tenants": azure.tenants, "subscriptions": azure.subscriptions, "vms": azure.vms, "resource_groups": azure.resource_groups}.get(_list_action, [])


func _show_azure_list() -> void:
	page = "azure_list"
	allow_input = false
	var items: Array = _azure_items()
	text = "【真实 Azure · 只读】%s\n%s\n" % [_voice("list"), azure.message]
	choices = []
	if not items.is_empty():
		_list_index = clampi(_list_index, 0, items.size() - 1)
		var item: Dictionary = items[_list_index]
		text += "已加载 %d 项，当前第 %d 项\n" % [items.size(), _list_index + 1]
		if _list_action == "vms":
			text += _vm_text(item)
		elif _list_action == "resource_groups":
			text += "资源组：%s\nID：%s\n区域：%s\n标签：%s" % [item.get("name", ""), item.get("id", ""), item.get("region", ""), JSON.stringify(item.get("tags", {}))]
		else:
			text += "名称：%s\nID：%s" % [item.get("name", ""), item.get("id", "")]
		if _list_action != "resource_groups":
			choices.append({"id": "select_item", "label": "选择%s：%s" % [{"tenants": "目录", "subscriptions": "订阅", "vms": "VM"}[_list_action], item.get("name", "")]})
		if _list_index > 0:
			choices.append({"id": "previous", "label": "上一项"})
		if _list_index + 1 < items.size():
			choices.append({"id": "next", "label": "下一项"})
	else:
		text += _voice("empty") + "\n当前页没有结果；没有使用演示数据。"
	if _list_index + 1 >= items.size() and azure.more.get(_list_action, false):
		choices.append({"id": "load_more", "label": "读取 API 下一页"})
	choices.append({"id": "back", "label": "返回话题"})
	_record_npc(text)
	changed.emit()


func _vm_text(vm: Dictionary) -> String:
	if vm.is_empty():
		return "尚未选择真实 VM，请找奥伦读取并选择。"
	return "VM：%s\nResourceId：%s\n资源组：%s\n区域：%s · 规格：%s\n状态：%s · Provisioning：%s · OS：%s\n刷新：%s\n标签：%s" % [vm.get("name", ""), vm.get("resource_id", ""), vm.get("resource_group", ""), vm.get("region", ""), vm.get("size", ""), vm.get("power_state", "unknown"), vm.get("provisioning_state", ""), vm.get("os_type", ""), vm.get("last_refresh", ""), JSON.stringify(vm.get("tags", {}))]


func _on_azure_response(response: Dictionary) -> void:
	if not is_open or _azure_pending.is_empty() or response.get("id") != _azure_pending or response.get("action") != _azure_action:
		return
	_azure_pending = ""
	pending_request_id = ""
	busy = false
	_azure_generation = int(azure.context.get("generation", 0))
	last_response = response.duplicate(true)
	last_response.request_id = response.id
	last_response.npc_id = npc_id
	if not response.get("ok", false):
		_show_page("result", "【真实 Azure 请求失败 · 未使用演示数据】\n" + _voice("failure") + "\n" + str(response.get("message", "")))
	elif _azure_action in ["tenants", "subscriptions", "vms", "resource_groups"]:
		_show_azure_list()
	elif _azure_action == "inspect":
		_show_page("result", "【真实 Azure · 只读】\n" + _voice("result") + "\n" + azure.message + "\n" + _vm_text(azure.selected))
	else:
		_show_root()
		text += "\n" + azure.message
		_record_npc(text)
		changed.emit()


func _on_azure_changed() -> void:
	var generation: int = int(azure.context.get("generation", 0))
	if generation == _azure_generation:
		# A registration view can cancel the shared session without a reply.
		if not _azure_pending.is_empty() and not azure.busy:
			_azure_pending = ""
			pending_request_id = ""
			busy = false
			if is_open:
				_show_page("result", "【真实 Azure】" + _voice("cancelled") + "\n请求已取消，请重新选择话题。")
		return
	_azure_generation = generation
	var cancelled_query: bool = not _azure_pending.is_empty()
	_azure_pending = ""
	_cancel_pending()
	_session_generation += 1
	last_request = {}
	last_response = {}
	if is_open:
		_show_root()
		if cancelled_query:
			text += "\n原请求已取消，上下文已变化，请重新选择话题。"
		changed.emit()


func _voice(kind: String) -> String:
	return NpcCatalog.service_line(npc_id, kind)


func _record_npc(message: String) -> void:
	var npc: Dictionary = NpcCatalog.get_npc(npc_id)
	_record(npc.get("name", npc_id), message)


func _record(speaker: String, message: String) -> void:
	history.append({"speaker": speaker, "text": message})
	while history.size() > MAX_HISTORY:
		history.pop_front()
	_save_history()


func _save_history() -> void:
	if not npc_id.is_empty():
		history_by_npc[npc_id] = history.duplicate(true)