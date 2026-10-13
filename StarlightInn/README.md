# 星灯旅店 · Starlight Inn

中世纪幻想旅店，四位会散步、打招呼和交谈的住客。未登录保留完整离线演示，登录后在原 NPC 对话框直接查询真实 Azure，只读、无 AI。

## 2026-10-09 · 听声音认识住客

- 米拉温柔但有主见，奥伦慢条斯理、带点冷幽默，伊芙好奇且讲证据，菲恩爱表演也懂得留白；招呼、自言自语和资源查询都有各自的口吻。
- 游走增加公共落脚点。住客相距约 190 像素、地板范围内视线相通时，会停步面向彼此，自动开始交流；不会隔着大厅或非地板区域喊话。
- 六组双人闲聊、四组三人剧场和两段四人剧场共 12 段。优先选择附近人数最多的场景，一次一组、轮流发言，每句在说话者头顶显示约两秒，结束后继续散步；有全场和剧本冷却，不反复刷同一段。
- 玩家交谈、点选参与者或打开指南、手记、Azure 登记簿会中断剧场；旧泡泡立即清除，不在关闭界面后补播。
- 日常台本见 `NPC_DIALOGUE.md`，两秒短句版在 `scripts/npc_scenes.gd`；定向验证入口为 `tests/test_npc_conversations.gd`。资源口吻只包装说明，真实名称、ID、状态、标签和错误原样保留；闲聊不触发 AI、认证或云操作。

## 2026-10-09 · 活起来的酒馆

- 使用 `gpt-image-2.5-sunburst`、`high` 质量新增 9 张母版：四位住客多动作图集、主角八帧步态图集、初晓/白昼/夕照/夜泊四种大厅光景。
- 四位 NPC 各有 32 张四向走路帧与 8 张表情/手势；主角每方向 8 帧，步态跟随实际速度。奥伦慢步拄杖、伸腰点头，年轻住客会欢快小跳，米拉会挥手迎客。
- 住客会随机闲逛、避开家具、玩家和彼此，偶尔自然寒暄。点选的住客会停下来等你；正在交谈的住客不会走开。闲聊只在本机发生，不调用 AI 或 Azure。
- 四种背景自动平滑流转，一轮约五分钟。`T` 或左上光景按钮可提前切换；灯晕、窗光、余烬、浮尘和杯口热气持续变化，人物也随同一时钟改变光色。
- 母版在 `assets/source/lively/`。`tools/prepare_lively_art.ps1` 从整张图识别完整人物轮廓，不再按不可靠的等分行裁断头脚；保留原比例，统一缩放和脚底基线。米拉、菲恩的左右行按实际人物朝向映射。
- 人物逐帧检查总览在 `qa/art-review/`，修复前对照在其 `before/` 子目录。生产切片共 192 张，连同头像、背景及原有道具为 210 张生产 PNG。定向行为验证入口为 `tests/test_lively.gd`，已有 `test_game.gd` 与 `test_facing.gd` 同步更新为八帧契约。
- 本轮交付验包入口为 `tests/verify_lively_export.ps1`，结果写入 `qa/lively-package-verification.json`，核对 210 张纹理、原有 9 段声音、全部四向八帧、六文件 ZIP 和公开配置哈希。窗口关闭会先释放场景再退出；有界启动验证使用 `--qa-exit-after=<秒>`，让音频线程完成清理。

## 2026-10-09 认证修复与当前验收

- 修复对同一 WinRT 请求重复调用 `wait_for()` 导致重复注册完成回调的问题；实际延迟异步操作对照复现旧代码 `0x80000018`，新实现只注册一次，保留取消和超时。
- WAM 请求采用 AzureRM-rust 相同的 scope-only v2 配方：ARM `user_impersonation` 与 `openid profile offline_access`，不混用 `resource`。
- 成功回包明确显示“已登录”、账户和下一步选择订阅；长诊断可换行。真实 API 错误不回退演示数据。
- 四位住客直接在原对话框查询：米拉目录/订阅，奥伦 VM，伊芙 VM 属性/标签，菲恩资源组。目录、订阅、VM 必须明确选择，分页可继续读取；注销恢复演示。当前界面没有真实写操作。
- 当前定向验证：原生等待/共享核心、实际私有管道、登记簿与 NPC 路由均通过，发布包六文件与最新构建匹配，用户公开配置保持不变。
- 已在真实桌面发起 WAM 并验证取消返回；账户选择或 MFA 需要本人完成，尚未确认真实登录成功及 ARM 查询。以下历史离线记录不作为当前登录成功证据。

## 交付与操作

复制完整 `play/`：`StarlightInn.exe`、`native/StarlightAzure.exe`、公开 `azure-settings.json` 及三份说明文档。不需要安装 .NET、MSAL、VC 运行库、PowerShell 或 Azure CLI。`Play.ps1` 只是源码目录的可选启动入口，玩家可直接启动 EXE。便携包为 `StarlightInn-Windows.zip`。

WASD/方向键移动，Shift 加速，点地面/NPC 寻路，E/Enter 交谈，鼠标/1–4 选择，Esc 关闭，J/F1 手记，M 静音，T 切换光景，F11 全屏。声音默认开启。未登录时四位住客仍提供原演示；HUD 登记簿用于公开配置及 WAM 登录。登录后：米拉查询目录/订阅，并由用户明确选择订阅；奥伦查询、翻页和明确选择真实 VM；伊芙读取同一 VM 属性/标签；菲恩查询、翻页查看真实资源组。结果及错误直接显示在原对话框，等待时可返回取消，注销后恢复演示。真实模式关闭自由输入，不提供启动/停止/执行按钮。

## 原生 Azure

- 游戏使用普通 Godot 4.7.2 + GDScript，独立 `/MT` C++/WinRT helper 通过 `OS.execute_with_pipe` 的私有标准流通信。没有 TCP localhost 服务、浏览器 fallback 或 PowerShell 运行依赖。
- 令牌仅在 helper/WAM/Windows HTTP 内；不交给 GD、不放 argv/env/临时文件/日志。协议只有安全 DTO，无任意 REST/token getter。
- 首次/换账户由用户主动发起 WAM 强制交互认证；恢复使用保存的原生 `WebAccount.Id` 精确查找，并验证 ClientId、provider、实际目录。初始目录不是实际目录限制。真人选择界面与组织策略尚未验收。
- v2 档案位于 `%LOCALAPPDATA%\StarlightInn\Azure\session-profile.v2.bin`，当前用户 DPAPI 保护，仅偏好、账户/目录/订阅元数据。旧 v1 MSAL 档案不读取、不删除、不自动迁移，升级后首次需手动登录。
- 只访问国际 ARM。当前玩家入口仅目录、订阅、VM 属性/标签和资源组查询；配置见 `AAD_SETUP.md`。下列写操作契约为保留的 native 兼容机制，不是当前 UI 功能。
- 确认有效 2 分钟，一次消费，重新读目标后、令牌获取后紧贴发送再次检查 TTL/上下文。明确 401 最多失效缓存并静默重试一次；超时/断网/5xx 不自动重发 POST。
- 202/submitted/pending 不是成功；保留原租约核对原目标。受理未知即使读到 running 仍 unknown，禁止重复提交；操作记录仅本次进程内，退出不撤销云操作。
- execute 回包中的原操作立即记入本地记录，不等待 journal；空/部分 journal 不清掉未决记录。执行请求超时立即隔离，已出站请求或未决操作在 helper 断线后保留原身份/目标及 unknown；同一游戏进程内重启 helper 仍禁止 prepare/execute。明确提交前拒绝与已确认 failed/succeeded 不永久阻塞。退出游戏不会持久保存这些记录，也不代表云操作没执行。
- 排队 login/restore 使用 reader 捕获的认证代次，Core 在同一锁内验证后才开始认证；取消登录、关闭查询、注销断开及关闭自动登录均使旧任务失效并返回同 ID 取消回复，之后的新手动登录仍有效。此边界只做了合成身份/HTTP 验证，不是已真人验证 WAM 界面。
- 注销立即断开本进程，分别尝试清空磁盘元数据和 `SignOutAsync(clientId)` 本应用缓存，不删除 Windows 账户；任何清理失败均报告。
- 生产 headless 模式在启动 helper 前拒绝请求，不读个人档案、不认证、不访问 ARM。

## 重建与离线验证

项目内 `tools/godot-standard/` 保留经官方 SHA512 校验的普通编辑器与模板，不改变全局 Godot/.NET/系统设置。原生重建入口 `native/build.ps1` 使用已有 VS2022 x64 Build Tools、Windows SDK、`/MT /W4 /WX`，生成生产 helper、共享核心测试与独立编译的管道夹具，输出 `qa/native-build/`。发布只复制生产 helper，不含夹具。

| 云端历史离线测试 | 通过 / 失败 |
|---|---|
| 原生共享核心 | 286 / 0（非历史 C# 112 项） |
| 实际 Godot→独立夹具私有管道及生产桥接边界 | 175 / 0 |
| Azure 主场景/真实本地 Controls（假身份/ARM） | 142 / 0 |
| 游戏完整回归 | 5112 / 0 |
| 可见人物朝向 | 504 / 0 |
| 离线对话 | 423 / 0 |
| 声音触发/软件混音/释放 | 436 / 0 |
| 独立 PCM 文件分析 | 248 / 0 |

合计 **7326 / 0**。修复前新增用例实际捕获核心 215 通过 / 2 失败、管道 60 通过 / 12 失败，证据为 `qa/review-baseline-core.log` / `qa/review-baseline-pipe.log`；追加迟到终态边界修复前为 173 通过 / 2 失败（`qa/review-late-terminal-before.log`）。修复后结果为各 `qa/offline-native-*.log`。真实管道夹具先经共享 Execute 完成一次合成 POST，再以条件变量阻断 journal/退出；排队取消同样使用队列屏障，不依赖睡眠时序。DPAPI 仅测试项目内随机命名的合成档案，未读取个人档案。

GDScript 测试通过普通引擎 `--headless --path <工程> --script res://tests/<测试>.gd` 执行；`tests/test_native_pipe.gd` 唯一显式选择独立合成 helper。`tests/check_audio.ps1` 仅解析文件、不播放。`tests/verify_native_export.ps1` 保留为旧认证修复的静态验包入口：PE 导入、所有 PCK 条目完整性、38 纹理/9 音频、发布/ZIP 白名单与哈希，绝不启动 EXE。扩展动画后的本轮交付使用上面的 `tests/verify_lively_export.ps1`。旧 `test_export.ps1` 已归档，没有默认 GUI 探测入口。

实测体积、SHA256、资源不变校验和发布证据见 `qa/native-release-verification.json`；轻量修复摘要为 `qa/native-final-verification.json`，旧报告仅归档为 `qa/native-release-verification.previous.json`，不能用旧哈希验证本次 ZIP。旧发布与源码完整备份为 `qa/legacy-dotnet/`（374 文件哈希清单），活跃 C#/.NET 工程及旧说明另移至 `archive/dotnet/`；两处均不导入、不发布。

上表是云端历史离线记录；当时未启动 GUI、WAM/浏览器认证或真实 Azure 读写。当前修复和桌面验收范围见本文开头；软件混音通过仍不代表实体试听。
