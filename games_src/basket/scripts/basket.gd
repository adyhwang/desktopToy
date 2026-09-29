extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 接水果：篮子在屏幕底部，鼠标控制其水平移动；物品从屏幕左/右外侧随机抛入，接住加分/扣分
## 落点 = 屏内随机 x（玩家需移动篮子去接）：固定飞行时长 T 反解初速度
## vx = (target_x − x0)/T，vy0 = (target_y − y0 − ½gT²)/T（Godot y 向下，重力 +g）
## 篮子前景/背景双层真实遮挡：BasketBack（画在水果下层）+ Items + BasketFront（画在水果上层），
## 接住的水果限速沉入篮内被前壁遮挡，沉够深度后淡出（无 clip_y 裁剪）

const FallingItem := preload("res://scripts/falling_item.gd")
const GameHud := preload("res://scripts/game_hud.gd")

const GRAVITY_RATIO := 2.2     # g = 屏高 × 此系数 / FLIGHT_REF²
const FLIGHT_REF := 1.8        # 重力参考时长（s）
const FLIGHT_MIN := 1.6        # 随机飞行时长下限（s）
const FLIGHT_MAX := 2.2        # 随机飞行时长上限（s）
const SPAWN_OFF_R := 2.0       # 出手点出屏距离 = r × 此值
const SPAWN_H_MIN := 0.08      # 随机起始高度下限 / 屏高
const SPAWN_H_MAX := 0.30      # 随机起始高度上限 / 屏高
const TARGET_X_MIN_RATIO := 0.10  # 抛物线目标 x 随机区间下限 / 屏宽
const TARGET_X_MAX_RATIO := 0.90  # 上限 / 屏宽
const BAD_RATIO := 0.3         # 坏水果权重（随机阈值，完好 70% / 坏 30%）
const GOLD_RATIO := 0.08       # 金果概率（+3，先于好/坏判定）
const BOMB_RATIO := 0.08       # 炸弹概率（接住 −3，落地不扣）
const MAX_ITEMS := 6           # 同屏物品上限兜底（防卡顿，超限跳过生成）
const SCORE_MARGIN := 0.3      # 接住判定：|dx| < 开口半宽 − r × 此系数
const CATCH_SINK_BALLS := 1.5  # 接住后继续下沉深度 = r × 此值
const CATCH_FADE_TIME := 0.25  # 下沉到位后淡出时长
const RIM_REST := 0.5          # 篮沿反弹弹性（压沿弹飞）
const RIM_TUBE := 0.18         # 篮沿管半径 = r × 此系数
const WALL_REST := 0.45        # 篮壁反弹弹性
const WALL_MIN_VX := 1.5       # 篮壁弹开的最小水平速度 = r × 此系数

# 掉落节奏：每累计 SPAWN_STEP_SCORE 分间隔减 SPAWN_STEP_DELTA（score 整数除法，允许负分）
const SPAWN_INTERVAL_START := 2.0
const SPAWN_INTERVAL_MIN := 0.2
const SPAWN_STEP_SCORE := 3
const SPAWN_STEP_DELTA := 0.1

# 物品清单（assets/fruits/ 下文件名，不含扩展名）：加分 10 种 / 扣分 10 种（Pineapple 大写与文件名一致）
const GOOD_ITEMS := ["apple", "banana", "watermelon", "pear", "orange", "grape", "peach", "strawberry", "carrot", "Pineapple"]
const BAD_ITEMS := ["apple_rot", "banana_rot", "watermelon_bite", "pear_rot", "orange_rot", "peach_rot", "grape_rot", "strawberry_rot", "carrot_rot", "Pineapple_rot"]

# ===== 尺寸与布局配置（物品半径 r 为基准，其余全部跟随）=====
const ITEM_R_RATIO := 0.035        # 物品半径 = min(屏宽, 屏高) × 此值
const RIM_Y_RATIO := 0.82          # 篮口平面 y / 屏高
const BASKET_TEX_ITEMS := 4.2      # 篮子贴图渲染宽 = r × 此值（篮口内宽 ≈ 3.7r）
const EDGE_RATIO := 0.05           # 篮子水平移动 clamp 边距 / 屏宽
const FOLLOW_T := 0.0              # 篮子鼠标水平跟随残差系数（权重 = 1 − pow(此值, delta)；0 = 即时跟随无延迟，要平滑手感可用 0.0002）
const CATCH_CENTER_SPEED := 8.0    # 接住后水果向篮心水平收敛速度（每秒，越大归中越快）
const GROUND_Y_RATIO := 0.95       # 地面线 y / 屏高（篮底附近，未接住落此线）
const SCORE_FONT_RATIO := 0.035    # 记分牌字号 = min(屏宽, 屏高) × 此值
const POPUP_FONT_RATIO := 0.06     # 得分飘字字号 = min(屏宽, 屏高) × 此值
const POPUP_TIME := 0.8            # 飘字动画时长（s）
const POPUP_RISE_RATIO := 0.08     # 飘字上浮距离 = min(屏宽, 屏高) × 此值
const SFX_POOL := 4                # 音效播放器池
const BGM_DB := -6.0               # BGM 音量（dB）
const SFX_DB := -4.0               # 音效全局音量偏移（默认 0dB 过响，统一下移）
const COMBO_MIN := 3               # 连击飘字触发次数（连续成功 ≥ 此值显示 combo×N）
const COMBO_FONT_RATIO := 0.075    # combo 飘字字号 = min(屏宽, 屏高) × 此值
const SHADOW_ALPHA_MAX := 0.30     # 落点预警阴影最大透明度
const SHADOW_OFF_SCORE := 5        # 达到此分后关闭落点预警阴影（提高难度）

var hud: RefCounted                # 通用 HUD（最高分/连击/音量）

@onready var _basket_back: Node2D = $BasketBack
@onready var _basket_front: Node2D = $BasketFront
@onready var _items_root: Node2D = $Items
@onready var _scoreboard: Label = $HudBar/ScoreBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var score := 0
var _r := 24.0
var _g := 0.0
var _rim_y := 0.0
var _ground_y := 0.0
var _spawn_t := SPAWN_INTERVAL_START
var _sfx_streams := {}        # 音效名 → AudioStream
var _sfx_players: Array = []
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button               # 排行榜按钮
var _hbox: HBoxContainer          # 右上角按钮排容器（等间距/底对齐）
var _bgm: AudioStreamPlayer


func start() -> void:
	randomize()
	hud = GameHud.new("basket")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()   # 先建按钮再布局（_layout 会设置按钮位置，null 会报错中断）
	_layout()
	_init_sfx()
	_refresh_score()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，分数入排行榜
	print("[basket] stop, final score=%d" % score)


## 键盘 R 重开（与右上角 R 按钮一致）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()


func _exit_button_pressed() -> void:
	exit_requested.emit()


## 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + 音量循环
## 容器统一等间距（8px）、按钮固定 56×56 底对齐、图标统一 32px 居中 —— 保证水平/垂直全对齐
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
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
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()   # R 改循环箭头图标（同风格程序生成）
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, _exit_btn]:
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


## 重开：上一局分数入排行榜；清空物品、分数与连击归零，节奏重置（排行榜保留）
func _restart() -> void:
	hud.commit_score()
	for it in _items_root.get_children():
		it.queue_free()
	score = 0
	_spawn_t = SPAWN_INTERVAL_START
	hud.reset_run()
	_sync_bgm()
	_refresh_score()


## 记分牌刷新：分数；负分红字
func _refresh_score() -> void:
	_scoreboard.text = "%d" % score
	_scoreboard.add_theme_color_override("font_color", Color(0.95, 0.25, 0.2) if score < 0 else Color.WHITE)


## 得分统一入口：计分 + 最高分 + 连击（成功/失败）+ 飘字
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


func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_r = m * ITEM_R_RATIO
	_g = GRAVITY_RATIO * vp.y / (FLIGHT_REF * FLIGHT_REF)
	_rim_y = vp.y * RIM_Y_RATIO
	_ground_y = vp.y * GROUND_Y_RATIO
	for b in [_basket_back, _basket_front]:
		b.item_radius = _r
		b.tex_w_items = BASKET_TEX_ITEMS
		b.opening_half = _r * BASKET_TEX_ITEMS * b.OPEN_W_RATIO / 2.0
	_basket_back.tex_paths = ["res://games/basket/assets/basket_back.png", "res://assets/basket_back.png"]
	_basket_front.tex_paths = ["res://games/basket/assets/basket_front.png", "res://assets/basket_front.png"]
	if absf(_basket_back.base_position.y - _rim_y) > 0.5:
		_basket_back.base_position = Vector2(vp.x * 0.5, _rim_y)   # 首次布局：篮子置于底部中央
	else:
		_basket_back.base_position.y = _rim_y                      # 窗口尺寸变化：仅更新篮口高度
	_basket_front.base_position = _basket_back.base_position
	_basket_back.apply_base()
	_basket_front.apply_base()
	_basket_back.queue_redraw()
	_basket_front.queue_redraw()
	for it in _items_root.get_children():
		it.radius = _r
		it.g = _g
		it.ground_y = _ground_y
		it.queue_redraw()
	_scoreboard.custom_minimum_size = Vector2(175.0, m * SCORE_FONT_RATIO * 1.9)   # 单行背景板
	_scoreboard.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scoreboard.add_theme_font_size_override("font_size", int(m * SCORE_FONT_RATIO))
	# 信息板 HudBar 整体水平居中（代码定位，Node2D 父下锚点不可靠）
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	# 右上角按钮排：容器定位右上（等间距/尺寸/对齐在 _setup_buttons 统一设定）
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


func _process(delta: float) -> void:
	var vp := get_viewport_rect().size
	# 篮子鼠标水平平滑跟随（主控统一驱动：两层 base_position 同帧更新，篮内水果跟随才不会滞后穿模）
	var tx: float = clampf(get_global_mouse_position().x, vp.x * EDGE_RATIO, vp.x * (1.0 - EDGE_RATIO))
	var w: float = 1.0 - pow(FOLLOW_T, delta)
	var bx: float = lerpf(_basket_back.base_position.x, tx, w)
	_basket_back.base_position.x = bx
	_basket_front.base_position.x = bx
	_basket_back.apply_base()
	_basket_front.apply_base()
	_spawn_t -= delta
	if _spawn_t <= 0.0:
		_spawn()
		_spawn_t = _spawn_interval()
	_judge_items()
	queue_redraw()   # 落点预警阴影随物品每帧更新
	# 已接住（下沉中）的物品：水平跟随篮子并向篮心收敛（防边缘压壁穿模），沉够深度后淡出释放
	# （遮挡由前景层前壁真实完成）
	for it in _items_root.get_children():
		var sinking: bool = it.sinking
		if sinking:
			it.catch_rel_x = lerpf(it.catch_rel_x, 0.0, minf(CATCH_CENTER_SPEED * delta, 1.0))
			it.position.x = _basket_front.position.x + it.catch_rel_x
			var pos: Vector2 = it.position
			if pos.y >= _rim_y + _r * CATCH_SINK_BALLS:
				it.fade_time = CATCH_FADE_TIME
				it.fade_out()


## 得分/扣分飘字：屏幕中心浮现（bonus 决定文本与颜色：正绿/金，负红），上浮淡出后自毁（可多个并发）
func _spawn_popup(bonus: int) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = "+%d" % bonus if bonus > 0 else "%d" % bonus
	var col := Color(0.2, 0.85, 0.3)
	if bonus >= 3:
		col = Color(1.0, 0.85, 0.25)   # 金果金色
	elif bonus < 0:
		col = Color(0.95, 0.25, 0.2)
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


## 连击飘字：红色 combo×N（连续成功 COMBO_MIN 次以上每次显示）
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


## 当前掉落间隔：按 score / SPAWN_STEP_SCORE 整数除法收紧，夹取 [MIN, START]
func _spawn_interval() -> float:
	var iv: float = SPAWN_INTERVAL_START - float(score / SPAWN_STEP_SCORE) * SPAWN_STEP_DELTA
	return clampf(iv, SPAWN_INTERVAL_MIN, SPAWN_INTERVAL_START)


## 落点预警阴影：画在最底层（根节点 _draw），每个飞行中物品按出生抛物线的落点 x 画椭圆
## 越接近地面越大越深，帮助玩家预判
func _draw() -> void:
	if hud == null or score >= SHADOW_OFF_SCORE:   # 达分后关闭预警阴影
		return
	for it in _items_root.get_children():
		if it.done:
			continue
		var prog: float = clampf((it.position.y - it.start_y) / maxf(_ground_y - it.start_y, 1.0), 0.0, 1.0)
		var a: float = SHADOW_ALPHA_MAX * (0.35 + 0.65 * prog)
		draw_circle(Vector2(it.target_x, _ground_y), _r * (0.5 + 0.35 * prog), Color(0.0, 0.0, 0.0, a))


## 随机抛入：随机侧/起始高度/飞行时长/物品，落点 = 屏内随机 x（玩家移动篮子去接）
## 特殊物品：金果（+3）/ 炸弹（接住 −3、落地不扣），先于好/坏判定
func _spawn() -> void:
	if _items_root.get_child_count() >= MAX_ITEMS:
		return
	var vp := get_viewport_rect().size
	var roll := randf()
	var bonus := 0
	var tex_name: String
	if roll < GOLD_RATIO:
		tex_name = "gold"
		bonus = 3
	elif roll < GOLD_RATIO + BOMB_RATIO:
		tex_name = "bomb"
		bonus = -3
	else:
		var bad := randf() < BAD_RATIO
		bonus = -1 if bad else 1
		var pool: Array = BAD_ITEMS if bad else GOOD_ITEMS
		tex_name = pool[randi() % pool.size()]
	var flight_t: float = randf_range(FLIGHT_MIN, FLIGHT_MAX)
	var x0: float = -_r * SPAWN_OFF_R if randf() < 0.5 else vp.x + _r * SPAWN_OFF_R
	var y0: float = vp.y * randf_range(SPAWN_H_MIN, SPAWN_H_MAX)
	var target_x: float = vp.x * randf_range(TARGET_X_MIN_RATIO, TARGET_X_MAX_RATIO)   # 屏内随机落点
	var vx: float = (target_x - x0) / flight_t
	var vy0: float = (_rim_y - y0 - 0.5 * _g * flight_t * flight_t) / flight_t
	var it: Node2D = FallingItem.new()
	it.good = bonus > 0
	it.bonus = bonus
	it.item_name = tex_name
	it.target_x = target_x
	it.radius = _r
	it.g = _g
	it.flight_t = flight_t
	it.ground_y = _ground_y
	_items_root.add_child(it)
	it.spawn(vx, vy0, x0, y0)


## 判定（仅物品下落段 vy > 0）：穿越篮口平面且 |dx| 在开口内 = 接住；落到地面线 = 未接住
func _judge_items() -> void:
	var vp := get_viewport_rect().size
	for it in _items_root.get_children():
		var done: bool = it.done
		if done:
			continue
		var pos: Vector2 = it.position
		var v: Vector2 = it.v
		var prev_y: float = it.prev_y
		var air_t: float = it.air_t
		# 接住：按物品 bonus 计分（好 +1 / 坏 −1 / 金 +3 / 炸弹 −3）；限速沉入篮内被前景层前壁遮挡
		# （弹飞后可再次接住：计分只发生在进篮/落地两个终点，scored 锁保证每件只计一次）
		if v.y > 0.0 and prev_y < _rim_y and pos.y >= _rim_y \
				and absf(pos.x - _basket_front.position.x) < _basket_front.opening_half - _r * SCORE_MARGIN:
			if not it.scored:   # 计分锁：每件水果只计一次（弹飞后再进篮也算接住）
				it.scored = true
				var b: int = it.bonus
				_add_score(b)
				_spawn_popup(b)
				_play_sfx("catch" if b > 0 else "bad")   # 加分泡泡声 / 扣分失败音
			_basket_back.shake()
			_basket_front.shake()
			_basket_back.bounce()
			_basket_front.bounce()
			it.catch_rel_x = pos.x - _basket_front.position.x   # 记录接住时相对篮心偏移，下沉期间随篮子平移
			it.catch_sink()
			continue
		# 篮沿：砸中篮口边沿弹飞（圆管模型，每件一次，仅下落段）——压沿的水果弹飞不进篮
		if v.y > 0.0 and not it.rim_hit:
			var tube: float = _r * RIM_TUBE
			for edge_x in [-_basket_front.opening_half, _basket_front.opening_half]:
				var edge := _basket_front.position + Vector2(edge_x, 0.0)
				var off := pos - edge
				if off.length() < _r + tube:
					it.rim_hit = true
					var n := off.normalized()
					it.v = (v - v.dot(n) * 2.0 * n) * RIM_REST   # 沿命中点法线镜面反射
					it.position = edge + n * (_r + tube + 1.0)   # 推出沿外防二次判定
					_play_sfx("thud", -3.0)
					_basket_back.shake()
					_basket_front.shake()
					break
			if it.rim_hit:
				continue
		# 篮壁外侧：砸中篮身侧壁水平弹开（梯形半宽按 y 插值，每件一次）
		if v.y > 0.0 and not it.rim_hit and not it.wall_hit:
			var rel := pos - _basket_front.position
			var s: float = _r * BASKET_TEX_ITEMS / _basket_front.tex_size.x
			var body_h: float = _basket_front.body_h_px * s
			if rel.y > _r * 0.1 and rel.y < body_h + _r:
				var half: float = lerpf(_basket_front.wall_top_half_px, _basket_front.wall_bottom_half_px,
						clampf(rel.y / body_h, 0.0, 1.0)) * s
				if absf(rel.x) - half < _r \
						and absf(rel.x) > _basket_front.opening_half - _r * SCORE_MARGIN:
					it.wall_hit = true
					var side := signf(rel.x)
					it.v.x = side * maxf(absf(v.x) * WALL_REST, _r * WALL_MIN_VX)   # 向壁外侧弹开
					it.position.x = _basket_front.position.x + side * (half + _r + 1.0)
					_play_sfx("thud", -6.0)
					_basket_back.shake()
					_basket_front.shake()
		# 未接住落地：好果/金果 −1 后淡出，坏果/炸弹直接淡出不扣分
		if v.y > 0.0 and pos.y >= _ground_y:
			if it.good and not it.scored:   # 计分锁：每件水果只计一次
				it.scored = true
				_add_score(-1)
				_spawn_popup(-1)
				_play_sfx("bad", -3.0)   # 好果落地：低沉失败音
			it.fade_out()
			continue
		# 看门狗兜底：飞行超时 / 落出屏底的物品强制清理
		if air_t > it.flight_t * 2.5 or pos.y > vp.y + _r * 3.0:
			it.fade_out()


## 音效初始化：pck 内 mp3 走字节解码，编辑器预览走导入资源（双路径）
func _init_sfx() -> void:
	var files := {"catch": "catch.mp3", "thud": "thud.mp3", "bad": "bad.mp3"}
	for name: String in files:
		for base in ["res://games/basket/assets/sfx/", "res://assets/sfx/"]:
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
	for base in ["res://games/basket/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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
	if not _sfx_streams.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return
