extends Node
## Token-free DTOs only. Native authentication/HTTP never runs in headless QA.
signal Reply(json: String)
signal JournalChanged(json: String)
signal Initialized

const MAX_PACKET := 1024 * 1024
const MAX_QUEUE := 1024 * 1024
var _pipe: Dictionary = {}
var _rx := PackedByteArray()
var _tx := PackedByteArray()
var _pending: Dictionary = {}
var _uncertain_requests: Dictionary = {}
var _confirmations: Dictionary = {}
var _queued_bytes: int = 0
var _sent_bytes: int = 0
var _context: Dictionary = {"generation": 0, "account": "", "tenant_id": "", "tenant_name": "", "subscription_id": "", "subscription_name": ""}
var _settings: Dictionary = {"client_id": "", "initial_tenant": "organizations"}
var _preferences: Dictionary = {"auto_login": true, "has_identity": false, "restoring": false, "notice": "请首次手动登录；仅原生 WAM，不保存密码。"}
var _config_path: String = ""
var _profile_path: String = ""
var _config_error: String = ""
var _boot_failure: String = ""
var _ready_deadline: int = 0
var _booted: bool = false
var _exiting: bool = false
var _write_quarantine: bool = false
var _last_operations: Array = []
var _orphan_operations: Array = []
var request_timeout_ms: int = 190000


func _ready() -> void:
    _config_path = ProjectSettings.globalize_path("res://azure-settings.json") if OS.has_feature("editor") else OS.get_executable_path().get_base_dir().path_join("azure-settings.json")
    var file := FileAccess.open(_config_path, FileAccess.READ)
    if file != null:
        if file.get_length() > 4096:
            _config_error = "公开配置过大，请重新保存。"
        else:
            var raw: Variant = JSON.parse_string(file.get_as_text())
            if raw is Dictionary and raw.size() == 2 and raw.get("client_id") is String and raw.get("initial_tenant") is String:
                _settings = raw
            else:
                _config_error = "公开配置无效，请重新保存 ClientId 与初始目录。"
        file.close()
    if _allow_helper():
        _start()


func _allow_helper() -> bool:
    return OS.get_name() == "Windows" and DisplayServer.get_name() != "headless"


func _helper_path() -> String:
    return ProjectSettings.globalize_path("res://native/StarlightAzure.exe") if OS.has_feature("editor") else OS.get_executable_path().get_base_dir().path_join("native/StarlightAzure.exe")


func _start() -> bool:
    if not _pipe.is_empty():
        return true
    _pipe = OS.execute_with_pipe(_helper_path(), ["--pipe-v2"], false)
    if _pipe.is_empty():
        _config_error = "HELPER_UNAVAILABLE：本地 helper 未启动；请检查发布目录中的 native/StarlightAzure.exe。"
        return false
    _boot_failure = ""
    _rx.clear()
    _tx.clear()
    _queued_bytes = 0
    _sent_bytes = 0
    _booted = false
    _ready_deadline = Time.get_ticks_msec() + 5000
    _enqueue({"id": "bootstrap", "action": "bootstrap", "args": _settings, "hwnd": 0})
    return true


func GetSettings() -> String:
    return JSON.stringify({"settings": _settings, "path": _config_path, "error": _config_error, "preferences": _preferences, "profile_path": _profile_path})


func GetContext() -> String:
    return JSON.stringify(_context)


func Request(id: String, action: String, arguments: String) -> void:
    if _exiting:
        return
    if not _allow_helper():
        _failure(id, action, "HEADLESS_OFFLINE")
        return
    if _write_quarantine and action in ["prepare", "execute"]:
        _failure(id, action, "HELPER_RESULT_UNCERTAIN")
        return
    var args: Variant = JSON.parse_string(arguments)
    if id.is_empty() or id.length() > 100 or not args is Dictionary or arguments.to_utf8_buffer().size() > MAX_PACKET:
        _failure(id, action, "INVALID_REQUEST")
        return
    if _pending.has(id) or _uncertain_requests.has(id):
        _failure(id, action, "DUPLICATE_REQUEST")
        return
    if not _start():
        _failure(id, action, "HELPER_UNAVAILABLE")
        return
    var hwnd: int = 0 if DisplayServer.get_name() == "headless" else DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
    var confirmation: Dictionary = _confirmations.get(args.get("nonce", ""), {})
    _pending[id] = {"action": action, "deadline": Time.get_ticks_msec() + request_timeout_ms, "wire_start": _queued_bytes, "context": confirmation.get("context", _context).duplicate(true), "target": confirmation.get("target", {}).duplicate(true), "operation_action": confirmation.get("action", "execute")}
    if not _enqueue({"id": id, "action": action, "args": args, "hwnd": hwnd}):
        _pending.erase(id)
        _failure(id, action, "PIPE_BACKPRESSURE")


func _enqueue(packet: Dictionary) -> bool:
    var bytes := (JSON.stringify(packet) + "\n").to_utf8_buffer()
    if bytes.size() > MAX_PACKET or _tx.size() + bytes.size() > MAX_QUEUE:
        return false
    _tx.append_array(bytes)
    _queued_bytes += bytes.size()
    return true


func CancelLogin() -> void:
    _control("cancel_login")


func CancelConfirmation() -> void:
    _confirmations.clear()
    _control("cancel_confirmation")


func CancelQueries() -> void:
    _control("cancel_queries")


func _control(action: String) -> void:
    if not _pipe.is_empty() and not _enqueue({"id": "control", "action": action, "args": {}, "hwnd": 0}):
        _lost("PIPE_BACKPRESSURE")


func _failure(id: String, action: String, code: String) -> void:
    var message := "本地请求未完成；未启动浏览器或输出凭据。操作提交结果若不确定，不得盲目重复提交。"
    if not _boot_failure.is_empty():
        message = _boot_failure
    elif code.begins_with("HELPER_"):
        message = "阶段: helper_boot; " + code + "。请检查本地 helper 与发布目录，不能据此认定缺少 WAM。"
    Reply.emit(JSON.stringify({"id": id, "action": action, "ok": false, "code": code, "message": message, "context": _context, "preferences": _preferences, "data": null, "mode": "real"}))


func _safe_diagnostic(raw: Dictionary) -> String:
    var diag: Variant = raw.get("diagnostic")
    if not diag is Dictionary or not raw.get("code") in ["AUTH_NATIVE_FAILED", "WAM_PROVIDER_MISSING", "WAM_WINDOW_REQUIRED", "HELPER_BOOT_FAILED"]:
        return ""
    if not diag.get("stage") in ["winrt_init", "wam_factory", "find_provider", "create_request", "parent_window", "request_token", "silent_token", "validate_response", "find_account", "sign_out", "invalidate_cache", "helper_boot"]:
        return ""
    var hr: Variant = diag.get("hresult")
    if not hr is String or hr.length() != 10 or not hr.begins_with("0x"):
        return ""
    for digit: String in hr.substr(2):
        if not digit in "0123456789ABCDEF":
            return ""
    if diag.has("provider_error") and (not (diag.provider_error is int or diag.provider_error is float) or not is_finite(float(diag.provider_error)) or float(diag.provider_error) < 0 or float(diag.provider_error) > 4294967295 or float(diag.provider_error) != floor(float(diag.provider_error))):
        return ""
    var detail: String = "阶段: %s; HRESULT: %s" % [diag.stage, hr]
    if diag.has("provider_error"):
        detail += "; ProviderError: %d (0x%08X)" % [int(diag.provider_error), int(diag.provider_error)]
    # Only this reconstructed whitelist goes to logs; never raw.message/json.
    print("AUTH_DIAGNOSTIC code=%s %s" % [raw.code, detail])
    var hint := "原生认证/初始化未完成；未输出原始异常或凭据。"
    if raw.code == "WAM_PROVIDER_MISSING":
        hint = "本账户的 Entra broker provider 不可用；先检查组件状态，不自动安装。"
    elif raw.code == "WAM_WINDOW_REQUIRED":
        hint = "父窗口校验失败，未发起 WAM 请求。"
    return hint + " " + detail


func _process(_delta: float) -> void:
    if _exiting or _pipe.is_empty():
        return
    if not OS.is_process_running(_pipe.pid):
        _lost("HELPER_EXITED")
        return
    var io: FileAccess = _pipe.stdio
    # One-byte writes are indivisible: success consumes one byte; full pipe
    # consumes none. Never resend a possibly-partial multi-byte buffer.
    var sent: int = 0
    while sent < mini(_tx.size(), 4096):
        if not io.store_8(_tx[sent]):
            if io.get_error() != ERR_BUSY and io.get_error() != ERR_FILE_CANT_WRITE:
                _lost("PIPE_WRITE_FAILED")
                return
            break
        sent += 1
        _sent_bytes += 1
    if sent > 0:
        _tx = _tx.slice(sent)
    var available: int = io.get_length()
    if available > 0:
        var bytes := io.get_buffer(mini(available, 65536))
        if io.get_error() != OK:
            _lost("PIPE_READ_FAILED")
            return
        _rx.append_array(bytes)
    if _rx.size() > MAX_PACKET:
        _lost("PIPE_TOO_LARGE")
        return
    var newline: int = _rx.find(10)
    while newline >= 0:
        var raw: Variant = JSON.parse_string(_rx.slice(0, newline).get_string_from_utf8())
        _rx = _rx.slice(newline + 1)
        if not raw is Dictionary:
            _lost("PIPE_INVALID_PACKET")
            return
        _receive(raw)
        if _pipe.is_empty():
            return
        newline = _rx.find(10)
    # Drain stderr but never print/parse it as an exception or credential.
    if not OS.is_process_running(_pipe.pid):
        _lost("HELPER_EXITED")
        return
    var err: FileAccess = _pipe.stderr
    if err.get_length() > 0:
        err.get_buffer(mini(err.get_length(), 65536))
    if not OS.is_process_running(_pipe.pid):
        _lost("HELPER_EXITED")
        return
    var now: int = Time.get_ticks_msec()
    if not _booted and now > _ready_deadline:
        _lost("HELPER_START_TIMEOUT")
        return
    _expire_pending(now)


func _expire_pending(now: int) -> void:
    # Signals may synchronously cancel/drop other requests or enqueue new ones.
    var expired: Dictionary = {}
    for id: String in _pending.keys():
        var entry: Dictionary = _pending[id]
        if now >= entry.deadline:
            expired[id] = entry
    for id: String in expired:
        if not _pending.has(id) or _pending[id] != expired[id]:
            continue
        var entry: Dictionary = expired[id]
        _pending.erase(id)
        if entry.action == "execute":
            # Even queued-only packets can still leave after this timeout.
            _uncertain(id, entry, "执行请求超时；提交结果未确认，禁止重复写入。")
        _failure(id, entry.action, "REQUEST_TIMEOUT")


func _terminal(record: Dictionary) -> bool:
    return record.get("state", "unknown") in ["succeeded", "failed"]


func _operation_valid(record: Variant) -> bool:
    return record is Dictionary and record.get("id") is String and not record.id.is_empty() and record.get("state") is String and record.get("context") is Dictionary and record.get("target") is Dictionary and record.target.get("resource_id") is String and record.get("action") in ["start", "deallocate"]


func _upsert(records: Array, record: Dictionary) -> void:
    for index: int in range(records.size()):
        if records[index].get("id") == record.id:
            if _terminal(records[index]) and not _terminal(record):
                return
            records[index] = record.duplicate(true)
            return
    records.append(record.duplicate(true))


func _refresh_quarantine() -> void:
    _write_quarantine = false
    for record: Dictionary in _orphan_operations:
        if not _terminal(record):
            _write_quarantine = true


func _publish_journal() -> void:
    JournalChanged.emit(JSON.stringify(_orphan_operations + _last_operations))


func _uncertain(id: String, entry: Dictionary, message: String, publish: bool = true) -> void:
    _uncertain_requests[id] = entry.duplicate(true)
    var target: Dictionary = entry.get("target", {}).duplicate(true)
    if target.is_empty():
        target = {"resource_id": "unknown:execute:" + id, "name": "目标未回包"}
    var record := {"id": "local-uncertain:" + id, "request_id": id, "context": entry.get("context", _context).duplicate(true), "target": target, "action": entry.get("operation_action", "execute"), "state": "unknown", "message": message, "updated": Time.get_datetime_string_from_system(true), "transport": "partially_or_fully_sent" if _sent_bytes > entry.get("wire_start", -1) else "queued_not_yet_sent"}
    _upsert(_orphan_operations, record)
    _refresh_quarantine()
    if publish:
        _publish_journal()


func _track_reply(id: String, raw: Dictionary, late: bool) -> bool:
    if raw.get("ok", false):
        if not _operation_valid(raw.get("data")):
            return false
        var record: Dictionary = raw.data.duplicate(true)
        # Replace only the correlated local timeout, never another operation.
        for index: int in range(_orphan_operations.size() - 1, -1, -1):
            if _orphan_operations[index].get("request_id") == id:
                _orphan_operations.remove_at(index)
        if late:
            for index: int in range(_last_operations.size() - 1, -1, -1):
                if _last_operations[index].id == record.id:
                    if _terminal(_last_operations[index]) and not _terminal(record):
                        record = _last_operations[index].duplicate(true)
                    _last_operations.remove_at(index)
            _upsert(_orphan_operations, record)
        else:
            _upsert(_last_operations, record)
    else:
        # Core emits ok=false only before its guarded POST creates a Job.
        for index: int in range(_orphan_operations.size() - 1, -1, -1):
            if _orphan_operations[index].get("request_id") == id:
                _orphan_operations.remove_at(index)
    _uncertain_requests.erase(id)
    _refresh_quarantine()
    return true


func _receive(raw: Dictionary) -> void:
    if raw.get("kind") == "boot_error":
        var detail := _safe_diagnostic(raw)
        if detail.is_empty():
            _lost("PIPE_INVALID_DIAGNOSTIC")
            return
        _boot_failure = detail
        _config_error = "HELPER_BOOT_FAILED：" + detail
        _preferences.has_identity = false
        _lost("HELPER_BOOT_FAILED")
        Initialized.emit()
    elif raw.get("kind") == "ready":
        _booted = true
        _settings = raw.get("settings", _settings)
        _context = raw.get("context", _context)
        _preferences = raw.get("preferences", _preferences)
        _profile_path = raw.get("profile_path", "")
        _config_error = raw.get("error", _config_error)
        Initialized.emit()
    elif raw.get("kind") == "journal":
        var records: Variant = raw.get("data")
        if not records is Array:
            _lost("PIPE_INVALID_JOURNAL")
            return
        for record: Variant in records:
            if not _operation_valid(record):
                _lost("PIPE_INVALID_JOURNAL")
                return
            var orphan: bool = false
            for saved: Dictionary in _orphan_operations:
                if saved.id == record.id:
                    orphan = true
                    break
            _upsert(_orphan_operations if orphan else _last_operations, record)
        # Empty/partial journals never erase reply-tracked unresolved jobs.
        _refresh_quarantine()
        _publish_journal()
    elif _pending.has(raw.get("id", "")) or _uncertain_requests.has(raw.get("id", "")):
        var late: bool = not _pending.has(raw.id)
        var entry: Dictionary = _uncertain_requests[raw.id] if late else _pending[raw.id]
        if raw.get("action") != entry.action:
            _lost("PIPE_CORRELATION_FAILED")
            return
        if entry.action == "execute" and not _track_reply(raw.id, raw, late):
            _uncertain(raw.id, entry, "执行回包无有效操作记录；结果未知，禁止重复写入。", false)
            _lost("PIPE_INVALID_OPERATION")
            return
        _pending.erase(raw.id)
        if late:
            _publish_journal()
            return
        if raw.has("diagnostic"):
            var detail := _safe_diagnostic(raw)
            if detail.is_empty():
                _failure(raw.id, entry.action, "PIPE_INVALID_DIAGNOSTIC")
                return
            raw.message = detail
            # Do not forward unexpected diagnostic fields even from a helper.
            var safe_fields: Dictionary = {"stage": raw.diagnostic.stage, "hresult": raw.diagnostic.hresult}
            if raw.diagnostic.has("provider_error"):
                safe_fields.provider_error = int(raw.diagnostic.provider_error)
            raw.diagnostic = safe_fields
        _context = raw.get("context", _context)
        _preferences = raw.get("preferences", _preferences)
        if entry.action == "configure" and raw.get("ok", false):
            _settings = raw.data
        if entry.action == "prepare" and raw.get("ok", false) and raw.get("data") is Dictionary:
            _confirmations.clear()
            _confirmations[raw.data.get("nonce", "")] = raw.data.duplicate(true)
        if entry.action == "execute":
            _confirmations.clear()
            _publish_journal()
        Reply.emit(JSON.stringify(raw))


func _lost(code: String) -> void:
    if not _booted and _boot_failure.is_empty():
        _config_error = "阶段: helper_boot; " + code + "。本地 helper 未就绪，未发起认证。"
    var pending := _pending.duplicate(true)
    _pending.clear()
    # Record transport progress before closing resets it. A failed enqueue or
    # wholly unsent packet cleared here cannot have reached the helper.
    for id: String in pending:
        var entry: Dictionary = pending[id]
        if entry.action == "execute" and _sent_bytes > entry.get("wire_start", -1):
            _uncertain(id, entry, "helper 中断；已出站执行请求结果未知，本进程禁止重复写入。", false)
    for record: Dictionary in _last_operations:
        var saved := record.duplicate(true)
        if not _terminal(saved):
            saved.state = "unknown"
            saved.message = "helper 通信已中断；原操作结果不确定，本进程禁止再次写入。请在 Azure 门户核对，不因重启而盲目重发。"
        _upsert(_orphan_operations, saved)
    _last_operations.clear()
    _close_pipe()
    _confirmations.clear()
    _refresh_quarantine()
    _context = {"generation": int(_context.generation) + 1, "account": "", "tenant_id": "", "tenant_name": "", "subscription_id": "", "subscription_name": ""}
    if not _orphan_operations.is_empty():
        _publish_journal()
    for id: String in pending:
        _failure(id, pending[id].action, code)


func _close_pipe() -> void:
    if not _pipe.is_empty():
        _pipe.stdio.close()
        _pipe.stderr.close()
    _pipe.clear()
    _rx.clear()
    _tx.clear()
    _queued_bytes = 0
    _sent_bytes = 0


func _exit_tree() -> void:
    _exiting = true
    # EOF is authoritative shutdown. Helper checks the actual parent HANDLE,
    # cancels its owned worker, joins it, and never kills unrelated processes.
    _close_pipe()
    _pending.clear()