extends "res://scripts/capability_provider.gd"

const BINDINGS: Dictionary = {
	"oren": "azure.vm", "eve": "azure.resource", "finn": "ai.chat",
}
const ACTIONS: Dictionary = {
	"oren": ["list_all", "list_running", "preview_shutdown"],
	"eve": ["inspect", "tags"],
	"finn": ["chat", "story", "explain"],
}
const MAX_MESSAGE_LENGTH: int = 280
const VM_SAMPLES: Array[Dictionary] = [
	{
		"id": "inn-lantern-01", "name": "inn-lantern-01", "status": "running",
		"region": "星湾北区（虚构）", "size": "演示规格 · 2 vCPU / 4 GiB",
		"tags": {"owner": "星灯旅店（虚构）", "purpose": "门廊灯火", "environment": "local-demo"},
	},
	{
		"id": "inn-library-02", "name": "inn-library-02", "status": "running",
		"region": "月桥西区（虚构）", "size": "演示规格 · 4 vCPU / 8 GiB",
		"tags": {"owner": "星灯旅店（虚构）", "purpose": "故事书架", "environment": "local-demo"},
	},
	{
		"id": "inn-sleeping-03", "name": "inn-sleeping-03", "status": "stopped",
		"region": "星湾北区（虚构）", "size": "演示规格 · 1 vCPU / 2 GiB",
		"tags": {"owner": "星灯旅店（虚构）", "purpose": "备用客房", "environment": "local-demo"},
	},
]


func execute(request: Dictionary) -> Dictionary:
	var invalid: Dictionary = _validate_request(request)
	if not invalid.is_empty():
		return invalid
	var npc_id: String = request["npc_id"]
	var capability: String = request["capability"]
	var action: String = request["action"]
	var arguments: Dictionary = request["arguments"]
	if not BINDINGS.has(npc_id):
		return _failure(request, "UNKNOWN_NPC", "【本地演示】这位住客没有绑定演示能力。")
	if capability != BINDINGS[npc_id]:
		return _failure(request, "CAPABILITY_MISMATCH", "【本地演示】这枚传话铃不属于当前住客，未执行任何操作。")
	var allowed_actions: Array = ACTIONS[npc_id]
	if not allowed_actions.has(action):
		return _failure(request, "UNSUPPORTED_ACTION", "【本地演示】账簿里没有这个动作，未执行任何操作。")
	var allowed_arguments: Array[String] = []
	if action == "preview_shutdown" or action == "inspect" or action == "tags":
		allowed_arguments.append("target_id")
	elif action == "chat":
		allowed_arguments.append("message")
	for key: Variant in arguments:
		if not allowed_arguments.has(key):
			return _failure(request, "INVALID_ARGUMENTS", "【本地演示】这个动作不接受参数：%s。" % str(key))
	match npc_id:
		"oren":
			return _vm_action(request, action, arguments)
		"eve":
			return _resource_action(request, action, arguments)
		"finn":
			return _chat_action(request, action, arguments)
	return _failure(request, "UNKNOWN_ERROR", "【本地演示】传话铃走错了路，请返回话题后再试。")


func _vm_action(request: Dictionary, action: String, arguments: Dictionary) -> Dictionary:
	if action == "preview_shutdown":
		var target: Dictionary = _find_target(arguments.get("target_id"))
		if target.is_empty() or target.get("status") != "running":
			return _failure(request, "INVALID_TARGET", "【本地演示数据】请选一盏正在运行的示例云灯；这个目标不可用于预览。")
		return _success(request,
			"【本地演示数据】名字和步骤都对上了，这回只翻账簿，不动灯。已排演 %s 的关机步骤。未执行任何真实操作，未改变任何示例状态；这盏虚构云灯仍为 running。预览不是执行授权。" % target["name"],
			{"source": "local_demo", "target_id": target["id"], "target": target,
				"executed": false, "state_changed": false, "status": target["status"]})
	var items: Array[Dictionary] = []
	var lines: PackedStringArray = []
	for sample: Dictionary in VM_SAMPLES:
		if action == "list_running" and sample["status"] != "running":
			continue
		items.append(sample.duplicate(true))
		lines.append("%s · %s" % [sample["name"], sample["status"]])
	return _success(request,
		"【本地演示数据】嗯，账簿翻到这里了。一项一项看，名字可别略过去。\n账簿里有 %d 台符合条件的虚构虚拟机，未查询 Azure，也不代表真实资源状态：\n%s" % [items.size(), "\n".join(lines)],
		{"source": "local_demo", "items": items, "count": items.size()})


func _resource_action(request: Dictionary, action: String, arguments: Dictionary) -> Dictionary:
	var target: Dictionary = _find_target(arguments.get("target_id", "inn-lantern-01"))
	if target.is_empty():
		return _failure(request, "INVALID_TARGET", "【本地演示数据】这张星图没有对应的虚构资源，请使用示例目标。")
	if action == "tags":
		return _success(request,
			"【本地演示数据】你看这些便签！名字写清楚，才不至于把糖和盐摆成一类。\n%s 的标签：归属「星灯旅店（虚构）」、用途「%s」、环境「local-demo」。它们不是云端查询结果。" % [target["name"], target["tags"]["purpose"]],
			{"source": "local_demo", "target_id": target["id"], "tags": target["tags"]})
	target["type"] = "虚拟机（演示）"
	target["operating_system"] = "旅店样例系统（虚构）"
	return _success(request,
		"【本地演示数据】等一下，先看清楚，再说结论！我把属性逐项列好了：\n名称：%s\n区域：%s\n规格：%s\n状态：%s\n这些是预先写好的演示属性，没有联系 Azure，不代表真实资源。" % [target["name"], target["region"], target["size"], target["status"]],
		{"source": "local_demo", "resource": target})


func _chat_action(request: Dictionary, action: String, arguments: Dictionary) -> Dictionary:
	if action == "story":
		return _success(request,
			"【本地预设回复 · 未调用 AI】从前，有颗小星星错过了归家的队伍。米拉没有问它为何迟到，只在门廊多点了一盏灯。后来，所有迷路的旅人都学会了抬头——不是为了找最亮的星，而是找那盏愿意等人的灯。你听，门铃又响了。",
			{"source": "local_preset", "topic": "story"})
	if action == "explain":
		return _success(request,
			"【本地预设回复 · 未调用 AI】把 API 想成旅店的传话铃：请求写着找谁、做什么和带来的话；回复带回结果或错误。此刻，铃声只在这台电脑里绕一圈，回答来自预设文本，没有连接 AI 或 Azure。",
			{"source": "local_preset", "topic": "api"})
	var raw_message: Variant = arguments.get("message")
	if not raw_message is String:
		return _failure(request, "INVALID_ARGUMENTS", "【本地预设回复】message 必须是一段文字，未调用 AI。")
	var original: String = raw_message
	var message: String = original.strip_edges()
	if message.is_empty():
		return _failure(request, "EMPTY_MESSAGE", "【本地预设回复】长椅已经留好了，写下一点想说的话吧。未调用 AI。")
	if original.length() > MAX_MESSAGE_LENGTH:
		return _failure(request, "MESSAGE_TOO_LONG", "【本地预设回复】这一页最多容纳 280 字，请把话稍稍收短。未调用 AI。")
	var answer: String = "朋友，小事也值得被听见。哪一段愿意说，哪一段留在这张椅子上，都由你决定。"
	var lower: String = message.to_lower()
	if "谢谢" in message or "辛苦" in message:
		answer = "我本来准备说“不必客气”的。你这么认真一说，我倒有点不好意思。谢谢，肯停下来听就是最好的礼物。"
	elif "迷路" in message or "担心" in message or "难过" in message:
		answer = "这回先不唱了。你不必把事情讲成快乐结尾，想说我听着，想安静也可以一起坐会儿。"
	elif "api" in lower or "接口" in message or "azure" in lower or "ai" in lower:
		answer = "眼前只是本地模板与关键词分支，不是 AI 推理，也没有查询 Azure；就像排练时的传话铃。"
	elif "星" in message or "故事" in message or "月" in message:
		answer = "我有一段关于门廊星灯的旧故事。灯不追赶旅人，只把回来的路照得温柔一点。"
	elif "你好" in message or "旅店" in message:
		answer = "欢迎坐到星灯下面。米拉照看炉火，我照看还没说完的故事。"
	return _success(request, "【本地预设回复 · 未调用 AI】你说：“%s”。%s" % [message, answer],
		{"source": "local_template", "input": message, "topic": "chat"})


func _find_target(value: Variant) -> Dictionary:
	if not value is String:
		return {}
	for sample: Dictionary in VM_SAMPLES:
		if sample["id"] == value:
			return sample.duplicate(true)
	return {}