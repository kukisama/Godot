extends SceneTree

const NpcCatalog = preload("res://scripts/npc_catalog.gd")
const ProviderScript = preload("res://scripts/capability_provider.gd")
const DemoProvider = preload("res://scripts/demo_provider.gd")
const PortScript = preload("res://scripts/capability_port.gd")
const DialogueScript = preload("res://scripts/dialogue.gd")


class ProbeProvider:
	extends RefCounted
	signal started
	signal finished
	var tree: SceneTree
	var delay_seconds: float = 0.0
	var behavior: String = "echo"
	var calls: Array[Dictionary] = []
	var completed_count: int = 0

	func execute(request: Dictionary) -> Variant:
		calls.append(request.duplicate(true))
		started.emit()
		if delay_seconds > 0.0:
			await tree.create_timer(delay_seconds).timeout
		var response: Dictionary = {
			"request_id": request["request_id"], "npc_id": request["npc_id"],
			"ok": true, "mode": "demo", "message": "【本地演示数据】测试替身的预设回复。",
			"data": {"echo": request["arguments"].duplicate(true)}, "error": {}, "side_effects": false,
		}
		match behavior:
			"failure":
				response["ok"] = false
				response["message"] = "【本地演示】测试替身暂时收起了账簿，请稍后再试。"
				response["error"] = {"code": "LOCAL_FAILURE", "message": response["message"], "details": {"retryable": true}}
			"unknown_error":
				response["ok"] = false
				response["error"] = 17
			"mismatch_id":
				response["request_id"] = "wrong-request"
			"mismatch_npc":
				response["npc_id"] = "finn"
			"missing_message":
				response.erase("message")
			"empty_message":
				response["message"] = "  "
			"bad_ok":
				response["ok"] = 1
			"bad_data":
				response["data"] = []
			"missing_error":
				response.erase("error")
			"ambiguous_success":
				response["error"] = {"code": "CONTRADICTION"}
			"unexpected_mode":
				response["mode"] = "not-demo"
			"side_effects":
				response["side_effects"] = true
		completed_count += 1
		finished.emit()
		if behavior == "not_dictionary":
			return "not a response dictionary"
		return response


var passed: int = 0
var failed: int = 0
var dialogue: DialogueScript
var requests: Array[Dictionary] = []
var responses: Array[Dictionary] = []
var changed_count: int = 0
var closed_count: int = 0
var _unit_sequence: int = 0
var _finished: bool = false
var _completed_sections: Array[String] = []


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	# One deadline, not polling: a broken async path must fail rather than hang forever.
	create_timer(30.0).timeout.connect(_deadline)
	_test_catalog()
	_test_providers()
	dialogue = DialogueScript.new()
	dialogue.port.latency_seconds = 0.01
	root.add_child(dialogue)
	dialogue.changed.connect(_on_changed)
	dialogue.closed.connect(_on_closed)
	dialogue.port.request_dispatched.connect(_on_request)
	dialogue.port.response_ready.connect(_on_response)
	_expect(dialogue.port.get_parent() == dialogue, "_ready owns the capability port")
	_expect(not dialogue.is_open and not dialogue.busy and dialogue.pending_request_id.is_empty(), "initial dialogue state")
	_test_roots_and_mira()
	await _test_oren_and_eve()
	await _test_preview()
	await _test_finn_and_history()
	await _test_failure_and_cancellation()
	await _test_port_contract()
	_expect(_completed_sections == ["catalog", "providers", "roots_and_mira", "oren_and_eve", "preview", "finn_and_history", "failure_and_cancellation", "port_contract"], "all eight test sections completed without an aborted function")
	dialogue.close()
	dialogue.queue_free()
	await process_frame
	_finished = true
	print("DIALOGUE_TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_catalog() -> void:
	_expect(NpcCatalog.IDS == ["mira", "oren", "eve", "finn", "lyra"], "catalog IDs and order")
	var names: Array[String] = ["米拉", "奥伦", "伊芙", "菲恩", "莱拉"]
	var titles: Array[String] = ["旅店主人", "云务管家", "星术鉴定师", "吟游诗人", "巡路信使"]
	var positions: Array[Vector2] = [Vector2(825, 392), Vector2(356, 505), Vector2(1159, 592), Vector2(417, 785), Vector2(950, 650)]
	var labels: Array[String] = ["旅店向导", "云端投影 · 演示", "资源鉴定 · 演示", "AI 对话 · 演示", "旅途见闻 · 本地故事"]
	var colors: Array[Color] = [Color("f4c878"), Color("65d7e7"), Color("bda2f4"), Color("94d699"), Color("43c6b8")]
	for index: int in range(NpcCatalog.IDS.size()):
		var id: String = NpcCatalog.IDS[index]
		var npc: Dictionary = NpcCatalog.get_npc(id)
		_expect(npc.has_all(["id", "name", "title", "capability", "accent", "position", "greeting"]), id + " catalog fields")
		_expect(npc["id"] == id and npc["name"] == names[index] and npc["title"] == titles[index], id + " identity")
		_expect(npc["position"] == positions[index] and npc["position"] is Vector2, id + " exact position")
		_expect(npc["capability"] == labels[index], id + " capability label")
		_expect(npc["accent"] is Color and npc["accent"] == colors[index], id + " accent color")
		_expect(npc["greeting"] is String and not npc["greeting"].is_empty(), id + " greeting")
		npc["name"] = "changed by caller"
		_expect(NpcCatalog.get_npc(id)["name"] == names[index], id + " returns a copy")
	_expect(NpcCatalog.get_npc("unknown").is_empty(), "unknown NPC is empty")
	_completed_sections.append("catalog")


func _test_providers() -> void:
	var base: ProviderScript = ProviderScript.new()
	var demo: DemoProvider = DemoProvider.new()
	var request: Dictionary = _request("oren", "azure.vm", "list_all")
	var result: Dictionary = base.execute(request)
	_assert_envelope(result, request, "base provider")
	_expect(_code(result) == "NOT_CONFIGURED", "base provider is never a real implementation")
	for field: String in ["request_id", "npc_id", "capability", "action", "arguments"]:
		var invalid: Dictionary = request.duplicate(true)
		invalid.erase(field)
		_expect(_code(demo.execute(invalid)) == "INVALID_REQUEST", "reject missing " + field)
	var invalid_arguments: Dictionary = request.duplicate(true)
	invalid_arguments["arguments"] = []
	_expect(_code(demo.execute(invalid_arguments)) == "INVALID_REQUEST", "reject non-dictionary arguments")
	var cases: Array[Dictionary] = [
		_request("oren", "azure.vm", "list_all"),
		_request("oren", "azure.vm", "list_running"),
		_request("oren", "azure.vm", "preview_shutdown", {"target_id": "inn-lantern-01"}),
		_request("eve", "azure.resource", "inspect"),
		_request("eve", "azure.resource", "tags"),
		_request("finn", "ai.chat", "chat", {"message": "你好，旅店"}),
		_request("finn", "ai.chat", "story"),
		_request("finn", "ai.chat", "explain"),
	]
	for item: Dictionary in cases:
		result = demo.execute(item)
		_assert_envelope(result, item, str(item["action"]))
		_expect(result["ok"], "bound action succeeds: " + str(item["action"]))
		_expect("本地" in result["message"], "explicit local marker: " + str(item["action"]))
	var all_before: Dictionary = demo.execute(_request("oren", "azure.vm", "list_all"))
	var all_items: Array = _data(all_before).get("items", [])
	_expect(all_items.size() == 3, "three fictional VMs")
	_expect(all_items[0]["status"] == "running" and all_items[1]["status"] == "running" and all_items[2]["status"] == "stopped", "exactly two running and one stopped")
	var running: Dictionary = demo.execute(_request("oren", "azure.vm", "list_running"))
	_expect(_data(running)["items"].size() == 2, "running filter")
	for target: String in ["inn-lantern-01", "inn-library-02"]:
		result = demo.execute(_request("oren", "azure.vm", "preview_shutdown", {"target_id": target}))
		_expect(result["ok"] and _data(result)["executed"] == false, target + " preview never executes")
		_expect(_data(result)["state_changed"] == false and _data(result)["status"] == "running", target + " preview keeps sample status")
		_expect("未执行任何真实操作" in result["message"] and "未改变" in result["message"], target + " explicit no-operation message")
	var after_preview: Dictionary = demo.execute(_request("oren", "azure.vm", "list_all"))
	_expect(_data(after_preview)["items"] == all_items, "preview cannot change any VM or tags")
	all_items[0]["status"] = "tampered"
	all_items[0]["tags"]["owner"] = "tampered"
	result = demo.execute(_request("oren", "azure.vm", "list_all"))
	_expect(_data(result)["items"][0]["status"] == "running", "VM response is deep-copied")
	_expect(_data(result)["items"][0]["tags"]["owner"] != "tampered", "nested tags are deep-copied")
	for bad_target: Variant in [null, 42, "", "not-a-sample", "inn-sleeping-03"]:
		result = demo.execute(_request("oren", "azure.vm", "preview_shutdown", {"target_id": bad_target}))
		_expect(_code(result) == "INVALID_TARGET", "reject invalid/stopped preview target: " + str(bad_target))
	_expect(_code(demo.execute(_request("oren", "azure.vm", "preview_shutdown"))) == "INVALID_TARGET", "preview requires explicit target")
	for action: String in ["inspect", "tags"]:
		_expect(_code(demo.execute(_request("eve", "azure.resource", action, {"target_id": "missing"}))) == "INVALID_TARGET", "reject unknown resource for " + action)
	result = demo.execute(_request("eve", "azure.resource", "inspect", {"target_id": "inn-library-02"}))
	_expect(_data(result)["resource"].has_all(["name", "region", "size", "status", "type", "operating_system"]), "resource inspection attributes")
	_expect(_data(result)["resource"]["name"] == "inn-library-02", "explicit resource target")
	var invalid_cases: Array[Dictionary] = [
		{"request": _request("nobody", "azure.vm", "list_all"), "code": "UNKNOWN_NPC"},
		{"request": _request("mira", "azure.vm", "list_all"), "code": "UNKNOWN_NPC"},
		{"request": _request("oren", "azure.resource", "inspect"), "code": "CAPABILITY_MISMATCH"},
		{"request": _request("eve", "azure.vm", "list_all"), "code": "CAPABILITY_MISMATCH"},
		{"request": _request("finn", "azure.vm", "list_all"), "code": "CAPABILITY_MISMATCH"},
		{"request": _request("oren", "azure.vm", "delete"), "code": "UNSUPPORTED_ACTION"},
		{"request": _request("eve", "azure.resource", "chat"), "code": "UNSUPPORTED_ACTION"},
		{"request": _request("finn", "ai.chat", "inspect"), "code": "UNSUPPORTED_ACTION"},
		{"request": _request("oren", "azure.vm", "list_all", {"force": true}), "code": "INVALID_ARGUMENTS"},
		{"request": _request("finn", "ai.chat", "chat", {"message": 123}), "code": "INVALID_ARGUMENTS"},
		{"request": _request("finn", "ai.chat", "chat", {"message": " \t\n"}), "code": "EMPTY_MESSAGE"},
		{"request": _request("finn", "ai.chat", "chat", {"message": "星".repeat(281)}), "code": "MESSAGE_TOO_LONG"},
	]
	for invalid_case: Dictionary in invalid_cases:
		result = demo.execute(invalid_case["request"])
		_expect(not result["ok"] and _code(result) == invalid_case["code"], "structured provider error: " + str(invalid_case["code"]))
		_expect(result["side_effects"] == false and result["mode"] == "demo", "errors remain offline")
	result = demo.execute(_request("finn", "ai.chat", "chat", {"message": "星".repeat(280)}))
	_expect(result["ok"], "provider accepts exactly 280 characters")
	var template_responses: Dictionary = {}
	for message: String in ["谢谢", "我有点难过", "API 是什么", "讲一个星星故事", "你好，旅店", "蓝色茶杯"]:
		result = demo.execute(_request("finn", "ai.chat", "chat", {"message": message}))
		_expect(message in result["message"] and "未调用 AI" in result["message"], "template quotes input and disclaims AI: " + message)
		template_responses[result["message"]] = true
	_expect(template_responses.size() == 6, "keyword branches and fallback produce distinct replies")
	_completed_sections.append("providers")


func _test_roots_and_mira() -> void:
	var menus: Dictionary = {
		"mira": ["guide", "residents", "legend", "goodbye"],
		"oren": ["list_running", "list_all", "shutdown_preview", "chat"],
		"eve": ["inspect", "tags", "explain_resource", "goodbye"],
		"finn": ["story", "explain_api", "free_chat", "goodbye"],
		"lyra": ["road_story", "satchel", "storm", "goodbye"],
	}
	for id: String in NpcCatalog.IDS:
		_expect(dialogue.open_for(id), "open " + id)
		_expect(_choice_ids() == menus[id], id + " complete root menu")
		_expect(dialogue.is_open and dialogue.page == "root" and dialogue.visited.has(id), id + " root and visited state")
		_expect(dialogue.allow_input == (id == "finn"), id + " input permission")
		_expect(dialogue.history[0].has_all(["speaker", "text"]), id + " history schema")
	_expect(closed_count == 0, "switching NPC does not emit closed")
	dialogue.open_for("mira")
	var before_changed: int = changed_count
	var before_text: String = dialogue.text
	_expect(not dialogue.open_for("unknown"), "unknown open rejected")
	_expect(dialogue.npc_id == "mira" and dialogue.text == before_text and changed_count == before_changed, "unknown open leaves conversation intact")
	var before_requests: int = requests.size()
	dialogue.choose("forged-action")
	dialogue.choose("confirm_preview")
	dialogue.send_message("米拉不能接收自由输入")
	_expect(requests.size() == before_requests and changed_count == before_changed, "invalid choices and forbidden input are no-ops")
	for choice: String in ["guide", "residents", "legend"]:
		dialogue.choose(choice)
		_expect(dialogue.page == choice and _choice_ids() == ["back"], "Mira branch and back: " + choice)
		_expect(dialogue.history[-2]["speaker"] == "旅人" and dialogue.history[-1]["speaker"] == "米拉", "Mira history contains both speakers")
		before_changed = changed_count
		dialogue.choose(choice)
		_expect(changed_count == before_changed, "double click on old local option ignored")
		dialogue.choose("back")
		_expect(dialogue.is_open and dialogue.page == "root", "back is not close")
	_expect(requests.size() == before_requests, "all Mira branches are local text without requests")
	var before_closed: int = closed_count
	dialogue.choose("goodbye")
	_expect(not dialogue.is_open and closed_count == before_closed + 1, "goodbye emits closed once")
	before_changed = changed_count
	dialogue.close()
	dialogue.choose("guide")
	_expect(closed_count == before_closed + 1 and changed_count == before_changed, "repeated close and closed-menu selection do nothing")
	_completed_sections.append("roots_and_mira")


func _test_oren_and_eve() -> void:
	dialogue.open_for("oren")
	var before_requests: int = requests.size()
	dialogue.choose("list_running")
	_expect(dialogue.busy and not dialogue.pending_request_id.is_empty(), "request is immediately pending")
	_expect(dialogue.last_request["action"] == "list_running" and dialogue.last_request["npc_id"] == "oren", "debug request matches branch")
	_expect(_choice_ids() == ["back"], "waiting page retains back option")
	dialogue.choose("list_running")
	dialogue.choose("list_all")
	dialogue.choose("back")
	dialogue.send_message("busy input")
	_expect(requests.size() == before_requests + 1 and dialogue.busy, "busy ignores duplicate, different, back and text input")
	await _finish_dialogue()
	_expect(_data(dialogue.last_response)["items"].size() == 2, "Oren running result")
	_expect("本地演示数据" in dialogue.text and _choice_ids() == ["back"], "result is local and offers back")
	dialogue.choose("list_all")
	_expect(requests.size() == before_requests + 1, "old root choice cannot execute from result")
	dialogue.choose("back")
	dialogue.choose("list_all")
	await _finish_dialogue()
	_expect(_data(dialogue.last_response)["items"].size() == 3, "Oren all VM result")
	dialogue.choose("back")
	before_requests = requests.size()
	dialogue.choose("chat")
	_expect(dialogue.page == "chat" and requests.size() == before_requests, "Oren chat is a local branch, not an unsupported capability")
	dialogue.choose("back")
	dialogue.open_for("eve")
	dialogue.choose("inspect")
	await _finish_dialogue()
	_expect(_data(dialogue.last_response)["resource"].has_all(["region", "size", "status"]), "Eve displays demo attributes")
	dialogue.choose("back")
	dialogue.choose("tags")
	await _finish_dialogue()
	_expect(_data(dialogue.last_response)["tags"]["environment"] == "local-demo", "Eve displays demo tags")
	dialogue.choose("back")
	before_requests = requests.size()
	dialogue.choose("explain_resource")
	_expect(dialogue.page == "explain_resource" and requests.size() == before_requests, "Eve resource explanation is local")
	dialogue.choose("back")
	dialogue.choose("goodbye")
	_expect(not dialogue.is_open, "Eve goodbye")
	_completed_sections.append("oren_and_eve")


func _test_preview() -> void:
	dialogue.open_for("oren")
	var before_requests: int = requests.size()
	dialogue.choose("confirm_preview")
	dialogue.choose("shutdown_preview")
	_expect(dialogue.page == "targets" and _choice_ids() == ["target_lantern", "target_library", "back"], "preview first shows only two running targets")
	dialogue.choose("target_sleeping")
	dialogue.choose("confirm_preview")
	_expect(dialogue.page == "targets" and requests.size() == before_requests, "no request or confirmation before a valid target")
	dialogue.choose("target_lantern")
	_expect(dialogue.page == "confirm" and "inn-lantern-01" in dialogue.text, "separate target confirmation page")
	_expect(_choice_ids() == ["confirm_preview", "back"] and requests.size() == before_requests, "target selection does not dispatch")
	dialogue.choose("target_lantern")
	dialogue.choose("back")
	dialogue.choose("confirm_preview")
	_expect(dialogue.page == "root" and requests.size() == before_requests, "back cancels target and old confirmation")
	dialogue.choose("shutdown_preview")
	dialogue.choose("target_library")
	dialogue.close()
	dialogue.open_for("oren")
	dialogue.choose("confirm_preview")
	_expect(requests.size() == before_requests, "close cancels confirmation across reopening")
	dialogue.choose("shutdown_preview")
	dialogue.choose("target_library")
	dialogue.choose("confirm_preview")
	_expect(dialogue.busy and requests.size() == before_requests + 1, "only current confirmation dispatches")
	_expect(dialogue.last_request["action"] == "preview_shutdown" and dialogue.last_request["arguments"]["target_id"] == "inn-library-02", "preview targets selected VM")
	dialogue.choose("confirm_preview")
	_expect(requests.size() == before_requests + 1, "double confirmation cannot dispatch twice")
	await _finish_dialogue()
	_expect(_data(dialogue.last_response)["executed"] == false and dialogue.last_response["side_effects"] == false, "confirmed preview has no real side effects")
	_expect("未执行任何真实操作" in dialogue.text and "未改变" in dialogue.text, "preview result explicitly disclaims any change")
	dialogue.choose("back")
	dialogue.choose("list_running")
	await _finish_dialogue()
	var items: Array = _data(dialogue.last_response)["items"]
	_expect(items.size() == 2 and items[1]["id"] == "inn-library-02" and items[1]["status"] == "running", "confirmed preview did not stop the sample")
	_completed_sections.append("preview")


func _test_finn_and_history() -> void:
	dialogue.open_for("finn")
	for choice: String in ["story", "explain_api"]:
		dialogue.choose(choice)
		await _finish_dialogue()
		_expect("未调用 AI" in dialogue.text and dialogue.allow_input, "Finn preset reply with input still enabled: " + choice)
		dialogue.choose("back")
	var before_requests: int = requests.size()
	dialogue.choose("free_chat")
	_expect(dialogue.page == "input" and dialogue.allow_input and requests.size() == before_requests, "free chat opens without dispatch")
	dialogue.send_message(" \t\n\r ")
	_expect(not dialogue.busy and "空白" in dialogue.text and requests.size() == before_requests, "blank input is visibly rejected without submission")
	dialogue.send_message("星".repeat(281))
	_expect(not dialogue.busy and "280" in dialogue.text and requests.size() == before_requests, "overlong input is visibly rejected without submission")
	dialogue.send_message(" " + "星".repeat(280))
	_expect(requests.size() == before_requests, "original input length includes surrounding whitespace")
	dialogue.send_message("星".repeat(280))
	await _finish_dialogue()
	_expect(dialogue.last_response["ok"] and dialogue.last_request["arguments"]["message"].length() == 280, "dialogue accepts exactly 280 characters")
	dialogue.send_message("[b]星灯[/b]")
	await _finish_dialogue()
	_expect("[b]星灯[/b]" in dialogue.text, "user markup remains literal plain text")
	_expect(dialogue.history[-2]["text"] == "[b]星灯[/b]" and dialogue.history[-2]["speaker"] == "旅人", "history preserves user input")
	_expect(dialogue.history[-1]["speaker"] == "菲恩" and dialogue.history[-1]["text"] == dialogue.text, "history preserves NPC reply")
	before_requests = requests.size()
	dialogue.send_message("  谢谢你，菲恩  \n")
	dialogue.send_message("这句不能在忙碌时提交")
	_expect(requests.size() == before_requests + 1, "busy blocks repeated free text")
	await _finish_dialogue()
	_expect(_data(dialogue.last_response)["input"] == "谢谢你，菲恩", "valid input trims edges")
	for index: int in range(31):
		dialogue.send_message("今晚的第 %d 杯热茶" % index)
		await _finish_dialogue()
	_expect(dialogue.history.size() == 60, "current NPC history is capped at 60 entries")
	_expect(dialogue.history_by_npc["finn"].size() == 60, "stored NPC history is capped at 60 entries")
	var saved_finn: Array[Dictionary] = dialogue.history.duplicate(true)
	dialogue.open_for("mira")
	_expect(dialogue.history != saved_finn and dialogue.history_by_npc["finn"] == saved_finn, "histories do not leak across NPCs")
	dialogue.open_for("finn")
	_expect(dialogue.history == saved_finn, "reopening restores history without duplicate greeting")
	_expect(dialogue.visited.size() == 5, "visited remembers all five NPCs")
	dialogue.choose("goodbye")
	_expect(not dialogue.is_open and not dialogue.allow_input and dialogue.history.is_empty(), "Finn goodbye clears live UI but retains stored history")
	_expect(dialogue.history_by_npc["finn"] == saved_finn, "close preserves session history")
	_completed_sections.append("finn_and_history")


func _test_failure_and_cancellation() -> void:
	dialogue.port.provider = ProviderScript.new()
	dialogue.open_for("oren")
	dialogue.choose("list_all")
	await _finish_dialogue()
	_expect(_code(dialogue.last_response) == "NOT_CONFIGURED" and not dialogue.last_response["ok"], "failure response reaches dialogue")
	_expect("未配置" in dialogue.text and _choice_ids() == ["back"] and not dialogue.busy, "failure visible and UI unlocked")
	var probe: ProbeProvider = ProbeProvider.new()
	probe.tree = self
	probe.behavior = "failure"
	dialogue.port.provider = probe
	dialogue.choose("back")
	dialogue.choose("list_all")
	await _finish_dialogue()
	_expect(_code(dialogue.last_response) == "LOCAL_FAILURE" and dialogue.history[-1]["text"] == dialogue.text, "structured error is recorded as NPC reply")
	probe = ProbeProvider.new()
	probe.tree = self
	dialogue.port.provider = probe
	dialogue.open_for("oren")
	dialogue.choose("list_all")
	var before_responses: int = responses.size()
	dialogue.close()
	await create_timer(0.05).timeout
	_expect(probe.calls.is_empty() and responses.size() == before_responses, "closing before latency cancels execution and response")
	_expect(not dialogue.busy and dialogue.pending_request_id.is_empty(), "close clears pending UI state")
	probe = ProbeProvider.new()
	probe.tree = self
	probe.delay_seconds = 0.04
	dialogue.port.provider = probe
	dialogue.open_for("finn")
	dialogue.send_message("请替我留一盏灯")
	await probe.started
	before_responses = responses.size()
	dialogue.close()
	await _finish_probe(probe)
	_expect(probe.calls.size() == 1 and probe.completed_count == 1, "late provider actually finished after close")
	_expect(responses.size() == before_responses and dialogue.last_response.is_empty(), "late result after close is discarded")
	probe = ProbeProvider.new()
	probe.tree = self
	probe.delay_seconds = 0.07
	dialogue.port.provider = probe
	dialogue.open_for("oren")
	dialogue.choose("list_all")
	var old_id: String = dialogue.pending_request_id
	await probe.started
	var before_closed: int = closed_count
	dialogue.open_for("eve")
	dialogue.port.provider = DemoProvider.new()
	dialogue.choose("inspect")
	var current_id: String = dialogue.pending_request_id
	var waiting_text: String = dialogue.text
	var forged: Dictionary = {
		"request_id": old_id, "npc_id": "oren", "ok": true, "mode": "demo",
		"message": "旧 NPC 的晚到回复", "data": {}, "error": {}, "side_effects": false,
	}
	dialogue.port.response_ready.emit(forged)
	forged["request_id"] = current_id
	dialogue.port.response_ready.emit(forged)
	forged["request_id"] = old_id
	forged["npc_id"] = "eve"
	dialogue.port.response_ready.emit(forged)
	_expect(dialogue.busy and dialogue.pending_request_id == current_id and dialogue.text == waiting_text, "dialogue rejects wrong ID, wrong NPC and stale reply")
	await _finish_dialogue()
	await _finish_probe(probe)
	_expect(dialogue.npc_id == "eve" and dialogue.last_response["request_id"] == current_id, "late Oren result cannot replace Eve response")
	_expect(dialogue.history[-1]["speaker"] == "伊芙" and not ("旧 NPC" in dialogue.text), "late reply cannot pollute new history")
	_expect(closed_count == before_closed, "switch cancels without emitting closed")
	dialogue.open_for("oren")
	dialogue.choose("list_all")
	current_id = dialogue.pending_request_id
	_expect(not dialogue.open_for("missing") and dialogue.pending_request_id == current_id, "invalid open does not cancel active request")
	await _finish_dialogue()
	_expect(dialogue.last_response["request_id"] == current_id and dialogue.last_response["ok"], "valid pending request survives invalid open")
	# Reentrant listeners can close before request() returns its ID.
	dialogue.open_for("oren")
	var close_on_dispatch: Callable = func(_request_data: Dictionary) -> void: dialogue.close()
	dialogue.port.request_dispatched.connect(close_on_dispatch)
	before_responses = responses.size()
	dialogue.choose("list_all")
	dialogue.port.request_dispatched.disconnect(close_on_dispatch)
	await create_timer(0.05).timeout
	_expect(not dialogue.is_open and not dialogue.busy and dialogue.pending_request_id.is_empty(), "reentrant close cannot leave an orphan pending ID")
	_expect(responses.size() == before_responses, "reentrant close also cancels the port request")
	_completed_sections.append("failure_and_cancellation")


func _test_port_contract() -> void:
	var port: PortScript = PortScript.new()
	_expect(is_equal_approx(port.latency_seconds, 0.35) and port.provider.get_script() == DemoProvider, "port default provider and latency")
	port.latency_seconds = 0.01
	root.add_child(port)
	var probe: ProbeProvider = ProbeProvider.new()
	probe.tree = self
	port.provider = probe
	var arguments: Dictionary = {"nested": {"items": [{"value": "original"}]}}
	var mutate_signal: Callable = func(envelope: Dictionary) -> void:
		envelope["arguments"]["nested"]["items"][0]["value"] = "signal mutation"
		envelope["request_id"] = "signal mutation"
	port.request_dispatched.connect(mutate_signal)
	var first_id: String = port.request("oren", "azure.vm", "list_all", arguments)
	port.request_dispatched.disconnect(mutate_signal)
	arguments["nested"]["items"][0]["value"] = "caller mutation"
	port.last_request["arguments"]["nested"]["items"][0]["value"] = "debug mutation"
	_expect(probe.calls.is_empty(), "request returns before executing provider")
	var result: Dictionary = await port.response_ready
	_expect(result["request_id"] == first_id and probe.calls[0]["request_id"] == first_id, "signal cannot rewrite pending request identity")
	_expect(probe.calls[0]["arguments"]["nested"]["items"][0]["value"] == "original", "caller, signal and debug mutations cannot change deep-copied request")
	_expect(_data(result)["echo"]["nested"]["items"][0]["value"] == "original", "provider sees pristine nested arguments")
	var malformed_cases: Array[Dictionary] = [
		{"behavior": "failure", "code": "LOCAL_FAILURE"},
		{"behavior": "unknown_error", "code": "UNKNOWN_ERROR"},
		{"behavior": "mismatch_id", "code": "RESPONSE_MISMATCH"},
		{"behavior": "mismatch_npc", "code": "RESPONSE_MISMATCH"},
		{"behavior": "not_dictionary", "code": "INVALID_RESPONSE"},
		{"behavior": "missing_message", "code": "INVALID_RESPONSE"},
		{"behavior": "empty_message", "code": "INVALID_RESPONSE"},
		{"behavior": "bad_ok", "code": "INVALID_RESPONSE"},
		{"behavior": "bad_data", "code": "INVALID_RESPONSE"},
		{"behavior": "missing_error", "code": "INVALID_RESPONSE"},
		{"behavior": "ambiguous_success", "code": "INVALID_RESPONSE"},
		{"behavior": "unexpected_mode", "code": "UNSAFE_RESPONSE"},
		{"behavior": "side_effects", "code": "UNSAFE_RESPONSE"},
	]
	for malformed: Dictionary in malformed_cases:
		probe.behavior = malformed["behavior"]
		result = await _roundtrip(port)
		_expect(_code(result) == malformed["code"] and not result["ok"], "normalize " + str(malformed["behavior"]))
		_assert_envelope(result, port.last_request, "normalized " + str(malformed["behavior"]))
	probe.behavior = "echo"
	var next_provider: ProbeProvider = ProbeProvider.new()
	next_provider.tree = self
	var calls_before: int = probe.calls.size()
	var cancelled_id: String = port.request("oren", "azure.vm", "list_all")
	port.cancel(cancelled_id)
	port.cancel(cancelled_id)
	port.cancel("unknown-id")
	await create_timer(0.05).timeout
	_expect(probe.calls.size() == calls_before, "cancel is idempotent and prevents execution")
	var replaced_id: String = port.request("oren", "azure.vm", "list_all")
	port.provider = next_provider
	result = await port.response_ready
	_expect(result["request_id"] == replaced_id and _code(result) == "PROVIDER_REPLACED", "replacement before execution is a structured failure")
	_expect(probe.calls.size() == calls_before and next_provider.calls.is_empty(), "old request is never rerouted to new provider")
	result = await _roundtrip(port)
	_expect(result["ok"] and next_provider.calls.size() == 1, "new requests use replacement provider")
	_expect(result["request_id"] != first_id and result["request_id"] != cancelled_id, "request IDs are unique")
	var roundtrip_id: String = port.request("oren", "azure.vm", "list_all")
	port.provider = probe
	port.provider = next_provider
	result = await port.response_ready
	_expect(result["request_id"] == roundtrip_id and _code(result) == "PROVIDER_REPLACED", "A-B-A replacement is detected by generation")
	probe = ProbeProvider.new()
	probe.tree = self
	probe.delay_seconds = 0.03
	port.provider = probe
	var in_flight_id: String = port.request("oren", "azure.vm", "list_all")
	await probe.started
	port.provider = next_provider
	result = await port.response_ready
	_expect(result["request_id"] == in_flight_id and _code(result) == "PROVIDER_REPLACED", "replacement during provider await rejects late data")
	_expect(probe.completed_count == 1, "replacement test actually completed old provider")
	port.provider = null
	result = await _roundtrip(port)
	_expect(_code(result) == "NOT_CONFIGURED", "null provider normalized")
	port.provider = RefCounted.new()
	result = await _roundtrip(port)
	_expect(_code(result) == "INVALID_PROVIDER", "missing execute method normalized")
	port.queue_free()
	var detached: PortScript = PortScript.new()
	detached.request("oren", "azure.vm", "list_all")
	result = await detached.response_ready
	_expect(_code(result) == "PORT_NOT_READY", "request outside scene tree fails asynchronously")
	detached.queue_free()
	await process_frame
	_completed_sections.append("port_contract")


func _finish_dialogue() -> void:
	if dialogue.busy:
		await dialogue.changed
	# changed is nested inside response_ready; let all response listeners finish.
	await process_frame
	_expect(not dialogue.busy and dialogue.pending_request_id.is_empty(), "async completion clears busy and pending ID")


func _finish_probe(probe: ProbeProvider) -> void:
	if probe.completed_count == 0:
		await probe.finished
	await process_frame


func _roundtrip(port: PortScript) -> Dictionary:
	var request_id: String = port.request("oren", "azure.vm", "list_all")
	var response: Dictionary = await port.response_ready
	_expect(response.get("request_id") == request_id, "port reply is correlated with its request")
	return response


func _request(npc_id: String, capability: String, action: String, arguments: Dictionary = {}) -> Dictionary:
	_unit_sequence += 1
	return {"request_id": "unit-%d" % _unit_sequence, "npc_id": npc_id, "capability": capability, "action": action, "arguments": arguments.duplicate(true)}


func _data(response: Dictionary) -> Dictionary:
	var value: Variant = response.get("data", {})
	if value is Dictionary:
		return value
	return {}


func _code(response: Dictionary) -> String:
	var error: Variant = response.get("error", {})
	if error is Dictionary:
		return str(error.get("code", ""))
	return ""


func _choice_ids() -> Array[String]:
	var result: Array[String] = []
	for choice: Dictionary in dialogue.choices:
		result.append(choice["id"])
	return result


func _assert_envelope(response: Dictionary, request: Dictionary, label: String) -> void:
	_expect(response.has_all(["request_id", "npc_id", "ok", "mode", "message", "data", "error", "side_effects"]), label + " response fields")
	_expect(response.get("request_id") == request.get("request_id") and response.get("npc_id") == request.get("npc_id"), label + " response correlation")
	_expect(response.get("ok") is bool and response.get("mode") == "demo" and response.get("side_effects") == false, label + " local safety envelope")
	_expect(response.get("message") is String and not str(response.get("message", "")).is_empty(), label + " visible message")
	_expect(response.get("data") is Dictionary and response.get("error") is Dictionary, label + " data and error dictionaries")
	if response.get("ok") == false:
		var error: Dictionary = response.get("error", {})
		_expect(error.has_all(["code", "message", "details"]) and error.get("details") is Dictionary, label + " structured error fields")


func _expect(condition: bool, label: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: " + label)


func _on_request(request: Dictionary) -> void:
	requests.append(request.duplicate(true))


func _on_response(response: Dictionary) -> void:
	responses.append(response.duplicate(true))


func _on_changed() -> void:
	changed_count += 1


func _on_closed() -> void:
	closed_count += 1


func _deadline() -> void:
	if _finished:
		return
	_expect(false, "test deadline: an async path did not finish")
	print("DIALOGUE_TESTS: %d passed, %d failed" % [passed, failed])
	quit(1)