# 钟誓 · HOLLOW BELL

独立 Godot 4 项目。第一关「雾鸦隘口」。不修改 ForestGlow。

## 完成标准

- 从标题进入游戏，可移动、跳跃、闪避、三段连击、蓄力重击、格挡、回复、暂停与重新开始。
- 穿越林径、断桥、修道院、钟楼四段，激活两个检查点，击败守钟巨像后到达出口完成第一关。
- 恰好八种敌人（含 Boss），各自有逐帧移动/攻击/受击素材、可读前摇和不同攻击逻辑。
- 非写实、无血腥的奇幻战斗；击败敌人后化为金色光尘。
- 使用生成的高精度像素图集、真实 3D 地形/建筑、分层远景、灯光、阴影与空气透视，不以静态图片平移充当动作。
- 原创循环探索曲、Boss 曲、胜利乐句，独立移动/武器/魔法/环境音效；可调音量。
- 自动化覆盖输入、跳跃与边缘容错、战斗有效帧、八种 AI、Boss 阶段、检查点、死亡重生、暂停和通关；导出并启动 Windows EXE。

## 操作

| 操作 | 键鼠 | 手柄 |
|---|---|---|
| 移动 | A/D、左右方向键 | 左摇杆 / 方向键 |
| 跳跃 | Space | A |
| 轻击（三段连击） | J / 鼠标左键 | X |
| 蓄力重击 | K / 鼠标右键，按住蓄力 | Y |
| 闪避 | Shift / L | B |
| 格挡（起手可弹反） | Q | LB |
| 回复 | E | RB |
| 暂停 | Esc | Start |
| 全屏 | F11 | — |

## 敌人与攻击语言

1. 荆棘匍兽 `briar`：低伏蓄力、水平扑击；跳过它或闪避。
2. 锈剑侍卫 `sentinel`：举剑亮刃、近身两连斩；格挡/弹反。
3. 长枪守望 `lancer`：回收长枪、长距离直线突刺；从上方越过。
4. 棘弩猎手 `arbalist`：架弩、瞄准光线、单发弩箭；利用掩体与跳跃。
5. 灯笼司祭 `cantor`：抬灯吟唱、三枚错速弧线光球；打断吟唱。
6. 石翼幼像 `gargoyle`：振翼悬停、锁定位置、斜向俯冲；移动躲开落点。
7. 重锤典狱 `warden`：抬锤停顿、砸地、地面波；跳跃与背后重击。
8. 守钟巨像 `boss`：大幅横扫、跃起落地、钟鸣三重地波；半血进入第二阶段，前摇更短并增加连续段数，不引入第九种怪物。

## 空间与节奏

横向坐标 -8..198，角色脚底 y=0，运动平面 z=0。

- 0..39：雾林与路碑；逐个介绍移动、轻击、闪避。
- 39..85：断桥与猎手；第一个检查点 x=62。
- 85..133：修道院阶台与飞行敌人；第二个检查点 x=133。
- 133..158：重锤守卫与最后补给。
- 158..187：钟楼 Boss 场；战斗时封门。
- 191：已击败 Boss 后触发通关。
- 缺口 39..42、82..85、121..125；坠落损血并回检查点。

## 美术接口

`assets/source/` 只放原始生成图片；素材处理工具生成 `assets/sprites/`、`assets/environment/`。

- 角色图集：1536×1024，严格 6 列 × 4 行，每格 256×256，纯洋红色底转透明。
- 原点：每格脚底约 y=232，人物朝右；Sprite3D offset.y=104，将脚底对齐世界 y=0。
- `hero_motion.png`：idle 0..5 / run 6..11 / jump 12..17 / dodge 18..23。
- `hero_combat.png`：slash_1 0..5 / slash_2 6..11 / slash_3 12..17 / guard,hurt,heavy 18..23。
- 普通敌人与 Boss：idle 0..5 / move 6..11 / attack 12..17 / hurt 18..20 + dissolve 21..23。
- 扩展动作在图集关键姿态之上结合骨架式整体倾角、武器弧线、披风惯性、落地压缩、光效、顿帧与音效，不能只做平移。

## 脚本分工与接口

- `scripts/game.gd`：流程、输入映射、碰撞命中、投射物、检查点、相机。
- `scripts/actor.gd`：共享 CharacterBody3D、帧动画、朝向、受击反馈。
- `scripts/player.gd`：输入、运动与战斗状态机。
- `scripts/enemy.gd`：八类敌人状态机。
- `scripts/world.gd`：3D 环境、碰撞地形、灯与背景；`build()`、`update_world(delta, player_x)`、`close_boss_gate()`、`open_boss_gate()`。
- `scripts/hud.gd`：中文/英文标题、状态、教程、暂停、设置、胜利页。
- `scripts/audio.gd`：`set_music(name)`、`play_sfx(name, pitch=1.0)`、`set_volume(value)`。
- `scripts/effects.gd`：`burst(pos,tint,count)`、`slash(pos,facing,tint,radius)`，打击与环境粒子。

共享 `game` 节点公开：`hero`、`enemies`、`state`、`effects`、`audio`；方法 `hurt_player(damage, from_x, knockback=5.0) -> bool`、`spawn_projectile(origin, direction, kind, damage, speed, owner, tint)`、`spawn_wave(x, direction, damage, owner)`、`shake(strength)`、`on_enemy_defeated(enemy)`。

测试与制作工具仅用于开发，不导出到游戏。音乐、美术均为本项目原创/生成素材；运行不需要网络、账号或 API 密钥。