extends Object
## 子弹图标绘制（静态工具，无状态）：12 种玩家子弹 + 劫匪石块
## 扁平卡通 + 粗黑描边，与合集美术风格一致
## 调用方式：draw_glyph(cv, id, r, pos, rot, scl)——变换由本函数统一设置（内部使用绝对矩阵，
## 不依赖调用方预设），绘制结束后变换停留在基准态 t0，调用方需自行复位
## r = 图标基准半径（整体尺寸约 2r）

const OUTLINE := Color(0.10, 0.08, 0.07)

static var _tex_cache := {}


## 从包内 assets 加载 PNG（原始字节解码，双路径兼容编辑器工程 / pck 运行时；失败返回 null）
static func load_png(rel: String) -> Texture2D:
	if _tex_cache.has(rel):
		return _tex_cache[rel]
	var tex: Texture2D = null
	for base in ["res://assets/", "res://games/slingshot/assets/"]:
		var f := FileAccess.open(base + rel, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				tex = ImageTexture.create_from_image(img)
			break
	_tex_cache[rel] = tex
	return tex


static func draw_glyph(cv: CanvasItem, id: String, r: float, pos := Vector2.ZERO, rot := 0.0, scl := 1.0) -> void:
	# 素材优先：assets/bullets/<id>.png（画布 100×100，内容居中占 80%）→ 显示边长 2.5r 时视觉尺寸与程序化一致；
	# PNG 缺失时回退下方程序化绘制（删掉素材不影响运行）
	var tex := load_png("bullets/%s.png" % id)
	if tex != null:
		var tt := Transform2D(rot, pos).scaled_local(Vector2.ONE * scl)
		cv.draw_set_transform_matrix(tt)
		cv.draw_texture_rect(tex, Rect2(-1.25 * r, -1.25 * r, 2.5 * r, 2.5 * r), false)
		cv.draw_set_transform_matrix(Transform2D())
		return
	var ow: float = maxf(r * 0.20, 1.5)
	var t0 := Transform2D(rot, pos).scaled_local(Vector2.ONE * scl)
	cv.draw_set_transform_matrix(t0)   # 统一基准变换：所有分支（含无特殊变换的）都画在 pos/rot/scl 处
	match id:
		"stone":
			_poly(cv, _blob(r * 0.95, [0.85, 1.0, 0.92, 0.78, 0.95, 0.88, 0.80]), Color(0.62, 0.60, 0.57), OUTLINE, ow)
			_line(cv, Vector2(-r * 0.25, -r * 0.15), Vector2(r * 0.15, -r * 0.35), Color(0.78, 0.76, 0.72), ow * 0.6)
		"egg":
			cv.draw_set_transform_matrix(t0 * Transform2D(0.35, Vector2(0, r * 0.05)).scaled_local(Vector2(0.82, 1.0)))
			_circle(cv, Vector2.ZERO, r * 0.85, Color(0.97, 0.95, 0.90), OUTLINE, ow)
			cv.draw_set_transform_matrix(t0)
			_line(cv, Vector2(-r * 0.30, -r * 0.25), Vector2(-r * 0.12, -r * 0.42), Color.WHITE, ow * 0.5)
		"tomato":
			_circle(cv, Vector2.ZERO, r * 0.92, Color(0.86, 0.22, 0.18), OUTLINE, ow)
			for i in 5:
				var a: float = -PI / 2.0 + (float(i) - 2.0) * 0.5
				_poly(cv, [Vector2.ZERO, Vector2.from_angle(a - 0.28) * r * 0.55, Vector2.from_angle(a + 0.28) * r * 0.55], Color(0.30, 0.58, 0.22), OUTLINE, ow * 0.6)
			_circle(cv, Vector2(0, -r * 0.18), r * 0.12, Color(0.24, 0.46, 0.18), OUTLINE, ow * 0.5)
		"apple":
			cv.draw_set_transform_matrix(t0.scaled_local(Vector2(1.05, 0.95)))
			_circle(cv, Vector2.ZERO, r * 0.92, Color(0.82, 0.20, 0.20), OUTLINE, ow)
			cv.draw_set_transform_matrix(t0)
			_line(cv, Vector2(0, -r * 0.75), Vector2(r * 0.08, -r * 1.15), Color(0.42, 0.28, 0.14), ow * 0.7)
			_poly(cv, [Vector2(r * 0.10, -r * 1.05), Vector2(r * 0.55, -r * 1.30), Vector2(r * 0.45, -r * 0.92)], Color(0.36, 0.64, 0.26), OUTLINE, ow * 0.6)
		"firecracker":
			_poly(cv, [Vector2(-r * 0.42, -r * 0.70), Vector2(r * 0.42, -r * 0.70), Vector2(r * 0.42, r * 0.70), Vector2(-r * 0.42, r * 0.70)], Color(0.88, 0.25, 0.20), OUTLINE, ow)
			_poly(cv, [Vector2(-r * 0.42, -r * 0.70), Vector2(r * 0.42, -r * 0.70), Vector2(r * 0.42, -r * 0.48), Vector2(-r * 0.42, -r * 0.48)], Color(0.92, 0.78, 0.30), OUTLINE, ow * 0.6)
			_poly(cv, [Vector2(-r * 0.42, r * 0.48), Vector2(r * 0.42, r * 0.48), Vector2(r * 0.42, r * 0.70), Vector2(-r * 0.42, r * 0.70)], Color(0.92, 0.78, 0.30), OUTLINE, ow * 0.6)
			_line(cv, Vector2(0, -r * 0.70), Vector2(r * 0.20, -r * 1.05), Color(0.55, 0.45, 0.30), ow * 0.7)
			_line(cv, Vector2(r * 0.20, -r * 1.05), Vector2(r * 0.45, -r * 0.95), Color(0.55, 0.45, 0.30), ow * 0.7)
			for i in 4:
				var a: float = float(i) * TAU / 4.0 + 0.4
				_line(cv, Vector2(r * 0.45, -r * 0.95), Vector2(r * 0.45, -r * 0.95) + Vector2.from_angle(a) * r * 0.22, Color(1.0, 0.85, 0.30), ow * 0.5)
		"blade":
			var pts := PackedVector2Array()
			for i in 8:
				var a: float = float(i) * TAU / 8.0 - PI / 2.0
				var rr: float = r if i % 2 == 0 else r * 0.40
				pts.append(Vector2.from_angle(a) * rr)
			_poly(cv, pts, Color(0.78, 0.81, 0.86), OUTLINE, ow)
			_circle(cv, Vector2.ZERO, r * 0.16, Color(0.35, 0.37, 0.40), OUTLINE, ow * 0.5)
		"bottle":
			_poly(cv, [Vector2(-r * 0.16, -r * 0.95), Vector2(r * 0.16, -r * 0.95), Vector2(r * 0.16, -r * 0.55), Vector2(r * 0.52, -r * 0.25), Vector2(r * 0.52, r * 0.85), Vector2(-r * 0.52, r * 0.85), Vector2(-r * 0.52, -r * 0.25), Vector2(-r * 0.16, -r * 0.55)], Color(0.30, 0.62, 0.38), OUTLINE, ow)
			_poly(cv, [Vector2(-r * 0.24, -r * 1.05), Vector2(r * 0.24, -r * 1.05), Vector2(r * 0.24, -r * 0.88), Vector2(-r * 0.24, -r * 0.88)], Color(0.55, 0.40, 0.25), OUTLINE, ow * 0.6)
			_line(cv, Vector2(-r * 0.32, -r * 0.10), Vector2(-r * 0.32, r * 0.60), Color(0.62, 0.85, 0.66), ow * 0.5)
		"balloon":
			_circle(cv, Vector2(0, -r * 0.10), r * 0.82, Color(0.32, 0.56, 0.90), OUTLINE, ow)
			_poly(cv, [Vector2(-r * 0.16, r * 0.66), Vector2(r * 0.16, r * 0.66), Vector2(0, r * 0.92)], Color(0.32, 0.56, 0.90), OUTLINE, ow * 0.6)
			var str_pts := PackedVector2Array()
			for i in 7:
				var k: float = float(i) / 6.0
				str_pts.append(Vector2(sin(k * 9.0) * r * 0.12, r * 0.92 + k * r * 0.75))
			cv.draw_polyline(str_pts, Color(0.55, 0.55, 0.58), ow * 0.5, true)
			_line(cv, Vector2(-r * 0.30, -r * 0.42), Vector2(-r * 0.12, -r * 0.62), Color(0.72, 0.85, 1.0), ow * 0.6)
		"boomerang":
			_poly(cv, [Vector2(-r * 0.95, -r * 0.55), Vector2(-r * 0.35, -r * 0.20), Vector2(r * 0.55, -r * 0.05), Vector2(r * 0.90, -r * 0.45), Vector2(r * 0.95, 0.10), Vector2(r * 0.30, r * 0.35), Vector2(-r * 0.60, r * 0.25), Vector2(-r * 0.98, r * 0.05)], Color(0.72, 0.50, 0.26), OUTLINE, ow)
			_line(cv, Vector2(-r * 0.70, -r * 0.25), Vector2(r * 0.55, -r * 0.05), Color(0.88, 0.68, 0.42), ow * 0.5)
		"shotput":
			_circle(cv, Vector2.ZERO, r * 0.90, Color(0.32, 0.33, 0.37), OUTLINE, ow)
			cv.draw_arc(Vector2(-r * 0.15, -r * 0.15), r * 0.60, PI * 0.85, PI * 1.45, 12, Color(0.62, 0.65, 0.70), ow * 0.7, true)
		"stink":
			cv.draw_set_transform_matrix(t0 * Transform2D(0.3, Vector2(0, r * 0.10)).scaled_local(Vector2(0.82, 1.0)))
			_circle(cv, Vector2.ZERO, r * 0.80, Color(0.62, 0.76, 0.34), OUTLINE, ow)
			cv.draw_set_transform_matrix(t0)
			for i in 3:
				var x: float = (float(i) - 1.0) * r * 0.45
				var pts := PackedVector2Array()
				for k in 7:
					var kk: float = float(k) / 6.0
					pts.append(Vector2(x + sin(kk * 12.0 + float(i)) * r * 0.10, -r * 0.55 - kk * r * 0.55))
				cv.draw_polyline(pts, Color(0.48, 0.60, 0.26), ow * 0.5, true)
		"turret":
			_line(cv, Vector2(-r * 0.35, r * 0.55), Vector2(-r * 0.55, r * 0.88), Color(0.10, 0.08, 0.07), ow * 0.9)
			_line(cv, Vector2(r * 0.35, r * 0.55), Vector2(r * 0.55, r * 0.88), Color(0.10, 0.08, 0.07), ow * 0.9)
			_line(cv, Vector2(0, r * 0.55), Vector2(0, r * 0.90), Color(0.10, 0.08, 0.07), ow * 0.9)
			_line(cv, Vector2(0, -r * 0.30), Vector2(0, -r * 0.85), Color(0.40, 0.45, 0.52), ow * 1.2)
			_poly(cv, [Vector2(-r * 0.62, r * 0.55), Vector2(r * 0.62, r * 0.55), Vector2(r * 0.50, -r * 0.30), Vector2(-r * 0.50, -r * 0.30)], Color(0.58, 0.64, 0.72), OUTLINE, ow)
			_circle(cv, Vector2(0, r * 0.12), r * 0.26, Color(0.30, 0.70, 0.95), OUTLINE, ow * 0.6)
			_circle(cv, Vector2(0, r * 0.12), r * 0.10, Color.WHITE)
		"wasp":
			_circle(cv, Vector2(-r * 0.42, -r * 0.60), r * 0.30, Color(1, 1, 1, 0.85))
			_circle(cv, Vector2(r * 0.18, -r * 0.66), r * 0.26, Color(1, 1, 1, 0.85))
			_poly(cv, [Vector2(-r * 0.10, r * 0.62), Vector2(r * 0.10, r * 0.62), Vector2(0, r * 1.00)], Color(0.12, 0.10, 0.08), OUTLINE, ow * 0.4)
			_circle(cv, Vector2.ZERO, r * 0.72, Color(0.95, 0.78, 0.22), OUTLINE, ow)
			_line(cv, Vector2(-r * 0.15, -r * 0.66), Vector2(-r * 0.15, r * 0.66), Color(0.12, 0.10, 0.08), ow * 0.8)
			_line(cv, Vector2(r * 0.20, -r * 0.60), Vector2(r * 0.20, r * 0.60), Color(0.12, 0.10, 0.08), ow * 0.8)
			_circle(cv, Vector2(-r * 0.38, -r * 0.16), r * 0.09, Color(0.12, 0.10, 0.08))
		"rock":
			_poly(cv, _blob(r * 0.85, [0.9, 0.8, 0.95, 0.85, 0.9, 0.8, 0.92]), Color(0.52, 0.48, 0.44), OUTLINE, ow)
			_line(cv, Vector2(-r * 0.20, -r * 0.10), Vector2(r * 0.12, -r * 0.28), Color(0.66, 0.62, 0.58), ow * 0.5)
		_:
			_circle(cv, Vector2.ZERO, r * 0.85, Color.GRAY, OUTLINE, ow)


## 弹弓弓架（基座+立柱+双叉，黑描边+木色）——运行时与素材导出工具共用，保证 PNG 与程序化外观一致
static func draw_sling_frame(cv: CanvasItem, sp: Vector2, u: float) -> void:
	var base := sp + Vector2(0, 16.0 * u)
	var segs: Array = [[base, sp], [sp, sp + Vector2(-17.0 * u, -44.0 * u)], [sp, sp + Vector2(17.0 * u, -44.0 * u)]]
	for seg: Array in segs:
		cv.draw_line(seg[0], seg[1], Color(0.10, 0.08, 0.07), 15.0 * u, true)
	for seg: Array in segs:
		cv.draw_line(seg[0], seg[1], Color(0.58, 0.40, 0.22), 10.0 * u, true)


## 圆形（含描边）
static func _circle(cv: CanvasItem, c: Vector2, r: float, fill: Color, ol := Color(0, 0, 0, 0), ow := 0.0) -> void:
	cv.draw_circle(c, r, fill)
	if ow > 0.0:
		cv.draw_arc(c, r, 0.0, TAU, 40, ol, ow, true)


## 多边形（填充 + 闭合描边）
static func _poly(cv: CanvasItem, pts: PackedVector2Array, fill: Color, ol := Color(0, 0, 0, 0), ow := 0.0) -> void:
	if pts.size() < 3:
		return
	cv.draw_colored_polygon(pts, fill)
	if ow > 0.0:
		var closed := pts.duplicate()
		closed.append(pts[0])
		cv.draw_polyline(closed, ol, ow, true)


## 线段
static func _line(cv: CanvasItem, a: Vector2, b: Vector2, col: Color, w: float) -> void:
	cv.draw_line(a, b, col, w, true)


## 不规则石块轮廓：7 个顶点，半径按系数表抖动
static func _blob(r: float, j: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 7:
		var a: float = float(i) * TAU / 7.0 - PI / 2.0
		pts.append(Vector2.from_angle(a) * r * float(j[i % j.size()]))
	return pts
