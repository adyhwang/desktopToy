extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 水果分区（Fruit Count，哪个水果多）：棋盘随机布满水果并被切成 N 个连通区域，
## 找出水果最多（格子数最多、唯一最大）的区域，单击该区域得分进入下一关；
## 选错扣分并可继续尝试。（棋盘每 2 关扩 1 格、区域数 3 起隔关 +1 封顶 7 个，
## 扩格方向按屏幕剩余空间逐格判断，总格子数达 400 封顶且单维可超 20，尽量填满屏幕）
## 最高分复用合集存档（GameHud submit_score/commit_score，排行榜分值 = 得分）

const GameHud := preload("res://scripts/game_hud.gd")

const FRUITS := ["apple", "banana", "carrot", "grape", "orange", "peach", "pear", "Pineapple", "strawberry", "watermelon"]
const BOARD_MIN := 6        # 第 1 关 6×6
const BOARD_CELLS := 400    # 总格子数上限（=20×20，单维可超 20），达到后不再扩大
const REGIONS_MIN := 3      # 第 1 关切 3 个区域
const REGIONS_MAX := 10      # 区域数上限
const KINDS_BASE := 3       # 种类数 = 3 + 关卡（夹 4..10）：第 1 关 4 种，第 7 关起满 10 种
const TOP_H := 86.0         # 顶栏高度（棋盘从其下开始布局）
const MARGIN := 14.0        # 棋盘区边距
const HIGHLIGHT_T := 0.5    # 点击后区域高亮边框时长（s），到时判定
const VANISH_TICK := 0.2    # 通过后每 0.2s 所有区域各移除 1 个水果
const VANISH_DUR := 0.3    # 单个水果消失动画时长（s）
const BREATH_HOLD := 2.0    # 只剩正确区域水果后的呼吸停留时长（s），到时切下一关
const SCORE_RIGHT := 2      # 选对 +2
const SCORE_WRONG := -1     # 选错 -1
const POPUP_TIME := 0.8     # 飘字动画时长（s）
const SFX_POOL := 4
const BGM_DB := -6.0
const SFX_DB := -4.0

# 配色（扁平卡通，纯色 + 深描边，同围住水果棋盘风格）
const COL_PANEL := Color(0.984, 0.918, 0.749)        # 棋盘底：米黄
const COL_PANEL_BORDER := Color(0.30, 0.23, 0.18)    # 深棕描边
const COL_GRID := Color(0.858, 0.769, 0.576)         # 细网格线
const COL_CHECKER := Color(1, 1, 1, 0.16)            # 棋盘格淡色交替
const COL_ZONE_LINE := Color(0.16, 0.55, 0.28)       # 区域分隔线（绿色，与棋盘米黄底对比清晰）
const COL_HL := Color(1.0, 0.85, 0.25)               # 点击高亮边框：金色
const COL_HL2 := Color(1, 1, 1, 0.9)                 # 高亮外圈白线
const COL_ERR_MASK := Color(0.92, 0.22, 0.16, 0.30)  # 选错区域红色半透明遮罩
const COL_OK_MASK := Color(0.20, 0.80, 0.35, 0.30)   # 选对区域绿色半透明遮罩
const COL_POPUP_OK := Color(0.20, 0.85, 0.30)
const COL_POPUP_ERR := Color(0.95, 0.30, 0.22)

enum State { IDLE, HIGHLIGHT, WIN_ANIM }

var hud: RefCounted
var level := 1
var score := 0
var cols := BOARD_MIN
var rows := BOARD_MIN
var kinds := 4
var zone_count := REGIONS_MIN
var zones := PackedInt32Array()           # rows*cols 个区域 id（0..zone_count-1），行优先
var target_zone := -1                     # 水果最多的区域（生成时保证唯一最大）
var grid: Array[int] = []                 # rows*cols 个水果索引（-1 = 已消失），行优先
var _texs := {}                           # 水果名 → Texture2D
var _cell := 60.0
var _origin := Vector2.ZERO               # 棋盘左上角
var _state := State.IDLE
var _sel_zone := -1                       # 当前点击的区域（高亮边框）
var _hl_t := -1.0                         # >0：高亮边框倒计时
var _ok_zone := -1                        # 选对区域（绿色遮罩，进入下一关前保留）
var _err_zones := {}                      # 选错区域 id -> true（红色遮罩，保留到本关结束）
var _vanish_anims: Array = []             # 消失中水果 {cell, fruit, t}（向上位移渐透明）
var _vanish_t := 0.0                      # 消散 tick 计时器
var _clear_done := false                  # 错误区域已全部清空（停止消散，正确区域开始呼吸）
var _win_hold := -1.0                     # >0：呼吸停留倒计时
var _anim_t := 0.0                        # 动画相位累计（呼吸缩放）
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
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("fruit_count")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()   # 先建按钮再布局（_layout 会定位，null 会报错中断）
	_layout()
	_init_sfx()
	_gen_level()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，得分入排行榜
	print("[fruit_count] stop, level=%d score=%d" % [level, score])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()
		return
	if _state != State.IDLE:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var c := int(floor((event.position.x - _origin.x) / _cell))
		var r := int(floor((event.position.y - _origin.y) / _cell))
		if c < 0 or r < 0 or c >= cols or r >= rows:
			return
		_sel_zone = zones[r * cols + c]
		_hl_t = HIGHLIGHT_T
		_state = State.HIGHLIGHT
		queue_redraw()


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 关卡 =====

## 棋盘可用像素区（与 _layout 同源，无预览面板占位）
func _board_avail() -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(maxf(vp.x - MARGIN * 2.0, 60.0), maxf(vp.y - TOP_H - MARGIN * 2.0, 60.0))


## 棋盘尺寸：从 6×6 起扩 steps 次（每 2 关扩 1 格，区域满 7 后每关扩 1 格），方向按屏幕剩余空间决定（avail = 可用像素区）——
## 横向加一列不缩格子则优先加宽，否则纵向加一行不缩格子则加高；
## 两边都要缩格子时选格子更大的方向继续扩（此时才真正缩小棋盘格子，尽量填满屏幕）；
## 总格子数达到 BOARD_CELLS（=20×20=400，单维可超 20）后不再扩大
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


## 生成关卡：区域数与棋盘尺寸按关推进 → 切区域（保证唯一最大）→ 随机铺水果
## 关卡节奏（二选一交替）：偶数关 +1 区域（封顶 7），奇数关 +1 格；区域满 7 后每关 +1 格
func _gen_level() -> void:
	var grow := (level - 1) - mini(REGIONS_MAX - REGIONS_MIN, level / 2)
	var dims := _board_dims(grow, _board_avail())
	cols = dims.x
	rows = dims.y
	zone_count = REGIONS_MIN + mini(REGIONS_MAX - REGIONS_MIN, level / 2)
	kinds = clampi(KINDS_BASE + level, 4, FRUITS.size())
	zones = _gen_zones(cols, rows, zone_count)
	var sizes := _zone_sizes(zones, zone_count)
	target_zone = sizes.find(sizes.max())   # _gen_zones 保证唯一最大
	grid.resize(cols * rows)
	for i in grid.size():
		grid[i] = randi() % kinds
	_state = State.IDLE
	_sel_zone = -1
	_hl_t = -1.0
	_ok_zone = -1
	_err_zones.clear()
	_vanish_anims.clear()
	_clear_done = false
	_win_hold = -1.0
	_anim_t = 0.0
	_refresh_labels()
	_layout()   # rows/cols 变了必须重算 cell/origin，棋盘按屏幕宽高缩放


## ===== 区域切分 =====

## 把 w×h 切成 n 个连通区域，保证"水果最多"的区域唯一（领先差距随关卡收紧）：
## 前期最大区明显领先便于上手，后期最大区领先第二大限制在 1..5 格（肉眼难分辨，需数格子）——
## gap_max 随关卡从 9 递减到 5，gap_min 随关卡从 7 收紧到 1；目标区配额系数同步贴近均分。
## 带配额的随机生长（目标区域配额 ≈ 系数×均分，其余区域不超过其配额）→ 校验不满足则重掷；
## 重掷耗尽后用"叶子格转移"兜底强制唯一
func _gen_zones(w: int, h: int, n: int) -> PackedInt32Array:
	var total := w * h
	var gap_max := clampi(5 + (10 - level) / 2, 5, 10)                        # 领先上限
	var gap_min := clampi(mini(gap_max - 2, 11 - level), 1, gap_max - 1)     # 领先下限
	var q_factor := clampf(1.5 - (level - 1) * 0.05, 1.05, 1.5)              # 目标区配额系数
	var q_target := clampi(int(float(total) * q_factor / n), n + 1, total - 2 * (n - 1))
	for attempt in 60:
		var zones_try := _grow_zones(w, h, n, q_target)
		var sizes := _zone_sizes(zones_try, n)
		var order: Array = []
		for z in n:
			order.append(z)
		order.sort_custom(func(a: int, b: int) -> bool: return sizes[a] > sizes[b])
		var lead: int = sizes[order[0]] - sizes[order[1]]
		if (lead >= gap_min and lead <= gap_max) or (attempt >= 40 and lead >= 1):
			return zones_try   # lead >= 1 即唯一最大
	# 兜底：转移叶子格强制唯一最大（玩法正确性优先于领先幅度）
	var zones_out := _grow_zones(w, h, n, q_target)
	_make_unique(zones_out, w, h, n)
	return zones_out


## 随机多源生长：n 个种子随机撒点，带配额扩展（每区满配额后冻结，
## 全冻结时解冻继续，保证覆盖全盘且每区连通）
func _grow_zones(w: int, h: int, n: int, q_target: int) -> PackedInt32Array:
	var total := w * h
	var zones := PackedInt32Array()
	zones.resize(total)
	zones.fill(-1)
	# 配额：其余区域在均分剩余的基础上随机扰动，且不超过 q_target-2（保证目标区域明显最大）
	var rest := total - q_target
	var base := maxi(rest / (n - 1), 2)
	var quotas: Array[int] = []
	quotas.resize(n)
	for z in n:
		if z == n - 1:
			quotas[z] = q_target
		else:
			var v := base + randi() % maxi(1, base / 2) - base / 4
			quotas[z] = clampi(v, 2, q_target - 2)
	# 种子随机撒点（不重复）
	var order: Array = []
	for i in total:
		order.append(i)
	order.shuffle()
	var counts: Array[int] = []
	counts.resize(n)
	counts.fill(0)
	var frontiers: Array = []   # 每区相邻未分配格集合（cell -> true）
	for z in n:
		zones[order[z]] = z
		counts[z] = 1
	for z in n:
		frontiers.append({})
		_add_frontier(zones, frontiers[z], w, h, order[z])   # 全部种子先落盘再建边界，防止把其他种子误当未分配格
	var assigned := n
	var unfreeze := false   # 未满额区域被满额区地理封锁时置 true：解除全部配额继续填满
	while assigned < total:
		var free_exists := false
		if not unfreeze:
			for z in n:
				if counts[z] < quotas[z]:
					free_exists = true
					break
		var cands: Array = []
		for z in n:
			if not unfreeze and free_exists and counts[z] >= quotas[z]:
				continue   # 满额冻结
			for c: int in frontiers[z]:
				cands.append(Vector2i(z, c))
		if cands.is_empty():
			if not unfreeze and free_exists:
				unfreeze = true   # 未满区无路可走：解冻所有区域继续填充
				continue
			break   # 无候选可扩
		var pick: Vector2i = cands[randi() % cands.size()]
		var z2 := pick.x
		var c2 := pick.y
		zones[c2] = z2
		counts[z2] += 1
		assigned += 1
		for z in n:
			frontiers[z].erase(c2)
		_add_frontier(zones, frontiers[z2], w, h, c2)
	# 兜底：被地理封锁的空格分给相邻任一区域（保持连通），多遍扫描直到无空格（内部空格需等边界格先分配）
	if assigned < total:
		var changed := true
		while changed:
			changed = false
			for i in total:
				if zones[i] >= 0:
					continue
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var p: Vector2i = Vector2i(i % w, i / w) + d
					if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h and zones[p.y * w + p.x] >= 0:
						zones[i] = zones[p.y * w + p.x]
						assigned += 1
						changed = true
						break
	return zones


## 把 cell 的未分配邻居加入该区的边界候选集
func _add_frontier(zones: PackedInt32Array, frontier: Dictionary, w: int, h: int, cell: int) -> void:
	var cx := cell % w
	var cy := cell / w
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var p: Vector2i = Vector2i(cx, cy) + d
		if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h:
			var idx := p.y * w + p.x
			if zones[idx] < 0:
				frontier[idx] = true


## 统计各区域格子数
func _zone_sizes(zones: PackedInt32Array, n: int) -> Array[int]:
	var sizes: Array[int] = []
	sizes.resize(n)
	sizes.fill(0)
	for v in zones:
		if v >= 0:
			sizes[v] += 1
	return sizes


## 叶子格转移：反复把并列最大区域的一个边界叶子格（移除后原区域仍连通）转给相邻区域，
## 直到最大区域唯一（保证玩法答案唯一）
func _make_unique(zones: PackedInt32Array, w: int, h: int, n: int) -> void:
	for guard in 300:
		var sizes := _zone_sizes(zones, n)
		var mx: int = sizes.max()
		var tops: Array = []
		for z in n:
			if sizes[z] == mx:
				tops.append(z)
		if tops.size() == 1:
			return
		var a: int = tops[randi() % tops.size()]
		if sizes[a] <= 1:
			continue
		var cells: Array = []
		for i in zones.size():
			if zones[i] == a:
				cells.append(i)
		cells.shuffle()
		for c: int in cells:
			var nb := {}
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var p: Vector2i = Vector2i(c % w, c / w) + d
				if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h:
					var zz: int = zones[p.y * w + p.x]
					if zz != a:
						nb[zz] = true
			if nb.is_empty():
				continue
			if _zone_connected_without(zones, w, h, a, c):
				var dst: int = nb.keys()[randi() % nb.size()]
				zones[c] = dst
				break
	# 极端兜底（300 次仍并列）：放弃修正（实际棋盘规模下不会发生）


## 检查区域 a 移除格 without 后剩余格子是否仍连通
func _zone_connected_without(zones: PackedInt32Array, w: int, h: int, a: int, without: int) -> bool:
	var start := -1
	var count := 0
	for i in zones.size():
		if zones[i] == a and i != without:
			if start < 0:
				start = i
			count += 1
	if count <= 0:
		return false
	var seen := {start: true}
	var stack: Array = [start]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var p: Vector2i = Vector2i(cur % w, cur / w) + d
			if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h:
				var idx := p.y * w + p.x
				if zones[idx] == a and idx != without and not seen.has(idx):
					seen[idx] = true
					stack.append(idx)
	return seen.size() == count


## ===== 判定 =====

func _judge() -> void:
	_hl_t = -1.0
	var z := _sel_zone
	_sel_zone = -1
	if z == target_zone:
		score += SCORE_RIGHT
		_ok_zone = target_zone
		hud.submit_score(score)   # submit_score 内部自动比较落盘（负分/低分不影响最高分）
		_play_sfx("win")
		_state = State.WIN_ANIM
		_vanish_t = 0.0   # 立即开始第一步消散
		_spawn_popup("+%d" % SCORE_RIGHT, COL_POPUP_OK, _zone_center(z))
	else:
		score += SCORE_WRONG
		_err_zones[z] = true   # 红色遮罩保留到本关结束
		_play_sfx("fail")
		_state = State.IDLE
		_spawn_popup("%d" % SCORE_WRONG, COL_POPUP_ERR, _zone_center(z))
	_refresh_labels()
	queue_redraw()


func _process(delta: float) -> void:
	match _state:
		State.HIGHLIGHT:
			_hl_t -= delta
			queue_redraw()   # 高亮边框逐帧刷新（含呼吸外圈）
			if _hl_t <= 0.0:
				_judge()
		State.WIN_ANIM:
			_anim_t += delta
			for a in _vanish_anims:
				a.t += delta
			_vanish_anims = _vanish_anims.filter(func(a) -> bool: return a.t < VANISH_DUR)
			if not _clear_done:
				_vanish_t -= delta
				if _vanish_t <= 0.0:
					_vanish_t += VANISH_TICK
					_vanish_step()
			else:
				_win_hold -= delta
				if _win_hold <= 0.0:
					_next_level()
			queue_redraw()


## 消散一步：每个区域（含正确区域）各移除 1 个水果（向上位移渐透明）；
## 错误区域全部清空后停止消散（正确区域剩余的水果保留，进入呼吸停留）
func _vanish_step() -> void:
	for z in zone_count:
		var cells: Array = []
		for i in grid.size():
			if zones[i] == z and grid[i] >= 0:
				cells.append(i)
		if cells.is_empty():
			continue
		var c: int = cells[randi() % cells.size()]
		_vanish_anims.append({"cell": c, "fruit": grid[c], "t": 0.0})
		grid[c] = -1
	var err_left := false
	for i in grid.size():
		if zones[i] != target_zone and grid[i] >= 0:
			err_left = true
			break
	if not err_left:
		_clear_done = true
		_win_hold = BREATH_HOLD


func _next_level() -> void:
	level += 1
	_gen_level()


## 区域中心像素（所有格子几何中心均值）
func _zone_center(z: int) -> Vector2:
	var acc := Vector2.ZERO
	var cnt := 0
	for i in grid.size():
		if zones[i] == z:
			acc += _origin + (Vector2(i % cols, i / cols) + Vector2(0.5, 0.5)) * _cell
			cnt += 1
	if cnt == 0:
		return _origin + Vector2(cols, rows) * _cell * 0.5
	return acc / cnt


## ===== 重开 / 排行榜 / 音量 / BGM =====

## 重开：上一局得分入排行榜，从第 1 关重开
func _restart() -> void:
	hud.commit_score()
	level = 1
	score = 0
	_state = State.IDLE
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


## ===== 布局 =====

## 棋盘严格贴合可用区（随屏幕宽高与关卡尺寸缩放）：
## cell = min(可用高/rows, 可用宽/cols)，下限仅防 0 除，水平/垂直均在可用区内居中
func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var avail := _board_avail()
	_cell = maxf(minf(avail.y / rows, avail.x / cols), 1.0)
	var bw := cols * _cell
	var bh := rows * _cell
	_origin = Vector2(MARGIN + maxf((avail.x - bw) * 0.5, 0.0), TOP_H + maxf((avail.y - bh) * 0.5, 0.0))
	_level_board.custom_minimum_size = Vector2(170.0, m * 0.051)
	_level_board.add_theme_font_size_override("font_size", int(m * 0.035))
	_score_board.custom_minimum_size = Vector2(170.0, m * 0.051)
	_score_board.add_theme_font_size_override("font_size", int(m * 0.035))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	_refresh_labels()
	queue_redraw()


func _refresh_labels() -> void:
	_level_board.text = str(level)
	_score_board.text = str(score)


## ===== 绘制 =====

func _draw() -> void:
	if grid.is_empty():
		return
	var pad := 10.0
	var board := Rect2(_origin - Vector2(pad, pad), Vector2(cols * _cell, rows * _cell) + Vector2(pad * 2.0, pad * 2.0))
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.border_color = COL_PANEL_BORDER
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(14)
	draw_style_box(sb, board)
	# 细网格线（画在水果下层）
	for x in cols + 1:
		var gx := _origin.x + x * _cell
		draw_line(Vector2(gx, _origin.y), Vector2(gx, _origin.y + rows * _cell), COL_GRID, 1.0)
	for y in rows + 1:
		var gy := _origin.y + y * _cell
		draw_line(Vector2(_origin.x, gy), Vector2(_origin.x + cols * _cell, gy), COL_GRID, 1.0)
	# 区域分隔线（深棕粗线，画在水果下层）：扫描格间 zone 不同的边
	var lw := 3.0
	for y in rows:
		for x in cols:
			var idx := y * cols + x
			var p0 := _origin + Vector2(x, y) * _cell
			if x + 1 < cols and zones[idx] != zones[idx + 1]:
				draw_line(p0 + Vector2(_cell, 0), p0 + Vector2(_cell, _cell), COL_ZONE_LINE, lw)
			if y + 1 < rows and zones[idx] != zones[idx + cols]:
				draw_line(p0 + Vector2(0, _cell), p0 + Vector2(_cell, _cell), COL_ZONE_LINE, lw)
	# 水果（-1 = 已消失）；呼吸阶段正确区域水果放大缩小
	for y in rows:
		for x in cols:
			var f: int = grid[y * cols + x]
			if f < 0:
				continue
			var tex: Texture2D = _texs[FRUITS[f]]
			if tex == null:
				continue
			var r := Rect2(_origin + Vector2(x, y) * _cell, Vector2.ONE * _cell)
			var ip := _cell * 0.12
			if _clear_done and zones[y * cols + x] == target_zone:
				var s := 1.0 + 0.06 * sin(_anim_t * 5.0)
				var half := _cell * 0.5 - ip * s
				var ctr := r.get_center()
				draw_texture_rect(tex, Rect2(ctr - Vector2.ONE * half, Vector2.ONE * half * 2.0), false)
			else:
				draw_texture_rect(tex, Rect2(r.position + Vector2(ip, ip), Vector2.ONE * (_cell - ip * 2.0)), false)
	# 消失动画水果：向上位移 + 渐透明
	for a in _vanish_anims:
		var k: float = clampf(a.t / VANISH_DUR, 0.0, 1.0)
		var tex: Texture2D = _texs[FRUITS[a.fruit]]
		if tex == null:
			continue
		var ip := _cell * 0.12
		var sz := _cell - ip * 2.0
		var pos: Vector2 = _origin + Vector2(a.cell % cols, a.cell / cols) * _cell + Vector2(ip, ip - k * _cell * 0.9)
		draw_texture_rect(tex, Rect2(pos, Vector2.ONE * sz), false, Color(1, 1, 1, 1.0 - k))
	# 遮罩：选错红 / 选对绿（半透明填充区域内每格）
	for y in rows:
		for x in cols:
			var z: int = zones[y * cols + x]
			var r := Rect2(_origin + Vector2(x, y) * _cell, Vector2.ONE * _cell)
			if _err_zones.has(z):
				draw_rect(r.grow(-1.0), COL_ERR_MASK, true)
			elif z == _ok_zone:
				draw_rect(r.grow(-1.0), COL_OK_MASK, true)
	# 点击高亮：选中区域轮廓白色粗线打底 + 金色线（0.5s 后判定）
	if _hl_t > 0.0 and _sel_zone >= 0:
		var segs := _zone_outline(_sel_zone)
		for seg: Array in segs:
			draw_line(seg[0], seg[1], COL_HL2, 8.0)
		for seg: Array in segs:
			draw_line(seg[0], seg[1], COL_HL, 4.0)


## 区域轮廓：区域内每格与区域外相邻的边，返回线段端点列表（每项 [from, to]）
func _zone_outline(z: int) -> Array:
	var segs: Array = []
	for y in rows:
		for x in cols:
			if zones[y * cols + x] != z:
				continue
			var p0 := _origin + Vector2(x, y) * _cell
			var p1 := p0 + Vector2(_cell, 0)
			var p2 := p0 + Vector2(_cell, _cell)
			var p3 := p0 + Vector2(0, _cell)
			if y == 0 or zones[(y - 1) * cols + x] != z:
				segs.append([p0, p1])
			if x == cols - 1 or zones[y * cols + x + 1] != z:
				segs.append([p1, p2])
			if y == rows - 1 or zones[(y + 1) * cols + x] != z:
				segs.append([p3, p2])
			if x == 0 or zones[y * cols + x - 1] != z:
				segs.append([p0, p3])
	return segs


## ===== 反馈特效 =====

## 飘字：在指定位置浮现，上浮淡出后自毁（可多个并发）
func _spawn_popup(text: String, col: Color, pos: Vector2) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * 0.05))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.4, m * 0.08)
	lb.position = pos - lb.size * 0.5
	lb.position.x = clampf(lb.position.x, 8.0, vp.x - lb.size.x - 8.0)
	lb.position.y = maxf(lb.position.y, TOP_H + 8.0)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.06, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## ===== 音效 =====

## pck 内音频走字节解码，编辑器预览走导入资源（双路径）；WAV 用 AudioStreamWAV
func _init_sfx() -> void:
	var files := {"win": "win.wav", "fail": "fail.wav"}
	for sname: String in files:
		for base in ["res://games/fruit_count/assets/sfx/", "res://assets/sfx/"]:
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
	# BGM：复用围住水果的水果主题（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/fruit_count/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## 水果贴图加载：pck 内 png 未走导入流程，字节解码（双路径兼容）
func _load_textures() -> void:
	for fname: String in FRUITS:
		for base in ["res://games/fruit_count/assets/fruits/", "res://assets/fruits/"]:
			var path: String = base + fname + ".png"
			if ResourceLoader.exists(path):
				_texs[fname] = load(path)
				break
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				var img := Image.new()
				if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
					_texs[fname] = ImageTexture.create_from_image(img)
				break
