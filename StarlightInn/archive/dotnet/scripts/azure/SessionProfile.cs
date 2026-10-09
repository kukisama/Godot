using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Starlight.Azure;

// Metadata only. Never a token cache. Username is display-only, not identity.
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record SessionProfile(int Version = 1, bool AutoLogin = true,
    string ClientId = "", string InitialTenant = "", string HomeAccountId = "",
    string Username = "", string TenantId = "", string SubscriptionId = "", string SubscriptionName = "")
{
    [JsonIgnore] public bool HasIdentity => HomeAccountId?.Length > 0;
    public void Validate()
    {
        if (Version != 1 || new[] { ClientId, InitialTenant, HomeAccountId, Username, TenantId, SubscriptionId, SubscriptionName }.Any(x => x == null || x.Length > 512 || x.Any(char.IsControl)))
            throw new BridgeError("INVALID_PROFILE", "账户档案版本或字段无效；请手动重新登录。");
        if (!HasIdentity)
        {
            if (ClientId.Length + InitialTenant.Length + Username.Length + TenantId.Length + SubscriptionId.Length + SubscriptionName.Length != 0)
                throw new BridgeError("INVALID_PROFILE", "账户档案缺少固定身份；请手动重新登录。");
            return;
        }
        new Settings(ClientId, InitialTenant).Validate();
        // This app supports Entra accounts only (uid.utid), never email/loginHint.
        var parts = HomeAccountId.Split('.');
        if (parts.Length != 2 || parts.Any(x => !Guid.TryParseExact(x, "D", out var id) || id == Guid.Empty) ||
            !Guid.TryParseExact(TenantId, "D", out var tenant) || tenant == Guid.Empty ||
            (SubscriptionId.Length > 0 && (!Guid.TryParseExact(SubscriptionId, "D", out var sub) || sub == Guid.Empty)) ||
            (SubscriptionId.Length == 0 && SubscriptionName.Length > 0))
            throw new BridgeError("INVALID_PROFILE", "账户/目录/订阅档案身份无效；请手动重新登录。");
    }
    public void Match(Settings settings)
    {
        Validate(); settings.Validate();
        // InitialTenant is an authorization entry point, not SupportedAccountTypes
        // or a local tenant allowlist. Restore still pins the saved actual tenant.
        if (!HasIdentity || !Same(ClientId, settings.ClientId) || !Same(InitialTenant, settings.InitialTenant))
            throw new BridgeError("PROFILE_MISMATCH", "登录配置已改变，不能恢复旧账户；请手动重新登录。");
    }
    public static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}
public interface IProfileStore
{
    SessionProfile Load();
    void Save(SessionProfile profile);
}
public sealed class MemoryProfileStore : IProfileStore
{
    public SessionProfile Value = new();
    public SessionProfile Load() => Value;
    public void Save(SessionProfile profile) { profile.Validate(); Value = profile; }
}
public sealed class UserProfileStore(string path) : IProfileStore
{
    public string PathName => path;
    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "StarlightInn", "Azure", "session-profile.v1.bin");
    public SessionProfile Load()
    {
        if (!File.Exists(path)) return new();
        if (new FileInfo(path).Length is <= 0 or > 16384) throw new BridgeError("INVALID_PROFILE", "账户档案无效；请手动重新登录。");
        var bytes = Protect(File.ReadAllBytes(path), false);
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var keys = new[] { "version", "auto_login", "client_id", "initial_tenant", "home_account_id", "username", "tenant_id", "subscription_id", "subscription_name" };
            var properties = document.RootElement.EnumerateObject().ToArray();
            if (properties.Length != keys.Length || keys.Any(k => properties.Count(p => p.Name == k) != 1)) throw new JsonException();
            var value = JsonSerializer.Deserialize<SessionProfile>(bytes, AzureCore.Json) ?? throw new JsonException();
            value.Validate(); return value;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    public void Save(SessionProfile profile)
    {
        profile.Validate();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(profile, AzureCore.Json);
        byte[] protectedBytes;
        try { protectedBytes = Protect(bytes, true); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllBytes(temp, protectedBytes); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    private static byte[] Protect(byte[] bytes, bool encrypt)
    {
        if (!OperatingSystem.IsWindows()) throw new BridgeError("PROFILE_UNAVAILABLE", "账户记忆需要 Windows 当前用户保护；未保存明文档案。");
        var input = new Blob { Size = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        var output = new Blob();
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            // Current user scope; UI_FORBIDDEN. No machine-wide protection or prompts.
            var ok = encrypt ? CryptProtectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new BridgeError("INVALID_PROFILE", "无法保护/打开本用户账户档案；请手动重新登录。");
            var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, output.Size); return result;
        }
        finally
        {
            for (var i = 0; i < input.Size; i++) Marshal.WriteByte(input.Data, i, 0);
            Marshal.FreeHGlobal(input.Data);
            if (output.Data != IntPtr.Zero) { for (var i = 0; i < output.Size; i++) Marshal.WriteByte(output.Data, i, 0); LocalFree(output.Data); }
        }
    }
}