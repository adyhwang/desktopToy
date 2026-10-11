extends Node2D
## 桌面破坏王：小狗道具——以屏幕中心为圆心沿阿基米德螺线行走，半径逐渐变大，走出边缘后消失
## 爪印通过 stamp_cb 回调给主脚本盖进痕迹画布（主脚本负责转画布坐标与限流）
## 生成位置即螺线起点（主脚本已设 position，_ready 时换算初始极坐标）

var frames: Array = []            # 4 帧行走贴图
var speed := 92.0                 # 切向线速度（px/s，1080 基准，主脚本按 _u 缩放）
var grow := 18.0                 # 半径增速（px/s，同基准）
var stamp_cb: Callable            # stamp_cb.call(爪印视口坐标)
var fps := 8.0

var _spr: Sprite2D
var _anim_t := 0.0
var _step_dist := 0.0             # 距上次爪印的累计路程
var _side := 1                    # 左右爪交替（垂直于行进方向偏移）
var _center := Vector2.ZERO       # 螺线圆心（屏幕中心）
var _ang := 0.0                   # 当前极角
var _rad := 60.0                  # 当前半径
var _max_r := 1200.0              # 超出此半径销毁（中心到最远角 + 余量）
var _spin := 1                    # 旋转方向（1 顺时针 / -1 逆时针，随机）
var _prev := Vector2.ZERO         # 上一帧位置（求速度方向）


func _ready() -> void:
	_center = get_viewport_rect().size * 0.5
	var off := position - _center
	if off.length() < 8.0:
		off = Vector2.from_angle(randf() * TAU) * 60.0
	_rad = off.length()
	_ang = off.angle()
	var vp := get_viewport_rect().size
	_max_r = Vector2(maxf(_center.x, vp.x - _center.x), maxf(_center.y, vp.y - _center.y)).length() + 60.0
	_prev = position
	_spin = 1 if randf() < 0.5 else -1
	_spr = Sprite2D.new()
	_spr.texture = frames[0]
	add_child(_spr)
	rotation = 0.04 * (1.0 if randf() < 0.5 else -1.0)   # 轻微歪头行走


func _process(delta: float) -> void:
	var spd := speed * scale.x
	# 角速度 = 切向线速 / 半径（线速恒定的螺线），半径持续外扩
	_ang += _spin * (spd / maxf(_rad, 24.0)) * delta
	_rad += grow * scale.x * delta
	position = _center + Vector2.from_angle(_ang) * _rad
	var vel := (position - _prev) / maxf(delta, 0.0001)
	_prev = position
	if absf(vel.x) > 1.0:
		_spr.flip_h = vel.x < 0            # 贴图默认朝右，向左走时镜像
	_step_dist += vel.length() * delta
	_anim_t += delta
	_spr.texture = frames[int(_anim_t * fps) % frames.size()]
	if _step_dist >= 22.0 * scale.x:
		_step_dist = fmod(_step_dist, 22.0 * scale.x)
		_side = -_side
		var vdir := vel.normalized() if vel.length() > 1.0 else Vector2.RIGHT
		var perp := Vector2(-vdir.y, vdir.x) * (9.0 * scale.x * _side)
		stamp_cb.call(position + perp + Vector2(randf_range(-3, 3), randf_range(-3, 3)) * scale.x)
	# 半径超出屏幕对角即走出边缘，销毁
	if _rad >= _max_r:
		queue_free()
