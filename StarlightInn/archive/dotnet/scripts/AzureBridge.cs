using Godot;
using Starlight.Azure;
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

public partial class AzureBridge : Node
{
    [Signal] public delegate void ReplyEventHandler(string json);
    [Signal] public delegate void JournalChangedEventHandler(string json);
    private readonly ConcurrentQueue<string> replies = new();
    private AzureCore core = null!;
    private volatile bool exiting;
    private string configPath = "";
    private string configError = "";
    private string lastJournal = "";
    private string profilePath = "";
    private bool headless;
    private double journalClock;
    public override void _Ready()
    {
        profilePath = UserProfileStore.DefaultPath;
        headless = DisplayServer.GetName() == "headless";
        // Offline QA must never load a real user's metadata, even before its fake
        // bridge is installed. Desktop WAM/profile behavior remains unchanged.
        core = new AzureCore(new WamIdentity(), profiles: headless ? new MemoryProfileStore() : new UserProfileStore(profilePath));
        // Godot 4 export templates use the template feature, not the old
        // standalone tag. A packed res:// path must never become a CWD file.
        configPath = OS.HasFeature("editor")
            ? ProjectSettings.GlobalizePath("res://azure-settings.json")
            : Path.Combine(Path.GetDirectoryName(OS.GetExecutablePath())!, "azure-settings.json");
        try
        {
            if (File.Exists(configPath))
            {
                var raw = JsonNode.Parse(File.ReadAllText(configPath)) as JsonObject ?? throw new JsonException();
                ValidateKeys(raw, "client_id", "initial_tenant");
                core.Configure(new(AzureCore.Text(raw, "client_id"), AzureCore.Text(raw, "initial_tenant") is { Length: > 0 } t ? t : "organizations"));
            }
        }
        catch (Exception) { configError = "配置文件无效：请在登记簿重新保存 ClientId 与初始目录。"; }
        GD.Print("AZURE_BRIDGE_READY: real MSAL WAM compiled; silent-only remembered identity restore; no automatic login dialogs; token-free DTO boundary");
    }
    public string GetSettings() => JsonSerializer.Serialize(new { settings = core.Configuration, path = configPath, error = configError,
        preferences = core.Preferences, profile_path = profilePath }, AzureCore.Json);
    public string GetContext() => JsonSerializer.Serialize(core.Current, AzureCore.Json);
    public void CancelLogin() => core.CancelLogin();
    public void CancelConfirmation() => core.CancelConfirmation();
    public void CancelQueries() => core.CancelQueries();
    // Request comes from explicit UI actions. Capturing HWND is main-thread only.
    public void Request(string id, string action, string arguments)
    {
        if (exiting) return;
        var hwnd = DisplayServer.GetName() == "headless" ? IntPtr.Zero : (IntPtr)DisplayServer.WindowGetNativeHandle(DisplayServer.HandleType.WindowHandle);
        _ = Dispatch(id, action, arguments, hwnd);
    }
    private async Task Dispatch(string id, string action, string arguments, IntPtr hwnd)
    {
        object? data = null;
        var ok = true; var code = ""; var message = "";
        try
        {
            if (headless) throw new BridgeError("HEADLESS_OFFLINE", "无界面模式仅允许离线测试；未读取个人档案、认证或调用真实 Azure。请使用合成测试桥。");
            if (id.Length == 0 || id.Length > 100) throw new BridgeError("INVALID_REQUEST", "请求编号无效。");
            var args = JsonNode.Parse(arguments) as JsonObject ?? throw new BridgeError("INVALID_REQUEST", "参数应为对象。");
            string Arg(string key) => AzureCore.Text(args, key);
            bool More() => args["more"]?.GetValue<bool>() ?? false;
            switch (action)
            {
                case "configure":
                    ValidateKeys(args, "client_id", "initial_tenant");
                    var value = new Settings(Arg("client_id"), Arg("initial_tenant").Length == 0 ? "organizations" : Arg("initial_tenant"));
                    // Public configuration only. Tokens/cache never go to disk.
                    core.Configure(value, config => File.WriteAllText(configPath, JsonSerializer.Serialize(config, AzureCore.Json)));
                    configError = ""; data = value; message = "公开应用配置已保存；尚未登录。";
                    break;
                case "login":
                    ValidateKeys(args, "browser", "select_account", "tenant");
                    data = await core.Login(args["browser"]?.GetValue<bool>() ?? false,
                        args["select_account"]?.GetValue<bool>() ?? false, Arg("tenant"), hwnd);
                    message = "已连接真实 Azure；请读取目录与订阅。" + core.ConnectionNotice; break;
                case "restore":
                    ValidateKeys(args); message = await core.TryRestore(); data = core.Current; break;
                case "auto_login":
                    ValidateKeys(args, "enabled"); core.SetAutoLogin(args["enabled"]?.GetValue<bool>() ?? throw new BridgeError("INVALID_ARGUMENTS", "缺少自动登录开关。"));
                    message = "自动登录偏好已保存；未注销当前账户。"; data = core.Current; break;
                case "logout":
                    ValidateKeys(args); await core.Logout(); data = core.Current;
                    message = "仅注销本应用；未退出 Windows 账户，已受理云操作未撤销。"; break;
                case "tenants": ValidateKeys(args, "more"); data = await core.ListDirectories(More()); break;
                case "subscriptions": ValidateKeys(args, "more"); data = await core.ListSubscriptions(More()); break;
                case "select_subscription": ValidateKeys(args, "id"); core.SelectSubscription(Arg("id")); data = core.Current; break;
                case "vms": ValidateKeys(args, "more"); data = await core.ListVms(More()); break;
                case "inspect": ValidateKeys(args, "resource_id"); data = await core.Inspect(Arg("resource_id")); break;
                case "prepare": ValidateKeys(args, "resource_id", "action"); data = await core.Prepare(Arg("resource_id"), Arg("action")); break;
                case "execute": ValidateKeys(args, "nonce"); data = await core.Execute(Arg("nonce")); break;
                case "operations": ValidateKeys(args); data = core.Operations; break;
                case "resume": ValidateKeys(args, "id"); core.Resume(Arg("id")); data = core.Operations; break;
                default: throw new BridgeError("UNSUPPORTED_ACTION", "不支持此动作；没有任意 REST 入口。");
            }
        }
        catch (BridgeError e) { ok = false; code = e.Code; message = e.Message; }
        catch (OperationCanceledException) { ok = false; code = "CANCELLED_OR_TIMEOUT"; message = action == "restore" ? "需要重新登录：静默恢复已取消或超时；未自动弹窗，公开设置仍保留。" : "本地等待已取消或超时；已受理云操作不会因此撤销。"; }
        catch (UnauthorizedAccessException) { ok = false; code = "CONFIG_IO"; message = "公开配置目录不可写；请复制到可写目录，不要求管理员权限。"; }
        catch (IOException) { ok = false; code = "CONFIG_IO"; message = "公开配置无法保存，请确认本应用目录可写；不要求管理员权限。"; }
        catch (Exception) { ok = false; code = "REQUEST_FAILED"; message = "请求未完成，请检查配置或网络；未输出原始异常或凭据。"; }
        if (!exiting) replies.Enqueue(JsonSerializer.Serialize(new { id, action, ok, code, message, data, context = core.Current,
            preferences = core.Preferences, mode = "real" }, AzureCore.Json));
    }
    private static void ValidateKeys(JsonObject args, params string[] allowed)
    {
        foreach (var pair in args) if (Array.IndexOf(allowed, pair.Key) < 0)
            throw new BridgeError("INVALID_ARGUMENTS", "拒绝未允许的请求参数。");
    }
    public override void _Process(double delta)
    {
        if (exiting) return;
        // A worker never touches a Godot object. Signals run only on main thread,
        // with queued replies discarded once this Node leaves the tree.
        while (replies.TryDequeue(out var json)) EmitSignal(SignalName.Reply, json);
        journalClock += delta;
        if (journalClock < 0.25) return;
        journalClock = 0;
        var journal = JsonSerializer.Serialize(core.Operations, AzureCore.Json);
        if (journal != lastJournal) { lastJournal = journal; EmitSignal(SignalName.JournalChanged, journal); }
    }
    public override void _ExitTree()
    {
        exiting = true; core?.Dispose();
        while (replies.TryDequeue(out _)) { }
    }
}