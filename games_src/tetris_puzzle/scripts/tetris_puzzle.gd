extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## Tetris Puzzle（方块拼图）：拖动待选区方块碎片放入目标图形，完全填满即通关
## 经典模式：7 种 tetromino（每关从 14 块池抽取）；棱镜模式：16 种异形块
## 关卡：第 1 关拼 2 块，每 3 关 +1，达到全部块数后进入无尽模式（每关随机全量拼图）
## 操作：按住拖动 / 松开吸附放置（非法弹回）/ 双击顺时针旋转 90° / 提示按钮高亮正确位置
## 存档：user://settings.cfg [tetris_puzzle]（最高关卡进度 + 上次模式）

const PieceData := preload("res://scripts/piece_data.gd")
const Piece := preload("res://scripts/piece.gd")
const GameHud := preload("res://scripts/game_hud.gd")

# ===== 存档 =====
const SEC := "tetris_puzzle"

# ===== 布局 =====
const HUD_H := 86.0          # 顶部栏高度
const SLOT_PITCH := 4        # 待选区货位间距（格）：4 列 × 4 格 = 16 格铺满

# ===== 关卡 =====
const BASE_COUNT := 2
const LEVELS_PER_STEP := 3
const GEN_ATTEMPTS := 24

const SFX_POOL := 6
const BGM_DB := -12.0
const SFX_DB := -6.0

# 配色
const COL_PANEL := Color(0.16, 0.19, 0.18, 0.88)
const COL_GRID := Color(1, 1, 1, 0.07)
const COL_TGT_BASE := Color(0.70, 0.73, 0.77)        # 目标格基色（浅灰）
const COL_TGT_LIT := Color(0.88, 0.90, 0.93)         # 目标格受光棱
const COL_TGT_DARK := Color(0.44, 0.47, 0.51)        # 目标格背光棱
const COL_GHOST_OK := Color(0.35, 0.85, 0.4, 0.35)
const COL_GHOST_BAD := Color(0.9, 0.3, 0.25, 0.30)

var hud: RefCounted
var mode := "classic"            # classic | prism
var level := 1
var count := 2
var max_level := 0               # 存档：最高通关关卡

# 方块
var _defs: Array = []            # 当前模式方块定义（PieceData.CLASSIC / PRISM）
var pool: Array = []             # 待选区全量方块定义实体（经典 2 套 14 块 / 棱镜 16 块）
var pieces: Array = []           # Piece 控件（待选 + 目标网格上临时放置）
var _tex_cache := {}             # id -> Array[Texture2D]（4 旋转态）

# 目标
var target_cells := {}           # Vector2i(col,row) -> true
var target_cols := 0
var target_rows := 0
var grid_cols := 0               # 目标区完整网格尺寸（形状外扩 2 格，允许自由摆放）
var grid_rows := 0
var _z_top := 1                  # 自由摆放叠层：后移动 / 旋转的块 z 递增置顶
var solution: Array = []         # [{id, rot, col, row}]（生成解序列）
var won := false

# 拖拽 / 提示
var drag_piece: Control = null
var drag_off := Vector2.ZERO
var drag_moved := false          # 本次按压后是否实际移动（区分原地双击与拖拽）
var ghost_cells: Array = []      # 对齐后的网格坐标
var ghost_valid := false
var ghost_origin := Vector2.ZERO   # ghost 吸附基准原点（所在区域网格原点）
var ghost_show := false
var hint_active := false         # 提示高亮中（高亮全部未拼入方块的正确位置）
var hint_until_ms := 0           # 提示消失时间戳

# 布局度量
var _vp := Vector2(1920, 1080)
var _landscape := true
var cell := 48.0
var sel_rect := Rect2()
var tgt_rect := Rect2()
var sel_origin := Vector2.ZERO   # 待选网格原点
var tgt_origin := Vector2.ZERO   # 目标网格原点
var sel_cols := 4                # 待选货位列数（布局恒定，_build_level 先于 _layout 使用）
var sel_rows := 4

# UI
var _top_btns: HBoxContainer
var _top_left: HBoxContainer
var _mode_opt: OptionButton
var _count_opt: OptionButton
var _hint_btn: Button
var _restart_btn: Button
var _volume_btn: Button
var _win_panel: Control = null

# 音效
var _sfx := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer

@onready var _board_level: Label = $BoardLevel
@onready var _board_count: Label = $BoardCount
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("tetris_puzzle")
	_load_save()
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_init_sfx()
	level = max_level + 1
	_new_level()
	_layout()


func stop() -> void:
	get_tree().paused = false
	if _bgm != null:
		_bgm.stop()
	_save()
	print("[tetris_puzzle] stop, level=%d max_level=%d" % [level, max_level])


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 存档 =====
func _load_save() -> void:
	var cf := ConfigFile.new()
	if cf.load(GameHud.CFG_PATH) == OK:
		max_level = int(cf.get_value(SEC, "max_level", 0))
		mode = String(cf.get_value(SEC, "mode", "classic"))
	if mode != "prism":
		mode = "classic"


func _save() -> void:
	var cf := ConfigFile.new()
	cf.load(GameHud.CFG_PATH)
	cf.set_value(SEC, "max_level", max_level)
	cf.set_value(SEC, "mode", mode)
	cf.save(GameHud.CFG_PATH)


## 解锁方块数：通关第 L 关解锁 2 + L/3（封顶全部块数）
func unlocked_count() -> int:
	return mini(BASE_COUNT + max_level / LEVELS_PER_STEP, _pool_size())


func _pool_size() -> int:
	return pool.size() if not pool.is_empty() else (PieceData.CLASSIC.size() * 2 if mode == "classic" else PieceData.PRISM.size())


func _default_count(lv: int) -> int:
	return mini(BASE_COUNT + (lv - 1) / LEVELS_PER_STEP, _pool_size())


## ===== 新关卡 =====
func _new_level() -> void:
	_defs = PieceData.CLASSIC if mode == "classic" else PieceData.PRISM
	count = _default_count(level)
	_build_level()
	_update_hud()
	_refresh_count_options()


func _build_level() -> void:
	won = false
	drag_piece = null
	ghost_show = false
	hint_active = false
	_z_top = 1
	target_cells.clear()
	solution.clear()
	for p: Control in pieces:
		p.queue_free()
	pieces.clear()
	# 待选区全量方块池：经典 = 2 套 tetromino（14 块），棱镜 = 16 块
	pool = (_defs + _defs) if mode == "classic" else _defs.duplicate()
	# 洗牌抽取 count 块生成可解目标图形
	var idxs: Array = []
	for i in _defs.size():
		idxs.append(i)
	var picked: Array = []
	var tries := 0
	while picked.size() < count and tries < 200:
		tries += 1
		idxs.shuffle()
		picked = idxs.slice(0, count)
		if _gen_solution(picked):
			break
	if solution.is_empty():   # 极端兜底：降块数重试
		count = maxi(2, count - 1)
		idxs.shuffle()
		picked = idxs.slice(0, count)
		_gen_solution(picked)
	# 创建全部池方块控件（初始朝向随机，保留旋转玩法；初始摆放在待选区货位）
	for i in pool.size():
		var def: Dictionary = pool[i]
		var p: Control = Piece.new()
		var texs := _piece_texs(String(def.id))
		p.setup(String(def.id), def.color, def.cells, cell, texs)
		p.piece_pressed.connect(_on_piece_pressed)
		p.piece_double_clicked.connect(_on_piece_double_clicked)
		p.set_meta("zone", "sel")
		p.set_meta("off", Vector2i((i % sel_cols) * SLOT_PITCH, (i / sel_cols) * SLOT_PITCH))
		add_child(p)
		p.set_rotation_state(randi() % 4, def.cells)
		pieces.append(p)
	# 解序列格子数 = 目标格数
	var cols := 0
	var rows := 0
	for g: Variant in target_cells:
		cols = maxi(cols, int(g.x) + 1)
		rows = maxi(rows, int(g.y) + 1)
	target_cols = cols
	target_rows = rows
	# 形状平移到网格中心（对齐网格；网格恒为 16×16，_layout 尚未执行故用常量）
	var shift := Vector2i((16 - cols) / 2, (16 - rows) / 2)
	if shift != Vector2i.ZERO:
		var centered := {}
		for g: Vector2i in target_cells:
			centered[g + shift] = true
		target_cells = centered
		for s: Dictionary in solution:
			s.off = Vector2i(s.off) + shift
	_layout()


## 生成可解目标：逐块邻接拼合（保证连通且必然可解），成功写入 solution / target_cells
func _gen_solution(picked: Array) -> bool:
	var placed := {}
	var sol: Array = []
	for pi: int in picked:
		var def: Dictionary = _defs[pi]
		var states: Array = PieceData.rot_states(def.cells)
		var cands: Array = []
		if placed.is_empty():
			for rot in states.size():
				cands.append({"rot": rot, "off": Vector2i.ZERO, "adj": 0, "gcells": _gcells(states[rot], Vector2i.ZERO)})
		else:
			for rot in states.size():
				var cells: Array = states[rot]
				for pc: Variant in placed.keys():
					for c: Array in cells:
						for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
							var anchor: Vector2i = Vector2i(pc) + d
							var off: Vector2i = anchor - Vector2i(int(c[1]), int(c[0]))
							var gcells := _gcells(cells, off)
							if gcells.is_empty():
								continue
							var bad := false
							for g: Vector2i in gcells:
								if placed.has(g):
									bad = true
									break
							if bad:
								continue
							var adj := 0
							for g: Vector2i in gcells:
								for d2: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
									if placed.has(g + d2):
										adj += 1
							cands.append({"rot": rot, "off": off, "adj": adj, "gcells": gcells})
		if cands.is_empty():
			return false
		# 紧凑优先 + 随机：邻接数前 50% 中随机选一
		cands.sort_custom(func(a, b): return int(a.adj) > int(b.adj))
		var keep := maxi(1, cands.size() / 2)
		var pick: Dictionary = cands[randi() % keep]
		for g: Vector2i in pick.gcells:
			placed[g] = true
		sol.append({"id": String(def.id), "rot": int(pick.rot), "off": Vector2i(pick.off)})
	# 规范化：平移到 min col/row = 0
	var min_v := Vector2i(9999, 9999)
	for g: Variant in placed:
		min_v = Vector2i(mini(min_v.x, int(g.x)), mini(min_v.y, int(g.y)))
	var cols := 0
	var rows := 0
	for g: Variant in placed:
		cols = maxi(cols, int(g.x) - min_v.x + 1)
		rows = maxi(rows, int(g.y) - min_v.y + 1)
	if maxi(cols, rows) > 14:   # 16×16 网格内需留空隙供自由摆放
		return false
	target_cells.clear()
	for g: Variant in placed:
		target_cells[Vector2i(int(g.x) - min_v.x, int(g.y) - min_v.y)] = true
	for s: Dictionary in sol:
		s.off = Vector2i(s.off) - min_v
	solution = sol
	return true


func _gcells(cells: Array, off: Vector2i) -> Array:
	var out: Array = []
	for c: Array in cells:
		out.append(Vector2i(int(c[1]), int(c[0])) + off)
	return out


## ===== 布局 =====
func _layout() -> void:
	_vp = get_viewport().get_visible_rect().size
	_landscape = _vp.x >= _vp.y
	var m := minf(_vp.x, _vp.y)
	# HUD 节点层级高于方块（块 z=1 / 拖动 z=100）
	_board_level.z_index = 150
	_board_count.z_index = 150
	_exit_btn.z_index = 150
	# HUD 板居中（避让右侧按钮组）
	if _top_btns != null:
		_top_btns.reset_size()
		_top_btns.position = Vector2(_vp.x - _top_btns.size.x - 16.0, 14.0)
	if _top_left != null:
		_top_left.reset_size()
		_top_left.position = Vector2(16.0, 14.0)
	var btns_w := _top_btns.size.x if _top_btns != null else 0.0
	var bw := _board_level.size.x + _board_count.size.x + 20.0
	var cx := maxf(16.0, (_vp.x - btns_w) / 2.0 - bw / 2.0)
	_board_level.position = Vector2(cx, 14.0)
	_board_count.position = Vector2(cx + _board_level.size.x + 20.0, 14.0)
	# 区域划分
	var area := Rect2(12.0, HUD_H, _vp.x - 24.0, _vp.y - HUD_H - 12.0)
	if _landscape:
		var half := area.size.x / 2.0
		sel_rect = Rect2(area.position, Vector2(half - 6.0, area.size.y))
		tgt_rect = Rect2(area.position + Vector2(half + 6.0, 0), Vector2(half - 6.0, area.size.y))
	else:
		var half := area.size.y / 2.0
		sel_rect = Rect2(area.position, Vector2(area.size.x, half - 6.0))
		tgt_rect = Rect2(area.position + Vector2(0, half + 6.0), Vector2(area.size.x, area.size.y - half - 6.0))
	# 两区统一 16×16 网格：铺满面板区域（无内边距），格子随区域尺寸自适应放大
	sel_cols = 4
	sel_rows = 4
	grid_cols = 16
	grid_rows = 16
	var cell_t := minf(tgt_rect.size.x, tgt_rect.size.y) / 16.0
	var cell_s := minf(sel_rect.size.x, sel_rect.size.y) / 16.0
	cell = minf(cell_t, cell_s)
	# 网格原点（面板内居中）
	sel_origin = sel_rect.get_center() - Vector2(sel_cols * SLOT_PITCH, sel_rows * SLOT_PITCH) * cell / 2.0
	tgt_origin = tgt_rect.get_center() - Vector2(grid_cols, grid_rows) * cell / 2.0
	# 更新方块（按记录的网格位重摆：两区自由摆放，位置随窗口尺寸自适应）
	for p: Control in pieces:
		p.cell_px = cell
		p.set_rotation_state(p.rot, _def_cells(p.piece_id))
		if drag_piece == p:
			p.position = get_global_mouse_position() - drag_off
		else:
			var zone := str(p.get_meta("zone", "sel"))
			var origin := sel_origin if zone == "sel" else tgt_origin
			p.position = origin + Vector2(Vector2i(p.get_meta("off", Vector2i.ZERO))) * cell
	queue_redraw()


func _def_cells(id: String) -> Array:
	for d: Dictionary in _defs:
		if String(d.id) == id:
			return d.cells
	return []


## ===== 方块交互 =====
func _on_piece_pressed(p: Control, at: Vector2) -> void:
	if won or drag_piece != null:
		return
	drag_piece = p
	drag_off = at
	drag_moved = false
	p.z_index = 100   # 拖拽中置顶，确保始终可见
	p.hinted = false
	queue_redraw()


## 双击：顺时针旋转 90°，保持原位就近吸附（后操作的块叠在上层）
func _on_piece_double_clicked(p: Control) -> void:
	if won:
		return
	if drag_piece == p:
		if drag_moved:
			return   # 拖动中不旋转
		drag_piece = null   # 原地双击：先结束第一击挂起的拖拽态
		ghost_show = false
	p.set_rotation_state(p.rot + 1, _def_cells(p.piece_id))
	_snap_piece(p)
	_play_sfx("rotate")
	queue_redraw()
	_evaluate_win()


## 松手：就近吸附所在区域的网格（两区自由摆放、允许重叠、不弹回）
func _drop_piece() -> void:
	var p := drag_piece
	drag_piece = null
	ghost_show = false
	_snap_piece(p)
	_play_sfx("place")
	queue_redraw()
	_evaluate_win()


## 吸附：按块中心所在面板取网格，左上格 round 对齐后 clamp 到网格内；后操作置顶
func _snap_piece(p: Control) -> void:
	var zone := "tgt" if tgt_rect.has_point(p.position + p.size / 2.0) else "sel"
	var origin := sel_origin if zone == "sel" else tgt_origin
	var b := PieceData.bounds(p.cells)
	var off := Vector2i((p.position - origin + Vector2(cell, cell) * 0.5) / cell)
	off.x = clampi(off.x, 0, 16 - b.x)
	off.y = clampi(off.y, 0, 16 - b.y)
	p.position = origin + Vector2(off) * cell
	p.set_meta("zone", zone)
	p.set_meta("off", off)
	_z_top = mini(_z_top + 1, 99)
	p.z_index = _z_top


## 过关判定（参考原项目）：完全位于目标形状内的块需无重叠且恰好铺满全部形状格；
## 压着形状但超出的块视为未就位（不能多），形状格有缺（不能少）同样不过关
func _evaluate_win() -> void:
	if won:
		return
	var owner := {}
	for p: Control in pieces:
		if p == drag_piece or str(p.get_meta("zone", "sel")) != "tgt":
			continue
		var gcells := _gcells(p.cells, Vector2i(p.get_meta("off", Vector2i.ZERO)))
		var inter := 0
		for g: Vector2i in gcells:
			if target_cells.has(g):
				inter += 1
		if inter == 0:
			continue   # 与目标形状无关的块不参与
		if inter < gcells.size():
			return   # 有块压着形状边界（不能多）
		for g: Vector2i in gcells:
			if owner.has(g):
				return   # 形状内块重叠
			owner[g] = p
	if target_cells.size() > 0 and owner.size() == target_cells.size():
		_win()


func _input(event: InputEvent) -> void:
	if drag_piece == null:
		return
	if event is InputEventMouseMotion:
		if not drag_moved and event.relative.length() > 4.0:
			drag_moved = true   # 超过抖动阈值才算实际拖动
		drag_piece.position = event.global_position - drag_off
		_update_ghost()
		queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_drop_piece()


func _update_ghost() -> void:
	var p := drag_piece
	if p == null:
		ghost_show = false
		return
	var zone := "tgt" if tgt_rect.has_point(p.position + p.size / 2.0) else "sel"
	var origin := sel_origin if zone == "sel" else tgt_origin
	var b := PieceData.bounds(p.cells)
	var off := Vector2i((p.position - origin + Vector2(cell, cell) * 0.5) / cell)
	off.x = clampi(off.x, 0, 16 - b.x)
	off.y = clampi(off.y, 0, 16 - b.y)
	ghost_cells = _gcells(p.cells, off)
	ghost_origin = origin
	ghost_valid = true   # 自由摆放：吸附位置总是合法
	ghost_show = true


## ===== 提示 =====
## 点击显示提示：一次高亮全部未拼入方块的正确位置（对应块 + 目标格），3 秒后自动消失
func _on_hint() -> void:
	if won or solution.is_empty():
		return
	hint_active = true
	hint_until_ms = Time.get_ticks_msec() + 3000
	for p: Control in pieces:
		p.hinted = _in_solution(p.piece_id) and p != drag_piece
	queue_redraw()


func _clear_hint() -> void:
	hint_active = false
	for p: Control in pieces:
		p.hinted = false
		p.queue_redraw()   # 方块自身重绘，清除提示描边残留
	queue_redraw()


func _in_solution(id: String) -> bool:
	for s: Dictionary in solution:
		if String(s.id) == id:
			return true
	return false


## ===== 胜利 =====
func _win() -> void:
	won = true
	_play_sfx("win")
	max_level = maxi(max_level, level)
	_save()
	_update_hud()
	_show_win_panel()


func _show_win_panel() -> void:
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
	vb.add_theme_constant_override("separation", int(m * 0.018))
	panel.add_child(vb)
	var title := Label.new()
	title.text = hud.t("popup.win_title", "Puzzle Complete!")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(m * 0.055))
	GameHud._style_label(title, Color(1.0, 0.85, 0.25))
	vb.add_child(title)
	var msg := Label.new()
	msg.text = hud.t("popup.endless", "Endless Mode · Next Level %d") % (level + 1) if count >= _pool_size() else hud.t("popup.win_msg", "Level %d cleared. Keep going!") % level
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", int(m * 0.032))
	GameHud._style_label(msg, Color.WHITE)
	vb.add_child(msg)
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
	panel.z_index = 200   # 弹窗置于所有方块之上
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
	_new_level()
	_layout()


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
	_top_btns.z_index = 150   # HUD 高于方块（块 z=1 / 拖动 z=100）
	add_child(_top_btns)
	_top_btns.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	# 左上角按钮组：2 个下拉框 + 提示钮（2026-10-10 用户定，避开右上 ✕ 列）
	_top_left = HBoxContainer.new()
	_top_left.name = "TopLeft"
	_top_left.add_theme_constant_override("separation", -8)
	_top_left.z_index = 150
	add_child(_top_left)
	_top_left.process_mode = Node.PROCESS_MODE_ALWAYS
	_mode_opt = _make_option()
	_mode_opt.add_item(hud.t("mode.classic", "Classic Blocks"))
	_mode_opt.add_item(hud.t("mode.prism", "Prism Blocks"))
	_mode_opt.selected = 0 if mode == "classic" else 1
	_mode_opt.item_selected.connect(_on_mode_selected)
	_count_opt = _make_option()
	_count_opt.item_selected.connect(_on_count_selected)
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
	for b: Control in [_mode_opt, _count_opt, _hint_btn]:
		_top_left.add_child(b)
		b.custom_minimum_size = Vector2(44.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.add_theme_constant_override("icon_max_width", 32)
	for b: Control in [bgm_btn, _volume_btn, _restart_btn, min_btn, _exit_btn]:
		_top_btns.add_child(b)
		b.custom_minimum_size = Vector2(44.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.add_theme_constant_override("icon_max_width", 32)
	_restart_btn.pressed.connect(_on_restart)
	bgm_btn.pressed.connect(_on_bgm.bind(bgm_btn))
	_volume_btn.pressed.connect(_on_volume)
	for b: Button in [_mode_opt, _count_opt, _hint_btn]:
		b.add_theme_font_size_override("font_size", 22)


func _make_option() -> OptionButton:
	var ob := OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	ob.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for col in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		ob.add_theme_color_override(col, Color.WHITE)
	ob.add_theme_color_override("font_outline_color", Color.BLACK)
	ob.add_theme_constant_override("outline_size", 6)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.72)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(8.0)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	ob.add_theme_stylebox_override("normal", sb)
	var sbh: StyleBoxFlat = sb.duplicate()
	sbh.bg_color = Color(0.24, 0.28, 0.27, 0.85)
	ob.add_theme_stylebox_override("hover", sbh)
	ob.add_theme_stylebox_override("pressed", sbh)
	ob.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var pop := ob.get_popup()
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.16, 0.19, 0.18, 0.97)
	psb.set_corner_radius_all(12)
	psb.set_content_margin_all(10.0)
	pop.add_theme_stylebox_override("panel", psb)
	pop.add_theme_color_override("font_color", Color.WHITE)
	pop.add_theme_color_override("font_hover_color", Color(1.0, 0.85, 0.25))
	pop.add_theme_constant_override("outline_size", 4)
	pop.add_theme_color_override("font_outline_color", Color.BLACK)
	return ob


func _on_mode_selected(i: int) -> void:
	var new_mode := "classic" if i == 0 else "prism"
	if new_mode == mode:
		return
	mode = new_mode
	_save()
	_new_level()
	_layout()


func _on_count_selected(i: int) -> void:
	var v := 2 + i
	if v == count:
		return
	count = v
	# 跳到该方块数对应关卡集的第一关（count = 2 + (level-1)/3）
	level = (v - BASE_COUNT) * LEVELS_PER_STEP + 1
	_new_level()
	_layout()


## 方块数下拉：2 .. 已解锁数
func _refresh_count_options() -> void:
	if _count_opt == null:
		return
	_count_opt.clear()
	var umax := unlocked_count()
	for v in range(2, umax + 1):
		_count_opt.add_item(str(v))
	_count_opt.selected = clampi(count - 2, 0, umax - 2)


func _update_hud() -> void:
	_board_level.text = hud.t("hud.level", "Level %d") % level
	if count >= _pool_size():
		_board_count.text = "%s ∞" % (hud.t("hud.count", "Pieces %d") % count)
	else:
		_board_count.text = hud.t("hud.count", "Pieces %d") % count


## 重开：不刷新目标图形，仅将方块归位到待选区初始货位（保留当前旋转朝向）
func _on_restart() -> void:
	if won:
		return
	_play_sfx("fail", 1.0, -10.0)
	drag_piece = null
	ghost_show = false
	_z_top = 1
	_clear_hint()
	for i in pieces.size():
		var p: Control = pieces[i]
		var off := Vector2i((i % sel_cols) * SLOT_PITCH, (i / sel_cols) * SLOT_PITCH)
		p.set_meta("zone", "sel")
		p.set_meta("off", off)
		p.z_index = 0
		p.position = sel_origin + Vector2(off) * cell
	queue_redraw()


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


## ===== 贴图缓存（4 旋转态，Image.rotate_90 与 cells 旋转公式一致）=====
func _piece_texs(id: String) -> Array:
	if _tex_cache.has(id):
		return _tex_cache[id]
	var out: Array = []
	var f := FileAccess.open("res://assets/blocks/%s.png" % id, FileAccess.READ)
	if f != null:
		var img := Image.new()
		if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
			out.append(ImageTexture.create_from_image(img))
			for i in 3:
				img.rotate_90(CLOCKWISE)
				out.append(ImageTexture.create_from_image(img))
	f.close()
	_tex_cache[id] = out
	return out


## ===== 绘制 =====
func _process(_delta: float) -> void:
	# 提示超时消失 + 脉冲动画
	if hint_active and Time.get_ticks_msec() >= hint_until_ms:
		_clear_hint()
	for p: Control in pieces:
		p.tick_hint()


func _draw() -> void:
	# 面板底
	_draw_panel(sel_rect)
	_draw_panel(tgt_rect)
	# 待选区网格
	_draw_grid(sel_rect, sel_origin, sel_cols * SLOT_PITCH, sel_rows * SLOT_PITCH)
	# 目标区完整网格 + 目标图形立体格（形状恒保持原状）
	_draw_grid(tgt_rect, tgt_origin, grid_cols, grid_rows)
	if target_cols > 0:
		_draw_target()
	# ghost（拖拽预览，绿色吸附位置）
	if ghost_show and drag_piece != null:
		for g: Vector2i in ghost_cells:
			draw_rect(Rect2(ghost_origin + Vector2(g) * cell + Vector2.ONE * 2.0, Vector2.ONE * (cell - 4.0)), COL_GHOST_OK, true)
	# 提示：全部未拼入方块的正确位置按其方块颜色高亮
	if hint_active:
		for s: Dictionary in solution:
			var gcells := _gcells(PieceData.rot_states(_def_cells(String(s.id)))[int(s.rot)], Vector2i(s.off))
			var c: Color = _def_color(String(s.id))
			c.a = 0.42
			for g: Vector2i in gcells:
				draw_rect(Rect2(tgt_origin + Vector2(g) * cell + Vector2.ONE * 3.0, Vector2.ONE * (cell - 6.0)), c, true)


func _def_color(id: String) -> Color:
	for d: Dictionary in _defs:
		if String(d.id) == id:
			return d.color
	return Color.WHITE


func _draw_panel(r: Rect2) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.set_corner_radius_all(14)
	draw_style_box(sb, r)


func _draw_grid(area: Rect2, origin: Vector2, cols: int, rows: int) -> void:
	if cols <= 0 or rows <= 0:
		return
	var w := cols * cell
	var h := rows * cell
	for i in cols + 1:
		var x := origin.x + i * cell
		draw_line(Vector2(x, origin.y), Vector2(x, origin.y + h), COL_GRID, 1.0)
	for j in rows + 1:
		var y := origin.y + j * cell
		draw_line(Vector2(origin.x, y), Vector2(origin.x + w, y), COL_GRID, 1.0)


## 目标图形：浅灰立体格（先全部画底面阴影，再画格面，避免相邻格互相覆盖棱边）+ 黑色外轮廓
## 方块填入后立即移除，形状恒保持完整原状
func _draw_target() -> void:
	for g: Variant in target_cells:
		var r := Rect2(tgt_origin + Vector2(g) * cell, Vector2.ONE * cell)
		draw_rect(r.grow(3.0), COL_TGT_DARK, true)
	for g: Variant in target_cells:
		var r := Rect2(tgt_origin + Vector2(g) * cell, Vector2.ONE * cell)
		draw_rect(r, COL_TGT_BASE, true)
		draw_rect(Rect2(r.position, Vector2(cell, 4.0)), COL_TGT_LIT, true)
		draw_rect(Rect2(r.position, Vector2(4.0, cell)), COL_TGT_LIT, true)
		draw_rect(Rect2(r.position + Vector2(0, cell - 4.0), Vector2(cell, 4.0)), COL_TGT_DARK, true)
		draw_rect(Rect2(r.position + Vector2(cell - 4.0, 0), Vector2(4.0, cell)), COL_TGT_DARK, true)
	# 外轮廓黑描边
	for g: Variant in target_cells:
		var p0 := tgt_origin + Vector2(g) * cell
		var gc := Vector2i(g)
		if not target_cells.has(gc + Vector2i(0, -1)):
			draw_line(p0, p0 + Vector2(cell, 0), Color(0.1, 0.09, 0.1), 3.0)
		if not target_cells.has(gc + Vector2i(0, 1)):
			draw_line(p0 + Vector2(0, cell), p0 + Vector2(cell, cell), Color(0.1, 0.09, 0.1), 3.0)
		if not target_cells.has(gc + Vector2i(-1, 0)):
			draw_line(p0, p0 + Vector2(0, cell), Color(0.1, 0.09, 0.1), 3.0)
		if not target_cells.has(gc + Vector2i(1, 0)):
			draw_line(p0 + Vector2(cell, 0), p0 + Vector2(cell, cell), Color(0.1, 0.09, 0.1), 3.0)


## ===== 音效 =====
func _init_sfx() -> void:
	_sfx = {
		"place": _make_snap(),        # 放置：清脆"啪"
		"fail": _make_plop(),         # 弹回：低沉"噗"
		"win": _load_stream("crowd_cheer.mp3"),
		"rotate": _make_thud(),       # 旋转：短促"卜"
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
	_bgm.process_mode = Node.PROCESS_MODE_ALWAYS   # 过关弹窗暂停时 BGM 不中断
	add_child(_bgm)
	if hud.bgm_on:
		_bgm.play()


## 程序生成旋转音：短促低闷"卜"（低频双音快衰减）
func _make_thud() -> AudioStreamWAV:
	var rate := 44100
	var n := int(rate * 0.09)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var v := sin(t * 180.0 * TAU) * exp(-t * 45.0) * 0.7 \
				+ sin(t * 90.0 * TAU) * exp(-t * 38.0) * 0.3
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	return _wav(data, rate)


## 程序生成放置音：清脆"啪"（高频振铃 + 噪声瞬态）
func _make_snap() -> AudioStreamWAV:
	var rate := 44100
	var n := int(rate * 0.05)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		var t := float(i) / rate
		var v := sin(t * 1900.0 * TAU) * exp(-t * 90.0) * 0.5 \
				+ (rng.randf() * 2.0 - 1.0) * exp(-t * 220.0) * 0.35
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	return _wav(data, rate)


## 程序生成弹回音：低沉下滑"噗"
func _make_plop() -> AudioStreamWAV:
	var rate := 44100
	var n := int(rate * 0.12)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / rate
		phase += TAU * (150.0 - 60.0 * t / 0.12) / rate
		var v := sin(phase) * exp(-t * 28.0) * 0.6
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	return _wav(data, rate)


func _wav(data: PackedByteArray, rate: int) -> AudioStreamWAV:
	var ws := AudioStreamWAV.new()
	ws.format = AudioStreamWAV.FORMAT_16_BITS
	ws.mix_rate = rate
	ws.stereo = false
	ws.data = data
	return ws


func _load_stream(fname: String) -> AudioStream:
	var f := FileAccess.open("res://assets/sfx/" + fname, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	var mp := AudioStreamMP3.new()
	mp.data = buf
	return mp


func _play_sfx(name: String, pitch: float = 1.0, db: float = SFX_DB) -> void:
	if not _sfx.has(name) or _sfx[name] == null:
		return
	for ap: AudioStreamPlayer in _sfx_players:
		if not ap.playing:
			ap.stream = _sfx[name]
			ap.pitch_scale = pitch
			ap.volume_db = db
			ap.play()
			return
