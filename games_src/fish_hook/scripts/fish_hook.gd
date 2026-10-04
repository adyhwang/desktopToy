extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 钓鱼 Fish Hook：下方岸坡（木桶/鱼竿/饵盒）+ 上方三层水体（表层/中层/底层）
## 流程：木桶选打窝饵 → 点击水面打窝（饵团抛出落水缓缓下沉，窝点内咬钩率大增）
##       塑料盒选钩饵（挂在钩上，影响不同稀有度鱼的咬钩率）→ 点鱼竿选浮漂深度（表层/中层/底层）
##       → 点击水面抛竿，饵钩沉到浮漂深度所在水层 → 鱼咬钩（浮漂下沉抖动）
##       → 按住左键向下拖鼠标"拔河"（下拉距离=拉力），拉力压过鱼力则把鱼往岸边拉，
##         鱼力连续 5 秒大于拉力 → 鱼线断裂（鱼饵丢失）；拉到岸边即钓起
## 鱼群：全部鱼类全层活动（任何深度都可能咬钩），但在各自"舒适水层"咬钩率最高（RARITY.comf 倍率）
## 远水加成：抛竿落点离岸越远，稀有度越高咬钩率加成越大（RARITY.far，常见/垃圾不受影响）
## 空钩规则：不挂鱼饵时只有垃圾（旧靴子/鱼骨）会咬钩，挂饵才会吸引正常鱼类
## 钓起展示：居中放大 3 倍展示，下方显示"鱼名·稀有度"标签（稀有度按 RARITY_COL 着色）；
## 史诗/神话鱼从鱼身向外放射五颜六色的太阳光式光芒（画在鱼下层，不被鱼身挡住）
## 稀有度六档统一管理咬钩参数（RARITY 表）：常见/普通/稀有/传说/史诗/神话（垃圾 boot/fishbone 单独 junk 档）
## 鱼种 61 种（KINDS 表，贴图 assets/<id>.png，旧素材前缀 fish_）：
##   常见 12：白条/鲫鱼/鲤鱼/草鱼/鲢鱼/鳊鱼/罗非鱼/丁桂鱼/鲳鱼/黄花鱼/梭鱼/金鱼 + 虾/青蛙
##   普通 4：泥鳅/白条鱼/麦穗鱼/螃蟹  稀有 23：鲶鱼/黑鱼/鳜鱼/鳙鱼/青鱼/翘嘴/三文鱼/鳕鱼/河豚/甲鱼等
##   传说 5：箭毒鱼/巨骨舌鱼/冰鱼/南极鳕鱼/皇带鱼  史诗 9：金枪鱼/旗鱼/马林鱼/电鳗/海马/锦鲤等
##   神话 5：金龙/腔棘鱼/电鳗王/龙鱼/鲛人/鲲  垃圾：旧靴子/鱼骨（负分+断连击）
## 分值：常见 1-5 → 普通 4 → 稀有 6-9 → 传说 13-16 → 史诗 19-24 → 神话 30-40；垃圾负分
## 连击：连续钓到鱼加成 ×1→×3 封顶，钓到垃圾或断线清零
## 纯鼠标操作；HUD/排行榜/按钮排与合集统一，素材程序生成（GenFishingSprites.cs）

const GameHud := preload("res://scripts/game_hud.gd")

enum State { IDLE, CAST, SINK, WAIT, BITE, FIGHT, LAND, REEL }

# —— 布局（屏幕比例）——
const Y_WATER_TOP := 0.14      # 水面顶（天空/远景带下沿）
const Y_SHORE := 0.80          # 岸线（水体下沿）

# —— 拔河参数 ——
const BITE_WINDOW := 10       # 咬钩反应窗口兜底值（s）；实际按咬钩鱼稀有度 RARITY.window 取值
const BREAK_T := 2.2           # 拉力超出红线（上/下任一）的容忍时长（s），超时断线
const PULL_RANGE := 0.22       # 拉力满值下拉鼠标距离（vp.y 比例）
const REEL_RATE := 0.30        # 拉力-鱼力差 → 上岸进度速率（1/s）
const RUN_SPD := 0.20          # 爆发冲刺横移速率（vp.x/s）
const RUN_MAX := 0.12          # 冲刺横移上限（vp.x）
const LAND_T := 2.5            # 钓起拉近展示时长（s，含 0.4s 拉近；居中放大 3 倍展示）
const LAND_MOVE_T := 0.4       # 展示结束飞向左上角钓获列表的时长（s）
const LAND_SHRINK_T := 0.35    # 垃圾缩小段时长（s）：3 倍缩小到 1 倍，然后在水岸之上丢出
const CAST_T := 1.5            # 抛竿总时长（s）：0.5s 后仰蓄力 + 1.0s 前挥抛物线飞行
const CAST_WIND_T := 0.5       # 抛竿后仰蓄力时长（s）
const REELIN_T := 0.7          # 自动收杆时长（s）：吐钩/断线后程序收杆回待机
# —— 打窝 ——
const CHUM_R := 0.15           # 窝点半径（min 边比例）
const CHUM_LIFE := 30.0        # 窝点持续（s）
const CHUM_SINK_T := 1.4       # 饵团落水下沉时长（s）
const CHUM_FLY_T := 0.55       # 饵团抛出飞行时长（s）
const CHUM_MAX := 4            # 同时存在的窝点上限
# —— 稀有度配置（咬钩基率/舒适层倍率/槽位权重/反应窗口/窝点敏感度统一按稀有度管理）——
# 常见、普通、稀有、传说、史诗、神话、垃圾
# bite   咬钩基率：该稀有度每秒基础咬钩概率（舒适水层再乘 comf）
# comf   舒适层咬钩倍率：鱼位于舒适水层时 bite×此值，其他水层 ×1（全层活动但舒适层概率最高）；-1=全层同率
# slot   槽位权重：鱼群槽位刷新池按稀有度加权（越稀有越难刷出）
# window 咬钩反应窗口（s）：稀有度越高留给玩家按住拔河的反应时间越短
# chum   窝点敏感度：窝点加成对该稀有度的有效系数（1=全额；越稀有的鱼越吃窝，垃圾最不吃窝）
# far    远水加成：落水点离岸越远咬钩率越高，倍率 = 1 + 距岸比例 × far（0=不受距离影响，稀有鱼加成更大）
const RARITY := {
	"common":    {"bite": 0.0021, "comf": 2.0, "slot": 5.0, "window": 10.0, "chum": 0.9, "far": 0.0},
	"uncommon":  {"bite": 0.0015, "comf": 2.2, "slot": 3.0, "window": 9.0,  "chum": 1.0, "far": 0.15},
	"rare":      {"bite": 0.00085, "comf": 2.4, "slot": 1.6, "window": 8.0,  "chum": 1.1, "far": 0.35},
	"legendary": {"bite": 0.00055, "comf": 2.6, "slot": 0.8, "window": 7.0,  "chum": 1.2, "far": 0.55},
	"epic":      {"bite": 0.0003, "comf": 2.8, "slot": 0.4, "window": 6.0,  "chum": 1.35, "far": 0.75},
	"mythic":    {"bite": 0.00009, "comf": 3.0, "slot": 0.12, "window": 5.0, "chum": 1.5, "far": 1.0},
	"junk":      {"bite": 0.006, "comf": 1.0, "slot": 1.2, "window": 10.0, "chum": 0.5, "far": 0.0},
}
# 稀有度显示色（开发者强制鱼种按钮/提示用，纯色扁平）
const RARITY_COL := {
	"common": Color(0.85, 0.87, 0.85),
	"uncommon": Color(0.50, 0.90, 0.50),
	"rare": Color(0.45, 0.70, 1.00),
	"legendary": Color(0.75, 0.50, 1.00),
	"epic": Color(1.00, 0.72, 0.30),
	"mythic": Color(1.00, 0.40, 0.45),
	"junk": Color(0.62, 0.56, 0.50),
}
# 开发者强制稀有度循环列表（首项 ""=跟随自然概率，其余对应 RARITY 档位）
const DEV_RARS := ["", "common", "uncommon", "rare", "legendary", "epic", "mythic", "junk"]

# —— 鱼种：value 分值 / layer 出现水层(0表1中2底，-1=大鱼中底层随机，-2=全层随机)
#            rar 稀有度(查 RARITY) / comf 舒适水层(-1=全层同率)
#            r 显示半径(min边比) str 基础鱼力 burst 爆发增幅
const KINDS := {
	"minnow": {"rar": "common", "value": 1, "layer": 0, "comf": 0, "r": 0.030, "str": 0.30, "burst": 0.22, "tex": "fish_minnow.png"},
	"crucian": {"rar": "common", "value": 3, "layer": 1, "comf": 1, "r": 0.046, "str": 0.48, "burst": 0.35, "tex": "fish_crucian.png"},
	"carp": {"rar": "common", "value": 5, "layer": -1, "comf": 1, "r": 0.066, "str": 0.62, "burst": 0.45, "tex": "fish_carp.png"},
	"golden": {"rar": "common", "value": 5, "layer": 2, "comf": 2, "r": 0.060, "str": 0.58, "burst": 0.55, "tex": "fish_golden.png"},
	"grasscarp": {"rar": "common", "value": 4, "layer": 1, "comf": 1, "r": 0.058, "str": 0.55, "burst": 0.38, "tex": "grasscarp.png"},
	"silvercarp": {"rar": "common", "value": 3, "layer": 1, "comf": 1, "r": 0.056, "str": 0.50, "burst": 0.35, "tex": "silvercarp.png"},
	"bream": {"rar": "common", "value": 3, "layer": 1, "comf": 1, "r": 0.054, "str": 0.48, "burst": 0.30, "tex": "bream.png"},
	"tilapia": {"rar": "common", "value": 3, "layer": 1, "comf": 0, "r": 0.052, "str": 0.50, "burst": 0.36, "tex": "tilapia.png"},
	"tench": {"rar": "common", "value": 4, "layer": 2, "comf": 2, "r": 0.050, "str": 0.52, "burst": 0.34, "tex": "tench.png"},
	"pomfret": {"rar": "common", "value": 3, "layer": 1, "comf": 1, "r": 0.052, "str": 0.46, "burst": 0.28, "tex": "pomfret.png"},
	"yellowcroaker": {"rar": "common", "value": 4, "layer": 1, "comf": 1, "r": 0.048, "str": 0.50, "burst": 0.32, "tex": "yellowcroaker.png"},
	"mullet": {"rar": "common", "value": 3, "layer": 1, "comf": 0, "r": 0.054, "str": 0.52, "burst": 0.36, "tex": "mullet.png"},
	"puffer": {"rar": "rare", "value": 9, "layer": 1, "comf": 1, "r": 0.055, "str": 0.62, "burst": 0.65, "tex": "fish_puffer.png"},
	"shrimp": {"rar": "common", "value": 2, "layer": 2, "comf": 2, "r": 0.040, "str": 0.32, "burst": 0.20, "tex": "fish_shrimp.png"},
	"frog": {"rar": "common", "value": 2, "layer": 0, "comf": 0, "r": 0.038, "str": 0.30, "burst": 0.42, "tex": "fish_frog.png"},
	"loach": {"rar": "uncommon", "value": 4, "layer": 2, "comf": 2, "r": 0.034, "str": 0.36, "burst": 0.44, "tex": "fish_loach.png"},
	"crab": {"rar": "uncommon", "value": 3, "layer": 2, "comf": 2, "r": 0.044, "str": 0.42, "burst": 0.38, "tex": "fish_crab.png"},
	"bleak": {"rar": "uncommon", "value": 4, "layer": 0, "comf": 0, "r": 0.040, "str": 0.44, "burst": 0.42, "tex": "bleak.png"},
	"gudgeon": {"rar": "uncommon", "value": 4, "layer": 1, "comf": 1, "r": 0.036, "str": 0.42, "burst": 0.40, "tex": "gudgeon.png"},
	"catfish": {"rar": "rare", "value": 8, "layer": 2, "comf": 2, "r": 0.064, "str": 0.72, "burst": 0.42, "tex": "catfish.png"},
	"yellowcat": {"rar": "rare", "value": 7, "layer": 2, "comf": 2, "r": 0.054, "str": 0.66, "burst": 0.44, "tex": "yellowcat.png"},
	"snakehead": {"rar": "rare", "value": 9, "layer": 2, "comf": 2, "r": 0.062, "str": 0.78, "burst": 0.48, "tex": "snakehead.png"},
	"mandarinfish": {"rar": "rare", "value": 9, "layer": 2, "comf": 2, "r": 0.056, "str": 0.74, "burst": 0.52, "tex": "mandarinfish.png"},
	"bighead": {"rar": "rare", "value": 8, "layer": 1, "comf": 1, "r": 0.068, "str": 0.70, "burst": 0.38, "tex": "bighead.png"},
	"blackcarp": {"rar": "rare", "value": 8, "layer": -1, "comf": 2, "r": 0.064, "str": 0.74, "burst": 0.42, "tex": "blackcarp.png"},
	"culter": {"rar": "rare", "value": 8, "layer": 1, "comf": 0, "r": 0.058, "str": 0.72, "burst": 0.50, "tex": "culter.png"},
	"rainbowtrout": {"rar": "rare", "value": 8, "layer": 1, "comf": 1, "r": 0.056, "str": 0.70, "burst": 0.54, "tex": "rainbowtrout.png"},
	"seabream": {"rar": "rare", "value": 7, "layer": 1, "comf": 1, "r": 0.052, "str": 0.66, "burst": 0.44, "tex": "seabream.png"},
	"grouper": {"rar": "rare", "value": 9, "layer": 2, "comf": 2, "r": 0.060, "str": 0.76, "burst": 0.46, "tex": "grouper.png"},
	"flounder": {"rar": "rare", "value": 7, "layer": 2, "comf": 2, "r": 0.058, "str": 0.62, "burst": 0.30, "tex": "flounder.png"},
	"mackerel": {"rar": "rare", "value": 7, "layer": 1, "comf": 1, "r": 0.054, "str": 0.68, "burst": 0.50, "tex": "mackerel.png"},
	"hairtail": {"rar": "rare", "value": 7, "layer": 1, "comf": 1, "r": 0.056, "str": 0.66, "burst": 0.46, "tex": "hairtail.png"},
	"salmon": {"rar": "rare", "value": 8, "layer": 1, "comf": 1, "r": 0.060, "str": 0.72, "burst": 0.56, "tex": "salmon.png"},
	"cod": {"rar": "rare", "value": 7, "layer": 2, "comf": 2, "r": 0.058, "str": 0.68, "burst": 0.42, "tex": "cod.png"},
	"ray": {"rar": "rare", "value": 9, "layer": 2, "comf": 2, "r": 0.068, "str": 0.70, "burst": 0.36, "tex": "ray.png"},
	"betta": {"rar": "rare", "value": 7, "layer": 0, "comf": 0, "r": 0.048, "str": 0.58, "burst": 0.60, "tex": "betta.png"},
	"arcticcod": {"rar": "rare", "value": 8, "layer": 2, "comf": 2, "r": 0.056, "str": 0.66, "burst": 0.40, "tex": "arcticcod.png"},
	"poisonfish": {"rar": "legendary", "value": 13, "layer": 1, "comf": 0, "r": 0.052, "str": 0.82, "burst": 0.62, "tex": "poisonfish.png"},
	"arapaima": {"rar": "legendary", "value": 15, "layer": 2, "comf": 2, "r": 0.076, "str": 0.88, "burst": 0.55, "tex": "arapaima.png"},
	"icefish": {"rar": "legendary", "value": 14, "layer": 2, "comf": 2, "r": 0.044, "str": 0.70, "burst": 0.50, "tex": "icefish.png"},
	"antarcod": {"rar": "legendary", "value": 13, "layer": 2, "comf": 2, "r": 0.060, "str": 0.80, "burst": 0.44, "tex": "antarcod.png"},
	"oarfish": {"rar": "legendary", "value": 16, "layer": 1, "comf": 1, "r": 0.070, "str": 0.86, "burst": 0.48, "tex": "oarfish.png"},
	"tuna": {"rar": "epic", "value": 20, "layer": -1, "comf": 1, "r": 0.070, "str": 0.94, "burst": 0.58, "tex": "tuna.png"},
	"sailfish": {"rar": "epic", "value": 22, "layer": 1, "comf": 0, "r": 0.072, "str": 0.96, "burst": 0.60, "tex": "sailfish.png"},
	"marlin": {"rar": "epic", "value": 24, "layer": 1, "comf": 0, "r": 0.074, "str": 0.98, "burst": 0.62, "tex": "marlin.png"},
	"eel": {"rar": "epic", "value": 21, "layer": 2, "comf": 2, "r": 0.062, "str": 0.92, "burst": 0.66, "tex": "eel.png"},
	"seahorse": {"rar": "epic", "value": 19, "layer": 1, "comf": 1, "r": 0.044, "str": 0.60, "burst": 0.35, "tex": "seahorse.png"},
	"discus": {"rar": "epic", "value": 19, "layer": 1, "comf": 1, "r": 0.054, "str": 0.78, "burst": 0.50, "tex": "discus.png"},
	"piranha": {"rar": "epic", "value": 20, "layer": 1, "comf": 1, "r": 0.052, "str": 0.90, "burst": 0.72, "tex": "piranha.png"},
	"lungfish": {"rar": "epic", "value": 19, "layer": 2, "comf": 2, "r": 0.060, "str": 0.86, "burst": 0.44, "tex": "lungfish.png"},
	"kingsalmon": {"rar": "epic", "value": 22, "layer": 1, "comf": 1, "r": 0.068, "str": 0.96, "burst": 0.58, "tex": "kingsalmon.png"},
	"koi": {"rar": "epic", "value": 21, "layer": 0, "comf": 0, "r": 0.062, "str": 0.84, "burst": 0.46, "tex": "koi.png"},
	"goldendragon": {"rar": "mythic", "value": 15, "layer": -2, "comf": -1, "r": 0.075, "str": 1.0, "burst": 1.0, "tex": "fish_dragon.png"},
	"coelacanth": {"rar": "mythic", "value": 30, "layer": 2, "comf": 2, "r": 0.074, "str": 1.0, "burst": 0.60, "tex": "coelacanth.png"},
	"eelking": {"rar": "mythic", "value": 32, "layer": 2, "comf": 2, "r": 0.070, "str": 1.0, "burst": 0.72, "tex": "eelking.png"},
	"arowana": {"rar": "mythic", "value": 30, "layer": 1, "comf": 1, "r": 0.070, "str": 1.0, "burst": 0.58, "tex": "arowana.png"},
	"mermaid": {"rar": "mythic", "value": 35, "layer": -2, "comf": -1, "r": 0.072, "str": 1.0, "burst": 0.60, "tex": "mermaid.png"},
	"kun": {"rar": "mythic", "value": 40, "layer": -2, "comf": -1, "r": 0.085, "str": 1.0, "burst": 0.55, "tex": "kun.png"},
	"turtle": {"rar": "rare", "value": 6, "layer": 2, "comf": 2, "r": 0.056, "str": 0.72, "burst": 0.30, "tex": "fish_turtle.png"},
	"fishbone": {"rar": "junk", "value": -1, "layer": -2, "comf": -1, "r": 0.048, "str": 0.15, "burst": 0.08, "tex": "fishbone.png"},
	"boot": {"rar": "junk", "value": -2, "layer": -2, "comf": -1, "r": 0.052, "str": 0.18, "burst": 0.09, "tex": "boot.png"},
}
const GARBAGE := ["boot", "fishbone"]   # 垃圾（rar=junk 全层同率咬钩；统计/图鉴过滤用）


## 大型鱼/高稀有判定：钓起欢呼音效（r 大或稀有度 rare 以上）
func _is_big(kind: String) -> bool:
	return (KINDS[kind].rar in ["rare", "legendary", "epic", "mythic"])

# —— 钩饵：mult=各稀有度咬钩率倍数（缺省 0.8）；空钩（none）只有垃圾会咬钩；tint=复用鱼贴图染色（小鱼饵）——
const BAITS := {
	"none": {"tex": "", "mult": {}},   # 空钩：只有垃圾（junk）会咬钩，junk 倍率 1.0
	"worm": {"tex": "bait_worm.png", "mult": {"common": 1.6, "uncommon": 1.4, "rare": 1.1, "legendary": 0.9, "epic": 0.8, "mythic": 0.6, "junk": 1.2}},
	"corn": {"tex": "bait_corn.png", "mult": {"common": 0.7, "uncommon": 1.6, "rare": 1.8, "legendary": 1.2, "epic": 0.9, "mythic": 0.5, "junk": 1.0}},
	"greenfish": {"tex": "fish_minnow.png", "tint": Color(0.6, 1.0, 0.68), "mult": {"common": 0.3, "uncommon": 1.6, "rare": 2.2, "legendary": 2.4, "epic": 2.0, "mythic": 2.4, "junk": 0.6}},
	"crucianfry": {"tex": "fish_crucian.png", "tint": Color(1.0, 0.72, 0.72), "mult": {"common": 0.3, "uncommon": 1.4, "rare": 2.4, "legendary": 2.2, "epic": 2.2, "mythic": 2.6, "junk": 0.6}},
	"shrimp_bait": {"tex": "fish_shrimp.png", "tint": Color(1.0, 0.88, 0.95), "mult": {"common": 0.4, "uncommon": 1.5, "rare": 1.6, "legendary": 1.8, "epic": 1.6, "mythic": 1.6, "junk": 0.6}},
	"apple": {"tex": "bait_apple.png", "mult": {"common": 0.6, "uncommon": 1.2, "rare": 1.0, "legendary": 1.1, "epic": 1.0, "mythic": 0.6, "junk": 1.0}},
	"caterpillar": {"tex": "bait_caterpillar.png", "mult": {"common": 1.9, "uncommon": 1.0, "rare": 0.8, "legendary": 0.8, "epic": 0.7, "mythic": 0.5, "junk": 1.0}},
	"strawberry": {"tex": "bait_strawberry.png", "mult": {"common": 0.6, "uncommon": 1.2, "rare": 1.3, "legendary": 1.2, "epic": 1.1, "mythic": 1.3, "junk": 1.0}},
}
const BAIT_ORDER := ["worm", "corn", "greenfish", "crucianfry", "shrimp_bait", "apple", "caterpillar", "strawberry"]

# —— 打窝饵（q=窝点内咬钩率倍数）——
const CHUMS := {
	"worm": {"tex": "bait_worm.png", "q": 2.5},
	"mealworm": {"tex": "bait_mealworm.png", "q": 2.2},
	"corn": {"tex": "bait_corn.png", "q": 2.0},
	"rice": {"tex": "bait_rice.png", "q": 1.8},
}
const CHUM_ORDER := ["worm", "mealworm", "corn", "rice"]

# —— 鱼群槽位（池内鱼种按各自稀有度 RARITY.slot 权重刷新；条目 ["kind"] 或 ["kind", 权重倍率]）——
const SLOT_POOLS := [
	# —— 常见（8 槽：新手主打，几乎每竿有鱼）——
	["minnow", "crucian", "silvercarp", "bream", "pomfret", "mullet"],
	["crucian", "grasscarp", "tilapia", "yellowcroaker"],
	["minnow", "bleak", "gudgeon"],
	["grasscarp", "carp", "tench"],
	["frog"],                                             # 表层青蛙
	["shrimp", "loach"],                                  # 底层虾/泥鳅
	["carp", "silvercarp", "bighead"],                    # 中层混养
	["golden", "minnow", "crucian"],                      # 金鱼点缀
	# —— 普通/稀有（6 槽：进阶目标）——
	["bleak", "gudgeon", "loach"],                        # 表层小鱼
	["catfish", "yellowcat", "snakehead"],                # 底层凶猛
	["mandarinfish", "blackcarp", "culter"],              # 底层名贵
	["rainbowtrout", "salmon", "seabream", "mackerel"],   # 中层洄游
	["grouper", "cod", "arcticcod", "flounder"],          # 底层海鱼
	["betta", "puffer", "ray", "crab"],                   # 特色种
	# —— 高稀有（7 槽：传说/史诗出没）——
	["turtle", "carp", "golden"],                         # 底层稀有甲鱼
	["poisonfish", "icefish", "antarcod"],                # 极地/毒物
	["arapaima", "snakehead", "catfish"],                 # 巨型淡水
	["oarfish", "hairtail", "mackerel"],                  # 深海长条
	["tuna", "sailfish", "marlin", "kingsalmon"],         # 大洋掠食者
	["eel", "lungfish", "eelking"],                       # 底层电鳗系
	["seahorse", "discus", "koi", "piranha", "poisonfish"], # 观赏奇种
	# —— 神话（3 槽：顶级传说）——
	["goldendragon", "kun"],                              # 神话全层
	["coelacanth", "arowana", "mermaid"],                 # 活化石/龙鱼
	["mermaid", "kun", "eelking", "goldendragon"],        # 神话混池
	# —— 垃圾（3 槽：鞋/鱼骨）——
	["boot"],
	["fishbone"],
	["boot", "fishbone"],
]

const SFX_DB := -4.0
const BGM_DB := -6.0
const SFX_POOL := 4
const SCENERY_SEED := 20260928
# —— 鱼跃（鱼不常驻显示，偶尔跃出水面作氛围）——
const JUMP_T := 0.95           # 跃出动画时长（s）
const FISH_SHRINK := 0.72      # 鱼显示尺寸缩放（略微缩小）
const FLOAT_R := 0.012         # 浮漂半径（min 边比例）；穿线点 = 漂身中心上方 2.2R

var hud: RefCounted
var state := State.IDLE
var score := 0
var count := 0                  # 钓鱼数（垃圾不计）
var combo := 0
var _u := 1.0
var _time := 0.0
# 装备/选择
var _bait := "none"             # 钩上鱼饵
var _depth := 1                 # 浮漂深度所在水层 0/1/2
var _carrying := ""             # 手持打窝饵（""=无）
# 鱼群
var _fish: Array = []           # {kind, layer, slot}（鱼不显示，仅作咬钩概率/鱼跃数据）
var _slots: Array = []          # {pool, respawn_t}
var _jumps: Array = []          # 跃出动画 {kind, t, x, x1, y, dir}（x=跃出点，x1=落水点，均为比例坐标）
var _jump_t := 2.0              # 下次鱼跃倒计时（s）
# 抛竿/水下
var _cast_t := 0.0              # CAST 阶段计时
var _cast_from := Vector2.ZERO  # 竿尖
var _cast_to := Vector2.ZERO    # 落水点
var _sink_t := 0.0
var _float_x := 0.0            # 浮漂 x（屏幕）
var _wait_t := 0.0
var _bite_t := 0.0
var _bite_fish := {}            # 咬钩鱼引用
var _fight_fish := {}           # 拔河鱼引用
# 拔河
var _lmb := false
var _press_y := 0.0
var _progress := 0.0            # 上岸进度 0→1
var _run_x := 0.0               # 鱼冲刺横移（px）
var _run_dir := 1.0
var _burst_on := false
var _burst_t := 0.0
var _fish_f := 0.0              # 当前帧鱼力（画拉力计用）
var _player_f := 0.0
var _lose_t := 0.0              # 拉力超出红线的累计时长（s）
var _reel_t := 0.0
var _rest_t := 0.0              # 鱼逃脱后的恢复倒计时（s）：期间不可操作，竿上只挂浮漂（钩被带走）
var _reelin_t := 0.0            # 自动收杆进度计时
var _reelin_from := Vector2.ZERO  # 收杆起点（浮漂当前水面位置）
var _reelin_hook := true        # 收杆时钩是否还在（吐钩=true 空钩收回；断线=false 钩被鱼带走）
var _gauge_pos := Vector2.ZERO  # 拉力计锚点：按下左键瞬间的鼠标位置（固定不跟随）
# 钓起动画
var _land_t := 0.0
var _land_from := Vector2.ZERO
var _land_kind := ""
# 打窝
var _chum_fly := {}             # {t, from, to, kind}
var _chum_sink: Array = []      # {t, pos, kind}
var _zones: Array = []          # {x, y, r, t, q}
# 钓获展示
var _caught: Array = []         # 钓起的鱼 kind 列表（顶左展示）
var _prev_record := 0           # 开局时历史最高（首破时弹纪录）
var _record_popped := false
var _fight_tip_n := 0           # 拔河操作提示已弹次数（只弹前 3 次，避免刷屏）
# 特效
var _ripples: Array = []
var _drops: Array = []
var _splashes: Array = []
var _popups: Array = []
var _bubbles: Array = []
# 布景缓存
var _pebbles: Array = []
var _grass: Array = []
var _clouds: Array = []
var _shimmer: Array = []
var _y_top := 0.0
var _y_shore := 0.0
var _tex := {}
var _sfx := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
# UI
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _score_board: Label = $HudBar/ScoreBoard
@onready var _count_board: Label = $HudBar/CountBoard
@onready var _exit_btn: Button = $ExitButton
var _hbox: HBoxContainer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _menu_layer: Control = null   # 打开中的选择面板（木桶/饵盒/鱼竿）
# 开发者模式（暗门：排行榜面板 5 秒内点满 10 次，关闭排行榜后弹出调试窗口）
var _dev_pending := false
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_win: PanelContainer
var _dev_drag := false
var _dev_rar_btn: Button
var _dev_rar_i := 0             # 强制咬钩稀有度循环索引（0=跟随自然概率，1..7=按稀有度强制）
var _dev_bite_now := false       # 立即咬钩（下一帧触发）
var _dev_bite_mult := 1.0        # 咬钩率全局倍率
var _dev_fish_mult := 1.0        # 鱼力全局倍率
var _dev_reel_mult := 1.0        # 收线速度全局倍率


func start() -> void:
	randomize()
	hud = GameHud.new("fish_hook")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()
	_init_sfx()
	_layout()
	_init_population()
	_prev_record = hud.best_score()
	_refresh_boards()
	# 开场提示
	var tip1: String = hud.t("ui.tip_menu", "Click the bucket / bait box / rod to prepare, then click the water to cast")
	var tip2: String = hud.t("ui.tip_cast", "Click the water to cast")
	_popup(tip1, Color(0.75, 0.93, 1.0))
	get_tree().create_timer(2.2).timeout.connect(func() -> void:
		if state == State.IDLE:
			_popup(tip2, Color(1.0, 0.85, 0.4)))


func stop() -> void:
	get_tree().paused = false          # 排行榜可能还挂着暂停，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_run(score, count)       # 中途退出也把本局成绩入榜
	print("[fish_hook] stop, score=%d fish=%d" % [score, count])


func _exit_button_pressed() -> void:
	exit_requested.emit()


func on_leaderboard_closed() -> void:
	if _dev_pending:   # 暗门已触发：弹出开发者窗口
		_dev_pending = false
		_show_dev_window()


# ===== 资源加载 =====

func _load_textures() -> void:
	for k: String in KINDS:   # 全部鱼种/垃圾贴图
		_tex[KINDS[k].tex] = _load_png("assets/" + KINDS[k].tex)
	for k: String in BAITS:
		var tx: String = BAITS[k].tex
		if tx != "" and not _tex.has(tx):
			_tex[tx] = _load_png("assets/" + tx)
	for k: String in CHUMS:
		var tx2: String = CHUMS[k].tex
		if not _tex.has(tx2):
			_tex[tx2] = _load_png("assets/" + tx2)
	for n: String in ["bucket", "box"]:
		_tex[n] = _load_png("assets/%s.png" % n)
	for i in 7:   # 水花序列帧（复用打水漂素材）
		_tex["splash_%d" % i] = _load_png("assets/splash_%d.png" % i)


func _load_png(rel: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码（编辑器期走 res:// 相对路径）
	for p: String in ["res://games/fish_hook/" + rel, "res://" + rel]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


# ===== 布局（Node2D 父下 Control 锚点不可靠，全部代码定位）=====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_u = m / 1080.0
	_y_top = vp.y * Y_WATER_TOP
	_y_shore = vp.y * Y_SHORE
	_build_scenery(vp)
	var fs := int(m * 0.035)
	for b: Label in [_score_board, _count_board]:
		b.custom_minimum_size = Vector2(fs * 6.0, fs * 1.9)
		b.add_theme_font_size_override("font_size", fs)
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


## 布景缓存：岸坡碎石/草丛/云/波光（种子固定）
func _build_scenery(vp: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SCENERY_SEED
	_pebbles.clear()
	for i in 70:
		var y := rng.randf_range(_y_shore + vp.y * 0.02, vp.y - 6.0)
		var depth := (y - _y_shore) / maxf(vp.y - _y_shore, 1.0)
		_pebbles.append({
			"pos": Vector2(rng.randf_range(6.0, vp.x - 6.0), y),
			"r": lerpf(4.0, 12.0, depth) * rng.randf_range(0.7, 1.3) * _u,
			"col": rng.randf_range(0.30, 0.55),
		})
	_grass.clear()
	for i in 26:
		_grass.append({
			"pos": Vector2(rng.randf_range(4.0, vp.x - 4.0), _y_shore + rng.randf_range(-2.0, 6.0)),
			"h": vp.y * rng.randf_range(0.012, 0.026),
			"lean": rng.randf_range(-0.35, 0.35),
			"col": rng.randf(),
		})
	_clouds.clear()
	for i in 4:
		_clouds.append({
			"pos": Vector2(rng.randf_range(0.1, 0.9) * vp.x, rng.randf_range(0.2, 0.8) * _y_top),
			"r": vp.y * rng.randf_range(0.012, 0.024),
			"sp": rng.randf_range(3.0, 8.0),
		})
	_shimmer.clear()
	for i in 8:
		_shimmer.append({
			"frac": (i + rng.randf_range(0.15, 0.85)) / 8.0,
			"amp": rng.randf_range(0.5, 1.0),
			"ph": rng.randf_range(0.0, TAU),
			"sp": rng.randf_range(6.0, 16.0) * (1.0 if rng.randf() < 0.5 else -1.0),
		})


# ===== 右上角按钮排：✕ + 排行榜 + R 重开 + 音量循环 + BGM =====

func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, _exit_btn]:
		_hbox.add_child(b)
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 32)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	_lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_restart)
	_bgm_btn.pressed.connect(_on_bgm)
	_volume_btn.pressed.connect(_on_volume)


func _on_lb() -> void:
	hud.show_leaderboard(self, score, count)
	_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次


func _on_bgm() -> void:
	if hud.cycle_bgm():
		if _bgm != null:
			_bgm.play()
	elif _bgm != null:
		_bgm.stop()
	_bgm_btn.icon = hud.bgm_icon()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


func _restart() -> void:
	_rest_t = 0.0
	_lmb = false
	score = 0
	count = 0
	combo = 0
	_bait = "none"
	_depth = 1
	_carrying = ""
	_caught.clear()
	_zones.clear()
	_chum_fly.clear()
	_chum_sink.clear()
	_splashes.clear()
	_drops.clear()
	_ripples.clear()
	_popups.clear()
	_close_menu()
	_init_population()
	hud.reset_run()
	_prev_record = hud.best_score()
	_record_popped = false
	state = State.IDLE
	_refresh_boards()


# ===== 鱼群 =====

func _init_population() -> void:
	_fish.clear()
	_slots.clear()
	for pool: Array in SLOT_POOLS:
		_slots.append({"pool": pool, "respawn_t": 0.0})
	for i in _slots.size():
		_spawn_from_slot(i)


func _pick_pool_kind(pool: Array) -> String:
	var total := 0.0
	for e: Variant in pool:
		total += _slot_weight(e)
	var r := randf() * total
	for e: Variant in pool:
		r -= _slot_weight(e)
		if r <= 0.0:
			return String(e) if e is String else String(e[0])
	return String(pool[0]) if pool[0] is String else String(pool[0][0])


## 槽位条目权重 = 稀有度 slot 权重 × 条目倍率（条目 ["kind"] 或 ["kind", 倍率]）
func _slot_weight(e: Variant) -> float:
	var kind: String = e if e is String else String(e[0])
	var mult: float = 1.0 if e is String else float(e[1])
	return float(RARITY[KINDS[kind].rar].slot) * mult


func _resolve_layer(kind: String) -> int:
	match KINDS[kind].layer:
		-1: return 2 if randf() < 0.65 else 1   # 大型鱼：中底层
		-2: return randi() % 3                   # 垃圾：全层随机
		_: return KINDS[kind].layer


func _spawn_from_slot(i: int) -> void:
	var kind := _pick_pool_kind(_slots[i].pool)
	var layer := _resolve_layer(kind)
	_fish.append({"kind": kind, "layer": layer, "slot": i})
	_slots[i].respawn_t = 0.0


func _remove_fish(f: Dictionary) -> void:
	var idx := _fish.find(f)
	if idx >= 0:
		_fish.remove_at(idx)
	var slot := int(f.get("slot", -1))
	if slot >= 0 and slot < _slots.size():
		_slots[slot].respawn_t = randf_range(4.0, 8.0)


func _step_fish(delta: float) -> void:
	# 鱼不显示不游动：只做槽位补充（被钓走/逃走的槽位延迟刷新）
	for i in _slots.size():
		var alive := false
		for f: Dictionary in _fish:
			if int(f.get("slot", -1)) == i:
				alive = true
				break
		if not alive:
			_slots[i].respawn_t = maxf(float(_slots[i].respawn_t) - delta, 0.0)
			if _slots[i].respawn_t <= 0.0:
				_spawn_from_slot(i)


# ===== 主循环 =====

func _process(delta: float) -> void:
	var vp := get_viewport_rect().size
	_time += delta
	match state:
		State.CAST:
			_cast_t += delta
			if _cast_t >= CAST_T:   # 抛竿抛物线飞行
				_start_sink()
		State.SINK:
			_sink_t += delta
			if _sink_t >= _sink_dur():
				state = State.WAIT
				_wait_t = 0.0
		State.WAIT:
			_wait_t += delta
			_step_bite_chance(delta, vp)
		State.BITE:
			_bite_t += delta
			if _bite_t >= _bite_window():
				_bite_missed()
		State.FIGHT:
			_step_fight(delta, vp)
		State.LAND:
			_land_t += delta
			var extra := LAND_SHRINK_T if int(KINDS[_land_kind].value) < 0 else 0.0
			if _land_t >= LAND_T + LAND_MOVE_T + extra:
				_finish_land()
		State.REEL:
			_reelin_t += delta
			if _reelin_t >= REELIN_T:
				state = State.IDLE
	if _rest_t > 0.0:
		_rest_t = maxf(_rest_t - delta, 0.0)   # 逃脱恢复倒计时（期间封锁操作）
	_step_chum(delta, vp)
	_step_fish(delta)
	_step_jump(delta, vp)
	_step_fx(delta)
	_refresh_boards()
	queue_redraw()


## 钩饵下沉时长：越深越久
func _sink_dur() -> float:
	return 0.35 + 0.35 * _depth


## 咬钩反应窗口：按咬钩鱼的稀有度取值（无鱼引用时用兜底值）
func _bite_window() -> float:
	if _bite_fish.is_empty():
		return BITE_WINDOW
	return float(RARITY[KINDS[_bite_fish.kind].rar].window)


# ===== 打窝 =====

func _step_chum(delta: float, vp: Vector2) -> void:
	if not _chum_fly.is_empty():
		_chum_fly.t += delta
		if _chum_fly.t >= CHUM_FLY_T:
			_spawn_splash(_chum_fly.to, 0.6)
			_play_sfx("plop")
			_chum_sink.append({"t": 0.0, "pos": _chum_fly.to, "kind": _chum_fly.kind})
			_chum_fly = {}
	for c: Dictionary in _chum_sink:
		c.t += delta
		if c.t >= CHUM_SINK_T:
			_zones.append({
				"x": c.pos.x / vp.x,
				"y": c.pos.y,   # 窝点就在抛投落点（鼠标点击位置）
				"r": CHUM_R * minf(vp.x, vp.y),
				"t": 0.0, "q": CHUMS[c.kind].q,
			})
			if _zones.size() > CHUM_MAX:
				_zones.pop_front()
			var done: String = hud.t("ui.chum_done", "Chummed! Fish are gathering")
			_popup(done, Color(0.95, 0.8, 0.5))
	_chum_sink = _chum_sink.filter(func(c: Dictionary) -> bool: return c.t < CHUM_SINK_T)
	for z: Dictionary in _zones:
		z.t += delta
	_zones = _zones.filter(func(z: Dictionary) -> bool: return z.t < CHUM_LIFE)


## 抛出打窝饵（从岸边中间弧线抛到点击处）
func _throw_chum(to: Vector2) -> void:
	var vp := get_viewport_rect().size
	_chum_fly = {"t": 0.0, "from": Vector2(vp.x * 0.5, _y_shore - 20.0 * _u), "to": to, "kind": _carrying}
	_carrying = ""
	_play_sfx("throw")


# ===== 咬钩判定 =====

## 鱼饵对某稀有度的咬钩率倍数（空钩只咬垃圾：junk 全额 1.0；未配置的稀有度缺省 0.8）
func _bait_mult(rar: String) -> float:
	if _bait == "none":
		return 1.0
	return float(BAITS[_bait].mult.get(rar, 0.8))


## 鱼位于当前浮漂水层的咬钩倍率：舒适层 ×RARITY.comf，全层同率鱼(comf=-1)恒 ×comf
func _layer_mult(kind: Dictionary) -> float:
	var r: Dictionary = RARITY[kind.rar]
	return float(r.comf) if int(kind.comf) < 0 or int(kind.comf) == _depth else 1.0


func _hook_chum_q(vp: Vector2) -> float:
	# 浮漂（下水点）落在窝点平面范围内才享受加成
	var q := 1.0
	for z: Dictionary in _zones:
		if Vector2(z.x * vp.x, z.y).distance_to(Vector2(_float_x, _cast_to.y)) < z.r:
			q = maxf(q, z.q)
	return q


## 落水点离岸距离 0..1（0=贴岸，1=最远水面）：按水面竖直范围归一（岸线在下、水面顶在上）
func _far_dist() -> float:
	if _cast_to == Vector2.ZERO:
		return 0.0
	var vp := get_viewport_rect().size
	var d := (Y_SHORE - _cast_to.y / vp.y) / (Y_SHORE - Y_WATER_TOP)
	return clampf(d, 0.0, 1.0)


func _step_bite_chance(delta: float, vp: Vector2) -> void:
	# 咬钩纯概率判定（无空间/距离因素）：
	# 稀有度基率 × 舒适层倍率 × 鱼饵(稀有度)倍率 × 窝点加成(稀有度敏感度) × 远水加成(稀有度 far)
	# 空钩时只有垃圾（旧靴子/鱼骨）会咬钩
	var q := _hook_chum_q(vp)
	var far_d := _far_dist()
	var rate := 0.0
	for f: Dictionary in _fish:
		var k: Dictionary = KINDS[f.kind]
		if _bait == "none" and k.rar != "junk":
			continue
		var r: Dictionary = RARITY[k.rar]
		var chum_m: float = 1.0 + (q - 1.0) * float(r.chum)
		var far_m: float = 1.0 + far_d * float(r.far)
		rate += float(r.bite) * _layer_mult(k) * _bait_mult(k.rar) * chum_m * far_m
	if rate > 0.0 or _dev_bite_now:
		rate *= _dev_bite_mult
		if _dev_bite_now:
			rate = 10.0   # 开发者：立即咬钩
			_dev_bite_now = false
		if randf() < rate * delta:
			_start_bite(vp)


func _start_bite(vp: Vector2) -> void:
	# 全层活动：按"稀有度基率×舒适层倍率"加权随机选一条鱼咬钩；开发者强制稀有度时从 KINDS 随机选该档鱼
	if _dev_rar_i > 0:
		var rar: String = DEV_RARS[_dev_rar_i]
		var pool: Array = KINDS.keys().filter(func(k: String) -> bool: return KINDS[k].rar == rar)
		_bite_fish = {"kind": pool[randi() % pool.size()], "layer": _depth, "slot": -1}
	else:
		if _fish.is_empty():
			return
		var total := 0.0
		for f: Dictionary in _fish:
			total += float(RARITY[KINDS[f.kind].rar].bite) * _layer_mult(KINDS[f.kind])
		var r := randf() * total
		var pick: Dictionary = _fish[_fish.size() - 1]
		for f: Dictionary in _fish:
			r -= float(RARITY[KINDS[f.kind].rar].bite) * _layer_mult(KINDS[f.kind])
			if r <= 0.0:
				pick = f
				break
		_bite_fish = pick
	state = State.BITE
	_bite_t = 0.0
	_spawn_ripple(Vector2(_float_x, vp.y * Y_WATER_TOP + 8.0 * _u), 0.7)
	_play_sfx("bite")
	var tip: String = hud.t("ui.tip_bite", "Fish on! Hold left button and pull down!")
	_popup(tip, Color(1.0, 0.55, 0.4))


func _bite_missed() -> void:
	_play_sfx("snap")   # 鱼吐钩跑掉：多人叹气声
	var f: Dictionary = _bite_fish
	_bite_fish = {}
	if not f.is_empty():
		_remove_fish(f)
	_bait = "none"   # 鱼吐钩跑掉，饵被带走
	_reelin_t = 0.0
	_reelin_from = Vector2(_float_x, _cast_to.y)
	_reelin_hook = true   # 空钩还在
	var miss: String = hud.t("ui.bite_miss", "The fish spat the hook and left...")
	_popup(miss, Color(0.85, 0.85, 0.85))
	state = State.REEL   # 程序自动收杆


# ===== 拔河 =====

func _start_fight() -> void:
	var vp := get_viewport_rect().size
	_fight_fish = _bite_fish
	_bite_fish = {}
	state = State.FIGHT
	_lmb = true
	_press_y = get_global_mouse_position().y
	_progress = 0.0
	_run_x = 0.0
	_burst_on = false
	_burst_t = randf_range(0.7, 1.3)
	_lose_t = 0.0
	_gauge_pos = get_global_mouse_position()   # 拉力计固定在按下瞬间的鼠标右侧
	_play_sfx("hook")
	if _fight_tip_n < 3:
		_fight_tip_n += 1
		var tip2: String = hud.t("ui.tip_fight", "Pull down to reel! Keep the pull between the red lines!")
		_popup(tip2, Color(1.0, 0.85, 0.4))


func _fish_force() -> float:
	var k: Dictionary = KINDS[_fight_fish.kind]
	var f: float = float(k.str) * _dev_fish_mult
	if _burst_on:
		f += float(k.burst) * _dev_fish_mult * (0.65 + 0.35 * sin(_time * 11.0))
	else:
		f += 0.05 * sin(_time * 3.0)
	return f


## 拔河安全区间：两条红线的间距由鱼种决定（鱼越大越窄），中心随鱼挣扎缓慢摆动
func _fight_zone() -> Dictionary:
	var k: Dictionary = KINDS[_fight_fish.kind]
	var half: float = maxf(0.26 - (float(k.str) + float(k.burst)) * 0.13, 0.07)
	var amp: float = 0.05 + float(k.burst) * 0.07
	var center: float = 0.5 + amp * sin(_time * (1.1 + float(k.str)))
	center = clampf(center, half + 0.06, 1.0 - half - 0.06)
	return {"low": center - half, "high": center + half, "center": center, "half": half}


func _step_fight(delta: float, vp: Vector2) -> void:
	if _fight_fish.is_empty():
		state = State.IDLE
		return
	# 爆发调度（冲刺/喘息交替）
	_burst_t -= delta
	if _burst_t <= 0.0:
		_burst_on = not _burst_on
		_burst_t = randf_range(1.1, 2.1) if _burst_on else randf_range(0.9, 1.9)
		if _burst_on:
			_run_dir = 1.0 if randf() < 0.5 else -1.0
	# 拉力：按住左键下拉的距离
	_player_f = 0.0
	if _lmb:
		_player_f = clampf((get_global_mouse_position().y - _press_y) / (vp.y * PULL_RANGE), 0.0, 1.0)
	_fish_f = _fish_force()
	# 拉力必须保持在两条红线之间：区间内收线，超出（上/下任一）1.2s 断线
	var zone: Dictionary = _fight_zone()
	var in_zone: bool = _player_f >= float(zone.low) and _player_f <= float(zone.high)
	if in_zone:
		_lose_t = maxf(_lose_t - delta * 2.0, 0.0)
	else:
		_lose_t += delta
	if _lose_t >= BREAK_T:
		_line_broke(vp)
		return
	# 上岸进度：区间内才拉回，越贴近中心越快
	if in_zone:
		var acc: float = 1.0 - 0.5 * absf(_player_f - float(zone.center)) / maxf(float(zone.half), 0.01)
		_progress = clampf(_progress + REEL_RATE * _dev_reel_mult * acc * delta, -0.15, 1.0)
	# 冲刺横移（浮漂前进后退的视觉）
	if _burst_on:
		_run_x = clampf(_run_x + _run_dir * RUN_SPD * vp.x * delta, -RUN_MAX * vp.x, RUN_MAX * vp.x)
	else:
		_run_x *= exp(-2.5 * delta)
	# 收线咔哒声
	if in_zone:
		_reel_t -= delta
		if _reel_t <= 0.0:
			_reel_t = 0.09
			_play_sfx("reel", -6.0)
	if _progress >= 1.0:
		_catch_fish(vp)


## 断线：鱼逃脱并带走饵钩，程序自动收杆（REEL），浮字提示
func _line_broke(vp: Vector2) -> void:
	_play_sfx("snap")
	var msg: String = hud.t("ui.line_broke", "Line snapped! The fish escaped...")
	_popup(msg, Color(1.0, 0.4, 0.35))
	_rest_t = 2.2
	combo = 0
	_bait = "none"
	var f: Dictionary = _fight_fish
	_fight_fish = {}
	if not f.is_empty():
		_remove_fish(f)
	_reelin_t = 0.0
	_reelin_from = _rod_tip(vp).lerp(_fight_pos(vp), 0.5)   # 拔河线上的浮漂位置
	_reelin_hook = false   # 钩饵被鱼带走
	state = State.REEL


## 钓起：抛上岸 + 结算
func _catch_fish(vp: Vector2) -> void:
	var k: Dictionary = KINDS[_fight_fish.kind]
	_land_kind = _fight_fish.kind
	_land_from = _fight_pos(vp)
	_remove_fish(_fight_fish)
	_fight_fish = {}
	_land_t = 0.0
	state = State.LAND
	_spawn_splash(_land_from, 0.9)
	_play_sfx("splash")
	var value := int(k.value)
	if value < 0:
		# 垃圾：扣分 + 清连击
		score = maxi(score + value, 0)
		combo = 0
		var trash: String = hud.t("ui.trash_catch", "Caught trash  -%d pts") % -value
		_popup(trash, Color(0.7, 0.7, 0.7))
		_play_sfx("trash")
	else:
		combo += 1
		var mult := minf(1.0 + 0.5 * (combo - 1), 3.0)
		var pts := roundi(value * mult)
		score += pts
		count += 1
		_popup("+%d" % pts, Color(0.55, 1.0, 0.6))
		if combo >= 2:
			var ctext: String = hud.t("ui.combo", "Combo x%d") % combo
			get_tree().create_timer(0.35).timeout.connect(func() -> void:
				_popup("%s ×%.1f" % [ctext, mult], Color(1.0, 0.85, 0.3)))
		if _is_big(_land_kind):
			_play_sfx("cheer")   # 大型鱼/稀有鱼：群体欢呼（优先于连击音效）
		elif combo >= 2:
			_play_sfx("combo", clampf(-2.0 + combo, -6.0, 0.0))
		else:
			_play_sfx("catch")
		# 纪录检测（每局只弹一次）
		var res: Dictionary = hud.commit_run(score, count)
		if res.rec and not _record_popped:
			_record_popped = true
			var rec: String = hud.t("ui.new_record", "New Record!")
			get_tree().create_timer(0.8).timeout.connect(func() -> void:
				_popup(rec, Color(1.0, 0.85, 0.25)))
			_play_sfx("record")


## 展示结束：鱼加入左上角钓获列表（垃圾坠出画面，不展示）
func _finish_land() -> void:
	if int(KINDS[_land_kind].value) >= 0:
		_caught.append(_land_kind)
	state = State.IDLE


# ===== 特效 =====

func _spawn_splash(pos: Vector2, inten: float) -> void:
	var k := clampf(inten, 0.3, 1.4)
	_splashes.append({"pos": pos, "t": 0.0, "sc": k})
	for i in int(5 + inten * 9.0):
		var ang := randf_range(-PI * 0.85, -PI * 0.15)
		var sp := randf_range(110.0, 380.0) * inten * _u
		_drops.append({"pos": pos + Vector2(0, -4 * _u), "vel": Vector2.from_angle(ang) * sp,
				"t": 0.0, "life": randf_range(0.3, 0.6), "r": randf_range(1.5, 3.2) * _u})
	_spawn_ripple(pos, inten * 0.8)


func _spawn_ripple(pos: Vector2, inten: float) -> void:
	_ripples.append({"pos": pos, "r0": maxf(14.0 * _u * inten, 8.0), "t": 0.0, "life": 0.9})


func _step_fx(delta: float) -> void:
	for r: Dictionary in _ripples:
		r.t += delta
	_ripples = _ripples.filter(func(x: Dictionary) -> bool: return x.t < x.life)
	for dp: Dictionary in _drops:
		dp.t += delta
		dp.vel.y += 820.0 * _u * delta
		dp.pos += dp.vel * delta
	_drops = _drops.filter(func(x: Dictionary) -> bool: return x.t < x.life)
	for sp: Dictionary in _splashes:
		sp.t += delta
	_splashes = _splashes.filter(func(x: Dictionary) -> bool: return x.t < 7.0 * 0.055)
	if randf() < delta * 0.7:
		var vp := get_viewport_rect().size
		_bubbles.append({"pos": Vector2(randf_range(vp.x * 0.1, vp.x * 0.9), randf_range(_y_top + 40.0 * _u, _y_shore - 20.0 * _u)),
				"t": 0.0, "life": randf_range(1.2, 2.4), "r": randf_range(1.5, 3.0) * _u})
	for bb: Dictionary in _bubbles:
		bb.t += delta
		bb.pos.y -= 30.0 * _u * delta
	_bubbles = _bubbles.filter(func(x: Dictionary) -> bool: return x.t < x.life)
	for pp: Dictionary in _popups:
		pp.t += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.t < x.life)


func _popup(text: String, col: Color) -> void:
	_popups.append({"text": text, "col": col, "t": 0.0, "life": 1.8})


func _refresh_boards() -> void:
	if hud == null:
		return   # 无头冒烟：start() 未调用（hud 未初始化）时跳过
	var ss: String = hud.t("hud.score", "Score")
	var ff: String = hud.t("hud.fish", "Fish")
	_score_board.text = "%s %d" % [ss, score]
	_count_board.text = "%s %d" % [ff, count]


# ===== 选择面板（木桶/饵盒/鱼竿：自绘模态层）=====

func _open_menu(title: String, entries: Array, cols: int) -> void:
	_close_menu()
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var layer := Control.new()
	layer.name = "MenuLayer"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			_close_menu())
	layer.add_child(dim)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.19, 0.19, 0.95)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.03)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.015))
	panel.add_child(vb)
	var lb := Label.new()
	lb.text = title
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(m * 0.042))
	lb.add_theme_color_override("font_color", Color(0.55, 0.9, 0.95))
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	vb.add_child(lb)
	var grid := GridContainer.new()
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", int(m * 0.012))
	grid.add_theme_constant_override("v_separation", int(m * 0.012))
	vb.add_child(grid)
	for e: Dictionary in entries:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(m * 0.135, m * 0.165)
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(0.10, 0.15, 0.15, 0.9)
		bs.set_corner_radius_all(12)
		btn.add_theme_stylebox_override("normal", bs)
		var bh := bs.duplicate() as StyleBoxFlat
		bh.bg_color = Color(0.16, 0.24, 0.24, 0.95)
		btn.add_theme_stylebox_override("hover", bh)
		btn.add_theme_stylebox_override("pressed", bh)
		var cell := VBoxContainer.new()
		cell.set_anchors_preset(Control.PRESET_FULL_RECT)
		cell.alignment = BoxContainer.ALIGNMENT_CENTER
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_theme_constant_override("separation", 4)
		if e.tex != "":
			var ic := TextureRect.new()
			ic.texture = _tex.get(e.tex)
			ic.custom_minimum_size = Vector2(m * 0.07, m * 0.07)
			ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if e.tint != null:
				ic.modulate = e.tint
			cell.add_child(ic)
		var nm := Label.new()
		nm.text = e.label
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.add_theme_font_size_override("font_size", int(m * 0.019))
		nm.add_theme_color_override("font_color", Color.WHITE)
		nm.add_theme_color_override("font_outline_color", Color.BLACK)
		nm.add_theme_constant_override("outline_size", 6)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(nm)
		btn.add_child(cell)
		var cb: Callable = e.cb
		btn.pressed.connect(func() -> void:
			_play_sfx("pick")
			_close_menu()
			cb.call())
		grid.add_child(btn)
	layer.add_child(panel)
	add_child(layer)
	panel.reset_size()
	panel.position = Vector2(vp.x / 2.0 - panel.size.x / 2.0, vp.y / 2.0 - panel.size.y / 2.0)
	_menu_layer = layer


func _close_menu() -> void:
	if _menu_layer != null:
		_menu_layer.queue_free()
		_menu_layer = null


func _open_bucket_menu() -> void:
	var entries: Array = []
	for c: String in CHUM_ORDER:
		entries.append({
			"tex": CHUMS[c].tex, "tint": null,
			"label": hud.t("bait." + c, c),
			"cb": func() -> void: _carrying = c,
		})
	var title: String = hud.t("ui.chum_title", "Choose Chum Bait")
	_open_menu(title, entries, 4)


func _open_box_menu() -> void:
	var entries: Array = []
	for b: String in BAIT_ORDER:
		var tint: Variant = BAITS[b].get("tint")
		entries.append({
			"tex": BAITS[b].tex, "tint": tint,
			"label": hud.t("bait." + b, b),
			"cb": func() -> void: _bait = b,
		})
	entries.append({
		"tex": "", "tint": null,
		"label": hud.t("ui.bait_none", "No Bait"),
		"cb": func() -> void: _bait = "none",
	})
	var title: String = hud.t("ui.bait_title", "Choose Hook Bait")
	_open_menu(title, entries, 3)


# ===== 输入 =====

func _unhandled_input(event: InputEvent) -> void:
	if _rest_t > 0.0:
		return   # 鱼逃脱后的短暂恢复期：暂不可操作
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_lmb = mb.pressed
			if not mb.pressed:
				return
			if state == State.BITE:
				_start_fight()
				return
			# 正在钓鱼（抛竿中 / 沉浮 / 等待咬钩）：点击鱼竿直接收杆
			if state in [State.CAST, State.SINK, State.WAIT] \
					and _hit_prop(mb.position, _rod_rect(get_viewport_rect().size)):
				state = State.IDLE
				var rmsg: String = hud.t("ui.reeled_in", "Reeled in")
				_popup(rmsg, Color(0.8, 0.8, 0.8))
				return
			if state != State.IDLE:
				return
			var mp := mb.position
			# 岸边道具：木桶 / 饵盒 / 鱼竿
			var vp := get_viewport_rect().size
			if _hit_prop(mp, _bucket_rect(vp)):
				_open_bucket_menu()
				return
			if _hit_prop(mp, _box_rect(vp)):
				_open_box_menu()
				return
			if _hit_prop(mp, _rod_rect(vp)):
				return   # 鱼竿：仅展示，无交互
			# 待机浮漂：点击直接切换浮漂深度（表→中→底循环）
			if mp.distance_to(_idle_float_pos(vp)) < 34.0 * _u:
				_depth = (_depth + 1) % 3
				var names := ["depth.0", "depth.1", "depth.2"]
				var dmsg: String = "%s: %s" % [
					hud.t("ui.depth_title", "Float Depth"),
					hud.t(names[_depth], ["Surface", "Middle", "Bottom"][_depth])]
				_popup(dmsg, Color(0.75, 0.93, 1.0))
				_play_sfx("pick")
				return
			# 水面：打窝 or 抛竿
			if mp.y < _y_shore - 8.0 * _u and mp.y > _y_top:
				if _carrying != "":
					_throw_chum(mp)
				else:
					_cast(mp)
			elif _carrying != "":
				# 点击岸边 / 非水面区域：空手取消打窝手持（触摸友好，与右键取消等效）
				_carrying = ""
				_play_sfx("pick")
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# 右键：取消打窝手持 / 收竿
			if _carrying != "":
				_carrying = ""
			elif state in [State.CAST, State.SINK, State.WAIT]:
				state = State.IDLE
				var msg: String = hud.t("ui.reeled_in", "Reeled in")
				_popup(msg, Color(0.8, 0.8, 0.8))


func _cast(mp: Vector2) -> void:
	var vp := get_viewport_rect().size
	state = State.CAST   # 先切状态：竿尖按"抛竿后略微超出岸线"取位
	_cast_from = _rod_tip(vp)
	_cast_to = mp        # 水面是平面：钩从点击位置下水，浮漂就在下水处
	_float_x = mp.x
	_cast_t = 0.0
	_play_sfx("cast")


func _start_sink() -> void:
	_sink_t = 0.0
	state = State.SINK
	_spawn_splash(_cast_to, 0.5)
	_play_sfx("plop")


func _rod_base(vp: Vector2) -> Vector2:
	# 竿底：岸边水平居中 + 岸区垂直居中（与木桶/饵盒同一基准）
	return Vector2(vp.x * 0.5, _y_shore + (vp.y - _y_shore) * 0.5)


func _rod_tip(vp: Vector2) -> Vector2:
	# 竿尖：未抛竿不超过岸线；抛竿后略微超出；拔河时被拽得大幅下垂（随鱼力）；
	# 自动收杆时从下垂位平滑抬回
	var over := 0.0
	if state == State.FIGHT:
		over = vp.y * (0.09 + maxf(_fish_f, 0.0) * 0.06)
	elif state == State.BITE:
		over = vp.y * (0.11 + sin(_time * 9.0) * 0.015)   # 咬钩：竿尖被拽得明显下垂
	elif state == State.REEL:
		over = vp.y * lerpf(0.15, 0.07, clampf(_reelin_t / REELIN_T, 0.0, 1.0))
	elif state == State.CAST:
		# 后仰蓄力：竿尖抬到岸线上方；前挥 0.18s 内快速甩回前伸位
		var swing := clampf((_cast_t - CAST_WIND_T) / 0.18, 0.0, 1.0)
		over = -vp.y * 0.11 * (1.0 - swing)
	elif state != State.IDLE:
		over = vp.y * 0.07
	return Vector2(vp.x * 0.5 + vp.x * 0.11, _y_shore - over)


func _bucket_rect(vp: Vector2) -> Rect2:
	var m := minf(vp.x, vp.y)
	var sz := m * 0.16
	return Rect2(vp.x * 0.13 - sz * 0.5, _y_shore + (vp.y - _y_shore) * 0.5 - sz * 0.5, sz, sz)


func _box_rect(vp: Vector2) -> Rect2:
	var m := minf(vp.x, vp.y)
	var sz := m * 0.16
	return Rect2(vp.x * 0.87 - sz * 0.5, _y_shore + (vp.y - _y_shore) * 0.5 - sz * 0.5, sz, sz)


func _rod_rect(vp: Vector2) -> Rect2:
	# 竿底局部点击区（岸区中部一小块），不竖跨水体——否则会拦截抛竿点击
	var m := minf(vp.x, vp.y)
	var b := _rod_base(vp)
	return Rect2(b.x - m * 0.09, b.y - m * 0.07, m * 0.18, m * 0.14)


func _hit_prop(p: Vector2, r: Rect2) -> bool:
	return r.has_point(p)


# ===== 绘制 =====

func _draw() -> void:
	var vp := get_viewport_rect().size
	_draw_sky(vp)
	_draw_water(vp)
	_draw_zones(vp)
	_draw_jumps(vp)
	_draw_ripples()
	_draw_splashes()
	_draw_drops()
	_draw_bubbles()
	_draw_shore(vp)
	_draw_props(vp)
	_draw_land_fish(vp)   # 钓起鱼展示/列表：岸坡与道具之上
	_draw_land_throw(vp)   # 垃圾丢出段：水岸之上层（压过岸坡与道具）
	_draw_carry(vp)
	_draw_caught(vp)
	_draw_gauge(vp)
	_draw_gear(vp)      # 鱼竿/鱼线/浮漂最上层（压过水花、岸坡、道具；浮字之下）
	_draw_popups(vp)


func _draw_sky(vp: Vector2) -> void:
	# 白日天空 + 云 + 远树带
	draw_rect(Rect2(0, 0, vp.x, _y_top), Color(0.62, 0.82, 0.90))
	for c: Dictionary in _clouds:
		var cx: float = fposmod(c.pos.x + _time * c.sp * _u, vp.x + c.r * 6.0) - c.r * 3.0
		var cy: float = c.pos.y
		draw_circle(Vector2(cx, cy), c.r, Color(1, 1, 1, 0.75))
		draw_circle(Vector2(cx + c.r * 0.8, cy + c.r * 0.25), c.r * 0.7, Color(1, 1, 1, 0.7))
		draw_circle(Vector2(cx - c.r * 0.8, cy + c.r * 0.3), c.r * 0.6, Color(1, 1, 1, 0.65))
	# 远树带
	var tree_h := vp.y * 0.035
	draw_rect(Rect2(0, _y_top - tree_h, vp.x, tree_h), Color(0.30, 0.48, 0.30))
	for i in int(vp.x / (46.0 * _u)) + 1:
		var tx := i * 46.0 * _u + 12.0 * _u
		draw_circle(Vector2(tx, _y_top - tree_h), tree_h * 0.55, Color(0.26, 0.44, 0.27))
	# 太阳
	draw_circle(Vector2(vp.x * 0.88, _y_top * 0.32), vp.y * 0.030, Color(1.0, 0.93, 0.55, 0.95))


func _draw_water(vp: Vector2) -> void:
	# 水色 + 水面线 + 波光
	draw_rect(Rect2(0, _y_top, vp.x, _y_shore - _y_top), Color(0.30, 0.58, 0.68, 0.95))
	# 水面线
	draw_rect(Rect2(0, _y_top - 1.5 * _u, vp.x, 3.0 * _u), Color(0.85, 0.96, 1.0, 0.5))
	# 波光
	for sm: Dictionary in _shimmer:
		var y := lerpf(_y_top + 14.0 * _u, _y_shore - 14.0 * _u, sm.frac)
		var w: float = lerpf(36.0, 96.0, sm.frac) * _u * sm.amp
		var span: float = vp.x + w
		var x0: float = fmod(_time * sm.sp * _u + sm.ph * 300.0, span) - w
		var a := 0.08 + 0.05 * sin(_time * 1.7 + sm.ph)
		while x0 < vp.x:
			draw_line(Vector2(x0, y), Vector2(x0 + w * 0.55, y), Color(0.8, 0.96, 1.0, a), 2.0 * _u)
			x0 += span / 3.0


func _draw_zones(vp: Vector2) -> void:
	# 窝点：水底棕色饵雾（渐显渐隐 + 冒泡）
	for z: Dictionary in _zones:
		var k: float = z.t / CHUM_LIFE
		var a: float = clampf(k * 8.0, 0.0, 1.0) * clampf((1.0 - k) * 4.0, 0.0, 1.0)
		draw_set_transform(Vector2(z.x * vp.x, z.y), 0.0, Vector2(1.0, 0.45))
		draw_circle(Vector2.ZERO, z.r, Color(0.45, 0.33, 0.20, 0.30 * a))
		draw_circle(Vector2.ZERO, z.r * 0.6, Color(0.52, 0.38, 0.22, 0.35 * a))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if randf() < 0.06:
			_bubbles.append({"pos": Vector2(z.x * vp.x + randf_range(-z.r, z.r) * 0.6, z.y - randf_range(0, z.r * 0.4)),
					"t": 0.0, "life": randf_range(0.8, 1.6), "r": randf_range(1.5, 2.6) * _u})


## 鱼贴图统一绘制入口（贴图头朝左；flip=-1 翻转头朝右；mult=额外缩放）
func _draw_fish_sprite(vp: Vector2, kind: String, pos: Vector2, rot: float, flip: float, mult: float) -> void:
	var k: Dictionary = KINDS[kind]
	var tex: Texture2D = _tex.get(k.tex)
	if tex == null:
		return
	var rr: float = k.r * minf(vp.x, vp.y) * FISH_SHRINK * mult
	var s := 2.0 * rr / 116.0
	draw_set_transform(pos, rot, Vector2(flip * s, s))
	draw_texture(tex, Vector2(-64, -64))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _step_jump(delta: float, vp: Vector2) -> void:
	# 偶发鱼跃（纯氛围）：非垃圾鱼在任意水面位置跃出再落回；窝点内更常跃出（呼应打窝）
	_jump_t -= delta
	if _jump_t <= 0.0:
		_jump_t = randf_range(2.5, 6.0)
		var cand := _fish.filter(func(f: Dictionary) -> bool: return not GARBAGE.has(f.kind))
		if not cand.is_empty():
			var f: Dictionary = cand[randi() % cand.size()]
			var jx := randf_range(0.12, 0.88)
			var jy := randf_range(Y_WATER_TOP + 0.02, Y_SHORE - 0.06)
			if not _zones.is_empty() and randf() < 0.6:
				var z: Dictionary = _zones[randi() % _zones.size()]
				jx = clampf(float(z.x) + randf_range(-0.06, 0.06), 0.08, 0.92)
				jy = clampf(float(z.y) / vp.y + randf_range(-0.04, 0.04), Y_WATER_TOP + 0.02, Y_SHORE - 0.06)
			var dir := 1.0 if randf() < 0.5 else -1.0
			var jx1 := clampf(jx + dir * randf_range(0.08, 0.16), 0.06, 0.94)   # 落水点 = 跃出点沿跃进方向前移
			_jumps.append({"kind": f.kind, "t": 0.0, "x": jx, "x1": jx1, "y": jy, "dir": dir})
			_spawn_ripple(Vector2(jx * vp.x, jy * vp.y + 10.0 * _u), 0.6)
			_play_sfx("plop", -8.0)
	for j: Dictionary in _jumps:
		j.t += delta
		if j.t >= JUMP_T:
			_spawn_splash(Vector2(float(j.x1) * vp.x, float(j.y) * vp.y + 10.0 * _u), 0.55)
	_jumps = _jumps.filter(func(j: Dictionary) -> bool: return j.t < JUMP_T)


func _draw_jumps(vp: Vector2) -> void:
	for j: Dictionary in _jumps:
		var k: float = j.t / JUMP_T
		var arc := sin(k * PI)
		var pos := Vector2(lerpf(float(j.x), float(j.x1), k) * vp.x,
				float(j.y) * vp.y + 14.0 * _u - arc * vp.y * 0.085)
		# 起跳抬头 → 落水低头（贴图头朝左：dir=1 向右跳需翻转并反向旋转）
		var rot: float = lerpf(-0.9, 0.9, k) * float(j.dir)
		_draw_fish_sprite(vp, j.kind, pos, rot, -float(j.dir), 0.8)


## 钓起展示：拉近屏幕中心放大 3 倍展示（LAND_T），随后鱼飞向左上角列表末尾；
## 垃圾先缩小 3 倍（3.0→1.0），再由 _draw_land_throw 在水岸之上层丢出画面
func _draw_land_fish(vp: Vector2) -> void:
	if state != State.LAND:
		return
	var m := minf(vp.x, vp.y)
	var center := Vector2(vp.x * 0.5, vp.y * 0.45)
	var cell := m * 0.040
	if _land_t < 0.4:
		# 拉近：从钓起位置飞向屏幕中心，放大到 3 倍（ease-out）
		var e1 := 1.0 - pow(1.0 - clampf(_land_t / 0.4, 0.0, 1.0), 2.0)
		var ct := (_land_from + center) * 0.5 + Vector2(0, -vp.y * 0.10)
		var p0 := _land_from.lerp(ct, e1)
		var p1 := ct.lerp(center, e1)
		var rot1 := (1.0 - e1) * PI * 0.85 + sin(_time * 18.0) * 0.04 * (1.0 - e1)
		_draw_fish_sprite(vp, _land_kind, p0.lerp(p1, e1), rot1, 1.0, lerpf(1.0, 3.0, e1))
	elif _land_t < LAND_T:
		# 居中放大展示：轻微摆动；史诗/神话鱼沿轮廓发五颜六色流转的光（光环画在鱼下层，大鱼不挡）
		var sway := sin(_time * 5.0) * 0.06
		if KINDS[_land_kind].rar in ["epic", "mythic"]:
			_draw_aura_glow(vp, _land_kind, center, sway, 3.0)
		_draw_fish_sprite(vp, _land_kind, center, sway, 1.0, 3.0)
	elif int(KINDS[_land_kind].value) >= 0:
		# 飞行段：鱼缩小转向左上角列表末尾（新鱼左半叠旧鱼右半）
		var e2: float = pow(clampf((_land_t - LAND_T) / LAND_MOVE_T, 0.0, 1.0), 2.0)
		var corner := Vector2(18.0 * _u + cell * 0.5 + _caught.size() * cell * 0.5, 84.0 * _u + cell * 0.5)
		_draw_fish_sprite(vp, _land_kind, center.lerp(corner, e2), lerpf(0.0, PI / 2.0, e2), 1.0, lerpf(3.0, 0.55, e2))
	elif _land_t < LAND_T + LAND_SHRINK_T:
		# 垃圾缩小段：3 倍缩小到 1 倍（ease-out），缩小完成后转岸上层丢出
		var es := 1.0 - pow(1.0 - clampf((_land_t - LAND_T) / LAND_SHRINK_T, 0.0, 1.0), 2.0)
		_draw_fish_sprite(vp, _land_kind, center, sin(_time * 5.0) * 0.06, 1.0, lerpf(3.0, 1.0, es))
	_draw_land_label(vp, center)


## 钓起展示标签：鱼名·稀有度（如"龙鱼·神话"），居中展示段显示，拉近淡入、飞走/缩小淡出
func _draw_land_label(vp: Vector2, center: Vector2) -> void:
	var m := minf(vp.x, vp.y)
	var a: float = 1.0
	if _land_t < 0.4:
		a = clampf(_land_t / 0.4, 0.0, 1.0)
	elif _land_t >= LAND_T:
		a = 1.0 - clampf((_land_t - LAND_T) / 0.35, 0.0, 1.0)
	if a <= 0.02:
		return
	var rar: String = KINDS[_land_kind].rar
	var fname: String = hud.t("fish." + _land_kind, _land_kind)
	var rname: String = hud.t("rar." + rar, rar)
	var font := ThemeDB.fallback_font
	var fs := int(m * 0.042)
	var sep := fs * 0.35
	var w1 := font.get_string_size(fname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w2 := font.get_string_size(rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var base := Vector2(center.x - (w1 + sep + w2) * 0.5, center.y + m * 0.20)
	var col_name := Color(1.0, 1.0, 1.0, a)
	var col_rar: Color = RARITY_COL[rar]
	col_rar.a = a
	var col_out := Color(0.05, 0.06, 0.05, a)
	var osize := int(fs * 0.22)
	draw_string_outline(font, base, fname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osize, col_out)
	draw_string(font, base, fname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col_name)
	draw_string_outline(font, base + Vector2(w1 + sep, 0.0), rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, osize, col_out)
	draw_string(font, base + Vector2(w1 + sep, 0.0), rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col_rar)


## 史诗/神话鱼展示：从鱼身向外放射五颜六色的光芒（太阳光式光线）
## 每根光线为向外张开的楔形（两节梯形拼成，外节渐隐），从鱼轮廓处向外射出；
## 色相随角度+时间流转、整组缓慢旋转、每根独立伸缩闪烁；画在鱼本体之下——
## 内端藏进鱼身后、外段透出轮廓之外，形成"鱼向外发光"的效果，大鱼也挡不住
func _draw_aura_glow(vp: Vector2, kind: String, pos: Vector2, rot: float, mult: float) -> void:
	var k: Dictionary = KINDS[kind]
	var rr: float = k.r * minf(vp.x, vp.y) * FISH_SHRINK * mult
	var m := minf(vp.x, vp.y)
	var rays := 12
	draw_set_transform(pos, rot, Vector2.ONE)
	for i in rays:
		var ang: float = TAU * i / rays + _time * 0.15
		var dir := Vector2(cos(ang), sin(ang))
		var n := Vector2(-dir.y, dir.x)
		var hue := fposmod(_time * 0.22 + float(i) / rays, 1.0)
		var tw_i := 0.5 + 0.5 * sin(_time * 3.0 + i * 1.7)   # 每根光独立闪烁相位
		var r0 := rr * 1.02                                   # 内端（藏入鱼身，被本体盖住）
		var length := m * (0.05 + 0.11 * tw_i)                # 光束长度（呼吸伸缩）
		var r1 := r0 + length
		var rm := r0 + length * 0.55
		var w0 := m * 0.010                                   # 内窄外宽的楔形
		var w1 := m * 0.030
		var wm := lerpf(w0, w1, 0.55)
		var a := 0.26 + 0.30 * tw_i
		var p_a := dir * r0
		var p_m := dir * rm
		var p_b := dir * r1
		var col_in := Color.from_hsv(hue, 0.70, 1.0, a)
		var col_out := Color.from_hsv(hue, 0.70, 1.0, a * 0.35)
		draw_colored_polygon(PackedVector2Array([p_a + n * w0, p_a - n * w0, p_m - n * wm, p_m + n * wm]), col_in)
		draw_colored_polygon(PackedVector2Array([p_m + n * wm, p_m - n * wm, p_b - n * w1, p_b + n * w1]), col_out)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 垃圾丢出段（水岸之上层绘制）：缩小完成后旋转着甩出画面下方
func _draw_land_throw(vp: Vector2) -> void:
	if state != State.LAND or int(KINDS[_land_kind].value) >= 0:
		return
	var t0 := LAND_T + LAND_SHRINK_T
	if _land_t < t0:
		return
	var m := minf(vp.x, vp.y)
	var cell := m * 0.040
	var center := Vector2(vp.x * 0.5, vp.y * 0.45)
	var e := clampf((_land_t - t0) / LAND_MOVE_T, 0.0, 1.0)
	var pos := Vector2(center.x + sin(e * 3.0) * m * 0.02, center.y + e * e * (vp.y - center.y + cell * 1.5))
	_draw_fish_sprite(vp, _land_kind, pos, e * PI * 2.0, 1.0, 1.0)


## 拔河中鱼的位置（从下水点被拉向岸边 + 冲刺横移 + 挣扎摆动）
func _fight_pos(vp: Vector2) -> Vector2:
	var land := Vector2(vp.x * 0.52, _y_shore - vp.y * 0.03)
	var hooked := Vector2(_float_x, _cast_to.y)   # 鱼从下水点开始（水面为平面，无深浅）
	var base := hooked.lerp(land, clampf(_progress, 0.0, 1.0))
	var struggle := sin(_time * (14.0 if _burst_on else 7.0)) * 6.0 * _u
	return base + Vector2(_run_x, struggle)


func _draw_gear(vp: Vector2) -> void:
	# —— 鱼竿（弯曲随拉力）——
	var base := _rod_base(vp)
	var tip := _rod_tip(vp)
	var bend := 0.12
	var ctrl := (base + tip) * 0.5 + Vector2(bend * vp.x * 0.10, bend * vp.y * 0.22)
	if state == State.FIGHT:
		# 上钩拔河：竿身大幅下弓 + 向鱼的方向侧弯
		bend = 0.16 + maxf(_fish_f, _player_f) * 0.40
		var dx := 0.0
		if not _fight_fish.is_empty():
			dx = _fight_pos(vp).x - base.x
		ctrl = (base + tip) * 0.5 + Vector2(
			bend * vp.x * 0.10 + clampf(dx * 0.18, -vp.x * 0.06, vp.x * 0.06),
			bend * vp.y * 0.26)
	elif state == State.BITE:
		# 咬钩：鱼拉线，竿身明显下弯（比待机弯得多，随挣扎脉动）
		bend = 0.30 + sin(_time * 9.0) * 0.05
		ctrl = (base + tip) * 0.5 + Vector2(bend * vp.x * 0.10, bend * vp.y * 0.24)
	elif state == State.REEL:
		# 自动收杆：竿身弯度平滑回落
		var rk := 1.0 - pow(1.0 - clampf(_reelin_t / REELIN_T, 0.0, 1.0), 2.0)
		bend = lerpf(0.50, 0.12, rk)
		ctrl = (base + tip) * 0.5 + Vector2(bend * vp.x * 0.10, bend * vp.y * lerpf(0.26, 0.22, rk))
	elif state == State.CAST:
		if _cast_t < CAST_WIND_T:
			# 后仰蓄力：竿身上弓（向后抬）
			var wind: float = clampf(_cast_t / CAST_WIND_T, 0.0, 1.0)
			ctrl = (base + tip) * 0.5 + Vector2(-vp.x * 0.05, -vp.y * 0.12) * wind
		else:
			# 前挥：竿身快速前弯回弹（正弦脉冲）
			var swing: float = clampf((_cast_t - CAST_WIND_T) / 0.18, 0.0, 1.0)
			ctrl = (base + tip) * 0.5 + Vector2(vp.x * 0.05, vp.y * 0.06) * sin(swing * PI)
	var pts := PackedVector2Array()
	for i in 13:
		var t := i / 12.0
		var p0 := base.lerp(ctrl, t)
		var p1 := ctrl.lerp(tip, t)
		pts.append(p0.lerp(p1, t))
	for i in 12:
		draw_line(pts[i], pts[i + 1], Color(0.32, 0.22, 0.14), lerpf(7.0, 2.4, i / 12.0) * _u)
	# 渔轮
	draw_circle(base + Vector2(10.0 * _u, 4.0 * _u), 8.0 * _u, Color(0.45, 0.5, 0.55))
	draw_arc(base + Vector2(10.0 * _u, 4.0 * _u), 8.0 * _u, 0, TAU, 16, Color(0.2, 0.22, 0.25), 2.0 * _u)
	# 鱼线
	var line_col := Color(0.92, 0.94, 0.92, 0.65)
	if state == State.FIGHT:
		line_col = Color(0.92, 0.94 - 0.6 * clampf(_lose_t / BREAK_T, 0.0, 1.0), 0.92 - 0.6 * clampf(_lose_t / BREAK_T, 0.0, 1.0), 0.8)
	if state == State.IDLE:
		# 待机：竿尖垂线挂着钩和浮漂（浮漂高度随深度档位）；
		# 鱼逃脱恢复期只显示浮漂（钩被鱼带走）。鱼线画在浮漂之上。
		var hang := vp.y * 0.10
		var hook_pos := tip + Vector2(0, hang)
		_draw_float(_idle_float_pos(vp), vp, 1.0)
		draw_line(tip, hook_pos, line_col, 1.4 * _u)
		if _rest_t <= 0.0:
			_draw_hook(hook_pos, vp)
	elif state == State.CAST:
		if _cast_t < CAST_WIND_T:
			# 后仰蓄力：浮漂收在竿尖下方短线悬挂
			var wind: float = clampf(_cast_t / CAST_WIND_T, 0.0, 1.0)
			var hang := tip + Vector2(0, (30.0 + 12.0 * wind) * _u)
			draw_line(tip, hang, line_col, 1.6 * _u)
			_draw_float(hang, vp, 1.0, false)
			_draw_hook(hang + Vector2(0, FLOAT_R * 4.4 * minf(vp.x, vp.y)), vp)
		else:
			# 大弧度抛物线：弧顶更高；鱼钩沿运动方向甩在浮漂前方
			var t2: float = clampf((_cast_t - CAST_WIND_T) / (CAST_T - CAST_WIND_T), 0.0, 1.0)
			var ct := (_cast_from + _cast_to) * 0.5 + Vector2(0, -vp.y * 0.26)
			var p0: Vector2 = _cast_from + Vector2(0, 42.0 * _u)
			var q0 := p0.lerp(ct, t2)
			var q1 := ct.lerp(_cast_to, t2)
			var fly := q0.lerp(q1, t2)
			var tangent := (_cast_to - p0).normalized()
			draw_line(tip, fly, line_col, 1.6 * _u)
			_draw_float(fly, vp, 1.0, false)
			_draw_hook(fly + tangent * FLOAT_R * 4.0 * minf(vp.x, vp.y) + Vector2(0, FLOAT_R * 1.2 * minf(vp.x, vp.y)), vp)
	elif state in [State.SINK, State.WAIT, State.BITE]:
		# 入水后只显示浮漂（在下水点，入水时渐显）；鱼饵与水下线/钩不显示
		# 主线：竿尖 → 浮漂顶端穿线点，浮漂悬挂在主线下端（鱼线画在浮漂之上）
		var fs := _float_state(vp)
		_draw_float(fs.pos, vp, fs.alpha)
		var tie: Vector2 = fs.pos + Vector2(0, -FLOAT_R * 2.2 * minf(vp.x, vp.y))
		draw_line(tip, tie, line_col, 1.6 * _u)
	elif state == State.FIGHT:
		# 拔河：浮漂留在水面原位并随上岸进度被拉向岸边（与鱼同步，竿尖侧稍偏不遮鱼），
		# 挣扎/爆发时抖动加剧；主线绷直 竿尖→浮漂（鱼线画在浮漂之上）
		var fp := _fight_pos(vp)
		var m2 := minf(vp.x, vp.y)
		var to_tip := (tip - fp).normalized()
		var fpos := fp + to_tip * FLOAT_R * 3.6 * m2
		fpos.y += sin(_time * (18.0 if _burst_on else 9.0)) * 2.5 * _u
		_draw_float(fpos, vp, 1.0)
		draw_line(tip, fpos, line_col, 1.8 * _u)
	elif state == State.REEL:
		# 自动收杆：浮漂沿主线从水面拉回竿尖挂位（吐钩时空钩跟着收回；断线钩已丢）
		var ke := 1.0 - pow(1.0 - clampf(_reelin_t / REELIN_T, 0.0, 1.0), 2.0)
		var dir := _reelin_from - tip
		var full := dir.length()
		dir = dir / maxf(full, 1.0)
		var hang := vp.y * 0.10
		var len_now: float = lerpf(full, hang, ke)
		var endp := tip + dir * len_now
		_draw_float(tip + dir * len_now * (1.0 - 0.30 * _depth), vp, 1.0)
		draw_line(tip, endp, line_col, 1.6 * _u)
		if _reelin_hook:
			_draw_hook(endp, vp)


## 待机竿上浮漂位置（竿尖垂线上，高度随深度档位低/中/高）
func _idle_float_pos(vp: Vector2) -> Vector2:
	var hang := vp.y * 0.10
	return _rod_tip(vp) + Vector2(0, hang * (1.0 - 0.30 * _depth))


## 浮漂状态：位置 = 钩下水点（水面是平面，浮漂就在下水处，无深浅沉浮）；
## FIGHT 阶段浮漂由 _draw_gear 直接按鱼线中点计算，不走此函数
func _float_state(vp: Vector2) -> Dictionary:
	var pos := Vector2(_float_x, _cast_to.y)
	var alpha := 1.0
	match state:
		State.SINK:
			var k: float = clampf(_sink_t / _sink_dur(), 0.0, 1.0)
			alpha = 0.25 + 0.75 * k                  # 入水渐显
			pos.y += sin(k * PI) * 3.0 * _u          # 落水轻微起伏
		State.WAIT:
			pos.y += sin(_time * 2.2) * 1.5 * _u     # 水面轻晃
		State.BITE:
			# 咬钩挣扎：大幅快速随机乱窜（多频正弦叠加，无固定轨迹）
			var fx: float = sin(_time * 13.7) + sin(_time * 7.3 + 1.7) * 0.6 + sin(_time * 23.1 + 4.2) * 0.4
			var fy: float = sin(_time * 17.3 + 2.0) + sin(_time * 9.7 + 0.6) * 0.5
			pos.x += fx * 16.0 * _u
			pos.y += fy * 5.0 * _u + sin(_time * 22.0) * 3.0 * _u
	return {"pos": pos, "alpha": alpha}


## 浮漂：红顶白底胶囊（入水时渐显，拔河时挂在线上）
func _draw_float(pos: Vector2, vp: Vector2, alpha: float, ripple := true) -> void:
	var r: float = FLOAT_R * minf(vp.x, vp.y)
	var a := clampf(alpha, 0.12, 1.0)
	draw_line(pos + Vector2(0, -r * 2.2), pos + Vector2(0, -r * 1.1), Color(0.9, 0.9, 0.9, a), 2.4 * _u)
	draw_circle(pos, r, Color(0.90, 0.26, 0.22, a))
	draw_rect(Rect2(pos.x - r, pos.y, r * 2, r * 1.2), Color(0.95, 0.95, 0.92, a))
	draw_arc(pos, r, 0, TAU, 16, Color(0.15, 0.12, 0.10, a), 2.2 * _u)
	draw_line(pos + Vector2(-r, r * 1.2), pos + Vector2(r, r * 1.2), Color(0.15, 0.12, 0.10, a), 2.2 * _u)
	if ripple:   # 水面交界波纹（抛竿飞行中不显示）
		draw_arc(pos, r * 1.7, 0, TAU, 20, Color(0.85, 0.97, 1.0, 0.35 * a), 1.8 * _u)


## 鱼钩：J 形 + 鱼饵贴图
func _draw_hook(pos: Vector2, vp: Vector2) -> void:
	var s: float = 0.008 * minf(vp.x, vp.y)
	draw_arc(pos + Vector2(0, s * 0.6), s, PI * 0.1, PI * 1.35, 10, Color(0.75, 0.78, 0.8), 2.2 * _u)
	draw_line(pos + Vector2(0, 0), pos + Vector2(0, s * 0.8), Color(0.75, 0.78, 0.8), 2.2 * _u)
	var bait: Dictionary = BAITS[_bait]
	if _bait != "none" and bait.tex != "":
		var tex: Texture2D = _tex.get(bait.tex)
		if tex != null:
			var bs := 0.036 * minf(vp.x, vp.y) / 128.0
			var tint: Color = bait.get("tint", Color.WHITE)
			draw_set_transform(pos + Vector2(0, s * 1.3), 0.0, Vector2(bs, bs))   # 鱼饵紧钩在钩弧内
			draw_texture(tex, Vector2(-64, -64), tint)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_ripples() -> void:
	for r: Dictionary in _ripples:
		var k: float = r.t / r.life
		var rad: float = r.r0 * (0.35 + 1.6 * k)
		var a: float = (1.0 - k) * 0.7
		draw_set_transform(r.pos, 0.0, Vector2(1.0, 0.32))
		draw_arc(Vector2.ZERO, rad, 0.0, TAU, 32, Color(0.85, 0.97, 1.0, a), 2.2 * _u)
		draw_arc(Vector2.ZERO, rad * 0.55, 0.0, TAU, 24, Color(0.85, 0.97, 1.0, a * 0.6), 1.6 * _u)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_splashes() -> void:
	for sp: Dictionary in _splashes:
		var frame := int(sp.t / 0.055)
		if frame > 6:
			continue
		var tex: Texture2D = _tex.get("splash_%d" % frame)
		if tex == null:
			continue
		var sz: float = 150.0 * sp.sc * _u
		draw_texture_rect(tex, Rect2(sp.pos - Vector2(sz * 0.5, sz * 0.72), Vector2(sz, sz)), false)


func _draw_drops() -> void:
	for dp: Dictionary in _drops:
		var a: float = 1.0 - dp.t / dp.life
		draw_circle(dp.pos, dp.r, Color(0.82, 0.95, 1.0, a * 0.85))


func _draw_bubbles() -> void:
	for bb: Dictionary in _bubbles:
		var a: float = (1.0 - bb.t / bb.life) * 0.55
		draw_arc(bb.pos, bb.r, 0.0, TAU, 10, Color(0.9, 0.98, 1.0, a), 1.4 * _u)


func _draw_shore(vp: Vector2) -> void:
	# 岸坡：土色 + 草缘 + 碎石
	draw_rect(Rect2(0, _y_shore, vp.x, vp.y - _y_shore), Color(0.48, 0.38, 0.26))
	draw_rect(Rect2(0, _y_shore, vp.x, 6.0 * _u), Color(0.58, 0.48, 0.32))   # 湿土边
	for g: Dictionary in _grass:
		var col := Color(0.32 + g.col * 0.12, 0.55 + g.col * 0.15, 0.22)
		draw_line(g.pos, g.pos + Vector2(g.lean * g.h, -g.h), col, 2.6 * _u)
		draw_line(g.pos + Vector2(3.0 * _u, 0), g.pos + Vector2(3.0 * _u + g.lean * g.h * 0.7, -g.h * 0.7), col, 2.2 * _u)
	for pb: Dictionary in _pebbles:
		draw_circle(pb.pos, pb.r, Color(pb.col, pb.col * 0.92, pb.col * 0.8))
		draw_arc(pb.pos, pb.r, 0, TAU, 10, Color(0.25, 0.2, 0.15, 0.5), 1.4 * _u)


func _draw_props(vp: Vector2) -> void:
	# 木桶 / 塑料盒
	var m := minf(vp.x, vp.y)
	var bucket_tex: Texture2D = _tex.get("bucket")
	if bucket_tex != null:
		var r := _bucket_rect(vp)
		draw_texture_rect(bucket_tex, Rect2(r.position, r.size), false)
	var box_tex: Texture2D = _tex.get("box")
	if box_tex != null:
		var r2 := _box_rect(vp)
		draw_texture_rect(box_tex, Rect2(r2.position, r2.size), false)
	# 装备状态小字（鱼饵 + 深度）——hud 未初始化（无头冒烟）时跳过
	if hud == null:
		return
	var bait_label: String = hud.t("ui.bait_none", "No Bait")
	if _bait != "none":
		bait_label = hud.t("bait." + _bait, _bait)
	var depth_label: String = hud.t("depth." + str(_depth), str(_depth))
	var info := "%s · %s" % [bait_label, depth_label]
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(vp.x * 0.5 - m * 0.12, _y_shore + (vp.y - _y_shore) * 0.86),
			info, HORIZONTAL_ALIGNMENT_CENTER, m * 0.24, int(m * 0.020), Color(1, 1, 1, 0.6))


func _draw_carry(vp: Vector2) -> void:
	# 手持打窝饵跟随鼠标：一大把饵料（当前打窝饵贴图堆叠成捧）
	if _carrying == "" or _menu_layer != null:
		return
	var mp := get_global_mouse_position()
	var bob := sin(_time * 4.0) * 2.0 * _u
	var m := minf(vp.x, vp.y)
	var tex: Texture2D = _tex.get(CHUMS[_carrying].tex)
	if tex != null:
		var rng := RandomNumberGenerator.new()
		rng.seed = 88
		for i in 9:
			var off := Vector2(rng.randf_range(-18.0, 18.0), rng.randf_range(-10.0, 8.0)) * _u + Vector2(0, bob)
			var s: float = (m * 0.044) if i == 0 else (m * rng.randf_range(0.018, 0.030))
			var jolt := 1.0 + sin(_time * 6.0 + i * 1.7) * 0.06   # 轻微呼吸
			s *= jolt
			draw_texture_rect(tex, Rect2(mp + off - Vector2(s, s) * 0.5, Vector2(s, s)), false)
		# 散落小粒
		for j in 4:
			var off2 := Vector2(sin(_time * 5.0 + j * 2.1) * 20.0, 10.0 + cos(_time * 4.0 + j) * 4.0) * _u + Vector2(0, bob)
			draw_circle(mp + off2, 2.6 * _u, Color(0.44, 0.32, 0.20))
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = 88
		for i in 7:
			var off := Vector2(rng.randf_range(-16.0, 16.0), rng.randf_range(-12.0, 6.0)) * _u + Vector2(0, bob)
			draw_circle(mp + off, rng.randf_range(4.0, 8.0) * _u, Color(0.44, 0.32, 0.20))
	# 提示圈
	draw_arc(mp, 24.0 * _u, 0, TAU, 24, Color(1, 1, 1, 0.35), 2.0 * _u)


func _draw_caught(vp: Vector2) -> void:
	# 顶左：钓起的鱼（头朝上，水平排列，超 1/3 屏宽换行）
	if _caught.is_empty():
		return
	var m := minf(vp.x, vp.y)
	var cell := m * 0.040
	var gap := cell * 0.35
	var x0 := 18.0 * _u
	var y0 := 84.0 * _u
	var x := x0
	var y := y0
	for kind: String in _caught:
		var tex: Texture2D = _tex.get(KINDS[kind].tex)
		if tex == null:
			continue
		var s := cell / 128.0
		# 贴图头朝左 → 顺时针转 90° 头朝上；后画的（新鱼）覆盖先画的，左半叠在旧鱼右半上
		draw_set_transform(Vector2(x + cell * 0.5, y + cell * 0.5), PI / 2.0, Vector2(s, s))
		draw_texture(tex, Vector2(-64, -64))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		x += cell * 0.5
		if x + cell > vp.x / 3.0:
			x = x0
			y += cell + gap * 0.6


## 拔河拉力计（按下左键瞬间固定在鼠标右侧，钓起/脱钩后消失；
## 白=玩家拉力，两条红线=安全区间，间距由鱼种决定，拉力须保持在两线之间）
func _draw_gauge(vp: Vector2) -> void:
	if state != State.FIGHT:
		return
	var m := minf(vp.x, vp.y)
	var h := vp.y * 0.40
	var w := 14.0 * _u
	# 竖条以按下点为中心、出现在其右侧（clamp 防出屏/压 HUD）
	var x := clampf(_gauge_pos.x + 26.0 * _u, 10.0 * _u, vp.x - w - 10.0 * _u)
	var y0 := clampf(_gauge_pos.y - h * 0.5, 90.0 * _u, vp.y - h - 20.0 * _u)
	draw_rect(Rect2(x, y0, w, h), Color(0, 0, 0, 0.35))
	# 玩家拉力（从下往上充）
	var ph := h * clampf(_player_f, 0.0, 1.0)
	draw_rect(Rect2(x, y0 + h - ph, w, ph), Color(0.85, 0.95, 1.0, 0.9))
	# 两条红线（安全区间，随鱼挣扎缓慢移动）
	var zone: Dictionary = _fight_zone()
	var ly := y0 + h * (1.0 - clampf(float(zone.low), 0.0, 1.0))
	var hy := y0 + h * (1.0 - clampf(float(zone.high), 0.0, 1.0))
	draw_rect(Rect2(x - 4.0 * _u, ly - 1.5 * _u, w + 8.0 * _u, 3.0 * _u), Color(1.0, 0.35, 0.25, 0.95))
	draw_rect(Rect2(x - 4.0 * _u, hy - 1.5 * _u, w + 8.0 * _u, 3.0 * _u), Color(1.0, 0.35, 0.25, 0.95))
	# 危险累积（超出红线 1.2s 断线）：红罩渐显
	if _lose_t > 0.0:
		var danger := clampf(_lose_t / BREAK_T, 0.0, 1.0)
		draw_rect(Rect2(x, y0, w, h), Color(1.0, 0.2, 0.15, 0.25 * danger))
	# 顶部小字
	var font := ThemeDB.fallback_font
	var lb: String = hud.t("hud.pull", "Pull")
	draw_string(font, Vector2(x - 6.0 * _u, y0 - 10.0 * _u), lb, HORIZONTAL_ALIGNMENT_LEFT, 60.0 * _u, int(m * 0.020), Color(1, 1, 1, 0.8))


func _draw_popups(vp: Vector2) -> void:
	var m := minf(vp.x, vp.y)
	var font := ThemeDB.fallback_font
	var idx := 0
	for pp: Dictionary in _popups:
		var k: float = pp.t / pp.life
		var a: float = clampf(k * 6.0, 0.0, 1.0) * (1.0 - maxf((k - 0.6) / 0.4, 0.0))
		var pos := Vector2(vp.x / 2.0, vp.y * 0.40 + idx * m * 0.055 - k * 34.0 * _u)
		draw_string(font, pos - Vector2(vp.x, 0), pp.text, HORIZONTAL_ALIGNMENT_CENTER,
				vp.x * 2.0, int(m * 0.045), Color(pp.col.r, pp.col.g, pp.col.b, a))
		idx += 1


# ===== 音效（程序合成）=====

func _tone(f0: float, f1: float, dur: float, square: bool, vol: float) -> PackedByteArray:
	var rate := 22050
	var n := maxi(1, int(dur * rate))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(n)
		phase += TAU * lerpf(f0, f1, t) / rate
		var s := (1.0 if fmod(phase, TAU) < PI else -1.0) if square else sin(phase)
		var env := (1.0 - t) * (1.0 - t)
		bytes.encode_s16(i * 2, int(clampf(s * env * vol, -1.0, 1.0) * 32000))
	return bytes


func _noise(dur: float, vol: float, lp: float) -> PackedByteArray:
	var rate := 22050
	var n := maxi(1, int(dur * rate))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var acc := 0.0
	for i in n:
		var t := float(i) / float(n)
		acc = lerpf(acc, randf_range(-1.0, 1.0), 1.0 / maxf(lp, 1.0))
		var env := (1.0 - t) * (1.0 - t)
		bytes.encode_s16(i * 2, int(clampf(acc * env * vol, -1.0, 1.0) * 32000))
	return bytes


## parts 元素：["t", f0, f1, dur, square, vol] 音调 / ["n", dur, vol, lp] 噪声
func _sfx_stream(parts: Array) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = 22050
	var all := PackedByteArray()
	for p: Array in parts:
		if p[0] == "t":
			all.append_array(_tone(p[1], p[2], p[3], p[4], p[5]))
		else:
			all.append_array(_noise(p[1], p[2], p[3]))
	st.data = all
	return st


## 加载下载的真实音效（免版权/已授权，assets/sfx/），覆盖同名合成音效；ogg/wav/mp3 字节解码
func _load_sfx_file(key: String, fname: String) -> void:
	for base: String in ["res://games/fish_hook/assets/sfx/" + fname, "res://assets/sfx/" + fname]:
		var f := FileAccess.open(base, FileAccess.READ)
		if f == null:
			continue
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var stream: AudioStream = null
		if fname.ends_with(".ogg"):
			stream = AudioStreamOggVorbis.load_from_buffer(bytes)
		elif fname.ends_with(".wav"):
			stream = AudioStreamWAV.load_from_buffer(bytes)
		elif fname.ends_with(".mp3"):
			stream = AudioStreamMP3.load_from_buffer(bytes)
		if stream != null:
			_sfx[key] = stream
		return


func _init_sfx() -> void:
	_sfx["throw"] = _sfx_stream([["n", 0.14, 0.28, 4.0], ["t", 260.0, 720.0, 0.14, false, 0.25]])
	_sfx["cast"] = _sfx_stream([["n", 0.18, 0.34, 4.0], ["t", 300.0, 900.0, 0.16, false, 0.28]])
	_sfx["plop"] = _sfx_stream([["t", 220.0, 110.0, 0.12, true, 0.4], ["n", 0.08, 0.3, 3.0]])
	_sfx["splash"] = _sfx_stream([["n", 0.30, 0.55, 2.0], ["t", 160.0, 60.0, 0.2, false, 0.4]])
	_sfx["bite"] = _sfx_stream([["t", 320.0, 190.0, 0.09, false, 0.5], ["t", 260.0, 150.0, 0.11, false, 0.5]])
	_sfx["hook"] = _sfx_stream([["t", 500.0, 260.0, 0.08, false, 0.45], ["n", 0.05, 0.3, 3.0]])
	_sfx["reel"] = _sfx_stream([["t", 880.0, 860.0, 0.03, true, 0.22]])
	_sfx["snap"] = _sfx_stream([["n", 0.07, 0.75, 2.0], ["t", 700.0, 110.0, 0.28, false, 0.5]])
	_sfx["catch"] = _sfx_stream([["t", 523.0, 523.0, 0.09, false, 0.35], ["t", 659.0, 659.0, 0.09, false, 0.35], ["t", 784.0, 784.0, 0.16, false, 0.4]])
	_sfx["combo"] = _sfx_stream([["t", 523.0, 523.0, 0.07, false, 0.35], ["t", 659.0, 659.0, 0.07, false, 0.35], ["t", 784.0, 784.0, 0.07, false, 0.38], ["t", 1046.0, 1046.0, 0.14, false, 0.4]])
	_sfx["trash"] = _sfx_stream([["t", 300.0, 160.0, 0.22, true, 0.35], ["t", 220.0, 110.0, 0.26, true, 0.3]])
	_sfx["chum"] = _sfx_stream([["n", 0.22, 0.4, 3.0], ["t", 180.0, 90.0, 0.16, false, 0.35]])
	_sfx["pick"] = _sfx_stream([["t", 520.0, 780.0, 0.09, false, 0.35]])
	_sfx["record"] = _sfx_stream([["t", 523.0, 523.0, 0.09, false, 0.35], ["t", 659.0, 659.0, 0.09, false, 0.35], ["t", 784.0, 784.0, 0.09, false, 0.38], ["t", 1046.0, 1046.0, 0.2, false, 0.42]])
	# 真实音效覆盖（CC0 下载，OpenGameArt：Skippy Fish 水声 / Fisheefects / rubberduck 水花包）
	_load_sfx_file("plop", "waterreentry.ogg")     # 饵团入水·鱼回水扑通
	_load_sfx_file("splash", "splash_01.ogg")      # 鱼跃落水大水花
	_load_sfx_file("cast", "swim.ogg")             # 挥竿划水
	_load_sfx_file("bite", "bloop.mp3")            # 咬钩泡泡
	_load_sfx_file("hook", "bubbles.ogg")          # 刺鱼气泡
	_load_sfx_file("snap", "crowd_aww.mp3")        # 鱼脱钩/吐钩·多人叹气声
	_load_sfx_file("cheer", "crowd_cheer.ogg")     # 大型鱼/稀有鱼钓起·群体欢呼
	_load_sfx_file("catch", "point_special.mp3")   # 钓起得分
	_load_sfx_file("combo", "point_normal.mp3")    # 连击加分
	_load_sfx_file("chum", "eating.ogg")           # 打窝撒饵
	_load_sfx_file("trash", "slime_12.ogg")        # 垃圾黏液
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM）
	for base: String in ["res://games/fish_hook/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
		var bf := FileAccess.open(base, FileAccess.READ)
		if bf != null:
			var st := AudioStreamMP3.load_from_buffer(bf.get_buffer(bf.get_length()))
			st.loop = true
			_bgm = AudioStreamPlayer.new()
			_bgm.stream = st
			_bgm.volume_db = BGM_DB
			add_child(_bgm)
			if hud.bgm_on:
				_bgm.play()
			break


func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	var stream: AudioStream = _sfx.get(sfx_name)
	if stream == null:
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


# ===== 开发者模式（参考打砖块：排行榜面板 5 秒点 10 次 → 关闭后弹调试窗口）=====

func _arm_dev_clicks() -> void:
	var panel := get_node_or_null("LeaderboardPanel")
	if panel != null:
		panel.gui_input.connect(_dev_panel_input)


func _dev_panel_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT
			and event.pressed):
		return
	var now := Time.get_ticks_msec()
	if now - _dev_click_ms > 5000:   # 超过 5 秒重新计数
		_dev_clicks = 0
	_dev_click_ms = now
	_dev_clicks += 1
	if _dev_clicks >= 10 and not _dev_pending:
		_dev_pending = true
		var panel := get_node_or_null("LeaderboardPanel")
		if panel != null:   # 标题变金色反馈
			var head := panel.get_child(0)
			if head is Container and head.get_child(0) is Label:
				(head.get_child(0) as Label).add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))


func _show_dev_window() -> void:
	if _dev_win != null and is_instance_valid(_dev_win):
		return
	var vp := get_viewport_rect().size
	_dev_win = PanelContainer.new()
	_dev_win.process_mode = Node.PROCESS_MODE_ALWAYS   # 排行榜暂停中也可调参
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.15, 0.15, 0.96)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(12)
	_dev_win.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_dev_win.add_child(vb)
	# 标题栏（拖动把手）+ 关闭
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	vb.add_child(head)
	var title := Label.new()
	title.text = "DEV MODE"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 6)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := GameHud.make_button("✕")
	close_btn.pressed.connect(_dev_close)
	head.add_child(close_btn)
	# 按钮网格
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)
	var actions := [
		[hud.t("dev.bite_now", "Bite Now"), _dev_bite_now_act, hud.t("dev.tip_bite_now", "Instant bite: triggers a bite on the next frame while waiting")],
		[hud.t("dev.land_now", "Land Now"), _dev_land_now_act, hud.t("dev.tip_land_now", "Instant land: pulls the fish to shore into the catch show")],
		[hud.t("dev.rar_force", "Force Rarity"), _dev_rar_cycle, hud.t("dev.tip_rar_force", "Force bite rarity: click/scroll = next, right-click = prev (off → common → ... → junk)")],
		[hud.t("dev.score", "Score +100"), _dev_score_act, hud.t("dev.tip_score", "Adds 100 score and commits to the leaderboard")],
		[hud.t("dev.combo", "Combo x3"), _dev_combo_act, hud.t("dev.tip_combo", "Sets combo to x3")],
		[hud.t("dev.bite_avg", "Avg Bite 5s"), _dev_bite_avg_act, hud.t("dev.tip_bite_avg", "Sets bite rate to about one bite per 5 s (mult 5.0)")],
	]
	for a: Array in actions:
		var b: Button = GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(176.0, 30.0)
		b.clip_text = true
		b.tooltip_text = a[2]   # 悬停提示
		b.pressed.connect(a[1])
		grid.add_child(b)
	_dev_rar_btn = grid.get_child(2)   # 强制稀有度按钮（文字/颜色随循环更新）
	# 右键/滚轮上=反向循环
	_dev_rar_btn.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_dev_rar_cycle(-1)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_dev_rar_cycle(1))
	# 滑块：咬钩率 / 鱼力 / 收线速度
	_dev_add_slider(vb, hud.t("dev.bite_rate", "Bite Rate"), _dev_bite_mult, 0.0, 20.0, hud.t("dev.tip_bite_rate", "Global bite-rate multiplier (base rate x bait x chum)"), func(v: float) -> void:
		_dev_bite_mult = v)
	_dev_add_slider(vb, hud.t("dev.fish_str", "Fish Strength"), _dev_fish_mult, 0.1, 2.0, hud.t("dev.tip_fish_str", "Global fish-strength multiplier (base and burst both scaled)"), func(v: float) -> void:
		_dev_fish_mult = v)
	_dev_add_slider(vb, hud.t("dev.reel_speed", "Reel Speed"), _dev_reel_mult, 0.2, 5.0, hud.t("dev.tip_reel_speed", "Reel speed multiplier (shore progress rate)"), func(v: float) -> void:
		_dev_reel_mult = v)
	add_child(_dev_win)
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 标题栏拖动
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += event.relative)


## 调试滑块行：左侧标签（显示当前值），右侧 HSlider；tip 为悬停提示
func _dev_add_slider(parent: Control, label: String, init: float, mn: float, mx: float, tip: String, on_change: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.tooltip_text = tip
	parent.add_child(row)
	var lb := Label.new()
	lb.text = "%s ×%.2f" % [label, init]
	lb.add_theme_font_size_override("font_size", 13)
	lb.custom_minimum_size = Vector2(150.0, 0)
	lb.add_theme_color_override("font_color", Color.WHITE)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 4)
	row.add_child(lb)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = 0.05
	sl.value = init
	sl.custom_minimum_size = Vector2(140.0, 20.0)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.value_changed.connect(func(v: float) -> void:
		on_change.call(v)
		lb.text = "%s ×%.2f" % [label, v])
	row.add_child(sl)


func _dev_close() -> void:
	_dev_drag = false
	if _dev_win != null and is_instance_valid(_dev_win):
		_dev_win.queue_free()
	_dev_win = null


## 调试按钮动作
func _dev_bite_now_act() -> void:
	if state == State.WAIT:
		_dev_bite_now = true
	else:
		_popup("Bite Now: need WAIT state", Color(1.0, 0.6, 0.4))


func _dev_land_now_act() -> void:
	if state == State.FIGHT:
		_progress = 1.0   # 下一帧触发钓起
	else:
		_popup("Land Now: need FIGHT state", Color(1.0, 0.6, 0.4))


## 强制稀有度循环（dir=1 下一个 / -1 上一个，共 8 档："" + 七档稀有度）
func _dev_rar_cycle(dir: int = 1) -> void:
	_dev_rar_i = wrapi(_dev_rar_i + dir, 0, DEV_RARS.size())
	if _dev_rar_btn != null and is_instance_valid(_dev_rar_btn):
		if _dev_rar_i == 0:   # 关闭（跟随自然概率）
			_dev_rar_btn.text = hud.t("dev.rar_force", "Force Rarity")
			_dev_rar_btn.remove_theme_color_override("font_color")
			_dev_rar_btn.tooltip_text = hud.t("dev.tip_rar_force", "Force bite rarity: click/scroll = next, right-click = prev")
		else:
			var rar: String = DEV_RARS[_dev_rar_i]
			_dev_rar_btn.text = hud.t("rar." + rar, rar)
			_dev_rar_btn.add_theme_color_override("font_color", RARITY_COL[rar])
			_dev_rar_btn.tooltip_text = "%s: %s" % [hud.t("dev.rar_force", "Force Rarity"), hud.t("rar." + rar, rar)]


func _dev_score_act() -> void:
	score += 100
	_refresh_boards()
	hud.commit_run(score, count)
	_popup("DEV: score +100", Color(1.0, 0.85, 0.25))


func _dev_combo_act() -> void:
	combo = 3
	_popup("DEV: combo x3", Color(1.0, 0.85, 0.25))


func _dev_bite_avg_act() -> void:
	_dev_bite_mult = 5.0
	_popup("DEV: bite rate x5 (~5s/bite)", Color(1.0, 0.85, 0.25))
