extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 完美拍照（Perfect Snap）：程序生成一幅大幅动态公园全景（静态景物 + 固定轨迹循环运动的
## 动态元素），右上角给出目标取景缩略图（含元素种类/坐标/动画相位记录）。玩家操控取景
## 相机：按住左键拖动平移、底部按钮/滚轮缩放（7 档）、点快门或空格拍照；系统把当前视野
## 内的元素数据与目标记录做逻辑比对（非像素比对），输出匹配百分比与评级：
## ≥85 完美 / 68-84 优秀 / 45-67 合格 / <45 不合格。
## 保证可达成：目标即真实区域+真实时刻的快照；目标框宽高比恒等于相机宽高比（窗口
## resize 自动重生成目标），动态元素周期均整除 60s（天空小循环 ≤10s），等待必能对齐。
## 取景框恒占屏幕 70%（宽高各 70% 居中），框外画面被遮罩压暗（相机取景器效果）。
## 存档复用合集 GameHud：排行榜记录本局最高匹配度；结算弹窗提供「重拍 / 下一关」。

const GameHud := preload("res://scripts/game_hud.gd")

# ===== 可配置参数 =====
const PARK_W := 16640.0              # 全景宽（世界像素，4 个分区横向拼接）
const PARK_H := 2340.0               # 全景高（世界像素，16:9）
const SKY_H := 600.0                 # 天空带高度（约 PARK_H 的 1/4）
const SECTION_W := 4160.0            # 单分区宽（公园由 4 个风格各异的主题分区拼接：游乐区/市集区/野趣区/湖畔区）
const VIEW_FRAC := 0.70              # 取景框占屏幕比例（宽高各 70%，居中；框外遮罩压暗）
const ZOOM_FRACS := [0.24, 0.30, 0.37, 0.45, 0.55, 0.66, 0.78]  # 7 档视野高占全景比（0.45=默认档）
const ZOOM_START := 3                # 初始缩放档位下标（7 档的中档）
const ZOOM_W := [0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3, 4, 4, 4, 5, 5, 6]  # 目标图缩放档随机权重（各档均出现，中档加权）
const SPEED_SCALE := 1.0             # 元素移动速度全局倍率
const KEY_PAN_SPD := 0.7             # 方向键平移速度（×视野宽/秒）
const MATCH_W_KIND := 0.45           # 匹配权重：元素种类
const MATCH_W_POS := 0.35            # 匹配权重：位置偏差
const MATCH_W_STATE := 0.20          # 匹配权重：动态状态（相位）
const POS_TOL := 0.80                # 位置偏差容差（视野尺寸归一化）
const PHASE_TOL := 0.35              # 动态相位容差（循环 0..1）
const ZOOM_MISS := 0.10              # 缩放档每差 1 档的位置分惩罚
const RATE_PERFECT := 85             # 完美评级阈值
const RATE_GREAT := 68               # 优秀评级阈值
const RATE_GOOD := 45                # 合格评级阈值（存档下限）
const SCORE_PERFECT := 1000          # 完美得分
const SCORE_GREAT := 600             # 优秀得分
const SCORE_GOOD := 300              # 合格得分
const COMBO_BONUS := 200             # 完美连击每次额外加分
const LANDMARK_MIN := 4              # 目标区标志性元素数量下限
const DYN_MIN := 2                   # 目标区动态元素数量下限
const TARGET_MIN := 8                # 目标区元素总数下限
const TARGET_DIST := 900.0           # 相邻两次目标中心最小间距
const THUMB_W := 224                 # 缩略图宽（px，高按相机宽高比自适应）
const TOP_H := 86.0                  # 顶栏高度
const OUT_W := 4.0                   # 世界元素描边宽（世界像素）
const FLASH_T := 0.52                # 快门白闪时长（s）
const RESULT_DELAY := 0.3            # 拍照到弹结算的延迟（s）
const SFX_POOL := 4
const BGM_DB := -12.0
const SFX_DB := -4.0

# ===== 配色（扁平卡通，纯色 + 深描边，对齐合集风格） =====
const COL_OUT := Color(0.13, 0.11, 0.10)
const COL_SKY := Color(0.62, 0.85, 0.95)
const COL_SUN := Color(1.0, 0.84, 0.35)
const COL_SUN_RAY := Color(1.0, 0.72, 0.30)
const COL_CLOUD := Color(1, 1, 1)
const COL_GRASS := Color(0.49, 0.76, 0.31)
const COL_GRASS_L := Color(0.56, 0.82, 0.36)
const COL_HILL := Color(0.60, 0.80, 0.42)
const COL_SHADOW := Color(0.20, 0.40, 0.15, 0.22)
const COL_PATH := Color(0.85, 0.76, 0.55)
const COL_TRUNK := Color(0.55, 0.38, 0.22)
const COL_LEAF := Color(0.36, 0.66, 0.30)
const COL_LEAF_L := Color(0.46, 0.74, 0.36)
const COL_BANYAN := Color(0.28, 0.56, 0.27)
const COL_BUSH := Color(0.30, 0.60, 0.28)
const COL_WOOD := Color(0.72, 0.50, 0.28)
const COL_WOOD_D := Color(0.55, 0.36, 0.19)
const COL_KIOSK := Color(0.95, 0.87, 0.70)
const COL_AWNING := Color(0.90, 0.35, 0.30)
const COL_AWNING2 := Color(0.98, 0.96, 0.92)
const COL_GLASS := Color(0.45, 0.62, 0.72)
const COL_LAMP := Color(1.0, 0.90, 0.55)
const COL_POLE := Color(0.35, 0.40, 0.42)
const COL_SOIL := Color(0.52, 0.37, 0.24)
const COL_SLIDE := Color(0.95, 0.55, 0.20)
const COL_METAL := Color(0.55, 0.60, 0.65)
const COL_BIN := Color(0.42, 0.65, 0.45)
const COL_SIGN := Color(0.90, 0.83, 0.62)
const COL_STONE := Color(0.72, 0.72, 0.70)
const COL_STONE_D := Color(0.60, 0.60, 0.58)
const COL_FENCE := Color(0.93, 0.89, 0.80)
const COL_PANTS := Color(0.30, 0.34, 0.45)
const COL_BEE := Color(1.0, 0.82, 0.20)
const COL_PLANE := Color(0.95, 0.96, 0.98)
const COL_PLANE_R := Color(0.90, 0.32, 0.30)
const COL_SAND := Color(0.94, 0.86, 0.60)
const COL_SAND_D := Color(0.84, 0.74, 0.46)
const COL_BARREL := Color(0.78, 0.56, 0.32)
const COL_UM1 := Color(0.92, 0.42, 0.36)
const COL_UM2 := Color(0.98, 0.96, 0.90)
const COL_STUMP := Color(0.80, 0.62, 0.38)
const COL_SQ := Color(0.72, 0.48, 0.26)
const COL_SQ_D := Color(0.58, 0.37, 0.19)
const COL_PIG := Color(0.82, 0.82, 0.84)
const COL_KITE := Color(0.92, 0.35, 0.40)
const COL_WATER := Color(0.42, 0.68, 0.87)   # 湖水
const COL_WATER_L := Color(0.60, 0.79, 0.93) # 湖水高光
const COL_WILLOW := Color(0.40, 0.66, 0.32)  # 垂柳
const COL_REED := Color(0.47, 0.64, 0.30)    # 芦苇
const COL_LOTUS := Color(0.95, 0.60, 0.74)   # 荷花
const COL_SWAN := Color(0.97, 0.96, 0.92)    # 天鹅
const COL_DUCK := Color(0.72, 0.44, 0.16)    # 野鸭
const COL_R_PERFECT := Color(1.0, 0.85, 0.25)
const COL_R_GREAT := Color(0.30, 0.85, 0.40)
const COL_R_GOOD := Color(0.40, 0.70, 1.0)
const COL_R_FAIL := Color(0.92, 0.25, 0.20)

const SHIRTS := [Color(0.90,0.35,0.30), Color(0.30,0.50,0.85), Color(1.0,0.80,0.25),
		Color(0.35,0.75,0.40), Color(0.65,0.45,0.85), Color(0.95,0.55,0.25), Color(0.30,0.70,0.70)]
const SKINS := [Color(1.0,0.87,0.72), Color(0.94,0.78,0.62), Color(0.82,0.62,0.45)]
const FLOWERS := [Color(0.95,0.45,0.55), Color(1.0,0.85,0.30), Color(0.98,0.98,0.95), Color(0.75,0.55,0.90)]
const DOG_COLS := [Color(0.85,0.62,0.35), Color(0.90,0.88,0.82), Color(0.45,0.32,0.22)]
const KITE_COLS := [Color(0.92,0.35,0.40), Color(0.30,0.55,0.90), Color(1.0,0.72,0.25)]
const BIRD_COLS := [Color(0.55,0.70,0.90), Color(0.90,0.60,0.35), Color(0.60,0.60,0.65), Color(0.85,0.80,0.70)]
const BALLOON_COLS := [Color(0.90,0.40,0.40), Color(0.35,0.65,0.85), Color(0.95,0.70,0.30), Color(0.55,0.75,0.45)]
const RATE_KEYS := ["ps.rating_fail", "ps.rating_good", "ps.rating_great", "ps.rating_perfect"]
const RATE_COLS := [COL_R_FAIL, COL_R_GOOD, COL_R_GREAT, COL_R_PERFECT]
const RATE_SCORES := [0, SCORE_GOOD, SCORE_GREAT, SCORE_PERFECT]
const LANDMARKS := ["banyan", "tree", "bench", "kiosk", "lamp", "bed", "slide", "swing", "bin", "sign", "stone", "sun",
		"seesaw", "sandbox", "stall", "barrel", "umbrella", "stump", "log", "lake", "willow", "bridge", "fountain"]

## 目标图记录：一次拍照判定的全部依据（区域 + 逐元素快照）
class Target:
	var rect := Rect2()
	var zoom_i := 0
	var items: Array = []   # {pos, ph, d_idx(动态下标,-1=静态), kind, no_state}

## 场景画笔：主画面（跟随相机）/ 屏幕特效层 / 缩略图（冻结相位）共用脚本，按 mode 分流
class Painter extends Node2D:
	var g: Node2D
	var mode := "world"        # world / fx / thumb
	var clip := Rect2()        # 裁剪矩形（世界坐标）
	var phase_ovr := {}        # 动态下标 → 固定相位（缩略图冻结用）
	func _draw() -> void:
		if g == null:
			return
		if mode == "fx":
			g._draw_scene_fx(self)
		else:
			g._draw_scene(self)

var hud: RefCounted
var score := 0                      # 本局得分
var run_best := 0                   # 本局最高匹配度
var _streak := 0                    # 完美连击数
var _elapsed := 0.0                 # 本局已过时间
var _zoom_idx := ZOOM_START
var _cam := Rect2()                 # 相机视野（世界坐标）
var _dragging := false
var _drag_m0 := Vector2.ZERO
var _drag_c0 := Vector2.ZERO
var _paths: Array = []              # {pts, cum, len, w}
var _statics: Array = []            # 静态元素
var _hills: Array = []
var _patches: Array = []
var _daisies: Array = []
var _dyns: Array = []               # 动态元素（t 累计，st 为当帧状态缓存）
var _target: Target
var _last_center := Vector2(-1e9, -1e9)
var _world: Painter
var _fx: Painter
var _vp_t: SubViewport              # 目标图缩略渲染
var _vp_c: SubViewport              # 拍照缩略渲染
var _flash_t := -1.0
var _result_t := -1.0
var _pending := {}
var _popup: PanelContainer
var _press := {}                    # 工具按钮按压反馈 {id: 剩余s}
var _tool := {}                     # 底部工具栏圆钮 {shutter/zoom_in/zoom_out: Vector2}
var _time_shown := ""
var _started := false               # start() 完成前，_process/_input 不介入
var _pv_panel: PanelContainer
var _pv_rect: TextureRect
var _pv_label: Label
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _hbox: HBoxContainer
var _lb_btn: Button
var _restart_btn: Button
var _bgm_btn: Button
var _volume_btn: Button

@onready var _time_board: Label = $HudBar/TimeBoard
@onready var _score_board: Label = $HudBar/ScoreBoard
@onready var _best_board: Label = $HudBar/BestBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("perfect_snap")
	get_viewport().size_changed.connect(_layout)
	_build_park()
	_setup_painters()
	_setup_buttons()          # 先建按钮再布局（_layout 会定位）
	_setup_preview()
	_layout()
	_init_sfx()
	_apply_cam()
	_gen_target()
	_refresh_hud()
	_started = true


func stop() -> void:
	get_tree().paused = false  # 弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	_commit_run()
	print("[perfect_snap] stop, score=%d best_match=%d%% all_time=%d%%" % [score, run_best, hud.max_score])


## 本局结束：把本局最高匹配度入排行榜（最高匹配度同时已实时落盘）
func _commit_run() -> void:
	if run_best > 0:
		hud.submit_score(run_best)
	hud.commit_score()


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 主循环 =====

func _process(delta: float) -> void:
	if not _started or get_tree().paused:
		return
	_elapsed += delta
	for e in _dyns:
		e.t += delta * SPEED_SCALE / e.period
		e.st = _dyn_state(e, fposmod(e.t, 1.0))
	# 方向键平移
	var pan := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		pan.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		pan.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		pan.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		pan.y += 1.0
	if pan != Vector2.ZERO:
		_cam.position += pan * _cam.size.x * KEY_PAN_SPD * delta
		_apply_cam()
	# 计时器
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash_t = -1.0
	if _result_t > 0.0:
		_result_t -= delta
		if _result_t <= 0.0:
			_result_t = -1.0
			_show_result(_pending)
	for k in _press.keys():
		_press[k] -= delta
		if _press[k] <= 0.0:
			_press.erase(k)
	# 鼠标悬停工具栏换手型
	var mp := get_viewport().get_mouse_position()
	if not _dragging:
		if mp.distance_to(_tool.get("shutter", Vector2(-1e3, -1e3))) <= 56.0 \
				or mp.distance_to(_tool.get("zoom_in", Vector2(-1e3, -1e3))) <= 40.0 \
				or mp.distance_to(_tool.get("zoom_out", Vector2(-1e3, -1e3))) <= 40.0:
			Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)
		else:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_world.queue_redraw()
	_fx.queue_redraw()
	_refresh_time()


func _unhandled_input(event: InputEvent) -> void:
	if not _started:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var mp: Vector2 = event.position
				if mp.distance_to(_tool.get("shutter", Vector2(-1e3, -1e3))) <= 56.0:
					_press["shutter"] = 0.14
					_do_shutter()
					return
				if mp.distance_to(_tool.get("zoom_in", Vector2(-1e3, -1e3))) <= 40.0:
					_press["zoom_in"] = 0.14
					_set_zoom(_zoom_idx - 1)
					return
				if mp.distance_to(_tool.get("zoom_out", Vector2(-1e3, -1e3))) <= 40.0:
					_press["zoom_out"] = 0.14
					_set_zoom(_zoom_idx + 1)
					return
				_dragging = true
				_drag_m0 = mp
				_drag_c0 = _cam.get_center()
			else:
				_dragging = false
		elif event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_set_zoom(_zoom_idx - 1)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_set_zoom(_zoom_idx + 1)
	elif event is InputEventMouseMotion and _dragging:
		var s: float = _vf_rect().size.x / _cam.size.x
		_cam.position = _drag_c0 - (event.position - _drag_m0) / s - _cam.size * 0.5
		_apply_cam()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_do_shutter()
		elif event.keycode == KEY_R:
			_restart()


## ===== 相机 =====

## 取景框（屏幕坐标）：恒占屏幕 70%，居中
func _vf_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var sz := vp * VIEW_FRAC
	return Rect2((vp - sz) * 0.5, sz)


func _apply_cam() -> void:
	var vf := _vf_rect()
	var half := _cam.size * 0.5
	var c := _cam.get_center().clamp(half, Vector2(PARK_W, PARK_H) - half)
	_cam.position = c - half
	var s := vf.size.x / _cam.size.x
	_world.scale = Vector2(s, s)
	_world.position = vf.position - _cam.position * s
	# 框外多留一圈画布，让遮罩下能看到压暗的场景延续（取景器渐晕效果）
	_world.clip = _cam.grow(480.0)


func _set_zoom(idx: int) -> void:
	var i := clampi(idx, 0, ZOOM_FRACS.size() - 1)
	if i == _zoom_idx:
		return
	var c := _cam.get_center()
	var vh: float = PARK_H * ZOOM_FRACS[i]
	var vp := get_viewport_rect().size
	var vw: float = minf(vh * vp.x / vp.y, PARK_W)
	_zoom_idx = i
	_cam = Rect2(c - Vector2(vw, vh) * 0.5, Vector2(vw, vh))
	_apply_cam()


func _zoom_size(idx: int) -> Vector2:
	var vh: float = PARK_H * ZOOM_FRACS[idx]
	var vp := get_viewport_rect().size
	return Vector2(minf(vh * vp.x / vp.y, PARK_W), vh)


## ===== 全景生成 =====

## 路径折线（闭环保留首点重合）：预计算累计长度
func _add_path(pts: PackedVector2Array, w: float) -> void:
	var cum := PackedFloat32Array()
	cum.append(0.0)
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
		cum.append(total)
	_paths.append({"pts": pts, "cum": cum, "len": total, "w": w})


func _path_point(idx: int, dist: float) -> Dictionary:
	var p: Dictionary = _paths[idx]
	var d := fposmod(dist, p.len)
	var pts: PackedVector2Array = p.pts
	var cum: PackedFloat32Array = p.cum
	for i in range(1, pts.size()):
		if d <= cum[i] or i == pts.size() - 1:
			var t := (d - cum[i - 1]) / maxf(cum[i] - cum[i - 1], 0.001)
			return {"pos": pts[i - 1].lerp(pts[i], t), "tan": (pts[i] - pts[i - 1]).normalized()}
	return {"pos": pts[0], "tan": Vector2.RIGHT}


## 折线往返（猫/店员踱步）
func _ppos(a: Vector2, b: Vector2, ph: float) -> Dictionary:
	var u := 1.0 - absf(1.0 - 2.0 * fposmod(ph, 1.0))
	return {"pos": a.lerp(b, u), "face": 1.0 if fposmod(ph, 1.0) < 0.5 else -1.0}


## 动态元素状态（纯函数：主画面每帧缓存 / 缩略图按记录相位冻结）
func _dyn_state(e: Dictionary, ph: float) -> Dictionary:
	match e.kind:
		"cloud":
			return {"pos": e.anchor + Vector2(e.amp * sin(TAU * fposmod(ph, 1.0)), 9.0 * sin(TAU * fposmod(ph * 2.0, 1.0)))}
		"bird":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.3)
			var flap := 0.5 + 0.5 * sin(TAU * fposmod(ph * e.flap_mul, 1.0))
			return {"pos": pos, "face": signf(cos(a)) if absf(cos(a)) > 0.05 else 1.0, "flap": flap}
		"plane":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.28)
			var dx := -sin(a)
			var f := signf(dx) if absf(dx) > 0.05 else 1.0
			# 局部系俯仰角：上飞抬头、下飞低头（镜像后取反保证世界方向正确）
			var ang := clampf(atan2(cos(a) * e.r * 0.28, absf(dx) * e.r), -0.35, 0.35)
			return {"pos": pos, "face": f, "ang": ang, "prop": fposmod(ph * e.prop_mul, 1.0)}
		"hotair":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.45)
			return {"pos": pos, "sway": 0.07 * sin(TAU * fposmod(ph * 2.0, 1.0))}
		"visitor":
			var d: float = (fposmod(ph, 1.0) if e.dir > 0 else 1.0 - fposmod(ph, 1.0)) * _paths[e.path].len
			var pr := _path_point(e.path, d)
			var face := signf(e.dir * pr.tan.x)
			return {"pos": pr.pos, "face": face if face != 0.0 else 1.0, "walk": fposmod(d * 0.028, 1.0)}
		"dog":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.42)
			var d2: float = e.r * a
			return {"pos": pos, "face": signf(-sin(a)) if absf(sin(a)) > 0.05 else 1.0, "walk": fposmod(d2 * 0.02, 1.0)}
		"cat", "vendor":
			var st := _ppos(e.a, e.b, ph)
			st["walk"] = fposmod(ph * 8.0, 1.0)
			return st
		"orbit_kid":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.55)
			var face := -signf(sin(a))
			return {"pos": pos, "face": face if face != 0.0 else 1.0, "walk": fposmod(ph * 10.0, 1.0)}
		"swing_kid":
			var ang := 0.85 * sin(TAU * fposmod(ph, 1.0))
			var seat: Vector2 = e.pivot + Vector2(sin(ang), cos(ang)) * e.rope
			return {"pos": seat, "ang": ang}
		"bee", "butterfly", "dragonfly":
			var a := TAU * fposmod(ph, 1.0)
			var r2: float = e.r + 10.0 * sin(TAU * fposmod(ph * 2.0, 1.0))
			var pos: Vector2 = e.c + Vector2(cos(a) * r2, sin(a) * r2 * 0.6)
			var flap := 0.5 + 0.5 * sin(TAU * fposmod(ph * e.flap_mul, 1.0))
			return {"pos": pos, "face": signf(cos(a)) if absf(cos(a)) > 0.05 else 1.0, "flap": flap}
		"balloon":
			return {"pos": e.anchor + Vector2(7.0 * sin(TAU * ph), 6.0 * sin(TAU * ph * 0.5) - 6.0)}
		"kite":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.45)
			var ang := 0.45 * sin(TAU * fposmod(ph * 2.0, 1.0))
			return {"pos": pos, "ang": ang, "face": signf(cos(a)) if absf(cos(a)) > 0.05 else 1.0}
		"pigeon":
			var a := TAU * fposmod(ph, 1.0)
			var r2: float = e.r + 7.0 * sin(TAU * fposmod(ph * 3.0, 1.0))
			var pos: Vector2 = e.c + Vector2(cos(a) * r2, sin(a) * r2 * 0.3)
			return {"pos": pos, "face": signf(cos(a)) if absf(cos(a)) > 0.05 else 1.0, "peck": fposmod(ph * 5.0, 1.0)}
		"squirrel":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.45)
			var face := -signf(sin(a))
			return {"pos": pos, "face": face if face != 0.0 else 1.0, "tail": fposmod(ph * 3.0, 1.0)}
		"duck":
			var a := TAU * fposmod(ph, 1.0)
			var pos: Vector2 = e.c + Vector2(cos(a) * e.r, sin(a) * e.r * 0.38)
			return {"pos": pos, "face": signf(cos(a)) if absf(cos(a)) > 0.05 else 1.0,
					"ripple": fposmod(ph * 4.0, 1.0)}
		"swan":
			var st := _ppos(e.a, e.b, ph)
			st["bob"] = sin(TAU * fposmod(ph * 4.0, 1.0))
			return st
	return {"pos": e.get("pos", Vector2.ZERO)}


func _build_park() -> void:
	# —— 公园由 4 个 SECTION_W 宽的分区横向拼接：布局各自独立不重复 ——
	for sec in 4:
		_mk_section(float(sec) * SECTION_W, sec)
	for e in _dyns:
		e.st = _dyn_state(e, fposmod(e.t, 1.0))


## 拼装一个分区：布局各自独立不重复（ox 为分区左缘的世界 x，sec 为分区号 0/1/2/3）
func _mk_section(ox: float, sec: int) -> void:
	# —— 围栏：底边整排（每区一段，拼接后横贯全景）+ 草地上沿一段（pos 取中点，供裁剪与入镜记录访问）
	_statics.append({"kind": "fence", "pos": Vector2(ox + 2080, 2300), "a": Vector2(ox + 40, 2300), "b": Vector2(ox + 4120, 2300), "rad": 2100.0})
	_statics.append({"kind": "fence", "pos": Vector2(ox + 440, 730), "a": Vector2(ox + 120, 710), "b": Vector2(ox + 760, 750), "rad": 400.0})
	match sec:
		0:
			_mk_playground(ox)   # 游乐区：榕树 + 滑梯秋千 + 东西环路
		1:
			_mk_market(ox)       # 市集区：售货亭 + 花市 + 环路带南北支路
		2:
			_mk_wild(ox)         # 野趣区：密林 + 双石 + 蜿蜒 S 形路径
		3:
			_mk_lakeside(ox)     # 湖畔区：大湖 + 石桥喷泉 + 垂柳芦苇 + 水禽
	# —— 草地斑块 / 雏菊（数量各区不同）——
	for i in [14, 12, 16, 13][sec]:
		_patches.append({"pos": Vector2(randf_range(ox + 150, ox + SECTION_W - 150), randf_range(SKY_H + 130, PARK_H - 120)),
				"rx": randf_range(90, 220), "ry": randf_range(26, 55), "rad": 230.0})
	for i in [26, 22, 30, 26][sec]:
		_daisies.append({"pos": Vector2(randf_range(ox + 120, ox + SECTION_W - 120), randf_range(SKY_H + 140, PARK_H - 90)), "rad": 16.0})
	# —— 天空动态（每区随机位置；周期均为 60 的约数且 ≤10s）——
	for i in 4:
		_dyns.append({"kind": "cloud", "period": 6.0 if i % 2 == 0 else 10.0, "t": randf() * 10.0,
				"anchor": Vector2(ox + randf_range(200, SECTION_W - 200), 110.0 + 95.0 * i + randf_range(-25, 25)),
				"amp": randf_range(60, 110), "s": randf_range(0.9, 1.6), "rad": 160.0, "st": {}})
	for b in 2:
		_dyns.append({"kind": "bird", "period": 5.0 if b == 0 else 6.0, "t": randf() * 6.0,
				"c": Vector2(ox + randf_range(300, SECTION_W - 300), randf_range(130.0, SKY_H - 120.0)),
				"r": randf_range(110.0, 180.0), "flap_mul": 3.0 if b == 0 else 2.0,
				"col": BIRD_COLS[(sec * 2 + b) % BIRD_COLS.size()], "rad": 45.0, "st": {}})
	_dyns.append({"kind": "plane", "period": 10.0, "t": randf() * 10.0,
			"c": Vector2(ox + randf_range(500, SECTION_W - 500), randf_range(160.0, SKY_H - 190.0)),
			"r": randf_range(240.0, 320.0), "prop_mul": 6.0, "rad": 90.0, "st": {}})
	_dyns.append({"kind": "hotair", "period": 10.0, "t": randf() * 10.0,
			"c": Vector2(ox + randf_range(300, SECTION_W - 300), randf_range(230.0, SKY_H - 160.0)),
			"r": randf_range(60.0, 100.0), "col": BALLOON_COLS[sec % BALLOON_COLS.size()], "rad": 70.0, "st": {}})


func _jit(v: float) -> float:
	return v + randf_range(-70.0, 70.0)


## 游人（沿指定路径巡游）
func _mk_visitor(path: int, dir: int, period: float, h: float) -> void:
	_dyns.append({"kind": "visitor", "period": period, "t": randf() * period, "path": path, "dir": dir,
			"shirt": SHIRTS[randi() % SHIRTS.size()], "skin": SKINS[randi() % SKINS.size()], "h": h, "rad": 70.0, "st": {}})


## —— 分区 0：游乐区（榕树 + 滑梯秋千 + 东西环路）——
func _mk_playground(ox: float) -> void:
	# 路径：东西向环路
	var fwd := PackedVector2Array([Vector2(80, 1530), Vector2(1100, 1550), Vector2(2100, 1580),
			Vector2(3100, 1550), Vector2(4080, 1520)])
	for i in fwd.size():
		fwd[i] += Vector2(ox, 0)
	var loop := PackedVector2Array(fwd)
	for i in range(fwd.size() - 1, -1, -1):
		loop.append(fwd[i] + Vector2(0, 168))
	loop.append(fwd[0])
	_add_path(loop, 150.0)
	var pa := _paths.size() - 1
	# 太阳 / 山丘
	_statics.append({"kind": "sun", "pos": Vector2(ox + 700, 170), "rad": 150.0})
	for h in [[900, 50, 520, 90], [2300, 42, 640, 110], [3500, 46, 560, 95]]:
		_hills.append({"pos": Vector2(ox + h[0], SKY_H + h[1]), "rx": h[2], "ry": h[3], "rad": h[2] + 30.0})
	# 静态：榕树 + 树灌 + 长椅 + 游乐设施
	_statics.append({"kind": "banyan", "pos": Vector2(_jit(ox + 620), _jit(1250)), "rad": 340.0})
	for t in [[1400, 1080, 1.35], [2380, 1100, 1.2], [3700, 1780, 1.3], [300, 1900, 1.15], [2520, 2210, 1.0],
			[1980, 990, 1.05], [3300, 1150, 1.1]]:
		_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + t[0]), _jit(t[1])), "s": t[2], "rad": 130.0 * t[2]})
	for b in [[880, 1230, 1.0], [1720, 1150, 0.85], [2900, 1180, 0.9], [3820, 1980, 1.0], [1200, 2260, 0.8],
			[2150, 2300, 0.9], [3900, 1260, 0.85]]:
		_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + b[0]), _jit(b[1])), "s": b[2], "rad": 70.0 * b[2]})
	for bn in [[1250, 1712, 1.0], [2350, 1712, -1.0], [3350, 1700, 1.0], [300, 2050, -1.0]]:
		_statics.append({"kind": "bench", "pos": Vector2(ox + bn[0], bn[1]), "flip": bn[2], "rad": 80.0})
	for l in [[450, 1640], [1750, 1660], [2650, 1640], [3900, 1620], [520, 2100]]:
		_statics.append({"kind": "lamp", "pos": Vector2(ox + l[0], l[1]), "rad": 90.0})
	_mk_bed(Vector2(ox + 1150, 1430), 180.0, 72.0)
	_mk_bed(Vector2(ox + 2600, 1250), 155.0, 65.0)
	_mk_bed(Vector2(ox + 1650, 2130), 210.0, 78.0)
	_mk_bed(Vector2(ox + 3300, 2150), 165.0, 66.0)
	_statics.append({"kind": "slide", "pos": Vector2(ox + 850, 2000), "flip": 1.0, "rad": 150.0})
	_statics.append({"kind": "swing", "pos": Vector2(ox + 1560, 2000), "rad": 150.0})
	_statics.append({"kind": "seesaw", "pos": Vector2(ox + 2350, 2000), "flip": 1.0, "rad": 130.0})
	_statics.append({"kind": "sandbox", "pos": Vector2(ox + 2000, 2280), "rad": 140.0})
	_statics.append({"kind": "bin", "pos": Vector2(ox + 2210, 1680), "rad": 50.0})
	_statics.append({"kind": "bin", "pos": Vector2(ox + 3490, 1660), "rad": 50.0})
	_statics.append({"kind": "bin", "pos": Vector2(ox + 900, 2250), "rad": 50.0})
	_statics.append({"kind": "sign", "pos": Vector2(ox + 2160, 1720), "rad": 70.0})
	_statics.append({"kind": "stone", "pos": Vector2(ox + 2680, 2000), "rad": 110.0})
	_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + 950), _jit(950)), "s": 1.05, "rad": 136.0})
	_statics.append({"kind": "bench", "pos": Vector2(ox + 3850, 2100), "flip": 1.0, "rad": 80.0})
	_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + 3550), _jit(2250)), "s": 0.85, "rad": 60.0})
	# 动态：游人四（周期加倍=减速，60 约数）/ 狗 / 猫 / 绕树小孩 / 荡秋千小孩 / 蜂蝶 / 风筝 / 鸽子二
	_mk_visitor(pa, 1, 60.0, 88.0)
	_mk_visitor(pa, 1, 60.0, 92.0)
	_mk_visitor(pa, -1, 30.0, 86.0)
	_mk_visitor(pa, -1, 60.0, 90.0)
	_dyns.append({"kind": "kite", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 1800, SKY_H + 420), "r": 240.0,
			"col": KITE_COLS[randi() % KITE_COLS.size()], "rad": 90.0, "st": {}})
	_dyns.append({"kind": "pigeon", "period": 12.0, "t": randf() * 12.0, "c": Vector2(ox + 1250, 1620), "r": 70.0,
			"rad": 45.0, "st": {}})
	_dyns.append({"kind": "pigeon", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 3450, 2080), "r": 85.0,
			"rad": 45.0, "st": {}})
	_dyns.append({"kind": "dog", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 2900, 2060), "r": 420.0,
			"col": DOG_COLS[randi() % DOG_COLS.size()], "rad": 70.0, "st": {}})
	_dyns.append({"kind": "cat", "period": 30.0, "t": randf() * 30.0, "a": Vector2(ox + 2560, 1980), "b": Vector2(ox + 2800, 2090),
			"col": Color(0.60, 0.55, 0.52), "rad": 55.0, "st": {}})
	_dyns.append({"kind": "orbit_kid", "period": 60.0, "t": randf() * 60.0, "c": Vector2(ox + 620, 1250), "r": 330.0,
			"shirt": SHIRTS[2], "skin": SKINS[0], "rad": 70.0, "st": {}})
	_dyns.append({"kind": "swing_kid", "period": 2.0, "t": randf() * 2.0, "pivot": Vector2(ox + 1560, 1905), "rope": 130.0,
			"shirt": SHIRTS[4], "skin": SKINS[0], "rad": 110.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 6.0, "t": randf() * 6.0, "c": Vector2(ox + 1150, 1360), "r": 80.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 10.0, "t": randf() * 10.0, "c": Vector2(ox + 1650, 2060), "r": 95.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 12.0, "t": randf() * 12.0, "c": Vector2(ox + 3650, 1300), "r": 75.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 2600, 1190), "r": 75.0,
			"col": Color(0.85, 0.45, 0.75), "flap_mul": 2.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 1150, 1370), "r": 90.0,
			"col": Color(1.0, 0.72, 0.25), "flap_mul": 2.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 3200, 1450), "r": 80.0,
			"col": Color(0.30, 0.70, 0.70), "flap_mul": 2.0, "rad": 45.0, "st": {}})


## —— 分区 1：市集区（售货亭 + 花市三坛 + 环路带南北支路）——
func _mk_market(ox: float) -> void:
	# 路径：环路 + 南北支路（市集区专属）
	var fwd := PackedVector2Array([Vector2(100, 1545), Vector2(1200, 1570), Vector2(2300, 1535),
			Vector2(3300, 1565), Vector2(4060, 1530)])
	for i in fwd.size():
		fwd[i] += Vector2(ox, 0)
	var loop := PackedVector2Array(fwd)
	for i in range(fwd.size() - 1, -1, -1):
		loop.append(fwd[i] + Vector2(0, 165))
	loop.append(fwd[0])
	_add_path(loop, 150.0)
	var pa := _paths.size() - 1
	var ver := PackedVector2Array([Vector2(2090, 900), Vector2(2075, 1150), Vector2(2085, 1400),
			Vector2(2030, 1750), Vector2(1985, 2100), Vector2(1950, 2320)])
	for i in ver.size():
		ver[i] += Vector2(ox, 0)
	var loop_b := PackedVector2Array(ver)
	for i in range(ver.size() - 1, -1, -1):
		loop_b.append(ver[i] + Vector2(155, 0))
	loop_b.append(ver[0])
	_add_path(loop_b, 120.0)
	var pb := _paths.size() - 1
	# 太阳 / 山丘
	_statics.append({"kind": "sun", "pos": Vector2(ox + 3600, 170), "rad": 150.0})
	for h in [[600, 48, 540, 85], [2100, 44, 600, 105], [3600, 50, 560, 95]]:
		_hills.append({"pos": Vector2(ox + h[0], SKY_H + h[1]), "rx": h[2], "ry": h[3], "rad": h[2] + 30.0})
	# 静态：售货亭 + 花坛四 + 长椅四 + 摊位/木桶/遮阳伞（无榕树无游乐设施）
	for t in [[1000, 1100, 1.2], [1900, 1120, 1.05], [3050, 1150, 1.25], [3850, 1850, 1.15], [2600, 960, 1.05]]:
		_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + t[0]), _jit(t[1])), "s": t[2], "rad": 130.0 * t[2]})
	for b in [[500, 1300, 0.9], [1450, 1250, 1.0], [2400, 1200, 0.85], [3100, 1300, 0.95], [1300, 2200, 1.0], [3300, 2150, 0.9],
			[3900, 1250, 0.8]]:
		_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + b[0]), _jit(b[1])), "s": b[2], "rad": 70.0 * b[2]})
	_statics.append({"kind": "kiosk", "pos": Vector2(ox + 3260, 1330), "rad": 150.0})
	_statics.append({"kind": "stall", "pos": Vector2(ox + 1500, 2140), "flip": 1.0, "rad": 110.0})
	_statics.append({"kind": "stall", "pos": Vector2(ox + 3520, 2160), "flip": -1.0, "rad": 110.0})
	_statics.append({"kind": "barrel", "pos": Vector2(ox + 2980, 1480), "s": 1.0, "rad": 40.0})
	_statics.append({"kind": "barrel", "pos": Vector2(ox + 3550, 1490), "s": 0.9, "rad": 40.0})
	_statics.append({"kind": "umbrella", "pos": Vector2(ox + 980, 2260), "s": 1.0, "rad": 110.0})
	_statics.append({"kind": "umbrella", "pos": Vector2(ox + 2400, 2180), "s": 0.9, "rad": 100.0})
	for bn in [[900, 1712, 1.0], [1750, 1712, -1.0], [2700, 1700, 1.0], [3650, 1712, -1.0]]:
		_statics.append({"kind": "bench", "pos": Vector2(ox + bn[0], bn[1]), "flip": bn[2], "rad": 80.0})
	for l in [[700, 1650], [1900, 1660], [2900, 1640], [1500, 2300]]:
		_statics.append({"kind": "lamp", "pos": Vector2(ox + l[0], l[1]), "rad": 90.0})
	_mk_bed(Vector2(ox + 1150, 1430), 175.0, 70.0)
	_mk_bed(Vector2(ox + 2400, 1280), 165.0, 68.0)
	_mk_bed(Vector2(ox + 2750, 2130), 200.0, 75.0)
	_mk_bed(Vector2(ox + 700, 2150), 150.0, 62.0)
	_statics.append({"kind": "bin", "pos": Vector2(ox + 2450, 1680), "rad": 50.0})
	_statics.append({"kind": "bin", "pos": Vector2(ox + 3550, 1660), "rad": 50.0})
	_statics.append({"kind": "sign", "pos": Vector2(ox + 1300, 1720), "rad": 70.0})
	_statics.append({"kind": "stone", "pos": Vector2(ox + 2150, 2050), "rad": 110.0})
	_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + 700), _jit(980)), "s": 1.1, "rad": 143.0})
	_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + 2000), _jit(2260)), "s": 0.9, "rad": 63.0})
	_statics.append({"kind": "barrel", "pos": Vector2(ox + 3120, 2200), "s": 0.85, "rad": 40.0})
	# 动态：游人含支路（周期加倍=减速）/ 店员 / 蜂 / 蝶 / 手拿气球 / 鸽子二
	_mk_visitor(pa, 1, 60.0, 88.0)
	_mk_visitor(pa, -1, 60.0, 90.0)
	_mk_visitor(pb, 1, 30.0, 86.0)
	_mk_visitor(pb, -1, 30.0, 88.0)
	_dyns.append({"kind": "vendor", "period": 60.0, "t": randf() * 60.0, "a": Vector2(ox + 3170, 1465), "b": Vector2(ox + 3430, 1465),
			"skin": SKINS[1], "rad": 70.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 6.0, "t": randf() * 6.0, "c": Vector2(ox + 2450, 1350), "r": 80.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 10.0, "t": randf() * 10.0, "c": Vector2(ox + 2950, 2050), "r": 90.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 12.0, "t": randf() * 12.0, "c": Vector2(ox + 1700, 1200), "r": 70.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 1200, 1250), "r": 80.0,
			"col": Color(0.85, 0.45, 0.75), "flap_mul": 2.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "balloon", "period": 5.0, "t": randf() * 5.0, "anchor": Vector2(ox + 3390, 1300),
			"col": Color(0.95, 0.40, 0.45), "rad": 45.0, "st": {}})
	_dyns.append({"kind": "pigeon", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 2200, 1630), "r": 75.0,
			"rad": 45.0, "st": {}})
	_dyns.append({"kind": "pigeon", "period": 12.0, "t": randf() * 12.0, "c": Vector2(ox + 1200, 2100), "r": 60.0,
			"rad": 45.0, "st": {}})


## —— 分区 2：野趣区（密林七树 + 双石 + 蜿蜒 S 形路径）——
func _mk_wild(ox: float) -> void:
	# 路径：S 形蜿蜒闭合（与前两区形状完全不同）
	var sn := PackedVector2Array([Vector2(200, 1650), Vector2(900, 1450), Vector2(1600, 1700), Vector2(2300, 1500),
			Vector2(3000, 1750), Vector2(3700, 1550), Vector2(3900, 1900), Vector2(3200, 2080), Vector2(2300, 1950),
			Vector2(1400, 2100), Vector2(500, 1950)])
	for i in sn.size():
		sn[i] += Vector2(ox, 0)
	sn.append(sn[0])
	_add_path(sn, 130.0)
	var pa := _paths.size() - 1
	# 太阳 / 山丘
	_statics.append({"kind": "sun", "pos": Vector2(ox + 2000, 160), "rad": 150.0})
	for h in [[1200, 46, 560, 95], [2600, 50, 620, 100], [3900, 42, 520, 85]]:
		_hills.append({"pos": Vector2(ox + h[0], SKY_H + h[1]), "rx": h[2], "ry": h[3], "rad": h[2] + 30.0})
	# 静态：密树八棵 + 树桩/枯木/蘑菇（无售货亭无游乐设施）
	for t in [[400, 1150, 1.3], [1100, 1050, 1.1], [1900, 1120, 1.35], [2650, 1080, 1.1], [3350, 1150, 1.2], [650, 2150, 1.15], [3050, 2230, 1.0],
			[2450, 2260, 1.05]]:
		_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + t[0]), _jit(t[1])), "s": t[2], "rad": 130.0 * t[2]})
	for b in [[800, 1350, 0.9], [2200, 1300, 0.85], [3000, 1400, 1.0], [3700, 1350, 0.9],
			[1500, 2270, 0.95], [3500, 2200, 0.9]]:
		_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + b[0]), _jit(b[1])), "s": b[2], "rad": 70.0 * b[2]})
	_statics.append({"kind": "stump", "pos": Vector2(ox + 800, 1900), "s": 1.0, "rad": 50.0})
	_statics.append({"kind": "stump", "pos": Vector2(ox + 2700, 2160), "s": 0.85, "rad": 45.0})
	_statics.append({"kind": "log", "pos": Vector2(ox + 1750, 2240), "s": 1.0, "rad": 110.0})
	_statics.append({"kind": "mushroom", "pos": Vector2(ox + 1050, 1440), "s": 1.0, "rad": 40.0})
	_statics.append({"kind": "mushroom", "pos": Vector2(ox + 2870, 1200), "s": 0.9, "rad": 40.0})
	_statics.append({"kind": "mushroom", "pos": Vector2(ox + 2120, 2330), "s": 0.8, "rad": 35.0})
	for bn in [[1500, 1810, 1.0], [2870, 1860, -1.0]]:
		_statics.append({"kind": "bench", "pos": Vector2(ox + bn[0], bn[1]), "flip": bn[2], "rad": 80.0})
	for l in [[1000, 1740], [2200, 1790], [3450, 1820]]:
		_statics.append({"kind": "lamp", "pos": Vector2(ox + l[0], l[1]), "rad": 90.0})
	_mk_bed(Vector2(ox + 1800, 1400), 170.0, 70.0)
	_mk_bed(Vector2(ox + 3250, 1900), 190.0, 72.0)
	_statics.append({"kind": "bin", "pos": Vector2(ox + 1600, 1900), "rad": 50.0})
	_statics.append({"kind": "sign", "pos": Vector2(ox + 2600, 1780), "rad": 70.0})
	_statics.append({"kind": "stone", "pos": Vector2(ox + 1200, 1850), "rad": 110.0})
	_statics.append({"kind": "stone", "pos": Vector2(ox + 2800, 1900), "rad": 110.0})
	_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + 1500), _jit(980)), "s": 1.0, "rad": 130.0})
	_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + 2600), _jit(1450)), "s": 0.8, "rad": 56.0})
	_statics.append({"kind": "mushroom", "pos": Vector2(ox + 3550, 1450), "s": 0.9, "rad": 40.0})
	_statics.append({"kind": "stump", "pos": Vector2(ox + 2050, 1300), "s": 0.9, "rad": 45.0})
	# 动态：游人四（周期加倍=减速）/ 狗 / 猫 / 绕树小孩 / 蜂 / 蝶 / 松鼠
	_mk_visitor(pa, 1, 60.0, 90.0)
	_mk_visitor(pa, 1, 30.0, 86.0)
	_mk_visitor(pa, -1, 60.0, 92.0)
	_mk_visitor(pa, 1, 60.0, 88.0)
	_dyns.append({"kind": "dog", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 3500, 2000), "r": 380.0,
			"col": DOG_COLS[randi() % DOG_COLS.size()], "rad": 70.0, "st": {}})
	_dyns.append({"kind": "cat", "period": 30.0, "t": randf() * 30.0, "a": Vector2(ox + 2500, 1850), "b": Vector2(ox + 2750, 1980),
			"col": Color(0.55, 0.45, 0.38), "rad": 55.0, "st": {}})
	_dyns.append({"kind": "orbit_kid", "period": 60.0, "t": randf() * 60.0, "c": Vector2(ox + 1900, 1120), "r": 300.0,
			"shirt": SHIRTS[5], "skin": SKINS[2], "rad": 70.0, "st": {}})
	_dyns.append({"kind": "bee", "period": 10.0, "t": randf() * 10.0, "c": Vector2(ox + 1800, 1420), "r": 85.0,
			"flap_mul": 3.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 1500, 1550), "r": 85.0,
			"col": Color(0.85, 0.45, 0.75), "flap_mul": 2.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 12.0, "t": randf() * 12.0, "c": Vector2(ox + 3300, 1300), "r": 75.0,
			"col": Color(1.0, 0.72, 0.25), "flap_mul": 2.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "butterfly", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 2900, 1600), "r": 70.0,
			"col": Color(0.30, 0.70, 0.70), "flap_mul": 2.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "squirrel", "period": 5.0, "t": randf() * 5.0, "c": Vector2(ox + 1100, 1150), "r": 130.0,
			"rad": 40.0, "st": {}})
	_dyns.append({"kind": "squirrel", "period": 10.0, "t": randf() * 10.0, "c": Vector2(ox + 3350, 1260), "r": 140.0,
			"rad": 40.0, "st": {}})
	_dyns.append({"kind": "squirrel", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 2200, 1500), "r": 110.0,
			"rad": 40.0, "st": {}})


## —— 分区 3：湖畔区（大湖 + 石桥喷泉 + 垂柳芦苇 + 水禽，元素种类与其余三区互斥）——
func _mk_lakeside(ox: float) -> void:
	# 路径：环湖北岸步道（东西微弧 + 南岸返回闭合，与前三区形状不同）
	var fwd := PackedVector2Array([Vector2(300, 1420), Vector2(1200, 1440), Vector2(2200, 1410), Vector2(3200, 1440),
			Vector2(4050, 1410)])
	for i in fwd.size():
		fwd[i] += Vector2(ox, 0)
	var loop := PackedVector2Array(fwd)
	for i in range(fwd.size() - 1, -1, -1):
		loop.append(fwd[i] + Vector2(0, 165))
	loop.append(fwd[0])
	_add_path(loop, 140.0)
	var pa := _paths.size() - 1
	# 太阳 / 山丘
	_statics.append({"kind": "sun", "pos": Vector2(ox + 1400, 170), "rad": 150.0})
	for h in [[800, 48, 560, 90], [2200, 44, 600, 100], [3600, 46, 540, 88]]:
		_hills.append({"pos": Vector2(ox + h[0], SKY_H + h[1]), "rx": h[2], "ry": h[3], "rad": h[2] + 30.0})
	# 大湖（先入列先绘制，桥/荷叶/芦苇/水禽盖其上）
	_statics.append({"kind": "lake", "pos": Vector2(ox + 2050, 1950), "rx": 1480.0, "ry": 330.0, "rad": 1550.0})
	# 静态：石桥 + 喷泉 + 垂柳 + 荷叶 + 芦苇 + 树灌椅灯（无游乐设施/售货亭/密林专属）
	_statics.append({"kind": "bridge", "pos": Vector2(ox + 950, 1730), "rad": 260.0})
	_statics.append({"kind": "fountain", "pos": Vector2(ox + 2050, 1920), "rad": 200.0})
	for w in [[560, 1300, 1.0], [3480, 1270, 1.1], [3900, 2150, 0.9]]:
		_statics.append({"kind": "willow", "pos": Vector2(_jit(ox + w[0]), _jit(w[1])), "s": w[2], "rad": 150.0 * w[2]})
	for lp in [[1350, 1820], [1650, 2060], [2450, 1950], [2750, 2120], [2950, 1800]]:
		_statics.append({"kind": "lily", "pos": Vector2(ox + lp[0], lp[1]), "s": randf_range(0.8, 1.2), "rad": 35.0})
	for rd in [[640, 1700], [3350, 1750], [950, 2230], [3150, 2260]]:
		_statics.append({"kind": "reed", "pos": Vector2(ox + rd[0], rd[1]), "s": randf_range(0.85, 1.15), "rad": 45.0})
	for t in [[400, 1000, 1.2], [1300, 950, 1.1], [2900, 1000, 1.25], [3750, 1500, 1.0]]:
		_statics.append({"kind": "tree", "pos": Vector2(_jit(ox + t[0]), _jit(t[1])), "s": t[2], "rad": 130.0 * t[2]})
	for b in [[750, 1200, 0.9], [1700, 1150, 0.85], [2600, 1200, 0.95], [3500, 1350, 0.9], [500, 2100, 0.85],
			[3900, 1900, 0.8]]:
		_statics.append({"kind": "bush", "pos": Vector2(_jit(ox + b[0]), _jit(b[1])), "s": b[2], "rad": 70.0 * b[2]})
	for bn in [[1500, 1330, 1.0], [2700, 1330, -1.0]]:
		_statics.append({"kind": "bench", "pos": Vector2(ox + bn[0], bn[1]), "flip": bn[2], "rad": 80.0})
	for l in [[900, 1350], [2100, 1320], [3300, 1350]]:
		_statics.append({"kind": "lamp", "pos": Vector2(ox + l[0], l[1]), "rad": 90.0})
	_mk_bed(Vector2(ox + 1450, 1240), 160.0, 62.0)
	_mk_bed(Vector2(ox + 3150, 1230), 155.0, 60.0)
	_statics.append({"kind": "bin", "pos": Vector2(ox + 1900, 1300), "rad": 50.0})
	_statics.append({"kind": "sign", "pos": Vector2(ox + 3600, 1450), "rad": 70.0})
	_statics.append({"kind": "stone", "pos": Vector2(ox + 2350, 1250), "rad": 110.0})
	# 动态：游人三（慢速漫步）/ 野鸭二 / 天鹅 / 蜻蜓二（周期均为 60 约数）
	_mk_visitor(pa, 1, 60.0, 90.0)
	_mk_visitor(pa, -1, 30.0, 86.0)
	_mk_visitor(pa, 1, 60.0, 88.0)
	_dyns.append({"kind": "duck", "period": 12.0, "t": randf() * 12.0, "c": Vector2(ox + 1600, 1950), "r": 90.0,
			"rad": 45.0, "st": {}})
	_dyns.append({"kind": "duck", "period": 20.0, "t": randf() * 20.0, "c": Vector2(ox + 2650, 2080), "r": 75.0,
			"rad": 45.0, "st": {}})
	_dyns.append({"kind": "swan", "period": 30.0, "t": randf() * 30.0, "a": Vector2(ox + 1300, 1800), "b": Vector2(ox + 2800, 1850),
			"rad": 60.0, "st": {}})
	_dyns.append({"kind": "dragonfly", "period": 6.0, "t": randf() * 6.0, "c": Vector2(ox + 1900, 1660), "r": 70.0,
			"col": Color(0.30, 0.70, 0.75), "flap_mul": 4.0, "rad": 45.0, "st": {}})
	_dyns.append({"kind": "dragonfly", "period": 10.0, "t": randf() * 10.0, "c": Vector2(ox + 2400, 1750), "r": 60.0,
			"col": Color(0.55, 0.75, 0.30), "flap_mul": 4.0, "rad": 45.0, "st": {}})


func _mk_bed(pos: Vector2, rx: float, ry: float) -> void:
	var fs: Array = []
	for i in 9:
		var a := TAU * i / 9.0 + randf_range(-0.2, 0.2)
		var rr := randf_range(0.35, 0.85)
		fs.append({"o": Vector2(cos(a) * rx * rr, sin(a) * ry * rr), "c": FLOWERS[randi() % FLOWERS.size()]})
	_statics.append({"kind": "bed", "pos": pos, "rx": rx, "ry": ry, "flowers": fs, "rad": maxf(rx, ry) + 40.0})


## ===== 目标图 =====

func _gen_target() -> void:
	var vp := get_viewport_rect().size
	var best: Target = null
	var best_sc := -1
	for i in 48:
		# 前 7 个候选强制遍历全部缩放档（各档位都能取到目标），其后按权重随机（中档加权）
		var zi: int = i if i < ZOOM_FRACS.size() else ZOOM_W[randi() % ZOOM_W.size()]
		var sz := _zoom_size(zi)
		var c := Vector2(randf_range(sz.x * 0.5, PARK_W - sz.x * 0.5), randf_range(sz.y * 0.5, PARK_H - sz.y * 0.5))
		if _last_center.x > -1e8 and c.distance_to(_last_center) < TARGET_DIST:
			continue
		var rect := Rect2(c - sz * 0.5, sz)
		var t := _record_rect(rect, zi)
		var lm := 0
		var dn := 0
		for it in t.items:
			if it.lm:
				lm += 1
			if it.d_idx >= 0:
				dn += 1
		var sc := lm * 10 + dn * 3 + t.items.size()
		if lm >= LANDMARK_MIN and dn >= DYN_MIN and t.items.size() >= TARGET_MIN:
			best = t
			best_sc = sc
			break
		if sc > best_sc:
			best = t
			best_sc = sc
	_target = best
	_last_center = _target.rect.get_center()
	# 目标缩略图：冻结记录时刻的动态相位
	var ovr := {}
	for it in _target.items:
		if it.d_idx >= 0:
			ovr[it.d_idx] = it.ph
	_render_thumb(_vp_t, _target.rect, ovr)


## 记录区域内全部元素（中心点在框内才算入镜）
func _record_rect(rect: Rect2, zi: int) -> Target:
	var t := Target.new()
	t.rect = rect
	t.zoom_i = zi
	for e in _statics:
		if rect.has_point(e.pos):
			t.items.append({"pos": e.pos, "ph": 0.0, "d_idx": -1, "kind": e.kind, "lm": LANDMARKS.has(e.kind), "no_state": true})
	for i in _dyns.size():
		var e: Dictionary = _dyns[i]
		var ph := fposmod(e.t, 1.0)
		var st := _dyn_state(e, ph)
		if rect.has_point(st.pos):
			t.items.append({"pos": st.pos, "ph": ph, "d_idx": i, "kind": e.kind, "lm": false, "no_state": e.kind == "cloud"})
	return t


## ===== 拍照与匹配判定（纯逻辑数据比对，无像素运算） =====

func _do_shutter() -> void:
	if _result_t > 0.0 or get_tree().paused:
		return
	_play_sfx("shutter")
	_flash_t = FLASH_T
	_render_thumb(_vp_c, _cam, {})   # 拍照缩略图：定格当前画面
	_pending = _compute_match()
	_result_t = RESULT_DELAY


func _compute_match() -> Dictionary:
	var rect: Rect2 = _target.rect
	var cam := _cam
	var size_sim: float = clampf(1.0 - ZOOM_MISS * absi(_target.zoom_i - _zoom_idx), 0.4, 1.0)
	var matched := 0
	var pos_sum := 0.0
	var pos_n := 0
	var st_sum := 0.0
	var st_n := 0
	for it in _target.items:
		var cur: Vector2
		var ph := 0.0
		if it.d_idx >= 0:
			var e: Dictionary = _dyns[it.d_idx]
			cur = e.st.pos
			ph = fposmod(e.t, 1.0)
		else:
			cur = it.pos
		if not cam.has_point(cur):
			continue
		matched += 1
		var d: float = ((it.pos - rect.position) / rect.size - (cur - cam.position) / cam.size).length()
		pos_sum += clampf(1.0 - d / POS_TOL, 0.0, 1.0)
		pos_n += 1
		if not it.no_state:
			var pd := absf(wrapf(ph - it.ph, -0.5, 0.5))
			st_sum += clampf(1.0 - pd / PHASE_TOL, 0.0, 1.0)
			st_n += 1
	var n := _target.items.size()
	var kind_s := float(matched) / maxf(n, 1.0)
	var pos_s := pos_sum / maxf(pos_n, 1.0)
	var st_s := st_sum / maxf(st_n, 1.0)
	var wk := MATCH_W_KIND
	var wp := MATCH_W_POS
	var ws := MATCH_W_STATE
	if st_n == 0:      # 目标无动态元素：状态权重并入位置
		wp += ws
		ws = 0.0
	var pct := int(round(100.0 * (wk * kind_s + wp * pos_s * size_sim + ws * st_s)))
	var rating := 0
	if pct >= RATE_PERFECT:
		rating = 3
	elif pct >= RATE_GREAT:
		rating = 2
	elif pct >= RATE_GOOD:
		rating = 1
	var bonus := 0
	if rating == 3:
		_streak += 1
		bonus = COMBO_BONUS * (_streak - 1)
	else:
		_streak = 0
	var gained: int = RATE_SCORES[rating] + bonus
	score += gained
	var new_record := false
	if rating >= 1:   # 合格及以上才计入成绩
		if pct > hud.max_score:
			new_record = true
		hud.submit_score(pct)
		run_best = maxi(run_best, pct)
		_refresh_hud()
	if rating >= 2:
		_play_sfx("win", 0.0 if rating == 3 else -6.0)
	elif rating == 0:
		_play_sfx("fail")
	if rating == 3:
		_spawn_particles(get_viewport_rect().size * 0.5)
	return {"pct": pct, "rating": rating, "gained": gained, "bonus": bonus, "new_record": new_record}


## ===== 结算弹窗 =====

func _show_result(r: Dictionary) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var panel := PanelContainer.new()
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.94)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.032)
	panel.add_theme_stylebox_override("panel", sb)
	panel.z_index = 220
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.014))
	panel.add_child(vb)
	# 评级标题
	var head := Label.new()
	head.text = hud.t(RATE_KEYS[r.rating], ["Fail", "Good", "Great", "Perfect!"][r.rating])
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", int(m * 0.055))
	head.add_theme_color_override("font_color", RATE_COLS[r.rating])
	head.add_theme_color_override("font_outline_color", Color.BLACK)
	head.add_theme_constant_override("outline_size", 10)
	vb.add_child(head)
	if r.new_record:
		var nr := Label.new()
		nr.text = hud.t("ps.new_record", "New Record!")
		nr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nr.add_theme_font_size_override("font_size", int(m * 0.028))
		nr.add_theme_color_override("font_color", COL_R_PERFECT)
		nr.add_theme_color_override("font_outline_color", Color.BLACK)
		nr.add_theme_constant_override("outline_size", 8)
		vb.add_child(nr)
	# 目标图 vs 拍照对比
	var cmp := HBoxContainer.new()
	cmp.alignment = BoxContainer.ALIGNMENT_CENTER
	cmp.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(cmp)
	for pair in [[hud.t("ps.target", "Target"), _vp_t.get_texture()],
			[hud.t("ps.yours", "Your Photo"), _vp_c.get_texture()]]:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", int(m * 0.008))
		cmp.add_child(box)
		var cap := Label.new()
		cap.text = pair[0]
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.add_theme_font_size_override("font_size", int(m * 0.022))
		cap.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		box.add_child(cap)
		var tr := TextureRect.new()
		tr.texture = pair[1]
		# 对比图宽高比跟随相机（与目标框一致），避免拉伸失真
		var pw := m * 0.155
		var ph := minf(pw * _cam.size.y / maxf(_cam.size.x, 1.0), m * 0.34)
		tr.custom_minimum_size = Vector2(pw, ph)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		box.add_child(tr)
	# 匹配度
	var pct := Label.new()
	pct.text = "%s %d%%" % [hud.t("ps.match", "Match"), r.pct]
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pct.add_theme_font_size_override("font_size", int(m * 0.045))
	pct.add_theme_color_override("font_color", Color.WHITE)
	pct.add_theme_color_override("font_outline_color", Color.BLACK)
	pct.add_theme_constant_override("outline_size", 8)
	vb.add_child(pct)
	# 得分 / 提示
	var sub := Label.new()
	if r.rating == 0:
		sub.text = hud.t("ps.fail_hint", "Below %d%% — adjust framing and try again!") % RATE_GOOD
	else:
		sub.text = "+%d" % r.gained
		if r.bonus > 0:
			sub.text += "   %s" % (hud.t("ps.combo", "Combo x%d") % (_streak))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", int(m * 0.028))
	sub.add_theme_color_override("font_color", COL_R_PERFECT if r.rating > 0 else Color(0.8, 0.8, 0.8))
	sub.add_theme_color_override("font_outline_color", Color.BLACK)
	sub.add_theme_constant_override("outline_size", 6)
	vb.add_child(sub)
	# 按钮：重拍 / 下一关
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(row)
	var rt := GameHud.make_button(hud.t("ps.retake", "Retake"))
	rt.add_theme_font_size_override("font_size", int(m * 0.026))
	rt.pressed.connect(_close_result)
	row.add_child(rt)
	var nx := GameHud.make_button(hud.t("ps.next", "Next"))
	nx.add_theme_font_size_override("font_size", int(m * 0.026))
	nx.pressed.connect(func() -> void:
		_close_result()
		_gen_target())
	row.add_child(nx)
	var rk := GameHud.make_button(hud.t("ui.top10", "Top 10"))
	rk.add_theme_font_size_override("font_size", int(m * 0.026))
	rk.pressed.connect(func() -> void:
		_close_result()   # 先关结算弹窗（取消暂停），排行榜自己会再暂停并负责关闭时恢复
		var rank: int = hud.commit_score() if run_best > 0 else 0   # 本局成绩先入榜，榜内高亮名次
		hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), run_best, rank))
	row.add_child(rk)
	add_child(panel)
	panel.reset_size()
	panel.position = Vector2(vp.x / 2.0 - panel.size.x / 2.0, vp.y / 2.0 - panel.size.y / 2.0)
	_popup = panel
	get_tree().paused = true


func _close_result() -> void:
	if _popup != null and is_instance_valid(_popup):
		_popup.queue_free()
	_popup = null
	get_tree().paused = false


## ===== 重开 / 排行榜 / 音量 / BGM =====

func _restart() -> void:
	_commit_run()
	_close_result()
	score = 0
	run_best = 0
	_streak = 0
	_elapsed = 0.0
	_time_shown = ""
	hud.reset_run()
	_refresh_hud()
	_gen_target()
	_sync_bgm()


func _on_lb() -> void:
	if _popup != null and is_instance_valid(_popup):
		return   # 结算弹窗打开时不叠加排行榜（避免关榜误恢复暂停）
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


## 右上角按钮排（HBox）：✕（tscn 已有）+ 排行榜 + R 重开 + BGM + 音量循环
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS
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


## ===== 目标图预览面板（右上角，参考围住水果） =====

func _setup_painters() -> void:
	_world = Painter.new()
	_world.g = self
	_world.name = "World"
	add_child(_world)
	_fx = Painter.new()
	_fx.g = self
	_fx.mode = "fx"
	_fx.name = "Fx"
	add_child(_fx)
	_vp_t = SubViewport.new()
	_vp_t.size = Vector2i(THUMB_W, roundi(THUMB_W * 0.5625))   # 占位，_render_thumb 按实际比例重设
	_vp_t.transparent_bg = true
	_vp_t.render_target_update_mode = SubViewport.UPDATE_ONCE
	var pt := Painter.new()
	pt.g = self
	_vp_t.add_child(pt)
	add_child(_vp_t)
	_vp_c = SubViewport.new()
	_vp_c.size = Vector2i(THUMB_W, roundi(THUMB_W * 0.5625))
	_vp_c.transparent_bg = true
	_vp_c.render_target_update_mode = SubViewport.UPDATE_ONCE
	var pc := Painter.new()
	pc.g = self
	_vp_c.add_child(pc)
	add_child(_vp_c)


func _render_thumb(vp: SubViewport, rect: Rect2, ovr: Dictionary) -> void:
	var p: Painter = vp.get_child(0)
	p.phase_ovr = ovr
	p.clip = rect
	# 视口尺寸跟随裁剪框宽高比（恒等于相机比例），避免拉伸/留黑边
	vp.size = Vector2i(THUMB_W, maxi(2, roundi(THUMB_W * rect.size.y / rect.size.x)))
	var s := float(THUMB_W) / rect.size.x
	p.scale = Vector2(s, s)
	p.position = -rect.position * s
	p.queue_redraw()   # 重设裁剪/变换后必须重绘，否则缩略图停留在旧首帧内容
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _setup_preview() -> void:
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	_pv_panel = PanelContainer.new()
	_pv_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.984, 0.918, 0.749, 0.96)
	sb.border_color = Color(0.30, 0.23, 0.18)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(10.0)
	_pv_panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	_pv_panel.add_child(vb)
	_pv_label = Label.new()
	_pv_label.text = hud.t("ps.target", "Target")
	_pv_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pv_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pv_label.add_theme_color_override("font_color", Color(0.30, 0.23, 0.18))
	_pv_label.add_theme_font_size_override("font_size", int(m * 0.024))
	vb.add_child(_pv_label)
	_pv_rect = TextureRect.new()
	_pv_rect.texture = _vp_t.get_texture()
	var asp0 := (_cam.size.y / _cam.size.x) if _cam.size.x > 0.0 else 0.5625
	_pv_rect.custom_minimum_size = Vector2(THUMB_W, THUMB_W * asp0)
	_pv_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pv_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_pv_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_pv_rect)
	add_child(_pv_panel)
	_pv_panel.reset_size()


## ===== 布局 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	# 相机视野随窗口宽高比重算（保持当前档位与中心）
	var c := _cam.get_center() if _cam.size.x > 0.0 else Vector2(PARK_W, PARK_H) * 0.5
	var sz := _zoom_size(_zoom_idx)
	_cam = Rect2(c - sz * 0.5, sz)
	_apply_cam()
	if _pv_panel != null:
		_pv_label.add_theme_font_size_override("font_size", int(m * 0.024))
		var tw := clampf(m * 0.16, THUMB_W * 0.7, THUMB_W * 1.6)
		var th := minf(tw * _cam.size.y / maxf(_cam.size.x, 1.0), m * 0.45)
		_pv_rect.custom_minimum_size = Vector2(tw, th)
		_pv_panel.reset_size()
	# 窗口宽高比变化 → 旧目标框比例与相机不再一致（完美匹配不可能达成），重生成目标
	if _started and _target != null:
		var asp := _cam.size.y / _cam.size.x
		if absf(asp - _target.rect.size.y / _target.rect.size.x) > 0.01:
			_gen_target()
	for lb: Label in [_time_board, _score_board, _best_board]:
		lb.custom_minimum_size = Vector2(150.0, m * 0.051)
		lb.add_theme_font_size_override("font_size", int(m * 0.033))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	if _pv_panel != null:
		_pv_panel.position = Vector2(vp.x - _pv_panel.size.x - 16.0, TOP_H + 10.0)
	# 底部工具栏圆钮位置
	var cy := vp.y - m * 0.085
	_tool["shutter"] = Vector2(vp.x * 0.5, cy)
	_tool["zoom_in"] = Vector2(vp.x * 0.5 + m * 0.105, cy)
	_tool["zoom_out"] = Vector2(vp.x * 0.5 - m * 0.105, cy)


func _refresh_hud() -> void:
	_score_board.text = str(score)
	_best_board.text = ("%d%%" % hud.max_score) if hud.max_score > 0 else "--%"


func _refresh_time() -> void:
	var t := int(_elapsed)
	var s := "%d:%02d" % [t / 60, t % 60]
	if s != _time_shown:
		_time_shown = s
		_time_board.text = s


## ===== 绘制（世界坐标系，由 Painter 携带相机/缩略图变换） =====

func _draw_scene(p: Painter) -> void:
	var clip := p.clip
	# 天空
	p.draw_rect(Rect2(0, 0, PARK_W, SKY_H), COL_SKY)
	# 云（天空层）
	for i in _dyns.size():
		var e: Dictionary = _dyns[i]
		if e.kind != "cloud":
			continue
		var st: Dictionary = _dyn_st_for(p, i)
		if _vis(p, st.pos, e.rad):
			_d_cloud(p, st.pos, e.s)
	# 天空动态元素（飞鸟 / 客机 / 热气球）
	for i in _dyns.size():
		var e: Dictionary = _dyns[i]
		if e.kind != "bird" and e.kind != "plane" and e.kind != "hotair":
			continue
		var st: Dictionary = _dyn_st_for(p, i)
		if not _vis(p, st.pos, e.rad):
			continue
		match e.kind:
			"bird": _d_bird(p, st.pos, st.face, st.flap, e.col)
			"plane": _d_plane(p, st.pos, st.face, st.ang, st.prop)
			"hotair": _d_hotair(p, st.pos, st.sway, e.col)
	# 远山 / 草地 / 斑块 / 雏菊
	for h in _hills:
		if _vis(p, h.pos, h.rad):
			_elli(p, h.pos, h.rx, h.ry, COL_HILL, 0.0)
	p.draw_rect(Rect2(0, SKY_H, PARK_W, PARK_H - SKY_H), COL_GRASS)
	for pa in _patches:
		if _vis(p, pa.pos, pa.rad):
			_elli(p, pa.pos, pa.rx, pa.ry, COL_GRASS_L, 0.0)
	for d in _daisies:
		if _vis(p, d.pos, 16.0):
			p.draw_circle(d.pos, 4.5, Color(1, 1, 1, 0.9))
			p.draw_circle(d.pos, 1.8, Color(1.0, 0.85, 0.25))
	# 路径
	for pa in _paths:
		var pts: PackedVector2Array = pa.pts
		if pts.size() < 2:
			continue
		p.draw_polyline(pts, COL_OUT, pa.w + 10.0, true)
		p.draw_polyline(pts, COL_PATH, pa.w, true)
	# 静态元素
	for e in _statics:
		if not _vis(p, e.pos, e.rad):
			continue
		match e.kind:
			"sun": _d_sun(p, e.pos)
			"banyan": _d_banyan(p, e)
			"tree": _d_tree(p, e)
			"bush": _d_bush(p, e)
			"bench": _d_bench(p, e)
			"kiosk": _d_kiosk(p, e)
			"lamp": _d_lamp(p, e)
			"bed": _d_bed(p, e)
			"slide": _d_slide(p, e)
			"swing": _d_swing_frame(p, e)
			"bin": _d_bin(p, e)
			"sign": _d_sign(p, e)
			"stone": _d_stone(p, e)
			"fence": _d_fence(p, e)
			"seesaw": _d_seesaw(p, e)
			"sandbox": _d_sandbox(p, e)
			"stall": _d_stall(p, e)
			"barrel": _d_barrel(p, e)
			"umbrella": _d_umbrella(p, e)
			"stump": _d_stump(p, e)
			"log": _d_log(p, e)
			"mushroom": _d_mushroom(p, e)
			"lake": _d_lake(p, e)
			"willow": _d_willow(p, e)
			"bridge": _d_bridge(p, e)
			"lily": _d_lily(p, e)
			"fountain": _d_fountain(p, e)
			"reed": _d_reed(p, e)
	# 动态元素（地面层；云与天空元素已在上面绘制）
	for i in _dyns.size():
		var e: Dictionary = _dyns[i]
		if e.kind == "cloud" or e.kind == "bird" or e.kind == "plane" or e.kind == "hotair":
			continue
		var st: Dictionary = _dyn_st_for(p, i)
		if not _vis(p, st.pos, e.rad):
			continue
		match e.kind:
			"visitor": _person(p, st.pos, e.h, e.shirt, e.skin, st.walk, st.face)
			"vendor": _d_vendor(p, e, st)
			"orbit_kid": _person(p, st.pos, 72.0, e.shirt, e.skin, st.walk, st.face)
			"swing_kid": _d_swing_kid(p, e, st)
			"dog": _d_dog(p, e, st)
			"cat": _d_cat(p, e, st)
			"bee": _d_bee(p, st.pos, st.flap)
			"butterfly": _d_butterfly(p, st.pos, st.flap, e.col)
			"balloon": _d_balloon(p, st.pos, e.anchor, e.col)
			"kite": _d_kite(p, st.pos, st.ang, st.face, e.col)
			"pigeon": _d_pigeon(p, st.pos, st.face, st.peck)
			"squirrel": _d_squirrel(p, st.pos, st.face, st.tail)
			"duck": _d_duck(p, st.pos, st.face, st.ripple)
			"swan": _d_swan(p, st.pos, st.face, st.bob)
			"dragonfly": _d_dragonfly(p, st.pos, st.flap, e.col)


func _vis(p: Painter, pos: Vector2, rad: float) -> bool:
	var q := pos.clamp(p.clip.position, p.clip.end)
	return q.distance_squared_to(pos) <= rad * rad


## 动态元素状态：主画面用当帧缓存，缩略图用记录相位冻结
func _dyn_st_for(p: Painter, i: int) -> Dictionary:
	if p.phase_ovr.has(i):
		return _dyn_state(_dyns[i], p.phase_ovr[i])
	return _dyns[i].st


## —— 基础图元 ——

func _rr(p: Painter, r: Rect2, rad: float, col: Color, border := 3.0) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.border_color = COL_OUT
	sb.set_border_width_all(int(border))
	sb.set_corner_radius_all(int(rad))
	p.draw_style_box(sb, r)


func _circ(p: Painter, c: Vector2, r: float, col: Color, w := OUT_W) -> void:
	p.draw_circle(c, r, col)
	if w > 0.0:
		p.draw_arc(c, r, 0, TAU, 40, COL_OUT, w, true)


func _ell(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 26:
		var a := TAU * i / 26.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


func _elli(p: Painter, c: Vector2, rx: float, ry: float, col: Color, w := OUT_W) -> void:
	var pts := _ell(c, rx, ry)
	p.draw_colored_polygon(pts, col)
	if w > 0.0:
		var closed := pts.duplicate()
		closed.append(pts[0])
		p.draw_polyline(closed, COL_OUT, w, true)


func _shadow(p: Painter, feet: Vector2, rx: float) -> void:
	p.draw_colored_polygon(_ell(feet + Vector2(0, 3), rx, rx * 0.26), COL_SHADOW)


## 先描边后填充的圆簇（云/树冠合并轮廓）
func _blob(p: Painter, cs: Array, rs: Array, col: Color, base: Vector2) -> void:
	for i in cs.size():
		p.draw_arc(base + cs[i], rs[i] + 2.0, 0, TAU, 36, COL_OUT, OUT_W, true)
	for i in cs.size():
		p.draw_circle(base + cs[i], rs[i], col)


## —— 静态元素 ——

func _d_sun(p: Painter, c: Vector2) -> void:
	for i in 10:
		var a := TAU * i / 10.0
		p.draw_line(c + Vector2.from_angle(a) * 86.0, c + Vector2.from_angle(a) * 116.0, COL_SUN_RAY, 7.0, true)
	_circ(p, c, 62.0, COL_SUN)


func _d_cloud(p: Painter, pos: Vector2, s: float) -> void:
	_blob(p, [Vector2(0, 0), Vector2(34 * s, -12 * s), Vector2(-34 * s, -8 * s), Vector2(2 * s, -22 * s)],
			[26.0 * s, 20.0 * s, 18.0 * s, 20.0 * s], COL_CLOUD, pos)


func _d_tree(p: Painter, e: Dictionary) -> void:
	var b: Vector2 = e.pos
	var s: float = e.s
	_shadow(p, b, 58.0 * s)
	_rr(p, Rect2(b + Vector2(-9.0 * s, -74.0 * s), Vector2(18.0 * s, 76.0 * s)), 6.0 * s, COL_TRUNK)
	_blob(p, [Vector2(0, -98 * s), Vector2(-27 * s, -74 * s), Vector2(27 * s, -74 * s)],
			[40.0 * s, 30.0 * s, 30.0 * s], COL_LEAF, b)
	p.draw_circle(b + Vector2(-30.0 * s, -86.0 * s), 9.0 * s, COL_LEAF_L)


func _d_banyan(p: Painter, e: Dictionary) -> void:
	var b: Vector2 = e.pos
	_shadow(p, b, 170.0)
	# 板根（中根为三角形；侧根为四边形，顶边按 x 降序连线绕行，避免自交致三角化失败）
	for rx in [-1.0, 0.0, 1.0]:
		if absf(rx) < 0.5:
			p.draw_colored_polygon(PackedVector2Array([b + Vector2(-26.0, 0), b + Vector2(26.0, 0),
					b + Vector2(0, -46.0)]), COL_TRUNK)
		else:
			var x1 := maxf(rx * 70.0, rx * 16.0)
			var x2 := minf(rx * 70.0, rx * 16.0)
			p.draw_colored_polygon(PackedVector2Array([b + Vector2(rx * 20.0 - 26.0, 0), b + Vector2(rx * 20.0 + 26.0, 0),
					b + Vector2(x1, -78.0), b + Vector2(x2, -78.0)]), COL_TRUNK)
	_rr(p, Rect2(b + Vector2(-34.0, -128.0), Vector2(68.0, 130.0)), 14.0, COL_TRUNK)
	_blob(p, [Vector2(0, -215), Vector2(-120, -170), Vector2(120, -170), Vector2(-70, -235), Vector2(70, -235)],
			[95.0, 78.0, 78.0, 70.0, 70.0], COL_BANYAN, b)
	# 垂下的气根
	for vx in [-100.0, -40.0, 55.0, 110.0]:
		var top := b + Vector2(vx, -170.0 + absf(vx) * 0.3)
		p.draw_line(top, top + Vector2(0, 46.0), COL_TRUNK, 4.0, true)
		p.draw_circle(top + Vector2(0, 48.0), 5.0, COL_TRUNK)


func _d_bush(p: Painter, e: Dictionary) -> void:
	var b: Vector2 = e.pos
	var s: float = e.s
	_blob(p, [Vector2(-18 * s, -14 * s), Vector2(18 * s, -14 * s), Vector2(0, -26 * s)],
			[18.0 * s, 18.0 * s, 20.0 * s], COL_BUSH, b)
	p.draw_circle(b + Vector2(-6.0 * s, -22.0 * s), 4.0 * s, COL_R_PERFECT)
	p.draw_circle(b + Vector2(12.0 * s, -12.0 * s), 4.0 * s, COL_R_FAIL)


func _d_bench(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	var f: float = e.flip
	_shadow(p, o, 46.0)
	_rr(p, Rect2(o + Vector2(-26.0 * f - 3.0, -26.0), Vector2(6.0, 26.0)), 2.0, COL_WOOD_D)
	_rr(p, Rect2(o + Vector2(20.0 * f - 3.0, -26.0), Vector2(6.0, 26.0)), 2.0, COL_WOOD_D)
	_rr(p, Rect2(o + Vector2(-34.0, -34.0), Vector2(68.0, 10.0)), 3.0, COL_WOOD)
	var bx := minf(20.0 * f, 34.0 * f)
	_rr(p, Rect2(o + Vector2(bx - 3.0, -58.0), Vector2(absf(34.0 * f - 20.0 * f) + 6.0, 28.0)), 3.0, COL_WOOD)
	# 板条缝
	p.draw_line(o + Vector2(-34.0, -29.0), o + Vector2(34.0, -29.0), COL_WOOD_D, 2.0, true)
	p.draw_line(o + Vector2(-34.0, -24.0), o + Vector2(34.0, -24.0), COL_WOOD_D, 2.0, true)


func _d_kiosk(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_shadow(p, o, 80.0)
	_rr(p, Rect2(o + Vector2(-55.0, -95.0), Vector2(110.0, 95.0)), 4.0, COL_KIOSK)
	_rr(p, Rect2(o + Vector2(-38.0, -78.0), Vector2(36.0, 42.0)), 4.0, COL_GLASS)
	_rr(p, Rect2(o + Vector2(10.0, -50.0), Vector2(34.0, 50.0)), 3.0, COL_WOOD)
	for i in 5:
		_rr(p, Rect2(o + Vector2(-62.0 + i * 25.0, -128.0), Vector2(25.0, 32.0)), 0.0,
				COL_AWNING if i % 2 == 0 else COL_AWNING2, 0.0)
	p.draw_rect(Rect2(o + Vector2(-62.0, -128.0), Vector2(125.0, 32.0)), COL_OUT, false, 3.0)


func _d_lamp(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_shadow(p, o, 22.0)
	p.draw_line(o, o + Vector2(0, -122.0), COL_POLE, 7.0, true)
	p.draw_line(o + Vector2(-9.0, 0), o + Vector2(9.0, 0), COL_POLE, 7.0, true)
	_circ(p, o + Vector2(0, -132.0), 14.0, COL_LAMP)
	_rr(p, Rect2(o + Vector2(-17.0, -154.0), Vector2(34.0, 10.0)), 4.0, COL_POLE)


func _d_bed(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_elli(p, o, e.rx, e.ry, COL_SOIL)
	for f in e.flowers:
		_circ(p, o + f.o, 7.5, f.c, 2.5)
		p.draw_circle(o + f.o, 2.6, Color(1.0, 0.85, 0.25))


func _d_slide(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	var f: float = e.flip
	_shadow(p, o + Vector2(40.0 * f, 0), 90.0)
	# 平台 + 支柱
	_rr(p, Rect2(o + Vector2(14.0 * f, -78.0), Vector2(52.0 * f, 12.0)), 3.0, COL_SLIDE)
	p.draw_line(o + Vector2(58.0 * f, -66.0), o + Vector2(58.0 * f, 0), COL_METAL, 6.0, true)
	# 梯子
	p.draw_line(o + Vector2(6.0 * f, 0), o + Vector2(6.0 * f, -78.0), COL_METAL, 5.0, true)
	p.draw_line(o + Vector2(24.0 * f, 0), o + Vector2(24.0 * f, -78.0), COL_METAL, 5.0, true)
	for i in 4:
		p.draw_line(o + Vector2(6.0 * f, -16.0 - i * 17.0), o + Vector2(24.0 * f, -16.0 - i * 17.0), COL_METAL, 4.0, true)
	# 滑道
	var chute := PackedVector2Array([o + Vector2(64.0 * f, -72.0), o + Vector2(112.0 * f, -34.0), o + Vector2(152.0 * f, 0)])
	p.draw_polyline(chute, COL_OUT, 26.0, true)
	p.draw_polyline(chute, COL_SLIDE, 18.0, true)


func _d_swing_frame(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_shadow(p, o, 70.0)
	p.draw_line(o + Vector2(-58.0, 0), o + Vector2(-20.0, -98.0), COL_METAL, 7.0, true)
	p.draw_line(o + Vector2(58.0, 0), o + Vector2(20.0, -98.0), COL_METAL, 7.0, true)
	p.draw_line(o + Vector2(-64.0, -98.0), o + Vector2(64.0, -98.0), COL_METAL, 8.0, true)


func _d_swing_kid(p: Painter, e: Dictionary, st: Dictionary) -> void:
	var pivot: Vector2 = e.pivot
	var seat: Vector2 = st.pos
	var ang: float = st.ang
	p.draw_line(pivot, seat + Vector2(-7.0, -14.0), COL_POLE, 3.0, true)
	p.draw_line(pivot, seat + Vector2(7.0, -14.0), COL_POLE, 3.0, true)
	_rr(p, Rect2(seat + Vector2(-13.0, -8.0), Vector2(26.0, 7.0)), 2.0, COL_WOOD)
	_person(p, seat + Vector2(0, -8.0), 60.0, e.shirt, e.skin, 0.0, 1.0)
	# 双手抓绳
	var sh := seat + Vector2(0, -8.0 - 60.0 * 0.62)
	p.draw_line(sh + Vector2(-8.0, 4.0), pivot.lerp(seat + Vector2(-7.0, -14.0), 0.55), e.skin, 5.0, true)
	p.draw_line(sh + Vector2(8.0, 4.0), pivot.lerp(seat + Vector2(7.0, -14.0), 0.55), e.skin, 5.0, true)


func _d_bin(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_shadow(p, o, 26.0)
	_rr(p, Rect2(o + Vector2(-17.0, -42.0), Vector2(34.0, 42.0)), 6.0, COL_BIN)
	_rr(p, Rect2(o + Vector2(-20.0, -50.0), Vector2(40.0, 10.0)), 4.0, COL_BIN.darkened(0.25))
	_rr(p, Rect2(o + Vector2(-10.0, -47.0), Vector2(20.0, 4.0)), 2.0, Color(0.15, 0.2, 0.15))


func _d_sign(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_shadow(p, o, 20.0)
	p.draw_line(o, o + Vector2(0, -72.0), COL_TRUNK, 6.0, true)
	_rr(p, Rect2(o + Vector2(-6.0, -112.0), Vector2(76.0, 40.0)), 6.0, COL_SIGN)
	var a := o + Vector2(6.0, -100.0)
	p.draw_colored_polygon(PackedVector2Array([a, a + Vector2(30.0, 0), a + Vector2(30.0, -7.0),
			a + Vector2(48.0, 5.0), a + Vector2(30.0, 17.0), a + Vector2(30.0, 10.0), a + Vector2(0, 10.0)]), COL_OUT)


func _d_stone(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_shadow(p, o, 60.0)
	_rr(p, Rect2(o + Vector2(-9.0, -50.0), Vector2(18.0, 50.0)), 3.0, COL_STONE_D)
	_elli(p, o + Vector2(0, -54.0), 44.0, 13.0, COL_STONE)
	for sx in [-66.0, 66.0]:
		_rr(p, Rect2(o + Vector2(sx - 13.0, -16.0), Vector2(26.0, 16.0)), 4.0, COL_STONE_D)
		_elli(p, o + Vector2(sx, -16.0), 15.0, 5.0, COL_STONE, 2.5)


func _d_fence(p: Painter, e: Dictionary) -> void:
	var a: Vector2 = e.a
	var b: Vector2 = e.b
	var seg_len := a.distance_to(b)
	var dir := (b - a).normalized()
	p.draw_line(a + Vector2(0, -30.0), b + Vector2(0, -30.0), COL_OUT, 8.0, true)
	p.draw_line(a + Vector2(0, -30.0), b + Vector2(0, -30.0), COL_FENCE, 5.0, true)
	p.draw_line(a + Vector2(0, -14.0), b + Vector2(0, -14.0), COL_OUT, 8.0, true)
	p.draw_line(a + Vector2(0, -14.0), b + Vector2(0, -14.0), COL_FENCE, 5.0, true)
	var d := 0.0
	while d <= seg_len:
		var pt := a + dir * d
		_rr(p, Rect2(pt + Vector2(-5.0, -38.0), Vector2(10.0, 38.0)), 2.0, COL_FENCE)
		d += 150.0


## —— 人物与动物 ——

func _person(p: Painter, feet: Vector2, h: float, shirt: Color, skin: Color, walk: float, face: float) -> void:
	_shadow(p, feet, h * 0.30)
	var hip := feet + Vector2(0, -h * 0.42)
	var sw := sin(walk * TAU) * h * 0.14
	p.draw_line(hip + Vector2(-h * 0.07, 0), feet + Vector2(-h * 0.07 + sw, 0), COL_PANTS, h * 0.10, true)
	p.draw_line(hip + Vector2(h * 0.07, 0), feet + Vector2(h * 0.07 - sw, 0), COL_PANTS, h * 0.10, true)
	_rr(p, Rect2(feet + Vector2(-h * 0.17, -h * 0.80), Vector2(h * 0.34, h * 0.44)), h * 0.10, shirt)
	p.draw_line(feet + Vector2(-h * 0.13, -h * 0.72), feet + Vector2(-h * 0.16 - sw * 0.5, -h * 0.44), skin, h * 0.08, true)
	p.draw_line(feet + Vector2(h * 0.13, -h * 0.72), feet + Vector2(h * 0.16 + sw * 0.5, -h * 0.44), skin, h * 0.08, true)
	var head := feet + Vector2(0, -h * 0.90)
	_circ(p, head, h * 0.15, skin, h * 0.05)
	p.draw_arc(head, h * 0.15, PI, TAU, 20, Color(0.25, 0.17, 0.12), h * 0.09, true)


## —— 新增静态元素（第四轮丰富化）——

func _d_seesaw(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	var f: float = e.get("flip", 1.0)
	_shadow(p, c, 120.0)
	var ang := 0.24 * f
	var dir := Vector2(cos(ang), sin(ang))
	var a := c + Vector2(0, -34) - dir * 120.0
	var b2 := c + Vector2(0, -34) + dir * 120.0
	# 支点三角
	p.draw_colored_polygon(PackedVector2Array([c + Vector2(-30, 6), c + Vector2(30, 6), c + Vector2(0, -36)]), COL_WOOD_D)
	p.draw_polyline(PackedVector2Array([c + Vector2(-30, 6), c + Vector2(0, -36), c + Vector2(30, 6), c + Vector2(-30, 6)]), COL_OUT, OUT_W, true)
	# 板（描边线 + 板色线）
	p.draw_line(a, b2, COL_OUT, 20.0, true)
	p.draw_line(a, b2, COL_WOOD, 13.0, true)
	# 两端把手 + 座垫
	for pt in [a, b2]:
		_circ(p, pt + Vector2(0, -12), 7.0, COL_METAL, 3.0)
		p.draw_line(pt + Vector2(-14, 2), pt + Vector2(14, 2), COL_SLIDE, 8.0, true)


func _d_sandbox(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	_shadow(p, c, 132.0)
	_rr(p, Rect2(c - Vector2(130, 66), Vector2(260, 132)), 18.0, COL_WOOD, 4.0)
	_rr(p, Rect2(c - Vector2(112, 50), Vector2(224, 100)), 12.0, COL_SAND, 3.0)
	# 沙面波纹
	for i in 3:
		p.draw_arc(c + Vector2(-44 + i * 44, 10), 26.0, 3.5, 5.9, 12, COL_SAND_D, 3.0, true)
	# 小桶 + 铲子
	_rr(p, Rect2(c + Vector2(36, -20), Vector2(26, 26)), 4.0, COL_SLIDE, 3.0)
	p.draw_line(c + Vector2(-60, -12), c + Vector2(-36, 6), COL_METAL, 6.0, true)
	_circ(p, c + Vector2(-62, -15), 6.0, COL_METAL, 2.5)


func _d_stall(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	_shadow(p, c, 100.0)
	# 两根柱
	for sx in [-74.0, 74.0]:
		p.draw_line(c + Vector2(sx, -8), c + Vector2(sx, -122), COL_WOOD_D, 9.0, true)
	# 柜台 + 货物
	_rr(p, Rect2(c + Vector2(-82, -54), Vector2(164, 48)), 6.0, COL_WOOD, 3.0)
	for i in 3:
		_circ(p, c + Vector2(-48 + i * 48, -62), 10.0, FLOWERS[i % FLOWERS.size()], 2.5)
	# 条纹棚顶（底边波浪圆）
	var aw := Rect2(c + Vector2(-96, -178), Vector2(192, 52))
	for i in 6:
		var seg := Rect2(aw.position + Vector2(i * 32, 0), Vector2(32, aw.size.y))
		p.draw_rect(seg, COL_AWNING if i % 2 == 0 else COL_AWNING2)
		p.draw_circle(aw.position + Vector2(i * 32 + 16, aw.size.y), 16.0, COL_AWNING if i % 2 == 0 else COL_AWNING2)
	p.draw_rect(aw, COL_OUT, false, OUT_W)


func _d_barrel(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	var s: float = e.get("s", 1.0)
	_shadow(p, c, 34.0 * s)
	_rr(p, Rect2(c + Vector2(-30 * s, -110 * s), Vector2(60 * s, 110 * s)), 22.0, COL_BARREL, 4.0)
	for yy in [-78.0, -30.0]:
		p.draw_line(c + Vector2(-30 * s, yy * s), c + Vector2(30 * s, yy * s), COL_METAL, 6.0 * s, true)
	_elli(p, c + Vector2(0, -110 * s), 28.0 * s, 9.0 * s, COL_WOOD, 3.0)


func _d_umbrella(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	var s: float = e.get("s", 1.0)
	_shadow(p, c, 30.0 * s)
	p.draw_line(c, c + Vector2(0, -150 * s), COL_POLE, 8.0 * s, true)
	# 伞面：8 瓣半圆交替色
	var top := c + Vector2(0, -150 * s)
	var R := 105.0 * s
	for i in 8:
		var a0 := PI + PI * i / 8.0
		var a1 := PI + PI * (i + 1) / 8.0
		var pts := PackedVector2Array([top])
		for k in 7:
			pts.append(top + Vector2.from_angle(a0 + (a1 - a0) * k / 6.0) * R)
		p.draw_colored_polygon(pts, COL_UM1 if i % 2 == 0 else COL_UM2)
	p.draw_arc(top, R, PI, TAU, 40, COL_OUT, OUT_W, true)
	p.draw_line(top + Vector2(-R, 0), top + Vector2(R, 0), COL_OUT, OUT_W, true)
	p.draw_line(top, top + Vector2(0, -16 * s), COL_POLE, 5.0 * s, true)


func _d_stump(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	var s: float = e.get("s", 1.0)
	_shadow(p, c, 44.0 * s)
	_rr(p, Rect2(c + Vector2(-36 * s, -74 * s), Vector2(72 * s, 74 * s)), 8.0, COL_STUMP, 4.0)
	# 侧根
	p.draw_line(c + Vector2(-36 * s, -6 * s), c + Vector2(-54 * s, 4 * s), COL_STUMP, 8.0 * s, true)
	p.draw_line(c + Vector2(36 * s, -6 * s), c + Vector2(54 * s, 4 * s), COL_STUMP, 8.0 * s, true)
	# 顶面年轮
	var tc := c + Vector2(0, -74 * s)
	_elli(p, tc, 36.0 * s, 13.0 * s, COL_WOOD, 3.0)
	_elli(p, tc, 22.0 * s, 8.0 * s, COL_WOOD_D, 2.5)
	_elli(p, tc, 8.0 * s, 3.0 * s, COL_SOIL, 0.0)


func _d_log(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	var s: float = e.get("s", 1.0)
	_shadow(p, c, 90.0 * s)
	_rr(p, Rect2(c + Vector2(-95 * s, -34 * s), Vector2(190 * s, 56 * s)), 26.0, COL_BARREL, 4.0)
	# 木纹
	p.draw_line(c + Vector2(-70 * s, -12 * s), c + Vector2(-20 * s, -12 * s), COL_WOOD_D, 4.0 * s, true)
	p.draw_line(c + Vector2(10 * s, 6 * s), c + Vector2(70 * s, 6 * s), COL_WOOD_D, 4.0 * s, true)
	# 右端面年轮
	var fc := c + Vector2(95 * s, -6 * s)
	_elli(p, fc, 16.0 * s, 28.0 * s, COL_STUMP, 3.0)
	_elli(p, fc, 8.0 * s, 14.0 * s, COL_WOOD_D, 0.0)


func _d_mushroom(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	var s: float = e.get("s", 1.0)
	_shadow(p, c, 20.0 * s)
	# 柄 + 伞盖 + 白点
	_rr(p, Rect2(c + Vector2(-9 * s, -40 * s), Vector2(18 * s, 40 * s)), 6.0, Color(0.96, 0.93, 0.85), 3.0)
	_elli(p, c + Vector2(0, -46 * s), 34.0 * s, 24.0 * s, COL_SLIDE, 3.0)
	for o in [Vector2(-14, -54), Vector2(4, -62), Vector2(18, -46)]:
		p.draw_circle(c + Vector2(o.x * s, o.y * s), 4.5 * s, COL_CLOUD)


## —— 湖畔区静态元素（第五轮新增分区）——

func _d_lake(p: Painter, e: Dictionary) -> void:
	var c: Vector2 = e.pos
	_elli(p, c, e.rx, e.ry, COL_OUT, 6.0)          # 深色底=岸线描边
	_elli(p, c, e.rx - 6.0, e.ry - 6.0, COL_WATER, 0.0)
	# 波光三段
	for dy in [-0.45, 0.1, 0.55]:
		var ry2: float = e.ry * dy
		var rx2: float = e.rx * (0.55 + 0.3 * absf(dy))
		p.draw_line(c + Vector2(-rx2 * 0.55, ry2), c + Vector2(rx2 * 0.55, ry2), COL_WATER_L, 4.0, true)
		p.draw_line(c + Vector2(-rx2 * 0.2, ry2 + 14.0), c + Vector2(rx2 * 0.1, ry2 + 14.0), COL_WATER_L, 3.0, true)


func _d_willow(p: Painter, e: Dictionary) -> void:
	var b: Vector2 = e.pos
	var s: float = e.s
	_shadow(p, b, 60.0 * s)
	_rr(p, Rect2(b + Vector2(-10.0 * s, -80.0 * s), Vector2(20.0 * s, 82.0 * s)), 7.0 * s, COL_TRUNK)
	# 树冠
	_blob(p, [Vector2(0, -110 * s), Vector2(-34 * s, -88 * s), Vector2(34 * s, -88 * s)],
			[38.0 * s, 28.0 * s, 28.0 * s], COL_WILLOW, b)
	# 垂枝五缕（随风弯的细线 + 末端小叶）
	for i in 5:
		var bx := (-52.0 + 26.0 * i) * s
		var top := b + Vector2(bx * 0.8, -96.0 * s)
		var mid := top + Vector2(bx * 0.35, 34.0 * s)
		var tip := mid + Vector2(bx * 0.2, 52.0 * s)
		p.draw_polyline(PackedVector2Array([top, mid, tip]), COL_WILLOW, 4.0 * s, true)
		p.draw_circle(tip, 4.0 * s, COL_WILLOW.lightened(0.15))


func _d_bridge(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	# 石拱桥：拱洞 + 桥面 + 栏杆
	p.draw_colored_polygon(PackedVector2Array([o + Vector2(-190, 30), o + Vector2(190, 30),
			o + Vector2(160, -40), o + Vector2(-160, -40)]), COL_STONE_D)
	p.draw_circle(o + Vector2(0, 30), 60.0, COL_WATER.darkened(0.15))
	_rr(p, Rect2(o + Vector2(-200, -58), Vector2(400, 26)), 6.0, COL_STONE)
	p.draw_line(o + Vector2(-190, -32), o + Vector2(190, -32), COL_OUT, 3.0, true)
	for i in 6:
		var bx := -165.0 + i * 66.0
		p.draw_line(o + Vector2(bx, -32), o + Vector2(bx, -58), COL_OUT, 4.0, true)
		p.draw_circle(o + Vector2(bx, -62), 4.5, COL_STONE_D)


func _d_lily(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	var s: float = e.s
	_elli(p, o, 20.0 * s, 8.0 * s, COL_WILLOW.lightened(0.1), 2.5)
	p.draw_line(o, o + Vector2(16.0 * s, -6.0 * s), COL_GRASS.darkened(0.15), 2.5, true)   # 叶缺刻
	if s > 0.95:   # 部分荷叶开花
		_circ(p, o + Vector2(0, -8.0 * s), 6.5 * s, COL_LOTUS, 2.0)
		p.draw_circle(o + Vector2(0, -8.0 * s), 2.2 * s, COL_SUN)


func _d_fountain(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	_elli(p, o, 90.0, 30.0, COL_STONE, 4.0)
	_elli(p, o, 76.0, 24.0, COL_WATER_L, 0.0)
	_rr(p, Rect2(o + Vector2(-10, -60), Vector2(20, 56)), 4.0, COL_STONE_D)
	# 水柱 + 落水珠
	p.draw_line(o + Vector2(0, -60), o + Vector2(0, -120), COL_WATER_L, 7.0, true)
	p.draw_line(o + Vector2(0, -60), o + Vector2(0, -120), Color(1, 1, 1, 0.5), 3.0, true)
	for dx in [-34.0, -20.0, 20.0, 34.0]:
		p.draw_circle(o + Vector2(dx, -78 + absf(dx) * 0.6), 4.0, COL_WATER_L)
		p.draw_circle(o + Vector2(dx * 1.4, -40 + absf(dx) * 0.3), 3.0, COL_WATER_L)


func _d_reed(p: Painter, e: Dictionary) -> void:
	var o: Vector2 = e.pos
	var s: float = e.s
	for i in 4:
		var bx := (-12.0 + 8.0 * i) * s
		var h := (58.0 + 9.0 * (i % 3)) * s
		var sway := 5.0 * sin(float(i) * 1.7)
		p.draw_line(o + Vector2(bx, 0), o + Vector2(bx + sway, -h), COL_REED, 3.5 * s, true)
		_elli(p, o + Vector2(bx + sway, -h - 7.0 * s), 3.2 * s, 9.0 * s, COL_REED.darkened(0.18), 0.0)


## —— 新增动态元素（第四轮丰富化）——

func _d_kite(p: Painter, pos: Vector2, ang: float, face: float, col: Color) -> void:
	p.draw_set_transform(pos, ang * face, Vector2(face, 1.0))
	var w := 34.0
	var h := 46.0
	var pts := PackedVector2Array([Vector2(0, -h), Vector2(w, 0), Vector2(0, h * 0.55), Vector2(-w, 0), Vector2(0, -h)])
	p.draw_colored_polygon(PackedVector2Array([Vector2(0, -h), Vector2(w, 0), Vector2(0, h * 0.55), Vector2(-w, 0)]), col)
	p.draw_polyline(pts, COL_OUT, 3.0, true)
	# 骨架
	p.draw_line(Vector2(0, -h), Vector2(0, h * 0.55), COL_OUT, 3.0, true)
	p.draw_line(Vector2(-w, 0), Vector2(w, 0), COL_OUT, 3.0, true)
	# 尾巴三节
	for i in 3:
		var ty := h * 0.55 + 16.0 + i * 17.0
		p.draw_circle(Vector2(sin(float(i) * 2.1) * 10.0, ty), 7.0 - i, col.darkened(0.15 * (i + 1)))
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _d_pigeon(p: Painter, pos: Vector2, face: float, peck: float) -> void:
	_shadow(p, pos, 16.0)
	var head_y := -13.0 if peck < 0.3 else -20.0   # 低头啄食
	p.draw_set_transform(pos, 0.0, Vector2(face, 1.0))
	# 身体
	var bd := _ell(Vector2(0, -12), 16.0, 11.0)
	p.draw_colored_polygon(bd, COL_PIG)
	bd.append(bd[0])
	p.draw_polyline(bd, COL_OUT, 2.5, true)
	# 翅膀斑 + 尾
	p.draw_colored_polygon(_ell(Vector2(-2, -14), 9.0, 6.0), COL_STONE_D)
	p.draw_line(Vector2(-14, -10), Vector2(-24, -14), COL_STONE_D, 5.0, true)
	# 头 + 喙
	_circ(p, Vector2(10, head_y), 7.5, COL_PIG, 2.5)
	p.draw_line(Vector2(16, head_y), Vector2(23, head_y + 1.5), Color(0.95, 0.62, 0.20), 4.0, true)
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _d_squirrel(p: Painter, pos: Vector2, face: float, tw: float) -> void:
	_shadow(p, pos, 14.0)
	p.draw_set_transform(pos, 0.0, Vector2(face, 1.0))
	# 大尾巴（上卷圆簇）
	for i in 4:
		var tt := fposmod(tw + float(i) * 0.25, 1.0)
		var off := Vector2(-14.0 - 4.0 * i, -10.0 - i * 13.0 + 3.0 * sin(TAU * tt))
		_circ(p, off, 11.0 - i * 1.6, COL_SQ if i < 2 else COL_SQ_D, 2.5)
	# 身体 + 头 + 耳
	var bd := _ell(Vector2(0, -10), 13.0, 10.0)
	p.draw_colored_polygon(bd, COL_SQ)
	bd.append(bd[0])
	p.draw_polyline(bd, COL_OUT, 2.5, true)
	_circ(p, Vector2(10, -16), 7.0, COL_SQ, 2.5)
	for ex in [6.0, 13.0]:
		_circ(p, Vector2(ex, -24), 3.0, COL_SQ_D, 2.0)
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## —— 湖畔区动态元素（第五轮新增分区）——

func _d_duck(p: Painter, pos: Vector2, face: float, ripple: float) -> void:
	# 水波圈（游动尾迹）
	p.draw_arc(pos, 16.0 + ripple * 22.0, 0, TAU, 24, Color(1, 1, 1, 0.55 * (1.0 - ripple)), 2.0, true)
	p.draw_set_transform(pos, 0.0, Vector2(face, 1.0))
	# 身体 + 尾尖
	_elli(p, Vector2(0, -10), 16.0, 10.0, COL_DUCK)
	p.draw_colored_polygon(PackedVector2Array([Vector2(-14, -12), Vector2(-26, -18), Vector2(-13, -5)]), COL_DUCK.darkened(0.15))
	# 头颈（绿头）+ 喙
	_circ(p, Vector2(11, -22), 7.5, Color(0.20, 0.52, 0.30), 2.5)
	p.draw_line(Vector2(17, -22), Vector2(25, -20), COL_SUN_RAY, 4.0, true)
	p.draw_circle(Vector2(13, -24), 1.4, COL_OUT)
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _d_swan(p: Painter, pos: Vector2, face: float, bob: float) -> void:
	var o := pos + Vector2(0, bob * 2.5)
	p.draw_arc(pos, 20.0 + (bob + 1.0) * 10.0, 0, TAU, 24, Color(1, 1, 1, 0.4), 2.0, true)
	p.draw_set_transform(o, 0.0, Vector2(face, 1.0))
	# 身体（白椭圆）+ 翅影
	_elli(p, Vector2(0, -14), 24.0, 13.0, COL_SWAN)
	_elli(p, Vector2(-4, -18), 15.0, 8.0, COL_SWAN.darkened(0.06))
	# S 形长颈 + 头
	p.draw_polyline(PackedVector2Array([Vector2(14, -18), Vector2(22, -30), Vector2(20, -44), Vector2(26, -52)]),
			COL_SWAN, 6.5, true)
	_circ(p, Vector2(28, -54), 6.0, COL_SWAN, 2.0)
	# 橙喙 + 眼
	p.draw_colored_polygon(PackedVector2Array([Vector2(33, -55), Vector2(41, -53), Vector2(33, -51)]), COL_SUN_RAY)
	p.draw_circle(Vector2(29, -56), 1.3, COL_OUT)
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _d_dragonfly(p: Painter, pos: Vector2, flap: float, col: Color) -> void:
	# 四翼（上下扑动）
	var wx := 6.0 + flap * 7.0
	for pair in [[-1.0, -1.0], [1.0, -1.0], [-1.0, 1.0], [1.0, 1.0]]:
		var wy: float = 5.0 * pair[1]
		p.draw_line(pos, pos + Vector2(wx * pair[0], wy - 3.0 * flap * pair[1]), Color(1, 1, 1, 0.75), 2.5, true)
	# 长尾分节
	p.draw_line(pos + Vector2(0, -2), pos + Vector2(0, 20), col, 3.5, true)
	for i in 4:
		p.draw_circle(pos + Vector2(0, 2.0 + i * 5.0), 2.0, col.darkened(0.2))
	# 头 + 眼
	_circ(p, pos + Vector2(0, -6), 5.0, col, 2.0)
	p.draw_circle(pos + Vector2(-2.5, -8), 2.2, Color(0.15, 0.15, 0.18))
	p.draw_circle(pos + Vector2(2.5, -8), 2.2, Color(0.15, 0.15, 0.18))


func _d_vendor(p: Painter, e: Dictionary, st: Dictionary) -> void:
	_person(p, st.pos, 90.0, Color(0.95, 0.95, 0.92), e.skin, st.walk, st.face)
	_rr(p, Rect2(st.pos + Vector2(-14.0, -52.0), Vector2(28.0, 24.0)), 4.0, COL_R_FAIL)


func _d_dog(p: Painter, e: Dictionary, st: Dictionary) -> void:
	var o: Vector2 = st.pos
	var f: float = st.face
	_shadow(p, o, 34.0)
	var body := o + Vector2(0, -24.0)
	for i in 4:
		var lx := (-22.0 + i * 15.0) * f
		var lw := sin(st.walk * TAU + i * PI * 0.7) * 9.0
		p.draw_line(body + Vector2(lx, 4.0), o + Vector2(lx + lw, 0), e.col, 6.0, true)
	_elli(p, body, 30.0, 15.0, e.col)
	var head := o + Vector2(36.0 * f, -36.0)
	_circ(p, head, 13.0, e.col)
	# 耳朵
	p.draw_colored_polygon(PackedVector2Array([head + Vector2(-4.0 * f, -10.0), head + Vector2(4.0 * f, -10.0),
			head + Vector2(0.0, -22.0)]), e.col.darkened(0.25))
	p.draw_circle(head + Vector2(7.0 * f, -2.0), 2.2, COL_OUT)
	# 尾巴摇摆
	var wag := sin(st.walk * TAU * 2.0) * 12.0
	p.draw_line(body + Vector2(-28.0 * f, -4.0), body + Vector2(-44.0 * f, -20.0 + wag), e.col, 6.0, true)


func _d_cat(p: Painter, e: Dictionary, st: Dictionary) -> void:
	var o: Vector2 = st.pos
	var f: float = st.face
	_shadow(p, o, 24.0)
	var body := o + Vector2(0, -14.0)
	for i in 4:
		var lx := (-13.0 + i * 9.0) * f
		var lw := sin(st.walk * TAU + i * PI * 0.7) * 5.0
		p.draw_line(body + Vector2(lx, 3.0), o + Vector2(lx + lw, 0), e.col, 4.0, true)
	_elli(p, body, 19.0, 10.0, e.col)
	var head := o + Vector2(22.0 * f, -22.0)
	_circ(p, head, 9.0, e.col)
	p.draw_colored_polygon(PackedVector2Array([head + Vector2(-6.0 * f, -6.0), head + Vector2(-1.0 * f, -6.0),
			head + Vector2(-5.0 * f, -14.0)]), e.col)
	p.draw_colored_polygon(PackedVector2Array([head + Vector2(2.0 * f, -6.0), head + Vector2(6.0 * f, -6.0),
			head + Vector2(6.0 * f, -14.0)]), e.col)
	p.draw_circle(head + Vector2(4.0 * f, -1.0), 1.6, COL_OUT)
	# 上翘尾巴
	p.draw_polyline(PackedVector2Array([body + Vector2(-17.0 * f, -4.0), body + Vector2(-28.0 * f, -14.0),
			body + Vector2(-26.0 * f, -26.0)]), e.col, 4.0, true)


func _d_bee(p: Painter, pos: Vector2, flap: float) -> void:
	var wy := -10.0 - flap * 5.0
	p.draw_circle(pos + Vector2(-6.0, wy), 5.5, Color(1, 1, 1, 0.85))
	p.draw_circle(pos + Vector2(6.0, wy), 5.5, Color(1, 1, 1, 0.85))
	_circ(p, pos, 9.0, COL_BEE, 2.5)
	p.draw_line(pos + Vector2(-3.0, -8.0), pos + Vector2(-3.0, 8.0), COL_OUT, 3.0, true)
	p.draw_line(pos + Vector2(3.0, -8.0), pos + Vector2(3.0, 8.0), COL_OUT, 3.0, true)


func _d_butterfly(p: Painter, pos: Vector2, flap: float, col: Color) -> void:
	var wx := 4.0 + flap * 6.0
	p.draw_line(pos + Vector2(0, -7.0), pos + Vector2(0, 7.0), COL_OUT, 3.0, true)
	p.draw_circle(pos + Vector2(-wx, -4.0), 6.0, col)
	p.draw_circle(pos + Vector2(wx, -4.0), 6.0, col)
	p.draw_circle(pos + Vector2(-wx * 0.7, 4.0), 4.5, col.lightened(0.2))
	p.draw_circle(pos + Vector2(wx * 0.7, 4.0), 4.5, col.lightened(0.2))


func _d_balloon(p: Painter, pos: Vector2, anchor: Vector2, col: Color) -> void:
	var mid := (pos + anchor) * 0.5 + Vector2(12.0, 0)
	p.draw_polyline(PackedVector2Array([anchor, mid, pos]), COL_OUT, 2.0, true)
	_circ(p, pos, 17.0, col)
	p.draw_circle(pos + Vector2(-5.0, -6.0), 4.0, Color(1, 1, 1, 0.7))
	p.draw_colored_polygon(PackedVector2Array([pos + Vector2(0, 16.0), pos + Vector2(-4.0, 23.0),
			pos + Vector2(4.0, 23.0)]), col)


## —— 天空动态元素 ——

func _d_bird(p: Painter, pos: Vector2, f: float, flap: float, col: Color) -> void:
	# 尾羽
	p.draw_colored_polygon(PackedVector2Array([pos + Vector2(-9.0 * f, -2.0), pos + Vector2(-17.0 * f, -6.0),
			pos + Vector2(-17.0 * f, 1.0)]), col.darkened(0.2))
	# 身体与头
	_elli(p, pos, 12.0, 7.5, col)
	_circ(p, pos + Vector2(9.0 * f, -5.0), 6.0, col, 2.5)
	# 喙与眼
	p.draw_colored_polygon(PackedVector2Array([pos + Vector2(14.0 * f, -7.0), pos + Vector2(21.0 * f, -4.5),
			pos + Vector2(14.0 * f, -2.5)]), COL_SUN_RAY)
	p.draw_circle(pos + Vector2(10.5 * f, -6.0), 1.5, COL_OUT)
	# 双翅（flap 0..1 上下扇动）
	var tip := pos + Vector2(-2.0 * f, -17.0 * flap - 3.0)
	p.draw_colored_polygon(PackedVector2Array([pos + Vector2(3.0 * f, -3.0), tip,
			pos + Vector2(-6.0 * f, 1.0)]), col.lightened(0.18))
	p.draw_line(pos + Vector2(3.0 * f, -3.0), tip, COL_OUT, 2.0, true)
	p.draw_line(tip, pos + Vector2(-6.0 * f, 1.0), COL_OUT, 2.0, true)


func _d_plane(p: Painter, pos: Vector2, f: float, ang: float, prop: float) -> void:
	# 局部系绘制：f 镜像朝向，ang*f 保证镜像后俯仰方向仍与世界一致
	p.draw_set_transform(pos, ang * f, Vector2(f, 1.0))
	# 机翼（侧视：机身下侧后掠）
	p.draw_colored_polygon(PackedVector2Array([Vector2(10.0, 2.0), Vector2(-12.0, 24.0),
			Vector2(-24.0, 24.0), Vector2(-8.0, 2.0)]), COL_PLANE_R)
	# 机身 + 机鼻
	_rr(p, Rect2(Vector2(-34.0, -9.0), Vector2(72.0, 18.0)), 9.0, COL_PLANE)
	p.draw_colored_polygon(PackedVector2Array([Vector2(38.0, -9.0), Vector2(50.0, 0.0),
			Vector2(38.0, 9.0)]), COL_PLANE_R)
	# 座舱与舷窗
	_circ(p, Vector2(20.0, -3.0), 5.5, COL_GLASS, 2.0)
	for wx in [-4.0, -14.0, -24.0]:
		p.draw_circle(Vector2(wx, 0.0), 2.6, COL_GLASS)
	# 尾翼
	p.draw_colored_polygon(PackedVector2Array([Vector2(-30.0, -8.0), Vector2(-42.0, -26.0),
			Vector2(-33.0, -26.0), Vector2(-24.0, -8.0)]), COL_PLANE_R)
	p.draw_colored_polygon(PackedVector2Array([Vector2(-32.0, 4.0), Vector2(-44.0, 12.0),
			Vector2(-32.0, 12.0)]), COL_PLANE_R)
	# 螺旋桨（侧视：竖直桨叶长度随相位旋转变化）
	var bl := 26.0 * absf(sin(prop * TAU))
	p.draw_line(Vector2(52.0, -bl), Vector2(52.0, bl), COL_OUT, 4.0, true)
	p.draw_circle(Vector2(52.0, 0.0), 3.5, COL_OUT)
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)   # 复位，避免污染后续绘制


func _d_hotair(p: Painter, pos: Vector2, sway: float, col: Color) -> void:
	p.draw_set_transform(pos, sway, Vector2.ONE)
	# 球皮 + 竖条纹 + 高光
	_circ(p, Vector2(0, -26.0), 34.0, col)
	for sx in [-12.0, 12.0]:
		p.draw_line(Vector2(sx, -56.0), Vector2(sx, 4.0), col.darkened(0.15), 5.0, true)
	p.draw_circle(Vector2(-11.0, -37.0), 7.0, Color(1, 1, 1, 0.55))
	# 收口
	p.draw_colored_polygon(PackedVector2Array([Vector2(-10.0, 6.0), Vector2(10.0, 6.0),
			Vector2(0.0, 17.0)]), col.darkened(0.2))
	# 吊绳 + 吊篮
	p.draw_line(Vector2(-8.0, 8.0), Vector2(-8.0, 18.0), COL_OUT, 2.0, true)
	p.draw_line(Vector2(8.0, 8.0), Vector2(8.0, 18.0), COL_OUT, 2.0, true)
	p.draw_rect(Rect2(Vector2(-10.0, 17.0), Vector2(20.0, 13.0)), COL_WOOD)
	p.draw_rect(Rect2(Vector2(-10.0, 17.0), Vector2(20.0, 13.0)), COL_OUT, false, 2.5)
	p.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)   # 复位，避免污染后续绘制


## ===== 屏幕层特效（取景框 / 工具栏 / 白闪） =====

func _draw_scene_fx(p: Painter) -> void:
	var vp := get_viewport_rect().size
	# 取景框（屏幕 70% 居中）外遮罩：上/下/左/右四条压暗带
	var vf := _vf_rect()
	var dim := Color(0.09, 0.12, 0.11, 0.62)
	p.draw_rect(Rect2(0, 0, vp.x, vf.position.y), dim)
	p.draw_rect(Rect2(0, vf.end.y, vp.x, vp.y - vf.end.y), dim)
	p.draw_rect(Rect2(0, vf.position.y, vf.position.x, vf.size.y), dim)
	p.draw_rect(Rect2(vf.end.x, vf.position.y, vp.x - vf.end.x, vf.size.y), dim)
	# 取景框四角
	var l := 46.0
	var pts := [vf.position, Vector2(vf.end.x, vf.position.y), vf.end, Vector2(vf.position.x, vf.end.y)]
	var dirs := [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	for i in 4:
		var c: Vector2 = pts[i]
		var d: Vector2 = dirs[i]
		p.draw_line(c, c + Vector2(l * d.x, 0), COL_OUT, 9.0, true)
		p.draw_line(c, c + Vector2(0, l * d.y), COL_OUT, 9.0, true)
		p.draw_line(c, c + Vector2(l * d.x, 0), Color.WHITE, 5.0, true)
		p.draw_line(c, c + Vector2(0, l * d.y), Color.WHITE, 5.0, true)
	# 底部工具栏
	var m := minf(vp.x, vp.y)
	var st_c: Vector2 = _tool.get("shutter", Vector2(vp.x * 0.5, vp.y - 90.0))
	var sc := 1.0 - (0.08 if _press.has("shutter") else 0.0)
	var r := m * 0.052 * sc
	p.draw_circle(st_c, r + 4.0, COL_OUT)
	p.draw_circle(st_c, r, Color(0.93, 0.34, 0.28))
	p.draw_arc(st_c, r * 0.66, 0, TAU, 48, Color.WHITE, 5.0, true)
	for pair in [["zoom_in", "+"], ["zoom_out", "-"]]:
		var c2: Vector2 = _tool.get(pair[0], Vector2.ZERO)
		var sc2 := 1.0 - (0.08 if _press.has(pair[0]) else 0.0)
		var r2 := m * 0.032 * sc2
		p.draw_circle(c2, r2 + 4.0, COL_OUT)
		p.draw_circle(c2, r2, Color(0.96, 0.94, 0.88))
		var gl := r2 * 0.55
		p.draw_line(c2 + Vector2(-gl, 0), c2 + Vector2(gl, 0), COL_OUT, 6.0, true)
		if pair[1] == "+":
			p.draw_line(c2 + Vector2(0, -gl), c2 + Vector2(0, gl), COL_OUT, 6.0, true)
	# 缩放档位指示点
	for i in ZOOM_FRACS.size():
		var dp := st_c + Vector2((i - ZOOM_START) * 26.0, -r - 30.0)
		p.draw_circle(dp, 6.5, Color.WHITE if i == _zoom_idx else Color(1, 1, 1, 0.35))
		p.draw_arc(dp, 6.5, 0, TAU, 20, COL_OUT, 2.0, true)
	# 快门白闪
	if _flash_t > 0.0:
		p.draw_rect(Rect2(Vector2.ZERO, vp), Color(1, 1, 1, clampf(_flash_t / FLASH_T, 0.0, 1.0) * 0.85))


## ===== 反馈特效 =====

## 完美评级：金色粒子迸发
func _spawn_particles(pos: Vector2) -> void:
	var par := CPUParticles2D.new()
	par.position = pos
	par.one_shot = true
	par.explosiveness = 1.0
	par.amount = 46
	par.lifetime = 1.0
	par.direction = Vector2(0, -1)
	par.spread = 70.0
	par.gravity = Vector2(0, 640)
	par.initial_velocity_min = 240.0
	par.initial_velocity_max = 480.0
	par.angular_velocity_min = -360.0
	par.angular_velocity_max = 360.0
	par.scale_amount_min = 4.0
	par.scale_amount_max = 9.0
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.85, 0.25, 1.0))
	g.set_color(1, Color(1.0, 0.55, 0.15, 0.0))
	par.color_ramp = g
	add_child(par)
	par.emitting = true
	var tw := create_tween()
	tw.tween_interval(1.5)
	tw.tween_callback(par.queue_free)


## ===== 音效 =====

## pck 内音频走字节解码，编辑器预览走导入资源（双路径）；WAV 用 AudioStreamWAV
func _init_sfx() -> void:
	var files := {"shutter": "shutter.wav", "win": "win.wav", "fail": "fail.wav"}
	for sname: String in files:
		for base in ["res://games/perfect_snap/assets/sfx/", "res://assets/sfx/"]:
			var path: String = base + files[sname]
			if ResourceLoader.exists(path):
				_sfx_streams[sname] = load(path)
				break
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				_sfx_streams[sname] = AudioStreamWAV.load_from_buffer(f.get_buffer(f.get_length()))
				break
	for i in SFX_POOL:
		var pl := AudioStreamPlayer.new()
		add_child(pl)
		_sfx_players.append(pl)
	# BGM：复用合集通用 BGM（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/perfect_snap/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


func _play_sfx(sfx_name: String, volume_db := 0.0) -> void:
	if not _sfx_streams.has(sfx_name):
		return
	for pl: AudioStreamPlayer in _sfx_players:
		if not pl.playing:
			pl.stream = _sfx_streams[sfx_name]
			pl.volume_db = volume_db + SFX_DB
			pl.play()
			return
