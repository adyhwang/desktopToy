extends Node2D
## 右手双姿势：待机托举 = hand.png（掌心朝上托举碗）；松开左键推送 = hand2.png（掌心朝前手指朝上）
## 节点原点 = 垃圾中心；节点 y 与 scale 由主控驱动（托举位 / 瞄准低位 / 松手回送）

const PALM_CENTER := Vector2(0.5, 0.586)        # hand.png 掌碗中心在贴图中比例（与生成素材一致：256,300 / 512）
const PALM_CENTER_PUSH := Vector2(0.51, 0.66)   # hand2.png 掌心中心在贴图中比例（350x498 素材）

var pushing := false:    # true=松手推送中，切换为 hand2 贴图（主控在发射/回待机时设置）
	set(v):
		if pushing != v:
			pushing = v
			queue_redraw()
var item_radius := 24.0  # 主控设置，决定手显示大小
var tex_scale := 5.2     # 手贴图渲染宽 = item_radius × 此值（主控统一配置传入）
var grip_offset := 17.0  # 掌碗/掌心中心相对垃圾中心的下偏移（主控传入：r × HAND_GRIP_BALLS）
var _tex: Texture2D
var _tex_push: Texture2D


func _ready() -> void:
	# 原始 png 字节解码（pck 内未走导入流程）；第二条路径供编辑器直接打开本工程预览
	for p in ["res://games/trash/assets/hand.png", "res://assets/hand.png"]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				_tex = ImageTexture.create_from_image(img)
			break
	for p in ["res://games/trash/assets/hand2.png", "res://assets/hand2.png"]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				_tex_push = ImageTexture.create_from_image(img)
			break


func _draw() -> void:
	var tex := _tex_push if (pushing and _tex_push != null) else _tex
	var palm := PALM_CENTER_PUSH if (pushing and _tex_push != null) else PALM_CENTER
	if tex != null and item_radius > 0.0:
		var s := item_radius * tex_scale / tex.get_width()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		# 掌碗/掌心中心对齐垃圾心下方 grip_offset（垃圾坐在手中）
		draw_texture(tex, Vector2(-tex.get_width() * palm.x, -tex.get_height() * palm.y + grip_offset / s))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化简化托举手（素材缺失时）
	var skin := Color(0.91, 0.79, 0.66)
	var dk := Color(0.835, 0.69, 0.553)
	if item_radius <= 0.0:
		return
	draw_circle(Vector2(0, item_radius * 0.9), item_radius * 1.25, skin)
	for i in 4:
		draw_circle(Vector2(-item_radius * 1.05 + i * item_radius * 0.7, item_radius * 0.1), item_radius * 0.32, skin)
	draw_arc(Vector2(0, item_radius * 0.7), item_radius * 0.9, 0.3, PI - 0.3, 24, dk, 2.0)
