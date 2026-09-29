extends Node2D
## 机器猫道具实体：自动追杀最近的害虫并吃掉（走 died 信号正常计分）
## 速度 = 老鼠 ×2；吃一只冷却 0.5s；不吃已被策反的友军害虫
## 无虫可吃时绕水果盘旋待命；存活 10s，末 2 秒闪烁后淡出

const LIFE_T := 10.0         # 存活时长（s）
const EAT_CD := 0.5          # 吃掉一只后的冷却（s）
const VANISH_T := 0.5        # 淡出时长（s）

var radius := 36.0
var speed := 320.0           # px/s@1080p 基准（老鼠 160 × 2，主场景已乘 _u）
var fruit_pos := Vector2.ZERO
var pests_root: Node2D       # 害虫容器（跨容器找目标）
var walk_frames: Array = []
var fps := 10.0

var _t := 0.0
var _anim_t := 0.0
var _frame := 0
var _cd := 0.0
var _life := LIFE_T
var _base_scale := Vector2.ONE
var _spr: Sprite2D


func _ready() -> void:
	_spr = Sprite2D.new()
	_spr.texture = walk_frames[0] if not walk_frames.is_empty() else null
	add_child(_spr)
	apply_radius()
	scale = Vector2.ONE * 0.1
	var tw := create_tween()   # 出场弹出
	tw.tween_property(self, "scale", _base_scale, 0.25) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## 半径 → 贴图缩放（窗口尺寸变化时重新套用）
func apply_radius() -> void:
	_base_scale = Vector2.ONE * (radius * 2.0 / 96.0)
	scale = _base_scale


func _process(delta: float) -> void:
	_t += delta
	_life -= delta
	if _life <= 0.0:
		set_process(false)
		var tw := create_tween()
		tw.tween_property(self, "modulate:a", 0.0, VANISH_T)
		tw.chain().tween_callback(queue_free)
		return
	if _life < 2.0:
		modulate.a = 0.45 + 0.55 * (0.5 + 0.5 * sin(_t * 12.0))   # 末 2 秒闪烁预告消失
	# 行走动画帧循环
	_anim_t += delta * fps
	if _anim_t >= 1.0 and not walk_frames.is_empty():
		_anim_t = fmod(_anim_t, 1.0)
		_frame = (_frame + 1) % walk_frames.size()
		_spr.texture = walk_frames[_frame]
	_cd = maxf(_cd - delta, 0.0)
	# 最近活害虫（跳过策反友军与尸体）
	var target: Node2D = null
	var bd := INF
	if pests_root != null:
		for q in pests_root.get_children():
			if q.dying or q.charmed:
				continue
			var d: float = position.distance_to(q.position)
			if d < bd:
				bd = d
				target = q
	var dir: Vector2
	if target != null:
		dir = (target.position - position).normalized()
		if _cd <= 0.0 and bd <= radius * 0.7 + target.radius:
			target.slain_by_charm()   # 吃掉：正常计分死亡
			_cd = EAT_CD
			var tw := create_tween()  # 嚼一口
			tw.tween_property(_spr, "scale", Vector2(1.15, 0.85), 0.08)
			tw.tween_property(_spr, "scale", Vector2.ONE, 0.10)
	else:
		var orbit := fruit_pos + Vector2.from_angle(_t * 1.2) * radius * 3.5
		dir = (orbit - position).normalized()
	position += dir * speed * delta
	rotation = dir.angle() + PI / 2.0
