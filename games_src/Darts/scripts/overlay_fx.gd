extends Node2D
## 瞄准辅助层（常驻最顶层）：风力预测线 + 精力圈（BotW 风格，含专注到位金态）；参数由 dart.gd 每帧写入

var show_wind := false        # 是否显示风力预测线（AIM 且有风）
var wind_dir := Vector2.RIGHT # 风漂移方向（屏幕坐标单位向量）
var wind_len := 0.0           # 预测线长度（px = 满程漂移距离）
var show_focus := false       # 专注是否到位（晃动收敛到最小，精力弧变金呼吸）
var crosshair_pos := Vector2.ZERO
var focus_r := 40.0           # 精力圈/金环半径（px，画在准星处）
# 精力圈（BotW 荒野之息风格）：与专注金环合并，按住左键蓄力时显示在准星处
var show_stamina := false     # 是否显示精力圈（AIM 且按住左键）
var stamina_ratio := 1.0      # 剩余精力 1→0（消耗时弧沿逆时针方向移除）
var stamina_w := 8.0          # 环线宽（px）
const STAMINA_LOW := 0.3      # 低于此比例整圈变红
var _t := 0.0                 # 呼吸时钟


func _process(delta: float) -> void:
	_t += delta
	if show_wind or show_focus or show_stamina:
		queue_redraw()


func _draw() -> void:
	if show_wind and wind_len > 1.0:
		var from := crosshair_pos + wind_dir * (focus_r * 0.9)
		var to := from + wind_dir * wind_len
		draw_line(from, to, Color(0.55, 0.8, 1.0, 0.45), 2.0, true)
		# 末端箭头：尖端 + 两侧收口
		var tip := to + wind_dir * 9.0
		var side := Vector2(-wind_dir.y, wind_dir.x)
		draw_colored_polygon(PackedVector2Array([tip, to + side * 5.0, to - side * 5.0]),
				Color(0.55, 0.8, 1.0, 0.65))
	# 精力圈：画在准星处，满精力整圈 #2BDB75，按住时逆时针移除，快耗尽变红；
	# 专注到位后弧变金色呼吸（原金环与之合并）；淡白轨道底环衬底让剩余比例可读
	if show_stamina and stamina_ratio > 0.005:
		var col: Color
		if show_focus:
			col = Color(1.0, 0.85, 0.25, 0.55 + 0.3 * sin(_t * 6.0))
		elif stamina_ratio <= STAMINA_LOW:
			col = Color(0.95, 0.25, 0.2)
		else:
			col = Color8(0x2B, 0xDB, 0x75)
		draw_arc(crosshair_pos, focus_r, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.18), stamina_w, true)
		# 剩余弧：起点在顶部（-PI/2），角度向负方向延伸 = 逆时针；消耗时弧尾沿逆时针缩回顶部
		draw_arc(crosshair_pos, focus_r, -PI / 2.0, -PI / 2.0 - TAU * stamina_ratio,
				8 + int(48.0 * stamina_ratio), col, stamina_w, true)
