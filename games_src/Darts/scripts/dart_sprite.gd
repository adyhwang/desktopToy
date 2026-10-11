extends Node2D
## 程序绘制飞镖：针尖在本地原点，镖身朝 -X 延伸（rotation=0 时针头指向 +X）
## 手持 / 飞行 / 钉靶三种形态共用本脚本，仅 length 不同

var length := 120.0

# 配色（扁平常色：银针 + 深灰镖身 + 橙色镖羽）
const COL_NEEDLE := Color(0.78, 0.80, 0.84)
const COL_BARREL := Color(0.24, 0.26, 0.30)
const COL_SHAFT := Color(0.55, 0.57, 0.60)
const COL_FLIGHT := Color(0.90, 0.47, 0.13)
const COL_FLIGHT_DARK := Color(0.72, 0.36, 0.09)


func _draw() -> void:
	var L := length
	# 针（细银线，针尖在原点）
	draw_line(Vector2(0, 0), Vector2(-L * 0.22, 0), COL_NEEDLE, maxf(2.0, L * 0.022), true)
	# 镖身（粗深灰）
	draw_line(Vector2(-L * 0.22, 0), Vector2(-L * 0.46, 0), COL_BARREL, L * 0.075)
	# 杆
	draw_line(Vector2(-L * 0.46, 0), Vector2(-L * 0.60, 0), COL_SHAFT, L * 0.038)
	# 镖羽：上下主羽（橙色四边形）+ 斜向暗橙副羽增加层次
	_petal(L, 1.0, COL_FLIGHT)
	_petal(L, -1.0, COL_FLIGHT)
	_petal(L * 0.82, 0.55, COL_FLIGHT_DARK)
	_petal(L * 0.82, -0.55, COL_FLIGHT_DARK)


## 一片镖羽：从杆部向后展开的四边形，s 控制方向与大小
func _petal(L: float, s: float, col: Color) -> void:
	var pts := PackedVector2Array([
		Vector2(-L * 0.56, 0),
		Vector2(-L * 0.74, s * L * 0.17),
		Vector2(-L * 0.98, s * L * 0.21),
		Vector2(-L * 0.92, s * L * 0.03),
	])
	draw_colored_polygon(pts, col)
