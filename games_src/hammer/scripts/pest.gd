extends Node2D
## 单只害虫：顶视贴图朝上（画布 96×96），运行时旋转朝向移动方向
## 轨迹规则（禁止长距离直线直奔水果中心）：
## 1. 生成时在水果周围随机取目标点，不全部指向正中心；
## 2. 前进方向叠加差异化的摆动/弧弯波形，路径自然弯曲；
## 3. 每 1~2 秒随机微调一次方向（试探行为），偏角随时间衰减回位；
## 4. 靠近水果区域（或绕过随机目标点）后切换为直奔水果正中心
## 差异化形态：蟑螂小幅折线最直 / 苍蝇飞一段抖一段交替最飘逸 / 蚊子 1 秒转圈+左右抖动逼近 / 老鼠大弧迂回+停顿冲刺
## 被击中未致死：击退 + 短暂眩晕 + 受击闪红缩放；致死：死亡帧展示后保持尸体（主场景按上限清理）
## 被吸尘器吸走：旋转缩小飞入吸点；抵达水果：缩小钻入水果消失

signal reached_fruit(pest)   # 抵达水果（污染成功）
signal died(pest)            # 被击杀（主场景计分/裂纹/音效）

const DEAD_SHOW := 0.45      # 死亡帧展示时长（s）
const DEAD_FADE := 0.30      # 死亡淡出时长（s）
const STUN_T := 0.30         # 受击眩晕时长（s）
const VANISH_T := 0.35       # 钻入水果消失时长（s）

const FINAL_NEAR := 1.6      # 距水果 < arrive_r × 此值 → 切换直奔阶段
const WP_NEAR := 1.2         # 距随机目标点 < radius × 此值 → 切换直奔阶段
const JITTER_ANG := {"roach": 0.35, "fly": 0.7, "mos": 0.5, "rat": 0.8}   # 试探偏角幅度（rad）
const JITTER_RECOVER := 1.6  # 试探偏角回位速度（rad/s）

var kind := "roach"
var value := 10
var hp := 1
var radius := 24.0
var speed := 60.0
var wobble_amp := 0.0        # 侧摆幅度（px）
var wobble_freq := 1.5       # 侧摆频率（Hz）
var fruit_pos := Vector2.ZERO
var arrive_r := 60.0         # 距水果小于此值判定污染
var walk_frames: Array = []  # 4 帧移动动画
var dead_frames: Array = []  # 3 帧死亡静态图
var fps := 8.0

var dying := false           # 死亡展示/钻入水果中（不可再被击中）
var charmed := false         # 被杀虫喷雾策反：追杀其他害虫，不污染水果
var charge_target: Node2D = null   # 策反追杀目标（失效自动换最近活虫）

var _dir := Vector2.DOWN
var _t := 0.0
var _phase := 0.0
var _anim_t := 0.0
var _frame := 0
var _stun := 0.0
var _vanish_k := -1.0        # >=0 钻入水果进度
var _flying := false         # 被吸尘器吸走：尸体朝吸点飞入
var _fly_pos := Vector2.ZERO
var _base_scale := Vector2.ONE
var _spr: Sprite2D

# 轨迹状态
var _wp := Vector2.ZERO      # 随机目标点（水果周围一圈，不全部指向正中心）
var _final := false          # 已进入直奔水果阶段
var _spiral_sign := 1.0      # 蚊子螺旋方向（±1，生成时随机）
var _jitter_t := 0.0         # 下次试探微调倒计时（s）
var _jitter_ang := 0.0       # 当前试探偏角（rad，随时间衰减回位）
var _pause_t := 0.0          # 老鼠停顿剩余（s）
var _dash_t := 0.0           # 老鼠冲刺剩余（s）
var _act_t := 0.0            # 老鼠下次停顿/冲刺判定倒计时（s）
var _fly_t := 0.0            # 苍蝇抖动/平稳段剩余（s）
var _fly_wob := true         # 苍蝇当前是否抖动段（飞一段抖一段交替）


func _ready() -> void:
	_spr = Sprite2D.new()
	_spr.texture = walk_frames[0] if not walk_frames.is_empty() else null
	add_child(_spr)
	_phase = randf() * TAU
	_spiral_sign = 1.0 if randf() < 0.5 else -1.0
	_act_t = randf_range(1.2, 2.4)
	_pick_waypoint()
	apply_radius()


## 随机目标点：水果周围一圈随机方位与距离（不全部指向正中心）
func _pick_waypoint() -> void:
	_wp = fruit_pos + Vector2.from_angle(randf() * TAU) * arrive_r * randf_range(0.7, 2.0)


## 半径 → 贴图缩放（窗口尺寸变化时重新套用）
func apply_radius() -> void:
	_base_scale = Vector2.ONE * (radius * 2.0 / 96.0)
	if _vanish_k < 0.0:
		scale = _base_scale


## 挥锤命中：返回是否致死（未致死做击退+眩晕+闪红；死亡/钻入中不可再命中）
## dmg 为本次伤害（大号铁锤传大值秒杀任何害虫）
func hit(dmg: int = 1) -> bool:
	if dying:
		return false
	hp -= dmg
	if hp <= 0:
		dying = true
		rotation += randf_range(-0.4, 0.4)   # 倒地姿态随机歪一点
		if not dead_frames.is_empty():
			_spr.texture = dead_frames[randi() % dead_frames.size()]
		_t = 0.0
		died.emit(self)
		return true
	_stun = STUN_T
	position -= _dir * radius * 0.9   # 击退（远离水果方向）
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1.0, 0.4, 0.4), 0.06)
	tw.tween_property(self, "modulate", Color(0.62, 1.0, 0.62) if charmed else Color.WHITE, 0.25)
	var tp := create_tween()
	tp.tween_property(self, "scale", _base_scale * 1.18, 0.05)
	tp.tween_property(self, "scale", _base_scale, 0.15)
	return false


## 被杀虫喷雾策反：调转枪口追杀其他害虫（绿色标记；目标失效自动换最近活虫）
func charm(target: Node2D) -> void:
	if dying:
		return
	charmed = true
	charge_target = target
	_stun = 0.0
	modulate = Color(0.62, 1.0, 0.62)


## 被策反虫/机器猫捕食致死：走正常死亡流程（died 信号 → 主场景计分）
func slain_by_charm() -> void:
	if dying:
		return
	dying = true
	rotation += randf_range(-0.4, 0.4)
	if not dead_frames.is_empty():
		_spr.texture = dead_frames[randi() % dead_frames.size()]
	_t = 0.0
	died.emit(self)


## 策反虫撞上目标：与目标同归于尽，自身自爆不计分
func destruct() -> void:
	if dying:
		return
	dying = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", _base_scale * 1.35, 0.10)
	tw.tween_property(self, "modulate:a", 0.0, 0.12)
	tw.chain().tween_callback(queue_free)


## 被吸尘器吸走：正常计分死亡，尸体朝吸点飞入消失
func vacuumed_to(pos: Vector2) -> void:
	if dying:
		return
	dying = true
	died.emit(self)
	_fly_pos = pos
	_flying = true


## 是否留下尸体（钻入水果 / 被吸走的不留）
func leaves_corpse() -> bool:
	return not _flying and _vanish_k < 0.0


## 尸体清理：淡出后自毁（主场景超 CORPSE_MAX 上限时移除最旧尸体）
func fade_corpse() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.4)
	tw.tween_callback(queue_free)


func _process(delta: float) -> void:
	if dying:
		if _flying:
			# 吸尘器吸入：旋转缩小飞入吸点
			position = position.lerp(_fly_pos, minf(delta * 12.0, 1.0))
			rotation += delta * 22.0
			scale = scale * maxf(1.0 - delta * 6.0, 0.05)
			modulate.a = maxf(modulate.a - delta * 5.0, 0.0)
			if modulate.a <= 0.02:
				queue_free()
		elif _vanish_k >= 0.0:
			# 钻入水果：缩小淡出
			_vanish_k += delta / VANISH_T
			var k: float = clampf(_vanish_k, 0.0, 1.0)
			scale = _base_scale * (1.0 - k * 0.8)
			modulate.a = 1.0 - k
			if k >= 1.0:
				queue_free()
		else:
			# 死亡帧展示后保持尸体不清理（主场景按 CORPSE_MAX 上限调 fade_corpse 移除最旧）
			pass
		return
	_t += delta
	if _stun > 0.0:
		_stun -= delta
		return
	# 行走动画帧循环
	_anim_t += delta * fps
	if _anim_t >= 1.0 and walk_frames.size() > 0:
		_anim_t = fmod(_anim_t, 1.0)
		_frame = (_frame + 1) % walk_frames.size()
		_spr.texture = walk_frames[_frame]
	if charmed:
		_charm_move(delta)
		return
	# 阶段切换：靠近水果区域（或绕过随机目标点）→ 直奔水果正中心
	if not _final and (position.distance_to(fruit_pos) <= arrive_r * FINAL_NEAR
			or position.distance_to(_wp) <= radius * WP_NEAR):
		_final = true
	var tgt := fruit_pos if _final else _wp
	var base := (tgt - position).normalized()
	if base == Vector2.ZERO:
		base = Vector2.DOWN
	var side := base.orthogonal()
	var vel := base * speed
	# 差异化轨迹形态（禁止长距离直线直奔）
	match kind:
		"roach":
			# 小幅左右摆动的折线爬行（路径相对最直）
			vel += side * cos(_t * TAU * wobble_freq + _phase) * wobble_amp * TAU * wobble_freq
		"fly":
			# 高频不规则 S 形波浪：飞一段抖一段交替（抖动频繁，轨迹最飘逸）
			_fly_t -= delta
			if _fly_t <= 0.0:
				_fly_wob = not _fly_wob
				_fly_t = randf_range(0.7, 1.4) if _fly_wob else randf_range(0.5, 1.0)
			if _fly_wob:
				vel += side * (cos(_t * TAU * wobble_freq + _phase) * 0.7
						+ cos(_t * TAU * wobble_freq * 2.71 + _phase * 1.7) * 0.3) \
						* wobble_amp * TAU * wobble_freq
		"mos":
			# 1 秒转一圈快速转圈前进（摆线轨迹：旋转分量 + 向心推进分量），叠加左右抖动靠近中心
			var wobble_ang := 0.4 * sin(_t * 9.0 + _phase)   # 高频左右抖动
			vel = (base.rotated(_spiral_sign * _t * TAU + wobble_ang) * 0.8 + base * 0.3) * speed
		"rat":
			# 大弧度迂回折线跑动，偶有停顿冲刺，刻意偏离正中路径
			vel += side * cos(_t * TAU * wobble_freq + _phase) * wobble_amp * TAU * wobble_freq
			if _pause_t > 0.0:
				_pause_t -= delta
				vel *= 0.12              # 停顿
			elif _dash_t > 0.0:
				_dash_t -= delta
				vel *= 1.5               # 冲刺
			else:
				_act_t -= delta
				if _act_t <= 0.0:
					if randf() < 0.45:
						_pause_t = randf_range(0.35, 0.7)
					else:
						_dash_t = randf_range(0.4, 0.8)
					_act_t = randf_range(1.2, 2.4)
	# 试探行为：每 1~2 秒随机微调一次前进方向，偏角随时间衰减回位
	_jitter_t -= delta
	if _jitter_t <= 0.0:
		_jitter_t = randf_range(1.0, 2.0)
		_jitter_ang = randf_range(-1.0, 1.0) * JITTER_ANG.get(kind, 0.5)
	_jitter_ang = move_toward(_jitter_ang, 0.0, JITTER_RECOVER * delta)
	vel = vel.rotated(_jitter_ang)
	position += vel * delta
	_dir = vel.normalized()
	rotation = _dir.angle() + PI / 2.0
	# 抵达水果
	if position.distance_to(fruit_pos) <= arrive_r:
		dying = true            # 与死亡共用"不可再击中"标记
		_vanish_k = 0.0
		reached_fruit.emit(self)


## 策反移动：全速（×1.6）追杀最近害虫，撞上即同归于尽；无目标绕水果盘旋待命
func _charm_move(delta: float) -> void:
	if charge_target == null or not is_instance_valid(charge_target) or charge_target.dying:
		charge_target = _find_nearest_pest()
	var dir: Vector2
	var spd := speed * 1.6
	if charge_target != null:
		dir = (charge_target.position - position).normalized()
		if position.distance_to(charge_target.position) <= radius * 0.8 + charge_target.radius:
			charge_target.slain_by_charm()   # 目标正常计分死亡
			destruct()                        # 自身自爆无分
			return
	else:
		var orbit := fruit_pos + Vector2.from_angle(_t * 1.5 + _phase) * radius * 3.0
		dir = (orbit - position).normalized()
		spd = speed * 0.8
	position += dir * spd * delta
	rotation = dir.angle() + PI / 2.0


## 最近的未策反活害虫（排除自己，防策反内战）
func _find_nearest_pest() -> Node2D:
	var best: Node2D = null
	var bd := INF
	for q in get_parent().get_children():
		if q == self or q.dying or q.charmed:
			continue
		var d: float = position.distance_to(q.position)
		if d < bd:
			bd = d
			best = q
	return best
