extends "res://scripts/game_base.gd"  # 打包时自动改写为包前缀路径
## 桌面破坏王 Desk Wreck：纯鼠标沙盒——14 种道具随意破坏/清洁桌面
## 所有痕迹永久保留在痕迹画布上（RGBA8 Image，多层叠加混合），清洁工具可擦除
## 右键按住弹出道具选择轮盘（悬停高亮，松开确认切换）；左键使用道具（点击型单次 / 持续型按住连发）
## 顶部信息栏显示当前破坏度百分比；高分榜（历史破坏度峰值 Top10）经 game_hud 持久保存
## 痕迹画布实现：固定分辨率 Image（跟随窗口初始化，长边上限 2048）→ Sprite2D 拉伸显示
##   - 盖章：Image.blend_rect（alpha 混合，天然支持多层叠加混色）
##   - 擦除：get_region 取小块 → 字节级 alpha 衰减 → blit_rect 回写
##   - 上传：ImageTexture.update 全量重传（本版本仅支持 1 参全量上传）
## 不自绘背景：透出启动器截取的系统桌面截图（与其他小游戏一致）

const Dog := preload("res://scripts/dog.gd")
const GameHud := preload("res://scripts/game_hud.gd")

const GRID_W := 64              # 破坏度统计网格（覆盖画布）
const GRID_H := 36
const CANVAS_CAP := 2048.0      # 画布长边上限（控内存/上传量）
const FX_MAX := 600             # 特效粒子上限
const DOG_CAP := 4              # 同屏小狗上限
const FUSE_T := 0.9             # 鞭炮引信时长（s）
const GAME_HINT_T := 6.0        # 底部操作提示展示时长（s）

const WASHER_R := 88.0          # 清洗喷枪擦除半径（画布 px，1080 基准）
const SPONGE_HALF := 52.0       # 海绵擦方形擦除半边长
const SAW_LINE_COL := Color(0.16, 0.13, 0.10, 1.0)   # 电锯细线颜色（深棕黑刻痕）
const LASER_LINE_COL := Color(1.0, 0.15, 0.15, 1.0)  # 激光笔细线颜色（亮红）
const TRAIL_SPACING := {"spray": 9.0, "sponge": 16.0, "washer": 20.0}
const HAND_TEX := 208.0         # 手持道具光标显示尺寸（贴图 256，作用点=中心）
const GUN_H := 72.0             # 枪械显示高度（贴图 96 高）
const GUN_MUZZLE_OFF := 66.0    # 枪口距枪身中心偏移（贴图 88px × 显示比 0.75）
const HAND_HIDE_T := 0.4        # 投掷道具丢出后图标重生延迟（s）
const SWING_T := 0.16           # 铁锤砸击动画时长（s）
const PRESS_T := 0.18           # 印章按压动画时长（s）
const HAMMER_HOT := Vector2(0, 256)    # 鼠标点在锤光标画布中的位置（图片左下角，256 基准）
const HAMMER_PIVOT := Vector2(116, 220)   # 锤柄尾（握把末端）画布坐标：挥锤动画的旋转锚点
const HAMMER_HEAD := Vector2(115, 60)     # 锤头中心画布坐标：抡到 -90° 时砸击落点=此处
const DOG_CD := 0.5             # 小狗放置冷却（期间隐藏手持图标且不可放置）

# 道具表：kind = click 单次生效 / hold 按住连发；clean = true 清洁类（准星蓝色+擦除圈预览）
# cat = hand 手持（道具贴图即光标，作用点=贴图中心）/ gun 枪械（底部持枪对准光标）/ toss 投掷（底部图标抛出）
const TOOLS := [
	{"id": "egg", "name": "鸡蛋", "kind": "click", "clean": false, "cat": "toss"},
	{"id": "paint", "name": "彩弹枪", "kind": "click", "clean": false, "cat": "gun"},
	{"id": "saw", "name": "电锯", "kind": "hold", "clean": false, "cat": "hand"},
	{"id": "flame", "name": "喷火器", "kind": "hold", "clean": false, "cat": "hand"},
	{"id": "mg", "name": "机关枪", "kind": "hold", "clean": false, "cat": "gun"},
	{"id": "hammer", "name": "铁锤", "kind": "click", "clean": false, "cat": "hand"},
	{"id": "ink", "name": "墨水瓶", "kind": "click", "clean": false, "cat": "toss"},
	{"id": "spray", "name": "涂鸦喷雾", "kind": "hold", "clean": false, "cat": "hand"},
	{"id": "cracker", "name": "小鞭炮", "kind": "click", "clean": false, "cat": "toss"},
	{"id": "laser", "name": "激光笔", "kind": "hold", "clean": false, "cat": "gun"},
	{"id": "stamp", "name": "印章", "kind": "click", "clean": false, "cat": "hand"},
	{"id": "dog", "name": "小狗", "kind": "click", "clean": false, "cat": "hand"},
	{"id": "washer", "name": "清洗喷枪", "kind": "hold", "clean": true, "cat": "gun"},
	{"id": "sponge", "name": "海绵擦", "kind": "hold", "clean": false, "cat": "hand"},
]

const PAINT_COLS := [
	Color(0.86, 0.20, 0.16), Color(0.18, 0.42, 0.86), Color(0.20, 0.65, 0.30), Color(0.95, 0.78, 0.16),
	Color(0.90, 0.42, 0.66), Color(0.95, 0.52, 0.16), Color(0.55, 0.30, 0.80), Color(0.20, 0.72, 0.80),
]
const STAMP_FALLBACK := ["apple", "bone", "book", "can", "cat", "cola", "cup", "dog", "durian", "egg", "fish", "pen"]
const STAMP_WORDS := ["OK", "GO", "COME", "PASS", "GOOD", "HI", "DOG", "CAT", "PIG", "COW", "HEN", "FOX", "BIRD", "FISH", "ONE", "TWO", "SIX", "TEN", "APPLE", "PEAR"]

## 5x7 点阵字模（每字节一列，bit0=顶行）：A-Z 0-9（印章英文单词/数字痕迹用）
const GLYPHS := {
	"A": [0x7C, 0x12, 0x11, 0x12, 0x7C], "B": [0x7F, 0x49, 0x49, 0x49, 0x36],
	"C": [0x3E, 0x41, 0x41, 0x41, 0x22], "D": [0x7F, 0x41, 0x41, 0x22, 0x1C],
	"E": [0x7F, 0x49, 0x49, 0x49, 0x41], "F": [0x7F, 0x09, 0x09, 0x09, 0x01],
	"G": [0x3E, 0x41, 0x49, 0x49, 0x7A], "H": [0x7F, 0x08, 0x08, 0x08, 0x7F],
	"I": [0x00, 0x41, 0x7F, 0x41, 0x00], "J": [0x20, 0x40, 0x41, 0x3F, 0x01],
	"K": [0x7F, 0x08, 0x14, 0x22, 0x41], "L": [0x7F, 0x40, 0x40, 0x40, 0x40],
	"M": [0x7F, 0x02, 0x0C, 0x02, 0x7F], "N": [0x7F, 0x04, 0x08, 0x10, 0x7F],
	"O": [0x3E, 0x41, 0x41, 0x41, 0x3E], "P": [0x7F, 0x09, 0x09, 0x09, 0x06],
	"Q": [0x3E, 0x41, 0x51, 0x21, 0x5E], "R": [0x7F, 0x09, 0x19, 0x29, 0x46],
	"S": [0x46, 0x49, 0x49, 0x49, 0x31], "T": [0x01, 0x01, 0x7F, 0x01, 0x01],
	"U": [0x3F, 0x40, 0x40, 0x40, 0x3F], "V": [0x1F, 0x20, 0x40, 0x20, 0x1F],
	"W": [0x3F, 0x40, 0x38, 0x40, 0x3F], "X": [0x63, 0x14, 0x08, 0x14, 0x63],
	"Y": [0x07, 0x08, 0x70, 0x08, 0x07], "Z": [0x61, 0x51, 0x49, 0x45, 0x43],
	"0": [0x3E, 0x51, 0x49, 0x45, 0x3E], "1": [0x00, 0x42, 0x7F, 0x40, 0x00],
	"2": [0x42, 0x61, 0x51, 0x49, 0x46], "3": [0x21, 0x41, 0x45, 0x4B, 0x31],
	"4": [0x18, 0x14, 0x12, 0x7F, 0x10], "5": [0x27, 0x45, 0x45, 0x45, 0x39],
	"6": [0x3C, 0x4A, 0x49, 0x49, 0x30], "7": [0x01, 0x71, 0x09, 0x05, 0x03],
	"8": [0x36, 0x49, 0x49, 0x49, 0x36], "9": [0x06, 0x49, 0x49, 0x29, 0x1E],
}

const SFX_DB := -4.0
const BGM_DB := -6.0
const SFX_POOL := 4

var hud: RefCounted
var state := 0                  # 0 游玩（沙盒无结算，占位与扩展一致）

var _tool_idx := 0
var _tool := "egg"
var _u := 1.0                   # 全局缩放 = min边 / 1080
var _time := 0.0
var _gen := 0                   # 重开代际（作废挂起的延迟回调）

# 痕迹画布
var _canvas: Image
var _canvas_tex: ImageTexture
var _canvas_dirty := false
var _dirty_rect := Rect2i()
var _grid := PackedByteArray()  # 破坏度网格 0/1
var _cell_w := 30.0
var _cell_h := 30.0
var _pct := -1                  # 当前破坏度 %（-1 强制刷新）
var _peak := 0                  # 本局峰值破坏度（高分榜数据源）

# 输入/轮盘
var _hold := false
var _trail_pos := Vector2.ZERO
var _rate_acc := 0.0
var _snd_acc := {}
var _wheel_open := false
var _wheel_sticky := false      # 点击模式（左下徽章弹出）：左键点扇区选择 / 点空白关闭
var _badge_rect := Rect2()      # 左下角当前道具徽章的点击区域
var _wheel_center := Vector2.ZERO
var _wheel_r_in := 60.0
var _wheel_r_out := 220.0
var _wheel_hover := -1
var _flame_dir := Vector2(0, 1)
var _saw_dir := Vector2.from_angle(-PI / 4.0)   # 电锯锯切方向（锁定后=直线方向，锯条对准该向）
var _saw_ang := -PI / 4.0                        # 电锯光标当前角（平滑过渡，松开回右上待命）
var _saw_line_p0 := Vector2.ZERO   # 电锯直线锁定：按下点（锯切被约束在过此点的直线上）
var _saw_line_dir := Vector2.ZERO  # 电锯直线锁定：初始移动方向
var _saw_line_on := false          # true=初始方向已锁定，锯切只沿该直线移动
var _spray_hue := 0.0
var _gun_base := Vector2.ZERO   # 枪械握持位置（屏幕底中）
var _gun_ang := 0.0             # 枪身旋转角（对准光标）
var _gun_muzzle := Vector2.ZERO # 枪口全局位置（特效起点）
var _hand_hide := 0.0           # >0 投掷道具图标隐藏倒计时
var _swing_t := 0.0             # 铁锤砸击动画剩余时长
var _hammer_wait := false       # true=锤已起挥待落：抡到 -90°（动画半程）时结算落痕
var _press_t := 0.0             # 印章按压动画剩余时长
var _dog_cd := 0.0              # 小狗放置冷却倒计时（>0 隐藏手持图标且不可放置）

# 特效
var _fx: Array = []             # 粒子 {kind, pos, vel, t, life, size, ...}
var _fuses: Array = []          # 鞭炮引信 {pos, t}
var _shake_d := 0.0
var _shake_dur := 0.0
var _shake_t := 0.0

# 资源
var _tex := {}
var _st := {}                   # 预烘焙痕迹印章（Image；蛋痕启动时同步生成，其余后台线程生成后合并）
var _stamp_icons_r: Array = []  # 印章红图（trash 素材染色，懒加载）
var _stamp_icons_b: Array = []  # 印章蓝图
var _stamp_thread: Thread = null  # 痕迹贴图后台烘焙线程（完成经 _merge_stamps 合并回收）
var _st_bg: Dictionary = {}     # 后台烘焙结果（线程本地写，主线程 _merge_stamps 合并）
var _sfx := {}
var _sfx_players: Array = []
var _sfx_loop := {}             # 真实音效循环播放器（电锯：按住播/松开停）
var _dog_bark_t := 0.0          # 小狗在场随机狗叫倒计时（s）
var _bgm: AudioStreamPlayer

@onready var _world: Node2D = $World
@onready var _marks: Sprite2D = $World/Marks
@onready var _dogs_root: Node2D = $World/Dogs
@onready var _projs_root: Node2D = $World/Projs
@onready var _fx_node: Node2D = $World/Fx
@onready var _wreck_board: Label = $HudBar/WreckBoard
@onready var _best_board: Label = $HudBar/BestBoard
@onready var _hud_bar: HBoxContainer = $HudBar
@onready var _exit_btn: Button = $ExitButton

var _restart_btn: Button
var _volume_btn: Button
var _bgm_btn: Button
var _lb_btn: Button
var _hbox: HBoxContainer
var _wheel_ctl: Control
var _reticle_ctl: Control


func start() -> void:
	randomize()
	hud = GameHud.new("desk_wreck")
	get_viewport().size_changed.connect(_layout)
	_load_textures()
	_init_canvas()
	_init_stamps()
	_wheel_ctl = Control.new()
	_wheel_ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wheel_ctl.visible = false
	_wheel_ctl.draw.connect(_draw_wheel)
	add_child(_wheel_ctl)
	_reticle_ctl = Control.new()
	_reticle_ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle_ctl.draw.connect(_draw_reticle)
	add_child(_reticle_ctl)
	_fx_node.draw.connect(_draw_fx)
	_setup_buttons()
	_layout()
	_init_sfx()
	_refresh_boards()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


func stop() -> void:
	if _stamp_thread != null and _stamp_thread.is_started():
		_stamp_thread.wait_to_finish()   # 对象销毁前必须结束后台烘焙线程
		_stamp_thread = null
	get_tree().paused = false            # 排行榜可能还在暂停态，兜底恢复
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _bgm != null:
		_bgm.stop()
	hud.commit_score()                   # 本局峰值入榜
	print("[desk_wreck] stop, peak=%d%%" % _peak)


func _notification(what: int) -> void:
	# 排行榜暂停树时恢复系统指针，关榜回到隐藏准星模式
	if what == NOTIFICATION_PAUSED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif what == NOTIFICATION_UNPAUSED:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


func _exit_button_pressed() -> void:
	exit_requested.emit()


# ===== 资源加载 =====

func _load_textures() -> void:
	for t: Dictionary in TOOLS:
		_tex["t_" + t.id] = _load_png("assets/t_%s.png" % t.id)
	for n: String in ["cur_saw", "cur_flame", "cur_hammer", "cur_spray", "cur_stamp", "cur_sponge",
			"gun_paint", "gun_mg", "gun_laser", "gun_washer"]:
		_tex[n] = _load_png("assets/%s.png" % n)
	for f in 4:
		_tex["dog_w%d" % f] = _load_png("assets/dog_w%d.png" % f)
	for n: String in ["proj_egg", "proj_cracker"]:
		_tex[n] = _load_png("assets/%s.png" % n)


func _load_png(rel: String) -> Texture2D:
	# pck 内原始 png 无导入资源 loader，统一按字节解码（编辑器期走 res:// 相对路径）
	for p: String in ["res://games/desk_wreck/" + rel, "res://" + rel]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


# ===== 痕迹画布 =====

func _init_canvas() -> void:
	var vp := get_viewport_rect().size
	var k := minf(1.0, CANVAS_CAP / maxf(vp.x, vp.y))
	var size := Vector2i(int(vp.x * k), int(vp.y * k))
	_canvas = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	_canvas.fill(Color(0, 0, 0, 0))
	_canvas_tex = ImageTexture.create_from_image(_canvas)
	_marks.texture = _canvas_tex
	_marks.centered = false
	_grid.resize(GRID_W * GRID_H)
	_grid.fill(0)
	_cell_w = float(size.x) / float(GRID_W)
	_cell_h = float(size.y) / float(GRID_H)


func _to_canvas(vpos: Vector2) -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(vpos.x * _canvas.get_width() / vp.x, vpos.y * _canvas.get_height() / vp.y)


## 盖章：alpha 混合贴入画布（自动裁剪出界部分），并标记破坏度网格与脏矩形；img 为 null（后台未就绪）跳过
func _stamp_mark(img: Image, cpos: Vector2, grid_r: float = -1.0) -> void:
	if img == null:
		return
	var half := Vector2(img.get_width(), img.get_height()) * 0.5
	var dst := Vector2i((cpos - half).floor())
	var sr := Rect2i(Vector2i.ZERO, Vector2i(img.get_width(), img.get_height()))
	var cl := Rect2i(dst, sr.size).intersection(Rect2i(0, 0, _canvas.get_width(), _canvas.get_height()))
	if cl.size.x <= 0 or cl.size.y <= 0:
		return
	sr = Rect2i(sr.position + (cl.position - dst), cl.size)
	dst = cl.position
	_canvas.blend_rect(img, sr, dst)
	_grid_mark(cpos, half.x if grid_r < 0.0 else grid_r)
	_canvas_dirty = true
	var dirty := Rect2i(dst, cl.size)
	_dirty_rect = _dirty_rect.merge(dirty) if _dirty_rect.has_area() else dirty


## 擦除：圆形区域 alpha 衰减（中心强边缘弱），随后重采样受影响网格
func _erase_at(vpos: Vector2, radius: float, strength: float) -> void:
	var cpos := _to_canvas(vpos)
	var rect := Rect2i(int(cpos.x - radius) - 1, int(cpos.y - radius) - 1,
			int(radius * 2.0) + 2, int(radius * 2.0) + 2) \
			.intersection(Rect2i(0, 0, _canvas.get_width(), _canvas.get_height()))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var region := _canvas.get_region(rect)
	var bytes := region.get_data()
	var w := rect.size.x
	var r2 := radius * radius
	for y in rect.size.y:
		var dy := float(y + rect.position.y) - cpos.y
		var row := y * w * 4 + 3
		for x in w:
			var dx := float(x + rect.position.x) - cpos.x
			var d2 := dx * dx + dy * dy
			if d2 >= r2:
				continue
			var fall := 1.0 - strength * (1.0 - sqrt(d2 / r2))
			var idx := row + x * 4
			bytes[idx] = int(bytes[idx] * fall)
	var patch := Image.create_from_data(w, rect.size.y, false, Image.FORMAT_RGBA8, bytes)
	_canvas.blit_rect(patch, Rect2i(0, 0, w, rect.size.y), rect.position)
	_grid_resample(rect)
	_canvas_dirty = true
	_dirty_rect = _dirty_rect.merge(rect) if _dirty_rect.has_area() else rect


## 海绵"吸走颜色"：方形区域像素向白色混合（中心强边缘弱），随后重采样受影响网格
func _paint_white(vpos: Vector2, half: float) -> void:
	var cpos := _to_canvas(vpos)
	var rect := Rect2i(int(cpos.x - half) - 1, int(cpos.y - half) - 1,
			int(half * 2.0) + 2, int(half * 2.0) + 2) \
			.intersection(Rect2i(0, 0, _canvas.get_width(), _canvas.get_height()))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var region := _canvas.get_region(rect)
	var bytes := region.get_data()
	var w := rect.size.x
	for y in rect.size.y:
		var dy := absf(float(y + rect.position.y) - cpos.y)
		var row := y * w * 4
		for x in w:
			var dx := absf(float(x + rect.position.x) - cpos.x)
			var dedge := half - maxf(dx, dy)   # 切比雪夫距离到边
			if dedge <= 0.0:
				continue
			var fall := dedge / half           # 中心1→边缘0
			var idx := row + x * 4
			for k in 3:
				bytes[idx + k] = int(bytes[idx + k] + (255.0 - bytes[idx + k]) * fall)
			bytes[idx + 3] = int(maxf(bytes[idx + 3], 255.0 * fall))
	var patch := Image.create_from_data(w, rect.size.y, false, Image.FORMAT_RGBA8, bytes)
	_canvas.blit_rect(patch, Rect2i(0, 0, w, rect.size.y), rect.position)
	_grid_resample(rect)
	_canvas_dirty = true
	_dirty_rect = _dirty_rect.merge(rect) if _dirty_rect.has_area() else rect


## 画布连续细线（电锯/激光笔刻痕）：逐像素覆盖直线，直改 Image 字节后重采样网格
func _canvas_line(c0: Vector2, c1: Vector2, wd: float = 2.2, col: Color = SAW_LINE_COL) -> void:
	var cw := _canvas.get_width()
	var ch := _canvas.get_height()
	var bw := maxi(1, int(round(wd)))
	var n := clampi(int(ceil(c0.distance_to(c1) / maxf(wd * 0.45, 0.8))), 1, 512)
	var mn := Vector2i(99999, 99999)
	var mx := Vector2i(-1, -1)
	for i in n + 1:
		var p := Vector2i(c0.lerp(c1, float(i) / float(n)).floor())
		for oy in bw:
			for ox in bw:
				var q := p + Vector2i(ox, oy)
				if q.x < 0 or q.y < 0 or q.x >= cw or q.y >= ch:
					continue
				_canvas.set_pixelv(q, col)
				if q.x < mn.x:
					mn.x = q.x
				if q.y < mn.y:
					mn.y = q.y
				if q.x > mx.x:
					mx.x = q.x
				if q.y > mx.y:
					mx.y = q.y
	if mx.x < 0:
		return
	var rect := Rect2i(mn, mx - mn + Vector2i.ONE)
	_grid_resample(rect)
	_canvas_dirty = true
	_dirty_rect = _dirty_rect.merge(rect) if _dirty_rect.has_area() else rect


## 脏时整图刷新画布纹理（ImageTexture.update 仅支持全量上传）
func _flush_canvas() -> void:
	if not _canvas_dirty:
		return
	_canvas_tex.update(_canvas)
	_canvas_dirty = false
	_dirty_rect = Rect2i()


# ===== 破坏度统计 =====

func _grid_mark(cpos: Vector2, r: float) -> void:
	var x0 := clampi(int((cpos.x - r) / _cell_w), 0, GRID_W - 1)
	var x1 := clampi(int((cpos.x + r) / _cell_w), 0, GRID_W - 1)
	var y0 := clampi(int((cpos.y - r) / _cell_h), 0, GRID_H - 1)
	var y1 := clampi(int((cpos.y + r) / _cell_h), 0, GRID_H - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			_grid[y * GRID_W + x] = 1


## 擦除后重采样受影响格子：采样点平均 alpha 低于阈值视为已清洁
func _grid_resample(rect: Rect2i) -> void:
	var x0 := clampi(int(rect.position.x / _cell_w), 0, GRID_W - 1)
	var x1 := clampi(int((rect.position.x + rect.size.x) / _cell_w), 0, GRID_W - 1)
	var y0 := clampi(int(rect.position.y / _cell_h), 0, GRID_H - 1)
	var y1 := clampi(int((rect.position.y + rect.size.y) / _cell_h), 0, GRID_H - 1)
	for gy in range(y0, y1 + 1):
		for gx in range(x0, x1 + 1):
			var sum := 0.0
			for sy in 4:
				for sx in 4:
					var px := int((gx + (0.125 + 0.25 * sx)) * _cell_w)
					var py := int((gy + (0.125 + 0.25 * sy)) * _cell_h)
					px = clampi(px, 0, _canvas.get_width() - 1)
					py = clampi(py, 0, _canvas.get_height() - 1)
					sum += _canvas.get_pixel(px, py).a
			_grid[gy * GRID_W + gx] = 1 if sum / 16.0 > 0.09 else 0


func _update_pct() -> void:
	var dirty := 0
	for i in _grid.size():
		if _grid[i] != 0:
			dirty += 1
	var pct := int(round(100.0 * dirty / float(_grid.size())))
	if pct != _pct:
		_pct = pct
		_wreck_board.text = hud.t("hud.wreck", "破坏 %d%%") % pct
	if pct > _peak:
		_peak = pct
		hud.submit_score(_peak)
		_best_board.text = hud.t("hud.best", "纪录 %d%%") % hud.max_score


func _refresh_boards() -> void:
	_wreck_board.text = hud.t("hud.wreck", "破坏 %d%%") % maxi(_pct, 0)
	_best_board.text = hud.t("hud.best", "纪录 %d%%") % hud.max_score


# ===== 印章烘焙（圆点并集 / 染色）=====

## 圆点并集印章：circles 元素 {o: 相对中心偏移, r: 半径, soft: 硬边比例}
func _union_img(sz: int, col: Color, circles: Array) -> Image:
	var img := Image.create_empty(sz, sz, false, Image.FORMAT_RGBA8)
	var R := sz * 0.5
	for y in sz:
		for x in sz:
			var p := Vector2(x + 0.5, y + 0.5) - Vector2(R, R)
			var a := 0.0
			for c: Dictionary in circles:
				var d: float = p.distance_to(c.o) / c.r
				var ca := 0.0
				if d < 1.0:
					ca = 1.0 if d <= c.soft else (1.0 - (d - c.soft) / (1.0 - c.soft))
				a = maxf(a, ca)
			if a > 0.0:
				img.set_pixel(x, y, Color(col.r, col.g, col.b, col.a * a))
	return img


func _blob(sz: int, col: Color, soft: float) -> Image:
	return _union_img(sz, col, [{"o": Vector2.ZERO, "r": sz * 0.5, "soft": soft}])


func _splat(sz: int, col: Color, n: int) -> Image:
	var circles: Array = [{"o": Vector2.ZERO, "r": sz * 0.30, "soft": 0.55}]
	for i in n:
		var ang := randf() * TAU
		var dist := sz * randf_range(0.10, 0.30)
		circles.append({"o": Vector2.from_angle(ang) * dist, "r": sz * randf_range(0.10, 0.22), "soft": 0.5})
	return _union_img(sz, col, circles)


func _tint(src: Image, col: Color) -> Image:
	var img: Image = src.duplicate()
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.0:
				img.set_pixel(x, y, Color(col.r * c.r, col.g * c.g, col.b * c.b, c.a * col.a))
	return img


func _init_stamps() -> void:
	# 鸡蛋痕迹同步生成（开局默认工具，需立即可用，仅数十 ms）；
	# 其余痕迹逐像素生成累计 ~1.6s（GDScript 像素循环慢），放后台线程烘焙，完成后回主线程合并。
	# 后台生成每次运行随机（保留生动性）；未就绪期间对应工具痕迹暂缺（_stamp_mark 跳过，不报错）
	_st["egg_splat"] = []
	for i in 3:
		_st["egg_splat"].append(_splat(150, Color(0.96, 0.96, 0.92, 0.58), 8))
	_st["yolk"] = _blob(56, Color(0.97, 0.72, 0.12, 0.95), 0.5)
	_st["shard"] = _blob(14, Color(0.94, 0.93, 0.88, 0.9), 0.6)
	if OS.has_feature("web"):
		# web 构建无线程支持（COOP/COEP 限制，Thread.start 必败）：主线程同步烘焙（约 1.6s，开局一次性卡顿）
		_gen_stamps_bg()
	else:
		_stamp_thread = Thread.new()
		_stamp_thread.start(_gen_stamps_bg)


## 后台线程：逐像素烘焙其余全部痕迹贴图（只写线程本地 _st_bg，不碰主线程状态）
func _gen_stamps_bg() -> void:
	var d := {}
	d["ink"] = []
	for i in 2:
		d["ink"].append(_splat(190, Color(0.09, 0.08, 0.12, 0.92), 10))
	d["ink_dot"] = _blob(36, Color(0.09, 0.08, 0.12, 0.85), 0.4)
	d["ink_edge"] = _blob(250, Color(0.09, 0.08, 0.12, 0.20), 0.08)
	d["paint"] = {}
	d["paint_drip"] = {}
	for col: Color in PAINT_COLS:
		d["paint"][col] = [_splat(95, Color(col.r, col.g, col.b, 0.9), 7), _splat(95, Color(col.r, col.g, col.b, 0.9), 7)]
		d["paint_drip"][col] = _blob(26, Color(col.r, col.g, col.b, 0.85), 0.4)
	d["graffiti"] = []
	d["speck"] = []
	var white := _blob(72, Color.WHITE, 0.12)
	var speck_w := _blob(20, Color.WHITE, 0.2)
	for i in 12:
		var col := Color.from_hsv(float(i) / 12.0, 0.75, 0.95)
		d["graffiti"].append(_tint(white, Color(col.r, col.g, col.b, 0.5)))
		d["speck"].append(_tint(speck_w, Color(col.r, col.g, col.b, 0.6)))
	d["char"] = _splat(90, Color(0.12, 0.10, 0.08, 0.8), 6)
	d["char_s"] = _blob(40, Color(0.12, 0.10, 0.08, 0.6), 0.3)
	d["lava"] = []                 # 岩浆主体（橙红）
	for i in 3:
		d["lava"].append(_splat(64, Color(0.93, 0.30, 0.06, 0.92), 6))
	d["lava_dark"] = []            # 岩浆暗缘（深红褐）
	d["lava_hot"] = []             # 岩浆炽心（亮黄）
	for i in 2:
		d["lava_dark"].append(_splat(80, Color(0.45, 0.10, 0.04, 0.85), 5))
		d["lava_hot"].append(_splat(34, Color(1.0, 0.78, 0.22, 0.9), 4))
	d["hole_rim"] = _blob(44, Color(0.24, 0.22, 0.20, 0.45), 0.4)
	d["hole"] = _blob(18, Color(0.06, 0.05, 0.04, 0.95), 0.55)
	d["dent"] = _blob(120, Color(0.24, 0.18, 0.13, 0.5), 0.3)
	d["dent_core"] = _blob(56, Color(0.14, 0.10, 0.07, 0.55), 0.4)
	d["blast"] = _blob(110, Color(0.09, 0.07, 0.05, 0.85), 0.25)
	d["crack_bit"] = _blob(12, Color(0.10, 0.08, 0.06, 0.9), 0.6)
	d["paw"] = []
	var paw_circles: Array = [{"o": Vector2(0, 5), "r": 13.0, "soft": 0.4}]
	for a: float in [-2.6, -2.0, -1.15, -0.55]:
		paw_circles.append({"o": Vector2.from_angle(a + PI / 2.0) * 15.0, "r": 6.0, "soft": 0.35})
	var paw := _union_img(54, Color(0.37, 0.25, 0.16, 0.75), paw_circles)
	d["paw"] = [paw, paw.duplicate()]
	d["paw"][1].flip_x()
	d["mud"] = _blob(14, Color(0.37, 0.25, 0.16, 0.5), 0.4)
	_st_bg = d
	_merge_stamps.call_deferred()   # 回主线程合并（避免跨线程写共享字典）


## 主线程合并后台烘焙结果并回收线程
func _merge_stamps() -> void:
	for k: String in _st_bg:
		_st[k] = _st_bg[k]
	_st_bg.clear()
	if _stamp_thread != null and _stamp_thread.is_started():
		_stamp_thread.wait_to_finish()
	_stamp_thread = null


## 安全取痕迹贴图：后台尚未烘焙完（键缺失/数组为空）返回 null，_stamp_mark 会跳过
func _st_pick(key: String) -> Image:
	var v: Variant = _st.get(key)
	if v is Array:
		var arr: Array = v
		return arr[randi() % arr.size()] if not arr.is_empty() else null
	return v as Image


## 印章图案：trash 素材按印泥色染色（懒加载； trash 包不在则用程序兜底图案）
func _stamp_icons_set(base: Color, cache: Array) -> Array:
	if not cache.is_empty():
		return cache
	var names: Array = []
	var d := DirAccess.open("res://games/trash/assets/trash")
	if d != null:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if f.ends_with(".png"):
				names.append(f.get_basename())
			f = d.get_next()
		d.list_dir_end()
	if names.is_empty():
		names = STAMP_FALLBACK
	for n: String in names:
		var img := Image.create_empty(128, 128, false, Image.FORMAT_RGBA8)
		# trash 素材来自其他 pck（启动器会挂载全部 games/*.pck，包内虚拟路径不支持 ..）
		var src: Texture2D = null
		for sp: String in ["res://games/trash/assets/trash/%s.png" % n,
				"res://games/desk_wreck/assets/%s.png" % n]:
			var ff := FileAccess.open(sp, FileAccess.READ)
			if ff != null:
				var probe := Image.new()
				if probe.load_png_from_buffer(ff.get_buffer(ff.get_length())) == OK:
					src = ImageTexture.create_from_image(probe)
					break
		if src == null:
			var star := _splat(120, Color.WHITE, 5)
			img.blend_rect(star, Rect2i(0, 0, 120, 120), Vector2i(4, 4))
		else:
			var simg: Image = src.get_image().duplicate()
			simg.convert(Image.FORMAT_RGBA8)   # blend_rect 要求两图格式一致
			var k := 72.0 / maxf(simg.get_width(), simg.get_height())   # 印图匹配印章贴图印面（圈径101内）
			simg.resize(int(simg.get_width() * k), int(simg.get_height() * k), Image.INTERPOLATE_LANCZOS)
			var dst := Vector2i(int((128 - simg.get_width()) * 0.5), int((128 - simg.get_height()) * 0.5))
			img.blend_rect(simg, Rect2i(0, 0, simg.get_width(), simg.get_height()), dst)
		# 印泥色染色：保留明度层次
		for y in 128:
			for x in 128:
				var c := img.get_pixel(x, y)
				if c.a > 0.0:
					var lum := (c.r + c.g + c.b) / 3.0
					var f2 := 0.55 + 0.45 * lum
					img.set_pixel(x, y, Color(base.r * f2, base.g * f2, base.b * f2, c.a * 0.9))
		cache.append(img)
	return cache


## 点阵文字痕迹图（印章英文单词/阿拉伯数字）：5x7 字模逐位渲染
func _word_img(text: String, col: Color, scale: int = 3) -> Image:
	var w := (5 * scale + 2) * text.length() - 2
	var img := Image.create_empty(w, 7 * scale, false, Image.FORMAT_RGBA8)
	for ci in text.length():
		var gl: Array = GLYPHS[text[ci]]
		for gx in 5:
			var bits: int = gl[gx]
			for gy in 7:
				if bits & (1 << gy):
					for sy in scale:
						for sx in scale:
							img.set_pixel((5 * scale + 2) * ci + gx * scale + sx, gy * scale + sy, col)
	return img


# ===== 输入 =====

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed and not _wheel_open:
				_open_wheel()
			elif not mb.pressed and _wheel_open and not _wheel_sticky:
				_close_wheel(true)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _wheel_open:
					if _wheel_sticky:
						# 点击模式：点扇区选择，点空白/中心关闭
						_wheel_hover_calc()
						if _wheel_hover >= 0:
							_set_tool(_wheel_hover)
						_close_wheel(false)
					return
				var mp := get_global_mouse_position()
				if _badge_rect.size.x > 0.0 and _badge_rect.has_point(mp):
					_open_wheel(true)   # 点击左下徽章：弹出道具选择轮盘（点击模式）
				else:
					_hold = true
					_trail_pos = mp
					_rate_acc = 0.0
					if _tool == "saw":
						_saw_line_p0 = mp
						_saw_line_on = false   # 电锯：按下重置，待初始移动锁定直线方向
					_use_click_tool()
			else:
				_hold = false


# ===== 道具轮盘（右键按住 / 左下徽章点击）=====

func _open_wheel(sticky: bool = false) -> void:
	_hold = false
	_wheel_sticky = sticky
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_wheel_r_out = m * 0.205
	_wheel_r_in = m * 0.06
	var mp := get_global_mouse_position()
	var at := vp * 0.5 if sticky else mp   # 点击模式固定屏幕中心弹出，避免左下角被裁
	_wheel_center = Vector2(
			clampf(at.x, _wheel_r_out + 16.0, vp.x - _wheel_r_out - 16.0),
			clampf(at.y, _wheel_r_out + 16.0, vp.y - _wheel_r_out - 16.0))
	_wheel_hover = -1
	_wheel_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # 轮盘期间恢复系统指针，便于精确选扇区
	_wheel_ctl.visible = true
	_wheel_ctl.queue_redraw()


func _close_wheel(confirm: bool) -> void:
	_wheel_open = false
	_wheel_sticky = false
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN   # 关轮盘回隐藏指针模式
	_wheel_ctl.visible = false
	if confirm and _wheel_hover >= 0:
		_set_tool(_wheel_hover)


func _set_tool(idx: int) -> void:
	_tool_idx = idx
	_tool = TOOLS[idx].id
	_hammer_wait = false   # 中途切锤取消：本次挥击不结算落痕
	_play_sfx("select")
	_popup_at(_wheel_center, hud.t("tool." + String(TOOLS[idx].id), String(TOOLS[idx].name)),
			Color(0.55, 1.0, 0.6) if TOOLS[idx].clean else Color.WHITE)


func _wheel_hover_calc() -> void:
	var mp := get_global_mouse_position()
	var d := mp.distance_to(_wheel_center)
	if d < _wheel_r_in * 0.5 or d > _wheel_r_out * 1.15:
		_wheel_hover = -1
	else:
		# 从正上方起顺时针的扇区角系（与轮盘绘制一致）
		var a := fposmod(atan2(mp.y - _wheel_center.y, mp.x - _wheel_center.x) + PI / 2.0, TAU)
		_wheel_hover = int(a / (TAU / TOOLS.size())) % TOOLS.size()


func _draw_wheel() -> void:
	if not _wheel_open:
		return
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var c := _wheel_center
	var n := TOOLS.size()
	var seg := TAU / float(n)
	var font := ThemeDB.fallback_font
	var w: Control = _wheel_ctl
	w.draw_circle(c, _wheel_r_out + 10.0 * _u, Color(0.05, 0.05, 0.06, 0.55))
	for i in n:
		var a0 := -PI / 2.0 + i * seg + seg * 0.02
		var a1 := -PI / 2.0 + (i + 1) * seg - seg * 0.02
		var pts := PackedVector2Array()
		for k in 7:
			pts.append(c + Vector2.from_angle(a0 + (a1 - a0) * k / 6.0) * _wheel_r_out)
		for k in 7:
			pts.append(c + Vector2.from_angle(a1 - (a1 - a0) * k / 6.0) * _wheel_r_in)
		var cols := PackedColorArray()
		cols.resize(pts.size())
		var fill := Color(1, 1, 1, 0.10) if i == _wheel_hover else Color(0, 0, 0, 0.14)
		for k in pts.size():
			cols[k] = fill
		w.draw_polygon(pts, cols)
		var amid := -PI / 2.0 + (i + 0.5) * seg
		var ipos := c + Vector2.from_angle(amid) * (_wheel_r_in + (_wheel_r_out - _wheel_r_in) * 0.55)
		var isz := m * (0.060 if i == _wheel_hover else 0.048)
		var tex: Texture2D = _tex["t_" + TOOLS[i].id]
		if tex != null:
			w.draw_texture_rect(tex, Rect2(ipos - Vector2(isz, isz) * 0.5, Vector2(isz, isz)), false)
		if i == _wheel_hover:
			w.draw_arc(c, _wheel_r_out + 6.0 * _u, a0 - seg * 0.02, a1 + seg * 0.02, 8, Color(1.0, 0.85, 0.25), 4.0 * _u, true)
		if i == _tool_idx:   # 当前道具标记：金色内弧
			w.draw_arc(c, _wheel_r_in + 3.0 * _u, a0, a1, 8, Color(1.0, 0.85, 0.25, 0.9), 3.0 * _u, true)
	# 中心：当前道具
	w.draw_circle(c, _wheel_r_in * 0.92, Color(0.10, 0.10, 0.12, 0.9))
	var ctex: Texture2D = _tex["t_" + _tool]
	var cisz := _wheel_r_in * 1.1
	if ctex != null:
		w.draw_texture_rect(ctex, Rect2(c - Vector2(cisz, cisz) * 0.5, Vector2(cisz, cisz)), false)
	var fs := int(m * 0.024)
	if _wheel_hover >= 0:
		w.draw_string(font, c + Vector2(-_wheel_r_out, _wheel_r_in * 0.75 + fs), hud.t("tool." + String(TOOLS[_wheel_hover].id), String(TOOLS[_wheel_hover].name)),
				HORIZONTAL_ALIGNMENT_CENTER, _wheel_r_out * 2.0, fs, Color.WHITE)
	else:
		w.draw_string(font, c + Vector2(-_wheel_r_out, _wheel_r_in * 0.75 + fs), hud.t("tool." + String(TOOLS[_tool_idx].id), String(TOOLS[_tool_idx].name)),
				HORIZONTAL_ALIGNMENT_CENTER, _wheel_r_out * 2.0, fs, Color(1.0, 0.85, 0.25))
	var tip: String = hud.t("ui.wheel_sticky", "点击扇区选择 · 点击空白关闭") if _wheel_sticky else hud.t("ui.wheel_drag", "悬停选择 · 松开右键确认")
	w.draw_string(font, c + Vector2(-_wheel_r_out, _wheel_r_out + fs * 2.2),
			tip, HORIZONTAL_ALIGNMENT_CENTER, _wheel_r_out * 2.0, fs, Color(1, 1, 1, 0.7))


# ===== 道具使用 =====

func _use_click_tool() -> void:
	var mp := get_global_mouse_position()
	match _tool:
		"egg":
			_play_sfx("throw")
			_hand_hide = HAND_HIDE_T
			_toss(_tex["proj_egg"], mp, 0.38, func(pos: Vector2) -> void: _egg_splat(pos))
		"paint":
			_play_sfx("shot")
			var ci := randi() % PAINT_COLS.size()
			_fx.append({"kind": "pellet", "a": _gun_muzzle, "b": mp, "pos": _gun_muzzle,
					"t": 0.0, "life": 0.13, "col": PAINT_COLS[ci], "ci": ci})
		"ink":
			_play_sfx("throw")
			_hand_hide = HAND_HIDE_T
			_toss(_tex["t_ink"], mp, 0.44, func(pos: Vector2) -> void: _ink_splash(pos))
		"cracker":
			_play_sfx("throw")
			_hand_hide = HAND_HIDE_T
			_toss(_tex["proj_cracker"], mp, 0.34, func(pos: Vector2) -> void: _cracker_land(pos))
		"hammer":
			if _hammer_wait:   # 上一击还没落锤又点了：先把上一击落了再起新挥
				_hammer_wait = false
				_hammer_smash(_hammer_head_pos(mp))
			_swing_t = SWING_T   # 光标铁锤砸击动画
			_hammer_wait = true  # 抡到位（动画半程）再落痕，痕迹跟随锤头落点
		"stamp":
			_press_t = PRESS_T   # 光标印章按压缩放
			_stamp_press(mp)
		"dog":
			if _dog_cd <= 0.0:
				_spawn_dog(mp)
				_dog_cd = DOG_CD   # 冷却期间隐藏手持图标且不可再放


## 投掷物：从底部道具图标位置旋转抛物线飞向落点
func _toss(tex: Texture2D, to: Vector2, dur: float, done: Callable) -> void:
	var vp := get_viewport_rect().size
	var from := Vector2(vp.x * 0.5, vp.y - 46.0 * _u)
	var t: Node2D = Toss.new(tex, 1.1 * _u)
	_projs_root.add_child(t)
	t.fly(from, to, minf(vp.x, vp.y) * 0.22, dur, randf_range(7.0, 11.0), done)


func _egg_splat(vpos: Vector2) -> void:
	var c := _to_canvas(vpos)
	_stamp_mark(_st_pick("egg_splat"), c)
	_stamp_mark(_st_pick("yolk"), c + Vector2(randf_range(-10, 10), randf_range(-8, 8)))
	for i in 5:   # 蛋壳碎
		var ang := randf() * TAU
		_stamp_mark(_st_pick("shard"), c + Vector2.from_angle(ang) * randf_range(40.0, 62.0))
	for i in 4:   # 蛋壳飞溅粒子
		_fx.append({"kind": "spark", "pos": vpos, "vel": Vector2.from_angle(randf() * TAU) * randf_range(120, 260) * _u,
				"t": 0.0, "life": 0.4, "col": Color(0.95, 0.94, 0.9)})
	_play_sfx("splat")


func _paint_splat(vpos: Vector2, ci: int) -> void:
	var col: Color = PAINT_COLS[ci]
	var c := _to_canvas(vpos)
	var arr: Array = _st.get("paint", {}).get(col, [])
	if not arr.is_empty():
		_stamp_mark(arr[randi() % arr.size()], c)
	var drip: Variant = _st.get("paint_drip", {}).get(col)
	for i in 1 + randi() % 2:   # 流滴
		_stamp_mark(drip, c + Vector2(randf_range(-24, 24), randf_range(36, 66)))
	_play_sfx("splat")


func _ink_splash(vpos: Vector2) -> void:
	var c := _to_canvas(vpos)
	_stamp_mark(_st_pick("ink"), c)
	for i in 3:   # 溅点
		_stamp_mark(_st_pick("ink_dot"), c + Vector2.from_angle(randf() * TAU) * randf_range(70.0, 110.0))
	for i in 2:   # 下淌墨滴
		_stamp_mark(_st_pick("ink_dot"), c + Vector2(randf_range(-16, 16), randf_range(56, 92)))
	_play_sfx("splat")
	_play_sfx("drip")
	# 边缘缓慢晕开（gen 防重开残留）
	var gen := _gen
	var tw := create_tween()
	for i in 3:
		tw.tween_interval(0.7)
		tw.tween_callback(func() -> void:
			if gen == _gen:
				_stamp_mark(_st_pick("ink_edge"), c + Vector2(randf_range(-16, 16), randf_range(-16, 16)), 70.0))


func _cracker_land(vpos: Vector2) -> void:
	_fuses.append({"pos": vpos, "t": FUSE_T})
	_play_sfx("thud", -6.0)
	var gen := _gen
	var tw := create_tween()
	tw.tween_interval(FUSE_T)
	tw.tween_callback(func() -> void:
		if gen == _gen:
			_cracker_bang(vpos))


func _cracker_bang(vpos: Vector2) -> void:
	for i in _fuses.size():
		if _fuses[i].pos.distance_to(vpos) < 2.0:
			_fuses.remove_at(i)
			break
	var c := _to_canvas(vpos)
	_stamp_mark(_st_pick("blast"), c)
	for i in 10:   # 细碎放射裂纹
		var ang := TAU * float(i) / 10.0 + randf_range(-0.2, 0.2)
		var p := c
		var step := randf_range(5.0, 9.0) * _u
		for j in 3 + randi() % 4:
			ang += randf_range(-0.35, 0.35)
			p += Vector2.from_angle(ang) * step
			_stamp_mark(_st_pick("crack_bit"), p, 8.0)
	_fx.append({"kind": "flash", "pos": vpos, "vel": Vector2.ZERO, "t": 0.0, "life": 0.22, "r0": 10.0, "r1": 90.0})
	for i in 10:
		_fx.append({"kind": "spark", "pos": vpos, "vel": Vector2.from_angle(randf() * TAU) * randf_range(180, 420) * _u,
				"t": 0.0, "life": 0.45, "col": Color(1.0, 0.7, 0.25)})
	_shake(16.0, 0.3)
	_play_sfx("boom")


func _hammer_head_pos(mp: Vector2) -> Vector2:
	# 抡到 -90° 瞬间锤头中心的屏幕位置：柄尾锚点 + 锤头相对柄尾逆时针转 90°（(x,y)→(y,-x)）
	var tsz := HAND_TEX * _u
	var rel := (HAMMER_HEAD - HAMMER_PIVOT).rotated(-PI / 2.0)
	return mp + (HAMMER_PIVOT - HAMMER_HOT + rel) / 256.0 * tsz


func _hammer_smash(vpos: Vector2) -> void:
	var c := _to_canvas(vpos)
	_stamp_mark(_st_pick("dent"), c)
	_stamp_mark(_st_pick("dent_core"), c + Vector2(randf_range(-6, 6), randf_range(-6, 6)))
	for i in 8 + randi() % 4:   # 放射状裂纹
		var ang := TAU * float(i) / 8.0 + randf_range(-0.25, 0.25)
		var p := c
		var step := randf_range(6.0, 10.0) * _u
		for j in 3 + randi() % 4:
			ang += randf_range(-0.4, 0.4)
			p += Vector2.from_angle(ang) * step
			_stamp_mark(_st_pick("crack_bit"), p, 8.0)
	_shake(9.0, 0.2)
	_play_sfx("thud")
	_play_sfx("boom", -8.0)


func _stamp_press(vpos: Vector2) -> void:
	var c := _to_canvas(vpos)
	var col := Color(0.78, 0.12, 0.10) if randf() < 0.5 else Color(0.12, 0.24, 0.72)   # 印泥随机红/蓝
	var roll := randf()
	if roll < 0.5:    # 图案（trash 素材染色）
		var icons := _stamp_icons_set(col, _stamp_icons_r if col.r > col.b else _stamp_icons_b)
		_stamp_mark(icons[randi() % icons.size()], c)
	elif roll < 0.8:  # 常用英文单词（动物/水果/常见词）
		_stamp_mark(_word_img(STAMP_WORDS[randi() % STAMP_WORDS.size()], col), c)
	else:             # 阿拉伯数字（0-99）
		_stamp_mark(_word_img(str(randi() % 100), col), c)
	_play_sfx("stamp")


func _spawn_dog(vpos: Vector2) -> void:
	if _dogs_root.get_child_count() >= DOG_CAP:
		_popup_at(vpos, hud.t("ui.too_many_dogs", "小狗太多了！"), Color(0.98, 0.35, 0.3))
		return
	var vp := get_viewport_rect().size
	var pos := Vector2(clampf(vpos.x, 40.0, vp.x - 40.0), clampf(vpos.y, 40.0, vp.y - 40.0))
	var d: Node2D = Dog.new()
	d.frames = [_tex["dog_w0"], _tex["dog_w1"], _tex["dog_w2"], _tex["dog_w3"]]
	d.speed = 92.0 * _u
	d.stamp_cb = _dog_paw
	d.position = pos
	d.scale = Vector2.ONE * _u
	_dogs_root.add_child(d)
	_play_sfx_rand("bark", -6.0)   # 真实狗叫随机变体，音量减半（无下载文件回退合成音）
	_dog_bark_t = randf_range(1.5, 3.2)


func _dog_paw(vpos: Vector2) -> void:
	var c := _to_canvas(vpos)
	_stamp_mark(_st_pick("paw"), c)
	if randf() < 0.3:
		_stamp_mark(_st_pick("mud"), c + Vector2(randf_range(-16, 16), randf_range(-16, 16)))


# ===== 持续型道具（按住左键 tick）=====

func _tick_hold(delta: float) -> void:
	if not _hold or _wheel_open:
		return
	var mp := get_global_mouse_position()
	var t := _tool
	# 连线型：电锯/激光——每帧把上一位置到当前位置画整段连续细线
	if t == "saw" or t == "laser":
		var cut := mp
		if t == "saw":
			# 直线锯切：按下后由初始移动方向锁定一条过按下点的直线，
			# 锯痕与锯子光标只能沿该线往返移动（垂直分量被投影去除，不能拐弯）
			if not _saw_line_on:
				var mv0 := mp - _saw_line_p0
				if mv0.length() >= 10.0 * _u:
					_saw_line_dir = mv0.normalized()
					_saw_line_on = true
					_saw_dir = _saw_line_dir
			if _saw_line_on:
				cut = _saw_line_p0 + _saw_line_dir * maxf((mp - _saw_line_p0).dot(_saw_line_dir), 0.0)
		var c0 := _to_canvas(_trail_pos)
		var c1 := _to_canvas(cut)
		if c0.distance_to(c1) > 0.4:
			if t == "saw":
				_canvas_line(c0, c1, 2.2, SAW_LINE_COL)
			else:
				_canvas_line(c0, c1, 1.0, LASER_LINE_COL)   # 激光：更细的亮红线
		_trail_pos = cut
		if t == "laser" and randf() < 0.05:
			_fx.append({"kind": "smoke", "pos": mp, "vel": Vector2.from_angle(randf() * TAU) * 20.0 * _u,
					"t": 0.0, "life": 0.8, "size": 6.0})
	# 轨迹型：沿移动路径按间距盖章（瞬移限步防卡顿）
	elif TRAIL_SPACING.has(t):
		var spacing: float = TRAIL_SPACING[t] * _u
		var from := _trail_pos
		var d := from.distance_to(mp)
		if d < spacing * 0.35:
			_stamp_trail_tool(t, mp, Vector2(0, 1))
		else:
			var dir := (mp - from) / d
			var steps := mini(int(d / spacing), 8)
			var p := from
			for i in steps:
				p += dir * spacing
				_stamp_trail_tool(t, p, dir)
			_trail_pos = p if steps > 0 else mp
			if int(d / spacing) > 8:
				_trail_pos = mp   # 大步跳：丢弃中间路径防瞬移卡顿
	# 定频型：机关枪 / 喷火器
	var iv := 99.0
	if t == "mg":
		iv = 0.07
	elif t == "flame":
		iv = 0.24
	if iv < 90.0:
		_rate_acc += delta
		while _rate_acc >= iv:
			_rate_acc -= iv
			if t == "mg":
				_mg_fire(mp)
			else:
				_flame_launch(mp)
	# 工具声循环（电锯走 _sfx_loop 专用循环播放器，不在此表；喷火团音随发射单发触发）
	var snd_iv := 99.0
	match t:
		"spray": snd_iv = 0.18
		"washer": snd_iv = 0.26
		"sponge": snd_iv = 0.3
		"laser": snd_iv = 0.95   # 真实激光音长 0.92s，间隔匹配防重叠
	if snd_iv < 90.0:
		_snd_acc[t] = _snd_acc.get(t, snd_iv) + delta
		if _snd_acc[t] >= snd_iv:
			_snd_acc[t] = 0.0
			_play_sfx(t)


func _stamp_trail_tool(t: String, p: Vector2, dir: Vector2) -> void:
	var c := _to_canvas(p)
	match t:
		"spray":
			_spray_hue = fmod(_spray_hue + 0.013, 1.0)
			var gi := int(_spray_hue * 12.0) % 12
			var garr: Array = _st.get("graffiti", [])
			if gi < garr.size():   # 同批生成 graffiti+speck，就绪后一起可用
				_stamp_mark(garr[gi], c + Vector2(randf_range(-6, 6), randf_range(-6, 6)), 30.0)
				if randf() < 0.25:
					_stamp_mark(_st["speck"][gi], c + Vector2.from_angle(randf() * TAU) * randf_range(10.0, 22.0))
		"washer":
			_erase_at(p, WASHER_R, 0.8)
			var jdir := (p - _gun_muzzle).normalized()   # 水柱粒子从枪口喷向落点
			var jdist := p.distance_to(_gun_muzzle)
			for i in 2:
				_fx.append({"kind": "jet", "pos": _gun_muzzle,
						"vel": jdir.rotated(randf_range(-0.09, 0.09)) * maxf(jdist, 60.0) / 0.18,
						"t": 0.0, "life": 0.18})
			if randf() < 0.4:
				_fx.append({"kind": "drop", "pos": p + Vector2(randf_range(-40, 40), randf_range(-20, 20)) * _u,
						"vel": Vector2(randf_range(-60, 60), randf_range(60, 160)) * _u, "t": 0.0, "life": 0.5})
		"sponge":
			_paint_white(p, SPONGE_HALF)
			if randf() < 0.25:
				_fx.append({"kind": "bubble", "pos": p + Vector2(randf_range(-36, 36), randf_range(-36, 10)) * _u,
						"vel": Vector2(randf_range(-20, 20), -40.0) * _u, "t": 0.0, "life": 0.9})


func _mg_fire(mp: Vector2) -> void:
	var c := _to_canvas(mp + Vector2(randf_range(-9, 9), randf_range(-9, 9)))
	_stamp_mark(_st_pick("hole_rim"), c)
	_stamp_mark(_st_pick("hole"), c)
	_fx.append({"kind": "tracer", "a": _gun_muzzle, "b": mp, "t": 0.0, "life": 0.08})
	_fx.append({"kind": "muzzle", "pos": _gun_muzzle, "vel": Vector2.ZERO, "t": 0.0, "life": 0.06})
	_fx.append({"kind": "shell", "pos": _gun_base + Vector2(-8, -4).rotated(_gun_ang) * _u,
			"vel": Vector2(randf_range(-160, -90), randf_range(-220, -140)) * _u,
			"t": 0.0, "life": 0.7, "rot": randf() * TAU, "vr": randf_range(-14, 14)})
	_play_sfx("shot", -2.0)


## 喷火器：喷出一枚火团（飞出后落地，向前滚动沿途把地面烧成岩浆）
func _flame_launch(mp: Vector2) -> void:
	var vel := mp - _trail_pos
	if vel.length() > 3.0:
		_flame_dir = _flame_dir.lerp(vel.normalized(), 0.25).normalized()
	_trail_pos = mp
	var dir := _flame_dir.rotated(randf_range(-0.12, 0.12))
	_fx.append({"kind": "fireball", "pos": mp + _flame_dir * 14.0 * _u,
			"vel": dir * randf_range(560.0, 660.0) * _u,
			"t": 0.0, "life": randf_range(1.25, 1.55), "size": randf_range(9.0, 12.0) * _u,
			"roll": false, "acc": 0.0, "last": mp, "sd": randf() * TAU})
	_play_sfx("flame")


## 火团滚动沿途的岩浆痕迹（暗缘/主体/炽心三层随机 + 偶发焦斑）
func _lava_stamp(c: Vector2) -> void:
	var r := randf()
	if r < 0.5:
		_stamp_mark(_st_pick("lava"), c + Vector2(randf_range(-4, 4), randf_range(-4, 4)) * _u)
	elif r < 0.75:
		_stamp_mark(_st_pick("lava_dark"), c + Vector2(randf_range(-8, 8), randf_range(-8, 8)) * _u)
	else:
		_stamp_mark(_st_pick("lava_hot"), c + Vector2(randf_range(-6, 6), randf_range(-6, 6)) * _u)
	if randf() < 0.15:
		_stamp_mark(_st_pick("char_s"), c + Vector2.from_angle(randf() * TAU) * randf_range(20.0, 36.0) * _u, 20.0)


## 火团烧尽：岩浆洼收尾（焦底 + 暗缘 + 亮心）+ 余烬与烟
func _fireball_out(p: Dictionary) -> void:
	var c := _to_canvas(p.pos)
	_stamp_mark(_st_pick("char"), c)
	_stamp_mark(_st_pick("lava_dark"), c)
	_stamp_mark(_st_pick("lava"), c + Vector2(randf_range(-5, 5), randf_range(-5, 5)) * _u)
	_stamp_mark(_st_pick("lava_hot"), c + Vector2(randf_range(-8, 8), randf_range(-8, 8)) * _u, 26.0)
	for i in 3:
		_fx.append({"kind": "smoke", "pos": p.pos + Vector2(randf_range(-8, 8), randf_range(-8, 8)) * _u,
				"vel": Vector2(randf_range(-20, 20), randf_range(-50, -20)) * _u,
				"t": 0.0, "life": randf_range(0.6, 0.9), "size": 7.0})
	for i in 4:
		_fx.append({"kind": "spark", "pos": p.pos, "vel": Vector2.from_angle(randf() * TAU) * randf_range(80, 220) * _u,
				"t": 0.0, "life": randf_range(0.25, 0.4), "col": Color(1.0, 0.62, 0.16)})


# ===== 特效粒子 =====

func _tick_fx(delta: float) -> void:
	var i := _fx.size() - 1
	while i >= 0:
		var p: Dictionary = _fx[i]
		var kind: String = p.get("kind", "")
		var nt: float = p.t + delta / float(p.life)
		if kind == "pellet" and nt >= 1.0:   # 彩弹到达落点：炸开
			_paint_splat(p.b, int(p.ci))
		if kind == "fireball" and nt >= 1.0:   # 火团烧尽：留下岩浆洼
			_fireball_out(p)
		p.t = nt
		if p.t >= 1.0:
			_fx.remove_at(i)
		else:
			match kind:
				"pellet":
					p.pos = p.a.lerp(p.b, p.t)
				"fireball":
					p.vel *= maxf(1.0 - delta * (1.5 if p.roll else 0.9), 0.0)
					p.pos += p.vel * delta
					var vps := get_viewport_rect().size   # 撞屏幕边缘反弹
					if p.pos.x < 8.0 * _u:
						p.pos.x = 8.0 * _u
						p.vel.x = absf(p.vel.x) * 0.7
					elif p.pos.x > vps.x - 8.0 * _u:
						p.pos.x = vps.x - 8.0 * _u
						p.vel.x = -absf(p.vel.x) * 0.7
					if p.pos.y < 8.0 * _u:
						p.pos.y = 8.0 * _u
						p.vel.y = absf(p.vel.y) * 0.7
					elif p.pos.y > vps.y - 8.0 * _u:
						p.pos.y = vps.y - 8.0 * _u
						p.vel.y = -absf(p.vel.y) * 0.7
					if not p.roll and p.t >= 0.25:   # 飞行段结束→落地滚动
						p.roll = true
						p.last = p.pos
					if p.roll:   # 滚动沿途按间距留岩浆
						p.acc += p.pos.distance_to(p.last)
						if p.acc >= 13.0 * _u:
							p.acc = 0.0
							_lava_stamp(_to_canvas(p.pos))
					p.last = p.pos
					var spd: float = p.vel.length()
					if spd > 130.0 * _u and randf() < 0.55:   # 火舌尾迹
						var back: Vector2 = p.vel / spd
						_fx.append({"kind": "flame", "pos": p.pos - back * 8.0 * _u + Vector2(randf_range(-5, 5), randf_range(-5, 5)) * _u,
								"vel": -back * spd * 0.15 + Vector2(randf_range(-30, 30), randf_range(-60, -10)) * _u,
								"t": 0.0, "life": randf_range(0.16, 0.3), "size": randf_range(6.0, 10.0) * _u})
					if p.roll and randf() < 0.2:   # 滚动烟
						_fx.append({"kind": "smoke", "pos": p.pos, "vel": Vector2(randf_range(-25, 25), randf_range(-55, -15)) * _u,
								"t": 0.0, "life": randf_range(0.5, 0.8), "size": 6.0})
				"spark", "shell", "drop", "sawdust":
					p.vel.y += 1100.0 * _u * delta
					p.pos += p.vel * delta
					if p.has("rot"):
						p.rot += p.vr * delta
				"jet":
					p.vel.y += 500.0 * _u * delta
					p.pos += p.vel * delta
				"flame":
					p.vel *= maxf(1.0 - delta * 2.6, 0.0)
					p.pos += p.vel * delta
				"smoke":
					p.vel *= maxf(1.0 - delta * 1.5, 0.0)
					p.vel.y -= 90.0 * _u * delta
					p.pos += p.vel * delta
				"bubble":
					p.vel.y -= 60.0 * _u * delta
					p.pos += p.vel * delta
		i -= 1
	if _fx.size() > FX_MAX:
		_fx = _fx.slice(_fx.size() - FX_MAX)
	# 鞭炮引信火花
	i = _fuses.size() - 1
	while i >= 0:
		var f: Dictionary = _fuses[i]
		f.t -= delta
		if f.t <= 0.0:
			_fuses.remove_at(i)
		else:
			if randf() < 0.6:
				_fx.append({"kind": "spark", "pos": f.pos + Vector2(0, -10) * _u,
						"vel": Vector2.from_angle(-PI / 2.0 + randf_range(-0.8, 0.8)) * randf_range(40, 120) * _u,
						"t": 0.0, "life": 0.3, "col": Color(1.0, 0.8, 0.3)})
		i -= 1


func _draw_fx() -> void:
	var w: Node2D = _fx_node
	for p: Dictionary in _fx:
		var t: float = p.t
		match p.get("kind", ""):
			"flame":
				var col := Color(1.0, 0.85, 0.2).lerp(Color(0.92, 0.3, 0.1), t)
				if t > 0.62:
					col = col.lerp(Color(0.3, 0.26, 0.24), (t - 0.62) / 0.38)
				col.a = 0.85 * (1.0 - t)
				w.draw_circle(p.pos, p.size * (1.0 - 0.6 * t), col)
			"fireball":
				var fl := 0.9 + 0.25 * sin(_time * 26.0 + float(p.sd))   # 火苗闪烁
				var rr: float = p.size * fl
				w.draw_circle(p.pos, rr * 2.1, Color(1.0, 0.45, 0.08, 0.20 * (1.0 - t)))
				w.draw_circle(p.pos, rr * 1.35, Color(1.0, 0.52, 0.10, 0.8 * (1.0 - t * 0.4)))
				w.draw_circle(p.pos, rr, Color(1.0, 0.72, 0.16, 0.95 * (1.0 - t * 0.3)))
				w.draw_circle(p.pos, rr * 0.5, Color(1.0, 0.95, 0.65, 0.95 * (1.0 - t * 0.5)))
			"smoke":
				w.draw_circle(p.pos, p.size * _u * (1.0 + t * 1.6), Color(0.45, 0.45, 0.45, 0.28 * (1.0 - t)))
			"spark":
				w.draw_circle(p.pos, 3.0 * _u, Color(p.col.r, p.col.g, p.col.b, 1.0 - t))
			"sawdust":
				w.draw_circle(p.pos, 2.5 * _u, Color(0.72, 0.55, 0.35, 0.9 * (1.0 - t)))
			"shell":
				w.draw_set_transform(p.pos, p.rot, Vector2.ONE)
				w.draw_rect(Rect2(-Vector2(3.0, 1.6) * _u, Vector2(6.0, 3.2) * _u), Color(0.85, 0.68, 0.25, 1.0 - t * 0.5))
				w.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			"drop":
				w.draw_circle(p.pos, 3.2 * _u, Color(0.45, 0.7, 0.95, 0.85 * (1.0 - t)))
			"bubble":
				w.draw_arc(p.pos, 4.5 * _u, 0, TAU, 12, Color(0.9, 0.96, 1.0, 0.75 * (1.0 - t)), 1.6 * _u, true)
			"muzzle":
				w.draw_circle(p.pos, 11.0 * _u * (1.0 - t), Color(1.0, 0.85, 0.3, 0.9 * (1.0 - t)))
				w.draw_circle(p.pos, 5.5 * _u * (1.0 - t), Color(1.0, 1.0, 0.9, 1.0 - t))
			"tracer":
				w.draw_line(p.a, p.b, Color(1.0, 0.9, 0.5, 0.75 * (1.0 - t)), 2.2 * _u, true)
			"pellet":
				var tail: Vector2 = p.a.lerp(p.b, maxf(p.t - 0.2, 0.0))
				w.draw_line(tail, p.pos, Color(p.col.r, p.col.g, p.col.b, 0.5), 4.5 * _u, true)
				w.draw_circle(p.pos, 6.5 * _u, p.col)
			"jet":
				var jv: Vector2 = p.vel.normalized() * 14.0 * _u
				w.draw_line(p.pos - jv, p.pos, Color(0.55, 0.8, 1.0, 0.7 * (1.0 - t)), 3.0 * _u, true)
			"flash":
				var r: float = lerpf(p.r0, p.r1, t) * _u
				w.draw_circle(p.pos, r, Color(1.0, 0.95, 0.8, 0.5 * (1.0 - t)))
				w.draw_arc(p.pos, r, 0, TAU, 32, Color(1.0, 0.8, 0.35, 0.8 * (1.0 - t)), 4.0 * _u, true)
	for f: Dictionary in _fuses:
		var ctex: Texture2D = _tex["proj_cracker"]   # 鞭炮本体躺在落点（此前只有火星没有本体）
		if ctex != null:
			w.draw_set_transform(f.pos, 0.4, Vector2.ONE)
			w.draw_texture_rect(ctex, Rect2(Vector2(-17, -17) * _u, Vector2(34, 34) * _u), false)
			w.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		w.draw_circle(f.pos + Vector2(0, -10) * _u, 3.5 * _u, Color(1.0, 0.75, 0.25))
		for i in 3:
			var a := randf() * TAU
			w.draw_line(f.pos + Vector2(0, -10) * _u,
					f.pos + Vector2(0, -10) * _u + Vector2.from_angle(a) * randf_range(4.0, 11.0) * _u,
					Color(1.0, 0.85, 0.3, 0.9), 1.5 * _u, true)


func _shake(d: float, dur: float) -> void:
	_shake_d = maxf(_shake_d, d)
	_shake_dur = maxf(_shake_dur, dur)
	_shake_t = _shake_dur


func _tick_shake(delta: float) -> void:
	if _shake_t > 0.0:
		_shake_t -= delta
		if _shake_t <= 0.0:
			_world.position = Vector2.ZERO
			_shake_d = 0.0
			_shake_dur = 0.0
		else:
			var k: float = _shake_t / _shake_dur
			_world.position = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake_d * k * _u


# ===== 准星与信息提示 =====

func _draw_reticle() -> void:
	if get_tree().paused:
		return
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var mp := get_global_mouse_position()
	var info: Dictionary = TOOLS[_tool_idx]
	var cat: String = info.cat
	var clean: bool = info.clean
	var col := Color(0.35, 0.65, 1.0) if clean else Color(0.95, 0.3, 0.25)
	var r: Control = _reticle_ctl
	# ===== 手持类：道具贴图即光标（作用点=贴图中心=痕迹产生点）；轮盘打开时隐藏（避免遮挡选项）=====
	if cat == "hand" and not _wheel_open:
		var ctex: Texture2D = _tex["dog_w0"] if _tool == "dog" else _tex["cur_" + _tool]
		var hs := HAND_TEX * _u
		var tsz := Vector2(128.0 * _u, 96.0 * _u) if _tool == "dog" else Vector2(hs, hs)   # 小狗手持=放置实际大小（贴图 128x96）
		var wob := Vector2.ZERO
		if _hold and (_tool == "saw" or _tool == "spray" or _tool == "flame"):
			wob = Vector2(randf_range(-2.2, 2.2), randf_range(-2.2, 2.2)) * _u   # 使用中手持抖动
		var ang := 0.0
		var sc := 1.0
		var sp := mp   # 锯切点：电锯持锯时被约束在锁定的直线上（光标只沿线移动）
		if _tool == "saw" and _hold and _saw_line_on:
			sp = _saw_line_p0 + _saw_line_dir * maxf((mp - _saw_line_p0).dot(_saw_line_dir), 0.0)
		var pivot := sp + wob
		if _tool == "hammer" and _swing_t > 0.0:
			var k := 1.0 - _swing_t / SWING_T
			ang = -PI / 2.0 * sin(k * PI)   # 以柄尾为锚逆时针抡 90° 再回弹（负角=逆时针）
			pivot = mp + (HAMMER_PIVOT - HAMMER_HOT) / 256.0 * tsz + wob   # 旋转中心=柄尾屏幕位置
		elif _tool == "saw":
			ang = _saw_ang                              # 锯条对准锯切方向（贴图锯条已转正右 0°）
		elif _tool == "flame":
			ang = _flame_dir.angle() + 0.785            # 贴图喷口默认朝右上 -45°，补偿对准火焰方向
		elif _tool == "stamp" and _press_t > 0.0:
			sc = 1.0 + 0.22 * (_press_t / PRESS_T)       # 按压缩放
		if _tool == "sponge":
			var hv := SPONGE_HALF * _u
			var sq := Rect2(mp - Vector2(hv, hv), Vector2(hv, hv) * 2.0)
			r.draw_rect(sq, Color(1.0, 1.0, 1.0, 0.22), true)
			r.draw_rect(sq, Color(1.0, 1.0, 1.0, 0.55), false, 2.0 * _u)
		if ctex != null and not (_tool == "dog" and _dog_cd > 0.0):
			var anchor := -tsz * 0.5
			if _tool == "hammer":
				anchor = -HAMMER_HOT / 256.0 * tsz      # 图片左下角对齐鼠标点（HAMMER_HOT）
			r.draw_set_transform(pivot, ang, Vector2(sc, sc))
			r.draw_texture_rect(ctex, Rect2(sp + wob + anchor - pivot, tsz), false)
			r.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if _tool == "dog" and _dog_cd > 0.0:   # 放置冷却：隐藏手持小狗，显示准星环提示
			r.draw_arc(mp, 13.0 * _u, 0, TAU, 24, Color(0.95, 0.3, 0.25, 0.9), 2.4 * _u, true)
	# ===== 枪械类：底部持枪 + 枪口→光标特效线 =====
	elif cat == "gun":
		var gtex: Texture2D = _tex["gun_" + _tool]
		var gs := GUN_H / 96.0 * _u
		if gtex != null:
			r.draw_set_transform(_gun_base, _gun_ang, Vector2(gs, gs))
			r.draw_texture_rect(gtex, Rect2(-Vector2(96, 48), Vector2(192, 96)), false)
			r.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if _hold and _tool == "laser":
			r.draw_line(_gun_muzzle, mp, Color(1.0, 0.25, 0.2, 0.28), 7.0 * _u, true)
			r.draw_line(_gun_muzzle, mp, Color(1.0, 0.45, 0.4, 0.95), 2.2 * _u, true)
		elif _hold and _tool == "washer":
			r.draw_line(_gun_muzzle, mp, Color(0.45, 0.7, 0.95, 0.22), 10.0 * _u, true)
			r.draw_line(_gun_muzzle, mp, Color(0.6, 0.85, 1.0, 0.6), 3.5 * _u, true)
		if _tool == "washer":
			r.draw_arc(mp, WASHER_R * _u, 0, TAU, 36, Color(0.35, 0.65, 1.0, 0.28), 2.0 * _u, true)
		# 准星环 + 心点
		r.draw_arc(mp, 13.0 * _u, 0, TAU, 24, col, 2.4 * _u, true)
		r.draw_circle(mp, 2.6 * _u, col)
	# ===== 投掷类：准星环 =====
	else:
		r.draw_arc(mp, 13.0 * _u, 0, TAU, 24, col, 2.4 * _u, true)
		r.draw_circle(mp, 2.6 * _u, col)
	# 底部投掷道具图标（丢出后短暂隐藏，0.4s 重生"新道具"）
	if cat == "toss" and _hand_hide <= 0.0:
		var itex: Texture2D = _tex["proj_egg"] if _tool == "egg" else (_tex["proj_cracker"] if _tool == "cracker" else _tex["t_ink"])
		var isz2 := 64.0 * _u
		r.draw_texture_rect(itex, Rect2(Vector2(vp.x * 0.5 - isz2 * 0.5, vp.y - isz2 - 14.0 * _u), Vector2(isz2, isz2)), false)
	# 当前道具小徽章（左下角：图标 + 名称，点击弹出道具选择轮盘）
	var isz := 40.0 * _u
	var chip := Vector2(18.0, vp.y - 18.0 - isz)
	_badge_rect = Rect2(chip - Vector2(6.0, 6.0) * _u, Vector2(isz + 12.0 * _u, isz + 12.0 * _u))
	var tex: Texture2D = _tex["t_" + _tool]
	if _badge_rect.has_point(mp):   # 悬停高亮，提示可点击
		r.draw_rect(_badge_rect, Color(1, 1, 1, 0.08), true)
		r.draw_rect(_badge_rect, Color(1.0, 0.85, 0.25, 0.9), false, 2.0 * _u)
	if tex != null:
		r.draw_texture_rect(tex, Rect2(chip, Vector2(isz, isz)), false)
	r.draw_string(ThemeDB.fallback_font, chip + Vector2(isz + 10.0 * _u, isz * 0.78), hud.t("tool." + String(info.id), String(info.name)),
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(m * 0.024), Color(1, 1, 1, 0.92))
	# 开局操作提示（渐隐）
	if _time < GAME_HINT_T:
		var a: float = clampf((GAME_HINT_T - _time) / 2.0, 0.0, 1.0)
		r.draw_string(ThemeDB.fallback_font, Vector2(0, vp.y - m * 0.035), hud.t("ui.hint_controls", "左键使用道具 · 右键或点击左下图标选择道具"),
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, int(m * 0.026), Color(1, 1, 1, 0.65 * a))


# ===== 主循环 =====

func _process(delta: float) -> void:
	if hud == null:   # 编辑器直跑预览未 start()，UI 节点尚未创建
		return
	_time += delta
	_tick_shake(delta)
	_flush_canvas()
	_fx_node.queue_redraw()
	_reticle_ctl.queue_redraw()
	if _wheel_open:
		_wheel_hover_calc()
		_wheel_ctl.queue_redraw()
	if get_tree().paused:
		return
	# 道具姿态计时与枪口位置
	_hand_hide = maxf(_hand_hide - delta, 0.0)
	_swing_t = maxf(_swing_t - delta, 0.0)
	_dog_cd = maxf(_dog_cd - delta, 0.0)
	_press_t = maxf(_press_t - delta, 0.0)
	if _hammer_wait and _swing_t <= SWING_T * 0.5:   # 锤抡到位（-90°）瞬间落痕，用此刻鼠标位置使锤子跟手
		_hammer_wait = false
		_hammer_smash(_hammer_head_pos(get_global_mouse_position()))
	var vp := get_viewport_rect().size
	_gun_base = Vector2(vp.x * 0.5, vp.y - 46.0 * _u)
	if TOOLS[_tool_idx].cat == "gun":
		var gmp := get_global_mouse_position()
		_gun_ang = (gmp - _gun_base).angle()
		_gun_muzzle = _gun_base + Vector2(GUN_MUZZLE_OFF * _u, 0.0).rotated(_gun_ang)
	_tick_fx(delta)
	_tick_hold(delta)
	# 小狗在场期间随机汪叫（真实狗叫变体）
	if _dogs_root.get_child_count() > 0:
		_dog_bark_t -= delta
		if _dog_bark_t <= 0.0:
			_dog_bark_t = randf_range(1.5, 3.2)
			_play_sfx_rand("bark", -6.0)
	# 电锯光标角平滑：持锯时锯条转向锯切方向，松开回右上待命姿态
	var saw_tgt := _saw_dir.angle() if (_hold and _tool == "saw" and not _wheel_open) else (-PI / 4.0)
	_saw_ang = lerp_angle(_saw_ang, saw_tgt, minf(1.0 - exp(-14.0 * delta), 1.0))
	# 电锯循环声对账：按住电锯（非轮盘态）播放，否则停止
	if _sfx_loop.has("saw"):
		var sp: AudioStreamPlayer = _sfx_loop["saw"]
		if _hold and not _wheel_open and _tool == "saw":
			if not sp.playing:
				sp.play()
		elif sp.playing:
			sp.stop()
	_update_pct()


# ===== 重开与流程 =====

func _restart() -> void:
	hud.commit_score()   # 本局峰值入榜
	_gen += 1
	_canvas.fill(Color(0, 0, 0, 0))
	_grid.fill(0)
	_pct = -1
	_peak = 0
	_fx.clear()
	_fuses.clear()
	_hand_hide = 0.0
	_swing_t = 0.0
	_hammer_wait = false
	_press_t = 0.0
	_dog_cd = 0.0
	for d in _dogs_root.get_children():
		d.queue_free()
	for p in _projs_root.get_children():
		p.queue_free()
	_canvas_dirty = true
	_dirty_rect = Rect2i(Vector2i.ZERO, _canvas.get_size())
	_flush_canvas()
	_refresh_boards()
	_play_sfx("wash", -4.0)
	_popup(hud.t("ui.cleaned", "桌面已清理"), Color(0.5, 1.0, 0.55))


func _on_lb() -> void:
	hud.show_leaderboard(self, "Top 10", -1, -1)


func _on_bgm() -> void:
	hud.cycle_bgm()
	_bgm_btn.icon = hud.bgm_icon()
	_sync_bgm()


func _sync_bgm() -> void:
	if _bgm == null:
		return
	if hud.bgm_on and not _bgm.playing:
		_bgm.play()
	elif not hud.bgm_on and _bgm.playing:
		_bgm.stop()


func _on_volume() -> void:
	hud.cycle_volume()
	_volume_btn.icon = hud.volume_icon()


# ===== 布局与按钮排 =====

func _layout() -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	_u = m / 1080.0
	_marks.centered = false
	_marks.scale = vp / Vector2(_canvas.get_width(), _canvas.get_height())
	# 信息板随窗口缩放；整体水平居中（Node2D 父下锚点不可靠，代码定位）
	var fs := int(m * 0.035)
	var bw := fs * 6.0
	var bh := fs * 1.9
	for b: Label in [_wreck_board, _best_board]:
		b.custom_minimum_size = Vector2(bw, bh)
		b.add_theme_font_size_override("font_size", fs)
	_hud_bar.reset_size()
	_hud_bar.position = Vector2((vp.x - _hud_bar.size.x) / 2.0, 14.0)
	if _hbox != null:
		_hbox.reset_size()
		_hbox.position = Vector2(vp.x - _hbox.size.x - 20.0, 14.0)
	_wheel_ctl.position = Vector2.ZERO
	_wheel_ctl.size = vp
	_reticle_ctl.position = Vector2.ZERO
	_reticle_ctl.size = vp


## 右上角按钮排（HBox 容器）：✕（tscn 已有）+ 排行榜 + 重开 + 音量循环 + BGM
func _setup_buttons() -> void:
	_hbox = HBoxContainer.new()
	_hbox.name = "TopButtons"
	_hbox.add_theme_constant_override("separation", 8)
	add_child(_hbox)
	var old_parent := _exit_btn.get_parent()
	old_parent.remove_child(_exit_btn)
	GameHud.style_button(_exit_btn)
	_exit_btn.text = ""
	_lb_btn = GameHud.make_button("")
	_restart_btn = GameHud.make_button("")
	_bgm_btn = GameHud.make_button("")
	_volume_btn = GameHud.make_button("")
	_exit_btn.icon = hud.ui_icon("close.png")
	_lb_btn.icon = hud.lb_icon()
	_restart_btn.icon = hud.restart_icon()
	_bgm_btn.icon = hud.bgm_icon()
	_volume_btn.icon = hud.volume_icon()
	for b: Button in [_lb_btn, _bgm_btn, _volume_btn, _restart_btn, _exit_btn]:
		_hbox.add_child(b)
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", 32)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	_lb_btn.pressed.connect(_on_lb)
	_restart_btn.pressed.connect(_restart)
	_bgm_btn.pressed.connect(_on_bgm)
	_volume_btn.pressed.connect(_on_volume)


# ===== 飘字 =====

## 指定位置弹出飘字（切换道具名等），上浮淡出后自毁
func _popup_at(pos: Vector2, text: String, col: Color) -> void:
	var m := minf(get_viewport_rect().size.x, get_viewport_rect().size.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)
	lb.add_theme_font_size_override("font_size", int(m * 0.038))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.2, m * 0.045 * 1.6)
	lb.position = pos - lb.size * 0.5
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.06, 0.8)
	tw.tween_property(lb, "modulate:a", 0.0, 0.8).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


## 屏中偏上大字提示
func _popup(text: String, col: Color) -> void:
	var vp := get_viewport_rect().size
	var m := minf(vp.x, vp.y)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 10)
	lb.add_theme_font_size_override("font_size", int(m * 0.06))
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.size = Vector2(m * 0.6, m * 0.06 * 1.5)
	lb.position = Vector2(vp.x * 0.5 - lb.size.x * 0.5, vp.y * 0.30)
	add_child(lb)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y - m * 0.04, 1.0)
	tw.tween_property(lb, "modulate:a", 0.0, 1.0).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(lb.queue_free)


# ===== 投掷物 =====

class Toss extends Node2D:
	var spr: Sprite2D

	func _init(tex: Texture2D, s: float) -> void:
		spr = Sprite2D.new()
		spr.texture = tex
		spr.scale = Vector2.ONE * s
		add_child(spr)

	func fly(from: Vector2, to: Vector2, h: float, dur: float, spin: float, done: Callable) -> void:
		position = from
		var ctrl := (from + to) * 0.5 - Vector2(0.0, h)
		var step := func(t: float) -> void:
			var a: Vector2 = from.lerp(ctrl, t)
			var b: Vector2 = ctrl.lerp(to, t)
			position = a.lerp(b, t)
		var tw := create_tween()
		tw.tween_method(step, 0.0, 1.0, dur)
		tw.parallel().tween_property(spr, "rotation", spin, dur)
		tw.tween_callback(func() -> void:
			if done.is_valid():
				done.call(to)
			queue_free())


# ===== 音效（程序合成：正弦/方波滑音 + 低通噪声，与合集其他游戏同套）=====

func _tone(f0: float, f1: float, dur: float, square: bool, vol: float) -> PackedByteArray:
	var rate := 22050
	var n := maxi(1, int(dur * rate))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(n)
		phase += TAU * lerpf(f0, f1, t) / rate
		var s := (1.0 if fmod(phase, TAU) < PI else -1.0) if square else sin(phase)
		var env := (1.0 - t) * (1.0 - t)
		bytes.encode_s16(i * 2, int(clampf(s * env * vol, -1.0, 1.0) * 32000))
	return bytes


func _noise(dur: float, vol: float, lp: float) -> PackedByteArray:
	var rate := 22050
	var n := maxi(1, int(dur * rate))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var acc := 0.0
	for i in n:
		var t := float(i) / float(n)
		acc = lerpf(acc, randf_range(-1.0, 1.0), 1.0 / maxf(lp, 1.0))   # 简单一阶低通
		var env := (1.0 - t) * (1.0 - t)
		bytes.encode_s16(i * 2, int(clampf(acc * env * vol, -1.0, 1.0) * 32000))
	return bytes


## parts 元素：["t", f0, f1, dur, square, vol] 音调 / ["n", dur, vol, lp] 噪声
func _sfx_stream(parts: Array) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = 22050
	var all := PackedByteArray()
	for p: Array in parts:
		if p[0] == "t":
			all.append_array(_tone(p[1], p[2], p[3], p[4], p[5]))
		else:
			all.append_array(_noise(p[1], p[2], p[3]))
	st.data = all
	return st


func _init_sfx() -> void:
	_sfx["splat"] = _sfx_stream([["n", 0.12, 0.55, 2.0], ["t", 160.0, 60.0, 0.10, false, 0.5]])   # 蛋/彩弹砸糊
	_sfx["shot"] = _sfx_stream([["n", 0.05, 0.5, 1.2]])                        # 机关枪点射
	_sfx["boom"] = _sfx_stream([["n", 0.30, 0.8, 1.5], ["t", 120.0, 40.0, 0.25, false, 0.8]])   # 爆炸
	_sfx["thud"] = _sfx_stream([["t", 200.0, 90.0, 0.08, true, 0.5]])          # 砸击闷响
	_sfx["flame"] = _sfx_stream([["n", 0.28, 0.5, 3.5], ["t", 220.0, 90.0, 0.22, false, 0.3]])   # 喷火团（呼啸）
	_sfx["laser"] = _sfx_stream([["t", 1400.0, 1000.0, 0.09, true, 0.12]])     # 激光（文件加载失败时的兜底）
	_sfx["spray"] = _sfx_stream([["n", 0.22, 0.4, 10.0]])                      # 涂鸦喷雾
	_sfx["washer"] = _sfx_stream([["n", 0.28, 0.5, 4.0]])                      # 高压水
	_sfx["sponge"] = _sfx_stream([["t", 700.0, 1050.0, 0.10, false, 0.18]])    # 海绵擦拭
	_sfx["stamp"] = _sfx_stream([["t", 180.0, 80.0, 0.10, false, 0.5]])        # 盖章
	_sfx["bark"] = _sfx_stream([["t", 420.0, 300.0, 0.09, true, 0.4], ["t", 380.0, 260.0, 0.12, true, 0.4]])   # 狗叫
	_sfx["throw"] = _sfx_stream([["n", 0.15, 0.25, 3.0]])                      # 投掷风声
	_sfx["drip"] = _sfx_stream([["t", 600.0, 300.0, 0.08, false, 0.25]])       # 墨滴
	_sfx["select"] = _sfx_stream([["t", 500.0, 750.0, 0.09, false, 0.3]])      # 轮盘选道具
	# 电锯/激光用真实录音（Mixkit 免费授权）：电锯=循环播放（按住播、松开停），激光=单发重触发
	for base: String in ["res://games/desk_wreck/assets/sfx/saw.mp3", "res://assets/sfx/saw.mp3"]:
		var sf := FileAccess.open(base, FileAccess.READ)
		if sf != null:
			var st := AudioStreamMP3.load_from_buffer(sf.get_buffer(sf.get_length()))
			st.loop = true
			var p := AudioStreamPlayer.new()
			p.stream = st
			p.volume_db = SFX_DB - 3.0
			add_child(p)
			_sfx_loop["saw"] = p
			break
	for base: String in ["res://games/desk_wreck/assets/sfx/laser.mp3", "res://assets/sfx/laser.mp3"]:
		var lf := FileAccess.open(base, FileAccess.READ)
		if lf != null:
			_sfx["laser"] = AudioStreamMP3.load_from_buffer(lf.get_buffer(lf.get_length()))
			break
	# 真实狗叫录音（Mixkit 免费授权）3 变体：小狗放置与行走期间随机播放，读取失败回退合成音
	for i in 3:
		for base: String in ["res://games/desk_wreck/assets/sfx/dog%d.mp3" % (i + 1), "res://assets/sfx/dog%d.mp3" % (i + 1)]:
			var df := FileAccess.open(base, FileAccess.READ)
			if df != null:
				var dst := AudioStreamMP3.load_from_buffer(df.get_buffer(df.get_length()))
				if dst != null:
					_sfx["bark%d" % (i + 1)] = dst
				break
	for i in SFX_POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_players.append(p)
	# BGM：低音量循环（读取失败则无 BGM，不影响玩法）
	for base: String in ["res://games/desk_wreck/assets/sfx/bgm.mp3", "res://assets/sfx/bgm.mp3"]:
		var bf := FileAccess.open(base, FileAccess.READ)
		if bf != null:
			var st := AudioStreamMP3.load_from_buffer(bf.get_buffer(bf.get_length()))
			st.loop = true
			_bgm = AudioStreamPlayer.new()
			_bgm.stream = st
			_bgm.volume_db = BGM_DB
			add_child(_bgm)
			if hud.bgm_on:
				_bgm.play()
			break


## 播放音效：从池中取空闲播放器（volume_db 负值降低音量）
func _play_sfx(sfx_name: String, volume_db: float = 0.0) -> void:
	if not _sfx.has(sfx_name):
		return
	for p: AudioStreamPlayer in _sfx_players:
		if not p.playing:
			p.stream = _sfx[sfx_name]
			p.volume_db = volume_db + SFX_DB
			p.play()
			return


## 随机变体音效：探测 <base>1..<base>8 变体键（真实录音），有则随机播一个，否则回退基础合成音
func _play_sfx_rand(sfx_base: String, volume_db: float = 0.0) -> void:
	var keys: Array[String] = []
	for i in 8:
		var k := "%s%d" % [sfx_base, i + 1]
		if _sfx.has(k):
			keys.append(k)
	_play_sfx(sfx_base if keys.is_empty() else keys[randi() % keys.size()], volume_db)
