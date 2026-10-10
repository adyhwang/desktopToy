extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## Maze（走迷宫）：俯视角随机迷宫，控制小人抵达绿色出口门通关，无失败判定
## 关卡：第 1 关 10×10，每过 1 关扩 1 格（方向按屏幕剩余空间决定，总格子数达 625 封顶且单维可超 25）；低关按比例打通死路（braid），高关死路更多
## 生成：递归回溯完美迷宫（全连通，出口必可达）→ BFS 取距起点最远边界格为出口
## 外墙：四周围墙封闭，仅在出口/入口处凿门洞；出口门嵌在外墙线上（左右侧门贴图旋转 90°）
## 操作：左键点击 / 拖拽指引目标点（角色自动寻走，撞墙停滞即停）；方向键备用
## 提示：? 按钮——BFS 算出小人当前位置到出口门的路径，金色圆点轨迹显示 6 秒，可随时重按刷新
## 计分：金币 +10；通关时间奖励 = 剩余秒 ×4；超时不失败仅停发时间奖励
## R 键：不重建迷宫，仅重置状态（小人回起点、金币复原、计时重置、分数回滚到本关开始）
## 小猪 CPU：第 2 关起与小人同在起点格出生，速度约 0.8× 小人，
##   沿左墙或右墙贴墙走（左手/右手定则），必经出口格后钻出门洞出迷宫（仅提示，无胜负影响）；
##   玩家先于小猪出迷宫得竞速奖励 +100
## 不记录关卡进度：每次进入从第 1 关开始；最高分/排行榜走 GameHud 共用体系（提交会话累计总分+到达关卡）
## 计时校准：按"起点→出口"实际 BFS 路程折算 time_limit（15 + 0.9×路程，夹取 45..240 秒）
## 开发者模式：排行榜面板 5 秒内点满 10 次 → 关闭后弹出 DEV 窗口（上一关/下一关/跳关/时间+30/传送出口）；
##   DEV 窗口常驻：切关/过关不关闭，浮于胜利弹窗与排行榜之上

const GameHud := preload("res://scripts/game_hud.gd")

# ===== 布局 =====
const HUD_H := 86.0          # 顶部栏高度

# ===== 关卡 / 玩法 =====
const BASE_CELLS := 10       # 第 1 关迷宫边长（格）
const MAX_AREA := 625       # 总格子数上限（=25×25，单维可超 25），达到后不再扩大
const SUB := 8               # 每格细分：墙厚 1 细分 + 通道 7 细分（墙细、路宽）
const PLAYER_R := 1.0        # 玩家碰撞半边长（细分单位，AABB 边长 2）
const PLAYER_SPEED := 21.0   # 移动速度（细分/秒 ≈ 2.6 格/秒）
const STUCK_T := 0.3         # 撞墙停滞判定时长（秒），到点清除移动目标
const COIN_SCORE := 10       # 每枚金币得分
const TIME_BONUS_PER_S := 4  # 通关时每剩余 1 秒的奖励分
const HINT_MS := 6000        # 提示轨迹显示时长（毫秒）
const PIG_SPEED := 12.0      # 小猪速度（细分/秒，约 0.8× 小人）
const PIG_FROM_LEVEL := 2    # 第 2 关起出现小猪 CPU 玩家
const PIG_TWO_FROM_LEVEL := 10  # 第 10 关起双小猪（一抱左墙一抱右墙）
const PIG_RACE_BONUS := 100  # 玩家先于小猪出迷宫的竞速奖励

# 配色（扁平卡通，对齐合集风格）
const COL_PANEL := Color(0.16, 0.19, 0.18, 0.88)
const COL_FLOOR := Color(0.93, 0.88, 0.76, 0.30)   # 半透明浅米色通道
const COL_WALL := Color(0.07, 0.07, 0.07)          # 全黑墙
const COL_OUTLINE := Color(0.10, 0.09, 0.09)
const COL_START := Color(0.45, 0.75, 0.95, 0.30)
const COL_START_RING := Color(0.30, 0.60, 0.85, 0.80)
const COL_EXIT := Color(0.20, 0.80, 0.35, 0.30)

var hud: RefCounted
var level := 1
var score := 0                   # 本局总分（跨关累计）
var level_start_score := 0       # 本关开始时的总分（R 重置 / 重玩回滚基准）
var level_score := 0             # 本关已得金币分
var won := false
var hint_active := false          # 提示轨迹显示中（小人→出口门的金色路径）
var hint_until_ms := 0            # 提示消失时间戳
var hint_path := PackedVector2Array()  # 提示路径（细分坐标：ppos→途经格中心→门中心）

# 迷宫
var cols := 10
var rows := 10
var vw := {}                     # 竖墙 (x,y)->true：格 (x-1,y) 与 (x,y) 之间，x∈0..cols
var hw := {}                     # 横墙 (x,y)->true：格 (x,y-1) 与 (x,y) 之间，y∈0..rows
var solid := PackedByteArray()   # 细分占据格（1=墙），尺寸 gw×gh
var gw := 0                      # 细分网格宽 = cols*SUB+1
var gh := 0
var start_cell := Vector2i.ZERO
var exit_cell := Vector2i.ZERO
var coins: Array = []            # [{cell, sub, taken, spr}]
var coin_sprites: Array = []

# 玩家（位置/碰撞均为细分单位）
var player: Sprite2D
var door_sprite: Sprite2D
var ppos := Vector2.ZERO
var ptarget := Vector2.ZERO
var has_target := false
var dragging := false
var stuck_t := 0.0
var moving := false
var facing := "down"             # down | up | side
var flip_left := false           # side 朝向镜像
var anim_t := 0.0
var coin_t := 0.0

# 小猪 CPU 玩家：沿左墙或右墙贴墙走到出口
var pigs: Array = []            # 每项 {spr, pos, cell, tcell, dir, hug_left, target, has_target, to_door, escaped, moving, facing, flip}
var pig_anim_t := 0.0

# 开发者模式（排行榜面板暗门：5 秒点满 10 次 → 关闭后弹出 DEV 窗口）
var _dev_pending := false
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_win: PanelContainer
var _dev_drag := false
var _dev_jump_sl: HSlider           # 跳关滑块/值标签（切关后同步到当前关）
var _dev_jump_lb: Label

# 计时
var time_limit := 60.0
var time_left := 60.0
var _last_time_shown := -1

# 布局度量
var _vp := Vector2(1920, 1080)
var area := Rect2()
var sub_px := 8.0
var origin := Vector2.ZERO
var _wall_rects: Array[Rect2] = []   # 墙体合并矩形（px，_layout 重建）

# 纹理
var _tex_walk := {}              # dir -> Array[Texture2D]（4 帧）
var _tex_idle := {}              # dir -> Array[Texture2D]（2 帧）
var _tex_pig_walk := {}          # 小猪行走 4 帧
var _tex_pig_idle := {}          # 小猪静止 2 帧
var _tex_coin: Array = []        # 4 帧
var _tex_door: Array = []        # 2 帧

# UI
var _top_btns: HBoxContainer
var _top_left: HBoxContainer
var _restart_btn: Button
var _volume_btn: Button
var _hint_btn: Button
var _win_panel: Control = null

# 音效
var _sfx := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer

const BGM_DB := -12.0
const SFX_DB := -6.0
const SFX_POOL := 4

@onready var _board_level: Label = $BoardLevel
@onready var _board_time: Label = $BoardTime
@onready var _board_score: Label = $BoardScore
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("maze")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_init_sfx()
	_load_textures()
	score = 0
	level = 1   # 不记录关卡进度：每次进入从第 1 关开始
	_new_level()
	_layout()


func stop() -> void:
	get_tree().paused = false
	if _bgm != null:
		_bgm.stop()
	hud.commit_score(level)   # 结束本局：会话累计总分 + 到达关卡入排行榜 top10
	print("[maze] stop, level=%d score=%d" % [level, score])


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 新关卡 =====

## 迷宫可用像素区（_layout 与扩盘方向判断共用）
func _maze_area() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	return Rect2(12.0, HUD_H, vp.x - 24.0, vp.y - HUD_H - 12.0)


## 关卡迷宫尺寸：第 1 关 10×10；每过 1 关扩 1 格，方向按屏幕剩余空间决定（avail = 可用像素区）——
## 横向加一列不缩格子则优先加宽，否则纵向加一行不缩格子则加高；
## 两边都要缩格子时选格子更大的方向继续扩（此时才真正缩小迷宫格子，尽量填满屏幕）；
## 总格子数达到 MAX_AREA（=25×25=625，单维可超 25）后不再扩大
## （细分网格 = 格数×SUB+1，判断与 _layout 的 sub_px 公式同源）
func _level_dims(lv: int, avail: Vector2) -> Vector2i:
	var w := BASE_CELLS
	var h := BASE_CELLS
	for i in lv - 1:
		if w * h >= MAX_AREA:
			break
		var cur := minf(avail.x / (w * SUB + 1), avail.y / (h * SUB + 1))   # 当前细分像素
		var cw := avail.x / ((w + 1) * SUB + 1)                             # 加一列后的细分像素
		var ch := avail.y / ((h + 1) * SUB + 1)                             # 加一行后的细分像素
		if cw >= cur:
			w += 1
		elif ch >= cur:
			h += 1
		elif cw >= ch:
			w += 1
		else:
			h += 1
	return Vector2i(w, h)


func _new_level() -> void:
	won = false
	dragging = false
	has_target = false
	stuck_t = 0.0
	moving = false
	facing = "down"
	flip_left = false
	hint_active = false
	hint_path = PackedVector2Array()
	level_start_score = score
	level_score = 0
	_last_time_shown = -1
	# 每过 1 关扩 1 格，方向按屏幕剩余空间决定（见 _level_dims）
	var dims := _level_dims(level, _maze_area().size)
	cols = dims.x
	rows = dims.y
	_gen_maze()
	_build_solid()
	_setup_timer()   # 按实际路程校准计时
	ppos = _cell_center(start_cell)   # 小人出生点必须落到起点格中心（默认原点在墙内，会被碰撞推离飞出）
	_ensure_sprites()
	_spawn_pig()
	_update_hud()
	queue_redraw()


## 递归回溯生成完美迷宫（全连通，任意两点可达 → 出口必可达）
func _gen_maze() -> void:
	vw = {}
	hw = {}
	for x in cols + 1:
		for y in rows:
			vw[Vector2i(x, y)] = true
	for x in cols:
		for y in rows + 1:
			hw[Vector2i(x, y)] = true
	var visited := {Vector2i(randi() % cols, randi() % rows): true}
	var stack: Array = [visited.keys()[0]]
	while not stack.is_empty():
		var cur: Vector2i = stack[stack.size() - 1]
		var nbs: Array = []
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cur + d
			if nb.x >= 0 and nb.y >= 0 and nb.x < cols and nb.y < rows and not visited.has(nb):
				nbs.append(nb)
		if nbs.is_empty():
			stack.pop_back()
			continue
		var nxt: Vector2i = nbs[randi() % nbs.size()]
		if cur.x == nxt.x:
			hw[Vector2i(cur.x, maxi(cur.y, nxt.y))] = false
		else:
			vw[Vector2i(maxi(cur.x, nxt.x), cur.y)] = false
		visited[nxt] = true
		stack.append(nxt)
	_braid()
	_pick_endpoints()


## 打通部分死路（braid）：关卡越低打通比例越高（环路多 → 死路少 → 更容易）
func _braid() -> void:
	var braid := clampf(0.5 - float(level - 1) * 0.08, 0.0, 0.5)
	if braid <= 0.0:
		return
	for y in rows:
		for x in cols:
			var closed: Array = []
			var open := 0
			if bool(vw[Vector2i(x, y)]):
				closed.append("W")
			else:
				open += 1
			if bool(vw[Vector2i(x + 1, y)]):
				closed.append("E")
			else:
				open += 1
			if bool(hw[Vector2i(x, y)]):
				closed.append("N")
			else:
				open += 1
			if bool(hw[Vector2i(x, y + 1)]):
				closed.append("S")
			else:
				open += 1
			if open != 3 or closed.is_empty() or randf() >= braid:
				continue   # 仅处理死路（3 墙 1 开口）
			# 随机打通一面非边界内墙（加环路，不破坏连通性）
			var inner: Array = []
			for w: String in closed:
				if w == "W" and x > 0:
					inner.append(w)
				elif w == "E" and x < cols - 1:
					inner.append(w)
				elif w == "N" and y > 0:
					inner.append(w)
				elif w == "S" and y < rows - 1:
					inner.append(w)
			if inner.is_empty():
				continue
			var pick: String = inner[randi() % inner.size()]
			match pick:
				"W":
					vw[Vector2i(x, y)] = false
				"E":
					vw[Vector2i(x + 1, y)] = false
				"N":
					hw[Vector2i(x, y)] = false
				"S":
					hw[Vector2i(x, y + 1)] = false


## 起点 = 左下角格；出口 = BFS 距起点最远的边界格（保证路径足够长）
func _pick_endpoints() -> void:
	start_cell = Vector2i(0, rows - 1)
	var dist := {start_cell: 0}
	var queue: Array = [start_cell]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cur + d
			if nb.x < 0 or nb.y < 0 or nb.x >= cols or nb.y >= rows or dist.has(nb):
				continue
			var open := false
			if d.x == 1:
				open = not bool(vw[Vector2i(cur.x + 1, cur.y)])
			elif d.x == -1:
				open = not bool(vw[Vector2i(cur.x, cur.y)])
			elif d.y == 1:
				open = not bool(hw[Vector2i(cur.x, cur.y + 1)])
			else:
				open = not bool(hw[Vector2i(cur.x, cur.y)])
			if open:
				dist[nb] = int(dist[cur]) + 1
				queue.append(nb)
	exit_cell = start_cell
	var best := -1
	for c: Vector2i in dist.keys():
		if c == start_cell:
			continue
		if c.x == 0 or c.y == 0 or c.x == cols - 1 or c.y == rows - 1:
			if int(dist[c]) > best:
				best = int(dist[c])
				exit_cell = c


## ===== 计时校准 =====
## 计时 = 15s + 0.9 × 起点→出口 的 BFS 路程，夹取 45..240 秒
func _setup_timer() -> void:
	var dist_all := _bfs_dist(start_cell)
	var tour := int(dist_all.get(exit_cell, cols + rows))
	time_limit = clampf(15.0 + 0.9 * float(tour), 45.0, 240.0)
	time_left = time_limit


## BFS 距离场
func _bfs_dist(src: Vector2i) -> Dictionary:
	var dist := {src: 0}
	var queue: Array = [src]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cur + d
			if nb.x < 0 or nb.y < 0 or nb.x >= cols or nb.y >= rows or dist.has(nb):
				continue
			if not _open_between(cur, nb):
				continue
			dist[nb] = int(dist[cur]) + 1
			queue.append(nb)
	return dist


## 细分占据格：[边框 1][通道 7][墙缝 1]...[边框 1]，墙厚 1 细分
## 通道 = 8k+1 .. 8k+7（与 _cell_center 的 8k+4.5 连续中心对齐，勿再 +1 偏移）
func _build_solid() -> void:
	gw = cols * SUB + 1
	gh = rows * SUB + 1
	solid.resize(gw * gh)
	solid.fill(1)
	for y in rows:
		for x in cols:
			for sy in range(1, SUB):
				for sx in range(1, SUB):
					solid[(y * SUB + sy) * gw + (x * SUB + sx)] = 0
	# 打通内墙缝
	for y in rows:
		for x in cols:
			if x > 0 and not bool(vw[Vector2i(x, y)]):
				for sy in range(1 + y * SUB, SUB + y * SUB):
					solid[sy * gw + x * SUB] = 0
			if y > 0 and not bool(hw[Vector2i(x, y)]):
				for sx in range(1 + x * SUB, SUB + x * SUB):
					solid[y * SUB * gw + sx] = 0
	# 出口/入口：在外边框凿开门洞（四周围墙仅在这两处断开）
	_carve_rim(exit_cell, _outer_side(exit_cell))
	_carve_rim(start_cell, _outer_side(start_cell))


## 格贴靠的外墙侧（角格取先命中的唯一一侧，保证只开一个门洞）
func _outer_side(c: Vector2i) -> String:
	if c.y == 0:
		return "top"
	if c.y == rows - 1:
		return "bottom"
	if c.x == 0:
		return "left"
	return "right"


## 在外边框上凿开该格对应的 4 细分门洞
func _carve_rim(c: Vector2i, side: String) -> void:
	var s0 := 1 + (c.x if side == "top" or side == "bottom" else c.y) * SUB
	for i in SUB:
		match side:
			"top":
				solid[s0 + i] = 0
			"bottom":
				solid[(gh - 1) * gw + s0 + i] = 0
			"left":
				solid[(s0 + i) * gw] = 0
			_:
				solid[(s0 + i) * gw + gw - 1] = 0


## 外墙门洞区域（细分坐标 → px 矩形，用于绘制入口门槛）
func _rim_rect(c: Vector2i, side: String) -> Rect2:
	var s0 := 1 + (c.x if side == "top" or side == "bottom" else c.y) * SUB
	match side:
		"top":
			return Rect2(origin + Vector2(s0, 0) * sub_px, Vector2(SUB, 1) * sub_px)
		"bottom":
			return Rect2(origin + Vector2(s0, gh - 1) * sub_px, Vector2(SUB, 1) * sub_px)
		"left":
			return Rect2(origin + Vector2(0, s0) * sub_px, Vector2(1, SUB) * sub_px)
		_:
			return Rect2(origin + Vector2(gw - 1, s0) * sub_px, Vector2(1, SUB) * sub_px)


## 出口门中心（嵌在外墙门洞线上）
func _door_pos() -> Vector2:
	var cc := (1.0 + SUB) * 0.5   # 格中心细分坐标（通道中点）
	match _outer_side(exit_cell):
		"top":
			return Vector2(cc + SUB * float(exit_cell.x), 0.5)
		"bottom":
			return Vector2(cc + SUB * float(exit_cell.x), float(gh) - 0.5)
		"left":
			return Vector2(0.5, cc + SUB * float(exit_cell.y))
		_:
			return Vector2(float(gw) - 0.5, cc + SUB * float(exit_cell.y))


## 格中心的细分坐标（通道区域中点：墙厚 1，通道区间 [1, SUB]）
func _cell_center(c: Vector2i) -> Vector2:
	var cc := (1.0 + SUB) * 0.5
	return Vector2(cc + SUB * float(c.x), cc + SUB * float(c.y))


## ===== 实体精灵 =====
func _ensure_sprites() -> void:
	if player == null:
		player = Sprite2D.new()
		player.z_index = 4   # 小人最上层，避免被门/金币遮挡
		add_child(player)
	if door_sprite != null:
		door_sprite.queue_free()
	door_sprite = Sprite2D.new()
	door_sprite.z_index = 2
	add_child(door_sprite)
	for s: Sprite2D in coin_sprites:
		s.queue_free()
	coin_sprites.clear()
	coins.clear()
	# 金币布点：非起终点格中随机取，彼此与起点保持间距
	var cand: Array = []
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if c == start_cell or c == exit_cell:
				continue
			cand.append(c)
	cand.shuffle()
	var want := clampi(cols * rows / 10, 5, 24)
	var picked: Array = []
	for c: Vector2i in cand:
		if picked.size() >= want:
			break
		if _cell_center(c).distance_to(_cell_center(start_cell)) < 7.0:
			continue
		var ok := true
		for p: Vector2i in picked:
			if _cell_center(c).distance_to(_cell_center(p)) < 7.0:
				ok = false
				break
		if ok:
			picked.append(c)
	for c: Vector2i in picked:
		var spr := Sprite2D.new()
		spr.z_index = 3
		add_child(spr)
		if not _tex_coin.is_empty():
			spr.texture = _tex_coin[0]
		coins.append({"cell": c, "sub": _cell_center(c), "taken": false, "spr": spr})
		coin_sprites.append(spr)


## ===== 小猪 CPU 玩家 =====
## 与小人同在起点格出生（第 2 关起 1 只，第 5 关起 2 只：一只抱左墙一只抱右墙）。
## 贴墙游走等价于沿"所抱墙连通面"绕行——外墙除两个门洞外完整连通，猪必经过出口格，
## 抵达出口格后直奔门洞出迷宫。出迷宫不结算、无失败判定，仅提示；
## 玩家若先于所有小猪出迷宫，竞速奖励 +100。
func _spawn_pig() -> void:
	for p: Dictionary in pigs:
		(p.spr as Sprite2D).queue_free()
	pigs.clear()
	pig_anim_t = 0.0
	if level < PIG_FROM_LEVEL:
		return
	var count := 2 if level >= PIG_TWO_FROM_LEVEL else 1
	for i in count:
		var spr := Sprite2D.new()
		spr.z_index = 3
		add_child(spr)
		var hug := i == 0   # 第 1 只抱左墙，第 2 只抱右墙（起点分头走）
		var cell := start_cell
		spr.position = origin + _cell_center(cell) * sub_px
		pigs.append({
			"spr": spr, "pos": _cell_center(cell), "cell": cell, "tcell": cell,
			"dir": _boundary_dir(cell, hug), "hug_left": hug,
			"target": _cell_center(cell), "has_target": false, "to_door": false,
			"escaped": false, "moving": false, "facing": "down", "flip": false,
		})


## 是否还有小猪未出迷宫（决定玩家竞速奖励）
func _pig_inside() -> bool:
	return pigs.any(func(p: Dictionary) -> bool: return not bool(p.escaped))


## 沿边行走方向：让所抱一侧（左/右）始终是外墙
func _boundary_dir(c: Vector2i, hug_left: bool) -> Vector2i:
	if c.y == 0:
		return Vector2i(1, 0) if hug_left else Vector2i(-1, 0)
	if c.y == rows - 1:
		return Vector2i(-1, 0) if hug_left else Vector2i(1, 0)
	if c.x == 0:
		return Vector2i(0, -1) if hug_left else Vector2i(0, 1)
	return Vector2i(0, 1) if hug_left else Vector2i(0, -1)


func _hand_left(d: Vector2i) -> Vector2i:
	return Vector2i(d.y, -d.x)


func _hand_right(d: Vector2i) -> Vector2i:
	return Vector2i(-d.y, d.x)


## 贴墙定则选下一格：抱侧 → 直行 → 另一侧 → 掉头（格中心间移动，天然不穿墙）
func _pig_next_leg(p: Dictionary) -> void:
	var d: Vector2i = p.dir
	var order: Array
	if bool(p.hug_left):
		order = [_hand_left(d), d, _hand_right(d), -d]
	else:
		order = [_hand_right(d), d, _hand_left(d), -d]
	var nd := -d
	for dd: Vector2i in order:
		var nb: Vector2i = p.cell + dd
		if nb.x >= 0 and nb.y >= 0 and nb.x < cols and nb.y < rows and _open_between(p.cell, nb):
			nd = dd
			break
	p.dir = nd
	p.tcell = p.cell + nd
	p.target = _cell_center(p.tcell)
	p.has_target = true


func _tick_pig(delta: float) -> void:
	if pigs.is_empty():
		return
	pig_anim_t += delta
	for p: Dictionary in pigs:
		if bool(p.escaped):
			continue
		var prev: Vector2 = p.pos
		if not bool(p.has_target):
			_pig_next_leg(p)
		var to: Vector2 = p.target - p.pos
		var step := PIG_SPEED * delta
		if to.length() <= step:
			p.pos = p.target
			p.has_target = false
			if bool(p.to_door):
				_pig_escape(p)
				continue
			p.cell = p.tcell
			if p.cell == exit_cell:
				p.to_door = true   # 抵达出口格：直奔外墙门洞
				p.target = _door_pos()
				p.has_target = true
			else:
				_pig_next_leg(p)
		else:
			p.pos = p.pos + to.normalized() * step
		p.moving = (p.pos - prev).length_squared() > 0.000001
		if p.moving and bool(p.has_target):
			var v: Vector2 = p.target - p.pos
			if absf(v.x) > absf(v.y):
				p.facing = "side"
				p.flip = v.x < 0.0
			else:
				p.facing = "down" if v.y > 0.0 else "up"
		(p.spr as Sprite2D).position = origin + p.pos * sub_px


func _pig_escape(p: Dictionary) -> void:
	p.escaped = true
	p.moving = false
	(p.spr as Sprite2D).visible = false
	_play_sfx("coin", 0.7, -10.0)
	_show_toast(hud.t("pig.escaped", "The pig got out!"))


## 轻提示（2.5 秒自动淡出）：小猪出迷宫等
func _show_toast(text: String) -> void:
	var lb := Label.new()
	lb.text = text
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", 30)
	lb.process_mode = Node.PROCESS_MODE_ALWAYS
	GameHud._style_label(lb, Color(1.0, 0.85, 0.25))
	add_child(lb)
	lb.z_index = 180
	lb.reset_size()
	lb.position = Vector2(_vp.x / 2.0 - lb.size.x / 2.0, _vp.y * 0.18)
	var tw := create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_interval(1.8)
	tw.tween_property(lb, "modulate:a", 0.0, 0.7)
	tw.tween_callback(lb.queue_free)


## ===== 布局 =====
func _layout() -> void:
	_vp = get_viewport().get_visible_rect().size
	# HUD 节点高于游戏元素
	_board_level.z_index = 150
	_board_time.z_index = 150
	_board_score.z_index = 150
	_exit_btn.z_index = 150
	if _top_btns != null:
		_top_btns.reset_size()
		_top_btns.position = Vector2(_vp.x - _top_btns.size.x - 16.0, 14.0)
	if _top_left != null:
		_top_left.reset_size()
		_top_left.position = Vector2(16.0, 14.0)
	# 信息板居中（避让右侧按钮组）
	var btns_w := _top_btns.size.x if _top_btns != null else 0.0
	var bw := _board_level.size.x + _board_time.size.x + _board_score.size.x + 40.0
	var cx := maxf(16.0, (_vp.x - btns_w) / 2.0 - bw / 2.0)
	_board_level.position = Vector2(cx, 14.0)
	_board_time.position = Vector2(cx + _board_level.size.x + 20.0, 14.0)
	_board_score.position = Vector2(cx + _board_level.size.x + _board_time.size.x + 40.0, 14.0)
	# 迷宫区域与细分像素
	area = _maze_area()
	sub_px = minf(area.size.x / float(gw), area.size.y / float(gh))
	origin = area.get_center() - Vector2(gw, gh) * sub_px / 2.0
	# 墙体合并矩形（px）
	_build_wall_rects()
	# 实体缩放与位置
	if player != null:
		player.scale = Vector2.ONE * (4.0 * sub_px / 64.0)
		player.position = origin + ppos * sub_px
	if door_sprite != null:
		door_sprite.scale = Vector2.ONE * (3.2 * sub_px / 120.0)
		door_sprite.position = origin + _cell_center(exit_cell) * sub_px   # 门立在出口光圈内
		# 左右两侧出口：门贴图旋转 90° 沿通道方向竖放
		door_sprite.rotation = 0.0 if (exit_cell.y == 0 or exit_cell.y == rows - 1) else PI / 2.0
	for c: Dictionary in coins:
		var spr: Sprite2D = c.spr
		spr.scale = Vector2.ONE * (3.0 * sub_px / 48.0)
		spr.position = origin + Vector2(c.sub) * sub_px
	for p: Dictionary in pigs:
		var ps: Sprite2D = p.spr
		ps.scale = Vector2.ONE * (4.0 * sub_px / 64.0)
		ps.position = origin + Vector2(p.pos) * sub_px
	queue_redraw()


## 墙体 2D 贪心合并（横向成段再纵向同宽扩展），减少 draw_rect 数量
func _build_wall_rects() -> void:
	_wall_rects.clear()
	var used := PackedByteArray()
	used.resize(gw * gh)
	for sy in gh:
		for sx in gw:
			var idx := sy * gw + sx
			if used[idx] == 1 or solid[idx] == 0:
				continue
			var x1 := sx
			while x1 + 1 < gw and solid[sy * gw + x1 + 1] == 1 and used[sy * gw + x1 + 1] == 0:
				x1 += 1
			var y1 := sy
			while y1 + 1 < gh:
				var ok := true
				for xx in range(sx, x1 + 1):
					if solid[(y1 + 1) * gw + xx] == 0 or used[(y1 + 1) * gw + xx] == 1:
						ok = false
						break
				if not ok:
					break
				y1 += 1
			for yy in range(sy, y1 + 1):
				for xx in range(sx, x1 + 1):
					used[yy * gw + xx] = 1
			var rect := Rect2(Vector2(sx, sy), Vector2(x1 - sx + 1, y1 - sy + 1))
			_wall_rects.append(Rect2(origin + rect.position * sub_px, rect.size * sub_px))


## ===== 主循环 =====
func _process(delta_raw: float) -> void:
	if won or hud == null:   # hud 为空：未经 start() 直跑场景（无头检查）
		return
	var delta := minf(delta_raw, 0.2)   # 防卡顿帧穿墙
	# 提示超时自动消失
	if hint_active and Time.get_ticks_msec() >= hint_until_ms:
		_clear_hint()
	# 计时（超时不失败，仅停发时间奖励）
	if time_left > 0.0:
		time_left = maxf(0.0, time_left - delta)
		var tsec := int(ceilf(time_left))
		if tsec != _last_time_shown:
			_last_time_shown = tsec
			_board_time.text = hud.t("hud.time", "Time %d") % tsec
			var tc := Color(1.0, 0.45, 0.40) if time_left < 10.0 else Color.WHITE
			_board_time.add_theme_color_override("font_color", tc)
	_tick_move(delta)
	_tick_pig(delta)
	_check_pickups()
	_check_win()
	_anim(delta)


## 移动：方向键优先，其次点击/拖拽目标寻走；AABB 逐轴碰撞
func _tick_move(delta: float) -> void:
	var key := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT):
		key.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		key.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP):
		key.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN):
		key.y += 1.0
	var v := Vector2.ZERO
	if key != Vector2.ZERO:
		has_target = false
		v = key.normalized() * PLAYER_SPEED
	elif has_target:
		var to := ptarget - ppos
		var step := PLAYER_SPEED * delta
		if to.length() <= step:
			v = to / maxf(delta, 0.0001)   # 一步到位
		else:
			v = to.normalized() * PLAYER_SPEED
	if v == Vector2.ZERO:
		moving = false
		return
	var prev := ppos
	_move_by(v * delta)
	# 防御夹取：任何情况下小人中心不得越出迷宫范围（杜绝碰撞推离逸出屏幕）
	ppos.x = clampf(ppos.x, 1.0 + PLAYER_R, float(gw - 1) - PLAYER_R)
	ppos.y = clampf(ppos.y, 1.0 + PLAYER_R, float(gh - 1) - PLAYER_R)
	if has_target:
		if ppos.distance_to(ptarget) < 0.05:
			has_target = false
			stuck_t = 0.0
		else:
			var gained := prev.distance_to(ptarget) - ppos.distance_to(ptarget)
			if gained < PLAYER_SPEED * delta * 0.25:
				stuck_t += delta   # 撞墙停滞（碰撞吃掉位移）
				if stuck_t > STUCK_T:
					has_target = false   # 碰到墙壁停止
			else:
				stuck_t = 0.0
	moving = (ppos - prev).length_squared() > 0.000001
	if moving:
		if absf(v.x) > absf(v.y):
			facing = "side"
			flip_left = v.x < 0.0
		else:
			facing = "down" if v.y > 0.0 else "up"
	if player != null:
		player.position = origin + ppos * sub_px


## AABB（半边长 PLAYER_R）逐轴移动 + 推离，稳定不穿墙
func _move_by(d: Vector2) -> void:
	if absf(d.x) > 0.000001:
		ppos.x += d.x
		_resolve_axis(0, d.x)
	if absf(d.y) > 0.000001:
		ppos.y += d.y
		_resolve_axis(1, d.y)


func _resolve_axis(axis: int, dir: float) -> void:
	var x0 := int(floorf(ppos.x - PLAYER_R))
	var x1 := int(floorf(ppos.x + PLAYER_R))
	var y0 := int(floorf(ppos.y - PLAYER_R))
	var y1 := int(floorf(ppos.y + PLAYER_R))
	for sy in range(y0, y1 + 1):
		for sx in range(x0, x1 + 1):
			if not _solid_at(sx, sy):
				continue
			# AABB 相交判定（贴面接触不算）
			if ppos.x + PLAYER_R <= float(sx) or ppos.x - PLAYER_R >= float(sx + 1):
				continue
			if ppos.y + PLAYER_R <= float(sy) or ppos.y - PLAYER_R >= float(sy + 1):
				continue
			if axis == 0:
				if dir > 0.0:
					ppos.x = minf(ppos.x, float(sx) - PLAYER_R)
				elif dir < 0.0:
					ppos.x = maxf(ppos.x, float(sx + 1) + PLAYER_R)
			else:
				if dir > 0.0:
					ppos.y = minf(ppos.y, float(sy) - PLAYER_R)
				elif dir < 0.0:
					ppos.y = maxf(ppos.y, float(sy + 1) + PLAYER_R)


func _solid_at(sx: int, sy: int) -> bool:
	if sx < 0 or sy < 0 or sx >= gw or sy >= gh:
		return true
	return solid[sy * gw + sx] == 1


func _check_pickups() -> void:
	for c: Dictionary in coins:
		if bool(c.taken):
			continue
		if ppos.distance_to(Vector2(c.sub)) < 1.7:
			c.taken = true
			(c.spr as Sprite2D).visible = false
			score += COIN_SCORE
			level_score += COIN_SCORE
			_play_sfx("coin")
			_spawn_float_text(Vector2(c.sub), "+%d" % COIN_SCORE, Color(1.0, 0.85, 0.25))
			_update_hud()


## 拾取飘字（+10）：原地生成、上飘淡出
func _spawn_float_text(sub: Vector2, text: String, col: Color) -> void:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", int(maxf(16.0, sub_px * 2.6)))
	GameHud._style_label(lb, col)
	add_child(lb)
	lb.z_index = 120
	lb.reset_size()
	lb.position = origin + sub * sub_px - Vector2(lb.size.x / 2.0, lb.size.y + sub_px * 1.5)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - sub_px * 5.0, 0.9)
	tw.tween_property(lb, "modulate:a", 0.0, 0.65).set_delay(0.25)
	tw.chain().tween_callback(lb.queue_free)


## ===== 提示 =====
## 点击 ? 显示从小人当前位置到出口门的 BFS 路径（金色圆点轨迹），6 秒后自动消失；可随时重按刷新
func _on_hint() -> void:
	if won:
		return
	hint_path = _path_to_exit()
	if hint_path.is_empty():
		return
	hint_active = true
	hint_until_ms = Time.get_ticks_msec() + HINT_MS
	queue_redraw()


func _clear_hint() -> void:
	hint_active = false
	hint_path = PackedVector2Array()
	queue_redraw()


func _open_between(a: Vector2i, b: Vector2i) -> bool:
	if a.x == b.x:
		return not bool(hw[Vector2i(a.x, maxi(a.y, b.y))])
	return not bool(vw[Vector2i(maxi(a.x, b.x), a.y)])


## 小人所在格 → 出口格 BFS 最短路（细分坐标折线：前端接小人，尾端接出口光圈中心）
func _path_to_exit() -> PackedVector2Array:
	var sc := Vector2i(
		clampi(int(floorf((ppos.x - 1.0) / float(SUB))), 0, cols - 1),
		clampi(int(floorf((ppos.y - 1.0) / float(SUB))), 0, rows - 1))
	var cells := _bfs_cells_to(sc, exit_cell)
	if cells.is_empty():
		return PackedVector2Array()
	cells.reverse()
	cells.insert(0, ppos)
	cells.append(_cell_center(exit_cell))
	return cells


## BFS 格路径（格中心序列，target→sc 顺序；不可达返回空）
func _bfs_cells_to(sc: Vector2i, target: Vector2i) -> Array:
	var prev := {sc: Vector2i(-1, -1)}
	var queue: Array = [sc]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if cur == target:
			break
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cur + d
			if nb.x < 0 or nb.y < 0 or nb.x >= cols or nb.y >= rows or prev.has(nb):
				continue
			if not _open_between(cur, nb):
				continue
			prev[nb] = cur
			queue.append(nb)
	if not prev.has(target):
		return []
	var cells: Array = []
	var c := target
	while c.x >= 0:
		cells.append(_cell_center(c))
		c = prev[c]
	return cells


func _check_win() -> void:
	if ppos.distance_to(_cell_center(exit_cell)) < 2.6:   # 进入出口格光圈即通关
		_win()


func _anim(delta: float) -> void:
	anim_t += delta
	coin_t += delta
	if player != null:
		var tex: Texture2D = null
		if moving:
			var arr: Array = _tex_walk.get(facing, [])
			if not arr.is_empty():
				tex = arr[int(anim_t * 9.0) % arr.size()]
		else:
			var arr: Array = _tex_idle.get(facing, [])
			if not arr.is_empty():
				tex = arr[int(anim_t * 2.0) % arr.size()]
		if tex != null:
			player.texture = tex
		player.flip_h = facing == "side" and flip_left
	if not _tex_coin.is_empty():
		var cf: int = int(coin_t * 6.0) % _tex_coin.size()
		var i := 0
		for c: Dictionary in coins:
			if bool(c.taken):
				continue
			var spr: Sprite2D = c.spr
			spr.texture = _tex_coin[cf]
			spr.position = origin + Vector2(c.sub) * sub_px \
					+ Vector2(0.0, sin(coin_t * 3.0 + float(i) * 1.3) * sub_px * 0.18)
			i += 1
	if door_sprite != null and _tex_door.size() == 2:
		door_sprite.texture = _tex_door[int(coin_t * 2.2) % 2]
		door_sprite.modulate.a = 0.85 + 0.15 * sin(coin_t * 4.0)
	# 小猪动画（行走 4 帧 / 静止 2 帧）
	for p: Dictionary in pigs:
		if bool(p.escaped):
			continue
		var spr: Sprite2D = p.spr
		var ptex: Texture2D = null
		if bool(p.moving):
			var parr: Array = _tex_pig_walk.get(p.facing, [])
			if not parr.is_empty():
				ptex = parr[int(pig_anim_t * 7.0) % parr.size()]
		else:
			var parr: Array = _tex_pig_idle.get(p.facing, [])
			if not parr.is_empty():
				ptex = parr[int(pig_anim_t * 2.0) % parr.size()]
		if ptex != null:
			spr.texture = ptex
		spr.flip_h = p.facing == "side" and bool(p.flip)


## ===== 输入 =====
func _unhandled_input(event: InputEvent) -> void:
	if won:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				dragging = true
				_set_target(mb.position)
			else:
				dragging = false   # 松手后继续走向最后目标点
	elif event is InputEventMouseMotion and dragging:
		_set_target((event as InputEventMouseMotion).position)


## 点击/拖拽：目标点换算到细分坐标并夹取到迷宫内
func _set_target(mpos: Vector2) -> void:
	var sub := (mpos - origin) / sub_px
	sub.x = clampf(sub.x, 1.0 + PLAYER_R, float(gw - 1) - PLAYER_R)
	sub.y = clampf(sub.y, 1.0 + PLAYER_R, float(gh - 1) - PLAYER_R)
	ptarget = sub
	has_target = true
	stuck_t = 0.0


## ===== 胜利 =====
func _win() -> void:
	won = true
	dragging = false
	has_target = false
	moving = false
	_play_sfx("win")
	var tb := int(time_left) * TIME_BONUS_PER_S
	var pig_bonus := PIG_RACE_BONUS if (not pigs.is_empty() and _pig_inside()) else 0
	score += tb + pig_bonus
	hud.submit_score(score, level)   # 最高分即时刷新（会话累计总分 + 到达关卡）
	_update_hud()
	_show_win_panel(tb, pig_bonus)


func _show_win_panel(tb: int, pig_bonus: int) -> void:
	if _win_panel != null:
		_win_panel.queue_free()
	var m := minf(_vp.x, _vp.y)
	var panel := PanelContainer.new()
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.96)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.04)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.014))
	panel.add_child(vb)
	var title := Label.new()
	title.text = hud.t("popup.win_title", "Maze Cleared!")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(m * 0.055))
	GameHud._style_label(title, Color(1.0, 0.85, 0.25))
	vb.add_child(title)
	var msg := Label.new()
	msg.text = hud.t("popup.win_msg", "Level %d cleared. Keep going!") % level
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", int(m * 0.030))
	GameHud._style_label(msg, Color.WHITE)
	vb.add_child(msg)
	var lines: Array = [
		[hud.t("popup.coins", "Coins +%d") % level_score, Color.WHITE],
		[hud.t("popup.time_bonus", "Time bonus +%d") % tb, Color.WHITE],
	]
	if pig_bonus > 0:   # 玩家先于小猪出迷宫
		lines.append([hud.t("popup.pig_bonus", "Beat the pig +%d") % pig_bonus, Color(1.0, 0.6, 0.75)])
	lines.append_array([
		[hud.t("popup.total", "Total score %d") % score, Color(1.0, 0.85, 0.25)],
		[hud.t("popup.best", "Best %d") % hud.max_score, Color(0.8, 0.8, 0.8)],
	])
	for line: Array in lines:
		var lb := Label.new()
		lb.text = String(line[0])
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.add_theme_font_size_override("font_size", int(m * 0.026))
		GameHud._style_label(lb, line[1])
		vb.add_child(lb)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(row)
	var next_btn := GameHud.make_button(hud.t("popup.next", "Next Level"))
	next_btn.pressed.connect(_on_next)
	row.add_child(next_btn)
	var replay_btn := GameHud.make_button(hud.t("popup.replay", "Replay"))
	replay_btn.pressed.connect(_on_replay)
	row.add_child(replay_btn)
	add_child(panel)
	panel.z_index = 200
	panel.reset_size()
	panel.position = Vector2(_vp.x / 2.0 - panel.size.x / 2.0, _vp.y / 2.0 - panel.size.y / 2.0)
	for b: Button in row.get_children():
		b.add_theme_font_size_override("font_size", int(m * 0.034))
	get_tree().paused = true
	_win_panel = panel


func _close_win() -> void:
	get_tree().paused = false
	if _win_panel != null:
		_win_panel.queue_free()
		_win_panel = null


func _on_next() -> void:
	_close_win()
	level += 1
	_new_level()
	_layout()


func _on_replay() -> void:
	_close_win()
	_reset_state()
	_layout()


## ===== R 重置：不重建迷宫，仅重置状态 =====
## 小人回起点、金币复原、计时重置、分数回滚到本关开始（扣除本关金币/时间奖励）
func _reset_state() -> void:
	won = false
	dragging = false
	has_target = false
	stuck_t = 0.0
	moving = false
	facing = "down"
	flip_left = false
	hint_active = false
	hint_path = PackedVector2Array()
	ppos = _cell_center(start_cell)
	time_left = time_limit
	_last_time_shown = -1
	for c: Dictionary in coins:
		c.taken = false
		(c.spr as Sprite2D).visible = true
	score = level_start_score
	level_score = 0
	_spawn_pig()   # 小猪回出生角落（不重建迷宫）
	_update_hud()
	if player != null:
		player.position = origin + ppos * sub_px
	queue_redraw()


func _on_restart() -> void:
	if won:
		return
	_play_sfx("reset")
	_reset_state()


## ===== 顶部按钮 =====
func _setup_buttons() -> void:
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_exit_btn.icon = hud.ui_icon("close.png")

	# 最小化钮（关闭钮左侧）：点击最小化窗口（桌面 Win/Linux）
	var min_btn := GameHud.make_button("")
	min_btn.icon = hud.ui_icon("minimize.png")
	min_btn.custom_minimum_size = Vector2(44.0, 56.0)
	min_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	min_btn.add_theme_constant_override("icon_max_width", 32)
	min_btn.pressed.connect(func() -> void: get_window().mode = Window.MODE_MINIMIZED)
	_top_btns = HBoxContainer.new()
	_top_btns.name = "TopButtons"
	_top_btns.add_theme_constant_override("separation", -8)
	_top_btns.z_index = 150
	add_child(_top_btns)
	_top_btns.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	# 左上角按钮组：提示钮（2026-10-10 用户定，避开右上 ✕ 列）
	_top_left = HBoxContainer.new()
	_top_left.name = "TopLeft"
	_top_left.add_theme_constant_override("separation", -8)
	_top_left.z_index = 150
	add_child(_top_left)
	_top_left.process_mode = Node.PROCESS_MODE_ALWAYS
	var lb_btn := GameHud.make_button("")
	lb_btn.icon = hud.lb_icon()
	lb_btn.pressed.connect(_on_leaderboard)
	_hint_btn = GameHud.make_button("?")
	_hint_btn.pressed.connect(_on_hint)
	var bgm_btn := GameHud.make_button("")
	bgm_btn.icon = hud.bgm_icon()
	_volume_btn = GameHud.make_button("")
	_volume_btn.icon = hud.volume_icon()
	_restart_btn = GameHud.make_button("")
	_restart_btn.icon = hud.restart_icon()
	# 退出按钮从场景挂载点移入按钮组
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	_top_left.add_child(_hint_btn)
	_hint_btn.custom_minimum_size = Vector2(44.0, 56.0)
	_hint_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	_hint_btn.add_theme_constant_override("icon_max_width", 32)
	for b: Control in [lb_btn, bgm_btn, _volume_btn, _restart_btn, min_btn, _exit_btn]:
		_top_btns.add_child(b)
		b.custom_minimum_size = Vector2(44.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.add_theme_constant_override("icon_max_width", 32)
	_restart_btn.pressed.connect(_on_restart)
	bgm_btn.pressed.connect(_on_bgm.bind(bgm_btn))
	_volume_btn.pressed.connect(_on_volume)
	_hint_btn.add_theme_font_size_override("font_size", 22)


func _on_leaderboard() -> void:
	hud.show_leaderboard(self, hud.t("lb.title", "Leaderboard"), score, 0)
	_arm_dev_clicks()


func _on_bgm(btn: Button) -> void:
	var on: bool = hud.cycle_bgm()
	btn.icon = hud.bgm_icon()
	if on:
		_bgm.play()
	else:
		_bgm.stop()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


func _update_hud() -> void:
	_board_level.text = hud.t("hud.level", "Level %d") % level
	_board_time.text = hud.t("hud.time", "Time %d") % int(ceilf(time_left))
	_board_time.add_theme_color_override("font_color", Color.WHITE)
	_board_score.text = hud.t("hud.score", "Score %d") % score


## ===== 绘制 =====
func _draw() -> void:
	# 区域底板
	draw_rect(area, COL_PANEL)
	if gw <= 0:
		return
	# 通道地面（半透明浅米色，含墙下区域，墙后绘制覆盖）
	var inner := Rect2(origin + Vector2(1, 1) * sub_px, Vector2(gw - 2, gh - 2) * sub_px)
	draw_rect(inner, COL_FLOOR)
	# 起点标记
	var sp := origin + _cell_center(start_cell) * sub_px
	draw_circle(sp, sub_px * SUB * 0.3, COL_START)
	draw_arc(sp, sub_px * SUB * 0.3, 0.0, TAU, 32, COL_START_RING, 2.0)
	# 出口光圈（出口格中心，整圈位于迷宫内，触摸屏易点中）
	var ep := origin + _cell_center(exit_cell) * sub_px
	draw_circle(ep, sub_px * SUB * 0.38, COL_EXIT)
	# 墙体：先描边后填充（相邻矩形描边自然融合）
	var ol := maxf(2.0, sub_px * 0.35)
	for r: Rect2 in _wall_rects:
		draw_rect(r.grow(ol), COL_OUTLINE)
	for r: Rect2 in _wall_rects:
		draw_rect(r, COL_WALL)
	# 入口门槛（起点外墙缺口处的暖色门垫）
	var sr := _rim_rect(start_cell, _outer_side(start_cell))
	draw_rect(sr.grow(ol * 0.75), COL_OUTLINE)
	draw_rect(sr, Color(0.85, 0.72, 0.50, 0.95))
	# 提示路径（金色轨迹：淡线 + 圆点，6 秒后自动消失）
	if hint_active and hint_path.size() >= 2:
		var ppx := PackedVector2Array()
		for p: Vector2 in hint_path:
			ppx.append(origin + p * sub_px)
		draw_polyline(ppx, Color(1.0, 0.85, 0.25, 0.35), sub_px * 0.7, true)
		var seg := sub_px * 2.2
		for i in range(ppx.size() - 1):
			var a := ppx[i]
			var b := ppx[i + 1]
			var d := a.distance_to(b)
			var t := 0.0
			while t <= d:
				draw_circle(a.lerp(b, t / maxf(d, 0.001)), sub_px * 0.42, Color(1.0, 0.85, 0.25, 0.85))
				t += seg


## ===== 贴图加载（pck 内 png 字节解码；双路径兼容编辑器直跑）=====
func _load_textures() -> void:
	for dir: String in ["down", "up", "side"]:
		var walk: Array = []
		for f in 4:
			walk.append(_load_png("res://assets/player/walk_%s_%d.png" % [dir, f]))
		_tex_walk[dir] = walk
		var idle: Array = []
		for f in 2:
			idle.append(_load_png("res://assets/player/idle_%s_%d.png" % [dir, f]))
		_tex_idle[dir] = idle
		# 小猪 CPU 玩家贴图（同规格像素画）
		var pwalk: Array = []
		for f in 4:
			pwalk.append(_load_png("res://assets/player/pig_walk_%s_%d.png" % [dir, f]))
		_tex_pig_walk[dir] = pwalk
		var pidle: Array = []
		for f in 2:
			pidle.append(_load_png("res://assets/player/pig_idle_%s_%d.png" % [dir, f]))
		_tex_pig_idle[dir] = pidle
	for f in 4:
		_tex_coin.append(_load_png("res://assets/coin_%d.png" % f))
	for f in 2:
		_tex_door.append(_load_png("res://assets/exit_door_%d.png" % f))


func _load_png(path: String) -> Texture2D:
	for p: String in ["res://games/maze/" + path.trim_prefix("res://games/maze/"), path]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


## ===== 音效 =====
func _init_sfx() -> void:
	_sfx = {
		"coin": _load_wav("coin.wav"),       # 拾金币：双音"叮"
		"reset": _load_wav("reset.wav"),     # 重置：低沉"噗"
		"win": _load_stream("cheer.mp3"),    # 通关：欢呼
	}
	for i in SFX_POOL:
		var ap := AudioStreamPlayer.new()
		ap.volume_db = SFX_DB
		ap.process_mode = Node.PROCESS_MODE_ALWAYS   # 过关弹窗暂停时音效正常播放
		add_child(ap)
		_sfx_players.append(ap)
	_bgm = AudioStreamPlayer.new()
	var bs: AudioStream = _load_stream("bgm.mp3")
	if bs is AudioStreamMP3:
		bs.loop = true
	_bgm.stream = bs
	_bgm.volume_db = BGM_DB
	_bgm.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_bgm)
	if hud.bgm_on:
		_bgm.play()


func _load_wav(fname: String) -> AudioStreamWAV:
	var f := FileAccess.open("res://assets/sfx/" + fname, FileAccess.READ)
	if f == null:
		return null
	return AudioStreamWAV.load_from_buffer(f.get_buffer(f.get_length()))


func _load_stream(fname: String) -> AudioStream:
	var f := FileAccess.open("res://assets/sfx/" + fname, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	var mp := AudioStreamMP3.new()
	mp.data = buf
	return mp


func _play_sfx(sname: String, pitch: float = 1.0, db: float = SFX_DB) -> void:
	if not _sfx.has(sname) or _sfx[sname] == null:
		return
	for ap: AudioStreamPlayer in _sfx_players:
		if not ap.playing:
			ap.stream = _sfx[sname]
			ap.pitch_scale = pitch
			ap.volume_db = db
			ap.play()
			return


# ===== 开发者模式 =====
## 暗门：排行榜面板弹出后，5 秒内在面板上点击满 10 次 → 关闭排行榜后弹出调试窗口。
## 调试窗口可拖动、不暂停游戏；支持跳关 / 加时 / 传送出口。

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
		[hud.t("dev.prev", "Prev Level"), _dev_prev],
		[hud.t("dev.next", "Next Level"), _dev_next],
		[hud.t("dev.time", "Time +30"), _dev_add_time],
		[hud.t("dev.tp", "To Exit"), _dev_teleport],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.pressed.connect(a[1])
		grid.add_child(b)
	# 跳关：滑块选目标关卡 + 执行按钮
	var jr := HBoxContainer.new()
	jr.add_theme_constant_override("separation", 8)
	vb.add_child(jr)
	var jlb := _dev_label(hud.t("dev.jump_lv", "Jump to"))
	jr.add_child(jlb)
	var sl := HSlider.new()
	sl.min_value = 1.0
	sl.max_value = 30.0
	sl.step = 1.0
	sl.value = level
	sl.custom_minimum_size = Vector2(150.0, 20.0)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	jr.add_child(sl)
	var jv := _dev_label(str(level))
	jv.custom_minimum_size = Vector2(26.0, 0)
	jv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	jr.add_child(jv)
	sl.value_changed.connect(func(v: float) -> void: jv.text = str(int(v)))
	var go := GameHud.make_button(hud.t("dev.jump", "Jump"))
	go.add_theme_font_size_override("font_size", 14)
	go.custom_minimum_size = Vector2(70.0, 28.0)
	go.pressed.connect(func() -> void: _dev_goto(int(sl.value)))
	jr.add_child(go)
	_dev_jump_sl = sl
	_dev_jump_lb = jv
	add_child(_dev_win)
	_dev_win.z_index = 250   # 浮于胜利弹窗(200)/排行榜之上：过关不遮挡、不关闭
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
	_dev_jump_sl = null
	_dev_jump_lb = null


## 开发者按钮动作：切关保留 DEV 窗口（不随过关/切关关闭），跳关滑块同步当前关
func _dev_goto(lv: int) -> void:
	_close_win()   # 胜利弹窗开着时也能直接切关
	level = clampi(lv, 1, 99)
	_new_level()
	_layout()
	if _dev_jump_sl != null and is_instance_valid(_dev_jump_sl):
		_dev_jump_sl.value = float(level)
	if _dev_jump_lb != null and is_instance_valid(_dev_jump_lb):
		_dev_jump_lb.text = str(level)


func _dev_prev() -> void:
	_dev_goto(level - 1)


func _dev_next() -> void:
	_dev_goto(level + 1)


func _dev_add_time() -> void:
	time_left = minf(time_limit, time_left + 30.0)
	_last_time_shown = -1   # 强制 HUD 立即刷新


func _dev_teleport() -> void:
	ppos = _cell_center(exit_cell)   # 传送到出口光圈 → 下一帧 _check_win 触发通关
	has_target = false
	if player != null:
		player.position = origin + ppos * sub_px
