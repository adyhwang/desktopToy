extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 四面挡板打砖块 Breakout：正方形闭合场地 + 上下左右四挡板，中央 15×15 砖区
## 鼠标 X 同步控制上/下挡板水平移动，鼠标 Y 同步控制左/右挡板垂直移动（不超出场地）
## 球撞挡板后 HIT_COUPLING_T 窗口内移动挡板可持续给球施加偏移角与加速度（击点偏移 + 挡板速度传递）
## 30 个关卡文件（levels/level_NN.txt，15 行 × 15 个数字，exe 旁同名文件可覆盖自定义），30 关后回第 1 关循环：
## 偶数关砖块为水果/动物图案；循环难度递增：每圈砖块耐久 +1（需碰撞 圈数+1 次），球速/挡板尺寸不变；
## 道具击碎 10% 掉落（增益 90% / 减益 10%，21 关起 20%），
## 道具飞向最近的激活挡板，碰任意挡板生效、飞出场地消失；同类效果刷新时长、互斥效果后者覆盖
## 生命 5 起步、每关 +1、无上限；归零结算入榜（排行榜弹窗关闭后自动开新局）
## BGM 复用 dart 包同款曲目；音效为程序合成（AudioStreamWAV，无外部素材）

const GameHud := preload("res://scripts/game_hud.gd")

const SFX_POOL := 4             # 音效播放器池
const BGM_DB := -8.0            # BGM 音量（dB）
const SFX_DB := -4.0            # 音效全局音量偏移

# ===== 场地几何（均以 min(屏宽,屏高) m 或正方形边长 S 为基准，改这里全局调）=====
const S_RATIO := 0.84           # 场地边长 S = m × 此值（正方形，屏幕居中）
const B_RATIO := 0.75           # 砖区边长 B = S × 此值（场地正中，四周留球通道）
const PAD_T_RATIO := 0.02       # 挡板厚度 = S × 此值
const PAD_L_RATIO := 0.22       # 挡板基准全长 = S × 此值
const BALL_R_RATIO := 0.011     # 球半径 = S × 此值
const BALL_SPEED_RATIO := 0.50  # 球基准速度 = S × 此值 / s
const PU_SPEED_RATIO := 0.10    # 道具漂移速度 = S × 此值 / s
const GRID := 15                # 网格 15×15：关卡 txt 格式 = 15 行 × 每行 15 个数字

# ===== 玩法参数 =====
const LIVES_START := 9          # 初始生命
const RESPAWN_T := 0.9          # 失球重生等待（s）
const NEXT_LEVEL_T := 1.0       # 过关停顿（s）

# 挡板耦合：碰挡板后窗口内移动挡板，持续给球施加偏角与加速度（等效"瞬间抽球"的时间展开）
const HIT_COUPLING_T := 0.12    # 碰挡板后的耦合窗口（s）
const COUPLE_GAIN := 0.001      # 耦合增益：挡板速度(px/s) → 每秒切向方向修正量
const COUPLE_MIN_VEL := 80.0    # 挡板速度低于此值(px/s)视为未移动（过滤鼠标微抖），不施加

# 反弹钳制（全局）与兜底瞄准（≤ ASSIST_N 砖）：解决小球沿挡板平行空飞
const ASSIST_N := 10             # 兜底瞄准阈值：剩余砖块 ≤ 此值开启
const BOUNCE_MIN := 0.2        # 反弹后方向距轴向最小夹角（≈15°，全程生效防平行空跑；发球不受限）
const IDLE_STUCK_T := 10.0      # 兜底瞄准（≤ASSIST_N 砖）：连续无击碎时长（s），下次碰挡板射向最近砖

# 难度系统：初始仅底部挡板，每过 4 关依次增加 左→右→上；缺失边为白墙自动反弹（球/道具不出界）
const PADDLE_ORDER := ["left", "right", "top"]   # 挡板增加顺序
const DROP_RATE := 0.10         # 击碎掉道具概率
const DEBUFF_RATE := 0.10       # 减益占比（21 关起 DEBUFF_RATE_LATE）
const DEBUFF_RATE_LATE := 0.20
const LATE_LEVEL := 21
const MAX_BALLS := 18           # 多球上限（防性能爆炸）
const BRICK_BASE := 10          # 砖块基础分
const BRICK_COMBO := 2          # 连击每层加分局
const COMBO_CAP := 15           # 连击加分层级上限
const LEVEL_BONUS0 := 100       # 通关奖励 = 100 + (level-1)×50

# ===== 道具定义 =====
const EFFECT_DUR := {"slow": 8.0, "double": 10.0, "pierce": 8.0,
		"fast": 6.0, "invert": 5.0, "random": 10.0, "fog": 10.0}
const PAD_LONG := 1.3           # 挡板加长：永久倍率（拾取即生效，拾取缩短被覆盖，新局复位）
const PAD_SHORT := 0.7          # 挡板缩短：永久倍率
const BUFFS := ["long", "slow", "double", "multi", "pierce", "life"]
const DEBUFFS := ["short", "fast", "invert", "random", "fog"]
const PU_NAME := {"long": "Paddle Long", "slow": "Slow Ball", "double": "Double Score",
		"multi": "Multi Ball", "pierce": "Pierce Ball", "life": "+1 Life",
		"short": "Paddle Short", "fast": "Fast Ball", "invert": "Invert!",
		"random": "Random Bounce", "fog": "Fog"}
const EFFECT_NAMES := {"slow": "Slow Ball", "double": "Double Score", "pierce": "Pierce Ball",
		"fast": "Fast Ball", "invert": "Invert", "random": "Random", "fog": "Fog"}
const PU_TEX := {"long": "pu_long.png", "slow": "pu_slow.png", "double": "pu_double.png",
		"multi": "pu_multi.png", "pierce": "pu_pierce.png", "life": "pu_life.png",
		"short": "pu_short.png", "fast": "pu_fast.png", "invert": "pu_invert.png",
		"random": "pu_random.png", "fog": "pu_fog.png"}
const COL_BUFF := Color(0.45, 0.9, 0.5)
const COL_DEBUFF := Color(0.98, 0.35, 0.3)

const BRICK_COLORS := [Color(0.93, 0.36, 0.31), Color(0.97, 0.64, 0.22), Color(0.99, 0.84, 0.28),
		Color(0.45, 0.79, 0.44), Color(0.36, 0.66, 0.93), Color(0.68, 0.52, 0.87)]
const BRICK_PATTERNS := ["p_apple", "p_banana", "p_strawberry", "p_peach", "p_grape", "p_cat", "p_dog", "p_rabbit"]   # 偶数关图案砖贴图（水果/动物）
const POPUP_MAX := 14           # 飘字上限（防刷屏）

enum State { READY, PLAY, DEAD, OVER }

var hud: RefCounted

@onready var _level_board: Label = $HudBar/LevelBoard
@onready var _score_board: Label = $HudBar/ScoreBoard
@onready var _lives_board: Label = $HudBar/LivesBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.READY
var level := 1
var loop := 0                   # 30 关循环圈数（球速/挡板随之变化）
var score := 0
var lives := LIVES_START

# 布局快照（_layout 更新）
var _m := 0.0
var _S := 0.0
var _C := Vector2.ZERO
var _sq := Rect2()              # 场地正方形
var _B := 0.0
var _cell := 0.0
var _B0 := Vector2.ZERO         # 砖区左上角
var _T := 0.0                   # 挡板厚
var _hl := 0.0                  # 挡板基准半长
var _r := 0.0                   # 球半径

var _balls: Array = []
var _pups: Array = []
var _bricks := {}               # Vector2i(r,c) → Brick
var _bricks_left := 0
var _effects := {}              # 效果名 → 剩余秒
var _state_t := 0.0             # READY/DEAD 倒计时
var _advance_pending := false   # READY 到点先过关再发球
var _popup_count := 0

var _bricks_root: Node2D
var _balls_root: Node2D
var _pups_root: Node2D
var _fx_root: Node2D
var _paddles := {}              # top/bottom/left/right → Paddle
var _fog: Sprite2D
var _tex := {}                  # 贴图缓存
var _sfx := {}                  # 音效流缓存
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _hbox: HBoxContainer

# 开发者模式：5 秒内点击排行榜面板满 10 次 → 关闭后弹出调试窗口（可拖动，不影响游戏运行）
var _dev_pending := false       # 已触发暗门，等排行榜关闭
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_speed := 1.0           # 球速倍率（滑块，乘在 _speed_mult 上）
var _dev_pad := 1.0             # 挡板长度倍率（滑块，乘在 _paddle_mult 上）
var _dev_drop := DROP_RATE      # 道具掉率（滑块直接覆盖）
var _dev_win: PanelContainer
var _dev_drag := false

# 兜底瞄准状态
var _idle_t := 0.0              # 连续无击碎累计时长
var _assist_on_hit := false     # 兜底触发：下次碰任意挡板直接射向最近砖
var _effect_labels := {}        # 右侧道具剩余时间浮字（效果名 → Label）

# 难度系统状态
var paddle_count := 1           # 当前挡板数（1~4，只增不减；循环关卡不回退）
var pad_perm := 1.0             # 挡板永久长度倍率（加长/缩短道具，拾取即生效，跨关保留，新局复位）


# ===== 实体内部类（不用 class_name，包内自包含）=====

class Paddle extends Node2D:
	var horizontal := true
	var half_len := 100.0
	var thick := 18.0
	var tint := Color.WHITE
	var vel := 0.0                 # 切向速度（px/s，施加偏移角用）
	var _prev := 0.0

	func _init(h: bool, c: Color) -> void:
		horizontal = h
		tint = c

	func apply_size() -> void:
		queue_redraw()   # 程序自绘：尺寸变化直接重绘，无贴图拉伸变形

	func _draw() -> void:
		# 直角长方形：黑色描边打底 + 主体色填充，任意长度不变形
		var size := Vector2(half_len * 2.0, thick) if horizontal else Vector2(thick, half_len * 2.0)
		var ow := maxf(2.0, thick * 0.18)   # 描边宽
		draw_rect(Rect2(-size / 2.0 - Vector2.ONE * ow * 0.5, size + Vector2.ONE * ow),
				Color(0.08, 0.07, 0.06))
		draw_rect(Rect2(-size / 2.0, size), tint)

	func rect() -> Rect2:
		var size := Vector2(half_len * 2.0, thick) if horizontal else Vector2(thick, half_len * 2.0)
		return Rect2(position - size / 2.0, size)

	func track_vel(delta: float) -> void:
		var cur := position.x if horizontal else position.y
		vel = clampf((cur - _prev) / maxf(delta, 0.0001), -3000.0, 3000.0)
		_prev = cur


class Ball extends Node2D:
	var dir := Vector2.ZERO        # 单位方向（速度大小由主循环按效果统一计算）
	var couple_t := 0.0            # 剩余耦合时间：碰挡板后窗口内挡板移动仍影响球
	var couple_paddle: Paddle = null  # 耦合中的挡板
	var last_brick := Vector2i(-9, -9)  # 穿透弹去重：最近已扣血的砖格（离开砖体后清除）
	var spr: Sprite2D

	func _init(tex: Texture2D, radius: float) -> void:
		spr = Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2.ONE * (radius * 2.0 / 48.0)
		add_child(spr)


class Brick extends Node2D:
	var cell := Vector2i.ZERO
	var tint := Color.WHITE
	var hp := 1                    # 剩余耐久（= 1 + 循环圈数，受击递减）
	var spr: Sprite2D
	var base: Sprite2D = null      # 图案砖底层砖头贴图（偶数关先画砖底再叠图案）

	func _init(tex: Texture2D, s: float, c: Color, rc: Vector2i, base_tex: Texture2D = null) -> void:
		cell = rc
		tint = c
		if base_tex != null:
			base = Sprite2D.new()
			base.texture = base_tex
			base.scale = Vector2.ONE * s
			add_child(base)
		spr = Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2.ONE * s
		add_child(spr)

	# 耐久视觉：剩余 hp 越多颜色越深（每层 ×0.75 亮度），砖底与图案同步变暗
	func apply_hp_visual() -> void:
		var m := tint * pow(0.75, hp - 1)
		spr.modulate = m
		if base != null:
			base.modulate = m

	# 受击闪烁：闪白后渐回当前耐久色
	func hit_flash() -> void:
		var target := tint * pow(0.75, hp - 1)
		var tw := create_tween()
		spr.modulate = Color(1.8, 1.8, 1.8)
		if base != null:
			base.modulate = Color(1.8, 1.8, 1.8)
		tw.tween_property(spr, "modulate", target, 0.12)
		if base != null:
			tw.parallel().tween_property(base, "modulate", target, 0.12)

	func vanish() -> void:
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(spr, "scale", spr.scale * 1.25, 0.10)
		tw.chain().tween_property(self, "scale", Vector2.ONE * 0.05, 0.10)
		tw.parallel().tween_property(self, "modulate:a", 0.0, 0.10)
		tw.chain().tween_callback(queue_free)


class PowerUp extends Node2D:
	var kind := ""
	var dir := Vector2.ONE
	var n := 0                     # multi 分裂个数（生成时随机 2..4，图标角标显示）
	var spr: Sprite2D

	func _init(tex: Texture2D, s: float, k: String, d: Vector2) -> void:
		kind = k
		dir = d
		spr = Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2.ONE * s
		add_child(spr)


# ===== 生命周期 =====

func start() -> void:
	hud = GameHud.new("breakout")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_init_sfx()
	_setup_buttons()
	_build_field()
	_layout()
	_new_game()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()          # 中途退出也把本局分数入排行榜
	print("[breakout] stop, score=%d level=%d loop=%d lives=%d" % [score, level, loop, lives])


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源加载 =====

func _load_textures() -> void:
	for n: String in ["brick", "ball"]:
		_tex[n] = _load_png("res://assets/%s.png" % n)
	for n: String in BRICK_PATTERNS:
		_tex[n] = _load_png("res://assets/%s.png" % n)
	for k: String in PU_TEX:
		_tex[k] = _load_png("res://assets/" + PU_TEX[k])


func _load_png(path: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码（编辑器期走 res:// 相对路径）
	for p: String in ["res://games/breakout/" + path.trim_prefix("res://"), path]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


## 音效程序合成：正弦/方波滑音 + 衰减包络，拼段成 AudioStreamWAV
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


func _sfx_stream(parts: Array) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = 22050
	var all := PackedByteArray()
	for p: Array in parts:
		all.append_array(_tone(p[0], p[1], p[2], p[3], p[4]))
	st.data = all
	return st


func _init_sfx() -> void:
	_sfx["paddle"] = _sfx_stream([[420, 480, 0.06, true, 0.4]])
	_sfx["brick"] = _sfx_stream([[880, 220, 0.08, false, 0.55]])
	_sfx["good"] = _sfx_stream([[523, 523, 0.07, true, 0.35], [784, 784, 0.09, true, 0.35]])
	_sfx["bad"] = _sfx_stream([[392, 392, 0.08, true, 0.35], [196, 196, 0.12, true, 0.35]])
	_sfx["lose"] = _sfx_stream([[330, 82, 0.35, false, 0.6]])
	_sfx["clear"] = _sfx_stream([[523, 523, 0.09, true, 0.35], [659, 659, 0.09, true, 0.35], [784, 784, 0.14, true, 0.35]])
	_sfx["over"] = _sfx_stream([[392, 392, 0.12, true, 0.35], [311, 311, 0.12, true, 0.35], [233, 233, 0.22, true, 0.35]])
	_sfx["launch"] = _sfx_stream([[440, 660, 0.08, false, 0.4]])
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM，不影响玩法）
	for base: String in ["res://games/breakout/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


func _play_sfx(n: String) -> void:
	if not _sfx.has(n):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx[n]
			p.volume_db = SFX_DB
			p.play()
			return


# ===== 场地搭建 =====

func _build_field() -> void:
	_bricks_root = Node2D.new()
	_balls_root = Node2D.new()
	_pups_root = Node2D.new()
	_fx_root = Node2D.new()
	add_child(_bricks_root)
	add_child(_balls_root)
	add_child(_pups_root)
	# 视野模糊遮挡（道具 fog 生效时盖住砖区；圆形径向渐变，边缘羽化）
	# 位于砖块/球/道具之上（雾内看不见弹球与道具）、飘字特效之下
	_fog = Sprite2D.new()
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.6, 0.8, 1.0])
	grad.colors = PackedColorArray([
		Color(0.08, 0.09, 0.10, 0.97), Color(0.08, 0.09, 0.10, 0.95),
		Color(0.08, 0.09, 0.10, 0.55), Color(0.08, 0.09, 0.10, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)   # 半径 = 纹理宽的一半，圆直径 = 纹理宽
	gt.width = 256
	gt.height = 256
	_fog.texture = gt
	_fog.visible = false
	add_child(_fog)
	# 挡板：上/下蓝色（水平）、左/右橙色（垂直）
	_paddles["top"] = Paddle.new(true, Color(0.36, 0.66, 0.93))
	_paddles["bottom"] = Paddle.new(true, Color(0.36, 0.66, 0.93))
	_paddles["left"] = Paddle.new(false, Color(0.98, 0.62, 0.25))
	_paddles["right"] = Paddle.new(false, Color(0.98, 0.62, 0.25))
	for k: String in _paddles:
		add_child(_paddles[k])
	add_child(_fx_root)


# ===== 布局 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	_m = minf(vp.x, vp.y)
	_S = _m * S_RATIO
	_C = vp / 2.0
	_sq = Rect2(_C - Vector2.ONE * _S / 2.0, Vector2.ONE * _S)
	_T = _S * PAD_T_RATIO
	_hl = _S * PAD_L_RATIO / 2.0
	_B = _S * B_RATIO
	_cell = _B / GRID
	_B0 = _C - Vector2.ONE * _B / 2.0
	_r = _S * BALL_R_RATIO
	# 挡板：轴向位置贴边（垂直于移动轴的坐标固定在边缘内侧）
	var pm := _paddle_mult()
	_paddles["top"].position = Vector2(clampf(_paddles["top"].position.x, _sq.position.x + _hl * pm, _sq.end.x - _hl * pm), _sq.position.y + _T / 2.0)
	_paddles["bottom"].position = Vector2(clampf(_paddles["bottom"].position.x, _sq.position.x + _hl * pm, _sq.end.x - _hl * pm), _sq.end.y - _T / 2.0)
	_paddles["left"].position = Vector2(_sq.position.x + _T / 2.0, clampf(_paddles["left"].position.y, _sq.position.y + _hl * pm, _sq.end.y - _hl * pm))
	_paddles["right"].position = Vector2(_sq.end.x - _T / 2.0, clampf(_paddles["right"].position.y, _sq.position.y + _hl * pm, _sq.end.y - _hl * pm))
	# 砖块重摆（键不变，位置按新网格重算）
	for key: Vector2i in _bricks:
		_bricks[key].position = _cell_center(key)
	# 球/道具钳回场内
	for b: Ball in _balls:
		b.position = b.position.clamp(_sq.position + Vector2.ONE * _r, _sq.end - Vector2.ONE * _r)
	for pu: PowerUp in _pups:
		pu.position = pu.position.clamp(_sq.position, _sq.end)
	# 圆形模糊遮罩：圆心 = 砖区中心，直径 = 砖区边长（贴合砖块区域大小，边缘羽化渐隐）
	_fog.position = _C
	_fog.scale = Vector2.ONE * (_B / 256.0)
	_layout_boards(vp)
	_layout_buttons(vp)
	queue_redraw()


func _layout_boards(vp: Vector2) -> void:
	# 三个信息板随窗口缩放字号与板尺寸；整体水平居中用代码定位
	# （Node2D 父下 Control 锚点不可靠，与右上按钮排 _layout_buttons 同套路）
	var fs := int(_m * 0.035)
	var bw := fs * 5.0
	var bh := fs * 1.9
	for b: Label in [_level_board, _score_board, _lives_board]:
		b.custom_minimum_size = Vector2(bw, bh)
		b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_theme_font_size_override("font_size", fs)
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)


func _layout_buttons(vp: Vector2) -> void:
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


func _setup_buttons() -> void:
	# 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + BGM + 音量 + R 重开
	# 容器统一等间距（8px）、按钮固定 56×56 底对齐、图标统一 32px 居中 —— 保证水平/垂直全对齐
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_lb_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")

	# 最小化钮（关闭钮左侧）：点击最小化窗口（桌面 Win/Linux）
	var min_btn := GameHud.make_button("")
	min_btn.icon = hud.ui_icon("minimize.png")
	min_btn.custom_minimum_size = Vector2(56.0, 56.0)
	min_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	min_btn.add_theme_constant_override("icon_max_width", 32)
	min_btn.pressed.connect(func() -> void: get_window().mode = Window.MODE_MINIMIZED)
	_exit_btn.pressed.connect(_exit_button_pressed)
	_lb_btn.icon = hud.lb_icon()
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	_restart_btn.icon = hud.restart_icon()
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


func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), -1, -1)
	_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次


func _on_bgm() -> void:
	hud.cycle_bgm()
	_bgm_btn.icon = hud.bgm_icon()
	_sync_bgm()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


func _sync_bgm() -> void:
	if _bgm == null:
		return
	if hud.bgm_on and not _bgm.playing:
		_bgm.play()
	elif not hud.bgm_on and _bgm.playing:
		_bgm.stop()


# ===== 回合流程 =====

func _new_game() -> void:
	var lb := get_node_or_null("LeaderboardPanel")
	if lb != null:
		lb.queue_free()
	level = 1
	loop = 0
	score = 0
	lives = LIVES_START
	paddle_count = _level_paddles(1)
	pad_perm = 1.0              # 挡板长度倍率复位
	_apply_paddle_visibility()
	hud.reset_run()
	_clear_balls_pups_effects()
	_load_level(1)
	_spawn_ball()
	_sync_bgm()
	_refresh_boards()


## 过关 → 下一关（30 关后回 1 关：砖块耐久 +1；球速/挡板尺寸不变；挡板数只增不减）
func _advance_level() -> void:
	level += 1
	if level > 30:
		level = 1
		loop += 1
		_popup(hud.t("tip.loop_up", "Loop %d! Tougher Bricks") % (loop + 1), Color(1.0, 0.85, 0.25), _C + Vector2(0, -_S * 0.22))
	paddle_count = maxi(paddle_count, _level_paddles(level))
	_apply_paddle_visibility()
	_load_level(level)


## 关卡对应挡板数：1-4 关 1 块（底），5-8 关 2 块（+左），9-12 关 3 块（+右），13+ 关全 4 块（+上）
func _level_paddles(lv: int) -> int:
	return clampi(1 + (lv - 1) / 4, 1, 4)


## 挡板是否激活（bottom 恒在；其余按 PADDLE_ORDER 依次解锁）
func _paddle_active(k: String) -> bool:
	if k == "bottom":
		return true
	return PADDLE_ORDER.find(k) < paddle_count - 1


## 按挡板数刷新可见性（未激活边显示为白墙）
func _apply_paddle_visibility() -> void:
	for k: String in _paddles:
		_paddles[k].visible = _paddle_active(k)
	queue_redraw()


func _level_clear() -> void:
	var bonus := LEVEL_BONUS0 + (level - 1) * 50
	score += bonus
	hud.submit_score(score)
	lives += 1   # 通关奖励 1 条生命（无上限）
	_play_sfx("clear")
	_popup(hud.t("tip.level_clear", "Level Clear! +%d") % bonus, Color(1.0, 0.85, 0.25), _C + Vector2(0, -_S * 0.18))
	_clear_balls_pups_effects()
	state = State.READY
	_state_t = NEXT_LEVEL_T
	_advance_pending = true
	_refresh_boards()


func _restart() -> void:
	_new_game()


func _game_over() -> void:
	state = State.OVER
	_clear_balls_pups_effects()
	_play_sfx("over")
	_popup(hud.t("tip.game_over", "Game Over"), Color(0.98, 0.35, 0.3), _C + Vector2(0, -_S * 0.18))
	var rank: int = hud.commit_score()
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), score, rank)   # 弹出时自动暂停，关闭后自动开新局
	_arm_dev_clicks()   # 暗门：面板上 5 秒内点满 10 次


func _spawn_ball() -> void:
	var b := Ball.new(_tex["ball"], _r)
	b.position = _paddle_rest_pos()
	_balls_root.add_child(b)
	_balls.append(b)
	state = State.READY
	_popup(hud.t("tip.click_launch", "Click to Launch"), Color(1, 1, 1, 0.9), _C + Vector2(0, _S * 0.30), true)


## 待发球停靠点：下挡板中心点正上方（球贴挡板顶面，READY 期跟随挡板）
func _paddle_rest_pos() -> Vector2:
	var pr: Rect2 = _paddles["bottom"].rect()
	return Vector2(_paddles["bottom"].position.x, pr.position.y - _r)


## 左键点击发射待发球（READY 且非过关停顿期）
func _launch_ready() -> void:
	if state != State.READY or _advance_pending or _balls.is_empty():
		return
	for b: Ball in _balls:
		_launch_ball(b)
	_play_sfx("launch")
	state = State.PLAY


func _launch_ball(b: Ball) -> void:
	b.dir = Vector2.UP   # 垂直向上发射


# ===== 关卡加载 =====

## 读取关卡：exe 旁 levels/（玩家自定义覆盖）→ 包内 levels/；缺失时用内置兜底布局
func _read_level_lines(lv: int) -> Array:
	var paths: Array = []
	if not OS.has_feature("editor"):
		paths.append(OS.get_executable_path().get_base_dir().path_join("levels/level_%02d.txt" % lv))
	paths.append_array(["res://games/breakout/levels/level_%02d.txt" % lv, "res://levels/level_%02d.txt" % lv])
	for p: String in paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var lines := []
		for line: String in f.get_as_text().split("\n"):
			line = line.strip_edges()
			if line.length() == GRID:
				lines.append(line)
		f.close()
		if lines.size() == GRID:
			return lines
		print("[breakout] 关卡文件无效，尝试下一候选: ", p)
	return []


func _load_level(lv: int) -> void:
	for key: Vector2i in _bricks:
		_bricks[key].queue_free()
	_bricks.clear()
	var lines := _read_level_lines(lv)
	if lines.is_empty():   # 兜底：中央 3×6 实心块（正常情况不可达，仅防外部文件全缺失）
		lines = []
		for r in GRID:
			var row := ""
			for c in GRID:
				row += "1" if (r >= 6 and r <= 7 and c >= 4 and c <= 10) else "0"
			lines.append(row)
		print("[breakout] 未找到 level_%02d，使用内置兜底布局" % lv)
	for r in GRID:
		for c in GRID:
			if lines[r][c] == "1":
				var key := Vector2i(r, c)
				var even := level % 2 == 0   # 偶数关：水果/动物图案砖（底层先画砖头，图案叠在上面）
				var tex: Texture2D = _tex[BRICK_PATTERNS[(r + c) % BRICK_PATTERNS.size()]] if even else _tex["brick"]
				var col: Color = Color.WHITE if even else BRICK_COLORS[r % BRICK_COLORS.size()]
				var brick := Brick.new(tex, _cell * 0.94 / 64.0, col, key, _tex["brick"] if even else null)
				brick.hp = 1 + loop   # 循环难度：每圈耐久 +1（需碰撞 圈数+1 次）
				brick.apply_hp_visual()
				brick.position = _cell_center(key)
				_bricks_root.add_child(brick)
				_bricks[key] = brick
	_bricks_left = _bricks.size()
	print("[breakout] level=%d loop=%d bricks=%d" % [level, loop, _bricks_left])


func _cell_center(key: Vector2i) -> Vector2:
	return _B0 + Vector2((key.y + 0.5) * _cell, (key.x + 0.5) * _cell)


# ===== 主循环 =====

func _process(delta: float) -> void:
	if hud == null:   # 无头冒烟（--quit 直跑 entry）不经 start()，对象未创建直接跳过
		return
	_move_paddles(delta)
	_tick_effects(delta)
	_fog.visible = _has("fog")
	match state:
		State.READY:
			if _advance_pending:
				_state_t -= delta
				if _state_t <= 0.0:
					_advance_pending = false
					_advance_level()
					_refresh_boards()
					_spawn_ball()
			elif not _balls.is_empty():
				_balls[0].position = _paddle_rest_pos()   # 待发球贴下挡板跟随
		State.DEAD:
			_state_t -= delta
			if _state_t <= 0.0:
				_spawn_ball()
		State.PLAY:
			_physics_balls(delta)
			# 兜底瞄准计时（≤ASSIST_N 砖）：连续 IDLE_STUCK_T 秒无击碎 → 下次碰挡板射向最近砖
			if _bricks_left > 0 and _bricks_left <= ASSIST_N:
				_idle_t += delta
				if _idle_t >= IDLE_STUCK_T:
					_assist_on_hit = true
			else:
				_idle_t = 0.0
				_assist_on_hit = false
		State.OVER:
			if get_node_or_null("LeaderboardPanel") == null and is_inside_tree():
				_new_game()
	if state != State.OVER:
		_move_powerups(delta)
	_sync_ball_visual()
	_sync_effect_labels()


## 鼠标 → 四挡板目标位（X 控上下、Y 控左右；反转道具时镜像映射），无延迟直跟
func _move_paddles(delta: float) -> void:
	var pm := _paddle_mult()
	var hl := _hl * pm
	for k: String in _paddles:
		_paddles[k].half_len = hl
		_paddles[k].thick = _T
		_paddles[k].apply_size()
	var mp := get_global_mouse_position()
	var mx := 2.0 * _C.x - mp.x if _has("invert") else mp.x
	var my := 2.0 * _C.y - mp.y if _has("invert") else mp.y
	_paddles["top"].position.x = clampf(mx, _sq.position.x + hl, _sq.end.x - hl)
	_paddles["bottom"].position.x = clampf(mx, _sq.position.x + hl, _sq.end.x - hl)
	_paddles["left"].position.y = clampf(my, _sq.position.y + hl, _sq.end.y - hl)
	_paddles["right"].position.y = clampf(my, _sq.position.y + hl, _sq.end.y - hl)
	for k: String in _paddles:
		if not _paddle_active(k):
			continue   # 未激活挡板不跟随鼠标（白墙边）
		_paddles[k].track_vel(delta)


func _tick_effects(delta: float) -> void:
	for k: String in _effects.keys():
		_effects[k] -= delta
		if _effects[k] <= 0.0:
			_effects.erase(k)


func _has(k: String) -> bool:
	return _effects.has(k)


## 界面右侧浮字：实时显示激活道具的英文名与剩余时间（到期/互斥顶替自动移除；雾遮不住它）
func _sync_effect_labels() -> void:
	var vp := get_viewport_rect().size
	var fs := int(maxf(12.0, minf(vp.x, vp.y) * 0.020))
	var x := _sq.end.x + 14.0
	var y := _sq.position.y + 4.0
	for k: String in _effects:
		var lb: Label = _effect_labels.get(k)
		if lb == null:
			lb = Label.new()
			lb.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
			lb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			add_child(lb)
			_effect_labels[k] = lb
		lb.add_theme_font_size_override("font_size", fs)
		lb.add_theme_constant_override("outline_size", maxi(3, int(fs * 0.22)))
		lb.text = "%s %.1fs" % [hud.t("effect." + k, String(EFFECT_NAMES.get(k, k))), _effects[k]]
		lb.position = Vector2(x, y)
		y += fs * 1.5
	for k: String in _effect_labels.keys():
		if not _effects.has(k):
			(_effect_labels[k] as Label).queue_free()
			_effect_labels.erase(k)


## 挡板长度倍率：加长/缩短道具的永久倍率（互斥，后者覆盖）× 开发者滑块
func _paddle_mult() -> float:
	return pad_perm * _dev_pad


## 球速倍率：基准恒定 × 减速/加速效果（互斥）× 开发者滑块
func _speed_mult() -> float:
	var mult := 1.0
	if _has("slow"):
		mult *= 0.75
	elif _has("fast"):
		mult *= 1.25
	return mult * _dev_speed


func _sync_ball_visual() -> void:
	for b: Ball in _balls:
		if _has("pierce"):
			b.spr.modulate = Color(0.98, 0.45, 0.4)   # 穿透弹球：红
		elif _assist_on_hit:
			b.spr.modulate = Color(1.0, 0.3, 0.3)     # 兜底瞄准激活：红光提示（击中砖块后解除）
		else:
			b.spr.modulate = Color.WHITE


# ===== 球物理 =====

func _physics_balls(delta: float) -> void:
	var speed := _S * BALL_SPEED_RATIO * _speed_mult()
	for b: Ball in _balls.duplicate():
		# 挡板耦合：碰挡板后窗口内移动挡板，持续给球施加切向偏角与加速度
		if b.couple_t > 0.0:
			b.couple_t -= delta
			if b.couple_paddle != null and absf(b.couple_paddle.vel) > COUPLE_MIN_VEL:
				var p := b.couple_paddle
				var tv := Vector2(p.vel, 0.0) if p.horizontal else Vector2(0.0, p.vel)
				var nd: Vector2 = b.dir + tv * (COUPLE_GAIN * delta)
				if nd.length_squared() > 0.0001:
					b.dir = nd.normalized()
					_bounce_clamp(b)   # 耦合偏转后仍禁沿轴向平行
			if b.couple_t <= 0.0:
				b.couple_paddle = null
		var vel := b.dir * speed
		var steps := maxi(1, ceili(speed * delta / (_r * 0.5)))   # 子步防穿隧
		var sdt := delta / steps
		for i in steps:
			b.position += vel * sdt
			if _ball_step(b, speed):
				break   # 本球出界消亡
			if state != State.PLAY:   # 过关/结算中途清场，跳出物理
				return
			vel = b.dir * speed   # 反弹后按新方向继续


## 单子步碰撞解算，返回 true = 球出界消亡
func _ball_step(b: Ball, speed: float) -> bool:
	# 挡板反弹（击点偏移 + 挡板速度传递偏移角；随机反弹道具则随机方向；未激活边为白墙无挡板碰撞）
	for k: String in ["top", "bottom", "left", "right"]:
		if not _paddle_active(k):
			continue
		var p: Paddle = _paddles[k]
		var pr := p.rect()
		if not _circle_rect(b.position, _r, pr):
			continue
		var approaching := (k == "top" and b.dir.y < 0.0) or (k == "bottom" and b.dir.y > 0.0) \
				or (k == "left" and b.dir.x < 0.0) or (k == "right" and b.dir.x > 0.0)
		if not approaching:
			continue
		# 兜底瞄准：连续无击碎后碰挡板不按常规反弹，直接射向最近砖
		# （不进入挡板耦合：瞄准方向固定，之后移动挡板不影响弹球方向）
		if _assist_on_hit and _bricks_left <= ASSIST_N:
			var want := _nearest_brick_dir(b.position)
			if want != Vector2.ZERO:
				b.dir = want
				_idle_t = 0.0
				_assist_on_hit = false
				b.couple_t = 0.0
				b.couple_paddle = null
				_push_ball_out(b, pr, k)
				_play_sfx("paddle")
				return false
		match k:
			"top":
				b.dir = _paddle_bounce_dir(b, p, true, 1.0)
			"bottom":
				b.dir = _paddle_bounce_dir(b, p, true, -1.0)
			"left":
				b.dir = _paddle_bounce_dir(b, p, false, 1.0)
			"right":
				b.dir = _paddle_bounce_dir(b, p, false, -1.0)
		_push_ball_out(b, pr, k)
		_bounce_clamp(b)
		b.couple_t = HIT_COUPLING_T
		b.couple_paddle = p
		_play_sfx("paddle")
		return false
	# 砖块碰撞（9 邻域格检查；穿透弹不反弹连续击碎）
	var bc := Vector2i(
			clampi(int((b.position.y - _B0.y) / _cell), 0, GRID - 1),
			clampi(int((b.position.x - _B0.x) / _cell), 0, GRID - 1))
	var touched := false   # 本子步是否接触砖块（穿透去重用）
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			var key := Vector2i(bc.x + dr, bc.y + dc)
			if not _bricks.has(key):
				continue
			var cr := Rect2(_cell_center(key) - Vector2.ONE * _cell / 2.0, Vector2.ONE * _cell)
			var closest := b.position.clamp(cr.position, cr.end)
			if b.position.distance_to(closest) > _r:
				continue
			touched = true
			if _has("pierce"):
				# 穿透弹不反弹连续击碎；同一砖一次穿越只扣一次血，离开砖体后可再次受击
				if b.last_brick != key:
					b.last_brick = key
					_break_brick(key)
				continue
			b.last_brick = Vector2i(-9, -9)
			_break_brick(key)
			var n := b.position - closest
			if n.length_squared() < 0.0001:
				n = -b.dir   # 球心陷入格内（罕见）：按来向反弹
			n = n.normalized()
			b.dir = b.dir.bounce(n)
			b.position = closest + n * (_r + 0.5)
			_bounce_clamp(b)   # 反弹后禁沿轴向平行空跑（全程生效）
			return false
	if not touched:
		b.last_brick = Vector2i(-9, -9)   # 已离开砖体：清除穿透去重记录
	# 白墙：无挡板的边自动反弹（球不出界），镜面反射后同样受轴向钳制
	var wall := false
	if not _paddle_active("top") and b.dir.y < 0.0 and b.position.y - _r <= _sq.position.y:
		b.position.y = _sq.position.y + _r
		b.dir.y = -b.dir.y
		wall = true
	if not _paddle_active("bottom") and b.dir.y > 0.0 and b.position.y + _r >= _sq.end.y:
		b.position.y = _sq.end.y - _r
		b.dir.y = -b.dir.y
		wall = true
	if not _paddle_active("left") and b.dir.x < 0.0 and b.position.x - _r <= _sq.position.x:
		b.position.x = _sq.position.x + _r
		b.dir.x = -b.dir.x
		wall = true
	if not _paddle_active("right") and b.dir.x > 0.0 and b.position.x + _r >= _sq.end.x:
		b.position.x = _sq.end.x - _r
		b.dir.x = -b.dir.x
		wall = true
	if wall:
		_bounce_clamp(b)
		_play_sfx("paddle")
		return false
	# 完全飞出场地 → 失球
	if b.position.x < _sq.position.x - _r or b.position.x > _sq.end.x + _r \
			or b.position.y < _sq.position.y - _r or b.position.y > _sq.end.y + _r:
		_on_ball_lost(b)
		return true
	return false


## 挡板反弹：物理反射（法向翻转、切向保持）+ 击点/挡板速度小幅偏转
## side：+1 向下弹（顶板）/ -1 向上弹（底板）；垂直挡板轴互换
func _paddle_bounce_dir(b: Ball, p: Paddle, horizontal: bool, side: float) -> Vector2:
	if _has("random"):
		var n := Vector2(0, side) if horizontal else Vector2(side, 0)
		return Vector2.from_angle(n.angle() + randf_range(-1.1, 1.1))
	var offset := 0.0
	var pv := 0.0
	if horizontal:
		offset = clampf((b.position.x - p.position.x) / maxf(p.half_len, 0.001), -1.0, 1.0)
		pv = clampf(p.vel / 2000.0, -1.0, 1.0)
	else:
		offset = clampf((b.position.y - p.position.y) / maxf(p.half_len, 0.001), -1.0, 1.0)
		pv = clampf(p.vel / 2000.0, -1.0, 1.0)
	var nrm := Vector2(0, side) if horizontal else Vector2(side, 0)
	var refl := b.dir.bounce(nrm)   # 物理反射：法向分量翻转、切向分量保持
	if refl.length_squared() < 0.0001:
		refl = nrm
	var turn := offset * 0.35 + pv * 0.30   # 击点偏移 + 挡板速度 → 小幅偏转角（保留手感）
	var out := refl.rotated(turn)
	# 偏转不得反转切向分量：陡直入射+边缘击点时，偏转会让弹向翻到来向侧（原路弹回感），回退纯反射
	var tr := refl.x if horizontal else refl.y
	var to := out.x if horizontal else out.y
	if tr * to < 0.0:
		out = refl
	# 法向分量下限 0.35：浅角掠板时强制抬起，防止贴板滑行/轴向钳制推向来向侧
	var fn := out.normalized().dot(nrm)
	if fn < 0.35:
		var tdir := out - nrm * out.dot(nrm)   # 切向分量
		if tdir.length_squared() < 0.0001:
			tdir = Vector2(1, 0) if horizontal else Vector2(0, 1)
		out = nrm * 0.35 + tdir.normalized() * sqrt(1.0 - 0.35 * 0.35)
	return out.normalized()


## 球推出到挡板表面外（防二次穿透）
func _push_ball_out(b: Ball, pr: Rect2, k: String) -> void:
	match k:
		"top":
			b.position.y = pr.end.y + _r + 0.5
		"bottom":
			b.position.y = pr.position.y - _r - 0.5
		"left":
			b.position.x = pr.end.x + _r + 0.5
		"right":
			b.position.x = pr.position.x - _r - 0.5


func _circle_rect(pos: Vector2, radius: float, rect: Rect2) -> bool:
	var closest := pos.clamp(rect.position, rect.end)
	return pos.distance_squared_to(closest) <= radius * radius


# ===== 辅助机制（反弹钳制 + 兜底瞄准）=====

## 距离最近砖块的方向（单位向量；无砖返回零向量）
func _nearest_brick_dir(from: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_d := INF
	for key: Vector2i in _bricks:
		var c := _cell_center(key)
		var d := from.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = (c - from) / maxf(sqrt(d), 0.001)
	return best


## 反弹钳制（全程生效，不限砖数）：反弹后方向与水平/垂直轴的夹角都不小于 BOUNCE_MIN，
## 禁止沿挡板平行空跑；仅作用于反弹出口，发球/吸附球发射的初始方向不受限
func _bounce_clamp(b: Ball) -> void:
	if _bricks_left <= 0:
		return
	var ang := b.dir.angle()   # (-PI, PI]
	var q := snappedf(ang, PI / 2.0)   # 最近的轴向角（0 / ±PI/2 / PI）
	if absf(ang - q) < BOUNCE_MIN:
		var s := 1.0 if ang >= q else -1.0
		ang = q + s * BOUNCE_MIN   # 推离轴向 BOUNCE_MIN（≈15°）
		b.dir = Vector2.from_angle(ang)


## 砖块受击：先扣耐久（计分 + 闪烁），耐久尽才击碎（计分/飘字/掉落/消除/过关检查）
func _break_brick(key: Vector2i) -> void:
	_idle_t = 0.0          # 击中即重置兜底瞄准计时
	_assist_on_hit = false
	var brick: Brick = _bricks[key]
	var combo: int = hud.on_success()
	var pts := (BRICK_BASE + BRICK_COMBO * mini(combo - 1, COMBO_CAP)) * (2 if _has("double") else 1)
	score += pts
	hud.submit_score(score)
	_refresh_boards()
	_play_sfx("brick")
	if brick.hp > 1:       # 未击碎：扣耐久 + 受击闪烁，不掉落不消除
		brick.hp -= 1
		brick.apply_hp_visual()
		brick.hit_flash()
		return
	_bricks.erase(key)
	_bricks_left -= 1
	var at := _cell_center(key)
	if _popup_count < POPUP_MAX:
		_popup("+%d" % pts, Color(1, 1, 1, 0.9), at, true)
	if combo >= 10 and combo % 10 == 0:
		_popup(hud.t("tip.combo", "Combo ×%d") % combo, Color(0.98, 0.62, 0.25), _C + Vector2(0, -_S * 0.15))
	brick.vanish()
	if randf() < _dev_drop:
		_spawn_powerup(at)
	if _bricks_left <= 0:
		_level_clear()


## 掉落道具：从砖位飞向最近的激活挡板，碰任意挡板生效，飞出场地消失
func _spawn_powerup(at: Vector2) -> void:
	var debuff_rate := DEBUFF_RATE_LATE if level >= LATE_LEVEL else DEBUFF_RATE
	var kind: String
	if randf() < debuff_rate:
		kind = DEBUFFS[randi() % DEBUFFS.size()]
	else:
		kind = BUFFS[randi() % BUFFS.size()]
	var pu := PowerUp.new(_tex[kind], _cell * 2.1 / 96.0, kind, _nearest_paddle_dir(at))
	if kind == "multi":
		pu.n = randi_range(2, 4)   # 分裂个数生成时即确定（图标右下角显示 ×n）
		var lb := Label.new()
		lb.text = "×%d" % pu.n
		lb.add_theme_font_size_override("font_size", int(_cell * 0.85))
		lb.add_theme_color_override("font_color", Color.WHITE)
		lb.add_theme_color_override("font_outline_color", Color.BLACK)
		lb.add_theme_constant_override("outline_size", 4)
		lb.size = Vector2(_cell * 1.4, _cell * 1.0)
		lb.position = Vector2(_cell * 0.45, _cell * 0.4)
		pu.add_child(lb)
	pu.position = at
	_pups_root.add_child(pu)
	_pups.append(pu)


## 道具飞行方向：从生成点指向最近的激活挡板中心（与兜底瞄准 _nearest_brick_dir 同手法）
func _nearest_paddle_dir(from: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_d := INF
	for k: String in _paddles:
		if not _paddle_active(k):
			continue   # 未激活挡板（白墙边）不作为目标
		var d := from.distance_to(_paddles[k].position)
		if d < best_d:
			best_d = d
			best = _paddles[k].position - from
	if best.length_squared() < 0.0001:   # 与挡板中心重合（理论不可达）：随机方向兜底
		return Vector2.from_angle(randf() * TAU)
	return best.normalized()


func _move_powerups(delta: float) -> void:
	var sp := _S * PU_SPEED_RATIO
	for pu: PowerUp in _pups.duplicate():
		pu.position += pu.dir * sp * delta
		var hit := false
		for k: String in _paddles:
			if not _paddle_active(k):
				continue
			if _circle_rect(pu.position, _cell * 1.05, _paddles[k].rect()):
				_apply_powerup(pu)
				hit = true
				break
		if hit:
			_pups.erase(pu)
			pu.queue_free()
			continue
		# 白墙：无挡板的边道具反弹（不掉出）
		if not _paddle_active("top") and pu.dir.y < 0.0 and pu.position.y - _cell <= _sq.position.y:
			pu.position.y = _sq.position.y + _cell
			pu.dir.y = -pu.dir.y
		if not _paddle_active("bottom") and pu.dir.y > 0.0 and pu.position.y + _cell >= _sq.end.y:
			pu.position.y = _sq.end.y - _cell
			pu.dir.y = -pu.dir.y
		if not _paddle_active("left") and pu.dir.x < 0.0 and pu.position.x - _cell <= _sq.position.x:
			pu.position.x = _sq.position.x + _cell
			pu.dir.x = -pu.dir.x
		if not _paddle_active("right") and pu.dir.x > 0.0 and pu.position.x + _cell >= _sq.end.x:
			pu.position.x = _sq.end.x - _cell
			pu.dir.x = -pu.dir.x
		if not _sq.grow(_r * 3.0).has_point(pu.position):
			_pups.erase(pu)
			pu.queue_free()


func _apply_powerup(pu: PowerUp) -> void:
	var kind := pu.kind
	var buff := kind in BUFFS
	_play_sfx("good" if buff else "bad")
	match kind:
		"life":
			lives += 1
			_refresh_boards()
		"multi":
			_apply_multi(pu)
		"long":
			pad_perm = PAD_LONG    # 永久加长（与缩短互斥：直接覆盖倍率）
		"short":
			pad_perm = PAD_SHORT   # 永久缩短
		_:
			_effects[kind] = EFFECT_DUR[kind]
			match kind:   # 互斥效果后者覆盖
				"slow": _effects.erase("fast")
				"fast": _effects.erase("slow")
	_popup(hud.t("effect." + kind, String(PU_NAME[kind])) + (" ×%d" % pu.n if kind == "multi" else ""),
			COL_BUFF if buff else COL_DEBUFF, _C + Vector2(0, -_S * 0.12))


## 多球分裂：当前所有小球各自分裂为 n 个（n = 图标角标，2..4），独立运动永久直到出界
## 开发者模式直接调用（pu = null）时按 n = 3 处理
func _apply_multi(pu: PowerUp = null) -> void:
	var n := 3 if pu == null else (pu.n if pu.n >= 2 else randi_range(2, 4))
	if _balls.is_empty():
		# 无球期（重生等待中）捡到：从下挡板上方直接分出 n 颗（向上扇形展开）
		var rest := _paddle_rest_pos()
		for i in n:
			var b := Ball.new(_tex["ball"], _r)
			b.position = rest
			b.dir = Vector2.from_angle(-PI / 2.0 + (float(i) / (n - 1) - 0.5) * 1.6)
			_balls_root.add_child(b)
			_balls.append(b)
		if state == State.DEAD:
			state = State.PLAY
		return
	var snapshot := _balls.duplicate()
	for b: Ball in snapshot:
		for i in n - 1:
			if _balls.size() >= MAX_BALLS:
				return
			var nb := Ball.new(_tex["ball"], _r)
			nb.position = b.position
			nb.dir = b.dir.rotated((0.5 + 0.6 * randf()) * (1.0 if (i % 2 == 0) else -1.0))
			_balls_root.add_child(nb)
			_balls.append(nb)


## 失球：多球时出界的球直接消失（不扣命）；最后一球出界才 -1 生命、连击清零；
## 生命归零结算，否则回到下挡板待发
func _on_ball_lost(b: Ball) -> void:
	_balls.erase(b)
	b.queue_free()
	if not _balls.is_empty():   # 场上还有球（多球分裂）：继续游戏，无惩罚
		return
	lives -= 1
	hud.on_fail()
	_play_sfx("lose")
	_popup("-1 Life", Color(0.98, 0.35, 0.3), _C + Vector2(0, -_S * 0.12))
	_refresh_boards()
	if lives <= 0:
		_game_over()
	else:
		state = State.DEAD
		_state_t = RESPAWN_T


func _clear_balls_pups_effects() -> void:
	for b: Ball in _balls:
		b.queue_free()
	_balls.clear()
	for pu: PowerUp in _pups:
		pu.queue_free()
	_pups.clear()
	_effects.clear()
	_idle_t = 0.0          # 兜底瞄准状态一并复位
	_assist_on_hit = false


# ===== HUD =====

func _refresh_boards() -> void:
	_level_board.text = hud.t("hud.level", "Lv %d") % level
	_score_board.text = "%d" % score
	_lives_board.text = "Life %d" % lives


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed:
		_launch_ready()   # READY 待发球发射（按钮/面板点击被 GUI 消费，不会到达这里）


# ===== 飘字 =====

func _popup(text: String, color: Color, pos: Vector2, small := false) -> void:
	var m := _m
	var lb := Label.new()
	lb.text = text
	var fs := int(m * (0.022 if small else 0.045))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", fs)
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.size = Vector2(240.0, fs * 1.5)
	lb.position = pos - Vector2(120.0, fs * 0.75)
	_fx_root.add_child(lb)
	_popup_count += 1
	var life := 0.5 if small else 0.9
	var tw := lb.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.05, life)
	tw.tween_property(lb, "modulate:a", 0.0, life)
	tw.chain().tween_callback(func() -> void:
		_popup_count -= 1
		lb.queue_free())


# ===== 场地绘制 =====

func _draw() -> void:
	if _S <= 0.0:
		return
	# 场地边框分边绘制：有挡板的边不画线（挡板实体即边界）；白墙边 = 黄色墙线 + 外侧黑色阴影
	var lw := maxf(3.0, _S * 0.008)
	var sw := lw * 1.1                 # 阴影宽（略宽于墙线）
	var soff := lw * 0.5 + sw * 0.5    # 阴影中心距场地边界的外侧偏移（紧贴黄线外沿）
	var wcol := Color(0.95, 0.78, 0.22)
	var bcol := Color(0.05, 0.04, 0.03, 0.5)
	var tl := _sq.position
	var br := _sq.end
	if not _paddle_active("top"):
		draw_line(Vector2(tl.x, tl.y), Vector2(br.x, tl.y), wcol, lw)
		draw_line(Vector2(tl.x, tl.y - soff), Vector2(br.x, tl.y - soff), bcol, sw)
	if not _paddle_active("bottom"):
		draw_line(Vector2(tl.x, br.y), Vector2(br.x, br.y), wcol, lw)
		draw_line(Vector2(tl.x, br.y + soff), Vector2(br.x, br.y + soff), bcol, sw)
	if not _paddle_active("left"):
		draw_line(Vector2(tl.x, tl.y), Vector2(tl.x, br.y), wcol, lw)
		draw_line(Vector2(tl.x - soff, tl.y), Vector2(tl.x - soff, br.y), bcol, sw)
	if not _paddle_active("right"):
		draw_line(Vector2(br.x, tl.y), Vector2(br.x, br.y), wcol, lw)
		draw_line(Vector2(br.x + soff, tl.y), Vector2(br.x + soff, br.y), bcol, sw)


# ===== 开发者模式 =====
## 暗门：排行榜面板弹出后，5 秒内在面板上点击满 10 次 → 关闭排行榜后弹出调试窗口。
## 调试窗口可拖动、不暂停游戏、参数实时生效。

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
		[hud.t("dev.life100", "Life = 100"), _dev_life_100, hud.t("dev.tip_life100", "Set lives to 100")],
		[hud.t("dev.life_up", "Life +1"), _dev_life_up, hud.t("dev.tip_life_up", "Add 1 life")],
		[hud.t("dev.life_down", "Life -1"), _dev_life_down, hud.t("dev.tip_life_down", "Remove 1 life")],
		[hud.t("dev.multi", "Multi Ball"), _dev_multi, hud.t("dev.tip_multi", "Multi ball: every ball splits into 3, moving independently and permanently until it leaves the field")],
		[hud.t("dev.pierce", "Pierce Ball"), _dev_pierce, hud.t("dev.tip_pierce", "Pierce ball: balls pass through bricks without bouncing, smashing along the way (lasts %d s)") % int(EFFECT_DUR["pierce"])],
		[hud.t("dev.fog", "Fog"), _dev_fog, hud.t("dev.tip_fog", "Fog: the central brick area is covered by a semi-transparent gray overlay (lasts %d s)") % int(EFFECT_DUR["fog"])],
		[hud.t("dev.invert", "Invert"), _dev_invert, hud.t("dev.tip_invert", "Invert controls: mouse X/Y axes and paddle movement direction are reversed (lasts %d s)") % int(EFFECT_DUR["invert"])],
		[hud.t("dev.clear_level", "Clear Level"), _dev_clear_level, hud.t("dev.tip_clear_level", "Clear level: instantly remove all bricks and trigger the clear bonus")],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.tooltip_text = a[2]   # 悬停提示
		b.pressed.connect(a[1])
		grid.add_child(b)
	# 滑块：球速 / 挡板长度 / 道具掉率
	_dev_add_slider(vb, hud.t("dev.ball_speed", "Ball Speed"), _dev_speed, 0.25, 3.0, hud.t("dev.tip_ball_speed", "Ball speed multiplier (applied on top of slow/fast ball effects)"), func(v: float) -> void:
		_dev_speed = v)
	_dev_add_slider(vb, hud.t("dev.paddle_length", "Paddle Length"), _dev_pad, 0.3, 6.0, hud.t("dev.tip_paddle_length", "Paddle length multiplier (applied on top of long/short paddle effects)"), func(v: float) -> void:
		_dev_pad = v)
	_dev_add_slider(vb, hud.t("dev.drop_rate", "Drop Rate"), _dev_drop, 0.0, 1.0, hud.t("dev.tip_drop_rate", "Power-up drop rate (chance a smashed brick drops a power-up)"), func(v: float) -> void:
		_dev_drop = v)
	add_child(_dev_win)
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 标题栏拖动（面板任意位置按住标题栏移动，不影响游戏；游戏不暂停）
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
func _dev_life_100() -> void:
	lives = 100
	_refresh_boards()


func _dev_life_up() -> void:
	lives += 1
	_refresh_boards()


func _dev_life_down() -> void:
	lives = maxi(0, lives - 1)
	_refresh_boards()


func _dev_multi() -> void:
	_apply_multi()


func _dev_pierce() -> void:
	_effects["pierce"] = EFFECT_DUR["pierce"]


func _dev_fog() -> void:
	_effects["fog"] = EFFECT_DUR["fog"]


func _dev_invert() -> void:
	_effects["invert"] = EFFECT_DUR["invert"]


## 开发者清屏：全部砖块消失并直接走过关流程
func _dev_clear_level() -> void:
	for key: Vector2i in _bricks:
		_bricks[key].vanish()
	_bricks.clear()
	_bricks_left = 0
	_level_clear()
