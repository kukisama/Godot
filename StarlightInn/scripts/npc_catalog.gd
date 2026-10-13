extends RefCounted

const IDS = ["mira", "oren", "eve", "finn"]

const RECORDS: Dictionary = {
	"mira": {
		"id": "mira", "name": "米拉", "title": "旅店主人",
		"capability": "旅店向导", "accent": Color("f4c878"),
		"position": Vector2(825, 392),
		"walk_speed": 83.0, "roam_radius": 380.0,
		"roam_points": [Vector2(715, 470), Vector2(970, 485), Vector2(820, 600), Vector2(670, 555), Vector2(750, 660), Vector2(835, 720)],
		"hellos": ["先坐。事情慢慢讲，汤可不等人。", "想热闹一点，还是找个安静角落？", "不想说话也行，我去擦杯子。"],
		"small_talk": ["杯子有个小缺口……留给我用吧。", "再尝一口。也许不是盐少，是我饿了。", "椅子往里挪一点，省得绊着人。", "都喝上热的了。好，现在轮到我。", "茶又凉了。下回得有人管管我。", "先不夸菲恩，夸早了能唱到明天。"],
		"greeting": "进来吧，先坐。事情可以慢慢讲，汤可不等人。想认认路，还是听听住客们的故事？没想好也不算白来，在我这儿歇会儿。这里的能力都是本地演示。",
	},
	"oren": {
		"id": "oren", "name": "奥伦", "title": "云务管家",
		"capability": "云端投影 · 演示", "accent": Color("65d7e7"),
		"position": Vector2(356, 505),
		"walk_speed": 56.0, "roam_radius": 570.0,
		"roam_points": [Vector2(430, 545), Vector2(505, 625), Vector2(390, 680), Vector2(565, 530), Vector2(750, 660), Vector2(835, 720)],
		"hellos": ["炉边有位子，坐下听椅子抱怨一声就好。", "嗯，来了。有事，还是只想烤烤手？", "慢点走。门槛这一步，不差那一会儿。"],
		"small_talk": ["字写这么小……年轻时候真不体谅人。", "添一块就够，不必非烧得旺。", "账簿没老，拿账簿的人有点意见。", "做个记号。记性好也不用为难自己。", "一件一件说，挤在一起都说不清。", "这回趁热喝，免得米拉又来查。"],
		"greeting": "炉边还有个位子。那把椅子比我年长，坐下时听它抱怨一声就好。账簿里有三盏虚构云灯，全是本地演示数据，没有连接 Azure。我们慢慢翻，也能看看绝不动手的关机预览。",
	},
	"eve": {
		"id": "eve", "name": "伊芙", "title": "星术鉴定师",
		"capability": "资源鉴定 · 演示", "accent": Color("bda2f4"),
		"position": Vector2(1159, 592),
		"walk_speed": 97.0, "roam_radius": 465.0,
		"roam_points": [Vector2(1130, 685), Vector2(1050, 575), Vector2(1300, 625), Vector2(990, 720), Vector2(750, 660), Vector2(835, 720)],
		"hellos": ["先别动！袖口那粒……哦，是面包屑。", "来得正好，我有个更好懂的说法！", "看这里，这粒星砂和旁边不一样。"],
		"small_talk": ["亮得不一样。它们真的不一样！", "不乱！只是还没决定按什么来排。", "少看一项。划掉重写，纸又不会笑我。", "杯子一转，光跑了……茶也跑了。", "先喝一口。米拉已经提醒第三次了。", "原来在这里！值得高兴一下。"],
		"greeting": "先别动，你袖口那粒亮东西……星砂？不对，是面包屑。好，鉴定结束！现在认真欢迎你。我能带你看资源的本地演示属性和标签；它们是虚构样本，不代表真实云端状态。",
	},
	"finn": {
		"id": "finn", "name": "菲恩", "title": "吟游诗人",
		"capability": "AI 对话 · 演示", "accent": Color("94d699"),
		"position": Vector2(417, 785),
		"walk_speed": 110.0, "roam_radius": 475.0,
		"roam_points": [Vector2(575, 775), Vector2(485, 650), Vector2(665, 865), Vector2(530, 900), Vector2(750, 660), Vector2(835, 720)],
		"hellos": ["朋友，今天的开场白归你！", "只想坐坐也行，我会小声一点。", "新曲子，还是替我挑挑毛病？"],
		"small_talk": ["再弹一次，确认不是刚好蒙对。", "空一拍，留点想象……好吧，是忘词。", "椅子听得认真，就是掌声得练练。", "脚步有点重，新朋友走累了啊。", "快乐结尾明天再写，今晚停在这里。", "奥伦说还不错。我就当全场喝彩了！"],
		"greeting": "朋友，来得正好！今天的开场白归你。只想安静坐坐也行，我会小声一点。这次用本地预设回复陪你聊聊，没有调用 AI。你可以点一则故事，也可以写下不超过 280 字的一句话。",
	},
}

const SERVICE_LINES: Dictionary = {
	"mira": {
		"real_greeting": "先坐，目录和订阅我们慢慢看。名字像，也不一定是同一个；你明确选择，我不替你拿主意。",
		"waiting": "先歇一会儿。我等回信，不替你猜结果。",
		"list": "清单放在这里。看清名字，再挑你要的那一项。",
		"empty": "这一页没找到东西。先看返回的说明，不忙着下结论。",
		"failure": "这次没读到，先别急。错误原样留在下面，我们看清楚再说。",
		"cancelled": "好，先收起来。你想好下一步，我们再看。",
	},
	"oren": {
		"real_greeting": "一项一项看，不怕慢。查询真实 VM 后，由你明确选择；这里只读，不启动，也不关停。",
		"waiting": "嗯，等回信。该核对的名字，一项也不省。",
		"list": "账簿翻到这里了。先看清名称和状态，再往下一项走。",
		"empty": "这页没有条目。没有读到，和没有存在，是两回事。",
		"selected": "嗯，目标记好了。选中，不是动手；这里只读。",
		"failure": "这件事，得说清楚。下面是原来的错误，不拿旧账当新结果。",
		"subscription_required": "先把账簿选对。请找米拉读取并明确选择订阅。",
		"cancelled": "嗯，先停在这一页。不赶着重来。",
	},
	"eve": {
		"real_greeting": "先找奥伦选好真实 VM，我再看同一个目标的属性和标签。没读到的那项，就说不知道。",
		"waiting": "等一下，我先看清楚。亮不亮能欣赏，属性可不能猜。",
		"result": "你看这里！属性和标签按返回值列好；缺的那项，不替它编答案。",
		"failure": "这次没读到，先不猜。错误在下面，原话保留。",
		"subscription_required": "先找米拉读取并明确选择订阅，我才知道看哪一份。",
		"target_required": "先找奥伦读取并选择真实 VM。我得看同一个目标，不能随手换一份。",
		"cancelled": "好，收回这次等待。下回从看清目标开始。",
	},
	"finn": {
		"real_greeting": "这一页收起即兴段子，只查询真实资源组。不是 AI 聊天，自由输入已关闭；结果不能编得好看。",
		"waiting": "传话铃响了。这段先留白，等真正的回信。",
		"list": "朋友，这回唱名不押韵。资源组的名字、区域和标签，都按清单来。",
		"empty": "这一页暂时没有登场的名字。我留个空拍，不临时编一位。",
		"failure": "这一段没接上。先不替它圆场，原来的错误就在下面。",
		"subscription_required": "开场前得选好清单。请找米拉读取并明确选择订阅。",
		"cancelled": "好，休止符落在这里。下一段由你决定。",
	},
}


static func get_npc(id: String) -> Dictionary:
	if not RECORDS.has(id):
		return {}
	var record: Dictionary = RECORDS[id]
	return record.duplicate(true)


static func service_line(id: String, kind: String) -> String:
	var lines: Dictionary = SERVICE_LINES.get(id, {})
	return str(lines.get(kind, ""))