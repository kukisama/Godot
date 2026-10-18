# 林间拾光 · Forest Glow

一个 Godot 4 / GDScript 鼠标小游戏，用来演示生成素材、透明精灵、点击反馈和完整游玩流程。

## 打开

- **直接玩**：双击本目录的 [`play/ForestGlow.exe`](./play/ForestGlow.exe)，游戏资源已嵌入 EXE。
- **编辑项目**：在 Godot 中导入 [`project.godot`](./project.godot)，点击编辑器的运行按钮。
- 本机实测版本为 Godot `4.7.2`。项目不含 C#、联网服务或运行时 API 密钥。

## 玩法

45 秒内收集至少 36 点微光，即可获胜。所有操作都用鼠标左键。

| 目标 | 效果 |
| --- | --- |
| 橙色果实 | +1 点 |
| 蓝色果实 | +2 点 |
| 金色星星 | +5 点 |
| 灰色孢子 | 扣 4 秒、清空连击 |
| 每连续采集 5 次 | 额外 +2 点 |

果实消失前未收集会清空连击；放过孢子没有惩罚。点空地不扣分。右上角可以暂停和静音，切换到其他窗口会自动暂停。结算后可重玩或返回首页。

最佳分数保存在 Godot 的 `user://best.cfg`，不写入项目素材目录。

## 图片素材

背景和精灵图集均实际使用 **`gpt-image-2.5-flare`** 生成，没有用程序绘制图标替代生成素材。

- [`assets/source/forest.png`](./assets/source/forest.png)：原始森林背景。
- [`assets/source/sprites.png`](./assets/source/sprites.png)：原始 3 列 × 2 行品红底图集。
- `assets/sprites/`：自动切出的橙果、蓝果、星星、孢子、闪光、叶片，共 6 张透明 PNG，均为 256 × 256。
- [`tools/slice_assets.gd`](./tools/slice_assets.gd)：分格、品红去底、边缘去色、透明边界裁剪、等比缩放并居中留白；保留原图，可重复切割。

用 Godot 控制台入口，以本目录为 `--path`，添加 `--headless --script res://tools/slice_assets.gd` 可重建切图；之后执行 `--headless --editor --import` 重新导入资源。正常试玩无需运行切图脚本。

音效由 [`scripts/game.gd`](./scripts/game.gd) 合成，包括采集、奖励、误点和胜利提示；没有外部音频依赖。

## 测试与导出

- [`tests/test_game.gd`](./tests/test_game.gd) 向真实 Viewport 注入鼠标事件，不直接调用采集回调来代替输入验证。
- 2026-10-08 实测：**31 项检查，0 失败**。覆盖资源、开始、三种计分、连击、空点、右键、静音、暂停、弹窗阻挡、胜负、重玩、失焦暂停、生成槽位和完整一局。
- 运行测试：Godot 控制台入口以本目录为 `--path`，添加 `--headless --script res://tests/test_game.gd -- --test-mode`；测试不会改写个人最佳分数。
- [`export_presets.cfg`](./export_presets.cfg) 已配置 `Windows Desktop`，产物位于 `play/ForestGlow.exe`。重新导出需安装与编辑器版本匹配的 Windows 模板。
- Windows 导出成功；显式 ANGLE 的有界窗口运行退出码为 0。本机原生 OpenGL 不足时会自动回退 ANGLE，此项不代表其他机器的性能测试。
- 用户已实际试玩并反馈“可以玩，还不错”。当前版本保留，不继续扩展玩法。