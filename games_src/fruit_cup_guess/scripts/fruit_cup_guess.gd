extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 猜水果（Fruit Cup Guess）：经典翻纸杯猜物。
## 桌面横排若干倒扣纸杯，杯下各藏一种水果；上方提示区高亮本局目标水果。
## 简单模式：开局掀杯展示全部水果并先揭晓目标 → 盖杯打乱 → 点击纸杯竞猜；
## 困难模式：先盖杯打乱、后揭晓目标（需同时记住多个杯的位置）。
## 猜中 +n（n = 剩余纸杯数 × 得分系数）；猜错 -1 且该杯丢弃（剩余 -1）；
## 只剩最后一杯（即目标杯）仍未猜中即判负，自动掀开展示后结算。
## 关卡递进：纸杯数 / 打乱次数 / 水果品种数逐关轮流 +1（3 起步，上限 7）。
## 总分累计，复用合集存档（GameHud submit_score/commit_score）。

const GameHud := preload("res://scripts/game_hud.gd")

# —— 可配置核心参数 ——
const FRUITS_POOL := ["apple", "banana", "carrot", "grape", "orange",
		"peach", "pear", "Pineapple", "strawberry", "watermelon"]
const CUPS_START := 3            # 初始纸杯数（第 1 关）
const CUPS_MAX := 5              # 纸杯数上限
const SHUFFLES_START := 3        # 初始每局交换次数
const SHUFFLES_MAX := 7
const SCORE_FACTOR := 1.0        # 猜中得分 = 剩余纸杯数 × SCORE_FACTOR
const WRONG_PENALTY := 1         # 猜错扣分
const SEC := "fruit_cup_guess"   # settings.cfg 模式持久化节名

# —— 动画节奏（s）——
const DEAL_TIME := 0.45          # 纸杯入场（错峰落下）
const SHOW_TIME := 1.75          # 开局掀杯展示保持
const FLIP_TIME := 0.42          # 掀杯 / 盖杯单程
const SLIDE_TIME := 0.42         # 单次交换滑动
const SWAP_PAUSE := 0.16         # 两次交换间隔
const REVEAL_TIME := 0.85        # 困难模式打乱后揭晓目标停顿
const RESULT_HOLD := 1.05        # 猜中后金色闪光展示
const DISCARD_TIME := 0.50       # 猜错纸杯丢弃动画
const LOSE_DELAY := 0.55         # 全部纸杯耗尽到失败弹窗延迟
const FLIP_LIFT_K := 0.72        # 掀杯抬起高度 = 杯高 × 系数
const BOWL_SINK_K := 0.06        # 碗贴图/水果下沉比例（底缘扣进桌面横带，可微调）

const SFX_POOL := 4
const BGM_DB := -6.0
const SFX_DB := -4.0

# 配色（扁平卡通，同围住水果；无背景面板，透出启动器壁纸）
const COL_PANEL_BORDER := Color(0.30, 0.23, 0.18)    # 深棕描边
const COL_TABLE := Color(0.90, 0.79, 0.60)           # 桌面横带
const COL_GOLD := Color(1.0, 0.85, 0.25)
const COL_ERR := Color(0.92, 0.30, 0.22)
const COL_GRAY := Color(0.55, 0.55, 0.60)
const COL_FLOAT_OK := Color(0.16, 0.55, 0.18)
# 纸杯染色（modulate 乘白底杯贴图，最多 7 只）
const CUP_TINTS := [
	Color(0.90, 0.30, 0.26),   # 红
	Color(0.96, 0.72, 0.20),   # 黄
	Color(0.28, 0.68, 0.70),   # 青
	Color(0.45, 0.75, 0.35),   # 绿
	Color(0.35, 0.55, 0.88),   # 蓝
	Color(0.95, 0.55, 0.22),   # 橙
	Color(0.75, 0.45, 0.80),   # 紫
]

var hud: RefCounted
var mode := "easy"               # easy：先揭晓目标再打乱 / hard：先打乱后揭晓
var level := 1                   # 当前关卡
var total := 0                   # 本局累计总分（跨关卡）
var round_score := 0             # 本局得分增量（弹窗显示）
var cups_left := 0               # 剩余纸杯数（猜错 -1）
var target_kind := ""            # 目标水果品种
var _hint_shown := false         # 提示区是否已揭晓目标
var _hint_pop := 1.0             # 揭晓弹跳动画 0..1
var _n_cups := CUPS_START
var _shuffles := SHUFFLES_START
var _cups: Array[Dictionary] = []   # {slot,fruit,tint,x,lift,rot,alpha,tilt,open,anim,t,delay,from_x,dir}
var _phase := "idle"             # deal/show/close/shuffle/reveal/guess/flip/result/discard/losewait/idle
var _phase_t := 0.0
var _swaps_left := 0
var _swap_a := -1                # 滑动中的两杯下标（-1 = 无）
var _swap_b := -1
var _swap_pause_t := 0.0
var _last_pair := [-1, -1]
var _moved := {}                 # 打乱中已移动过的杯下标（保证目标杯至少移动一次）
var _guess_i := -1               # 正在掀开/结果展示的杯下标
var _floats: Array[Dictionary] = []  # {txt,col,pos,t}
var _committed := false          # 本局总分是否已入榜
var _popup: Control = null
var _alive_t := 0.0              # 脉冲动画计时

var _vp := Vector2(1920, 1080)
var _panel := Rect2()            # 场地面板
var _hint_rect := Rect2()        # 目标提示区
var _cup_w := 140.0
var _cup_h := 165.0
var _fruit_sz := 110.0
var _pitch := 210.0
var _table_y := 900.0
var _tex_cup: Texture2D
var _fruit_texs := {}            # 品种名 → Texture2D
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _hbox: HBoxContainer
var _top_left: HBoxContainer
var _mode_opt: OptionButton
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
	hud = GameHud.new("fruit_cup_guess")
	_load_mode()
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_setup_buttons()
	_layout()
	_init_sfx()
	_new_run()


func stop() -> void:
	get_tree().paused = false
	if _bgm != null:
		_bgm.stop()
	if not _committed and total > 0:   # 中途退出视作本局结束
		_commit_run()
	print("[fruit_cup_guess] stop, level=%d total=%d best=%d" % [level, total, hud.max_score])


## ===== 关卡参数：每关仅一项 +1，按 纸杯 → 打乱 轮流递进（3 起步，纸杯封顶 5、打乱封顶 7）=====
## 水果品种数恒等于纸杯数（全部唯一，用户定），不再单独递进

func _params_for_level(lv: int) -> Dictionary:
	var cups := CUPS_START
	var shuffles := SHUFFLES_START
	for s in lv - 1:
		for k in 2:   # 该步轮到的项封顶则顺延到下一项
			var idx: int = (s + k) % 2
			if idx == 0 and cups < CUPS_MAX:
				cups += 1
				break
			elif idx == 1 and shuffles < SHUFFLES_MAX:
				shuffles += 1
				break
	return {"cups": cups, "shuffles": shuffles}


## ===== 回合构建 =====

func _new_run() -> void:
	level = 1
	total = 0
	_committed = false
	_new_round()


func _new_round() -> void:
	_close_popup()
	var prm := _params_for_level(level)
	_n_cups = int(prm["cups"])
	_shuffles = int(prm["shuffles"])
	round_score = 0
	cups_left = _n_cups
	# 水果分配：品种数 = 杯数，全部唯一（随机抽取即洗牌）
	var kinds := FRUITS_POOL.duplicate()
	kinds.shuffle()
	kinds = kinds.slice(0, _n_cups)
	var bag: Array = kinds
	var tint: Color = CUP_TINTS[(level - 1) % CUP_TINTS.size()]   # 每关全杯同色，按关卡轮换
	_cups.clear()
	_floats.clear()
	target_kind = kinds[randi() % kinds.size()]
	_hint_shown = mode == "easy"
	_hint_pop = 1.0 if _hint_shown else 0.0
	for i in _n_cups:
		_cups.append({
			"slot": i, "fruit": bag[i], "tint": tint,
			"x": 0.0, "lift": 0.0, "rot": 0.0, "alpha": 1.0,
			"tilt": 0.26 if i % 2 == 0 else -0.26, "open": false,
			"anim": "", "t": 0.0, "delay": 0.0, "from_x": 0.0, "dir": 0.0,
		})
	_layout()
	for c in _cups:   # 入场：从上方错峰落下
		c["x"] = _slot_x(int(c["slot"]))
		c["lift"] = _cup_h * 2.4
		c["delay"] = float(int(c["slot"])) * 0.07
		c["anim"] = "deal"
		c["t"] = 0.0
	_phase = "deal"
	_phase_t = 0.0
	_swaps_left = 0
	_swap_a = -1
	_swap_b = -1
	_guess_i = -1
	_last_pair = [-1, -1]
	_moved.clear()
	_refresh_hud()
	queue_redraw()


## ===== 主循环 =====

func _process(delta: float) -> void:
	_alive_t += delta
	for c in _cups:
		_advance_cup(c, delta)
	for f in _floats.duplicate():
		var t: float = f["t"] + delta / 0.9
		if t >= 1.0:
			_floats.erase(f)
		else:
			f["t"] = t
	match _phase:
		"deal":
			if _all_idle():
				_start_show()
		"show":
			_phase_t += delta
			if _phase_t >= SHOW_TIME:
				_start_close()
		"close":
			if _all_idle():
				_start_shuffle()
		"shuffle":
			_advance_shuffle(delta)
		"reveal":
			_phase_t += delta
			_hint_pop = minf(_phase_t / 0.35, 1.0)
			if _phase_t >= REVEAL_TIME:
				_start_guess()
		"flip":
			var c: Dictionary = _cups[_guess_i]
			if String(c["anim"]) == "":
				_resolve_guess()
		"result":
			_phase_t += delta
			if _phase_t >= RESULT_HOLD:
				_show_win_popup()
		"discard":
			if _all_idle():
				if cups_left <= 1:   # 只剩最后一杯（目标杯）：判负，掀开展示后结算
					_reveal_last_target()
					_phase = "losewait"
					_phase_t = 0.0
				else:
					_phase = "guess"
		"losewait":
			_phase_t += delta
			if _phase_t >= LOSE_DELAY:
				_show_lose_popup()
	queue_redraw()


func _advance_cup(c: Dictionary, delta: float) -> void:
	var anim: String = c["anim"]
	if anim == "":
		return
	var t: float = float(c["t"]) + delta
	c["t"] = t
	match anim:
		"deal":
			var k: float = clampf((t - float(c["delay"])) / DEAL_TIME, 0.0, 1.0)
			c["lift"] = _cup_h * 2.4 * (1.0 - _bounce_out(k))
			if k >= 1.0:
				c["anim"] = ""
				c["lift"] = 0.0
		"flipup":
			var k: float = clampf(t / FLIP_TIME, 0.0, 1.0)
			c["lift"] = FLIP_LIFT_K * _cup_h * k
			c["rot"] = float(c["tilt"]) * k
			if k >= 1.0:
				c["anim"] = ""
				c["open"] = true
		"flipdown":
			var k: float = clampf(t / FLIP_TIME, 0.0, 1.0)
			c["lift"] = FLIP_LIFT_K * _cup_h * (1.0 - k)
			c["rot"] = float(c["tilt"]) * (1.0 - k)
			if k >= 1.0:
				c["anim"] = ""
				c["open"] = false
				c["rot"] = 0.0
		"slide":
			var k: float = clampf(t / SLIDE_TIME, 0.0, 1.0)
			var tx: float = _slot_x(int(c["slot"]))
			c["x"] = lerpf(float(c["from_x"]), tx, ease(k, -1.6))
			c["lift"] = sin(k * PI) * _cup_h * 0.30
			c["rot"] = float(c["dir"]) * 0.15 * sin(k * PI)
			if k >= 1.0:
				c["anim"] = ""
				c["x"] = tx
				c["lift"] = 0.0
				c["rot"] = 0.0
		"discard":
			var k: float = clampf(t / DISCARD_TIME, 0.0, 1.0)
			c["alpha"] = 1.0 - k
			c["x"] = float(c["from_x"]) + float(c["dir"]) * 150.0 * k * k
			c["lift"] = k * 55.0
			c["rot"] = float(c["dir"]) * 0.35 * k
			if k >= 1.0:
				c["anim"] = ""


func _all_idle() -> bool:
	for c in _cups:
		if String(c["anim"]) != "":
			return false
	return true


## ===== 阶段推进 =====

func _start_show() -> void:
	_phase = "show"
	_phase_t = 0.0
	for c in _cups:
		c["anim"] = "flipup"
		c["t"] = 0.0
	_play_sfx("flip")


func _start_close() -> void:
	_phase = "close"
	_phase_t = 0.0
	for c in _cups:
		c["anim"] = "flipdown"
		c["t"] = 0.0
	_play_sfx("flip")


func _start_shuffle() -> void:
	_phase = "shuffle"
	_phase_t = 0.0
	_swaps_left = _shuffles
	_swap_a = -1
	_swap_b = -1
	_moved.clear()
	_swap_pause_t = 0.35   # 起手节拍


func _advance_shuffle(delta: float) -> void:
	if _swap_a >= 0:
		if String(_cups[_swap_a]["anim"]) == "" and String(_cups[_swap_b]["anim"]) == "":
			_swap_a = -1
			_swap_b = -1
			_swaps_left -= 1
			_swap_pause_t = SWAP_PAUSE
		return
	if _swaps_left <= 0:
		if mode == "hard":
			_start_reveal()
		else:
			_start_guess()
		return
	_swap_pause_t -= delta
	if _swap_pause_t <= 0.0:
		_next_swap()


func _next_swap() -> void:
	var n := _cups.size()
	var a := -1
	var b := -1
	var b_forced := false
	# 目标杯（藏目标水果的杯）至少移动一次：剩余交换次数刚够时强制带上未动过的目标杯
	var unmoved_t: Array = []
	for i in n:
		if not _moved.has(i) and String(_cups[i]["fruit"]) == target_kind:
			unmoved_t.append(i)
	if unmoved_t.size() >= 2 and _swaps_left <= 1:
		a = unmoved_t[0]   # 只剩最后一次交换：两只未动目标杯互换，一次全动
		b = unmoved_t[1]
		b_forced = true
	elif not unmoved_t.is_empty() and _swaps_left <= unmoved_t.size():
		a = unmoved_t[0]   # 强制一只未动目标杯参与本次交换
	if a >= 0 and not b_forced:
		for attempt in 10:
			b = randi() % n
			if b == a:
				continue
			if [a, b] == _last_pair or [b, a] == _last_pair:
				continue
			break
		if b == a or b < 0:   # 兜底：相邻杯
			b = (a + 1) % n
	else:
		for attempt in 10:
			a = randi() % n
			b = randi() % n
			if a == b:
				continue
			if [a, b] == _last_pair or [b, a] == _last_pair:
				continue
			break
		if a == b or a < 0:   # 兜底：相邻两杯
			a = randi() % n
			b = (a + 1) % n
	_moved[a] = true
	_moved[b] = true
	_last_pair = [a, b]
	var ca: Dictionary = _cups[a]
	var cb: Dictionary = _cups[b]
	var tmp: int = int(ca["slot"])
	ca["slot"] = int(cb["slot"])
	cb["slot"] = tmp
	for c: Dictionary in [ca, cb]:
		c["anim"] = "slide"
		c["t"] = 0.0
		c["from_x"] = float(c["x"])
		c["dir"] = signf(_slot_x(int(c["slot"])) - float(c["x"]))
	_swap_a = a
	_swap_b = b
	_play_sfx("slide")


func _start_reveal() -> void:
	_phase = "reveal"
	_phase_t = 0.0
	_hint_shown = true
	_hint_pop = 0.0
	_play_sfx("flip")


func _start_guess() -> void:
	_phase = "guess"
	_phase_t = 0.0


func _guess(i: int) -> void:
	if _phase != "guess":
		return
	var c: Dictionary = _cups[i]
	if String(c["anim"]) != "" or bool(c["open"]) or float(c["alpha"]) < 1.0:
		return
	_guess_i = i
	c["anim"] = "flipup"
	c["t"] = 0.0
	_phase = "flip"
	_play_sfx("flip")


func _resolve_guess() -> void:
	var c: Dictionary = _cups[_guess_i]
	c["open"] = true
	var fpos := Vector2(float(c["x"]), _table_y - _fruit_sz * 0.5)
	if String(c["fruit"]) == target_kind:
		var gained := int(round(float(cups_left) * SCORE_FACTOR))
		total += gained
		round_score += gained
		_phase = "result"
		_phase_t = 0.0
		_play_sfx("correct")
		_spawn_burst(fpos, COL_GOLD, 30, 340.0)
		_spawn_float("+%d" % gained, COL_FLOAT_OK, fpos)
		_refresh_hud()
	else:
		total -= WRONG_PENALTY
		round_score -= WRONG_PENALTY
		cups_left -= 1
		c["anim"] = "discard"
		c["t"] = 0.0
		c["from_x"] = float(c["x"])
		c["dir"] = -1.0 if float(c["x"]) < _vp.x * 0.5 else 1.0
		_phase = "discard"
		_play_sfx("wrong")
		_spawn_burst(fpos, COL_GRAY, 20, 240.0)
		_spawn_float("-%d" % WRONG_PENALTY, COL_ERR, fpos)
		_refresh_hud()


## 败局展示：掀开最后剩下的目标杯（让玩家看到目标在哪），随后弹失败结算
func _reveal_last_target() -> void:
	for c in _cups:
		if String(c["anim"]) == "" and not bool(c["open"]) and float(c["alpha"]) >= 1.0:
			c["anim"] = "flipup"
			c["t"] = 0.0
			_play_sfx("flip")


## ===== 结算 =====

func _commit_run() -> void:
	if _committed:
		return
	hud.submit_score(total)
	hud.commit_score()
	_committed = true


func _show_win_popup() -> void:
	_phase = "idle"
	get_tree().paused = true
	_play_sfx("win")
	_popup = _make_popup_base()
	var vb: VBoxContainer = _popup.get_child(0)
	_add_popup_label(vb, hud.t("popup.win_title", "Found it!"),
			Color(1.0, 0.85, 0.25), 0.055)
	_add_popup_label(vb, "%s      %s" % [
				hud.t("popup.round_gain", "Round score +%d") % round_score,
				hud.t("popup.total", "Total %d") % total], Color.WHITE, 0.032)
	var row := _add_popup_row(vb)
	_add_popup_btn(row, hud.t("popup.replay", "Play Again"), _on_replay_round)
	_add_popup_btn(row, hud.t("popup.next", "Next Level"), _on_next_level)
	_finish_popup()


func _show_lose_popup() -> void:
	_phase = "idle"
	_commit_run()
	get_tree().paused = true
	_play_sfx("lose")
	_popup = _make_popup_base()
	var vb: VBoxContainer = _popup.get_child(0)
	_add_popup_label(vb, hud.t("popup.lose_title", "Not This Time"),
			Color(0.95, 0.55, 0.40), 0.055)
	_add_popup_label(vb, "%s      %s" % [
				hud.t("popup.round_score", "Round score %d") % round_score,
				hud.t("popup.total", "Total %d") % total], Color.WHITE, 0.032)
	var row := _add_popup_row(vb)
	_add_popup_btn(row, hud.t("popup.replay", "Play Again"), _on_new_run)
	_finish_popup()


## 结算弹窗基底：深色半透明圆角面板（同合集样式），返回面板（child(0) 为 VBox）
func _make_popup_base() -> PanelContainer:
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
	return panel


func _add_popup_label(vb: VBoxContainer, txt: String, col: Color, fs_k: float) -> void:
	var m := minf(_vp.x, _vp.y)
	var lb := Label.new()
	lb.text = txt
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(m * fs_k))
	GameHud._style_label(lb, col)
	vb.add_child(lb)


func _add_popup_row(vb: VBoxContainer) -> HBoxContainer:
	var m := minf(_vp.x, _vp.y)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(row)
	return row


func _add_popup_btn(row: HBoxContainer, txt: String, cb: Callable) -> void:
	var m := minf(_vp.x, _vp.y)
	var b := GameHud.make_button(txt)
	b.add_theme_font_size_override("font_size", int(m * 0.034))
	b.pressed.connect(cb)
	row.add_child(b)


func _finish_popup() -> void:
	add_child(_popup)
	_popup.z_index = 200
	_popup.reset_size()
	_popup.position = (_vp - _popup.size) * 0.5


func _close_popup() -> void:
	get_tree().paused = false
	if _popup != null:
		_popup.queue_free()
		_popup = null


func _on_replay_round() -> void:   # 胜利弹窗：重玩本关（总分保留）
	_close_popup()
	_new_round()


func _on_next_level() -> void:     # 胜利弹窗：下一关
	level += 1
	_new_round()


func _on_new_run() -> void:        # 失败弹窗：重新开始（新的一局）
	_close_popup()
	_new_run()


## ===== 输入 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and _phase == "guess":
		_click_pick(event.position)


func _click_pick(pos: Vector2) -> void:
	for i in _cups.size():
		var c: Dictionary = _cups[i]
		if String(c["anim"]) != "" or bool(c["open"]) or float(c["alpha"]) < 1.0:
			continue
		var r := Rect2(float(c["x"]) - _cup_w * 0.55, _table_y - _cup_h * 1.15,
				_cup_w * 1.1, _cup_h * 1.15)
		if r.has_point(pos):   # 杯宽 1.1 < 间距 1.5 不重叠，命中即选
			_guess(i)
			return


func _exit_button_pressed() -> void:
	exit_requested.emit()


func _restart() -> void:
	if not _committed and total > 0:   # 重开视作本局结束（合集惯例）
		_commit_run()
	_new_run()


## ===== 布局 =====

func _layout() -> void:
	_vp = get_viewport_rect().size
	var m := minf(_vp.x, _vp.y)
	_panel = Rect2(24.0, 84.0, maxf(_vp.x - 48.0, 60.0), maxf(_vp.y - 108.0, 60.0))
	_table_y = _panel.position.y + _panel.size.y - m * 0.085
	var n := maxi(_n_cups, 1)
	_cup_w = clampf((_panel.size.x - 90.0) / (float(n) * 1.5), 80.0, 180.0)
	_cup_h = _cup_w * 1.18
	_fruit_sz = _cup_w * 0.80
	_pitch = _cup_w * 1.5
	var hw := minf(520.0, _panel.size.x * 0.42)
	_hint_rect = Rect2(_vp.x * 0.5 - hw * 0.5, _panel.position.y + m * 0.018, hw, m * 0.088)
	for c in _cups:
		if String(c["anim"]) != "slide":
			c["x"] = _slot_x(int(c["slot"]))
	for b: Label in [_level_board, _score_board]:
		b.custom_minimum_size = Vector2(200.0, m * 0.051)
		b.add_theme_font_size_override("font_size", int(m * 0.035))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((_vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(_vp.x - _hbox.size.x - 20.0, 14.0)
	if _top_left != null:
		_top_left.reset_size()
		_top_left.position = Vector2(20.0, 14.0)
	_refresh_hud()
	queue_redraw()


func _slot_x(slot: int) -> float:
	return _vp.x * 0.5 + (float(slot) - float(_n_cups - 1) * 0.5) * _pitch


func _refresh_hud() -> void:
	_level_board.text = hud.t("hud.level", "Level %d") % level
	_score_board.text = hud.t("hud.score", "Score %d") % total


## ===== 顶部按钮 =====

## 右上角按钮排（HBox 容器）：排行榜 + 重开 + BGM + 音量 + ✕（tscn 已有）；模式下拉在左上角
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()   # tscn 节点迁入容器（原父为游戏根）
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_mode_opt = _make_option()
	_mode_opt.add_item(hud.t("mode.easy", "Easy"))
	_mode_opt.add_item(hud.t("mode.hard", "Hard"))
	_mode_opt.selected = 0 if mode == "easy" else 1
	_mode_opt.item_selected.connect(_on_mode_selected)
	# 左上角按钮组：模式下拉框（2026-10-10 用户定，避开右上 ✕ 列）
	_top_left = HBoxContainer.new()
	_top_left.name = "TopLeft"
	_top_left.add_theme_constant_override("separation", -8)
	add_child(_top_left)
	_top_left.process_mode = Node.PROCESS_MODE_ALWAYS
	_top_left.add_child(_mode_opt)
	_mode_opt.custom_minimum_size = Vector2(56.0, 56.0)
	_mode_opt.size_flags_vertical = Control.SIZE_SHRINK_END
	_mode_opt.add_theme_constant_override("icon_max_width", 32)
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")

	# 最小化钮（关闭钮左侧）：点击最小化窗口（桌面 Win/Linux）
	var min_btn := GameHud.make_button("")
	min_btn.icon = hud.ui_icon("minimize.png")
	min_btn.custom_minimum_size = Vector2(56.0, 56.0)
	min_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	min_btn.add_theme_constant_override("icon_max_width", 32)
	min_btn.pressed.connect(func() -> void: get_window().mode = Window.MODE_MINIMIZED)
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Control in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, min_btn, _exit_btn]:
		_hbox.add_child(b)
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.add_theme_constant_override("icon_max_width", 32)
	_mode_opt.add_theme_font_size_override("font_size", 22)
	_lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_restart)
	_bgm_btn.pressed.connect(_on_bgm)
	_volume_btn.pressed.connect(_on_volume)


## 模式下拉框：样式同方块拼图（深色半透明圆角 + 白字黑描边）
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
	var new_mode := "easy" if i == 0 else "hard"
	if new_mode == mode:
		return
	mode = new_mode
	_save_mode()
	_new_round()   # 切换模式重开本关（关卡与总分保留）


func _load_mode() -> void:
	var cf := ConfigFile.new()
	if cf.load(GameHud.CFG_PATH) == OK:
		mode = String(cf.get_value(SEC, "mode", "easy"))
	if mode != "easy" and mode != "hard":
		mode = "easy"


func _save_mode() -> void:
	var cf := ConfigFile.new()
	cf.load(GameHud.CFG_PATH)
	cf.set_value(SEC, "mode", mode)
	cf.save(GameHud.CFG_PATH)


func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("ui.top10", "Leaderboard"), -1, -1)


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


## ===== 绘制 =====

func _draw() -> void:
	# 无背景：不画面板填充，直接透出启动器壁纸（_panel 仅作布局矩形）
	# 桌面横带 + 上沿线
	var band := Rect2(_panel.position.x + 4.0, _table_y,
			_panel.size.x - 8.0, _panel.position.y + _panel.size.y - _table_y - 4.0)
	draw_rect(band, COL_TABLE, true)
	draw_line(Vector2(band.position.x, _table_y),
			Vector2(band.position.x + band.size.x, _table_y), COL_PANEL_BORDER, 3.0)
	_draw_hint()
	# 纸杯与水果：水果先画（杯下），滑动中的杯最后画（视觉在前）
	var order: Array = _cups.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa: int = 1 if String(a["anim"]) == "slide" else 0
		var sb2: int = 1 if String(b["anim"]) == "slide" else 0
		if sa != sb2:
			return sa < sb2
		return int(a["slot"]) < int(b["slot"]))
	for c: Dictionary in order:
		_draw_cup(c)
	# 漂浮文字
	for f in _floats:
		_draw_float(f)


## 目标提示区：金色脉冲描边 + 水果图标；未揭晓时灰色问号
func _draw_hint() -> void:
	var r := _hint_rect
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.55)
	sb.set_corner_radius_all(14)
	draw_style_box(sb, r)
	if _hint_shown:
		var pop := _hint_pop
		var pulse := 0.55 + 0.35 * sin(_alive_t * 4.0)
		var gsb := StyleBoxFlat.new()
		gsb.bg_color = Color(0, 0, 0, 0)
		gsb.border_color = Color(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b,
				clampf(pulse + 0.2 * (1.0 - pop), 0.0, 1.0))
		gsb.set_border_width_all(4)
		gsb.set_corner_radius_all(14)
		var gr := Rect2(r.position + (Vector2.ONE * (1.0 - _ease_out_back(pop)) * r.size * 0.5),
				r.size * _ease_out_back(pop))
		draw_style_box(gsb, gr)
		var icon_sz := r.size.y * 0.62
		var tex: Texture2D = _fruit_texs.get(target_kind)
		if tex != null:
			var ipos := r.position + Vector2(r.size.x * 0.30 - icon_sz * 0.5,
					(r.size.y - icon_sz) * 0.5)
			draw_texture_rect(tex, Rect2(ipos, Vector2.ONE * icon_sz), false)
		var font := ThemeDB.fallback_font
		var fs := int(r.size.y * 0.30)
		var tpos := r.position + Vector2(r.size.x * 0.46, r.size.y * 0.5 + fs * 0.36)
		draw_string_outline(font, tpos, hud.t("hint.target", "Target Fruit"),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 6, Color(0, 0, 0, 0.25))
		draw_string(font, tpos, hud.t("hint.target", "Target Fruit"),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_PANEL_BORDER)
	else:
		var font := ThemeDB.fallback_font
		var fs := int(r.size.y * 0.56)
		draw_string(font, r.position + Vector2(r.size.x * 0.5 - fs * 0.28,
				r.size.y * 0.5 + fs * 0.36), "?",
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_GRAY)


func _draw_cup(c: Dictionary) -> void:
	var alpha: float = float(c["alpha"])
	if alpha <= 0.01:
		return
	var x := float(c["x"])
	var lift := float(c["lift"])
	# 影子（贴桌面，随抬升缩小变淡）
	var sh_k := clampf(lift / maxf(_cup_h, 1.0), 0.0, 1.0)
	var shr := _cup_w * 0.46 * (1.0 - 0.30 * sh_k)
	draw_set_transform(Vector2(x, _table_y), 0.0, Vector2(1.0, 0.26))
	draw_circle(Vector2.ZERO, shr,
			Color(0.12, 0.09, 0.05, 0.16 * alpha * (1.0 - 0.5 * sh_k)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 水果（杯下，随杯移动；结果展示时轻弹跳）
	var fruit_vis := false
	var fa := alpha
	var anim: String = c["anim"]
	if anim == "flipup":
		fruit_vis = float(c["t"]) > FLIP_TIME * 0.45
	elif anim == "flipdown":
		fruit_vis = float(c["t"]) < FLIP_TIME * 0.55
	elif anim == "discard":
		fruit_vis = true
		fa = alpha
	elif bool(c["open"]):
		fruit_vis = true
	if fruit_vis:
		var tex: Texture2D = _fruit_texs.get(String(c["fruit"]))
		if tex != null:
			var fsz := _fruit_sz
			if _phase == "result" and _guess_i >= 0 and _cups[_guess_i] == c:
				fsz *= 1.0 + 0.10 * sin(_alive_t * 9.0)
			var fpos := Vector2(x - fsz * 0.5, _table_y - fsz + _cup_h * BOWL_SINK_K)
			draw_texture_rect(tex, Rect2(fpos, Vector2.ONE * fsz), false,
					Color(1, 1, 1, fa))
	# 杯体（底边中心锚点，绕其旋转/位移；下沉 BOWL_SINK_K 扣进桌面横带）
	var tint: Color = c["tint"]
	if _tex_cup != null:
		var pivot := Vector2(x, _table_y - lift)
		draw_set_transform(pivot, float(c["rot"]), Vector2.ONE)
		draw_texture_rect(_tex_cup,
				Rect2(Vector2(-_cup_w * 0.5, -_cup_h + _cup_h * BOWL_SINK_K),
						Vector2(_cup_w, _cup_h)),
				false, Color(tint.r, tint.g, tint.b, alpha))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_float(f: Dictionary) -> void:
	var t: float = f["t"]
	var font := ThemeDB.fallback_font
	var fs := int(_cup_w * 0.34)
	var p: Vector2 = f["pos"] + Vector2(-80.0, -60.0 * t)
	var col: Color = f["col"]
	var a := 1.0 - t * t
	draw_string_outline(font, p, String(f["txt"]), HORIZONTAL_ALIGNMENT_CENTER,
			160, fs, 7, Color(0, 0, 0, 0.7 * a))
	draw_string(font, p, String(f["txt"]), HORIZONTAL_ALIGNMENT_CENTER,
			160, fs, Color(col.r, col.g, col.b, a))


## ===== 特效 =====

func _spawn_burst(pos: Vector2, col: Color, amount: int, speed: float) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = 0.8
	p.direction = Vector2(0, -1)
	p.spread = 75.0
	p.gravity = Vector2(0, 640)
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
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


func _spawn_float(txt: String, col: Color, pos: Vector2) -> void:
	_floats.append({"txt": txt, "col": col, "pos": pos, "t": 0.0})


## ===== 贴图与音效 =====

func _load_textures() -> void:
	_tex_cup = _load_png("assets/cup.png")
	for kind: String in FRUITS_POOL:
		_fruit_texs[kind] = _load_png("assets/fruits/%s.png" % kind)


## pck 内 png 字节解码（不走导入流程）；双路径兼容编辑器直跑
func _load_png(rel: String) -> Texture2D:
	for base in ["res://games/fruit_cup_guess/", "res://"]:
		var f := FileAccess.open(base + rel, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
			return null
	return null


## pck 内音频走字节解码，编辑器预览走导入资源（双路径）
func _init_sfx() -> void:
	var files := {"slide": "slide.wav", "flip": "flip.wav", "correct": "correct.wav",
			"wrong": "wrong.wav", "win": "win.wav", "lose": "lose.wav"}
	for sname: String in files:
		for base in ["res://games/fruit_cup_guess/assets/sfx/", "res://assets/sfx/"]:
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
		p.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（结算弹窗）仍播结算音效
		add_child(p)
		_sfx_players.append(p)
	# BGM：复用合集 BGM（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/fruit_cup_guess/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
		var bf := FileAccess.open(base, FileAccess.READ)
		if bf != null:
			var st := AudioStreamMP3.load_from_buffer(bf.get_buffer(bf.get_length()))
			st.loop = true
			_bgm = AudioStreamPlayer.new()
			_bgm.stream = st
			_bgm.volume_db = BGM_DB
			_bgm.process_mode = Node.PROCESS_MODE_ALWAYS   # 结算弹窗暂停中 BGM 连续不停
			add_child(_bgm)
			if hud.bgm_on:
				_bgm.play()
			break


## 播放音效：从池中取空闲播放器
func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx_streams.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


## ===== 缓动辅助 =====

## easeOutBounce（入场落地弹跳）
func _bounce_out(t: float) -> float:
	var n1 := 7.5625
	var d1 := 1.0
	if t < 1.0 / 2.75:
		return n1 * t * t
	if t < 2.0 / 2.75:
		var t2 := t - 1.5 / 2.75
		return n1 * t2 * t2 + 0.75
	if t < 2.5 / 2.75:
		var t3 := t - 2.25 / 2.75
		return n1 * t3 * t3 + 0.9375
	var t4 := t - 2.625 / 2.75
	return n1 * t4 * t4 + 0.984375


## easeOutBack（揭晓弹跳，轻微过冲）
func _ease_out_back(t: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	var k := clampf(t, 0.0, 1.0)
	return 1.0 + c3 * pow(k - 1.0, 3.0) + c1 * pow(k - 1.0, 2.0)
