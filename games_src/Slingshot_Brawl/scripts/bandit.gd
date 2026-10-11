extends Node2D
## 劫匪单位：俯视角卡通形象 + 漫游 AI（随机路点、避墙避边界）
## 眩晕 / 减速 / 中毒与猫附着（持续伤害）/ 闪避冲刺 / 投掷手反击
## 生成、伤害结算、掉落与移除在主控 slingshot.gd；本脚本只管行为与绘制
## 素材：assets/bandits/<kind>.png（画布 128×128，身体中心=画布中心）存在时贴图绘制，缺失回退程序化

const Glyph := preload("res://scripts/glyphs.gd")

var game: Node2D             # 主控（提供路点 / 滑动碰撞 / 投掷请求）
var kind := "normal"         # normal / agile / thrower / armored
var hp := 3.0
var hp_max := 3.0
var speed := 55.0            # px/s（生成时已含波次难度倍率）
var score := 10
var radius := 30.0
var dodge := 0.0             # 子弹闪避概率 0~1
var armor := 0.0             # 伤害减免 0~1

# —— 状态 ——
var stun_t := 0.0            # 眩晕剩余（受击硬直 / 西红柿·苹果眩晕）
var slow_t := 0.0            # 减速剩余（蛋液 / 水渍踩中时由主控刷新）
var slow_mult := 1.0         # 当前减速倍率
var dot_acc := 0.0           # 持续伤害累计（毒雾），≥1 扣 1 血（无视护甲）
var dash_t := 0.0            # 闪避冲刺剩余
var dash_dir := Vector2.ZERO
var side: float = 1.0 if randf() < 0.5 else -1.0   # 绕障偏好侧（固定 ±1，防止左右交替摇摆）
var throw_cd := 0.0          # 投掷冷却（thrower）
var throw_wait := -1.0       # 投掷预警倒计时（>=0 原地瞄准中，头顶红色 !），结束后投掷
var spawn_t := 0.35          # 出生缩放动画剩余
var dead := false

var _dead_t := 0.0           # 死亡弹飞动画剩余（>0 播放中）
var _dead_v := Vector2.ZERO  # 死亡弹飞速度（含重力积分）
var _dead_spin := 0.0        # 死亡旋转速度

var _wp := Vector2.ZERO      # 当前漫游路点
var _wait := 0.0             # 路点间停顿
var _wp_age := 0.0           # 当前路点已追逐时长（超时强制换路，兜底防卡死/摇摆）
var _stuck_t := 0.0          # 卡死累计时长（有移动意图但挪不动，超阈值换路点）
var _wobble := 0.0           # 星星/浮动动画相位
var _face := -PI / 2.0       # 朝向角
var _spin := 0.0

# 外观（主控按 kind 设置）
var col_body := Color(0.33, 0.40, 0.58)
var col_hat := Color(0.52, 0.20, 0.16)


func _process(delta: float) -> void:
	_wobble += delta * 5.0
	_spin += delta * 9.0
	if dead:
		# 死亡弹飞：旋转 + 渐隐，动画结束后自行移除
		if _dead_t > 0.0:
			_dead_t -= delta
			position += _dead_v * delta
			_dead_v.y += 900.0 * delta
			rotation += _dead_spin * delta
			modulate.a = clampf(_dead_t / 0.75, 0.0, 1.0)
			if _dead_t <= 0.0:
				queue_free()
		return
	if spawn_t > 0.0:
		spawn_t = maxf(spawn_t - delta, 0.0)
		scale = Vector2.ONE * (1.0 - spawn_t / 0.35)
	# 计时器
	if stun_t > 0.0:
		stun_t -= delta
	if slow_t > 0.0:
		slow_t -= delta
		if slow_t <= 0.0:
			slow_mult = 1.0
	if dot_acc >= 1.0:
		var d := floori(dot_acc)
		dot_acc -= float(d)
		game.bandit_dot(self, int(d))
	# 闪避冲刺
	if dash_t > 0.0:
		dash_t -= delta
		_move(dash_dir * speed * 3.2 * delta)
		queue_redraw()
		return
	# 眩晕：原地发懵
	if stun_t > 0.0:
		queue_redraw()
		return
	# 投掷手反击：冷却结束先原地瞄准 2 秒（头顶红色 ! 预警），再投掷
	if kind == "thrower":
		if throw_wait >= 0.0:
			throw_wait -= delta
			if throw_wait <= 0.0:
				throw_wait = -1.0
				game.bandit_throw(self)
				throw_cd = randf_range(3.2, 5.0)
		else:
			throw_cd -= delta
			if throw_cd <= 0.0:
				throw_wait = 2.0
	# 瞄准中原地站桩（不漫游，给玩家预警反应窗口）
	if throw_wait >= 0.0:
		queue_redraw()
		return
	# 漫游
	if _wait > 0.0:
		_wait -= delta
	else:
		_wp_age += delta
		var step: Vector2 = (_wp - position)
		# 到点 / 追逐超时（被墙反复绕行摇摆时永远到不了）→ 换路点
		if step.length() < 10.0 or _wp_age > 3.0:
			_new_wp()
			_wp_age = 0.0
			_wait = randf_range(0.15, 0.85)
		else:
			var spd: float = speed * slow_mult
			var want: Vector2 = step.normalized() * spd * delta
			var before := position
			_move(want)
			# 卡死检测：有移动意图但几乎没挪动 → 换路点（修复被掩体卡住永久卡死）
			if position.distance_to(before) < want.length() * 0.3:
				_stuck_t += delta
				if _stuck_t > 0.45:
					_stuck_t = 0.0
					_new_wp()
					_wp_age = 0.0
			else:
				_stuck_t = 0.0
	queue_redraw()


func _move(step: Vector2) -> void:
	if step.length_squared() < 0.0001:
		return
	position = game.bandit_slide(self, position + step)
	_face = lerp_angle(_face, step.angle(), 1.0 - exp(-10.0 * get_process_delta_time()))


func _new_wp() -> void:
	_wp = game.roam_point(false, self)
	_wp_age = 0.0
	_stuck_t = 0.0


## 受击（主控调用）：armor 减免 / 硬直 / 击退 / 闪白 + 顿帧回调；返回是否死亡
## knock >= 0 时取 max(knock, 18 + dmg*8) 的默认击退（普通子弹不传也有小位移）；传 -1 表示无击退（持续伤/炮台黄蜂）
func take_damage(dmg: float, from_pos: Vector2, knock: float) -> bool:
	if dead:
		return false
	var eff: float = dmg * (1.0 - armor)
	hp -= eff
	stun_t = maxf(stun_t, 0.22)   # 受击硬直
	if knock >= 0.0:
		var push: Vector2 = (position - from_pos).normalized() * maxf(knock, 18.0 + dmg * 8.0)
		if push.length_squared() > 0.0001:
			position = game.bandit_slide(self, position + push)
	modulate = Color(2.6, 2.6, 2.6, modulate.a)
	var tw := create_tween()   # 只恢复 RGB，不碰 alpha（死亡渐隐独立控制）
	tw.tween_property(self, "modulate:r", 1.0, 0.20)
	tw.parallel().tween_property(self, "modulate:g", 1.0, 0.20)
	tw.parallel().tween_property(self, "modulate:b", 1.0, 0.20)
	if game.has_method("on_bandit_hit"):
		game.on_bandit_hit(hp <= 0.0)   # 顿帧：死亡长顿、普命短顿
	if hp <= 0.0:
		dead = true
		return true
	return false


## 死亡弹飞（主控结算分数/掉落后调用，替代立即移除）：沿击退方向旋转飞出，渐隐消失
func die_launch(dir: Vector2) -> void:
	_dead_t = 0.75
	_dead_v = dir * 260.0 + Vector2(0, -240.0)
	_dead_spin = (5.0 + randf() * 4.0) * (1.0 if randf() < 0.5 else -1.0)
	modulate = Color(1.0, 1.0, 1.0, modulate.a)   # 清白闪（RGB 归位，alpha 交由渐隐）


## 闪避冲刺（主控在子弹落点判定时调用）：向闪避方向快速横移，本次不受伤害
func do_dash(dir: Vector2) -> void:
	dash_dir = dir.normalized()
	if dash_dir.length_squared() > 0.0001:
		dash_t = 0.26


static var _body_tex := {}


## 本体绘制（身体/手/头/帽/眼/投掷石块）——运行时回退绘制与素材导出工具共用，保证 PNG 与程序化外观一致
static func draw_body(cv: CanvasItem, p_kind: String, r: float, body: Color, hat: Color, face: float, x_eye: bool) -> void:
	# 身体（朝向 face 的肩膀椭圆）
	cv.draw_set_transform(Vector2.ZERO, face, Vector2(1.15, 0.85))
	var bw := r * 1.12 if p_kind == "armored" else r * 1.0
	cv.draw_circle(Vector2.ZERO, bw, body)
	cv.draw_arc(Vector2.ZERO, bw, 0.0, TAU, 40, Color(0.10, 0.08, 0.07), r * 0.14, true)
	# 手（两侧）
	cv.draw_circle(Vector2(r * 0.05, -bw * 0.92), r * 0.24, Color(0.96, 0.80, 0.62))
	cv.draw_circle(Vector2(r * 0.05, bw * 0.92), r * 0.24, Color(0.96, 0.80, 0.62))
	cv.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 头（朝向前方偏移）
	var hc := Vector2.from_angle(face) * r * 0.30
	cv.draw_circle(hc, r * 0.62, Color(0.96, 0.80, 0.62))
	cv.draw_arc(hc, r * 0.62, 0.0, TAU, 32, Color(0.10, 0.08, 0.07), r * 0.12, true)
	# 帽子（盖住后脑，前方露出脸）
	cv.draw_circle(hc - Vector2.from_angle(face) * r * 0.14, r * 0.58, hat)
	cv.draw_arc(hc - Vector2.from_angle(face) * r * 0.14, r * 0.58, 0.0, TAU, 32, Color(0.10, 0.08, 0.07), r * 0.11, true)
	if p_kind == "armored":   # 金属盔铆钉
		for i in 3:
			var a: float = face + PI + (float(i) - 1.0) * 0.7
			cv.draw_circle(hc + Vector2.from_angle(a) * r * 0.38, r * 0.07, Color(0.30, 0.32, 0.36))
	# 眼睛
	var eye_c := hc + Vector2.from_angle(face) * r * 0.34
	var perp := Vector2.from_angle(face + PI / 2.0)
	if x_eye:   # 眩晕：X 眼
		for sgn in [-1.0, 1.0]:
			var e: Vector2 = eye_c + perp * sgn * r * 0.16
			cv.draw_line(e - Vector2(r * 0.07, r * 0.07), e + Vector2(r * 0.07, r * 0.07), Color(0.12, 0.10, 0.10), r * 0.06, true)
			cv.draw_line(e - Vector2(-r * 0.07, r * 0.07), e + Vector2(-r * 0.07, r * 0.07), Color(0.12, 0.10, 0.10), r * 0.06, true)
	else:
		for sgn in [-1.0, 1.0]:
			cv.draw_circle(eye_c + perp * sgn * r * 0.16, r * 0.08, Color(0.12, 0.10, 0.10))
	# 投掷手：手中石块
	if p_kind == "thrower":
		cv.draw_circle(Vector2(r * 0.05, bw * 0.92), r * 0.30, Color(0.52, 0.48, 0.44))
		cv.draw_arc(Vector2(r * 0.05, bw * 0.92), r * 0.30, 0.0, TAU, 20, Color(0.10, 0.08, 0.07), r * 0.08, true)


func _kind_tex() -> Texture2D:
	if not _body_tex.has(kind):
		_body_tex[kind] = Glyph.load_png("bandits/%s.png" % kind)
	return _body_tex[kind]


func _draw() -> void:
	var r := radius
	# 阴影（死亡弹飞时缩小，体现离地）
	var sh := 0.5 if dead else 1.0
	draw_set_transform(Vector2(0, r * 0.18), 0.0, Vector2(1.0, 0.55))
	draw_circle(Vector2.ZERO, r * 1.02 * sh, Color(0, 0, 0, 0.24))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 头位置（眩晕星星/感叹号等特效锚点，程序化与贴图两种模式通用）
	var hc := Vector2.from_angle(_face) * r * 0.30
	# 本体：素材优先（导出朝向为 -PI/2，运行时按 _face + PI/2 旋转对齐）；缺失回退程序化
	var tex := _kind_tex()
	if tex != null:
		var s := 3.2 * r   # 导出 r=40 / 画布 128 → 显示边长 128/40·r，与程序化视觉尺寸一致
		draw_set_transform(Vector2.ZERO, _face + PI / 2.0, Vector2.ONE)
		draw_texture_rect(tex, Rect2(Vector2(-0.5, -0.5) * s, Vector2(s, s)), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_body(self, kind, r, col_body, col_hat, _face, stun_t > 0.0)
	if dead:
		return   # 尸体只画本体，不带状态特效
	# 眩晕星星
	if stun_t > 0.0:
		for i in 3:
			var a: float = _wobble + float(i) * TAU / 3.0
			_star(hc + Vector2.from_angle(a) * Vector2(r * 0.95, r * 0.35) + Vector2(0, -r * 0.55), r * 0.16)
	# 投掷预警：红色 ! （原地瞄准中，脉冲跳动）
	if throw_wait >= 0.0:
		var bob: float = sin(_wobble * 7.0) * 3.0
		draw_string(ThemeDB.fallback_font, Vector2(r * 0.50, -r * 1.60 + bob), "!",
				HORIZONTAL_ALIGNMENT_LEFT, -1, int(r * 1.25), Color(0.95, 0.18, 0.12))
	# 血条（受伤后显示）
	if hp < hp_max - 0.01:
		var bw2: float = r * 1.7
		var by: float = -r * 1.55
		draw_rect(Rect2(-bw2 * 0.5, by, bw2, r * 0.16), Color(0, 0, 0, 0.55))
		var ratio: float = clampf(hp / hp_max, 0.0, 1.0)
		var col := Color(0.30, 0.80, 0.30) if ratio > 0.5 else (Color(0.95, 0.75, 0.20) if ratio > 0.25 else Color(0.92, 0.25, 0.20))
		draw_rect(Rect2(-bw2 * 0.5, by, bw2 * ratio, r * 0.16), col)


## 小四角星（眩晕）
func _star(p: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	for i in 8:
		var a: float = float(i) * TAU / 8.0 - PI / 2.0
		var rr: float = r if i % 2 == 0 else r * 0.40
		pts.append(p + Vector2.from_angle(a) * rr)
	var c := pts.duplicate()
	c.append(pts[0])
	draw_colored_polygon(pts, Color(1.0, 0.85, 0.25))
	draw_polyline(c, Color(0.35, 0.25, 0.05), 2.0, true)
