extends Node2D
## 救援气垫：贴图绘制 + 被砸压扁回弹动画（squash 1→0 衰减，压扁时横向鼓出）
## 节点原点 = 气垫底部中心（贴地面），顶面 = position.y - ch

var tex: Texture2D
var hw := 86.0:      # 半宽（主控 _layout/开发者模式传入；setter 自动重绘）
	set(v):
		hw = v
		queue_redraw()
var ch := 32.0:      # 厚（高）
	set(v):
		ch = v
		queue_redraw()
var sq := 0.0         # 压扁程度 0~1


func squash() -> void:
	sq = 1.0
	queue_redraw()


func _process(delta: float) -> void:
	if sq > 0.0:
		sq = maxf(0.0, sq - delta * 4.0)
		queue_redraw()


func _draw() -> void:
	if tex != null:
		# 以底部为基准压扁：纵向缩短、横向鼓出
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0 + sq * 0.55, 1.0 - sq * 0.38))
		draw_texture_rect(tex, Rect2(-hw, -ch, hw * 2.0, ch), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序绘制圆角条
	draw_rect(Rect2(-hw, -ch, hw * 2.0, ch), Color(0.88, 0.28, 0.23))
	draw_rect(Rect2(-hw, -ch, hw * 2.0, ch), Color.BLACK, false, 3.0)
