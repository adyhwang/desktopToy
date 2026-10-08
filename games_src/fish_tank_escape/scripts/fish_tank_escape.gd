extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 鱼缸逃生（Fish Tank Escape）：鸟瞰固定场地（玻璃鱼缸），1×1 方块带景深效果从空中持续掉落，
## 落地严格对齐网格堆叠（覆盖 1 格高度 +1），掉落间隔随存活时间逐渐缩短（难度递增）。
## 点击网格指挥小人 BFS 最短路径自动躲避（仅四方向、相邻格高度差 ≤ MAX_STEP 可通行），
## 方向键可单格移动。
## 被下落方块砸中、或四周相邻格高度差全部 > MAX_STEP 被围困 → 游戏结束；
## 堆到缸口高度（WALL_H 层）并站上边缘格 → 跳出鱼缸获胜。
## 成绩 = 存活秒数，复用合集存档（GameHud submit_score/commit_score，分值 = 秒）。

const GameHud := preload("res://scripts/game_hud.gd")

# —— 可配置核心参数 ——
const GRID_W := 6             # 网格宽（格）
const GRID_H := 3             # 网格高（格）
const BLOCK_SIZE := 1          # 下落方块边长（格，1×1）
const SPAWN_EVERY := 1.6       # 开局掉落间隔（s，随存活时间线性递减至 SPAWN_MIN）
const SPAWN_MIN := 0.6         # 后期最小掉落间隔（s）
const SPAWN_RAMP := 60.0       # 间隔从 SPAWN_EVERY 递减到 SPAWN_MIN 的时长（s）
const FIRST_DELAY := 1.2       # 开局首个方块延迟（s）
const FALL_TIME := 2.5         # 单块下落时长（s）
const DROP_H := 2.35           # 下落起始高度（格，视觉景深）
const SPAWN_SCALE := 1.5       # 生成时方块放大倍率（随下落缩至 1.0）
const MAX_STEP := 1            # 可跨越的最大高度差（格）
const STEP_TIME := 0.24        # 小人移动一格耗时（s）
const HOP_H := 0.30            # 跳跃弧高（格，腾空视觉）
const OVER_DELAY := 0.7        # 结束到弹窗的延迟（s）
const DENY_TIME := 0.45        # 点击不可达格的红闪时长（s）
const WALL_H := 7              # 缸壁高度（层）；玩家堆至此层且站在边缘格即可跳出鱼缸获胜
const WIN_TIME := 2.8          # 逃生跳出动画时长（s）

const TOP_H := 150.0            # 顶栏高度（场地从其下开始布局）
const MARGIN := 16.0           # 场地区边距
const LIFT_K := 0.16           # 每层高度的视觉抬升 = cell × LIFT_K
const SFX_POOL := 4
const BGM_DB := -6.0
const SFX_DB := -4.0

# 配色（扁平卡通，同围住水果网格风）
const COL_PANEL := Color(0.984, 0.918, 0.749)        # 场地底：米黄
const COL_PANEL_BORDER := Color(0.30, 0.23, 0.18)    # 深棕描边
const COL_GRID := Color(0.858, 0.769, 0.576)         # 网格线
const COL_CHECKER := Color(1, 1, 1, 0.16)            # 棋盘格淡色交替
const COL_DENY := Color(0.92, 0.30, 0.22, 0.40)      # 不可达格红闪填充
const COL_WALL_OUT := Color(0.20, 0.15, 0.11)        # 缸壁描边（同方块深棕）
const WALL_GAP := 0.0      # 内壁离场地边缘（格宽比例，0=贴合网格边缘）
const WALL_THICK := 0.25   # 壁厚（格宽比例，薄壁）
const WALL_N := 12.0       # 缸壁超椭圆指数（2=椭圆，越大越方；12≈带小圆角的矩形）
const COL_GLASS := Color(0.72, 0.90, 0.94)            # 缸壁玻璃淡青
const COL_GLASS_TOP := Color(0.88, 0.97, 0.98)        # 玻璃壁顶亮面
const GLASS_ALPHA := 0.18  # 玻璃面不透明度（不挡视线，可手调）
const COL_GOLD := Color(1.0, 0.85, 0.25)              # 暗门触发标题金 / DEV 标题

# 方块层色（modulate 乘到白底方块贴图上）：赤橙黄绿青蓝紫按层高固定，
# 下标 = 落地前该格高度 % 7（每格从下到上固定赤→紫循环）
const RAINBOW := [
	Color(0.90, 0.26, 0.24),     # 赤
	Color(0.96, 0.55, 0.16),     # 橙
	Color(0.96, 0.84, 0.22),     # 黄
	Color(0.42, 0.76, 0.32),     # 绿
	Color(0.28, 0.76, 0.72),     # 青
	Color(0.30, 0.52, 0.90),     # 蓝
	Color(0.60, 0.38, 0.84),     # 紫
]
const DIRS4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var hud: RefCounted
var heights: Array[int] = []      # 场地每格堆叠高度（行优先）
var tints: Array[int] = []        # 每格顶块色调下标（落地方块染色）
var falls: Array[Dictionary] = [] # 下落中方块 {cx, cy, t, tint}（t 0..1）
var _dusts: Array[Dictionary] = []  # 落地尘圈 {pos, t}

var player_c := Vector2i(9, 9)    # 小人逻辑格（移动中 = 正在进入的格）
var _path: Array[Vector2i] = []   # 待走路径（不含当前格）
var _target := Vector2i(-1, -1)   # 点击目标格（-1 = 无）
var _stepping := false            # 正在两格间移动
var _step_from := Vector2i(-1, -1)
var _step_t := 0.0                # 当前步进度 0..1
var _walk_anim := 0.0             # 行走动画计时（s）
var _facing := "down"             # down / up / side
var _flip := false                # side 朝左镜像

var alive := 0.0                  # 本局存活秒数
var _spawn_t := FIRST_DELAY
var over := false
var _over_cause := ""             # crushed / trapped
var _over_t := -1.0               # >0：结束红闪/延迟倒计时
var _committed := false             # 本局成绩是否已入榜（在弹高分榜时提交）
var _lb_from_over := false          # 当前排行榜是否由游戏结束弹出（关闭后据此重开一局）
var _dev_pending := false           # 开发者暗门：排行榜面板 5 秒点满 10 次，关闭后弹 DEV 窗口
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_win: PanelContainer
var _dev_drag := false
var _deny := Vector2i(-1, -1)     # 不可达提示格
var _deny_t := -1.0

var level := 1                     # 当前关卡（难度暂不随关卡变化）
var _win_t := -1.0                 # ≥0：逃生动画进度 0..1（完成置 -1 并弹结算）
var _win_from := Vector2.ZERO      # 逃生动画起点（堆顶支撑面中心，像素）
var _win_dir := Vector2.ZERO       # 逃生跳出方向（单位向量，指向边缘外）
var _popup: Control = null         # 过关结算面板

var _cell := 50.0
var _origin := Vector2.ZERO
var _zoom := 1.0                  # 整体缩放：高堆顶将出顶栏时以场地中心为锚缩小（平滑跟随）
var _tex_block: Texture2D
var _block_aspect := 580.0 / 512.0   # 立方体贴图高宽比（顶面+前侧面一体，_load_textures 按实际贴图更新）
var _texs := {}                   # "walk_down" / "idle_side" ... → Texture2D 数组
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _hbox: HBoxContainer
var _lb_btn: Button
var _restart_btn: Button
var _bgm_btn: Button
var _volume_btn: Button

@onready var _time_board: Label = $HudBar/TimeBoard
@onready var _best_board: Label = $HudBar/BestBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("fish_tank_escape")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()   # 先建按钮再布局（_layout 会定位）
	_layout()
	_init_sfx()
	_reset_run()


func stop() -> void:
	get_tree().paused = false
	if _bgm != null:
		_bgm.stop()
	if not _committed and alive >= 1.0:   # 中途退出视作本局结束
		hud.submit_score(int(alive))
		hud.commit_score()
		_committed = true
	print("[fish_tank_escape] stop, alive=%.1f best=%d" % [alive, hud.max_score])


## ===== 回合重置 =====

func _reset_run() -> void:
	heights.resize(GRID_W * GRID_H)
	tints.resize(GRID_W * GRID_H)
	for i in GRID_W * GRID_H:
		heights[i] = 0
		tints[i] = 0
	falls.clear()
	_dusts.clear()
	player_c = Vector2i(GRID_W / 2, GRID_H / 2)
	_path.clear()
	_target = Vector2i(-1, -1)
	_stepping = false
	_step_from = Vector2i(-1, -1)
	_step_t = 0.0
	_walk_anim = 0.0
	_facing = "down"
	_flip = false
	alive = 0.0
	_spawn_t = FIRST_DELAY
	over = false
	_over_cause = ""
	_over_t = -1.0
	_committed = false
	_deny = Vector2i(-1, -1)
	_deny_t = -1.0
	_lb_from_over = false
	_zoom = 1.0
	_win_t = -1.0
	_win_from = Vector2.ZERO
	_win_dir = Vector2.ZERO
	if _popup != null:
		_popup.queue_free()
		_popup = null
		get_tree().paused = false
	hud.reset_run()
	_refresh_hud()
	queue_redraw()


## ===== 主循环 =====

func _process(delta: float) -> void:
	# 整体缩放平滑跟随（over 后也推进，作视觉收尾）
	_zoom = lerpf(_zoom, _zoom_target(), minf(delta * 5.0, 1.0))
	# 下落方块与尘圈始终推进（over 后只作视觉收尾，_land 内不再触发结束判定）
	for f in falls.duplicate():
		var t: float = f["t"] + delta / FALL_TIME
		if t >= 1.0:
			_land(f)
		else:
			f["t"] = t
	for d in _dusts.duplicate():
		var dt: float = d["t"] + delta * 2.2
		if dt >= 1.0:
			_dusts.erase(d)
		else:
			d["t"] = dt
	if over:
		if _over_cause == "escaped":
			if _win_t >= 0.0:   # 逃生跳出动画推进，完成后弹过关结算
				_win_t += delta / WIN_TIME
				if _win_t >= 1.0:
					_win_t = -1.0
					_show_win_popup()
		elif _over_t > 0.0:
			_over_t -= delta
			if _over_t <= 0.0:
				_show_lb()
		queue_redraw()
		return
	alive += delta
	# 方块生成（间隔随存活时间递减）
	_spawn_t -= delta
	if _spawn_t <= 0.0:
		_spawn_t = _spawn_interval()
		_spawn_block()
	if _deny_t > 0.0:
		_deny_t -= delta
		if _deny_t <= 0.0:
			_deny_t = -1.0
			_deny = Vector2i(-1, -1)
	_move_player(delta)
	_refresh_hud()
	queue_redraw()


## ===== 方块：生成 / 落地 =====

## 当前掉落间隔：开局 SPAWN_EVERY，随存活时间在 SPAWN_RAMP 内线性递减至 SPAWN_MIN
func _spawn_interval() -> float:
	var k := clampf(alive / SPAWN_RAMP, 0.0, 1.0)
	return lerpf(SPAWN_EVERY, SPAWN_MIN, k)


func _spawn_block() -> void:
	# 逐格双重加权随机：北侧（屏幕上方）行优先——南格堆太高会盖住北格（点不到上面的
	# 格子/方块）；堆得矮的格子也优先——各格堆高更均匀，矮格权重 = 与最高堆的差 + 1。
	# 已叠满 WALL_H 层的格、或已有方块在途的格不再掉落（单格上限 WALL_H 块，
	# 在途占用保证落地 +1 后恰好 ≤ WALL_H）
	var mh := _max_h()
	var cols := GRID_W - BLOCK_SIZE + 1
	var rows := GRID_H - BLOCK_SIZE + 1
	var weights: Array[float] = []
	for cy in rows:
		for cx in cols:
			var i := cy * GRID_W + cx
			var occupied := false
			for f in falls:
				if int(f.cx) == cx and int(f.cy) == cy:
					occupied = true
					break
			if occupied or heights[i] >= WALL_H:
				weights.append(0.0)
			else:
				weights.append(float(GRID_H - cy)
						* float(maxi(mh - heights[i], 0) + 1))
	var idx := _weighted_pick(weights)
	if weights[idx] <= 0.0:   # 全部格子已叠满（实际对局到不了）
		return
	var cx := idx % cols
	var cy := int(idx / float(cols))
	falls.append({"cx": cx, "cy": cy, "t": 0.0,
			"tint": heights[cy * GRID_W + cx] % RAINBOW.size()})


## 按权重随机取下标（权重和取随机数 + 逐项消耗）
func _weighted_pick(weights: Array[float]) -> int:
	var total := 0.0
	for w in weights:
		total += w
	var r := randf() * total
	for i in weights.size():
		r -= weights[i]
		if r <= 0.0:
			return i
	return weights.size() - 1


func _land(f: Dictionary) -> void:
	falls.erase(f)
	var cells: Array[Vector2i] = []
	for dy in BLOCK_SIZE:
		for dx in BLOCK_SIZE:
			cells.append(Vector2i(int(f["cx"]) + dx, int(f["cy"]) + dy))
	for p in cells:
		var i: int = p.y * GRID_W + p.x
		heights[i] = heights[i] + 1
		tints[i] = (heights[i] - 1) % RAINBOW.size()   # 落地前高度 = 层色下标
	# 尘圈（落在当前最高堆顶）
	var mh := 0
	for p in cells:
		mh = maxi(mh, _h_at(p))
	var fc := _foot_rect(Vector2i(int(f["cx"]), int(f["cy"])))
	_dusts.append({"pos": fc.get_center() - Vector2(0.0, float(mh) * _lift()), "t": 0.0})
	_play_sfx("land", -4.0)
	if not over and player_c in cells:   # 被正在下落的方块砸中
		_game_over("crushed")
		return
	if not over and _check_escape():     # 落块把玩家垫上墙顶（边缘格）→ 逃生
		return
	if not over and not _has_escape():   # 落地后可能围困
		_game_over("trapped")
		return
	# 高度变化后重算剩余路径（不可达则停下）
	if not _path.is_empty() and _target.x >= 0:
		var np := _find_path(player_c, _target)
		if np.is_empty():
			_path.clear()
			_target = Vector2i(-1, -1)
		else:
			_path = np


## 玩家当前是否还有可移动的相邻格（出界或高度差 > MAX_STEP 均不可走）
func _has_escape() -> bool:
	var h0: int = _h_at(player_c)
	for d in DIRS4:
		var n: Vector2i = player_c + d
		if n.x < 0 or n.y < 0 or n.x >= GRID_W or n.y >= GRID_H:
			continue
		if absi(_h_at(n) - h0) <= MAX_STEP:
			return true
	return false


func _game_over(cause: String) -> void:
	over = true
	_over_cause = cause
	_over_t = OVER_DELAY
	_path.clear()
	_target = Vector2i(-1, -1)
	_play_sfx("hit" if cause == "crushed" else "over")
	if cause == "crushed":
		_play_sfx("scream", -2.0)   # 男声「啊」惨叫（与撞击爆响叠加）
	var zc := _zoom_pivot()   # 粒子为节点不受绘制缩放，位置按缩放锚点换算
	var bp := _cell_center(player_c) - Vector2(0.0, _elev(_h_at(player_c)))
	_spawn_burst(zc + (bp - zc) * _zoom,
			Color(1.0, 0.35, 0.25) if cause == "crushed" else Color(0.6, 0.6, 0.65))


## 玩家是否达成逃生：堆顶高度（WALL_H 层）且位于边缘格 → 跳出鱼缸
func _check_escape() -> bool:
	if _h_at(player_c) < WALL_H:
		return false
	if player_c.x != 0 and player_c.x != GRID_W - 1 \
			and player_c.y != 0 and player_c.y != GRID_H - 1:
		return false
	_start_escape()
	return true


## 逃生成功：跳出方向取所在边缘朝外，成绩照常入榜，播庆祝音效，动画完成后弹结算
func _start_escape() -> void:
	over = true
	_over_cause = "escaped"
	_path.clear()
	_target = Vector2i(-1, -1)
	_stepping = false
	_step_from = Vector2i(-1, -1)
	if player_c.x == 0:
		_win_dir = Vector2(-1, 0)
	elif player_c.x == GRID_W - 1:
		_win_dir = Vector2(1, 0)
	elif player_c.y == 0:
		_win_dir = Vector2(0, -1)
	else:
		_win_dir = Vector2(0, 1)
	if _win_dir.x != 0:
		_facing = "side"
		_flip = _win_dir.x < 0
	else:
		_facing = "down" if _win_dir.y > 0 else "up"
	_win_from = _cell_center(player_c) - Vector2(0.0, _sup_eh(_h_at(player_c)))
	_win_t = 0.0
	if not _committed:
		hud.submit_score(int(alive))
		hud.commit_score()
		_committed = true
	_play_sfx("win")
	_refresh_hud()


## ===== 玩家移动 =====

func _move_player(delta: float) -> void:
	# 路径被清空（如落地后重算不可达）时，正在进行的当前步要先走完再停，防半途瞬移
	if _path.is_empty() and not _stepping:
		_step_from = Vector2i(-1, -1)
		return
	if not _stepping:
		_stepping = true
		_step_from = player_c
		player_c = _path.pop_front()
		var dd := player_c - _step_from
		if dd.x != 0:
			_facing = "side"
			_flip = dd.x < 0
		elif dd.y != 0:
			_facing = "down" if dd.y > 0 else "up"
		_step_t = 0.0
	_step_t += delta / STEP_TIME
	_walk_anim += delta
	if _step_t >= 1.0:
		_stepping = false
		_step_from = Vector2i(-1, -1)
		_step_t = 0.0
		if _path.is_empty():
			_target = Vector2i(-1, -1)
		if _check_escape():   # 站上墙顶高度（边缘格）→ 逃生
			return
		if not _has_escape():   # 到达后可能主动跳进死路
			_game_over("trapped")


## BFS 最短路径（四方向，相邻格高度差 ≤ MAX_STEP 可通行），返回不含起点的格序列
func _find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var res: Array[Vector2i] = []
	if from == to:
		return res
	var prev := {}   # Vector2i → 来源格
	prev[from] = Vector2i(-1, -1)
	var q: Array[Vector2i] = [from]
	var head := 0
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		if cur == to:
			break
		var hc: int = _h_at(cur)
		for d in DIRS4:
			var n: Vector2i = cur + d
			if prev.has(n):
				continue
			if n.x < 0 or n.y < 0 or n.x >= GRID_W or n.y >= GRID_H:
				continue
			if absi(_h_at(n) - hc) > MAX_STEP:
				continue
			prev[n] = cur
			q.append(n)
	if not prev.has(to):
		return res
	var c: Vector2i = to
	while c != from:
		res.push_front(c)
		var pv: Vector2i = prev[c]
		c = pv
	return res


func _click_cell(cell: Vector2i) -> void:
	if cell == player_c:
		return
	var p := _find_path(player_c, cell)
	if p.is_empty():
		_deny = cell
		_deny_t = DENY_TIME
		return
	_path = p
	_target = cell


func _key_step(d: Vector2i) -> void:
	var n: Vector2i = player_c + d
	if n.x < 0 or n.y < 0 or n.x >= GRID_W or n.y >= GRID_H:
		return
	if absi(_h_at(n) - _h_at(player_c)) > MAX_STEP:
		_deny = n
		_deny_t = DENY_TIME
		return
	_path = [n]   # 键盘自由走，无目标格；移动中按下则到达当前格后立刻转向
	_target = Vector2i(-1, -1)


## ===== 输入 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
			return
		var d := Vector2i.ZERO
		match event.keycode:
			KEY_LEFT:
				d = Vector2i(-1, 0)
			KEY_RIGHT:
				d = Vector2i(1, 0)
			KEY_UP:
				d = Vector2i(0, -1)
			KEY_DOWN:
				d = Vector2i(0, 1)
		if d != Vector2i.ZERO and not over:
			_key_step(d)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and not over:
		var cell := _pick_cell(event.position)
		if cell.x < 0:
			return
		_click_cell(cell)


func _exit_button_pressed() -> void:
	exit_requested.emit()


func _restart() -> void:
	if not _committed and alive >= 1.0:   # 重开也视作本局结束（合集惯例）
		hud.submit_score(int(alive))
		hud.commit_score()
		_committed = true
	_reset_run()


## ===== 布局与按钮 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var avail_w: float = maxf(vp.x - MARGIN * 2.0, 60.0)
	var avail_h: float = maxf(vp.y - TOP_H - MARGIN * 2.0, 60.0)
	_cell = maxf(minf(avail_w / float(GRID_W), avail_h / float(GRID_H)), 1.0)
	var bw := float(GRID_W) * _cell
	var bh := float(GRID_H) * _cell
	_origin = Vector2((vp.x - bw) * 0.5, TOP_H + (vp.y - TOP_H - bh) * 0.5)
	for b: Label in [_time_board, _best_board]:
		b.custom_minimum_size = Vector2(200.0, m * 0.051)
		b.add_theme_font_size_override("font_size", int(m * 0.035))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	_refresh_hud()
	queue_redraw()


## 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + BGM + 音量循环
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
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
	_lb_from_over = over   # 结束态点开榜：关闭后同样重开
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), -1, -1)
	_arm_dev_clicks()


func _on_bgm() -> void:
	hud.cycle_bgm()
	_bgm_btn.icon = hud.bgm_icon()
	if _bgm != null:
		if hud.bgm_on:
			_bgm.play()
		else:
			_bgm.stop()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


func _refresh_hud() -> void:
	_time_board.text = "%s %s" % [hud.t("bd.time", "Time"), _fmt_time(alive)]
	_best_board.text = "%s %s" % [hud.t("bd.best", "Best"), _fmt_time(float(hud.max_score))]


func _fmt_time(t: float) -> String:
	var s := int(t)
	return "%d:%02d" % [s / 60, s % 60]


## ===== 绘制 =====

func _draw() -> void:
	if heights.is_empty():
		return
	# 整体缩放（高堆时以场地中心为锚缩小）；zt 供子函数与局部 transform 复合
	var zt := Transform2D(Vector2(_zoom, 0.0), Vector2(0.0, _zoom), _zoom_pivot() * (1.0 - _zoom))
	draw_set_transform_matrix(zt)
	var pad := 10.0   # 立方体贴图 1:1 收在格内（厚度不越界），四边对称 pad 即可
	var board := Rect2(_origin - Vector2(pad, pad),
			Vector2(float(GRID_W) * _cell, float(GRID_H) * _cell) + Vector2(pad * 2.0, pad * 2.0))
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.border_color = COL_PANEL_BORDER
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(14)
	draw_style_box(sb, board)
	# 网格线
	for x in GRID_W + 1:
		var gx := _origin.x + float(x) * _cell
		draw_line(Vector2(gx, _origin.y), Vector2(gx, _origin.y + float(GRID_H) * _cell), COL_GRID, 1.0)
	for y in GRID_H + 1:
		var gy := _origin.y + float(y) * _cell
		draw_line(Vector2(_origin.x, gy), Vector2(_origin.x + float(GRID_W) * _cell, gy), COL_GRID, 1.0)
	# 棋盘格淡色交替
	for y in GRID_H:
		for x in GRID_W:
			if (x + y) % 2 == 0:
				var r := Rect2(_origin + Vector2(float(x), float(y)) * _cell, Vector2.ONE * _cell)
				draw_rect(r, COL_CHECKER, true)
	# 缸壁北半（玻璃背面）：先画，在堆叠与人后
	_draw_wall_back()
	# 已落地方块堆（行优先，南侧后画覆盖北侧，符合俯视遮挡；每层 = 一体化立方体贴图，
	# 顶面与前侧面同图经描边衔接，层间前侧面恰好 ≈ LIFT 无缝堆叠）
	var bs := _block_sz()
	for y in GRID_H:
		for x in GRID_W:
			var h: int = heights[y * GRID_W + x]
			if h <= 0:
				continue
			var base := Rect2(_origin + Vector2(float(x), float(y)) * _cell, Vector2.ONE * _cell)
			var tint: Color = RAINBOW[tints[y * GRID_W + x]]
			for k in h:
				var shade := 1.0 if k == h - 1 else (0.62 + 0.38 * float(k + 1) / float(h))
				draw_texture_rect(_tex_block,
						Rect2(base.position - Vector2(0.0, float(k) * _lift()), bs),
						false, Color(tint.r * shade, tint.g * shade, tint.b * shade))
	# 落地尘圈（方形描边扩散，呼应方形阴影）
	for d in _dusts:
		var dt: float = d["t"]
		var e := _cell * (1.0 + 1.4 * dt)
		draw_rect(Rect2(d["pos"] - Vector2(e, e) * 0.5, Vector2(e, e)),
				Color(1.0, 1.0, 1.0, 0.55 * (1.0 - dt)), false, maxf(_cell * 0.06, 2.0))
	# 小人（影子 + 贴图）：被砸中后直接移除（不绘制），围困结束仍显示
	if not (over and _over_cause == "crushed"):
		_draw_player(zt)
	# 不可达红闪（画在堆叠之上避免被方块挡住；覆盖该格堆叠的视觉体，随层数上扩）
	if _deny_t > 0.0 and _deny.x >= 0:
		var dh := _h_at(_deny)
		var dr := Rect2(_origin + Vector2(_deny) * _cell
				- Vector2(0.0, float(dh - 1) * _lift()),
				Vector2(_cell, _cell + float(dh - 1) * _lift()))
		draw_rect(dr, COL_DENY, true)
	# 下落方块的地面阴影（先）与方块本体（后）
	for f in falls:
		_draw_fall(f, zt)
	# 南侧缸壁（玻璃正面）：半透明画在最上（不挡视线；跳出动画的人落地缸外）
	_draw_wall_front()
	draw_set_transform_matrix(Transform2D())   # 复位绘制变换


## ===== 连续方形鱼缸壁：一圈玻璃薄壁（厚 WALL_THICK 格）环绕场地，高 WALL_H 层 =====
## 形状为超椭圆（n=WALL_N，近矩形带小圆角）；四面全是半透明玻璃（北半先画在南半
## 之前，南半最后画在人/方块之上），东西端帽封口相连成缸。

## 环半宽/半高：thick 0=内壁 1=外壁（场地半宽/半高 + 间隙 + 壁厚）
func _wall_ab(thick: float) -> Vector2:
	var half := Vector2(float(GRID_W), float(GRID_H)) * _cell * 0.5 + Vector2.ONE * (_cell * WALL_GAP)
	return half + Vector2.ONE * (_cell * WALL_THICK * thick)


## 壁上一点：超椭圆（|x/a|^n + |y/b|^n = 1）参数化，th 为以场地中心为心的
## 极角（0=东 PI/2=南 PI=西），h 为离地高度；θ=0/PI 处 x=±a，端帽衔接不变
func _wall_pt(thick: float, th: float, h: float) -> Vector2:
	var ab := _wall_ab(thick)
	var k := 2.0 / WALL_N
	var c := cos(th)
	var s := sin(th)
	var pt := Vector2(signf(c) * pow(absf(c), k) * ab.x, signf(s) * pow(absf(s), k) * ab.y)
	return _zoom_pivot() + pt - Vector2(0.0, h)


## 玻璃弧片：外壁→内壁整片填充（墙顶到底缘，无砖纹）+ 上部反光弧带 + 径向棱线
func _glass_arc(th0: float, th1: float, alpha: float) -> void:
	var h := float(WALL_H) * _lift()
	var n := 48
	var gcol := Color(COL_GLASS.r, COL_GLASS.g, COL_GLASS.b, alpha)
	# 玻璃弧片按 48 段「外壁顶→内壁底」四边形铺设（大多边形 earcut 会三角化失败）
	for i in n:
		var t0 := lerpf(th0, th1, float(i) / float(n))
		var t1 := lerpf(th0, th1, float(i + 1) / float(n))
		draw_colored_polygon(PackedVector2Array([
				_wall_pt(1.0, t0, h), _wall_pt(1.0, t1, h),
				_wall_pt(0.0, t1, 0.0), _wall_pt(0.0, t0, 0.0)]), gcol)
	# 上部反光弧带：外壁往内 8%~22%、弧长 18%~82% 处（玻璃顶部反光）
	var gl := Color(1, 1, 1, alpha * 0.9)
	var a0 := lerpf(th0, th1, 0.18)
	var a1 := lerpf(th0, th1, 0.82)
	for i in 32:
		var t0 := lerpf(a0, a1, float(i) / 32.0)
		var t1 := lerpf(a0, a1, float(i + 1) / 32.0)
		draw_colored_polygon(PackedVector2Array([
				_wall_pt(0.92, t0, h * 0.88), _wall_pt(0.92, t1, h * 0.88),
				_wall_pt(0.78, t1, h * 0.88), _wall_pt(0.78, t0, h * 0.88)]), gl)
	# 径向棱线（玻璃分瓣反光，弧上均分 3 条，中高度）
	var edge := Color(1, 1, 1, alpha * 0.7)
	for k in 3:
		var th := lerpf(th0, th1, (float(k) + 1.0) / 4.0)
		draw_line(_wall_pt(1.0, th, h * 0.5), _wall_pt(0.0, th, h * 0.5), edge, 2.0)


## 壁顶（环状顶面）：内壁与外壁之间、抬升 WALL_H×lift 的一段环带
func _wall_rim(th0: float, th1: float, alpha: float) -> void:
	var h := float(WALL_H) * _lift()
	var n := 48
	var c := Color(COL_GLASS_TOP.r, COL_GLASS_TOP.g, COL_GLASS_TOP.b, alpha)
	for i in n:
		var t0 := lerpf(th0, th1, float(i) / float(n))
		var t1 := lerpf(th0, th1, float(i + 1) / float(n))
		draw_colored_polygon(PackedVector2Array([
				_wall_pt(1.0, t0, h), _wall_pt(1.0, t1, h),
				_wall_pt(0.0, t1, h), _wall_pt(0.0, t0, h)]), c)


## 北半缸壁（先画，在堆叠/人后）：玻璃弧片 + 东西端帽 + 玻璃壁顶 + 半透明描边
func _draw_wall_back() -> void:
	var h := float(WALL_H) * _lift()
	var n := 48
	var a := GLASS_ALPHA
	_glass_arc(PI, TAU, a)
	# 东西端帽（内外壁之间封口，稍实于玻璃面）
	var cap := Color(COL_GLASS.r, COL_GLASS.g, COL_GLASS.b, minf(a + 0.12, 1.0))
	for s in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
				_zoom_pivot() + Vector2(s * _wall_ab(0.0).x, 0.0),
				_zoom_pivot() + Vector2(s * _wall_ab(1.0).x, 0.0),
				_zoom_pivot() + Vector2(s * _wall_ab(1.0).x, -h),
				_zoom_pivot() + Vector2(s * _wall_ab(0.0).x, -h)]), cap)
	_wall_rim(PI, TAU, minf(a + 0.35, 1.0))
	var out_c := Color(COL_WALL_OUT.r, COL_WALL_OUT.g, COL_WALL_OUT.b, minf(a + 0.35, 1.0))
	var gn := PackedVector2Array()
	for i in n + 1:
		gn.append(_wall_pt(0.0, PI + TAU * float(i) / float(n), 0.0))
	draw_polyline(gn, out_c, 3.0)
	for t in [0.0, 1.0]:
		var ln := PackedVector2Array()
		for i in n + 1:
			ln.append(_wall_pt(t, PI + TAU * float(i) / float(n), h))
		draw_polyline(ln, out_c, 3.0)
	for s in [-1.0, 1.0]:
		for t in [0.0, 1.0]:
			draw_line(_zoom_pivot() + Vector2(s * _wall_ab(t).x, 0.0),
					_zoom_pivot() + Vector2(s * _wall_ab(t).x, -h), out_c, 3.0)


## 南半缸壁（最后画，在人/方块之上）：玻璃弧片 + 玻璃壁顶 + 半透明描边
func _draw_wall_front() -> void:
	var h := float(WALL_H) * _lift()
	var n := 48
	var a := GLASS_ALPHA
	_glass_arc(0.0, PI, a)
	_wall_rim(0.0, PI, minf(a + 0.35, 1.0))
	var out_c := Color(COL_WALL_OUT.r, COL_WALL_OUT.g, COL_WALL_OUT.b, minf(a + 0.35, 1.0))
	var gs := PackedVector2Array()
	for i in n + 1:
		gs.append(_wall_pt(1.0, PI * float(i) / float(n), 0.0))
	draw_polyline(gs, out_c, 3.0)
	for t in [0.0, 1.0]:
		var ln := PackedVector2Array()
		for i in n + 1:
			ln.append(_wall_pt(t, PI * float(i) / float(n), h))
		draw_polyline(ln, out_c, 3.0)


func _draw_player(zt: Transform2D) -> void:
	var frames: Array = _texs["idle_" + _facing]
	if _stepping:
		frames = _texs["walk_" + _facing]
	var fi := 0
	if over and _over_cause == "escaped":
		if _win_t >= 0.0:   # 跳出动画：行走帧
			frames = _texs["walk_" + _facing]
			fi = int(_win_t * WIN_TIME * 8.0) % frames.size()
	elif over:
		fi = 0
	elif _stepping:
		fi = int(_walk_anim * 8.0) % frames.size()
	else:
		fi = int(alive * 2.0) % frames.size()
	var tex: Texture2D = frames[fi]
	if tex == null:
		return
	# 位置：两格间插值 + 支撑面抬升 + 跳跃弧（腾空过格；影子留支撑面）
	var cpos: Vector2
	var ground_eh: float
	var hop := 0.0
	if over and _over_cause == "escaped":
		# 逃生动画：从堆顶抛物线跃向墙外，落定站墙外地面
		var k: float = 1.0 if _win_t < 0.0 else clampf(_win_t, 0.0, 1.0)
		cpos = _win_from + _win_dir * (1.6 * _cell) * k
		ground_eh = lerpf(_sup_eh(_h_at(player_c)), 0.0, k)
		hop = sin(k * PI) * 1.2 * _cell
	elif _stepping:
		var k := clampf(_step_t, 0.0, 1.0)
		cpos = _cell_center(_step_from).lerp(_cell_center(player_c), k)
		ground_eh = lerpf(_sup_eh(_h_at(_step_from)), _sup_eh(_h_at(player_c)), k)
		hop = sin(k * PI) * HOP_H * _cell
	else:
		cpos = _cell_center(player_c)
		ground_eh = _sup_eh(_h_at(player_c))
	var foot := cpos - Vector2(0.0, ground_eh + hop)   # 脚底 = 支撑面中心（格心 / 堆顶面中心）
	var ts := tex.get_size()
	var w := _cell * 0.72
	var hgt := w * ts.y / maxf(ts.x, 1.0)
	var mod := Color(1, 1, 1)
	if over and _over_cause != "escaped":   # 逃生成功保持本色
		mod = Color(1.0, 0.45, 0.4) if _over_cause == "crushed" else Color(0.65, 0.65, 0.7)
	# 影子贴在支撑面（脚底正下方）：跳起时缩小变淡（腾空感）；局部 transform 与缩放矩阵复合
	var hop_k := clampf(hop / maxf(HOP_H * _cell, 0.001), 0.0, 1.0)
	var sc := 1.0 - 0.30 * hop_k
	draw_set_transform_matrix(zt * Transform2D(Vector2(sc, 0.0), Vector2(0.0, 0.42 * sc),
			cpos - Vector2(0.0, ground_eh)))
	draw_circle(Vector2.ZERO, w * 0.42, Color(0.12, 0.09, 0.05, 0.18 * (1.0 - 0.4 * hop_k)))
	draw_set_transform_matrix(zt)
	# 贴图以脚底为底边中心向上绘制（落脚点 = 支撑面中心）
	var dst := Rect2(foot - Vector2(w * 0.5, hgt), Vector2(w, hgt))
	if _flip:
		draw_set_transform_matrix(zt * Transform2D(Vector2(-1.0, 0.0), Vector2(0.0, 1.0), dst.get_center()))
		draw_texture_rect(tex, Rect2(-Vector2(w, hgt) * 0.5, Vector2(w, hgt)), false, mod)
		draw_set_transform_matrix(zt)
	else:
		draw_texture_rect(tex, dst, false, mod)


func _draw_fall(f: Dictionary, zt: Transform2D) -> void:
	var t: float = clampf(float(f["t"]), 0.0, 1.0)
	var foot := _foot_rect(Vector2i(int(f["cx"]), int(f["cy"])))
	# 方形阴影：投在当前堆顶，随下落变大变深
	var mh := 0
	for dy in BLOCK_SIZE:
		for dx in BLOCK_SIZE:
			mh = maxi(mh, _h_at(Vector2i(int(f["cx"]) + dx, int(f["cy"]) + dy)))
	var sh_size := foot.size * lerpf(0.35, 1.0, t)
	var sh_r := Rect2(foot.get_center() - sh_size * 0.5 - Vector2(0.0, float(mh) * _lift()), sh_size)
	draw_rect(sh_r, Color(0.12, 0.09, 0.05, lerpf(0.10, 0.40, t)), true)
	# 方块本体：4 个一体化立方块，从高处放大块渐缩到位（位置加速下落，与落地渲染无缝衔接）
	var tint: Color = RAINBOW[int(f["tint"])]
	var half := _cell * 0.5
	var fbs := _block_sz()
	for dy in BLOCK_SIZE:
		for dx in BLOCK_SIZE:
			var p := Vector2i(int(f["cx"]) + dx, int(f["cy"]) + dy)
			var target_off := float(_h_at(p)) * _lift()   # 落定后该格顶块抬升
			var off := lerpf(target_off + DROP_H * _cell, target_off, t * t)
			var s := lerpf(SPAWN_SCALE, 1.0, t)
			var c := _cell_center(p) - Vector2(0.0, off)
			draw_set_transform_matrix(zt * Transform2D(Vector2(s, 0.0), Vector2(0.0, s), c))
			draw_texture_rect(_tex_block, Rect2(-Vector2(half, half), fbs), false, tint)
			draw_set_transform_matrix(zt)


## ===== 结束 → 高分榜（高亮本局成绩）=====

## 提交本局成绩并弹出合集统一排行榜（current 行高亮本局存活时长）
func _show_lb() -> void:
	_lb_from_over = true
	hud.submit_score(int(alive))
	var rank: int = hud.commit_score()
	_committed = true
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), int(alive), rank)
	_arm_dev_clicks()
	_refresh_hud()   # BestBoard 同步新纪录


## 排行榜关闭回调（GameHud._close_lb 调用， paused 已恢复）：
## 暗门已触发则弹出 DEV 窗口；否则结束弹出的榜关闭后重开一局、
## 游戏中手动弹出的榜关闭后继续当前局
func on_leaderboard_closed() -> void:
	if _dev_pending:
		_dev_pending = false
		_show_dev_window()
	elif _lb_from_over:
		_lb_from_over = false
		_restart()


## ===== 开发者模式（排行榜面板暗门：5 秒点满 10 次 → 关闭后弹出 DEV 窗口）=====

## 绑定排行榜面板点击计数（每次弹榜后调用，面板为新建节点）
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
		if panel != null:   # 标题金色反馈（面板 ALWAYS，暂停中可见）
			var head := panel.get_child(0)
			if head is Container and head.get_child(0) is Label:
				(head.get_child(0) as Label).add_theme_color_override("font_color", COL_GOLD)


## DEV 窗口：可拖动、常驻（✕ 关闭），功能按钮 2 列网格
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
		[hud.t("dev.time", "Time +60"), _dev_add_time],
		[hud.t("dev.raise", "Raise cell"), _dev_raise_cell],
		[hud.t("dev.win", "Escape now"), _dev_escape],
		[hud.t("dev.clear", "Clear blocks"), _dev_clear],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.pressed.connect(a[1])
		grid.add_child(b)
	add_child(_dev_win)     # 屏幕坐标（同排行榜面板，不随绘制缩放）
	_dev_win.z_index = 250  # 浮于排行榜(220)之上
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 标题栏拖动
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += event.relative)


func _dev_close() -> void:
	_dev_drag = false
	if _dev_win != null and is_instance_valid(_dev_win):
		_dev_win.queue_free()
	_dev_win = null


## 时间 +60 秒（成绩 = 存活秒数，直接提高本局成绩）
func _dev_add_time() -> void:
	if over:
		return
	alive += 60.0
	_refresh_hud()


## 垫高人物所在格 +1（模拟一次落地：染色 + 落地音）
func _dev_raise_cell() -> void:
	if over:
		return
	var i := player_c.y * GRID_W + player_c.x
	heights[i] += 1
	tints[i] = (heights[i] - 1) % RAINBOW.size()
	_play_sfx("land", -4.0)
	queue_redraw()
	_refresh_hud()


## 立即逃生获胜（走正常逃生流程：跳出动画 → 结算 → 入榜）
func _dev_escape() -> void:
	if not over:
		_start_escape()


## 清空全部方块（堆叠归零）
func _dev_clear() -> void:
	if over:
		return
	heights.fill(0)
	tints.fill(0)
	queue_redraw()
	_refresh_hud()


## 过关结算：复用方块拼图（tetris_puzzle）结算 UI——深色半透明底圆角 18 + 金黄标题
## + 白字信息 + 居中按钮行（下一关），按钮字号后置覆盖（同 tetris 做法）
func _show_win_popup() -> void:
	get_tree().paused = true
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	_popup = PanelContainer.new()
	_popup.name = "WinPopup"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.96)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.04)
	_popup.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.018))
	_popup.add_child(vb)
	var title := Label.new()
	title.text = hud.t("bd.win_title", "Escaped!")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(m * 0.055))
	GameHud._style_label(title, Color(1.0, 0.85, 0.25))
	vb.add_child(title)
	var info := Label.new()
	info.text = "%s      %s" % [hud.t("bd.level", "Level %s") % str(level), _fmt_time(alive)]
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", int(m * 0.032))
	GameHud._style_label(info, Color.WHITE)
	vb.add_child(info)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(row)
	var next_btn := GameHud.make_button(hud.t("bd.next", "Next Level"))
	next_btn.pressed.connect(_on_next_level)
	row.add_child(next_btn)
	for b: Button in row.get_children():
		b.add_theme_font_size_override("font_size", int(m * 0.034))
	add_child(_popup)
	_popup.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中仍可点击
	_popup.z_index = 200
	_popup.reset_size()
	_popup.position = (get_viewport_rect().size - _popup.size) * 0.5


## 下一关：难度不变，重开一局（关卡数 +1）
func _on_next_level() -> void:
	level += 1
	_reset_run()


## ===== 特效 =====

## 结束粒子迸发
func _spawn_burst(pos: Vector2, col: Color) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 32
	p.lifetime = 0.8
	p.direction = Vector2(0, -1)
	p.spread = 75.0
	p.gravity = Vector2(0, 640)
	p.initial_velocity_min = 180.0
	p.initial_velocity_max = 380.0
	p.scale_amount_min = 4.0
	p.scale_amount_max = 8.0
	var g := Gradient.new()
	g.set_color(0, col)
	g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.color_ramp = g
	add_child(p)
	p.emitting = true
	var tw := create_tween()
	tw.tween_interval(1.3)
	tw.tween_callback(p.queue_free)


## ===== 贴图与音效 =====

func _load_textures() -> void:
	_tex_block = _load_png("assets/blocks/block.png")
	if _tex_block != null:
		_block_aspect = _tex_block.get_size().y / maxf(_tex_block.get_size().x, 1.0)
	for dirn: String in ["down", "up", "side"]:
		var walk: Array = []
		var idle: Array = []
		for i in 4:
			walk.append(_load_png("assets/player/walk_%s_%d.png" % [dirn, i]))
		for i in 2:
			idle.append(_load_png("assets/player/idle_%s_%d.png" % [dirn, i]))
		_texs["walk_" + dirn] = walk
		_texs["idle_" + dirn] = idle


## pck 内 png 字节解码（不走导入流程）；双路径兼容编辑器直跑
func _load_png(rel: String) -> Texture2D:
	for base in ["res://games/fish_tank_escape/", "res://"]:
		var f := FileAccess.open(base + rel, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
			return null
	return null


## pck 内音频走字节解码，编辑器预览走导入资源（双路径）；WAV 用 AudioStreamWAV
func _init_sfx() -> void:
	var files := {"land": "land.wav", "hit": "hit.wav", "over": "over.wav", "scream": "scream.wav", "win": "win.wav"}
	for sname: String in files:
		for base in ["res://games/fish_tank_escape/assets/sfx/", "res://assets/sfx/"]:
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
	# BGM：复用合集 BGM（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/fish_tank_escape/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## ===== 几何辅助 =====

func _max_h() -> int:
	var m := 0
	for h in heights:
		m = maxi(m, int(h))
	return m


## 整体缩放目标：最高堆顶/墙顶（含人物头顶余量）将顶出屏幕顶时缩小画面以容纳全景；
## 锚点为场地中心（堆顶与底边同时向中心收），无高墙时为 1（不缩放）
func _zoom_target() -> float:
	# 墙顶伸出（壁顶在场心上方：横向半径 + WALL_H×lift）；堆顶伸出按最高堆算
	var wall_over := (WALL_GAP + WALL_THICK) * _cell + float(WALL_H) * _lift()
	var stack_over := float(maxi(_max_h() - 1, 0)) * _lift()
	var overflow := maxf(wall_over, stack_over) + _cell * 0.35   # 伸出 + 人物头顶余量
	var pivot_y := _origin.y + float(GRID_H) * _cell * 0.5
	return minf(1.0, (pivot_y - 40.0) / (float(GRID_H) * _cell * 0.5 + overflow))   # 墙顶最多收到 HUD（40px）之下


## 缩放锚点：场地中心
func _zoom_pivot() -> Vector2:
	return Vector2(_origin.x + float(GRID_W) * _cell * 0.5, _origin.y + float(GRID_H) * _cell * 0.5)


## 点击视觉命中：格子可点区域 = 地面格向上扩 (h-1)×lift（堆叠顶面上沿）；
## 从最南行倒序检测（南侧后画盖北侧，视觉最前的堆优先命中）；
## 缩放时先把屏幕坐标按缩放锚点逆变换回场景坐标（与绘制一致）
func _pick_cell(pos: Vector2) -> Vector2i:
	var p := pos
	if _zoom < 1.0:
		p = _zoom_pivot() + (pos - _zoom_pivot()) / _zoom
	for y in range(GRID_H - 1, -1, -1):
		for x in GRID_W:
			var h := _h_at(Vector2i(x, y))
			var r := Rect2(_origin + Vector2(float(x), float(y)) * _cell
					- Vector2(0.0, float(h - 1) * _lift()),
					Vector2(_cell, _cell + float(h - 1) * _lift()))
			if r.has_point(p):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _cell_center(p: Vector2i) -> Vector2:
	return _origin + (Vector2(p) + Vector2(0.5, 0.5)) * _cell


func _foot_rect(top_left: Vector2i) -> Rect2:
	return Rect2(_origin + Vector2(top_left) * _cell, Vector2.ONE * (_cell * float(BLOCK_SIZE)))


func _lift() -> float:
	return _cell * LIFT_K


## 立方体贴图绘制尺寸：宽 = cell（顶面），高按贴图比例（含前侧面厚度 ≈ LIFT）
func _block_sz() -> Vector2:
	return Vector2(_cell, _cell * _block_aspect)


func _h_at(p: Vector2i) -> int:
	return heights[p.y * GRID_W + p.x]


## 站立高度视觉抬升：h≤1 贴地，h≥2 每加一层抬一格 LIFT
func _elev(h: int) -> float:
	return maxf(0.0, float(h - 1)) * _lift()


## 脚底支撑面相对格心的抬升：空地 = 格心；堆顶 = 立方体顶面中心
## （顶面高 cell−lift、居中偏上，其中心比格心高 lift/2，h≥1 时叠加）
func _sup_eh(h: int) -> float:
	return _elev(h) + (_lift() * 0.5 if h >= 1 else 0.0)
