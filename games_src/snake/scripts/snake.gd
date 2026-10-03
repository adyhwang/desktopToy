extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 贪吃蛇 Snake：N×N 网格（10 起步，身体每增 6 段横竖各扩 1 格带动画，30 封顶）
## 操作：鼠标左键/触屏点击转向（水平移动按 Y 判上下、垂直移动按 X 判左右，点击蛇身无效）；
##       方向键 ↑↓←→ 备选；R 重开。撞墙/咬自身游戏结束。
## 食物（FOODS 表统一配置）：苹果 60% +1节+10分 提速；香蕉 10% +2节+25分 减速；
## 葡萄 10% 不长 +15分 临时减速3秒；桃子 10% +1节+18分 减速；草莓 10% +1节+22分 减速
## 提速/减速净效果 clamp 在 [STEP_MIN, STEP_BASE]：提速不超最高速，减速不低于基础速
## 蛇按格子步进，渲染格间插值 + 转向角度渐变（平滑过渡）；吃到食物闪光+轻震，死亡红色闪烁
## 手机浏览器（web_android/web_ios）自动精简特效（关震动/闪光防掉帧）
## BGM: "Summer Park - 8bit tune (loop)" by Scribe (opengameart.org), CC0；音效为程序合成 WAV

const GameHud := preload("res://scripts/game_hud.gd")

const SFX_POOL := 4             # 音效播放器池
const BGM_DB := -9.0            # BGM 音量（dB）
const SFX_DB := -4.0            # 音效全局音量偏移

# ===== 可调参数（改这里全局生效）=====
const GRID_START := 10          # 初始网格边长（GRID_START×GRID_START）
const GRID_MAX := 30            # 网格上限
const GROW_EVERY := 6           # 身体每增加 6 段，网格横竖各扩 1 格
const STEP_BASE := 0.5         # 蛇基础移动速度（秒/格，越小越快）——同时是减速下限（间隔上限）
const STEP_DEC := 0.0055        # 每吃 1 个提速水果的速度增量（步进间隔减量，s）
const STEP_INC := 0.0055        # 每吃 1 个减速水果的步进间隔增量（s，回退提速）
const STEP_MIN := 0.085         # 步进间隔下限（速度上限）
const SLOW_T := 3.0             # 葡萄临时减速时长（s）
const SLOW_FACTOR := 1.6        # 临时减速倍率（步进间隔 × 此值）

# ===== 水果配置表（统一管理，风格同合集其他游戏的 KINDS 表）=====
# p：随机权重（自动归一化，无需凑 1）；grow：蛇身增长节数；score：得分；
# spd：步进间隔净增量（负=提速 / 正=减速，净效果 clamp 在 [STEP_MIN, STEP_BASE]：
#      提速不超过最高速度，减速不低于基础速度）；
# slow：临时减速时长（s，期间间隔 ×SLOW_FACTOR，0=无）；sfx：音效；col：飘字/闪光颜色
const FOODS := {
	"apple":      {"tex": "food_apple",      "p": 0.80, "grow": 1, "score": 10, "spd": -STEP_DEC, "slow": 0.0, "sfx": "eat",   "col": Color(0.93, 0.32, 0.28)},
	"banana":     {"tex": "food_banana",     "p": 0.05, "grow": 2, "score": 25, "spd": STEP_INC,  "slow": 0.0, "sfx": "bonus", "col": Color(0.98, 0.82, 0.24)},
	"grape":      {"tex": "food_grape",      "p": 0.05, "grow": 1, "score": 15, "spd": 0.0,       "slow": SLOW_T, "sfx": "slow", "col": Color(0.72, 0.45, 0.85)},
	"peach":      {"tex": "food_peach",      "p": 0.05, "grow": 1, "score": 18, "spd": STEP_INC,  "slow": 0.0, "sfx": "bonus", "col": Color(0.99, 0.62, 0.48)},
	"strawberry": {"tex": "food_strawberry", "p": 0.05, "grow": 1, "score": 22, "spd": STEP_INC,  "slow": 0.0, "sfx": "bonus", "col": Color(0.94, 0.30, 0.42)},
}

# ===== 布局（合集风格）=====
const HEADER_H := 150.0         # 顶部 HUD 保留高度
const EDGE_BOTTOM := 24.0       # 棋盘下缘边距
const BOARD_EDGE_X := 0.03      # 棋盘水平边距 / min(屏宽,屏高)
const SCORE_FONT_RATIO := 0.035 # 记分牌字号 = m × 此值
const POPUP_FONT_RATIO := 0.05  # 飘字字号 = m × 此值
const POPUP_TIME := 0.8         # 飘字时长（s）
const GROW_ANIM_T := 0.8       # 扩格动画时长（s，期间暂停步进）
const OVER_T := 1.0             # 结束后延迟弹排行榜（s）：等红色闪烁 + 结束音效
const FLASH_T := 0.2            # 吃食物闪光时长（s）
const SHAKE_T := 0.09           # 屏幕震动时长（s）
const SHAKE_AMP := 5.0          # 屏幕震动幅度（px）

const COL_PANEL := Color(0.16, 0.19, 0.18, 0.55)  # 棋盘面板底（半透明深色）
const COL_GRID := Color(1, 1, 1, 0.10)            # 网格线浅色半透明
const COL_BORDER := Color(1, 1, 1, 0.32)          # 边框（墙）

enum State { READY, PLAY, GROW, OVER }

var hud: RefCounted

@onready var _scoreboard: Label = $HudBar/ScoreBoard
@onready var _lenboard: Label = $HudBar/LenBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var state := State.READY
var score := 0
var _grid := GRID_START                 # 当前网格边长（逻辑值）
var _grid_disp := float(GRID_START)     # 网格边长显示值（扩格动画插值）
var _grid_from := float(GRID_START)     # 扩格动画起点
var _cells: Array = []                  # 蛇身格子（Vector2i，[0]=头）
var _prev_cells: Array = []             # 上一步格子快照（渲染插值源）
var _dir := Vector2i.RIGHT
var _pending_dir := Vector2i.RIGHT      # 下一步生效的转向（防一步内连转自杀）
var _step_t := 0.0                      # 步进累计
var _grow_pending := 0                  # 待生长节数（香蕉 +2 分两步长）
var _growth_total := 0                  # 身体累计增加段数（扩格依据）
var _speed_off := 0.0                   # 步进间隔净偏移（负=净提速，clamp 在 [STEP_MIN,STEP_BASE]）
var _slow_left := 0.0                   # 临时减速剩余（s）
var _food_cell := Vector2i(-1, -1)
var _food_kind := "apple"               # 当前食物种类（FOODS 表 key）
var _grow_anim_t := 0.0                 # 扩格动画剩余（s）
var _over_t := 0.0                      # OVER 延迟弹排行榜倒计时
var _over_rank := 0
var _pulse_t := 0.0                     # 食物呼吸动画相位
var _shake_t := 0.0                     # 屏幕震动剩余
var _record_shown := false              # 破纪录飘字只提示一次
var _low_fx := false                    # 手机浏览器精简特效

# 布局快照（_layout 更新）
var _m := 100.0
var _board_rect := Rect2()              # 棋盘像素矩形（正方形，居中）
var _cell := 40.0                       # 单元格边长

var _board: Node2D                      # 棋盘绘制（面板/网格线/墙，参与震动）
var _shake_root: Node2D                 # 震动容器（棋盘+蛇+食物+特效整体偏移）
var _snake_root: Node2D
var _fx_root: Node2D
var _seg_sprites: Array = []            # 蛇身精灵池（[0]=头，末位=尾）
var _food_sprite: Sprite2D
var _flash_rect: ColorRect              # 死亡红色闪烁层
var _tex := {}                          # 贴图表
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _hbox: HBoxContainer


func start() -> void:
	hud = GameHud.new("snake")
	_low_fx = OS.has_feature("web_android") or OS.has_feature("web_ios")
	get_viewport().size_changed.connect(_layout)
	_setup_buttons()
	_load_textures()
	_init_sfx()
	# 场景树：shake_root{board, snake, food, fx} + 全屏红闪层（后加的绘制在上）
	_shake_root = Node2D.new()
	add_child(_shake_root)
	_board = Node2D.new()
	_board.draw.connect(_on_board_draw)
	_shake_root.add_child(_board)
	_snake_root = Node2D.new()
	_shake_root.add_child(_snake_root)
	_fx_root = Node2D.new()
	_shake_root.add_child(_fx_root)
	_food_sprite = Sprite2D.new()
	_food_sprite.visible = false
	_fx_root.add_child(_food_sprite)
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
	print("[snake] stop, score=%d len=%d grid=%d" % [score, _cells.size(), _grid])


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源 =====

func _load_textures() -> void:
	for n: String in ["head", "body", "tail", "fx_flash"]:
		_tex[n] = _load_png("res://assets/%s.png" % n)
	for k: String in FOODS:   # 食物贴图按配置表加载
		var t: String = FOODS[k].tex
		_tex[t] = _load_png("res://assets/%s.png" % t)


func _load_png(path: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码
	for p: String in ["res://games/snake/" + path.trim_prefix("res://"), path]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


func _init_sfx() -> void:
	var files := {"eat": "eat.wav", "bonus": "bonus.wav", "slow": "slow.wav",
			"grow": "grow.wav", "die": "die.wav"}
	for n: String in files:
		var f := FileAccess.open("res://assets/sfx/" + files[n], FileAccess.READ)
		if f != null:
			_sfx_streams[n] = AudioStreamWAV.load_from_buffer(f.get_buffer(f.get_length()))
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
	_m = minf(vp.x, vp.y)
	# 棋盘正方形：水平留 BOARD_EDGE_X 边距，顶部让出 HUD，底部留边，可用区垂直居中
	var avail_h := vp.y - HEADER_H - EDGE_BOTTOM
	var side := maxf(minf(vp.x - _m * BOARD_EDGE_X * 2.0, avail_h), 120.0)
	var center := Vector2(vp.x / 2.0, HEADER_H + avail_h / 2.0)
	_board_rect = Rect2(center - Vector2(side, side) / 2.0, Vector2(side, side))
	_cell = side / _grid_disp
	if _flash_rect != null:
		_flash_rect.position = Vector2.ZERO
		_flash_rect.size = vp
	_layout_boards(vp)
	_layout_buttons(vp)
	if _board != null:
		_board.queue_redraw()


func _layout_boards(vp: Vector2) -> void:
	# 顶栏信息牌（Score+Len）整体水平居中；窄屏缩窄防溢出
	var bw := clampf(_m * 0.24, 90.0, 190.0)
	var bh := _m * SCORE_FONT_RATIO * 1.9
	for b: Label in [_scoreboard, _lenboard]:
		b.custom_minimum_size = Vector2(bw, bh)
		b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_theme_font_size_override("font_size", int(_m * SCORE_FONT_RATIO))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)


func _layout_buttons(vp: Vector2) -> void:
	_hbox.reset_size()
	if vp.x < _hud_bar.position.x + _hud_bar.size.x + _hbox.size.x + 28.0:
		# 窄屏（手机竖屏）：按钮排让到信息牌下方一行的右侧
		_hbox.position = Vector2(vp.x - _hbox.size.x - 12.0, 14.0 + _hud_bar.size.y + 6.0)
	else:
		_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)


func _setup_buttons() -> void:
	# 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + 重开 + 音乐 + 音量（与合集一致）
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	var old_parent := _exit_btn.get_parent()   # tscn 节点迁入容器（原父为游戏根）
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")   # pressed 已在 entry.tscn 连接，勿重复
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, _exit_btn]:
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
	_grid = GRID_START
	_grid_disp = float(GRID_START)
	_grid_from = float(GRID_START)
	_cell = _board_rect.size.x / _grid_disp   # 格长立即归位（否则首帧按上局格长渲染）
	_board.queue_redraw()   # 重绘网格线：不重绘则棋盘残留上局的大网格（扩格后重开不归位）
	score = 0
	_growth_total = 0
	_grow_pending = 0
	_speed_off = 0.0
	_slow_left = 0.0
	_grow_anim_t = 0.0
	_over_t = 0.0
	_shake_t = 0.0
	_record_shown = false
	_flash_rect.color.a = 0.0
	hud.reset_run()
	_sync_bgm()   # 结算停过 BGM，重开恢复播放
	# 初始 3 节：头+身+尾，居中水平朝右
	var cy := _grid / 2
	_cells = [Vector2i(_grid / 2 + 1, cy), Vector2i(_grid / 2, cy), Vector2i(_grid / 2 - 1, cy)]
	_prev_cells = _cells.duplicate()
	_dir = Vector2i.RIGHT
	_pending_dir = _dir
	_step_t = 0.0
	state = State.READY
	_clear_sprites()
	_spawn_food()
	_refresh_boards()
	_popup(hud.t("tip.click_start", "Click to Start"), Color(1, 1, 1, 0.9),
			Vector2(_board_rect.get_center().x, _board_rect.position.y + _board_rect.size.y * 0.30))


## 身体累计增量对应网格边长：每 GROW_EVERY 段扩 1 格
func _grid_for(growth: int) -> int:
	return mini(GRID_START + growth / GROW_EVERY, GRID_MAX)


## 当前步进间隔：基础 + 净偏移（苹果提速负 / 减速水果正），clamp 在 [STEP_MIN, STEP_BASE]
## ——提速不超过最高速度、减速不低于基础速度；临时减速期（葡萄）再 ×SLOW_FACTOR
func _step_time() -> float:
	var t := clampf(STEP_BASE + _speed_off, STEP_MIN, STEP_BASE)
	return t * (SLOW_FACTOR if _slow_left > 0.0 else 1.0)


func _refresh_boards() -> void:
	_scoreboard.text = "%d" % score
	_lenboard.text = hud.t("hud.len", "Len %d") % _cells.size()


func _restart() -> void:
	_new_game()


# ===== 主循环 =====

func _process(delta: float) -> void:
	if hud == null:   # 无头冒烟（--quit 直跑 entry）不经 start()，对象未创建直接跳过
		return
	if state == State.OVER:
		# 先等红色闪烁 + 结束音效再弹排行榜；面板关闭后自动开新局（与合集同套路）
		if _over_t > 0.0:
			_over_t -= delta
			if _over_t <= 0.0:
				_over_t = 0.0
				hud.show_leaderboard(self, hud.t("lb.title", "Top 10"), score, _over_rank)
		elif get_node_or_null("LeaderboardPanel") == null:
			_new_game()
		_tick_shake(delta)
		_update_positions(clampf(_step_t / _step_time(), 0.0, 1.0))
		return
	_pulse_t += delta
	if _slow_left > 0.0:
		_slow_left -= delta
	if state == State.GROW:
		# 扩格动画：网格显示值平滑过渡（格子渐小），期间暂停步进
		_grow_anim_t -= delta
		var k := 1.0 - clampf(_grow_anim_t / GROW_ANIM_T, 0.0, 1.0)
		_grid_disp = lerpf(_grid_from, float(_grid), k)
		_cell = _board_rect.size.x / _grid_disp
		_board.queue_redraw()
		if _grow_anim_t <= 0.0:
			_grid_disp = float(_grid)
			state = State.PLAY
			_board.queue_redraw()
	elif state == State.PLAY:
		_step_t += delta
		var guard := 0
		while _step_t >= _step_time() and state == State.PLAY and guard < 4:
			_step_t -= _step_time()
			_step()
			guard += 1
	_tick_shake(delta)
	_update_positions(clampf(_step_t / _step_time(), 0.0, 1.0) if state == State.PLAY else 1.0)
	_update_food()


## 步进一格：转向生效 → 头前移 → 撞墙/咬自身判定 → 吃食物 → 生长
func _step() -> void:
	if _pending_dir != -_dir and _pending_dir != _dir:
		_dir = _pending_dir
	_prev_cells = _cells.duplicate()
	var nh: Vector2i = _cells[0] + _dir
	# 撞地图边界墙体
	if nh.x < 0 or nh.y < 0 or nh.x >= _grid or nh.y >= _grid:
		_die()
		return
	# 头部碰撞自身身体任意一节
	if nh in _cells:
		_die()
		return
	_cells.push_front(nh)
	var ate := nh == _food_cell
	if not ate:
		if _grow_pending > 0:
			_grow_pending -= 1   # 本步不删尾 = 长一节
		else:
			_cells.pop_back()
	if ate:
		_on_eat()


## 吃到食物：查 FOODS 表计分/生长/调速/特效/刷新食物/扩格检查
func _on_eat() -> void:
	var cfg: Dictionary = FOODS[_food_kind]
	var pts := int(cfg.score)
	var grow := int(cfg.grow)
	score += pts
	_speed_off += float(cfg.spd)   # 净速度偏移（提速负/减速正，显示效果由 _step_time clamp）
	if float(cfg.slow) > 0.0:
		_slow_left = float(cfg.slow)
		_popup(hud.t("tip.slow", "Slow 3s"), cfg.col,
				_cell_center(Vector2(_food_cell)) + Vector2(0, -_cell))
	_play_sfx(cfg.sfx)
	_growth_total += grow
	_grow_pending += grow
	if hud.submit_score(score) and not _record_shown:
		_record_shown = true
		_popup(hud.t("tip.new_record", "New Record!"), Color(1.0, 0.85, 0.25),
				Vector2(_board_rect.get_center().x, _board_rect.position.y + _board_rect.size.y * 0.22))
	_popup("+%d" % pts, _food_color(), _cell_center(Vector2(_food_cell)))
	_flash_at(_food_cell, _food_color())
	if not _low_fx:
		_shake_t = SHAKE_T
	_refresh_boards()
	_spawn_food()
	# 扩格检查：身体累计增量跨过 GROW_EVERY 整数倍 → 网格 +1（带动画）
	var target := _grid_for(_growth_total)
	if target > _grid:
		_grid_from = float(_grid)
		_grid = target
		_grow_anim_t = GROW_ANIM_T
		state = State.GROW
		_play_sfx("grow")
		_popup(hud.t("tip.grid_grow", "Field Grows %d×%d") % [_grid, _grid],
				Color(1.0, 0.85, 0.25),
				Vector2(_board_rect.get_center().x, _board_rect.position.y + _board_rect.size.y * 0.14))


## 死亡（撞墙/咬自身）：红色闪烁特效 + 入榜 + 延迟弹排行榜
func _die() -> void:
	state = State.OVER
	_play_sfx("die")
	_red_flash()
	if not _low_fx:
		_shake_t = SHAKE_T * 1.6
	_over_rank = hud.commit_score()
	_over_t = OVER_T
	print("[snake] game over, score=%d len=%d grid=%d" % [score, _cells.size(), _grid])


# ===== 渲染（每帧格间插值 + 转向角度渐变）=====

func _update_positions(t: float) -> void:
	_cell = _board_rect.size.x / _grid_disp
	var n := _cells.size()
	if n == 0:
		return
	_ensure_sprites()
	var scl := _cell / 96.0
	for i in n:
		var sp: Sprite2D = _seg_sprites[i]
		var cur: Vector2i = _cells[i]
		var prev: Vector2i = _prev_cells[i] if i < _prev_cells.size() else cur
		var pc := Vector2(prev)
		var cc := Vector2(cur)
		sp.position = _board_rect.position + (pc.lerp(cc, t) + Vector2(0.5, 0.5)) * _cell
		sp.scale = Vector2(scl, scl)
		if i == 0:
			# 蛇头：朝移动方向，转向时角度渐变（平滑过渡）
			var pangle := Vector2(_dir).angle()
			if _prev_cells.size() > 1:
				pangle = Vector2(Vector2i(_prev_cells[0]) - Vector2i(_prev_cells[1])).angle()
			sp.rotation = lerp_angle(pangle, Vector2(_dir).angle(), t)
			sp.texture = _tex["head"]
			sp.scale = Vector2(scl * 1.08, scl * 1.08)
			sp.z_index = 3
		elif i == n - 1:
			# 蛇尾：尖端拖在行进反方向（贴图尖朝左，宽端朝前）
			sp.rotation = Vector2(Vector2i(_cells[i - 1]) - cur).angle()
			sp.texture = _tex["tail"]
			sp.z_index = 1
		else:
			sp.texture = _tex["body"]
			sp.z_index = 2


## 食物：贴图/位置/呼吸脉动
func _update_food() -> void:
	if _food_cell.x < 0:
		_food_sprite.visible = false
		return
	_food_sprite.visible = true
	_food_sprite.position = _cell_center(Vector2(_food_cell))
	_food_sprite.texture = _tex[String(FOODS[_food_kind].tex)]
	# 呼吸动画：缩放 ±6% 正弦脉动
	var breathe := 1.0 + sin(_pulse_t * 4.0) * 0.06
	var scl := _cell * 0.82 * breathe / 96.0
	_food_sprite.scale = Vector2(scl, scl)
	_food_sprite.rotation = sin(_pulse_t * 2.2) * 0.08
	_food_sprite.z_index = 1


## 蛇身精灵池：数量随长度增减
func _ensure_sprites() -> void:
	while _seg_sprites.size() < _cells.size():
		var sp := Sprite2D.new()
		sp.texture = _tex["body"]
		sp.centered = true
		_snake_root.add_child(sp)
		_seg_sprites.append(sp)
	while _seg_sprites.size() > _cells.size():
		var sp: Sprite2D = _seg_sprites.pop_back()
		sp.queue_free()


func _clear_sprites() -> void:
	for sp: Sprite2D in _seg_sprites:
		sp.queue_free()
	_seg_sprites.clear()


# ===== 棋盘绘制（面板底 + 浅色半透明网格线 + 墙边框；扩格动画逐帧重绘）=====

func _on_board_draw() -> void:
	var r := _board_rect
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(3)
	sb.border_color = COL_BORDER
	sb.draw(_board.get_canvas_item(), r)
	# 网格线（浅色半透明）：竖横各 n-1 条，随 _grid_disp 插值平滑移动
	var n := int(roundf(_grid_disp))
	var lw := 1.0 if _low_fx else 1.5
	for i in range(1, n):
		var x := r.position.x + i * _cell
		var y := r.position.y + i * _cell
		if x < r.end.x - 0.5:
			_board.draw_line(Vector2(x, r.position.y + 3), Vector2(x, r.end.y - 3), COL_GRID, lw)
		if y < r.end.y - 0.5:
			_board.draw_line(Vector2(r.position.x + 3, y), Vector2(r.end.x - 3, y), COL_GRID, lw)


# ===== 特效 =====

## 吃食物闪光：星芒贴图放大淡出（低特效模式跳过）
func _flash_at(cell: Vector2i, col: Color) -> void:
	if _low_fx or _tex["fx_flash"] == null:
		return
	var fx := Sprite2D.new()
	fx.texture = _tex["fx_flash"]
	fx.position = _cell_center(Vector2(cell))
	fx.modulate = Color(col.r, col.g, col.b, 0.9)
	fx.scale = Vector2.ONE * _cell * 0.4 / 96.0
	fx.z_index = 5
	_fx_root.add_child(fx)
	var tw := fx.create_tween()
	tw.set_parallel(true)
	tw.tween_property(fx, "scale", Vector2.ONE * _cell * 1.15 / 96.0, FLASH_T) \
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
	if _shake_t > 0.0:
		_shake_t -= delta
		var amp := SHAKE_AMP * clampf(_shake_t / SHAKE_T, 0.0, 1.0)
		_shake_root.position = Vector2(randf_range(-amp, amp), randf_range(-amp, amp))
	else:
		_shake_root.position = Vector2.ZERO


# ===== 飘字 =====

func _popup(text: String, color: Color, pos: Vector2) -> void:
	var lb := Label.new()
	lb.text = text
	lb.position = pos - Vector2(100.0, _m * POPUP_FONT_RATIO)
	lb.size = Vector2(200.0, _m * POPUP_FONT_RATIO * 1.4)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(_m * POPUP_FONT_RATIO))
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.z_index = 10
	add_child(lb)
	var tw := lb.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - _m * 0.06, POPUP_TIME)
	tw.tween_property(lb, "modulate:a", 0.0, POPUP_TIME)
	tw.chain().tween_callback(lb.queue_free)


# ===== 几何 =====

## 格子中心像素（棋盘左上角 + 半格）
func _cell_center(c: Vector2) -> Vector2:
	return _board_rect.position + (c + Vector2(0.5, 0.5)) * _cell


## 像素 → 格子（棋盘外返回 -1,-1）
func _cell_at(pos: Vector2) -> Vector2i:
	var rel := pos - _board_rect.position
	if rel.x < 0 or rel.y < 0 or rel.x >= _board_rect.size.x or rel.y >= _board_rect.size.y:
		return Vector2i(-1, -1)
	return Vector2i(int(rel.x / _cell), int(rel.y / _cell))


func _food_color() -> Color:
	return FOODS[_food_kind].col


# ===== 交互 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
			return
		var kd := _key_dir(event.keycode)
		if kd != Vector2i.ZERO:
			_input_dir(kd)
		return
	# 鼠标左键 / 触屏点击（emulate_mouse_from_touch 默认开启，触摸也会派生鼠标事件）
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click_turn(get_global_mouse_position())


func _key_dir(code: int) -> Vector2i:
	match code:
		KEY_UP: return Vector2i.UP
		KEY_DOWN: return Vector2i.DOWN
		KEY_LEFT: return Vector2i.LEFT
		KEY_RIGHT: return Vector2i.RIGHT
		_: return Vector2i.ZERO


## 点击/触摸转向：水平移动按 Y 判上下、垂直移动按 X 判左右；点击蛇身无效
func _click_turn(pos: Vector2) -> void:
	var head := _cell_center(Vector2(_cells[0]))
	var cell := _cell_at(pos)
	if cell.x >= 0 and cell in _cells:
		return   # 点击蛇身子无效
	if state == State.READY:
		# 蛇水平朝右：按 Y 判上下启动
		var dy := pos.y - head.y
		if absf(dy) < _cell * 0.25:
			return
		_startplay(Vector2i.DOWN if dy > 0.0 else Vector2i.UP)
		return
	if state != State.PLAY:
		return
	if _dir.x != 0:   # 水平移动 → 按 Y 轴判断
		var dy := pos.y - head.y
		if absf(dy) < _cell * 0.25:
			return
		_input_dir(Vector2i.DOWN if dy > 0.0 else Vector2i.UP)
	else:             # 垂直移动 → 按 X 轴判断
		var dx := pos.x - head.x
		if absf(dx) < _cell * 0.25:
			return
		_input_dir(Vector2i.RIGHT if dx > 0.0 else Vector2i.LEFT)


func _input_dir(d: Vector2i) -> void:
	if state == State.READY:
		_startplay(d)
		return
	if state != State.PLAY:
		return
	if d == -_dir or d == _dir:
		return
	_pending_dir = d


func _startplay(d: Vector2i) -> void:
	if d == -_dir:
		return   # 初始朝右，直接掉头无效
	_pending_dir = d
	if state == State.READY:
		state = State.PLAY
		_step_t = 0.0


# ===== 食物生成 =====

## 在空白格子随机刷新食物（不生成在蛇身体上）
func _spawn_food() -> void:
	var occupied := {}
	for c: Vector2i in _cells:
		occupied[c] = true
	var empty: Array = []
	for y in _grid:
		for x in _grid:
			var c := Vector2i(x, y)
			if not occupied.has(c):
				empty.append(c)
	if empty.is_empty():
		_food_cell = Vector2i(-1, -1)   # 满盘（理论上 30×30 蛇占满前已结束）
		return
	_food_cell = empty[randi() % empty.size()]
	# 种类：按 FOODS 配置表权重随机（权重自动归一化）
	var total := 0.0
	for k: String in FOODS:
		total += float(FOODS[k].p)
	var r := randf() * total
	_food_kind = "apple"
	for k: String in FOODS:
		r -= float(FOODS[k].p)
		if r <= 0.0:
			_food_kind = k
			break
