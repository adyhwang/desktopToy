extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 桌面投篮：交互状态机 + 抛物线 + 进球判定 + 计分（M3）+ 残影/透视缩放/筐晃动/网飘动/动态难度（M4）
## 玩法：手跟随鼠标，按住举球（0.2s），松开甩投（鼠标水平速度决定水平初速）
## 抛物线：固定飞行时长 T，重力按屏高归一化，vy0 反解"球于 T 时回到筐口平面下落"

enum State { IDLE, CHARGING, FLYING, RESULT }

const GameHud := preload("res://scripts/game_hud.gd")

const FLIGHT_T := 1.5          # 固定飞行时长（s）
const GRAVITY_RATIO := 2.2     # g = 屏高 × 此系数 / T²
const CHARGE_TIME := 0.2       # 抬手举球时长
const HAND_FOLLOW_T := 0.0     # 手水平跟随残差系数（权重 = 1 − pow(此值, delta)；0 = 即时跟随无延迟，要平滑手感可用 0.0002）
const VX_GAIN := 1.45          # 鼠标甩动速度 → 水平初速系数
const VX_MAX_RATIO := 0.15     # 水平最大位移占屏宽比例（/T）
const SCORE_REST := 0.1        # 进球后 RESULT 停留时长（s）
const MISS_REST := 0.5         # 未进（落地弹尽/出屏/超时）后 RESULT 停留时长（s）
const SCALE_FAR := 0.8         # 透视缩放下限
const TRAIL_STEP := 0.05       # 残影采样间隔
const TRAIL_MAX := 15          # 残影最大点数
const DIFF_SCORE := 2          # 动态难度触发分
const DIFF_STEP := 5           # 每 N 分速度 +1
const SPEED_LEVEL_MAX := 100
const HOOP_RANGE := 0.3        # 难度移动区间：中心 ± 此比例 × 屏宽
const HOOP_SPEED := 0.015      # 像素速度 = level × 屏宽 × 此系数
const GOAL_MARGIN := 0.55      # 完全进入判定：|dx| < R − r×此系数 才得分
const RIM_REST := 0.55         # 打铁反弹弹性系数
const RIM_TUBE := 0.16         # 筐圈管半径 = r × 此系数
const SFX_POOL := 4            # 音效播放器池
const BGM_DB := 3.0           # BGM 音量（dB）
const SFX_DB := -3.0           # 音效全局音量偏移（默认 0dB 过响，统一下移）
const GROUND_Y_RATIO := 0.5    # 地面 y / 屏高（未进球落到屏幕中央水平线反弹）
const GROUND_REST := 0.55      # 地面反弹弹性
const GROUND_FRICTION := 0.7   # 每次落地反弹的水平速度衰减
const BOUNCE_STOP := 0.18      # 反弹速度 < g × 此值 时弹尽，进入下一轮

# ===== 尺寸与布局配置（唯一入口：球径为基准，其余全部跟随；改这里即可全局调大小）=====
const BALL_R_RATIO := 0.048        # 球半径 = min(屏宽, 屏高) × 此值
const HOOP_HALF_BALLS := 1.35      # 筐口判定半宽 = 球半径 × 此值（筐贴图随之缩放）
const NET_LEN_BALLS := 3.05        # 网长 = 球半径 × 此值（兜底绘制 + 出网判定；按新素材网底实测 3.06 校准）
const HANDS_TEX_BALLS := 3.0       # 手贴图渲染宽 = 球半径 × 此值
const HAND_GRIP_BALLS := -0.25      # 手指尖交汇点在球心下方 = 球半径 × 此值（越小手越"抓"住球）
const HAND_LOW_RATIO := 0.80       # 手低位 y / 屏高
const HAND_HIGH_RATIO := 0.68      # 手举起 y / 屏高
const HOOP_POS_RATIO := Vector2(0.5, 0.28)  # 筐口平面锚点 / (屏宽, 屏高)
const SCORE_FONT_RATIO := 0.035    # 记分牌字号 = min(屏宽, 屏高) × 此值
const POPUP_FONT_RATIO := 0.06     # 得分飘字字号 = min(屏宽, 屏高) × 此值
const POPUP_TIME := 0.8            # 飘字动画时长（s）
const POPUP_RISE_RATIO := 0.08     # 飘字上浮距离 = min(屏宽, 屏高) × 此值
const COMBO_MIN := 3               # 连击飘字触发次数（连续进球 ≥ 此值显示 combo×N）
const COMBO_FONT_RATIO := 0.075    # combo 飘字字号 = min(屏宽, 屏高) × 此值
const FIRE_THRESHOLD := 5          # 连中此球数开启彩虹拖影

var hud: RefCounted                # 通用 HUD（最高分/连击/音量）

@onready var _hoop_back: Node2D = $HoopBack
@onready var _hoop_front: Node2D = $HoopFront
@onready var _hands: Node2D = $Hands
@onready var _ball: Node2D = $Ball
@onready var _trail: Line2D = $Trail
@onready var _scoreboard: Label = $HudBar/ScoreBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.IDLE
var score := 0

var _ball_r := 24.0
var _g := 0.0
var _flight_t := 0.0
var _rest_t := 0.0
var _ball_v := Vector2.ZERO    # 飞行速度 (vx, vy)
var _prev_ball_y := 0.0
var _mouse_vx := 0.0           # 低通平滑后的鼠标水平速度
var _prev_mouse_x := 0.0
var _charge_tween: Tween
var _fade_tween: Tween
var _trail_t := 0.0
# 动态难度
var _moving := false
var _speed_level := 1
var _hoop_dir := 1.0
var _low_y := 0.0             # 手低位 y（屏高比例）
var _high_y := 0.0            # 手举起 y
var _scored := false          # 本次飞行已得分（球穿网中）
var _net_phase := 0           # 进球引导轨迹阶段：1=汇入网心 2=垂直下坠
var _rim_hit := false         # 本次飞行已打铁（只弹一次）
var _board_hit := false       # 本次飞行已打板（只弹一次）
var _goal_fading := false     # 进球球已出网、开始淡出
var _sfx_streams := {}        # 音效名 → AudioStream
var _sfx_players: Array = []
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _bgm: AudioStreamPlayer
var _lb_btn: Button               # 排行榜按钮
var _hbox: HBoxContainer          # 右上角按钮排容器（等间距/底对齐）


func start() -> void:
	hud = GameHud.new("basketball")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()   # 先建按钮再布局（_layout 会设置按钮位置，null 会报错中断）
	_layout()
	_init_sfx()
	_refresh_score()
	_update_trail()
	_enter_idle()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，分数入排行榜
	print("[basketball] stop, final score=%d" % score)


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
	hud.show_leaderboard(self, hud.t("lb.title", "Top 10"), -1, -1)


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


## 重开：上一局分数入排行榜；分数与连击归零、新球回手（排行榜保留）
func _restart() -> void:
	hud.commit_score()
	score = 0
	hud.reset_run()
	_sync_bgm()
	_refresh_score()
	_update_trail()
	_enter_idle()


## 记分牌刷新：分数；负分红字
func _refresh_score() -> void:
	_scoreboard.text = "%d" % score
	_scoreboard.add_theme_color_override("font_color", Color(0.95, 0.25, 0.2) if score < 0 else Color.WHITE)


## 得分统一入口：计分 + 最高分 + 连击（进球 success / miss fail）+ 着火状态刷新
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
	_update_trail()


## 音效初始化：pck 内 mp3 走字节解码，编辑器预览走导入资源（双路径）
func _init_sfx() -> void:
	var files := {"board_hit": "board_hit.mp3", "rim_hit": "rim_hit.mp3", "score": "score.mp3",
			"cheer": "crowd_cheer.mp3", "aww": "crowd_aww.mp3"}
	for name: String in files:
		for base in ["res://games/basketball/assets/sfx/", "res://assets/sfx/"]:
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
	for base in ["res://games/basketball/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_ball_r = m * BALL_R_RATIO
	_g = GRAVITY_RATIO * vp.y / (FLIGHT_T * FLIGHT_T)
	# 篮筐双层：front=筐圈+网（原点=筐口平面，判定线），back=背板（原点=背板底缘，抬升布置在筐口上方）
	_hoop_front.tex_paths = ["res://games/basketball/assets/hoop_front.png", "res://assets/hoop_front.png"]
	_hoop_back.tex_paths = ["res://games/basketball/assets/hoop_back.png", "res://assets/hoop_back.png"]
	_hoop_back.is_back = true
	var rim_pos := Vector2(vp.x * HOOP_POS_RATIO.x, vp.y * HOOP_POS_RATIO.y)
	_hoop_front.base_position = rim_pos
	_hoop_back.base_position = rim_pos + Vector2(0.0, -_ball_r * HOOP_HALF_BALLS * 2.0 * _hoop_back.BACK_GAP_RATIO)
	_hoop_front.half_width = _ball_r * HOOP_HALF_BALLS
	_hoop_back.half_width = _ball_r * HOOP_HALF_BALLS
	_hoop_front.net_len = _ball_r * NET_LEN_BALLS
	_hoop_front.apply_base()
	_hoop_back.apply_base()
	_hoop_front.queue_redraw()
	_hoop_back.queue_redraw()
	_trail.z_index = 1   # 残影与球同层（筐前景之上）
	_hands.z_index = 2   # 手永远在球之上（球待机/空中 z=1，进球入网 z=0）
	_low_y = vp.y * HAND_LOW_RATIO
	_high_y = vp.y * HAND_HIGH_RATIO
	_hands.position = Vector2(_hands.position.x, _low_y)
	_hands.ball_radius = _ball_r
	_hands.tex_scale = HANDS_TEX_BALLS
	_hands.grip_offset = _ball_r * HAND_GRIP_BALLS
	_hands.queue_redraw()
	_ball.radius = _ball_r
	_ball.queue_redraw()
	_trail.width = _ball_r * 0.8
	_update_trail()
	_scoreboard.custom_minimum_size = Vector2(380.0, m * SCORE_FONT_RATIO * 1.9)   # 单行背景板
	_scoreboard.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scoreboard.add_theme_font_size_override("font_size", int(m * SCORE_FONT_RATIO))
	# 信息板 HudBar 整体水平居中（代码定位，Node2D 父下锚点不可靠）
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	# 右上角按钮排：容器定位右上（等间距/尺寸/对齐在 _setup_buttons 统一设定）
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


## 拖影特效：连中 FIRE_THRESHOLD 球后残影换彩虹渐变（老点透明渐隐）；断连后恢复普通橙色
func _update_trail() -> void:
	if hud == null:
		return
	var grad := Gradient.new()
	if hud.combo >= FIRE_THRESHOLD:
		grad.offsets = PackedFloat32Array([0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
		grad.colors = PackedColorArray([
				Color(1.0, 0.2, 0.2, 0.0), Color(1.0, 0.55, 0.1, 0.35),
				Color(1.0, 0.9, 0.2, 0.55), Color(0.2, 0.9, 0.3, 0.7),
				Color(0.2, 0.5, 1.0, 0.85), Color(0.7, 0.3, 1.0, 0.9)])
	else:
		grad.set_color(0, Color(0.90, 0.47, 0.13, 0.0))
		grad.set_color(1, Color(0.90, 0.47, 0.13, 0.45))
	_trail.gradient = grad


func _enter_idle() -> void:
	state = State.IDLE
	_scored = false
	_net_phase = 0
	_rim_hit = false
	_board_hit = false
	_goal_fading = false
	if _fade_tween != null:       # 关键：杀掉上一局的残留淡出 tween，防止新球被压暗"消失"
		_fade_tween.kill()
	_ball.z_index = 1            # 新一局：球回到筐前景之上（空中层）
	_ball.modulate.a = 1.0
	_ball.scale = Vector2.ONE
	_ball.rotation = 0.0
	# 先定位到手中再显示，避免在上一球消失处闪现一帧
	_ball.position = _hold_pos()
	_ball.visible = true
	if _charge_tween != null:
		_charge_tween.kill()
	_hands.scale = Vector2.ONE
	_charge_tween = create_tween()
	_charge_tween.tween_property(_hands, "rise", 0.0, CHARGE_TIME)


func _process(delta: float) -> void:
	var vp := get_viewport_rect().size
	var mouse := get_global_mouse_position()
	# 鼠标水平速度低通（甩投力度）
	_mouse_vx = lerpf(_mouse_vx, (mouse.x - _prev_mouse_x) / maxf(delta, 0.001), 0.5)
	_prev_mouse_x = mouse.x
	_update_difficulty(delta, vp)
	match state:
		State.IDLE, State.CHARGING:
			# 手跟随鼠标（平滑），rise 驱动低位/举起，球心即手节点原点
			var k := 1.0 - pow(HAND_FOLLOW_T, delta)   # 跟随权重（0 系数时 = 1 即时跟随，帧率无关）
			var hx := clampf(lerpf(_hands.position.x, mouse.x, k), vp.x * 0.06, vp.x * 0.94)
			_hands.position.x = hx
			var rise: float = _hands.rise
			_hands.position.y = lerpf(_low_y, _high_y, rise)
			_ball.position = _hold_pos()
		State.FLYING:
			_step_flight(delta, vp)
		State.RESULT:
			_rest_t -= delta
			if _rest_t <= 0.0:
				_enter_idle()


## 得分飘字：屏幕中心浮现（文本/颜色由调用方传入：+1 绿 / SWISH! 金），上浮淡出后自毁（可多个并发）
func _spawn_score_popup(text: String, col: Color) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
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


## 连击飘字：红色 combo×N（连续进球 COMBO_MIN 次以上每次显示）
func _spawn_combo(n: int) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = hud.t("pop.combo", "combo×%d") % n
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


## 动态难度：得分 > 10 后篮筐匀速往复，每 5 分加速一级（上限 50），退出游戏实例销毁自然重置
func _update_difficulty(delta: float, vp: Vector2) -> void:
	if score > DIFF_SCORE:
		_moving = true
	if not _moving:
		return
	_speed_level = mini(1 + (score - DIFF_SCORE - 1) / DIFF_STEP, SPEED_LEVEL_MAX)
	var sp := _speed_level * vp.x * HOOP_SPEED * delta * _hoop_dir
	var half := vp.x * HOOP_RANGE
	var x: float = _hoop_front.base_position.x + sp
	if x > vp.x * 0.5 + half:
		x = vp.x * 0.5 + half
		_hoop_dir = -1.0
	elif x < vp.x * 0.5 - half:
		x = vp.x * 0.5 - half
		_hoop_dir = 1.0
	_hoop_front.base_position.x = x
	_hoop_back.base_position.x = x   # 两层水平同步移动（back 保持相对筐口的抬升偏移）
	_hoop_front.apply_base()
	_hoop_back.apply_base()


func _hold_pos() -> Vector2:
	return _hands.position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()   # 键盘 R 与右上角 R 按钮一致
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and state == State.IDLE:
			state = State.CHARGING
			if _charge_tween != null:
				_charge_tween.kill()
			# 抬手举球：过冲缓动让"抬起"动作更明显
			_charge_tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_charge_tween.tween_property(_hands, "rise", 1.0, CHARGE_TIME)
		elif not event.pressed and state == State.CHARGING:
			_launch()


func _launch() -> void:
	var vp := get_viewport_rect().size
	var from := _hold_pos()
	var vx := clampf(_mouse_vx * VX_GAIN, -vp.x * VX_MAX_RATIO / FLIGHT_T, vp.x * VX_MAX_RATIO / FLIGHT_T)
	# vy0 反解：t=T 时球回到筐口平面且处于下落段
	var vy0: float = (from.y - _hoop_front.position.y + 0.5 * _g * FLIGHT_T * FLIGHT_T) / FLIGHT_T
	_ball.position = from
	_prev_ball_y = from.y
	_ball_v = Vector2(vx, -vy0)
	_flight_t = 0.0
	_trail_t = 0.0
	_scored = false
	_rim_hit = false
	_board_hit = false
	_goal_fading = false
	_trail.clear_points()
	_follow_through()
	state = State.FLYING


## 出手跟随：手随球上送 1.2 球径并压扁（高度 85%、宽度不变）；时长按出手球速反算（手速匹配球速）
func _follow_through() -> void:
	if _charge_tween != null:
		_charge_tween.kill()
	var dist := _ball_r * 1.2
	var dur: float = clampf(dist / maxf(_ball_v.length(), 1.0), 0.04, 0.1)
	_charge_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_charge_tween.tween_property(_hands, "position:y", _hands.position.y - dist, dur)
	_charge_tween.tween_property(_hands, "scale:y", 0.75, dur)


func _step_flight(delta: float, vp: Vector2) -> void:
	_flight_t += delta
	# 看门狗：飞行总时长超限（含未进反弹段）强制收尾，保证球必定回手
	if _flight_t > 4.5:
		_fade_out()
		return
	var rim := _hoop_front.position   # 筐口平面（判定线，含晃动偏移）
	# 进球后走引导轨迹：汇入篮网中心 → 减速垂直下坠 → 出网底淡出
	if _scored:
		_step_goal(delta, rim)
		return
	_ball_v.y += _g * delta
	_prev_ball_y = _ball.position.y
	_ball.position += _ball_v * delta
	# 透视缩放（近大远小）+ 飞行旋转（基础自转 + 随水平速度，直投也旋转）
	var t := clampf(_flight_t / FLIGHT_T, 0.0, 1.0)
	_ball.scale = Vector2.ONE * lerpf(1.0, SCALE_FAR, t)
	var omega := _ball_v.x / maxf(_ball_r, 1.0) * 0.6
	if absf(omega) < 3.0:
		omega = 3.0 if _ball_v.x >= 0.0 else -3.0
	_ball.rotation += omega * delta
	# 轨迹残影采样
	_trail_t += delta
	if _trail_t >= TRAIL_STEP:
		_trail_t = 0.0
		_trail.add_point(_ball.position)
		if _trail.get_point_count() > TRAIL_MAX:
			_trail.remove_point(0)
	# 进球判定：下落段球心穿越筐口平面，且球心完全处于筐口内（完全进入才得分）
	if not _scored and _ball_v.y > 0.0 and _prev_ball_y < rim.y and _ball.position.y >= rim.y:
		if absf(_ball.position.x - rim.x) < _hoop_front.half_width - _ball_r * GOAL_MARGIN:
			_score_goal()
	# 打铁：仅下落段，球心在进球窗口内豁免（空心入网），压圈（窗口外）按命中位置弹飞（每球一次）
	if not _scored and not _rim_hit and _ball_v.y > 0.0 and absf(_ball.position.y - rim.y) < _ball_r * 2.5 \
			and absf(_ball.position.x - rim.x) >= _hoop_front.half_width - _ball_r * GOAL_MARGIN:
		var tube := _ball_r * RIM_TUBE
		for edge_x in [rim.x - _hoop_front.half_width, rim.x + _hoop_front.half_width]:
			var edge := Vector2(edge_x, rim.y)
			var off := _ball.position - edge
			if off.length() < _ball_r + tube:
				var n := off.normalized()
				_ball_v = (_ball_v - _ball_v.dot(n) * 2.0 * n) * RIM_REST
				_ball.position = edge + n * (_ball_r + tube + 1.0)
				_rim_hit = true
				_hoop_front.shake()
				_hoop_back.shake()
				_play_sfx("rim_hit")
				break
	# 打板：仅下落段（未碰过筐沿、球心在进球窗口外），碰撞面为筐口平面下方一线，按球心相对碰撞点位置决定反弹方向
	if not _scored and not _rim_hit and not _board_hit and _ball_v.y > 0.0 \
			and absf(_ball.position.x - rim.x) >= _hoop_front.half_width - _ball_r * GOAL_MARGIN:
		var rect: Rect2 = _hoop_back.board_rect()   # 背板碰撞（back 层实测几何）
		var bx: float = _ball.position.x
		var by: float = _ball.position.y
		if rect.size.x > 0.0 and bx > rect.position.x - _ball_r and bx < rect.end.x + _ball_r:
			var line_y: float = rim.y + _ball_r * 0.3
			if by + _ball_r >= line_y and by - _ball_r <= line_y:
				var closest := Vector2(clampf(bx, rect.position.x, rect.end.x), line_y)
				var off2 := _ball.position - closest
				var n2 := off2.normalized() if off2.length() > 0.001 else Vector2.UP
				_ball_v = (_ball_v - _ball_v.dot(n2) * 2.0 * n2) * RIM_REST
				_ball.position = closest + n2 * (_ball_r + 1.0)
				_board_hit = true
				_hoop_front.shake()
				_hoop_back.shake()
				_play_sfx("board_hit")
	# 未进：落到地面（屏幕中央水平线）多次反弹衰减，弹尽停稳后进入下一轮
	if not _scored and _ball_v.y > 0.0 and _ball.position.y >= vp.y * GROUND_Y_RATIO - _ball_r:
		_ball.position.y = vp.y * GROUND_Y_RATIO - _ball_r
		_ball_v.y = -absf(_ball_v.y) * GROUND_REST
		_ball_v.x *= GROUND_FRICTION
		if absf(_ball_v.y) < _g * BOUNCE_STOP:
			_fade_out()
			return
	# 收尾兜底：超时 / 侧向出屏
	if not _scored and (_flight_t > FLIGHT_T * 2.0 or _ball.position.x < -_ball_r * 3.0 \
			or _ball.position.x > vp.x + _ball_r * 3.0):
		_fade_out()


func _score_goal() -> void:
	_scored = true
	_net_phase = 1
	_trail.clear_points()
	_ball.z_index = 0            # 沉入网内：回到筐前景之下，被网线真实遮挡（叠加半透明）
	_ball.modulate.a = 0.45
	# 空心球（SWISH）：未碰筐沿、未打板直接入网 → 金色 SWISH 飘字 + 欢呼声更大
	var swish: bool = not _rim_hit and not _board_hit
	_add_score(1)
	_spawn_score_popup(hud.t("pop.swish", "SWISH! +1") if swish else "+1",
			Color(1.0, 0.85, 0.25) if swish else Color(0.2, 0.85, 0.3))
	_hoop_front.shake()
	_hoop_back.shake()
	_hoop_front.swing_net()
	_play_sfx("score")
	_play_sfx("cheer", 4.0 if swish else -6.0)


## 进球引导轨迹：阶段1 指数趋近篮网中心（随距离自然减速），阶段2 慢速垂直下坠，出网底淡出
func _step_goal(delta: float, rim: Vector2) -> void:
	var net_center := Vector2(rim.x, rim.y + _hoop_front.net_len * 0.45)
	match _net_phase:
		1:
			_ball.position = _ball.position.lerp(net_center, 1.0 - pow(0.002, delta))
			_ball.rotation += 2.0 * delta
			if _ball.position.distance_to(net_center) < _ball_r * 0.3:
				_net_phase = 2
				_ball_v = Vector2.ZERO
		2:
			_ball_v = Vector2(0.0, minf(_ball_v.y + _ball_r * 3.0 * delta, _ball_r * 2.5))
			_ball.position += _ball_v * delta
			if _ball.position.y > rim.y + _hoop_front.net_len:
				_goal_fading = true
				if _fade_tween != null:
					_fade_tween.kill()
				_fade_tween = create_tween()
				_fade_tween.tween_property(_ball, "modulate:a", 0.0, 0.3)
				_fade_tween.tween_callback(_fade_out)


func _fade_out() -> void:
	if state == State.RESULT:
		return
	state = State.RESULT
	_rest_t = SCORE_REST if _scored else MISS_REST
	_trail.clear_points()
	if not _scored:
		hud.on_fail()   # miss：断连击（篮球不扣分，仅清零 combo）
		_update_trail()
		_play_sfx("aww", -6.0)
		# 未进路径：原地淡出收尾（进球路径已在穿网出底时淡出完毕，无需再计时）
		if _fade_tween != null:
			_fade_tween.kill()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_ball, "modulate:a", 0.0, 0.25)
