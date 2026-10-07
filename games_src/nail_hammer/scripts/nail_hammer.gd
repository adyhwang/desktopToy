extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 锤钉高手（Nail Hammer）：木板上的钉子高度各不相同，移动鼠标吸附对准钉子，
## 按住左键蓄力（无蓄力条：蓄力力度进入当前钉子剩余深度的容差带时锤子闪光+微震提示），
## 松开挥锤击打——蓄力决定钉入深度，任意高度的钉子都可一次钉入，只有一次刚好钉入才算完美。
## 完美击打仅限一次击打就把钉子钉入位（高分）；被普通击打过的钉子（多次击打）不再有完美判定；过载打弯钉子扣分（弯钉头留在木板面上可见）。
## 钉子有夸张卡通表情：平时随剩余高度（平静/担忧/害怕），蓄力时按力度（得意/担忧/惊恐），击打后上浮反应（开心/咬牙/晕厥）。
## 全部钉子钉入木板通关进入下一关（按剩余时间奖励）。
## 关卡：3×3 起，每关扩 1 格（方向按屏幕剩余空间逐格判断，总格子数达 36 封顶且单维可超 6）
## 最高分复用合集存档（GameHud submit_score/commit_score）

const GameHud := preload("res://scripts/game_hud.gd")

# ===== 布局 =====
const TOP_H := 86.0          # 顶栏高度
const MARGIN := 14.0         # 棋盘区边距

# ===== 关卡 / 玩法 =====
const BOARD_MIN := 3         # 第 1 关 3×3
const BOARD_CELLS := 36      # 总格子数上限（=6×6，单维可超 6），达到后不再扩大
const CHARGE_MAX := 1.6      # 蓄力满值（秒），到顶后不再增长
const MAX_HIT_DEPTH := 1.0   # 单次最大击打深度（=钉子总高归一化 1.0，任意高度的钉子都可一次钉入）
const PERFECT_TOL_START := 0.24   # 第 1 关完美容差（窗口 ≈ 0.77s，前期大幅降低难度）
const PERFECT_TOL_MIN := 0.09     # 完美容差下限（第 6 关起保持，窗口 ≈ 0.29s）
const PERFECT_TOL_STEP := 0.03    # 每关容差收紧量
const NAIL_SEAT_TOL := 0.06  # 击打后剩余 ≤ 此值视为已钉牢（防"看似钉完还能再钉"）
const PERFECT_HINT_T := 0.28 # 完美窗口提示动画时长（s）：锤子闪光+微震，无蓄力条
const NAIL_H0_MIN := 0.3     # 初始露出高度下限
const NAIL_H0_MAX := 1.0     # 初始露出高度上限
const NAIL_H_K := 0.62       # 露出 1.0 对应像素高（×cell）
const HAM_CANVAS := 256.0
const HAM_PIVOT := Vector2(116, 220)   # 柄尾（挥锤旋转锚点，画布坐标，复用 hammer 游戏锤子素材）
const HAM_HEAD := Vector2(115, 60)     # 锤头中心（完美提示闪光锚点，画布坐标）
const HAM_REST := -0.55      # 悬停角（弧度，负=逆时针即头向左倾）
const HAM_RAISED := -0.20    # 蓄力满时扬起角（越接近 0 头越高）
const HAM_HIT_ANG := -PI / 2.0   # 落锤角：锤头转到柄尾正左方（击打点=反推的 pivot 偏移基准）
const SCORE_HIT := 1         # 普通击打
const SCORE_PERFECT := 10    # 完美击打
const SCORE_OVER := -3       # 蓄力过载（打弯钉子）
const TIME_BASE := 12.0      # 关卡限时 = TIME_BASE + 钉数 × TIME_PER_NAIL
const TIME_PER_NAIL := 3.5
const TIME_BONUS_PER_S := 2  # 通关时每剩余 1 秒的奖励分
const SWING_DUR := 0.09      # 挥锤下摆时长（s）
const HIT_AT := SWING_DUR    # 命中判定时刻=下摆到底（锤头落到钉上）瞬间
const RECOVER_DUR := 0.22    # 挥锤后回弹时长（s）
const POPUP_TIME := 0.8      # 飘字动画时长（s）
const SFX_POOL := 4
const BGM_DB := -12.0
const SFX_DB := -4.0

# 配色（扁平卡通，纯色 + 黑描边，对齐合集风格）
const COL_BOARD := Color(0.804, 0.522, 0.247)        # 木板
const COL_BOARD_D := Color(0.588, 0.353, 0.157)      # 木板横纹/板缝
const COL_BOARD_L := Color(0.878, 0.635, 0.353)      # 木板亮面
const COL_OUTLINE := Color(0.12, 0.10, 0.09)         # 黑描边
const COL_AIM := Color(0.30, 0.85, 0.40, 0.38)       # 吸附钉子顶部绿色高亮
const COL_GOLD := Color(1.0, 0.85, 0.25)
const COL_ERR := Color(0.92, 0.22, 0.16)
const COL_CHIP := Color(0.878, 0.635, 0.353)         # 木屑
const COL_CHIP_D := Color(0.690, 0.435, 0.184)
const COL_CRACK := Color(0.34, 0.21, 0.09)           # 木板裂纹（过载击打）
const COL_DENT := Color(0.40, 0.26, 0.12)            # 过载木板凹陷压痕
const CRACK_MAX := 40        # 裂纹组上限（超出移除最旧）
const COL_FACE := Color(0.16, 0.12, 0.10)            # 钉子表情线条色
const FACE_T := 0.7          # 击打反应表情存活时长（s）

enum State { IDLE, CHARGING, SWING }

var hud: RefCounted
var level := 1
var score := 0
var cols := BOARD_MIN
var rows := BOARD_MIN
var nails: Array = []             # rows*cols 个 {h0, h, disp_h, bent}，行优先；h=剩余露出（0..1），disp_h 绘制平滑收敛
var done_count := 0               # 已钉入数量
var _tex_nail: Texture2D
var _tex_bent: Texture2D
var _tex_hammer: Texture2D
var _cell := 90.0
var _origin := Vector2.ZERO       # 棋盘左上角
var _state := State.IDLE
var _mouse := Vector2.ZERO        # 鼠标逻辑坐标
var _aim := -1                    # 当前吸附钉子索引（-1 无；蓄力中移动鼠标可换目标，挥锤动画中停更=隐式锁定）
var _hammer_pos := Vector2.ZERO   # 锤柄尾（pivot）平滑位置
var _charge_t := 0.0
var _in_zone := false             # 蓄力中是否处于完美窗口（边沿触发提示）
var _hint_t := -1.0               # >=0：完美窗口提示闪光剩余（锤子闪光+微震）
var _swing_t := 0.0
var _swing_from := 0.0            # 挥锤起始角
var _hit_applied := false
var _shake_t := -1.0              # >=0：屏幕震动剩余
var _shake_amp := 0.0
var _particles: Array = []        # 木屑 {pos, vel, t, col, size}
var _cracks: Array = []           # 过载击打木板裂纹 [{segs: Array[PackedVector2Array]}]（每关清空）
var _faces: Array = []            # 击打反应表情 {pos, state, t}（从钉头上浮淡出）
var _anim_t := 0.0                # 全局动画时钟（眨眼相位）
var _flash_t := -1.0              # >=0：特效倒计时（金/红）
var _flash_pos := Vector2.ZERO
var _flash_gold := true
var _settle_t := -1.0             # >=0：通关结算倒计时（进下一关）
var time_limit := 60.0
var time_left := 60.0
var _timed_out := false           # 超时后停表（不失败，仅无时间奖励）
var _last_time_shown := -1
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _hbox: HBoxContainer
var _lb_btn: Button
var _restart_btn: Button
var _bgm_btn: Button
var _volume_btn: Button

@onready var _level_board: Label = $HudBar/LevelBoard
@onready var _score_board: Label = $HudBar/ScoreBoard
@onready var _time_board: Label = $HudBar/TimeBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("nail_hammer")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()   # 先建按钮再布局（_layout 会定位，null 会报错中断）
	_layout()
	_init_sfx()
	_gen_level()
	_hammer_pos = get_viewport_rect().size * 0.5


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，得分入排行榜
	print("[nail_hammer] stop, level=%d score=%d" % [level, score])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()
		return
	if event is InputEventMouseMotion:
		_mouse = event.position
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == State.IDLE and _settle_t < 0.0 and _aim >= 0:
			_state = State.CHARGING
			_charge_t = 0.0
			_in_zone = false
		elif not event.pressed and _state == State.CHARGING:
			_swing_from = _charge_angle(_charge_t / CHARGE_MAX)
			_swing_t = 0.0
			_hit_applied = false
			_in_zone = false
			_state = State.SWING


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 关卡 =====

## 棋盘可用像素区（与 _layout 同源）
func _board_avail() -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(maxf(vp.x - MARGIN * 2.0, 60.0), maxf(vp.y - TOP_H - MARGIN * 2.0, 60.0))


## 棋盘尺寸：从 3×3 起每关扩 1 格，方向按屏幕剩余空间决定（avail = 可用像素区）——
## 横向加一列不缩格子则优先加宽，否则纵向加一行不缩格子则加高；
## 两边都要缩格子时选格子更大的方向继续扩；总格子数达到 BOARD_CELLS（=6×6=36，单维可超 6）后不再扩大
func _board_dims(steps: int, avail: Vector2) -> Vector2i:
	var w := BOARD_MIN
	var h := BOARD_MIN
	for i in steps:
		if w * h >= BOARD_CELLS:
			break
		var cur := minf(avail.x / w, avail.y / h)   # 当前格子边长
		var cw := avail.x / (w + 1.0)               # 加一列后的格子边长
		var ch := avail.y / (h + 1.0)               # 加一行后的格子边长
		if cw >= cur:
			w += 1
		elif ch >= cur:
			h += 1
		elif cw >= ch:
			w += 1
		else:
			h += 1
	return Vector2i(w, h)


## 生成关卡：棋盘扩格 → 每格随机一颗钉子（初始露出高度随机，越高需要越多击打）→ 校准限时
func _gen_level() -> void:
	var dims := _board_dims(level - 1, _board_avail())
	cols = dims.x
	rows = dims.y
	nails.resize(cols * rows)
	done_count = 0
	for i in nails.size():
		var h0 := randf_range(NAIL_H0_MIN, NAIL_H0_MAX)
		nails[i] = {"h0": h0, "h": h0, "disp_h": h0, "bent": false, "touched": false}
	time_limit = TIME_BASE + nails.size() * TIME_PER_NAIL
	time_left = time_limit
	_timed_out = false
	_last_time_shown = -1
	_state = State.IDLE
	_aim = -1
	_settle_t = -1.0
	_particles.clear()
	_cracks.clear()
	_faces.clear()
	_flash_t = -1.0
	_shake_t = -1.0
	_refresh_labels()
	_layout()   # rows/cols 变了必须重算 cell/origin


## ===== 主循环 =====

func _process(delta: float) -> void:
	_anim_t += delta
	# 锤子吸附目标：最近的未完成钉子（网格中心距离）
	_update_aim()
	# 锤柄尾平滑跟随吸附钉子上方
	var target := _hammer_target()
	_hammer_pos = _hammer_pos.lerp(target, minf(delta * 14.0, 1.0))
	# 钉子绘制高度平滑收敛（钉入下移动画）
	for n: Dictionary in nails:
		n.disp_h += (n.h - n.disp_h) * minf(delta * 12.0, 1.0)
	match _state:
		State.CHARGING:
			_charge_t = minf(_charge_t + delta, CHARGE_MAX)
			# 完美窗口提示：仅未击打过的钉子可完美——蓄力力度进入 [剩余-座入容差, 剩余+完美容差]
			# （此刻松手即可一次入位=完美）时锤子闪光+微震，边沿触发一次
			var in_zone := false
			if _aim >= 0 and not nails[_aim].touched:
				var ratio := _charge_t / CHARGE_MAX
				var rem: float = nails[_aim].h
				in_zone = ratio >= rem - NAIL_SEAT_TOL and ratio <= rem + _perfect_tol()
			if in_zone and not _in_zone:
				_hint_t = PERFECT_HINT_T
				_shake_t = 0.12
				_shake_amp = 2.5
			_in_zone = in_zone
		State.SWING:
			_swing_t += delta
			if not _hit_applied and _swing_t >= HIT_AT:
				_hit_applied = true
				_apply_hit(_charge_t / CHARGE_MAX)
			if _swing_t >= SWING_DUR + RECOVER_DUR:
				_state = State.IDLE
	# 计时（未超时且未结算时递减；超时不失败，仅无时间奖励）
	if not _timed_out and _settle_t < 0.0:
		time_left = maxf(time_left - delta, 0.0)
		if time_left <= 0.0:
			_timed_out = true
			_refresh_labels()
	# 通关结算倒计时
	if _settle_t >= 0.0:
		_settle_t -= delta
		if _settle_t < 0.0:
			_next_level()
	# 特效衰减
	if _shake_t >= 0.0:
		_shake_t -= delta
	if _flash_t >= 0.0:
		_flash_t -= delta
	if _hint_t >= 0.0:
		_hint_t -= delta
	# 击打反应表情：上浮 + 倒计时
	for f: Dictionary in _faces:
		f.t -= delta
		f.pos.y -= delta * _cell * 0.35
	_faces = _faces.filter(func(f: Dictionary) -> bool: return f.t > 0.0)
	# 表情眨眼/反应动画需要持续重绘，直接每帧重绘
	queue_redraw()
	_refresh_time()


## 吸附：找距鼠标最近的未完成钉子（悬停与蓄力中动态更新——按住未放也可换目标；挥锤动画中停更）
func _update_aim() -> void:
	if _state == State.SWING:
		return
	var best := -1
	var best_d := INF
	for i in nails.size():
		var n: Dictionary = nails[i]
		if n.h <= 0.0:
			continue
		var d := _cell_center(i).distance_to(_mouse)
		if d < best_d:
			best_d = d
			best = i
	_aim = best


## 锤柄尾（pivot）目标位：击打点=当前钉子露出段上部，落锤角（-90°）时锤头恰好落在击打点上——
## 锤头相对柄尾 (HAM_HEAD-HAM_PIVOT) 旋转 -90° 后 = (-160, 1)（画布坐标），反推 pivot = 击打点 + (160, -1)×s
func _hammer_target() -> Vector2:
	var aim := _aim
	if aim < 0:
		return _mouse
	var n: Dictionary = nails[aim]
	var pos := _cell_center(aim)
	var nail_h_px := _cell * NAIL_H_K
	var vis_h: float = clampf(n.disp_h, 0.02, 1.0) * nail_h_px
	var target := Vector2(pos.x, pos.y + nail_h_px * 0.28 - vis_h + minf(vis_h * 0.3, _cell * 0.12))
	return target + Vector2(160.0, -1.0) * (_hammer_tsz() / HAM_CANVAS)


## 锤子显示边长（画布 256 映射到屏幕的尺寸）：随钉子高度缩放，限高防顶行出屏
func _hammer_tsz() -> float:
	var vp := get_viewport_rect().size
	return minf(_cell * NAIL_H_K * 1.35, vp.y * 0.20)


## 蓄力姿态角：从悬停角向扬起角过渡（蓄力越满锤头扬得越高）
func _charge_angle(ratio: float) -> float:
	return lerpf(HAM_REST, HAM_RAISED, clampf(ratio, 0.0, 1.0))


## 完美容差（归一化深度）：完美 = 一次击打入位（力度缺口 ≤ NAIL_SEAT_TOL）且未过载（超出 ≤ 此值）
## ——前期宽（窗口长、降低难度），每关收紧，第 6 关起保持下限
func _perfect_tol() -> float:
	return maxf(PERFECT_TOL_MIN, PERFECT_TOL_START - float(level - 1) * PERFECT_TOL_STEP)


func _hammer_angle() -> float:
	match _state:
		State.CHARGING:
			return _charge_angle(_charge_t / CHARGE_MAX)
		State.SWING:
			if _swing_t < SWING_DUR:
				var k := _swing_t / SWING_DUR
				return lerpf(_swing_from, HAM_HIT_ANG, k * k)   # 快速下摆（锤头砸向钉子）
			var k2 := (_swing_t - SWING_DUR) / RECOVER_DUR
			return lerpf(HAM_HIT_ANG, HAM_REST, minf(k2, 1.0))   # 回弹
	return HAM_REST   # IDLE 悬停


## ===== 击打 =====

func _apply_hit(ratio: float) -> void:
	var aim := _aim
	if aim < 0 or ratio <= 0.02:
		return
	var n: Dictionary = nails[aim]
	var pos := _cell_center(aim)
	var hit_depth := ratio * MAX_HIT_DEPTH   # 单次击打深度
	var rem: float = n.h                     # 剩余露出
	_shake_t = 0.28
	_shake_amp = 3.0 + ratio * 9.0
	if hit_depth > rem + _perfect_tol():
		# 蓄力过载：打弯钉子（一击钉入但扣分）
		n.h = 0.0
		n.bent = true
		done_count += 1
		score += SCORE_OVER
		_flash_gold = false
		_flash_t = 0.45
		_flash_pos = pos
		_spawn_chips(pos, 8)
		_spawn_cracks(pos)
		_spawn_face(pos, "ko")
		_play_sfx("miss")
		_spawn_popup("%d %s" % [SCORE_OVER, hud.t("nh.overload", "Over!")], COL_ERR, pos)
		hud.submit_score(maxi(score, 0))
	elif not n.touched and rem - hit_depth <= NAIL_SEAT_TOL:
		# 完美击打：仅限第一击就把钉子一次钉入位（力度缺口 ≤ NAIL_SEAT_TOL 且未过载）
		# 被普通击打过（touched）的钉子不再有完美判定
		n.h = 0.0
		done_count += 1
		score += SCORE_PERFECT
		_flash_gold = true
		_flash_t = 0.45
		_flash_pos = pos
		_spawn_chips(pos, 14)
		_spawn_face(pos, "happy")
		_play_sfx("perfect")
		_spawn_popup("+%d %s" % [SCORE_PERFECT, hud.t("nh.perfect", "Perfect!")], COL_GOLD, pos)
		hud.submit_score(score)
	else:
		# 普通击打：部分钉入（力度不足/多次击打/未一次入位）；剩余极薄视为已钉牢，防"看似钉完还能再钉"
		n.h = rem - hit_depth
		score += SCORE_HIT
		if n.h <= NAIL_SEAT_TOL:
			n.h = 0.0
			done_count += 1
		else:
			n.touched = true   # 未一次入位，之后该钉子不再有完美判定
		_spawn_chips(pos, 6)
		_spawn_face(pos, "grit")
		_play_sfx("hit")
		_spawn_popup("+%d" % SCORE_HIT, Color(1, 1, 1), pos)
		hud.submit_score(score)
	_refresh_labels()
	if done_count >= nails.size():
		_finish_level()


## 全部钉入：结算时间奖励并进入下一关
func _finish_level() -> void:
	var bonus := 0
	if time_left > 0.0:
		bonus = int(time_left) * TIME_BONUS_PER_S
		score += bonus
	hud.submit_score(score)
	_refresh_labels()
	if bonus > 0:
		_spawn_popup("+%d %s" % [bonus, hud.t("nh.time_bonus", "Time Bonus")], COL_GOLD, _board_rect().get_center() + Vector2(0, -_cell))
	_play_sfx("perfect")
	_settle_t = 1.1


func _next_level() -> void:
	level += 1
	_gen_level()


## ===== 布局 =====

## 棋盘严格贴合可用区（随屏幕宽高与关卡尺寸缩放）
func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var avail := _board_avail()
	_cell = maxf(minf(avail.y / rows, avail.x / cols), 1.0)
	var bw := cols * _cell
	var bh := rows * _cell
	_origin = Vector2(MARGIN + maxf((avail.x - bw) * 0.5, 0.0), TOP_H + maxf((avail.y - bh) * 0.5, 0.0))
	_level_board.custom_minimum_size = Vector2(150.0, m * 0.051)
	_level_board.add_theme_font_size_override("font_size", int(m * 0.035))
	_score_board.custom_minimum_size = Vector2(150.0, m * 0.051)
	_score_board.add_theme_font_size_override("font_size", int(m * 0.035))
	_time_board.custom_minimum_size = Vector2(150.0, m * 0.051)
	_time_board.add_theme_font_size_override("font_size", int(m * 0.035))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	_refresh_labels()
	queue_redraw()


func _board_rect() -> Rect2:
	return Rect2(_origin, Vector2(cols * _cell, rows * _cell))


func _cell_center(i: int) -> Vector2:
	return _origin + (Vector2(i % cols, i / cols) + Vector2(0.5, 0.5)) * _cell


func _refresh_labels() -> void:
	_level_board.text = str(level)
	_score_board.text = str(score)


func _refresh_time() -> void:
	var s := int(ceilf(time_left))
	if s != _last_time_shown:
		_last_time_shown = s
		_time_board.text = str(s)


## ===== 绘制 =====

func _draw() -> void:
	if nails.is_empty():
		return
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	# 屏幕震动偏移
	var off := Vector2.ZERO
	if _shake_t >= 0.0:
		off = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake_amp * (_shake_t / 0.28)
	var orig := Transform2D()
	orig.origin = off
	draw_set_transform_matrix(orig)
	# 木板（覆盖网格图案）：整块圆角木板 + 横纹 + 黑描边
	var pad := _cell * 0.16
	var board := _board_rect().grow(pad)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BOARD
	sb.border_color = COL_OUTLINE
	sb.set_border_width_all(maxi(int(m * 0.006), 3))
	sb.set_corner_radius_all(int(_cell * 0.22))
	draw_style_box(sb, board)
	# 木纹横线（每行一条板缝 + 亮面高光）
	for y in rows:
		var ly := _origin.y + (y + 0.5) * _cell
		draw_line(Vector2(board.position.x + 8, ly), Vector2(board.end.x - 8, ly), COL_BOARD_D, maxi(int(m * 0.003), 2))
		draw_line(Vector2(board.position.x + 8, ly - _cell * 0.32), Vector2(board.end.x - 8, ly - _cell * 0.32), COL_BOARD_L, 1)
	# 过载击打的木板裂纹（永久痕迹，画在钉子下层）
	if not _cracks.is_empty():
		var crack_w := maxf(_cell * 0.035, 2.0)
		for c: Dictionary in _cracks:
			var segs: Array = c.segs
			for pts: PackedVector2Array in segs:
				for j in pts.size() - 1:
					draw_line(pts[j], pts[j + 1], COL_CRACK, crack_w)
	# 钉子
	var nail_h_px := _cell * NAIL_H_K   # 露出 1.0 对应像素高
	var nail_w := _cell * 0.30
	for i in nails.size():
		var n: Dictionary = nails[i]
		var pos := _cell_center(i)
		if n.h <= 0.0:
			if n.bent:
				# 过载打弯：木板面压出凹陷（扁椭圆压痕，画在弯钉下层），弯钉陷在凹坑内、弯头多露一截
				var dent_c := pos + Vector2(0.0, nail_h_px * 0.28)   # 入位面线 = 凹陷中心
				var dent_r := nail_w * 0.70
				draw_set_transform_matrix(orig * Transform2D(Vector2(1.0, 0.0), Vector2(0.0, 0.42), dent_c))
				draw_circle(Vector2.ZERO, dent_r, COL_DENT)
				draw_arc(Vector2.ZERO, dent_r, 0, TAU, 24, COL_OUTLINE, maxf(_cell * 0.012, 1.2))
				draw_set_transform_matrix(orig)
				if _tex_bent != null:
					var bvis: float = maxf(n.disp_h, 0.30) * nail_h_px    # 残留可见高度（顶部多露）
					var bsrc := Rect2(0, 0, _tex_bent.get_width(), _tex_bent.get_height() * clampf(bvis / nail_h_px, 0.02, 1.0))
					# 底端沉入凹陷 0.12×nail_h_px（钉在坑里），上段露在面线上
					var bdst := Rect2(Vector2(pos.x - nail_w * 0.5, dent_c.y + nail_h_px * 0.12 - bvis), Vector2(nail_w, bvis))
					draw_texture_rect_region(_tex_bent, bdst, bsrc)
			else:
				# 已钉入：留一枚扁钉帽贴在木板面（与钉子入位线同高，防钉入动画结束后钉帽上跳）
				var cap := Rect2(pos + Vector2(-nail_w * 0.42, nail_h_px * 0.28 - _cell * 0.035), Vector2(nail_w * 0.84, _cell * 0.07))
				draw_rect(cap, IRON_COL_VAL)
				draw_rect(cap, COL_OUTLINE, false, 2.0)
			continue
		var tex: Texture2D = _tex_bent if n.bent else _tex_nail
		if tex != null:
			var vis_h: float = clampf(n.disp_h, 0.02, 1.0) * nail_h_px
			# 取贴图顶部部分（钉头在上），底边贴木板面：钉子下沉 = 可见上段缩短
			var src := Rect2(0, 0, tex.get_width(), tex.get_height() * clampf(n.disp_h, 0.02, 1.0))
			var dst := Rect2(Vector2(pos.x - nail_w * 0.5, pos.y + nail_h_px * 0.28 - vis_h), Vector2(nail_w, vis_h))
			draw_texture_rect_region(tex, dst, src)
			# 吸附钉子顶部绿色半透明高亮（罩住钉头段）
			if i == _aim and _state != State.SWING:
				var glow := Rect2(dst.position + Vector2(-4.0, -2.0), Vector2(dst.size.x + 8.0, minf(dst.size.y * 0.4, _cell * 0.16)))
				draw_rect(glow, COL_AIM, true)
			# 钉子表情：蓄力/挥锤时按力度（得意/担忧/惊恐），平时按剩余高度（平静/担忧/害怕）
			var fstate := "calm"
			if i == _aim and (_state == State.CHARGING or _state == State.SWING):
				var cr: float = _charge_t / CHARGE_MAX
				var rem_f: float = n.h
				if cr >= rem_f - NAIL_SEAT_TOL:
					fstate = "panic"   # 力度已达入位带（马上被钉进去）或会过载
				elif cr >= rem_f - _perfect_tol() * 2.0:
					fstate = "worried"   # 力度逼近
				else:
					fstate = "smug"   # 力度还差得远
			else:
				fstate = "scared" if n.h <= 0.25 else ("worried" if n.h <= 0.55 else "calm")
			var blink := fposmod(_anim_t + float(i) * 0.9, 3.4) < 0.13
			_draw_face(Vector2(pos.x, dst.position.y + dst.size.y * 0.38), nail_w * 1.05, fstate, 1.0, blink)
	# 木屑粒子
	for p: Dictionary in _particles:
		var k: float = clampf(p.t / 0.55, 0.0, 1.0)
		draw_rect(Rect2(p.pos - Vector2.ONE * p.size * 0.5, Vector2.ONE * p.size), Color(p.col.r, p.col.g, p.col.b, 1.0 - k))
	# 命中特效：金闪（完美）扩散圆环 / 红闪（过载）
	if _flash_t >= 0.0:
		var k: float = 1.0 - _flash_t / 0.45
		var rr: float = _cell * (0.2 + k * 0.9)
		var col: Color = COL_GOLD if _flash_gold else COL_ERR
		col.a = 1.0 - k
		draw_arc(_flash_pos, rr, 0, TAU, 32, col, 5.0)
		if _flash_gold:
			draw_arc(_flash_pos, rr * 0.6, 0, TAU, 24, Color(col.r, col.g, col.b, col.a * 0.7), 3.0)
	# 击打反应表情（上浮淡出）：开心=完美 / 咬牙=普通 / 晕厥=过载
	for f: Dictionary in _faces:
		var fk: float = clampf(f.t / FACE_T, 0.0, 1.0)
		var fa: float = clampf(fk / 0.4, 0.0, 1.0)
		_draw_face(f.pos, _cell * 0.34, f.state, fa, false)
	# 锤子（柄尾 pivot，旋转挥打；蓄力进完美窗口时闪光提示）
	_draw_hammer(off)
	draw_set_transform_matrix(Transform2D())   # 恢复变换


const IRON_COL_VAL := Color(0.70, 0.73, 0.76)        # 钉帽金属色


## 绘制锤子（与 hammer 游戏同款锤子素材与约定）：贴图直立、柄尾=旋转锚点，
## 悬停时头向左倾；挥锤绕柄尾逆时针抡到 -90°（锤头砸在钉子上）再回弹；
## 蓄力进入完美窗口时锤身金色脉冲 + 锤头白色扩散圈（无蓄力条的力度提示）
func _draw_hammer(shake_off: Vector2) -> void:
	if _tex_hammer == null:
		return
	var ang := _hammer_angle()
	var s := _hammer_tsz() / HAM_CANVAS
	var mod := Color.WHITE
	if _hint_t >= 0.0:
		var k: float = _hint_t / PERFECT_HINT_T   # 1=刚触发 → 0=结束
		mod = Color(1.0, 1.0 - 0.28 * k, 1.0 - 0.5 * k)   # 金色脉冲渐隐回白
	draw_set_transform(_hammer_pos + shake_off, ang, Vector2(s, s))
	draw_texture_rect(_tex_hammer, Rect2(-HAM_PIVOT, Vector2.ONE * HAM_CANVAS), false, mod)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _hint_t >= 0.0:
		var k2: float = 1.0 - _hint_t / PERFECT_HINT_T
		var head := _hammer_pos + (HAM_HEAD - HAM_PIVOT).rotated(ang) * s + shake_off
		draw_arc(head, _cell * (0.10 + k2 * 0.42), 0, TAU, 24, Color(1, 1, 1, (1.0 - k2) * 0.85), 4.0)
		draw_arc(head, _cell * (0.06 + k2 * 0.28), 0, TAU, 20, Color(1.0, 0.9, 0.4, (1.0 - k2) * 0.6), 2.5)


## ===== 反馈特效 =====

## 木屑飞溅粒子：从钉子位置向上随机喷出，重力下落（木色+白+金属屑混色提升可见度）
func _spawn_chips(pos: Vector2, cnt: int) -> void:
	var cols: Array = [COL_CHIP, COL_CHIP_D, Color(0.96, 0.96, 0.94), IRON_COL_VAL]
	for i in cnt:
		var vel := Vector2(randf_range(-1.0, 1.0) * _cell * 2.2, randf_range(-2.6, -1.0) * _cell)
		_particles.append({
			"pos": pos + Vector2(randf_range(-6, 6), randf_range(-8, 0)),
			"vel": vel,
			"t": 0.0,
			"col": cols[randi() % cols.size()],
			"size": randf_range(_cell * 0.05, _cell * 0.10),
		})


## 过载击打：钉子入位点的木板面生成永久放射状裂纹（随机锯齿折线，画在钉子下层）
func _spawn_cracks(pos: Vector2) -> void:
	var surface := Vector2(pos.x, pos.y + _cell * NAIL_H_K * 0.28)   # 钉子入位的木板面线
	var nail_w := _cell * 0.30
	var segs: Array = []
	var count := randi_range(3, 5)
	for k in count:
		# 裂纹朝下半圆散开（木板面以下才是木头），锯齿折线向外延伸
		var t := float(k) / maxf(float(count - 1), 1.0)
		var dir := Vector2.from_angle(lerpf(0.08 * PI, 0.92 * PI, t) + randf_range(-0.25, 0.25))
		var cur := surface + dir * nail_w * 0.6
		var pts := PackedVector2Array([cur])
		var steps := randi_range(2, 3)
		var seg_len := randf_range(_cell * 0.22, _cell * 0.5) / float(steps)
		for s in steps:
			cur += dir.rotated(randf_range(-0.5, 0.5)) * seg_len
			pts.append(cur)
		segs.append(pts)
	_cracks.append({"segs": segs})
	if _cracks.size() > CRACK_MAX:
		_cracks.pop_front()
	queue_redraw()


## 击打反应表情：从钉头大致位置（入位面上方半段）上浮淡出（happy=完美 / grit=普通 / ko=过载）
func _spawn_face(pos: Vector2, state: String) -> void:
	_faces.append({
		"pos": Vector2(pos.x, pos.y + _cell * NAIL_H_K * (0.28 - 0.45)),
		"state": state,
		"t": FACE_T,
	})


## 钉子卡通表情：夸张变形的眼睛+嘴巴按状态组合，size 为脸宽（画在钉身段上/上浮气泡）
## 状态：calm 平静 / smug 得意 / worried 担忧 / scared 害怕 / panic 惊恐 / happy 开心 / grit 咬牙 / ko 晕厥
func _draw_face(c: Vector2, size: float, state: String, alpha: float, blink: bool) -> void:
	var col := Color(COL_FACE.r, COL_FACE.g, COL_FACE.b, alpha)
	var wht := Color(1.0, 1.0, 1.0, alpha)
	var lw := maxf(size * 0.06, 1.5)
	var ex := size * 0.30    # 眼距
	var ey := -size * 0.16   # 眼高度
	var my := size * 0.30    # 嘴高度
	var er := size * 0.12    # 基础眼径
	for sx in [-1.0, 1.0]:
		var e := c + Vector2(sx * ex, ey)
		match state:
			"calm":
				if blink:
					draw_line(e + Vector2(-er, 0), e + Vector2(er, 0), col, lw)
				else:
					draw_circle(e, er, col)
			"smug":
				draw_arc(e, er, PI + 0.35, TAU - 0.35, 10, col, lw)   # ^ 形得意眯眼
			"happy":
				draw_arc(e, er * 1.2, PI + 0.4, TAU - 0.4, 10, col, lw)
			"worried":
				draw_circle(e, er, wht)
				draw_arc(e, er, 0, TAU, 12, col, maxf(size * 0.04, 1.2))
				draw_circle(e + Vector2(0, er * 0.3), er * 0.45, col)   # 瞳孔下移=不安
			"scared":
				var wr := er * 1.6
				draw_circle(e, wr, wht)
				draw_arc(e, wr, 0, TAU, 14, col, maxf(size * 0.045, 1.2))
				draw_circle(e, wr * 0.34, col)
			"panic":
				var pr := er * 2.1
				draw_circle(e, pr, wht)
				draw_arc(e, pr, 0, TAU, 16, col, lw)
				draw_circle(e + Vector2(0, pr * 0.25), pr * 0.32, col)
			"grit":
				# >< 挤紧的眼
				draw_line(e + Vector2(-er, -er * 0.8), e + Vector2(er * 0.7, 0), col, lw)
				draw_line(e + Vector2(-er, er * 0.8), e + Vector2(er * 0.7, 0), col, lw)
			"ko":
				# X X 晕厥眼
				var kr := er * 1.1
				draw_line(e + Vector2(-kr, -kr), e + Vector2(kr, kr), col, lw)
				draw_line(e + Vector2(-kr, kr), e + Vector2(kr, -kr), col, lw)
	# 嘴
	var m := c + Vector2(0, my)
	var mw := size * 0.32
	match state:
		"calm":
			draw_line(m + Vector2(-mw * 0.5, 0), m + Vector2(mw * 0.5, 0), col, maxf(size * 0.05, 1.5))
		"smug":
			draw_arc(m + Vector2(0, -mw * 0.4), mw * 0.7, 0.5, PI - 0.5, 12, col, maxf(size * 0.05, 1.5))   # 微笑
		"worried":
			draw_polyline(PackedVector2Array([m + Vector2(-mw, 0), m + Vector2(-mw * 0.33, mw * 0.3), m + Vector2(mw * 0.33, -mw * 0.3), m + Vector2(mw, 0)]), col, maxf(size * 0.05, 1.5))   # 波浪嘴
		"scared":
			draw_circle(m, size * 0.09, col)   # 小 o 嘴
		"panic":
			draw_circle(m, size * 0.15, col)   # 大叫的 o 嘴
		"happy":
			draw_arc(m + Vector2(0, -size * 0.08), size * 0.28, 0.4, PI - 0.4, 14, col, maxf(size * 0.07, 2.0))   # 大笑
		"grit":
			var gr := Rect2(m + Vector2(-mw, -size * 0.07), Vector2(mw * 2.0, size * 0.14))
			draw_rect(gr, col)
			draw_line(m + Vector2(-mw * 0.34, -size * 0.07), m + Vector2(-mw * 0.34, size * 0.07), wht, 1.2)
			draw_line(m + Vector2(mw * 0.34, -size * 0.07), m + Vector2(mw * 0.34, size * 0.07), wht, 1.2)
		"ko":
			draw_polyline(PackedVector2Array([m + Vector2(-mw, 0), m + Vector2(-mw * 0.5, -mw * 0.45), m + Vector2(0, 0), m + Vector2(mw * 0.5, -mw * 0.45), m + Vector2(mw, 0)]), col, maxf(size * 0.06, 1.5))   # 晕厥波浪嘴


## 飘字：上浮淡出后自毁
func _spawn_popup(text: String, col: Color, pos: Vector2) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * 0.04))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.42, m * 0.07)
	lb.position = pos - lb.size * 0.5
	lb.position.x = clampf(lb.position.x, 8.0, vp.x - lb.size.x - 8.0)
	lb.position.y = maxf(lb.position.y, TOP_H + 8.0)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.06, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


func _physics_process(delta: float) -> void:
	# 粒子物理：重力下落（帧率无关步进，与渲染分离）
	if _particles.is_empty():
		return
	var arr: Array = []
	for p: Dictionary in _particles:
		p.t += delta
		if p.t < 0.55:
			p.vel.y += _cell * 9.0 * delta
			p.pos += p.vel * delta
			arr.append(p)
	_particles = arr


## ===== 重开 / 排行榜 / 音量 / BGM =====

func _restart() -> void:
	hud.commit_score()
	level = 1
	score = 0
	_gen_level()
	_sync_bgm()


func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), -1, -1)


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


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


## 右上角按钮排：✕（tscn 已有）+ 排行榜 + R 重开 + BGM + 音量
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()   # tscn 节点迁入容器
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


## ===== 音效 =====

func _init_sfx() -> void:
	var files := {"hit": "hit.wav", "perfect": "perfect.wav", "miss": "miss.wav"}
	for sname: String in files:
		for base in ["res://games/nail_hammer/assets/sfx/", "res://assets/sfx/"]:
			var path: String = base + files[sname]
			if ResourceLoader.exists(path):
				_sfx_streams[sname] = load(path)
				break
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				_sfx_streams[sname] = AudioStreamWAV.load_from_buffer(f.get_buffer(f.get_length()))
				break
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：复用铁锤打害虫 BGM（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/nail_hammer/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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
	if not _sfx_streams.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


## 贴图加载：pck 内 png 未走导入流程，字节解码（双路径兼容）
func _load_textures() -> void:
	for entry: Array in [["nails/nail_straight.png", "nail"], ["nails/nail_bent.png", "bent"], ["hammer_idle.png", "hammer"]]:
		for base in ["res://games/nail_hammer/assets/", "res://assets/"]:
			var path: String = base + entry[0]
			if ResourceLoader.exists(path):
				_set_tex(entry[1], load(path))
				break
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				var img := Image.new()
				if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
					_set_tex(entry[1], ImageTexture.create_from_image(img))
				break


func _set_tex(key: String, tex: Texture2D) -> void:
	match key:
		"nail":
			_tex_nail = tex
		"bent":
			_tex_bent = tex
		"hammer":
			_tex_hammer = tex
