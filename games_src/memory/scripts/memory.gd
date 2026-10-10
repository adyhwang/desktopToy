extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 记忆配对 Memory Match：4×4 翻牌配对（8 对），全部消除过关 +1 并开下一关
## 总时间 120s 贯穿所有关卡，时间到结算；最佳纪录 = 单局最多过关数（GameHud 持久化）
## 卡面 = 程序生成卡底（3 套随机）+ 复用合集素材图案（篮球/纸团/易拉罐/电池/书本/可乐瓶/垃圾桶/镖盘）
## 卡背 = 程序生成 3 套深底几何纹样，每关随机；BGM: "Happy Arcade Tune" by rezoner (opengameart.org), CC-BY 3.0

const GameHud := preload("res://scripts/game_hud.gd")

const SFX_POOL := 4             # 音效播放器池
const COMBO_MIN := 3            # 连击飘字触发次数
const COLS_LAND := 6            # 宽屏网格：6 列 × 3 行（9 对）
const ROWS_LAND := 3
const COLS_PORT := 3            # 竖屏网格：3 列 × 6 行
const ROWS_PORT := 6
const FLIP_T := 0.16            # 翻面半程（scale.x 1→0→换面→1 的每半程）时长
const MATCH_DELAY := 0.42       # 第二张翻正后到判定消除的等待
const MISMATCH_T := 0.62        # 错配两张停留展示时长（到点翻回）
const MATCH_T := 0.34           # 配对消除动画时长（弹大后缩小淡出）
const DEAL_T := 0.30            # 发牌单卡弹入时长
const DEAL_STAGGER := 0.04      # 发牌逐张间隔
const NEXT_LEVEL_T := 0.9       # 过关停顿后开下一关
const HEADER_H := 150.0         # 顶栏保留高度（网格上下各留此值：防遮挡 + 相对窗口垂直居中）
const EDGE_X := 0.03            # 网格水平边距 / min(屏宽, 屏高)
const CARD_H_RATIO := 1.25      # 卡高 / 卡宽（卡底贴图 512×640）
const SCORE_FONT_RATIO := 0.035 # 记分牌字号 = m × 此值
const POPUP_FONT_RATIO := 0.055 # 飘字字号 = m × 此值
const POPUP_TIME := 0.8         # 飘字时长（s）
const BGM_DB := -6.0            # BGM 音量（dB）
const SFX_DB := -4.0            # 音效全局音量偏移（默认 0dB 过响，统一下移）
const ICON_W := 0.60            # 卡面图案宽 = 卡宽 × 此值（等比适配）

# 卡面图案（assets/cards/ 下文件名，不含扩展名）：9 种水果）→ 9 对满铺网格
const SUITS := ["apple", "banana", "orange", "peach", "pear", "grape", "strawberry", "watermelon", "carrot"]
const FRONT_SETS := 3           # 卡底/卡背各 3 款（front_0..2 / back_0..2）

enum State { PLAY, LOCK, DEAL }

var hud: RefCounted

@onready var _scoreboard: Label = $HudBar/ScoreBoard
@onready var _pairs_board: Label = $HudBar/PairsBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.DEAL
var level := 1
var score := 0                  # 本局得分：每对 +1，过关 +5（开局为 0）
var pairs_left := 0             # 本关剩余配对数

var _cols := COLS_LAND          # 网格布局（_new_level 按屏幕方向快照，转屏当关内只重排位置）
var _rows := ROWS_LAND
var _card_root: Node2D
var _cards: Array = []
var _first: Node2D              # 第一张翻开待配的卡
var _pair_a: Node2D
var _pair_b: Node2D
var _pending_match := false     # 本组预判定结果（两张翻开时即已知）
var _lock_t := 0.0              # LOCK 状态倒计时（判定/翻回）
var _dealt := 0                 # 已发牌数（DEAL 状态进度）
var _deal_t := 0.0
var _card_w := 120.0            # 卡显示宽（_layout 更新）
var _gap := 16.0
var _front_tex: Array = []      # 3 款卡底
var _back_tex: Array = []       # 3 款卡背
var _suit_tex := {}             # 图案名 → Texture2D
var _combo := 0                 # 连击（成功配对连击）
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button             # 排行榜按钮
var _hbox: HBoxContainer        # 右上角按钮排容器（等间距/底对齐）


class Card extends Node2D:
	var back: Sprite2D
	var front: Sprite2D
	var icon: Sprite2D
	var suit := ""         # 配对键（图案名）
	var matched := false
	var revealed := false
	var flip_tween: Tween  # 翻面防重入

	## 按当前 _card_w 设置子贴图缩放（卡底 512×640 等比、图案按适配比例）
	func apply_size(cw: float) -> void:
		var s := cw / 512.0
		back.scale = Vector2(s, s)
		front.scale = Vector2(s, s)
		var tw: Texture2D = icon.texture
		if tw != null:
			var ts: float = minf(cw * 0.66 / tw.get_width(), cw * CARD_H_RATIO * 0.52 / tw.get_height())
			icon.scale = Vector2(ts, ts)

	func _show_front() -> void:
		back.visible = false
		front.visible = true
		icon.visible = true

	func _show_back() -> void:
		back.visible = true
		front.visible = false
		icon.visible = false

	## 翻正面：scale.x 1→0（背）→ 换面 → 0→1
	func reveal() -> void:
		revealed = true
		_flip(true)

	## 翻背面
	func cover() -> void:
		revealed = false
		_flip(false)

	func _flip(to_front: bool) -> void:
		if flip_tween != null and flip_tween.is_valid():
			flip_tween.kill()
		scale.x = 1.0
		flip_tween = create_tween()
		flip_tween.tween_property(self, "scale:x", 0.001, FLIP_T)
		flip_tween.tween_callback(_show_front if to_front else _show_back)
		flip_tween.tween_property(self, "scale:x", 1.0, FLIP_T)

	## 配对消除：弹大后缩小淡出
	func vanish(t: float) -> void:
		matched = true
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(self, "scale", Vector2.ONE * 1.14, t * 0.4).set_trans(Tween.TRANS_SINE)
		tw.chain().tween_property(self, "scale", Vector2.ONE * 0.05, t * 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(self, "modulate:a", 0.0, t * 0.6)


func start() -> void:
	hud = GameHud.new("memory")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_card_root = Node2D.new()
	add_child(_card_root)
	_load_textures()
	_init_sfx()
	_layout()
	_new_game()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 中途退出也把本局分数入排行榜
	print("[memory] stop, score=%d level=%d pairs_left=%d" % [score, level, pairs_left])


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源 =====

func _load_textures() -> void:
	for i in FRONT_SETS:
		_front_tex.append(_load_png("res://assets/cards/front_%d.png" % i))
		_back_tex.append(_load_png("res://assets/cards/back_%d.png" % i))
	for s: String in SUITS:
		_suit_tex[s] = _load_png("res://assets/cards/%s.png" % s)


func _load_png(path: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码
	for p: String in ["res://games/memory/" + path.trim_prefix("res://"), path]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


func _init_sfx() -> void:
	var files := {"flip": "flip.mp3", "match": "match.mp3", "miss": "miss.mp3", "win": "win.mp3"}
	for n: String in files:
		var f := FileAccess.open("res://assets/sfx/" + files[n], FileAccess.READ)
		if f != null:
			_sfx_streams[n] = AudioStreamMP3.load_from_buffer(f.get_buffer(f.get_length()))
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM，不影响玩法）
	var bf := FileAccess.open("res://assets/sfx/bgm.mp3", FileAccess.READ)
	if bf != null:
		var st := AudioStreamMP3.load_from_buffer(bf.get_buffer(bf.get_length()))
		st.loop = true
		_bgm = AudioStreamPlayer.new()
		_bgm.stream = st
		_bgm.volume_db = BGM_DB
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


# ===== 布局 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_gap = m * 0.012
	# 卡宽唯一来源：左右留 EDGE_X 边距、上下各留 HEADER_H 等高空间（对称防遮挡）
	_card_w = minf(
			(vp.x - m * EDGE_X * 2.0 - (_cols - 1) * _gap) / _cols,
			(vp.y - HEADER_H * 2.0 - (_rows - 1) * _gap) / (_rows * CARD_H_RATIO))
	_layout_cards()
	_layout_boards(vp, m)
	_layout_buttons(vp, m)


## 卡片摆放统一入口（转屏重排也走这里）
func _layout_cards() -> void:
	for c: Card in _cards:
		if is_instance_valid(c):
			c.position = _card_pos(_cards.find(c))
			c.apply_size(_card_w)


func _layout_boards(vp: Vector2, m: float) -> void:
	# 顶栏信息牌（HudBar 内并列：Score+Pairs）整体水平居中（代码定位，Node2D 父下锚点不可靠）
	var bw := 190.0
	var bh := m * SCORE_FONT_RATIO * 1.9
	for b: Label in [_scoreboard, _pairs_board]:
		b.custom_minimum_size = Vector2(bw, bh)
		b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_theme_font_size_override("font_size", int(m * SCORE_FONT_RATIO))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)


func _layout_buttons(_vp: Vector2, _m: float) -> void:
	# 右上角按钮排：容器定位右上（等间距/尺寸/对齐在 _setup_buttons 统一设定）
	_hbox.reset_size()
	_hbox.position = Vector2(_vp.x - _hbox.size.x - 20.0, 14.0)


func _setup_buttons() -> void:
	# 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + R 重开 + 音量循环
	# 容器统一等间距（8px）、按钮固定 56×56 底对齐、图标统一 32px 居中 —— 保证水平/垂直全对齐
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
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
	_exit_btn.icon = hud.ui_icon("close.png")   # pressed 已在 entry.tscn 连接，勿重复

	# 最小化钮（关闭钮左侧）：点击最小化窗口（桌面 Win/Linux）
	var min_btn := GameHud.make_button("")
	min_btn.icon = hud.ui_icon("minimize.png")
	min_btn.custom_minimum_size = Vector2(56.0, 56.0)
	min_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	min_btn.add_theme_constant_override("icon_max_width", 32)
	min_btn.pressed.connect(func() -> void: get_window().mode = Window.MODE_MINIMIZED)
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()   # R 改循环箭头图标（同风格程序生成）
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
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


## 排行榜弹窗（手动查看：不高亮当前局）
func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("lb.title", "Top 10"), -1, -1)


func _on_bgm() -> void:
	hud.cycle_bgm()
	_bgm_btn.icon = hud.bgm_icon()
	_sync_bgm()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


## BGM 播放状态与开关保持一致（重开/过关重进时恢复播放）
func _sync_bgm() -> void:
	if _bgm == null:
		return
	if hud.bgm_on and not _bgm.playing:
		_bgm.play()
	elif not hud.bgm_on and _bgm.playing:
		_bgm.stop()


# ===== 回合流程 =====

func _new_game() -> void:
	level = 1
	score = 0
	hud.reset_run()
	_sync_bgm()   # 结算停过 BGM，重开恢复播放
	_new_level()


## 新一关：按屏幕方向定网格（宽屏 6×3 / 竖屏 3×6），随机卡底/卡背套装，9 图案 ×2 洗牌铺满
func _new_level() -> void:
	var vp := get_viewport_rect().size
	if vp.x >= vp.y:
		_cols = COLS_LAND
		_rows = ROWS_LAND
	else:
		_cols = COLS_PORT
		_rows = ROWS_PORT
	for c: Card in _cards:
		if is_instance_valid(c):
			c.queue_free()
	_cards.clear()
	_first = null
	pairs_left = _cols * _rows / 2
	var front_idx := randi() % FRONT_SETS
	var back_idx := randi() % FRONT_SETS
	var deck: Array = []
	for s: String in SUITS:
		deck.append(s)
		deck.append(s)
	deck.shuffle()
	for i in _cols * _rows:
		var c := Card.new()
		c.suit = deck[i]
		c.back = Sprite2D.new()
		c.back.texture = _back_tex[back_idx]
		c.front = Sprite2D.new()
		c.front.texture = _front_tex[front_idx]
		c.icon = Sprite2D.new()
		c.icon.texture = _suit_tex[c.suit]
		for sp: Sprite2D in [c.back, c.front, c.icon]:
			sp.centered = true          # 显式锚定卡中心（Sprite2D 默认居中，显式声明防误解）
			sp.position = Vector2.ZERO
			c.add_child(sp)
		c._show_back()
		c.position = _card_pos(i)
		c.scale = Vector2.ZERO
		_card_root.add_child(c)
		_cards.append(c)
		c.apply_size(_card_w)
		# 发牌动画：逐张弹入
		var tw := c.create_tween()
		tw.tween_interval(DEAL_STAGGER * i)
		tw.tween_property(c, "scale", Vector2.ONE, DEAL_T).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_dealt = 0
	_deal_t = DEAL_STAGGER * (_cols * _rows - 1) + DEAL_T
	state = State.DEAL
	_layout_cards()   # 统一摆位（print 自检）
	_refresh_boards()


## 第 i 张卡中心（布局唯一真源）：网格外框 gw×gh 在窗口水平+垂直正中，卡中心 = 外框左上角 + 半格
func _card_pos(i: int) -> Vector2:
	var vp := get_viewport_rect().size
	var gw := _cols * _card_w + (_cols - 1) * _gap
	var gh := _rows * _card_w * CARD_H_RATIO + (_rows - 1) * _gap
	return Vector2((vp.x - gw) / 2.0, (vp.y - gh) / 2.0) + Vector2(
			(i % _cols + 0.5) * (_card_w + _gap),
			(i / _cols + 0.5) * (_card_w * CARD_H_RATIO + _gap))


func _restart() -> void:
	var lb := get_node_or_null("LeaderboardPanel")   # R 键重开时关掉排行榜弹窗（Replay 回调自身也会关，双保险）
	if lb != null:
		lb.queue_free()
	_new_game()


# ===== 主循环 =====

func _process(delta: float) -> void:
	if hud == null:   # 无头冒烟（--quit 直跑 entry）不经 start()，对象未创建直接跳过
		return
	match state:
		State.LOCK:
			_lock_t -= delta
			if _lock_t <= 0.0:
				_resolve_pair()
		State.DEAL:
			_deal_t -= delta
			if _deal_t <= 0.0:
				state = State.PLAY


func _refresh_boards() -> void:
	_scoreboard.text = "%d" % score
	_pairs_board.text = hud.t("hud.pairs", "Pairs %d") % pairs_left


# ===== 交互 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
			return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if state != State.PLAY:
			return
		var c := _card_at(get_global_mouse_position())
		if c != null:
			_pick(c)


func _card_at(pos: Vector2) -> Node2D:
	for c: Card in _cards:
		if is_instance_valid(c) and not c.matched and absf(pos.x - c.position.x) <= _card_w / 2.0 \
				and absf(pos.y - c.position.y) <= _card_w * CARD_H_RATIO / 2.0:
			return c
	return null


func _pick(c: Node2D) -> void:
	if c.revealed:
		return
	_play_sfx("flip")
	c.reveal()
	if _first == null:
		_first = c
		return
	_pair_a = _first
	_pair_b = c
	_first = null
	# 结果可立即预知：相同等待翻正后消牌；不同多停留 MISMATCH_T 供记忆后翻回
	_pending_match = _pair_a.suit == _pair_b.suit
	state = State.LOCK
	_lock_t = MATCH_DELAY if _pending_match else MATCH_DELAY + MISMATCH_T


## LOCK 到点：按预判定结果处理本组两张
func _resolve_pair() -> void:
	var a := _pair_a
	var b := _pair_b
	_pair_a = null
	_pair_b = null
	state = State.PLAY
	if a == null or b == null or not is_instance_valid(a) or not is_instance_valid(b):
		return
	if _pending_match:
		_on_match(a, b)
	else:
		_on_mismatch(a, b)


func _on_match(a: Node2D, b: Node2D) -> void:
	_play_sfx("match")
	score += 1
	hud.submit_score(score)
	pairs_left -= 1
	_combo = hud.on_success()
	_popup("+1", Color(0.3, 0.9, 0.4), a.position)
	if _combo >= COMBO_MIN:
		_popup(hud.t("tip.combo", "combo×%d") % _combo, Color(0.95, 0.2, 0.15),
				Vector2(get_viewport_rect().size.x / 2.0, get_viewport_rect().size.y * 0.30))
	a.vanish(MATCH_T)
	b.vanish(MATCH_T)
	if pairs_left <= 0:
		_level_up()
	_refresh_boards()


func _on_mismatch(a: Node2D, b: Node2D) -> void:
	_play_sfx("miss", -4.0)
	hud.on_fail()
	_combo = 0
	# 错配展示已在 LOCK 期间完成（_lock_t = MISMATCH_T 由 _pick 重设——此处仅翻回）
	a.cover()
	b.cover()


func _level_up() -> void:
	level += 1
	score += 5   # 过关奖励
	hud.submit_score(score)
	_play_sfx("win", -6.0)
	_popup(hud.t("tip.level_up", "Level Up! +5"), Color(1.0, 0.85, 0.25),
			Vector2(get_viewport_rect().size.x / 2.0, get_viewport_rect().size.y * 0.34))
	# 总时间不重置继续倒数；停顿后开下一关（计时到点结算则放弃开新关）
	var t := get_tree().create_timer(NEXT_LEVEL_T)
	t.timeout.connect(_next_level_if_valid)


func _next_level_if_valid() -> void:
	if is_inside_tree() and pairs_left <= 0:
		_new_level()


# ===== 飘字 =====

func _popup(text: String, color: Color, pos: Vector2) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.position = pos - Vector2(100.0, m * POPUP_FONT_RATIO)
	lb.size = Vector2(200.0, m * POPUP_FONT_RATIO * 1.4)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(m * POPUP_FONT_RATIO))
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	add_child(lb)
	var tw := lb.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.08, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME)
	tw.chain().tween_callback(lb.queue_free)
