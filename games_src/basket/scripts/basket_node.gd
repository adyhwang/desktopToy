extends Node2D
## 编织水果篮（前景/背景双层，同一脚本两实例）：节点原点 = 篮口平面中心（判定线）
## 背景层（basket_back）画在水果下层、前景层（basket_front）画在水果上层——接住的水果沉入篮内
## 被前壁真实遮挡。水平位置由主控统一驱动（保证与篮内水果同帧同步）；
## 晃动作用于独立偏移量（两层由主控同步 shake，互不覆盖）。素材缺失时程序化兜底绘制

const RIM_CENTER := Vector2(0.5, 0.3155)   # 篮口平面中心在贴图中比例（back 腔椭圆最宽行对齐 front 篮口平面 y=161.5/512）
const OPEN_W_RATIO := 0.88                 # 篮口内宽 / 贴图宽（back 腔最宽 467px − 描边 ≈ 450/512）
# 篮身梯形几何（front 实测，篮壁外侧碰撞用）
const BODY_H_RATIO := 0.505            # 篮口平面到篮底 / 贴图宽（258.5/512）
const WALL_TOP_HALF_RATIO := 0.4385    # 篮身顶部外半宽 / 贴图宽（224.5/512）
const WALL_BOTTOM_HALF_RATIO := 0.254  # 篮身底部外半宽 / 贴图宽（130/512）

var tex_paths: Array = ["res://games/basket/assets/basket_front.png", "res://assets/basket_front.png"]:  # 主控按层配置
	set(v):
		if v == tex_paths:
			return   # _layout 每次窗口变化都会重赋值，内容相同不重复解码
		tex_paths = v
		_load_tex()
var opening_half := 0.0    # 篮口判定半宽（主控按 r×BASKET_TEX_ITEMS×OPEN_W_RATIO/2 传入）
var tex_w_items := 4.2     # 贴图渲染宽 = item_radius × 此值（主控统一配置传入）
var item_radius := 24.0
var base_position := Vector2.ZERO  # 篮口平面中心锚点（x/y 均由主控维护）
var tex_size := Vector2(512, 512)  # 贴图尺寸
var body_h_px := 258.5             # 篮口平面到篮底（贴图像素，主控 _step 碰撞换算用）
var wall_top_half_px := 224.5      # 篮身顶部外半宽（贴图像素）
var wall_bottom_half_px := 130.0   # 篮身底部外半宽（贴图像素）
var _tex: Texture2D
var _shake_off := Vector2.ZERO     # 晃动偏移（Tween 驱动，_process 只读不写）
var _shake_tween: Tween
var _bounce_tween: Tween


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
	if _tex != null:
		tex_size = Vector2(_tex.get_width(), _tex.get_height())
		body_h_px = BODY_H_RATIO * tex_size.x
		wall_top_half_px = WALL_TOP_HALF_RATIO * tex_size.x
		wall_bottom_half_px = WALL_BOTTOM_HALF_RATIO * tex_size.x
	queue_redraw()


func _process(_delta: float) -> void:
	# 仅应用晃动偏移（跟随鼠标已上移主控，保证与篮内水果严格同帧）
	position = base_position + _shake_off


func apply_base() -> void:
	position = base_position + _shake_off


## 接住/未接住晃动（0.2s 位移抖动，作用于偏移量；主控两层同步调用）
func shake() -> void:
	if _shake_tween != null:
		_shake_tween.kill()
	_shake_off = Vector2.ZERO
	_shake_tween = create_tween()
	for dx in [-6.0, 5.0, -3.0, 0.0]:
		_shake_tween.tween_property(self, "_shake_off:x", dx, 0.05)


## 接住微缩放弹跳：scale 1→1.12→1（作用于 scale，与 shake 不同属性可并行；主控两层同步调用）
func bounce() -> void:
	if _bounce_tween != null:
		_bounce_tween.kill()
	scale = Vector2.ONE
	_bounce_tween = create_tween()
	_bounce_tween.tween_property(self, "scale", Vector2(1.12, 1.12), 0.07)
	_bounce_tween.tween_property(self, "scale", Vector2.ONE, 0.09)


func _draw() -> void:
	if _tex != null and item_radius > 0.0:
		var s := item_radius * tex_w_items / _tex.get_width()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		draw_texture(_tex, -Vector2(_tex.get_width() * RIM_CENTER.x, _tex.get_height() * RIM_CENTER.y))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化编织篮（素材缺失时），几何与生成素材一致
	if item_radius <= 0.0:
		return
	var k := item_radius * tex_w_items / 512.0
	var body := PackedVector2Array([Vector2(-210, 4) * k, Vector2(210, 4) * k, Vector2(150, 372) * k, Vector2(-150, 372) * k])
	draw_colored_polygon(body, Color(0.78, 0.58, 0.35))
	for i in range(-6, 7):
		var x := i * 52.0 * k
		draw_line(Vector2(x, 4 * k), Vector2(x * 0.714, 372 * k), Color(0.61, 0.43, 0.24), 3.0 * k)
		draw_line(Vector2(x * 0.714, 372 * k), Vector2(x, 4 * k), Color(0.61, 0.43, 0.24), 3.0 * k)
	# 篮口椭圆（原点 = 篮口平面中心）
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.182))
	draw_circle(Vector2.ZERO, 220.0 * k, Color(0.84, 0.67, 0.44))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.15))
	draw_circle(Vector2.ZERO, 200.0 * k, Color(0.37, 0.26, 0.16))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
