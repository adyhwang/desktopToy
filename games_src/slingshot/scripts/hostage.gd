extends Node2D
## 被捆绑的人质（素材：assets/hostages/hostage_tied.png，坐在椅子上）
## 过关后挣脱换 free 素材（hostage_free.png）向下跑出屏幕，由主控移除后才进入下一波

const Glyph := preload("res://scripts/glyphs.gd")

var escaped := false      # true = 已挣脱撤离（不再受误击惩罚，向下跑出屏幕）
var scl := 1.0            # 视口缩放（主控生成时设置）
var _tex_tied: Texture2D
var _tex_free: Texture2D


func _ready() -> void:
	_tex_tied = Glyph.load_png("hostages/hostage_tied.png")
	_tex_free = Glyph.load_png("hostages/hostage_free.png")
	queue_redraw()


func _process(delta: float) -> void:
	if not escaped:
		return
	position.y += 190.0 * scl * delta   # 挣脱后向下跑，直到移出屏幕（主控负责移除）
	queue_redraw()


func _draw() -> void:
	var tex := _tex_free if escaped else _tex_tied
	if tex == null:
		return
	# 画布 160×160，锚点 = 椅子/双脚与地面交点 (80, 138)
	var s := 160.0 * scl
	draw_texture_rect(tex, Rect2(-80.0 * scl, -138.0 * scl, s, s), false)
