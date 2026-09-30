extends Node2D
## 飞行投射物（玩家子弹 + 劫匪石块）：抛物线表现 = 本体升高放大 + 地面影子缩小
## 位置推进 / 碰撞 / 效果结算全部由主控 slingshot.gd 驱动（_tick_shots），本脚本只负责数据与绘制

const Glyph := preload("res://scripts/glyphs.gd")

var mode := "shot"           # shot=玩家子弹 / rock=劫匪石块
var kind := "stone"          # 玩家子弹 id（BULLETS）
var from := Vector2.ZERO
var to := Vector2.ZERO
var flight := 0.6            # 单程飞行时长（s）
var arc_px := 120.0          # 弧顶高度（px）
var t := 0.0                 # 已飞行时间
var state := 0               # 0 飞行 / 1 引信等待
var fuse := 0.0              # 鞭炮落地延迟
var pierce := 0              # 剩余穿透数
var hits: Array = []         # 已命中劫匪（穿透/去重）
var hit_any := false         # 本次投射是否命中过（连击结算用）
var comboed := false         # 连击是否已结算
var ground := Vector2.ZERO   # 地面投影（主控每帧刷新）
var h := 0.0                 # 当前高度（px）
var done := false            # 生命周期结束（主控回收）

# 回旋镖水平椭圆绕行参数（主控发射时设置）
var boom_home := Vector2.ZERO  # 起飞弹弓位（回到此处且弹弓仍在才可回收）
var bcenter := Vector2.ZERO    # 椭圆中心（起飞点前方 ba 处）
var ba := 0.0                  # 半长轴（沿发射方向）
var bb := 0.0                  # 半短轴（垂直发射方向）
var bdir := Vector2.RIGHT      # 发射方向（局部→全局基）

var _spin := 0.0
var _fuse_blink := 0.0


func _process(delta: float) -> void:
	_spin += delta * 10.0
	if state == 1:
		_fuse_blink += delta * 22.0
	queue_redraw()


## 抛物线插值进度 u∈[0,1]
func u() -> float:
	return clampf(t / maxf(flight, 0.01), 0.0, 1.0)


## 回旋镖椭圆上某进度 ub∈[0,1] 的全局地面点（与主控推进公式一致）
func boom_point(ub: float) -> Vector2:
	var th: float = PI + TAU * ub
	var l := Vector2(cos(th) * ba, sin(th) * bb)
	return bcenter + Vector2(l.x * bdir.x - l.y * bdir.y, l.x * bdir.y + l.y * bdir.x)


func _draw() -> void:
	var r: float = 11.0
	var hn: float = clampf(h / maxf(arc_px, 1.0), 0.0, 1.0)
	var blink: bool = state == 1 and fmod(_fuse_blink, 1.0) > 0.5
	# 地面影子（越高越小越淡）
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, 0.55))
	draw_circle(Vector2.ZERO, r * (1.0 - 0.45 * hn), Color(0, 0, 0, 0.28 * (1.0 - 0.55 * hn)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 飞行拖尾（沿轨迹向后采样 3 个渐隐残影，最快子弹也能看清飞行路径；局部坐标 = 全局 - 节点位置）
	if state == 0:
		var ut: float = u()
		var boomer: bool = kind == "boomerang"
		for k in 3:
			var ub: float = ut - float(k + 1) * 0.055
			if ub <= 0.02:
				break
			var gb: Vector2 = boom_point(ub) if boomer else from.lerp(to, ub)
			var hb: float = 0.0 if boomer else arc_px * 4.0 * ub * (1.0 - ub)
			draw_circle(gb - ground + Vector2(0, -hb), r * (0.55 - 0.12 * float(k)),
					Color(0.95, 0.95, 0.92, 0.26 - 0.07 * float(k)))
	if blink:
		return
	# 本体（越高越大）
	Glyph.draw_glyph(self, "rock" if mode == "rock" else kind, r * 1.05,
			Vector2(0, -h), _rot(), 1.0 + 0.75 * hn)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 鞭炮引信火花
	if state == 1:
		draw_circle(Vector2(0, -h - r), 3.0 + sin(_fuse_blink * 30.0), Color(1.0, 0.85, 0.30))


## 按类型给本体加旋转动感（刀片/回旋镖自旋，脆物翻滚）
func _rot() -> float:
	if mode == "rock":
		return _spin * 1.6
	match kind:
		"blade":
			return _spin * 5.0
		"boomerang":
			return _spin * 3.5
		"bottle", "egg", "stink", "tomato", "apple":
			return minf(t * 5.0, PI * 0.5)
		_:
			return 0.0
