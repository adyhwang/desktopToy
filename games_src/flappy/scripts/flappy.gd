extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## Flappy Bird（肥鸟）：点击/空格/↑ 扇翅上升，重力自然下落，穿越成对管道间隙 +1 分
## 居中纵向场景：天空背景 + 太阳 + 远景云漂移 + 底部地面滚动；带外两侧暗化画框（合集风格）
## 碰撞：管道（圆 vs 矩形）/ 地面 / 顶部边界 → 撞击红闪震动 → 小鸟坠落落地 → 弹排行榜
## 难度：每 10 分管速 +10%（上限 1.8×）；生成间距随分数小幅缩短（下限 −20%）
## 小鸟角度随速度平滑过渡（上升抬头 / 下落低头 / 坠地翻直）；手机浏览器自动精简特效

const GameHud := preload("res://scripts/game_hud.gd")

enum State { READY, PLAY, DYING, OVER }

# ===== 可调参数（改这里全局生效）=====
const GRAVITY := 3200.0         # 重力加速度（px/s²，×_u 随窗口缩放）
const FLAP_VY := -640.0         # 扇翅瞬时冲量（竖直速度直接置为此值，px/s）
const MAX_FALL := 980.0         # 最大下落速度（px/s）
const PIPE_SPEED := 240.0       # 管道基础移动速度（px/s，×_u）
const SPEED_STEP := 0.10        # 每 10 分管速提升比例
const SPEED_CAP := 1.8          # 管道速度上限倍率
const GAP := 300.0              # 管道通行间隙高度（px，×_u）
const SPAWN_DIST := 450.0       # 管道水平生成间距（px，×_u）
const DIST_FLOOR := 0.85        # 间距缩短下限倍率（−15%）

# ===== 布局常量 =====
const HEADER_H := 150.0         # 顶部 HUD 让高
const EDGE_BOTTOM := 24.0
const BIRD_X_RATIO := 0.30      # 小鸟 x 在场景内比例
const GROUND_H := 120.0         # 地面条带高
const CAP_H := 56.0             # 管口帽高（贴图基准）
const PIPE_W := 96.0            # 管身宽（贴图基准）
const GROUND_TEX_W := 128.0     # 地面贴图横向平铺单元宽

# ===== 特效常量 =====
const FLASH_T := 0.2            # 穿越闪光时长（s）
const SHAKE_T := 0.22           # 屏幕震动时长（s）
const SHAKE_AMP := 5.0          # 屏幕震动幅度（px）
const OVER_T := 1.0             # 落地后延迟弹排行榜（s）
const POPUP_TIME := 0.8
const SCORE_FONT_RATIO := 0.035
const POPUP_FONT_RATIO := 0.05

const COL_SKY := Color(0.53, 0.81, 0.94)
const COL_OUT := Color(0.10, 0.13, 0.12, 0.55)   # 带外遮罩
const COL_BORDER := Color(0.08, 0.07, 0.06)
const COL_SUN := Color(1.0, 0.9, 0.45)

const SFX_DB := -2.0
const BGM_DB := -6.0
const SFX_POOL := 4

var hud: RefCounted
var state := State.READY
var score := 0

var _u := 1.0                          # 全局缩放 = min边 / 1080
var _pulse_t := 0.0                    # 全局动画相位（悬停/扇翅）
var _bird_y := 0.0                     # 小鸟 y（px）
var _vy := 0.0                         # 竖直速度（px/s）
var _rot := 0.0                        # 小鸟角度（rad，0=朝右）
var _wing_frame := 0                   # 扇翅帧（0=up 1=down）
var _wing_t := 0.0                     # 扇翅计时
var _pipes: Array = []                 # [{x, gy, scored}] x=管左缘（带内 px）
var _pipe_speed_mult := 1.0
var _ground_off := 0.0                 # 地面滚动偏移
var _clouds: Array = []                # [{x, y, spd, kind, scl}]
var _over_t := 0.0
var _over_rank := 0
var _shake_t := 0.0
var _record_shown := false
var _low_fx := false

# 布局快照（_layout 更新）
var _band := Rect2()                   # 竖向场景矩形
var _ground_y := 0.0                   # 地面顶部 y
var _bird_x := 0.0

var _world: Node2D                     # 场景绘制（天空元素/管道/地面/画框，参与震动）
var _bird: Sprite2D
var _fx_root: Node2D
var _sky_rect: ColorRect
var _flash_rect: ColorRect
var _tex := {}
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _hbox: HBoxContainer


func start() -> void:
	randomize()
	hud = GameHud.new("flappy")
	_low_fx = OS.has_feature("web_android") or OS.has_feature("web_ios")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_load_textures()
	_init_sfx()
	# 场景树：sky（全屏底）→ shake_root{world, bird, fx} → 红闪层
	_sky_rect = ColorRect.new()
	_sky_rect.color = COL_SKY
	_sky_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sky_rect.z_index = -10   # 全屏天空底色压到 tscn 静态节点（HUD）之下，否则盖住顶部 UI
	add_child(_sky_rect)
	var shake_root := Node2D.new()
	add_child(shake_root)
	_world = Node2D.new()
	_world.draw.connect(_on_world_draw)
	shake_root.add_child(_world)
	_bird = Sprite2D.new()
	_bird.texture = _tex["bird_wing_up"]
	shake_root.add_child(_bird)
	_fx_root = Node2D.new()
	shake_root.add_child(_fx_root)
	_flash_rect = ColorRect.new()
	_flash_rect.color = Color(0.92, 0.18, 0.14, 0.0)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash_rect)
	_layout()
	_new_game()


func stop() -> void:
	get_tree().paused = false   # 排行榜弹窗可能还在暂停态，兜底恢复
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()   # 中途退出也把本局分数入排行榜（已提交则无害）
	print("[flappy] stop, score=%d" % score)


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源 =====

func _load_textures() -> void:
	for n: String in ["bird_wing_up", "bird_wing_down", "cloud0", "cloud1", "sun",
			"ground", "pipe_body", "pipe_cap", "fx_flash"]:
		_tex[n] = _load_png("res://assets/%s.png" % n)


func _load_png(path: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码
	for p: String in ["res://games/flappy/" + path.trim_prefix("res://"), path]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


func _init_sfx() -> void:
	var files := {"wing": "wing.wav", "score": "score.wav", "hit": "hit.wav", "die": "die.wav"}
	for n: String in files:
		var f := FileAccess.open("res://assets/sfx/" + files[n], FileAccess.READ)
		if f != null:
			_sfx_streams[n] = AudioStreamWAV.load_from_buffer(f.get_buffer(f.get_length()))
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)   # 播放器必须进树，否则播放报错无声
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
	_u = minf(vp.x, vp.y) / 1080.0
	var avail_h := maxf(vp.y - HEADER_H - EDGE_BOTTOM, 200.0)
	# 全宽场景：左右到屏边、顶到屏幕顶，底 = 地面底（下沿留白不变）
	_band = Rect2(0.0, 0.0, vp.x, HEADER_H + avail_h)
	_ground_y = _band.end.y - GROUND_H * _u
	_bird_x = _band.position.x + _band.size.x * BIRD_X_RATIO
	_sky_rect.position = Vector2.ZERO
	_sky_rect.size = vp
	if _flash_rect != null:
		_flash_rect.position = Vector2.ZERO
		_flash_rect.size = vp
	_layout_boards(vp)
	_layout_buttons(vp)
	if _world != null:
		_world.queue_redraw()


func _layout_boards(vp: Vector2) -> void:
	# 顶栏分数牌水平居中（单板）
	var bw := clampf(_u * 190.0, 90.0, 190.0)
	var bh := _u * 1080.0 * SCORE_FONT_RATIO * 1.9
	var b: Label = $HudBar/ScoreBoard
	b.custom_minimum_size = Vector2(bw, bh)
	b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	b.add_theme_font_size_override("font_size", int(_u * 1080.0 * SCORE_FONT_RATIO))
	$HudBar.reset_size()
	$HudBar.position = Vector2((vp.x - $HudBar.size.x) / 2.0, 14.0)


func _layout_buttons(vp: Vector2) -> void:
	_hbox.reset_size()
	var hud_bar: HBoxContainer = $HudBar
	if vp.x < hud_bar.position.x + hud_bar.size.x + _hbox.size.x + 28.0:
		_hbox.position = Vector2(vp.x - _hbox.size.x - 12.0, 14.0 + hud_bar.size.y + 6.0)
	else:
		_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


func _setup_buttons() -> void:
	# 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + 重开 + 音乐 + 音量（与合集一致）
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/弹窗）顶栏按钮仍可点
	var exit_btn: Button = $ExitButton
	var old_parent := exit_btn.get_parent()   # tscn 节点迁入容器（原父为游戏根）
	old_parent.remove_child(exit_btn)
	GameHud.style_button(exit_btn)
	exit_btn.text = ""
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	exit_btn.icon = hud.ui_icon("close.png")   # pressed 已在 entry.tscn 连接，勿重复

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
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, min_btn, exit_btn]:
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


# ===== 回合流程 =====

func _new_game() -> void:
	var lb := get_node_or_null("LeaderboardPanel")   # 重开时关掉排行榜弹窗（双保险）
	if lb != null:
		lb.queue_free()
	score = 0
	_vy = 0.0
	_rot = 0.0
	_wing_frame = 0
	_wing_t = 0.0
	_pipes.clear()
	_over_t = 0.0
	_shake_t = 0.0
	_record_shown = false
	_flash_rect.color.a = 0.0
	hud.reset_run()
	_sync_bgm()   # 结算停过 BGM，重开恢复播放
	_bird_y = _band.get_center().y
	for i in 3:   # 远景云初始化（缓慢左漂，wrap 循环；x/速度均为带宽比例坐标）
		_clouds.append({
			"x": randf_range(0.0, 1.0), "y": randf_range(0.10, 0.42),
			"spd": randf_range(0.008, 0.02), "kind": i % 2,
			"scl": randf_range(0.8, 1.5),
		})
	state = State.READY
	_refresh_board()
	_world.queue_redraw()
	_popup(hud.t("tip.click_start", "Click to Start"), Color(1, 1, 1, 0.95),
			Vector2(_band.get_center().x, _band.position.y + _band.size.y * 0.30))


func _refresh_board() -> void:
	$HudBar/ScoreBoard.text = "%d" % score


func _restart() -> void:
	_new_game()


# ===== 主循环 =====

func _process(delta: float) -> void:
	if hud == null:   # 无头冒烟（--quit 直跑 entry）不经 start()，对象未创建直接跳过
		return
	_pulse_t += delta
	_tick_shake(delta)
	match state:
		State.READY:
			# 悬停：正弦浮动 + 慢速扇翅
			_bird_y = _band.get_center().y + sin(_pulse_t * 3.0) * 14.0 * _u
			_vy = 0.0
			_rot = lerpf(_rot, 0.0, minf(1.0, delta * 10.0))
			_tick_wing(delta, 0.22)
			_scroll_world(delta, 0.35)
		State.PLAY:
			_vy = minf(_vy + GRAVITY * _u * delta, MAX_FALL * _u)
			_bird_y += _vy * delta
			# 角度：上升快抬头、下落缓低头，平滑过渡
			var target := clampf(lerpf(-0.45, 1.25, (_vy / _u + 680.0) / 1660.0), -0.45, 1.25)
			_rot = lerp_angle(_rot, target, minf(1.0, delta * (14.0 if _vy < 0.0 else 7.0)))
			_tick_wing(delta, 0.12)
			_scroll_world(delta, 1.0)
			_move_pipes(delta)
			_check_score()
			_check_collide()
		State.DYING:
			# 撞击后：管道停止，小鸟坠落翻转
			_vy = minf(_vy + GRAVITY * _u * delta, MAX_FALL * _u)
			_bird_y += _vy * delta
			_rot = lerp_angle(_rot, PI * 0.5, minf(1.0, delta * 9.0))
			if _bird_y >= _ground_y - 30.0 * _u:
				_bird_y = _ground_y - 30.0 * _u
				_on_landed()
		State.OVER:
			if _over_t > 0.0:
				_over_t -= delta
				if _over_t <= 0.0:
					_over_t = 0.0
					hud.show_leaderboard(self, hud.t("lb.title", "Top 10"), score, _over_rank)
			elif get_node_or_null("LeaderboardPanel") == null:
				_new_game()
	_update_bird()
	_world.queue_redraw()


## 扇翅动画：按周期交替上下两帧
func _tick_wing(delta: float, period: float) -> void:
	_wing_t += delta
	if _wing_t >= period:
		_wing_t = 0.0
		_wing_frame = 1 - _wing_frame


## 世界滚动：地面/云按当前管速比例移动
func _scroll_world(delta: float, mult: float) -> void:
	var v := _pipe_speed() * mult
	_ground_off = fmod(_ground_off + v * delta, GROUND_TEX_W * _u)
	for c: Dictionary in _clouds:
		c.x -= c.spd * delta   # 比例速度：每秒移动带宽的 0.8%~2%
		if c.x < -0.25:
			c.x = 1.25
			c.y = randf_range(0.10, 0.42)


## 管道移动 + 生成 + 移除
func _move_pipes(delta: float) -> void:
	var v := _pipe_speed()
	for p: Dictionary in _pipes:
		p.x -= v * delta
	while _pipes.size() == 0 or _pipes[-1].x < _band.end.x - _spawn_dist():
		_spawn_pipe()
	while _pipes.size() > 0 and _pipes[0].x + PIPE_W * _u < _band.position.x - 10.0:
		_pipes.pop_front()


func _pipe_speed() -> float:
	return PIPE_SPEED * _u * minf(1.0 + floor(score / 10.0) * SPEED_STEP, SPEED_CAP)


## 生成间距随分数小幅缩短（下限 DIST_FLOOR）
func _spawn_dist() -> float:
	return SPAWN_DIST * _u * maxf(DIST_FLOOR, 1.0 - score * 0.004)


func _spawn_pipe() -> void:
	var margin := GAP * _u * 0.5 + 70.0 * _u
	var gy := 0.0
	if _pipes.size() > 0:
		var last_gy: float = _pipes[-1].gy
		# 限差：与上一间隙中心差 ≤ 水平间距×0.5——按管间飞行时间预算爬升能力
		# （鸟可持续爬升约 300px/s，间距缩短时限差同步收紧，保证任何分数段都物理可达）
		var max_dy: float = _spawn_dist() * 0.5
		var lo := maxf(margin, last_gy - max_dy)
		var hi := minf(_ground_y - margin, last_gy + max_dy)
		gy = randf_range(lo, hi) if hi > lo else (lo + hi) / 2.0
	else:
		gy = randf_range(margin, _ground_y - margin)
	var x: float = _band.end.x + 40.0 if _pipes.size() == 0 else _pipes[-1].x + _spawn_dist()
	_pipes.append({"x": x, "gy": gy, "scored": false})


## 计分：小鸟越过管道中心线
func _check_score() -> void:
	for p: Dictionary in _pipes:
		if not p.scored and p.x + PIPE_W * _u * 0.5 < _bird_x:
			p.scored = true
			score += 1
			_play_sfx("score")
			if hud.submit_score(score) and not _record_shown:
				_record_shown = true
				_popup(hud.t("tip.new_record", "New Record!"), Color(1.0, 0.85, 0.25),
						Vector2(_band.get_center().x, _band.position.y + _band.size.y * 0.20))
			_popup("+1", Color(1, 1, 1), Vector2(_bird_x, _bird_y - 60.0 * _u))
			_flash_at(Vector2(_bird_x, _bird_y - 50.0 * _u), Color(1.0, 0.95, 0.5))
			_refresh_board()


## 碰撞：管道（圆 vs 上下管矩形）/ 地面 / 顶部
func _check_collide() -> void:
	var r := 28.0 * _u
	if _bird_y + r >= _ground_y:
		_on_hit()
		return
	if _bird_y - r <= _band.position.y:
		_on_hit()
		return
	var c := Vector2(_bird_x, _bird_y)
	for p: Dictionary in _pipes:
		var w := PIPE_W * _u
		var half_gap := GAP * _u * 0.5
		var top_rect := Rect2(p.x, _band.position.y - 40.0, w, p.gy - half_gap - _band.position.y + 40.0)
		var bot_rect := Rect2(p.x, p.gy + half_gap, w, _ground_y - p.gy - half_gap)
		if _circle_rect(c, r, top_rect) or _circle_rect(c, r, bot_rect):
			_on_hit()
			return


## 圆 vs 矩形
func _circle_rect(c: Vector2, r: float, rc: Rect2) -> bool:
	var near := c.clamp(rc.position, rc.end)
	return c.distance_squared_to(near) <= r * r


## 撞击：音效 + 红闪 + 震动 → 坠落
func _on_hit() -> void:
	if state != State.PLAY:
		return
	state = State.DYING
	_play_sfx("hit")
	_red_flash()
	if not _low_fx:
		_shake_t = SHAKE_T * 1.6
	_vy = maxf(_vy, -200.0)   # 撞顶时反转下坠
	print("[flappy] hit, score=%d" % score)


## 落地：die 音效 + 入榜 + 延迟弹排行榜
func _on_landed() -> void:
	state = State.OVER
	_play_sfx("die")
	_over_rank = hud.commit_score()
	_over_t = OVER_T
	print("[flappy] game over, score=%d" % score)


# ===== 渲染 =====

func _update_bird() -> void:
	_bird.position = Vector2(_bird_x, _bird_y)
	_bird.rotation = _rot
	_bird.texture = _tex["bird_wing_down"] if _wing_frame == 1 else _tex["bird_wing_up"]
	var scl := 64.0 * _u / 96.0   # 显示 64px（贴图 96）
	_bird.scale = Vector2(scl, scl)


## 场景绘制：太阳/云/管道/地面/带外画框
## 管道/地面等 tile 平铺元素统一在 draw_set_transform(×_u) 内用贴图原始坐标绘制
## ——tile 模式按原始像素平铺不缩放，直接混用 _u 缩放坐标会导致部件尺寸不一致无法拼接
func _on_world_draw() -> void:
	var d := _world
	var band := _band
	var bu: Vector2 = band.position
	d.draw_set_transform(bu, 0.0, Vector2(_u, _u))   # 进入 96 基准坐标系（原点=带左上）
	var bw := band.size.x / _u        # 带宽（原始 px）
	var bh := band.size.y / _u
	var ground_y := bh - GROUND_H     # 地面顶（原始 px）
	# 太阳（右上角固定，96px 原始尺寸）
	d.draw_texture(_tex["sun"], Vector2(bw - 96.0 - 40.0, 36.0), Color(1, 1, 1, 0.9))
	# 远景云（缓慢漂移，半透明；c.scl 为原始倍率）
	for c: Dictionary in _clouds:
		var t: Texture2D = _tex["cloud0"] if c.kind == 0 else _tex["cloud1"]
		d.draw_texture(t, Vector2(c.x * bw - t.get_width() * c.scl * 0.5, c.y * bh), Color(1, 1, 1, 0.85))
	# 管道 body：垂直平铺（先画全部 body，cap 最后画——cap 内部会重设 transform）
	var half_gap := GAP * 0.5
	for p: Dictionary in _pipes:
		var x: float = (p.x - bu.x) / _u          # 管左缘（原始 px）
		var gy: float = (p.gy - bu.y) / _u        # 间隙中心（原始 px）
		var top_len: float = gy - half_gap - CAP_H
		if top_len > 0.0:
			d.draw_texture_rect(_tex["pipe_body"], Rect2(x, 0.0, PIPE_W, top_len), true)
		var bot_top: float = gy + half_gap + CAP_H
		d.draw_texture_rect(_tex["pipe_body"], Rect2(x, bot_top, PIPE_W, ground_y - bot_top), true)
	# 地面（横向平铺滚动；_ground_off 为屏幕 px，转原始 px）
	d.draw_texture_rect(_tex["ground"],
			Rect2(-_ground_off / _u, ground_y, bw + _ground_off / _u, GROUND_H), true)
	d.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)   # 回到屏幕坐标系
	# 管口帽（内部自管理 ×_u 缩放与倒置）
	for p: Dictionary in _pipes:
		var x: float = (p.x - bu.x) / _u
		var gy: float = (p.gy - bu.y) / _u
		_draw_cap(d, x + PIPE_W * 0.5, gy - half_gap - CAP_H * 0.5, true)
		_draw_cap(d, x + PIPE_W * 0.5, gy + half_gap + CAP_H * 0.5, false)
	# 带外暗化画框 + 竖描边（合集风格：粗黑描边）
	if band.position.x > 0.5:
		d.draw_rect(Rect2(0, 0, band.position.x, band.end.y), COL_OUT)
		d.draw_rect(Rect2(band.end.x, 0, maxf(get_viewport_rect().size.x - band.end.x, 0.0), band.end.y), COL_OUT)
		d.draw_line(Vector2(band.position.x, band.position.y), Vector2(band.position.x, band.end.y), COL_BORDER, 4.0)
		d.draw_line(Vector2(band.end.x, band.position.y), Vector2(band.end.x, band.end.y), COL_BORDER, 4.0)


## 管口帽：cx/cy 为带内 96 基准坐标；flip=true 倒置（上管间隙端）
func _draw_cap(d: Node2D, cx: float, cy: float, flip: bool) -> void:
	var t: Texture2D = _tex["pipe_cap"]
	var scl_y := -_u if flip else _u
	d.draw_set_transform(_band.position + Vector2(cx, cy) * _u, 0.0, Vector2(_u, scl_y))
	d.draw_texture(t, Vector2(-t.get_width() * 0.5, -CAP_H * 0.5))
	d.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 穿越闪光：星芒贴图放大淡出（低特效模式跳过）
func _flash_at(pos: Vector2, col: Color) -> void:
	if _low_fx or _tex["fx_flash"] == null:
		return
	var fx := Sprite2D.new()
	fx.texture = _tex["fx_flash"]
	fx.position = pos
	fx.modulate = Color(col.r, col.g, col.b, 0.9)
	fx.scale = Vector2.ONE * 40.0 * _u / 96.0
	fx.z_index = 5
	_fx_root.add_child(fx)
	var tw := fx.create_tween()
	tw.set_parallel(true)
	tw.tween_property(fx, "scale", Vector2.ONE * 110.0 * _u / 96.0, FLASH_T) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(fx, "modulate:a", 0.0, FLASH_T)
	tw.chain().tween_callback(fx.queue_free)


## 死亡红色闪烁：全屏红层 3 次脉冲后渐隐
func _red_flash() -> void:
	_flash_rect.color.a = 0.0
	var tw := _flash_rect.create_tween()
	for i in 3:
		tw.tween_property(_flash_rect, "color:a", 0.38, 0.09)
		tw.tween_property(_flash_rect, "color:a", 0.08, 0.09)
	tw.tween_property(_flash_rect, "color:a", 0.0, 0.30)


func _tick_shake(delta: float) -> void:
	var shake_root := _world.get_parent()
	if _shake_t > 0.0:
		_shake_t -= delta
		var amp := SHAKE_AMP * clampf(_shake_t / SHAKE_T, 0.0, 1.0)
		shake_root.position = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	else:
		shake_root.position = Vector2.ZERO


# ===== 飘字 =====

func _popup(text: String, color: Color, pos: Vector2) -> void:
	var lb := Label.new()
	lb.text = text
	lb.position = pos - Vector2(100.0, _u * 1080.0 * POPUP_FONT_RATIO)
	lb.size = Vector2(200.0, _u * 1080.0 * POPUP_FONT_RATIO * 1.4)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(_u * 1080.0 * POPUP_FONT_RATIO))
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.z_index = 10
	add_child(lb)
	var tw := lb.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - _u * 65.0, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME)
	tw.chain().tween_callback(lb.queue_free)


# ===== 交互 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
			return
		if event.keycode == KEY_SPACE or event.keycode == KEY_UP:
			_flap()
			return
	# 鼠标左键 / 触屏点击（emulate_mouse_from_touch 默认开启，触摸也会派生鼠标事件）
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_flap()


## 扇翅：READY 首击起飞，PLAY 获得向上冲量；DYING/OVER 忽略
func _flap() -> void:
	if state == State.READY:
		state = State.PLAY
	elif state != State.PLAY:
		return
	_vy = FLAP_VY * _u
	_wing_frame = 1   # 立即压翅
	_wing_t = 0.0
	_play_sfx("wing")
