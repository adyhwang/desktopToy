extends "res://scripts/game_base.gd"
## 打水漂 Stone Skip：下方碎石岸（玩家）→ 大部分画面的蓝绿水面纵深延伸 → 上方对岸灌木（透视景深）
## 流程：选石 → 瞄准（鼠标 Y=出手高度 X=自旋方向（右顺左逆）与强度，外围环形箭头指示，尾在下方）
##       → 按住左键蓄力（三槽：左=蓄力 5s 蓄满自动丢 / 右=出手高度 / 下=自旋；金线=80% 完美点，
##         超 80% 段变警示色=过火；松开即丢）→ 首段落点固定 1.2m，
##         蓄力决定弧线（80% 封顶=低平快掷，轻丢=高弧慢抛）与入水动能（弹跳强度）
##       → 贴水连跳（反弹保能量，入水角近似恒定，侧向限幅总体向前）→ 沉水下沉 /
##         抵岸掌声+滑行上岸（静止 1.5s 后淡出）→ 结算
## 物理因子：入水角（过大直接沉）、自旋（不足沉 / 过大侧漂改变方向）、重量与密度
##           （重=难起跳掉速快）、扁平度（越扁容错角越大）、弹性、空气阻力、浮力（木块宽容）
## 最优攻略（三槽金线 80% 精确对应）：硬币 + 高度 80% + 力 80% + 旋 80%（29 跳恰好抵 50m 对岸=金币最远距离）
## 计分：双榜（打漂次数 / 距离），石片沉水或抵达对岸本轮结束
## 视觉：石片自旋动画、入水水花序列帧 + 水花液滴、扩散椭圆水波纹（透视压扁）、侧翻下沉气泡
## 素材：icons8 CDN（鹅卵石/瓷瓶/砖头/玻璃瓶/徽章/篮球/橄榄球）+ 程序绘制（木块/乒乓球/水花帧/icon）

const GameHud := preload("res://scripts/game_hud.gd")

enum State { SELECT, AIM, CHARGE, FLY, LAND, SINK, RESULT }

# —— 物理与节奏（米制世界坐标，d=纵深距离 h=离水高度 z=横向偏移）——
const G := 10.0               # 重力（弹跳段抛物线）
const SC_FAR := 0.22           # 最远端缩放（操作物/波纹随距离持续缩小）
const D_FAR := 50.0            # 对岸距离（m，=金币最远距离）；透视 u=d/D_FAR 线性映射，D_FAR 精确落在对岸水线
const D_SPLASH := 1.2          # 首次入水固定位置（m，蓄力不改变落点）
const T_FLY := 0.5             # 首段飞行时长（s，出手到入水的动画时间；仅影响节奏）
const T_VH := 1.0              # 入水垂直速度基准时长（s；vh=(出手高+弧顶)/T_VH）
const V_IN := 7.8              # 入水基准水平速度（蓄力/质量缩放；倒推自"金币最远=50m"：三槽 80% 金币 29 跳恰好抵对岸）
const H_MIN := 0.1             # 出手高度下限（m，鼠标 Y 映射：低=贴水连跳）
const H_SWEET := 0.955         # 完美出手高度（m，高度槽 80% 金线精确对应；超 80% 继续升高=过火变差）
const ARC_LO := 0.40           # 首段弧顶附加高度（m，由蓄力决定：≥80% 蓄力=低弧平掷（封顶））
const ARC_HI := 0.60           # 首段弧顶附加高度（m，由蓄力决定：轻丢=高弧慢抛）
const SWEET_FRAC := 0.8        # 三槽完美点位置（80%）；蓄力增益软封顶点
const CHARGE_T := 5.0          # 蓄满时长（s，金线 80% 处=4s 为完美点；蓄满自动丢）
const PHYS_DT := 0.002         # 弹跳段固定物理步长（s，≈500Hz 与模拟器一致；帧率无关，低帧下成绩不缩水）
const SINK_T := 1.15           # 下沉动画时长（s）
const RESULT_T := 1.7          # 结算停留（s）
# 抵岸 sequence：掌声 + 缓出滑行上岸 → 静止 → 淡出
const LAND_SLIDE := 1.5        # 上岸滑行距离（m，越过对岸水线）
const LAND_SLIDE_T := 1.2      # 滑行时长（s，缓出）
const LAND_REST_T := 1.5       # 静止时长（s）
const LAND_FADE_T := 0.8       # 透明消失时长（s）
const VZ_MAX_FRAC := 0.08      # 侧向速度上限（占 _vd 比例，偏角≤约4.6°，总体保持向前）
const STONE_READY_SCALE := 4.0 / 3.0   # 准备状态悬空石片显示倍率（原 ×2，应要求缩小 1/3；丢出后渐缩回 1）
const SFX_DB := -4.0
const BGM_DB := -6.0
const SFX_POOL := 4

# 石片配置：r=显示半径(min边比) m=质量(出手速度÷√m、掉速少) flat=扁平度(容错角/升力)
# rest=弹性(起跳垂直分量) drag=空气阻力 sneed=起跳最低自旋 sover=过自旋侧漂阈值
# buoy=浮力(起跳加成+容错)
const STONES := [
	{"id": "pebble", "tex": "obj_pebble.png", "r": 0.045, "m": 0.7, "flat": 0.93, "rest": 0.66, "drag": 0.02, "sneed": 0.10, "sover": 1.30, "buoy": 0.35},
	{"id": "ceramic", "tex": "obj_ceramic.png", "r": 0.048, "m": 0.7, "flat": 0.85, "rest": 0.55, "drag": 0.03, "sneed": 0.18, "sover": 1.30, "buoy": 0.35},
	{"id": "book", "tex": "obj_book.png", "r": 0.056, "m": 1.2, "flat": 0.85, "rest": 0.35, "drag": 0.03, "sneed": 0.28, "sover": 1.15, "buoy": 0.30},
	{"id": "glass", "tex": "obj_glass.png", "r": 0.048, "m": 0.6, "flat": 0.80, "rest": 0.55, "drag": 0.04, "sneed": 0.16, "sover": 1.28, "buoy": 0.45},
	{"id": "coin", "tex": "obj_coin.png", "r": 0.040, "m": 0.45, "flat": 0.90, "rest": 0.60, "drag": 0.06, "sneed": 0.10, "sover": 1.25, "buoy": 0.55},
	{"id": "phone", "tex": "obj_phone.png", "r": 0.052, "m": 1.0, "flat": 0.88, "rest": 0.40, "drag": 0.03, "sneed": 0.22, "sover": 1.20, "buoy": 0.15},
]

var hud: RefCounted
var state := State.SELECT
var _u := 1.0
var _time := 0.0
var _stone_idx := 0
var _power := 0.0              # 蓄力 0→1（决定弧线与入水动能；≥80% 过火，槽变色提示）
var _aim_h := 0.4              # 瞄准出手高度（m，槽 80%=0.955 完美；拉满≈1.17 过火）
var _aim_lift := 0.0           # 瞄准悬空石片随鼠标 Y 的升降（px）
var _fill_h := 0.5             # 高度槽填充（=yr 0~1）
var _fill_x := 0.0             # 自旋槽填充（=xr -1~1，从中心向两侧）
var _spin := 0.0               # 自旋 -2.5..2.5（符号=视觉方向，鼠标 X；80%=2.0 完美点）
var _rot := 0.0                # 石片视觉累计旋转（rad）
# 飞行世界坐标
var _d := 0.0
var _h := 0.0
var _z := 0.0
var _vd := 0.0
var _vh := 0.0
var _vz := 0.0
var _s := 0.0                  # 飞行中自旋（逐跳衰减）
var _fly_t := -1.0             # 首段参数化飞行计时（-1=已结束，走弹跳物理）
var _phys_acc := 0.0           # 弹跳段固定步长积分累加器（s）
var _fly_arc := ARC_LO         # 首段弧顶附加高度（_throw 时按蓄力确定）
var _skips := 0
var _dist := 0.0
var _sink_t := 0.0
var _result_t := 0.0
var _land_t := 0.0             # 抵岸 sequence 计时（s：滑行→静止→淡出）
# 特效池
var _ripples: Array = []       # {pos, r0, t, life}
var _drops: Array = []         # {pos, vel, t, life, r}
var _bubbles: Array = []       # {pos, vel, t, life, r}
var _splashes: Array = []      # {pos, t, sc}
var _popups: Array = []        # {text, col, t, life}
# 布景缓存（_layout 重建；种子随机保证每帧一致）
var _pebbles: Array = []
var _bushes: Array = []
var _trees: Array = []
var _shimmer: Array = []
var _y_near := 0.0             # 近岸水线（屏幕 y）
var _y_far := 0.0              # 对岸水线
var _hs := 1.0                 # 高度米→px（近岸）
var _zs := 1.0                 # 横向米→px
var _hover := Vector2.ZERO     # 石片悬空点（屏幕）
var _tex := {}
var _sfx := {}
var _sfx_mp3 := {}             # mp3 音效（掌声等，pck 字节解码）
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
# UI
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _skips_board: Label = $HudBar/SkipsBoard
@onready var _dist_board: Label = $HudBar/DistBoard
@onready var _exit_btn: Button = $ExitButton
var _hbox: HBoxContainer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _select_layer: Control


func start() -> void:
	randomize()
	hud = GameHud.new("stone_skip")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()
	_layout()
	_init_sfx()
	_refresh_boards()
	_show_select()


func stop() -> void:
	get_tree().paused = false          # 排行榜可能还挂着暂停，兜底恢复
	if _bgm != null:
		_bgm.stop()
	print("[stone_skip] stop, last round: %d skips %.1f m" % [_skips, _dist])


func _exit_button_pressed() -> void:
	exit_requested.emit()


func on_leaderboard_closed() -> void:
	pass   # 关闭回调占位（无开发者暗门）


# ===== 资源加载 =====

func _load_textures() -> void:
	for st: Dictionary in STONES:
		_tex[st.tex] = _load_png("assets/" + st.tex)
	for f in 7:
		_tex["splash_%d" % f] = _load_png("assets/splash_%d.png" % f)


func _load_png(rel: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码（编辑器期走 res:// 相对路径）
	for p: String in ["res://games/stone_skip/" + rel, "res://" + rel]:
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
	_y_near = vp.y * 0.89
	_y_far = vp.y * 0.20   # 对岸线压低：天空+对岸只占上 20%，水面纵深更长
	_hs = vp.y * 0.22
	_zs = vp.x * 0.12
	_hover = Vector2(vp.x * 0.5, vp.y * 1.055)   # 悬空点
	_build_scenery(vp)
	# 信息板随窗口缩放；整体水平居中
	var fs := int(m * 0.035)
	for b: Label in [_skips_board, _dist_board]:
		b.custom_minimum_size = Vector2(fs * 6.0, fs * 1.9)
		b.add_theme_font_size_override("font_size", fs)
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	if _select_layer != null:   # 选石面板重建以适配新尺寸
		_select_layer.queue_free()
		_select_layer = null
		_show_select()


## 布景缓存：碎石滩 / 对岸灌木与树 / 波光行（种子固定，每帧绘制一致）
func _build_scenery(vp: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260926
	_pebbles.clear()
	for i in 120:
		var y := rng.randf_range(_y_near + vp.y * 0.02, vp.y - 8.0)
		var depth := (y - _y_near) / maxf(vp.y - _y_near, 1.0)   # 越靠下（越近）越大
		var r := lerpf(5.0, 16.0, depth) * rng.randf_range(0.6, 1.3) * _u
		var base := rng.randf_range(0.34, 0.62)
		var warm := rng.randf() < 0.4
		_pebbles.append({
			"pos": Vector2(rng.randf_range(6.0, vp.x - 6.0), y),
			"r": r, "asp": rng.randf_range(0.55, 0.85),
			"rot": rng.randf_range(-0.5, 0.5),
			"col": Color(base + 0.06, base, base - (0.04 if warm else -0.02)),
		})
	_bushes.clear()
	for i in 34:
		_bushes.append({
			"pos": Vector2(rng.randf_range(-20.0, vp.x + 20.0),
					rng.randf_range(_y_far - vp.y * 0.042, _y_far - vp.y * 0.005)),
			"r": rng.randf_range(vp.y * 0.008, vp.y * 0.019),
			"col": rng.randf_range(0.0, 1.0),
		})
	_trees.clear()
	for i in 6:
		var tx := rng.randf_range(vp.x * 0.08, vp.x * 0.92)
		_trees.append({
			"x": tx,
			"top": _y_far - vp.y * rng.randf_range(0.045, 0.058),
			"r": vp.y * rng.randf_range(0.014, 0.022),
		})
	_shimmer.clear()
	for i in 9:
		_shimmer.append({
			"frac": (i + rng.randf_range(0.15, 0.85)) / 9.0,
			"amp": rng.randf_range(0.5, 1.0),
			"ph": rng.randf_range(0.0, TAU),
			"sp": rng.randf_range(8.0, 20.0) * (1.0 if rng.randf() < 0.5 else -1.0),
		})


func _stone() -> Dictionary:
	return STONES[_stone_idx]


# ===== 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + 音量循环 + BGM =====

func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
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
	hud.show_leaderboard(self, _skips, _dist)


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
	# 重开：放弃当前轮（未沉水不计分），回选石
	_skips = 0
	_dist = 0.0
	_splashes.clear()
	_drops.clear()
	_ripples.clear()
	_bubbles.clear()
	_popups.clear()
	_show_select()
	_refresh_boards()


# ===== 选石面板（自绘模态层：全屏遮罩 + 深色圆角面板 + 3×3 石片格）=====

func _show_select() -> void:
	if _select_layer != null:
		return
	state = State.SELECT
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var layer := Control.new()
	layer.name = "SelectLayer"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
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
	var title := Label.new()
	var tt: String = hud.t("ui.select_title", "Choose Your Skipper")
	title.text = tt
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(m * 0.042))
	title.add_theme_color_override("font_color", Color(0.55, 0.9, 0.95))
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 8)
	vb.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", int(m * 0.014))
	grid.add_theme_constant_override("v_separation", int(m * 0.014))
	vb.add_child(grid)
	for i in STONES.size():
		var st: Dictionary = STONES[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(m * 0.15, m * 0.185)
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
		var ic := TextureRect.new()
		ic.texture = _tex.get(st.tex)
		ic.custom_minimum_size = Vector2(m * 0.085, m * 0.085)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(ic)
		var nm := Label.new()
		var key := "stone.%s" % st.id
		var ntxt: String = hud.t(key, st.id)
		nm.text = ntxt
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.add_theme_font_size_override("font_size", int(m * 0.021))
		nm.add_theme_color_override("font_color", Color.WHITE)
		nm.add_theme_color_override("font_outline_color", Color.BLACK)
		nm.add_theme_constant_override("outline_size", 6)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(nm)
		btn.add_child(cell)
		btn.pressed.connect(_pick_stone.bind(i))
		grid.add_child(btn)
	layer.add_child(panel)
	add_child(layer)
	panel.reset_size()
	panel.position = Vector2(vp.x / 2.0 - panel.size.x / 2.0, vp.y / 2.0 - panel.size.y / 2.0)
	_select_layer = layer


func _pick_stone(i: int) -> void:
	_stone_idx = i
	_play_sfx("pick")
	if _select_layer != null:
		_select_layer.queue_free()
		_select_layer = null
	state = State.AIM
	_power = 0.0
	_aim_h = 0.4
	_aim_lift = 0.0
	_spin = 0.0
	_rot = 0.0
	_skips = 0
	_dist = 0.0
	_d = 0.02
	_refresh_boards()
	var tip: String = hud.t("ui.tip_aim", "Mouse up/down: height · left/right: spin")
	_popup(tip, Color(0.75, 0.93, 1.0))
	var tip2: String = hud.t("ui.tip_charge", "Hold left button to charge")
	get_tree().create_timer(1.6).timeout.connect(func() -> void:
		if state == State.AIM or state == State.CHARGE:
			_popup(tip2, Color(1.0, 0.85, 0.4)))


# ===== 主循环 =====

func _process(delta: float) -> void:
	_time += delta
	match state:
		State.AIM, State.CHARGE:
			_update_aim()
			if state == State.CHARGE:
				_power += delta / CHARGE_T
				if _power >= 1.0:
					_power = 1.0
					_throw()
		State.FLY:
			_step_flight(delta)
		State.SINK:
			_sink_t += delta
			if _sink_t >= SINK_T:
				_finish_round()
		State.LAND:
			# 抵岸 sequence：缓出滑行上岸 → 静止 → 淡出 → 结算
			_land_t += delta
			var k := minf(_land_t / LAND_SLIDE_T, 1.0)
			_d = D_FAR + LAND_SLIDE * (1.0 - (1.0 - k) * (1.0 - k))
			if _land_t >= LAND_SLIDE_T + LAND_REST_T + LAND_FADE_T:
				_finish_round()
		State.RESULT:
			_result_t += delta
			if _result_t >= RESULT_T:
				_show_select()
	_step_fx(delta)
	_refresh_boards()
	queue_redraw()


## 瞄准：鼠标 Y→出手高度（槽 80%=完美点，石片随升降）+X→自旋（含蓄力阶段持续可调；弧线由蓄力决定）
func _update_aim() -> void:
	var vp := get_viewport_rect().size
	var mp := get_global_mouse_position()
	var yr := clampf((_hover.y - mp.y) / (vp.y * 0.30), 0.0, 1.0)   # 水面中部即满值
	# 槽 80%（金线）精确对应完美出手高度 H_SWEET；超 80% 继续升高=过火
	_aim_h = H_MIN + (H_SWEET - H_MIN) / SWEET_FRAC * yr
	_aim_lift = -(_aim_h - 0.4) * _hs   # 出手高度换算视觉升降（0.4m 为原悬空位）
	_fill_h = yr
	var xr := clampf((mp.x - vp.x * 0.5) / (vp.x * 0.25), -1.0, 1.0)
	_spin = xr * 2.5   # 槽 80% 自旋=2.0（完美点）；拉满 2.5 侧漂加倍=过火
	_fill_x = xr


## 松开/蓄满：丢出（首段落点固定 D_SPLASH；出手高度=瞄准，弧线高度=蓄力）
func _throw() -> void:
	_fly_arc = lerpf(ARC_HI, ARC_LO, clampf(_power / SWEET_FRAC, 0.0, 1.0))   # 蓄力越大弧线越低平（80% 起封顶），轻丢高抛
	_vd = 0.0
	_vh = 0.0
	_vz = 0.0
	_s = _spin
	_d = 0.02
	_h = _aim_h
	_z = 0.0
	_fly_t = 0.0
	_skips = 0
	_dist = 0.0
	_rot = 0.0
	_phys_acc = 0.0
	state = State.FLY
	# 丢出参数回显（诊断辅助：实际生效的输入百分比，一眼核对是否与瞄准槽对齐）
	_popup("高 %d%% · 力 %d%% · 旋 %d%%" % [
		roundi(_fill_h * 100.0), roundi(_power * 100.0), roundi(absf(_fill_x) * 100.0)],
		Color(1, 1, 1, 0.95))
	_play_sfx("throw")


## 首段参数化飞行：d 固定推进到 D_SPLASH，h 抛物弧（从出手高度 h0 起落，弧顶由蓄力决定）
func _step_first_fly(dt: float, st: Dictionary) -> bool:
	_fly_t += dt
	var u := _fly_t / T_FLY
	_rot += _s * 9.0 * dt
	if u >= 1.0:
		_d = D_SPLASH
		_h = 0.0
		# 构造入水速度：蓄力/质量决定水平动能（80% 起增益封顶），出手高度+弧顶决定垂直分量（高掷入水角大）
		_vd = V_IN * (0.8 + 0.5 * minf(_power, SWEET_FRAC)) * (1.10 - 0.10 * st.m)
		_vh = -(_aim_h + _fly_arc) / T_VH
		_fly_t = -1.0
		_contact(st)
		return state == State.FLY
	_d = 0.02 + (D_SPLASH - 0.02) * u
	_h = _aim_h * (1.0 - u) + _fly_arc * u * (1.0 - u)
	return true


## 飞行物理（首段参数化；弹跳段固定步长累加积分——与渲染帧率解耦，轨迹/成绩确定）
func _step_flight(delta: float) -> void:
	var st := _stone()
	if _fly_t >= 0.0:
		if not _step_first_fly(delta, st):
			_dist = _d
			return
	else:
		_phys_acc += minf(delta, 0.1)   # 单帧上限防卡顿螺旋
		var steps := 0
		while _phys_acc >= PHYS_DT and steps < 200:
			_phys_acc -= PHYS_DT
			steps += 1
			_vd = maxf(_vd - _vd * st.drag * 0.4 * PHYS_DT, 0.0)   # 空气阻力（轻物明显，贴水跳衰减弱）
			_vh -= _vh * st.drag * 0.6 * PHYS_DT
			_vh -= G * PHYS_DT
			_d += _vd * PHYS_DT
			_h += _vh * PHYS_DT
			_z += _vz * PHYS_DT
			# 过自旋空中侧偏（Magnus 简化，效果减半）+ 侧向限幅（总体保持向前）
			if absf(_s) > st.sover:
				_vz += signf(_s) * (absf(_s) - st.sover) * 0.45 * PHYS_DT
			_vz = clampf(_vz, -_vd * VZ_MAX_FRAC, _vd * VZ_MAX_FRAC)
			_rot += _s * 9.0 * PHYS_DT
			if _h <= 0.0 and _d > 0.5:
				_h = 0.0
				_contact(st)
				if state != State.FLY:
					break
	_dist = _d
	if state == State.FLY and _d >= D_FAR:
		_reach_far()


## 撞水：入水角/速度/自旋判定 → 起跳 or 沉没
func _contact(st: Dictionary) -> void:
	var phi := atan2(maxf(-_vh, 0.0), maxf(_vd, 0.01))            # 入水角（rad，相对水面）
	var phi_max: float = lerpf(0.16, 0.52, st.flat) + (st.buoy - 0.5) * 0.30   # 越扁/浮力越大容错越大（差异放大）
	var v_min: float = 1.5 + st.m * 0.55                          # 重物更难起跳（差异放大）
	if phi > phi_max or _vd < v_min or absf(_s) < st.sneed:
		_start_sink()
		return
	# 起跳：计分 + 水花 + 波纹 + 声
	_skips += 1
	var inten := clampf(_vd / 14.0, 0.35, 1.0)
	_spawn_splash(_d, _z, inten * (0.7 + st.r))
	_spawn_ripple(_d, _z, st)
	_play_sfx("plink", clampf((1.05 - inten) * 4.0, -8.0, 0.0))
	# 掉速：入水角越大掉越多；扁/轻/弹/浮利于保速（差异放大）
	var keep := clampf((0.965 - 0.045 * phi) * (0.88 + 0.14 * st.flat) * (1.05 - 0.06 * st.m) * (0.90 + 0.17 * st.rest), 0.42, 0.99)
	_vd *= keep
	# 反弹保能量：vh/vd 同乘 keep → 入水角逐跳严格恒定（贴水连跳，无正反馈仰角漂移）
	_vh = -_vh * keep
	# 橄榄球：落水随机偏折
	if st.get("chaos", 0.0) > 0.0:
		_vd *= randf_range(0.90, 1.06)
		_vz += randf_range(-1.0, 1.0) * st.chaos * 1.2
	# 过自旋：横向踢移（改变移动方向，效果减半）+ 侧向限幅（总体保持向前）
	if absf(_s) > st.sover:
		_vz += signf(_s) * (absf(_s) - st.sover) * 0.55
	_vz = clampf(_vz, -_vd * VZ_MAX_FRAC, _vd * VZ_MAX_FRAC)
	_s *= 0.90   # 自旋逐跳衰减（放缓，利于打更远）
	_h = 0.001


func _start_sink() -> void:
	state = State.SINK
	_sink_t = 0.0
	_dist = _d
	_spawn_splash(_d, _z, 0.55)
	_spawn_ripple(_d, _z, _stone())
	_play_sfx("sink")


## 抵达对岸：掌声 + 缓出滑行上岸 → 静止 1.5s → 淡出（State.LAND，结束后结算入榜）
func _reach_far() -> void:
	_d = D_FAR
	_dist = D_FAR
	_h = 0.0
	_spawn_splash(D_FAR - 0.2, _z, 0.5)
	_play_sfx("plop")
	_play_sfx("cheer", 2.0)
	state = State.LAND
	_land_t = 0.0


## 本轮结束：双榜提交 + 结算浮字
func _finish_round() -> void:
	var res: Dictionary = hud.commit_round(_skips, _dist)
	var line: String = hud.t("ui.round_result", "Round: %d skips · %.1f m") % [_skips, _dist]
	_popup(line, Color(0.98, 0.9, 0.55))
	if res.rec_s or res.rec_d:
		var rec: String = hud.t("ui.new_record", "New Record!")
		get_tree().create_timer(0.5).timeout.connect(func() -> void:
			_popup(rec, Color(1.0, 0.85, 0.25)))
		_play_sfx("record")
	state = State.RESULT
	_result_t = 0.0


func _refresh_boards() -> void:
	var ks: String = hud.t("hud.skips", "Skips")
	_skips_board.text = "%s %d" % [ks, _skips]
	_dist_board.text = "%.1f m" % _dist


# ===== 特效 =====

func _spawn_splash(d: float, z: float, inten: float) -> void:
	var p := _proj(d, 0.0, z)
	var k: float = lerpf(1.0, SC_FAR, _u_depth(d))   # 远处水花/液滴随距离缩小
	_splashes.append({"pos": p, "t": 0.0, "sc": clampf(inten, 0.3, 1.4) * k})
	for i in int(6 + inten * 10.0):
		var ang := randf_range(-PI * 0.85, -PI * 0.15)
		var sp := randf_range(120.0, 420.0) * inten * _u * k
		_drops.append({"pos": p + Vector2(0, -4 * _u * k), "vel": Vector2.from_angle(ang) * sp,
				"t": 0.0, "life": randf_range(0.35, 0.7), "r": randf_range(1.6, 3.6) * _u * k})


func _spawn_ripple(d: float, z: float, st: Dictionary) -> void:
	var p := _proj(d, 0.0, z)
	var r0: float = st.r * minf(get_viewport_rect().size.x, get_viewport_rect().size.y) \
			* lerpf(1.0, SC_FAR, _u_depth(d)) * 2.4
	_ripples.append({"pos": p, "r0": maxf(r0, 8.0), "t": 0.0, "life": 0.95})


func _step_fx(delta: float) -> void:
	for r: Dictionary in _ripples:
		r.t += delta
	_ripples = _ripples.filter(func(x: Dictionary) -> bool: return x.t < x.life)
	for dp: Dictionary in _drops:
		dp.t += delta
		dp.vel.y += 820.0 * _u * delta
		dp.pos += dp.vel * delta
	_drops = _drops.filter(func(x: Dictionary) -> bool: return x.t < x.life)
	for bb: Dictionary in _bubbles:
		bb.t += delta
		bb.pos.y -= 46.0 * _u * delta
		bb.pos.x += sin(_time * 6.0 + bb.pos.y * 0.05) * 12.0 * _u * delta
	_bubbles = _bubbles.filter(func(x: Dictionary) -> bool: return x.t < x.life)
	for sp: Dictionary in _splashes:
		sp.t += delta
		if sp.t < SINK_T * 0.5 and state == State.SINK and randf() < 0.35:
			_bubbles.append({"pos": sp.pos + Vector2(randf_range(-8, 8), randf_range(-4, 4)) * _u,
					"vel": Vector2.ZERO, "t": 0.0, "life": randf_range(0.5, 1.0), "r": randf_range(1.5, 3.0) * _u})
	_splashes = _splashes.filter(func(x: Dictionary) -> bool: return x.t < 7.0 * 0.055)
	for pp: Dictionary in _popups:
		pp.t += delta
	_popups = _popups.filter(func(x: Dictionary) -> bool: return x.t < x.life)


func _popup(text: String, col: Color) -> void:
	_popups.append({"text": text, "col": col, "t": 0.0, "life": 1.6})


# ===== 投影（世界坐标 → 屏幕）=====

func _u_depth(d: float) -> float:
	return clampf(d / D_FAR, 0.0, 1.0)   # 线性透视：判定到岸 D_FAR 精确画在对岸水线上（视觉与判定闭环）


## 首段发射偏移：把参数化首段的屏幕起点锚到悬空石片（hover 任意移动，抛物线都跟随），
## 到首落点 D_SPLASH 线性收敛回世界投影（落点与弹跳物理不变）
func _launch_off() -> Vector2:
	return _hover + Vector2(0.0, _aim_lift) - _proj(0.0, _aim_h, 0.0)


func _proj(d: float, h: float, z: float) -> Vector2:
	var vp := get_viewport_rect().size
	var u := _u_depth(d)
	var sc := lerpf(1.0, SC_FAR, u)
	return Vector2(vp.x * 0.5 + z * _zs * sc, lerpf(_y_near, _y_far, u) - h * _hs * sc)


func _stone_px(st: Dictionary, u: float) -> float:
	return st.r * minf(get_viewport_rect().size.x, get_viewport_rect().size.y) * lerpf(1.0, SC_FAR, u)


# ===== 绘制 =====

func _draw() -> void:
	var vp := get_viewport_rect().size
	_draw_sky_far(vp)
	_draw_water(vp)
	_draw_ripples()
	_draw_shore(vp)
	_draw_shadow()
	_draw_preview()
	_draw_splashes()
	_draw_drops()
	_draw_stone()
	_draw_bubbles()
	_draw_rings()
	_draw_popups()


func _draw_sky_far(vp: Vector2) -> void:
	var bush_top := _y_far - vp.y * 0.055   # 对岸带同步压缩
	# 夜空
	draw_rect(Rect2(0, 0, vp.x, bush_top), Color(0.075, 0.115, 0.175))
	draw_rect(Rect2(0, bush_top - vp.y * 0.04, vp.x, vp.y * 0.04), Color(0.10, 0.15, 0.21))
	# 月亮
	draw_circle(Vector2(vp.x * 0.78, bush_top * 0.38), vp.y * 0.028, Color(0.92, 0.93, 0.88, 0.9))
	draw_circle(Vector2(vp.x * 0.78 + vp.y * 0.012, bush_top * 0.38 - vp.y * 0.008), vp.y * 0.024, Color(0.075, 0.115, 0.175, 0.55))
	# 对岸带：深色地被 + 树 + 灌木团
	draw_rect(Rect2(0, bush_top, vp.x, _y_far - bush_top), Color(0.10, 0.16, 0.12))
	for tr: Dictionary in _trees:
		var trunk := Vector2(tr.x, _y_far - 2.0)
		draw_line(Vector2(trunk.x - 1.5 * _u, trunk.y), Vector2(trunk.x - 1.0 * _u, tr.top + tr.r * 0.6),
				Color(0.16, 0.11, 0.07), 4.0 * _u)
		draw_circle(Vector2(trunk.x - 1.2 * _u, tr.top + tr.r * 0.35), tr.r, Color(0.13, 0.23, 0.14))
		draw_circle(Vector2(trunk.x - 1.2 * _u - tr.r * 0.4, tr.top + tr.r * 0.75), tr.r * 0.6, Color(0.16, 0.27, 0.16))
		draw_circle(Vector2(trunk.x - 1.2 * _u + tr.r * 0.42, tr.top + tr.r * 0.8), tr.r * 0.55, Color(0.11, 0.20, 0.12))
	for b: Dictionary in _bushes:
		var col := Color(0.14 + b.col * 0.07, 0.24 + b.col * 0.10, 0.13 + b.col * 0.05)
		draw_circle(b.pos, b.r, col)
		draw_circle(b.pos + Vector2(b.r * 0.7, b.r * 0.25), b.r * 0.7, col * Color(0.9, 1.05, 0.9))
	# 对岸水线 + 岸侧倒影
	draw_rect(Rect2(0, _y_far - 2.0 * _u, vp.x, 2.5 * _u), Color(0.20, 0.30, 0.24, 0.8))
	draw_rect(Rect2(0, _y_far + 2.0 * _u, vp.x, vp.y * 0.014), Color(0.10, 0.19, 0.16, 0.30))


func _draw_water(vp: Vector2) -> void:
	# 蓝绿水面：单块四边形顶点色渐变（远亮近深）——离散横带会在每条带交界留台阶横线，半透明重叠更明显
	var top := Color(0.16, 0.44, 0.46, 0.62)
	var bot := Color(0.21, 0.34, 0.38, 0.62)
	draw_polygon(
			PackedVector2Array([Vector2(0, _y_far), Vector2(vp.x, _y_far), Vector2(vp.x, _y_near), Vector2(0, _y_near)]),
			PackedColorArray([top, top, bot, bot]))
	# 波光横线（缓移虚线，近大远小）
	for sm: Dictionary in _shimmer:
		var y := lerpf(_y_far + 10.0 * _u, _y_near - 10.0 * _u, sm.frac)
		var w: float = lerpf(30.0, 90.0, sm.frac) * _u * sm.amp
		var span: float = vp.x + w
		var x0: float = fmod(_time * sm.sp * _u + sm.ph * 300.0, span) - w
		var a := 0.10 + 0.05 * sin(_time * 1.7 + sm.ph)
		while x0 < vp.x:
			draw_line(Vector2(x0, y), Vector2(x0 + w * 0.55, y), Color(0.75, 0.95, 0.97, a), 2.0 * _u)
			x0 += span / 3.0


func _draw_shore(vp: Vector2) -> void:
	# 近岸碎石滩
	draw_rect(Rect2(0, _y_near, vp.x, vp.y - _y_near), Color(0.36, 0.33, 0.29))
	draw_rect(Rect2(0, _y_near, vp.x, 7.0 * _u), Color(0.44, 0.42, 0.37))   # 湿沙边
	for pb: Dictionary in _pebbles:
		draw_set_transform(pb.pos, pb.rot, Vector2(1.0, pb.asp))
		draw_circle(Vector2.ZERO, pb.r, pb.col)
		draw_arc(Vector2.ZERO, pb.r, 0.0, TAU, 12, pb.col * Color(0.55, 0.55, 0.6), 1.6 * _u)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_ripples() -> void:
	for r: Dictionary in _ripples:
		var k: float = r.t / r.life
		var rad: float = r.r0 * (0.35 + 0.9 * k)
		var a: float = (1.0 - k) * 0.75
		draw_set_transform(r.pos, 0.0, Vector2(1.0, 0.32))
		draw_arc(Vector2.ZERO, rad, 0.0, TAU, 32, Color(0.8, 0.97, 1.0, a), 2.4 * _u)
		draw_arc(Vector2.ZERO, rad * 0.55, 0.0, TAU, 24, Color(0.8, 0.97, 1.0, a * 0.6), 1.8 * _u)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_shadow() -> void:
	# 飞行石片的水面投影（判定落点的关键参照）
	if state != State.FLY:
		return
	var p := _proj(_d, 0.0, _z)
	var st := _stone()
	var a: float = clampf(0.30 - _h * 0.05, 0.06, 0.30)
	var rr: float = _stone_px(st, _u_depth(_d)) * (1.0 + _h * 0.12)
	draw_set_transform(p, 0.0, Vector2(1.0, 0.32))
	draw_circle(Vector2.ZERO, rr, Color(0.0, 0.1, 0.12, a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 预览抛物线：首段落点固定 D_SPLASH（蓄力不变落点），画投影虚点 + 落点判定环
func _draw_preview() -> void:
	if state != State.AIM and state != State.CHARGE:
		return
	var st := _stone()
	var pw := _power if state == State.CHARGE else 1.0
	var arc := lerpf(ARC_HI, ARC_LO, clampf(pw / SWEET_FRAC, 0.0, 1.0))
	var pts := PackedVector2Array()
	var off := _launch_off()
	for i in 40:
		var u := (float(i) + 1.0) / 40.0
		pts.append(_proj(0.02 + (D_SPLASH - 0.02) * u,
				_aim_h * (1.0 - u) + arc * u * (1.0 - u), 0.0) + off * (1.0 - u))
	var n := pts.size()
	for i in n:
		var uu := float(i) / maxf(n - 1.0, 1.0)
		draw_circle(pts[i], lerpf(4.5, 2.0, uu) * _u, Color(1.0, 1.0, 1.0, lerpf(0.85, 0.25, uu)))
	# 落点判定环（位置固定）：绿=会起跳 / 红=会沉（与 _contact 同公式）
	var vd_in: float = V_IN * (0.8 + 0.5 * minf(pw, SWEET_FRAC)) * (1.10 - 0.10 * st.m)
	var vh_in := (_aim_h + arc) / T_VH
	var phi0 := atan2(vh_in, vd_in)
	var phi_max: float = lerpf(0.16, 0.52, st.flat) + (st.buoy - 0.5) * 0.30
	var ok: bool = phi0 <= phi_max and vd_in >= 1.5 + st.m * 0.55 and absf(_spin) >= st.sneed
	var col := Color(0.35, 0.95, 0.5, 0.9) if ok else Color(0.98, 0.3, 0.25, 0.9)
	var rr: float = _stone_px(st, _u_depth(D_SPLASH)) * 1.5
	draw_set_transform(_proj(D_SPLASH, 0.0, 0.0), 0.0, Vector2(1.0, 0.32))
	draw_arc(Vector2.ZERO, rr, 0.0, TAU, 24, col, 2.6 * _u)
	draw_arc(Vector2.ZERO, rr * 0.5, 0.0, TAU, 16, Color(col.r, col.g, col.b, 0.5), 2.0 * _u)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_splashes() -> void:
	for sp: Dictionary in _splashes:
		var frame := int(sp.t / 0.055)
		if frame > 6:
			continue
		var tex: Texture2D = _tex.get("splash_%d" % frame)
		if tex == null:
			continue
		var sz: float = 160.0 * sp.sc * _u
		draw_texture_rect(tex, Rect2(sp.pos - Vector2(sz * 0.5, sz * 0.72), Vector2(sz, sz)), false)


func _draw_drops() -> void:
	for dp: Dictionary in _drops:
		var a: float = 1.0 - dp.t / dp.life
		draw_circle(dp.pos, dp.r, Color(0.82, 0.95, 1.0, a * 0.85))


func _draw_bubbles() -> void:
	for bb: Dictionary in _bubbles:
		var a: float = 1.0 - bb.t / bb.life
		draw_arc(bb.pos, bb.r, 0.0, TAU, 10, Color(0.85, 0.98, 1.0, a * 0.8), 1.4 * _u)


func _draw_stone() -> void:
	var st := _stone()
	var tex: Texture2D = _tex.get(st.tex)
	var pos: Vector2
	var rot := 0.0
	var alpha := 1.0
	var sc_u := 1.0               # 出手放大倍率（准备状态 ×4/3，丢出后逐渐缩回 1）
	match state:
		State.SELECT:
			return   # 选石面板时主石片不画
		State.AIM, State.CHARGE:
			pos = _hover + Vector2(0.0, _aim_lift + sin(_time * 2.2) * 5.0 * _u)   # 悬空浮动（随瞄准升降）
			sc_u = STONE_READY_SCALE   # 准备状态显示倍率（原 ×2，已缩小 1/3）
			if state == State.CHARGE:
				pos += Vector2(randf_range(-1, 1), randf_range(-1, 1)) * 2.4 * _u * _power   # 蓄力颤抖
				rot = sin(_time * 18.0) * 0.04 * _power
		State.FLY:
			pos = _proj(_d, _h, _z)
			pos += _launch_off() * (1.0 - clampf(_d / D_SPLASH, 0.0, 1.0))   # 首段起点锚定悬空点，到首落点收敛
			rot = _rot
			sc_u = lerpf(STONE_READY_SCALE, 1.0, clampf(_d / D_SPLASH, 0.0, 1.0))   # 丢出后到首落点逐渐缩小回正常
		State.SINK:
			# 侧翻下沉
			var k := _sink_t / SINK_T
			pos = _proj(_d, -k * 0.55, _z)
			rot = signf(_s if _s != 0.0 else 1.0) * k * PI * 0.45
			alpha = 1.0 - k * 0.92
			sc_u = lerpf(STONE_READY_SCALE, 1.0, clampf(_d / D_SPLASH, 0.0, 1.0))
		State.LAND:
			# 上岸：u>1 越过对岸水线滑行 → 静止 → 淡出（_u_depth 有 clamp，此处手算投影）
			var lu := _d / D_FAR
			var lsc := lerpf(1.0, SC_FAR, lu)
			var lvp := get_viewport_rect().size
			pos = Vector2(lvp.x * 0.5 + _z * _zs * lsc, lerpf(_y_near, _y_far, lu))
			rot = _rot   # 冻结落地姿态
			alpha = clampf(1.0 - (_land_t - LAND_SLIDE_T - LAND_REST_T) / LAND_FADE_T, 0.0, 1.0)
		State.RESULT:
			return
	if tex == null:
		# 兜底：程序灰扁石
		var px := _stone_px(st, _u_depth(_d)) * sc_u
		draw_circle(pos, px, Color(0.68, 0.72, 0.75, alpha))
		return
	var s := 2.0 * _stone_px(st, _u_depth(_d)) * sc_u / 116.0   # 内容最长边 116 → 显示直径 2r
	draw_set_transform(pos, rot, Vector2(s, s))
	draw_texture(tex, Vector2(-64, -64), Color(1, 1, 1, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 自旋环形箭头（尾在下方，长度随自旋，最长绕满一圈）+ 三瞄准槽（左蓄力/右高度/下自旋）
func _draw_rings() -> void:
	var st := _stone()
	if state != State.AIM and state != State.CHARGE:
		return
	var px := _stone_px(st, 0.0) * STONE_READY_SCALE   # 与准备状态石片尺寸匹配（同步缩小）
	var hc := _hover + Vector2(0.0, _aim_lift)   # 环形指示中心（随瞄准升降）
	# 自旋箭头（鼠标右半=顺时针 / 左半=逆时针，长度随自旋，最长绕满一圈）
	var sr := absf(_spin) / 2.5
	if sr > 0.02:
		var rr := px + 17.0 * _u
		var col := Color(0.5, 0.9, 1.0, 0.9)
		draw_arc(hc, rr, 0.0, TAU, 48, Color(0.5, 0.9, 1.0, 0.15), 2.2 * _u)
		var len := sr * (TAU - 0.10)
		var cw := _spin >= 0.0
		var start := PI / 2.0
		var end_ang := PI / 2.0 + (len if cw else -len)
		# 弧段始终从小角画到大角；逆时针时区间为 [PI/2-len, PI/2]，箭头在起始端
		draw_arc(hc, rr, minf(start, end_ang), maxf(start, end_ang), 8 + int(48.0 * sr), col, 3.4 * _u)
		var head_ang := end_ang if cw else start - len   # 箭头所在角度（前进端）
		var travel := Vector2.from_angle(head_ang + (PI / 2.0 if cw else -PI / 2.0))
		var radial := Vector2.from_angle(head_ang)
		var p1 := hc + Vector2.from_angle(head_ang) * rr
		draw_colored_polygon(PackedVector2Array([
			p1 + travel * 10.0 * _u,
			p1 - travel * 4.0 * _u - radial * 3.0 * _u,
			p1 - travel * 4.0 * _u + radial * 3.0 * _u,
		]), col)
	# —— 三瞄准槽：左竖=蓄力（从下往上充，蓄满自动丢）、右竖=出手高度、下横=自旋（从中心向鼠标侧充）
	#    金线=80% 完美点；填充超过 80% 的部分变警示色（过火提示） ——
	var sl := 110.0 * _u             # 槽长
	var sth := 9.0 * _u              # 槽厚
	var gap := px + 42.0 * _u        # 槽与石片中心间距
	var slot_bg := Color(1, 1, 1, 0.10)
	var slot_fg := Color(1, 1, 1, 0.78)
	var slot_over := Color(1.0, 0.42, 0.30, 0.9)   # 过火警示色
	var perfect := Color(1.0, 0.82, 0.25, 0.95)
	var vslot_w := sth + 8.0 * _u    # 竖槽金线加宽后的总宽
	var hy0 := hc.y - sl * 0.5       # 竖槽顶（蓄力/高度共用）
	# 蓄力槽（左）：5s 蓄满自动丢；金线 80%（=4s）处为完美点
	var cx := hc.x - gap - sth
	draw_rect(Rect2(cx, hy0, sth, sl), slot_bg)
	draw_rect(Rect2(cx, hy0 + sl * (1.0 - minf(_power, SWEET_FRAC)), sth, sl * minf(_power, SWEET_FRAC)), slot_fg)
	if _power > SWEET_FRAC:
		draw_rect(Rect2(cx, hy0 + sl * (1.0 - _power), sth, sl * (_power - SWEET_FRAC)), slot_over)
	draw_rect(Rect2(cx - 4.0 * _u, hy0 + sl * (1.0 - SWEET_FRAC) - 1.2 * _u, vslot_w, 2.4 * _u), perfect)
	# 高度槽（右）：yr 越大充得越高；金线 80% 精确对应完美出手高度 0.955m
	var hx := hc.x + gap
	draw_rect(Rect2(hx, hy0, sth, sl), slot_bg)
	draw_rect(Rect2(hx, hy0 + sl * (1.0 - minf(_fill_h, SWEET_FRAC)), sth, sl * minf(_fill_h, SWEET_FRAC)), slot_fg)
	if _fill_h > SWEET_FRAC:
		draw_rect(Rect2(hx, hy0 + sl * (1.0 - _fill_h), sth, sl * (_fill_h - SWEET_FRAC)), slot_over)
	draw_rect(Rect2(hx - 4.0 * _u, hy0 + sl * (1.0 - SWEET_FRAC) - 1.2 * _u, vslot_w, 2.4 * _u), perfect)
	# 自旋槽（下）：从中心向鼠标方向充，左=逆时针右=顺时针；金线=80% 格（两侧；低出手时贴屏底）
	var sy := minf(hc.y + gap, get_viewport_rect().size.y - sth - 6.0 * _u)
	var sx0 := hc.x - sl * 0.5
	draw_rect(Rect2(sx0, sy, sl, sth), slot_bg)
	var xf := absf(_fill_x)
	var w_main := sl * 0.5 * minf(xf, SWEET_FRAC)
	if _fill_x >= 0.0:
		draw_rect(Rect2(hc.x, sy, w_main, sth), slot_fg)
	else:
		draw_rect(Rect2(hc.x - w_main, sy, w_main, sth), slot_fg)
	if xf > SWEET_FRAC:
		var w_over := sl * 0.5 * (xf - SWEET_FRAC)
		if _fill_x >= 0.0:
			draw_rect(Rect2(hc.x + sl * 0.5 * SWEET_FRAC, sy, w_over, sth), slot_over)
		else:
			draw_rect(Rect2(hc.x - sl * 0.5 * SWEET_FRAC - w_over, sy, w_over, sth), slot_over)
	for sgn: int in [-1, 1]:
		var pxs := hc.x + float(sgn) * sl * 0.5 * SWEET_FRAC
		draw_rect(Rect2(pxs - 1.2 * _u, sy - 4.0 * _u, 2.4 * _u, sth + 8.0 * _u), perfect)


func _draw_popups() -> void:
	var vp := get_viewport_rect().size
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


# ===== 输入 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and state == State.AIM:
			state = State.CHARGE
			_power = 0.0
		elif not mb.pressed and state == State.CHARGE:
			_throw()


# ===== 音效（程序合成：正弦滑音 + 低通噪声）=====

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


func _init_sfx() -> void:
	_sfx["throw"] = _sfx_stream([["n", 0.16, 0.32, 4.0], ["t", 260.0, 880.0, 0.16, false, 0.28]])
	_sfx["plink"] = _sfx_stream([["t", 760.0, 380.0, 0.07, false, 0.5], ["n", 0.05, 0.3, 3.0]])
	_sfx["plink2"] = _sfx_stream([["t", 600.0, 300.0, 0.08, false, 0.5], ["n", 0.06, 0.32, 2.5]])
	_sfx["plink3"] = _sfx_stream([["t", 460.0, 230.0, 0.09, false, 0.5], ["n", 0.07, 0.34, 2.0]])
	_sfx["splash"] = _sfx_stream([["n", 0.34, 0.6, 2.0], ["t", 160.0, 60.0, 0.2, false, 0.4]])
	_sfx["sink"] = _sfx_stream([["t", 300.0, 80.0, 0.5, false, 0.45], ["n", 0.45, 0.3, 6.0]])
	_sfx["plop"] = _sfx_stream([["t", 220.0, 110.0, 0.12, true, 0.4], ["n", 0.08, 0.3, 3.0]])
	_sfx["pick"] = _sfx_stream([["t", 520.0, 780.0, 0.09, false, 0.35]])
	_sfx["record"] = _sfx_stream([["t", 523.0, 523.0, 0.09, false, 0.35], ["t", 659.0, 659.0, 0.09, false, 0.35], ["t", 784.0, 784.0, 0.18, false, 0.4]])
	# 掌声（取自投篮游戏 crowd_cheer.mp3）：pck 内 mp3 无导入资源，字节解码（双路径）
	for base: String in ["res://games/stone_skip/assets/sfx/crowd_cheer.mp3", "res://assets/sfx/crowd_cheer.mp3"]:
		var cf := FileAccess.open(base, FileAccess.READ)
		if cf != null:
			_sfx_mp3["cheer"] = AudioStreamMP3.load_from_buffer(cf.get_buffer(cf.get_length()))
			break
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（与其他游戏共用曲目；读取失败则无 BGM）
	for base: String in ["res://games/stone_skip/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## 播放音效：plink 按弹跳强度选变体（轻=高音），其余按名播放
func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if sfx_name == "plink":
		var r := randi() % 3
		sfx_name = "plink%d" % (r + 1)
	var stream: AudioStream = _sfx.get(sfx_name)
	if stream == null:
		stream = _sfx_mp3.get(sfx_name)
	if stream == null:
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db + SFX_DB
			p.play()
			return
