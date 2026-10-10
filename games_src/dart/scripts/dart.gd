extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 桌面飞镖：瞄准晃动 + 精力专注 + 抛物线飞行 + 标准 20 分区镖盘计分 + 301/501/701 减分制 + 风（第 3 镖起）
## 玩法：鼠标控制十字准星（隐藏系统指针），按住左键集中精力（晃动 3s 内收敛到最小，精力上限 6s 自动出手），
## 松开发射；命中分区按倍数扣减剩余分，刚好 0 获胜（记录最少用镖数），低于 0 该次无效不计分

enum State { AIM, FLY, REST, WON }

const GameHud := preload("res://scripts/game_hud.gd")
const DartSprite := preload("res://scripts/dart_sprite.gd")
const HitFx := preload("res://scripts/hit_fx.gd")
const OverlayFx := preload("res://scripts/overlay_fx.gd")

# ===== 镖盘几何（对 dartboard.png 实测标定：以双倍环外缘 = 1.0 归一化）=====
const RING_BULL50 := 0.045    # 内中心圆 50 分（红心）
const RING_BULL25 := 0.105    # 外中心圆 25 分
const RING_TRIPLE_IN := 0.557 # 三倍环内缘
const RING_TRIPLE_OUT := 0.629# 三倍环外缘
const RING_DOUBLE_IN := 0.913 # 双倍环内缘
const RING_DOUBLE_OUT := 1.0  # 双倍环外缘（计分半径基准）
const IMG_R_TO_SCORE := 0.8466   # 图像半径 → 计分归一化换算（双倍环外缘实测在 0.8466 图像半径处）
const RING_BOARD_EDGE := 1.1812  # 镖盘图外缘（黑数字环），钉靶但不得分
const SEGMENTS := [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]  # 顶20起顺时针

# ===== 玩法常量 =====
const FOCUS_TIME := 3.0          # 按住至晃动收敛到最小的时长（s）
const STAMINA_MAX := 6.0         # 每镖精力上限（s），耗尽自动出手
const FLIGHT_T := 0.55           # 飞行时长（s）
const REST_T := 0.55             # 两镖间隔（s）
const STUCK_MAX := 2             # 靶面最多同时显示飞镖数（新镖钉上时移除最旧）
const WIND_FROM_DART := 5        # 第 N 镖起出现风
const WIND_SPEED_MIN := 1.0      # 风速下限（显示单位）
const WIND_SPEED_MAX := 5.0      # 风速上限（显示单位）
const STUCK_SHAKE := [0.10, -0.07, 0.04, -0.02, 0.0]  # 钉靶颤动角偏移序列（rad，模拟扎进靶面）
const STUCK_SHAKE_STEP := 0.03   # 每段颤动时长（s）

# ===== 尺寸与布局（min(屏宽,屏高) 为基准，改这里全局调大小）=====
const BOARD_R_RATIO := 0.222       # 靶盘计分半径 = m × 此值（0.36 缩小 70% 即剩 30%；若想"缩到 70%"改 0.252）
const BOARD_POS_RATIO := Vector2(0.45, 0.42)
const CROSSHAIR_RATIO := 0.062     # 准星显示宽 = m × 此值
const HAND_LEN_RATIO := 0.16       # 手持镖长 = m × 此值
const FLIGHT_SHRINK := 0.5         # 丢出后逐渐缩小到此比例（飞行终末/钉靶尺寸 = 手持镖长 × 此值，可配置）
const DART_HOME_RATIO := Vector2(0.68, 0.56)  # 手持镖锚点 / (屏宽, 屏高)：固定屏幕右下角，可配置
const GAP_FOCUS_RATIO := 0.38      # 专注蓄力后拉距离 = 镖长 × 此值
const SWAY_MAX_RATIO := 0.045      # 未专注晃幅 = m × 此值
const SWAY_MIN_RATIO := 0.005      # 专注后晃幅
const ARC_RATIO := 0.15            # 抛物线拱高 = m × 此值
const WIND_DRIFT_RATIO := 0.012    # 每 1 风速满程漂移 = m × 此值（8 风速 ≈ 9.6% m）
const SCORE_FONT_RATIO := 0.035
const POPUP_FONT_RATIO := 0.06
const POPUP_TIME := 0.8
const POPUP_RISE_RATIO := 0.08

var hud: RefCounted

@onready var _board: Sprite2D = $Board
@onready var _stuck_root: Node2D = $StuckRoot
@onready var _flight_dart: Node2D = $FlightDart
@onready var _hand_dart: Node2D = $HandDart
@onready var _crosshair: Sprite2D = $Crosshair
@onready var _scoreboard: Label = $HudBar/ScoreBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.AIM
var target_score := 301
var remaining := 301
var darts_used := 0

var _best := 0                    # 该目标分最少用镖数（0 = 无记录）
var _stamina := 1.0               # 精力（1→0）
var _focus_t := 0.0               # 本次按住时长
var _focusing := false
var _sway_t := 0.0                # 晃动相位时钟
var _sway_off := Vector2.ZERO
var _aim_base := Vector2.ZERO     # 准星基准点（鼠标位置）
var _hand_len := 120.0
var _stuck_len := 84.0
var _dart_home := Vector2(800.0, 900.0)   # 手持镖固定锚点（右下角，_layout 更新）
var _board_r := 300.0             # 靶盘计分半径（px）
var _gap := 0.0                   # 蓄力后拉距离
# 飞行
var _fly_t := 0.0
var _fly_from := Vector2.ZERO
var _fly_to := Vector2.ZERO
var _fly_ctrl := Vector2.ZERO     # 贝塞尔控制点（拱顶）
var _wind_acc := Vector2.ZERO     # 风漂移累计
var _wind_v_px := Vector2.ZERO    # 风漂移速度（px/s）
var _prev_fly_pos := Vector2.ZERO
var _rest_t := 0.0
# 风
var _wind_active := false         # 当前镖受风影响
var _wind_visible := false        # 风向标显示
var _wind_angle := 0.0            # 风向（屏幕坐标弧度，风吹向的方向）
var _wind_speed := 0.0
var _wind_tex: Texture2D          # 风向标贴图（箭头尖朝上）+ 黑/白描边两层
var _wind_tex_white: Texture2D
var _wind_tex_black: Texture2D
# 钉靶
var _stuck: Array = []
# 音效
const BGM_DB := -35.0    # BGM 音量（dB）
const SFX_DB := -4.0    # 音效全局音量偏移（默认 0dB 过响，统一下移）
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
# UI
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button               # 排行榜按钮
var _hbox: HBoxContainer
var _hover_zone: Control         # 按钮区放大热区（透明，接近按钮排即切换指针并暂停）
var _panel: PanelContainer
var _ui_hover := false            # 鼠标悬停右上角按钮区（进入暂停游戏、显示系统指针）
var _overlay: Node2D   # 瞄准辅助层（风预测线 + 专注金环，最顶层）


func start() -> void:
	hud = GameHud.new("dart")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_overlay = OverlayFx.new()   # 瞄准辅助层挂最顶层（风预测线/专注金环盖在盘与准星上）
	add_child(_overlay)
	_load_textures()
	_init_sfx()
	_layout()
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)   # 隐藏系统指针，十字准星即光标
	new_game(301)


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if _bgm != null:
		_bgm.stop()
	print("[dart] stop, target=%d remaining=%d darts=%d" % [target_score, remaining, darts_used])


func _exit_tree() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _notification(what: int) -> void:
	# 排行榜弹出会暂停树，暂停期 _process 停跑、_sync_mouse 失效，指针会冻结在隐藏态
	# （胜利 1.5s 后自动弹榜时未悬停按钮区，面板上无光标可点）——暂停即显示系统指针，
	# 恢复后按当前状态切回准星/指针模式（同 desk_wreck 方案）
	if what == NOTIFICATION_PAUSED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif what == NOTIFICATION_UNPAUSED:
		_sync_mouse()


func _exit_button_pressed() -> void:
	exit_requested.emit()


func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_board_r = m * BOARD_R_RATIO
	_hand_len = m * HAND_LEN_RATIO
	_stuck_len = _hand_len * FLIGHT_SHRINK
	_dart_home = vp * DART_HOME_RATIO
	if _board.texture != null:
		_board.position = vp * BOARD_POS_RATIO
		_board.scale = Vector2.ONE * (2.0 * _board_r / (_board.texture.get_width() * IMG_R_TO_SCORE))
	if _crosshair.texture != null:
		_crosshair.scale = Vector2.ONE * (m * CROSSHAIR_RATIO / _crosshair.texture.get_width())
	_scoreboard.custom_minimum_size = Vector2(420.0, m * SCORE_FONT_RATIO * 1.9)   # 单行背景板
	_scoreboard.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scoreboard.add_theme_font_size_override("font_size", int(m * SCORE_FONT_RATIO))
	# 信息板 HudBar 整体水平居中（代码定位，Node2D 父下锚点不可靠）
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	# 右上角按钮排：容器定位右上（等间距/尺寸/对齐在 _setup_buttons 统一设定）
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	if _hover_zone != null:   # 热区随按钮排：四周放 28u、下方 44u（从游戏区接近的来向多留）
		var pad: float = minf(vp.x, vp.y) * (28.0 / 1080.0)
		_hover_zone.position = _hbox.position - Vector2(pad, pad)
		_hover_zone.size = _hbox.size + Vector2(pad * 2.0, pad + minf(vp.x, vp.y) * (44.0 / 1080.0))


## 贴图加载：pck 内原始 png 无导入资源，按字节解码（开发期与打包双路径）
func _load_textures() -> void:
	_board.texture = _load_png(["res://games/dart/assets/dartboard.png", "res://assets/dartboard.png"])
	_crosshair.texture = _load_png(["res://games/dart/assets/crosshair.png", "res://assets/crosshair.png"])
	_wind_tex = _load_png(["res://games/dart/assets/wind.png", "res://assets/wind.png"])
	_wind_tex_white = _load_png(["res://games/dart/assets/wind_white.png", "res://assets/wind_white.png"])
	_wind_tex_black = _load_png(["res://games/dart/assets/wind_black.png", "res://assets/wind_black.png"])


func _load_png(paths: Array) -> Texture2D:
	for p: String in paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


## 音效：mp3 字节解码 + 程序合成出手破风声
func _init_sfx() -> void:
	var files := {"hit": "hit.mp3", "win": "win.mp3", "bust": "bust.mp3"}
	for name: String in files:
		for base in ["res://games/dart/assets/sfx/", "res://assets/sfx/"]:
			var path: String = base + files[name]
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				_sfx_streams[name] = AudioStreamMP3.load_from_buffer(f.get_buffer(f.get_length()))
				break
	_sfx_streams["throw"] = _make_whoosh()
	for i in 4:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM，不影响玩法）
	for base in ["res://games/dart/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## 破风声：白噪声 + 正弦包络 + 一阶低通
func _make_whoosh() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.22)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var lp := 0.0
	for i in n:
		var t := float(i) / n
		var env := sin(t * PI)
		lp = lerpf(lp, randf() * 2.0 - 1.0, 0.12)
		bytes.encode_s16(i * 2, int(clampf(lp * env * env, -1.0, 1.0) * 26000.0))
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = rate
	st.data = bytes
	return st


func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx_streams.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


# ===== 回合管理 =====

## 新局：目标分数（301/501/701），剩余分重置，清空钉靶飞镖
func new_game(t: int) -> void:
	target_score = t
	remaining = t
	darts_used = 0
	for d in _stuck:
		d.queue_free()
	_stuck.clear()
	_set_panel_open(false)   # 关闭重开面板并恢复十字准星模式（隐藏指针）
	var cf := ConfigFile.new()
	if cf.load(hud.CFG_PATH) == OK:
		_best = int(cf.get_value("darts", "best_%d" % target_score, 0))
	_refresh_score()
	_new_dart()


## 新的一镖：精力回满、风按规则重掷（第 WIND_FROM_DART 镖起，出现风时浮字提示）
func _new_dart() -> void:
	state = State.AIM
	_stamina = 1.0
	_focus_t = 0.0
	_focusing = false
	_wind_active = darts_used >= WIND_FROM_DART - 1
	_wind_visible = _wind_active
	if _wind_active:
		_wind_angle = randf() * TAU
		_wind_speed = randf_range(WIND_SPEED_MIN, WIND_SPEED_MAX)
		_spawn_popup(hud.t("pop.wind", "Wind! %.1f m/s") % _wind_speed, Color(0.55, 0.8, 1.0), POPUP_FONT_RATIO * 0.8)
	# 移除超出上限的最旧钉靶镖：新镖入手前一刻才消失（钉靶瞬间不移除，短暂共存）
	while _stuck.size() > STUCK_MAX:
		var oldest: Node2D = _stuck.pop_front()
		if is_instance_valid(oldest):
			var parent := oldest.get_parent()
			if parent != null:
				parent.remove_child(oldest)   # 立即出树（queue_free 是帧末删除，当帧仍会绘制）
			oldest.queue_free()
	_hand_dart.visible = true
	_flight_dart.visible = false
	_flight_dart.modulate.a = 1.0   # 脱靶淡出 tween 会把 alpha 压到 0，新镖必须复位否则全程隐形


func _process(delta: float) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_sway_t += delta
	_update_aim(delta, m)
	match state:
		State.FLY:
			_step_flight(delta, m)
		State.REST:
			_rest_t -= delta
			if _rest_t <= 0.0:
				_new_dart()
	_sync_mouse()   # 指针可见性统一同步（按钮悬停/面板开 → 系统指针，否则准星模式）
	# 瞄准辅助层：风力预测线（AIM 且有风，长度=满程漂移）+ 精力圈（含专注到位金态，画在准星处）
	if _overlay != null:
		_overlay.show_wind = _wind_active and state == State.AIM
		_overlay.wind_dir = Vector2.from_angle(_wind_angle)
		_overlay.wind_len = _wind_speed * WIND_DRIFT_RATIO * m
		_overlay.show_focus = state == State.AIM and _focusing and _focus_t >= FOCUS_TIME
		_overlay.crosshair_pos = _crosshair.position
		_overlay.focus_r = m * 0.045
		_overlay.show_stamina = state == State.AIM and _focusing
		_overlay.stamina_ratio = _stamina
		_overlay.stamina_w = maxf(5.0, m * 0.011)
		_overlay.queue_redraw()
	queue_redraw()   # 根节点绘制风向标


## 瞄准：准星跟随鼠标 + 晃动（按住时 3s 内收敛），手持镖针尖指向抛物线拱顶方向（比准星高的仰角补偿）
func _update_aim(delta: float, m: float) -> void:
	var vp := get_viewport_rect().size
	_aim_base = get_global_mouse_position().clamp(Vector2.ZERO, vp)
	if _focusing and state == State.AIM:
		_focus_t += delta
		_stamina = maxf(0.0, 1.0 - _focus_t / STAMINA_MAX)
		if _stamina <= 0.0:
			_fire()
	var amp: float
	if _focusing:
		amp = lerpf(m * SWAY_MAX_RATIO, m * SWAY_MIN_RATIO, clampf(_focus_t / FOCUS_TIME, 0.0, 1.0))
	else:
		amp = m * SWAY_MAX_RATIO
	var sx := sin(_sway_t * 1.9) + 0.55 * sin(_sway_t * 3.7 + 1.3)
	var sy := cos(_sway_t * 1.5) + 0.55 * sin(_sway_t * 2.9 + 0.7)
	_sway_off = Vector2(sx, sy) * (amp / 1.55)
	_crosshair.position = _aim_base + _sway_off
	# 专注到位：准星泛金提示"此刻出手最稳"（叠加辅助层金环呼吸）
	var locked := _focusing and _focus_t >= FOCUS_TIME
	_crosshair.modulate = Color(1.0, 0.88, 0.5) if locked else Color.WHITE
	if state == State.AIM:
		# 手持镖固定在屏幕右下角不随准星移动，仅旋转；瞄准点 = 出手点与准星中点上方拱顶处
		# （抛物线仰角补偿：针头指向比准星高 ARC_RATIO×m 的抛物线高点方向，与 _fire 控制点同构）；蓄力时沿镖身反方向后拉
		var focus_k := clampf(_focus_t / FOCUS_TIME, 0.0, 1.0) if _focusing else 0.0
		_gap = _hand_len * GAP_FOCUS_RATIO * focus_k
		var aim_point := (_dart_home + _crosshair.position) * 0.5 + Vector2(0.0, -m * ARC_RATIO)
		var aim_dir := (aim_point - _dart_home).normalized()
		_hand_dart.position = _dart_home - aim_dir * _gap
		_hand_dart.rotation = aim_dir.angle()
		_hand_dart.length = _hand_len
		_hand_dart.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_toggle_panel()   # 键盘 R 与重开按钮一致：弹出/关闭目标分数面板
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _panel != null and _panel.visible:
			return
		if event.pressed and state == State.AIM:
			_focusing = true
			_focus_t = 0.0
		elif not event.pressed and _focusing and state == State.AIM:
			_fire()


## 发射：从手持镖位置沿抛物线飞向松开瞬间准星位置，风漂移在飞行中逐帧累加
func _fire() -> void:
	if state != State.AIM:
		return
	state = State.FLY
	_focusing = false
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	_fly_from = _hand_dart.position
	_fly_to = _crosshair.position
	_fly_ctrl = (_fly_from + _fly_to) * 0.5 + Vector2(0.0, -m * ARC_RATIO)
	_fly_t = 0.0
	_wind_acc = Vector2.ZERO
	if _wind_active:
		var drift := Vector2.from_angle(_wind_angle) * (_wind_speed * WIND_DRIFT_RATIO * m)
		_wind_v_px = drift / FLIGHT_T
	else:
		_wind_v_px = Vector2.ZERO
	_hand_dart.visible = false
	_flight_dart.position = _fly_from
	_flight_dart.rotation = (_fly_to - _fly_from).angle()
	_flight_dart.length = _hand_len
	_flight_dart.visible = true
	_prev_fly_pos = _fly_from
	_play_sfx("throw", -4.0)


## 飞行：二次贝塞尔抛物线 + 风漂移累加，逐渐缩小（飞离视角），针头始终朝向运动方向
func _step_flight(delta: float, m: float) -> void:
	_fly_t += delta
	var t := clampf(_fly_t / FLIGHT_T, 0.0, 1.0)
	var a := _fly_from.lerp(_fly_ctrl, t)
	var b := _fly_ctrl.lerp(_fly_to, t)
	_wind_acc += _wind_v_px * delta
	_prev_fly_pos = _flight_dart.position
	_flight_dart.position = a.lerp(b, t) + _wind_acc
	var dir := _flight_dart.position - _prev_fly_pos
	if dir.length_squared() > 0.25:
		_flight_dart.rotation = dir.angle()
	_flight_dart.length = lerpf(_hand_len, _stuck_len, t)
	_flight_dart.queue_redraw()
	if t >= 1.0:
		_resolve_hit()


## 命中结算：计分区（扣分/胜利/爆分）/ 黑环（钉靶 0 分）/ 脱靶（坠落淡出）
## 判定统一用屏幕像素：双倍环外缘屏幕半径 = _board_r（与 _layout 缩放公式一致），不经过 to_local（其返回图像像素，易混单位）
func _resolve_hit() -> void:
	darts_used += 1
	var pos := _flight_dart.position
	var rel := pos - _board.global_position   # 盘心 → 落点（屏幕像素）
	var r_norm := rel.length() / _board_r if _board_r > 0.0 else 99.0
	if r_norm <= RING_DOUBLE_OUT:
		_stick(pos)
		_score_zone(r_norm, rel, pos)
		_flight_dart.visible = false   # 钉靶镖已原地显示，立即隐藏飞行镖避免残影重合
	elif r_norm <= RING_BOARD_EDGE:
		_stick(pos)
		_flight_dart.visible = false
		_play_sfx("hit", -8.0)
		_spawn_popup(hud.t("pop.no_score", "No Score"), Color(0.75, 0.75, 0.75), 0.04)
	else:
		_play_sfx("bust")
		_spawn_popup(hud.t("pop.miss", "Miss"), Color(0.75, 0.75, 0.75), 0.04)
		_fall_out()
	if state != State.WON:   # 胜利保持 WON，不被 REST 覆盖
		state = State.REST
		_rest_t = REST_T
	_refresh_score()


## 钉靶：以入射方向 + 少量随机偏转把飞镖固定在命中点，附短促颤动（模拟扎进靶面）
func _stick(pos: Vector2) -> void:
	var d: Node2D = DartSprite.new()
	d.position = pos
	var rot := _flight_dart.rotation + randf_range(-0.12, 0.12)
	d.rotation = rot
	d.length = _stuck_len
	_stuck_root.add_child(d)
	d.queue_redraw()
	_stuck.append(d)
	# 颤动 tween 绑定镖节点自身（移除释放时自动失效）
	var tw := d.create_tween()
	for off: float in STUCK_SHAKE:
		tw.tween_property(d, "rotation", rot + off, STUCK_SHAKE_STEP)


## 分区计分：按标定环半径与顺时针分区表取分，执行 301 减分规则（rel = 盘心→落点，屏幕像素）
func _score_zone(r_norm: float, rel: Vector2, pos: Vector2) -> void:
	var ang := wrapf(rad_to_deg(rel.angle()) + 90.0, 0.0, 360.0)   # 顶 = 0°，顺时针
	var seg: int = SEGMENTS[int(wrapf(ang + 9.0, 0.0, 360.0) / 18.0)]
	var base := 0
	var mult := 1
	if r_norm <= RING_BULL50:
		base = 50
	elif r_norm <= RING_BULL25:
		base = 25
	elif r_norm <= RING_TRIPLE_IN:
		base = seg
	elif r_norm <= RING_TRIPLE_OUT:
		base = seg
		mult = 3
	elif r_norm <= RING_DOUBLE_IN:
		base = seg
	elif r_norm <= RING_DOUBLE_OUT:
		base = seg
		mult = 2
	var s := base * mult
	_spawn_hit_fx(ang, pos, base, mult)
	var new_rem: int = remaining - s
	if new_rem == 0:
		remaining = 0
		_win()
	elif new_rem < 0:
		_play_sfx("bust")
		_spawn_popup(hud.t("pop.bust", "BUST! %d") % s, Color(0.95, 0.25, 0.2), POPUP_FONT_RATIO)
	else:
		remaining = new_rem
		if base == 50:
			_play_sfx("win")          # BULL：全场欢呼
			_spawn_popup(hud.t("pop.bull", "BULL! -50"), Color(1.0, 0.85, 0.25), POPUP_FONT_RATIO)
		elif mult == 3:
			_play_sfx("win", -8.0)    # 三倍区：小欢呼
			_spawn_popup("-%d" % s, Color(1.0, 0.85, 0.25), POPUP_FONT_RATIO)
		else:
			_play_sfx("hit")
			_spawn_popup("-%d" % s, Color(0.2, 0.85, 0.3), POPUP_FONT_RATIO)


## 命中特效：扇区楔形高亮（吸附到实际分区边界，扇区全长）+ 落点扩散圈；颜色按倍数区分
func _spawn_hit_fx(ang: float, pos: Vector2, base: int, mult: int) -> void:
	var col: Color
	if base == 50:
		col = Color(0.95, 0.3, 0.25)      # BULL50 红
	elif base == 25:
		col = Color(0.3, 0.9, 0.5)        # BULL25 绿
	elif mult == 3:
		col = Color(1.0, 0.85, 0.25)      # 三倍金
	elif mult == 2:
		col = Color(0.35, 0.7, 1.0)       # 双倍蓝
	else:
		col = Color(0.4, 0.9, 0.5)        # 单倍绿
	var fx: Node2D = HitFx.new()
	fx.center = _board.global_position
	fx.pos = pos
	fx.col = col
	fx.radius = _board_r                  # 楔形外径 = 双倍环外缘（扇区全长）
	fx.inner = RING_BULL25 * _board_r     # 楔形内缘 = 25 分圈外缘
	if base <= 20:
		# 楔形吸附实际分区：与计分同式取分区号，中心 = 分区号 × 18°（勿用命中角 ± 9°，会与盘面分区线错开）
		var c := float(int(wrapf(ang + 9.0, 0.0, 360.0) / 18.0)) * 18.0
		fx.seg_a = deg_to_rad(c - 9.0) - PI / 2.0
		fx.seg_b = deg_to_rad(c + 9.0) - PI / 2.0
	else:
		fx.seg_a = 0.0   # BULL：不画扇形只画圆环
		fx.seg_b = 0.0
	add_child(fx)
	move_child(fx, _board.get_index() + 1)   # 盘之上、钉靶镖之下


## 胜利：剩余分刚好归零，记录最少用镖数（按目标分分别保存）
func _win() -> void:
	state = State.WON
	_hand_dart.visible = false
	_flight_dart.visible = false
	var used := darts_used
	if _best == 0 or used < _best:
		_best = used
		var cf := ConfigFile.new()
		cf.load(hud.CFG_PATH)
		cf.set_value("darts", "best_%d" % target_score, _best)
		cf.save(hud.CFG_PATH)
	_play_sfx("win")
	_spawn_popup(hud.t("pop.win", "You Win! %d Darts") % used, Color(1.0, 0.85, 0.25), POPUP_FONT_RATIO)
	# 1.5 秒后自动弹出纪录榜（各目标分最少镖数）；tween 绑定本节点，游戏退出时自动失效
	var tw := create_tween()
	tw.tween_interval(1.5)
	tw.tween_callback(func() -> void: _show_records(hud.t("pop.win", "You Win! %d Darts") % used))


## 各目标分最少镖数纪录行（ConfigFile darts/best_<target>）
func _records_lines() -> Array:
	var cf := ConfigFile.new()
	cf.load(hud.CFG_PATH)
	var lines: Array = []
	for t: int in [301, 501, 701]:
		var b: int = int(cf.get_value("darts", "best_%d" % t, 0))
		lines.append("%s: %s" % [hud.t("board.pts", "%d pts") % t,
				(hud.t("board.darts", "%d darts") % b) if b > 0 else "—"])
	return lines


## 纪录榜弹窗（重开用右上角循环箭头按钮打开目标分面板）
func _show_records(title: String) -> void:
	hud.show_leaderboard(self, title, -1, -1, _records_lines())


## 脱靶坠落：顺势下坠并淡出
func _fall_out() -> void:
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_flight_dart, "position:y", _flight_dart.position.y + 260.0, 0.5) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(_flight_dart, "modulate:a", 0.0, 0.45)
	tw.chain().tween_callback(func() -> void: _flight_dart.visible = false)


func _refresh_score() -> void:
	_scoreboard.text = "%d" % remaining


## 飘字：上浮淡出（文本/颜色/字号比例由调用方传入，可多个并发）
func _spawn_popup(text: String, col: Color, font_ratio: float) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * font_ratio))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.5, m * font_ratio * 1.5)
	lb.position = Vector2(vp.x * 0.5 - lb.size.x * 0.5, vp.y * 0.28)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * POPUP_RISE_RATIO, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


# ===== 按钮 / 目标分数面板 =====

func _setup_buttons() -> void:
	# 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + 音量循环
	# 容器统一等间距（8px）、按钮固定 56×56 底对齐、图标统一 32px 居中 —— 保证水平/垂直全对齐
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中按钮仍可响应（鼠标悬停暂停游戏）
	# 放大透明热区（ALWAYS）：准星晃动下鼠标实际位置常在按钮排矩形外，直接挂 HBox 的
	# enter/exited 识别率很低（准星指到 ≠ 鼠标本体在按钮上）——热区比按钮排大一圈，
	# 接近即切指针并暂停；先添加保持在 _hbox 下层，按钮点击命中优先
	_hover_zone = Control.new()
	_hover_zone.name = "TopButtonsHotZone"
	_hover_zone.process_mode = Node.PROCESS_MODE_ALWAYS
	_hover_zone.mouse_filter = Control.MOUSE_FILTER_STOP
	_hover_zone.mouse_entered.connect(_on_ui_hover.bind(true))
	_hover_zone.mouse_exited.connect(_on_ui_hover.bind(false))
	add_child(_hover_zone)
	add_child(_hbox)
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
	_restart_btn.pressed.connect(_toggle_panel)
	_bgm_btn.pressed.connect(_on_bgm)
	_volume_btn.pressed.connect(_on_volume)
	_build_panel()


## 鼠标进入/离开右上角按钮区：进入时暂停游戏并显示系统指针（准星机制下难以点按钮），
## 离开时恢复；排行榜面板开着时保持其暂停（面板自带恢复逻辑）
func _on_ui_hover(entered: bool) -> void:
	_ui_hover = entered
	if entered:
		get_tree().paused = true
	else:
		if get_node_or_null("LeaderboardPanel") == null:
			get_tree().paused = false


## 每帧统一同步指针可见性：按钮悬停 / 热区 / 目标分面板 / 排行榜任一有效即显示，否则隐藏（准星模式）
func _sync_mouse() -> void:
	var in_zone := _hover_zone != null \
			and _hover_zone.get_global_rect().has_point(get_global_mouse_position())
	var want_vis := _ui_hover or in_zone or (_panel != null and _panel.visible) \
			or get_node_or_null("LeaderboardPanel") != null
	if (Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE) != want_vis:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if want_vis else Input.MOUSE_MODE_HIDDEN)


## 排行榜（各目标分最少镖数纪录表，手动查看）
func _on_lb() -> void:
	_show_records(hud.t("board.title", "Records"))


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


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


## 弹窗开关：打开时恢复系统指针便于点击，关闭时切回十字准星模式（隐藏指针）
func _toggle_panel() -> void:
	_set_panel_open(not _panel.visible)


func _set_panel_open(open: bool) -> void:
	_panel.visible = open
	if open:
		var vp := get_viewport_rect().size
		_panel.position = vp * 0.5 - _panel.size * 0.5
	# 指针可见性由 _process 末尾 _sync_mouse 统一管理


func _on_target(t: int) -> void:
	new_game(t)


## 目标分数选择面板（点 R 弹出，301/501/701 任选其一重开）
func _build_panel() -> void:
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.12, 0.92)
	sb.border_color = Color.BLACK
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 16.0
	sb.content_margin_bottom = 20.0
	_panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = hud.t("ui.target_score", "Target Score")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 6)
	title.add_theme_font_size_override("font_size", 30)
	vb.add_child(title)
	for t in [301, 501, 701]:
		var b := GameHud.make_button(str(t))
		b.custom_minimum_size = Vector2(160, 52)
		b.add_theme_font_size_override("font_size", 30)
		b.pressed.connect(_on_target.bind(t))
		vb.add_child(b)
	_panel.add_child(vb)
	add_child(_panel)
	_panel.reset_size()
	_panel.size = _panel.get_combined_minimum_size()
	_panel.visible = false


# ===== 根节点自绘：风向标（有风时；精力圈在独立辅助层绘制）=====

func _draw() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	# 风向标：右侧居中，Wind 箭头（尖朝上）旋转指向风吹去的方向；黑/白描边双层衬底保证任何桌面背景可见
	if _wind_visible and _wind_tex != null:
		var center := Vector2(vp.x - m * 0.11, vp.y * 0.5)
		var s := m * 0.15
		var half := s * 0.5
		var rot: float = _wind_angle + PI / 2.0
		draw_set_transform_matrix(Transform2D(rot, center))
		if _wind_tex_black != null:
			var eb := s * 0.26
			draw_texture_rect(_wind_tex_black, Rect2(-half - eb * 0.5, -half - eb * 0.5, s + eb, s + eb), false)
		if _wind_tex_white != null:
			var ew := s * 0.13
			draw_texture_rect(_wind_tex_white, Rect2(-half - ew * 0.5, -half - ew * 0.5, s + ew, s + ew), false)
		draw_texture_rect(_wind_tex, Rect2(-half, -half, s, s), false)
		draw_set_transform_matrix(Transform2D())
		var txt: String = hud.t("hud.wind_speed", "%.1f m/s") % _wind_speed
		var font := ThemeDB.fallback_font
		var fs := int(m * 0.030)
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		var tpos := Vector2(center.x - tw * 0.5, center.y + half + fs * 1.5)
		draw_string(font, tpos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		draw_string_outline(font, tpos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color.BLACK)
