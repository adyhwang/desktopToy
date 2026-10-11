extends Node2D
## 命中特效：扇区淡色楔形高亮 + 落点扩散圆环；自计时结束后自毁
## 由 dart.gd 在命中时创建（插到 Board 之上、钉靶镖之下），参数一次性写入

const TIME := 0.45          # 特效总时长（s）

var center := Vector2.ZERO  # 盘心（屏幕坐标）
var pos := Vector2.ZERO     # 落点（屏幕坐标）
var col := Color.WHITE      # 特效主色（按命中区倍数：单倍绿/双倍蓝/三倍金/BULL 红）
var seg_a := 0.0            # 扇形起止屏幕弧度（seg_b <= seg_a 时只画圆环不画扇形）
var seg_b := 0.0
var radius := 100.0         # 扇形外径（px，= 双倍环外缘，扇区全长）
var inner := 30.0           # 扇形内径（px，= 25 分圈外缘 0.105×盘半径）
var _t := 0.0


func _process(delta: float) -> void:
	_t += delta
	if _t >= TIME:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var k := clampf(_t / TIME, 0.0, 1.0)
	var fade := 1.0 - k
	if seg_b > seg_a:
		# 扇区楔形：外弧（命中半径）+ 内弧（25 分圈外缘）闭合
		var pts := PackedVector2Array()
		var steps := 14
		for i in steps + 1:
			pts.append(center + Vector2.from_angle(lerpf(seg_a, seg_b, float(i) / steps)) * radius)
		for i in steps + 1:
			pts.append(center + Vector2.from_angle(lerpf(seg_b, seg_a, float(i) / steps)) * inner)
		draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.20 * fade))
	# 落点扩散圆环 + 中心闪点
	var r := lerpf(8.0, radius * 0.32, k)
	draw_arc(pos, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.9 * fade), 3.0, true)
	draw_circle(pos, 5.0 * fade, Color(col.r, col.g, col.b, 0.8 * fade))
