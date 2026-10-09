# 星灯旅店：原生 WAM 与 Azure 权限

本版本是普通 Godot + C++/WinRT 的 Windows 桌面公开客户端，只有登录用户的 ARM 委托权限。已有公开 `azure-settings.json` 原样保留；迁移没有创建应用、借用其他软件 ClientId/token 或执行云端授权。

## 与旧版不同之处

- 不再使用 .NET/MSAL/Broker DLL，不再提供浏览器备用，不监听 localhost。此版本不需要新增 `http://localhost`；已有该 URI 也不会使用，是否移除由注册所有者决定。
- Win32 WAM 仍注册 `ms-appx-web://microsoft.aad.brokerplugin/{client_id}`（换成本应用实际 GUID）。微软 Win32 适配实现区分 client ID 与 UWP SID，参见[微软 WAM 适配源码](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/blob/4.49.1/src/client/Microsoft.Identity.Client/Platforms/Features/WamBroker/WamAdapters.cs)。本工程不是 UWP/Store 应用，不要求 Store/MSIX 关联。
- 父窗口是游戏的真实 HWND，helper 验证其属于实际父进程。所用[Win32 WAM interop](https://learn.microsoft.com/en-us/windows/win32/api/webauthenticationcoremanagerinterop/nn-webauthenticationcoremanagerinterop-iwebauthenticationcoremanagerinterop)最低 build 20348；运行时 QI 失败返回 WAM_UNAVAILABLE，不承诺所有 Windows 10 都支持，不自动打开浏览器。
- 首次与换账户使用用户主动发起的 [ForceAuthentication](https://learn.microsoft.com/en-us/uwp/api/windows.security.authentication.web.core.webtokenrequestprompttype) 请求；不静默挑首个/默认 Windows 账户。该枚举要求用户凭据交互，不等于已真人验证账户选择界面，具体界面与组织策略须自测。

## 注册与同意

仅使用本应用自己的[Entra 应用注册](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)，平台为移动和桌面。单租户初始目录填应用 TenantId GUID，多租户可填 organizations 或入口目录 GUID；跨目录由[账号类型与组织策略](https://learn.microsoft.com/en-us/entra/identity-platform/single-and-multi-tenant-apps)决定。`initial_tenant` 是入口，不是本地实际目录允许列表；保存的实际来宾目录 B 可不同于入口 A。

不创建 secret/证书，不启用隐式流，不为修复认证启用 ROPC/设备代码等未实现流程；[桌面公开客户端配置](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration)中的公共客户端流开关不能与桌面 URI 混淆。密码/MFA 只由真人在微软认证窗口输入，绝不交给聊天或 GD 输入框。

应用 API 权限为 Azure Service Management 的委托 `user_impersonation`；实际请求 ARM scope 加 WAM 身份辅助 openid/profile，不调用 Graph、不请求应用级权限。[Compute REST scopes](https://learn.microsoft.com/en-us/rest/api/compute/virtual-machines/list-all?view=rest-compute-2025-04-01#security)给出 ARM 委托权限。组织[用户同意政策](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent)可能要求管理员批准；同意不是给用户授予 RBAC。

- 只读用户可使用已有 [Reader](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/general#reader)。
- [VM Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/compute#virtual-machine-contributor)覆盖启停但权限远超最小，不默认授予 Owner。
- 更窄角色由组织按[Compute 权限表](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/compute#microsoftcompute)审核 read、instanceView/read、start/action、deallocate/action，以及订阅与区域操作状态读权限；这不是已真人验证的完整角色模板。轮询可能需[相应资源组级权限](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/async-operations#permission-for-tracking-async-status)，轮询 403 不得当未受理后重发。

## 配置与档案

公开配置仅 `client_id` / `initial_tenant`。源码读取工程根，发布读取游戏 EXE 同目录，与 CWD 无关；helper 固定位于 `native/`，自身从父目录读取同一配置。米拉登记簿保存 GUID 一次即可，已连接先注销再修改。无 .env、环境密钥或本应用磁盘令牌缓存。

v2 元数据路径：`%LOCALAPPDATA%\StarlightInn\Azure\session-profile.v2.bin`，Windows 当前用户 DPAPI 加密，schema 为 version=2、auto_login、client_id、initial_tenant、native_account_id、provider、username、tenant_id、subscription_id、subscription_name。native_account_id 是原生不透明 WebAccount.Id，**不是 MSAL home_account_id**。v1 原文件保留但不读取/删除/转换，升级首次手动登录。

恢复只对[精确 WebAccount](https://learn.microsoft.com/en-us/uwp/api/windows.security.authentication.web.core.webauthenticationcoremanager.findaccountasync)做[带账户的静默请求](https://learn.microsoft.com/en-us/uwp/api/windows.security.authentication.web.core.webauthenticationcoremanager.gettokensilentlyasync)，核对返回账户/provider/ClientId/实际目录与 ARM scope，不以用户名认证。订阅最多 10 页、30 秒重新验证，找不到则保留已验证账户但要求重选；身份失败保持断开、不弹窗。开关关闭取消恢复，不注销当前账户。

注销先清内存，再分别尝试清空磁盘身份和[仅本应用 SignOutAsync(clientId)](https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.webaccount.signoutasync)，不移除 Windows 账户。PROFILE_IO / LOGOUT_CACHE_FAILED / LOGOUT_INCOMPLETE 分别报告单独/双重失败；磁盘失败不能承诺下次不恢复。

## 云操作安全与验收

同 Job ID 的迟到回包替换旧 journal 缓存；已确认终态不被较旧 submitted/pending 快照回退。该顺序边界另以生产 GD 桥接内存注入断言验证，不伪称真实云操作已成功。

排队的 login/restore 在协议 reader 入队时捕获 Core 认证代次；Core 在保护认证状态的同一锁内检查该代次，然后才重置取消标志并启动身份调用。取消登录、关闭查询/窗口、注销断开、关闭自动登录均失效旧任务，返回原请求 ID 的 `CANCELLED_OR_TIMEOUT`，不是静默删队列等到 UI 超时。reader 已执行的取消不会在队列中的注销/偏好保存时再失效后来的新手动意图；明确 configure 仍可执行，但不能复活旧登录。这些行为以合成身份调用计数、并发条件变量和真实私有管道屏障验证，未验证真人 WAM 交互。

GD 收到 execute 的 OperationRecord 时立即按原 Job ID 留存，不依赖 helper 的 reply/journal 发送顺序；空 journal 不会清掉未决记录。执行请求超时立即生成包含已知原账户/目录/订阅/目标的 unknown 本地记录，并隔离写入；迟到回包只用于原记录核对，不复活已超时 UI 请求。已出站执行请求或未决 submitted/pending/unknown/deferred 在异常断线后保持隔离，同一游戏进程重启 helper 也不能 prepare/execute。未出站且随关闭清掉的请求、明确提交前拒绝和真正 failed/succeeded 可正确放行；unknown 不能靠当前资源状态冒充成功。游戏退出后记录不持久化，仍需核对原资源，不能将重启当作安全重发依据。

prepare 不发 POST；完整上下文/目标/影响确认有效两分钟、一次消费，执行重新读取状态，并在取令牌后紧贴发送检查 TTL。401 最多调用[InvalidateCacheAsync](https://learn.microsoft.com/en-us/uwp/api/windows.security.authentication.web.core.webtokenrequestresult.invalidatecacheasync) 后对同一账户静默获取并重试一次，重试仍检查 TTL/上下文。超时/断网/5xx 不重发。

遵循[ARM 异步流程](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/async-operations)：202 仅受理，轮询绑定原租约/ResourceId，unknown 不因当前 running 而变成功；关闭、注销、退出不撤销云动作，操作记录仅本次运行。停止解除分配不代表磁盘/IP 全免费，见[状态与计费](https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing)。本应用没有 restart/delete/powerOff。

本轮仅原生编译、工厂 QI（无 token 请求）、合成核心、真实 GD→独立合成 helper 管道、headless 游戏/声音软件回归、PCM 和静态发布校验。生产 headless 不启动 helper、不读个人档案。没有 GUI、真人 WAM/浏览器认证、真实 Azure 读写或声卡检查；真实账号选择、跨进程恢复、租户属性、同意/RBAC 与云操作必须由用户在正常 Windows 桌面自测。
