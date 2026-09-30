extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## Slingshot Brawl（弹弓打坏人）：2D 俯视角弹弓射击
## 方形场地上 80% 为劫匪区（随机砖墙掩体，可挡子弹，高抛物线可飞越），下 20% 为玩家区，
## 弹弓固定在左 / 中 / 右三个地点：按住左键出现抛物线预览，移动鼠标调落点，松开发射；
## 按住时再按右键取消。12 种子弹（石头无限，其余击杀掉落拾取），4 种劫匪逐波解锁，
## 波次递进（数量 / 属性 / 闪避 / 反击 / 精英 / 掩体破坏），第 10 波起无尽模式。
## 连击：连续命中提升分数倍率（最高 ×3），脱靶重置。被投掷劫匪石块命中扣 1 条命。

const Bandit := preload("res://scripts/bandit.gd")
const Bullet := preload("res://scripts/bullet.gd")
const Glyph := preload("res://scripts/glyphs.gd")
const GameHud := preload("res://scripts/game_hud.gd")
const Hostage := preload("res://scripts/hostage.gd")

# ===== 布局（比例 × 视口）=====
const FIELD_H_R := 0.80       # 场地高（正方形边长）/ 屏高
const FIELD_TOP_R := 0.095    # 场地顶 / 屏高（HUD 下方）
const ROBBER_FRAC := 0.8      # 劫匪区占场地高比例
const SLING_OFFS := [0.18, 0.5, 0.82]   # 三个弹弓位（场地宽比例）

# ===== 波次 / 难度 =====
const LIVES0 := 3
const LIVES_CAP := 99
const WAVE_BREAK_T := 1.6     # 波次间隔（s）
const SPAWN_IV := 0.85        # 生成间隔（s）
const MAX_ALIVE := 12         # 场上劫匪上限
const ENDLESS_WAVE := 10      # 第 10 波起无尽（难度冻结）
const WALLS_N := 1            # 开局掩体数（第 3 波起每波 +1，最多 6，每波随机重新生成）
const DROP_RATE := 0.30       # 击杀掉落概率
const GAMEOVER_T := 1.4
const RELOAD_T := 0.5         # 换弹间隔（s）：发射后冷却，期间不能再次发射
const ROCK_HIT_R := 62.0      # 石块命中弹弓判定半径（× _u）
const BODY_H := 44.0          # 劫匪可被命中高度（× _u）
const WALL_H := 100.0          # 掩体可阻挡高度（× _u）：子弹经过掩体上方时高度低于此值则被挡
const HOSTAGE_R := 34.0        # 人质命中半径（× _u）：玩家子弹误击扣生命
const HOSTAGE_H := 70.0        # 人质可被命中高度（× _u）
const HOSTAGE_CD := 5.0        # 误击人质免伤间隔（s）

# ===== 子弹表（顺序即轮盘顺序；arc=弧顶/场地高，flight=飞行时长，splash=溅射半径/场地宽）=====
const BULLETS: Array = [
	{"id": "stone", "dmg": 2.0, "arc": 0.16, "flight": 0.55, "splash": 0.0, "inf": true},
	{"id": "egg", "dmg": 1.0, "arc": 0.30, "flight": 0.80, "splash": 0.055, "zone": "slick"},
	{"id": "tomato", "dmg": 1.0, "arc": 0.30, "flight": 0.80, "splash": 0.10, "stun": 10.0},
	{"id": "apple", "dmg": 3.0, "arc": 0.32, "flight": 0.80, "splash": 0.0, "stun": 5.0},
	{"id": "firecracker", "dmg": 5.0, "arc": 0.55, "flight": 1.05, "splash": 0.12, "fuse": 0.3, "boom": true},
	{"id": "blade", "dmg": 6.0, "arc": 0.09, "flight": 0.60, "splash": 0.0, "pierce": 2},
	{"id": "bottle", "dmg": 2.0, "arc": 0.30, "flight": 0.78, "splash": 0.07, "shards": true},
	{"id": "balloon", "dmg": 1.0, "arc": 0.30, "flight": 0.78, "splash": 0.16, "zone": "water"},
	{"id": "boomerang", "dmg": 2.0, "arc": 0.15, "flight": 1.10, "splash": 0.0, "pierce": 99, "boomerang": true},
	{"id": "shotput", "dmg": 6.0, "arc": 0.50, "flight": 1.05, "splash": 0.05, "knock": 110.0},
	{"id": "stink", "dmg": 1.0, "arc": 0.30, "flight": 0.80, "splash": 0.08, "zone": "poison"},
	{"id": "turret", "dmg": 0.5, "arc": 0.30, "flight": 0.80, "splash": 0.0, "turret": true},
	{"id": "wasp", "dmg": 0.5, "arc": 0.30, "flight": 0.80, "splash": 0.0, "wasps": 3},
]

# ===== 劫匪类型表 =====
const KINDS: Array = [
	{"id": "normal", "hp": 3.0, "speed": 55.0, "score": 10, "radius": 30.0, "dodge": 0.0, "armor": 0.0, "wave": 1,
		"body": Color(0.33, 0.40, 0.58), "hat": Color(0.50, 0.20, 0.16)},
	{"id": "agile", "hp": 2.0, "speed": 88.0, "score": 15, "radius": 26.0, "dodge": 0.35, "armor": 0.0, "wave": 2,
		"body": Color(0.28, 0.50, 0.34), "hat": Color(0.16, 0.16, 0.18)},
	{"id": "thrower", "hp": 4.0, "speed": 48.0, "score": 20, "radius": 31.0, "dodge": 0.05, "armor": 0.0, "wave": 3,
		"body": Color(0.60, 0.38, 0.20), "hat": Color(0.72, 0.55, 0.20)},
	{"id": "armored", "hp": 8.0, "speed": 34.0, "score": 30, "radius": 34.0, "dodge": 0.0, "armor": 0.30, "wave": 5,
		"body": Color(0.42, 0.45, 0.50), "hat": Color(0.62, 0.66, 0.72)},
]

const FONT_RATIO := 0.030
const POPUP_TIME := 0.9
const POPUP_RISE_RATIO := 0.06
const SFX_POOL := 6
const BGM_DB := -12.0
const SFX_DB := -4.0

enum St { PLAY, OVER }
enum Wph { BREAK, RUN, ESCAPE }   # ESCAPE = 过关后人质挣脱撤离（跑出屏幕后才开始下一波）

var hud: RefCounted
var _sling_tex: Texture2D            # 弹弓弓架贴图（assets/slingshot.png，null=回退程序化绘制）

@onready var _bandits: Node2D = $Bandits
@onready var _shots: Node2D = $Shots
@onready var _board_score: Label = $HudBar/BoardScore
@onready var _board_wave: Label = $HudBar/BoardWave
@onready var _board_lives: Label = $HudBar/BoardLives
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state: int = St.PLAY
var _wave := 1
var _wph: int = Wph.BREAK
var _wave_t := 1.2
var _spawn_left := 0
var _spawn_t := 0.0
var _score := 0
var _lives := LIVES0
var _combo := 0
var _endless_shown := false
var _over_t := 0.0                # OVER 后延迟弹排行榜倒计时（s）
var _lb_shown := false            # 排行榜已弹出
var _final_rank := -1             # 结算名次（_game_over 时缓存）

# 玩家
var _sel := 0                       # 当前子弹索引（BULLETS）
var _ammo := {}                     # id -> 数量（stone 无限）
var _aiming := false
var _aim_spot := 1                  # 瞄准时锁定的弹弓位
var _aim_target := Vector2.ZERO
var _hurt_t := 0.0
var _reload := 0.0                  # 换弹剩余（>0 冷却中不能发射）
var _aim_layer: Node2D              # 抛物线预览独立层（z_index 置顶，压在劫匪/掩体/子弹之上）
var _linger := false                # 发射后弹弓原地滞留（直到子弹消失才恢复跟随鼠标）
var _linger_spot := 0               # 滞留弹弓位
var _hitstop := 0.0                 # 击中顿帧剩余（>0 时全场时间减速，强化打击感）
var _shake := 0.0                   # 屏幕震动强度（px，爆炸/重击触发，快速衰减）
var _hostage_cd := 0.0              # 误击人质免伤剩余（>0 时再击不扣命）
var _hostage_box: Node2D            # 人质容器（z 序高于劫匪：劫匪移动不遮盖人质）

# 场景对象
var _walls: Array = []              # {c, he, rot}
var _zones: Array = []              # {kind, pos, r, t, dur, blobs}
var _pickups: Array = []            # {kind, pos, t}
var _turrets: Array = []            # 部署炮台 {pos, t, dur, cd, beam, beam_to}
var _wasps: Array = []              # 复仇黄蜂 {pos, target, cd, stings, wob}
var _fx: Array = []                 # {p, v, r, col, t, dur, g}

# 轮盘
var _wheel_open := false
var _wheel_sticky := false
var _wheel_ids: Array = []          # 本次打开时可选子弹 id 快照（弹药为 0 的不显示）
var _wheel_center := Vector2.ZERO
var _wheel_r_in := 60.0
var _wheel_r_out := 220.0
var _wheel_hover := -1
var _wheel_ctl: Control

# 布局度量
var _vp := Vector2(1920, 1080)
var _m := 1080.0
var _u := 1.0
var _field := Rect2()
var _robber := Rect2()
var _spots: Array = []              # 三个弹弓位
var _badge := Rect2()

# 开发者模式
var _dev_pending := false
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_spd := 1.0                 # 劫匪速度倍率
var _dev_spawn := 1.0               # 生成间隔倍率
var _dev_drop := DROP_RATE          # 掉落率
var _dev_win: PanelContainer
var _dev_drag := false

# 音效
var _sfx := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button


func start() -> void:
	randomize()
	hud = GameHud.new("slingshot")
	_sling_tex = Glyph.load_png("slingshot.png")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_init_sfx()
	_wheel_ctl = Control.new()
	_wheel_ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wheel_ctl.visible = false
	_wheel_ctl.draw.connect(_draw_wheel)
	add_child(_wheel_ctl)
	# 抛物线预览顶层图层：根节点 _draw 在子节点（劫匪/子弹/掩体）之下会被遮挡
	_aim_layer = Node2D.new()
	_aim_layer.z_index = 100
	_aim_layer.visible = false
	_aim_layer.draw.connect(_draw_aim_preview)
	add_child(_aim_layer)
	# 人质容器：z_index 高于劫匪，劫匪移动时不会遮盖人质
	_hostage_box = Node2D.new()
	_hostage_box.z_index = 6
	add_child(_hostage_box)
	_layout()
	_new_game()


func stop() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0   # 防轮盘开启时退出，慢动作残留到主程序
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()
	print("[slingshot] stop, score=%d wave=%d" % [_score, _wave])


func _exit_button_pressed() -> void:
	exit_requested.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _wheel_open and _wheel_sticky:
					_wheel_hover_calc()
					if _wheel_hover >= 0:
						_select_bullet(_wheel_hover)
					_close_wheel()
				elif _badge.has_point(mb.position) and state == St.PLAY and not _wheel_open:
					_open_wheel(true)    # 点击底部徽章：弹出点击式轮盘
				elif state == St.PLAY and not _wheel_open and _reload <= 0.0:
					# 换弹冷却中 / 轮盘打开时不进入瞄准（避免预览弧误触发与飞行弧并存的"双抛物线"）
					_aiming = true
					_aim_spot = _nearest_spot()
					_linger = false   # 重新瞄准立即解除滞留
					# 空弹自动切回石头（抛物线预览同步显示石头）
					var acfg: Dictionary = BULLETS[_sel]
					if not bool(acfg.get("inf", false)) and int(_ammo.get(String(acfg.id), 0)) <= 0:
						_sel = 0
					_update_aim()
			elif _aiming:
				_aiming = false
				if state == St.PLAY:
					_fire()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if _aiming:              # 按住左键时右键 = 取消发射
					_aiming = false
					_play_sfx("cancel")
				elif state == St.PLAY and not _wheel_open:
					_open_wheel(false)   # 右键按住：拖拽轮盘
			elif _wheel_open and not _wheel_sticky:
				_wheel_hover_calc()
				if _wheel_hover >= 0:
					_select_bullet(_wheel_hover)   # 松开确认：选中当前悬停扇区
				_close_wheel()
	elif event is InputEventMouseMotion:
		if _aiming:
			_update_aim()
		if _wheel_open:
			_wheel_hover_calc()
	elif event is InputEventKey and event.pressed and not event.echo:
		var ke := event as InputEventKey
		if ke.keycode == KEY_ESCAPE and _wheel_open:
			_close_wheel()
		elif ke.keycode == KEY_R and state == St.PLAY:
			hud.commit_score()
			_new_game()


## ===== 新局 =====
func _new_game() -> void:
	state = St.PLAY
	_wave = 1
	_spawn_t = 0.0
	_score = 0
	_lives = LIVES0
	_combo = 0
	_endless_shown = false
	_over_t = 0.0
	_lb_shown = false
	_final_rank = -1
	_sel = 0
	_ammo = {}
	_aiming = false
	_hurt_t = 0.0
	_zones.clear()
	_pickups.clear()
	_turrets.clear()
	_wasps.clear()
	_fx.clear()
	_hostage_cd = 0.0
	for c in _hostage_box.get_children():
		c.queue_free()
	for c in _bandits.get_children():
		c.queue_free()
	for c in _shots.get_children():
		c.queue_free()
	hud.reset_run()
	_start_wave()   # 进入第 1 波（设置生成数并弹横幅；掩体在 _start_wave 内按波数随机生成）


## ===== 布局 =====
func _layout() -> void:
	_vp = get_viewport_rect().size
	_m = minf(_vp.x, _vp.y)
	_u = _m / 1080.0
	var fh: float = _vp.y * FIELD_H_R
	var fw: float = minf(fh, _vp.x * 0.96)
	_field = Rect2((_vp.x - fw) / 2.0, _vp.y * FIELD_TOP_R, fw, fh)
	_robber = Rect2(_field.position, Vector2(fw, fh * ROBBER_FRAC))
	_spots.clear()
	for off: float in SLING_OFFS:
		_spots.append(Vector2(_field.position.x + fw * off, _field.end.y - fh * 0.10))
	_badge = Rect2((_vp.x - 190.0 * _u) / 2.0, _vp.y - 78.0 * _u, 190.0 * _u, 60.0 * _u)
	for b: Label in [_board_score, _board_wave, _board_lives]:
		b.add_theme_font_size_override("font_size", int(_m * FONT_RATIO))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((_vp.x - _hud_bar.size.x) / 2.0, 14.0)
	var hbox := get_node_or_null("TopButtons")
	if hbox != null:
		hbox.reset_size()
		hbox.position = Vector2(_vp.x - hbox.size.x - 20.0, 14.0)


## ===== 右上角按钮排（同合集规范）=====
func _setup_buttons() -> void:
	var _hbox := HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	var lb_btn := GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	var bgm_btn := GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")
	lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [lb_btn, bgm_btn, _volume_btn, _restart_btn, _exit_btn]:
		_hbox.add_child(b)
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 32)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_on_restart)
	bgm_btn.pressed.connect(_on_bgm.bind(bgm_btn))
	_volume_btn.pressed.connect(_on_volume)
	_hbox.reset_size()
	_hbox.set_meta("hbox", true)
	_hbox.position = Vector2(_vp.x - _hbox.size.x - 20.0, 14.0)


func _on_lb() -> void:
	var title: String = hud.t("ui.top10", "Top 10")
	hud.show_leaderboard(self, title, -1, -1)
	_arm_dev_clicks()


func _on_restart() -> void:
	if state == St.PLAY:
		hud.commit_score()
		_new_game()


func _on_bgm(bgm_btn: Button) -> void:
	hud.cycle_bgm()
	bgm_btn.icon = hud.bgm_icon()
	if _bgm != null:
		if hud.bgm_on and not _bgm.playing:
			_bgm.play()
		elif not hud.bgm_on and _bgm.playing:
			_bgm.stop()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


func on_leaderboard_closed() -> void:
	if _dev_pending:
		_dev_pending = false
		_show_dev_window()
	if state == St.OVER:
		_new_game()


## ===== 主循环 =====
func _process(delta: float) -> void:
	# 击中顿帧：短暂全场慢速（与轮盘 time_scale 独立叠加）
	var dt := delta
	if _hitstop > 0.0:
		_hitstop -= delta
		dt = delta * 0.12
	# 屏幕震动：随机偏移快速衰减
	_shake = maxf(_shake - delta * 70.0, 0.0)
	if _shake > 0.5:
		position = Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake))
	elif position != Vector2.ZERO:
		position = Vector2.ZERO
	_hurt_t = maxf(_hurt_t - delta, 0.0)
	_reload = maxf(_reload - delta, 0.0)
	_hostage_cd = maxf(_hostage_cd - delta, 0.0)
	_tick_fx(dt)
	if state == St.PLAY:
		_tick_wave(dt)
		_tick_zones(dt)
		_tick_turrets(dt)
		_tick_wasps(dt)
		_tick_shots(dt)
		_tick_pickups(dt)
	elif state == St.OVER:
		_over_t -= delta
		if _over_t <= 0.0 and not _lb_shown:
			_lb_shown = true
			_final_rank = hud.commit_score()
			var title: String = hud.t("ui.top10", "Top 10")
			hud.show_leaderboard(self, title, _score, _final_rank)
			_arm_dev_clicks()
	queue_redraw()
	if _wheel_open:
		_wheel_ctl.queue_redraw()   # 悬停高亮实时跟随鼠标（否则轮盘停留在打开瞬间的静态帧）
	if _aim_layer != null:
		_aim_layer.visible = _aiming
		if _aiming:
			_aim_layer.queue_redraw()


## 劫匪受击回调（bandit.take_damage 调用）：死亡长顿、普命短顿
func on_bandit_hit(fatal: bool) -> void:
	_hitstop = 0.06 if fatal else 0.025


## ===== 波次 =====
func _tick_wave(delta: float) -> void:
	if _wph == Wph.BREAK:
		_wave_t -= delta
		if _wave_t <= 0.0:
			_wph = Wph.RUN
			_spawn_t = 0.3
		return
	if _wph == Wph.ESCAPE:
		# 人质撤离：移除跑出屏幕者；全部离场后才进入下一波
		for h0: Node in _hostage_box.get_children():
			if is_instance_valid(h0) and (h0 as Node2D).position.y > _vp.y + 80.0:
				h0.queue_free()
		if _hostage_box.get_child_count() == 0:
			_lives = mini(_lives + 1, LIVES_CAP)   # 过关 +1 命
			_wave += 1
			_start_wave()
		return
	if _spawn_left > 0:
		_spawn_t -= delta
		if _spawn_t <= 0.0 and _alive_count() < MAX_ALIVE:
			_spawn_bandit()
			_spawn_left -= 1
			_spawn_t = SPAWN_IV * _dev_spawn
	elif _alive_count() == 0:
		var has_alive := false
		for h0: Node in _hostage_box.get_children():
			if is_instance_valid(h0) and not (h0 as Node2D).escaped:
				has_alive = true
				break
		if has_alive:
			# 过关：人质挣脱绳子撤离，人群欢呼，跑出屏幕后才开始下一波
			_wph = Wph.ESCAPE
			_play_sfx("cheer", -6.0)
			for h1: Node in _hostage_box.get_children():
				if is_instance_valid(h1):
					(h1 as Node2D).escaped = true
					(h1 as Node2D).queue_redraw()
		else:
			_lives = mini(_lives + 1, LIVES_CAP)   # 过关 +1 命
			_wave += 1
			_start_wave()


## 人质：第 1 波 1 个，第 3 / 第 6 波各 +1，此后不再增加；位于劫匪区上部 1/3 随机位置（避开掩体与人质互叠）
func _gen_hostages() -> void:
	var want := 1
	if _wave >= 6:
		want = 3
	elif _wave >= 3:
		want = 2
	var have := 0
	for c in _hostage_box.get_children():
		if is_instance_valid(c):
			have += 1
	for i in range(have, want):
		var p := Vector2.ZERO
		for try in 24:
			p = Vector2(randf_range(_robber.position.x + 70.0 * _u, _robber.end.x - 70.0 * _u),
					randf_range(_robber.position.y + 40.0 * _u, _robber.position.y + _robber.size.y / 3.0))
			var ok := true
			for w: Dictionary in _walls:
				if _obb_contains(p, w, 44.0 * _u):
					ok = false
					break
			if ok:
				for h0: Node in _hostage_box.get_children():
					if (h0 as Node2D).position.distance_to(p) < 110.0 * _u:
						ok = false
						break
			if ok:
				break
		var hs: Node2D = Hostage.new()
		hs.position = p
		hs.scl = _u
		_hostage_box.add_child(hs)


## 波次人数：第 1 波 3 人，之后每波 +1~2（无尽后封顶 14）
func _wave_count(n: int) -> int:
	var c := 3
	for i in range(2, n + 1):
		c += 1 + (randi() % 2)
	return mini(c, 14)


func _start_wave() -> void:
	_wph = Wph.BREAK
	_wave_t = WAVE_BREAK_T
	_spawn_left = _wave_count(_wave)
	_gen_walls(mini(WALLS_N + maxi(0, _wave - 2), 6))   # 每波随机重新生成掩体：波 3 起每波 +1，最多 6
	_gen_hostages()   # 人质：第 1 关 1 个，第 3 关 +1，第 6 关 +1，此后不增（按需补足）
	if _wave >= ENDLESS_WAVE:
		if not _endless_shown:
			_endless_shown = true
			_popup_center(hud.t("popup.endless", "ENDLESS"), Color(1.0, 0.55, 0.20))
		else:
			_popup_center(hud.t("popup.wave", "WAVE %d") % _wave, Color(1.0, 0.85, 0.25))
	else:
		_popup_center(hud.t("popup.wave", "WAVE %d") % _wave, Color(1.0, 0.85, 0.25))
	_refresh_hud()


## 难度倍率（第 10 波冻结）：血量每波 +10% 封顶 ×2，移速每波 +2% 封顶 ×2
func _hp_mult() -> float:
	return minf(1.0 + 0.10 * float(mini(_wave, ENDLESS_WAVE) - 1), 2.0)


func _spd_mult() -> float:
	return minf(1.0 + 0.02 * float(mini(_wave, ENDLESS_WAVE) - 1), 2.0)


func _alive_count() -> int:
	var n := 0
	for c in _bandits.get_children():
		if is_instance_valid(c) and not c.dead:
			n += 1
	return n


## 按波次权重挑劫匪类型
func _pick_kind() -> Dictionary:
	var pool: Array = []
	for k: Dictionary in KINDS:
		if _wave >= int(k.wave):
			var w := 10.0
			match String(k.id):
				"agile":
					w = 6.0
				"thrower":
					w = 5.0
				"armored":
					w = 2.0 + minf(float(_wave - 5), 5.0)
			pool.append([k, w])
	var total := 0.0
	for p: Array in pool:
		total += float(p[1])
	var roll: float = randf() * total
	for p: Array in pool:
		roll -= float(p[1])
		if roll <= 0.0:
			return p[0]
	return KINDS[0]


func _spawn_bandit() -> void:
	var k := _pick_kind()
	var p := _rand_spawn_pos()
	var b: Bandit = Bandit.new()
	b.game = self
	b.kind = String(k.id)
	b.hp_max = float(k.hp) * _hp_mult()
	b.hp = b.hp_max
	b.speed = float(k.speed) * _spd_mult() * _dev_spd
	b.score = int(k.score)
	b.radius = float(k.radius) * _u
	b.dodge = float(k.dodge)
	b.armor = float(k.armor)
	b.col_body = k.body
	b.col_hat = k.hat
	b.position = p
	b._wp = p
	b.throw_cd = randf_range(1.5, 3.5)
	_bandits.add_child(b)


func _rand_spawn_pos() -> Vector2:
	for i in 30:
		var p := Vector2(
			randf_range(_robber.position.x + 40.0 * _u, _robber.end.x - 40.0 * _u),
			randf_range(_robber.position.y + 40.0 * _u, _robber.end.y - 40.0 * _u))
		if _circle_blocked(p, 26.0 * _u):
			continue
		var ok := true
		for c in _bandits.get_children():
			if is_instance_valid(c) and not c.dead and c.position.distance_to(p) < 70.0 * _u:
				ok = false
				break
		if ok:
			return p
	return _robber.get_center()


## ===== 掩体（旋转砖墙 OBB）=====
func _gen_walls(n: int) -> void:
	_walls.clear()
	var angles := [0.0, PI / 2.0, PI / 4.0, -PI / 4.0, PI / 6.0, -PI / 6.0, PI / 3.0, -PI / 3.0]
	var tries := 0
	while _walls.size() < n and tries < 120:
		tries += 1
		var he := Vector2(randf_range(52.0, 118.0) * _u, randf_range(13.0, 20.0) * _u)
		var c := Vector2(
			randf_range(_robber.position.x + 90.0 * _u, _robber.end.x - 90.0 * _u),
			randf_range(_robber.position.y + 60.0 * _u, _robber.end.y - 60.0 * _u))
		var rot: float = angles[randi() % angles.size()]
		var bad := false
		for w: Dictionary in _walls:
			if c.distance_to(w.c) < (he.length() + (w.he as Vector2).length() + 36.0 * _u):
				bad = true
				break
		if bad:
			continue
		_walls.append({"c": c, "he": he, "rot": rot})


func _obb_local(p: Vector2, w: Dictionary) -> Vector2:
	return (p - (w.c as Vector2)).rotated(-float(w.rot))


func _obb_contains(p: Vector2, w: Dictionary, m: float) -> bool:
	var l := _obb_local(p, w)
	var he := w.he as Vector2
	return absf(l.x) <= he.x + m and absf(l.y) <= he.y + m


func _obb_dist(p: Vector2, w: Dictionary) -> float:
	var l := _obb_local(p, w)
	var he := w.he as Vector2
	var dx: float = maxf(absf(l.x) - he.x, 0.0)
	var dy: float = maxf(absf(l.y) - he.y, 0.0)
	return Vector2(dx, dy).length()


func _circle_blocked(p: Vector2, r: float) -> bool:
	for w: Dictionary in _walls:
		if _obb_dist(p, w) < r:
			return true
	return false


## 线段是否被掩体遮挡（溅射 LOS 判定，采样步进）
func _los_blocked(a: Vector2, b: Vector2) -> bool:
	var d: float = a.distance_to(b)
	var steps := maxi(int(d / (8.0 * _u)), 1)
	for i in range(1, steps):
		var p := a.lerp(b, float(i) / float(steps))
		for w: Dictionary in _walls:
			if _obb_contains(p, w, 0.0):
				return true
	return false


## ===== 劫匪 AI 支撑（bandit.gd 回调）=====
## 漫游路点：掩体附近点与空地点各半随机（不分难度），劫匪在掩体间穿行、不进墙不越界；
## 若当前没有任何劫匪处于"石头可打"位置，强制选一个可打位，保证玩家始终有目标不卡关
func roam_point(panic: bool, _b: Node2D) -> Vector2:
	var need_open := _reachable_count() == 0
	for i in 30:
		var p: Vector2
		if not panic and not need_open and not _walls.is_empty() and randf() < 0.5:
			var w: Dictionary = _walls[randi() % _walls.size()]
			var he := w.he as Vector2
			p = (w.c as Vector2) + Vector2.from_angle(randf() * TAU) * (maxf(he.x, he.y) + 52.0 * _u)
		else:
			p = Vector2(
				randf_range(_robber.position.x + 34.0 * _u, _robber.end.x - 34.0 * _u),
				randf_range(_robber.position.y + 34.0 * _u, _robber.end.y - 34.0 * _u))
		p.x = clampf(p.x, _robber.position.x + 26.0 * _u, _robber.end.x - 26.0 * _u)
		p.y = clampf(p.y, _robber.position.y + 26.0 * _u, _robber.end.y - 26.0 * _u)
		if _circle_blocked(p, 22.0 * _u):
			continue
		if need_open and not _stone_reachable(p):
			continue
		return p
	return _robber.get_center()


## 场上处于"石头可打"位置的劫匪数
func _reachable_count() -> int:
	var n := 0
	for c in _bandits.get_children():
		if is_instance_valid(c) and not c.dead and _stone_reachable(c.position):
			n += 1
	return n


## 石头可打判定：从任一弹弓位到目标点的地面视线不被掩体遮挡
## （石头弧线低平，地面视线不被挡则必然可达；被挡只是保守排除）
func _stone_reachable(p: Vector2) -> bool:
	for sp: Vector2 in _spots:
		if not _los_blocked(sp, p):
			return true
	return false


## 带滑动避障的移动：目标点出界 / 撞墙时依次尝试单轴滑动与斜向绕行，全部受阻则原地
func bandit_slide(b: Node2D, to: Vector2) -> Vector2:
	var r: float = b.radius * 0.8
	var p := to
	p.x = clampf(p.x, _robber.position.x + r, _robber.end.x - r)
	p.y = clampf(p.y, _robber.position.y + r, _robber.end.y - r)
	if not _circle_blocked(p, r):
		return p
	# 单轴滑动（沿墙滑）
	var only_x := Vector2(p.x, b.position.y)
	var only_y := Vector2(b.position.x, p.y)
	if not _circle_blocked(only_x, r):
		return only_x
	if not _circle_blocked(only_y, r):
		return only_y
	# 斜向绕行：先沿偏好侧试探（side 固定 ±1，防止左右交替原地摇摆），含卡进墙边时的脱困
	var dir := p - b.position
	var dist := minf(dir.length(), r * 1.6)
	if dist > 0.5:
		var sgn: float = b.side
		for ang: float in [sgn * PI / 4.0, sgn * PI / 2.0, sgn * PI * 0.75, -sgn * PI / 4.0, -sgn * PI / 2.0, -sgn * PI * 0.75]:
			var q := b.position + dir.rotated(ang).normalized() * dist
			q.x = clampf(q.x, _robber.position.x + r, _robber.end.x - r)
			q.y = clampf(q.y, _robber.position.y + r, _robber.end.y - r)
			if not _circle_blocked(q, r):
				return q
	return b.position


## 持续伤害（毒雾，无视护甲）
func bandit_dot(b: Node2D, dmg: int) -> void:
	if b.dead:
		return
	b.hp -= float(dmg)
	if b.hp <= 0.0:
		b.dead = true
		_on_bandit_died(b)


## 投掷手反击：原地瞄准 2 秒后朝玩家弹弓当前位置抛石块（属性与玩家石头子弹一致）
func bandit_throw(b: Node2D) -> void:
	var stone: Dictionary = BULLETS[0]
	var s: Bullet = Bullet.new()
	s.mode = "rock"
	s.comboed = true          # 劫匪石块不参与玩家连击结算
	s.from = b.position
	s.to = _sling_pos()
	s.flight = float(stone.flight)
	s.arc_px = float(stone.arc) * _field.size.y
	s.ground = b.position
	_shots.add_child(s)
	_play_sfx("rockthrow", -4.0)


## ===== 射击 =====
func _nearest_spot() -> int:
	var mx: float = get_global_mouse_position().x
	var best := 0
	var bd := 1e9
	for i in _spots.size():
		var d: float = absf((_spots[i] as Vector2).x - mx)
		if d < bd:
			bd = d
			best = i
	return best


## 当前弹弓位索引：瞄准锁定 > 发射滞留 > 离鼠标最近
func _sling_idx() -> int:
	if _aiming:
		return _aim_spot
	if _linger:
		return _linger_spot
	return _nearest_spot()


func _sling_pos() -> Vector2:
	return _spots[_sling_idx()]


func _update_aim() -> void:
	# 瞄准中锁定弹弓位（_aim_spot 在按下时确定，移动鼠标只调落点不换位）
	var mp := get_global_mouse_position()
	_aim_target = Vector2(
		clampf(mp.x, _field.position.x + 8.0 * _u, _field.end.x - 8.0 * _u),
		clampf(mp.y, _field.position.y + 8.0 * _u, _field.end.y - 8.0 * _u))


## 回旋镖椭圆几何：起飞点 sp → 最远点 target（长轴两端），供发射与预览共用
func _boom_geom(sp: Vector2, target: Vector2) -> Dictionary:
	var span: float = maxf((target - sp).length(), 120.0 * _u)
	var dir: Vector2 = (target - sp).normalized() if span > 0.5 else Vector2.RIGHT
	var ba: float = span * 0.5
	return {"center": sp + dir * ba, "dir": dir, "ba": ba, "bb": span * 0.30}


func _cfg(id: String) -> Dictionary:
	for b: Dictionary in BULLETS:
		if String(b.id) == id:
			return b
	return BULLETS[0]


func _fire() -> void:
	if _reload > 0.0:
		return   # 换弹冷却中
	var cfg: Dictionary = BULLETS[_sel]
	var id := String(cfg.id)
	if not bool(cfg.get("inf", false)) and int(_ammo.get(id, 0)) <= 0:
		_sel = 0   # 空弹兜底：自动切回石头并直接发射石头
		cfg = BULLETS[_sel]
		id = String(cfg.id)
	if not bool(cfg.get("inf", false)):
		_ammo[id] = int(_ammo.get(id, 0)) - 1
		if int(_ammo.get(id, 0)) <= 0 and _sel != 0:
			_sel = 0   # 打光自动切回石头
	var s: Bullet = Bullet.new()
	s.mode = "shot"
	s.kind = id
	# 发射起点 = 本次瞄准锁定的弹弓位（松开时 _aiming 已复位，不能走 _sling_pos 的最近位分支）
	_linger = true          # 弹弓原地滞留到子弹消失
	_linger_spot = _aim_spot
	var sp := _spots[_aim_spot] as Vector2
	var dir := (_aim_target - sp).normalized()
	s.from = sp + dir * 26.0 * _u
	s.to = _aim_target
	s.flight = float(cfg.flight)
	s.arc_px = float(cfg.arc) * _field.size.y
	s.pierce = int(cfg.get("pierce", 0))
	if bool(cfg.get("boomerang", false)):
		# 回旋镖：水平椭圆绕行一圈回到起飞点；全程穿透，撞掩体损毁
		# 椭圆最远点 = 鼠标落点（长轴 = 起飞点→落点距离，中心在其一半处）
		s.pierce = 99
		s.boom_home = sp
		var g: Dictionary = _boom_geom(sp, _aim_target)
		s.ba = g.ba
		s.bb = g.bb
		s.bdir = g.dir
		s.bcenter = g.center
	s.ground = s.from
	_shots.add_child(s)
	_reload = RELOAD_T      # 换弹冷却
	_play_sfx("throw")
	_refresh_hud()


func _tick_shots(delta: float) -> void:
	var children := _shots.get_children()
	for s: Bullet in children:
		if not is_instance_valid(s) or s.done:
			if is_instance_valid(s):
				s.queue_free()
				_settle_combo(s)
			continue
		# 引信等待（鞭炮落地）
		if s.state == 1:
			s.fuse -= delta
			if s.fuse <= 0.0:
				_explode(s)
			continue
		s.t += delta
		var u: float = s.u()
		if s.kind == "boomerang":
			# 回旋镖：水平椭圆绕行（θ 从 π 扫一圈回到 π，h 恒 0 → 必被掩体拦下）
			s.ground = s.boom_point(u)
			s.h = 0.0
		else:
			s.ground = s.from.lerp(s.to, u)
			s.h = s.arc_px * 4.0 * u * (1.0 - u)
		s.position = s.ground   # 节点位置同步（否则子弹静止在原点，看不到抛物线飞行）
		if s.mode == "rock":
			# 石块与玩家子弹同规则：经过掩体上方时高度低于墙高则被挡
			if s.h < WALL_H * _u:
				for w: Dictionary in _walls:
					if _obb_contains(s.ground, w, 2.0 * _u):
						_spawn_burst(s.ground, Color(0.52, 0.48, 0.44), 8, 130.0, 4.0 * _u)
						_play_sfx("wall", -4.0)
						s.done = true
						break
				if s.done:
					continue
			if u >= 1.0:
				_rock_land(s)
			continue
		# 撞墙：子弹经过掩体上方时高度低于墙高 → 碎裂；弧线高处飞越
		if s.h < WALL_H * _u:
			var walled := false
			for w: Dictionary in _walls:
				if _obb_contains(s.ground, w, 2.0 * _u):
					walled = true
					break
			if walled:
				_spawn_burst(s.ground, Color(0.62, 0.36, 0.24), 8, 130.0, 4.0 * _u)
				_play_sfx("wall", -4.0)
				s.done = true
				_settle_combo(s)
				continue
		# 误击人质：扣 1 条命（5 秒内只扣一次），子弹消失（撤离中的不惩罚）
		if s.mode == "shot" and s.h < HOSTAGE_H * _u:
			for hs: Node2D in _hostage_box.get_children():
				if is_instance_valid(hs) and not hs.escaped and s.ground.distance_to(hs.position) < HOSTAGE_R * _u:
					_spawn_burst(s.ground, Color(0.85, 0.80, 0.70), 8, 130.0, 4.0 * _u)
					_play_sfx("thud", -4.0)
					_hostage_punish()
					s.done = true
					break
			if s.done:
				continue
		# 命中劫匪
		if s.h < BODY_H * _u:
			var consumed := false
			for b: Bandit in _bandits.get_children():
				if not is_instance_valid(b) or b.dead or b.spawn_t > 0.15 or s.hits.has(b):
					continue
				if s.ground.distance_to(b.position) > b.radius + 10.0 * _u:
					continue
				# 敏捷劫匪概率闪避：侧移闪开，子弹继续飞行
				if b.dodge > 0.0 and b.stun_t <= 0.0 and randf() < b.dodge:
					var away := (b.position - s.ground).normalized()
					if away.length_squared() > 0.0001:
						b.do_dash(away.rotated(PI / 2.0 * (1.0 if randf() < 0.5 else -1.0)))
					_spawn_burst(b.position, Color(0.9, 0.9, 0.9), 4, 90.0, 3.0 * _u)
					continue
				if s.pierce > 0:
					s.pierce -= 1
					s.hits.append(b)
					s.hit_any = true
					_direct_hit(s, b)
				else:
					_land_bullet(s, s.ground, b)
					consumed = true
					break
			if consumed:
				continue
		# 到达落点
		if u >= 1.0:
			if s.kind == "boomerang":
				# 绕行一圈回到起飞点：弹弓仍在此位则回收返还弹药，否则消失
				if _sling_pos().distance_to(s.boom_home) < 14.0 * _u:
					_ammo[s.kind] = int(_ammo.get(s.kind, 0)) + 1
					_popup_at(s.ground + Vector2(0, -40.0 * _u), "+1", Color(0.45, 0.85, 0.45))
					_play_sfx("catch")
				_spawn_burst(s.ground, Color(0.72, 0.50, 0.26), 5, 90.0, 3.0 * _u)
				s.done = true
				_settle_combo(s)
			else:
				_land_bullet(s, s.to, null)
	# 滞留过期：场上没有存活玩家子弹时，弹弓恢复跟随鼠标（每帧检查，放循环外）
	if _linger:
		var any_alive := false
		for bs: Bullet in _shots.get_children():
			if is_instance_valid(bs) and not bs.done and bs.mode == "shot":
				any_alive = true
				break
		if not any_alive:
			_linger = false


## 直击（穿透类：刀片 / 回旋镖）
func _direct_hit(s: Bullet, b: Bandit) -> void:
	var cfg := _cfg(s.kind)
	_spawn_burst(b.position, Color(0.95, 0.30, 0.25), 5, 110.0, 3.0 * _u)
	_play_sfx("splat", -6.0)
	if b.take_damage(float(cfg.dmg), s.ground, float(cfg.get("knock", 0.0))):
		_on_bandit_died(b)


## 子弹落地结算（direct=直接命中的劫匪，可为 null）
func _land_bullet(s: Bullet, pos: Vector2, direct: Bandit) -> void:
	var cfg := _cfg(s.kind)
	var id := String(cfg.id)
	match id:
		"firecracker":   # 落地 / 命中后延迟 0.3s 爆炸
			s.from = pos
			s.to = pos
			s.t = s.flight
			s.ground = pos
			s.h = 0.0
			s.state = 1
			s.fuse = float(cfg.get("fuse", 0.3))
			return
		"egg", "tomato", "balloon", "stink", "bottle":
			_splash_apply(s, cfg, pos, direct)
		"turret":   # 落地部署自动炮台：周期性射击最近劫匪
			_turrets.append({"pos": pos, "t": 0.0, "dur": 9.0, "cd": 0.6, "beam": 0.0, "beam_to": Vector2.ZERO})
			_spawn_burst(pos, Color(0.55, 0.60, 0.66), 6, 90.0, 3.0 * _u)
			_play_sfx("latch", -8.0)
		"wasp":   # 落地炸出 3 只复仇黄蜂：各追最近劫匪蛰 3 次
			for i in 3:
				_wasps.append({"pos": pos + Vector2.from_angle(randf() * TAU) * 10.0 * _u,
						"cd": 0.35, "stings": 3, "wob": randf() * TAU})
			_spawn_burst(pos, Color(0.95, 0.80, 0.25), 8, 130.0, 3.0 * _u)
			_play_sfx("latch", -8.0)
		_:
			# 石头 / 苹果 / 铅球 / 刀片终点：单体直击效果
			if direct != null and is_instance_valid(direct) and not direct.dead:
				var stun: float = float(cfg.get("stun", 0.0))
				if stun > 0.0:
					direct.stun_t = maxf(direct.stun_t, stun)
					_play_sfx("stun", -6.0)
				if float(cfg.get("knock", 0.0)) > 0.0:
					_shake = maxf(_shake, 8.0 * _u)   # 铅球等重击震屏
				s.hit_any = true
				if direct.take_damage(float(cfg.dmg), pos, float(cfg.get("knock", 0.0))):
					_on_bandit_died(direct)
			_spawn_burst(pos, Color(0.75, 0.72, 0.68), 6, 100.0, 3.0 * _u)
	s.done = true
	_settle_combo(s)


## 溅射结算：直接命中目标全额+效果；范围内敌人有掩体遮挡（无 LOS）则半伤无效果
func _splash_apply(s: Bullet, cfg: Dictionary, pos: Vector2, direct: Bandit) -> void:
	var r_px: float = float(cfg.splash) * _field.size.x
	var stun: float = float(cfg.get("stun", 0.0))
	var hit_any := false
	# 溅射伤害
	for b: Bandit in _bandits.get_children():
		if not is_instance_valid(b) or b.dead:
			continue
		var is_direct: bool = b == direct
		if not is_direct and b.position.distance_to(pos) > r_px + b.radius:
			continue
		var walled := _los_blocked(pos, b.position)
		if walled and not is_direct:
			b.take_damage(float(cfg.dmg) * 0.5, pos, 0.0)   # 掩体边缘半伤
		else:
			hit_any = true
			if stun > 0.0:
				b.stun_t = maxf(b.stun_t, stun)
			if b.take_damage(float(cfg.dmg), pos, 0.0):
				_on_bandit_died(b)
	# 地面区域（蛋液滑 / 水渍 / 毒雾）
	var zone_kind := String(cfg.get("zone", ""))
	if zone_kind != "":
		var dur := 10.0
		if zone_kind == "poison":
			dur = 6.0
		var blobs: Array = []
		for i in 4:
			blobs.append(Vector2.from_angle(randf() * TAU) * randf() * r_px * 0.55)
		_zones.append({"kind": zone_kind, "pos": pos, "r": r_px, "t": 0.0, "dur": dur, "blobs": blobs})
	# 玻璃瓶碎片散射：溅射圈外圈的敌人受二次伤害
	if bool(cfg.get("shards", false)):
		var outer: float = r_px * 1.9
		var n := 0
		for b: Bandit in _bandits.get_children():
			if n >= 3:
				break
			if not is_instance_valid(b) or b.dead or b == direct:
				continue
			if b.position.distance_to(pos) > r_px + b.radius and b.position.distance_to(pos) <= outer + b.radius:
				n += 1
				_spawn_burst(b.position, Color(0.62, 0.85, 0.66), 4, 120.0, 2.5 * _u)
				if b.take_damage(1.0, pos, 0.0):
					_on_bandit_died(b)
		_play_sfx("shard", -4.0)
	# 落地表现
	var col := Color(0.93, 0.90, 0.55)
	match String(cfg.id):
		"tomato":
			col = Color(0.86, 0.22, 0.18)
		"balloon":
			col = Color(0.32, 0.56, 0.90)
		"stink":
			col = Color(0.62, 0.76, 0.34)
		"bottle":
			col = Color(0.30, 0.62, 0.38)
	_spawn_burst(pos, col, 10, 140.0, 4.0 * _u)
	if stun > 0.0:
		_play_sfx("stun", -4.0)
	else:
		_play_sfx("splat", -3.0)
	s.hit_any = s.hit_any or hit_any


## 鞭炮爆炸：全额伤害，范围伤害可绕过掩体
func _explode(s: Bullet) -> void:
	var cfg := _cfg("firecracker")
	var r_px: float = float(cfg.splash) * _field.size.x
	for b: Bandit in _bandits.get_children():
		if not is_instance_valid(b) or b.dead:
			continue
		if b.position.distance_to(s.ground) <= r_px + b.radius:
			s.hit_any = true
			if b.take_damage(float(cfg.dmg), s.ground, 0.0):
				_on_bandit_died(b)
	for i in 22:
		var a := randf() * TAU
		_spawn_fx(s.ground + Vector2.from_angle(a) * randf() * r_px * 0.4,
			[Color(1.0, 0.80, 0.25), Color(0.95, 0.45, 0.15), Color(0.35, 0.33, 0.30)][randi() % 3],
			randf_range(3.0, 7.0) * _u, randf_range(80.0, 260.0), 0.55)
	_play_sfx("boom")
	_shake = maxf(_shake, 12.0 * _u)   # 爆炸震屏
	s.done = true
	_settle_combo(s)


func _nearest_bandit(pos: Vector2, max_r: float) -> Bandit:
	var best: Bandit = null
	var bd := max_r
	for b: Bandit in _bandits.get_children():
		if not is_instance_valid(b) or b.dead:
			continue
		var d: float = b.position.distance_to(pos)
		if d < bd:
			bd = d
			best = b
	return best


## 劫匪死亡：计分（含连击倍率）+ 掉落 + 特效
func _on_bandit_died(b: Bandit) -> void:
	if not is_instance_valid(b):
		return
	var pts := int(round(float(b.score) * _combo_mult()))
	_score += pts
	hud.submit_score(_score)
	_popup_at(b.position, "+%d" % pts, Color(1.0, 0.85, 0.25))
	_spawn_burst(b.position, b.col_body, 14, 170.0, 5.0 * _u)
	_play_sfx("splat")
	if randf() < _dev_drop:
		var ids: Array = []
		for cfg: Dictionary in BULLETS:
			if not bool(cfg.get("inf", false)):
				ids.append(String(cfg.id))
		_pickups.append({"kind": ids[randi() % ids.size()], "pos": b.position, "t": 0.0, "n": randi_range(5, 10)})
	# 死亡弹飞：沿弹弓→劫匪方向旋转飞出压扁（尸体由 bandit 自行计时移除）
	var dir: Vector2 = b.position - _sling_pos()
	b.die_launch(dir.normalized() if dir.length_squared() > 1.0 else Vector2.UP)
	_refresh_hud()


## 连击结算：本次投射命中过 → 连击 +1；全程未命中 → 清零
func _settle_combo(s: Bullet) -> void:
	if s.comboed:
		return
	s.comboed = true
	if s.hit_any:
		_combo += 1
	else:
		_combo = 0


func _combo_mult() -> float:
	return minf(1.0 + 0.1 * float(_combo), 3.0)


## ===== 劫匪石块落点 =====
func _rock_land(s: Bullet) -> void:
	_spawn_burst(s.to, Color(0.52, 0.48, 0.44), 8, 120.0, 4.0 * _u)
	if s.to.distance_to(_sling_pos()) < ROCK_HIT_R * _u:
		_player_hit()
	else:
		_play_sfx("thud", -6.0)
	s.done = true


## 误击人质惩罚：扣 1 条命（HOSTAGE_CD 秒内只扣一次），复用玩家受击流程
func _hostage_punish() -> void:
	if _hostage_cd > 0.0:
		return
	_hostage_cd = HOSTAGE_CD
	_player_hit()


func _player_hit() -> void:
	_lives -= 1
	_hurt_t = 0.5
	_play_sfx("lose")
	_popup_at(_sling_pos() + Vector2(0, -70.0 * _u), "-1", Color(0.95, 0.25, 0.20))
	if _lives <= 0:
		_lives = 0
		state = St.OVER
		_over_t = GAMEOVER_T
		_aiming = false
		_popup_center(hud.t("popup.gameover", "GAME OVER"), Color(0.95, 0.25, 0.20))
	_refresh_hud()


## ===== 地面区域（蛋液滑 / 水渍 / 毒雾）=====
func _tick_zones(delta: float) -> void:
	var i := 0
	while i < _zones.size():
		var z: Dictionary = _zones[i]
		z.t = float(z.t) + delta
		if float(z.t) >= float(z.dur):
			_zones.remove_at(i)
			continue
		i += 1
	for b: Bandit in _bandits.get_children():
		if not is_instance_valid(b) or b.dead:
			continue
		for z: Dictionary in _zones:
			if b.position.distance_to(z.pos as Vector2) > float(z.r) + b.radius * 0.5:
				continue
			match String(z.kind):
				"slick":
					b.slow_mult = 0.7
					b.slow_t = 0.30
				"water":
					b.slow_mult = 0.5
					b.slow_t = 0.30
				"poison":
					b.dot_acc += delta   # 毒雾 1 伤/秒


## ===== 掉落拾取：原地 1.5s 后飞向底部弹药徽章 =====
func _tick_pickups(delta: float) -> void:
	var i := 0
	var bp := _badge.get_center()
	while i < _pickups.size():
		var p: Dictionary = _pickups[i]
		p.t = float(p.t) + delta
		if float(p.t) > 1.5:
			var pos := p.pos as Vector2
			var to_badge := bp - pos
			if to_badge.length() < 30.0 * _u:
				var id := String(p.kind)
				var n := int(p.get("n", 1))
				_ammo[id] = int(_ammo.get(id, 0)) + n
				_play_sfx("pickup", -4.0)
				_popup_at(bp + Vector2(0, -40.0 * _u), "+%d" % n, Color(0.55, 0.85, 0.45))
				_pickups.remove_at(i)
				_refresh_hud()
				continue
			p.pos = pos + to_badge.normalized() * minf(to_badge.length(), delta * 1400.0)
		i += 1


## ===== 粒子 =====
func _spawn_fx(p: Vector2, col: Color, r: float, spd: float, dur: float) -> void:
	_fx.append({"p": p, "v": Vector2.from_angle(randf() * TAU) * spd * randf_range(0.4, 1.0),
		"r": r, "col": col, "t": 0.0, "dur": dur, "g": 260.0})


func _spawn_burst(p: Vector2, col: Color, n: int, spd: float, r: float) -> void:
	for i in n:
		_spawn_fx(p, col, r * randf_range(0.6, 1.3), spd * randf_range(0.5, 1.2), 0.45)


func _tick_fx(delta: float) -> void:
	var i := 0
	while i < _fx.size():
		var f: Dictionary = _fx[i]
		f.t = float(f.t) + delta
		if float(f.t) >= float(f.dur):
			_fx.remove_at(i)
			continue
		f.v = (f.v as Vector2) + Vector2(0, float(f.g)) * delta
		f.p = (f.p as Vector2) + (f.v as Vector2) * delta
		i += 1


## ===== 轮盘 =====
func _open_wheel(sticky: bool) -> void:
	_aiming = false
	_wheel_sticky = sticky
	# 可选子弹快照：无限弹药或剩余 > 0 才显示
	_wheel_ids.clear()
	for cfg: Dictionary in BULLETS:
		if bool(cfg.get("inf", false)) or int(_ammo.get(String(cfg.id), 0)) > 0:
			_wheel_ids.append(String(cfg.id))
	var m := _m
	_wheel_r_out = m * 0.205
	_wheel_r_in = m * 0.065
	_wheel_center = _badge.get_center() + Vector2(0, -_wheel_r_out - 30.0 * _u) if sticky else get_global_mouse_position()
	_wheel_center = Vector2(
		clampf(_wheel_center.x, _wheel_r_out + 16.0, _vp.x - _wheel_r_out - 16.0),
		clampf(_wheel_center.y, _wheel_r_out + 16.0, _vp.y - _wheel_r_out - 16.0))
	_wheel_hover = -1
	_wheel_hover_calc()
	_wheel_open = true
	_wheel_ctl.visible = true
	_wheel_ctl.queue_redraw()
	_play_sfx("click", -6.0)
	Engine.time_scale = 0.1   # 轮盘期间慢动作，方便选弹


func _close_wheel() -> void:
	_wheel_open = false
	_wheel_sticky = false
	_wheel_ctl.visible = false
	Engine.time_scale = 1.0


func _select_bullet(i: int) -> void:
	if i < 0 or i >= _wheel_ids.size():
		return
	var idx := 0
	for j in BULLETS.size():
		if String(BULLETS[j].id) == String(_wheel_ids[i]):
			idx = j
			break
	_sel = idx
	_play_sfx("click")
	_refresh_hud()


func _wheel_hover_calc() -> void:
	var n := _wheel_ids.size()
	if n <= 0:
		_wheel_hover = -1
		return
	var mp := get_global_mouse_position()
	var d := mp.distance_to(_wheel_center)
	if d < _wheel_r_in * 0.5 or d > _wheel_r_out * 1.15:
		_wheel_hover = -1
	else:
		# 从正上方起顺时针的扇区角系（与轮盘绘制一致）
		var a := fposmod(atan2(mp.y - _wheel_center.y, mp.x - _wheel_center.x) + PI / 2.0, TAU)
		_wheel_hover = int(a / (TAU / n)) % n


## 轮盘绘制（桌面破坏王样式：半透明黑底 + 扇区多边形高亮 + 图标右下角弹药数 + 中心当前子弹）
func _draw_wheel() -> void:
	if not _wheel_open or _wheel_ids.is_empty():
		return
	var w: Control = _wheel_ctl
	var c := _wheel_center
	var n := _wheel_ids.size()
	var seg := TAU / float(n)
	var font := ThemeDB.fallback_font
	# 底盘：半透明黑大圆
	w.draw_circle(c, _wheel_r_out + 10.0 * _u, Color(0.05, 0.05, 0.06, 0.55))
	for i in n:
		var a0 := -PI / 2.0 + i * seg + seg * 0.02
		var a1 := -PI / 2.0 + (i + 1) * seg - seg * 0.02
		# 扇区多边形（外弧 7 点 + 内弧 7 点），悬停白高亮 / 平时暗色
		var pts := PackedVector2Array()
		for k in 7:
			pts.append(c + Vector2.from_angle(a0 + (a1 - a0) * k / 6.0) * _wheel_r_out)
		for k in 7:
			pts.append(c + Vector2.from_angle(a1 - (a1 - a0) * k / 6.0) * _wheel_r_in)
		var cols := PackedColorArray()
		cols.resize(pts.size())
		var fill := Color(1, 1, 1, 0.10) if i == _wheel_hover else Color(0, 0, 0, 0.14)
		for k in pts.size():
			cols[k] = fill
		w.draw_polygon(pts, cols)
		# 图标（扇区中线 0.55 半径处，悬停放大）
		var id := String(_wheel_ids[i])
		var cfg: Dictionary = _cfg(id)
		var amid := -PI / 2.0 + (i + 0.5) * seg
		var ipos := c + Vector2.from_angle(amid) * (_wheel_r_in + (_wheel_r_out - _wheel_r_in) * 0.55)
		var ir := _wheel_r_out * (0.150 if i == _wheel_hover else 0.122)
		Glyph.draw_glyph(w, id, ir, ipos)
		w.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# 剩余弹药：图标内右下角小字（黑衬底保证可读，无限显示 ∞）
		var cnt := -1 if bool(cfg.get("inf", false)) else int(_ammo.get(id, 0))
		var txt := "∞" if cnt < 0 else str(cnt)
		var fs := int(maxf(ir * 0.62, 11.0))
		var tp := ipos + Vector2(ir * 0.52, ir * 0.52)
		w.draw_circle(tp, fs * 0.72, Color(0.05, 0.05, 0.06, 0.78))
		w.draw_string(font, tp + Vector2(-fs * 2.0, fs * 0.36), txt, HORIZONTAL_ALIGNMENT_CENTER, fs * 4.0, fs, Color.WHITE)
		# 悬停金色外弧描边；当前装备金色内弧
		if i == _wheel_hover:
			w.draw_arc(c, _wheel_r_out + 6.0 * _u, a0 - seg * 0.02, a1 + seg * 0.02, 8, Color(1.0, 0.85, 0.25), 4.0 * _u, true)
		if id == String(BULLETS[_sel].id):
			w.draw_arc(c, _wheel_r_in + 3.0 * _u, a0, a1, 8, Color(1.0, 0.85, 0.25, 0.9), 3.0 * _u, true)
	# 中心：悬停 / 当前子弹图标 + 名称
	var show: String = String(_wheel_ids[_wheel_hover]) if _wheel_hover >= 0 else String(BULLETS[_sel].id)
	var cc := Color(1.0, 0.85, 0.25) if _wheel_hover >= 0 else Color.WHITE
	w.draw_circle(c, _wheel_r_in * 0.92, Color(0.10, 0.10, 0.12, 0.9))
	Glyph.draw_glyph(w, show, _wheel_r_in * 0.52, c)
	w.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var name_txt: String = hud.t("bullet." + show, show.capitalize())
	var scfg: Dictionary = _cfg(show)
	var sub := "∞" if bool(scfg.get("inf", false)) else "×%d" % int(_ammo.get(show, 0))
	var fs2 := int(_m * 0.024)
	w.draw_string(font, c + Vector2(-_wheel_r_out, _wheel_r_in * 0.75 + fs2), "%s %s" % [name_txt, sub],
			HORIZONTAL_ALIGNMENT_CENTER, _wheel_r_out * 2.0, fs2, cc)
	# 底部操作提示
	var tip: String = hud.t("ui.wheel_sticky", "Click a sector to select · Click blank to close") if _wheel_sticky \
			else hud.t("ui.wheel_drag", "Hover to select · Release right button to confirm")
	w.draw_string(font, c + Vector2(-_wheel_r_out, _wheel_r_out + fs2 * 2.2),
			tip, HORIZONTAL_ALIGNMENT_CENTER, _wheel_r_out * 2.0, fs2, Color(1, 1, 1, 0.7))


## ===== HUD =====
func _refresh_hud() -> void:
	var s_sc: String = hud.t("hud.score", "Score %d")
	_board_score.text = s_sc % _score
	var s_wv: String = hud.t("hud.wave", "Wave %d")
	_board_wave.text = s_wv % _wave
	var s_lv: String = hud.t("hud.lives", "Lives %d")
	_board_lives.text = s_lv % _lives


## ===== 绘制（根节点 _draw 在子节点之下）=====
func _draw() -> void:
	_draw_field()
	_draw_zones()
	_draw_walls()
	_draw_pickups()
	_draw_deployables()
	_draw_sling()
	_draw_rock_warnings()
	_draw_fx()
	_draw_badge()
	if _hurt_t > 0.0:
		draw_rect(Rect2(Vector2.ZERO, _vp), Color(0.9, 0.1, 0.1, 0.28 * _hurt_t / 0.5))


func _draw_field() -> void:
	# 背景透明（参考 dart/breakout）：不填充场地、不画边框，透出主程序的桌面快照；元素靠黑描边保证可读性
	# 区域分隔线（黑衬底 + 白线，透明背景下任何桌面都可见）
	var sy: float = _robber.end.y
	draw_line(Vector2(_field.position.x, sy), Vector2(_field.end.x, sy), Color(0.08, 0.07, 0.06, 0.55), 5.0 * _u, true)
	draw_line(Vector2(_field.position.x, sy), Vector2(_field.end.x, sy), Color(1, 1, 1, 0.45), 2.0 * _u, true)
	# 弹弓位地垫
	var cur := _sling_idx()
	for i in _spots.size():
		var p := _spots[i] as Vector2
		draw_circle(p, 40.0 * _u, Color(0.11, 0.115, 0.105))
		draw_arc(p, 40.0 * _u, 0.0, TAU, 40, Color(1.0, 0.85, 0.25) if i == cur else Color(0, 0, 0, 0.5), 2.5 * _u, true)


## ===== 部署物（自动炮台 / 复仇黄蜂）=====
func _tick_turrets(delta: float) -> void:
	for i in range(_turrets.size() - 1, -1, -1):
		var tu: Dictionary = _turrets[i]
		tu.t = float(tu.t) + delta
		tu.beam = maxf(float(tu.beam) - delta, 0.0)
		if float(tu.t) >= float(tu.dur):
			_spawn_burst(tu.pos, Color(0.55, 0.60, 0.66), 5, 80.0, 3.0 * _u)
			_turrets.remove_at(i)
			continue
		tu.cd = float(tu.cd) - delta
		if float(tu.cd) > 0.0:
			continue
		var b := _nearest_bandit(tu.pos, _field.size.x * 0.15)   # 攻击半径 = 场地宽 15%
		if b == null:
			tu.cd = 0.25
			continue
		tu.cd = 0.6
		tu.beam = 0.12
		tu.beam_to = b.position
		_spawn_burst(b.position, Color(0.35, 0.70, 0.95), 2, 60.0, 2.0 * _u)
		if b.take_damage(float(_cfg("turret").dmg), tu.pos, -1.0):
			_on_bandit_died(b)


func _tick_wasps(delta: float) -> void:
	for i in range(_wasps.size() - 1, -1, -1):
		var w: Dictionary = _wasps[i]
		w.wob = float(w.wob) + delta * 14.0
		w.cd = float(w.cd) - delta
		# 每帧直接重找最近存活劫匪（与炮台一致，不缓存目标；波次间隙无目标则原地悬停等待）
		var tg: Bandit = _nearest_bandit(w.pos, 9999.0)
		if tg != null:
			if w.pos.distance_to(tg.position) > tg.radius * 0.7:
				w.pos = (w.pos as Vector2).move_toward(tg.position, 160.0 * _u * delta)
			elif float(w.cd) <= 0.0:
				w.cd = 0.45
				w.stings = int(w.stings) - 1
				_spawn_burst(tg.position + Vector2(0, -10.0 * _u), Color(0.95, 0.80, 0.25), 3, 80.0, 2.0 * _u)
				if tg.take_damage(float(_cfg("wasp").dmg), w.pos, -1.0):
					_on_bandit_died(tg)
		if int(w.stings) <= 0:
			_spawn_burst(w.pos, Color(0.95, 0.80, 0.25), 3, 60.0, 2.0 * _u)
			_wasps.remove_at(i)


func _draw_deployables() -> void:
	# 自动炮台（小机器人 + 攻击光线）
	for tu: Dictionary in _turrets:
		var t: float = float(tu.t)
		if t >= float(tu.dur) - 1.2 and fmod(t * 6.0, 1.0) > 0.5:
			continue   # 寿命将尽闪烁
		var p: Vector2 = tu.pos
		if float(tu.beam) > 0.0:
			var a: float = float(tu.beam) / 0.12
			draw_line(p + Vector2(0, -12.0 * _u), tu.beam_to, Color(0.35, 0.70, 0.95, 0.85 * a), 3.0 * _u, true)
			draw_line(p + Vector2(0, -12.0 * _u), tu.beam_to, Color(1, 1, 1, 0.6 * a), 1.2 * _u, true)
		draw_line(p + Vector2(-9.0 * _u, 2.0 * _u), p, Color(0.10, 0.08, 0.07), 4.0 * _u, true)
		draw_line(p + Vector2(9.0 * _u, 2.0 * _u), p, Color(0.10, 0.08, 0.07), 4.0 * _u, true)
		draw_circle(p + Vector2(0, -11.0 * _u), 10.0 * _u, Color(0.58, 0.64, 0.72))
		draw_arc(p + Vector2(0, -11.0 * _u), 10.0 * _u, 0.0, TAU, 24, Color(0.10, 0.08, 0.07), 2.0 * _u, true)
		draw_circle(p + Vector2(0, -11.0 * _u), 4.5 * _u, Color(0.30, 0.70, 0.95))
	# 复仇黄蜂（黄蜂体 + 扑翅）
	for w: Dictionary in _wasps:
		var p2: Vector2 = (w.pos as Vector2) + Vector2(sin(float(w.wob)) * 3.0, cos(float(w.wob) * 1.7) * 3.0) * _u
		var flap: float = sin(float(w.wob) * 2.0) * 2.0
		draw_circle(p2 + Vector2(-4.0 * _u, -5.0 * _u + flap * _u), 4.0 * _u, Color(1, 1, 1, 0.7))
		draw_circle(p2 + Vector2(4.0 * _u, -5.0 * _u - flap * _u), 4.0 * _u, Color(1, 1, 1, 0.7))
		draw_circle(p2, 5.0 * _u, Color(0.95, 0.78, 0.22))
		draw_arc(p2, 5.0 * _u, 0.0, TAU, 16, Color(0.10, 0.08, 0.07), 1.5 * _u, true)
		draw_line(p2 + Vector2(-1.5, 0) * _u, p2 + Vector2(-1.5, -7.0) * _u, Color(0.12, 0.10, 0.08), 2.2 * _u, true)
		draw_line(p2 + Vector2(1.5, 0) * _u, p2 + Vector2(1.5, -7.0) * _u, Color(0.12, 0.10, 0.08), 2.2 * _u, true)


func _draw_zones() -> void:
	for z: Dictionary in _zones:
		var remain: float = 1.0 - clampf((float(z.t) - (float(z.dur) - 1.5)) / 1.5, 0.0, 1.0) if float(z.t) > float(z.dur) - 1.5 else 1.0
		var col := Color(0.93, 0.90, 0.55)
		match String(z.kind):
			"water":
				col = Color(0.35, 0.60, 0.92)
			"poison":
				col = Color(0.45, 0.75, 0.30)
		col.a = 0.40 * remain
		draw_circle(z.pos as Vector2, float(z.r), col)
		col.a = 0.28 * remain
		for off: Vector2 in z.blobs:
			draw_circle((z.pos as Vector2) + off, float(z.r) * 0.30, col)


func _draw_walls() -> void:
	# 按 y 排序绘制：靠下的墙盖住靠上的墙
	var ws: Array = _walls.duplicate()
	ws.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.c as Vector2).y < (b.c as Vector2).y)
	var th := 7.0 * _u   # 底部厚度层偏移（纯扁平风的立体感：下缘黑厚度 + 落影）
	for w: Dictionary in ws:
		var he := w.he as Vector2
		var c := w.c as Vector2
		var rot := float(w.rot)
		# 地面落影（右下偏移的半透明块）
		draw_set_transform(c + Vector2(5.0 * _u, 9.0 * _u), rot, Vector2.ONE)
		draw_rect(Rect2(-he, he * 2.0), Color(0, 0, 0, 0.18))
		# 底部厚度层：向下偏移的黑层，形成下缘厚度
		draw_set_transform(c + Vector2(0, th), rot, Vector2.ONE)
		draw_rect(Rect2(-he, he * 2.0), Color(0.10, 0.08, 0.07))
		# 墙体主体（原位）：砖色 + 砖缝 + 黑描边
		draw_set_transform(c, rot, Vector2.ONE)
		draw_rect(Rect2(-he, he * 2.0), Color(0.62, 0.37, 0.24))
		var bh := 10.0 * _u
		var bw := 26.0 * _u
		var rows := maxi(int(he.y * 2.0 / bh), 2)
		var r := 0
		while r < rows:
			var y0: float = -he.y + r * bh
			draw_line(Vector2(-he.x, y0), Vector2(he.x, y0), Color(0.40, 0.21, 0.13), 2.0 * _u, true)
			var off := 0.0 if r % 2 == 0 else bw * 0.5
			var x := -he.x + off
			while x < he.x:
				draw_line(Vector2(x, y0), Vector2(x, y0 + bh), Color(0.40, 0.21, 0.13), 1.5 * _u, true)
				x += bw
			r += 1
		draw_rect(Rect2(-he, he * 2.0), Color(0.10, 0.08, 0.07), false, 3.0 * _u)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_pickups() -> void:
	for p: Dictionary in _pickups:
		var pos := p.pos as Vector2
		var t: float = float(p.t)
		var bob: float = sin(t * 5.0) * 3.0 * _u
		var sc := 1.0
		if t > 1.5:
			sc = 0.7
		# 地面阴影圈 + 与轮盘同款无底图标（上下浮动，视觉统一）
		draw_set_transform(pos, 0.0, Vector2.ONE * sc)
		draw_circle(Vector2(0, 14.0 * _u), 20.0 * _u, Color(0, 0, 0, 0.18))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		Glyph.draw_glyph(self, String(p.kind), 18.0 * _u, pos + Vector2(0, bob), 0.0, sc)


## 抛物线预览配色（参考 trash：上升段橙红 → 下降段亮黄，外环+内核双层，沿弧线进度衰减）
const PREVIEW_RISE_RING := Color(1.0, 0.44, 0.26, 0.75)
const PREVIEW_RISE_CORE := Color(1.0, 0.62, 0.42, 0.9)
const PREVIEW_FALL_RING := Color(1.0, 0.84, 0.29, 0.85)
const PREVIEW_FALL_CORE := Color(1.0, 0.98, 0.9, 0.95)
const PREVIEW_RISE_RING_OFF := Color(0.50, 0.48, 0.45, 0.6)   # 无弹药：灰调同构
const PREVIEW_RISE_CORE_OFF := Color(0.66, 0.64, 0.60, 0.75)
const PREVIEW_FALL_RING_OFF := Color(0.38, 0.36, 0.34, 0.65)
const PREVIEW_FALL_CORE_OFF := Color(0.58, 0.56, 0.52, 0.8)
const PREVIEW_TAIL_SCALE := 0.55   # 尾端点尺寸比例（起点 1.0，越靠后越小）
const PREVIEW_TAIL_FADE := 0.5     # 尾端透明度比例（起点 1.0，越靠后越淡）

## 抛物线预览（绘制到顶层 _aim_layer，压在所有游戏元素之上）
func _draw_aim_preview() -> void:
	if not _aiming:
		return
	var L: CanvasItem = _aim_layer
	var cfg: Dictionary = BULLETS[_sel]
	var id := String(cfg.id)
	var sp := _spots[_aim_spot] as Vector2
	var arc_px: float = float(cfg.arc) * _field.size.y
	var has_ammo: bool = bool(cfg.get("inf", false)) or int(_ammo.get(id, 0)) > 0
	if id == "boomerang":
		# 回旋镖：预览 = 实际飞行的水平椭圆（前半程上升段色 / 后半程下降段色）
		var g: Dictionary = _boom_geom(sp, _aim_target)
		var bcen: Vector2 = g.center
		var bdir: Vector2 = g.dir
		var n2 := 20
		for k in range(1, n2 + 1):
			var uu: float = float(k) / float(n2)
			var th: float = PI + TAU * uu
			var l := Vector2(cos(th) * float(g.ba), sin(th) * float(g.bb))
			var p := bcen + Vector2(l.x * bdir.x - l.y * bdir.y, l.x * bdir.y + l.y * bdir.x)
			_preview_dot(L, p, uu, uu < 0.5, has_ammo)
		# 最远点环 + 起飞点中心
		L.draw_arc(_aim_target, 14.0 * _u, 0.0, TAU, 32, PREVIEW_FALL_RING if has_ammo else PREVIEW_FALL_RING_OFF, 2.5 * _u, true)
		L.draw_circle(_aim_target, 4.0 * _u, PREVIEW_FALL_CORE if has_ammo else PREVIEW_FALL_CORE_OFF)
		return
	# 参考弧线采样点（含落点）
	var n := 15
	var pts: Array[Vector2] = []
	for k in range(1, n + 1):
		var uu: float = float(k) / float(n)
		pts.append(sp.lerp(_aim_target, uu) + Vector2(0, -arc_px * 4.0 * uu * (1.0 - uu)))
	# 两遍绘制保证上升段叠在下降段之上（与 trash 一致）
	var apex_i := n / 2 - 1
	for i in n:
		if i > apex_i:
			_preview_dot(L, pts[i], float(i + 1) / float(n), false, has_ammo)
	for i in n:
		if i <= apex_i:
			_preview_dot(L, pts[i], float(i + 1) / float(n), true, has_ammo)
	# 落点环（溅射类显示范围）+ 落点中心
	var splash_px: float = float(cfg.splash) * _field.size.x
	var rr := maxf(splash_px, 14.0 * _u)
	L.draw_arc(_aim_target, rr, 0.0, TAU, 40, PREVIEW_FALL_RING if has_ammo else PREVIEW_FALL_RING_OFF, 2.5 * _u, true)
	L.draw_circle(_aim_target, 4.0 * _u, PREVIEW_FALL_CORE if has_ammo else PREVIEW_FALL_CORE_OFF)


## 预览弧单点：u = 沿弧线进度（0=起点），尺寸与透明度随 u 线性衰减；外环+内核双层
func _preview_dot(cv: CanvasItem, pos: Vector2, u: float, rising: bool, has_ammo: bool) -> void:
	var k := lerpf(1.0, PREVIEW_TAIL_SCALE, u)
	var fade := lerpf(1.0, PREVIEW_TAIL_FADE, u)
	var ring := (PREVIEW_RISE_RING if rising else PREVIEW_FALL_RING) if has_ammo else (PREVIEW_RISE_RING_OFF if rising else PREVIEW_FALL_RING_OFF)
	var core := (PREVIEW_RISE_CORE if rising else PREVIEW_FALL_CORE) if has_ammo else (PREVIEW_RISE_CORE_OFF if rising else PREVIEW_FALL_CORE_OFF)
	ring.a *= fade
	core.a *= fade
	cv.draw_circle(pos, 6.0 * _u * k, ring)
	cv.draw_circle(pos, 6.0 * _u * k * 0.5, core)


func _draw_sling() -> void:
	var sp := _sling_pos()
	var fork_l := sp + Vector2(-17.0 * _u, -44.0 * _u)
	var fork_r := sp + Vector2(17.0 * _u, -44.0 * _u)
	# 皮兜朝向：瞄准时向目标反方向拉
	var pouch := sp + Vector2(0, -8.0 * _u)
	if _aiming:
		var dir := (_aim_target - sp).normalized()
		pouch = sp - dir * 24.0 * _u + Vector2(0, -8.0 * _u)
	# 弓架：素材优先 assets/slingshot.png（画布 200×200，锚点=立柱底部与地面交点，位于画布 (100,180)；
	# 替换 PNG 时请保持叉尖间距约 ±17、高 44，皮筋才能对齐）；缺失回退程序化绘制
	if _sling_tex != null:
		var ts := 200.0 * _u
		draw_texture_rect(_sling_tex, Rect2(sp + Vector2(-100.0, -180.0) * _u, Vector2(ts, ts)), false)
	else:
		Glyph.draw_sling_frame(self, sp, _u)
	# 皮筋
	var band := Color(0.72, 0.22, 0.18)
	draw_line(fork_l, pouch, Color(0.10, 0.08, 0.07), 6.5 * _u, true)
	draw_line(fork_l, pouch, band, 4.0 * _u, true)
	draw_line(fork_r, pouch, Color(0.10, 0.08, 0.07), 6.5 * _u, true)
	draw_line(fork_r, pouch, band, 4.0 * _u, true)
	draw_circle(pouch, 6.0 * _u, band)
	draw_arc(pouch, 6.0 * _u, 0.0, TAU, 20, Color(0.10, 0.08, 0.07), 2.0 * _u, true)
	# 皮兜常驻显示当前子弹（瞄准时随皮兜向后拉）
	Glyph.draw_glyph(self, String(BULLETS[_sel].id), 11.0 * _u, pouch, -0.4, 0.8)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 换弹进度弧（金色顺时针填满 = 冷却结束可再次发射）
	if _reload > 0.0:
		var p: float = 1.0 - _reload / RELOAD_T
		draw_arc(sp, 48.0 * _u, -PI / 2.0, -PI / 2.0 + TAU * p, 24, Color(1.0, 0.85, 0.25, 0.85), 4.0 * _u, true)


func _draw_rock_warnings() -> void:
	for s: Bullet in _shots.get_children():
		if not is_instance_valid(s) or s.mode != "rock" or s.done:
			continue
		var u: float = s.u()
		var a := 0.30 + 0.25 * sin(s.t * 12.0)
		var col := Color(0.95, 0.25, 0.20, a * (1.0 - u * 0.4))
		for k in 4:
			var a0: float = k * TAU / 4.0 + s.t * 2.0
			draw_arc(s.to, ROCK_HIT_R * _u, a0, a0 + TAU / 8.0, 10, col, 3.0 * _u, true)


func _draw_fx() -> void:
	for f: Dictionary in _fx:
		var k: float = 1.0 - float(f.t) / float(f.dur)
		var c := f.col as Color
		c.a = k
		draw_circle(f.p as Vector2, float(f.r) * (0.5 + 0.5 * k), c)


## 底部弹药徽章：当前子弹图标 + 数量（点击弹轮盘）+ 连击倍率
func _draw_badge() -> void:
	var r := _badge
	draw_rect(r, Color(0.12, 0.13, 0.12, 0.92))
	draw_rect(r, Color(0.08, 0.07, 0.06), false, 3.0 * _u)
	var cfg: Dictionary = BULLETS[_sel]
	var id := String(cfg.id)
	var cnt := -1 if bool(cfg.get("inf", false)) else int(_ammo.get(id, 0))
	Glyph.draw_glyph(self, id, 16.0 * _u, r.position + Vector2(36.0 * _u, r.size.y / 2.0), 0.0, 1.1)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var txt := "∞" if cnt < 0 else "×%d" % cnt
	var col := Color.WHITE if cnt != 0 else Color(0.55, 0.55, 0.55)
	var font := ThemeDB.fallback_font
	draw_string(font, r.position + Vector2(64.0 * _u, r.size.y * 0.66), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, int(_m * 0.032), col)
	if _combo >= 2:
		var ct := "×%.1f" % _combo_mult()
		draw_string(font, r.end - Vector2(20.0 * _u + font.get_string_size(ct, HORIZONTAL_ALIGNMENT_LEFT, -1, int(_m * 0.024)).x, r.size.y * 0.30), ct, HORIZONTAL_ALIGNMENT_LEFT, -1, int(_m * 0.024), Color(1.0, 0.85, 0.25))


## ===== 飘字 =====
func _popup_at(pos: Vector2, txt: String, col: Color) -> void:
	var lb := Label.new()
	lb.text = txt
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(_m * 0.030))
	lb.position = pos - Vector2(40.0, 20.0)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - _m * 0.05, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


func _popup_center(txt: String, col: Color) -> void:
	var lb := Label.new()
	lb.text = txt
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 12)
	lb.add_theme_font_size_override("font_size", int(_m * 0.085))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(_vp.x * 0.8, _m * 0.12)
	lb.position = Vector2(_vp.x * 0.1, _vp.y * 0.36)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - _m * POPUP_RISE_RATIO, 1.3)
	tw.tween_property(lb, "modulate:a", 0.0, 1.3).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## ===== 开发者模式（暗门：排行榜面板 5 秒内点满 10 次，关榜弹出；参数实时生效）=====
func _arm_dev_clicks() -> void:
	var panel := get_node_or_null("LeaderboardPanel")
	if panel != null:
		panel.gui_input.connect(_dev_panel_input)


func _dev_panel_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
			and event.pressed):
		return
	var now := Time.get_ticks_msec()
	if now - _dev_click_ms > 5000:
		_dev_clicks = 0
	_dev_click_ms = now
	_dev_clicks += 1
	if _dev_clicks >= 10 and not _dev_pending:
		_dev_pending = true
		var panel := get_node_or_null("LeaderboardPanel")
		if panel != null:
			var head := panel.get_child(0)
			if head is Container and head.get_child(0) is Label:
				(head.get_child(0) as Label).add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))


func _show_dev_window() -> void:
	if _dev_win != null and is_instance_valid(_dev_win):
		return
	var vp := get_viewport_rect().size
	_dev_win = PanelContainer.new()
	_dev_win.process_mode = Node.PROCESS_MODE_ALWAYS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.15, 0.15, 0.96)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(12)
	_dev_win.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_dev_win.add_child(vb)
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
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)
	var actions := [
		[hud.t("dev.kill_all", "Kill All"), _dev_kill_all, hud.t("dev.tip_kill_all", "Remove all bandits (no score)")],
		[hud.t("dev.life_up", "Life +99"), _dev_life_up, hud.t("dev.tip_life_up", "Add 99 remaining lives")],
		[hud.t("dev.next_wave", "Next Wave"), _dev_next_wave, hud.t("dev.tip_next_wave", "Clear the field and start the next wave")],
		[hud.t("dev.ammo", "All Bullets +99"), _dev_ammo, hud.t("dev.tip_ammo", "Add 99 rounds to every bullet type")],
	]
	for a: Array in actions:
		var b := GameHud.make_button(a[0])
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(140.0, 30.0)
		b.tooltip_text = a[2]
		b.pressed.connect(a[1])
		grid.add_child(b)
	_dev_add_slider(vb, hud.t("dev.speed", "Bandit Speed"), _dev_spd, 0.25, 3.0, hud.t("dev.tip_speed", "Bandit move speed multiplier (applies to new spawns and updates live bandits)"), func(v: float) -> void:
		_dev_spd = v
		for c in _bandits.get_children():
			if is_instance_valid(c):
				c.speed = c.speed / maxf(_dev_spd_prev, 0.01) * _dev_spd
		_dev_spd_prev = _dev_spd)
	_dev_add_slider(vb, hud.t("dev.spawn", "Spawn Rate"), _dev_spawn, 0.1, 3.0, hud.t("dev.tip_spawn", "Spawn interval multiplier (lower = faster)"), func(v: float) -> void:
		_dev_spawn = v)
	_dev_add_slider(vb, hud.t("dev.drop", "Drop Rate"), _dev_drop * 100.0, 0.0, 100.0, hud.t("dev.tip_drop", "Kill drop chance in percent"), func(v: float) -> void:
		_dev_drop = v / 100.0)
	add_child(_dev_win)
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += (event as InputEventMouseMotion).relative)


var _dev_spd_prev := 1.0


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


func _dev_kill_all() -> void:
	for c in _bandits.get_children():
		if is_instance_valid(c):
			_spawn_burst(c.position, c.col_body, 10, 150.0, 5.0 * _u)
			c.queue_free()


func _dev_life_up() -> void:
	_lives = mini(_lives + 99, LIVES_CAP)
	_refresh_hud()


func _dev_next_wave() -> void:
	_dev_kill_all()
	_spawn_left = 0
	_wave += 1
	_start_wave()


func _dev_ammo() -> void:
	for cfg: Dictionary in BULLETS:
		var id := String(cfg.id)
		if not bool(cfg.get("inf", false)):
			_ammo[id] = int(_ammo.get(id, 0)) + 99
	_refresh_hud()


## ===== 音效（程序合成：正弦/方波滑音 + 低通噪声）=====
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


func _noise(dur: float, vol: float, lp: float) -> PackedByteArray:
	var rate := 22050
	var n := maxi(1, int(dur * rate))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var acc := 0.0
	for i in n:
		var t := float(i) / float(n)
		acc = lerpf(acc, randf_range(-1.0, 1.0), 1.0 / maxf(lp, 1.0))
		var env := (1.0 - t) * (1.0 - t)
		bytes.encode_s16(i * 2, int(clampf(acc * env * vol, -1.0, 1.0) * 32000))
	return bytes


## parts 元素：["t", f0, f1, dur, square, vol] 音调 / ["n", dur, vol, lp] 噪声
func _sfx_stream(parts: Array) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = 22050
	var all := PackedByteArray()
	for p: Array in parts:
		if p[0] == "t":
			all.append_array(_tone(p[1], p[2], p[3], p[4], p[5]))
		else:
			all.append_array(_noise(p[1], p[2], p[3]))
	st.data = all
	return st


func _init_sfx() -> void:
	_sfx["throw"] = _sfx_stream([["n", 0.09, 0.26, 5.0]])                       # 发射风声
	_sfx["splat"] = _sfx_stream([["n", 0.10, 0.55, 2.0], ["t", 180.0, 60.0, 0.09, false, 0.5]])   # 命中
	_sfx["wall"] = _sfx_stream([["t", 140.0, 70.0, 0.08, true, 0.5], ["n", 0.06, 0.40, 2.0]])     # 撞墙碎裂
	_sfx["boom"] = _sfx_stream([["n", 0.35, 0.85, 1.5], ["t", 120.0, 40.0, 0.30, false, 0.7]])    # 爆炸
	_sfx["empty"] = _sfx_stream([["t", 220.0, 180.0, 0.06, true, 0.25]])        # 弹药不足
	_sfx["click"] = _sfx_stream([["t", 600.0, 600.0, 0.04, true, 0.20]])        # 选中
	_sfx["cancel"] = _sfx_stream([["t", 400.0, 250.0, 0.07, true, 0.25]])       # 取消发射
	_sfx["pickup"] = _sfx_stream([["t", 520.0, 780.0, 0.10, false, 0.35]])      # 拾取弹药
	_sfx["catch"] = _sfx_stream([["t", 660.0, 990.0, 0.09, false, 0.40], ["t", 990.0, 660.0, 0.12, false, 0.40]])   # 回旋镖回收
	_sfx["wave"] = _sfx_stream([["t", 392.0, 392.0, 0.10, false, 0.35], ["t", 494.0, 494.0, 0.10, false, 0.35], ["t", 587.0, 587.0, 0.16, false, 0.35]])   # 波次开始
	_sfx["lose"] = _sfx_stream([["t", 330.0, 82.0, 0.35, false, 0.6]])          # 扣命
	_sfx["over"] = _sfx_stream([["t", 392.0, 392.0, 0.12, true, 0.35], ["t", 311.0, 311.0, 0.12, true, 0.35], ["t", 233.0, 233.0, 0.22, true, 0.35]])      # 游戏结束
	_sfx["stun"] = _sfx_stream([["t", 900.0, 700.0, 0.12, false, 0.30]])        # 眩晕
	_sfx["shard"] = _sfx_stream([["t", 1400.0, 900.0, 0.05, false, 0.20], ["n", 0.05, 0.30, 6.0]])   # 玻璃碎片
	_sfx["rockthrow"] = _sfx_stream([["n", 0.12, 0.30, 3.0]])                   # 劫匪投掷
	_sfx["thud"] = _sfx_stream([["t", 200.0, 110.0, 0.07, true, 0.45]])         # 石块落地
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	for base: String in ["res://games/slingshot/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
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
	for base: String in ["res://games/slingshot/assets/sfx/crowd_cheer.ogg", "res://assets/sfx/crowd_cheer.ogg"]:
		var cf := FileAccess.open(base, FileAccess.READ)
		if cf != null:
			_sfx["cheer"] = AudioStreamOggVorbis.load_from_buffer(cf.get_buffer(cf.get_length()))
			break


func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return
