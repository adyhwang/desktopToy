extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 分拣水果（Fruit Sort）：跷跷板物理分拣。
## 顶部管道持续掉落透明玻璃球，球内包裹一个随机水果（判定看它）。
## 按住鼠标左键左右拖动：统一倾斜所有跷跷板（左拖逆时针左低 / 右拖顺时针右低，
## 最大 ±80°），松手阻尼回弹归平。球落板吸附滑动（顺斜面滑向低端、滑出板端脱落），
## 主水果落入对应花篮 +2、落入错误花篮 -1、掉落地面无分无惩罚。
## 无尽模式：正确分拣数驱动难度（生成间隔/下落速度递增；8 次升 3 层 3 篮 3 种水果、
## 15 次升 4 层——篮/水果封顶 3；游戏区随层数缩放：区宽 0.2/0.3/0.4W、板场高 0.22/0.33/0.44H；
## 缩放基准：按 1080p 横屏设计值等比缩放（s = max(W/1920, H/1080)），竖屏随 H 放大
## 保持篮口≥球径，区宽钳面板 94% 防溢出）。
## 复用合集存档（GameHud submit_score/commit_score），最高分实时刷新。

const GameHud := preload("res://scripts/game_hud.gd")

# —— 可配置核心参数 ——
const FRUITS_POOL := ["apple", "banana", "carrot", "grape", "orange",
		"peach", "pear", "Pineapple", "strawberry", "watermelon"]
const KINDS_START := 2            # 起步水果种类（=花篮数，跷跷板 1+2 层共 3 块）
const KINDS_MAX := 3              # 种类上限（升 3 层 3 篮：1+2+3 共 6 块）
const UPGRADE_AT := 8             # 正确分拣数达到后升 3 层（1+2+3 共 6 板，篮/水果同步升 3）
const UPGRADE_AT2 := 15           # 正确分拣数达到后升 4 层（1+2+3+4 共 10 板，篮/水果封顶 3 不再加）
const SPAWN_EVERY_START := 2.2    # 生成间隔起步（s）
const SPAWN_EVERY_END := 1.2      # 生成间隔下限（随分拣数递减）
const FALL_START := 250.0         # 下落速度起步（px/s，匀速）
const FALL_END := 380.0           # 下落速度上限
const DIFF_RAMP := 40.0           # 正确分拣数达到后速度参数封顶
const MAX_BALLS := 15             # 同屏球数上限（达到后暂停生成）
const SCORE_OK := 2               # 分拣正确得分
const SCORE_BAD := -1             # 分拣错误扣分
const TILT_MAX_DEG := 80.0        # 跷跷板最大倾角（度，左右对称锁死）
const DRAG_RAD_PER_PX := 0.0025   # 拖动 1px → 目标倾角变化量（rad）
const FOLLOW_DRAG := 18.0         # 拖动时角度跟随系数（指数趋近）
const FOLLOW_RELEASE := 3.5       # 松手回弹系数（平滑归零无抖动）
const ROLL_ACCEL := 1150.0        # 沿板滑动加速度基数（× sinθ）
const ROLL_FRICTION := 0.55       # 滑动线性阻尼（比例/s）
const EXIT_KEEP := 0.85           # 脱板时保留的切向滑动速度比例
const WALL_BOUNCE := 0.55         # 撞玻璃墙保留的水平速度比例
const WALL_BOUNCE_MIN := 80.0     # 撞墙反弹的最小向内速度（足够弹离墙面不蹭行，又不过度弹飞）
const SINK_TIME := 0.32           # 入篮下沉消失时长（s）
const SFX_POOL := 4
const BGM_DB := -6.0
const SFX_DB := -4.0

# 配色（扁平卡通，同合集；无背景面板，透出启动器壁纸）
const COL_BORDER := Color(0.30, 0.23, 0.18)     # 深棕描边
const COL_GROUND := Color(0.90, 0.79, 0.60)     # 地面横带（同合集桌面横带）
const COL_WOOD := Color(0.80, 0.60, 0.36)       # 板面木色
const COL_WOOD_HI := Color(0.91, 0.74, 0.49)    # 板面高光条
const COL_WOOD_DARK := Color(0.42, 0.30, 0.18)  # 木描边
const COL_STAND := Color(0.55, 0.42, 0.26)      # 支架
const COL_PIPE := Color(0.60, 0.64, 0.69)       # 管道
const COL_PIPE_HI := Color(0.78, 0.82, 0.86)
const COL_PIPE_DARK := Color(0.34, 0.38, 0.44)
const COL_PIPE_IN := Color(0.16, 0.18, 0.22)
const COL_BASKET := Color(0.85, 0.66, 0.35)     # 花篮藤编
const COL_BASKET_DARK := Color(0.47, 0.34, 0.16)
const COL_GLASS := Color(0.85, 0.94, 1.0)       # 玻璃球
const COL_GOLD := Color(1.0, 0.85, 0.25)
const COL_ERR := Color(0.92, 0.30, 0.22)
const COL_FLOAT_OK := Color(0.16, 0.55, 0.18)
const COL_GRAY := Color(0.55, 0.55, 0.60)
const COL_DUST := Color(0.72, 0.62, 0.48)

var hud: RefCounted
var total := 0                   # 本局得分（正确 +2 / 错误 -1）
var delivered := 0               # 正确分拣数（难度驱动）
var kinds: Array = []            # 当前活跃水果（种类数 = 花篮数）
var _max_tilt: float = deg_to_rad(TILT_MAX_DEG)
var _ang := 0.0                  # 全局当前倾角（所有板一致，rad，+ = 右低顺时针）
var _ang_target := 0.0
var _dragging := false
var _drag_x0 := 0.0
var _ang0 := 0.0
var _boards: Array[Dictionary] = []   # 静态几何 {cx,y,L}（倾角为全局 _ang）
var _boards_rows := 2                 # 当前板层层数（2/3/4，随 delivered 升级递增）
var _balls: Array[Dictionary] = []
# ball: {main,sub,x,y,vx,state(fall/roll/sink),bi,s,sv,hop,t,cool_i,cool_y}
var _spawn_t := 0.0
var _floats: Array[Dictionary] = []   # {txt,col,pos,t}
var _committed := false
var _record_played := false           # 本局破纪录音效只播一次
var _alive_t := 0.0
var _pool_run: Array = []             # 本局水果抽取池（洗牌后按序取）

var _vp := Vector2(1920, 1080)
var _panel := Rect2()
var _ball_r := 30.0
var _plank_th := 16.0
var _pipe_cx := 960.0
var _pipe_w := 300.0
var _pipe_top := 0.0
var _pipe_mouth := 0.0
var _floor_y := 0.0
var _zone_l := 0.0                # 游戏区左界（随层数缩放：半宽 = 层数×板半长，墙内壁）
var _zone_r := 0.0                # 游戏区右界
var _basket_y := 0.0
var _basket_mw := 120.0
var _basket_bh := 90.0
var _fruit_texs := {}                 # 品种名 → Texture2D
var _sfx_streams := {}
var _sfx_players: Array = []
var _bgm: AudioStreamPlayer
var _hbox: HBoxContainer
var _lb_btn: Button
var _restart_btn: Button
var _bgm_btn: Button
var _volume_btn: Button
var _dev_pending := false           # 开发者暗门：排行榜面板 5 秒点满 10 次，关闭后弹 DEV 窗口
var _dev_clicks := 0
var _dev_click_ms := 0
var _dev_win: PanelContainer
var _dev_drag := false

@onready var _best_board: Label = $HudBar/BestBoard
@onready var _score_board: Label = $HudBar/ScoreBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton


func start() -> void:
	randomize()
	hud = GameHud.new("fruit_sort")
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
	_commit_run()
	print("[fruit_sort] stop, delivered=%d total=%d best=%d" % [delivered, total, hud.max_score])


## ===== 难度曲线（正确分拣数驱动）=====

func _spawn_every() -> float:
	return lerpf(SPAWN_EVERY_START, SPAWN_EVERY_END, clampf(float(delivered) / DIFF_RAMP, 0.0, 1.0))


func _fall_speed() -> float:
	return lerpf(FALL_START, FALL_END, clampf(float(delivered) / DIFF_RAMP, 0.0, 1.0))


func _kinds_wanted() -> int:
	return KINDS_MAX if delivered >= UPGRADE_AT else KINDS_START


## 板层层数（随正确分拣数递进：8 次 3 层 / 15 次 4 层；篮与水果种类封顶 3 不再增）
func _rows_wanted() -> int:
	if delivered >= UPGRADE_AT2:
		return 4
	return 3 if delivered >= UPGRADE_AT else 2


## ===== 局构建 =====

func _new_run() -> void:
	total = 0
	delivered = 0
	_committed = false
	_record_played = false
	_pool_run = FRUITS_POOL.duplicate()
	_pool_run.shuffle()
	kinds = _pool_run.slice(0, KINDS_START)
	_boards_rows = 2
	_balls.clear()
	_floats.clear()
	_ang = 0.0
	_ang_target = 0.0
	_dragging = false
	_spawn_t = 0.9
	hud.last_score = 0
	hud.reset_run()
	_build_boards()
	_sync_mouths()   # 重开回 2 层时板长可能恢复（4 层区宽上限曾压短）→ 口径同步
	_refresh_hud()
	queue_redraw()


## 板半长：按 1080p 横屏设计值 96（=0.05×1920）等比缩放，s = max(W/1920, H/1080)
## （16:9 下与旧 0.05W 完全一致；竖屏 W 窄随 H 放大，保持「篮口=板长 ≥ 1.7 球径」；
## 游戏区宽度由 1080p 设计值固定，其他分辨率等比缩放，不随窗口宽度直接压缩）；
## 再钳区宽（2×半长×层数）≤ 面板宽 94% 防溢出——层数越多板越短。篮口/管口上限跟随此值
func _board_half_len() -> float:
	var s := maxf(_vp.x / 1920.0, _vp.y / 1080.0)
	var L := maxf(96.0 * s, 40.0)
	return minf(L, _panel.size.x * 0.94 / (2.0 * float(_boards_rows)))


## 篮口/管口随板长同步（篮口半宽 = 板半长；管口 = 1080p 设计值 115.2 等比缩放，
## 上限 1.7 板长，落球必中 row1）
func _sync_mouths() -> void:
	_basket_mw = _board_half_len()
	var s := maxf(_vp.x / 1920.0, _vp.y / 1080.0)
	_pipe_w = minf(115.2 * s, _board_half_len() * 1.7)


## 跷跷板布局：游戏区随层数缩放——区宽 = 该层最多板数 × 板长（横屏 2/3/4 层 = 0.2/0.3/0.4W），
## 各行板在区内均分（与篮同心对齐，篮同样区内均分）；板行底部锚定 0.76H、
## 板场高随层数增高（2/3/4 层跨 0.22/0.33/0.44H，行距均分）。
## 升级瞬间区界/板 cx/y 重排，吸附球贴板随动继续滚（板下标顺序不变）
func _build_boards() -> void:
	var L := _board_half_len()
	_zone_l = _vp.x * 0.5 - L * float(_boards_rows)
	_zone_r = _vp.x * 0.5 + L * float(_boards_rows)
	var zone_w := _zone_r - _zone_l
	var pitch: float = 0.11 * float(_boards_rows) / float(maxi(_boards_rows - 1, 1))
	var rows_cnt := [1, 2, 3, 4]
	_boards.clear()
	for r in _boards_rows:
		var y := _vp.y * (0.76 - pitch * float(_boards_rows - 1 - r))
		var cnt: int = rows_cnt[r]
		for i in cnt:
			_boards.append({
				"cx": _zone_l + zone_w * (float(i) + 0.5) / float(cnt),
				"y": y,
				"L": L,
			})


## 花篮区内均分（2 篮 = 1/4、3/4 分位，3 篮 = 1/6、3/6、5/6 分位），随区宽缩放
func _basket_cxs() -> Array:
	var zone_w := _zone_r - _zone_l
	var out: Array = []
	for i in kinds.size():
		out.append(_zone_l + zone_w * (float(i) + 0.5) / float(kinds.size()))
	return out


## ===== 主循环 =====

func _process(delta: float) -> void:
	_advance(delta)
	queue_redraw()


## 全部模拟集中在此（headless 测试可直接步进，确定性可控）
func _advance(delta: float) -> void:
	_alive_t += delta
	# 倾角：指数趋近目标（拖动跟手 / 松手回弹），单调无过冲无抖动
	var k: float = FOLLOW_DRAG if _dragging else FOLLOW_RELEASE
	_ang = lerpf(_ang, _ang_target, 1.0 - exp(-k * delta))
	if not _dragging and absf(_ang - _ang_target) < 0.0004:
		_ang = _ang_target
	# 生成
	_spawn_t -= delta
	if _spawn_t <= 0.0:
		_spawn_t = _spawn_every()
		_spawn_ball()
	# 球
	for b in _balls.duplicate():
		_advance_ball(b, delta)
	_separate_balls()
	_post_separate_repair()
	# 浮字（dur=生命周期秒，普通分数字 0.9s / 升级提醒大字 1.8s）
	for f in _floats.duplicate():
		var t: float = float(f["t"]) + delta / float(f.get("dur", 0.9))
		if t >= 1.0:
			_floats.erase(f)
		else:
			f["t"] = t


## ===== 球：生成 / 落体 / 吸附滑动 =====

func _spawn_ball() -> void:
	var alive := 0
	for b in _balls:
		if String(b["state"]) != "sink":
			alive += 1
	if alive >= MAX_BALLS:
		return
	# 球内只包 1 个水果
	var main: String = String(kinds[randi() % kinds.size()])
	var jx: float = _pipe_w * 0.5 - _ball_r * 0.7
	_balls.append({
		"main": main,
		"x": _pipe_cx + randf_range(-jx, jx),
		"y": _pipe_mouth - _ball_r * 0.4,
		"vx": 0.0,
		"state": "fall", "bi": -1, "s": 0.0, "sv": 0.0,
		"hop": 0.0, "t": 0.0, "cool_i": -1, "cool_y": 0.0,
	})
	_play_sfx("spawn", -6.0)


func _advance_ball(b: Dictionary, delta: float) -> void:
	match String(b["state"]):
		"fall":
			b["t"] = minf(float(b["t"]) + delta / 0.16, 1.0)
			# 子步进防穿隧（每步 ≤ R/2），匀速下落
			var remain: float = _fall_speed() * delta
			while remain > 0.0 and String(b["state"]) == "fall":
				var step: float = minf(remain, _ball_r * 0.5)
				remain -= step
				b["y"] = float(b["y"]) + step
				b["x"] = float(b["x"]) + float(b["vx"]) * step / maxf(_fall_speed(), 1.0)
				_try_capture(b)
		"roll":
			_roll_ball(b, delta)
		"sink":
			b["t"] = float(b["t"]) + delta / SINK_TIME
			b["y"] = float(b["y"]) + 60.0 * delta
			if float(b["t"]) >= 1.0:
				_balls.erase(b)


## ===== 玻璃球碰撞（整球为碰撞体）=====
## 玻璃球 = 圆（球心 p、半径 _ball_r）；跷跷板 = 胶囊体（中心线段 c±t·L 膨胀 th/2，
## 绘制居中于中心线）；玻璃墙 = 区界竖直壁面。球与一切固体的碰撞都按整球体积判定：
## 先把球推出到固体表面（任何状态零侵入），再按接触朝向分流——
## 接触面朝上（板面/端点弧面上方）→ 落板吸附滚动；朝下/侧 → 弹开/被板挡住贴面滑落。

## 球间互斥（圆-圆碰撞）：重叠球对沿连线分离。roll 球把位移的切向分量吸进 s
##（球心恒贴板面立即重算），fall 吸收 x/y；sink 球不推动、对方全额推开。
## 只做位置分离不做速度交换（吸附式物理，稳定优先）：fall 球落在球上被撑住悬停，
## 横向有速度时自然滑开
func _separate_balls() -> void:
	var min_d := _ball_r * 2.0
	for a_i in _balls.size():
		var a: Dictionary = _balls[a_i]
		for b_i in range(a_i + 1, _balls.size()):
			var c: Dictionary = _balls[b_i]
			var dx: float = float(a["x"]) - float(c["x"])
			var dy: float = float(a["y"]) - float(c["y"])
			var dist := sqrt(dx * dx + dy * dy)
			if dist >= min_d:
				continue
			var overlap := min_d - dist
			var dir := Vector2(dx / dist, dy / dist) if dist > 0.001 else Vector2(0, -1)
			var full_a := String(a["state"]) == "sink"
			var full_c := String(c["state"]) == "sink"
			_push_ball(a, dir * (overlap if full_c else overlap * 0.5))
			_push_ball(c, -dir * (overlap if full_a else overlap * 0.5))


func _push_ball(b: Dictionary, v: Vector2) -> void:
	var st := String(b["state"])
	if st == "sink":
		return
	if st == "roll":
		var bd: Dictionary = _boards[int(b["bi"])]
		var L: float = float(bd["L"])
		b["s"] = clampf(float(b["s"]) + v.dot(Vector2(cos(_ang), sin(_ang))), -L, L)
		var n := _board_normal()
		b["x"] = float(bd["cx"]) + cos(_ang) * float(b["s"]) + n.x * _ball_rad()
		b["y"] = float(bd["y"]) + sin(_ang) * float(b["s"]) + n.y * _ball_rad()
	else:
		b["x"] = float(b["x"]) + v.x
		b["y"] = float(b["y"]) + v.y


## 帧末修复通道：球间分离只管球-球不管球-板，会把 roll 球沿板推过端缝挡位
## （1~4px 嵌进邻板端帽）、把 fall 球压进板体（可达 10px+ 深嵌入直落）。
## roll 球重跑端缝挡位并按 (bi,s) 公式复位球心（代价是与挤推球轻微重叠，优于嵌板）；
## fall 球对全部板做胶囊推出到表面（不吸附不改速度不钳墙——板推出优先于墙，
## 越墙部分下一子步开头墙钳制接管），保证任何帧结束时球对板零侵入
func _post_separate_repair() -> void:
	var rad := _ball_rad()
	var t := Vector2(cos(_ang), sin(_ang))
	var n := _board_normal()
	for b in _balls:
		var st := String(b["state"])
		if st == "roll":
			var bd: Dictionary = _boards[int(b["bi"])]
			_block_by_neighbor(b, bd)
			b["x"] = float(bd["cx"]) + t.x * float(b["s"]) + n.x * rad
			b["y"] = float(bd["y"]) + t.y * float(b["s"]) + n.y * rad
		elif st == "fall":
			var p := Vector2(float(b["x"]), float(b["y"]))
			# 大倾角跨排双板楔缝：一次推出可能进入另一板 → 迭代至零侵入（≤3 轮，
			# 板体互相重叠的极端楔形收敛到最宽点，残余属布局固有）
			for pass_i in 3:
				var pushed := false
				for bd2 in _boards:
					var c := Vector2(float(bd2["cx"]), float(bd2["y"]))
					var u: float = clampf((p - c).dot(t), -float(bd2["L"]), float(bd2["L"]))
					var q := c + t * u
					var dv := p - q
					var dist := dv.length()
					if dist < rad:
						var dir: Vector2 = dv / dist if dist > 0.001 else n
						p = q + dir * (rad + 0.5)
						b["x"] = p.x
						b["y"] = p.y
						pushed = true
				if not pushed:
					break


## 竖墙半厚（墙骑区界线绘制，内壁 = 区界 ± 半厚）
func _wall_in() -> float:
	return maxf(_ball_r * 0.28, 8.0) * 0.5


## 球心到板中心线的最小距离（整球 vs 板胶囊互斥半径）
func _ball_rad() -> float:
	return _ball_r + _plank_th * 0.5


## 落体碰撞检测：玻璃墙反弹 → 板胶囊碰撞（吸附/弹开）→ 入篮 → 落地（顺序即优先级）
func _try_capture(b: Dictionary) -> void:
	var wi := _wall_in()
	var l_lim := _zone_l + _ball_r + wi
	var r_lim := _zone_r - _ball_r - wi
	# 玻璃墙：球面不得越过竖墙内壁，水平速度反弹衰减（保底明显弹离墙面不蹭行）
	if float(b["x"]) < l_lim:
		b["x"] = l_lim
		b["vx"] = maxf(absf(float(b["vx"])) * WALL_BOUNCE, WALL_BOUNCE_MIN)
	elif float(b["x"]) > r_lim:
		b["x"] = r_lim
		b["vx"] = -maxf(absf(float(b["vx"])) * WALL_BOUNCE, WALL_BOUNCE_MIN)
	# 球间互斥：下落球撞到其他球上被撑住（推出到球面悬停，不再下落穿球/触板）。
	# 帧末 _separate_balls 来不及撑住——子步内不加此步，球会先穿到板上被吸附
	for c in _balls:
		if c == b or String(c["state"]) == "sink":
			continue
		var cdx: float = float(b["x"]) - float(c["x"])
		var cdy: float = float(b["y"]) - float(c["y"])
		var cdist := sqrt(cdx * cdx + cdy * cdy)
		if cdist >= _ball_r * 2.0:
			continue
		if cdist > 0.001:
			b["x"] = float(c["x"]) + cdx / cdist * (_ball_r * 2.0 + 0.5)
			b["y"] = float(c["y"]) + cdy / cdist * (_ball_r * 2.0 + 0.5)
		else:
			b["y"] = float(c["y"]) - _ball_r * 2.0
	b["x"] = clampf(float(b["x"]), l_lim, r_lim)
	var p := Vector2(float(b["x"]), float(b["y"]))
	var ang := _ang
	var t := Vector2(cos(ang), sin(ang))
	var n := Vector2(sin(ang), -cos(ang))   # 板面朝上法线
	var rad := _ball_rad()
	for i in _boards.size():
		var bd: Dictionary = _boards[i]
		var c := Vector2(float(bd["cx"]), float(bd["y"]))
		var d := p - c
		var u: float = clampf(d.dot(t), -float(bd["L"]), float(bd["L"]))
		var q := c + t * u
		var dv := p - q
		var dist := dv.length()
		if dist >= rad:
			continue   # 整球未触及板胶囊
		# 整球侵入板体：先推出到胶囊表面（零侵入），再按接触朝向分流
		var dir: Vector2 = dv / dist if dist > 0.001 else -n
		# 仅接触明显朝上（dir·n > 0.5，约 60° 锥内：板面正上/端点上空）才吸附；
		# 擦边斜触（球路过板旁擦过端点弧面侧缘）一律弹开，防球被"自动吸上板"
		var grab := dir.dot(n) > 0.5
		# 冷却板（刚脱落）不再完全免检——完全跳过会被快速转动的板整体扫过
		# 而穿模（球嵌板随板走）。免检期内：球心落回板面中部（|u| ≤ L − R/2）
		# 按真落回吸附；端点上空擦过仍自由飞过（防脱板端点循环再吸附、
		# 不改速度不托球蹭行），但必须推出到胶囊表面保零侵入——免检期内板旋转
		# 扫过免检球时球被端面铲开，不再被板身压穿直落；板底/侧面接触照常推出弹开
		if grab and i == int(b["cool_i"]) \
				and p.y - float(b["cool_y"]) < _ball_r * 2.2:
			if absf(d.dot(t)) <= float(bd["L"]) - _ball_r * 0.5:
				p = q + dir * (rad + 0.5)
				b["x"] = p.x
				b["y"] = p.y
				_land_on_board(b, i, u)
				return
			p = q + dir * (rad + 0.5)
			b["x"] = p.x
			b["y"] = p.y
			# 不回钳墙：板端恰在墙上，推出后再钳 x 会把球压回板端楔缝（板端/墙空间
			# 小于球径）——板推出优先，越墙 1~4px 由下一子步开头墙钳制反弹接管
			continue
		p = q + dir * (rad + 0.5)
		b["x"] = p.x
		b["y"] = p.y
		if grab:
			# 接触面朝上（板面或端点弧面上方）→ 整球落板吸附
			_land_on_board(b, i, u)
			return
		# 接触面朝下/侧下 → 球撞板底被挡住：下落匀速不变，水平分量按 dir 反射，
		# 每子步侵入→推出即沿板底贴面下滑；不回钳墙（板推出优先，防板端/墙楔缝
		# 回嵌，越墙由下一子步开头墙钳制反弹接管）
		var vn := float(b["vx"]) * dir.x + _fall_speed() * dir.y
		if vn < 0.0:
			b["vx"] = float(b["vx"]) - (1.0 + WALL_BOUNCE) * vn * dir.x
	var cxs := _basket_cxs()
	if p.y >= _basket_y:
		# 最近篮判定（篮口沿相接时球必入其一，并列取索引小）
		var k_best := -1
		var d_best := INF
		for k in cxs.size():
			var dk := absf(p.x - float(cxs[k]))
			if dk < d_best:
				d_best = dk
				k_best = k
		if k_best >= 0 and d_best <= _basket_mw:
			_ball_into_basket(b, k_best)
			return
	if p.y >= _floor_y:
		_ball_on_floor(b)


func _land_on_board(b: Dictionary, i: int, u: float) -> void:
	var bd: Dictionary = _boards[i]
	b["state"] = "roll"
	b["bi"] = i
	b["cool_i"] = -1
	b["s"] = u
	var t := Vector2(cos(_ang), sin(_ang))
	var vin := Vector2(float(b["vx"]), _fall_speed())
	b["sv"] = clampf(vin.dot(t) * 0.9, -520.0, 520.0)
	b["hop"] = 1.0
	b["t"] = 0.0
	_play_sfx("bounce", -8.0)
	var n := _board_normal()
	# 吸附落位：球心立即贴合板面上表面（球底恰触板面，消除 fall→roll 球心瞬移）
	var pos := Vector2(float(bd["cx"]), float(bd["y"])) + t * u + n * _ball_rad()
	b["x"] = pos.x
	b["y"] = pos.y
	var contact := pos - n * _ball_r
	_spawn_burst(contact, COL_DUST, 5, 80.0)


## 吸附滑动：顺斜面滑向低端（a = 基数 × sinθ），滑出板端脱落
func _roll_ball(b: Dictionary, delta: float) -> void:
	var i := int(b["bi"])
	if i < 0 or i >= _boards.size():
		b["state"] = "fall"   # 板被重建等异常兜底
		b["bi"] = -1
		return
	var bd: Dictionary = _boards[i]
	var L: float = float(bd["L"])
	var sv: float = float(b["sv"]) + ROLL_ACCEL * sin(_ang) * delta
	sv *= exp(-ROLL_FRICTION * delta)
	b["sv"] = sv
	b["s"] = float(b["s"]) + sv * delta
	if absf(float(b["s"])) >= L and signf(float(b["sv"])) == signf(float(b["s"])):
		_detach_ball(b, i)
		return
	b["s"] = clampf(float(b["s"]), -L, L)   # 端点兜底钳制
	# 同排邻板端缝挡球（板倾斜时两板胶囊重叠，球滚到端部会嵌进邻板体 → 穿模）
	_block_by_neighbor(b, bd)
	# 球心跟随板角实时更新（板转动时球随板面移动），球底恒贴板面上表面
	var n := _board_normal()
	b["x"] = float(bd["cx"]) + cos(_ang) * float(b["s"]) + n.x * _ball_rad()
	b["y"] = float(bd["y"]) + sin(_ang) * float(b["s"]) + n.y * _ball_rad()
	# roll 球心墙约束：球心必须恒在板面上（零侵板）且球面不出墙（零侵墙）。
	# 简单钳 x 会让球心脱离板面嵌进板体（板斜向墙侧、球滚向低端时尤甚）——
	# 钳 x 后沿板面反解 s 重投影；陡板（|cosθ| 过小）反解无意义 → 直接脱板转 fall，
	# 由 fall 的整球碰撞接管（球沿墙弹开/下滑）
	var wi := _wall_in()
	var l_lim := _zone_l + _ball_r + wi
	var r_lim := _zone_r - _ball_r - wi
	if float(b["x"]) < l_lim or float(b["x"]) > r_lim:
		var tx := cos(_ang)
		if absf(tx) > 0.2:
			var x_lim := clampf(float(b["x"]), l_lim, r_lim)
			var s2: float = (x_lim - (float(bd["cx"]) + n.x * _ball_rad())) / tx
			b["s"] = clampf(s2, -L, L)
			b["x"] = float(bd["cx"]) + tx * float(b["s"]) + n.x * _ball_rad()
			b["y"] = float(bd["y"]) + sin(_ang) * float(b["s"]) + n.y * _ball_rad()
			# 重投影后仍出墙（板端压墙线、球心法向偏移越过内壁）→ 脱板转 fall
			if float(b["x"]) < l_lim - 0.5 or float(b["x"]) > r_lim + 0.5:
				_detach_ball(b, i)
				return
		else:
			_detach_ball(b, i)
			return
	b["hop"] = maxf(float(b["hop"]) - delta / 0.22, 0.0)


## 同排紧邻板端缝挡球：板倾斜后两板胶囊重叠（板心距×sinθ < 球互斥半径 38，θ<23° 时
## 球贴板面滚到端部球面会嵌进邻板体 = 视觉穿模，脱板后又被邻板下表面弹开直落）。
## 球心沿板方向钳到距邻板端面 rad 的安全位、sv 轻微反弹 0.25 → 球抵住端缝停住不嵌；
## 板转平（法向间距恢复 ≥ rad）后挡位消失球继续滚。跨排大倾角重叠由布局固有决定，不在此处理
func _block_by_neighbor(b: Dictionary, bd: Dictionary) -> void:
	var sth := sin(_ang)
	if absf(sth) < 0.001:
		return   # 板平放时同排共线不相交
	var cth := cos(_ang)
	var rad_self := _ball_rad()
	for j in _boards.size():
		if _boards[j] == bd:
			continue
		var bd2: Dictionary = _boards[j]
		if absf(float(bd2["y"]) - float(bd["y"])) > 0.5:
			continue   # 仅同排（跨排重叠另属布局问题）
		var dc: float = float(bd2["cx"]) - float(bd["cx"])
		if absf(absf(dc) - (float(bd["L"]) + float(bd2["L"]))) > 1.0:
			continue   # 仅紧邻（端点相接）板
		var dn: float = rad_self - dc * sth   # 球心(贴本板面)到邻板线的带符号法向距
		if absf(dn) >= rad_self:
			continue   # 邻板在球下方或法向间距足够，不相交
		var dxlim: float = sqrt(maxf(rad_self * rad_self - dn * dn, 0.0))
		var tb: float = dc * cth - signf(dc) * float(bd2["L"])   # 邻板近端 t 坐标
		if dc > 0.0:
			var s_hi: float = tb - dxlim
			if float(b["s"]) > s_hi:
				b["s"] = s_hi
				b["sv"] = -float(b["sv"]) * 0.25
		else:
			var s_lo: float = tb + dxlim
			if float(b["s"]) < s_lo:
				b["s"] = s_lo
				b["sv"] = -float(b["sv"]) * 0.25


func _detach_ball(b: Dictionary, i: int) -> void:
	var bd: Dictionary = _boards[i]
	var L: float = float(bd["L"])
	b["s"] = clampf(float(b["s"]), -L, L)
	var n := _board_normal()
	b["x"] = float(bd["cx"]) + cos(_ang) * float(b["s"]) + n.x * _ball_rad()
	b["y"] = float(bd["y"]) + sin(_ang) * float(b["s"]) + n.y * _ball_rad()
	b["vx"] = float(b["sv"]) * EXIT_KEEP * cos(_ang)
	b["state"] = "fall"
	b["bi"] = -1
	b["cool_i"] = i
	b["cool_y"] = float(b["y"])
	# 球心出墙时不能只钳 x（会嵌进板体，且 detach 后该板免检不修正）——
	# 与 roll 同法沿板面反解重投影保持贴面，之后钳 x 兜底
	var wi := _wall_in()
	var l_lim := _zone_l + _ball_r + wi
	var r_lim := _zone_r - _ball_r - wi
	if float(b["x"]) < l_lim or float(b["x"]) > r_lim:
		var tx := cos(_ang)
		if absf(tx) > 0.2:
			var x_lim := clampf(float(b["x"]), l_lim, r_lim)
			var s2: float = (x_lim - (float(bd["cx"]) + n.x * _ball_rad())) / tx
			b["s"] = clampf(s2, -L, L)
			b["x"] = float(bd["cx"]) + tx * float(b["s"]) + n.x * _ball_rad()
			b["y"] = float(bd["y"]) + sin(_ang) * float(b["s"]) + n.y * _ball_rad()
			b["cool_y"] = float(b["y"])
		b["x"] = clampf(float(b["x"]), l_lim, r_lim)


func _board_normal() -> Vector2:
	return Vector2(sin(_ang), -cos(_ang))


## ===== 分拣判定 =====

func _ball_into_basket(b: Dictionary, k: int) -> void:
	b["state"] = "sink"
	b["t"] = 0.0
	b["x"] = lerpf(float(b["x"]), float(_basket_cxs()[k]), 0.5)   # 吸向篮口居中
	var pos := Vector2(float(b["x"]), _basket_y - _ball_r * 2.0)
	var ok: bool = String(b["main"]) == String(kinds[k])
	if ok:
		delivered += 1
		total += SCORE_OK
		_play_sfx("correct")
		_spawn_burst(Vector2(float(b["x"]), _basket_y), COL_GOLD, 26, 300.0)
		_spawn_float("+%d" % SCORE_OK, COL_FLOAT_OK, pos)
	else:
		total += SCORE_BAD
		_play_sfx("wrong")
		_spawn_burst(Vector2(float(b["x"]), _basket_y), COL_ERR, 18, 220.0)
		_spawn_float("%d" % SCORE_BAD, COL_ERR, pos)
	var prev_best: int = hud.max_score
	if hud.submit_score(total) and prev_best > 0 and not _record_played:
		_record_played = true   # 本局首次破纪录
		_play_sfx("record")
	_maybe_upgrade()
	_refresh_hud()


func _ball_on_floor(b: Dictionary) -> void:
	_spawn_burst(Vector2(float(b["x"]), _floor_y), COL_DUST, 10, 130.0)
	_play_sfx("bounce", -16.0)
	_balls.erase(b)


## 升级同步：篮/水果种类封顶 KINDS_MAX（15 次后不再增加），板层随正确分拣数递进
## （8 次 → 3 层 1+2+3，15 次 → 4 层 1+2+3+4）。层升时 1-3 层板下标不变，
## 吸附中的球原样保留继续滚动（4 层重排 y，球贴板随层平移，新板不碰撞现有球）；
## 每次实际升难度：清空场上已有球（板面重排后从干净状态重新掉落）+ 居中浮字提醒
func _maybe_upgrade() -> void:
	var changed := false
	while kinds.size() < _kinds_wanted():
		kinds.append(String(_pool_run[kinds.size()]))
		changed = true
	var rows := _rows_wanted()
	if _boards_rows < rows:
		_boards_rows = rows
		changed = true
	if changed:
		_build_boards()
		_sync_mouths()   # 板长随层数变化（区宽上限钳制）→ 篮口/管口同步
		_balls.clear()
		_spawn_float(hud.t("ui.upgrade", "Level Up!"), COL_GOLD,
				Vector2(_vp.x * 0.5, _vp.y * 0.40), 1.8, true)


## ===== 结束 / 重开 =====

func _commit_run() -> void:
	if _committed:
		return
	_committed = true
	if total > 0:
		hud.submit_score(total)
		hud.commit_score()


func _restart() -> void:
	if not _committed and total > 0:   # 重开视作本局结束（合集惯例）
		_commit_run()
	_new_run()


func _exit_button_pressed() -> void:
	exit_requested.emit()


## ===== 输入：按住左键左右拖动统一倾斜所有板 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_restart()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_x0 = event.position.x
			_ang0 = _ang_target
		else:
			_dragging = false
			_ang_target = 0.0   # 松手回弹归平（阻尼趋近，无抖动）
	elif event is InputEventMouseMotion and _dragging:
		# 左拖 dx<0 → 负角（逆时针左低）；右拖 dx>0 → 正角（顺时针右低）
		_ang_target = clampf(_ang0 + (event.position.x - _drag_x0) * DRAG_RAD_PER_PX,
				-_max_tilt, _max_tilt)


## ===== 布局 =====

func _layout() -> void:
	_vp = get_viewport_rect().size
	var m := minf(_vp.x, _vp.y)
	_panel = Rect2(24.0, 84.0, maxf(_vp.x - 48.0, 60.0), maxf(_vp.y - 108.0, 60.0))
	_ball_r = clampf(_vp.y * 0.028, 18.0, 34.0)
	_plank_th = clampf(_vp.y * 0.016, 12.0, 20.0)
	_build_boards()   # 板长/区界（1080p 设计等比缩放 + 区宽钳面板 94%）
	_pipe_cx = _vp.x * 0.5
	_pipe_top = _panel.position.y + 2.0
	_pipe_mouth = _panel.position.y + _vp.y * 0.10
	_basket_y = _vp.y * 0.86
	_basket_bh = clampf(_vp.y * 0.082, 56.0, 116.0)
	_floor_y = _vp.y * 0.92
	_sync_mouths()   # 篮口 = 板半长、管口上限 0.85 板长（落球必中 row1）
	for b: Label in [_best_board, _score_board]:
		b.custom_minimum_size = Vector2(200.0, m * 0.051)
		b.add_theme_font_size_override("font_size", int(m * 0.035))
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((_vp.x - _hud_bar.size.x) * 0.5, 14.0)
	_hbox.reset_size()
	_hbox.position = Vector2(_vp.x - _hbox.size.x - 20.0, 14.0)
	_refresh_hud()
	queue_redraw()


func _refresh_hud() -> void:
	_best_board.text = hud.t("hud.best", "Best %d") % hud.max_score
	_score_board.text = hud.t("hud.score", "Score %d") % total


## ===== 顶部按钮（排行榜 + 重开 + BGM + 音量 + ✕，tscn 已有 ✕）=====

func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", -8)
	add_child(_hbox)
	_hbox.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜）顶栏按钮仍可点
	var old_parent := _exit_btn.get_parent()   # tscn 节点迁入容器（原父为游戏根）
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
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
	_lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_restart)
	_bgm_btn.pressed.connect(_on_bgm)
	_volume_btn.pressed.connect(_on_volume)


func _on_lb() -> void:
	hud.show_leaderboard(self, hud.t("ui.top10", "Leaderboard"), -1, -1)
	_arm_dev_clicks()


## 排行榜关闭回调（GameHud._close_lb 调用，paused 已恢复）：
## 暗门已触发则弹出 DEV 窗口
func on_leaderboard_closed() -> void:
	if _dev_pending:
		_dev_pending = false
		_show_dev_window()


## ===== 开发者模式（排行榜面板暗门：5 秒点满 10 次 → 关闭后弹出 DEV 窗口）=====

## 绑定排行榜面板点击计数（每次弹榜后调用，面板为新建节点）
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
		if panel != null:   # 标题金色反馈（面板 ALWAYS，暂停中可见）
			var head := panel.get_child(0)
			if head is Container and head.get_child(0) is Label:
				(head.get_child(0) as Label).add_theme_color_override("font_color", COL_GOLD)


## DEV 窗口：可拖动、常驻（✕ 关闭），功能按钮 2 列网格
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
	title.add_theme_color_override("font_color", COL_GOLD)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 6)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := GameHud.make_button("✕")
	close_btn.pressed.connect(_dev_close)
	head.add_child(close_btn)
	# 功能按钮网格
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)
	var actions := [
		[hud.t("dev.score", "Score +10"), _dev_add_score],
		[hud.t("dev.upgrade", "Upgrade now"), _dev_upgrade],
		[hud.t("dev.spawn", "Spawn ball"), _dev_spawn],
		[hud.t("dev.clear", "Clear balls"), _dev_clear],
	]
	for a: Array in actions:
		var btn := GameHud.make_button(a[0])
		btn.add_theme_font_size_override("font_size", 14)
		btn.custom_minimum_size = Vector2(140.0, 30.0)
		btn.pressed.connect(a[1])
		grid.add_child(btn)
	add_child(_dev_win)     # 屏幕坐标（同排行榜面板，不随绘制缩放）
	_dev_win.z_index = 250  # 浮于排行榜(220)之上
	_dev_win.reset_size()
	_dev_win.position = Vector2(24.0, vp.y * 0.3)
	# 标题栏拖动
	head.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dev_drag = event.pressed
		elif event is InputEventMouseMotion and _dev_drag:
			_dev_win.position += event.relative)


func _dev_close() -> void:
	_dev_drag = false
	if _dev_win != null and is_instance_valid(_dev_win):
		_dev_win.queue_free()
	_dev_win = null


## 分数 +10（走正常提交，实时刷新最高分）
func _dev_add_score() -> void:
	total += 10
	hud.submit_score(total)
	_refresh_hud()


## 立即升满 4 层（1+2+3+4 共 10 板；篮/水果封顶 3）
## 旧实现守卫用当前 delivered 算目标——未达 8 分时 _kinds_wanted()=2，2<2 恒假，
## 按钮永远不生效；现无条件把 delivered 推到 UPGRADE_AT2 再同步
func _dev_upgrade() -> void:
	delivered = maxi(int(delivered), int(UPGRADE_AT2))
	_maybe_upgrade()
	_refresh_hud()
	queue_redraw()


## 立即生成一颗球
func _dev_spawn() -> void:
	_spawn_ball()


## 清空所有球
func _dev_clear() -> void:
	_balls.clear()
	queue_redraw()


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
	# 无背景：不画面板填充，直接透出启动器壁纸；地面横带（限游戏区）+ 上沿线
	var band := Rect2(_zone_l, _floor_y, _zone_r - _zone_l,
			_panel.position.y + _panel.size.y - _floor_y - 4.0)
	draw_rect(band, COL_GROUND, true)
	draw_line(Vector2(band.position.x, _floor_y),
			Vector2(band.position.x + band.size.x, _floor_y), COL_BORDER, 3.0)
	_draw_walls()
	_draw_pipe()
	# 入篮下沉的球画在花篮后面（沉入篮内）
	for b in _balls:
		if String(b["state"]) == "sink":
			_draw_ball(b)
	_draw_baskets()
	for bd in _boards:
		_draw_fulcrum(bd)
	for bd in _boards:
		_draw_plank(bd)
	for b in _balls:
		if String(b["state"]) != "sink":
			_draw_ball(b)
	for f in _floats:
		_draw_float(f)


## 透明玻璃墙（参考鱼缸逃生）：上段横条 + 两端竖条，阻挡球飞出游戏区
func _draw_walls() -> void:
	var t := maxf(_ball_r * 0.28, 8.0)   # 墙厚
	var top := _pipe_top
	var g := Color(COL_GLASS.r, COL_GLASS.g, COL_GLASS.b, 0.20)
	var go := Color(COL_BORDER.r, COL_BORDER.g, COL_BORDER.b, 0.55)
	var hi := Color(1, 1, 1, 0.35)
	# 两端竖墙
	for wx: float in [_zone_l, _zone_r]:
		draw_rect(Rect2(wx - t * 0.5, top, t, _floor_y - top), g, true)
		draw_line(Vector2(wx, top), Vector2(wx, _floor_y), hi, 2.0)
		draw_line(Vector2(wx - t * 0.5, top), Vector2(wx - t * 0.5, _floor_y), go, 2.0)
		draw_line(Vector2(wx + t * 0.5, top), Vector2(wx + t * 0.5, _floor_y), go, 2.0)
	# 上段横墙（横跨全区，管道料斗后画盖过中段）
	draw_rect(Rect2(_zone_l - t * 0.5, top, _zone_r - _zone_l + t, t), g, true)
	draw_line(Vector2(_zone_l - t * 0.5, top + t * 0.5),
			Vector2(_zone_r + t * 0.5, top + t * 0.5), hi, 2.0)
	draw_line(Vector2(_zone_l - t * 0.5, top + t),
			Vector2(_zone_r + t * 0.5, top + t), go, 2.0)


## 顶部管道：上宽下窄料斗 + 出料口暗槽
func _draw_pipe() -> void:
	var hw: float = _pipe_w * 0.5
	var hw2: float = hw + 26.0
	var cx := _pipe_cx
	var pts := PackedVector2Array([
		Vector2(cx - hw2, _pipe_top), Vector2(cx + hw2, _pipe_top),
		Vector2(cx + hw, _pipe_mouth), Vector2(cx - hw, _pipe_mouth),
	])
	draw_colored_polygon(pts, COL_PIPE)
	var ol := pts.duplicate()
	ol.append(pts[0])
	draw_polyline(ol, COL_PIPE_DARK, 3.0)
	# 顶沿高光条
	var hi := StyleBoxFlat.new()
	hi.bg_color = COL_PIPE_HI
	hi.set_corner_radius_all(5)
	draw_style_box(hi, Rect2(cx - hw2 + 8.0, _pipe_top + 6.0, hw2 * 2.0 - 16.0, 9.0))
	# 出料口暗槽
	draw_rect(Rect2(cx - hw + 8.0, _pipe_mouth - 12.0, hw * 2.0 - 16.0, 12.0), COL_PIPE_IN)


func _draw_baskets() -> void:
	var cxs := _basket_cxs()
	for k in cxs.size():
		var cx: float = float(cxs[k])
		# 地面影子
		draw_set_transform(Vector2(cx, _floor_y + 6.0), 0.0, Vector2(1.0, 0.22))
		draw_circle(Vector2.ZERO, _basket_mw * 1.05, Color(0.12, 0.09, 0.05, 0.14))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# 篮身梯形（口宽 → 底宽 62%）
		var bw: float = _basket_mw * 0.62
		var pts := PackedVector2Array([
			Vector2(cx - _basket_mw, _basket_y),
			Vector2(cx + _basket_mw, _basket_y),
			Vector2(cx + bw, _basket_y + _basket_bh),
			Vector2(cx - bw, _basket_y + _basket_bh),
		])
		draw_colored_polygon(pts, COL_BASKET)
		# 编织横纹
		for li in 2:
			var kk: float = 0.35 + 0.30 * float(li)
			var halfw: float = lerpf(_basket_mw, bw, kk)
			var ly: float = _basket_y + _basket_bh * kk
			draw_line(Vector2(cx - halfw + 6.0, ly), Vector2(cx + halfw - 6.0, ly),
					Color(COL_BASKET_DARK.r, COL_BASKET_DARK.g, COL_BASKET_DARK.b, 0.30), 3.0)
		var ol := pts.duplicate()
		ol.append(pts[0])
		draw_polyline(ol, COL_BASKET_DARK, 3.0)
		# 口沿横杆（圆角；宽 = 口宽 - 8，3 篮口沿相接不重叠）
		var rim := StyleBoxFlat.new()
		rim.bg_color = COL_BASKET_DARK
		rim.set_corner_radius_all(6)
		draw_style_box(rim, Rect2(cx - _basket_mw + 4.0, _basket_y - 7.0,
				(_basket_mw - 4.0) * 2.0, 12.0))
		# 水果标识徽章（篮身正面）
		var tex: Texture2D = _fruit_texs.get(String(kinds[k]))
		var bs: float = _basket_bh * 0.62
		var bc := Vector2(cx, _basket_y + _basket_bh * 0.60)
		draw_circle(bc, bs * 0.74, Color(1, 1, 1, 0.94))
		draw_arc(bc, bs * 0.74, 0, TAU, 40, COL_BASKET_DARK, 3.0)
		if tex != null:
			draw_texture_rect(tex, Rect2(bc - Vector2(bs, bs) * 0.5, Vector2(bs, bs)), false)


## 支架（三角托，画在板后面）
func _draw_fulcrum(bd: Dictionary) -> void:
	var cx: float = float(bd["cx"])
	var y: float = float(bd["y"])
	var w: float = _ball_r * 0.78
	var h: float = _ball_r * 1.18
	var pts := PackedVector2Array([
		Vector2(cx - w, y + 3.0), Vector2(cx + w, y + 3.0), Vector2(cx, y + h),
	])
	draw_colored_polygon(pts, COL_STAND)
	var ol := pts.duplicate()
	ol.append(pts[0])
	draw_polyline(ol, COL_WOOD_DARK, 3.0)


## 木板：绕板心（中心线中点）旋转；板体胶囊居中于中心线（碰撞与绘制一致），
## 球心恒在中心线上方 _ball_rad() 处、球底恰贴板面上表面
func _draw_plank(bd: Dictionary) -> void:
	var L: float = float(bd["L"])
	var th := _plank_th
	draw_set_transform(Vector2(float(bd["cx"]), float(bd["y"])), _ang, Vector2.ONE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_WOOD
	sb.set_corner_radius_all(th * 0.45)
	sb.set_border_width_all(3)
	sb.border_color = COL_WOOD_DARK
	sb.shadow_color = Color(0, 0, 0, 0.08)
	sb.shadow_size = 4
	sb.shadow_offset = Vector2(0, 3)
	draw_style_box(sb, Rect2(-L, -th * 0.5, L * 2.0, th))
	var sbh := StyleBoxFlat.new()
	sbh.bg_color = COL_WOOD_HI
	sbh.set_corner_radius_all(th * 0.22)
	draw_style_box(sbh, Rect2(-L * 0.90, -th * 0.5 + 3.0, L * 1.80, th * 0.26))
	draw_circle(Vector2.ZERO, th * 0.42, COL_WOOD_DARK)   # 中心轴钉
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 玻璃球：半透明球体 + 内部副水果（小，右上）+ 主水果（大，居中）+ 描边高光
func _draw_ball(b: Dictionary) -> void:
	var st := String(b["state"])
	var p := Vector2(float(b["x"]), float(b["y"]))
	var alpha := 1.0
	var scale := 1.0
	if st == "roll":
		var hop: float = float(b["hop"])
		if hop > 0.0 and int(b["bi"]) >= 0 and int(b["bi"]) < _boards.size():
			p += _board_normal() * sin(hop * PI) * _ball_r * 0.20   # 落板弹跳
	elif st == "sink":
		var t: float = float(b["t"])
		alpha = 1.0 - t
		scale = 1.0 - 0.25 * t
	else:
		scale = 0.4 + 0.6 * _ease_out_back(clampf(float(b["t"]), 0.0, 1.0))   # 生成弹出
	var R := _ball_r * scale
	if R < 2.0 or alpha <= 0.02:
		return
	# 球体：白底衬 + 淡青罩（浅色壁纸上也能显出球轮廓）
	draw_circle(p, R, Color(1, 1, 1, 0.34 * alpha))
	draw_circle(p, R, Color(COL_GLASS.r, COL_GLASS.g, COL_GLASS.b, 0.16 * alpha))
	# 内部水果：单个，居中（水果完全包在球内，碰撞主体是玻璃球）
	var tex_m: Texture2D = _fruit_texs.get(String(b["main"]))
	var sz_m := R * 0.9
	if tex_m != null:
		draw_texture_rect(tex_m, Rect2(p - Vector2(sz_m, sz_m) * 0.5, Vector2(sz_m, sz_m)),
				false, Color(1, 1, 1, alpha))
	# 玻璃描边（深棕实线，同合集描边风）+ 左上高光 + 底部反光
	draw_arc(p, R - 1.5, 0, TAU, 48, Color(COL_BORDER.r, COL_BORDER.g, COL_BORDER.b, 0.9 * alpha), 3.0)
	draw_arc(p, R * 0.74, PI * 1.08, PI * 1.52, 14, Color(1, 1, 1, 0.80 * alpha), 3.0)
	draw_arc(p, R * 0.80, PI * 0.15, PI * 0.55, 14, Color(1, 1, 1, 0.35 * alpha), 2.0)


func _draw_float(f: Dictionary) -> void:
	var t: float = float(f["t"])
	var font := ThemeDB.fallback_font
	var big := bool(f.get("big", false))
	# 大字（升级提醒）：随屏宽缩放、按面板中心对齐；普通分数字沿用原尺寸
	var fs: int = int(_vp.x * 0.034) if big else int(_ball_r * 1.35)
	var w: float = _vp.x * 0.9 if big else 160.0
	var p: Vector2 = f["pos"] + Vector2(-w * 0.5, -60.0 * t)
	var col: Color = f["col"]
	var a := 1.0 - t * t
	draw_string_outline(font, p, String(f["txt"]), HORIZONTAL_ALIGNMENT_CENTER,
			int(w), fs, 7, Color(0, 0, 0, 0.7 * a))
	draw_string(font, p, String(f["txt"]), HORIZONTAL_ALIGNMENT_CENTER,
			int(w), fs, Color(col.r, col.g, col.b, a))


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
	p.scale_amount_min = 3.0
	p.scale_amount_max = 7.0
	var g := Gradient.new()
	g.set_color(0, col)
	g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	p.color_ramp = g
	add_child(p)
	p.emitting = true
	var tw := create_tween()
	tw.tween_interval(1.3)
	tw.tween_callback(p.queue_free)


## 浮字：dur=生命周期秒（默认 0.9）；big=true 居中大字（升级提醒）
func _spawn_float(txt: String, col: Color, pos: Vector2, dur := 0.9, big := false) -> void:
	_floats.append({"txt": txt, "col": col, "pos": pos, "t": 0.0, "dur": dur, "big": big})


## ===== 贴图与音效 =====

func _load_textures() -> void:
	for kind: String in FRUITS_POOL:
		_fruit_texs[kind] = _load_png("assets/fruits/%s.png" % kind)


## pck 内 png 字节解码（不走导入流程）；双路径兼容编辑器直跑
func _load_png(rel: String) -> Texture2D:
	for base in ["res://games/fruit_sort/", "res://"]:
		var f := FileAccess.open(base + rel, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
			return null
	return null


## pck 内音频走字节解码，编辑器预览走导入资源（双路径）
func _init_sfx() -> void:
	var files := {"spawn": "slide.wav", "bounce": "flip.wav", "correct": "correct.wav",
			"wrong": "wrong.wav", "record": "win.wav"}
	for sname: String in files:
		for base in ["res://games/fruit_sort/assets/sfx/", "res://assets/sfx/"]:
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
		p.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜）音效仍可播
		add_child(p)
		_sfx_players.append(p)
	# BGM：复用合集 BGM（低音量循环，跟随 GameHud [audio] bgm_on）
	for base in ["res://games/fruit_sort/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
		var bf := FileAccess.open(base, FileAccess.READ)
		if bf != null:
			var st := AudioStreamMP3.load_from_buffer(bf.get_buffer(bf.get_length()))
			st.loop = true
			_bgm = AudioStreamPlayer.new()
			_bgm.stream = st
			_bgm.volume_db = BGM_DB
			_bgm.process_mode = Node.PROCESS_MODE_ALWAYS
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

## easeOutBack（生成弹出，轻微过冲）
func _ease_out_back(t: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	var k := clampf(t, 0.0, 1.0)
	return 1.0 + c3 * pow(k - 1.0, 3.0) + c1 * pow(k - 1.0, 2.0)
