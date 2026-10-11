extends Node2D
## 跳楼人物：状态机 PREP（阳台停留 0.5s）→ FLY（抛物线俯冲）→ AIR（气垫弹跳空中段）
## → LIE（气垫上躺 0.8s 轻微左右摆，主控驱动摆位）→ HOP（跳下气垫）→ WALK（跑回入口）→ QUEUE（站队尾）
## SPLAT（落地没接住）：主控负责落气垫/落地判定与弹跳参数（高度=上次下落最高点÷2），本节点负责积分与绘制
## 素材：dive=俯冲（头朝右，rot=0 基准）/ safe=抱头与躺卧 / stand=站立排队 / walk=行走（面朝左）；素材缺失时程序简笔兜底

enum St { PREP, FLY, AIR, LIE, HOP, WALK, QUEUE, ARRIVE, SPLAT, DONE }

const ROT_GAIN := 0.45       # 姿态前倾角 = atan2(vy, |vx|) × 此值（俯冲→头随速度下扎，弹起→微微上仰）
const SPIN_TUMBLE := 2.6     # SPLAT 翻滚角速度（rad/s）
const WALK_BOB_FREQ := 11.0  # 行走上下颠簸频率
const WALK_BOB_AMP := 2.5    # 行走颠簸幅度（px）
const PREP_T := 0.5          # 阳台停留时长（s），跳出前站位观察
const LIE_T := 0.8           # 气垫躺卧时长（s）
const STANDUP_T := 0.5       # 起身时长（s）：躺姿原地慢慢站起，不移动不跳动
const DRAW_DIVE := 1.15      # 俯冲贴图显示边长 = 身高 × 此值（与站立/排队人物同大小）
const DRAW_SAFE := 1.15      # 抱头/躺/行走贴图显示边长 = 身高 × 此值
const STAND_FOOT_PH := 0.372 # 站立时脚底相对贴图中心的偏移 / 人高（贴图内容脚位 41.4px × 1.15/128）

var st: int = St.PREP
var v := Vector2.ZERO
var g := 162.0               # 重力（主控传入）
var prev_y := 0.0            # 上一次积分前的中心 y（主控气垫平面穿越判定用）
var ph := 30.0               # 身高（主控传入）
var rp := 14.0               # 碰撞半径（主控传入）
var rot := 0.0
var st_t := 0.0              # 当前状态计时
var apex_y := 0.0            # 本次空中段最高点 y（首跳触垫时据此锁定初始落差）
var bounces_done := 0        # 已完成弹跳次数（主控累加）
var fall0_h := 0.0           # 首次触垫时锁定的初始落差（垫顶→起跳最高点，主控写）：弹跳高度均分基准
var bounce_total := 1        # 本关需弹跳次数 n（HUD 剩余提示用，主控传入）
var walk_target_x := 0.0     # 跑回目标（队尾位置，主控每帧更新）
var walk_speed := 420.0
var hold_launch := false     # 阳台预备放行开关（主控设：空中/垫上有人时暂不跳出）
var enter_mode := false      # 进楼模式：WALK 走向大楼门口，到达即 DONE（主控回收）
var walk_paused := false     # 地面行走互斥：进楼/入队进行中时其他走动者暂停
var queued_at := -1.0        # 归队时间戳（主控打戳）：队列槽位按此排序，先归队站前面
var lie_y := 0.0             # 获救躺卧锚点 y（接触点，躺卧/起身全程固定）
var lie_rot := 0.0           # 躺姿角度（起身插值起点）
var ground_y := 900.0
var min_x := 0.0             # 空中横移边界（楼右缘～屏右）
var max_x := 1900.0
var tex_dive: Texture2D
var tex_dive_frames: Array = []   # 空中挥舞动画帧（主控加载传入；空则退化为 tex_dive 静帧）
const DIVE_FPS := 10.0            # 挥舞帧率（6 帧循环 ≈0.6s/圈）
var tex_safe: Texture2D
var tex_stand: Texture2D
var tex_walk: Texture2D
var _pp := [0.0, 0.0]        # PREP 结束后跳出的初速 (vx, vy0)
var _fade_tween: Tween


## 阳台预备：站立停留 PREP_T 秒后按预存初速跳出
func prep_ledge(x0: float, y0: float, vx: float, vy0: float) -> void:
	position = Vector2(x0, y0)
	_pp = [vx, vy0]
	st = St.PREP
	st_t = 0.0
	rot = 0.0
	queue_redraw()


## 跃出阳台（PREP 计时到自动调用 / 主控直接调用）：位置 = 阳台落脚点上方
func launch(x0: float, y0: float, vx: float, vy0: float) -> void:
	position = Vector2(x0, y0)
	v = Vector2(vx, vy0)
	prev_y = y0
	apex_y = y0
	st = St.FLY
	queue_redraw()


## 落气垫弹跳（第 k 次弹跳）：主控按 上次下落最高点÷2 反解 vy_up 传入
func bounce(vy_up: float, vx_new: float) -> void:
	v = Vector2(vx_new, vy_up)
	st = St.AIR
	rot = -0.35   # 弹起瞬间微微上仰，下一帧起随速度恢复
	apex_y = position.y
	queue_redraw()


## 平稳落气垫：躺卧位由主控每帧贴垫（x=垫中间、y 沉入垫内）→ 躺满后原地起身
func land_safe() -> void:
	st = St.LIE
	st_t = 0.0
	rot = PI / 2.0
	lie_y = position.y    # 起身插值锚点：躺末位置（转 HOP 时刷新为最终躺位）
	lie_rot = rot
	scale = Vector2.ONE
	queue_redraw()


## 落地没接住：瘫地翻滚淡出
func splat() -> void:
	st = St.SPLAT
	st_t = 0.0
	if _fade_tween != null:
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_interval(0.55)
	_fade_tween.tween_property(self, "modulate:a", 0.0, 0.6)
	_fade_tween.tween_callback(func() -> void: st = St.DONE)


func _process(delta: float) -> void:
	st_t += delta
	match st:
		St.PREP:
			# 停留 PREP_T 后放行跳出；前一人还在空中/垫上时主控 hold（新人已站上阳台）
			if st_t >= PREP_T and not hold_launch:
				launch(position.x, position.y, _pp[0], _pp[1])
		St.FLY, St.AIR:
			prev_y = position.y
			v = Vector2(v.x, v.y + g * delta)
			position += v * delta
			apex_y = minf(apex_y, position.y)
			# 横移边界（右屏边/楼右缘）：反弹回
			if position.x < min_x:
				position.x = min_x
				v.x = absf(v.x) * 0.5
			elif position.x > max_x:
				position.x = max_x
				v.x = -absf(v.x) * 0.5
			rot = atan2(v.y, maxf(absf(v.x), 40.0)) * ROT_GAIN
		St.HOP:
			# 起身（躺→站插值）：原地慢慢站起来，位置固定在获救接触点
			var k: float = minf(st_t / STANDUP_T, 1.0)
			rot = lie_rot * (1.0 - k)
			position.y = lie_y + ((ground_y - ph * STAND_FOOT_PH) - lie_y) * k
			if k >= 1.0:
				st = St.WALK
				st_t = 0.0
		St.LIE:
			# 躺位由主控每帧贴气垫（x=垫中间、y 沉入垫内）；躺满锁存最终躺位，转入原地起身
			if st_t >= LIE_T:
				lie_y = position.y
				st = St.HOP
				st_t = 0.0
		St.WALK:
			# 跑向目标（双向：获救者补位到队尾 / 进楼者走向大楼门口）；地面互斥时暂停
			if not walk_paused:
				position.x = move_toward(position.x, walk_target_x, walk_speed * delta)
				if absf(position.x - walk_target_x) < 1.0:
					if enter_mode:
						st = St.DONE   # 进楼完成，主控回收
					else:
						st = St.QUEUE
						st_t = 0.0
		St.ARRIVE:
			# 新人从画面右边缘走入，横向走到排队站位（地面互斥由主控保证同一时刻唯一）
			position.x = move_toward(position.x, walk_target_x, walk_speed * delta)
			if position.x <= walk_target_x + 1.0:
				st = St.QUEUE
				st_t = 0.0
		St.QUEUE:
			pass   # 站队尾（bob 呼吸在 _draw），直到被主控回收（队首进楼）
		St.SPLAT:
			rot = minf(rot + SPIN_TUMBLE * delta, PI / 2.0)
			position.y = minf(position.y + 40.0 * delta, ground_y - rp * 0.4)
		St.DONE:
			pass
	queue_redraw()


func _draw() -> void:
	var tex: Texture2D = null
	var draw_sz := ph * DRAW_DIVE
	var gray := Color(1, 1, 1)
	match st:
		St.PREP, St.QUEUE:
			tex = tex_stand
			draw_sz = ph * DRAW_SAFE
		St.FLY, St.AIR:
			if not tex_dive_frames.is_empty():
				tex = tex_dive_frames[int(st_t * DIVE_FPS) % tex_dive_frames.size()]   # 手脚不断挥舞
			else:
				tex = tex_dive
			draw_sz = ph * DRAW_DIVE
		St.LIE, St.HOP:
			tex = tex_safe
			draw_sz = ph * DRAW_SAFE
		St.WALK, St.ARRIVE:
			tex = tex_walk if st == St.WALK else tex_stand
			draw_sz = ph * DRAW_SAFE
		St.SPLAT:
			tex = tex_safe
			draw_sz = ph * DRAW_SAFE
			gray = Color(0.6, 0.55, 0.5)
		St.DONE:
			return
	if tex != null:
		var s := draw_sz / float(tex.get_width())
		var bob := 0.0
		if st == St.WALK or st == St.ARRIVE:
			bob = absf(sin(st_t * WALK_BOB_FREQ)) * WALK_BOB_AMP * -1.0
		elif st == St.QUEUE:
			bob = absf(sin(st_t * 2.2)) * 1.2 * -1.0   # 站队呼吸微动
		draw_set_transform(Vector2(0, bob), rot, Vector2(s, s))
		draw_texture(tex, Vector2(-tex.get_width() * 0.5, -tex.get_height() * 0.5), gray)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		# 兜底：简笔小人（圆头 + 躯干）
		draw_circle(Vector2.ZERO, rp, Color(0.94, 0.83, 0.25))
		draw_line(Vector2.ZERO, Vector2(0, ph * 0.5), Color(0.94, 0.83, 0.25), rp)
