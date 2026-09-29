extends Node2D
## 篮球（CC0 素材：opengameart alleyapp / looneybits）：以原点为中心绘制，旋转/缩放由主控驱动

var radius := 20.0
var _tex: Texture2D


func _ready() -> void:
	# 原始 png 字节解码（pck 内未走导入流程）；第二条路径供编辑器直接打开本工程预览
	for p in ["res://games/basketball/assets/ball.png", "res://assets/ball.png"]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				_tex = ImageTexture.create_from_image(img)
			break


func _draw() -> void:
	if _tex != null:
		var s := radius * 2.0 / _tex.get_width()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		draw_texture(_tex, Vector2(-_tex.get_width() * 0.5, -_tex.get_height() * 0.5))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化绘制（素材缺失时）
	var orange := Color(0.90, 0.47, 0.13)
	var dark := Color(0.12, 0.08, 0.05)
	draw_circle(Vector2.ZERO, radius, orange)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, dark, 2.0)
	draw_line(Vector2(-radius, 0), Vector2(radius, 0), dark, 1.5)
	draw_line(Vector2(0, -radius), Vector2(0, radius), dark, 1.5)
	draw_arc(Vector2(-radius * 1.4, 0), radius * 1.4, -0.6, 0.6, 16, dark, 1.5)
	draw_arc(Vector2(radius * 1.4, 0), radius * 1.4, PI - 0.6, PI + 0.6, 16, dark, 1.5)
