extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 扔垃圾：交互状态机 + 抛物线 + 入篓判定 + 计分
## 玩法：手固定在屏内托举垃圾（鼠标不控制手）；按住左键手下移到底部并出现瞄准参考弧线，移动鼠标改变出手方向；
## 松开左键垃圾沿参考弧线抛出飞向垃圾桶，手快速上送回托举位
## 瞄准：抛物线恒经过鼠标点（鼠标即锚点，指哪弧线过哪）——固定飞行时长 AIM_T 反解出手速度；重力按屏高归一化

enum State { IDLE, AIMING, FLYING, RESULT }

const GameHud := preload("res://scripts/game_hud.gd")

const FLIGHT_T := 1.4          # 重力参考时长（s）：g = 屏高 × GRAVITY_RATIO / FLIGHT_T²（实际飞行时长随瞄准变化）
const GRAVITY_RATIO := 2.2     # g = 屏高 × 此系数 / FLIGHT_T²
const AIM_T := 1.4             # 瞄准飞行时长（s）：弧线恒经过鼠标点，T 越小出手越快
const AIM_SINK_TIME := 0.45     # 按下左键后手下移到底部时长（过冲缓动）
const AIM_HAND_SCALE := 0.95    # 按下瞄准时手缩小比例（1 = 原大小）
const PUSH_DIST_BALLS := 6.0   # 松手后手沿抛物线方向送出距离 = r × 此值
const PUSH_HOLD := 0.5         # 送出后停留时长（s）
const PUSH_H_KEEP := 0.45      # 送出方向水平分量保留比例（1 = 完全朝鼠标方向，越小越竖直）
const PUSH_RETURN := 0.5       # 停留后垂直回托举位时长（s）
const PREVIEW_STEP := 0.03     # 参考弧线采样间隔（s）
const PREVIEW_MAX := 70        # 参考弧线最大采样点数
const FLIGHT_MAX_T := 4.5      # 飞行看门狗时长（s，含入篓引导兜底）
const REST_TIME := 0.6         # RESULT 停留时长
const GROUND_REST := 0.5       # 地面反弹弹性（未进垃圾落到地面多次反弹）
const GROUND_FRICTION := 0.75  # 每次落地反弹的水平速度衰减
const BOUNCE_STOP := 0.18      # 反弹速度 < g × 此值 时视为弹尽停稳，开始淡出
const LOW_GROUND_GAP := 2.0    # 弧线顶点够不到地面时，临时地面 = 顶点下方 r × 此值
const SFX_POOL := 4            # 音效播放器池
const BGM_DB := -6.8           # BGM 音量（dB）
const SFX_DB := -4.0           # 音效全局音量偏移（默认 0dB 过响，统一下移）
const SCALE_FAR := 0.85        # 透视缩放下限
const SPIN_GAIN := 0.5         # 水平速度 → 自转角速度系数
const SPIN_MIN := 2.5          # 基础自转（rad/s），方向随水平速度
const SCORE_MARGIN := 0.35     # 入篓判定：|dx| < 开口半宽 − r×此系数
const GOAL_CENTER_SPEED := 8.0 # 入篓后垃圾向桶心水平收敛速度 = r × 此值 / 秒
const RIM_REST := 0.5          # 桶沿反弹弹性
const WALL_REST := 0.45        # 桶壁/桶底反弹弹性
const RIM_TUBE := 0.18         # 桶沿管半径 = r × 此系数

# ===== 尺寸与布局配置（垃圾半径 r 为基准，其余全部跟随）=====
const ITEM_R_RATIO := 0.035        # 垃圾半径 = min(屏宽, 屏高) × 此值
const BIN_POS_RATIO := Vector2(0.5, 0.20)  # 桶口平面锚点 / (屏宽, 屏高)
const BIN_TEX_ITEMS := 4.2         # 桶贴图渲染宽 = r × 此值（按新素材开口比例校准，保持开口 ≈3.3r 手感）
const HAND_TEX_ITEMS := 5.2        # 手贴图渲染宽 = r × 此值
const HAND_GRIP_BALLS := 0.8       # 掌碗中心在垃圾中心下方 = r × 此值
const HAND_HIGH_RATIO := 0.68      # 手固定托举 y / 屏高
const HAND_AIM_LOW_RATIO := 0.90   # 按下瞄准时手底部 y / 屏高
const HAND_FIXED_X := 0.5          # 手固定 x / 屏宽
const HAND_TILT_MAX := 20.0        # 手随鼠标水平位置的最大倾斜角（度，鼠标越远倾得越多）
const HAND_TILT_RANGE := 0.25      # 达到最大倾斜的鼠标水平距离 / 屏宽
const SCORE_FONT_RATIO := 0.035    # 记分牌字号 = min(屏宽, 屏高) × 此值
const POPUP_FONT_RATIO := 0.06     # 得分飘字字号 = min(屏宽, 屏高) × 此值
const POPUP_TIME := 0.8            # 飘字动画时长（s）
const POPUP_RISE_RATIO := 0.08     # 飘字上浮距离 = min(屏宽, 屏高) × 此值
const COMBO_MIN := 3               # 连击飘字触发次数（连续入篓 ≥ 此值显示 combo×N）
const COMBO_FONT_RATIO := 0.075    # combo 飘字字号 = min(屏宽, 屏高) × 此值
const DIFF_SCORE := 2              # 动态难度触发分
const DIFF_STEP := 5               # 每 N 分速度 +1
const SPEED_LEVEL_MAX := 100
const BIN_RANGE := 0.3             # 难度移动区间：中心 ± 此比例 × 屏宽
const BIN_SPEED := 0.015           # 像素速度 = level × 屏宽 × 此系数

@onready var _bin_back: Node2D = $BinBack
@onready var _bin_front: Node2D = $BinFront
@onready var _hand: Node2D = $Hand
@onready var _item: Node2D = $TrashItem
@onready var _scoreboard: Label = $HudBar/ScoreBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.IDLE
var score := 0

var _r := 24.0
var _g := 0.0
var _flight_t := 0.0
var _rest_t := 0.0
var _v := Vector2.ZERO         # 飞行速度 (vx, vy)
var _prev_y := 0.0
var _aim_v := Vector2.ZERO     # 瞄准出手速度矢量（抛物线恒经过鼠标点）
var _hand_tween: Tween
var _fade_tween: Tween
var _high_y := 0.0             # 手固定托举 y
var _ground_y := 0.0           # 地面 y（垃圾桶底部水平线）
var _flight_ground_y := 0.0    # 本次飞行的触地线（垃圾心）：正常=地面−r，矮弧线=顶点+gap
var _aim_low_y := 0.0          # 按下瞄准时手底部 y
var _aim_sink := 0.0           # 按下后手下移进度 0→1（Tween 驱动）
var _settle_t := 99.0          # 松手后手动作累计时间（s；往返→停留→回归 三段时间轴，超出即完成）
var _settle_t1 := 0.15         # 往返段时长（松手瞬间按出手速度反算）
var _push_dir := Vector2.ZERO  # 松手瞬间出手方向单位向量（手沿此方向送出）
var _launch_rot := 0.0         # 松手瞬间手倾斜角（送出/停留段保持，回归段转正）
var _launch_pos := Vector2.ZERO # 松手瞬间手位（送出段起点）
var _hand_home := Vector2.ZERO # 手固定托举位（回归终点）
var _scored := false           # 本次飞行已入篓
var _rim_hit := false          # 本次飞行已碰桶沿（只弹一次）
var _wall_hit := false         # 本次飞行已碰桶壁（只弹一次）
var _miss_counted := false     # 本次飞行未入篓已扣分（只扣一次）
var _goal_phase := 0           # 入篓引导阶段：1=落向桶内 2=桶底下坠
var _goal_rel_x := 0.0         # 入篓后相对桶心的水平偏移（刚性跟随桶移动，向 0 收敛防穿模）
var _sfx_streams := {}         # 音效名 → AudioStream
var _sfx_players: Array = []
var _last_item := ""           # 上一个垃圾名（避免连续重复）
var hud: RefCounted            # 通用 HUD（最高分/连击/音量）
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _bgm: AudioStreamPlayer
var _lb_btn: Button               # 排行榜按钮
var _hbox: HBoxContainer          # 右上角按钮排容器（等间距/底对齐）
# 动态难度
var _moving := false
var _speed_level := 1
var _bin_dir := 1.0


func start() -> void:
	randomize()
	hud = GameHud.new("trash")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()   # 先建按钮再布局（_layout 会设置按钮位置，null 会报错中断）
	_layout()
	_init_sfx()
	_refresh_score()
	_enter_idle()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，分数入排行榜
	print("[trash] stop, final score=%d" % score)


func _exit_button_pressed() -> void:
	exit_requested.emit()


## 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + 音量循环
## 容器统一等间距（8px）、按钮固定 56×56 底对齐、图标统一 32px 居中 —— 保证水平/垂直全对齐
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()   # tscn 节点迁入容器（原父为游戏根）
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")

	# 最小化钮（关闭钮左侧）：点击最小化窗口（桌面 Win/Linux）
	var min_btn := GameHud.make_button("")
	min_btn.icon = hud.ui_icon("minimize.png")
	min_btn.custom_minimum_size = Vector2(56.0, 56.0)
	min_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	min_btn.add_theme_constant_override("icon_max_width", 32)
	min_btn.pressed.connect(func() -> void: get_window().mode = Window.MODE_MINIMIZED)
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()   # R 改循环箭头图标（同风格程序生成）
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, min_btn, _exit_btn]:
		_hbox.add_child(b)
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END   # 底部对齐
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 32)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	_lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_restart)
	_bgm_btn.pressed.connect(_on_bgm)
	_volume_btn.pressed.connect(_on_volume)


## 排行榜弹窗（手动查看：不高亮当前局）
func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), -1, -1)


## BGM 开关：切换持久化状态并同步播放
func _on_bgm() -> void:
	hud.cycle_bgm()
	_bgm_btn.icon = hud.bgm_icon()
	_sync_bgm()


## BGM 播放状态与开关保持一致
func _sync_bgm() -> void:
	if _bgm == null:
		return
	if hud.bgm_on and not _bgm.playing:
		_bgm.play()
	elif not hud.bgm_on and _bgm.playing:
		_bgm.stop()


## 音量按钮图标：按档位切换 high/low/cross 贴图
func _update_volume_icon() -> void:
	_volume_btn.icon = hud.volume_icon()


func _on_volume() -> void:
	hud.cycle_volume()
	_update_volume_icon()


## 重开：上一局分数入排行榜；分数与连击归零、当前飞行作废回手（排行榜保留）
func _restart() -> void:
	hud.commit_score()
	score = 0
	hud.reset_run()
	_sync_bgm()
	_refresh_score()
	if _fade_tween != null:
		_fade_tween.kill()
	state = State.IDLE   # 强制脱离 AIMING/FLYING，_enter_idle 全面复位
	_enter_idle()


## 记分牌刷新：分数；负分红字
func _refresh_score() -> void:
	_scoreboard.text = "%d" % score
	_scoreboard.add_theme_color_override("font_color", Color(0.95, 0.25, 0.2) if score < 0 else Color.WHITE)


## 得分统一入口：计分 + 最高分 + 连击（入篓 success / 未入 fail）+ 飘字
func _add_score(bonus: int) -> void:
	score += bonus
	hud.submit_score(score)
	if bonus > 0:
		var n: int = hud.on_success()
		if n >= COMBO_MIN:
			_spawn_combo(n)
	else:
		hud.on_fail()
	_refresh_score()


## 音效初始化：pck 内 mp3 走字节解码，编辑器预览走导入资源（双路径，与投篮一致）
func _init_sfx() -> void:
	var files := {"bin_hit": "bin_hit.mp3", "score": "score.mp3", "miss": "miss.mp3"}
	for name: String in files:
		for base in ["res://games/trash/assets/sfx/", "res://assets/sfx/"]:
			var path: String = base + files[name]
			if ResourceLoader.exists(path):
				_sfx_streams[name] = load(path)
				break
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				_sfx_streams[name] = AudioStreamMP3.load_from_buffer(f.get_buffer(f.get_length()))
				break
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM，不影响玩法）
	for base in ["res://games/trash/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## 播放音效：从池中取空闲播放器（全部占用时丢弃本次）
func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx_streams.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_r = m * ITEM_R_RATIO
	_g = GRAVITY_RATIO * vp.y / (FLIGHT_T * FLIGHT_T)
	for b in [_bin_back, _bin_front]:
		b.item_radius = _r
		b.tex_w_items = BIN_TEX_ITEMS
		b.opening_half = _r * BIN_TEX_ITEMS * b.OPEN_W_RATIO / 2.0
	_bin_back.tex_paths = ["res://games/trash/assets/bin_back.png", "res://assets/bin_back.png"]
	_bin_front.tex_paths = ["res://games/trash/assets/bin_front.png", "res://assets/bin_front.png"]
	for b in [_bin_back, _bin_front]:
		b.base_position = Vector2(vp.x * BIN_POS_RATIO.x, vp.y * BIN_POS_RATIO.y)
		b.apply_base()
		b.queue_redraw()
	var bs: float = _r * BIN_TEX_ITEMS / _bin_front.tex_size.x
	_ground_y = _bin_front.position.y + _bin_front.body_h_px * bs   # 地面 = 桶底水平线
	_high_y = vp.y * HAND_HIGH_RATIO
	_aim_low_y = vp.y * HAND_AIM_LOW_RATIO
	_hand.item_radius = _r
	_hand.tex_scale = HAND_TEX_ITEMS
	_hand.grip_offset = _r * HAND_GRIP_BALLS
	_hand_home = Vector2(vp.x * HAND_FIXED_X, _high_y)
	_hand.position = _hand_home
	_hand.queue_redraw()
	_item.radius = _r
	_item.queue_redraw()
	_scoreboard.custom_minimum_size = Vector2(175.0, m * SCORE_FONT_RATIO * 1.9)   # 单行背景板
	_scoreboard.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scoreboard.add_theme_font_size_override("font_size", int(m * SCORE_FONT_RATIO))
	# 信息板 HudBar 整体水平居中（代码定位，Node2D 父下锚点不可靠）
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	# 右上角按钮排：容器定位右上（等间距/尺寸/对齐在 _setup_buttons 统一设定）
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


func _enter_idle() -> void:
	state = State.IDLE
	_scored = false
	_rim_hit = false
	_wall_hit = false
	_miss_counted = false
	_goal_phase = 0
	_hand.pushing = false  # 回待机：恢复托举姿势贴图（hand）
	if _hand_tween != null:
		_hand_tween.kill()
	if _fade_tween != null:   # 杀掉残留淡出 tween，防止重开时新垃圾被压暗"消失"
		_fade_tween.kill()
	_hand.scale = Vector2.ONE
	_hand.rotation = 0.0
	_settle_t = 99.0   # 手动作时间轴归位（若三段动画未完成则直接归位，x 一并复位）
	_hand.position = _hand_home
	# 新垃圾直接在手上生成：先定位再显示，避免在上一件消失处闪现一帧
	_item.position = _hand.position
	_prev_y = _item.position.y
	_item.z_index = 1   # 手持/空中：画在垃圾桶前景之上（桶移动过来不会盖住手上的垃圾）
	_item.modulate.a = 1.0
	_item.scale = Vector2.ONE
	_item.rotation = 0.0
	_item.visible = true
	_item.set_random(_last_item)
	_last_item = _item.current


func _process(delta: float) -> void:
	var vp := get_viewport_rect().size
	_update_difficulty(delta, vp)
	match state:
		State.IDLE:
			_item.position = _hand.position
			_hand.rotation = _hand_tilt(vp)
		State.AIMING:
			# 手下移到底部蓄势；抛物线恒经过鼠标点（锚点决定弧线），参考弧线每帧重绘
			_item.position = _hand.position
			_hand.position.y = lerpf(_high_y, _aim_low_y, _aim_sink)
			_hand.rotation = _hand_tilt(vp)
			_aim_v = _aim_goal()
			_update_preview()
		State.FLYING:
			_step_flight(delta, vp)
			# 松手手部三段：匀速送出（与垃圾同速，停在送出终点）→ 停留 PUSH_HOLD → 回托举位 PUSH_RETURN
			_settle_t += delta
			var push_off := _push_dir * (_r * PUSH_DIST_BALLS)
			if _settle_t < _settle_t1:
				var u1: float = _settle_t / _settle_t1
				_hand.position = _launch_pos + push_off * u1   # 匀速送出（与垃圾同速）
				_hand.rotation = _launch_rot   # 送出段保持松手前倾斜角
			elif _settle_t < _settle_t1 + PUSH_HOLD:
				_hand.position = _launch_pos + push_off
				_hand.rotation = _launch_rot
			else:
				var u2: float = clampf((_settle_t - _settle_t1 - PUSH_HOLD) / PUSH_RETURN, 0.0, 1.0)
				_hand.position = (_launch_pos + push_off).lerp(_hand_home, 1.0 - pow(1.0 - u2, 2.0))
				_hand.rotation = _launch_rot * (1.0 - u2)   # 回归途中转正
		State.RESULT:
			_rest_t -= delta
			if _rest_t <= 0.0:
				_enter_idle()


## 得分/扣分飘字：屏幕中心浮现 "+1"（绿）或 "-1"（红），上浮淡出后自毁（可多个并发）
func _spawn_popup(bonus: int) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = "+%d" % bonus if bonus > 0 else "%d" % bonus
	lb.add_theme_color_override("font_color", Color(0.2, 0.85, 0.3) if bonus > 0 else Color(0.95, 0.25, 0.2))
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * POPUP_FONT_RATIO))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.3, m * POPUP_FONT_RATIO * 1.5)
	lb.position = vp * 0.5 - lb.size * 0.5
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * POPUP_RISE_RATIO, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## 连击飘字：红色 combo×N（连续入篓 COMBO_MIN 次以上每次显示）
func _spawn_combo(n: int) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = hud.t("hud.combo", "combo×%d") % n
	lb.add_theme_color_override("font_color", Color(0.95, 0.2, 0.15))
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 10)
	lb.add_theme_font_size_override("font_size", int(m * COMBO_FONT_RATIO))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.5, m * COMBO_FONT_RATIO * 1.5)
	lb.position = Vector2(vp.x * 0.5 - lb.size.x * 0.5, vp.y * 0.30)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * POPUP_RISE_RATIO, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## 动态难度（与投篮一致）：得分超过阈值后垃圾桶匀速往复，每 5 分加速一级（上限 100），退出游戏实例销毁自然重置
func _update_difficulty(delta: float, vp: Vector2) -> void:
	if score > DIFF_SCORE:
		_moving = true
	if not _moving:
		return
	_speed_level = mini(1 + (score - DIFF_SCORE - 1) / DIFF_STEP, SPEED_LEVEL_MAX)
	var sp := _speed_level * vp.x * BIN_SPEED * delta * _bin_dir
	var x: float = _bin_front.base_position.x + sp
	var half := vp.x * BIN_RANGE
	if x > vp.x * 0.5 + half:
		x = vp.x * 0.5 + half
		_bin_dir = -1.0
	elif x < vp.x * 0.5 - half:
		x = vp.x * 0.5 - half
		_bin_dir = 1.0
	_bin_back.base_position.x = x
	_bin_front.base_position.x = x
	_bin_back.apply_base()
	_bin_front.apply_base()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()   # 键盘 R 与右上角 R 按钮一致
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and state == State.IDLE:
			state = State.AIMING
			if _hand_tween != null:
				_hand_tween.kill()
			_aim_v = _aim_goal()   # 瞄准方向先硬设，避免弧线从零渐起
			# 手下移到底部并缩小到 80%（过冲缓动，下压动作明显）
			_hand_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_hand_tween.tween_property(self, "_aim_sink", 1.0, AIM_SINK_TIME)
			_hand_tween.tween_property(_hand, "scale", Vector2.ONE * AIM_HAND_SCALE, AIM_SINK_TIME)
			queue_redraw()   # 出现参考弧线
		elif not event.pressed and state == State.AIMING:
			_launch()


func _launch() -> void:
	_item.position = _hand.position
	_prev_y = _item.position.y
	_item.z_index = 1   # 出手：空中飞行段在垃圾桶前景之上
	_v = _aim_v
	# 本次飞行的触地线：正常 = 地面线上方 r；弧线顶点够不到地面（矮弧）时改用顶点下方一段距离，
	# 否则下落段一开始就会满足触地条件、垃圾从半空瞬移到地面
	var rise := 0.0
	if _v.y < 0.0:
		rise = _v.y * _v.y / (2.0 * _g)   # 上升段高度 = vy²/2g
	var gy := _ground_y - _r
	if _item.position.y - rise > gy:
		gy = _item.position.y - rise + _r * LOW_GROUND_GAP
	_flight_ground_y = gy
	_flight_t = 0.0
	_scored = false
	_rim_hit = false
	_wall_hit = false
	_miss_counted = false
	_goal_phase = 0
	_hand.pushing = true   # 松开左键：切换推送姿势贴图（hand2）
	_launch_pos = _hand.position
	_launch_rot = _hand.rotation   # 记住松手前的倾斜角（送出段保持）
	# 送出方向 = 手→鼠标方位（呼应抛物线去向），水平分量收缩（送出更竖直，只带一点倾向），保留最少向上分量防朝下送
	var to_m := get_global_mouse_position() - _launch_pos
	if to_m.length() < 8.0:
		to_m = Vector2(0.0, -1.0)
	to_m.y = minf(to_m.y, -0.45 * to_m.length())
	_push_dir = Vector2(to_m.x * PUSH_H_KEEP, to_m.y).normalized()
	_push_hand()
	state = State.FLYING
	_item.preview_points = []   # 清除参考弧线


## 手随鼠标水平位置倾斜（手位固定，朝鼠标方向转动，垃圾保持在掌上）
func _hand_tilt(vp: Vector2) -> float:
	var dx := get_global_mouse_position().x - _hand.position.x
	var t: float = clampf(dx / (vp.x * HAND_TILT_RANGE), -1.0, 1.0)
	return deg_to_rad(t * HAND_TILT_MAX)


## 瞄准：抛物线恒经过鼠标点（鼠标即锚点）。固定飞行时长 AIM_T 反解唯一出手速度：
## vx = Δx/T，vy = (Δy − ½gT²)/T（Godot y 向下，重力 +g）；鼠标再低弧线也先上后下经过它，不会朝下丢
func _aim_goal() -> Vector2:
	var d := get_global_mouse_position() - _hand.position
	return Vector2(d.x / AIM_T, (d.y - 0.5 * _g * AIM_T * AIM_T) / AIM_T)


## 瞄准参考线：抛物线采样点赋给垃圾节点绘制（层级在垃圾桶之上、垃圾本体之下）
func _update_preview() -> void:
	var pts := PackedVector2Array()
	for i in PREVIEW_MAX:
		var t := PREVIEW_STEP * (i + 1.0)
		var off := _aim_v * t + Vector2(0.0, 0.5 * _g * t * t)
		if _item.position.y + off.y > get_viewport_rect().size.y + _r:
			break   # 弧线落出屏底即止
		pts.append(off)
	_item.preview_points = pts
	# 顶点采样索引：t_apex = −vy/g（出手恒向上，vy<0）；其前=上升段亮白，其后=下降段暗白
	_item.preview_apex_idx = clampi(int(-_aim_v.y / _g / PREVIEW_STEP), -1, pts.size())


## 松手：往返送出（_settle_t 时间轴主控驱动）+ 压扁恢复；时长按出手垃圾速度反算（手速匹配垃圾速）
func _push_hand() -> void:
	if _hand_tween != null:
		_hand_tween.kill()
	_settle_t = 0.0
	# 送出段匀速且速度 = 垃圾出手速度：时长 = 送出距离 / |v|
	_settle_t1 = _r * PUSH_DIST_BALLS / maxf(_v.length(), 1.0)
	_hand_tween = create_tween()
	_hand_tween.tween_property(_hand, "scale", Vector2(1.0, 0.75), _settle_t1)      # 出手瞬间压扁
	_hand_tween.tween_interval(PUSH_HOLD + PUSH_RETURN * 0.5)                       # 停留段保持压扁
	_hand_tween.tween_property(_hand, "scale", Vector2.ONE, PUSH_RETURN * 0.5)      # 回托举位途中恢复


func _step_flight(delta: float, vp: Vector2) -> void:
	_flight_t += delta
	# 看门狗：飞行总时长超限（含入篓引导异常）强制收尾，保证垃圾必定回手
	if _flight_t > FLIGHT_MAX_T:
		_fade_out()
		return
	var rim := _bin_front.position
	# 入篓后走引导轨迹：落向桶内 → 减速下坠 → 淡出
	if _scored:
		_step_goal(delta, rim)
		return
	_v.y += _g * delta
	_prev_y = _item.position.y
	_item.position += _v * delta
	# 透视缩放（近大远小，进度按瞄准飞行时长）+ 飞行旋转（基础自转 + 随水平速度）
	var t := clampf(_flight_t / AIM_T, 0.0, 1.0)
	_item.scale = Vector2.ONE * lerpf(1.0, SCALE_FAR, t)
	var omega := _v.x / maxf(_r, 1.0) * SPIN_GAIN
	if absf(omega) < SPIN_MIN:
		omega = SPIN_MIN if _v.x >= 0.0 else -SPIN_MIN
	_item.rotation += omega * delta
	# 入篓判定：下落段垃圾心穿越桶口平面，且 |dx| 在开口内（入篓即得分，比投篮宽松）
	if not _scored and _v.y > 0.0 and _prev_y < rim.y and _item.position.y >= rim.y:
		if absf(_item.position.x - rim.x) < _bin_front.opening_half - _r * SCORE_MARGIN:
			_score_goal()
	# 碰桶沿：仅下落段，入篓窗口内豁免，压沿按命中位置弹飞（每件一次）
	if not _scored and not _rim_hit and _v.y > 0.0:
		var tube := _r * RIM_TUBE
		for edge_x in [-_bin_front.opening_half, _bin_front.opening_half]:
			var edge := rim + Vector2(edge_x, 0.0)
			var off := _item.position - edge
			if off.length() < _r + tube:
				var n := off.normalized()
				_v = (_v - _v.dot(n) * 2.0 * n) * RIM_REST
				_item.position = edge + n * (_r + tube + 1.0)
				_rim_hit = true
				_shake_bin()
				_play_sfx("bin_hit")
				break
	# 碰桶壁/桶底（外侧，未碰沿时，仅下落段）：梯形桶身按 y 插值半宽近似
	if not _scored and not _rim_hit and not _wall_hit and _v.y > 0.0:
		_bin_wall(rim)
	# 未进：落到触地线（地面/矮弧临时地面）多次反弹衰减，每次落地发声，弹尽停稳后淡出
	if not _scored and _v.y > 0.0 and _item.position.y >= _flight_ground_y:
		_item.position.y = _flight_ground_y
		_v.y = -absf(_v.y) * GROUND_REST
		_v.x *= GROUND_FRICTION
		_play_sfx("miss")
		_count_miss()
		if absf(_v.y) < _g * BOUNCE_STOP:
			_fade_out()   # 弹尽停稳，淡出回手
			return
	# 收尾兜底：超时 / 侧向出屏
	if not _scored and (_flight_t > FLIGHT_MAX_T or _item.position.x < -_r * 3.0 \
			or _item.position.x > vp.x + _r * 3.0):
		_count_miss()
		_fade_out()


## 未入篓扣分（每次飞行只扣一次：首次触地或出屏兜底时触发）+ 红色 "-1" 飘字
func _count_miss() -> void:
	if _miss_counted:
		return
	_miss_counted = true
	_add_score(-1)
	_spawn_popup(-1)


## 桶身外侧碰撞：侧壁反弹水平速度，桶底反弹垂直速度（每件垃圾只判一次）
## 几何随贴图实测比例（bin.gd 按素材暴露）；素材缺失时 bin 侧回落到旧 512 基准兜底值
func _bin_wall(rim: Vector2) -> void:
	var s: float = _r * BIN_TEX_ITEMS / _bin_front.tex_size.x
	var body_h: float = _bin_front.body_h_px * s      # 桶口平面到桶底
	var rel := _item.position - rim
	if rel.y < 0.0 or rel.y > body_h + _r * 1.5:
		return
	var u: float = clampf(rel.y / body_h, 0.0, 1.0)
	var half: float = lerpf(_bin_front.wall_top_half_px, _bin_front.wall_bottom_half_px, u) * s   # 桶身外半宽随 y 收窄
	if absf(rel.x) > _bin_front.opening_half and absf(rel.x) < half + _r and rel.y < body_h:
		var side := signf(rel.x)
		_item.position.x = rim.x + side * (half + _r + 1.0)
		_v.x = -_v.x * WALL_REST
		_wall_hit = true
		_shake_bin()
		_play_sfx("bin_hit")
	elif absf(rel.x) < half and rel.y > body_h - _r and rel.y <= body_h + _r * 1.5:
		_item.position.y = rim.y + body_h - _r - 1.0
		_v.y = -absf(_v.y) * WALL_REST
		_wall_hit = true
		_shake_bin()
		_play_sfx("bin_hit")


func _score_goal() -> void:
	_scored = true
	_goal_phase = 1
	_goal_rel_x = _item.position.x - _bin_front.position.x   # 记录入篓瞬间相对桶心偏移（接水果同款）
	_add_score(1)
	_spawn_popup(1)
	_item.rotation = 0.0          # 入篓停转（轴对齐沉入桶内）
	_item.z_index = 0             # 沉入桶内：回到 BinFront 之下，被网格前壁遮挡
	_shake_bin()
	_play_sfx("score")


## 入篓引导轨迹：水平刚性跟随桶心（相对偏移向 0 收敛，桶快速移动也不穿模——接水果同款），
## 阶段1 指数趋近桶内高度，阶段2 减速下坠后淡出（桶内遮挡由 BinFront 网格前壁图层真实完成）
func _step_goal(delta: float, rim: Vector2) -> void:
	_goal_rel_x = move_toward(_goal_rel_x, 0.0, GOAL_CENTER_SPEED * _r * delta)
	_item.position.x = rim.x + _goal_rel_x
	var inside_y := rim.y + _r * 1.2
	if _goal_phase == 1:
		_item.position.y = lerpf(_item.position.y, inside_y, 1.0 - pow(0.002, delta))
		if _item.position.y >= inside_y - _r * 0.3:
			_goal_phase = 2
			_v = Vector2.ZERO
	else:
		_v = Vector2(0.0, minf(_v.y + _r * 3.0 * delta, _r * 2.5))
		_item.position.y += _v.y * delta
		if _item.position.y > rim.y + _r * 2.2:
			_fade_out()


## 两层桶同步晃动
func _shake_bin() -> void:
	_bin_back.shake()
	_bin_front.shake()


func _fade_out() -> void:
	if state == State.RESULT:
		return
	state = State.RESULT
	_rest_t = REST_TIME
	if _fade_tween != null:
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_item, "modulate:a", 0.0, 0.25)
