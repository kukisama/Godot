# 星灯旅店：真实 Azure 登记与权限

本工程是 **Godot.NET 桌面公开客户端**，用登录用户的委托权限访问国际 Azure ARM。默认 ClientId 为空，启动不弹登录框；可静默恢复上次明确选择的账户。不配置也能玩原离线旅店。下述注册/同意/角色步骤由应用所有者按组织政策完成，本交付没有创建应用、授权或执行真人云写。

## 1. 注册本应用，不借用其他软件的 ClientId

在 Microsoft Entra 管理中心的「应用注册 → 新注册」注册星灯旅店，保存「应用程序（客户端）ID」和「目录（租户）ID」。仅在自己的目录使用时选单租户（包含该目录的用户/来宾）；确需跨组织时才选多个 Entra 目录。两者不是同一个账号类型，详见[应用注册与支持账号类型](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)。

- 单租户：旅店的初始目录填该应用所在的 **TenantId GUID**，不要使用默认 `organizations` 来代替单租户配置。
- 多租户：初始目录可填 `organizations` 或目标 TenantId。目录列出不代表该应用已在每个目录获准使用；跨目录仍受各目录的来宾、同意和条件访问政策限制，参见[多租户应用概念](https://learn.microsoft.com/en-us/entra/identity-platform/single-and-multi-tenant-apps)。本应用不支持消费者专用、B2C、政府云或中国云配置。

`initial_tenant` 仅为初始授权入口，不等于注册的 SupportedAccountTypes，也不是本地租户允许列表。多租户应用可从 GUID 目录 A 登录，再明确切至获准访问的来宾目录 B；重启只向保存的实际目录 B 静默恢复，不回退 A 或 Windows 默认账户。单租户应用跨目录授权由 Entra 拒绝，不从初始 GUID 推断或新增本地账号类型配置，参见[单／多租户账号边界](https://learn.microsoft.com/en-us/entra/identity-platform/single-and-multi-tenant-apps)。

在「身份验证 → 添加平台 → 移动和桌面应用程序」添加 **`ms-appx-web://microsoft.aad.brokerplugin/{client_id}`**（用本应用实际 GUID 替换花括号）。这是门户中的 WAM 重定向注册；不是填写在 JSON 的字段，MSAL 的 broker 重定向由库处理，参见[WAM 重定向 URI 与父窗口要求](https://learn.microsoft.com/en-us/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam)。

只有希望使用游戏中的「浏览器备用（明确选择）」时，才在同一移动和桌面平台添加 **`http://localhost`**。这是系统浏览器的本地回环 URI，不要注册成 Web/SPA 平台，不启用隐式授权，参见[桌面平台配置](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration)。备用路径使用 MSAL 交互授权码流程；不会因 WAM 失败自动打开浏览器。

「高级设置 → 允许公共客户端流」与移动和桌面重定向注册不要混淆：[官方桌面配置说明](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration#enable-public-client-flow)将该开关用于不带重定向 URI 的设备代码、集成 Windows 和用户名密码流。本项目不实现这些流，不应为试图修复登录而启用 ROPC 或添加 secret。公开客户端由 `PublicClientApplicationBuilder` 创建，交互路径按上面的桌面 URI 注册。

**不要创建客户端密码或证书。不要给代理、聊天或游戏文本框输入密码、token、MFA码。** 认证交给微软窗口；WAM 需要可显示 UI 的交互式 Windows 用户会话，不能用服务/提权运行来代替，参见[WAM 集成最佳实践](https://learn.microsoft.com/en-us/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam#integration-best-practices)。

## 2. 委托 API 同意与用户 RBAC 是两件事

在本应用「API 权限 → 添加权限 → Microsoft API → Azure Service Management → 委托的权限」选择 **`user_impersonation`**；若列表布局变化，在 Microsoft API 中搜索该服务。本工程实际只请求 `https://management.azure.com/user_impersonation`；不请求 Microsoft Graph `User.Read` 或应用权限。[Compute REST 的 Security/scopes](https://learn.microsoft.com/en-us/rest/api/compute/virtual-machines/list-all?view=rest-compute-2025-04-01#security)列出该用户委托权限；其生成示例中的 secret/隐式流程不是本项目的认证方案。若新注册自动带有 Graph 权限，本应用不使用，可从此专用注册中去除；委托/应用权限区别、默认 Graph 权限与同意参见[API 权限配置](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-access-web-apis)。

用户能否自行同意取决于组织的[用户同意策略](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent)。遇到「需要管理员批准」应交由该组织审核此应用和确切委托权限，不请求全局管理员身份、不绕过政策。**管理员同意不会给登录用户新增 Azure RBAC 角色。**

云资源权限授予登录的用户/其组，作用域按实际任务限制，不是把角色授予客户端来实现无人值守身份：

- 只读：已有[Reader](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/general#reader)允许读取控制平面，不允许启动/停止。
- 启停：已有[Virtual Machine Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/compute#virtual-machine-contributor)可覆盖本功能，但权限远超启停（包含创建、删除、扩展等），不能称作最小权限。没有必要授予 Owner。
- 更窄角色由组织管理员按[自定义角色](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles)设计并验证。按[Compute 权限表](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/compute#microsoftcompute)，本功能对应 `Microsoft.Compute/virtualMachines/read`、`Microsoft.Compute/virtualMachines/instanceView/read`、`Microsoft.Compute/virtualMachines/start/action`、`Microsoft.Compute/virtualMachines/deallocate/action`；异步状态可能还需 `Microsoft.Compute/locations/operations/read` 等服务实际返回的状态路径读权限，订阅读取需相应 Resources 读权限。**这不是已经在真人环境验证的完整角色模板**，本交付不创建或分配角色。
- 只有 VM 级动作权限时，可能已能提交却无权读区域级操作状态；[ARM 异步操作权限说明](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/async-operations#permission-for-tracking-async-status)要求相应资源组级权限。遇到轮询 403 保留原记录为待核对，不能当成启动失败而重发。

## 3. 公开配置与试玩入口

配置只有 `client_id` 和 `initial_tenant` 两个字段。交付模板为 `{"client_id":"","initial_tenant":"organizations"}`，不含可用 ClientId、secret、token 或账户缓存。

| 运行方式 | 实际配置位置 |
|---|---|
| Godot.NET 源码运行 | 工程根 `azure-settings.json` |
| Windows 导出 | `StarlightInn.exe` **同目录** `azure-settings.json`，不依赖工作目录 |

直接在米拉的「Azure 登记簿」输入 GUID、保存一次即可，以后从上述位置读取，不必每次重填；已连接时先「注销本应用」再修改配置。目录不可写时复制整个 `play/` 到可写位置，不要以管理员身份运行。公开配置仍只有两个字段；没有 `.env`、环境变量密钥或自建磁盘 token cache。

### 记住明确账户与静默恢复

「记住账户与自动登录」默认开启，可在登记簿关闭。关闭不注销当前账户，但会取消在途启动恢复，并禁止下次启动恢复。首次没有档案时显示“请首次手动登录”，不选 Windows 默认账户或缓存第一个账户；**空 ClientId 不调用认证/ARM 网络**。手动首次登录和换账户仍明确选择微软账户。

本应用的元数据档案位于 **`%LOCALAPPDATA%\StarlightInn\Azure\session-profile.v1.bin`**，源码和发布版共用本用户路径，不随 EXE 复制到其他机器。它是 Windows **当前用户 DPAPI** 保护的版本化 JSON 内容（磁盘不是明文 JSON），不是认证缓存；不会随 `play/` 发布。

档案 schema 为 `version`（固定 1）、`auto_login`（布尔）、`client_id`、`initial_tenant`（配置关联）、`home_account_id`（固定账户身份）、`username`（仅显示）、`tenant_id`（实际令牌目录）、`subscription_id`、`subscription_name`。注销成功后身份与目录/订阅字段清空，仅保留版本与自动登录偏好。加载会验证字段集合、版本、长度和身份格式，拒绝额外/重复字段；ClientId 或初始目录配置变化时不能使用旧档案，实际目录必须为有效 GUID，但无需等于初始目录。

恢复实现调用官方 [`GetAccountAsync(identifier)`](https://learn.microsoft.com/en-us/dotnet/api/microsoft.identity.client.iclientapplicationbase.getaccountasync) 精确匹配 [`HomeAccountId.Identifier`](https://learn.microsoft.com/en-us/dotnet/api/microsoft.identity.client.iaccount.homeaccountid)，再对保存的实际目录调用 [`AcquireTokenSilent`](https://learn.microsoft.com/en-us/dotnet/api/microsoft.identity.client.acquiretokensilentparameterbuilder)。MSAL [4.90.1 官方实现](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/blob/4.90.1/src/client/Microsoft.Identity.Client/ClientApplicationBase.cs)会合并 broker 账户并按 home ID 过滤；本应用每次新进程可创建自己的 broker client，不依赖上次进程的对象列表，不用 username 认证或 `OperatingSystemAccount` 回退。已使用实际 MSAL/Broker 4.90.1 依赖编译验证；**尚未进行真人跨进程 WAM 静默往返验证**，WAM 缓存可用性和组织策略仍可能要求手动重新验证。

仅在令牌返回的 home ID、ClientId 与 tenant 全部匹配后建立连接。恢复 ARM 订阅最多读取 10 个安全分页、30 秒限时，必须当前目录实际返回相同 subscription ID，显示名称采用服务端值；不会信任档案范围或选择首个订阅。原订阅不可访问、未找到或查询超时则保留已验证账户，订阅未选择并提示重新选择。身份静默获取另有 30 秒限时；缓存缺失、身份不匹配或要求交互时保持真实 Azure 未连接，显示“需要重新登录”，**不自动启动 WAM/浏览器登录框，也不回退成 demo 已连接**。手动配置、登录、关闭开关、注销与退出均有取消/代次保护，晚到结果不能重新连接或覆盖新选择。

明确登录/换账户、成功切目录和选择订阅会更新当前档案；后台云操作使用原 lease，不改当前档案。恢复只读，不自动查询 VM 清单或启动/停止 VM。「注销本应用」立即断开并清空本进程记住的身份，再分别尝试清空磁盘身份档案、清理本应用 MSAL/WAM 缓存，保留公开配置和开关；不删除 Windows 账户。档案清除失败为 `PROFILE_IO`，缓存清理失败保留清洁错误码（通常 `LOGOUT_CACHE_FAILED`），双重失败为 `LOGOUT_INCOMPLETE`；提示分别说明结果，不掩盖任何失败，不撤销原云操作。本进程不再自动恢复，但磁盘写入失败时旧档案仍可能存在，**不能承诺下次启动不恢复**；请关闭自动登录并确认设置保存成功，或处理本用户目录写权限。可以手动登录，不禁用离线游戏。

**本应用只能通过微软认证，不能也不会保存密码。** token、refresh token、密码、MFA 与 Authorization 不写本应用文件、日志或 GDScript；令牌缓存交由 WAM。浏览器备用仍只能手动选择，本应用不为其序列化磁盘认证缓存；下次静默 WAM 找不到指定账户时要求手动登录，符合[WAM 用户动作与静默获取边界](https://learn.microsoft.com/en-us/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam#integration-best-practices)。

复制 **完整 `play/`**，不要只复制 EXE：其内嵌 PCK 之外仍有 `data_StarlightInn_windows_x86_64/` 的 .NET、MSAL 与原生 broker 依赖；目录名以实际导出产物为准。源码重建使用 Godot 4.7.2 **.NET**、已固定的 SDK 10.0.112、目标 net8.0 和 MSAL/Broker 4.90.1（见 csproj/锁文件），不是普通 Godot 编辑器。

## 4. 旅店内操作

1. HUD 或米拉独立入口打开登记簿。首次/换账户必须明确选择，不取 Windows 默认账户或第一个缓存账户；登录不是自动选择订阅。
2. 点击读取目录；切目录重新对同一选定用户授权，再读取该目录订阅并明确选择。切订阅不重新选账户。
3. 奥伦「云务账簿」刷新真实 VM。每次一页，显示是否还有下一页；名称/资源组/状态筛选仅作用于已加载页。`unknown` 不当作 `stopped`。
4. 选择 VM 后，伊芙「真实资源鉴定」读取同一完整 ResourceId 的属性、标签、instanceView。不会拿原离线样本名称查询。
5. 「启动…」或「停止并解除分配…」先生成 **2 分钟的一次确认**：账户、Tenant、订阅、资源组、VM、完整 ResourceId、动作、当前状态、费用与业务影响全部展示。取消零 POST；确认前再次读取状态，目标/会话已变则拒绝提交。最终初次 POST 发送前再次同步复核期限；慢读取/慢取令牌导致过期也返回 `EXPIRED_CONFIRMATION`，nonce 已消费，零 POST。

原四菜单槽与离线关机预览完整保留；菲恩仍是本地模板，不是联网 AI。离线 `confirm_preview` 永远不是执行真实动作的授权。

## 5. 已受理不等于成功，更不等于可以撤销

[ARM 异步流程](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/async-operations)中 HTTP 202 只表示受理。本实现优先 Azure-AsyncOperation，再 Location，遵守 Retry-After，并独立重新读取 instanceView 后才标成功。`submitted/pending/deferred/unknown` 都不是完成。

- 关闭面板取消旧查询/确认；切订阅、注销不改原操作的身份/目标，也不撤销 Azure 已受理动作。
- 超时、断网、408/5xx 等提交结果不确定时不自动重发 POST；同目标的未决记录禁止再次提交。「继续只读核对」不会重发。
- 内部 `AzureAcknowledged` 只在提交 HTTP 成功响应后设置。未知受理的记录即使后来读到 running/deallocated，仍保持 `unknown`：“目标当前已…，原提交结果仍未知；未自动重发”，不能把本来就运行的 VM 状态当作这次提交成功。已确认受理的 200/202 仍能通过最终实例状态完成；不安全的轮询 URL 保留受理事实但不会收到令牌。
- 操作日志仅本次运行内；退出只停止本地等待，重启不恢复日志。未知结果应在 Azure 门户按原 ResourceId 与活动日志核对，不因本地记录消失而认为未执行。
- 「停止并解除分配」会中断业务；[VM 状态与计费](https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing)区分 allocated/stopped 与 deallocated，解除分配不代表磁盘、IP 等全部免费。本应用不提供 powerOff/restart/delete。

## 6. 常见失败与验证边界

| 状态 | 处理 |
|---|---|
| NOT_CONFIGURED / INVALID_TENANT | 核对本应用 GUID、单/多租户与上面的配置路径 |
| WAM_UNAVAILABLE / WAM_WINDOW_REQUIRED | 保持普通交互式 Windows 桌面运行；如已注册 localhost，可主动选浏览器备用，不自动改系统组件 |
| INTERACTION_REQUIRED / 401 | 主动点击登录以满足微软授权/MFA/同意；后台查询不自行弹窗 |
| RELOGIN_REQUIRED | 静默恢复未完成；公开配置仍在，请手动重新登录，不自动挑其他账户 |
| FORBIDDEN / 403 | 核对当前用户、目录、订阅、目标作用域 RBAC；不自动升权，不能用管理员同意代替 RBAC |
| STALE_CONTEXT / CANCELLED_OR_TIMEOUT | 旧回包已丢弃，可重读清单；已受理操作仍看原记录 |
| unknown / deferred | 只读核对原操作/门户，不盲重发 |

交付已验证真实 MSAL 包编译、Godot.NET 主场景、合成身份/HTTP 安全核心、真实本地控件输入与渲染、旧演示/声音回归。**没有进行真人 WAM 登录、组织同意或真实 Azure VM 写入验收**；合成测试与截图的 fixture 数据不能当作真实云结果。图形会话存在 WASAPI 初始化失败后的引擎自动 Dummy 回退，软件混音通过不代表扬声器试听。

2026-10-09 本轮重新验证仅为离线核心/headless 场景、PCM 文件解析和静态发布包检查；未启动发布 EXE、认证窗口或浏览器，未访问真实 Azure，也未检查音频硬件。以上渲染/图形会话结论为历史记录。headless 桥不读取个人档案并拒绝真实请求；请在普通 Windows 桌面手动试玩完整 `play/`，实际 WAM/组织策略与云启停仍需真实身份后验证。发布已有公开配置原样保留，个人档案不发布。