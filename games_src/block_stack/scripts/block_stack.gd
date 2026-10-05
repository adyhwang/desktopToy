extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## Block Stack（方块叠高高）：无尽堆叠，2D 刚体物理
## 方块从画面上方生成，X 跟随鼠标/触摸；双击方块本体顺时针旋转 45°；
## 单击方块下方区域（左键释放时）放下方块；备选键盘 A/D 或 ←→ 移动、W/↑ 旋转、S/↓ 放下
## 待放方块下方渲染半透明虚影落点预览（透明度 GHOST_ALPHA，纯视觉不参与碰撞）
## 方块落到平台/已有方块上即堆叠；掉出平台外落出屏幕底部 1 秒后自动销毁
## 计分：落地 +10，较对齐 +20，精准对齐 +50 金色闪光；分值随当前堆叠高度增长
## 高度：1 米 = 64px（2 格）；左侧垂直米尺标注堆叠高度 + 本局最佳金色旗标
## 物理：真实刚体重力/碰撞/倾倒，倾斜堆叠自然物理表现
## 开发者模式：排行榜面板 5 秒内点满 10 次 → 关闭后弹出 DEV 窗口（抬高5米/指定下一个方块/+100分/清空堆叠），
## 性能：堆叠每升高 4 米，把该线以下已静止方块合并为静态刚体；镜头只随最高点向上平移（可缓慢回落），
##       不缩放画面；落到可视范围下方的方块不再渲染
## 存档：复用 GameHud（排行榜分值 = 得分，附到达高度米数），最高分即时刷新，stop 时提交入榜
##       DEV 窗口常驻可拖动，浮于排行榜之上（z_index 250）

const GameHud := preload("res://scripts/game_hud.gd")

# ===== 布局 =====
const HUD_H := 86.0            # 顶部栏高度

# ===== 玩法常量 =====
const CELL := 32.0             # 方块单格边长（素材 64px/格 × SPRITE_SCALE，缩小一半）
const SPRITE_SCALE := CELL / 64.0   # 贴图缩放：素材 64px/格 → CELL
const GHOST_ALPHA := 0.28      # 虚影透明度（可配置常量）
const HELD_Y_RATIO := 0.16     # 待放方块在屏幕高度的比例位置
const SPAWN_DELAY := 1       # 放下方块到下一块出现的间隔（秒）
const KEY_SPEED := 550.0       # 键盘移动速度（px/秒）
const ROT_STEP := PI / 4.0     # 每次双击旋转 45°
const GRAVITY_SCALE := 0.3     # 方块重力倍率
const PERFECT_PX := 5.0        # 精准对齐：与下方支撑中心水平偏差
const GOOD_PX := 17.0          # 较好对齐阈值
const SCORE_LAND := 10         # 落地基础分
const SCORE_GOOD := 20         # 较好对齐奖励
const SCORE_PERFECT := 50      # 精准对齐奖励
const HEIGHT_BONUS := 2        # 落地时每 1 米高度附加分
const MERGE_EVERY_M := 10     # 每升高 10 米触发一次底层合并
const LOST_AFTER := 1.0        # 掉出屏幕/平台的方块 1 秒后销毁
const STILL_VEL := 40.0        # 判定静止的速度阈值
const STILL_ANG := 1.2         # 判定静止的角速度阈值
const STILL_TIME := 0.35       # 持续静止时长（秒）后结算对齐得分
const LAND_WAIT := 3.0         # 接触后最长等待结算时间（超时不再计分）
const SHAKE_LAND := 5.0        # 落地镜头抖动幅度
const SFX_DB := -6.0
const SFX_POOL := 6
const BGM_DB := -12.0

# 方块池：经典 7 种 tetromino + 棱镜 16 种（cells = [row, col]，仅基础朝向，贴图 64px/格）
const BLOCKS: Array = [
	{"id": "i", "cells": [[0, 0], [0, 1], [0, 2], [0, 3]]},
	{"id": "o", "cells": [[0, 0], [0, 1], [1, 0], [1, 1]]},
	{"id": "t", "cells": [[0, 0], [0, 1], [0, 2], [1, 1]]},
	{"id": "s", "cells": [[0, 1], [0, 2], [1, 0], [1, 1]]},
	{"id": "z", "cells": [[0, 0], [0, 1], [1, 1], [1, 2]]},
	{"id": "j", "cells": [[0, 1], [1, 1], [2, 1], [2, 0]]},
	{"id": "l", "cells": [[0, 0], [1, 0], [2, 0], [2, 1]]},
	{"id": "y1", "cells": [[0, 0], [0, 1], [0, 2], [0, 3]]},
	{"id": "y2", "cells": [[0, 1], [0, 2], [1, 0], [1, 1], [2, 1], [2, 2]]},
	{"id": "y3", "cells": [[0, 1], [1, 0], [1, 1], [1, 2], [2, 1]]},
	{"id": "y4", "cells": [[0, 3], [0, 2], [1, 2], [0, 1], [1, 1], [1, 0]]},
	{"id": "g1", "cells": [[0, 0], [1, 0], [1, 1], [1, 2], [2, 0]]},
	{"id": "g2", "cells": [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1]]},
	{"id": "g3", "cells": [[0, 2], [1, 1], [1, 2], [2, 0], [2, 1]]},
	{"id": "g4", "cells": [[0, 0], [0, 3], [1, 0], [1, 1], [1, 2], [1, 3]]},
	{"id": "b1", "cells": [[0, 1], [0, 2], [1, 0], [1, 1], [1, 2], [1, 3]]},
	{"id": "b2", "cells": [[0, 0], [0, 1], [0, 2], [1, 2], [2, 2]]},
	{"id": "b3", "cells": [[0, 1], [1, 0], [1, 1], [1, 2], [1, 3], [2, 1]]},
	{"id": "b4", "cells": [[0, 1], [0, 2], [1, 0], [1, 1]]},
	{"id": "r1", "cells": [[0, 3], [1, 0], [1, 1], [1, 2], [1, 3]]},
	{"id": "r2", "cells": [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [2, 0]]},
	{"id": "r3", "cells": [[0, 1], [1, 0], [1, 1], [1, 2], [2, 1], [2, 2]]},
	{"id": "r4", "cells": [[0, 0], [0, 2], [1, 0], [1, 1], [1, 2]]},
]

# 配色（扁平卡通，对齐合集风格）
const COL_SKY := Color(0.80, 0.91, 0.94, 0.4)   # 50% 透明，透出桌面背景
const COL_WATER := Color(0.25, 0.55, 0.85)      # 底部水面（蓝色，顶部波浪滚动）
const COL_PEDESTAL := Color(0.78, 0.62, 0.42)
const COL_PEDESTAL_TOP := Color(0.90, 0.76, 0.55)
const COL_OUTLINE := Color(0.12, 0.10, 0.09)
const COL_RULER := Color(0.25, 0.28, 0.27, 0.9)
const COL_TICK := Color(0.25, 0.28, 0.27, 0.45)
const COL_NOW := Color(0.20, 0.75, 0.40)
const COL_BEST := Color(1.0, 0.80, 0.20)
const COL_GOLD := Color(1.0, 0.85, 0.25)
const COL_MERGED := Color(0.72, 0.75, 0.78)   # 已合并静态方块统一颜色（石灰白，区分活跃块）
const BASE_BELT := 28.0        # 底部"基座+水面"露出带总高（屏幕 px，约为原 282px 的十分之一）

var hud: RefCounted
var _vp := Vector2(1920, 1080)
var base_top_y := 993.0        # 平台顶面世界 Y
var platform_cx := 960.0       # 平台中心世界 X
var platform_half_w := 800.0   # 平台半宽
var area_left := 0.0           # 正方形游戏区左边缘（世界/屏幕 X 一致，镜头不横移）
var area_right := 1920.0       # 正方形游戏区右边缘
var area_top := 86.0           # 正方形游戏区顶边缘（= HUD_H）
var px_per_m := 48.0           # 1 米对应像素（_layout 按屏高标定：开局米尺 0..20m 完整可见，画面 1:1 不缩放）
var area_size := 994.0         # 正方形边长

# ===== 方块池实体 =====
var blocks: Array = []         # {body, spr, id, cells, cw, ch, contact_t, scored, still_t, born, lost_at, support}
var merged_tops: Array = []    # 已合并静态方块的世界 top_y（高度统计用）
var _mono_tex := {}            # id -> 合并统一色贴图缓存（_mono_texture 生成）
var _dyn_root: Node2D
var _static_root: Node2D
var _cell_shape: RectangleShape2D
var _phys_mat: PhysicsMaterial

# ===== 待放方块 =====
var held_active := false
var held_id := ""
var held_cells: Array = []
var held_cw := 1
var held_ch := 1
var held_rot := 0.0
var held_pos := Vector2.ZERO
var spawn_left := 0.0
var held_spr: Sprite2D
var _held_pop := 0.0           # 旋转/出现的弹跳动画计时
var _last_tap_ms := -10000     # 自实现双击判定：上次按下时刻（触摸屏合成的 double_click 不可靠，参考方块拼图）
var _last_tap_pos := Vector2.ZERO

# ===== 虚影预测（_physics_process 计算，_draw 使用）=====
var ghost_valid := false
var ghost_pos := Vector2.ZERO

# ===== 计分 / 高度 =====
var score := 0
var height_m := 0.0
var run_max_m := 0.0
var milestone := 0             # 已触发的 4m 合并段数
var _ms5_shown := 0            # 已提示过的 5m 里程碑

# ===== 特效 =====
var flashes: Array = []        # {pos, rot, size, t0, life, col}
var floats: Array = []         # {pos, text, t0, life, col, fsize}
var dusts: Array = []          # {pos, vel, t0, life}
var shake_amp := 0.0
var _t := 0.0                  # 本局累计时间
var _last_fall_sfx := -9.0

# ===== 镜头 =====
var cam: Camera2D
var cam_base_y := 400.0

# ===== 平台 / UI =====
var base_body: StaticBody2D
var _top_btns: HBoxContainer
var _restart_btn: Button
var _volume_btn: Button

# ===== 音效 =====
var _sfx := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer

# ===== 开发者模式（排行榜面板暗门：5 秒点满 10 次 → 关闭后弹出 DEV 窗口）=====
var _dev_pending := false
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_win: PanelContainer
var _dev_drag := false
var _dev_next_btn: Button   # "下一个方块"循环按钮（显示当前选中）
var _dev_next_id := ""      # 强制下一个生成的方块 id（"" = 随机）

@onready var _board_height: Label = $UI/BoardHeight
@onready var _board_score: Label = $UI/BoardScore
@onready var _exit_btn: Button = $UI/ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("block_stack")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_init_sfx()
	_cell_shape = RectangleShape2D.new()
	_cell_shape.size = Vector2(CELL, CELL)
	_phys_mat = PhysicsMaterial.new()
	_phys_mat.friction = 0.85
	_phys_mat.bounce = 0.05
	_dyn_root = Node2D.new()
	_dyn_root.name = "Blocks"
	add_child(_dyn_root)
	_static_root = Node2D.new()
	_static_root.name = "Statics"
	add_child(_static_root)
	held_spr = Sprite2D.new()
	held_spr.name = "Held"
	held_spr.visible = false
	add_child(held_spr)
	cam = Camera2D.new()
	cam.name = "Cam"
	add_child(cam)
	cam.make_current()
	_layout()
	_spawn_held()
	_update_hud()
	queue_redraw()


func stop() -> void:
	get_tree().paused = false
	if _bgm != null:
		_bgm.stop()
	hud.commit_score(int(round(run_max_m * 10.0)))   # 本局得分 + 最高堆叠高度（分米）入排行榜
	print("[block_stack] stop, score=%d max_height=%.1fm" % [score, run_max_m])


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 布局：正方形游戏区（HUD/按钮固定在顶部 HUD_H 条内，不随镜头）=====
func _layout() -> void:
	_vp = get_viewport().get_visible_rect().size
	# 正方形取景框：顶部留 HUD_H 给固定 HUD，底边贴屏幕底，水平居中
	area_size = minf(_vp.x, _vp.y - HUD_H)
	area_left = (_vp.x - area_size) * 0.5
	area_top = HUD_H
	area_right = area_left + area_size
	base_top_y = area_top + area_size * 0.98   # 平台顶贴近底边，草地/基座只露出一点点
	platform_cx = _vp.x * 0.5
	platform_half_w = area_size * 0.25   # 平台宽 = 正方形宽的一半
	# 米尺比例标定：1 米像素数 = 可用屏高 / 20（留出 20m 标签高度余量），开局米尺 0..20m 完整可见（画面保持 1:1 不缩放）
	px_per_m = (_vp.y - HUD_H - BASE_BELT - 26.0) / 20.0
	cam_base_y = base_top_y - _vp.y * 0.5 + BASE_BELT   # 基座顶显示在屏幕底上方 BASE_BELT 屏幕px 处
	# HUD 信息板（固定屏幕坐标）
	_board_height.position = Vector2(platform_cx - 250.0, 15.0)
	_board_height.size = Vector2(240.0, 56.0)
	_board_score.position = Vector2(platform_cx + 10.0, 15.0)
	_board_score.size = Vector2(240.0, 56.0)
	# 顶栏按钮（右上角）
	if _top_btns != null:
		_top_btns.reset_size()
		_top_btns.position = Vector2(_vp.x - 16.0 - _top_btns.size.x, (HUD_H - _top_btns.size.y) * 0.5)
	# 平台基座
	if base_body != null:
		base_body.queue_free()
	base_body = StaticBody2D.new()
	base_body.name = "Base"
	base_body.collision_layer = 1
	base_body.collision_mask = 0
	base_body.position = Vector2(platform_cx, base_top_y + 200.0)
	base_body.set_meta("cx", platform_cx)
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(platform_half_w * 2.0, 400.0)
	cs.shape = sh
	base_body.add_child(cs)
	add_child(base_body)
	if cam != null and cam.position == Vector2.ZERO:
		cam.position = Vector2(platform_cx, cam_base_y)


## ===== 待放方块 =====
func _spawn_held() -> void:
	var def: Dictionary = BLOCKS[randi() % BLOCKS.size()]
	if _dev_next_id != "":   # DEV：强制指定下一个方块
		for d: Dictionary in BLOCKS:
			if d.id == _dev_next_id:
				def = d
				break
	held_id = def.id
	held_cells = def.cells
	var b := _bounds(held_cells)
	held_cw = b.x
	held_ch = b.y
	held_rot = 0.0
	held_active = true
	held_spr.texture = _load_png("assets/blocks/%s.png" % held_id)
	held_spr.visible = true
	held_spr.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE) * 0.4
	_held_pop = 0.22
	var tw := held_spr.create_tween()
	tw.tween_property(held_spr, "scale", Vector2(SPRITE_SCALE, SPRITE_SCALE), 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if held_pos == Vector2.ZERO:
		held_pos = Vector2(platform_cx, cam.position.y - _vp.y * 0.5 + HUD_H + HELD_Y_RATIO * area_size)


func _drop_held() -> void:
	if not held_active:
		return
	held_active = false
	held_spr.visible = false
	spawn_left = SPAWN_DELAY
	var body := RigidBody2D.new()
	body.position = held_pos
	body.rotation = held_rot
	body.gravity_scale = GRAVITY_SCALE
	body.contact_monitor = true
	body.max_contacts_reported = 4
	body.collision_layer = 2
	body.collision_mask = 3
	body.physics_material_override = _phys_mat
	var blk := {
		"body": body, "spr": null, "id": held_id, "cells": held_cells,
		"cw": held_cw, "ch": held_ch, "contact_t": -1.0, "scored": false,
		"still_t": 0.0, "born": _t, "lost_at": -1.0, "support": null,
	}
	var spr := Sprite2D.new()
	spr.texture = held_spr.texture
	spr.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
	body.add_child(spr)
	blk.spr = spr
	for cell: Array in held_cells:
		var cs := CollisionShape2D.new()
		cs.shape = _cell_shape
		cs.position = _cell_offset(cell, held_cw, held_ch)
		body.add_child(cs)
	body.body_entered.connect(_on_block_contact.bind(blk))
	_dyn_root.add_child(body)
	body.linear_velocity = Vector2(0, 160)
	blocks.append(blk)


func _rotate_held() -> void:
	if not held_active:
		return
	held_rot += ROT_STEP
	_held_pop = 0.16
	var tw := held_spr.create_tween()
	held_spr.scale = Vector2(1.14, 1.14) * SPRITE_SCALE
	tw.tween_property(held_spr, "scale", Vector2(SPRITE_SCALE, SPRITE_SCALE), 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## ===== 输入 =====
func _unhandled_input(ev: InputEvent) -> void:
	if hud == null:
		return
	if ev is InputEventMouseMotion and held_active:
		held_pos.x = get_global_mouse_position().x
		return
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		var pos := get_global_mouse_position()
		if ev.pressed:
			if _point_on_held(pos):
				# 自实现双击：400ms 内两击、间距在容差内（触摸屏合成的 double_click 不可靠，参考方块拼图）
				var now := Time.get_ticks_msec()
				if now - _last_tap_ms < 400 and pos.distance_to(_last_tap_pos) < 32.0:
					_last_tap_ms = -10000
					_rotate_held()
				else:
					_last_tap_ms = now
					_last_tap_pos = pos
		elif held_active:
			# 左键在方块下方区域释放 → 放下方块（按住不放不下落）
			if pos.y > held_pos.y + _held_half().y:
				_drop_held()
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_W, KEY_UP:
				_rotate_held()
			KEY_S, KEY_DOWN:
				_drop_held()


func _point_on_held(pos: Vector2) -> bool:
	if not held_active:
		return false
	var h := _held_half() + Vector2(12, 12)
	return absf(pos.x - held_pos.x) <= h.x and absf(pos.y - held_pos.y) <= h.y


## ===== 主循环 =====
func _process(delta_raw: float) -> void:
	if hud == null:   # 未经 start() 直跑场景（无头检查）
		return
	var delta := minf(delta_raw, 0.2)
	_t += delta
	_tick_held(delta)
	_tick_blocks(delta)
	_tick_height()
	_tick_camera(delta)
	_tick_fx(delta)
	_update_hud()
	queue_redraw()


func _physics_process(_delta: float) -> void:
	if hud == null:
		return
	_predict_ghost()


## 待放方块：X 跟随鼠标 + 键盘微调，Y 贴屏幕上部；下落空间不足时自动抬高
func _tick_held(delta: float) -> void:
	if not held_active:
		spawn_left -= delta
		if spawn_left <= 0.0:
			_spawn_held()
		return
	var dir := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir += 1.0
	if dir != 0.0:
		held_pos.x += dir * KEY_SPEED * delta
	var h := _held_half()
	held_pos.x = clampf(held_pos.x, area_left + h.x + 4.0, area_right - h.x - 4.0)
	var base_y := cam.position.y - _vp.y * 0.5 + HUD_H + HELD_Y_RATIO * area_size
	if ghost_valid:
		base_y = minf(base_y, ghost_pos.y - h.y - 24.0)
	held_pos.y = base_y
	if _held_pop > 0.0:
		_held_pop -= delta
	held_spr.position = held_pos
	held_spr.rotation = held_rot


## ===== 已放置方块：结算 / 坍塌 / 丢失 / 底视剔除 =====
func _tick_blocks(delta: float) -> void:
	var cam_bottom := cam.position.y + _vp.y * 0.5
	for b: Dictionary in blocks:
		if not is_instance_valid(b.body):   # 先查有效性（freed 引用不能赋给类型变量）
			continue
		var body: RigidBody2D = b.body
		var vel := body.linear_velocity.length()
		var ang := absf(body.angular_velocity)
		# 落地结算：接触后持续静止 → 按支撑中心对齐程度计分
		if b.contact_t >= 0.0 and not b.scored:
			if vel < STILL_VEL and ang < STILL_ANG:
				b.still_t += delta
			else:
				b.still_t = 0.0
			if b.still_t >= STILL_TIME:
				_score_land(b)
			elif _t - b.contact_t > LAND_WAIT:
				b.scored = true   # 一直在翻滚滑动，不计对齐分
		# 掉出屏幕底部 / 平台范围：1 秒后销毁
		if b.lost_at < 0.0 and (body.position.y > base_top_y + 600.0
				or body.position.y > cam_bottom + 300.0
				or absf(body.position.x - platform_cx) > area_size * 0.5 + 250.0):
			b.lost_at = _t
			if _t - _last_fall_sfx > 0.4:
				_last_fall_sfx = _t
				_play_sfx("fall")
		if b.lost_at >= 0.0 and _t - b.lost_at > LOST_AFTER:
			body.queue_free()
			continue
		# 落到可视范围下方不再渲染
		var spr: Sprite2D = b.spr
		if spr != null:
			spr.visible = body.position.y < cam_bottom + 120.0
	# 清理已销毁条目
	blocks = blocks.filter(func(b: Dictionary) -> bool:
		return is_instance_valid(b.body))


func _on_block_contact(other: Node, blk: Dictionary) -> void:
	if blk.contact_t >= 0.0:
		return
	blk.contact_t = _t
	blk.support = other
	var body: RigidBody2D = blk.body
	_play_sfx("land", randf_range(0.92, 1.1))
	shake_amp = maxf(shake_amp, SHAKE_LAND)
	# 碰撞抖动：方块压扁回弹
	var spr: Sprite2D = blk.spr
	if spr != null:
		spr.scale = Vector2(1.12, 0.82) * SPRITE_SCALE
		var tw := spr.create_tween()
		tw.tween_property(spr, "scale", Vector2(SPRITE_SCALE, SPRITE_SCALE), 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 落点灰尘
	for i in 5:
		var ang := randf_range(PI, TAU)
		dusts.append({
			"pos": body.position + Vector2(randf_range(-24, 24), _block_half_h(blk) * 0.8),
			"vel": Vector2(cos(ang), sin(ang) * 0.4) * randf_range(60, 160),
			"t0": _t, "life": 0.35,
		})


## 对齐计分：与支撑中心水平偏差越小分越高，精准对齐触发金色闪光
func _score_land(blk: Dictionary) -> void:
	blk.scored = true
	var body: RigidBody2D = blk.body
	var support_cx := platform_cx
	if blk.support != null and is_instance_valid(blk.support):
		var n: Node = blk.support
		if n is StaticBody2D and n.has_meta("cx"):
			support_cx = n.get_meta("cx")
		elif n is RigidBody2D:
			support_cx = n.position.x
	var dx := absf(body.position.x - support_cx)
	var pts := SCORE_LAND + int(height_m) * HEIGHT_BONUS
	if dx <= PERFECT_PX:
		pts += SCORE_PERFECT
		flashes.append({"pos": body.position, "rot": body.rotation,
				"size": Vector2(blk.cw, blk.ch) * CELL, "t0": _t, "life": 0.45, "col": COL_GOLD})
		floats.append({"pos": body.position + Vector2(0, -70), "text": hud.t("fx.perfect", "Perfect! +%d") % pts,
				"t0": _t, "life": 0.9, "col": COL_GOLD, "fsize": 40})
		_play_sfx("perfect")
	elif dx <= GOOD_PX:
		pts += SCORE_GOOD
		floats.append({"pos": body.position + Vector2(0, -70), "text": hud.t("fx.good", "Nice! +%d") % pts,
				"t0": _t, "life": 0.8, "col": Color.WHITE, "fsize": 32})
	else:
		floats.append({"pos": body.position + Vector2(0, -70), "text": "+%d" % pts,
				"t0": _t, "life": 0.7, "col": Color(0.92, 0.92, 0.92), "fsize": 28})
	score += pts
	hud.submit_score(score, int(round(run_max_m * 10.0)))


## ===== 高度 / 里程碑 / 底层合并 =====
func _tick_height() -> void:
	var top := base_top_y
	for b: Dictionary in blocks:
		if not is_instance_valid(b.body) or b.lost_at >= 0.0 or b.contact_t < 0.0:
			continue   # 未接触的下落中方块不计高度
		top = minf(top, _block_top_y(b))
	for mt: float in merged_tops:
		top = minf(top, mt)
	height_m = maxf(0.0, (base_top_y - top) / px_per_m)
	if height_m > run_max_m:
		run_max_m = height_m
		hud.submit_score(score, int(round(run_max_m * 10.0)))
	# 5 米里程碑飘字（米尺特效）
	var ms5 := int(height_m / 5.0)
	if ms5 > _ms5_shown:
		_ms5_shown = ms5
		floats.append({"pos": Vector2(platform_cx, top - 60.0), "text": "%d m" % (ms5 * 5),
				"t0": _t, "life": 1.1, "col": COL_BEST, "fsize": 44})
	# 堆叠达到阈值：该线以下已静止方块合并为静态刚体（减少刚体数量）
	var ms := int(height_m / MERGE_EVERY_M)
	if ms > milestone:
		milestone = ms
		_merge_below(base_top_y - ms * MERGE_EVERY_M * px_per_m)


## 把 merge_line 以下（top_y 更大）已静止的方块转为静态刚体，贴图保留
func _merge_below(line_y: float) -> void:
	var margin := 30.0
	for b: Dictionary in blocks:
		if not is_instance_valid(b.body) or b.lost_at >= 0.0:
			continue
		var body: RigidBody2D = b.body
		if not b.scored or body.linear_velocity.length() > STILL_VEL:
			continue
		if _block_top_y(b) < line_y + margin:
			continue
		var sb := StaticBody2D.new()
		sb.collision_layer = 1
		sb.collision_mask = 0
		sb.position = body.position
		sb.rotation = body.rotation
		sb.set_meta("cx", body.position.x)
		for cs: Node in body.get_children():
			if cs is CollisionShape2D:
				var nc := CollisionShape2D.new()
				nc.shape = _cell_shape
				nc.position = cs.position
				sb.add_child(nc)
		_static_root.add_child(sb)
		merged_tops.append(_block_top_y(b))
		# 贴图从刚体迁移到静态层（保持全局位置），并换为统一颜色（已固定标识）
		var spr: Sprite2D = b.spr
		if spr != null:
			body.remove_child(spr)
			_static_root.add_child(spr)
			spr.texture = _mono_texture(b.id)
			spr.position = sb.position
			spr.rotation = sb.rotation
			spr.scale = Vector2(SPRITE_SCALE, SPRITE_SCALE)
		body.queue_free()
		b.body = null
	blocks = blocks.filter(func(b: Dictionary) -> bool:
		return is_instance_valid(b.body))


func _block_top_y(b: Dictionary) -> float:
	var body: RigidBody2D = b.body
	var tr := Transform2D(body.rotation, Vector2.ZERO)
	var half := CELL * 0.5 * (absf(sin(body.rotation)) + absf(cos(body.rotation)))
	var top := INF
	for cell: Array in b.cells:
		var ro := tr * _cell_offset(cell, b.cw, b.ch)
		top = minf(top, body.position.y + ro.y - half)
	return top


## ===== 虚影预测：逐格形状向下投射，取最小安全距离 =====
func _predict_ghost() -> void:
	ghost_valid = false
	if not held_active:
		return
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	var tr := Transform2D(held_rot, Vector2.ZERO)
	var frac := 1.0
	for cell: Array in held_cells:
		var params := PhysicsShapeQueryParameters2D.new()
		params.shape = _cell_shape
		params.transform = Transform2D(held_rot, held_pos + tr * _cell_offset(cell, held_cw, held_ch))
		params.collision_mask = 3
		params.motion = Vector2(0, 8192)
		var r := space.cast_motion(params)
		if r.size() < 2:
			continue
		frac = minf(frac, r[0])
	ghost_pos = held_pos + Vector2(0, 8192) * frac
	ghost_valid = true


## ===== 镜头：跟随堆叠最高点向上平移（不缩放），坍塌后缓慢回落 =====
func _tick_camera(delta: float) -> void:
	var top := base_top_y
	for b: Dictionary in blocks:
		if is_instance_valid(b.body) and b.lost_at < 0.0 and b.contact_t >= 0.0:
			top = minf(top, _block_top_y(b))
	for mt: float in merged_tops:
		top = minf(top, mt)
	var target := minf(cam_base_y, top - (HUD_H + 0.62 * area_size - _vp.y * 0.5))
	var k := 4.0 if target < cam.position.y else 1.6
	cam.position.y = lerpf(cam.position.y, target, 1.0 - exp(-k * delta))
	cam.position.x = platform_cx
	# 抖动
	shake_amp *= exp(-8.0 * delta)
	if shake_amp < 0.05:
		shake_amp = 0.0
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake_amp if shake_amp > 0.0 else Vector2.ZERO


func _tick_fx(delta: float) -> void:
	for d: Dictionary in dusts:
		d.pos += d.vel * delta
		d.vel.y += 500.0 * delta
	dusts = dusts.filter(func(d: Dictionary) -> bool: return _t - d.t0 < d.life)
	floats = floats.filter(func(f: Dictionary) -> bool: return _t - f.t0 < f.life)
	flashes = flashes.filter(func(f: Dictionary) -> bool: return _t - f.t0 < f.life)


## ===== 绘制 =====
func _draw() -> void:
	if hud == null:
		return
	var cam_top := cam.position.y - _vp.y * 0.5 - 120.0
	var cam_bot := cam.position.y + _vp.y * 0.5 + 120.0
	# 天空：限制在正方形内，顶边贴住取景框上沿（屏幕 HUD_H 处，不随镜头上移）
	var sky_top := cam.position.y - _vp.y * 0.5 + HUD_H
	draw_rect(Rect2(area_left, sky_top, area_size, cam_bot - sky_top), COL_SKY)
	# 水面（蓝色 + 顶部滚动波浪线与内部错相位波纹，_t 驱动动画）
	if cam_bot > base_top_y:
		draw_rect(Rect2(area_left, base_top_y, area_size, minf(cam_bot - base_top_y, 4000.0)), COL_WATER)
		var pts := PackedVector2Array()
		var x := area_left
		while x <= area_right + 16.0:
			pts.append(Vector2(x, base_top_y + sin(x * 0.02 + _t * 2.2) * 4.0 - 3.0))
			x += 16.0
		draw_polyline(pts, Color(1, 1, 1, 0.45), 3.0)
		for k in 4:
			var pts2 := PackedVector2Array()
			var y0 := base_top_y + 12.0 + k * 11.0
			x = area_left
			while x <= area_right + 16.0:
				pts2.append(Vector2(x, y0 + sin(x * 0.024 - _t * (1.7 - k * 0.3) + k * 2.1) * 3.0))
				x += 16.0
			draw_polyline(pts2, Color(1, 1, 1, 0.18 - k * 0.035), 2.0)
	# 平台基座（木色矮基座，露出带内无描边，防显成黑横线）
	var pl := Rect2(platform_cx - platform_half_w, base_top_y, platform_half_w * 2.0, 15.0)
	draw_rect(pl, COL_PEDESTAL)
	draw_rect(Rect2(pl.position.x, pl.position.y, pl.size.x, 3), COL_PEDESTAL_TOP)
	_draw_ruler(sky_top)   # 米尺只画到天空顶（屏幕 HUD_H 处），无遮盖条防上溢
	_draw_ghost()
	_draw_fx()


## 左侧垂直米尺：每 1 米刻度 + 标签，5 米金线；当前高度绿旗 / 本局最佳金旗
func _draw_ruler(ruler_top: float) -> void:
	var rx := area_left + 70.0
	draw_line(Vector2(rx, base_top_y), Vector2(rx, ruler_top), COL_RULER, 4.0)
	var font := ThemeDB.fallback_font
	var max_m := int((base_top_y - ruler_top) / px_per_m) + 1
	for m in max_m + 1:
		var y := base_top_y - m * px_per_m
		if y < ruler_top - 1.0:   # 1px 容差：20m 刻度贴线时浮点误差不致漏画
			break
		var big := m % 5 == 0
		draw_line(Vector2(rx - (14 if big else 8), y), Vector2(rx, y),
				COL_BEST if big and m > 0 else COL_TICK, 3.0 if big else 2.0)
		if m > 0 and (big or m <= 3):
			var txt := "%dm" % m
			draw_string_outline(font, Vector2(rx + 14, y + 8), txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 5, Color(0, 0, 0, 0.6))
			draw_string(font, Vector2(rx + 14, y + 8), txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.30, 0.34, 0.33, 0.9))
	# 当前高度旗（绿）
	if height_m >= 0.1:
		var y := base_top_y - height_m * px_per_m
		var col := COL_NOW
		draw_polygon(PackedVector2Array([Vector2(rx - 26, y), Vector2(rx - 4, y), Vector2(rx - 4, y - 26), Vector2(rx - 26, y - 13)]),
				PackedColorArray([col, col, col, col]))
		var txt := "%.1fm" % height_m
		draw_string_outline(font, Vector2(rx - 24, y - 32), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 6, Color.BLACK)
		draw_string(font, Vector2(rx - 24, y - 32), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
	# 本局最佳旗（金，避免与当前旗重叠）
	if run_max_m >= 0.3 and absf(run_max_m - height_m) > 0.08:
		var yb := base_top_y - run_max_m * px_per_m
		draw_line(Vector2(rx - 30, yb), Vector2(rx + 26, yb), Color(COL_BEST, 0.85), 2.0)
		var tb := "%.1fm" % run_max_m
		draw_string_outline(font, Vector2(rx + 30, yb - 6), tb, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, 5, Color.BLACK)
		draw_string(font, Vector2(rx + 30, yb - 6), tb, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, COL_BEST)


## 半透明虚影落点 + 虚线降落路径（纯视觉，不参与碰撞）
func _draw_ghost() -> void:
	if not held_active or not ghost_valid or hud == null:
		return
	var tex := held_spr.texture
	if tex == null:
		return
	var h := _held_half()
	# 虚线路径（从方块底到落点上方）
	var y0 := held_pos.y + h.y + 6.0
	var y1 := ghost_pos.y - h.y - 10.0
	if y1 > y0:
		var seg := 14.0
		var gap := 10.0
		var y := y0
		while y < y1:
			var e := minf(y + seg, y1)
			draw_line(Vector2(held_pos.x, y), Vector2(held_pos.x, e), Color(1, 1, 1, 0.5), 3.0)
			y = e + gap
	# 落点虚影
	var alpha := GHOST_ALPHA
	draw_set_transform(ghost_pos, held_rot, Vector2(SPRITE_SCALE, SPRITE_SCALE))
	draw_texture(tex, -tex.get_size() / 2.0, Color(1, 1, 1, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 落点基准线
	var bw := h.x
	draw_line(Vector2(ghost_pos.x - bw, ghost_pos.y + h.y + 2), Vector2(ghost_pos.x + bw, ghost_pos.y + h.y + 2),
			Color(COL_BEST, 0.6), 3.0)


func _draw_fx() -> void:
	var font := ThemeDB.fallback_font
	# 灰尘
	for d: Dictionary in dusts:
		var k: float = (_t - d.t0) / d.life
		draw_circle(d.pos, 5.0 + 8.0 * k, Color(0.85, 0.82, 0.75, 0.55 * (1.0 - k)))
	# 精准对齐闪光：淡入扩散的金色描边
	for f: Dictionary in flashes:
		var k: float = (_t - f.t0) / f.life
		var g := Rect2(f.pos - f.size / 2.0, f.size).grow(10.0 + 26.0 * k)
		draw_set_transform(f.pos, f.rot, Vector2.ONE)
		draw_rect(Rect2(-g.size / 2.0, g.size), Color(f.col.r, f.col.g, f.col.b, 0.5 * (1.0 - k)), false, 6.0)
		draw_rect(Rect2(-g.size / 2.0 - Vector2(8, 8), g.size + Vector2(16, 16)), Color(f.col.r, f.col.g, f.col.b, 0.22 * (1.0 - k)), false, 3.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 飘字
	for f: Dictionary in floats:
		var k: float = (_t - f.t0) / f.life
		var p: Vector2 = f.pos + Vector2(-120, -46.0 * k)   # 宽 240 居中
		var a: float = 1.0 - maxf(0.0, k * 1.4 - 0.4)
		var col: Color = f.col
		col.a = clampf(a, 0.0, 1.0)
		draw_string_outline(font, p, f.text, HORIZONTAL_ALIGNMENT_CENTER, 240, f.fsize, 7, Color(0, 0, 0, 0.7 * a))
		draw_string(font, p, f.text, HORIZONTAL_ALIGNMENT_CENTER, 240, f.fsize, col)


## ===== 顶部按钮 =====
func _setup_buttons() -> void:
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_exit_btn.icon = hud.ui_icon("close.png")
	_top_btns = HBoxContainer.new()
	_top_btns.name = "TopButtons"
	_top_btns.add_theme_constant_override("separation", 8)
	_top_btns.z_index = 150
	$UI.add_child(_top_btns)   # CanvasLayer 屏幕坐标，不随镜头
	_top_btns.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜弹窗）顶栏按钮仍可点
	var lb_btn := GameHud.make_button("")
	lb_btn.icon = hud.lb_icon()
	lb_btn.pressed.connect(_on_leaderboard)
	_volume_btn = GameHud.make_button("")
	_volume_btn.icon = hud.volume_icon()
	_restart_btn = GameHud.make_button("")
	_restart_btn.icon = hud.restart_icon()
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	for b: Control in [lb_btn, _volume_btn, _restart_btn, _exit_btn]:
		_top_btns.add_child(b)
		b.custom_minimum_size = Vector2(44.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.add_theme_constant_override("icon_max_width", 32)
	_restart_btn.pressed.connect(_on_restart)
	_volume_btn.pressed.connect(_on_volume)


func _on_leaderboard() -> void:
	hud.show_leaderboard(self, hud.t("lb.title", "Leaderboard"), score, 0)
	_arm_dev_clicks()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


func _on_restart() -> void:
	_play_sfx("fall", 0.8)
	_reset_run()


## 重开：清空全部方块与特效，镜头与状态复位（最高分/排行榜保留）
func _reset_run() -> void:
	for b: Dictionary in blocks:
		if is_instance_valid(b.body):
			b.body.queue_free()
	for ch: Node in _static_root.get_children():
		ch.queue_free()
	blocks.clear()
	merged_tops.clear()
	flashes.clear()
	floats.clear()
	dusts.clear()
	score = 0
	height_m = 0.0
	run_max_m = 0.0
	milestone = 0
	_ms5_shown = 0
	shake_amp = 0.0
	hud.reset_run()
	cam.position = Vector2(platform_cx, cam_base_y)
	cam.offset = Vector2.ZERO
	held_active = false
	held_pos = Vector2.ZERO
	spawn_left = 0.0
	_spawn_held()
	_update_hud()
	queue_redraw()


func _update_hud() -> void:
	_board_height.text = hud.t("hud.height", "Height %s") % ("%.1f m" % height_m)
	_board_score.text = hud.t("hud.score", "Score %d") % score


## ===== 开发者模式（排行榜面板暗门：5 秒点满 10 次 → 关闭后弹出 DEV 窗口）=====
## 窗口加到 UI CanvasLayer：固定屏幕坐标，镜头升很高也可见；常驻不自动关闭

func _arm_dev_clicks() -> void:
	var panel := get_node_or_null("UI/LeaderboardPanel")
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
		var panel := get_node_or_null("UI/LeaderboardPanel")
		if panel != null:   # 标题金色反馈（面板 ALWAYS，暂停中可见）
			var head := panel.get_child(0)
			if head is Container and head.get_child(0) is Label:
				(head.get_child(0) as Label).add_theme_color_override("font_color", COL_GOLD)


## 排行榜关闭回调（game_hud._close_lb 调用）：暗门已触发则弹出开发者窗口
func on_leaderboard_closed() -> void:
	if _dev_pending:
		_dev_pending = false
		_show_dev_window()


func _show_dev_window() -> void:
	if _dev_win != null and is_instance_valid(_dev_win):
		return
	var vp := get_viewport_rect().size
	_dev_win = PanelContainer.new()
	_dev_win.process_mode = Node.PROCESS_MODE_ALWAYS   # 排行榜暂停中也可操作
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
	title.add_theme_color_override("font_color", COL_GOLD)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 6)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := GameHud.make_button("✕")
	close_btn.pressed.connect(_dev_close)
	head.add_child(close_btn)
	# 功能按钮网格
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)
	var actions := [
		[hud.t("dev.raise", "Raise 5m"), _dev_raise_5m],
		[hud.t("dev.score", "Score +100"), _dev_add_score],
		[hud.t("dev.clear", "Clear stack"), _dev_clear_stack],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.pressed.connect(a[1])
		grid.add_child(b)
	# 下一个方块：循环按钮（显示当前选中，★ = 随机）
	var nr := HBoxContainer.new()
	nr.add_theme_constant_override("separation", 8)
	vb.add_child(nr)
	nr.add_child(_dev_label(hud.t("dev.next", "Next block")))
	_dev_next_btn = GameHud.make_button(_dev_next_text())
	_dev_next_btn.add_theme_font_size_override("font_size", 14)
	_dev_next_btn.custom_minimum_size = Vector2(150.0, 30.0)
	_dev_next_btn.pressed.connect(_dev_cycle_next)
	nr.add_child(_dev_next_btn)
	$UI.add_child(_dev_win)   # CanvasLayer 屏幕坐标：不随镜头移动
	_dev_win.z_index = 250    # 浮于排行榜(220)之上
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 标题栏拖动
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += event.relative)


## DEV 窗口小标签（统一样式）
func _dev_label(text: String) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 13)
	lb.add_theme_color_override("font_color", Color.WHITE)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 4)
	return lb


func _dev_close() -> void:
	_dev_drag = false
	if _dev_win != null and is_instance_valid(_dev_win):
		_dev_win.queue_free()
	_dev_win = null
	_dev_next_btn = null


func _dev_next_text() -> String:
	return "%s: %s" % [hud.t("dev.next", "Next block"), "★" if _dev_next_id == "" else _dev_next_id]


## 循环切换强制方块：随机 → 依次每种 → 随机
func _dev_cycle_next() -> void:
	var ids: Array = [""]
	for d: Dictionary in BLOCKS:
		ids.append(d.id)
	_dev_next_id = ids[(ids.find(_dev_next_id) + 1) % ids.size()]
	if _dev_next_btn != null and is_instance_valid(_dev_next_btn):
		_dev_next_btn.text = _dev_next_text()


## 抬高 5 米：已接触方块与静态层整体上移，并在新底部生成支撑板（方块站板即稳不回落）
func _dev_raise_5m() -> void:
	var dy := 5.0 * px_per_m
	for b: Dictionary in blocks:
		if not is_instance_valid(b.body) or b.lost_at >= 0.0 or b.contact_t < 0.0:
			continue   # 未接触的下落中方块不动，自然落到新支撑板上
		var body: RigidBody2D = b.body
		body.position.y -= dy
		body.linear_velocity = Vector2.ZERO
	for ch: Node in _static_root.get_children():
		if ch is Node2D:
			(ch as Node2D).position.y -= dy
	for i: int in merged_tops.size():
		merged_tops[i] -= dy
	# 支撑板：顶面 = 原平台顶 - dy；meta "cx" 供对齐计分
	var board := StaticBody2D.new()
	board.collision_layer = 1
	board.collision_mask = 0
	board.position = Vector2(platform_cx, base_top_y - dy + 15.0)
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(platform_half_w * 2.0, 30.0)
	cs.shape = shape
	board.add_child(cs)
	var poly := Polygon2D.new()
	var hw := platform_half_w
	poly.polygon = PackedVector2Array([Vector2(-hw, -15.0), Vector2(hw, -15.0), Vector2(hw, 15.0), Vector2(-hw, 15.0)])
	poly.color = COL_PEDESTAL
	board.add_child(poly)
	var ln := Line2D.new()
	ln.points = poly.polygon
	ln.closed = true
	ln.width = 6.0
	ln.default_color = COL_OUTLINE
	board.add_child(ln)
	board.set_meta("cx", platform_cx)
	_static_root.add_child(board)
	_play_sfx("land", 0.9)
	_tick_height()
	queue_redraw()


func _dev_add_score() -> void:
	score += 100
	hud.submit_score(score, int(round(run_max_m * 10.0)))
	_update_hud()
	_play_sfx("perfect", 0.9)


## 清空堆叠：清掉全部方块与静态层（分数/最高米数保留），里程碑复位后自然重发块
func _dev_clear_stack() -> void:
	for b: Dictionary in blocks:
		if is_instance_valid(b.body):
			b.body.queue_free()
	for ch: Node in _static_root.get_children():
		ch.queue_free()
	blocks.clear()
	merged_tops.clear()
	flashes.clear()
	floats.clear()
	dusts.clear()
	milestone = 0
	_ms5_shown = 0
	height_m = 0.0
	shake_amp = 0.0
	_play_sfx("fall", 0.8)
	_update_hud()
	queue_redraw()


## ===== 几何辅助 =====
func _cell_offset(cell: Array, cw: int, ch: int) -> Vector2:
	return Vector2((float(cell[1]) - (cw - 1) * 0.5) * CELL, (float(cell[0]) - (ch - 1) * 0.5) * CELL)


func _bounds(cells: Array) -> Vector2i:
	var mr := 0
	var mc := 0
	for c: Array in cells:
		mr = maxi(mr, int(c[0]))
		mc = maxi(mc, int(c[1]))
	return Vector2i(mc + 1, mr + 1)


## 待放方块旋转后的包围半尺寸
func _held_half() -> Vector2:
	var s := absf(sin(held_rot))
	var c := absf(cos(held_rot))
	var half := CELL * 0.5 * (s + c)
	var tr := Transform2D(held_rot, Vector2.ZERO)
	var mw := 0.0
	var mh := 0.0
	for cell: Array in held_cells:
		var ro := tr * _cell_offset(cell, held_cw, held_ch)
		mw = maxf(mw, absf(ro.x))
		mh = maxf(mh, absf(ro.y))
	return Vector2(mw + half, mh + half)


func _block_half_h(b: Dictionary) -> float:
	var rot: float = b.body.rotation if is_instance_valid(b.body) else 0.0
	return b.ch * CELL * 0.5 * (absf(sin(rot)) + absf(cos(rot)))


## ===== 贴图加载（pck 内 png 字节解码；双路径兼容编辑器直跑）=====
func _load_png(rel: String) -> Texture2D:
	for p: String in ["res://games/block_stack/" + rel, "res://" + rel]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


## 合并静态方块统一颜色贴图：不透明像素全部替换为 COL_MERGED（保留形状 alpha 与抗锯齿边缘），按 id 缓存
func _mono_texture(id: String) -> Texture2D:
	if _mono_tex.has(id):
		return _mono_tex[id]
	var out: Texture2D = null
	var src := _load_png("assets/blocks/%s.png" % id)
	if src != null:
		var img: Image = src.get_image()
		if img != null:
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if c.a > 0.05:
						img.set_pixel(x, y, Color(COL_MERGED, c.a))
			out = ImageTexture.create_from_image(img)
	_mono_tex[id] = out
	return out


## ===== 音效（wav/mp3/ogg 均可，文件缺失静默）=====
func _init_sfx() -> void:
	_sfx = {
		"land": _load_sfx("land"),          # 落地闷响
		"perfect": _load_sfx("perfect"),    # 精准对齐闪光
		"fall": _load_sfx("fall"),          # 方块坠落
	}
	for i in SFX_POOL:
		var ap := AudioStreamPlayer.new()
		ap.volume_db = SFX_DB
		ap.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(ap)
		_sfx_players.append(ap)
	# 背景音乐（复制自 tetris_puzzle，同源方块主题；排行榜暂停中继续播放）
	_bgm = AudioStreamPlayer.new()
	var bs: AudioStream = _load_sfx("bgm")
	if bs is AudioStreamMP3:
		bs.loop = true
	_bgm.stream = bs
	_bgm.volume_db = BGM_DB
	_bgm.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_bgm)
	if hud.bgm_on:
		_bgm.play()


func _load_sfx(sname: String) -> AudioStream:
	for ext: String in [".wav", ".ogg", ".mp3"]:
		for p: String in ["res://games/block_stack/assets/sfx/" + sname + ext, "res://assets/sfx/" + sname + ext]:
			var f := FileAccess.open(p, FileAccess.READ)
			if f == null:
				continue
			var buf := f.get_buffer(f.get_length())
			f.close()
			if ext == ".wav":
				return AudioStreamWAV.load_from_buffer(buf)
			elif ext == ".ogg":
				return AudioStreamOggVorbis.load_from_buffer(buf)
			return AudioStreamMP3.load_from_buffer(buf)
	return null


func _play_sfx(sname: String, pitch: float = 1.0) -> void:
	if not _sfx.has(sname) or _sfx[sname] == null:
		return
	for ap: AudioStreamPlayer in _sfx_players:
		if not ap.playing:
			ap.stream = _sfx[sname]
			ap.pitch_scale = pitch
			ap.volume_db = SFX_DB
			ap.play()
			return
