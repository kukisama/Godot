# 星灯旅店：离线对话接口

## 当前边界

- 本模块只运行本地 GDScript、内存示例数据和预设文本。没有网络请求、真实 AI/Azure SDK、凭据、环境变量或 `.env`；不保存聊天到磁盘。
- `azure.vm`、`azure.resource`、`ai.chat` 只是分派标识，不是连接配置。虚构名称、区域、规格、状态和标签均不代表真实世界；没有真实订阅 ID。
- 关机流程只有预览。确认后仍返回 `executed=false`、`state_changed=false`、`side_effects=false`，不会修改示例状态，更不会操作真实资源。
- 对话文字、用户输入和历史均为纯文本。UI 必须关闭 BBCode/富文本解析，不能把用户输入解释成标记。
- 本模块不实现大厅、移动、导航、按键、画面、主场景或导出。宿主负责根据 `is_open` 暂停移动，根据 `busy` 禁用提交，并决定 Esc 调用 `choose("back")` 还是 `close()`。

## 脚本与公开接口

均使用 `preload("res://scripts/文件名.gd")`，不依赖全局 `class_name` 缓存。

| 文件 | 基类 | 接口 |
|---|---|---|
| `npc_catalog.gd` | `RefCounted` | `const IDS`；`static get_npc(id: String) -> Dictionary` |
| `capability_provider.gd` | `RefCounted` | `execute(request: Dictionary) -> Dictionary`；合法请求默认返回 `NOT_CONFIGURED` |
| `demo_provider.gd` | `capability_provider.gd` | 同一 `execute` 接口，仅本地演示实现 |
| `capability_port.gd` | `Node` | `request(npc_id: String, capability: String, action: String, arguments: Dictionary = {}) -> String`；`cancel(request_id: String) -> void` |
| `dialogue.gd` | `Node` | `open_for(id: String) -> bool`；`choose(choice_id: String) -> void`；`send_message(message: String) -> void`；`close() -> void` |

`get_npc` 返回深复制的记录；未知 ID 返回 `{}`。记录字段：`id`、`name`、`title`、`capability`（UI 标签）、`accent: Color`、`position: Vector2`、`greeting: String`。

| ID | 姓名 / 职务 | UI 能力标签 | 位置 | 色彩 |
|---|---|---|---|---|
| `mira` | 米拉 / 旅店主人 | 旅店向导 | `(825, 392)` | 暖金 `#f4c878` |
| `oren` | 奥伦 / 云务管家 | 云端投影 · 演示 | `(356, 505)` | 青蓝 `#65d7e7` |
| `eve` | 伊芙 / 星术鉴定师 | 资源鉴定 · 演示 | `(1215, 567)` | 紫 `#bda2f4` |
| `finn` | 菲恩 / 吟游诗人 | AI 对话 · 演示 | `(417, 785)` | 绿 `#94d699` |

### CapabilityPort

- `provider: RefCounted` 默认 `DemoProvider.new()`；`latency_seconds: float = 0.35`，测试使用 `0.01`。
- `request_dispatched(request: Dictionary)` 在 pending 登记后同步发出一次；参数是副本。`request()` 返回唯一编号，随后使用 `SceneTreeTimer` 异步调用提供者，再发 `response_ready(response: Dictionary)`。即使延迟为零或配置无效，也不会在 `request()` 返回前发响应。
- `last_request: Dictionary` 是最近请求的调试副本。调用参数、信号参数、调试副本、实际执行参数相互隔离；嵌套字典/数组也深复制。
- `cancel` 幂等；被取消请求不再执行尚未开始的提供者，已经开始的晚到结果也不再发信号。节点退出场景树时清空 pending。
- 替换 `provider` 会递增版本。在途请求在执行前/执行后发现版本变化，返回原编号、原 NPC 的 `PROVIDER_REPLACED` 错误；不会把旧请求交给新提供者。A → B → A 也视为替换。已取消的请求仍无回包。
- 缺失提供者、错误返回类型、错误 ID/NPC、非法模式、副作用标记、缺少字段都会规范化为错误；UI 不会永久停在 busy。错误编号不规范时使用 `UNKNOWN_ERROR`。
- 本地提供者正常同步返回字典；端口也能等待异步测试替身。契约校验不是任意第三方代码的沙箱，不能凭 `side_effects=false` 证明未知代码没有副作用。

### Dialogue

把 `Dialogue` 实例加到场景树后，`_ready()` 自动将公开的 `port: CapabilityPort` 加为子节点并连接响应。可直接通过 `dialogue.port.latency_seconds` 调整测试延迟，或替换 `dialogue.port.provider`。

公开只读状态（UI 不应直接改写）：

| 字段 | 类型 / 含义 |
|---|---|
| `npc_id`、`is_open`、`busy` | 当前 NPC、对话开关、请求等待状态 |
| `page` | 初始/根页 `root`；本地话题页；目标 `targets`；确认 `confirm`；输入 `input`；等待 `waiting`；回复 `result` |
| `text` | 当前页面纯文本 |
| `choices: Array[Dictionary]` | 每项只有 `id`、`label`；仅接受当前列表中的 ID |
| `allow_input` | 对话打开且 NPC 为菲恩时为 true，其他人/关闭后为 false；busy 时即使 true 也不接受输入 |
| `history: Array[Dictionary]` | 当前 NPC 的聊天条目，`speaker` 为中文姓名或 `旅人`，`text` 为纯文本；最多 60 条 |
| `history_by_npc: Dictionary` | 按 NPC 保存本节点生命周期内的历史，各自最多 60 条；UI 只读 `history` |
| `visited: Dictionary` | 已打开的合法 NPC ID → true |
| `last_request`、`last_response` | 当前打开会话的最近请求/响应副本，供桌面 QA 使用 |
| `pending_request_id` | 等待中的请求编号，无等待时为空字符串 |

- `changed` 在公开操作产生状态变化时发出；非法/旧菜单 ID、busy 输入等无操作不发信号。`closed` 仅在一次真正的关闭时发出；切换 NPC、返回话题、重复关闭不发 `closed`。
- `open_for` 的未知 ID 返回 false，不取消、不覆盖当前会话；合法打开取消旧请求、恢复对应历史、进入根页并记录访问。重复打开同一 NPC 也重新回根页，不重复插入已有历史的欢迎词。
- 合法打开会清空 `last_request` / `last_response`；新请求清空 `last_response`。关闭保留调试字典，但清空当前 `npc_id`、`text`、`choices`、`history` 和 pending，历史缓存仍保留。
- `request_dispatched` 发出时 `request()` 尚未返回；监听该信号应读取其参数。UI/QA 可在随后的 `changed` 中读取完整的 `last_request` 和 `pending_request_id`。
- 非根页含 `back`；它回根话题而非关闭，并取消选定目标。等待页保留该按钮供 UI 显示，但 busy 时禁用；`close()` 始终可以取消等待。
- 自由文字只给菲恩使用，可在其任意非 busy 页面提交。空白或原始长度超过 280 个 Unicode 码点会显示错误而不提交；有效输入去除首尾空白后进入旅人历史，回复进入 NPC 历史。
- 响应必须同时匹配 pending 编号与当前 NPC；取消、关闭、切换后的晚到回复不得进入新会话。

## 菜单 choice IDs

| NPC / 页面 | ID → 含义 |
|---|---|
| 米拉根页 | `guide` → 向导；`residents` → 人物介绍；`legend` → 旅店传说；`goodbye` → 道别 |
| 奥伦根页 | `list_running` → 运行 VM；`list_all` → 全部 VM；`shutdown_preview` → 选择预览目标；`chat` → 本地闲谈 |
| 伊芙根页 | `inspect` → 属性；`tags` → 标签；`explain_resource` → 本地讲解；`goodbye` → 道别 |
| 菲恩根页 | `story` → 故事；`explain_api` → API 讲解；`free_chat` → 输入页；`goodbye` → 道别 |
| 关机目标页 | `target_lantern` → `inn-lantern-01`；`target_library` → `inn-library-02`；`back` → 取消并回根页 |
| 关机确认页 | `confirm_preview` → 仅请求预览；`back` → 取消并回根页 |
| 其他非根页 | `back` → 回根话题（busy 时忽略） |

从根页进入目标页、选中目标、返回或关闭，都不发送关机请求。只有**当前确认页**的 `confirm_preview` 会提交一次 `preview_shutdown`；等待/结果页不接受旧确认 ID。目标仅有两台 running 样本，不包含 stopped 样本。

## 请求 / 响应契约

### 请求

| 字段 | 类型 | 说明 |
|---|---|---|
| `request_id` | `String` | 非空，由端口唯一分配，响应必须原样返回 |
| `npc_id` | `String` | 非空，必须与能力绑定 NPC 相符 |
| `capability` | `String` | 下表机器标识，不是人物目录的中文 UI 标签 |
| `action` | `String` | 下表允许动作 |
| `arguments` | `Dictionary` | 必须存在；没有参数时为 `{}`；未知参数拒绝，不静默忽略 |

| NPC | capability | action | arguments / data |
|---|---|---|---|
| `oren` | `azure.vm` | `list_all` / `list_running` | `{}`；返回 `data.items`、`data.count`、`data.source="local_demo"` |
| `oren` | `azure.vm` | `preview_shutdown` | 必填 `target_id`，仅接受两台 running 样本；返回 `target_id`、`target`、`status`、`executed=false`、`state_changed=false` |
| `eve` | `azure.resource` | `inspect` | 可选 `target_id`，缺省 `inn-lantern-01`；返回 `data.resource`，含 id/name/region/size/status/type/operating_system/tags |
| `eve` | `azure.resource` | `tags` | 同上；返回 `data.target_id` 与 `data.tags` |
| `finn` | `ai.chat` | `chat` | 必填 `message: String`，非空、原始长度不超过 280；返回 `data.input`、`topic="chat"`、`source="local_template"` |
| `finn` | `ai.chat` | `story` / `explain` | `{}`；本地预设故事/API 讲解，`source="local_preset"` |

米拉无能力分派；奥伦闲谈和伊芙概念讲解由对话脚本本地提供。样本为 `inn-lantern-01` / `inn-library-02`（running）、`inn-sleeping-03`（stopped）。响应数据为副本，调用方修改副本不会修改样本。

### 响应

所有响应包含 `request_id: String`、`npc_id: String`（原样匹配请求）、`ok: bool`、`mode: String = "demo"`、`message: String`（可见纯文本）、`data: Dictionary`、`error: Dictionary`、`side_effects: bool = false`。

成功：`ok=true`、`error={}`。失败：`ok=false`、`data={}`、`error={code: String, message: String, details: Dictionary}`；`message` 与错误文字一致。提供者消息明确标注本地演示/预设回复，不宣称 AI 生成或实时云端查询。

错误码：

- 提供者：`NOT_CONFIGURED`、`INVALID_REQUEST`、`UNKNOWN_NPC`、`CAPABILITY_MISMATCH`、`UNSUPPORTED_ACTION`、`INVALID_ARGUMENTS`、`INVALID_TARGET`、`EMPTY_MESSAGE`、`MESSAGE_TOO_LONG`。
- 端口：`PORT_NOT_READY`、`INVALID_PROVIDER`、`PROVIDER_REPLACED`、`RESPONSE_MISMATCH`、`INVALID_RESPONSE`、`UNSAFE_RESPONSE`、`UNKNOWN_ERROR`。
- 自定义提供者合规的错误码和字典 `details` 会保留；非结构化未知错误规范化为 `UNKNOWN_ERROR`。不匹配 ID/NPC 的原包丢弃，并向原请求发出规范化错误，避免 UI 卡住。

## 未来扩展点（本轮不实现）

宿主可以替换 `port.provider`，保持请求身份、错误结构和取消语义不变。本轮的端口强制 `mode="demo"` 和 `side_effects=false`，因此**不支持直接接入真实服务**。未来真实适配需另行设计服务端鉴权、授权、最小权限、错误处理以及与演示模式明确分离的 UI/协议；客户端不放凭据。预览确认不是实际写操作的授权，也不能在未来自动升级成执行命令。本文件不提供真实云操作实现。

## 独立测试

PowerShell 命令：`& 'C:\Users\kukisama\AppData\Local\Programs\Godot\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe' --headless --path 'C:\Users\kukisama\Downloads\Scripts\Godot\StarlightInn' --script res://tests/test_dialogue.gd`

测试入口为 `SceneTree`，`_initialize()` 延迟调用 `run()`，自行创建 Dialogue 并加入 root。不载入 `game.gd` / `main.tscn`，不使用 `--editor`，不启动 GUI、不导出。使用事件等待及单次超时守卫，无外部轮询。

覆盖目录深复制、四 NPC 所有分支、返回/告别、非法/旧选项、输入边界、纯文本、60 条历史、确认前无请求、取消确认、预览状态不变、错误回包、关闭/切换晚到响应、请求深复制、提供者替换和响应规范化。每条断言明确计数；成功打印 `DIALOGUE_TESTS: n passed, 0 failed` 并退出 0；失败打印具体断言并退出 1。

Godot 4.7.2 实测注意：`changed` 可以嵌套在 `response_ready` 回调内，测试统计其他响应监听器之前需等当前派发结束（本测试等待一次 `process_frame`，并非轮询）；不要在对象自己的信号回调中直接 `free()`，应使用 `queue_free()`。测试另校验八个分组全部执行到末尾，防止函数被运行时错误中断后误报成功。