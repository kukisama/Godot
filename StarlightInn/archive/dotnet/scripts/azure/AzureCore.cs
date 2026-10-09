using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Starlight.Azure;

// Only these public DTOs cross the Godot boundary. No authentication result,
// exception body, token, HTTP headers or arbitrary ARM payload is serialized.
public sealed record Settings(string ClientId = "", string InitialTenant = "organizations")
{
    public void Validate(bool requireClient = true)
    {
        if ((requireClient || ClientId.Length > 0) && (!Guid.TryParse(ClientId, out var id) || id == Guid.Empty))
            throw new BridgeError("NOT_CONFIGURED", "请在米拉登记簿填写有效的应用 ClientId（不是密码）。");
        if (InitialTenant != "organizations" && (!Guid.TryParse(InitialTenant, out var tenant) || tenant == Guid.Empty))
            throw new BridgeError("INVALID_TENANT", "初始目录应为 organizations 或有效 TenantId。");
    }
}
public sealed class BridgeError : Exception
{
    public string Code { get; }
    public BridgeError(string code, string message) : base(message) => Code = code;
}
public sealed record NamedId(string Id, string Name);
public sealed record Context(long Generation, string Account, string TenantId, string TenantName,
    string SubscriptionId, string SubscriptionName);
public sealed record Vm(string ResourceId, string Name, string ResourceGroup, string Region, string Size,
    string PowerState, string LastRefresh, Dictionary<string, string> Tags, string ProvisioningState, string OsType);
public sealed record Page<T>(IReadOnlyList<T> Items, bool HasMore, string Notice);
public sealed record Confirmation(string Nonce, Context Context, Vm Target, string Action, string Impact, string Expires);
public sealed record OperationRecord(string Id, Context Context, Vm Target, string Action, string State,
    string Message, string Updated);

// A lease pins the EXACT explicitly selected account/client and tenant. Never
// pick the first cached account or consult global CLI/Windows default identity.
public interface IIdentity
{
    Task<IdentityLease> Login(Settings settings, string tenant, IdentityLease? previous,
        bool selectAccount, bool browser, IntPtr hwnd, CancellationToken ct);
    Task<IdentityLease> TryRestore(Settings settings, SessionProfile profile, CancellationToken ct);
    Task Logout(Settings settings, SessionProfile remembered);
}
public abstract class IdentityLease
{
    public abstract string Account { get; }
    public abstract string TenantId { get; }
    public abstract string HomeAccountId { get; }
    public abstract string ClientId { get; }
    public abstract Task<string> Token(bool forceRefresh, CancellationToken ct);
}
public sealed class AzureCore : IDisposable
{
    public const string Arm = "https://management.azure.com";
    public const string ComputeVersion = "2025-04-01";
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
    private readonly IIdentity identity;
    private readonly HttpClient http;
    private readonly object sync = new();
    private readonly SemaphoreSlim loginGate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource query = new();
    private CancellationTokenSource? auth;
    private IdentityLease? lease;
    private readonly IProfileStore profileStore;
    private SessionProfile profile = new();
    private bool restoring;
    private long authGeneration;
    private string profileNotice = "请首次手动登录；只使用微软认证，不保存密码。";
    public TimeSpan RestoreTimeout { get; set; } = TimeSpan.FromSeconds(30);
    public int MaxRestorePages { get; set; } = 10;
    private Settings settings = new();
    private Context context = new(0, "", "", "", "", "");
    private readonly Dictionary<string, NamedId> tenants = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, NamedId> subscriptions = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Vm> knownVms = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Ticket> tickets = new();
    private readonly Dictionary<string, Job> jobs = new();
    private readonly Dictionary<string, string> continuations = new();
    private readonly Func<DateTimeOffset> now;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    public TimeSpan ConfirmationTtl { get; set; } = TimeSpan.FromMinutes(2);
    public TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(30);
    public TimeSpan PollBudget { get; set; } = TimeSpan.FromMinutes(10);
    public int MaxPolls { get; set; } = 40;
    private sealed record Ticket(Confirmation Value, DateTimeOffset Deadline);
    private sealed class Job
    {
        public OperationRecord Record;
        public readonly IdentityLease Lease;
        public string PollUrl = "";
        public bool AsyncHeader;
        public TimeSpan Wait = TimeSpan.FromSeconds(2);
        public bool Polling;
        public bool AzureAcknowledged;
        public Job(OperationRecord record, IdentityLease lease) { Record = record; Lease = lease; }
    }
    private sealed record Snapshot(Context Context, IdentityLease Lease, CancellationToken Cancel);
    public AzureCore(IIdentity identity, HttpMessageHandler? handler = null,
        Func<DateTimeOffset>? clock = null, Func<TimeSpan, CancellationToken, Task>? wait = null, IProfileStore? profiles = null)
    {
        this.identity = identity;
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false });
        http.Timeout = Timeout.InfiniteTimeSpan;
        now = clock ?? (() => DateTimeOffset.UtcNow);
        delay = wait ?? Task.Delay;
        profileStore = profiles ?? new MemoryProfileStore();
        try { profile = profileStore.Load(); profile.Validate(); }
        catch (Exception) { profile = new(); profileNotice = "账户档案无效或不可读，需要重新登录；公开配置仍保留。"; }
    }
    public Context Current { get { lock (sync) return context; } }
    public Settings Configuration { get { lock (sync) return settings; } }
    public string ConnectionNotice { get { lock (sync) return profileNotice; } }
    public object Preferences { get { lock (sync) return new { auto_login = profile.AutoLogin, has_identity = profile.HasIdentity, restoring, notice = profileNotice }; } }
    public OperationRecord[] Operations { get { lock (sync) return jobs.Values.Select(x => x.Record).ToArray(); } }
    public void Configure(Settings value, Action<Settings>? persist = null)
    {
        value.Validate(false);
        lock (sync)
        {
            if (lease != null || (auth != null && !restoring)) throw new BridgeError("LOGOUT_REQUIRED", "请先注销本应用再修改登录配置。");
            persist?.Invoke(value); // A failed public-config save must not change the active configuration.
            auth?.Cancel(); authGeneration++;
            settings = value;
            Advance("", "", "", "", "");
        }
    }
    private void Advance(string account, string tenant, string tenantName, string sub, string subName)
    {
        query.Cancel(); query.Dispose(); query = new();
        context = new(context.Generation + 1, account, tenant, tenantName, sub, subName);
        tickets.Clear(); knownVms.Clear(); continuations.Clear();
    }
    public void CancelLogin() { lock (sync) { auth?.Cancel(); authGeneration++; } }
    private void SaveProfile(SessionProfile value)
    {
        profileStore.Save(value); profile = value;
    }
    private void RememberCurrent()
    {
        if (lease == null) return;
        SaveProfile(new(1, profile.AutoLogin, settings.ClientId, settings.InitialTenant, lease.HomeAccountId,
            lease.Account, lease.TenantId, context.SubscriptionId, context.SubscriptionName));
    }
    public void SetAutoLogin(bool enabled)
    {
        lock (sync)
        {
            SaveProfile(profile with { AutoLogin = enabled });
            if (!enabled && restoring) { auth?.Cancel(); authGeneration++; }
            profileNotice = enabled ? "已记住设置／下次启动静默登录；组织要求时重新验证。" : "已关闭下次启动静默登录；不注销当前账户。";
        }
    }
    public async Task<string> TryRestore()
    {
        if (!await loginGate.WaitAsync(0)) throw new BridgeError("LOGIN_BUSY", "已有登录正在进行。");
        CancellationTokenSource? local = null;
        long generation = 0;
        try
        {
            Settings config; SessionProfile saved;
            lock (sync)
            {
                if (lease != null) return "已连接明确账户，无需启动恢复。";
                if (settings.ClientId.Length == 0) return "真实 Azure 未配置；请保存公开 ClientId 并首次手动登录。";
                if (!profile.AutoLogin) return "自动登录已关闭，请手动登录。";
                if (!profile.HasIdentity) return profileNotice;
                config = settings; saved = profile; saved.Match(config);
                generation = ++authGeneration;
                local = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                local.CancelAfter(RestoreTimeout); auth = local; restoring = true;
                lease = null; tenants.Clear(); subscriptions.Clear(); Advance("", "", "", "", "");
            }
            var result = await identity.TryRestore(config, saved, local.Token).WaitAsync(local.Token);
            local.Token.ThrowIfCancellationRequested();
            if (!SessionProfile.Same(result.HomeAccountId, saved.HomeAccountId) || !SessionProfile.Same(result.TenantId, saved.TenantId) ||
                !SessionProfile.Same(result.ClientId, config.ClientId) || result.Account.Length == 0)
                throw new BridgeError("ACCOUNT_CHANGED", "静默返回身份不匹配，需要重新登录。");
            // Identity acquisition has completed. A subscription timeout must
            // not discard that verified account, while user/lifetime cancellation must.
            local.CancelAfter(Timeout.InfiniteTimeSpan);
            var found = new Dictionary<string, NamedId>(StringComparer.OrdinalIgnoreCase);
            var notice = "已静默恢复明确账户；请读取并选择订阅。";
            if (saved.SubscriptionId.Length > 0)
            {
                try
                {
                    using var subscriptionTimeout = CancellationTokenSource.CreateLinkedTokenSource(local.Token);
                    subscriptionTimeout.CancelAfter(RestoreTimeout);
                    var url = Arm + "/subscriptions?api-version=2022-12-01";
                    var visited = new HashSet<string>(StringComparer.Ordinal);
                    for (var i = 0; i < MaxRestorePages && visited.Add(url); i++)
                    {
                        var raw = await Get(result, url, subscriptionTimeout.Token).WaitAsync(subscriptionTimeout.Token);
                        foreach (var row in Values(raw))
                        {
                            var id = Text(row, "subscriptionId");
                            if (!Guid.TryParse(id, out var sub) || sub == Guid.Empty) throw new BridgeError("INVALID_RESPONSE", "订阅身份无效。");
                            if (Text(row, "tenantId").Length > 0 && !SessionProfile.Same(Text(row, "tenantId"), result.TenantId)) continue;
                            found[id] = new(id, Text(row, "displayName") is { Length: > 0 } n ? n : id);
                        }
                        if (found.ContainsKey(saved.SubscriptionId)) break;
                        var next = Text(raw, "nextLink");
                        if (next.Length == 0) break;
                        ValidateUrl(next, "/subscriptions"); url = next;
                    }
                    notice = found.ContainsKey(saved.SubscriptionId) ? "已静默恢复账户、目录及已验证订阅。" : "账户已恢复；原订阅未在有限分页中返回，请重新读取并选择订阅。";
                }
                catch (OperationCanceledException) when (!local.IsCancellationRequested) { notice = "账户已恢复；订阅查询超时，请重新选择订阅。"; found.Clear(); }
                catch (BridgeError) { notice = "账户已恢复；无法验证原订阅，请重新读取并选择订阅。"; found.Clear(); }
                catch (HttpRequestException) { notice = "账户已恢复；订阅网络查询未完成，请重新选择订阅。"; found.Clear(); }
            }
            lock (sync)
            {
                local.Token.ThrowIfCancellationRequested();
                if (generation != authGeneration || config != settings || !profile.AutoLogin) throw new OperationCanceledException(local.Token);
                lease = result;
                foreach (var item in found) subscriptions[item.Key] = item.Value;
                var sub = found.GetValueOrDefault(saved.SubscriptionId);
                Advance(result.Account, result.TenantId, result.TenantId, sub?.Id ?? "", sub?.Name ?? "");
                profileNotice = notice + " 下次启动静默登录；组织要求时重新验证。";
                return profileNotice;
            }
        }
        catch (Exception e) when (e is BridgeError or OperationCanceledException or HttpRequestException)
        {
            lock (sync)
            {
                if (local == null || generation == authGeneration)
                { lease = null; tenants.Clear(); subscriptions.Clear(); Advance("", "", "", "", ""); profileNotice = "需要重新登录：静默恢复未完成；请手动点击登录，未自动弹窗。"; }
            }
            if (e is OperationCanceledException) throw;
            throw new BridgeError("RELOGIN_REQUIRED", "需要重新登录：缓存缺失、身份/配置不匹配或组织要求验证；未自动弹窗。");
        }
        finally
        {
            lock (sync) if (auth == local) { auth = null; restoring = false; }
            local?.Dispose(); loginGate.Release();
        }
    }
    public async Task<Context> Login(bool browser, bool selectAccount, string tenant, IntPtr hwnd)
    {
        bool replacingRestore; long generation;
        lock (sync) { replacingRestore = restoring; if (replacingRestore) { auth?.Cancel(); authGeneration++; } generation = authGeneration; }
        if (replacingRestore) await loginGate.WaitAsync(lifetime.Token);
        else if (!await loginGate.WaitAsync(0)) throw new BridgeError("LOGIN_BUSY", "已有登录正在进行，请等待或取消。");
        CancellationTokenSource? local = null;
        try
        {
            Settings config;
            IdentityLease? previous;
            lock (sync)
            {
                if (generation != authGeneration) throw new OperationCanceledException();
                settings.Validate();
                if (tenant.Length > 0 && (!Guid.TryParse(tenant, out _) || (!tenants.ContainsKey(tenant) && tenant != settings.InitialTenant && tenant != context.TenantId)))
                    throw new BridgeError("INVALID_TENANT", "只能选择已列出的目录或配置的初始目录。");
                config = settings; previous = lease; selectAccount |= previous == null;
                subscriptions.Clear();
                Advance(context.Account, context.TenantId, context.TenantName, "", "");
                local = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                local.CancelAfter(TimeSpan.FromMinutes(3)); auth = local;
            }
            var result = await identity.Login(config, tenant.Length > 0 ? tenant : config.InitialTenant,
                previous, selectAccount, browser, hwnd, local.Token);
            local.Token.ThrowIfCancellationRequested();
            lock (sync)
            {
                local.Token.ThrowIfCancellationRequested();
                if (generation != authGeneration) throw new OperationCanceledException(local.Token);
                if (!Guid.TryParse(result.TenantId, out var resultTenant) || resultTenant == Guid.Empty || result.Account.Length == 0)
                    throw new BridgeError("INVALID_IDENTITY", "授权未返回有效的账户/目录身份。");
                if (!SessionProfile.Same(result.ClientId, config.ClientId) || (!selectAccount && previous != null && !SessionProfile.Same(result.HomeAccountId, previous.HomeAccountId)))
                    throw new BridgeError("ACCOUNT_CHANGED", "授权账户与明确选择身份不符。");
                new SessionProfile(1, profile.AutoLogin, config.ClientId, config.InitialTenant, result.HomeAccountId, result.Account, result.TenantId).Validate();
                lease = result;
                subscriptions.Clear();
                if (selectAccount) tenants.Clear();
                Advance(result.Account, result.TenantId, tenants.GetValueOrDefault(result.TenantId)?.Name ?? result.TenantId, "", "");
                RememberCurrent();
                profileNotice = profile.AutoLogin ? "已记住设置／下次启动静默登录；组织要求时重新验证。" : "已记住设置与账户；自动登录已关闭，当前账户保持连接。";
                return context;
            }
        }
        finally
        {
            lock (sync) if (auth == local) auth = null;
            local?.Dispose(); loginGate.Release();
        }
    }
    public async Task Logout()
    {
        Exception? saveError = null;
        BridgeError? cacheError = null;
        SessionProfile remembered; Settings config;
        lock (sync)
        {
            remembered = profile; config = settings;
            auth?.Cancel(); authGeneration++; lease = null; tenants.Clear(); subscriptions.Clear(); Advance("", "", "", "", "");
            var cleared = new SessionProfile(AutoLogin: profile.AutoLogin);
            profile = cleared;
            try { SaveProfile(cleared); } catch (Exception e) { saveError = e; }
            profileNotice = "本应用已断开，正在清理磁盘身份档案与应用缓存；尚未确认全部清理完成。";
        }
        // Does not cancel lifetime/job polling or sign the user out of Windows.
        await loginGate.WaitAsync();
        try { await identity.Logout(config, remembered); }
        catch (Exception e)
        {
            // Preserve only the clean bridge code, never raw MSAL/unknown details.
            cacheError = new BridgeError(e is BridgeError b ? b.Code : "LOGOUT_CACHE_FAILED",
                "本应用缓存清理失败，未删除 Windows 账户。");
        }
        finally { loginGate.Release(); }
        var diskNotice = saveError != null
            ? "磁盘身份档案清除失败，档案仍可能存在，下次启动可能尝试恢复；请关闭自动登录并确认设置保存成功，或处理本用户目录写权限。"
            : "磁盘身份档案已清空。";
        var notice = saveError == null && cacheError == null
            ? "已注销本应用并清除记住的身份；公开配置和自动登录偏好保留。请首次手动登录。"
            : "本应用已断开，本进程不再自动恢复；" + diskNotice + (cacheError?.Message ?? "本应用认证缓存已清理，未删除 Windows 账户。") + " 公开配置保留，可手动登录；已受理云操作未撤销。";
        lock (sync) profileNotice = notice;
        if (saveError != null || cacheError != null)
            throw new BridgeError(saveError != null ? (cacheError != null ? "LOGOUT_INCOMPLETE" : "PROFILE_IO") : cacheError!.Code, notice);
    }
    private Snapshot Capture(bool needsSub = true)
    {
        lock (sync)
        {
            if (auth != null) throw new BridgeError("LOGIN_BUSY", "登录期间不能查询或提交资源操作。");
            if (lease == null) throw new BridgeError("NOT_CONNECTED", "真实 Azure 未连接，请先在米拉登记簿登录。");
            if (needsSub && context.SubscriptionId.Length == 0) throw new BridgeError("SELECT_SUBSCRIPTION", "请先选择当前目录中的订阅。");
            return new(context, lease, query.Token);
        }
    }
    private void Check(Snapshot s)
    {
        lock (sync) if (s.Context.Generation != context.Generation || s.Cancel.IsCancellationRequested)
            throw new BridgeError("STALE_CONTEXT", "上下文已改变，旧查询结果已丢弃。");
    }
    public async Task<Page<NamedId>> ListDirectories(bool more = false)
    {
        var s = Capture(false);
        var page = await NamedPage(s, "tenants", "tenantId", more);
        lock (sync) { Check(s); foreach (var item in page.Items) tenants[item.Id] = item; }
        return page;
    }
    public async Task<Page<NamedId>> ListSubscriptions(bool more = false)
    {
        var s = Capture(false);
        var page = await NamedPage(s, "subscriptions", "subscriptionId", more);
        lock (sync) { Check(s); foreach (var item in page.Items) subscriptions[item.Id] = item; }
        return page;
    }
    private async Task<Page<NamedId>> NamedPage(Snapshot s, string kind, string key, bool more)
    {
        var path = "/" + kind;
        var url = PageUrl(kind, path + "?api-version=2022-12-01", more);
        var raw = await Get(s.Lease, url, s.Cancel);
        Check(s);
        var items = new List<NamedId>();
        foreach (var row in Values(raw))
        {
            var id = Text(row, key);
            if (!Guid.TryParse(id, out _)) throw new BridgeError("INVALID_RESPONSE", "目录/订阅响应身份无效。");
            if (kind == "subscriptions" && Text(row, "tenantId").Length > 0 && !Eq(Text(row, "tenantId"), s.Context.TenantId)) continue;
            items.Add(new(id, Text(row, "displayName") is { Length: > 0 } n ? n : id));
        }
        return new(items, SaveNext(s, kind, raw, path), "每次读取一个服务端分页；可点击继续读取，未静默截断。");
    }
    public void SelectSubscription(string id)
    {
        lock (sync)
        {
            if (lease == null) throw new BridgeError("NOT_CONNECTED", "尚未登录。");
            if (!subscriptions.TryGetValue(id, out var sub)) throw new BridgeError("INVALID_SUBSCRIPTION", "只能选择当前目录已返回的订阅。");
            Advance(context.Account, context.TenantId, context.TenantName, sub.Id, sub.Name);
            RememberCurrent();
        }
    }
    private string VmListPath(Context c) => $"/subscriptions/{c.SubscriptionId}/providers/Microsoft.Compute/virtualMachines";
    private string PageUrl(string kind, string initial, bool more)
    {
        lock (sync)
        {
            if (!more) { continuations.Remove(kind); return Arm + initial; }
            if (!continuations.TryGetValue(kind, out var url)) throw new BridgeError("NO_MORE", "没有下一页。");
            return url;
        }
    }
    private bool SaveNext(Snapshot s, string kind, JsonObject raw, string allowedPath)
    {
        var next = Text(raw, "nextLink");
        if (next.Length > 0) ValidateUrl(next, allowedPath);
        lock (sync) { Check(s); if (next.Length > 0) continuations[kind] = next; else continuations.Remove(kind); }
        return next.Length > 0;
    }
    public async Task<Page<Vm>> ListVms(bool more = false)
    {
        var s = Capture();
        var path = VmListPath(s.Context);
        var raw = await Get(s.Lease, PageUrl("vms", path + "?api-version=" + ComputeVersion + "&statusOnly=true", more), s.Cancel);
        Check(s);
        var result = Values(raw).Select(x => MapVm(x, s.Context.SubscriptionId)).ToList();
        var hasMore = SaveNext(s, "vms", raw, path);
        lock (sync) { Check(s); foreach (var vm in result) knownVms[vm.ResourceId] = vm; }
        return new(result, hasMore, "列表状态缺失显示 unknown；选中后可读取实例状态与属性。筛选只作用于已加载页。");
    }
    public async Task<Vm> Inspect(string resourceId)
    {
        var s = Capture(); RequireKnown(resourceId, s);
        var vm = await ReadVm(s.Lease, s.Context, resourceId, s.Cancel);
        lock (sync) { Check(s); knownVms[resourceId] = vm; }
        return vm;
    }
    private void RequireKnown(string id, Snapshot s)
    {
        ParseResource(id, s.Context.SubscriptionId);
        lock (sync) { Check(s); if (!knownVms.ContainsKey(id)) throw new BridgeError("INVALID_TARGET", "必须从当前真实 VM 清单选择资源，不能使用演示名称。"); }
    }
    private async Task<Vm> ReadVm(IdentityLease account, Context c, string id, CancellationToken ct)
    {
        var canonical = ParseResource(id, c.SubscriptionId).Canonical;
        var props = await Get(account, Arm + canonical + "?api-version=" + ComputeVersion, ct);
        var vm = MapVm(props, c.SubscriptionId);
        if (!Eq(vm.ResourceId, canonical)) throw new BridgeError("INVALID_RESPONSE", "返回的 VM 身份与目标不匹配。");
        var view = await Get(account, Arm + canonical + "/instanceView?api-version=" + ComputeVersion, ct);
        return vm with { PowerState = Power(view), LastRefresh = now().ToString("O") };
    }
    public async Task<Confirmation> Prepare(string id, string action)
    {
        if (action != "start" && action != "deallocate") throw new BridgeError("UNSUPPORTED_ACTION", "仅支持启动或停止并解除分配。");
        var s = Capture(); RequireKnown(id, s);
        var vm = await ReadVm(s.Lease, s.Context, id, s.Cancel);
        Check(s);
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var expires = now() + ConfirmationTtl;
        var impact = action == "start" ? "将启动真实虚拟机并产生运行计算费用。" : "将中断业务并释放计算资源；磁盘、IP 等仍可能计费，不是零费用。";
        var value = new Confirmation(nonce, s.Context, vm, action, impact, expires.ToString("O"));
        lock (sync)
        {
            Check(s); CheckNoActive(vm.ResourceId); tickets.Clear(); tickets[nonce] = new(value, expires);
        }
        return value;
    }
    public void CancelConfirmation() { lock (sync) tickets.Clear(); }
    public void CancelQueries()
    {
        lock (sync) Advance(context.Account, context.TenantId, context.TenantName, context.SubscriptionId, context.SubscriptionName);
    }
    private void CheckNoActive(string id)
    {
        if (jobs.Values.Any(x => Eq(x.Record.Target.ResourceId, id) && x.Record.State is "submitting" or "submitted" or "pending" or "deferred" or "unknown"))
            throw new BridgeError("OPERATION_ACTIVE", "该资源已有在途或结果不确定的操作；请查看原记录，不要重复提交。");
    }
    public async Task<OperationRecord> Execute(string nonce)
    {
        var s = Capture();
        Ticket ticket;
        lock (sync)
        {
            if (!tickets.Remove(nonce, out ticket!)) throw new BridgeError("INVALID_CONFIRMATION", "确认无效或已消费，请重新核对目标。");
            if (ticket.Deadline <= now()) throw new BridgeError("EXPIRED_CONFIRMATION", "确认已过期，请重新核对目标。");
            if (ticket.Value.Context.Generation != context.Generation) throw new BridgeError("STALE_CONTEXT", "确认上下文已改变。");
            CheckNoActive(ticket.Value.Target.ResourceId);
        }
        var fresh = await ReadVm(s.Lease, s.Context, ticket.Value.Target.ResourceId, s.Cancel);
        Check(s);
        if (fresh.PowerState != ticket.Value.Target.PowerState || fresh.ProvisioningState != ticket.Value.Target.ProvisioningState)
            throw new BridgeError("TARGET_CHANGED", "目标状态已变化，请重新读取并确认。");
        // Resolve token BEFORE committing the submission, but never retain it in a DTO.
        var token = await s.Lease.Token(false, s.Cancel);
        Job job;
        Task<HttpResponseMessage> submit;
        var path = ParseResource(fresh.ResourceId, s.Context.SubscriptionId).Canonical;
        using var request = new HttpRequestMessage(HttpMethod.Post, Arm + path + "/" + ticket.Value.Action + "?api-version=" + ComputeVersion);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        timeout.CancelAfter(RequestTimeout);
        lock (sync)
        {
            Check(s); CheckNoActive(fresh.ResourceId);
            if (ticket.Deadline <= now()) throw new BridgeError("EXPIRED_CONFIRMATION", "确认在最终提交前已过期；未发送 POST，请重新核对目标。");
            var record = new OperationRecord(Guid.NewGuid().ToString(), s.Context, fresh, ticket.Value.Action, "submitting", "正在提交；关闭面板或切换上下文不会撤销云端操作。", now().ToString("O"));
            job = new(record, s.Lease); jobs[record.Id] = job;
            // No await between final context check and sending. Job now belongs to
            // original context, not query cancellation. Never retry POST on timeout.
            submit = http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        }
        try
        {
            using var response = await submit;
            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                // Explicit server rejection, not ambiguous acceptance: refresh once.
                using var retry = await Send(s.Lease, HttpMethod.Post, request.RequestUri!.ToString(), lifetime.Token, true);
                Accept(job, retry);
            }
            else Accept(job, response);
            if (job.Record.State == "submitted") _ = Poll(job);
        }
        catch (BridgeError e) { Update(job, e.Code is "FORBIDDEN" or "INTERACTION_REQUIRED" or "REDIRECT_BLOCKED" || (e.Code.StartsWith("ARM_HTTP_4") && e.Code != "ARM_HTTP_408") ? "failed" : "unknown", e.Message); }
        catch (Exception) { Update(job, "unknown", "提交结果不确定，禁止自动重发 POST；请通过原资源记录核对。退出本地等待不能撤销云操作。"); }
        return job.Record;
    }
    private void Accept(Job job, HttpResponseMessage response)
    {
        EnsureSuccess(response);
        job.AzureAcknowledged = true;
        Update(job, "submitted", "Azure 已受理，尚未确认完成。关闭面板/注销不撤销操作。");
        var asyncUrl = Header(response, "Azure-AsyncOperation");
        var location = Header(response, "Location");
        job.AsyncHeader = asyncUrl.Length > 0;
        job.PollUrl = asyncUrl.Length > 0 ? asyncUrl : location;
        job.Wait = RetryAfter(response, TimeSpan.FromSeconds(2));
        // An unsafe server URL must never receive a bearer token. Acceptance is
        // still real, so report deferred, not failed and never replay the POST.
        if (job.PollUrl.Length > 0)
        {
            try { ValidatePoll(job.PollUrl, job.Record.Context.SubscriptionId); }
            catch (BridgeError) { Update(job, "deferred", "已受理，但轮询地址不在允许范围；请核对原资源，不能重复提交。"); }
        }
    }
    public void Resume(string id)
    {
        lock (sync)
        {
            if (!jobs.TryGetValue(id, out var job)) throw new BridgeError("INVALID_OPERATION", "操作记录不存在。");
            if (job.Record.State is "deferred" or "unknown" or "pending" or "submitted")
            {
                if (job.Polling) return;
                if (job.PollUrl.Length > 0)
                    try { ValidatePoll(job.PollUrl, job.Record.Context.SubscriptionId); }
                    catch (BridgeError) { job.PollUrl = ""; job.AsyncHeader = false; }
                _ = Poll(job);
            }
        }
    }
    private async Task Poll(Job job)
    {
        lock (sync) { if (job.Polling) return; job.Polling = true; }
        var deadline = now() + PollBudget;
        try
        {
            for (var i = 0; i < MaxPolls && now() < deadline; i++)
            {
                if (job.Wait > TimeSpan.FromSeconds(60) || now() + job.Wait >= deadline) break;
                await delay(job.Wait, lifetime.Token);
                if (job.PollUrl.Length > 0)
                {
                    ValidatePoll(job.PollUrl, job.Record.Context.SubscriptionId);
                    using var response = await Send(job.Lease, HttpMethod.Get, job.PollUrl, lifetime.Token);
                    EnsureSuccess(response);
                    var raw = await Body(response, lifetime.Token);
                    var status = Text(raw, "status");
                    if (Eq(status, "Failed") || Eq(status, "Canceled")) { Update(job, "failed", "Azure 返回操作失败/取消，未声明目标状态已达成。"); return; }
                    job.Wait = RetryAfter(response, TimeSpan.FromSeconds(Math.Min(30, 2 + i * 2)));
                    if ((job.AsyncHeader && !Eq(status, "Succeeded")) || response.StatusCode == HttpStatusCode.Accepted)
                    { Update(job, "pending", "Azure 仍在处理；这不是成功回执。"); continue; }
                }
                var vm = await ReadVm(job.Lease, job.Record.Context, job.Record.Target.ResourceId, lifetime.Token);
                var expected = job.Record.Action == "start" ? "running" : "deallocated";
                if (!job.AzureAcknowledged)
                {
                    Update(job, "unknown", "目标当前已 " + vm.PowerState + "，原提交结果仍未知；未自动重发。");
                    return;
                }
                if (vm.PowerState == expected) { Update(job, "succeeded", "已重新读取实例状态：" + expected); return; }
                Update(job, "pending", "操作尚未达到目标状态，当前为 " + vm.PowerState + "；继续处理中。");
            }
            Update(job, job.AzureAcknowledged ? "deferred" : "unknown", "本地轮询达到时限/次数/Retry-After 上限，云端结果待核对；可继续只读查询，不能盲目重发。");
        }
        catch (OperationCanceledException) { Update(job, job.AzureAcknowledged ? "deferred" : "unknown", "本地等待已停止；未撤销云操作，未重发 POST。"); }
        catch (BridgeError e) { Update(job, job.AzureAcknowledged ? "deferred" : "unknown", (job.AzureAcknowledged ? "已受理操作" : "提交结果未知的操作") + "查询未完成：" + e.Message); }
        catch (Exception) { Update(job, job.AzureAcknowledged ? "deferred" : "unknown", (job.AzureAcknowledged ? "已受理操作" : "提交结果未知的操作") + "查询失败；请核对原记录，未重发 POST。"); }
        finally { lock (sync) job.Polling = false; }
    }
    private void Update(Job job, string state, string message)
    { lock (sync) job.Record = job.Record with { State = state, Message = message, Updated = now().ToString("O") }; }
    private async Task<HttpResponseMessage> Send(IdentityLease account, HttpMethod method, string url, CancellationToken ct, bool force = false)
    {
        ValidateHost(url);
        for (var attempt = 0; attempt < (force ? 1 : 2); attempt++)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
            timeout.CancelAfter(RequestTimeout);
            var token = await account.Token(force || attempt > 0, timeout.Token);
            using var request = new HttpRequestMessage(method, url);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (response.StatusCode != HttpStatusCode.Unauthorized || attempt > 0 || force) return response;
            response.Dispose();
        }
        throw new BridgeError("UNAUTHORIZED", "授权已失效，请点击登录，不会在查询中弹窗。");
    }
    private async Task<JsonObject> Get(IdentityLease account, string url, CancellationToken ct)
    {
        using var response = await Send(account, HttpMethod.Get, url, ct);
        EnsureSuccess(response);
        return await Body(response, ct);
    }
    private static void EnsureSuccess(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode) return;
        if (response.StatusCode == HttpStatusCode.Forbidden) throw new BridgeError("FORBIDDEN", "403：当前用户在此资源范围没有所需 Azure RBAC 权限；不会自动提升权限。");
        if (response.StatusCode == HttpStatusCode.Unauthorized) throw new BridgeError("INTERACTION_REQUIRED", "401：静默刷新仍失败，请主动点击登录。");
        if ((int)response.StatusCode is >= 300 and < 400) throw new BridgeError("REDIRECT_BLOCKED", "已拒绝 ARM HTTP 重定向，未向其他地址传递令牌。");
        throw new BridgeError("ARM_HTTP_" + (int)response.StatusCode, "ARM 请求失败，HTTP " + (int)response.StatusCode + "；未输出服务端原始内容。");
    }
    private async Task<JsonObject> Body(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.Content.Headers.ContentLength > 8 * 1024 * 1024) throw new BridgeError("RESPONSE_TOO_LARGE", "响应超过 8 MiB，请缩小查询范围。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(RequestTimeout);
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int count;
        while ((count = await stream.ReadAsync(chunk, timeout.Token)) > 0)
        {
            if (buffer.Length + count > 8 * 1024 * 1024) throw new BridgeError("RESPONSE_TOO_LARGE", "响应超过 8 MiB。");
            buffer.Write(chunk, 0, count);
        }
        var bytes = buffer.ToArray();
        if (bytes.Length == 0) return new();
        try { return JsonNode.Parse(bytes) as JsonObject ?? throw new BridgeError("INVALID_RESPONSE", "ARM 未返回 JSON 对象。"); }
        catch (JsonException) { throw new BridgeError("INVALID_RESPONSE", "ARM 返回了无效 JSON；未输出原始内容。"); }
    }
    public static Uri ValidateHost(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !Eq(uri.Host, "management.azure.com") || uri.Port != 443 || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0 || url.Contains('\\'))
            throw new BridgeError("UNSAFE_URL", "拒绝非国际 Azure ARM HTTPS 地址。");
        if (uri.AbsolutePath.Contains('%') || url.Contains("/../") || url.Contains("/./")) throw new BridgeError("UNSAFE_URL", "拒绝编码或路径遍历地址。");
        return uri;
    }
    public static void ValidateUrl(string url, string allowedPath)
    {
        if (!Eq(ValidateHost(url).AbsolutePath, allowedPath)) throw new BridgeError("UNSAFE_URL", "分页路径超出原查询范围。");
    }
    public static void ValidatePoll(string url, string sub)
    {
        var path = ValidateHost(url).AbsolutePath;
        var pattern = "^/subscriptions/" + Regex.Escape(sub) + @"/(?:resourceGroups/[A-Za-z0-9_.()\-]+/)?providers/Microsoft\.Compute/locations/[A-Za-z0-9\-]+/(?:operations|operationResults|operationStatuses)/[A-Za-z0-9\-]+$";
        if (!Regex.IsMatch(path, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            throw new BridgeError("UNSAFE_URL", "轮询地址超出原订阅 Compute 操作状态路径。");
    }
    public sealed record Resource(string Canonical, string Group, string Name);
    public static Resource ParseResource(string id, string sub)
    {
        if (!Guid.TryParse(sub, out _)) throw new BridgeError("INVALID_TARGET", "订阅身份无效。");
        var match = Regex.Match(id, @"^/subscriptions/([0-9a-fA-F\-]{36})/resourceGroups/([A-Za-z0-9_.()\-]{1,90})/providers/Microsoft\.Compute/virtualMachines/([A-Za-z0-9_\-]{1,64})$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        if (!match.Success || !Eq(match.Groups[1].Value, sub) || match.Groups[2].Value is "." or ".." || match.Groups[2].Value.EndsWith('.'))
            throw new BridgeError("INVALID_TARGET", "资源必须是当前订阅完整 VM resourceId；拒绝外部 URL、跨订阅及路径注入。");
        return new($"/subscriptions/{sub}/resourceGroups/{match.Groups[2].Value}/providers/Microsoft.Compute/virtualMachines/{match.Groups[3].Value}", match.Groups[2].Value, match.Groups[3].Value);
    }
    private Vm MapVm(JsonObject row, string sub)
    {
        var resource = ParseResource(Text(row, "id"), sub);
        var properties = row["properties"] as JsonObject ?? new();
        var tags = new Dictionary<string, string>();
        if (row["tags"] is JsonObject rawTags) foreach (var pair in rawTags) tags[pair.Key] = pair.Value?.ToString() ?? "";
        return new(resource.Canonical, resource.Name, resource.Group, Text(row, "location"),
            Text(properties["hardwareProfile"] as JsonObject, "vmSize"), Power(properties["instanceView"] as JsonObject), now().ToString("O"),
            tags, Text(properties, "provisioningState"), Text(properties["storageProfile"]?["osDisk"] as JsonObject, "osType"));
    }
    public static string Power(JsonObject? view)
    {
        if (view?["statuses"] is JsonArray statuses) foreach (var item in statuses.OfType<JsonObject>())
        {
            var code = Text(item, "code");
            if (code.StartsWith("PowerState/", StringComparison.OrdinalIgnoreCase)) return code[11..].ToLowerInvariant();
        }
        return "unknown";
    }
    private static IEnumerable<JsonObject> Values(JsonObject raw)
    {
        if (raw["value"] is not JsonArray items || items.Any(x => x is not JsonObject))
            throw new BridgeError("INVALID_RESPONSE", "响应缺少列表 value 或包含无效条目；未静默丢弃数据。");
        return items.Cast<JsonObject>();
    }
    public static string Text(JsonObject? raw, string key) => raw?[key]?.ToString() ?? "";
    private static bool Eq(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    private static string Header(HttpResponseMessage r, string key) => r.Headers.TryGetValues(key, out var values) ? values.FirstOrDefault() ?? "" : "";
    public static TimeSpan RetryAfter(HttpResponseMessage r, TimeSpan fallback)
    {
        var retry = r.Headers.RetryAfter;
        var seconds = retry?.Delta?.TotalSeconds ?? (retry?.Date - DateTimeOffset.UtcNow)?.TotalSeconds ?? fallback.TotalSeconds;
        return TimeSpan.FromSeconds(Math.Max(1, seconds));
    }
    public void Dispose()
    {
        lifetime.Cancel(); CancelLogin(); query.Cancel(); http.Dispose();
        // Do not dispose cancellation sources while outstanding async continuations
        // can still create linked tokens. They are GC-managed after cancellation.
    }
}