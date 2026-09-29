extends Node2D
## 办公室黑色网格垃圾桶（双层：back=开口暗腔 / front=完整网格桶）：节点原点 = 桶口平面中心（判定线）
## back 画在垃圾下层（桶腔内壁）、front 画在垃圾上层——网格镂空可见桶内垃圾、网格线与唇沿真实遮挡，
## 入篓遮挡由图层完成。位置由主控统一驱动（难度移动），保证与桶内垃圾同帧；
## 晃动作用于独立偏移量（两层由主控同步 shake）。锚点/开口/桶身碰撞比例按用户素材（512×560）实测；
## 素材缺失时程序化兜底（back=开口暗腔椭圆、front=旧 512 基准整桶）

const RIM_CENTER := Vector2(0.5, 0.138)    # 桶口平面中心在贴图中比例（back 腔椭圆竖直[24,131]中点 77.5/560）
const OPEN_W_RATIO := 0.79                 # 桶口内宽 / 贴图宽（back 腔最宽 421px − 描边 ≈ 405/512）
const OPEN_ELLIPSE_B_RATIO := 0.09         # 桶口内口椭圆纵向半轴 / 贴图宽（内口半高 ≈ 46/512）
const BODY_H_RATIO := 0.91                 # 桶口平面到桶底 / 贴图宽（(543−77.5)/512）
const WALL_TOP_HALF_RATIO := 0.384         # 唇沿下方桶身外半宽 / 贴图宽（196.5/512）
const WALL_BOTTOM_HALF_RATIO := 0.22       # 桶身底部外半宽 / 贴图宽（112.5/512）

var tex_paths: Array = ["res://games/trash/assets/bin_front.png", "res://assets/bin_front.png"]:  # 主控按层配置
	set(v):
		if v == tex_paths:
			return   # _layout 每次窗口变化都会重赋值，内容相同不重复解码
		tex_paths = v
		_load_tex()
var opening_half := 0.0    # 桶口判定半宽（主控按 r×BIN_TEX_ITEMS×OPEN_W_RATIO/2 传入）
var tex_w_items := 5.8     # 贴图渲染宽 = item_radius × 此值（主控统一配置传入）
var item_radius := 24.0
var base_position := Vector2.ZERO  # 桶口平面中心锚点（x 由主控难度移动维护）
var tex_size := Vector2(512, 560)  # 贴图尺寸（兜底基准）
var body_h_px := 465.5             # 桶口平面到桶底（贴图像素，主控碰撞换算用）
var wall_top_half_px := 196.5      # 唇沿下方桶身外半宽（贴图像素）
var wall_bottom_half_px := 112.5   # 桶身底部外半宽（贴图像素）
var open_b_px := 46.0              # 桶口椭圆纵向半轴（贴图像素）
var _tex: Texture2D
var _shake_off := Vector2.ZERO     # 晃动偏移（Tween 驱动，_process 只读不写）
var _shake_tween: Tween


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
		open_b_px = OPEN_ELLIPSE_B_RATIO * tex_size.x
	queue_redraw()


func apply_base() -> void:
	position = base_position


## 命中桶沿/桶壁/入篓晃动（0.2s 位移抖动，独立偏移量由 _process 应用）
func shake() -> void:
	if _shake_tween != null:
		_shake_tween.kill()
	_shake_off = Vector2.ZERO
	_shake_tween = create_tween()
	for dx in [-6.0, 5.0, -3.0, 0.0]:
		_shake_tween.tween_property(self, "_shake_off:x", dx, 0.05)


func _process(_delta: float) -> void:
	# 仅应用晃动偏移（位置由主控统一驱动，与桶内垃圾严格同帧）
	position = base_position + _shake_off


func _draw() -> void:
	if _tex != null and item_radius > 0.0:
		var s := item_radius * tex_w_items / _tex.get_width()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		draw_texture(_tex, -Vector2(_tex.get_width() * RIM_CENTER.x, _tex.get_height() * RIM_CENTER.y))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化绘制（素材缺失时）
	if item_radius <= 0.0:
		return
	if String(tex_paths[0]).contains("bin_back"):
		# back 层兜底：开口暗腔扁椭圆（旧 512 基准口内半宽 200、纵向半高 32，中心在桶口平面 (0,-6)）
		var kb := item_radius * tex_w_items / 512.0
		draw_set_transform(Vector2(0.0, -6.0 * kb), 0.0, Vector2(kb, kb * 0.16))
		draw_circle(Vector2.ZERO, 200.0, Color(0.11, 0.1, 0.09))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# front 层兜底：程序化网格桶（几何与旧 512×560 生成素材一致）
	var k := item_radius * tex_w_items / 512.0
	var body := PackedVector2Array([Vector2(-216, -6) * k, Vector2(216, -6) * k, Vector2(160, 468) * k, Vector2(-160, 468) * k])
	var mesh := Color(0.31, 0.29, 0.275)
	var rim := Color(0.243, 0.231, 0.22)
	draw_colored_polygon(body, mesh)
	var half := 216.0 * k
	for i in range(-9, 10):
		var x := i * 52.0 * k
		draw_line(Vector2(x, -6 * k), Vector2(x + 478 * k, 472 * k), rim, 3.0 * k)
		draw_line(Vector2(x + 478 * k, -6 * k), Vector2(x, 472 * k), rim, 3.0 * k)
	draw_rect(Rect2(-230 * k, -52 * k, 460 * k, 52 * k), rim, true)
	draw_rect(Rect2(-230 * k, -52 * k, 460 * k, 52 * k), Color(0.18, 0.17, 0.16), false, 6.0 * k)
	draw_rect(Rect2(-half, -6 * k, half * 2.0, 16 * k), Color(0.15, 0.14, 0.13), true)
