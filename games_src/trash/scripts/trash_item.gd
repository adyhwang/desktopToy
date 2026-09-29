extends Node2D
## 随机垃圾道具：节点原点 = 物品中心；主控设置 radius 归一化显示大小
## 每次回待机随机换一件（避免与上一件重复）；素材为程序生成的扁平卡通办公风 PNG

const ITEMS := ["paper", "battery", "book", "cola", "pen", "bone", "cat", "dog",
		"apple", "durian", "banana", "can", "cup", "fish", "egg"]

var radius := 24.0
# 参考弧线配色：上升段橙红 → 下降段亮黄，与篮球残影橙色同族
const PREVIEW_RISE_RING := Color(1.0, 0.44, 0.26, 0.75)
const PREVIEW_RISE_CORE := Color(1.0, 0.62, 0.42, 0.9)
const PREVIEW_FALL_RING := Color(1.0, 0.84, 0.29, 0.85)
const PREVIEW_FALL_CORE := Color(1.0, 0.98, 0.9, 0.95)
const PREVIEW_TAIL_SCALE := 0.55   # 弧线尾端点尺寸比例（手边起点 1.0，越靠后越小）
const PREVIEW_TAIL_FADE := 0.5     # 弧线尾端透明度比例（手边起点 1.0，越靠后越淡）
var current := ""
var preview_points := PackedVector2Array():   # 参考弧线采样点（主控更新；画在本节点内=垃圾桶之上、垃圾本体之下）
	set(v):
		if preview_points != v:
			preview_points = v
			queue_redraw()
var preview_apex_idx := -1:                   # 弧线顶点采样索引
	set(v):
		if preview_apex_idx != v:
			preview_apex_idx = v
			queue_redraw()
var _tex: Texture2D


func set_random(avoid: String = "") -> void:
	var pool: Array = ITEMS.filter(func(x: String) -> bool: return x != avoid or ITEMS.size() <= 1)
	var pick: String = pool[randi() % pool.size()]
	current = pick
	_tex = _load_tex(pick)
	queue_redraw()


func _load_tex(item_name: String) -> Texture2D:
	# 原始 png 字节解码（pck 内未走导入流程）；第二条路径供编辑器直接打开本工程预览
	for base in ["res://games/trash/assets/trash/", "res://assets/trash/"]:
		var path: String = base + item_name + ".png"
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


func _draw() -> void:
	# 参考弧线（先画，交叉处被垃圾本体覆盖；上升段橙红、下降段亮黄；两遍绘制保证上升段叠在下降段之上；
	# 沿弧线进度 u 渐进衰减：越靠后点越小、颜色越淡）
	var n := preview_points.size()
	for i in n:
		if i <= preview_apex_idx:
			continue
		_draw_preview_dot(preview_points[i], float(i) / maxf(n - 1.0, 1.0), false)
	for i in n:
		if i > preview_apex_idx:
			continue
		_draw_preview_dot(preview_points[i], float(i) / maxf(n - 1.0, 1.0), true)
	if _tex != null:
		# 素材已按内容包围盒归一化（最宽边 ≈ 画布 92%），按画布宽映射到 2r
		var s := radius * 2.0 / _tex.get_width() / 0.92
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
		draw_texture(_tex, Vector2(-_tex.get_width() * 0.5, -_tex.get_height() * 0.5))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	# 兜底：程序化灰团（素材缺失时）
	draw_circle(Vector2.ZERO, radius, Color(0.82, 0.8, 0.76))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(0.3, 0.28, 0.25), 2.0)
	draw_line(Vector2(-radius * 0.4, -radius * 0.3), Vector2(radius * 0.3, radius * 0.4), Color(0.65, 0.63, 0.58), 2.0)


## 弧线单点绘制：u = 沿弧线进度（0=手边起点，1=末端），尺寸与透明度随 u 线性衰减
func _draw_preview_dot(pos: Vector2, u: float, rising: bool) -> void:
	var k := lerpf(1.0, PREVIEW_TAIL_SCALE, u)
	var fade := lerpf(1.0, PREVIEW_TAIL_FADE, u)
	var ring := PREVIEW_RISE_RING if rising else PREVIEW_FALL_RING
	var core := PREVIEW_RISE_CORE if rising else PREVIEW_FALL_CORE
	ring.a *= fade
	core.a *= fade
	draw_circle(pos, radius * 0.16 * k, ring)
	draw_circle(pos, radius * 0.16 * k * 0.5, core)
