# 星灯旅店 · Starlight Inn

中世纪幻想旅店，四位可以交谈的住客。原大厅、美术、导航、四槽离线对话与声音保持不变；真实 Azure 使用独立入口。

## 交付与操作

复制完整 `play/`：`StarlightInn.exe`、`native/StarlightAzure.exe`、公开 `azure-settings.json` 及三份说明文档。不需要安装 .NET、MSAL、VC 运行库、PowerShell 或 Azure CLI。`Play.ps1` 只是源码目录的可选启动入口，玩家可直接启动 EXE。便携包为 `StarlightInn-Windows.zip`。

WASD/方向键移动，Shift 加速，点地面/NPC 寻路，E/Enter 交谈，鼠标/1–4 选择，Esc 关闭，J/F1 手记，M 静音，F11 全屏。声音默认开启。米拉讲旅店，奥伦和伊芙原四槽仍是虚构资源演示；菲恩仍是本地模板回复，不是联网 AI。

## 原生 Azure

- 游戏使用普通 Godot 4.7.2 + GDScript，独立 `/MT` C++/WinRT helper 通过 `OS.execute_with_pipe` 的私有标准流通信。没有 TCP localhost 服务、浏览器 fallback 或 PowerShell 运行依赖。
- 令牌仅在 helper/WAM/Windows HTTP 内；不交给 GD、不放 argv/env/临时文件/日志。协议只有安全 DTO，无任意 REST/token getter。
- 首次/换账户由用户主动发起 WAM 强制交互认证；恢复使用保存的原生 `WebAccount.Id` 精确查找，并验证 ClientId、provider、实际目录。初始目录不是实际目录限制。真人选择界面与组织策略尚未验收。
- v2 档案位于 `%LOCALAPPDATA%\StarlightInn\Azure\session-profile.v2.bin`，当前用户 DPAPI 保护，仅偏好、账户/目录/订阅元数据。旧 v1 MSAL 档案不读取、不删除、不自动迁移，升级后首次需手动登录。
- 只访问国际 ARM。真实 VM 查询、启动/停止解除分配在独立登记簿/账簿内；配置与最小权限见 `AAD_SETUP.md`。
- 确认有效 2 分钟，一次消费，重新读目标后、令牌获取后紧贴发送再次检查 TTL/上下文。明确 401 最多失效缓存并静默重试一次；超时/断网/5xx 不自动重发 POST。
- 202/submitted/pending 不是成功；保留原租约核对原目标。受理未知即使读到 running 仍 unknown，禁止重复提交；操作记录仅本次进程内，退出不撤销云操作。
- execute 回包中的原操作立即记入本地记录，不等待 journal；空/部分 journal 不清掉未决记录。执行请求超时立即隔离，已出站请求或未决操作在 helper 断线后保留原身份/目标及 unknown；同一游戏进程内重启 helper 仍禁止 prepare/execute。明确提交前拒绝与已确认 failed/succeeded 不永久阻塞。退出游戏不会持久保存这些记录，也不代表云操作没执行。
- 排队 login/restore 使用 reader 捕获的认证代次，Core 在同一锁内验证后才开始认证；取消登录、关闭查询、注销断开及关闭自动登录均使旧任务失效并返回同 ID 取消回复，之后的新手动登录仍有效。此边界只做了合成身份/HTTP 验证，不是已真人验证 WAM 界面。
- 注销立即断开本进程，分别尝试清空磁盘元数据和 `SignOutAsync(clientId)` 本应用缓存，不删除 Windows 账户；任何清理失败均报告。
- 生产 headless 模式在启动 helper 前拒绝请求，不读个人档案、不认证、不访问 ARM。

## 重建与离线验证

项目内 `tools/godot-standard/` 保留经官方 SHA512 校验的普通编辑器与模板，不改变全局 Godot/.NET/系统设置。原生重建入口 `native/build.ps1` 使用已有 VS2022 x64 Build Tools、Windows SDK、`/MT /W4 /WX`，生成生产 helper、共享核心测试与独立编译的管道夹具，输出 `qa/native-build/`。发布只复制生产 helper，不含夹具。

| 本轮离线测试 | 通过 / 失败 |
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

GDScript 测试通过普通引擎 `--headless --path <工程> --script res://tests/<测试>.gd` 执行；`tests/test_native_pipe.gd` 唯一显式选择独立合成 helper。`tests/check_audio.ps1` 仅解析文件、不播放。`tests/verify_native_export.ps1` 默认仅静态验包：PE 导入、所有 PCK 条目完整性、38 纹理/9 音频、发布/ZIP 白名单与哈希，绝不启动 EXE。旧 `test_export.ps1` 已归档，没有默认 GUI 探测入口。

实测体积、SHA256、资源不变校验和发布证据见 `qa/native-release-verification.json`；轻量修复摘要为 `qa/native-final-verification.json`，旧报告仅归档为 `qa/native-release-verification.previous.json`，不能用旧哈希验证本次 ZIP。旧发布与源码完整备份为 `qa/legacy-dotnet/`（374 文件哈希清单），活跃 C#/.NET 工程及旧说明另移至 `archive/dotnet/`；两处均不导入、不发布。

本轮未启动 GUI 试玩、WAM/浏览器认证、真实 Azure 读写或声卡排查。软件混音通过不是实体试听；真人 WAM 登录、跨进程静默恢复、组织同意与真实云启停留待用户自测。重点 review：原生账户/实际目录返回属性、父 HWND 绑定、取消/EOF、最终 TTL、401 与 unknown 防重发、原租约轮询、DPAPI 和缓存清理失败。
