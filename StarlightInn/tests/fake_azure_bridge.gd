extends Node
## TEST ONLY. Never imported by a production script or exported.
signal Reply(json: String)
signal JournalChanged(json: String)
const SUB := "33333333-3333-4333-8333-333333333333"
const TENANT := "11111111-1111-4111-8111-111111111111"
const VM_ID := "/subscriptions/" + SUB + "/resourceGroups/fixture-rg/providers/Microsoft.Compute/virtualMachines/fixture-vm"
var context: Dictionary = {"generation": 0, "account": "", "tenant_id": "", "tenant_name": "", "subscription_id": "", "subscription_name": ""}
var settings: Dictionary = {"client_id": "", "initial_tenant": "organizations"}
var preferences: Dictionary = {"auto_login": true, "has_identity": false, "notice": "请首次手动登录。"}
var calls: Array = []
var hold: bool = false
var pending: Dictionary = {}
var cancelled: int = 0
var confirmation_cancels: int = 0
var writes: int = 0
var vm: Dictionary = {"resource_id": VM_ID, "name": "fixture-vm", "resource_group": "fixture-rg", "region": "eastus", "size": "Standard_B1s", "power_state": "running", "last_refresh": "2026-10-09T00:00:00Z", "tags": {"fixture": "yes"}, "provisioning_state": "Succeeded", "os_type": "Linux"}


func GetSettings() -> String:
	return JSON.stringify({"settings": settings, "path": "TEST ONLY / no file written", "error": "", "preferences": preferences, "profile_path": "TEST ONLY / metadata"})


func GetContext() -> String:
	return JSON.stringify(context)


func CancelLogin() -> void:
	cancelled += 1


func CancelConfirmation() -> void:
	confirmation_cancels += 1


func CancelQueries() -> void:
	context.generation += 1


func Request(id: String, action: String, json: String) -> void:
	var args: Dictionary = JSON.parse_string(json)
	calls.append({"id": id, "action": action, "args": args.duplicate(true)})
	pending = {"id": id, "action": action, "args": args}
	if not hold:
		complete.call_deferred()


func complete(ok: bool = true, code: String = "") -> void:
	if pending.is_empty():
		return
	var request: Dictionary = pending.duplicate(true)
	pending = {}
	var data: Variant = {}
	if ok:
		match request.action:
			"configure":
				settings = request.args.duplicate(true)
				context.generation += 1
				data = settings
			"login", "restore":
				context.generation += 1
				preferences.has_identity = true
				context.account = "fixture@example.invalid"
				context.tenant_id = TENANT
				context.tenant_name = "Fixture directory"
				context.subscription_id = ""
				context.subscription_name = ""
				data = context
			"logout":
				context.generation += 1
				preferences.has_identity = false
				context.account = ""
				context.subscription_id = ""
				data = context
			"auto_login":
				preferences.auto_login = request.args.enabled
				data = context
			"tenants":
				data = {"items": [{"id": TENANT, "name": "Fixture directory"}], "has_more": false, "notice": "FAKE directory page"}
			"subscriptions":
				data = {"items": [{"id": SUB, "name": "Fixture subscription"}], "has_more": false, "notice": "FAKE subscription page"}
			"select_subscription":
				context.generation += 1
				context.subscription_id = request.args.id
				context.subscription_name = "Fixture subscription"
				data = context
			"vms":
				var next: Dictionary = vm.duplicate(true)
				if request.args.get("more", false):
					next.resource_id += "2"
					next.name += "2"
				data = {"items": [next], "has_more": not request.args.get("more", false), "notice": "FAKE VM page"}
			"inspect":
				data = vm.duplicate(true)
				data.tags["inspected"] = "yes"
			"prepare":
				data = {"nonce": "fixture-nonce", "context": context.duplicate(true), "target": vm.duplicate(true), "action": request.args.action, "impact": "FAKE 影响说明：磁盘/IP 仍可能计费", "expires": "2099-10-09T00:00:00Z"}
			"execute":
				writes += 1
				data = {"state": "submitted", "message": "FAKE 已受理，尚未完成"}
	Reply.emit(JSON.stringify({"id": request.id, "action": request.action, "ok": ok, "code": code, "message": "FAKE 回执" if ok else "FAKE 授权失败", "data": data, "context": context.duplicate(true), "preferences": preferences.duplicate(true), "mode": "real"}))