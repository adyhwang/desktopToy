extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 围住水果（Fruit Enclose）：棋盘随机布满水果，玩家移动 2×2 方框，找出与右上角
## 目标样板完全一致的 2×2 区域，提交判定；通过进入下一关。
## 交互：左键按住方框区域内拖动才能移动方框（按住点相对方框的偏移保持不变）；
## 双击方框区域、或按住方框区域不动 0.5s 触发提交（一旦拖动过则本次按压不触发长按，避免移动误提交）
## （棋盘每过 1 关扩 1 格，方向按屏幕剩余空间决定，总格子数达 400 封顶且单维可超 20，尽量填满屏幕）
## 最高通关关卡复用合集存档（GameHud submit_score/commit_score，排行榜分值 = 关卡数）

const GameHud := preload("res://scripts/game_hud.gd")

const FRUITS := ["apple", "banana", "carrot", "grape", "orange", "peach", "pear", "Pineapple", "strawberry", "watermelon"]
const BOARD_MIN := 6        # 第 1 关 6×6
const BOARD_CELLS := 400    # 总格子数上限（=20×20，单维可超 20），达到后不再扩大
const KINDS_BASE := 3       # 种类数 = 3 + 关卡（夹 4..10）：第 1 关 4 种，第 7 关起满 10 种
const TOP_H := 86.0         # 顶栏高度（棋盘从其下开始布局）
const MARGIN := 14.0        # 棋盘区边距
const HOLD_MS := 500        # 长按提交判定：按住方框不动的时长 ms
const MOVE_DIST := 14.0     # 按压后移动超过该距离判定为拖动（取消本次长按资格）
const DOUBLE_MS := 400      # 双击提交判定：两次按下最大间隔 ms（触摸屏合成事件 double_click 标志不可靠，自实现）
const DOUBLE_DIST := 32.0   # 双击提交判定：两次按下最大间距 px
const WIN_HOLD := 0.9       # 通过后的停留时长（s），期间禁提交，到时切下一关
const ERR_TIME := 0.66      # 失败红闪时长（s，3 次闪烁）
const POPUP_TIME := 0.8     # 飘字动画时长（s）
const SFX_POOL := 4
const BGM_DB := -6.0
const SFX_DB := -4.0

# 配色（扁平卡通，纯色 + 深描边，网格风格参考方块拼图）
const COL_PANEL := Color(0.984, 0.918, 0.749)        # 棋盘底：米黄
const COL_PANEL_BORDER := Color(0.30, 0.23, 0.18)    # 深棕描边
const COL_GRID := Color(0.858, 0.769, 0.576)         # 网格线
const COL_CHECKER := Color(1, 1, 1, 0.16)            # 棋盘格淡色交替
const COL_SEL_FILL := Color(0.25, 0.85, 0.40, 0.30)  # 选择框半透明绿色高亮
const COL_SEL_LINE := Color(0.14, 0.55, 0.26)        # 选择框深绿描边
const COL_SEL_LINE2 := Color(1, 1, 1, 0.9)           # 选择框外圈白线提亮
const COL_ERR := Color(0.92, 0.22, 0.16)             # 失败红闪

var hud: RefCounted
var level := 1
var cols := BOARD_MIN
var rows := BOARD_MIN
var kinds := 4
var grid: Array[int] = []                 # rows*cols 个水果索引（FRUITS 下标），行优先
var pattern: Array[int] = [0, 0, 0, 0]    # 目标样板 2×2（行优先）
var _texs := {}                           # 水果名 → Texture2D
var _cell := 60.0
var _origin := Vector2.ZERO               # 棋盘左上角
var _bx := 0                              # 方框左上角格（col/row）
var _by := 0
var _busy := false                        # 通过动画期间禁提交
var _win_t := -1.0                        # >0：通过停留倒计时
var _err_t := -1.0                        # >0：失败红闪倒计时
var _pressing := false                    # 左键按住中（按下点在方框区域内）
var _dragging := false                    # 本次按压已进入拖动（取消长按资格）
var _hold_fired := false                  # 本次按压长按已触发（防重复提交）
var _press_ms := 0                        # 按下时刻 ms
var _press_pos := Vector2.ZERO            # 按下点
var _grab_px := Vector2.ZERO              # 按下点相对方框左上角的像素偏移（拖动保持）
var _last_ms := 0                         # 上次左键按下时刻（双击判定，0 = 无记录）
var _last_pos := Vector2.ZERO
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _hbox: HBoxContainer
var _lb_btn: Button
var _restart_btn: Button
var _bgm_btn: Button
var _volume_btn: Button
var _pv_panel: PanelContainer
var _pv_label: Label                    # 预览标题（字号随窗口缩放）
var _pv_rects: Array = []               # 预览面板 4 个 TextureRect
var _dev_pending := false               # DEV 暗门：面板 5 秒点满 10 次，关榜后弹窗
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_win: PanelContainer
var _dev_drag := false
var _dev_jump_sl: HSlider               # 跳关滑块/值标签（切关后同步到当前关）
var _dev_jump_lb: Label
var _dev_hint_cell := Vector2i(-1, -1)  # DEV 提示：解区左上格（-1 = 无）
var _dev_hint_t := -1.0                 # >0：提示高亮倒计时

@onready var _level_board: Label = $HudBar/LevelBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("fruit_enclose")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()   # 先建按钮再布局（_layout 会定位，null 会报错中断）
	_setup_preview()
	_layout()
	_init_sfx()
	_gen_level()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 退出视作本局结束，最高通关关卡入排行榜
	print("[fruit_enclose] stop, level=%d best=%d" % [level, hud.max_score])


## 键盘 R 重开（与右上角 R 按钮一致）
## 鼠标：按下方框区域内才开始按压；移动超阈值进入拖动（方框按抓取偏移跟随）；
## 按住不动满 HOLD_MS 触发提交（拖动过则本次按压不触发）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()
		return
	if event is InputEventMouseMotion:
		if _pressing and not _dragging and not _hold_fired \
				and event.position.distance_to(_press_pos) >= MOVE_DIST:
			_dragging = true
			queue_redraw()   # 停画长按进度圈
		if _pressing and _dragging:
			_move_box(event.position - _grab_px)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var sel := Rect2(_origin + Vector2(_bx, _by) * _cell, Vector2.ONE * (_cell * 2.0))
			if sel.has_point(event.position):
				_pressing = true
				_dragging = false
				_hold_fired = false
				_press_ms = Time.get_ticks_msec()
				_press_pos = event.position
				_grab_px = event.position - sel.position
				# 双击提交（与长按并存）：第二次按下在时限/间距内立即提交
				var now := Time.get_ticks_msec()
				if _last_ms > 0 and now - _last_ms <= DOUBLE_MS \
						and event.position.distance_to(_last_pos) <= DOUBLE_DIST:
					_last_ms = 0
					_hold_fired = true   # 已提交，本次按压取消长按资格
					_submit()
				else:
					_last_ms = now
					_last_pos = event.position
				queue_redraw()   # 开始画长按进度圈
		elif _pressing:
			_pressing = false
			_dragging = false
			queue_redraw()


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 关卡 =====

## 棋盘可用像素区（与 _layout 同源）：宽 = 屏宽 - 边距×2 - 右侧预览面板占位，高 = TOP_H 以下 - 边距×2
func _board_avail() -> Vector2:
	var vp := get_viewport_rect().size
	var avail_w: float = maxf(vp.x - MARGIN * 2.0, 60.0)
	var avail_h: float = maxf(vp.y - TOP_H - MARGIN * 2.0, 60.0)
	var pv_w := 0.0
	if _pv_panel != null:
		pv_w = _pv_panel.size.x + 20.0
	return Vector2(maxf(avail_w - pv_w, 60.0), avail_h)


## 棋盘尺寸：第 1 关 6×6；每通过 1 关扩 1 格，方向按屏幕剩余空间决定（avail = 可用像素区）——
## 横向加一列不缩格子则优先加宽，否则纵向加一行不缩格子则加高；
## 两边都要缩格子时选格子更大的方向继续扩（此时才真正缩小棋盘格子，尽量填满屏幕）；
## 总格子数达到 BOARD_CELLS（=20×20=400，单维可超 20）后不再扩大
func _board_dims(lv: int, avail: Vector2) -> Vector2i:
	var w := BOARD_MIN
	var h := BOARD_MIN
	for i in lv - 1:
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


## 生成关卡：随机样板 → 随机铺满 → 把样板写入随机位置（强制保证至少一处 2×2 匹配，有解）
func _gen_level() -> void:
	var dims := _board_dims(level, _board_avail())
	cols = dims.x
	rows = dims.y
	kinds = clampi(KINDS_BASE + level, 4, FRUITS.size())
	for i in 4:
		pattern[i] = randi() % kinds
	if pattern[0] == pattern[1] and pattern[1] == pattern[2] and pattern[2] == pattern[3]:
		pattern[3] = (pattern[3] + 1 + randi() % (kinds - 1)) % kinds   # 避免 4 个全同的纯运气样板
	grid.resize(cols * rows)
	for i in grid.size():
		grid[i] = randi() % kinds
	_write_pattern(randi() % (cols - 1), randi() % (rows - 1))
	_bx = clampi(cols / 2 - 1, 0, cols - 2)
	_by = clampi(rows / 2 - 1, 0, rows - 2)
	_pressing = false
	_dragging = false
	_hold_fired = false
	_last_ms = 0
	_dev_hint_cell = Vector2i(-1, -1)   # 换关清提示
	_dev_hint_t = -1.0
	_refresh_labels()
	_update_preview()
	_layout()   # rows/cols 变了必须重算 cell/origin，棋盘按屏幕宽高缩放（防大关卡溢出屏幕）


func _write_pattern(sx: int, sy: int) -> void:
	for dy in 2:
		for dx in 2:
			grid[(sy + dy) * cols + sx + dx] = pattern[dy * 2 + dx]


## 方框内 2×2 与样板逐位置比对
func _match_at(c: int, r: int) -> bool:
	for dy in 2:
		for dx in 2:
			if grid[(r + dy) * cols + c + dx] != pattern[dy * 2 + dx]:
				return false
	return true


## ===== 提交判定 =====

func _submit() -> void:
	if _busy or _win_t > 0.0:
		return
	if _match_at(_bx, _by):
		_busy = true
		_win_t = WIN_HOLD
		hud.submit_score(level)   # 记录最高通关关卡（submit_score 内部自动比较落盘）
		_play_sfx("win")
		_spawn_particles(_box_center())
		_spawn_popup(hud.t("fe.win", "Level %d cleared!") % level, Color(0.2, 0.85, 0.3))
		_refresh_labels()
	else:
		_err_t = ERR_TIME
		_play_sfx("fail")
		_spawn_popup(hud.t("fe.fail", "No match!"), COL_ERR)
		queue_redraw()


func _box_center() -> Vector2:
	return _origin + Vector2(_bx + 1, _by + 1) * _cell


func _process(delta: float) -> void:
	# 长按提交：按住方框未拖动满 HOLD_MS 触发一次
	if _pressing and not _dragging and not _hold_fired \
			and Time.get_ticks_msec() - _press_ms >= HOLD_MS:
		_hold_fired = true
		queue_redraw()   # 停画进度圈
		_submit()
	if _err_t > 0.0:
		_err_t -= delta
		queue_redraw()   # 红闪逐帧刷新
		if _err_t <= 0.0:
			_err_t = -1.0
			queue_redraw()
	if _dev_hint_t > 0.0:
		_dev_hint_t -= delta
		queue_redraw()   # DEV 提示闪烁逐帧刷新
		if _dev_hint_t <= 0.0:
			_dev_hint_t = -1.0
			_dev_hint_cell = Vector2i(-1, -1)
			queue_redraw()
	if _win_t > 0.0:
		_win_t -= delta
		if _win_t <= 0.0:
			_win_t = -1.0
			level += 1
			_busy = false
			_gen_level()


## 方框移动：鼠标位置吸附到格，clamp 在棋盘内（2×2 不能出界）
func _move_box(p: Vector2) -> void:
	var c := int(floor((p.x - _origin.x) / _cell))
	var r := int(floor((p.y - _origin.y) / _cell))
	var nx := clampi(c, 0, maxi(cols - 2, 0))
	var ny := clampi(r, 0, maxi(rows - 2, 0))
	if nx != _bx or ny != _by:
		_bx = nx
		_by = ny
		queue_redraw()


## ===== 重开 / 排行榜 / 音量 / BGM =====

## 重开：上一局进度入排行榜，关卡归 1 重生成
func _restart() -> void:
	hud.commit_score()
	level = 1
	_busy = false
	_win_t = -1.0
	_err_t = -1.0
	_gen_level()
	_sync_bgm()


func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("ui.top10", "Top 10"), -1, -1)
	_arm_dev_clicks()   # 暗门：排行榜面板 5 秒内点满 10 次


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


## ===== 目标样板预览（右上角） =====
## 覆盖在游戏区上的 Control 全部 mouse_filter=IGNORE，防止吞掉棋盘鼠标事件
func _setup_preview() -> void:
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	_pv_panel = PanelContainer.new()
	_pv_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.984, 0.918, 0.749, 0.96)
	sb.border_color = COL_PANEL_BORDER
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(10.0)
	_pv_panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	_pv_panel.add_child(vb)
	var lb := Label.new()
	lb.text = hud.t("fe.target", "Target")
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lb.add_theme_color_override("font_color", COL_PANEL_BORDER)
	lb.add_theme_font_size_override("font_size", int(m * 0.024))
	vb.add_child(lb)
	_pv_label = lb
	var gc := GridContainer.new()
	gc.columns = 2
	gc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gc.add_theme_constant_override("h_separation", 6)
	gc.add_theme_constant_override("v_separation", 6)
	vb.add_child(gc)
	var ic := clampf(m * 0.058, 44.0, 68.0)
	for i in 4:
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(ic, ic)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gc.add_child(tr)
		_pv_rects.append(tr)
	add_child(_pv_panel)
	_pv_panel.reset_size()


func _update_preview() -> void:
	for i in 4:
		var tr: TextureRect = _pv_rects[i]
		tr.texture = _texs[FRUITS[pattern[i]]]


## ===== 布局 =====

## 棋盘严格贴合可用区（随屏幕宽高与关卡尺寸缩放）：
## cell = min(可用高/rows, (可用宽−预览让位)/cols)，无有效下限兜底（仅防 0 除），
## 水平方向在"扣除右上预览后的区域"内居中（任何宽高比下棋盘完整可见且不压预览）
func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var avail_w: float = maxf(vp.x - MARGIN * 2.0, 60.0)
	var avail_h: float = maxf(vp.y - TOP_H - MARGIN * 2.0, 60.0)
	# 预览面板随窗口缩放（窄窗口时同步缩小，给棋盘让位）
	if _pv_panel != null:
		var ic := clampf(m * 0.058, 36.0, 68.0)
		for tr: TextureRect in _pv_rects:
			tr.custom_minimum_size = Vector2(ic, ic)
		if _pv_label != null:
			_pv_label.add_theme_font_size_override("font_size", int(m * 0.024))
		_pv_panel.reset_size()
	var pv_w := 0.0
	if _pv_panel != null:
		pv_w = _pv_panel.size.x + 20.0
	_cell = maxf(minf(avail_h / rows, (avail_w - pv_w) / cols), 1.0)
	var bw := cols * _cell
	var bh := rows * _cell
	var ox := MARGIN + maxf((avail_w - pv_w - bw) * 0.5, 0.0)
	var oy := TOP_H + maxf((avail_h - bh) * 0.5, 0.0)
	_origin = Vector2(ox, oy)
	_level_board.custom_minimum_size = Vector2(170.0, m * 0.051)
	_level_board.add_theme_font_size_override("font_size", int(m * 0.035))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	if _pv_panel != null:
		_pv_panel.position = Vector2(vp.x - _pv_panel.size.x - 16.0, TOP_H + 10.0)
	_refresh_labels()
	queue_redraw()


func _refresh_labels() -> void:
	_level_board.text = hud.t("fe.level", "Level %d") % level


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
	# 网格线（画在水果下层）
	for x in cols + 1:
		var gx := _origin.x + x * _cell
		draw_line(Vector2(gx, _origin.y), Vector2(gx, _origin.y + rows * _cell), COL_GRID, 1.0)
	for y in rows + 1:
		var gy := _origin.y + y * _cell
		draw_line(Vector2(_origin.x, gy), Vector2(_origin.x + cols * _cell, gy), COL_GRID, 1.0)
	# 格子：棋盘格淡色交替 + 水果
	for y in rows:
		for x in cols:
			var r := Rect2(_origin + Vector2(x, y) * _cell, Vector2.ONE * _cell)
			if (x + y) % 2 == 0:
				draw_rect(r, COL_CHECKER, true)
			var tex: Texture2D = _texs[FRUITS[grid[y * cols + x]]]
			if tex != null:
				var ip := _cell * 0.12
				draw_texture_rect(tex, Rect2(r.position + Vector2(ip, ip), Vector2.ONE * (_cell - ip * 2.0)), false)
	# 选择框：半透明高亮填充 + 深描边 + 外圈白线；失败时红闪（3 次）
	var sel := Rect2(_origin + Vector2(_bx, _by) * _cell, Vector2.ONE * (_cell * 2.0)).grow(-2.0)
	draw_rect(sel, COL_SEL_FILL, true)
	var lc := COL_SEL_LINE
	var lw := 4.0
	if _err_t > 0.0 and fmod(_err_t, 0.22) < 0.11:
		lc = COL_ERR
		lw = 6.0
	draw_rect(sel, lc, false, lw)
	draw_rect(sel.grow(3.0), COL_SEL_LINE2, false, 2.0)
	# 长按进度圈：按住方框未拖动时显示（金色圆弧随时间填满，满圈即提交）
	if _pressing and not _dragging and not _hold_fired:
		var k := clampf(float(Time.get_ticks_msec() - _press_ms) / float(HOLD_MS), 0.0, 1.0)
		draw_arc(sel.get_center(), _cell * 0.62, -PI * 0.5, -PI * 0.5 + TAU * k, 40,
				Color(1.0, 0.85, 0.25), maxf(_cell * 0.09, 3.0))
	# DEV 提示：金色闪烁高亮解区
	if _dev_hint_t > 0.0 and _dev_hint_cell.x >= 0:
		var hr := Rect2(_origin + Vector2(_dev_hint_cell) * _cell, Vector2.ONE * (_cell * 2.0)).grow(-4.0)
		if fmod(_dev_hint_t, 0.3) < 0.15:
			draw_rect(hr, Color(1.0, 0.85, 0.25, 0.35), true)
		draw_rect(hr, Color(1.0, 0.85, 0.25), false, 4.0)


## ===== 反馈特效 =====

## 通关金色粒子（方块粒子向上迸发后受重力洒落）
func _spawn_particles(pos: Vector2) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 40
	p.lifetime = 0.9
	p.direction = Vector2(0, -1)
	p.spread = 70.0
	p.gravity = Vector2(0, 640)
	p.initial_velocity_min = 220.0
	p.initial_velocity_max = 460.0
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.scale_amount_min = 4.0
	p.scale_amount_max = 9.0
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.85, 0.25, 1.0))
	g.set_color(1, Color(1.0, 0.55, 0.15, 0.0))
	p.color_ramp = g
	add_child(p)
	p.emitting = true
	var tw := create_tween()
	tw.tween_interval(1.4)
	tw.tween_callback(p.queue_free)


## 飘字：棋盘上方浮现，上浮淡出后自毁（可多个并发）
func _spawn_popup(text: String, col: Color) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * 0.05))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.6, m * 0.08)
	lb.position = Vector2(vp.x * 0.5 - lb.size.x * 0.5, vp.y * 0.22)
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
		for base in ["res://games/fruit_enclose/assets/sfx/", "res://assets/sfx/"]:
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
	# BGM：复用接水果的水果主题（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/fruit_enclose/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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


## ===== 开发者模式 =====
## 暗门：排行榜面板弹出后，5 秒内在面板上点击满 10 次 → 关闭排行榜后弹出调试窗口。
## 调试窗口可拖动、常驻（切关不关闭）、暂停中（排行榜弹出时）仍可操作。
## 功能：上一关 / 下一关 / 提示解区 / 自动过关 / 跳关滑块。

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
		[hud.t("dev.reveal", "Reveal"), _dev_reveal],
		[hud.t("dev.solve", "Auto Solve"), _dev_solve],
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
	_dev_win.z_index = 250   # 浮于排行榜(220)之上：切关不遮挡、不关闭
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


## 开发者按钮动作：切关保留 DEV 窗口（不随切关关闭），跳关滑块同步当前关
func _dev_goto(lv: int) -> void:
	level = clampi(lv, 1, 30)
	_busy = false
	_win_t = -1.0
	_err_t = -1.0
	_gen_level()
	if _dev_jump_sl != null and is_instance_valid(_dev_jump_sl):
		_dev_jump_sl.value = float(level)
	if _dev_jump_lb != null and is_instance_valid(_dev_jump_lb):
		_dev_jump_lb.text = str(level)


func _dev_prev() -> void:
	_dev_goto(level - 1)


func _dev_next() -> void:
	_dev_goto(level + 1)


## 提示解区：金色闪烁高亮一处匹配位置 2.5 秒
func _dev_reveal() -> void:
	var s := _find_solution()
	if s.x < 0:
		return
	_dev_hint_cell = s
	_dev_hint_t = 2.5


## 自动过关：方框移到解区并走真实提交流程（计分/音效/粒子/切关）
func _dev_solve() -> void:
	if _busy or _win_t > 0.0:
		return
	var s := _find_solution()
	if s.x < 0:
		return
	_bx = s.x
	_by = s.y
	_submit()


## 扫描棋盘找第一处与样板匹配的 2×2（生成时强制存在）
func _find_solution() -> Vector2i:
	for r in rows - 1:
		for c in cols - 1:
			if _match_at(c, r):
				return Vector2i(c, r)
	return Vector2i(-1, -1)


## 水果贴图加载：pck 内 png 未走导入流程，字节解码（双路径兼容）
func _load_textures() -> void:
	for fname: String in FRUITS:
		for base in ["res://games/fruit_enclose/assets/fruits/", "res://assets/fruits/"]:
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
