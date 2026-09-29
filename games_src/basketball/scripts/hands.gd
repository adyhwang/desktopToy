extends Node2D
## 持球双手（CC0 素材：opengameart alleyapp / looneybits）：只画手不画手臂
## 节点原点 = 球心位置；低位/举起由主控通过 rise(0~1) 驱动节点 y

var rise := 0.0          # 0=低位 1=举起（Tween 驱动）
var ball_radius := 20.0  # 主控设置，决定手显示大小
var tex_scale := 4.4     # 手贴图渲染宽 = ball_radius × 此值（主控统一配置传入）
var grip_offset := 11.0  # 指尖交汇点相对球心的下偏移（主控传入：球半径 × HAND_GRIP_BALLS）
var _tex: Texture2D


func _ready() -> void:
	# 原始 png 字节解码（pck 内未走导入流程）；第二条路径供编辑器直接打开本工程预览
	for p in ["res://games/basketball/assets/hands.png", "res://assets/hands.png"]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				_tex = ImageTexture.create_from_image(img)
			break


func _draw() -> void:
	if _tex != null and ball_radius > 0.0:
		var s := ball_radius * tex_scale / _tex.get_width()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		# 素材指尖交汇点约 (0.5w, 0.30h)，按 grip_offset 对齐（指尖扣住球身下缘）
		draw_texture(_tex, Vector2(-_tex.get_width() * 0.5, -_tex.get_height() * 0.30 + grip_offset))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化简化双手（素材缺失时）
	var skin := Color(0.96, 0.82, 0.70)
	if ball_radius > 0.0:
		draw_circle(Vector2(-ball_radius * 1.1, ball_radius * 0.9), ball_radius * 0.7, skin)
		draw_circle(Vector2(ball_radius * 1.1, ball_radius * 0.9), ball_radius * 0.7, skin)
