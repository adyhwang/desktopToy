extends RefCounted
## 通用 HUD 数据逻辑（打水漂版：双排行榜——打漂次数 + 距离，各 top10）
## 存档 user://settings.cfg：[highscores] <id>_skip/<id>_skip_top、<id>_dist/<id>_dist_top
## [audio] volume / bgm_on；[general] language

const CFG_PATH := "user://settings.cfg"
const VOLUME_STEPS := [1.0, 0.5, 0.0]   # 音量循环档位：100% → 50% → 静音
const TOP_N := 10                       # 排行榜容量

var game_id := ""
var scores_skip: Array = []     # 打漂次数榜（降序 top10）
var scores_dist: Array = []     # 距离榜（米，降序 top10）
var volume := 1.0
var bgm_on := true              # BGM 开关（独立于音量档位）
var lang := "en"                # 当前语言码（user://settings.cfg [general] language）
var _lang_cur: Dictionary = {}  # 合并后的当前语言字典（非英文时已先并入英文层兜底）


func _init(id: String) -> void:
	game_id = id
	_load()
	_load_lang()


func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		volume = float(cf.get_value("audio", "volume", 1.0))
		var sk: Variant = cf.get_value("highscores", game_id + "_skip_top", [])
		var di: Variant = cf.get_value("highscores", game_id + "_dist_top", [])
		scores_skip = sk if sk is Array else []
		scores_dist = di if di is Array else []
	bgm_on = bool(cf.get_value("audio", bgm_key(), true))
	apply_volume()


func bgm_key() -> String:
	return "bgm_on"


## —— 多语言：自包含加载链（不依赖启动器 autoload，各游戏包一份）——
## 合并优先级（后者覆盖前者）：
##   英文层：exe旁 games/_common/en.json → 包内 res://games/<id>/language/en.json → exe旁 games/<id>/en.json
##   当前语言层：同上三处 <code>.json（叠加在英文层之上）
func _load_lang() -> void:
	var code := "en"
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		code = String(cf.get_value("general", "language", "en"))
	if code.is_empty():
		code = "en"
	lang = code
	_lang_cur = {}
	for c: String in (["en", code] if code != "en" else ["en"]):
		for p: String in _lang_paths(c):
			var d := _read_json_dict(p)
			if not d.is_empty():
				_lang_cur.merge(d, true)


func _lang_paths(code: String) -> Array:
	var exe := OS.get_executable_path().get_base_dir()
	return [
		exe.path_join("games/_common/%s.json" % code),
		"res://games/%s/language/%s.json" % [game_id, code],
		exe.path_join("games/%s/%s.json" % [game_id, code]),
	]


func _read_json_dict(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


## 取译文：当前语言字典 → 代码内兜底文案
func t(key: String, fallback: String) -> String:
	var v: Variant = _lang_cur.get(key)
	return String(v) if v != null else fallback


## 本轮结束提交双榜：返回 {rank_s, rank_d, rec_s, rec_d}（名次 1 起；0=未入榜；rec=是否刷新纪录）
func commit_round(skips: int, dist: float) -> Dictionary:
	var res := {"rank_s": 0, "rank_d": 0, "rec_s": false, "rec_d": false}
	if skips > 0:
		var prev_best: int = scores_skip[0] if not scores_skip.is_empty() else 0
		res.rec_s = skips > prev_best
		scores_skip.append(skips)
		scores_skip.sort()
		scores_skip.reverse()
		if scores_skip.size() > TOP_N:
			scores_skip.resize(TOP_N)
		res.rank_s = scores_skip.find(skips) + 1
	if dist > 0.0:
		var prev_bd: float = scores_dist[0] if not scores_dist.is_empty() else 0.0
		res.rec_d = dist > prev_bd
		scores_dist.append(dist)
		scores_dist.sort()
		scores_dist.reverse()
		if scores_dist.size() > TOP_N:
			scores_dist.resize(TOP_N)
		res.rank_d = scores_dist.find(dist) + 1
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)
	cf.set_value("highscores", game_id + "_skip_top", scores_skip)
	cf.set_value("highscores", game_id + "_dist_top", scores_dist)
	cf.save(CFG_PATH)
	return res


func apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(bus, volume <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.001)))


## 循环音量档位并持久化，返回新音量
func cycle_volume() -> float:
	var i := VOLUME_STEPS.find(volume)
	volume = VOLUME_STEPS[(i + 1) % VOLUME_STEPS.size()] if i >= 0 else 1.0
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)
	cf.set_value("audio", "volume", volume)
	cf.save(CFG_PATH)
	apply_volume()
	return volume


## 切换 BGM 开关并持久化，返回新状态
func cycle_bgm() -> bool:
	bgm_on = not bgm_on
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)
	cf.set_value("audio", "bgm_on", bgm_on)
	cf.save(CFG_PATH)
	return bgm_on


## BGM 开关图标贴图：on/off
func bgm_icon() -> Texture2D:
	return ui_icon("musicOn.png" if bgm_on else "musicOff.png")


## 排行榜按钮图标贴图：奖杯
func lb_icon() -> Texture2D:
	return ui_icon("trophy.png")


## 重开按钮图标贴图：循环箭头
func restart_icon() -> Texture2D:
	return ui_icon("restart.png")


## 排行榜弹窗（模态深色面板，双榜并排：左=打漂次数 右=距离）
## cur_skips/cur_dist：本轮成绩（高亮对应名次行；>0 但未入榜时在"本轮成绩"行显示）
## 弹出时暂停游戏，面板 ALWAYS 不受影响；唯一按钮 Close（ESC 快捷键等效）
func show_leaderboard(parent: Node, cur_skips: int, cur_dist: float) -> void:
	var old := parent.get_node_or_null("LeaderboardPanel")
	if old != null:
		old.queue_free()
	var vp: Vector2 = parent.get_viewport().get_visible_rect().size
	var m := minf(vp.x, vp.y)
	var panel := PanelContainer.new()
	panel.name = "LeaderboardPanel"
	panel.process_mode = Node.PROCESS_MODE_ALWAYS   # 全局暂停时面板仍可响应点击
	panel.set_meta("parent", parent)   # 关闭时回调游戏节点
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.94)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.035)
	panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.014))
	panel.add_child(vb)
	var lb := Label.new()
	var title: String = t("ui.lb_title", "Leaderboard")
	lb.text = title
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(m * 0.048))
	_style_label(lb, Color.WHITE)
	vb.add_child(lb)
	# 双榜并排：左 次数 / 右 距离
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", int(m * 0.05))
	vb.add_child(cols)
	_fill_board(cols, t("ui.lb_skips", "Most Skips"), scores_skip, cur_skips, false)
	_fill_board(cols, t("ui.lb_dist", "Longest Distance"), scores_dist, cur_dist, true)
	# 本轮成绩行
	var cur := Label.new()
	if cur_skips > 0 or cur_dist > 0.0:
		cur.text = t("ui.round_result", "Round: %d skips · %.1f m") % [cur_skips, cur_dist]
		cur.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))
	else:
		cur.text = ""
	cur.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cur.add_theme_font_size_override("font_size", int(m * 0.030))
	_style_label(cur, Color(1.0, 0.85, 0.25))
	vb.add_child(cur)
	var row_box := HBoxContainer.new()
	row_box.alignment = BoxContainer.ALIGNMENT_CENTER
	row_box.add_theme_constant_override("separation", int(m * 0.03))
	vb.add_child(row_box)
	var cl := make_button(t("ui.close", "Close"))
	cl.pressed.connect(_close_lb.bind(panel))
	# ESC 快捷键关闭（面板 ALWAYS，暂停中仍生效）
	var sc := Shortcut.new()
	var kev := InputEventKey.new()
	kev.keycode = KEY_ESCAPE
	sc.events.append(kev)
	cl.shortcut_in_tooltip = false
	cl.shortcut = sc
	row_box.add_child(cl)
	parent.add_child(panel)
	panel.reset_size()
	panel.position = Vector2(vp.x / 2.0 - panel.size.x / 2.0, vp.y / 2.0 - panel.size.y / 2.0)
	for b: Button in row_box.get_children():
		b.add_theme_font_size_override("font_size", int(m * 0.032))
	parent.get_tree().paused = true   # 暂停游戏（面板 ALWAYS 不受影响，关闭时恢复）


## 单列榜单：title + top10（hot 值高亮所在名次；空表显示占位）
func _fill_board(cols: HBoxContainer, title: String, scores: Array, hot: float, is_dist: bool) -> void:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(4))
	cols.add_child(vb)
	var hd := Label.new()
	hd.text = title
	hd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hd.add_theme_font_size_override("font_size", 30)
	_style_label(hd, Color(0.55, 0.9, 0.95))
	vb.add_child(hd)
	if scores.is_empty():
		var empty := Label.new()
		empty.text = t("ui.records_empty", "No records yet")
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 26)
		_style_label(empty, Color(0.8, 0.8, 0.8))
		vb.add_child(empty)
	var shown := mini(scores.size(), TOP_N)
	for i in shown:
		var v: float = scores[i]
		var val: String = ("%.1f m" % v) if is_dist else str(int(v))
		var row := Label.new()
		row.text = "%d.  %s" % [i + 1, val]
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_theme_font_size_override("font_size", 27)
		var is_hot := hot > 0.0 and not scores.is_empty() and absf(scores[i] - hot) < 0.001
		_style_label(row, Color(1.0, 0.85, 0.25) if is_hot else Color.WHITE)
		vb.add_child(row)


static func _style_label(lb: Label, col: Color) -> void:
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)


static func _close_lb(p: Control) -> void:
	p.get_tree().paused = false   # 恢复游戏（Close 都会走到这里）
	if p.has_meta("parent"):
		var par: Node = p.get_meta("parent")
		if is_instance_valid(par) and par.has_method("on_leaderboard_closed"):
			par.on_leaderboard_closed()
	if is_instance_valid(p):
		p.queue_free()


## UI 图标贴图：assets/ui/ 下按文件名加载（pck 内 png 未走导入流程，字节解码；末条供编辑器预览）
func ui_icon(fname: String) -> Texture2D:
	for base in ["res://games/%s/assets/ui/" % game_id, "res://assets/ui/"]:
		var f := FileAccess.open(base + fname, FileAccess.READ)
		if f != null:
			var img := Image.new()
			if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
				return ImageTexture.create_from_image(img)
	return null


## 音量图标贴图：按当前档位返回 high/low/cross
func volume_icon() -> Texture2D:
	var name := "volumeHigh.png" if volume >= 0.99 else ("volumeLow.png" if volume >= 0.49 else "volumeCross.png")
	return ui_icon(name)


## 图标按钮统一样式：白字 + 黑色细描边、无背景（✕ / R / 音量共用）
static func style_button(b: Button) -> void:
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for col in ["font_color", "font_hover_color", "font_focus_color"]:
		b.add_theme_color_override(col, Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color(0.75, 0.75, 0.75))
	b.add_theme_color_override("font_outline_color", Color.BLACK)
	b.add_theme_constant_override("outline_size", 6)


## 图标按钮工厂：新建并套用统一样式
static func make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	style_button(b)
	return b
