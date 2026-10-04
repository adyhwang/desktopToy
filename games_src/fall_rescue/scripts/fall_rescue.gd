extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## Fall Rescue（拯救跳楼的人）：左侧 30 层高楼，人物从阳台向右抛物线俯冲坠落，
## 鼠标平移地面救援气垫接人；落到气垫弹跳 n 次（各跳高度在首落差与下限之间均分，末跳恰为下限），
## 弹完后再被接住=获救，
## 获救者双手抱头走回楼口重新排队；任意一次落地没接住扣 1 次机会（共 3 次）
## 关卡 n：第 9+n 层起跳（封顶 30 层=无尽模式，难度冻结），每关救援 n+2 人
## 股市折线（纯氛围）：开局 -10；每 5 秒 +1/-2 随机；每 15 秒 强制 -10；白色折线 STOCK_ALPHA 透明度
## 计分：总救人数 = 分数（排行榜存最高救援数）

const Jumper := preload("res://scripts/jumper.gd")
const GameHud := preload("res://scripts/game_hud.gd")

# ===== 布局（比例 × 视口）=====
const GROUND_Y_R := 0.92       # 地面线 y / 屏高
const BLD_LEFT_R := 0.03       # 楼左缘 x / 屏宽
const BLD_W_R := 0.20          # 楼宽 / 屏宽
const BLD_H_R := 0.88          # 楼总高（30 层）/ 屏高
const FLOORS := 30
const CUSH_H_R := 0.030        # 气垫厚 / 屏高
const STOCK_RECT_R := Rect2(0.285, 0.05, 0.32, 0.20)  # 股市面板（比例）

# ===== 股市 =====
const STOCK_ALPHA := 0.80      # 折线不透明度（常量，可代码微调）
const STOCK_TICK_S := 1.0      # 随机涨跌周期
const STOCK_CRASH_S := 6.0    # 强制崩盘周期
const STOCK_MAX_PTS := 80      # 折线保留点数（滚动窗口）
const STOCK_DOWN0 := 10        # 开局固定下跌点数
const STOCK_BASE := 4000       # 总市值常量（从 4000 起扣）

# ===== 物理 =====
# 坠落节奏对齐接水果（g≈0.68 屏高、飞行 1.6~2.2s）：G_R=0.15 → 10 层自由落体 ≈1.6s、30 层 ≈3.0s
const G_R := 0.15              # 重力 = 屏高 × 此值 (px/s²)
const VY0_R := 0.05            # 跳出瞬间向下初速 / 屏高（俯冲推力）
const BOUNCE_H_MIN_PH := 1.9    # 末次弹跳高度 / 人高（各跳高度在首落差与此值之间均分）
const BOUNCE_DRIFT_PH := 1.0   # 每次弹跳水平位移 / 人高（恒定，方向 70% 右 / 10% 不动 / 20% 左）
const PREP_T := 0.5            # 跳出前阳台停留时长（s）
const LIE_SINK := 0.15         # 躺姿中心沉入垫顶以下 / 垫厚（重合式贴合，不浮空）

# ===== 节奏 =====
const SPAWN_T0 := 1.2          # 开局首次进楼延迟（s）
const MISS_DELAY := 1.1        # 失误后下一轮进楼延迟（s）
const ENTER_PAUSE_T := 0.5     # 进楼完成到新人出现在阳台的停顿（s）
const FILL_PAUSE_T := 0.5      # 补充入队完成后的间隔（s）

## 串行流程阶段（地面侧严格一步步来，不并行）
enum SpawnPh { WAIT, ENTER, PAUSE, PREP }
const WALK_SPEED_R := 0.22     # 获救者走回速度 / 屏宽每秒
const GAMEOVER_T := 1.4        # 结束 → 排行榜延迟（s）
const CHANCES0 := 3            # 初始机会

# ===== 视觉 =====
const FONT_RATIO := 0.030      # 信息板字号
const POPUP_FONT_RATIO := 0.05
const POPUP_TIME := 0.9
const POPUP_RISE_RATIO := 0.07
const SFX_POOL := 4
const BGM_DB := -6.0
const SFX_DB := -4.0

enum St { PLAY, OVER }

const CushionScript := preload("res://scripts/cushion.gd")

var hud: RefCounted

@onready var _building: Sprite2D = $Building
@onready var _jumpers: Node2D = $Jumpers
@onready var _cush = $Cushion            # cushion.gd（动态访问 hw/ch/squash）
@onready var _board_level: Label = $HudBar/BoardLevel
@onready var _board_rescued: Label = $HudBar/BoardRescued
@onready var _board_chances: Label = $HudBar/BoardChances
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state: int = St.PLAY
var _level := 1                # 当前关卡（30 层封顶后冻结）
var _endless := false          # 无尽模式（楼层到 30 后开启）
var _chances := CHANCES0
var _score := 0                # 总救人数 = 分数
var _rescued_level := 0        # 本关已救人数
var _spawn_t := SPAWN_T0
var _spawn_ph := SpawnPh.WAIT  # 地面侧串行阶段
var _fill_t := 0.0             # 补充入队冷却
var _flow_t := 0.0             # 局内流程时钟（归队时间戳用）
var _over_t := 0.0
var _lb_shown := false
var _final_rank := 0

# ---- 开发者模式（暗门：排行榜面板 5 秒内点满 10 次，关榜弹出；参数实时生效）----
var _dev_pending := false
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_cush := 1.0            # 气垫长度倍率（滑块）
var _dev_queue := 0             # 额外排队人数（滑块，调试用）
var _dev_g := 1.0               # 坠落重力倍率（滑块，反解与积分同乘保证轨迹一致）
var _dev_win: PanelContainer
var _dev_drag := false

# 布局度量（_layout 刷新）
var _vp := Vector2(1920, 1080)
var _m := 1080.0
var _g := 1728.0
var _ground_y := 993.6
var _fh := 25.92               # 单层高
var _ph := 29.8                # 人高
var _rp := 13.4                # 人碰撞半径
var _bld_left := 57.6
var _bld_w := 384.0
var _bld_h := 777.6
var _cush_hw := 86.4
var _cush_h := 32.4
var _stock_px := Rect2(547, 54, 614, 216)

# 股市
var _stock_val := STOCK_BASE
var _stock_hist: Array[int] = []
var _stock_t5 := 0.0
var _stock_t15 := 0.0

# 素材/音效
var _tex_dive: Texture2D
var _tex_dive_frames: Array = []   # dive 挥舞帧序列（person_dive_0..5.png）
var _tex_safe: Texture2D
var _tex_stand: Texture2D
var _tex_walk: Texture2D
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button


func start() -> void:
	randomize()
	hud = GameHud.new("fall_rescue")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_load_textures()
	_init_sfx()
	_layout()
	_new_game()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，分数入排行榜
	print("[fall_rescue] stop, rescued=%d level=%d" % [_score, _level])


func _exit_button_pressed() -> void:
	exit_requested.emit()


## 键盘 R 重开
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		if state == St.PLAY:
			hud.commit_score()
			_new_game()


## 排行榜关闭回调（OVER 态：结算后自动开新局；暗门已触发则先弹开发者窗口）
func on_leaderboard_closed() -> void:
	if _dev_pending:
		_dev_pending = false
		_show_dev_window()
	if state == St.OVER:
		_new_game()


## 右上角按钮排（同合集规范：HBox 容器 / 56×56 底对齐 / 32px 图标）
func _setup_buttons() -> void:
	var _hbox := HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	var lb_btn := GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	var bgm_btn := GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")
	lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [lb_btn, bgm_btn, _volume_btn, _restart_btn, _exit_btn]:
		_hbox.add_child(b)
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 32)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_on_restart)
	bgm_btn.pressed.connect(_on_bgm.bind(bgm_btn))
	_volume_btn.pressed.connect(_on_volume)
	# 容器定位右上（_layout 中随窗口刷新）
	_hbox.reset_size()
	_hbox.set_meta("hbox", true)
	_hbox.position = Vector2(_vp.x - _hbox.size.x - 20.0, 14.0)


func _on_lb() -> void:
	var title: String = hud.t("ui.top10", "Top 10")
	hud.show_leaderboard(self, title, -1, -1)
	_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次


func _on_restart() -> void:
	if state == St.PLAY:
		hud.commit_score()
		_new_game()


func _on_bgm(bgm_btn: Button) -> void:
	hud.cycle_bgm()
	bgm_btn.icon = hud.bgm_icon()
	if _bgm != null:
		if hud.bgm_on and not _bgm.playing:
			_bgm.play()
		elif not hud.bgm_on and _bgm.playing:
			_bgm.stop()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


## ===== 新局 =====
func _new_game() -> void:
	state = St.PLAY
	_level = 1
	_endless = false
	_chances = CHANCES0
	_score = 0
	_rescued_level = 0
	_spawn_t = SPAWN_T0
	_spawn_ph = SpawnPh.WAIT
	_fill_t = 0.0
	_flow_t = 0.0
	_over_t = 0.0
	_lb_shown = false
	_final_rank = 0
	for c in _jumpers.get_children():
		c.queue_free()
	# 股市重置：总市值 4000 起，开局固定下跌 10 点
	_stock_val = STOCK_BASE
	_stock_hist = [STOCK_BASE]
	_stock_t5 = 0.0
	_stock_t15 = 0.0
	_stock_move(-STOCK_DOWN0)
	hud.reset_run()
	_refresh_hud()


func _floor_cur() -> int:
	return mini(9 + _level, FLOORS)


## ===== 布局 =====
func _layout() -> void:
	_vp = get_viewport_rect().size
	_m = minf(_vp.x, _vp.y)
	_g = G_R * _vp.y
	_ground_y = _vp.y * GROUND_Y_R
	_fh = _vp.y * BLD_H_R / float(FLOORS)
	_ph = _fh * 1.15
	_rp = _ph * 0.45
	_bld_left = _vp.x * BLD_LEFT_R
	_bld_w = _vp.x * BLD_W_R
	_bld_h = _vp.y * BLD_H_R
	_cush_hw = _ph * 1.25   # 气垫全宽 = 人高 × 2.5（半宽 1.25 人高）
	_cush_h = _vp.y * CUSH_H_R
	var sr: Rect2 = STOCK_RECT_R
	_stock_px = Rect2(sr.position.x * _vp.x, sr.position.y * _vp.y, sr.size.x * _vp.x, sr.size.y * _vp.y)
	# 高楼贴图：整图拉伸到楼体矩形（贴图内 30 行与 _fh 严格线性对应）
	_building.position = Vector2(_bld_left, _ground_y - _bld_h)
	if _building.texture != null:
		_building.scale = Vector2(_bld_w / _building.texture.get_width(), _bld_h / _building.texture.get_height())
	# 气垫
	_cush.hw = _cush_hw * _dev_cush
	_cush.ch = _cush_h
	_cush.position = Vector2(_cush.position.x, _ground_y)
	# 空中人物边界刷新
	for j in _jumpers.get_children():
		j.min_x = _bld_left + _bld_w + 4.0
		j.max_x = _vp.x - _rp
		j.ground_y = _ground_y
	# 信息板居中（Node2D 父下锚点不可靠，代码定位）
	for b: Label in [_board_level, _board_rescued, _board_chances]:
		b.add_theme_font_size_override("font_size", int(_m * FONT_RATIO))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((_vp.x - _hud_bar.size.x) / 2.0, 14.0)
	# 右上按钮排
	var hbox := get_node_or_null("TopButtons")
	if hbox != null:
		hbox.reset_size()
		hbox.position = Vector2(_vp.x - hbox.size.x - 20.0, 14.0)


## ===== 主循环 =====
func _process(delta: float) -> void:
	# 气垫鼠标水平跟随（无延迟无惯性，钳制在楼右缘～屏右）
	var min_cx: float = _bld_left + _bld_w - _cush_hw * 0.5
	var max_cx: float = _vp.x - _cush_hw - 6.0
	_cush.position.x = clampf(get_global_mouse_position().x, min_cx, max_cx)

	if state == St.PLAY:
		_tick_stock(delta)
		_tick_spawn(delta)
		_tick_fill(delta)
		_tick_flow(delta)
		_judge()
	elif state == St.OVER:
		_over_t -= delta
		if _over_t <= 0.0 and not _lb_shown:
			_lb_shown = true
			_final_rank = hud.commit_score()
			var title: String = hud.t("ui.top10", "Top 10")
			hud.show_leaderboard(self, title, _score, _final_rank)
			_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次
	# 清理完成的人物（走回入口 / 摔地淡出）
	for c in _jumpers.get_children():
		if c.st == Jumper.St.DONE:
			c.queue_free()
	queue_redraw()


## 股市：每 5s 随机 +1/-2，每 15s 强制 -10（独立计时，仅视觉氛围）
func _tick_stock(delta: float) -> void:
	_stock_t5 += delta
	_stock_t15 += delta
	if _stock_t5 >= STOCK_TICK_S:
		_stock_t5 -= STOCK_TICK_S
		_stock_move(1 if randf() < 0.5 else -2)
	if _stock_t15 >= STOCK_CRASH_S:
		_stock_t15 -= STOCK_CRASH_S
		_stock_move(-10)


func _stock_move(d: int) -> void:
	_stock_val += d
	_stock_hist.append(_stock_val)
	if _stock_hist.size() > STOCK_MAX_PTS:
		_stock_hist.pop_front()


## 大门 x（楼贴图门拱中心 403/512，人物走进此位置被楼体遮挡消失）
func _door_x() -> float:
	return _bld_left + _bld_w * 0.787


## 地面侧串行流程（不并行）：WAIT（队首走向门）→ ENTER（进楼中）→ PAUSE（停 0.5s）→
## PREP（新人出现在阳台，站 0.5s 且空中无人时跳出）→ 回 WAIT（队首走向门）
func _tick_spawn(delta: float) -> void:
	var has_prep := false
	var entering := false
	for c in _jumpers.get_children():
		match c.st:
			Jumper.St.PREP:
				has_prep = true
			Jumper.St.WALK:
				if c.enter_mode:
					entering = true
	var busy_air := false
	for c in _jumpers.get_children():
		if c.st == Jumper.St.FLY or c.st == Jumper.St.AIR or c.st == Jumper.St.LIE or c.st == Jumper.St.HOP:
			busy_air = true
	for c in _jumpers.get_children():
		if c.st == Jumper.St.PREP:
			c.hold_launch = busy_air
	match _spawn_ph:
		SpawnPh.WAIT:
			_spawn_t -= delta
			# 不被入队者（ARRIVE）阻塞：队首与新人入队同向行走（入队者始终在队首右侧）无交叉，
			# 可并行；否则开局空中人失误时，队首会干等第三人入队才进楼。
			# ground_busy 仍用于 _tick_fill（补充新人串行）与 _tick_flow（获救走回者暂停）
			if not has_prep and not entering and _spawn_t <= 0.0:
				var first := _front_queuer()
				if first != null:
					first.enter_mode = true
					first.queued_at = -1.0   # 清旧时间戳：获救归队后按当前时间重排（排到队尾）
					first.walk_target_x = _door_x()
					first.st = Jumper.St.WALK
					_spawn_ph = SpawnPh.ENTER
		SpawnPh.ENTER:
			if not entering:   # 进楼者已消失在大门内
				_spawn_ph = SpawnPh.PAUSE
				_spawn_t = ENTER_PAUSE_T
		SpawnPh.PAUSE:
			_spawn_t -= delta
			if _spawn_t <= 0.0:
				_spawn_ph = SpawnPh.PREP
				_spawn_on_ledge()   # 新人出现在阳台
		SpawnPh.PREP:
			if not has_prep:   # 新人已跳出，回到 WAIT
				_spawn_ph = SpawnPh.WAIT
				_spawn_t = 0.0


## 地面是否忙碌（有人正在进楼或走入队伍）——互斥依据
func _ground_busy() -> bool:
	for c in _jumpers.get_children():
		if c.st == Jumper.St.ARRIVE:
			return true
		if c.st == Jumper.St.WALK and c.enter_mode:
			return true
	return false


## 队首（归队时间最早）的排队者
func _front_queuer() -> Jumper:
	var first: Jumper = null
	for c in _jumpers.get_children():
		if c.st == Jumper.St.QUEUE and (first == null or c.queued_at < first.queued_at):
			first = c
	return first


## 新人出现在阳台（PREP_T 停留后跳出）
func _spawn_on_ledge() -> void:
	var f := _floor_cur()
	var ledge_y: float = _ground_y - float(f - 1) * _fh          # 阳台平台顶面（与贴图行底对齐）
	var x0: float = _bld_left + _bld_w + _ph * 0.02              # 贴近楼右缘
	var y0: float = ledge_y - _ph * 0.372   # 阳台站立脚贴阳台面（同 STAND_FOOT_PH）
	var top: float = _cush.position.y - float(_cush.ch)
	var drop_h: float = top - y0                                  # 跳楼位置离气垫顶面的落差
	var vy0: float = VY0_R * _vp.y
	var t: float = (-vy0 + sqrt(vy0 * vy0 + 2.0 * _g_eff() * maxf(drop_h, 10.0))) / _g_eff()
	# 水平漂移 = 跳楼位置高度的一半（楼层越高漂得越远）
	var target_x: float = x0 + drop_h * 0.5
	var vx: float = (target_x - x0) / maxf(t, 0.1)
	var j := _make_jumper()
	_jumpers.add_child(j)
	j.prep_ledge(x0, y0, vx, vy0)


## 补充队伍：还需人数 > 0 时，新人从画面底部（队位正下方）走入入队，一次一个
## 优先级：获救走回者与归队微调先完成，再生成新人物
func _tick_fill(delta: float) -> void:
	_fill_t -= delta
	if _ground_busy() or _fill_t > 0.0:
		return
	# 获救者回归全程（躺垫/跳下/走回）优先：归队前不生成新人物（升级瞬间尤其如此）
	for c in _jumpers.get_children():
		match c.st:
			Jumper.St.LIE, Jumper.St.HOP:
				return
			Jumper.St.WALK:
				if not c.enter_mode:
					return   # 有获救走回者在走
	# 归队微调中（QUEUE 未贴到槽位）也等待
	var gap := _queue_gap(_count_qw())
	var x0: float = _bld_left + _bld_w + 6.0
	var qn := 0
	var moving := false
	for c in _jumpers.get_children():
		if c.st == Jumper.St.QUEUE or c.st == Jumper.St.ARRIVE:
			if c.st == Jumper.St.QUEUE and absf(c.position.x - (x0 + float(qn) * gap)) > 2.0:
				moving = true
			qn += 1
	if moving or _queue_need() <= 0:
		return
	var sx: float = x0 + float(qn) * gap
	var j := _make_jumper()
	_jumpers.add_child(j)
	j.position = Vector2(_vp.x + _ph, _ground_y - _ph * Jumper.STAND_FOOT_PH)   # 画面右边缘外，脚贴地
	j.walk_target_x = sx
	j.ground_y = _ground_y
	j.st = Jumper.St.ARRIVE
	j.st_t = 0.0
	_fill_t = FILL_PAUSE_T


func _make_jumper() -> Jumper:
	var j: Jumper = Jumper.new()
	j.g = _g_eff()
	j.ph = _ph
	j.rp = _rp
	j.ground_y = _ground_y
	j.min_x = _bld_left + _bld_w + 4.0
	j.max_x = _vp.x - _rp
	j.bounce_total = _level
	j.walk_speed = WALK_SPEED_R * _vp.x
	j.tex_dive = _tex_dive
	j.tex_dive_frames = _tex_dive_frames
	j.tex_safe = _tex_safe
	j.tex_stand = _tex_stand
	j.tex_walk = _tex_walk
	return j


## 多实体并行流程驱动：WALK 走向动态队位 / QUEUE 每帧贴槽位（LIE/HOP 原地起身由 jumper 自管）
func _tick_flow(delta: float) -> void:
	_flow_t += delta
	var g_busy := _ground_busy()
	var gap := _queue_gap(_count_qw())
	var x0: float = _bld_left + _bld_w + 6.0
	# 新归队者打戳（队列槽位按归队时间排序：先归队站前面，获救者归队不会插到新人物之前）
	for c in _jumpers.get_children():
		if c.st == Jumper.St.QUEUE and c.queued_at < 0.0:
			c.queued_at = _flow_t
	# 排队者按归队时间排序，槽位 0..k-1；走入中（ARRIVE）占其后，获救走回排最后
	var quers: Array = []
	var arrs := 0
	for c in _jumpers.get_children():
		if c.st == Jumper.St.QUEUE:
			quers.append(c)
		elif c.st == Jumper.St.ARRIVE:
			arrs += 1
	quers.sort_custom(func(a, b): return a.queued_at < b.queued_at)
	var wi := 0
	for q in quers:
		wi += 1
	wi += arrs
	for c in _jumpers.get_children():
		match c.st:
			Jumper.St.LIE:
				# 躺卧全程贴气垫（x=垫中间、y 沉入垫内）：玩家移动垫时人贴着垫走，不会悬空
				var top2: float = _cush.position.y - float(_cush.ch)
				c.position.x = _cush.position.x
				c.position.y = top2 + float(_cush.ch) * LIE_SINK
			Jumper.St.WALK:
				if c.enter_mode:
					if c.position.x <= _door_x() + 2.0:
						c.st = Jumper.St.DONE   # 已走进大门内，立即消失（消失点=门位）
				else:
					# 获救者走回队尾（排在队列+走入中之后）：地面互斥时暂停
					c.walk_paused = g_busy
					c.walk_target_x = x0 + float(wi) * gap
					wi += 1
			Jumper.St.QUEUE:
				if not g_busy:
					# 贴自己的槽位（先归队站前面）；地面忙碌时静止
					var rank := 0
					for i in quers.size():
						if quers[i] == c:
							rank = i
							break
					var sx: float = x0 + float(rank) * gap
					c.position.x = move_toward(c.position.x, sx, c.walk_speed * delta)
					c.position.y = _ground_y - _ph * Jumper.STAND_FOOT_PH


## 统计占队位实体数（QUEUE + 走入中 + 走回中）
func _count_qw() -> int:
	var k := 0
	for c in _jumpers.get_children():
		if c.st == Jumper.St.WALK or c.st == Jumper.St.QUEUE or c.st == Jumper.St.ARRIVE:
			k += 1
	return k


## 还需补充入队的人数 = 还需救助总数（无尽恒 8）− 队伍侧已有人（QUEUE/ARRIVE/走回）
## − 流程中人数（阳台预备/空中，含进楼中——他将跳出）
func _queue_need() -> int:
	var total := 8 if _endless else maxi(_level + 2 - _rescued_level, 0)
	total += _dev_queue   # 开发者模式：额外排队人数
	var in_flow := 0
	var in_queue := 0
	for c in _jumpers.get_children():
		match c.st:
			Jumper.St.PREP, Jumper.St.FLY, Jumper.St.AIR:
				in_flow += 1
			Jumper.St.WALK:
				if c.enter_mode:
					in_flow += 1   # 进楼中，即将跳出
				else:
					in_queue += 1   # 获救走回，即将归队
			Jumper.St.QUEUE, Jumper.St.ARRIVE:
				in_queue += 1
	return clampi(total - in_flow - in_queue, 0, 64)


## 排队间距：人多时压缩（队尾不越 0.66 屏宽），最小半人距防完全重叠
func _queue_gap(_n: int) -> float:
	var gap: float = _ph * 0.5   # 每人间隔约半个人宽度（紧凑）
	if _n > 1:   # 人数极多时压缩（队尾不越 0.66 屏宽），下限 0.35 人宽防完全重叠
		gap = minf(gap, (_vp.x * 0.66 - (_bld_left + _bld_w + 6.0)) / float(_n - 1))
	return maxf(gap, _ph * 0.35)


## 判定（仅下落段 v.y > 0）：穿越气垫顶面且横向在垫内 = 弹跳/获救；落到地面 = 失误
func _judge() -> void:
	for c in _jumpers.get_children():
		if c.st == Jumper.St.FLY or c.st == Jumper.St.AIR:
			_judge_one(c)


func _judge_one(j: Jumper) -> void:
	if j.v.y <= 0.0:
		return
	var top: float = _cush.position.y - float(_cush.ch)
	var b_prev: float = j.prev_y + j.rp
	var b_now: float = j.position.y + j.rp
	# 横向窗口：人物边缘沾到垫边即算（比垫宽多让半个人身半径）
	var in_x: bool = absf(j.position.x - _cush.position.x) < float(_cush.hw) + j.rp * 0.5
	# 命中 = 穿越垫面瞬间，或底部已入垫体（垫面拦截：高速下落/气垫移动时不漏接）
	var hit: bool = in_x and ((b_prev <= top and b_now >= top) \
			or (b_now > top and b_now < top + float(_cush.ch) * 0.9))
	if hit:
		if j.bounces_done < _level:
			j.bounces_done += 1
			# 弹起高度：首落差（首跳触垫时锁定）与下限之间均分 n 档，第 k 跳 = h0 - k*(h0-min)/n，末跳恰为下限
			if j.bounces_done == 1:
				j.fall0_h = top - j.apex_y
			var min_h: float = _ph * BOUNCE_H_MIN_PH
			var h: float = maxf(j.fall0_h - float(j.bounces_done) * (j.fall0_h - min_h) / float(_level), min_h)
			var vy_up: float = -sqrt(2.0 * _g_eff() * h)
			# 水平位移：单次恒定（1 人高），方向 70% 右 / 10% 不动 / 20% 左
			var t_b: float = 2.0 * absf(vy_up) / _g_eff()
			var r := randf()
			var dir: float = 1.0 if r < 0.7 else (0.0 if r < 0.8 else -1.0)
			var vx_new: float = dir * BOUNCE_DRIFT_PH * _ph / maxf(t_b, 0.1)
			j.position.y = top - j.rp * 0.5   # 底部沉入垫面半个身位（用户要求重合贴合）
			j.bounce(vy_up, vx_new)
			_cush.squash()
			_play_sfx("thud", -3.0)
		else:
			_rescue(j)
		return
	if b_now >= _ground_y:
		_miss(j)


## 获救：+1 人；躺在气垫中间（主控每帧贴垫）→ 原地起身 → 跑回队尾
func _rescue(j: Jumper) -> void:
	var top: float = _cush.position.y - float(_cush.ch)
	j.position.x = _cush.position.x                      # 躺在气垫中间
	j.position.y = top + float(_cush.ch) * LIE_SINK      # 中心沉入垫内=重合式贴合
	j.land_safe()
	_score += 1
	_rescued_level += 1
	hud.submit_score(_score)
	hud.on_success()
	_play_sfx("catch")
	_popup("+1", Color(0.2, 0.85, 0.3), 0.40, false)
	if not _endless and _rescued_level >= _level + 2:
		_level_up()
	_refresh_hud()


## 过关：楼层 +1（封顶 30 = 无尽模式，难度冻结）
func _level_up() -> void:
	_level += 1
	_rescued_level = 0
	if _floor_cur() >= FLOORS:
		_endless = true
	var txt: String = hud.t("popup.levelup", "LEVEL %d") % _level
	_popup(txt, Color(1.0, 0.85, 0.25), 0.34, true)


## 失误：落地没接住，扣 1 次机会
func _miss(j: Jumper) -> void:
	j.splat()
	_chances -= 1
	hud.on_fail()
	_play_sfx("bad")
	_popup("-1", Color(0.95, 0.25, 0.2), 0.40, false)
	if _chances <= 0:
		_chances = 0
		state = St.OVER
		_over_t = GAMEOVER_T
		var txt: String = hud.t("popup.gameover", "GAME OVER")
		_popup(txt, Color(0.95, 0.25, 0.2), 0.40, true)
	else:
		_spawn_t = MISS_DELAY
	_refresh_hud()


func _refresh_hud() -> void:
	var s_lv: String = hud.t("hud.level", "LV %d")
	_board_level.text = s_lv % _level
	var s_rd: String = hud.t("hud.rescued", "Rescued %d")
	_board_rescued.text = s_rd % _score
	var s_ch: String = hud.t("hud.chances", "Chances %d")
	_board_chances.text = s_ch % _chances


## ===== 开发者模式（暗门 + 可拖动调试窗口，参数实时生效、游戏不暂停）=====

## 实际重力（含开发者倍率；跳出反解与积分同用，保证轨迹一致）
func _g_eff() -> float:
	return _g * _dev_g


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
		[hud.t("dev.next_level", "Next Level"), _dev_next_level, hud.t("dev.tip_next_level", "Instantly finish this level's rescue goal and advance")],
		[hud.t("dev.chance_up", "Chance +1"), _dev_chance_up, hud.t("dev.tip_chance_up", "Add 1 remaining chance")],
		[hud.t("dev.chance_full", "Chance = 3"), _dev_chance_full, hud.t("dev.tip_chance_full", "Restore chances to 3")],
		[hud.t("dev.stock_down", "Stock -10"), _dev_stock_down, hud.t("dev.tip_stock_down", "Stock market drops 10 points at once")],
		[hud.t("dev.spawn_now", "Spawn Now"), _dev_spawn_now, hud.t("dev.tip_spawn_now", "Skip the current enter-building delay and advance at once")],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.tooltip_text = a[2]   # 悬停提示
		b.pressed.connect(a[1])
		grid.add_child(b)
	# 滑块：气垫长度 / 排队人数 / 坠落速度
	_dev_add_slider(vb, hud.t("dev.cushion", "Cushion Length"), _dev_cush, 0.3, 4.0, hud.t("dev.tip_cushion", "Rescue cushion length multiplier"), func(v: float) -> void:
		_dev_cush = v
		_cush.hw = _cush_hw * _dev_cush)
	_dev_add_slider(vb, hud.t("dev.queue", "Queue Count"), float(_dev_queue), 0.0, 20.0, hud.t("dev.tip_queue", "Extra people in queue (added on top of the level goal)"), func(v: float) -> void:
		_dev_queue = int(round(v)), true)
	_dev_add_slider(vb, hud.t("dev.fall_speed", "Fall Speed"), _dev_g, 0.3, 3.0, hud.t("dev.tip_fall_speed", "Fall speed multiplier (gravity; jump trajectory solves with it too)"), func(v: float) -> void:
		_dev_g = v
		for c in _jumpers.get_children():
			c.g = _g_eff())
	add_child(_dev_win)
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 标题栏拖动（游戏不暂停）
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += event.relative)


## 调试滑块行：左侧标签（显示当前值），右侧 HSlider；tip 为悬停提示；is_int 时整数步进
func _dev_add_slider(parent: Control, label: String, init: float, mn: float, mx: float, tip: String, on_change: Callable, is_int := false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.tooltip_text = tip
	parent.add_child(row)
	var lb := Label.new()
	lb.text = ("%s %d" % [label, int(init)]) if is_int else ("%s ×%.2f" % [label, init])
	lb.add_theme_font_size_override("font_size", 13)
	lb.custom_minimum_size = Vector2(150.0, 0)
	lb.add_theme_color_override("font_color", Color.WHITE)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 4)
	row.add_child(lb)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = 1.0 if is_int else 0.05
	sl.value = init
	sl.custom_minimum_size = Vector2(140.0, 20.0)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.value_changed.connect(func(v: float) -> void:
		on_change.call(v)
		lb.text = ("%s %d" % [label, int(v)]) if is_int else ("%s ×%.2f" % [label, v]))
	row.add_child(sl)


func _dev_close() -> void:
	_dev_drag = false
	if _dev_win != null and is_instance_valid(_dev_win):
		_dev_win.queue_free()
	_dev_win = null


## 调试按钮动作
func _dev_next_level() -> void:
	if not _endless:
		_rescued_level = _level + 2
		_level_up()
	_refresh_hud()


func _dev_chance_up() -> void:
	_chances = mini(_chances + 1, 99)
	_refresh_hud()


func _dev_chance_full() -> void:
	_chances = CHANCES0
	_refresh_hud()


func _dev_stock_down() -> void:
	_stock_move(-10)


func _dev_spawn_now() -> void:
	_spawn_t = 0.0


## ===== 绘制：地面 / 排队人群 / 股市折线（根节点 _draw 在子节点之下）=====
func _draw() -> void:
	# 地面
	draw_rect(Rect2(0.0, _ground_y, _vp.x, _vp.y - _ground_y), Color(0.09, 0.09, 0.11, 0.5))
	draw_rect(Rect2(0.0, _ground_y, _vp.x, 2.5), Color(1, 1, 1, 0.28))
	_draw_door()
	_draw_stock()


## 大门入口标记（排队人群已全部实体化，由 _tick_fill 从画面底部走入）
func _draw_door() -> void:
	draw_rect(Rect2(_door_x() - _ph * 1.2, _ground_y - 3.0, _ph * 2.4, 3.0), Color(1, 1, 1, 0.18))


## 股市折线（涨红跌绿，市值 4000 起，透明度 STOCK_ALPHA，仅氛围）
func _draw_stock() -> void:
	var px := _stock_px
	draw_rect(px, Color(0.04, 0.06, 0.08, 0.32))
	draw_rect(px, Color(1, 1, 1, 0.22), false, 1.5)
	var col_up := Color(0.92, 0.24, 0.22, STOCK_ALPHA)     # 上涨红
	var col_down := Color(0.25, 0.78, 0.38, STOCK_ALPHA)   # 下跌绿
	var n := _stock_hist.size()
	var last_col := col_down
	if n >= 2:
		var vmin: float = float(_stock_hist.min())
		var vmax: float = float(_stock_hist.max())
		if vmax - vmin < 6.0:
			var mid := (vmax + vmin) * 0.5
			vmin = mid - 3.0
			vmax = mid + 3.0
		var pts := PackedVector2Array()
		for i in n:
			var fx: float = px.position.x + 8.0 + (px.size.x - 16.0) * float(i) / float(n - 1)
			var fy: float = px.position.y + 8.0 + (px.size.y - 16.0) * (1.0 - (float(_stock_hist[i]) - vmin) / (vmax - vmin))
			pts.append(Vector2(fx, fy))
		# 逐段画线：涨红 / 跌绿（A 股配色）
		for i in range(1, n):
			var c := col_up if _stock_hist[i] >= _stock_hist[i - 1] else col_down
			draw_line(pts[i - 1], pts[i], c, 2.5, true)
		last_col = col_up if _stock_hist[n - 1] >= _stock_hist[n - 2] else col_down
		draw_circle(pts[n - 1], 3.5, last_col)
	# 当前市值（颜色随最新涨跌）
	var font := ThemeDB.fallback_font
	var fs := int(_m * 0.024)
	var val_txt := "%d" % _stock_val
	var tw: float = font.get_string_size(val_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var vx: float = px.end.x - tw - 10.0
	draw_string(font, Vector2(vx + 2.0, px.position.y + fs + 10.0 + 2.0), val_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2(vx, px.position.y + fs + 10.0), val_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, last_col)


## 飘字（+1 / -1 / LEVEL N / GAME OVER）：屏幕中部浮现上飘淡出
func _popup(txt: String, col: Color, y_ratio: float, big: bool) -> void:
	var m := _m
	var lb := Label.new()
	lb.text = txt
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 10)
	lb.add_theme_font_size_override("font_size", int(m * (0.085 if big else POPUP_FONT_RATIO)))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.6, m * 0.1)
	lb.position = Vector2(_vp.x * 0.55 - lb.size.x * 0.5, _vp.y * y_ratio)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * POPUP_RISE_RATIO, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## ===== 素材 =====
func _load_textures() -> void:
	_tex_dive = _load_png("person_dive.png")
	_tex_dive_frames.clear()
	for i in 6:
		var t: Texture2D = _load_png("person_dive_%d.png" % i)
		if t == null:
			break
		_tex_dive_frames.append(t)
	if _tex_dive_frames.is_empty() and _tex_dive != null:
		_tex_dive_frames.append(_tex_dive)   # 无帧序列退化为单帧
	_tex_safe = _load_png("person_safe.png")
	_tex_stand = _load_png("person_stand.png")
	_tex_walk = _load_png("person_walk.png")
	_building.texture = _load_png("building.png")
	_cush.tex = _load_png("cushion.png")


## png 双路径字节解码（pck 内未走导入流程；第二条供编辑器直接预览）
func _load_png(fname: String) -> Texture2D:
	for base in ["res://games/fall_rescue/assets/", "res://assets/"]:
		var f := FileAccess.open(base + fname, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


## 音效初始化：pck 内 mp3 走字节解码，编辑器预览走导入资源（双路径）
func _init_sfx() -> void:
	var files := {"catch": "catch.mp3", "thud": "thud.mp3", "bad": "bad.mp3"}
	for sfx_name: String in files:
		for base in ["res://games/fall_rescue/assets/sfx/", "res://assets/sfx/"]:
			var path: String = base + files[sfx_name]
			if ResourceLoader.exists(path):
				_sfx_streams[sfx_name] = load(path)
				break
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				_sfx_streams[sfx_name] = AudioStreamMP3.load_from_buffer(f.get_buffer(f.get_length()))
				break
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	for base in ["res://games/fall_rescue/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## 播放音效：从池中取空闲播放器
func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx_streams.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return
