extends SceneTree
## Headless real Controls, synthetic bridge only: never auth/cache/ARM.
const FakeBridge = preload("res://tests/fake_azure_bridge.gd")

class NpcBridge:
	extends FakeBridge
	func complete(ok: bool = true, code: String = "") -> void:
		if not pending.is_empty() and ok and pending.action == "resource_groups":
			var request: Dictionary = pending.duplicate(true)
			pending = {}
			Reply.emit(JSON.stringify({"id": request.id, "action": request.action, "ok": true, "message": "FAKE", "mode": "real", "context": context, "data": {"items": [{"id": "/subscriptions/" + SUB + "/resourceGroups/fixture-rg", "name": "fixture-rg", "region": "eastus", "tags": {"fixture": "yes"}}], "has_more": not request.args.get("more", false), "notice": "FAKE resource groups"}}))
		else:
			super.complete(ok, code)

var game: Node
var fake: NpcBridge
var session: Node
var dialogue: Node
var failed: int = 0
var passed: int = 0
var finished: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(20).timeout.connect(func() -> void: if not finished: check(false, "watchdog"); quit(1))
	root.size = Vector2i(1600, 1000)
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	await settle()
	game.set_physics_process(false)
	fake = NpcBridge.new()
	fake.hold = true
	game.add_child(fake)
	session = game.azure_session
	dialogue = game.dialogue
	session.setup(fake)
	dialogue.port.latency_seconds = 0.01
	for id: String in ["mira", "oren", "eve", "finn"]:
		dialogue.open_for(id)
		check(dialogue.choices.size() == 4 and not dialogue.real_mode(), id + " complete offline menu")
	dialogue.send_message("你好，旅店")
	await create_timer(0.05).timeout
	await local_reply("offline_chat")
	check(dialogue.last_response.get("mode") == "demo" and "未调用 AI" in dialogue.text and fake.calls.is_empty(), "offline chat remains local")
	session.request("login", {"browser": false})
	fake.complete()
	check(session.connected() and "已登录" in session.message and "选择订阅" in session.message, "session login success and next step explicit")
	check(not dialogue.allow_input and not game.ui.input_line.visible and "只读" in game.ui.capability_label.text, "open Finn transitions to real mode, input hidden")
	var count: int = fake.calls.size()
	dialogue.send_message("禁止假 AI")
	check(fake.calls.size() == count and dialogue.page == "root", "real free chat disabled")
	dialogue.open_for("oren")
	dialogue.choose("vms")
	check(fake.calls.size() == count and "选择订阅" in dialogue.text and dialogue.last_response.is_empty(), "no subscription blocks query without demo fallback")
	dialogue.open_for("mira")
	dialogue.choose("tenants")
	check(fake.calls.back().action == "tenants", "Mira directory dispatch")
	fake.complete()
	check("Fixture directory" in game.ui.body.text and dialogue.page == "azure_list", "directory appears in original dialogue")
	check("清单放在这里" in dialogue.text and "真实 Azure" in dialogue.text, "Mira's host voice accompanies literal directory data")
	dialogue.choose("back")
	# A genuine viewport event, not Button.pressed.emit or choose().
	await settle()
	var button: Button = game.ui.choice_box.get_child(1)
	var point: Vector2 = button.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.pressed = pressed
		root.push_input(event, true)
	check(fake.calls.back().action == "subscriptions" and dialogue.busy, "viewport click dispatches Mira subscriptions")
	fake.complete()
	check(session.context.subscription_id.is_empty() and "选择订阅" in dialogue.choices[0].label, "subscription not automatically selected")
	dialogue.choose("select_item")
	check(fake.calls.back().action == "select_subscription" and fake.calls.back().args.id == FakeBridge.SUB, "explicit subscription button")
	fake.complete()
	check("已选择订阅" in dialogue.text and session.context.subscription_id == FakeBridge.SUB, "selected subscription response visible")
	dialogue.open_for("oren")
	dialogue.choose("vms")
	check(fake.calls.back().action == "vms", "Oren VM dispatch")
	fake.complete()
	check("fixture-vm" in dialogue.text and session.selected.is_empty(), "real VM not auto-selected")
	check("账簿翻到这里" in dialogue.text and "running" in dialogue.text, "Oren's measured voice leaves the actual VM status intact")
	dialogue.choose("load_more")
	check(fake.calls.back().args.more, "VM API next page explicit")
	fake.complete()
	check("fixture-vm2" in dialogue.text and session.vms.size() == 2, "second VM page presented")
	dialogue.choose("previous")
	dialogue.choose("select_item")
	check(session.selected.resource_id == FakeBridge.VM_ID and "已选择 VM" in dialogue.text, "explicit full ResourceId selected")
	dialogue.open_for("eve")
	for choice: String in ["inspect", "tags"]:
		dialogue.choose(choice)
		check(fake.calls.back().action == "inspect" and fake.calls.back().args.resource_id == FakeBridge.VM_ID, "Eve " + choice + " same true target")
		fake.complete()
		check("inspected" in dialogue.text and FakeBridge.VM_ID in game.ui.body.text, "Eve actual properties and tags in dialogue")
		check("你看这里" in dialogue.text and "不替它编答案" in dialogue.text, "Eve's curious voice distinguishes facts from missing fields")
		dialogue.choose("back")
	dialogue.open_for("finn")
	dialogue.choose("resource_groups")
	check(fake.calls.back().action == "resource_groups", "Finn resource_groups dispatch")
	fake.complete()
	check("fixture-rg" in dialogue.text and "eastus" in dialogue.text and "fixture" in dialogue.text, "resource group fields presented")
	check("唱名不押韵" in dialogue.text and "真实 Azure" in dialogue.text, "Finn's voice wraps actual resource groups without fictional replacements")
	dialogue.choose("load_more")
	check(fake.calls.back().args.more, "resource group API paging")
	fake.complete()
	dialogue.choose("back")
	dialogue.choose("resource_groups")
	var pending: Dictionary = fake.pending.duplicate(true)
	fake.pending = {}
	var long_error: String = "权限不足：" + "LongDiagnosticWithoutSpaces".repeat(30)
	fake.Reply.emit(JSON.stringify({"id": pending.id, "action": pending.action, "ok": false, "code": "FORBIDDEN", "message": long_error, "mode": "real", "context": fake.context, "data": null}))
	check(not dialogue.busy and "FORBIDDEN" in game.ui.body.text and long_error in game.ui.body.text and dialogue.last_response.mode == "real", "real error remains literal, no demo fallback")
	check("不替它圆场" in dialogue.text, "Finn keeps his voice even when the unmodified request fails")
	check(game.ui.body.autowrap_mode == TextServer.AUTOWRAP_ARBITRARY and game.ui.body.visible_characters == -1 and game.ui.body.scroll_active, "long real error wraps and scrolls, no typewriter delay")
	game.azure_panel.open_for("mira")
	await settle()
	check(game.azure_panel.content.get_child(0).autowrap_mode == TextServer.AUTOWRAP_ARBITRARY, "registration error wraps long diagnostics")
	check(not has_write_button(game.ui) and not has_write_button(game.azure_panel), "no real write buttons")
	game.azure_panel.hide_panel()
	dialogue.open_for("oren")
	dialogue.choose("vms")
	var stale: Dictionary = fake.pending.duplicate(true)
	check(not game.ui.choice_box.get_child(0).disabled, "real waiting Return remains enabled")
	dialogue.choose("back")
	var root_text: String = dialogue.text
	fake.complete()
	check(not dialogue.busy and dialogue.text == root_text and dialogue.last_response.is_empty(), "Return cancels and late result cannot replace root")
	dialogue.choose("vms")
	stale = fake.pending.duplicate(true)
	dialogue.open_for("finn")
	dialogue.choose("resource_groups")
	var current_id: String = dialogue.pending_request_id
	late(stale)
	check(dialogue.npc_id == "finn" and dialogue.busy and dialogue.pending_request_id == current_id, "late Oren response cannot enter Finn wait")
	fake.complete()
	check("fixture-rg" in dialogue.text and dialogue.last_response.npc_id == "finn", "current Finn response retained")
	dialogue.choose("back")
	dialogue.choose("resource_groups")
	stale = fake.pending.duplicate(true)
	dialogue.close()
	dialogue.open_for("finn")
	root_text = dialogue.text
	late(stale)
	check(dialogue.text == root_text and not dialogue.busy, "same NPC reopen rejects stale result")
	dialogue.open_for("oren")
	dialogue.choose("vms")
	session.close_view()
	check(not dialogue.busy and "取消" in dialogue.text, "external session cancellation releases dialogue")
	# Sign-out from session while a NPC query is in flight invalidates it.
	dialogue.open_for("finn")
	dialogue.choose("resource_groups")
	stale = fake.pending.duplicate(true)
	session.close_view()
	session.request("logout")
	fake.complete()
	late(stale)
	check(not session.connected() and dialogue.allow_input and dialogue.choices.size() == 4 and not dialogue.busy, "logout restores demo and rejects late real reply")
	count = fake.calls.size()
	dialogue.choose("story")
	await create_timer(0.05).timeout
	await local_reply("logout_story")
	check(dialogue.last_response.get("mode") == "demo" and fake.calls.size() == count, "logout demo gameplay works again")
	check(fake.writes == 0, "entire NPC workflow has zero VM writes")
	finished = true
	game.queue_free()
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	print("NPC_AZURE_TESTS: %d passed, %d failed; synthetic auth/ARM, real viewport click" % [passed, failed])
	quit(0 if failed == 0 else 1)


func local_reply(label: String) -> void:
	if dialogue.busy:
		print("NPC_LOCAL_REPLY_WAIT: %s busy=true after fixed 50ms; awaiting completion signal" % label)
		await dialogue.changed
	await process_frame
	check(not dialogue.busy and dialogue.pending_request_id.is_empty(), label + " completes its correlated local reply")


func late(request: Dictionary) -> void:
	var context: Dictionary = fake.context.duplicate(true)
	context.generation += 100
	fake.Reply.emit(JSON.stringify({"id": request.id, "action": request.action, "ok": true, "message": "STALE", "context": context, "data": {"items": [], "has_more": false}, "mode": "real"}))


func has_write_button(node: Node) -> bool:
	if node is Button and ("确认启动" in node.text or "启动…" in node.text or "解除分配…" in node.text or "确认停止" in node.text):
		return true
	for child: Node in node.get_children():
		if has_write_button(child):
			return true
	return false


func settle() -> void:
	for _index: int in range(4):
		await process_frame


func check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		printerr("FAIL NPC_AZURE: " + label)