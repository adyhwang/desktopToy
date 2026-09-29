extends Node2D
## 篮筐双层（back=透明背板+红托架 / front=橙筐圈+白网），同一脚本两实例，主控按层注入贴图与标识
## front 层原点 = 筐口平面中心（判定线）；back 层原点 = 背板底缘中心（主控按 BACK_GAP_RATIO 抬升布置）
## 位置由主控统一驱动（难度移动两层同步），晃动作用于独立偏移（两层由主控同步 shake）；
## front 层支持网飘动（绕原点小幅旋转）；素材缺失时程序化兜底
## 锚点/筐宽/背板比例按用户素材（hoop_front 512×693 / hoop_back 512×683）实测

const RIM_W_RATIO := 0.5566                      # 筐圈外沿宽 / 贴图宽（front 512×693 橙圈最宽行 x[108,393]→285/512；back 同宽画布共用）
const RIM_CENTER_FRONT := Vector2(0.489, 0.534)  # front：筐口平面中心（橙圈椭圆 y[342,399] 中线 370/693）
const RIM_CENTER_BACK := Vector2(0.498, 0.6428)  # back：背板底缘中心（512×683 主体 bbox x[11,499] 底 439）
const BACK_GAP_RATIO := -0.242                   # 背板底缘中心到筐口平面的距离 = 筐圈外沿宽 × 此值（负=低于筐口平面；两图同宽 512，像素直接可比：(370−439)/285）
# 背板碰撞区（back 图主体 bbox 相对背板底缘中心，比例 × 贴图宽/高）
const BACK_RECT_OFF := Vector2(-0.4766, -0.5651) # 左上角 (11-255)/512, (53-439)/683
const BACK_RECT_SIZE := Vector2(0.9531, 0.5651)  # (499-11)/512, (439-53)/683
const SHAKE_AMPS := [-2.5, 2.0, -1.0, 0.5, 0.0]  # 进球筐体晃动振幅序列（px，逐次衰减；原 [-7,6,-4,2,0] 减半）

var tex_paths: Array = ["res://games/basketball/assets/hoop_front.png", "res://assets/hoop_front.png"]:  # 主控按层配置
	set(v):
		if v == tex_paths:
			return   # _layout 每次窗口变化都会重赋值，内容相同不重复解码
		tex_paths = v
		_load_tex()
var is_back := false       # 层标识：true=背板层（board_rect/兜底背板），false=筐网层（网飘动）
var half_width := 0.0      # 筐口判定半宽（世界坐标，主控传入；两层同值 → 同缩放）
var net_len := 0.0         # 网长（世界坐标，出网判定/兜底绘制用，仅 front 层）
var base_position := Vector2.ZERO  # 层锚点（front=筐口平面；back=背板底缘中心）
var net_swing := 0.1       # 网飘动系数 -1~1（映射为小幅旋转，仅 front 层）
var _tex: Texture2D
var _shake_off := Vector2.ZERO     # 晃动偏移（Tween 驱动，_process 只读应用）
var _shake_tween: Tween
var _swing_tween: Tween


func _ready() -> void:
	_load_tex()   # 默认路径先加载一次；主控 _layout 配置 tex_paths 时由 setter 重新加载


## 按 tex_paths 双路径加载贴图（pck 内未走导入流程，字节解码；末条供编辑器直接打开本工程预览）
func _load_tex() -> void:
	for p in tex_paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				_tex = ImageTexture.create_from_image(img)
			break
	queue_redraw()


func apply_base() -> void:
	position = base_position + _shake_off


## 进球筐体晃动（0.3s 位移抖动，作用于偏移量；主控两层同步调用）
func shake() -> void:
	if _shake_tween != null:
		_shake_tween.kill()
	_shake_off = Vector2.ZERO
	_shake_tween = create_tween()
	for dx in SHAKE_AMPS:
		_shake_tween.tween_property(self, "_shake_off:x", dx, 0.06)


func _process(_delta: float) -> void:
	# 仅应用晃动偏移（位置由主控统一驱动，与筐判定严格同帧）
	position = base_position + _shake_off


## 进球篮网飘动（绕筐口小幅摆动衰减，仅 front 层调用）
func swing_net() -> void:
	if _swing_tween != null:
		_swing_tween.kill()
	_swing_tween = create_tween()
	_swing_tween.tween_method(_set_swing, 0.0, 0.2, 0.12)
	_swing_tween.tween_method(_set_swing, 0.2, -0.2, 0.16)
	_swing_tween.tween_method(_set_swing, -0.2, 0.0, 0.22)


func _set_swing(v: float) -> void:
	net_swing = v
	queue_redraw()


## 背板碰撞矩形（世界坐标，按 back 图实测 bbox）；front 层或素材缺失返回空矩形
func board_rect() -> Rect2:
	if not is_back or _tex == null or half_width <= 0.0:
		return Rect2()
	var s := half_width * 2.0 / (_tex.get_width() * RIM_W_RATIO)
	var w := _tex.get_width() * s
	var h := _tex.get_height() * s
	return Rect2(position + Vector2(BACK_RECT_OFF.x * w, BACK_RECT_OFF.y * h),
			Vector2(BACK_RECT_SIZE.x * w, BACK_RECT_SIZE.y * h))


func _draw() -> void:
	if _tex != null and half_width > 0.0:
		var s := half_width * 2.0 / (_tex.get_width() * RIM_W_RATIO)
		var anchor := RIM_CENTER_BACK if is_back else RIM_CENTER_FRONT
		draw_set_transform(Vector2.ZERO, net_swing * 0.06, Vector2(s, s))
		draw_texture(_tex, -Vector2(_tex.get_width() * anchor.x, _tex.get_height() * anchor.y))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化绘制（素材缺失时）
	if half_width <= 0.0:
		return
	if is_back:
		# back 层兜底：半透明背板（宽 1.72×筐外径）+ 白描边 + 红托架底条
		var w := half_width * 2.0 * 1.72
		var h := w * 0.79
		draw_rect(Rect2(-w / 2.0, -h, w, h), Color(0.92, 0.94, 0.96, 0.55))
		draw_rect(Rect2(-w / 2.0, -h, w, h), Color(0.8, 0.83, 0.86, 0.9), false, 4.0)
		draw_rect(Rect2(-w / 2.0, -h * 0.18, w, h * 0.18), Color(0.85, 0.15, 0.15, 0.85))
		return
	# front 层兜底：程序化筐圈 + 网（原版几何）
	var rim := Color(0.90, 0.47, 0.13)
	var net := Color(1, 1, 1, 0.8)
	draw_line(Vector2(-half_width, 0), Vector2(half_width, 0), rim, 6.0)
	var sway := net_swing * net_len * 0.35
	for i in [-1.0, 0.0, 1.0]:
		var top_x: float = i * half_width * 0.85
		var bot_x: float = i * half_width * 0.4 + sway
		draw_line(Vector2(top_x, 0), Vector2(bot_x, net_len), net, 1.5)
	for fy in [0.45, 0.8]:
		var xl: float = lerpf(-half_width, -half_width * 0.4, fy) + sway * fy
		var xr: float = lerpf(half_width, half_width * 0.4, fy) + sway * fy
		draw_line(Vector2(xl, net_len * fy), Vector2(xr, net_len * fy), net, 1.5)
