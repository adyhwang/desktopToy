extends Node2D
## 空中水果道具：节点原点 = 物品中心；主控 spawn() 注入初速度，本节点每帧积分（重力+旋转+透视缩放）
## 接住判定与表现由主控调用方法；素材为扁平卡通水果 PNG（512 透明底，双路径字节解码）
## 接住后引导下沉：限速继续下落，被篮子前景层（前壁贴图）真实遮挡，沉够深度后淡出

const SPIN_GAIN := 0.5     # 水平速度 → 自转角速度系数（风格同扔垃圾）
const SPIN_MIN := 2.5      # 基础自转（rad/s），方向随水平速度
const PERSP_NEAR := 0.9    # 透视缩放下限（出手时小，接近落点放大到 1.0）

var good := true           # true=加分物（好水果/金果），false=扣分物（坏水果/炸弹）
var bonus := 1             # 接住计分值：好 +1 / 坏 −1 / 金 +3 / 炸弹 −3（主控生成时传入）
var target_x := 0.0        # 出生抛物线的落点 x（主控画预警阴影用）
var start_y := 0.0         # 出生 y（阴影渐进透明度用）
var item_name := ""        # 素材文件名（不含扩展名，主控按清单随机传入）
var radius := 24.0         # 物品半径（主控 _layout 统一传入，归一化显示大小）
var g := 0.0               # 重力加速度（主控按屏高计算传入）
var flight_t := 2.0        # 本次飞行时长参考 T（透视缩放进度 + 看门狗用）
var ground_y := 0.0        # 地面线 y（主控传入）
var v := Vector2.ZERO      # 当前速度
var prev_y := 0.0          # 上一次积分前的 y（主控篮口平面穿越判定用）
var air_t := 0.0           # 已飞行时长（主控看门狗用）
var done := false          # 已接住/已落地/淡出中，主控跳过判定
var sinking := false       # 已接住、引导下沉中（限速下落 + 前景层遮挡）
var catch_rel_x := 0.0     # 接住瞬间相对篮子中心的水平偏移（主控传入，下沉期间跟随篮子）
var rim_hit := false       # 本次飞行已碰篮沿（只弹一次）
var wall_hit := false      # 本次飞行已碰篮壁（只弹一次）
var scored := false        # 计分锁：接住或落地只计一次（弹飞后二次穿越篮口不得重复计分）
var fade_time := 0.25      # 淡出时长（主控接住下沉到位后按 CATCH_FADE_TIME 传入；落地用默认值）
var _tex: Texture2D
var _fade_tween: Tween


func spawn(vx: float, vy0: float, x0: float, y0: float) -> void:
	v = Vector2(vx, vy0)
	position = Vector2(x0, y0)
	prev_y = y0
	start_y = y0
	air_t = 0.0
	_load_tex()
	queue_redraw()


## 被接住：停转、缩放冻结，限速继续下落入篮（前景层前壁真实遮挡）
func catch_sink() -> void:
	done = true
	sinking = true
	rotation = 0.0          # 轴对齐入篮
	scale = Vector2.ONE
	# 沉降限速：入篮口时 vy 可达 25r/s 以上，1.5r 下沉仅约 3 帧，下沉过程看不清
	v = Vector2(v.x * 0.25, minf(v.y, radius * 3.0))


## 下沉到位：主控调用，淡出并释放
func fade_out() -> void:
	if done and not sinking:
		return   # 已在淡出中（落地路径重复触发兜底）
	done = true
	sinking = false
	if _fade_tween != null:
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 0.0, fade_time)
	_fade_tween.tween_callback(queue_free)


func _process(delta: float) -> void:
	if done and not sinking:
		return
	air_t += delta
	v = Vector2(v.x, v.y + g * delta)
	prev_y = position.y
	if sinking:
		position.y += v.y * delta   # 下沉：水平不自行积分，由主控跟随篮子（catch_rel_x）
	else:
		position += v * delta
	# 飞行旋转与透视缩放：下沉中全部冻结（rotation=0、scale=ONE 已在 catch_sink 固定）
	if not sinking:
		var omega := v.x / maxf(radius, 1.0) * SPIN_GAIN
		if absf(omega) < SPIN_MIN:
			omega = SPIN_MIN if v.x >= 0.0 else -SPIN_MIN
		rotation += omega * delta
		var p := clampf(air_t / maxf(flight_t, 0.01), 0.0, 1.0)
		scale = Vector2.ONE * lerpf(PERSP_NEAR, 1.0, p)


func _load_tex() -> void:
	# 原始 png 字节解码（pck 内未走导入流程）；第二条路径供编辑器直接打开本工程预览
	for base in ["res://games/basket/assets/fruits/", "res://assets/fruits/"]:
		var path: String = base + item_name + ".png"
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				_tex = ImageTexture.create_from_image(img)
			break


func _draw() -> void:
	if _tex != null:
		# 素材已按内容包围盒归一化（最宽边 ≈ 画布 92%），按画布宽映射到 2r
		var s := radius * 2.0 / _tex.get_width() / 0.92
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		draw_texture(_tex, Vector2(-_tex.get_width() * 0.5, -_tex.get_height() * 0.5))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化灰圆（素材缺失时）
	draw_circle(Vector2.ZERO, radius, Color(0.85, 0.83, 0.78))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(0.35, 0.3, 0.25), 2.0)
