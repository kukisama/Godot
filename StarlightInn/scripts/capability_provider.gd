extends RefCounted

const STRING_FIELDS: Array[String] = ["request_id", "npc_id", "capability", "action"]


func execute(request: Dictionary) -> Dictionary:
	var invalid: Dictionary = _validate_request(request)
	if not invalid.is_empty():
		return invalid
	return _failure(request, "NOT_CONFIGURED", "【本地演示】这只传话铃尚未配置提供者，没有执行任何真实操作。")


func _validate_request(request: Dictionary) -> Dictionary:
	for field: String in STRING_FIELDS:
		var value: Variant = request.get(field)
		if not value is String:
			return _failure(request, "INVALID_REQUEST", "【本地演示】请求缺少有效的文字字段：%s。" % field, {"field": field})
		var string_value: String = value
		if string_value.strip_edges().is_empty():
			return _failure(request, "INVALID_REQUEST", "【本地演示】请求字段不能留白：%s。" % field, {"field": field})
	if not request.get("arguments") is Dictionary:
		return _failure(request, "INVALID_REQUEST", "【本地演示】arguments 必须是字典。", {"field": "arguments"})
	return {}


func _success(request: Dictionary, message: String, data: Dictionary = {}) -> Dictionary:
	return _envelope(request, true, message, data, {})


func _failure(request: Dictionary, code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return _envelope(request, false, message, {}, {
		"code": code, "message": message, "details": details.duplicate(true),
	})


func _envelope(request: Dictionary, ok: bool, message: String, data: Dictionary, error: Dictionary) -> Dictionary:
	return {
		"request_id": request.get("request_id", ""),
		"npc_id": request.get("npc_id", ""),
		"ok": ok,
		"mode": "demo",
		"message": message,
		"data": data.duplicate(true),
		"error": error.duplicate(true),
		"side_effects": false,
	}