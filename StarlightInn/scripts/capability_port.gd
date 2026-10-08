extends Node

signal response_ready(response: Dictionary)
signal request_dispatched(request: Dictionary)

const DemoProvider = preload("res://scripts/demo_provider.gd")

static var _sequence: int = 0
var _provider_generation: int = 0
var provider: RefCounted = DemoProvider.new():
	set(value):
		if provider != value:
			provider = value
			_provider_generation += 1
var latency_seconds: float = 0.35
var last_request: Dictionary = {}
var _pending: Dictionary = {}


func request(npc_id: String, capability: String, action: String, arguments: Dictionary = {}) -> String:
	_sequence += 1
	var request_id: String = "demo-%d-%d" % [get_instance_id(), _sequence]
	var envelope: Dictionary = {
		"request_id": request_id, "npc_id": npc_id, "capability": capability,
		"action": action, "arguments": arguments.duplicate(true),
	}
	_pending[request_id] = {
		"request": envelope, "provider": provider, "generation": _provider_generation,
	}
	last_request = envelope.duplicate(true)
	# Deferred entry guarantees that even a zero-delay/error response follows return.
	_dispatch_later.call_deferred(request_id)
	request_dispatched.emit(envelope.duplicate(true))
	return request_id


func cancel(request_id: String) -> void:
	_pending.erase(request_id)


func _exit_tree() -> void:
	_pending.clear()


func _dispatch_later(request_id: String) -> void:
	if not _pending.has(request_id):
		return
	var entry: Dictionary = _pending[request_id]
	var envelope: Dictionary = entry["request"]
	if not is_inside_tree():
		_complete(request_id, _error(envelope, "PORT_NOT_READY", "【本地演示】传话铃尚未进入场景，未执行任何操作。"))
		return
	var delay_seconds: float = maxf(0.0, latency_seconds)
	await get_tree().create_timer(delay_seconds).timeout
	if not is_inside_tree() or not _pending.has(request_id):
		return
	var selected_provider: RefCounted = entry["provider"]
	var generation: int = entry["generation"]
	if generation != _provider_generation or selected_provider != provider:
		_complete(request_id, _replaced(envelope))
		return
	if selected_provider == null:
		_complete(request_id, _error(envelope, "NOT_CONFIGURED", "【本地演示】尚未配置提供者，未执行任何操作。"))
		return
	if not selected_provider.has_method("execute"):
		_complete(request_id, _error(envelope, "INVALID_PROVIDER", "【本地演示】提供者没有 execute 方法，未执行任何操作。"))
		return
	# Await also accepts immediate Dictionary results; a delayed replacement remains safe.
	var raw_response: Variant = await selected_provider.call("execute", envelope.duplicate(true))
	if not is_inside_tree() or not _pending.has(request_id):
		return
	if generation != _provider_generation or selected_provider != provider:
		_complete(request_id, _replaced(envelope))
		return
	_complete(request_id, _normalize(raw_response, envelope))


func _complete(request_id: String, response: Dictionary) -> void:
	if not _pending.has(request_id):
		return
	_pending.erase(request_id)
	response_ready.emit(response.duplicate(true))


func _normalize(raw_response: Variant, envelope: Dictionary) -> Dictionary:
	if not raw_response is Dictionary:
		return _error(envelope, "INVALID_RESPONSE", "【本地演示】提供者没有返回有效字典，请返回话题后再试。")
	var response: Dictionary = raw_response
	if response.get("request_id") != envelope["request_id"] or response.get("npc_id") != envelope["npc_id"]:
		return _error(envelope, "RESPONSE_MISMATCH", "【本地演示】回信的编号或收信人不匹配，原回信已丢弃。")
	if response.get("mode") != "demo" or not response.get("side_effects") is bool or response.get("side_effects") != false:
		return _error(envelope, "UNSAFE_RESPONSE", "【本地演示】回信不符合离线演示约定，原回信已丢弃。")
	var message_value: Variant = response.get("message")
	if not response.get("ok") is bool or not message_value is String or not response.get("data") is Dictionary:
		return _error(envelope, "INVALID_RESPONSE", "【本地演示】回信格式不完整，请返回话题后再试。")
	var message: String = message_value
	if message.strip_edges().is_empty():
		return _error(envelope, "INVALID_RESPONSE", "【本地演示】收到了一封空白回信，请返回话题后再试。")
	if not response["ok"]:
		var code: String = "UNKNOWN_ERROR"
		var details: Dictionary = {}
		var raw_error: Variant = response.get("error")
		if raw_error is Dictionary:
			var error_dict: Dictionary = raw_error
			var raw_code: Variant = error_dict.get("code")
			if raw_code is String:
				var string_code: String = raw_code
				if not string_code.strip_edges().is_empty():
					code = string_code
			if error_dict.get("details") is Dictionary:
				details = error_dict["details"].duplicate(true)
		var failure: Dictionary = _error(envelope, code, message)
		failure["error"]["details"] = details
		return failure
	if not response.get("error") is Dictionary:
		return _error(envelope, "INVALID_RESPONSE", "【本地演示】成功回信缺少 error 字典，请返回话题后再试。")
	var success_error: Dictionary = response["error"]
	if not success_error.is_empty():
		return _error(envelope, "INVALID_RESPONSE", "【本地演示】回信同时声明成功和错误，原回信已丢弃。")
	return {
		"request_id": envelope["request_id"], "npc_id": envelope["npc_id"],
		"ok": true, "mode": "demo", "message": message,
		"data": response["data"].duplicate(true), "error": {}, "side_effects": false,
	}


func _replaced(envelope: Dictionary) -> Dictionary:
	return _error(envelope, "PROVIDER_REPLACED", "【本地演示】传话铃已更换提供者，旧请求结果不再使用，请返回话题后重试。")


func _error(envelope: Dictionary, code: String, message: String) -> Dictionary:
	return {
		"request_id": envelope["request_id"], "npc_id": envelope["npc_id"],
		"ok": false, "mode": "demo", "message": message, "data": {},
		"error": {"code": code, "message": message, "details": {}},
		"side_effects": false,
	}