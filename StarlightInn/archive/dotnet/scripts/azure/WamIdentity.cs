using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Identity.Client;
using Microsoft.Identity.Client.Broker;
using Microsoft.Identity.Client.Extensibility;

namespace Starlight.Azure;

public sealed class WamIdentity : IIdentity
{
    public static readonly string[] Scopes = { "https://management.azure.com/user_impersonation" };
    private readonly List<IPublicClientApplication> clients = new();
    private IPublicClientApplication? brokerClient;
    private IPublicClientApplication? browserClient;
    private string configuredId = "";
    private static string Authority(string tenant) => "https://login.microsoftonline.com/" + tenant;
    private IPublicClientApplication Application(Settings settings, bool browser)
    {
        if (!SessionProfile.Same(configuredId, settings.ClientId))
        { brokerClient = null; browserClient = null; configuredId = settings.ClientId; }
        var app = browser ? browserClient : brokerClient;
        if (app == null)
        {
            var builder = PublicClientApplicationBuilder.Create(settings.ClientId).WithAuthority(Authority(settings.InitialTenant));
            if (browser) builder = builder.WithRedirectUri("http://localhost");
            else builder = builder.WithDefaultRedirectUri().WithBroker(new BrokerOptions(BrokerOptions.OperatingSystems.Windows)
            { Title = "星灯旅店 · 真实 Azure", ListOperatingSystemAccounts = true });
            app = builder.Build(); clients.Add(app);
            if (browser) browserClient = app; else brokerClient = app;
        }
        return app;
    }
    public async Task<IdentityLease> TryRestore(Settings settings, SessionProfile profile, CancellationToken ct)
    {
        profile.Match(settings); ct.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindows()) throw new BridgeError("WAM_UNAVAILABLE", "静默恢复需要 Windows WAM；未启动浏览器。");
        var app = Application(settings, false); // Fresh process creates its own broker client.
        try
        {
            // Actual MSAL 4.90.1 account-filter API, includes broker discovery.
            // No username overload, First(), OS default or interactive fallback.
            var account = await app.GetAccountAsync(profile.HomeAccountId).WaitAsync(ct);
            if (account == null || !SessionProfile.Same(account.HomeAccountId?.Identifier ?? "", profile.HomeAccountId))
                throw new BridgeError("CACHE_MISSING", "指定账户不在 WAM 可用账户中，需要重新登录。");
            var result = await app.AcquireTokenSilent(Scopes, account).WithTenantId(profile.TenantId).ExecuteAsync(ct);
            if (!SessionProfile.Same(result.Account.HomeAccountId?.Identifier ?? "", profile.HomeAccountId) ||
                !SessionProfile.Same(result.TenantId, profile.TenantId) || !SessionProfile.Same(app.AppConfig.ClientId, settings.ClientId))
                throw new BridgeError("ACCOUNT_CHANGED", "静默令牌身份不匹配，需要重新登录。");
            return new Lease(app, result.Account, result.TenantId, result.Account.Username);
        }
        catch (MsalUiRequiredException) { throw new BridgeError("INTERACTION_REQUIRED", "组织要求重新验证，请手动点击登录；未自动弹窗。"); }
        catch (MsalException) { throw new BridgeError("AUTH_FAILED", "静默恢复失败，需要重新登录；未输出认证原始内容。"); }
    }
    public async Task<IdentityLease> Login(Settings settings, string tenant, IdentityLease? previous,
        bool selectAccount, bool browser, IntPtr hwnd, CancellationToken ct)
    {
        settings.Validate();
        if (!browser && (!OperatingSystem.IsWindows() || hwnd == IntPtr.Zero))
            throw new BridgeError("WAM_WINDOW_REQUIRED", "WAM 需要交互式 Windows 会话与真实游戏窗口；可显式选择浏览器备用。");
        var app = Application(settings, browser);
        var old = previous as Lease;
        AuthenticationResult? result = null;
        try
        {
            // First-ever login always asks the user to choose. Silent acquisition
            // only uses a previously explicitly selected account in THIS app.
            if (!selectAccount && old != null)
                try { result = await app.AcquireTokenSilent(Scopes, old.Selected).WithTenantId(tenant).ExecuteAsync(ct); }
                catch (MsalUiRequiredException) { }
            if (result == null)
            {
                var interactive = app.AcquireTokenInteractive(Scopes).WithTenantId(tenant)
                    .WithUseEmbeddedWebView(false).WithParentActivityOrWindow(hwnd);
                if (!browser) interactive = interactive.WithCustomWebUi(new RefuseBrowserFallback());
                if (selectAccount || old == null) interactive = interactive.WithPrompt(Prompt.SelectAccount);
                else interactive = interactive.WithAccount(old.Selected);
                result = await interactive.ExecuteAsync(ct);
                if (!selectAccount && old != null && result.Account.HomeAccountId.Identifier != old.Selected.HomeAccountId.Identifier)
                    throw new BridgeError("ACCOUNT_CHANGED", "目录授权返回了不同账户，请通过换账户入口明确选择。");
            }
            return new Lease(app, result.Account, result.TenantId, result.Account.Username);
        }
        catch (MsalException e)
        {
            if (e.ErrorCode == "authentication_canceled") throw new OperationCanceledException(ct);
            // No MSAL exception message/AdditionalExceptionData reaches UI or logs.
            throw new BridgeError("AUTH_FAILED", "微软登录未完成。请核对公开应用配置、目录同意策略或显式选择浏览器备用；未使用其他登录流。");
        }
    }
    public async Task Logout(Settings settings, SessionProfile remembered)
    {
        try
        {
            // Also clears the explicitly remembered app account after a restart
            // with auto-login OFF. No dependence on this process's clients list.
            if (remembered.HasIdentity)
            {
                remembered.Validate();
                var app = Application(new Settings(remembered.ClientId, remembered.InitialTenant), false);
                var exact = await app.GetAccountAsync(remembered.HomeAccountId);
                if (exact != null && SessionProfile.Same(exact.HomeAccountId?.Identifier ?? "", remembered.HomeAccountId)) await app.RemoveAsync(exact);
            }
            foreach (var app in clients)
                foreach (var account in await app.GetAccountsAsync()) await app.RemoveAsync(account);
        }
        catch (MsalException) { throw new BridgeError("LOGOUT_CACHE_FAILED", "本应用缓存清理失败，未删除 Windows 账户。"); }
        // RemoveAsync clears this app's cache, not Windows account registration.
    }
    // MSAL's broker path takes precedence over CustomWebUi. If the broker cannot
    // be used, this fallback fails closed instead of starting a browser. The
    // separate browser client is created only by the explicit UI button.
    public sealed class RefuseBrowserFallback : ICustomWebUi
    {
        public Task<Uri> AcquireAuthorizationCodeAsync(Uri authorizationUri, Uri redirectUri, CancellationToken cancellationToken)
            => throw new BridgeError("WAM_UNAVAILABLE", "WAM 不可用；未自动打开浏览器，请明确选择浏览器备用。");
    }
    private sealed class Lease : IdentityLease
    {
        private readonly IPublicClientApplication app;
        public readonly IAccount Selected;
        public override string Account { get; }
        public override string TenantId { get; }
        public override string HomeAccountId => Selected.HomeAccountId?.Identifier ?? "";
        public override string ClientId => app.AppConfig.ClientId;
        public Lease(IPublicClientApplication app, IAccount account, string tenant, string username)
        { this.app = app; Selected = account; TenantId = tenant; Account = username; }
        public override async Task<string> Token(bool forceRefresh, CancellationToken ct)
        {
            try
            {
                var result = await app.AcquireTokenSilent(Scopes, Selected).WithTenantId(TenantId)
                    .WithForceRefresh(forceRefresh).ExecuteAsync(ct);
                if (!SessionProfile.Same(result.Account.HomeAccountId?.Identifier ?? "", HomeAccountId) || !SessionProfile.Same(result.TenantId, TenantId))
                    throw new BridgeError("ACCOUNT_CHANGED", "令牌身份与原账户/目录不匹配。");
                return result.AccessToken;
            }
            catch (MsalUiRequiredException) { throw new BridgeError("INTERACTION_REQUIRED", "需要用户交互授权，请点击米拉登录按钮；查询不会自动弹窗。"); }
            catch (MsalException) { throw new BridgeError("AUTH_FAILED", "静默授权失败，请主动重新登录；未输出认证原始内容。"); }
        }
    }
}