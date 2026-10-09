using Starlight.Azure;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

// The production core and actual WAM package compile here. ALL network and
// identity calls below are synthetic fixtures, not live Azure tests.
internal static class Program
{
    internal const string Tenant = "11111111-1111-4111-8111-111111111111";
    internal const string Tenant2 = "22222222-2222-4222-8222-222222222222";
    internal const string Sub = "33333333-3333-4333-8333-333333333333";
    internal const string Sub2 = "44444444-4444-4444-8444-444444444444";
    internal const string Id = "/subscriptions/" + Sub + "/resourceGroups/fixture-rg/providers/Microsoft.Compute/virtualMachines/fixture-vm";
    private static int passed, failed;
    private static async Task Main()
    {
        await Test("empty ClientId fails closed", async () => { using var f = new Fixture(false); await Error("NOT_CONFIGURED", () => f.Core.Login(false, false, "", (IntPtr)1)); Assert(f.Identity.Logins == 0); });
        await Test("invalid / empty GUID configuration rejected", () => { foreach (var id in new[] { "bad", Guid.Empty.ToString() }) Throws("NOT_CONFIGURED", () => new Settings(id).Validate()); Throws("INVALID_TENANT", () => new Settings(Sub, "https://evil").Validate()); return Task.CompletedTask; });
        await Test("queries require login", async () => { using var f = new Fixture(); await Error("NOT_CONNECTED", () => f.Core.ListVms()); });
        await Test("no subscription selected after login", async () => { using var f = new Fixture(); await f.Login(); Assert(f.Core.Current.SubscriptionId == ""); await Error("SELECT_SUBSCRIPTION", () => f.Core.ListVms()); });
        await Test("same tenant subscription switching never authenticates", async () => { using var f = new Fixture(); await f.Ready(); var before = f.Identity.Logins; f.Core.SelectSubscription(Sub2); Assert(f.Identity.Logins == before && f.Core.Current.SubscriptionId == Sub2); });
        await Test("subscription must come from current list", async () => { using var f = new Fixture(); await f.Login(); Throws("INVALID_SUBSCRIPTION", () => f.Core.SelectSubscription(Sub)); });
        await Test("subscription tenant mismatch filtered", async () => { using var f = new Fixture(); await f.Login(); f.Http.MismatchedSub = true; var p = await f.Core.ListSubscriptions(); Assert(p.Items.Count == 1); Throws("INVALID_SUBSCRIPTION", () => f.Core.SelectSubscription(Sub2)); });
        await Test("first login explicit selection path, no cached default", async () => { using var f = new Fixture(); await f.Login(); Assert(f.Identity.Previous == null && !f.Identity.Browser); });
        await Test("duplicate login refused", async () => { using var f = new Fixture(); f.Identity.Block = new(); var first = f.Core.Login(false, false, "", (IntPtr)1); await Error("LOGIN_BUSY", () => f.Core.Login(false, false, "", (IntPtr)1)); f.Core.CancelLogin(); await Cancelled(first); });
        await Test("cancelled login cannot resurrect connection", async () => { using var f = new Fixture(); f.Identity.Block = new(); var task = f.Core.Login(false, false, "", (IntPtr)1); f.Core.CancelLogin(); f.Identity.Block.SetResult(); await Cancelled(task); Assert(f.Core.Current.Account == ""); });
        await Test("logout cancels in-flight login", async () => { using var f = new Fixture(); f.Identity.Block = new(); var task = f.Core.Login(false, false, "", (IntPtr)1); await f.Core.Logout(); await Cancelled(task); Assert(f.Core.Current.Account == "" && f.Identity.Logouts == 1); });
        await Test("queries blocked during identity switch", async () => { using var f = new Fixture(); await f.Ready(); f.Identity.Block = new(); var task = f.Core.Login(false, true, "", (IntPtr)1); await Error("LOGIN_BUSY", () => f.Core.ListDirectories()); f.Core.CancelLogin(); await Cancelled(task); });
        await Test("tenant switch passes same explicitly chosen account", async () => { using var f = new Fixture(); await f.Ready(); await f.Core.ListDirectories(); await f.Core.Login(false, false, Tenant2, (IntPtr)1); Assert(f.Identity.Previous != null && f.Core.Current.TenantId == Tenant2 && f.Core.Current.SubscriptionId == ""); });
        await Test("unknown directory rejected before authentication", async () => { using var f = new Fixture(); await f.Login(); var count = f.Identity.Logins; await Error("INVALID_TENANT", () => f.Core.Login(false, false, Tenant2, (IntPtr)1)); Assert(f.Identity.Logins == count); });
        await Test("explicit browser choice conveyed", async () => { using var f = new Fixture(); await f.Core.Login(true, true, "", (IntPtr)1); Assert(f.Identity.Browser && f.Identity.Select); });
        await Test("WAM implicit browser fallback fails closed", async () => { var ui = new WamIdentity.RefuseBrowserFallback(); await Error("WAM_UNAVAILABLE", () => ui.AcquireAuthorizationCodeAsync(new("https://login.microsoftonline.com/"), new("http://localhost"), default)); });
        await Test("WAM only delegated ARM scope", () => { Assert(WamIdentity.Scopes.SequenceEqual(new[] { "https://management.azure.com/user_impersonation" })); return Task.CompletedTask; });
        await Test("WAM absent HWND fails without starting auth", async () => { await Error("WAM_WINDOW_REQUIRED", () => new WamIdentity().Login(new(Sub), Tenant, null, true, false, IntPtr.Zero, default)); });
        await Test("silent interaction-required never starts login", async () => { using var f = new Fixture(); await f.Ready(); f.Identity.Lease.Error = "INTERACTION_REQUIRED"; var count = f.Identity.Logins; await Error("INTERACTION_REQUIRED", () => f.Core.ListVms()); Assert(count == f.Identity.Logins); });
        await Test("403 is clean RBAC failure", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Status = HttpStatusCode.Forbidden; await Error("FORBIDDEN", () => f.Core.ListVms()); });
        await Test("401 refreshes exactly once", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Unauthorized = 2; var count = f.Identity.Lease.Forces; await Error("INTERACTION_REQUIRED", () => f.Core.ListVms()); Assert(f.Identity.Lease.Forces - count == 1); });
        await Test("pagination exposes hasMore and loads next page", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Paginate = true; var a = await f.Core.ListVms(); var b = await f.Core.ListVms(true); Assert(a.HasMore && !b.HasMore && a.Items[0].Name != b.Items[0].Name && f.Http.Requests.Any(x => x.Contains("page=2"))); });
        await Test("malicious nextLink rejected before any external request", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Next = "https://evil.example/steal"; await Error("UNSAFE_URL", () => f.Core.ListVms()); await Error("INVALID_TARGET", () => f.Core.Inspect(Id)); Assert(f.Http.Requests.All(x => !x.Contains("evil"))); });
        await Test("cross-subscription nextLink rejected", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Next = AzureCore.Arm + "/subscriptions/" + Sub2 + "/providers/Microsoft.Compute/virtualMachines?api-version=2025-04-01"; await Error("UNSAFE_URL", () => f.Core.ListVms()); });
        await Test("unknown power is never stopped", () => { Assert(AzureCore.Power(new()) == "unknown"); Assert(AzureCore.Power(JsonNode.Parse("{\"statuses\":[{\"code\":\"PowerState/stopped\"}]}")!.AsObject()) == "stopped"); return Task.CompletedTask; });
        await Test("VM full-ID query and tags bind target", async () => { using var f = new Fixture(); await f.Ready(true); var vm = await f.Core.Inspect(Id); Assert(vm.ResourceId == Id && vm.Tags["fixture"] == "yes" && vm.PowerState == "running" && vm.Region == "eastus" && vm.Size == "Standard_B1s"); });
        await Test("demo name cannot become real target", async () => { using var f = new Fixture(); await f.Ready(true); await Error("INVALID_TARGET", () => f.Core.Prepare("inn-lantern-01", "deallocate")); Assert(f.Http.Posts == 0); });
        await Test("path / URL / cross subscription injection rejected", () => { foreach (var id in new[] { Id.Replace(Sub, Sub2), "https://evil/" + Id, Id + "/../start", Id + "?x=1", Id.Replace("fixture-rg", ".."), Id.Replace("fixture-vm", "x%2fstart") }) Throws("INVALID_TARGET", () => AzureCore.ParseResource(id, Sub)); return Task.CompletedTask; });
        await Test("ARM external / redirects / traversal URL rejected", () => { foreach (var url in new[] { "http://management.azure.com/x", "https://management.azure.com.evil/x", "https://name@management.azure.com/x", "https://management.azure.com:444/x", AzureCore.Arm + "/a/../b", AzureCore.Arm + "/a%2fb", AzureCore.Arm + "/x#secret" }) Throws("UNSAFE_URL", () => AzureCore.ValidateHost(url)); return Task.CompletedTask; });
        await Test("unsupported action never POSTs", async () => { using var f = new Fixture(); await f.Ready(true); await Error("UNSUPPORTED_ACTION", () => f.Core.Prepare(Id, "delete")); Assert(f.Http.Posts == 0); });
        await Test("confirmation binds identity, target, action, expiry", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "deallocate"); Assert(c.Context == f.Core.Current && c.Target.ResourceId == Id && c.Action == "deallocate" && c.Nonce.Length == 64 && c.Impact.Contains("磁盘") && DateTimeOffset.Parse(c.Expires) > f.Time); Assert(f.Http.Posts == 0); });
        await Test("nonce missing rejected", async () => { using var f = new Fixture(); await f.Ready(true); await Error("INVALID_CONFIRMATION", () => f.Core.Execute("bad")); Assert(f.Http.Posts == 0); });
        await Test("cancel confirmation issues zero POST", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); f.Core.CancelConfirmation(); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); Assert(f.Http.Posts == 0); });
        await Test("expired nonce consumed without POST", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); f.Time += TimeSpan.FromMinutes(3); await Error("EXPIRED_CONFIRMATION", () => f.Core.Execute(c.Nonce)); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); Assert(f.Http.Posts == 0); });
        await Test("context switch invalidates confirmation", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); f.Core.SelectSubscription(Sub2); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); Assert(f.Http.Posts == 0); });
        await Test("state changed between preview and commit blocks POST", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); f.Http.Power = "stopped"; await Error("TARGET_CHANGED", () => f.Core.Execute(c.Nonce)); Assert(f.Http.Posts == 0); });
        await Test("202 accepted is not succeeded before independent verification", async () => { using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new(); var c = await f.Core.Prepare(Id, "deallocate"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "submitted" && f.Http.Posts == 1); f.BlockPoll.SetResult(); });
        await Test("async status succeeded still requires VM final state", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.AsyncStatus = "Succeeded"; var c = await f.Core.Prepare(Id, "deallocate"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "deferred" && f.Http.Posts == 1 && f.Http.Requests.Count(x => x.Contains("instanceView")) >= 3); });
        await Test("deallocated final state independently proves completion", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.CompleteOnPost = true; var c = await f.Core.Prepare(Id, "deallocate"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "succeeded" && op.Message.Contains("deallocated")); });
        await Test("Azure failed status is not success", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.AsyncStatus = "Failed"; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "failed"); });
        await Test("oversized Retry-After defers without shortening", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.Retry = 120; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "deferred" && f.WaitCount == 0); });
        await Test("poll limit leaves unresolved operation blocked", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.AsyncStatus = "InProgress"; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "deferred"); await Error("OPERATION_ACTIVE", () => f.Core.Prepare(Id, "start")); });
        await Test("duplicate nonce single-use", async () => { using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new(); var c = await f.Core.Prepare(Id, "start"); await f.Core.Execute(c.Nonce); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); Assert(f.Http.Posts == 1); f.BlockPoll.SetResult(); });
        await Test("unknown submission never automatically re-POSTs", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.ThrowOnPost = true; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "unknown" && f.Http.Posts == 1); f.Core.Resume(op.Id); Assert(f.Http.Posts == 1); });
        await Test("POST 401 refresh once, 2nd rejection no 3rd POST", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.Post401 = true; var c = await f.Core.Prepare(Id, "start"); var forces = f.Identity.Lease.Forces; var op = await f.Core.Execute(c.Nonce); Assert(op.State == "failed" && f.Http.Posts == 2 && f.Identity.Lease.Forces - forces == 1); });
        await Test("malicious poll header never receives bearer", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.Poll = "https://evil.example/status"; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "deferred" && f.Http.Requests.All(x => !x.Contains("evil"))); f.Core.Resume(op.Id); Assert(f.Http.Posts == 1); });
        await Test("poll host safe but wrong subscription rejected", () => { Throws("UNSAFE_URL", () => AzureCore.ValidatePoll(AzureCore.Arm + "/subscriptions/" + Sub2 + "/providers/Microsoft.Compute/locations/eastus/operations/fixture", Sub)); return Task.CompletedTask; });
        await Test("operation survives logout with original context", async () => { using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new(); var c = await f.Core.Prepare(Id, "deallocate"); var op = await f.Core.Execute(c.Nonce); await f.Core.Logout(); Assert(f.Core.Operations[0].Context == c.Context && f.Core.Operations[0].State == "submitted" && f.Core.Current.Account == ""); f.Http.Power = "deallocated"; f.BlockPoll.SetResult(); });
        await Test("operation survives subscription switch, never retargeted", async () => { using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new(); var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); f.Core.SelectSubscription(Sub2); Assert(f.Core.Operations[0].Context.SubscriptionId == Sub && f.Core.Operations[0].Target.ResourceId == Id && f.Core.Current.SubscriptionId == Sub2); f.BlockPoll.SetResult(); });
        await Test("DTO serialization contains no token / auth result / headers", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); var json = JsonSerializer.Serialize(c, AzureCore.Json); Assert(!json.Contains("access_token") && !json.Contains("Bearer") && !json.Contains("synthetic-token") && json.Contains("resource_id") && json.Contains("generation")); });
        await Test("resource response ID mismatch rejected", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.WrongTarget = true; await Error("INVALID_RESPONSE", () => f.Core.Inspect(Id)); });
        await Test("close cancels queries and consumes every confirmation", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); var old = f.Core.Current; f.Core.CancelQueries(); Assert(f.Core.Current.Generation > old.Generation && f.Core.Current.SubscriptionId == Sub); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); await Error("INVALID_TARGET", () => f.Core.Inspect(Id)); Assert(f.Http.Posts == 0); });
        await Test("late VM query after close cannot repopulate writable target cache", async () => { using var f = new Fixture(); await f.Ready(); f.Http.BlockList = new(); var task = f.Core.ListVms(); var generation = f.Core.Current.Generation; f.Core.CancelQueries(); f.Http.BlockList.SetResult(); await CancelledOrStale(task); Assert(f.Core.Current.Generation > generation); f.Http.BlockList = null; await Error("INVALID_TARGET", () => f.Core.Prepare(Id, "start")); Assert(f.Http.Posts == 0); });
        await Test("malformed list items fail without silent data loss", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Malformed = true; await Error("INVALID_RESPONSE", () => f.Core.ListVms()); await Error("INVALID_TARGET", () => f.Core.Inspect(Id)); });
        await Test("chunked oversized response rejected before JSON parse", async () => { using var f = new Fixture(); await f.Ready(); f.Http.Oversized = true; await Error("RESPONSE_TOO_LARGE", () => f.Core.ListVms()); });
        await Test("query cancellation does not stop original-context accepted job", async () => { using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new(); var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); f.Core.CancelQueries(); Assert(f.Core.Operations[0].State == "submitted" && f.Core.Operations[0].Context == c.Context); f.BlockPoll.SetResult(); Assert(f.Http.Posts == 1); });
        await Test("failed configuration persistence leaves memory and generation unchanged", () => { using var f = new Fixture(); var config = f.Core.Configuration; var context = f.Core.Current; try { f.Core.Configure(new(Sub2, Tenant), _ => throw new IOException("synthetic disk failure")); throw new InvalidOperationException("save unexpectedly succeeded"); } catch (IOException) { Assert(f.Core.Configuration == config && f.Core.Current == context); } return Task.CompletedTask; });
        await Test("POST 500 and 408 remain uncertain and block repeat writes", async () => { foreach (var status in new[] { HttpStatusCode.InternalServerError, HttpStatusCode.RequestTimeout }) { using var f = new Fixture(); await f.Ready(true); f.Http.PostStatus = status; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "unknown" && f.Http.Posts == 1); await Error("OPERATION_ACTIVE", () => f.Core.Prepare(Id, "start")); } });
        await Test("late prepare after close cannot create confirmation", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.BlockVm = new(); var task = f.Core.Prepare(Id, "start"); f.Core.CancelQueries(); f.Http.BlockVm.SetResult(); await CancelledOrStale(task); await Error("INVALID_CONFIRMATION", () => f.Core.Execute("late-fixture-nonce")); Assert(f.Http.Posts == 0); });
        await Test("unknown initially running resume remains unknown, no extra POST", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.ThrowOnPost = true; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); f.Core.Resume(op.Id); var observed = f.Core.Operations.Single(); Assert(observed.State == "unknown" && observed.Message.Contains("原提交结果仍未知") && !observed.Message.Contains("已受理") && f.Http.Posts == 1); await Error("OPERATION_ACTIVE", () => f.Core.Prepare(Id, "start")); });
        await Test("unknown wrong state then matching still unknown", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.Power = "stopped"; f.Http.ThrowOnPost = true; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); f.Core.Resume(op.Id); Assert(f.Core.Operations.Single().State == "unknown"); f.Http.Power = "running"; f.Core.Resume(op.Id); Assert(f.Core.Operations.Single().State == "unknown" && f.Http.Posts == 1); });
        await Test("unknown poll failure never claims Azure acceptance", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.ThrowOnPost = true; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); f.Http.Status = HttpStatusCode.Forbidden; f.Core.Resume(op.Id); Assert(f.Core.Operations.Single().State == "unknown" && !f.Core.Operations.Single().Message.Contains("已受理")); });
        await Test("accepted 200 still completes after final state read", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.PostStatus = HttpStatusCode.OK; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "succeeded" && f.Http.Posts == 1); });
        await Test("accepted unsafe poll remains eligible for verified completion", async () => { using var f = new Fixture(); await f.Ready(true); f.Http.Poll = "https://evil.example/status"; var c = await f.Core.Prepare(Id, "start"); var op = await f.Core.Execute(c.Nonce); Assert(op.State == "deferred"); f.Core.Resume(op.Id); Assert(f.Core.Operations.Single().State == "succeeded" && f.Http.Posts == 1); });
        await Test("expiry during fresh VM read consumes nonce with zero POST", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); f.Http.OnVmRead = () => f.Time += TimeSpan.FromMinutes(3); await Error("EXPIRED_CONFIRMATION", () => f.Core.Execute(c.Nonce)); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); Assert(f.Http.Posts == 0 && f.Core.Operations.Length == 0); });
        await Test("expiry during final token fetch consumes nonce with zero POST", async () => { using var f = new Fixture(); await f.Ready(true); var c = await f.Core.Prepare(Id, "start"); var calls = 0; f.Identity.Lease.OnToken = () => { if (++calls == 3) f.Time += TimeSpan.FromMinutes(3); }; await Error("EXPIRED_CONFIRMATION", () => f.Core.Execute(c.Nonce)); await Error("INVALID_CONFIRMATION", () => f.Core.Execute(c.Nonce)); Assert(calls == 3 && f.Http.Posts == 0); });
        await Test("restore empty configuration never calls identity or HTTP", async () => { using var f = new Fixture(false, Remembered()); var note = await f.Core.TryRestore(); Assert(note.Contains("未配置") && f.Identity.Restores == 0 && f.Http.Requests.Count == 0); });
        await Test("restore no remembered account never picks default", async () => { using var f = new Fixture(); await f.Core.TryRestore(); Assert(f.Identity.Restores == 0 && f.Identity.Logins == 0 && f.Http.Requests.Count == 0); });
        await Test("restore disabled preference blocks next process", async () => { using var f = new Fixture(profiles: Remembered() with { AutoLogin = false }); await f.Core.TryRestore(); Assert(f.Identity.Restores == 0 && f.Core.Current.Account == ""); });
        await Test("restore exact home ID and verified subscription", async () => { using var f = new Fixture(profiles: Remembered()); await f.Core.TryRestore(); Assert(f.Identity.RestoredProfile!.HomeAccountId == Home && f.Core.Current.SubscriptionId == Sub && f.Identity.Logins == 0 && f.Http.Posts == 0); });
        await Test("same username different home ID rejected", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreHome = Tenant2 + "." + Tenant; await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Core.Current.Account == "" && f.Core.Configuration.ClientId == Sub && f.Http.Requests.Count == 0); });
        await Test("silent wrong tenant rejected before subscription lookup", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreTenant = Tenant2; await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Http.Requests.Count == 0 && f.Core.Current.Account == ""); });
        await Test("silent wrong client rejected", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreClient = Sub2; await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Core.Current.Account == ""); });
        await Test("changed ClientId cannot use old profile", async () => { using var f = new Fixture(profiles: Remembered()); f.Core.Configure(new(Sub2, Tenant)); await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Identity.Restores == 0 && f.Core.Configuration.ClientId == Sub2); });
        await Test("changed initial tenant rejects old profile", async () => { using var f = new Fixture(profiles: Remembered()); f.Core.Configure(new(Sub, Tenant2)); await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Identity.Restores == 0); });
        await Test("saved actual directory must be a valid GUID before authentication", async () => { using var f = new Fixture(profiles: Remembered() with { TenantId = "organizations" }); await f.Core.TryRestore(); Assert(f.Identity.Restores == 0 && f.Core.Current.Account == "" && f.Http.Requests.Count == 0); });
        await Test("guest tenant outside current list restores with exact token", async () => { using var f = new Fixture(profiles: Remembered() with { InitialTenant = "organizations", TenantId = Tenant2, SubscriptionId = "", SubscriptionName = "" }); f.Core.Configure(new(Sub, "organizations")); await f.Core.TryRestore(); Assert(f.Core.Current.TenantId == Tenant2 && f.Core.Current.SubscriptionId == ""); });
        await Test("saved subscription on second page verified not trusted", async () => { using var f = new Fixture(profiles: Remembered() with { SubscriptionId = Sub2, SubscriptionName = "untrusted name" }); f.Http.SubPages = true; await f.Core.TryRestore(); Assert(f.Core.Current.SubscriptionId == Sub2 && f.Core.Current.SubscriptionName == "Fixture subscription 2" && f.Http.Requests.Count == 2 && f.Http.Posts == 0); });
        await Test("missing saved subscription preserves account not first subscription", async () => { using var f = new Fixture(profiles: Remembered() with { SubscriptionId = Tenant2 }); var note = await f.Core.TryRestore(); Assert(f.Core.Current.Account.Length > 0 && f.Core.Current.SubscriptionId == "" && note.Contains("重新") && f.Http.Posts == 0); });
        await Test("subscription RBAC failure preserves restored account", async () => { using var f = new Fixture(profiles: Remembered()); f.Http.Status = HttpStatusCode.Forbidden; var note = await f.Core.TryRestore(); Assert(f.Core.Current.Account.Length > 0 && f.Core.Current.SubscriptionId == "" && note.Contains("重新")); });
        await Test("subscription wrong tenant never restores saved ID", async () => { using var f = new Fixture(profiles: Remembered() with { SubscriptionId = Sub2 }); f.Http.MismatchedSub = true; await f.Core.TryRestore(); Assert(f.Core.Current.Account.Length > 0 && f.Core.Current.SubscriptionId == ""); });
        await Test("restore pagination bounded and no external URL request", async () => { using var f = new Fixture(profiles: Remembered() with { SubscriptionId = Tenant2 }); f.Http.SubNext = "https://evil.example/subscriptions"; await f.Core.TryRestore(); Assert(f.Core.Current.Account.Length > 0 && f.Core.Current.SubscriptionId == "" && f.Http.Requests.Count == 1); });
        await Test("restore page cap leaves subscription unselected", async () => { using var f = new Fixture(profiles: Remembered() with { SubscriptionId = Sub2 }); f.Http.SubPages = true; f.Core.MaxRestorePages = 1; await f.Core.TryRestore(); Assert(f.Core.Current.Account.Length > 0 && f.Core.Current.SubscriptionId == "" && f.Http.Requests.Count == 1); });
        await Test("interaction required restore never opens manual login", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreError = "INTERACTION_REQUIRED"; await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Identity.Logins == 0 && f.Core.Current.Account == "" && f.Profiles.Value.HasIdentity); });
        await Test("logout race cannot resurrect remembered identity", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreBlock = new(); var task = f.Core.TryRestore(); await f.Core.Logout(); f.Identity.RestoreBlock.SetResult(); await Cancelled(task); Assert(f.Core.Current.Account == "" && !f.Profiles.Value.HasIdentity && f.Profiles.Value.AutoLogin && f.Identity.Logouts == 1 && f.Core.Configuration.ClientId == Sub); });
        await Test("manual login cancels restore and persists explicit account", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreBlock = new(); var task = f.Core.TryRestore(); await f.Login(); f.Identity.RestoreBlock.SetResult(); await Cancelled(task); Assert(f.Identity.Select && f.Core.Current.Account.Length > 0 && f.Profiles.Value.HomeAccountId == Home && f.Identity.Logins == 1); });
        await Test("configuration cancels restore and stale completion cannot connect", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreBlock = new(); var task = f.Core.TryRestore(); f.Core.Configure(new(Sub2, Tenant2)); f.Identity.RestoreBlock.SetResult(); await Cancelled(task); Assert(f.Core.Current.Account == "" && f.Core.Configuration.ClientId == Sub2); });
        await Test("checkbox off cancels in-flight restore", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreBlock = new(); var task = f.Core.TryRestore(); f.Core.SetAutoLogin(false); f.Identity.RestoreBlock.SetResult(); await Cancelled(task); Assert(!f.Profiles.Value.AutoLogin && f.Core.Current.Account == ""); });
        await Test("checkbox off does not logout connected account", async () => { using var f = new Fixture(); await f.Ready(); f.Core.SetAutoLogin(false); Assert(f.Core.Current.Account.Length > 0 && f.Identity.Logouts == 0 && !f.Profiles.Value.AutoLogin); });
        await Test("restore timeout fails closed without interactive auth", async () => { using var f = new Fixture(profiles: Remembered()); f.Core.RestoreTimeout = TimeSpan.FromMilliseconds(25); f.Identity.RestoreBlock = new(); await Cancelled(f.Core.TryRestore()); f.Identity.RestoreBlock.SetResult(); Assert(f.Identity.Logins == 0 && f.Core.Current.Account == ""); });
        await Test("dispose cancels restore without late connection", async () => { using var f = new Fixture(profiles: Remembered()); f.Identity.RestoreBlock = new(); var task = f.Core.TryRestore(); f.Core.Dispose(); f.Identity.RestoreBlock.SetResult(); await Cancelled(task); Assert(f.Core.Current.Account == ""); });
        await Test("manual directory and subscription save current metadata only", async () => { using var f = new Fixture(); await f.Ready(); Assert(f.Profiles.Value.SubscriptionId == Sub); await f.Core.ListDirectories(); await f.Core.Login(false, false, Tenant2, (IntPtr)1); Assert(f.Profiles.Value.TenantId == Tenant2 && f.Profiles.Value.HomeAccountId == Home && f.Profiles.Value.SubscriptionId == ""); });
        await Test("logout preserves false preference and config across new core", async () => { using var f = new Fixture(); await f.Ready(); f.Core.SetAutoLogin(false); await f.Core.Logout(); using var next = new Fixture(profiles: f.Profiles.Value); await next.Core.TryRestore(); Assert(!next.Profiles.Value.HasIdentity && !next.Profiles.Value.AutoLogin && next.Core.Configuration.ClientId == Sub && next.Identity.Restores == 0); });
        await Test("invalid profile version, IDs and username-as-identity rejected", () => { foreach (var value in new[] { Remembered() with { Version = 2 }, Remembered() with { HomeAccountId = "fixture@example.invalid" }, Remembered() with { TenantId = "../common" }, Remembered() with { SubscriptionId = Guid.Empty.ToString() }, Remembered() with { Username = "bad\nname" } }) Throws("INVALID_PROFILE", value.Validate); return Task.CompletedTask; });
        await Test("profile serialization strictly metadata no credentials", () => { var json = JsonSerializer.Serialize(Remembered(), AzureCore.Json); var raw = JsonNode.Parse(json)!.AsObject(); Assert(raw.Count == 9 && raw.ContainsKey("home_account_id") && !json.Contains("synthetic-token") && !json.Contains("access_token") && !raw.ContainsKey("has_identity")); return Task.CompletedTask; });
        await Test("DPAPI synthetic metadata roundtrip, tamper and extra field rejected", () => { var path = Path.Combine(AppContext.BaseDirectory, "StarlightInn-profile-fixture-" + Guid.NewGuid() + ".bin"); try { var store = new UserProfileStore(path); store.Save(Remembered()); Assert(store.Load() == Remembered()); var disk = File.ReadAllBytes(path); Assert(!Encoding.UTF8.GetString(disk).Contains(Home)); disk[^1] ^= 1; File.WriteAllBytes(path, disk); Throws("INVALID_PROFILE", () => store.Load()); try { JsonSerializer.Deserialize<SessionProfile>("{\"version\":1,\"token\":\"fake\"}", AzureCore.Json); throw new InvalidOperationException("extra field accepted"); } catch (JsonException) { } } finally { if (File.Exists(path)) File.Delete(path); } return Task.CompletedTask; });
        await Test("explicit account switch overwrites saved home ID not username", async () => { using var f = new Fixture(); await f.Ready(); f.Identity.LoginHome = Tenant2 + "." + Tenant; await f.Core.Login(false, true, "", (IntPtr)1); Assert(f.Profiles.Value.HomeAccountId == f.Identity.LoginHome && f.Profiles.Value.Username == "fixture@example.invalid" && f.Profiles.Value.SubscriptionId == ""); });
        await Test("logout during subscription restoration rejects late response", async () => { using var f = new Fixture(profiles: Remembered()); f.Http.BlockSubscriptions = new(); var task = f.Core.TryRestore(); var logout = f.Core.Logout(); f.Http.BlockSubscriptions.SetResult(); await logout; await Cancelled(task); Assert(!f.Profiles.Value.HasIdentity && f.Core.Current.Account == "" && f.Core.Current.SubscriptionId == "" && f.Http.Posts == 0); });
        await Test("subscription timeout retains verified account without subscription", async () => { using var f = new Fixture(profiles: Remembered()); f.Core.RestoreTimeout = TimeSpan.FromMilliseconds(25); f.Http.BlockSubscriptions = new(); var note = await f.Core.TryRestore(); f.Http.BlockSubscriptions.SetResult(); Assert(f.Core.Current.Account.Length > 0 && f.Core.Current.SubscriptionId == "" && note.Contains("超时") && f.Identity.Logins == 0 && f.Http.Posts == 0); });
        await Test("background job cannot rewrite current remembered subscription", async () => { using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new(); var c = await f.Core.Prepare(Id, "start"); await f.Core.Execute(c.Nonce); f.Core.SelectSubscription(Sub2); var observed = new TaskCompletionSource(); f.Http.OnViewRead = () => observed.TrySetResult(); f.BlockPoll.SetResult(); await observed.Task.WaitAsync(TimeSpan.FromSeconds(1)); Assert(f.Profiles.Value.SubscriptionId == Sub2 && f.Core.Operations.Single().Context.SubscriptionId == Sub); });
        await Test("GUID initial A guest actual B restart without subscription pins B", () => GuestRestart(false));
        await Test("GUID initial A guest actual B restart with subscription verifies B", () => GuestRestart(true));
        await Test("guest profile initial A changed to C rejects with zero auth", async () => { using var f = new Fixture(profiles: GuestProfile()); f.Core.Configure(new(Sub, Sub2)); await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Identity.Restores == 0 && f.Identity.Logins == 0 && f.Http.Requests.Count == 0 && f.Core.Current.Account == ""); });
        await Test("guest saved B silent returned A rejected never falls back", async () => { using var f = new Fixture(profiles: GuestProfile()); f.Identity.RestoreTenant = Tenant; await Error("RELOGIN_REQUIRED", () => f.Core.TryRestore()); Assert(f.Identity.Restores == 1 && f.Identity.RestoredProfile!.TenantId == Tenant2 && f.Identity.Logins == 0 && f.Http.Requests.Count == 0 && f.Core.Current.Account == ""); });
        await Test("logout profile save failure cache success truthful disconnected", () => LogoutFailure(true, false));
        await Test("logout profile save success cache failure truthful disconnected", () => LogoutFailure(false, true));
        await Test("logout dual failure reports both truthful disconnected", () => LogoutFailure(true, true));
        await Test("logout unknown cache exception sanitized and gate released", async () => { using var f = new Fixture(); await f.Ready(); f.Identity.CacheFailure = new InvalidOperationException("synthetic-raw-msal-detail"); var e = await LogoutError(f.Core, "LOGOUT_CACHE_FAILED"); Assert(!e.Message.Contains("synthetic-raw") && f.Core.ConnectionNotice == e.Message && f.Core.Current.Account == "" && !f.Profiles.Value.HasIdentity); await f.Login(); Assert(f.Core.Current.Account.Length > 0); });
        await Test("logout clean bridge cache code preserved without raw message", async () => { using var f = new Fixture(); await f.Ready(); f.Identity.CacheFailure = new BridgeError("CACHE_MISSING", "synthetic-raw-detail"); var e = await LogoutError(f.Core, "CACHE_MISSING"); Assert(!e.Message.Contains("synthetic-raw") && e.Message == f.Core.ConnectionNotice && !f.Profiles.Value.HasIdentity); });
        await Test("logout dual failure next core may restore old disk profile", async () => { using var f = new Fixture(); await f.Ready(); var old = f.Profiles.Value; f.Profiles.SaveFailure = new IOException("synthetic disk failure"); f.Identity.CacheFailure = new BridgeError("LOGOUT_CACHE_FAILED", "synthetic cache failure"); var e = await LogoutError(f.Core, "LOGOUT_INCOMPLETE"); using var next = new Fixture(profiles: f.Profiles.Value); await next.Core.TryRestore(); Assert(f.Profiles.Value == old && e.Message.Contains("下次启动可能尝试恢复") && next.Identity.Restores == 1 && next.Core.Current.TenantId == old.TenantId && next.Identity.Logins == 0); });
        await Test("logout cache failure cleared profile next core never restores", async () => { using var f = new Fixture(); await f.Ready(); f.Identity.CacheFailure = new BridgeError("LOGOUT_CACHE_FAILED", "synthetic cache failure"); await LogoutError(f.Core, "LOGOUT_CACHE_FAILED"); using var next = new Fixture(profiles: f.Profiles.Value); await next.Core.TryRestore(); Assert(!f.Profiles.Value.HasIdentity && next.Identity.Restores == 0 && next.Identity.Logins == 0 && next.Http.Requests.Count == 0 && next.Core.Current.Account == ""); });
        await Test("logout profile save failure still permits explicit manual login", async () => { using var f = new Fixture(); await f.Ready(); f.Profiles.SaveFailure = new IOException("synthetic disk failure"); await LogoutError(f.Core, "PROFILE_IO"); f.Profiles.SaveFailure = null; await f.Login(); Assert(f.Identity.Logins == 2 && f.Core.Current.Account.Length > 0 && f.Profiles.Value.HasIdentity); });
        Console.WriteLine($"BRIDGE_TESTS: {passed} passed, {failed} failed; FAKE identity/HTTP only; no live cloud write");
        Environment.ExitCode = failed == 0 ? 0 : 1;
    }
    private static async Task Test(string name, Func<Task> test)
    { try { await test(); passed++; Console.WriteLine("PASS " + name); } catch (Exception e) { failed++; Console.WriteLine("FAIL " + name + " [" + e.GetType().Name + "] " + (e is BridgeError b ? b.Code : e is InvalidOperationException ? e.Message : "fixture failure")); } }
    private static void Assert(bool ok) { if (!ok) throw new InvalidOperationException("assertion failed"); }
    private const string Home = Tenant + "." + Tenant;
    private static SessionProfile Remembered() => new(1, true, Sub, Tenant, Home, "fixture@example.invalid", Tenant, Sub, "Fixture subscription");
    private static SessionProfile GuestProfile() => Remembered() with { TenantId = Tenant2, SubscriptionId = "", SubscriptionName = "" };
    private static async Task GuestRestart(bool withSubscription)
    {
        using var f = new Fixture(); await f.Login(); await f.Core.ListDirectories();
        await f.Core.Login(false, false, Tenant2, (IntPtr)1);
        if (withSubscription) { f.Http.SubTenant = Tenant2; await f.Core.ListSubscriptions(); f.Core.SelectSubscription(Sub); }
        Assert(f.Profiles.Value.InitialTenant == Tenant && f.Profiles.Value.TenantId == Tenant2 && f.Profiles.Value.HomeAccountId == Home);
        using var next = new Fixture(profiles: f.Profiles.Value); next.Http.SubTenant = Tenant2;
        await next.Core.TryRestore();
        Assert(next.Identity.Restores == 1 && next.Identity.Logins == 0 && next.Identity.RestoredProfile!.TenantId == Tenant2 &&
            next.Core.Current.TenantId == Tenant2 && next.Core.Current.SubscriptionId == (withSubscription ? Sub : "") &&
            next.Http.Requests.Count == (withSubscription ? 1 : 0) && next.Http.Posts == 0);
    }
    private static async Task<BridgeError> LogoutError(AzureCore core, string code)
    {
        try { await core.Logout(); }
        catch (BridgeError e) { Assert(e.Code == code); return e; }
        throw new InvalidOperationException("expected " + code);
    }
    private static async Task LogoutFailure(bool saveFails, bool cacheFails)
    {
        using var f = new Fixture(); await f.Ready(true); f.BlockPoll = new();
        var c = await f.Core.Prepare(Id, "start"); await f.Core.Execute(c.Nonce);
        var oldProfile = f.Profiles.Value; var oldOperation = f.Core.Operations.Single();
        if (saveFails) f.Profiles.SaveFailure = new IOException("synthetic disk failure");
        if (cacheFails) f.Identity.CacheFailure = new BridgeError("LOGOUT_CACHE_FAILED", "synthetic cache failure");
        var e = await LogoutError(f.Core, saveFails ? (cacheFails ? "LOGOUT_INCOMPLETE" : "PROFILE_IO") : "LOGOUT_CACHE_FAILED");
        Assert(f.Identity.Logouts == 1 && f.Core.Current.Account == "" && f.Core.Current.TenantId == "" && f.Core.Current.SubscriptionId == "" &&
            f.Core.ConnectionNotice == e.Message && e.Message.Contains("本应用已断开") && e.Message.Contains("未删除 Windows 账户") &&
            !e.Message.Contains("已清除") && f.Core.Operations.Single() == oldOperation && f.Http.Posts == 1);
        var prefs = JsonSerializer.SerializeToNode(f.Core.Preferences, AzureCore.Json)!.AsObject();
        Assert(!prefs["has_identity"]!.GetValue<bool>() && !prefs["restoring"]!.GetValue<bool>());
        Assert(saveFails ? f.Profiles.Value == oldProfile && e.Message.Contains("磁盘身份档案清除失败") && e.Message.Contains("下次启动可能尝试恢复") && !e.Message.Contains("档案已清空") : !f.Profiles.Value.HasIdentity && e.Message.Contains("磁盘身份档案已清空"));
        Assert(cacheFails ? e.Message.Contains("本应用缓存清理失败") : e.Message.Contains("本应用认证缓存已清理"));
        await Error("NOT_CONNECTED", () => f.Core.ListDirectories());
        await f.Core.TryRestore(); // Gate released; in-process identity remains cleared even if disk save failed.
        Assert(f.Identity.Restores == 0 && f.Identity.Logins == 1 && f.Core.Current.Account == "");
    }
    private static void Throws(string code, Action work) { try { work(); } catch (BridgeError e) { Assert(e.Code == code); return; } throw new InvalidOperationException("expected " + code); }
    private static async Task Error(string code, Func<Task> work) { try { await work(); } catch (BridgeError e) { Assert(e.Code == code); return; } throw new InvalidOperationException("expected " + code); }
    private static async Task Cancelled(Task task) { try { await task; } catch (OperationCanceledException) { return; } throw new InvalidOperationException("expected cancellation"); }
    private static async Task CancelledOrStale(Task task) { try { await task; } catch (OperationCanceledException) { return; } catch (BridgeError e) when (e.Code == "STALE_CONTEXT") { return; } throw new InvalidOperationException("expected cancellation or stale response rejection"); }
    private sealed class Fixture : IDisposable
    {
        public readonly FakeIdentity Identity = new(); public readonly FakeArm Http = new(); public readonly AzureCore Core;
        public readonly FakeProfileStore Profiles = new();
        public DateTimeOffset Time = new(2026, 10, 9, 0, 0, 0, TimeSpan.Zero); public TaskCompletionSource? BlockPoll; public int WaitCount;
        public Fixture(bool configured = true, SessionProfile? profiles = null)
        {
            Profiles.Value = profiles ?? new();
            Core = new(Identity, Http, () => Time, (wait, ct) => { WaitCount++; Time += wait; return BlockPoll?.Task.WaitAsync(ct) ?? Task.CompletedTask; }, Profiles) { MaxPolls = 2 };
            if (configured) Core.Configure(new(Sub, Tenant));
        }
        public Task Login() => Core.Login(false, false, "", (IntPtr)1);
        public async Task Ready(bool list = false) { await Login(); await Core.ListSubscriptions(); Core.SelectSubscription(Sub); if (list) await Core.ListVms(); }
        public void Dispose() { Core.Dispose(); }
    }
    private sealed class FakeProfileStore : IProfileStore
    {
        public SessionProfile Value = new();
        public Exception? SaveFailure;
        public SessionProfile Load() => Value;
        public void Save(SessionProfile value) { if (SaveFailure != null) throw SaveFailure; value.Validate(); Value = value; }
    }
    private sealed class FakeIdentity : IIdentity
    {
        public int Logins, Logouts; public bool Browser, Select; public IdentityLease? Previous; public TaskCompletionSource? Block;
        public FakeLease Lease = new(Tenant);
        public int Restores; public SessionProfile? RestoredProfile;
        public TaskCompletionSource? RestoreBlock;
        public Exception? CacheFailure;
        public string RestoreError = "", RestoreHome = "", RestoreTenant = "", RestoreClient = "", LoginHome = Home;
        public async Task<IdentityLease> Login(Settings settings, string tenant, IdentityLease? previous, bool selectAccount, bool browser, IntPtr hwnd, CancellationToken ct)
        { Logins++; Browser = browser; Select = selectAccount; Previous = previous; if (Block != null) await Block.Task.WaitAsync(ct); Lease = new(tenant, LoginHome, settings.ClientId); return Lease; }
        public async Task<IdentityLease> TryRestore(Settings settings, SessionProfile profile, CancellationToken ct)
        {
            Restores++; RestoredProfile = profile;
            if (RestoreBlock != null) await RestoreBlock.Task; // Ignores cancellation on purpose: core must reject late completion.
            if (RestoreError.Length > 0) throw new BridgeError(RestoreError, "synthetic restore failure");
            return new FakeLease(RestoreTenant.Length > 0 ? RestoreTenant : profile.TenantId, RestoreHome.Length > 0 ? RestoreHome : profile.HomeAccountId,
                RestoreClient.Length > 0 ? RestoreClient : settings.ClientId);
        }
        public Task Logout(Settings settings, SessionProfile remembered) { Logouts++; return CacheFailure == null ? Task.CompletedTask : Task.FromException(CacheFailure); }
    }
    private sealed class FakeLease(string tenant, string home = Home, string client = Sub) : IdentityLease
    {
        public override string Account => "fixture@example.invalid"; public override string TenantId => tenant;
        public override string HomeAccountId => home; public override string ClientId => client;
        public Action? OnToken;
        public int Forces; public string Error = "";
        public override Task<string> Token(bool forceRefresh, CancellationToken ct) { ct.ThrowIfCancellationRequested(); OnToken?.Invoke(); if (forceRefresh) Forces++; if (Error.Length > 0) throw new BridgeError(Error, "synthetic clean auth failure"); return Task.FromResult("synthetic-token-not-a-credential"); }
    }
    private sealed class FakeArm : HttpMessageHandler
    {
        public readonly List<string> Requests = new(); public int Posts, Unauthorized, Retry = 1; public bool MismatchedSub, Paginate, WrongTarget, CompleteOnPost, ThrowOnPost, Post401;
        public string Next = "", Power = "running", AsyncStatus = "Succeeded", Poll = AzureCore.Arm + "/subscriptions/" + Sub + "/providers/Microsoft.Compute/locations/eastus/operations/fixture";
        public HttpStatusCode Status = HttpStatusCode.OK;
        public TaskCompletionSource? BlockList, BlockVm;
        public HttpStatusCode PostStatus = HttpStatusCode.Accepted;
        public bool Malformed, Oversized;
        public bool SubPages; public string SubNext = "", SubTenant = Tenant; public Action? OnVmRead, OnViewRead; public TaskCompletionSource? BlockSubscriptions;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request.Method + " " + request.RequestUri);
            Assert(request.RequestUri!.Host == "management.azure.com");
            if (request.Method == HttpMethod.Post)
            {
                Posts++; if (ThrowOnPost) return Task.FromException<HttpResponseMessage>(new HttpRequestException("synthetic disconnect"));
                if (Post401) return Task.FromResult(Response(HttpStatusCode.Unauthorized, new()));
                if (PostStatus != HttpStatusCode.Accepted) return Task.FromResult(Response(PostStatus, new()));
                if (CompleteOnPost) Power = request.RequestUri.AbsolutePath.EndsWith("/start") ? "running" : "deallocated";
                var r = Response(HttpStatusCode.Accepted, new()); r.Headers.Add("Azure-AsyncOperation", Poll); r.Headers.Add("Retry-After", Retry.ToString()); return Task.FromResult(r);
            }
            if (Unauthorized-- > 0) return Task.FromResult(Response(HttpStatusCode.Unauthorized, new()));
            if (Status != HttpStatusCode.OK) return Task.FromResult(Response(Status, new() { ["error"] = "raw content never exposed" }));
            var path = request.RequestUri.AbsolutePath;
            if (path == "/tenants") return Ok(new() { ["value"] = new JsonArray(new JsonObject { ["tenantId"] = Tenant, ["displayName"] = "Fixture directory" }, new JsonObject { ["tenantId"] = Tenant2, ["displayName"] = "Fixture guest" }) });
            if (path == "/subscriptions")
            {
                var second = request.RequestUri.Query.Contains("page=2");
                var rows = new JsonArray();
                if (!SubPages || !second) rows.Add(new JsonObject { ["subscriptionId"] = Sub, ["tenantId"] = SubTenant, ["displayName"] = "Fixture subscription" });
                if (!SubPages || second) rows.Add(new JsonObject { ["subscriptionId"] = Sub2, ["tenantId"] = MismatchedSub ? Tenant2 : SubTenant, ["displayName"] = "Fixture subscription 2" });
                var data = new JsonObject { ["value"] = rows };
                if (SubNext.Length > 0) data["nextLink"] = SubNext;
                else if (SubPages && !second) data["nextLink"] = AzureCore.Arm + "/subscriptions?api-version=2022-12-01&page=2";
                if (BlockSubscriptions != null) return BlockSubscriptions.Task.ContinueWith(_ => Response(HttpStatusCode.OK, data));
                return Ok(data);
            }
            if (path.Contains("/operations/")) { var r = Response(HttpStatusCode.OK, new() { ["status"] = AsyncStatus }); r.Headers.Add("Retry-After", Retry.ToString()); return Task.FromResult(r); }
            if (path.EndsWith("/instanceView")) { OnViewRead?.Invoke(); return Ok(new() { ["statuses"] = new JsonArray(new JsonObject { ["code"] = "PowerState/" + Power }) }); }
            if (path.EndsWith("/virtualMachines"))
            {
                if (Oversized) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new MemoryStream(new byte[8 * 1024 * 1024 + 1])) });
                if (Malformed) return Ok(new() { ["value"] = new JsonArray(JsonValue.Create("not-a-vm")) });
                var second = request.RequestUri.Query.Contains("page=2");
                var data = new JsonObject { ["value"] = new JsonArray(Vm(second ? Id + "2" : Id)) };
                if (Next.Length > 0) data["nextLink"] = Next;
                else if (Paginate && !second) data["nextLink"] = AzureCore.Arm + path + "?api-version=2025-04-01&page=2";
                if (BlockList != null) return BlockList.Task.ContinueWith(_ => Response(HttpStatusCode.OK, data)); // Deliberately ignores CT to test stale response defence.
                return Ok(data);
            }
            if (BlockVm != null) return BlockVm.Task.ContinueWith(_ => Response(HttpStatusCode.OK, Vm(Id)));
            OnVmRead?.Invoke();
            return Ok(Vm(WrongTarget ? Id + "2" : Id));
        }
        private JsonObject Vm(string id) => new() { ["id"] = id, ["location"] = "eastus", ["tags"] = new JsonObject { ["fixture"] = "yes" }, ["properties"] = new JsonObject { ["provisioningState"] = "Succeeded", ["hardwareProfile"] = new JsonObject { ["vmSize"] = "Standard_B1s" }, ["storageProfile"] = new JsonObject { ["osDisk"] = new JsonObject { ["osType"] = "Linux" } }, ["instanceView"] = new JsonObject { ["statuses"] = new JsonArray(new JsonObject { ["code"] = "PowerState/" + Power }) } } };
        private static Task<HttpResponseMessage> Ok(JsonObject value) => Task.FromResult(Response(HttpStatusCode.OK, value));
        private static HttpResponseMessage Response(HttpStatusCode status, JsonObject value) => new(status) { Content = new StringContent(value.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}