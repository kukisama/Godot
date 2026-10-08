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
	if not is_open or busy:
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
		_selected_target = ""
		_show_root()
		changed.emit()
		return
	_record("旅人", selected["label"])
	if npc_id == "oren" and page == "targets" and PREVIEW_TARGETS.has(choice_id):
		_selected_target = PREVIEW_TARGETS[choice_id]
		page = "confirm"
		text = "【本地演示数据】选中的是 %s（running）。下一步仅预览关机步骤：未执行任何真实操作，也不会改变示例状态。确认要看预览吗？返回话题会取消这个选择。" % _selected_target
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
					_show_page("guide", "用 WASD 或方向键慢慢走，也可以点地面走近。靠近住客后按 E 或 Enter 交谈，鼠标也能选择话题。聊天时旅人会停下脚步；返回话题不会告别，Esc 由大厅界面处理。别急，旅店的灯会等你。")
				"residents":
					_show_page("residents", "炉火旁的奥伦把虚构云灯记得一清二楚；星术桌边的伊芙爱给资源做小便签；长椅上的菲恩总给未完的故事留座。三人的能力都是本地演示，没有真实 AI 或 Azure 连接。想歇歇的话，我就在吧台。")
				"legend":
					_show_page("legend", "据说第一盏星灯，是一位迷路的制灯匠留下的。他找不到回家的星，就造了一盏等人回来的灯。后来这里成了旅店。我们不问谁走得最远，只问汤还要不要添一点。")
		"oren":
			match choice_id:
				"list_running", "list_all":
					_begin_request("azure.vm", choice_id)
				"shutdown_preview":
					page = "targets"
					_selected_target = ""
					text = "【本地演示数据】先从两盏 running 的虚构云灯里挑一盏。此页只做选择，尚未发送请求；停止的 inn-sleeping-03 不在预览目标中。"
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
					_show_page("explain_resource", "【本地预设讲解】把资源想成一间有编号的客房：区域是它所在的街区，规格像房间大小，状态是门上的挂牌，标签则是你自己贴的便签。这里讲的是虚构样本，不是任何真实资源的鉴定结果。")
		"finn":
			match choice_id:
				"story":
					_begin_request("ai.chat", "story")
				"explain_api":
					_begin_request("ai.chat", "explain")
				"free_chat":
					_show_page("input", "【本地预设对话 · 未调用 AI】写一句想说的话吧，最多 280 字。我的回答来自关键词和预设模板，不会离开这间电脑里的旅店。")


func send_message(message: String) -> void:
	if not is_open or busy or npc_id != "finn" or not allow_input:
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


func _show_page(next_page: String, message: String) -> void:
	page = next_page
	text = message
	choices = [{"id": "back", "label": "返回话题"}]
	allow_input = npc_id == "finn"
	_record_npc(message)
	changed.emit()


func _begin_request(capability: String, action: String, arguments: Dictionary = {}) -> void:
	var generation: int = _session_generation
	busy = true
	page = "waiting"
	text = "【本地演示】传话铃轻轻响了，正在准备本地演示数据或预设回复……"
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
	if not pending_request_id.is_empty():
		port.cancel(pending_request_id)
	pending_request_id = ""
	busy = false
	_selected_target = ""


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