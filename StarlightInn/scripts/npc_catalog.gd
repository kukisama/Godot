extends RefCounted

const IDS = ["mira", "oren", "eve", "finn"]

const RECORDS: Dictionary = {
	"mira": {
		"id": "mira", "name": "米拉", "title": "旅店主人",
		"capability": "旅店向导", "accent": Color("f4c878"),
		"position": Vector2(825, 392),
		"greeting": "欢迎来到星灯旅店。把一路的风尘交给门口的铃铛吧，我替你留了靠灯的位置。想认认路，还是听听住客们的故事？这里的能力都是本地演示。",
	},
	"oren": {
		"id": "oren", "name": "奥伦", "title": "云务管家",
		"capability": "云端投影 · 演示", "accent": Color("65d7e7"),
		"position": Vector2(356, 505),
		"greeting": "炉火正好，旅人。我的账簿里有三盏虚构的云灯——全是本地演示数据，没有连接 Azure。我们可以翻翻清单，也可以排演一次绝不动手的关机预览。",
	},
	"eve": {
		"id": "eve", "name": "伊芙", "title": "星术鉴定师",
		"capability": "资源鉴定 · 演示", "accent": Color("bda2f4"),
		"position": Vector2(1215, 567),
		"greeting": "小心桌角的星砂，它们总爱粘住袖口。我能带你看一份资源的本地演示属性和标签；这里的星图是虚构样本，不代表任何真实云端状态。",
	},
	"finn": {
		"id": "finn", "name": "菲恩", "title": "吟游诗人",
		"capability": "AI 对话 · 演示", "accent": Color("94d699"),
		"position": Vector2(417, 785),
		"greeting": "来，给你的故事留半张长椅。我会用本地预设回复陪你聊聊，并没有调用 AI。你可以点一则故事，也可以写下不超过 280 字的一句话。",
	},
}


static func get_npc(id: String) -> Dictionary:
	if not RECORDS.has(id):
		return {}
	var record: Dictionary = RECORDS[id]
	return record.duplicate(true)