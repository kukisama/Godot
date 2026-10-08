extends RefCounted
## Only these eight enemy kinds are present in Chapter I.

const ENEMIES := {
	"briar": {"name": "荆棘匍兽", "hp": 48.0, "speed": 3.4, "range": 3.6, "windup": 0.65, "recovery": 0.8, "cooldown": 1.5, "damage": 13.0, "pixel_size": 0.012, "height": 1.15, "tint": Color(0.67, 0.81, 0.40)},
	"sentinel": {"name": "锈剑侍卫", "hp": 78.0, "speed": 2.0, "range": 2.0, "windup": 0.62, "recovery": 0.65, "cooldown": 1.6, "damage": 12.0, "pixel_size": 0.013, "height": 2.0, "tint": Color(0.80, 0.67, 0.39)},
	"lancer": {"name": "长枪守望", "hp": 82.0, "speed": 1.8, "range": 4.2, "windup": 0.9, "recovery": 1.0, "cooldown": 1.8, "damage": 19.0, "pixel_size": 0.014, "height": 2.25, "tint": Color(0.63, 0.83, 0.74)},
	"arbalist": {"name": "棘弩猎手", "hp": 52.0, "speed": 1.65, "range": 9.0, "windup": 1.1, "recovery": 0.75, "cooldown": 2.1, "damage": 14.0, "pixel_size": 0.013, "height": 1.7, "tint": Color(0.86, 0.69, 0.35)},
	"cantor": {"name": "灯笼司祭", "hp": 65.0, "speed": 1.4, "range": 8.2, "windup": 1.2, "recovery": 1.05, "cooldown": 2.6, "damage": 12.0, "pixel_size": 0.014, "height": 2.1, "tint": Color(0.44, 0.86, 0.81)},
	"gargoyle": {"name": "石翼幼像", "hp": 48.0, "speed": 2.6, "range": 6.5, "windup": 0.9, "recovery": 0.9, "cooldown": 2.0, "damage": 15.0, "pixel_size": 0.012, "height": 1.4, "tint": Color(0.68, 0.81, 0.82)},
	"warden": {"name": "重锤典狱", "hp": 130.0, "speed": 1.05, "range": 3.2, "windup": 1.25, "recovery": 1.3, "cooldown": 2.2, "damage": 24.0, "pixel_size": 0.017, "height": 2.9, "tint": Color(0.90, 0.68, 0.36)},
	"boss": {"name": "守钟巨像 · 奥尔登", "hp": 760.0, "speed": 1.75, "range": 4.7, "windup": 1.05, "recovery": 1.15, "cooldown": 1.5, "damage": 23.0, "pixel_size": 0.023, "height": 4.15, "tint": Color(1.0, 0.74, 0.32)}
}

const SPAWNS := [
	{"kind": "briar", "x": 19.0},
	{"kind": "sentinel", "x": 30.0},
	{"kind": "briar", "x": 35.0},
	{"kind": "lancer", "x": 49.0},
	{"kind": "arbalist", "x": 57.0},
	{"kind": "sentinel", "x": 71.0},
	{"kind": "arbalist", "x": 77.0},
	{"kind": "cantor", "x": 94.0},
	{"kind": "briar", "x": 99.0},
	{"kind": "gargoyle", "x": 108.0},
	{"kind": "lancer", "x": 114.0},
	{"kind": "gargoyle", "x": 129.0},
	{"kind": "warden", "x": 143.0},
	{"kind": "cantor", "x": 151.0},
	{"kind": "boss", "x": 175.0}
]

const CHECKPOINTS := [Vector3(5, 0.1, 0), Vector3(62, 0.1, 0), Vector3(133, 0.1, 0)]
const GAPS := [Vector2(39, 42), Vector2(82, 85), Vector2(121, 125)]
const ZONES := [
	{"x": 0.0, "name": "雾林古道", "subtitle": "THE PILGRIM'S ROAD"},
	{"x": 40.0, "name": "断桥回声", "subtitle": "ECHOES OF THE AQUEDUCT"},
	{"x": 87.0, "name": "无声修道院", "subtitle": "THE SILENT ABBEY"},
	{"x": 157.0, "name": "最后一声钟鸣", "subtitle": "THE LAST BELL"}
]