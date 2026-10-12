extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 拼人脸 Face Puzzle：随机原画展示 5 秒 → 五官淡出 → 从器官面板选件拼回轮廓 → "完成"评分
## 匹配度 = 各器官槽位（种类/款式/位置/方向/左右配对）加权得分 - 画布外杂件扣分
## 结算弹窗：继续游戏（保留拼画可继续微调）/ 再来一局（清空开新脸）
## 素材：assets/faces/ 部件 PNG（launcher/tools/gen_face_puzzle_assets.gd 生成）
## BGM: 复用合集 Fruit_Cup_Guess 曲目；音效程序化合成（tick/pick/place/cancel/submit/win/miss）

const GameHud := preload("res://scripts/game_hud.gd")

const SFX_POOL := 4
const MEMORIZE_T := 5.0        # 观察记忆时长（s）
const FADE_T := 0.5            # 单件淡出时长
const FADE_STAGGER := 0.07     # 逐件淡出间隔
const BGM_DB := -6.0
const SFX_DB := -4.0
const TOPBAR_H := 84.0         # 顶栏保留高度

# —— 与 gen_face_puzzle_assets.gd 保持同步（构型基准）——
const CATS := ["hat", "hair", "glass", "brow", "beard", "eye", "nose", "ear", "mouth"]   # 面板顺序：按原画层级 ORIG_Z 从高到低
const ORIG_Z := {"hat": 8, "hair": 7, "glass": 6, "brow": 5, "beard": 4, "eye": 3, "nose": 2, "ear": 1, "mouth": 0}   # 原画部件层级：帽>发>镜>眉>胡>眼>鼻>耳>嘴
const CAT_N := {"hair": 6, "hat": 5, "brow": 4, "eye": 7, "glass": 4, "ear": 4, "nose": 7, "mouth": 7, "beard": 6}
const PAIRED := {"brow": true, "eye": true, "ear": true}
const REGION_BASE := {
	"hair": {"off": Vector2(0.0, -0.44), "r": 0.155},
	"hat": {"off": Vector2(0.0, -0.50), "r": 0.155},   # 与 hair 互斥；帽中心上移 0.06 减少露光头
	"ear": {"off": Vector2(0.53, 0.05), "r": 0.10},
	"brow": {"off": Vector2(-0.225, -0.155), "r": 0.115},
	"eye": {"off": Vector2(-0.215, 0.0), "r": 0.12},
	"glass": {"off": Vector2(0.0, 0.0), "r": 0.12},    # 鼻梁（镜片中心对齐两眼）
	"nose": {"off": Vector2(0.0, 0.155), "r": 0.105},
	"mouth": {"off": Vector2(0.0, 0.335), "r": 0.115},
	"beard": {"off": Vector2(0.0, 0.455), "r": 0.125},
}
const PART_SCALE := {
	"hair": {"w": 1.0}, "hat": {"w": 1.12}, "brow": {"w": 0.333}, "eye": {"w": 0.333},
	"glass": {"w": 0.75}, "ear": {"h": 0.3125}, "nose": {"h": 0.29}, "mouth": {"w": 0.4167}, "beard": {"w": 0.542},
}
const SLOT_WEIGHT := {"eye": 1.5, "brow": 1.2, "ear": 0.9, "nose": 1.0, "mouth": 1.3, "hair": 1.8, "hat": 1.8, "glass": 1.2, "beard": 1.0}
const W_CAT := 0.30   # 槽位内：种类对
const W_VAR := 0.35   # 款式对
const W_POS := 0.20   # 位置接近
const W_ROT := 0.15   # 方向接近
const EXTRA_PENALTY := 2.0   # 每个落不进区域的杂件扣分（百分点）
const ROT_TOL := PI / 4.0    # 方向满分容差
const PART_Z := 10           # 已放件基础层级
const SCALE_MIN := 0.5       # 微调滑条缩放范围
const SCALE_MAX := 1.6

enum State { MEMORIZE, FADE, BUILD, RESULT }

var hud: RefCounted

@onready var _best_board: Label = $HudBar/BestBoard
@onready var _parts_board: Label = $HudBar/PartsBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.MEMORIZE
var _recipe: Dictionary
var _slots: Array = []          # 原画槽位 [{key, cat, side, idx, rot}]

var _face_c := Vector2.ZERO     # 脸部中心（画布坐标）
var _face_f := 400.0            # 脸显示尺寸（px）
var _outline_sp: Sprite2D
var _orig_root: Node2D          # 记忆阶段原画部件（整体淡出）
var _ghost_root: Node2D         # 结算对比：原画半透明重影
var _placed: Array = []         # 已放置 [{cat, idx, side, local: Vector2, rot, region: String, sp}]
var _hand := {}                 # 手持 {cat, idx}
var _hand_sp: Sprite2D
var _sel := {}                  # 微调模式选中件（同 _placed 条目）
var _dial_drag := false
var _move_drag := false

var _hints: RegionHints
var _dial: Dial
var _size_slider: HSlider     # 微调模式：选中器官下方水平滑条（调整器官大小）
var _hint_btn: Button           # 左上角提示按钮（弹出原图 5 秒）
var _hint_root: Node2D          # 提示原画（BUILD 阶段临时覆盖显示）
var _hint_until_ms := 0
var _picker: PanelContainer      # 器官款式弹窗
var _result_panel: PanelContainer
var _list_box: VBoxContainer     # 左侧已用器官列表
var _countdown: Label
var _tip: Label
var _done_btn: Button

var _tex := {}                  # "cat_idx" → Texture2D
var _cell_btns := {}            # cat → 面板按钮
var _panel: PanelContainer
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _hbox: HBoxContainer
var _memo_t := 0.0
var _memo_tick := 99
var _fade_left := 0.0


## 区域提示圈（手持器官时显示全部槽位区域，悬停槽位高亮）
class RegionHints extends Node2D:
	var slots: Array = []
	var center := Vector2.ZERO
	var f := 400.0
	var hover := ""     # 悬停槽位 key
	var on := false

	func _draw() -> void:
		if not on:
			return
		for s in slots:
			var pos: Vector2 = center + s["off"] * f
			var r: float = s["r"] * f
			var hot: bool = s["key"] == hover
			draw_circle(pos, r, Color(1, 1, 1, 0.10 if not hot else 0.20))
			draw_arc(pos, r, 0, TAU, 48, Color(1, 0.9, 0.5, 0.9 if hot else 0.35), 3.0 if hot else 2.0, true)


## 旋转微调盘（右侧圆环 + 白点黑描边，拖点同步旋转器官）
class Dial extends Node2D:
	var radius := 80.0
	var angle := 0.0
	var ring_col := Color(1, 1, 1, 0.45)   # 圆环底色（_update_dial 中取滑条轨道色）

	func _draw() -> void:
		draw_arc(Vector2.ZERO, radius, 0, TAU, 64, ring_col, 5.0, true)
		var dot := Vector2(cos(angle), sin(angle)) * radius
		draw_circle(dot, 14.0, Color.BLACK)
		draw_circle(dot, 10.0, Color.WHITE)


func start() -> void:
	hud = GameHud.new("Face_Puzzle")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_hints = RegionHints.new()
	_hints.z_index = 30
	add_child(_hints)
	_setup_size_slider()
	_outline_sp = Sprite2D.new()
	_outline_sp.z_index = 5
	add_child(_outline_sp)
	_hand_sp = Sprite2D.new()
	_hand_sp.z_index = 100
	_hand_sp.modulate.a = 0.65
	_hand_sp.visible = false
	add_child(_hand_sp)
	_load_textures()
	_init_sfx()
	_setup_panel()
	_setup_list()
	_setup_labels()
	_layout()
	_refresh_boards()
	_new_run()
	_sync_bgm()


func stop() -> void:
	get_tree().paused = false
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()
	print("[face_puzzle] stop")


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源 =====

func _load_textures() -> void:
	for cat: String in CATS:
		for i in CAT_N[cat]:
			_tex["%s_%d" % [cat, i]] = _load_png("res://assets/faces/%s_%d.png" % [cat, i])
	for i in 7:
		_tex["outline_%d" % i] = _load_png("res://assets/faces/outline_%d.png" % i)


func _load_png(path: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码
	for p: String in ["res://games/Face_Puzzle/" + path.trim_prefix("res://"), path]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


func _init_sfx() -> void:
	var files := {"tick": "tick.wav", "pick": "pick.wav", "place": "place.wav", "cancel": "cancel.wav",
			"submit": "submit.wav", "win": "win.wav", "miss": "miss.wav"}
	for n: String in files:
		var f := FileAccess.open("res://assets/sfx/" + files[n], FileAccess.READ)
		if f != null:
			_sfx_streams[n] = AudioStreamWAV.load_from_buffer(f.get_buffer(f.get_length()))
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		p.process_mode = Node.PROCESS_MODE_ALWAYS   # 结算/排行榜暂停时音效不被截断
		add_child(p)
		_sfx_players.append(p)
	var bf := FileAccess.open("res://assets/sfx/bgm.mp3", FileAccess.READ)
	if bf != null:
		var st := AudioStreamMP3.load_from_buffer(bf.get_buffer(bf.get_length()))
		st.loop = true
		_bgm = AudioStreamPlayer.new()
		_bgm.stream = st
		_bgm.volume_db = BGM_DB
		_bgm.process_mode = Node.PROCESS_MODE_ALWAYS   # 结算/排行榜暂停时 BGM 继续
		add_child(_bgm)
		if hud.bgm_on:
			_bgm.play()


func _play_sfx(n: String, volume_db: float = 0.0) -> void:
	if not _sfx_streams.has(n):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx_streams[n]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


# ===== 顶栏按钮（同合集规范排布）=====

func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	var min_btn := GameHud.make_button("")
	min_btn.icon = hud.ui_icon("minimize.png")
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")   # pressed 已在 entry.tscn 连接，勿重复
	min_btn.pressed.connect(func() -> void: get_window().mode = Window.MODE_MINIMIZED)
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, min_btn, _exit_btn]:
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
	# 提示按钮：左上角（参考方块拼图），点击弹出原图 5 秒
	_hint_btn = GameHud.make_button("?")
	_hint_btn.pressed.connect(_on_hint)
	_hint_btn.custom_minimum_size = Vector2(44.0, 56.0)
	_hint_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	_hint_btn.add_theme_font_size_override("font_size", 22)
	add_child(_hint_btn)


func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("lb.title", "Top 10"), -1, -1)


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


func _restart() -> void:
	if _result_panel != null:
		_result_panel.queue_free()
		_result_panel = null
	get_tree().paused = false
	_new_run()


# ===== 面板 / 标签 =====

func _cat_name(cat: String) -> String:
	return hud.t("panel." + cat, cat.capitalize())


func _setup_panel() -> void:
	# 下方面板：器官格子（通用按钮/格子样式），弹窗沿用合集深色面板样式
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.78)
	sb.set_corner_radius_all(16)
	sb.set_content_margin_all(10)
	_panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_panel.add_child(row)
	for cat: String in CATS:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 2)
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.icon = _tex["%s_0" % cat]
		b.expand_icon = true
		b.custom_minimum_size = Vector2(64, 64)
		b.add_theme_constant_override("icon_max_width", 56)
		b.pressed.connect(_on_cell.bind(cat))
		cell.add_child(b)
		var lb := Label.new()
		lb.text = _cat_name(cat)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.add_theme_font_size_override("font_size", 20)
		lb.add_theme_color_override("font_color", Color.WHITE)
		lb.add_theme_color_override("font_outline_color", Color.BLACK)
		lb.add_theme_constant_override("outline_size", 6)
		cell.add_child(lb)
		row.add_child(cell)
		_cell_btns[cat] = b
	# 完成按钮：置于器官格子右侧（同排）
	_done_btn = GameHud.make_button(hud.t("btn.done", "Done"))
	_done_btn.add_theme_font_size_override("font_size", 40)
	_done_btn.pressed.connect(_on_done)
	_done_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_done_btn)
	add_child(_panel)


func _setup_labels() -> void:
	_countdown = Label.new()
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))
	_countdown.add_theme_color_override("font_outline_color", Color.BLACK)
	_countdown.add_theme_constant_override("outline_size", 12)
	add_child(_countdown)
	_tip = Label.new()
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.text = hud.t("tip.memorize", "Memorize the face!")
	_tip.add_theme_color_override("font_color", Color.WHITE)
	_tip.add_theme_color_override("font_outline_color", Color.BLACK)
	_tip.add_theme_constant_override("outline_size", 10)
	add_child(_tip)


# ===== 布局 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var panel_h := m * 0.145
	# 脸区随屏幕自适应：发/帽顶最高 -0.75F、胡须底最低 +0.64F，均留 12px 不越顶栏/底面板；
	# 脸中心取上下约束的均衡点，使脸在可用区内最大
	var top_min := TOPBAR_H + 12.0
	var bot_max := vp.y - panel_h - 12.0
	var cy := (top_min * 0.64 + bot_max * 0.75) / 1.39
	_face_f = minf(vp.x * 0.46, minf((cy - top_min) / 0.75, (bot_max - cy) / 0.64))
	_face_f = maxf(_face_f, 120.0)   # 极小窗口保底可玩
	_face_c = Vector2(vp.x / 2.0, cy)
	_outline_sp.position = _face_c
	if _outline_sp.texture != null:
		var s := _face_f * 1.06 / _outline_sp.texture.get_width()
		_outline_sp.scale = Vector2(s, s)
	for p in _placed:
		p["sp"].position = _face_c + p["local"]
		_apply_part_scale(p)
	_refresh_orig_positions()
	_hints.center = _face_c
	_hints.f = _face_f
	if not _sel.is_empty():
		_dial.position = _dial_pos_for(_sel)
		_size_slider.position = _slider_pos_for(_sel)
	_place_panel()
	_hbox.reset_size()
	_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	if _hint_btn != null:
		_hint_btn.reset_size()
		_hint_btn.position = Vector2(14.0, 14.0)
	if _list_box != null:
		_list_box.reset_size()
		_list_box.position = Vector2(10.0, TOPBAR_H + 10.0)
	_countdown.position = Vector2(vp.x / 2.0 - 100.0, _face_c.y - _face_f * 0.78)
	_countdown.size = Vector2(200, m * 0.1)
	_countdown.add_theme_font_size_override("font_size", int(m * 0.075))
	_tip.position = Vector2(vp.x / 2.0 - 250.0, _face_c.y - _face_f * 0.95)
	_tip.size = Vector2(500, m * 0.06)
	_tip.add_theme_font_size_override("font_size", int(m * 0.042))


## 器官面板居中贴底（完成按钮显隐会改变面板宽度，切换后需重摆）
func _place_panel() -> void:
	_panel.reset_size()
	var vp := get_viewport_rect().size
	_panel.position = Vector2((vp.x - _panel.size.x) / 2.0, vp.y - _panel.size.y - 10.0)


## 原画/重影/提示部件跟随布局
func _refresh_orig_positions() -> void:
	for root: Node2D in [_orig_root, _ghost_root, _hint_root]:
		if root == null or not is_instance_valid(root):
			continue
		for sp: Sprite2D in root.get_children():
			if sp.has_meta("slot_off"):
				sp.position = _face_c + sp.get_meta("slot_off") * _face_f


# ===== 回合流程 =====

func _new_run() -> void:
	_clear_parts()
	_clear_hint()
	_free_ghost()
	_pick_recipe()
	_slots = _build_slots()
	_hints.slots = _slots
	_hand = {}
	_hand_sp.visible = false
	_close_picker()
	_sel = {}
	_update_dial()
	_outline_sp.texture = _tex["outline_%d" % _recipe["outline"]]
	_layout()
	# 记忆阶段：按层级摆出完整原画
	if _orig_root != null:
		_orig_root.queue_free()
	_orig_root = Node2D.new()
	_orig_root.z_index = 20
	add_child(_orig_root)
	for s in _slots:
		var sp := _make_part_sprite(s["cat"], s["idx"], s["side"], s["rot"])
		sp.position = _face_c + s["off"] * _face_f
		sp.set_meta("slot_off", s["off"])
		_orig_root.add_child(sp)
	state = State.MEMORIZE
	_memo_t = MEMORIZE_T
	_memo_tick = int(MEMORIZE_T) + 1
	_done_btn.visible = false
	_place_panel()
	_countdown.visible = true
	_tip.visible = true
	_tip.modulate.a = 1.0
	var tw := _tip.create_tween()
	tw.tween_interval(1.4)
	tw.tween_property(_tip, "modulate:a", 0.0, 0.5)
	_refresh_boards()


## 随机生成一张原画配方（脸型/各部件变体随机组合，每局不同）
## outline 7 种脸型（含马里奥/哆啦A梦）；各器官类别随机变体；hair/hat 互斥（约 1/4 概率戴帽）；glass 约 1/2 概率；beard 约 1/3 概率无
func _pick_recipe() -> void:
	var rec := {"outline": randi() % 7}
	for cat: String in CATS:
		rec[cat] = randi() % CAT_N[cat]
	# 头发/帽子互斥（两区域圆心重合，避免放置判定歧义）
	if randi() % 4 == 0:
		rec["hair"] = -1
		rec["hat"] = randi() % CAT_N["hat"]
		if rec["outline"] == 2:   # 方脸冠部过宽（0.513F），帽穹盖不住两侧 → 方脸不出帽
			rec["outline"] = [0, 1, 3, 4, 5, 6][randi() % 6]
	else:
		rec["hat"] = -1
	# 眼镜与眼睛共存（区域在鼻梁）
	rec["glass"] = -1 if randi() % 2 == 0 else rec["glass"]
	rec["beard"] = -1 if randi() % 3 == 0 else rec["beard"]
	rec["brow_til"] = randf_range(-0.15, 0.15)
	rec["mouth_rot"] = randf_range(-0.08, 0.08)
	rec["ear_x"] = randf_range(0.50, 0.545)
	_recipe = rec


## 配方 → 槽位列表（含区域归一化偏移/半径/目标旋转）
func _build_slots() -> Array:
	var out: Array = []
	for cat: String in CATS:
		var idx: int = _recipe[cat]
		if idx < 0:
			continue
		var base: Dictionary = REGION_BASE[cat]
		var sides: Array = ["L", "R"] if PAIRED.get(cat, false) else [""]
		for side: String in sides:
			# ear 特殊（ear_x 正值）；其余成对件：L 用原值（x<0 屏幕左），R 取反到对侧
			var off: Vector2 = base["off"]
			if cat == "ear":
				off.x = _recipe["ear_x"] * (1.0 if side == "R" else -1.0)
			elif side == "R":
				off.x = -off.x
			var rot := 0.0
			if cat == "brow":
				rot = _recipe["brow_til"] * (1.0 if side == "L" else -1.0)
			elif cat == "mouth":
				rot = _recipe["mouth_rot"]
			out.append({"key": cat + ("_" + side if side != "" else ""), "cat": cat, "side": side,
				"idx": idx, "off": off, "r": base["r"], "rot": rot})
	return out


## 记忆结束：五官逐件淡出，仅留轮廓
func _start_fade() -> void:
	state = State.FADE
	_countdown.visible = false
	_tip.visible = false
	_done_btn.visible = false
	_place_panel()
	var sprites := _orig_root.get_children()
	var i := 0
	for sp: Sprite2D in sprites:
		var tw := sp.create_tween()
		tw.tween_interval(FADE_STAGGER * i)
		tw.tween_property(sp, "modulate:a", 0.0, FADE_T)
		i += 1
	_fade_left = FADE_STAGGER * (sprites.size() - 1) + FADE_T + 0.05


func _finish_fade() -> void:
	if _orig_root != null:
		_orig_root.queue_free()
		_orig_root = null
	state = State.BUILD
	_done_btn.visible = true
	_place_panel()


func _process(delta: float) -> void:
	if hud == null:
		return
	match state:
		State.MEMORIZE:
			_memo_t -= delta
			var n := maxi(int(ceil(_memo_t)), 0)
			if n != _memo_tick:
				_memo_tick = n
				_countdown.text = str(n)
				_play_sfx("tick")
			if _memo_t <= 0.0:
				_start_fade()
		State.FADE:
			_fade_left -= delta
			if _fade_left <= 0.0:
				_finish_fade()
		State.BUILD:
			if _hint_root != null and Time.get_ticks_msec() >= _hint_until_ms:
				var root := _hint_root
				_hint_root = null
				var tw := root.create_tween()
				tw.tween_property(root, "modulate:a", 0.0, 0.4)
				tw.tween_callback(root.queue_free)
			_process_build()


## BUILD 阶段逐帧：手持跟随 / 拖拽 / 区域悬停
func _process_build() -> void:
	var mp := get_global_mouse_position()
	if not _hand.is_empty() and _hand_sp.visible:
		_hand_sp.position = mp
		_hints.on = true
		_hints.hover = _region_at(mp)
		_hints.queue_redraw()
	elif _hints.on:
		_hints.on = false
		_hints.queue_redraw()
	if _move_drag and not _sel.is_empty():
		_sel["sp"].position = mp
		_sel["local"] = mp - _face_c
		_dial.position = _dial_pos_for(_sel)
		_size_slider.position = _slider_pos_for(_sel)
	if _dial_drag and _dial != null:
		var ang := (mp - _dial.position).angle()
		_dial.angle = ang
		_dial.queue_redraw()
		if not _sel.is_empty():
			_sel["rot"] = ang
			_sel["sp"].rotation = ang


func _refresh_boards() -> void:
	_best_board.text = hud.t("hud.best", "Best %d%%") % hud.max_score
	var occupied := 0
	for s in _slots:
		if _region_occupied(s["key"]):
			occupied += 1
	_parts_board.text = hud.t("hud.parts", "Parts %d/%d") % [occupied, _slots.size()]


# ===== 部件精灵 =====

func _make_part_sprite(cat: String, idx: int, side: String, rot: float) -> Sprite2D:
	var sp := Sprite2D.new()
	sp.texture = _tex["%s_%d" % [cat, idx]]
	var sc: Dictionary = PART_SCALE[cat]
	var tw: float = sc["w"] * _face_f / sp.texture.get_width() if sc.has("w") else sc["h"] * _face_f / sp.texture.get_height()
	sp.scale = Vector2(tw, tw)
	sp.z_index = ORIG_Z[cat]   # 原画层级；已放件由 _place_hand 覆盖为 PART_Z
	sp.flip_h = cat == "ear" and side == "L"
	sp.rotation = rot
	return sp


func _apply_part_scale(p: Dictionary) -> void:
	var sc: Dictionary = PART_SCALE[p["cat"]]
	var tw: float = sc["w"] * _face_f / p["sp"].texture.get_width() if sc.has("w") else sc["h"] * _face_f / p["sp"].texture.get_height()
	tw *= p.get("scale", 1.0)   # 微调滑条的额外缩放
	p["sp"].scale = Vector2(tw, tw)


# ===== 区域判定 =====

func _region_occupied(key: String) -> bool:
	for p in _placed:
		if p["region"] == key:
			return true
	return false


func _region_at(pos: Vector2) -> String:
	var best := ""
	var bd := 1e9
	for s in _slots:
		var d := pos.distance_to(_face_c + s["off"] * _face_f)
		if d <= s["r"] * _face_f and d < bd:
			bd = d
			best = s["key"]
	return best


# ===== 提示（左上角 ? 按钮：弹出原图 5 秒后自动淡出）=====

func _on_hint() -> void:
	if state != State.BUILD:
		return
	_exit_adjust()   # 置顶选中件会盖住提示原图(45)，先退出微调
	_clear_hint()
	_hint_root = Node2D.new()
	_hint_root.z_index = 45   # 覆盖已放件(10)，不挡手持(100)/转盘(120)
	add_child(_hint_root)
	for s in _slots:
		var sp := _make_part_sprite(s["cat"], s["idx"], s["side"], s["rot"])
		sp.position = _face_c + s["off"] * _face_f
		sp.set_meta("slot_off", s["off"])
		_hint_root.add_child(sp)
	_hint_until_ms = Time.get_ticks_msec() + int(MEMORIZE_T * 1000)
	_play_sfx("pick")


func _clear_hint() -> void:
	if _hint_root != null and is_instance_valid(_hint_root):
		_hint_root.queue_free()
	_hint_root = null


# ===== 面板 / 款式弹窗 =====

func _on_cell(cat: String) -> void:
	if state != State.BUILD:
		return
	if not _hand.is_empty() and _hand["cat"] == cat and _picker == null:
		_cancel_hand()
		return
	_open_picker(cat)


func _open_picker(cat: String) -> void:
	_close_picker()
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	var panel := PanelContainer.new()
	panel.process_mode = Node.PROCESS_MODE_ALWAYS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.96)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.02)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.012))
	panel.add_child(vb)
	var lb := Label.new()
	lb.text = hud.t("popup.title", "Pick: %s") % _cat_name(cat)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(m * 0.03))
	GameHud._style_label(lb, Color.WHITE)
	vb.add_child(lb)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", int(m * 0.012))
	grid.add_theme_constant_override("v_separation", int(m * 0.012))
	vb.add_child(grid)
	for i in CAT_N[cat]:
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.icon = _tex["%s_%d" % [cat, i]]
		b.custom_minimum_size = Vector2(m * 0.075, m * 0.075)
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", int(m * 0.06))
		b.pressed.connect(_take_hand.bind(cat, i))
		grid.add_child(b)
	add_child(panel)
	panel.z_index = 200
	panel.reset_size()
	var vp := get_viewport_rect().size
	var cell_x: float = _panel.position.x + _cell_btns[cat].get_global_rect().get_center().x - _panel.position.x
	panel.position = Vector2(clampf(cell_x - panel.size.x / 2.0, 10.0, vp.x - panel.size.x - 10.0),
			_panel.position.y - panel.size.y - 10.0)
	_picker = panel
	_play_sfx("pick")


func _close_picker() -> void:
	if _picker != null and is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null


func _take_hand(cat: String, idx: int) -> void:
	_close_picker()
	_hand = {"cat": cat, "idx": idx}
	_hand_sp.texture = _tex["%s_%d" % [cat, idx]]
	var sc: Dictionary = PART_SCALE[cat]
	var tw: float = sc["w"] * _face_f / _hand_sp.texture.get_width() if sc.has("w") else sc["h"] * _face_f / _hand_sp.texture.get_height()
	_hand_sp.scale = Vector2(tw, tw)
	_hand_sp.position = get_global_mouse_position()
	_hand_sp.visible = true
	_exit_adjust()
	_play_sfx("pick")


func _cancel_hand() -> void:
	_hand = {}
	_hand_sp.visible = false
	_hints.on = false
	_hints.queue_redraw()
	_play_sfx("cancel")


# ===== 放置 / 微调 =====

func _place_hand() -> void:
	var pos := get_global_mouse_position()
	var region := _region_at(pos)
	var side: String = ""
	if region != "":
		var slot := _slot_by_key(region)
		side = slot["side"]
	var sp := _make_part_sprite(_hand["cat"], _hand["idx"], side, 0.0)
	sp.position = pos
	sp.z_index = PART_Z
	add_child(sp)
	_placed.append({"cat": _hand["cat"], "idx": _hand["idx"], "side": side,
			"local": pos - _face_c, "rot": 0.0, "region": region, "scale": 1.0, "sp": sp})
	_hand = {}
	_hand_sp.visible = false
	_hints.on = false
	_hints.queue_redraw()
	_play_sfx("place")
	_refresh_boards()
	_refresh_parts_list()


func _slot_by_key(key: String) -> Dictionary:
	for s in _slots:
		if s["key"] == key:
			return s
	return {}


func _part_at(pos: Vector2) -> Dictionary:
	for i in range(_placed.size() - 1, -1, -1):
		var p: Dictionary = _placed[i]
		var half: Vector2 = p["sp"].texture.get_size() * p["sp"].scale.x * 0.5 + Vector2(8, 8)
		if absf(pos.x - p["sp"].position.x) <= half.x and absf(pos.y - p["sp"].position.y) <= half.y:
			return p
	return {}


func _enter_adjust(p: Dictionary) -> void:
	_sel = p
	p["sp"].z_index = _top_z() + 1   # 点击置顶：提升到当前所有图层之上（不随取消恢复）
	_refresh_parts_list()            # 列表跟随 z-index 动态重排
	_update_dial()
	_play_sfx("pick")


func _exit_adjust() -> void:
	if _sel.is_empty():
		return
	_sel = {}
	_dial_drag = false
	_move_drag = false
	_update_dial()


## 当前已放件最高层级
func _top_z() -> int:
	var z := PART_Z
	for p in _placed:
		z = maxi(z, p["sp"].z_index)
	return z


func _update_dial() -> void:
	var need: bool = not _sel.is_empty()
	if need and _dial == null:
		_dial = Dial.new()
		_dial.z_index = 120
		add_child(_dial)
		_dial.radius = minf(get_viewport_rect().size.x, get_viewport_rect().size.y) * 0.075
		var sb := _size_slider.get_theme_stylebox("slider") as StyleBoxFlat   # 圆环底色同滑条轨道
		if sb != null:
			_dial.ring_col = sb.bg_color
	if _dial != null:
		_dial.visible = need
		if need:
			_dial.angle = _sel["rot"]
			_dial.position = _dial_pos_for(_sel)
		_dial.queue_redraw()
	_update_size_slider()


## 微调盘位置：紧贴选中器官（器官右缘外一点，靠屏幕右边界时改放左侧）
func _dial_pos_for(p: Dictionary) -> Vector2:
	var half: float = maxf(p["sp"].texture.get_size().x, p["sp"].texture.get_size().y) * p["sp"].scale.x * 0.5
	var gap := half + _dial.radius + 12.0
	var pos: Vector2 = p["sp"].position + Vector2(gap, 0)
	if pos.x + _dial.radius > get_viewport_rect().size.x - 8.0:
		pos = p["sp"].position - Vector2(gap, 0)
	return pos


## 微调大小滑条：置于选中器官正下方（拖动调缩放，随器官移动/缩放跟随）
func _setup_size_slider() -> void:
	_size_slider = HSlider.new()
	_size_slider.z_index = 130
	_size_slider.min_value = SCALE_MIN
	_size_slider.max_value = SCALE_MAX
	_size_slider.step = 0.01
	_size_slider.value = 1.0
	_size_slider.custom_minimum_size = Vector2(150, 24)
	_size_slider.visible = false
	_size_slider.value_changed.connect(_on_size_changed)
	add_child(_size_slider)


## 滑条位置：器官下缘外一点，水平居中（clamp 在面板上方与屏幕内）
func _slider_pos_for(p: Dictionary) -> Vector2:
	var half_h: float = p["sp"].texture.get_size().y * p["sp"].scale.x * 0.5
	var w := _size_slider.custom_minimum_size.x
	var vp := get_viewport_rect().size
	var pos: Vector2 = p["sp"].position + Vector2(-w * 0.5, half_h + 10.0)
	pos.x = clampf(pos.x, 8.0, vp.x - w - 8.0)
	pos.y = minf(pos.y, vp.y - vp.y * 0.145 - 34.0)
	return pos


func _update_size_slider() -> void:
	if _size_slider == null:
		return
	var need: bool = not _sel.is_empty()
	_size_slider.visible = need
	if need:
		_size_slider.set_value_no_signal(_sel.get("scale", 1.0))
		_size_slider.position = _slider_pos_for(_sel)


func _on_size_changed(v: float) -> void:
	if _sel.is_empty():
		return
	_sel["scale"] = v
	_apply_part_scale(_sel)
	if _dial != null and _dial.visible:
		_dial.position = _dial_pos_for(_sel)
	_size_slider.position = _slider_pos_for(_sel)


## 微调后/移动后重判区域（器官允许重叠，不移除同区旧件）
func _reassign_region(p: Dictionary) -> void:
	var region := _region_at(p["sp"].position)
	if p["region"] == region:
		return
	p["region"] = region
	if region != "":
		var slot := _slot_by_key(region)
		p["side"] = slot["side"]
		p["sp"].flip_h = p["cat"] == "ear" and p["side"] == "L"
	_refresh_boards()
	_refresh_parts_list()


# ===== 输入 =====

func _unhandled_input(event: InputEvent) -> void:
	if hud == null:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_on_rmb()
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			_on_lmb(event.position)
		else:
			_on_lmb_release()


func _on_rmb() -> void:
	if state != State.BUILD:
		if _picker != null:
			_close_picker()
		return
	if not _hand.is_empty():
		_cancel_hand()
	elif not _sel.is_empty():
		_exit_adjust()
	elif _picker != null:
		_close_picker()


func _on_lmb(pos: Vector2) -> void:
	if state != State.BUILD:
		return
	if not _hand.is_empty():
		_place_hand()
		return
	if not _sel.is_empty():
		var dial := _dial
		if dial != null and pos.distance_to(dial.position + Vector2(cos(dial.angle), sin(dial.angle)) * dial.radius) <= 22.0:
			_dial_drag = true
			return
		var half: Vector2 = _sel["sp"].texture.get_size() * _sel["sp"].scale.x * 0.5 + Vector2(10, 10)
		if absf(pos.x - _sel["sp"].position.x) <= half.x and absf(pos.y - _sel["sp"].position.y) <= half.y:
			_move_drag = true
			return
		# 点外部：退出微调；点到其他已放件则切换选中
		var other := _part_at(pos)
		if not other.is_empty() and other != _sel:
			_enter_adjust(other)
		else:
			_exit_adjust()
		return
	var hit := _part_at(pos)
	if not hit.is_empty():
		_enter_adjust(hit)


func _on_lmb_release() -> void:
	if _dial_drag:
		_dial_drag = false
	if _move_drag:
		_move_drag = false
		if not _sel.is_empty():
			_reassign_region(_sel)


func _on_done() -> void:
	if state != State.BUILD:
		return
	_close_picker()
	_clear_hint()
	_exit_adjust()
	if not _hand.is_empty():
		_cancel_hand()
	_submit()


# ===== 评分 / 结算 =====

func _compute_match() -> int:
	var total_w := 0.0
	var gain := 0.0
	var claimed := {}   # 被槽位认领的 _placed 下标 → true
	for s in _slots:
		var w: float = SLOT_WEIGHT[s["cat"]]
		total_w += w
		# 同区域同类器官允许多件重叠：取最佳一件认领该槽位，其余按杂件扣分
		var best_k := -1.0
		var best_i := -1
		for pi in _placed.size():
			var p: Dictionary = _placed[pi]
			if p["region"] != s["key"] or p["cat"] != s["cat"]:
				continue
			var k := _slot_match(p, s)
			if k > best_k:
				best_k = k
				best_i = pi
		if best_i >= 0:
			claimed[best_i] = true
			gain += w * best_k
	var extras := 0
	for pi in _placed.size():
		if not claimed.has(pi):
			extras += 1
	return roundi(clampf(gain / maxf(total_w, 0.001) * 100.0 - extras * EXTRA_PENALTY, 0.0, 100.0))


## 单件对槽位匹配度 0~1（种类不符给保底 0.08）
func _slot_match(p: Dictionary, s: Dictionary) -> float:
	if p["cat"] != s["cat"]:
		return 0.08
	var var_k := 1.0 if p["idx"] == s["idx"] else 0.0
	var d: float = p["local"].distance_to(s["off"] * _face_f)
	var pos_k: float = clampf(1.0 - d / (s["r"] * _face_f), 0.0, 1.0)
	var rd: float = absf(wrapf(p["rot"] - s["rot"], -PI, PI))
	var rot_k: float = clampf(1.0 - rd / ROT_TOL, 0.0, 1.0)
	return W_CAT + W_VAR * var_k + W_POS * pos_k + W_ROT * rot_k


func _rank_text(v: int) -> String:
	if v >= 90:
		return hud.t("rank.90", "Perfect copy!")
	if v >= 75:
		return hud.t("rank.75", "Memory master")
	if v >= 60:
		return hud.t("rank.60", "Pretty good")
	if v >= 40:
		return hud.t("rank.40", "Close enough")
	return hud.t("rank.0", "Features ran away")


func _submit() -> void:
	state = State.RESULT
	var match := _compute_match()
	hud.submit_score(match)
	hud.commit_score()
	_refresh_boards()
	_play_sfx("win" if match >= 60 else "miss")
	# 原画半透明重影叠于拼画之上，直观对比差异
	_free_ghost()
	_ghost_root = Node2D.new()
	_ghost_root.z_index = 40
	_ghost_root.modulate.a = 0.45
	add_child(_ghost_root)
	for s in _slots:
		var sp := _make_part_sprite(s["cat"], s["idx"], s["side"], s["rot"])
		sp.position = _face_c + s["off"] * _face_f
		sp.set_meta("slot_off", s["off"])
		_ghost_root.add_child(sp)
	_show_result(match)


func _free_ghost() -> void:
	if _ghost_root != null and is_instance_valid(_ghost_root):
		_ghost_root.queue_free()
	_ghost_root = null


func _show_result(match: int) -> void:
	get_tree().paused = true
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
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
	title.text = hud.t("result.title", "Face Puzzle Result")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(m * 0.045))
	GameHud._style_label(title, Color.WHITE)
	vb.add_child(title)
	var big := Label.new()
	big.text = "%d%%" % match
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.add_theme_font_size_override("font_size", int(m * 0.085))
	GameHud._style_label(big, Color(1.0, 0.85, 0.25))
	vb.add_child(big)
	var rank := Label.new()
	rank.text = _rank_text(match)
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rank.add_theme_font_size_override("font_size", int(m * 0.034))
	GameHud._style_label(rank, Color.WHITE)
	vb.add_child(rank)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(row)
	var b_cont := GameHud.make_button(hud.t("popup.continue", "Keep Going"))
	b_cont.add_theme_font_size_override("font_size", int(m * 0.032))
	b_cont.pressed.connect(_on_continue)
	row.add_child(b_cont)
	var b_again := GameHud.make_button(hud.t("popup.again", "New Face"))
	b_again.add_theme_font_size_override("font_size", int(m * 0.032))
	b_again.pressed.connect(_on_again)
	row.add_child(b_again)
	add_child(panel)
	panel.z_index = 200
	panel.reset_size()
	panel.position = (get_viewport_rect().size - panel.size) * 0.5
	_result_panel = panel


func _close_result() -> void:
	get_tree().paused = false
	if _result_panel != null and is_instance_valid(_result_panel):
		_result_panel.queue_free()
	_result_panel = null


func _on_continue() -> void:
	_close_result()
	_free_ghost()
	state = State.BUILD


func _on_again() -> void:
	_close_result()
	_new_run()


# ===== 左侧已用器官列表 =====

func _setup_list() -> void:
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 6)
	add_child(_list_box)


## 全量重建列表行：图标按钮（点击进入该器官微操）+ 右侧 ✕ 删除按钮
func _refresh_parts_list() -> void:
	if _list_box == null:
		return
	for c in _list_box.get_children():
		_list_box.remove_child(c)
		c.queue_free()
	# 按 z-index 从高到低排（置顶件在列表最上；同层后放的在上）；bind 保留 _placed 原索引
	var order: Array = []
	for pi in _placed.size():
		order.append(pi)
	order.sort_custom(func(a: int, b: int) -> bool:
		var za: int = _placed[a]["sp"].z_index
		var zb: int = _placed[b]["sp"].z_index
		return za > zb if za != zb else a > b)
	for pi: int in order:
		var p: Dictionary = _placed[pi]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.icon = p["sp"].texture
		b.expand_icon = true
		b.custom_minimum_size = Vector2(52, 52)
		b.add_theme_constant_override("icon_max_width", 44)
		b.tooltip_text = _cat_name(p["cat"])
		b.pressed.connect(_select_from_list.bind(pi))
		row.add_child(b)
		var del := Button.new()
		GameHud.style_button(del)
		del.text = "✕"
		del.focus_mode = Control.FOCUS_NONE
		del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		del.add_theme_font_size_override("font_size", 20)
		del.pressed.connect(_remove_placed.bind(pi))
		row.add_child(del)
		_list_box.add_child(row)


## 列表点击：切换到该器官的微操模式
func _select_from_list(pi: int) -> void:
	if state != State.BUILD or pi >= _placed.size():
		return
	_enter_adjust(_placed[pi])


## 列表删除：移除该器官
func _remove_placed(pi: int) -> void:
	if state != State.BUILD or pi >= _placed.size():
		return
	var p: Dictionary = _placed[pi]
	if not _sel.is_empty() and _sel["sp"] == p["sp"]:
		_exit_adjust()
	if is_instance_valid(p["sp"]):
		p["sp"].queue_free()
	_placed.remove_at(pi)
	_play_sfx("cancel")
	_refresh_boards()
	_refresh_parts_list()


# ===== 清场 =====

func _clear_parts() -> void:
	for p in _placed:
		if is_instance_valid(p["sp"]):
			p["sp"].queue_free()
	_placed.clear()
	_refresh_parts_list()
