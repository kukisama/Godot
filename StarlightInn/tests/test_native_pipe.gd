extends SceneTree
const Bridge = preload("res://tests/pipe_test_bridge.gd")
var passed: int = 0
var failed: int = 0
var replies: Dictionary = {}
var bridge: Node
var finished: bool = false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	create_timer(30).timeout.connect(func() -> void: if not finished: check(false, "watchdog"); quit(1))
	memory_cases()
	await diagnostic_cases()
	await review_cases()
	bridge = Bridge.new()
	bridge.Reply.connect(func(json: String) -> void:
		var r: Dictionary = JSON.parse_string(json)
		replies[r.id] = r)
	root.add_child(bridge)
	await wait_ready()
	check(bridge._booted, "native bootstrap roundtrip")
	check(bridge._profile_path == "fixture-memory-only", "fixture no personal profile")
	var pid: int = bridge._pipe.pid
	var text := "中文😀引号\"换行\n".repeat(1600)
	for index: int in range(8):
		bridge.Request("echo-%d" % index, "fixture_echo", JSON.stringify({"text": text, "index": index}))
	await wait_reply("echo-7")
	for index: int in range(8):
		var r: Dictionary = replies.get("echo-%d" % index, {})
		check(r.get("ok", false), "correlated reply %d" % index)
		check(r.get("data", {}).get("text", "") == text, "fragmented UTF8 exact %d" % index)
		check(r.get("data", {}).get("index", -1) == index, "multi-message identity %d" % index)
	check(bridge._pending.is_empty(), "large writes drain without stranded pending")
	bridge.Request("login", "login", "{}")
	await wait_reply("login")
	check(replies.login.ok, "shared core login DTO over real pipe")
	check(not JSON.stringify(replies).contains("TEST_TOKEN"), "no credential over pipe")
	bridge.Request("subs", "subscriptions", "{}")
	await wait_reply("subs")
	check(replies.subs.data.items.size() == 1, "real protocol synthetic ARM")
	bridge.request_timeout_ms = 80
	bridge.Request("hang", "fixture_hang", "{}")
	await wait_reply("hang")
	check(replies.hang.code == "REQUEST_TIMEOUT", "timeout unlocks pending")
	bridge.Request("late", "fixture_late", "{}")
	await wait_reply("late")
	check(replies.late.code == "REQUEST_TIMEOUT", "late timed-out request")
	await create_timer(0.5).timeout
	check(replies.late.code == "REQUEST_TIMEOUT", "late native reply discarded")
	bridge.request_timeout_ms = 5000
	bridge.Request("crash", "fixture_crash", "{}")
	bridge.Request("uncertain", "execute", JSON.stringify({"nonce": "queued-behind-crash"}))
	await wait_reply("crash")
	check(replies.crash.code == "HELPER_EXITED", "helper crash releases pending")
	check(bridge._pipe.is_empty() and bridge._pending.is_empty(), "crash state cleared")
	check(not OS.is_process_running(pid), "crashed owned helper exited")
	check(replies.get("uncertain", {}).get("code") == "HELPER_EXITED", "lost execute does not remain busy")
	bridge.Request("blocked", "prepare", "{}")
	check(replies.blocked.code == "HELPER_RESULT_UNCERTAIN", "lost submit quarantines writes across reconnect")
	bridge.Request("restart", "fixture_echo", JSON.stringify({"text": "restart"}))
	await wait_reply("restart")
	check(replies.restart.data.text == "restart", "new private pipe after crash")
	pid = bridge._pipe.pid
	bridge.queue_free()
	await process_frame
	await create_timer(0.5).timeout
	check(not OS.is_process_running(pid), "EOF cleanup no orphan helper")
	finished = true
	print("NATIVE_PIPE_TESTS: %d passed, %d failed; real Godot/private pipe; fixture auth/ARM only" % [passed, failed])
	quit(0 if failed == 0 else 1)

func wait_ready() -> void:
	for index: int in range(500):
		if bridge._booted:
			return
		await create_timer(0.01).timeout

func diagnostic_cases() -> void:
	for mode: String in ["hresult", "provider", "missing", "boot"]:
		replies.clear()
		bridge = Bridge.new()
		bridge.Reply.connect(func(json: String) -> void:
			var r: Dictionary = JSON.parse_string(json)
			replies[r.id] = r)
		root.add_child(bridge)
		await wait_ready()
		var owned_pid: int = bridge._pipe.pid
		if mode == "boot":
			bridge.Request("boot", "fixture_boot_fault", "{}")
			await wait_reply("boot")
			check(replies.boot.code == "HELPER_BOOT_FAILED", "actual worker boot failure arrives before process exit")
			check("winrt_init" in replies.boot.message and "0x80004005" in replies.boot.message, "boot failure phase HRESULT not generic exit")
			check("HELPER_BOOT_FAILED" in JSON.parse_string(bridge.GetSettings()).error, "bootstrap readiness error accessible")
		else:
			bridge.Request("fault", "fixture_auth_fault", JSON.stringify({"mode": mode}))
			await wait_reply("fault")
			bridge.Request("diag-login", "login", "{}")
			await wait_reply("diag-login")
			var reply: Dictionary = replies["diag-login"]
			check(not reply.ok and reply.code == ("WAM_PROVIDER_MISSING" if mode == "missing" else "AUTH_NATIVE_FAILED"), mode + " exact safe error over actual pipe")
			check(reply.diagnostic.stage == ("find_provider" if mode == "missing" else "request_token"), mode + " exact phase")
			check(reply.diagnostic.hresult == ("0x80004005" if mode == "hresult" else "0x00000000"), mode + " exact HRESULT")
			check(not JSON.stringify(reply).contains("CANARY") and not JSON.stringify(reply).contains("username@example.invalid"), mode + " WinRT sensitive text absent in pipe DTO")
			check(bridge._context.account.is_empty() and bridge._pending.is_empty(), mode + " disconnected unlocked after error")
			if mode == "provider":
				check(reply.diagnostic.provider_error == 3400138760 and "0xCAA20008" in reply.message, "numeric provider error intact")
		bridge.queue_free()
		await process_frame
		await create_timer(0.25).timeout
		check(not OS.is_process_running(owned_pid), mode + " diagnostic fixture cleanup")
	replies.clear()

func review_cases() -> void:
	for mode: String in ["reply", "timeout"]:
		replies.clear()
		bridge = Bridge.new()
		bridge.Reply.connect(func(json: String) -> void:
			var r: Dictionary = JSON.parse_string(json)
			replies[r.id] = r)
		root.add_child(bridge)
		await wait_ready()
		for row: Array in [["auth", "login", {}], ["subs", "subscriptions", {}], ["select", "select_subscription", {"id": "11111111-1111-1111-1111-111111111111"}], ["vms", "vms", {}], ["prepare", "prepare", {"resource_id": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture-rg/providers/Microsoft.Compute/virtualMachines/fixture-vm", "action": "start"}], ["arm", "fixture_arm_execute_fault", {"mode": mode}]]:
			bridge.Request(row[0], row[1], JSON.stringify(row[2]))
			await wait_reply(row[0])
			check(replies[row[0]].ok, mode + " actual shared core setup " + row[0])
		bridge.request_timeout_ms = 120 if mode == "timeout" else 5000
		bridge.Request("submit", "execute", JSON.stringify({"nonce": replies.prepare.data.nonce}))
		await wait_reply("submit")
		check(bridge.evidence.get("posts") == 1, mode + " actual synthetic POST before fault")
		check(bridge.evidence.get("data", {}).get("state") == "submitted", mode + " actual operation not success")
		if mode == "reply":
			check(replies.submit.ok and replies.submit.data.state == "submitted", "accepted exact DTO not success")
			check(not bridge._last_operations.is_empty(), "reply tracks operation before journal")
		else:
			check(replies.submit.code == "REQUEST_TIMEOUT", "execute timeout before journal")
			check(bridge._write_quarantine, "execute timeout immediately quarantines")
		bridge.request_timeout_ms = 5000
		bridge.Request("release", "fixture_fault_release", "{}")
		for index: int in range(500):
			if bridge._pipe.is_empty():
				break
			await create_timer(0.01).timeout
		check(bridge._pipe.is_empty(), mode + " owned helper fault exited")
		check(bridge._write_quarantine, mode + " fault quarantines without journal")
		check(not bridge._orphan_operations.is_empty(), mode + " retained original operation")
		bridge.Request("blocked", "prepare", "{}")
		check(replies.get("blocked", {}).get("code") == "HELPER_RESULT_UNCERTAIN", mode + " prepare blocked")
		bridge.Request("restart", "fixture_echo", "{}")
		await wait_reply("restart")
		bridge.Request("blocked-execute", "execute", "{}")
		check(replies.get("blocked-execute", {}).get("code") == "HELPER_RESULT_UNCERTAIN", mode + " reconnect empty jobs cannot resubmit")
		bridge.queue_free()
		await process_frame
		await create_timer(0.25).timeout
	for control: String in ["cancel_login", "cancel_queries", "logout", "auto_login"]:
		replies.clear()
		bridge = Bridge.new()
		bridge.Reply.connect(func(json: String) -> void:
			var r: Dictionary = JSON.parse_string(json)
			replies[r.id] = r)
		root.add_child(bridge)
		await wait_ready()
		bridge.Request("gate", "fixture_gate", "{}")
		await wait_reply("gate")
		bridge.Request("queued-auth", "login", "{}")
		bridge.Request("queued-restore", "restore", "{}")
		if control == "cancel_login":
			bridge.CancelLogin()
		elif control == "cancel_queries":
			bridge.CancelQueries()
		else:
			bridge.Request("cancel-work", control, "{\"enabled\":false}" if control == "auto_login" else "{}")
		bridge.Request("stats", "fixture_stats", "{}")
		bridge.Request("new-login", "login", "{}")
		bridge.Request("release", "fixture_release", "{}")
		await wait_reply("new-login")
		for action: String in ["queued-auth", "queued-restore"]:
			check(replies.get(action, {}).get("code") == "CANCELLED_OR_TIMEOUT", control + " reader cancels " + action + " same ID error")
		check(replies.get("stats", {}).get("data", {}).get("identity_calls") == 0, control + " cancelled queue zero identity calls")
		check(replies.get("new-login", {}).get("ok", false), control + " later manual login valid")
		check(bridge._pending.is_empty(), control + " no quiet erase or stranded busy")
		var owned_pid: int = bridge._pipe.pid
		bridge.queue_free()
		await process_frame
		await create_timer(0.25).timeout
		check(not OS.is_process_running(owned_pid), control + " EOF cleanup")
	replies.clear()

func memory_cases() -> void:
	for code: String in ["AUTH_NATIVE_FAILED", "WAM_PROVIDER_MISSING", "WAM_WINDOW_REQUIRED"]:
		var safe := Bridge.new()
		var observed: Array[Dictionary] = []
		safe.Reply.connect(func(json: String) -> void: observed.append(JSON.parse_string(json)))
		safe._pending["diag"] = {"action": "login"}
		safe._receive({"id": "diag", "action": "login", "ok": false, "code": code, "message": "CANARY_SECRET", "diagnostic": {"stage": "request_token", "hresult": "0x80070005", "unexpected": "CANARY_SECRET"}})
		check(observed.size() == 1 and "0x80070005" in observed[0].message, "safe diagnostic rebuilt for " + code)
		check(not JSON.stringify(observed).contains("CANARY") and observed[0].diagnostic.size() == 2, "unexpected diagnostic fields and raw message stripped")
		safe.free()
	for invalid: Dictionary in [{"stage": "CANARY", "hresult": "0x80070005"}, {"stage": "wam_factory", "hresult": "CANARY"}, {"stage": "wam_factory", "hresult": "0x80070005", "provider_error": "CANARY"}, {"stage": "wam_factory", "hresult": "0x80070005", "provider_error": -1}, {"stage": "wam_factory", "hresult": "0x80070005", "provider_error": 1.5}, {"stage": "wam_factory", "hresult": "0x80070005", "provider_error": 4294967296}]:
		var safe := Bridge.new()
		var observed: Array[Dictionary] = []
		safe.Reply.connect(func(json: String) -> void: observed.append(JSON.parse_string(json)))
		safe._pending["diag"] = {"action": "login"}
		safe._receive({"id": "diag", "action": "login", "ok": false, "code": "AUTH_NATIVE_FAILED", "message": "CANARY", "diagnostic": invalid})
		check(observed.size() == 1 and observed[0].code == "PIPE_INVALID_DIAGNOSTIC" and not JSON.stringify(observed).contains("CANARY"), "malformed diagnostics rejected without echo")
		safe.free()
	var context := {"generation": 9, "account": "fixture@example.invalid", "tenant_id": "fixture-tenant", "tenant_name": "Fixture directory", "subscription_id": "fixture-sub", "subscription_name": "Fixture subscription"}
	var target := {"resource_id": "/fixture/original-vm", "name": "original-vm"}
	var entry := {"action": "execute", "deadline": 0, "wire_start": 0, "context": context, "target": target, "operation_action": "start"}
	for state: String in ["submitted", "pending", "unknown", "deferred", "failed", "succeeded"]:
		var b := Bridge.new()
		b._pending["submit"] = entry.duplicate(true)
		var record := {"id": "op-" + state, "context": context, "target": target, "action": "start", "state": state, "message": "synthetic " + state, "updated": "fixture time"}
		var observed: Array[Dictionary] = []
		b.Reply.connect(func(json: String) -> void: observed.append(JSON.parse_string(json)))
		b._receive({"id": "submit", "action": "execute", "ok": true, "data": record, "context": context})
		var expected_dto: Dictionary = JSON.parse_string(JSON.stringify(record))
		check(observed.size() == 1 and JSON.stringify(observed[0].data) == JSON.stringify(expected_dto), state + " matched reply exact DTO")
		check(b._last_operations.size() == 1 and b._pending.is_empty(), state + " reply stored before pending gone")
		b._receive({"kind": "journal", "data": []})
		check(b._last_operations.size() == 1, state + " empty journal preserves record")
		b._receive({"kind": "journal", "data": [record]})
		var stale_snapshot: Dictionary = record.duplicate(true)
		stale_snapshot.state = "submitted"
		b._receive({"kind": "journal", "data": [stale_snapshot]})
		check(b._last_operations.size() == 1, state + " journal merges by ID")
		b._lost("HELPER_EXITED")
		check(b._write_quarantine == (state not in ["failed", "succeeded"]), state + " only genuine terminal releases writes")
		check(b._orphan_operations[0].context == context and b._orphan_operations[0].target == target, state + " original identity target preserved")
		b._receive({"kind": "journal", "data": []})
		check(b._write_quarantine == (state not in ["failed", "succeeded"]), state + " restarted empty journal cannot erase isolation")
		b.free()
	for code: String in ["INVALID_CONFIRMATION", "EXPIRED_CONFIRMATION", "TARGET_CHANGED", "STALE_CONTEXT"]:
		var b := Bridge.new()
		b._pending["rejected"] = entry.duplicate(true)
		b._receive({"id": "rejected", "action": "execute", "ok": false, "code": code, "data": null})
		b._lost("HELPER_EXITED")
		check(not b._write_quarantine and b._orphan_operations.is_empty(), code + " explicit pre-POST rejection not permanently blocked")
		b.free()
	for state: String in ["submitted", "unknown", "deferred", "failed", "succeeded"]:
		var b := Bridge.new()
		var observed: Array[Dictionary] = []
		b.Reply.connect(func(json: String) -> void: observed.append(JSON.parse_string(json)))
		b._pending["timeout"] = entry.duplicate(true)
		b._expire_pending(1)
		check(b._write_quarantine and observed[0].code == "REQUEST_TIMEOUT", state + " timeout fail closed immediately")
		check(b._orphan_operations[0].context == context and b._orphan_operations[0].target == target and b._orphan_operations[0].state == "unknown", state + " timeout records identity target")
		var record := {"id": "late-op", "context": context, "target": target, "action": "start", "state": state, "message": "synthetic late", "updated": "fixture time"}
		var earlier_record: Dictionary = record.duplicate(true)
		earlier_record.state = "submitted"
		b._receive({"kind": "journal", "data": [earlier_record]})
		b._receive({"id": "timeout", "action": "execute", "ok": true, "data": record})
		check(observed.size() == 1, state + " late response never revives timed-out UI reply")
		check(b._orphan_operations.size() == 1 and b._orphan_operations[0].id == "late-op", state + " correlated late record replaces local orphan")
		check(b._write_quarantine == (state not in ["failed", "succeeded"]), state + " late real terminal only releases quarantine")
		b._lost("HELPER_EXITED")
		check(b._write_quarantine == (state not in ["failed", "succeeded"]) and b._orphan_operations.size() == 1, state + " late terminal replaces older journal through subsequent loss")
		b.free()
	var b := Bridge.new()
	b._pending["bad-reply"] = entry.duplicate(true)
	b._receive({"id": "bad-reply", "action": "execute", "ok": true, "data": null})
	check(b._write_quarantine and not b._orphan_operations.is_empty(), "malformed execute response fails closed")
	b.free()
	b = Bridge.new()
	b._pending["unsent"] = entry.duplicate(true)
	b._lost("PIPE_BACKPRESSURE")
	check(not b._write_quarantine, "wholly unsent closed packet safe no permanent block")
	b.free()
	b = Bridge.new()
	b._pending["partial"] = entry.duplicate(true)
	b._sent_bytes = 1
	b._lost("PIPE_WRITE_FAILED")
	check(b._write_quarantine and b._orphan_operations[0].transport == "partially_or_fully_sent", "partial message write conservatively uncertain")
	b.free()
	b = Bridge.new()
	b._tx.resize(b.MAX_QUEUE)
	check(not b._enqueue({"id": "too-full", "action": "execute"}) and not b._write_quarantine, "failed enqueue cannot submit or permanently quarantine")
	b.free()
	b = Bridge.new()
	var expired := {"action": "fixture_hang", "deadline": 0}
	b._pending["first"] = expired.duplicate()
	b._pending["second"] = expired.duplicate()
	var seen: Array[String] = []
	b.Reply.connect(func(json: String) -> void:
		var r: Dictionary = JSON.parse_string(json)
		seen.append(r.id)
		if r.id == "first":
			b._pending.erase("second")
			b._pending["new"] = {"action": "fixture_hang", "deadline": 500})
	b._expire_pending(1)
	check(seen == ["first"] and b._pending.has("new"), "timeout signal reentrancy preserves new requests without invalid lookup")
	b.free()

func wait_reply(id: String) -> void:
	for index: int in range(1200):
		if replies.has(id):
			return
		await create_timer(0.01).timeout
	check(false, "missing reply " + id)

func check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL PIPE " + label)