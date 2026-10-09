# 星灯旅店 · Starlight Inn

一间中世纪幻想旅店，四位可以交谈的住客。独立 Godot 4 工程，不依赖 ForestGlow / HollowBell。

## 试玩

- Windows 程序：`play/StarlightInn.exe`。
- 本机推荐入口：`Play.ps1`，使用 ANGLE 渲染，**声音默认开启**。
- 离线旅店不需要账户或网络。真实 Azure 的公开 ClientId 保存一次即可，见 `AAD_SETUP.md`；启动不弹登录框，可静默恢复上次明确选择的账户。
- 复制完整 `play/`（含 .NET/MSAL/原生依赖目录），不能只复制 EXE。
- 便携包：本目录 `StarlightInn-Windows.zip`，解压得到完整 `play/`；本轮未自动启动试玩。
- 导入 Godot **.NET 4.7.2** 时选择本目录的 `project.godot`。

## 操作

| 输入 | 行为 |
|---|---|
| WASD / 方向键 | 四向移动 |
| Shift | 加快移动 |
| 点地面 / NPC | 寻路过去；接近 NPC 后自动交谈 |
| E / Enter | 与附近的住客交谈 |
| 鼠标 / 1–4 | 选择当前对话选项 |
| Esc | 关闭当前手记或对话；取消行走目标 |
| J / F1 | 旅人手记 / 操作指南 |
| M | 静音 / 恢复声音；输入文字时不触发 |
| F11 | 全屏 / 窗口 |

## 四位住客

- **米拉**：旅店向导、住客介绍和星灯传说。
- **奥伦**：虚构虚拟机清单、运行状态与关机流程预览。
- **伊芙**：虚构资源属性、标签与概念讲解。
- **菲恩**：小故事、API 讲解、最多 280 字的自由输入及本地模板回复。

**原四槽菜单仍为严格离线演示，真实 Azure 使用额外独立入口。**
原关机“确认预览”不改变示例状态，更不是实际操作授权。
聊天记录按 NPC 隔离，只保留在本次运行内。接口契约见 `API.md`。

## 真实 Azure（用户委托，默认未配置）

- 米拉额外「Azure 登记簿」：WAM 首选、明确选择的浏览器备用、目录与订阅选择；HUD 显示当前真实身份。
- 默认开启「记住账户与自动登录」：首次需手动选账户；以后只尝试静默恢复固定 home account ID 与实际目录，再从当前目录的订阅列表（最多 10 页）验证原订阅。找不到订阅只提示重选，身份失败显示“需要重新登录”，不自动打开认证窗口。
- 初始目录仅为授权入口，不代表注册账号类型或本地租户允许列表；多租户可初始 GUID A、实际来宾 B，重启只恢复保存的 B，仍严格匹配配置、home ID、ClientId 与返回目录。单租户跨目录限制由 Entra 执行，见 `AAD_SETUP.md`。
- 关闭开关并成功保存后禁止下次恢复，不注销当前账号。「注销本应用」立即断开并清空本进程身份，分别清理磁盘档案和本应用缓存，保留 ClientId/初始目录/开关，不删除 Windows 账户。档案失败 `PROFILE_IO`、缓存失败通常 `LOGOUT_CACHE_FAILED`、双失败 `LOGOUT_INCOMPLETE`，提示分别说明结果；磁盘写入失败时旧档案仍可能存在，下次可能尝试恢复，请关闭自动登录并确认保存成功，或处理写权限，不承诺已全部清理。
- 公开 `azure-settings.json` schema 仍为 `client_id` / `initial_tenant`，发布版读取 EXE 同目录。本用户档案位于 `%LOCALAPPDATA%\StarlightInn\Azure\session-profile.v1.bin`，当前用户 DPAPI 保护，schema：`version`、`auto_login`、`client_id`、`initial_tenant`、`home_account_id`、`username`（只显示）、`tenant_id`、`subscription_id`、`subscription_name`。不保存密码或 token，不把档案打进发布包。
- 奥伦额外「云务账簿」：真实 VM 分页、筛选、启动/停止并解除分配；执行前完整身份/ResourceId 二次确认。
- 伊芙额外「真实资源鉴定」：同一选定 VM 的属性、标签和 instanceView。
- 菲恩仍纯本地模板。真实入口没有 demo 回退，不请求 Graph、secret、CLI 账户或应用级权限。
- HTTP 202 不等于成功；关闭/注销/退出不撤销已受理云操作。记录保留原上下文，仅本次运行内；不确定受理即使读到目标状态仍为 unknown，并阻止重复 POST。最终发送前复核确认 TTL，慢读取/取令牌导致过期也零 POST。
- 注册与最小权限说明见 `AAD_SETUP.md`。本交付未进行真人 WAM/Azure 云写验收。

## 美术与声音

- 在游戏代码实现前，用 Image 2.5 制作 5 张原图，再加工成 38 张游戏素材。
- 采用一张预渲染大厅背景、正交 3D 舞台、像素人物 billboard、投影、灯火、浮尘和轻景深，属于固定镜头 HD-2D 风格，不是可旋转的完整 3D 旅店模型。
- NPC 对话头像取自同一人物原图。原始生成图保留于 `assets/source/`。
- 主角右行原图中第 3 帧反向的问题，在 `tools/prepare_art.ps1` 中作确定性修正；原图不覆盖。
- 9 个原创合成 WAV：3 种木地板脚步、对话开合、选项、回信、鲁特琴短句及循环炉火。声音随位置变化，聊天时适当压低，失焦时暂停。
- 本轮已验证样本、触发和软件混音；按用户安排，实体设备试听与性能体验另行验证。没有强制使用 Dummy 音频驱动。

## 回归与重建

Godot.NET 4.7.2 / net8.0，SDK 固定 10.0.112，MSAL/Broker 4.90.1；Windows Desktop 导出预设，PCK 内嵌、.NET 依赖另带。发布产物位于 `play/`，测试输出位于 `qa/`。

| 验证入口 | 当前结果 |
|---|---|
| `tests/bridge/BridgeTests.csproj` | 112 通过，0 失败（原 100 + 新 12）；合成身份/HTTP，链接生产核心与真实 MSAL；含 DPAPI 合成档案、来宾 B 重启恢复、注销独立／双重失败及恢复竞态 |
| `tests/test_azure.gd` | 本轮 headless 140 通过，0 失败；33 次 viewport 控件点击，合成授权/ARM；含启动恢复中断、开关、注销、输入隔离及 headless 拒绝真实请求 |
| `tests/test_game.gd` | 5112 通过，0 失败 |
| `tests/test_facing.gd` | 504 通过，0 失败；检查图片里可见头朝向，不只检查帧名 |
| `tests/test_dialogue.gd` | 423 通过，0 失败 |
| `tests/test_sound.gd` | 436 通过，0 失败；包含非零软件混音及资源释放 |
| `tests/check_audio.ps1` | 248 通过，0 失败；独立解析 PCM 波形 |
| `tests/test_export.ps1 -StaticOnly` | 本轮静态验证 16 项产物、DLL/文档哈希、自包含 net8.0、MSAL 锁定版本、公开配置和个人档案排除；133 个内嵌 PCK 条目摘要完整，38 个纹理/9 个音频与当前导入数据 SHA256 相同；C# 为四个换行占位、实际实现核验 DLL；不启动 EXE、不加载个人档案 |

GDScript 回归通过 Godot 的 `--headless --path <本目录> --script res://tests/<测试名>.gd` 运行。
核心测试用 `dotnet run --project tests/bridge/BridgeTests.csproj -c OfflineReleaseQA --no-restore`（独立输出，避免旧 Debug DLL 锁）。发布锁文件对应 `dotnet restore StarlightInn.csproj --locked-mode -p:Configuration=ExportRelease -r win-x64`，生产发布构建加 `-c ExportRelease -r win-x64 --no-restore`。Debug 编辑器依赖使用独立 `-p:NuGetLockFilePath=qa/editor-packages.lock.json` 恢复并锁定，随后 `dotnet build StarlightInn.csproj --no-restore`；核心项目单独 `dotnet restore tests/bridge/BridgeTests.csproj --locked-mode`。本轮两个生产配置均为 0 警告、0 错误。
Windows 发布用 Godot.NET 的 `--headless --path <本目录> --export-release "Windows Desktop" play/StarlightInn.exe`。导出后仅运行 `tests/test_export.ps1 -StaticOnly`，结果在 `qa/azure-release-static-verification.json`；已有公开配置原样保留，缺失才复制模板。默认不带开关的旧发布测试会启动 GUI，**本轮未运行**。
本轮日志为 `qa/offline-*.log`，汇总为 `qa/release-validation.json`；所有上述回归（含 PCM 248 项）均重新执行，38 张制作 PNG 与 9 个 WAV 未改。headless 生产桥只使用内存档案，拒绝真实请求，避免测试启动阶段读取个人档案或触发认证/ARM；正常桌面恢复不变。
既有 ANGLE 136 项、截图及 EXE READY 验证仅为历史结果，不代表当前发布版图形验收。本轮没有 GUI、浏览器、真人认证、真实 Azure 网络/写操作或音频硬件检查。真实 WAM 静默路径此前按[官方固定 ID 查找 API](https://learn.microsoft.com/en-us/dotnet/api/microsoft.identity.client.iclientapplicationbase.getaccountasync)与[MSAL 4.90.1 broker 实现](https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/blob/4.90.1/src/client/Microsoft.Identity.Client/ClientApplicationBase.cs)核对；本轮真实包编译通过、身份均为合成夹具，没有进行真人跨进程 WAM 静默往返，真实登录与云启停留待用户测试。
图像重建用 `tools/prepare_art.ps1`；声音重建用 `tools/synthesize_audio.ps1`，均为本地制作，不重新发起生图请求。
前者基于本机 PowerShell 7.6 / .NET 10 绘图运行库；不要求玩家安装制作工具。

`tests/desktop_check.ps1` 只允许操作本项目导出的 EXE。前台输入和定向窗口消息是不同验收模式，不能混称为物理键鼠测试。
可选 `-- --qa-state=<绝对路径>` 启用本地诊断记录；仅此模式下 F12 可保存真实渲染帧。正常试玩无需启用。