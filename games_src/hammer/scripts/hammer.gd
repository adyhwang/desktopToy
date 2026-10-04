extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 铁锤打害虫：蟑螂/苍蝇/蚊子/老鼠从四边随机生成，沿飘忽路线扑向屏幕正中的水果
## 铁锤光标程序绘制：鼠标点=贴图左下角（锤悬在指针右上方），左键挥锤——绕柄尾锚点逆时针抡 90° 钟形曲线，
## 抡到位（动画半程）瞬间以锤头落点做命中判定/落空裂纹（锤子跟手）
## 害虫抵达水果扣 1 命并污染水果（外观逐次变腐），9 命起步、99 上限，每打死 9 只 +1 命，归零结束弹排行榜
## 尸体保留在地面（上限 20 只，超出淡出移除最旧）；老鼠 100 分后解锁
## 难度：得分越高生成间隔越短、高阶害虫权重越高；移动速度不变
## 害虫轨迹（见 pest.gd）：生成时随机水果周围目标点不直奔中心 + 差异化形态（蟑螂小幅折线 /
## 苍蝇飞一段抖一段交替 / 蚊子 1 秒转圈+左右抖动 / 老鼠大弧迂回+停顿冲刺）+ 每 1~2 秒试探微调方向
## 道具系统（参考打砖块）：击杀概率掉落徽章，点击图标激活——
## 大锤/双锤/喷雾/吸尘器为替换型互斥（光标形态切换），双倍得分/机器猫/额外生命即时或共存；
## 激活效果在界面右侧竖排显示英文名 + 实时倒计时

const Pest := preload("res://scripts/pest.gd")
const Cat := preload("res://scripts/cat.gd")
const GameHud := preload("res://scripts/game_hud.gd")

enum State { PLAY, OVER }

const LIVES_START := 9
const RAT_UNLOCK := 100           # 老鼠出现分数线
const MAX_PESTS := 10             # 同屏活虫上限（尸体不占名额）
const SPAWN_INTERVAL_START := 2.2
const SPAWN_INTERVAL_MIN := 0.7
const SPAWN_STEP_SCORE := 15      # 每此分数生成间隔收紧一档
const SPAWN_STEP_DELTA := 0.1
const GRACE_T := 1.0              # 开局首只害虫缓冲（s）
const SWING_T := 0.16             # 挥锤动画时长（s）：钟形曲线逆时针抡 90° 再回弹，半程=抡到位结算
const HIT_PAD := 12.0             # 命中判定外放（px，×_u）——卡通手感从宽
const CURSOR_CANVAS := 256.0      # 锤光标贴图画布边长
const HAMMER_TEX := 192.0         # 锤光标显示边长（px，×_u，随窗口缩放）
const HAMMER_HOT := Vector2(0, 256)       # 鼠标点=贴图左下角（画布坐标）
const HAMMER_PIVOT := Vector2(116, 220)   # 柄尾（挥锤旋转锚点，画布坐标）
const HAMMER_HEAD := Vector2(115, 60)     # 锤头中心（命中/落痕点，画布坐标）
const MAX_CRACKS := 20            # 地面裂纹上限（超出移除最旧）
const CORPSE_MAX := 20            # 尸体保留上限（超出淡出移除最旧）
const KILLS_PER_LIFE := 9         # 每打死此数害虫 +1 命（上限 LIVES_CAP）
const GAMEOVER_T := 1.3           # 结束后延迟弹排行榜（s）：等掉命动画 + 结束音乐播完
const DROP_T := 0.45              # 喷雾液滴寿命（s）
const FRUIT_ROT_TINT := Color(0.72, 0.80, 0.46)   # 污染变质目标色

# 害虫配置：speed px/s@108p 基准（全程不变）；rad/amp 为 min边 × 系数；
# hp 随机区间 [下限, 上限]；amp/freq 轨迹摆动幅度与频率（轨迹形态差异化实现见 pest.gd：
# 蟑螂小幅折线最直 / 苍蝇飞一段抖一段交替（仅用 amp/freq）/ 蚊子 1 秒转圈（amp 置 0）/ 老鼠大弧迂回+停顿冲刺）
const KINDS := {
	"roach": {"value": 10, "hp": [1, 2], "speed": 48.0, "rad": 0.058, "amp": 9.0, "freq": 0.9, "fps": 7.0},
	"mos": {"value": 15, "hp": [1, 1], "speed": 72.0, "rad": 0.032, "amp": 0.0, "freq": 0.9, "fps": 16.0},
	"fly": {"value": 20, "hp": [1, 1], "speed": 90.0, "rad": 0.036, "amp": 12.0, "freq": 2.6, "fps": 14.0},
	"rat": {"value": 30, "hp": [3, 4], "speed": 125.0, "rad": 0.066, "amp": 34.0, "freq": 0.3, "fps": 9.0},
}

const SFX_DB := -4.0
const BGM_DB := -6.0
const SFX_POOL := 4

# ===== 道具系统（参考打砖块：击杀概率掉落徽章，点击图标激活）=====
const DROP_RATE := 0.25         # 击杀掉落概率
const LIVES_CAP := 99           # 生命上限（击杀奖励与加命道具共同上限）
const PU_SIZE := 0.066          # 掉落徽章显示直径 = min边 × 系数
const PU_PICK_R := 0.036        # 徽章点击判定半径 = min边 × 系数
const PU_LIFE_T := 12.0         # 掉落徽章存活（s），末 3 秒闪烁
const EFFECT_DUR := {"big": 8.0, "dual": 8.0, "spray": 7.0, "double": 10.0, "vacuum": 10.0}
const SWAPS := ["big", "dual", "spray", "vacuum"]   # 替换型（光标形态）互斥：新顶旧
const PU_NAME := {"big": "Big Hammer", "dual": "Dual Hammers", "spray": "Insect Spray",
		"double": "Double Score", "vacuum": "Vacuum", "life": "+1 Life", "cat": "Robot Cat"}
const PU_TEX := {"big": "pu_big.png", "dual": "pu_dual.png", "spray": "pu_spray.png",
		"double": "pu_double.png", "vacuum": "pu_vacuum.png", "life": "pu_life.png", "cat": "pu_cat.png"}
const BIG_SCALE := 1.3         # 大号铁锤显示尺寸倍数（命中范围仍由 BIG_HIT_MULT 控制）
const BIG_HIT_MULT := 2.0       # 大号铁锤命中半径倍数（打击范围扩大 100%）
const BIG_DMG := 999            # 大号铁锤伤害（秒杀任何害虫，无视耐久）
const DUAL_OFF := Vector2(78.0, 46.0)   # 副锤相对主光标偏移（px@1080p ×_u），两锤范围不重叠
const SPRAY_R := 0.11           # 喷雾策反半径 = min边 × 系数
const VACUUM_R := 0.20          # 吸尘器吸取半径（基础命中 ×3，范围内全吸正常计分）
const CAT_SPEED := 250.0        # 机器猫速度 px/s@1080p 基准（老鼠 125 × 2）
const SPRAY_HOTSPOT := Vector2(32, 17)    # 喷雾光标热点 = 喷嘴口
const VACUUM_HOTSPOT := Vector2(12, 71)   # 吸尘器光标热点 = 吸嘴口
const RING_T := 0.35            # 喷雾/吸附特效圈时长（s）

var hud: RefCounted
var score := 0
var lives := LIVES_START
var pollutions := 0               # 水果被污染次数（外观渐腐）
var state := State.PLAY

var _u := 1.0                     # 全局缩放 = min边 / 1080
var _fruit_r := 60.0
var _spawn_t := GRACE_T
var _swing_t := -1.0              # >=0 挥锤动画剩余时长（钟形曲线相位）
var _hammer_wait := false         # true=已起挥待落：抡到 -90°（动画半程）时结算落痕
var _arrow_shown := false         # 当前显示系统箭头（UI 悬停切换跟踪）
var _fx_hammer: Node2D            # 锤光标独立层（z_index=100，压在害虫/水果/浮字等所有图层之上）
var _crosshair: Sprite2D          # 道具（喷雾/吸尘器）施加点瞄准星（复用飞镖 crosshair 素材）
var _cat_bark_t := 0.0            # 机器猫在场随机猫叫倒计时（s）
var _cracks: Array = []           # 地面裂纹 [{segs: Array[PackedVector2Array]}]
var _tex := {}
var _sfx := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _squeak_t := 3.0              # 害虫移动声随机计时
var _fruit_base_scale := Vector2.ONE
var _time := 0.0
var _effects := {}                # 激活效果：效果名 → 剩余秒（参考打砖块）
var _effect_labels := {}          # 右侧倒计时浮字（效果名 → Label）
var _rings: Array = []            # 喷雾/吸附特效圈 {pos, r0, r1, t, col}
var _drops: Array = []            # 喷雾液滴 {pos, vel, t}
var _corpses: Array = []          # 保留的害虫尸体（超 CORPSE_MAX 淡出移除最旧）
var _kills := 0                   # 本局击杀数（每 KILLS_PER_LIFE 只 +1 命）
var _over_t := 0.0                # OVER 后延迟弹排行榜倒计时（s）
var _over_rank := -1              # 结算名次（_game_over 时缓存）

# 开发者模式：排行榜弹出后 5 秒内点击面板满 10 次 → 关闭后弹出可拖动调试窗口（参考打砖块）
var _dev_pending := false         # 已触发暗门，等排行榜关闭
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_speed := 1.0             # 害虫速度倍率（滑块，生成时施加）
var _dev_spawn := 1.0             # 生成间隔倍率（滑块，越小刷得越快）
var _dev_drop := DROP_RATE        # 道具掉率（滑块直接覆盖）
var _dev_win: PanelContainer
var _dev_drag := false

@onready var _pests_root: Node2D = $Pests
@onready var _pups_root: Node2D = $Pups
@onready var _cats_root: Node2D = $Cats
@onready var _fruit: Sprite2D = $Fruit
@onready var _score_board: Label = $HudBar/ScoreBoard
@onready var _lives_board: Label = $HudBar/LivesBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _hbox: HBoxContainer


func start() -> void:
	randomize()
	hud = GameHud.new("hammer")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_fruit.texture = _tex["fruit"]
	_setup_buttons()
	_init_sfx()
	_refresh_boards()
	# 道具施加点瞄准星：复用飞镖 crosshair 素材，随道具效果显隐（_process 跟鼠标、_layout 定尺寸）
	_crosshair = Sprite2D.new()
	_crosshair.texture = _load_png("assets/crosshair.png")
	_crosshair.z_index = 101
	_crosshair.visible = false
	add_child(_crosshair)
	# 锤光标独立层：父节点 _draw 天然在 add_child 的子节点（害虫/水果/尸体/浮字）之下，
	# 会被遮挡；锤子必须压在所有图层之上（挥锤砸水果上的害虫时也要可见）
	_fx_hammer = Node2D.new()
	_fx_hammer.z_index = 100
	add_child(_fx_hammer)
	_fx_hammer.draw.connect(_draw_hammer_layer)
	_update_cursor()
	# 布局必须在动态节点（准星等）创建之后调用，否则首次 _layout 时 _crosshair 为 null，
	# 尺寸守卫跳过且无后续窗口缩放事件，准星将永远保持贴图原始大小（200px）
	_layout()


func stop() -> void:
	get_tree().paused = false          # 排行榜弹窗可能还在暂停态，兜底恢复
	Input.set_custom_mouse_cursor(null)   # 还原系统光标
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()                 # 中途退出也把本局分数入排行榜
	print("[hammer] stop, score=%d lives=%d" % [score, lives])


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源加载 =====

func _load_textures() -> void:
	for k: String in ["roach", "fly", "mos", "rat"]:
		for f in 4:
			_tex[k + "_w" + str(f)] = _load_png("assets/pest_%s_w%d.png" % [k, f])
		for v in 3:
			_tex[k + "_d" + str(v)] = _load_png("assets/pest_%s_d%d.png" % [k, v])
	for n: String in ["hammer_idle", "fruit", "spray_cursor", "vacuum_cursor"]:
		_tex[n] = _load_png("assets/%s.png" % n)
	for k: String in PU_TEX:
		_tex["pu_" + k] = _load_png("assets/" + PU_TEX[k])
	for f in 4:
		_tex["cat_w%d" % f] = _load_png("assets/cat_w%d.png" % f)


func _load_png(rel: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码（编辑器期走 res:// 相对路径）
	for p: String in ["res://games/hammer/" + rel, "res://" + rel]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


# ===== 指针形态（锤形态=MOUSE_MODE_HIDDEN 隐藏 + _draw 程序绘制；喷雾/吸尘器=工具光标图）=====

## 按激活效果更新指针形态（优先级：喷雾 > 吸尘器 > 锤=隐藏）；
## 光标显隐统一由 MOUSE_MODE 控制（锤形态隐藏系统指针，由独立层程序绘制）
func _update_cursor() -> void:
	if state == State.OVER or _tex.is_empty():
		_arrow_shown = true
		Input.set_custom_mouse_cursor(null)   # 结束/无贴图：系统箭头
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if _effects.has("spray"):
		_arrow_shown = false
		Input.set_custom_mouse_cursor(_tex["spray_cursor"], Input.CURSOR_ARROW, SPRAY_HOTSPOT)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _effects.has("vacuum"):
		_arrow_shown = false
		Input.set_custom_mouse_cursor(_tex["vacuum_cursor"], Input.CURSOR_ARROW, VACUUM_HOTSPOT)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_arrow_shown = false
		Input.set_custom_mouse_cursor(null)   # 锤形态：隐藏系统指针，锤子由独立层绘制
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


## UI 悬停时切系统箭头（指针需可见），离开后回当前形态（锤=隐藏 / 道具=工具光标）
func _sync_mouse() -> void:
	if state == State.OVER:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	var over_ui := get_viewport().gui_get_hovered_control() != null
	if over_ui and not _arrow_shown:
		_arrow_shown = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not over_ui and _arrow_shown:
		_arrow_shown = false
		_update_cursor()


func _notification(what: int) -> void:
	# 排行榜暂停树时恢复系统指针（暂停期 _sync_mouse 停转），关榜回当前形态
	if what == NOTIFICATION_PAUSED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif what == NOTIFICATION_UNPAUSED:
		_update_cursor()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if state != State.PLAY:
			return
		# 优先点击拾取掉落道具（点中不挥锤）
		var mp := get_global_mouse_position()
		var vp := get_viewport_rect().size
		var pr := PU_PICK_R * minf(vp.x, vp.y) + 6.0 * _u
		for pup in _pups_root.get_children():
			if mp.distance_to(pup.position) <= pr:
				var kind: String = pup.kind
				var pos: Vector2 = pup.position
				pup.collect()
				_apply_powerup(kind, pos)
				return
		_swing()


## 主点击分流：喷雾/吸尘器为范围技（无挥击帧），铁锤起挥（大锤范围加倍、双锤双判定点）
func _swing() -> void:
	var mp := get_global_mouse_position()
	if _effects.has("spray"):
		_spray_at(mp)
		return
	if _effects.has("vacuum"):
		_vacuum_at(mp)
		return
	if _hammer_wait:   # 上一击还没落锤又点了：先把上一击落了再起新挥
		_settle_smash()
	_swing_t = SWING_T   # 钟形曲线逆时针抡 90° 再回弹
	_hammer_wait = true  # 抡到位（动画半程）再结算落痕，痕迹跟随锤头落点
	_play_sfx("swing")


## 锤抡到位（-90°）结算：命中判定与落空裂纹都取此刻锤头落点（用结算时刻鼠标位置使锤子跟手）
func _settle_smash() -> void:
	_hammer_wait = false
	var big := _effects.has("big")
	var mp := get_global_mouse_position()
	var head := _hammer_head_pos(mp)
	var hit_any := _hammer_hit(head, BIG_HIT_MULT if big else 1.0, BIG_DMG if big else 1)   # 大锤秒杀任何害虫
	if _effects.has("dual"):   # 副锤第二判定点（独立锚点，同样取其锤头落点）
		if _hammer_hit(_hammer_head_pos(mp + DUAL_OFF * _u), 1.0, 1):
			hit_any = true
	if not hit_any:
		_add_crack(head, 26.0 * _u)      # 落空：锤头处砸出地面裂纹
		_play_sfx("thud", -4.0)


## 抡到 -90° 时锤头中心的屏幕位置：柄尾锚点 + 锤头相对柄尾逆时针转 90°（(x,y)→(y,-x)）
func _hammer_head_pos(anchor: Vector2) -> Vector2:
	var s := HAMMER_TEX * _u * (BIG_SCALE if _effects.has("big") else 1.0) / CURSOR_CANVAS
	var rel := (HAMMER_HEAD - HAMMER_PIVOT).rotated(-PI / 2.0)
	return anchor + (HAMMER_PIVOT - HAMMER_HOT + rel) * s


## 单锤落点判定：致死走 died 信号由 _on_pest_died 统一计分；未致死击退反馈
## dmg 为本次伤害（大号铁锤 999 = 秒杀任何害虫）
func _hammer_hit(pos: Vector2, mult: float, dmg: int = 1) -> bool:
	for p in _pests_root.get_children():
		if p.dying:
			continue
		if pos.distance_to(p.position) <= p.radius + HIT_PAD * _u * mult:
			if not p.hit(dmg):
				_add_crack(p.position, p.radius * 0.7)
				_play_sfx("thud")
			return true
	return false


## 杀虫喷雾：喷嘴范围内害虫被策反（调转攻击其他害虫，撞上同归于尽）+ 喷出液体特效
func _spray_at(mp: Vector2) -> void:
	_play_sfx("spray")
	_play_sfx("charm")
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	var r := SPRAY_R * m
	_add_ring(mp, r * 0.2, r, Color(0.85, 0.95, 1.0, 0.85))
	# 喷出液体：锥形雾状液滴（光标罐体喷嘴朝上，向上喷洒），减速飘散后淡出
	for i in 16:
		var ang: float = -PI / 2.0 + randf_range(-0.9, 0.9)
		_drops.append({
			"pos": mp + Vector2.from_angle(ang) * 14.0 * _u,
			"vel": Vector2.from_angle(ang) * randf_range(m * 0.18, m * 0.42),
			"t": 0.0,
		})
	for p in _pests_root.get_children():
		if p.dying or p.charmed:
			continue
		if mp.distance_to(p.position) <= r:
			p.charm(_nearest_pest_to(p))
			_popup_at(p.position, hud.t("pest.charmed", "策反!"), Color(0.5, 1.0, 0.55))


## 喷雾液滴推进：速度阻尼衰减，寿命到后移除
func _tick_drops(delta: float) -> void:
	if _drops.is_empty():
		return
	for d: Dictionary in _drops:
		d.t += delta / DROP_T
		d.pos += d.vel * delta
		d.vel *= maxf(1.0 - delta * 3.5, 0.0)   # 阻尼减速
	_drops = _drops.filter(func(d): return d.t < 1.0)


## 吸尘器：大范围把害虫全部吸走（正常计分，尸体飞入吸点）
func _vacuum_at(mp: Vector2) -> void:
	_play_sfx("vacuum")
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	var r := VACUUM_R * m
	_add_ring(mp, r, r * 0.1, Color(0.55, 0.8, 1.0, 0.85))   # 内聚圈
	for p in _pests_root.get_children():
		if p.dying:
			continue
		if mp.distance_to(p.position) <= r:
			p.vacuumed_to(mp)


## 最近的其他未策反活害虫（策反目标；无则 null，由害虫自行盘旋待命）
func _nearest_pest_to(p: Node2D) -> Node2D:
	var best: Node2D = null
	var bd := INF
	for q in _pests_root.get_children():
		if q == p or q.dying or q.charmed:
			continue
		var d: float = p.position.distance_to(q.position)
		if d < bd:
			bd = d
			best = q
	return best


# ===== 主循环 =====

func _process(delta: float) -> void:
	_time += delta
	# 水果轻微呼吸起伏
	_fruit.scale = _fruit_base_scale * (1.0 + 0.02 * sin(_time * 2.2))
	queue_redraw()   # 裂纹/特效圈每帧重绘（随窗口缩放）
	_fx_hammer.queue_redraw()   # 锤子跟随鼠标，独立层每帧重绘
	_sync_mouse()   # UI 悬停时切系统箭头
	# 道具施加点瞄准星：锤形态画在锤头实际落点（_hammer_head_pos，随大锤变大），
	# 喷雾/吸尘器画在作用锚点（鼠标处）；游玩期间常显，仅结算时隐藏
	if _crosshair != null:
		var mp := get_global_mouse_position()
		_crosshair.position = mp if (_effects.has("spray") or _effects.has("vacuum")) \
				else _hammer_head_pos(mp)
		_crosshair.visible = state == State.PLAY
	if state == State.OVER:
		# 先等掉命动画 + 结束音乐播完再弹排行榜；面板关闭后自动开新局（与 breakout 同套路）
		if _over_t > 0.0:
			_over_t -= delta
			if _over_t <= 0.0:
				_over_t = 0.0
				hud.show_leaderboard(self, "Top 10", score, _over_rank)   # 弹出时自动暂停
		elif get_node_or_null("LeaderboardPanel") == null:
			_new_game()
		return
	_tick_effects(delta)
	_tick_rings(delta)
	_tick_drops(delta)
	# 机器猫在场期间随机喵叫（真实猫叫变体）
	if _cats_root.get_child_count() > 0:
		_cat_bark_t -= delta
		if _cat_bark_t <= 0.0:
			_cat_bark_t = randf_range(1.2, 2.6)
			_play_sfx_rand("meow", -6.0)
	# 挥锤动画推进：钟形曲线半程（抡到 -90°）瞬间结算落痕
	if _swing_t >= 0.0:
		_swing_t -= delta
		if _hammer_wait and _swing_t <= SWING_T * 0.5:
			_settle_smash()
		if _swing_t < 0.0:
			_swing_t = -1.0
	_spawn_t -= delta
	if _spawn_t <= 0.0:
		_spawn()
		_spawn_t = _spawn_interval()
	# 害虫移动声（低频随机吱吱声，只有活虫时播）
	_squeak_t -= delta
	if _squeak_t <= 0.0:
		_squeak_t = randf_range(2.5, 4.5)
		for p in _pests_root.get_children():
			if not p.dying:
				_play_sfx("squeak", -6.0)
				break


## 当前生成间隔：按 score / SPAWN_STEP_SCORE 收紧，夹取 [MIN, START]；开发者模式可再乘倍率
func _spawn_interval() -> float:
	var iv: float = SPAWN_INTERVAL_START - float(score / SPAWN_STEP_SCORE) * SPAWN_STEP_DELTA
	return clampf(iv, SPAWN_INTERVAL_MIN, SPAWN_INTERVAL_START) * _dev_spawn


## 高阶害虫权重随得分提升；老鼠 RAT_UNLOCK 分后解锁
func _pick_kind() -> String:
	var w := {
		"roach": maxf(12.0, 45.0 - score * 0.5),
		"fly": minf(50.0, 25.0 + score * 0.35),
		"mos": minf(45.0, 15.0 + score * 0.45),
	}
	if score >= RAT_UNLOCK:
		w["rat"] = 8.0 + score * 0.25
	var total := 0.0
	for k: String in w:
		total += w[k]
	var roll := randf() * total
	for k: String in w:
		roll -= w[k]
		if roll <= 0.0:
			return k
	return "roach"


## 四边随机出屏生成，目标 = 水果中心附近随机偏移点（上限只统计活虫，尸体不占名额）
func _spawn() -> void:
	var alive := 0
	for p in _pests_root.get_children():
		if not p.dying:
			alive += 1
	if alive >= MAX_PESTS:
		return
	var kind := _pick_kind()
	var cfg: Dictionary = KINDS[kind]
	var vp := get_viewport_rect().size
	var r: float = cfg.rad * minf(vp.x, vp.y)
	var off := r * 1.3
	var pos: Vector2
	match randi() % 4:
		0: pos = Vector2(randf() * vp.x, -off)
		1: pos = Vector2(randf() * vp.x, vp.y + off)
		2: pos = Vector2(-off, randf() * vp.y)
		_: pos = Vector2(vp.x + off, randf() * vp.y)
	var p: Node2D = Pest.new()
	p.kind = kind
	p.value = cfg.value
	p.hp = randi_range(cfg.hp[0], cfg.hp[1])
	p.radius = r
	p.speed = cfg.speed * _u * _dev_speed   # 开发者模式：害虫速度倍率（生成时施加）
	p.wobble_amp = cfg.amp * _u
	p.wobble_freq = cfg.freq
	p.fps = cfg.fps
	p.fruit_pos = get_viewport_rect().size * 0.5 \
			+ Vector2.from_angle(randf() * TAU) * 30.0 * _u
	p.arrive_r = _fruit_r * 0.8 + r * 0.4
	p.walk_frames = [_tex[kind + "_w0"], _tex[kind + "_w1"], _tex[kind + "_w2"], _tex[kind + "_w3"]]
	p.dead_frames = [_tex[kind + "_d0"], _tex[kind + "_d1"], _tex[kind + "_d2"]]
	p.position = pos
	_pests_root.add_child(p)
	p.reached_fruit.connect(_on_pest_reached)
	p.died.connect(_on_pest_died)


## 害虫污染水果：扣 1 命 + 水果变质抖动
func _on_pest_reached(_p: Node2D) -> void:
	if state != State.PLAY:
		return
	lives -= 1
	pollutions += 1
	_refresh_boards()
	_play_sfx("lose")
	_popup_at(_fruit.position + Vector2(0, -_fruit_r), "-1 Life", Color(0.98, 0.35, 0.3))
	_fruit_hit_fx()
	if lives <= 0:
		_game_over()


## 水果受击：变质着色（随污染加深）+ 抖动缩放
func _fruit_hit_fx() -> void:
	var k: float = minf(pollutions * 0.15, 0.7)
	_fruit.modulate = Color.WHITE.lerp(FRUIT_ROT_TINT, k)
	var tw := create_tween()
	for i in 3:
		tw.tween_property(_fruit, "position:x", _fruit.position.x + 8.0 * _u, 0.04)
		tw.tween_property(_fruit, "position:x", _fruit.position.x - 8.0 * _u, 0.04)
	tw.tween_property(_fruit, "position:x", _fruit.position.x, 0.03)


## 害虫死亡统一结算（锤杀/策反杀/猫吃/吸尘）：
## 计分（双倍得分 ×2）+ 飘字 + 裂纹 + 音效 + 概率掉道具 + 尸体保留（上限清理）+ 每 9 杀 +1 命
func _on_pest_died(p: Node2D) -> void:
	if state != State.PLAY:
		return
	var v: int = p.value * (2 if _effects.has("double") else 1)
	_add_score(v)
	_popup_at(p.position, "+%d" % v, Color(1.0, 0.85, 0.25))
	_add_crack(p.position, p.radius * 1.3)
	_play_sfx("splat")
	if randf() < _dev_drop:
		_drop_pup(p.position)
	# 尸体保留：钻入水果/被吸走的不留；超上限淡出移除最旧
	if p.leaves_corpse():
		_corpses.append(p)
		while _corpses.size() > CORPSE_MAX:
			var old: Node2D = _corpses.pop_front()
			if is_instance_valid(old):
				old.fade_corpse()
	# 每 KILLS_PER_LIFE 杀 +1 命（上限 LIVES_CAP）
	_kills += 1
	if _kills % KILLS_PER_LIFE == 0 and lives < LIVES_CAP:
		lives += 1
		_refresh_boards()
		_popup_at(p.position + Vector2(0, -42.0 * _u), "+1 Life", Color(0.5, 1.0, 0.55))


# ===== 道具系统 =====

## 击杀掉落道具徽章：尸体处弹出小幅位移，12s 后消失（末 3 秒闪烁），点击激活
func _drop_pup(pos: Vector2) -> void:
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	var kind: String = PU_TEX.keys()[randi() % PU_TEX.size()]
	var pup := PowerUp.new(_tex["pu_" + kind], PU_SIZE * m / 96.0, kind)
	pup.position = pos
	pup.scale = Vector2.ONE * 0.1
	_pups_root.add_child(pup)
	var off := Vector2.from_angle(randf() * TAU) * m * 0.03
	var tw := create_tween().set_parallel(true)
	tw.tween_property(pup, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(pup, "position", pos + off, 0.3)


## 激活道具：替换型互斥（新顶旧 + 光标切换），即时型直接生效
func _apply_powerup(kind: String, pos: Vector2) -> void:
	_play_sfx("buff")
	_popup_at(pos, hud.t("pu." + kind, PU_NAME[kind]), Color(0.5, 1.0, 0.55))
	match kind:
		"life":
			if lives < LIVES_CAP:
				lives += 1
				_refresh_boards()
			else:
				_popup_at(pos + Vector2(0, -42.0 * _u), hud.t("pu.life_full", "生命已满"), Color(0.98, 0.35, 0.3))
		"cat":
			_spawn_cat()
		"double":
			_effects["double"] = EFFECT_DUR["double"]
		_:
			for s: String in SWAPS:   # 替换型互斥：清掉其他替换型
				_effects.erase(s)
			_effects[kind] = EFFECT_DUR[kind]
			_update_cursor()
	_sync_effect_labels()


## 生成机器猫：随机屏边入场，自动追杀最近害虫（速度 = 老鼠 ×2）
func _spawn_cat() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var cat: Node2D = Cat.new()
	cat.radius = m * 0.048
	cat.speed = CAT_SPEED * _u
	cat.fruit_pos = vp * 0.5
	cat.pests_root = _pests_root
	cat.walk_frames = [_tex["cat_w0"], _tex["cat_w1"], _tex["cat_w2"], _tex["cat_w3"]]
	var off: float = cat.radius * 1.5
	var pos: Vector2
	match randi() % 4:
		0: pos = Vector2(randf() * vp.x, -off)
		1: pos = Vector2(randf() * vp.x, vp.y + off)
		2: pos = Vector2(-off, randf() * vp.y)
		_: pos = Vector2(vp.x + off, randf() * vp.y)
	cat.position = pos
	_cats_root.add_child(cat)
	_play_sfx_rand("meow", -6.0)   # 真实猫叫随机变体，音量减半（无下载文件回退合成音）
	_cat_bark_t = randf_range(1.2, 2.6)


## 效果倒计时：到期移除（替换型到期还原光标）
func _tick_effects(delta: float) -> void:
	if _effects.is_empty():
		if not _effect_labels.is_empty():
			_sync_effect_labels()
		return
	for k: String in _effects.keys():
		_effects[k] -= delta
		if _effects[k] <= 0.0:
			_effects.erase(k)
			if SWAPS.has(k):
				_update_cursor()
	_sync_effect_labels()


## 界面右侧竖排浮字：激活道具英文名 + 实时倒计时（如"Insect Spray 5.3s"）
func _sync_effect_labels() -> void:
	var vp := get_viewport_rect().size
	var fs := int(maxf(12.0, minf(vp.x, vp.y) * 0.020))
	var y := 90.0
	var seen := {}
	for k: String in _effects:
		seen[k] = true
		var lb: Label = _effect_labels.get(k)
		if lb == null:
			lb = Label.new()
			lb.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
			lb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			add_child(lb)
			_effect_labels[k] = lb
		lb.add_theme_font_size_override("font_size", fs)
		lb.add_theme_constant_override("outline_size", maxi(3, int(fs * 0.22)))
		lb.text = "%s %.1fs" % [hud.t("pu." + k, PU_NAME.get(k, k)), _effects[k]]
		lb.reset_size()
		lb.position = Vector2(vp.x - lb.size.x - 16.0, y)
		y += fs * 1.5
	for k: String in _effect_labels.keys():
		if not seen.has(k):
			_effect_labels[k].queue_free()
			_effect_labels.erase(k)


## 喷雾扩散圈 / 吸尘内聚圈特效
func _add_ring(pos: Vector2, r0: float, r1: float, col: Color) -> void:
	_rings.append({"pos": pos, "r0": r0, "r1": r1, "t": 0.0, "col": col})


func _tick_rings(delta: float) -> void:
	if _rings.is_empty():
		return
	for rg: Dictionary in _rings:
		rg.t += delta / RING_T
	_rings = _rings.filter(func(rg): return rg.t < 1.0)


## 掉落道具徽章（点击激活；末 3 秒闪烁预告消失）
class PowerUp extends Node2D:
	var kind := ""
	var age := 0.0
	var spr: Sprite2D

	func _init(tex: Texture2D, s: float, k: String) -> void:
		kind = k
		spr = Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2.ONE * s
		add_child(spr)

	func _process(delta: float) -> void:
		age += delta
		if age >= PU_LIFE_T:
			queue_free()
		elif age >= PU_LIFE_T - 3.0:
			spr.modulate.a = 0.35 + 0.65 * (0.5 + 0.5 * sin(age * 10.0))

	## 拾取：放大淡出自毁
	func collect() -> void:
		set_process(false)
		var tw := create_tween()
		tw.tween_property(self, "scale", scale * 1.5, 0.12)
		tw.parallel().tween_property(self, "modulate:a", 0.0, 0.12)
		tw.chain().tween_callback(queue_free)


# ===== 计分与流程 =====

## 得分统一入口：计分 + 最高分提交
func _add_score(v: int) -> void:
	score += v
	hud.submit_score(score)
	_refresh_boards()


func _refresh_boards() -> void:
	_score_board.text = "%d" % score
	_lives_board.text = "Life %d" % maxi(lives, 0)
	_lives_board.add_theme_color_override("font_color",
			Color(1.0, 0.85, 0.25) if lives > 3 else Color(0.95, 0.25, 0.2))


func _game_over() -> void:
	state = State.OVER
	_swing_t = -1.0
	_hammer_wait = false
	_update_cursor()   # 结束后显示系统箭头（排行榜期间可点）
	_play_sfx("over")
	_popup(hud.t("ui.game_over", "Game Over"), Color(0.98, 0.35, 0.3))
	_over_rank = hud.commit_score()
	_over_t = GAMEOVER_T   # 延迟弹排行榜：等掉命动画 + 游戏结束音乐播完
	_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次


## 重开：上一局分数入排行榜；清场复位（含道具/效果/机器猫）
func _new_game() -> void:
	hud.commit_score()
	for p in _pests_root.get_children():
		p.queue_free()
	for x in _pups_root.get_children():
		x.queue_free()
	for c in _cats_root.get_children():
		c.queue_free()
	_effects.clear()
	_rings.clear()
	_drops.clear()
	_corpses.clear()
	_kills = 0
	_sync_effect_labels()   # 清空倒计时浮字
	score = 0
	lives = LIVES_START
	pollutions = 0
	_cracks.clear()
	_spawn_t = GRACE_T
	_swing_t = -1.0
	_hammer_wait = false
	_update_cursor()
	_fruit.modulate = Color.WHITE
	_fruit.position = get_viewport_rect().size * 0.5
	hud.reset_run()
	state = State.PLAY
	_refresh_boards()
	queue_redraw()


func _restart() -> void:
	if state == State.PLAY:
		_new_game()   # 手动重开（排行榜态被暂停不会触发）


# ===== 定位布局 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_u = m / 1080.0
	_fruit_r = m * 0.075
	_fruit_base_scale = Vector2.ONE * (_fruit_r * 2.0 / 128.0)
	_fruit.position = vp * 0.5
	for p in _pests_root.get_children():
		if p.get("radius") != null and KINDS.has(p.kind):
			p.radius = KINDS[p.kind].rad * m
			p.arrive_r = _fruit_r * 0.8 + p.radius * 0.4
			p.apply_radius()
	for c in _cats_root.get_children():
		if c.get("radius") != null:
			c.radius = m * 0.048
			c.apply_radius()
	# 信息板随窗口缩放；整体水平居中（Node2D 父下锚点不可靠，代码定位）
	var fs := int(m * 0.035)
	var bw := fs * 5.0
	var bh := fs * 1.9
	for b: Label in [_score_board, _lives_board]:
		b.custom_minimum_size = Vector2(bw, bh)
		b.add_theme_font_size_override("font_size", fs)
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	if _crosshair != null and _crosshair.texture != null:
		_crosshair.scale = Vector2.ONE * (m * 0.031 / _crosshair.texture.get_width())   # 显示宽 = 屏短边 × 0.031（飞镖的一半） 


## 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + 音量循环 + BGM
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
	_arrow_shown = true
	Input.set_custom_mouse_cursor(null)   # 排行榜期间显示系统箭头（弹出即暂停）
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.show_leaderboard(self, "Top 10", -1, -1)
	_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次


func _on_bgm() -> void:
	hud.cycle_bgm()
	_bgm_btn.icon = hud.bgm_icon()
	_sync_bgm()


func _sync_bgm() -> void:
	if _bgm == null:
		return
	if hud.bgm_on and not _bgm.playing:
		_bgm.play()
	elif not hud.bgm_on and _bgm.playing:
		_bgm.stop()


func _update_volume_icon() -> void:
	_volume_btn.icon = hud.volume_icon()


func _on_volume() -> void:
	hud.cycle_volume()
	_update_volume_icon()


# ===== 绘制：地面裂纹 =====

func _draw() -> void:
	# 地面裂纹（击杀/落空砸出，浅色在默认深灰背景上可见）
	for ck: Dictionary in _cracks:
		for pts: PackedVector2Array in ck.segs:
			draw_polyline(pts, Color(0.85, 0.82, 0.74, 0.85), 3.0 * _u, true)
	# 喷雾扩散圈 / 吸尘内聚圈
	for rg: Dictionary in _rings:
		var r: float = lerpf(rg.r0, rg.r1, rg.t)
		var c: Color = rg.col
		c.a *= 1.0 - rg.t
		draw_arc(rg.pos, r, 0, TAU, 48, c, 4.0 * _u, true)
	# 喷雾液滴（淡青绿小圆，随寿命缩小淡出）
	for d: Dictionary in _drops:
		var t: float = d.t
		var c2 := Color(0.55, 0.9, 0.75, 0.85 * (1.0 - t))
		draw_circle(d.pos, (5.0 - 3.0 * t) * _u, c2)


## 锤光标独立层绘制回调（_fx_hammer.draw 信号；z_index=100 压在害虫/水果/浮字之上）
func _draw_hammer_layer() -> void:
	if state != State.PLAY or _effects.has("spray") or _effects.has("vacuum"):
		return
	var mp := get_global_mouse_position()
	var tsz := HAMMER_TEX * _u * (BIG_SCALE if _effects.has("big") else 1.0)
	var ang := 0.0
	if _swing_t >= 0.0:
		ang = -PI / 2.0 * sin((1.0 - _swing_t / SWING_T) * PI)   # 逆时针抡 90° 再回弹（负角=逆时针）
	_draw_hammer(mp, tsz, ang)
	if _effects.has("dual"):
		_draw_hammer(mp + DUAL_OFF * _u, tsz, ang)   # 副锤（独立判定点，同款姿态）


## 绘制锤光标（绘制目标=锤光标独立层）：贴图左下角（HAMMER_HOT）对齐 anchor=鼠标点；
## 挥锤时绕柄尾（pivot）旋转 ang
func _draw_hammer(anchor: Vector2, tsz: float, ang: float) -> void:
	var s := tsz / CURSOR_CANVAS
	var pivot := anchor + (HAMMER_PIVOT - HAMMER_HOT) * s   # 柄尾屏幕位置=旋转中心
	_fx_hammer.draw_set_transform(pivot, ang, Vector2(s, s))
	_fx_hammer.draw_texture(_tex["hammer_idle"], -HAMMER_PIVOT)   # 贴图原点平移到柄尾，旋转时柄尾不动
	_fx_hammer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 砸出地面裂纹：以 pos 为心放射 n 条随机折线
func _add_crack(pos: Vector2, r: float) -> void:
	var segs: Array = []
	var n := 4 + randi() % 3
	for i in n:
		var ang := TAU * float(i) / float(n) + randf_range(-0.3, 0.3)
		var pts := PackedVector2Array()
		var p := pos
		pts.append(p)
		var step: float = r * randf_range(0.35, 0.55)
		for j in 2 + randi() % 2:
			ang += randf_range(-0.45, 0.45)
			p += Vector2.from_angle(ang) * step
			pts.append(p)
		segs.append(pts)
	_cracks.append({"segs": segs})
	if _cracks.size() > MAX_CRACKS:
		_cracks.pop_front()


# ===== 飘字 =====

## 指定位置弹出飘字（+分金 / -命红），上浮淡出后自毁（可多个并发）
func _popup_at(pos: Vector2, text: String, col: Color) -> void:
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * 0.045))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.2, m * 0.045 * 1.6)
	lb.position = pos - lb.size * 0.5
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.07, 0.8)
	tw.tween_property(lb, "modulate:a", 0.0, 0.8).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## 屏中偏上大字提示（Game Over 等）
func _popup(text: String, col: Color) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 10)
	lb.add_theme_font_size_override("font_size", int(m * 0.07))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.6, m * 0.07 * 1.5)
	lb.position = Vector2(vp.x * 0.5 - lb.size.x * 0.5, vp.y * 0.30)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.05, 1.2)
	tw.tween_property(lb, "modulate:a", 0.0, 1.2).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


# ===== 音效（程序合成：正弦/方波滑音 + 低通噪声）=====

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
		acc = lerpf(acc, randf_range(-1.0, 1.0), 1.0 / maxf(lp, 1.0))   # 简单一阶低通
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


func _init_sfx() -> void:
	_sfx["swing"] = _sfx_stream([["n", 0.09, 0.30, 3.0]])                       # 挥锤风声
	_sfx["splat"] = _sfx_stream([["n", 0.10, 0.55, 2.0], ["t", 180.0, 60.0, 0.09, false, 0.5]])   # 命中拍碎
	_sfx["thud"] = _sfx_stream([["t", 220.0, 120.0, 0.07, true, 0.45]])         # 落空/打疼闷响
	_sfx["lose"] = _sfx_stream([["t", 330.0, 82.0, 0.35, false, 0.6]])          # 扣命下滑音
	_sfx["over"] = _sfx_stream([["t", 392.0, 392.0, 0.12, true, 0.35], ["t", 311.0, 311.0, 0.12, true, 0.35], ["t", 233.0, 233.0, 0.22, true, 0.35]])
	_sfx["squeak"] = _sfx_stream([["t", 1300.0, 900.0, 0.05, false, 0.10]])     # 害虫移动吱吱声
	_sfx["buff"] = _sfx_stream([["t", 520.0, 780.0, 0.12, false, 0.40]])        # 拾取道具
	_sfx["spray"] = _sfx_stream([["n", 0.32, 0.50, 8.0]])                       # 喷雾嘶嘶（高频细噪）
	_sfx["vacuum"] = _sfx_stream([["n", 0.38, 0.60, 1.5]])                      # 吸尘低鸣
	_sfx["charm"] = _sfx_stream([["t", 300.0, 720.0, 0.18, false, 0.35]])       # 策反上滑音
	_sfx["meow"] = _sfx_stream([["t", 760.0, 520.0, 0.09, false, 0.45], ["t", 520.0, 860.0, 0.16, false, 0.45]])   # 猫叫两段滑音
	# 真实猫叫录音（Mixkit 免费授权）3 变体：机器猫激活与在场期间随机播放，读取失败回退合成音
	for i in 3:
		for base: String in ["res://games/hammer/assets/sfx/cat%d.mp3" % (i + 1), "res://assets/sfx/cat%d.mp3" % (i + 1)]:
			var cf := FileAccess.open(base, FileAccess.READ)
			if cf != null:
				var cst := AudioStreamMP3.load_from_buffer(cf.get_buffer(cf.get_length()))
				if cst != null:
					_sfx["meow%d" % (i + 1)] = cst
				break
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM，不影响玩法）
	for base: String in ["res://games/hammer/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## 播放音效：从池中取空闲播放器（volume_db 负值降低音量）
func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


## 随机变体音效：探测 <base>1..<base>8 变体键（真实录音），有则随机播一个，否则回退基础合成音
func _play_sfx_rand(sfx_base: String, volume_db: float = 0.0) -> void:
	var keys: Array[String] = []
	for i in 8:
		var k := "%s%d" % [sfx_base, i + 1]
		if _sfx.has(k):
			keys.append(k)
	_play_sfx(sfx_base if keys.is_empty() else keys[randi() % keys.size()], volume_db)


# ===== 开发者模式（参考打砖块：排行榜暗门 → 可拖动调试窗口，参数实时生效不暂停）=====

## 暗门：排行榜面板弹出后，5 秒内在面板上点击满 10 次 → 关闭排行榜后弹出调试窗口
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
		if panel != null:   # 标题反馈（面板 ALWAYS，暂停中可见）
			var head := panel.get_child(0)
			if head is Container and head.get_child(0) is Label:
				(head.get_child(0) as Label).add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))


## 排行榜关闭回调（game_hud._close_lb 调用）：还原游戏光标；暗门已触发则弹出开发者窗口
func on_leaderboard_closed() -> void:
	_update_cursor()
	if _dev_pending:
		_dev_pending = false
		_show_dev_window()


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
		[hud.t("dev.btn_life99", "Life = 99"), _dev_life_99, hud.t("dev.tip_life99", "Set lives to 99")],
		[hud.t("dev.btn_life_up", "Life +1"), _dev_life_up, hud.t("dev.tip_life_up", "Add 1 life")],
		[hud.t("dev.btn_life_down", "Life -1"), _dev_life_down, hud.t("dev.tip_life_down", "Subtract 1 life")],
		[hud.t("dev.btn_big", "Big Hammer"), func() -> void: _dev_pu("big"), hud.t("dev.tip_big", "Activate Big Hammer now: hit range ×2 and one-shot any pest (lasts %d s)") % int(EFFECT_DUR["big"])],
		[hud.t("dev.btn_dual", "Dual Hammers"), func() -> void: _dev_pu("dual"), hud.t("dev.tip_dual", "Activate Dual Hammers now: off-hand hammer adds a second hit point (lasts %d s)") % int(EFFECT_DUR["dual"])],
		[hud.t("dev.btn_spray", "Spray"), func() -> void: _dev_pu("spray"), hud.t("dev.tip_spray", "Activate Insect Spray now: sprayed pests turn on their kin (lasts %d s)") % int(EFFECT_DUR["spray"])],
		[hud.t("dev.btn_vacuum", "Vacuum"), func() -> void: _dev_pu("vacuum"), hud.t("dev.tip_vacuum", "Activate Vacuum now: sucks up all pests in a wide area (lasts %d s)") % int(EFFECT_DUR["vacuum"])],
		[hud.t("dev.btn_double", "Double Score"), func() -> void: _dev_pu("double"), hud.t("dev.tip_double", "Activate Double Score now: kill points ×2 (lasts %d s)") % int(EFFECT_DUR["double"])],
		[hud.t("dev.btn_cat", "Spawn Cat"), func() -> void: _dev_pu("cat"), hud.t("dev.tip_cat", "Spawn a Robot Cat now: auto-hunts the nearest pest")],
		[hud.t("dev.btn_kill_all", "Kill All"), _dev_kill_all, hud.t("dev.tip_kill_all", "Clear the screen: all pests die at once with normal scoring (drops included)")],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.tooltip_text = a[2]   # 悬停提示
		b.pressed.connect(a[1])
		grid.add_child(b)
	# 滑块：害虫速度 / 生成间隔 / 道具掉率
	_dev_add_slider(vb, hud.t("dev.slider_speed", "Pest Speed"), _dev_speed, 0.25, 3.0, hud.t("dev.tip_speed", "Pest speed multiplier (applies to newly spawned pests)"), func(v: float) -> void:
		_dev_speed = v)
	_dev_add_slider(vb, hud.t("dev.slider_spawn", "Spawn Rate"), _dev_spawn, 0.1, 3.0, hud.t("dev.tip_spawn", "Spawn interval multiplier (lower = pests spawn faster)"), func(v: float) -> void:
		_dev_spawn = v)
	_dev_add_slider(vb, hud.t("dev.slider_drop", "Drop Rate"), _dev_drop, 0.0, 1.0, hud.t("dev.tip_drop", "Power-up drop rate (chance a killed pest drops a power-up)"), func(v: float) -> void:
		_dev_drop = v)
	add_child(_dev_win)
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 面板按住标题栏拖动（不影响游戏；游戏不暂停）
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += event.relative)


## 调试滑块行：左侧标签（显示当前值），右侧 HSlider；tip 为中文悬停提示
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
func _dev_life_99() -> void:
	lives = 99
	_refresh_boards()


func _dev_life_up() -> void:
	lives += 1
	_refresh_boards()


func _dev_life_down() -> void:
	lives = maxi(0, lives - 1)
	_refresh_boards()


## 走正常道具激活流程（含音效/飘字/互斥/光标切换），提示位置取当前鼠标处
func _dev_pu(kind: String) -> void:
	_apply_powerup(kind, get_global_mouse_position())


## 清屏：全场活害虫走正常死亡流程（计分 + 掉落判定）
func _dev_kill_all() -> void:
	for p in _pests_root.get_children():
		if not p.dying:
			p.slain_by_charm()
