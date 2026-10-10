extends RefCounted
## 通用 HUD 数据逻辑（各游戏包自包含一份，不用 class_name）：
## 排行榜 top10 持久化 / 连击计数 / 音量与 BGM 控制 / 排行榜弹窗
## 存档 user://settings.cfg：[highscores] <id>（最高分）+ <id>_top（top10 数组，旧档自动迁移）；[audio] volume / bgm_on

const CFG_PATH := "user://settings.cfg"
const VOLUME_STEPS := [1.0, 0.5, 0.0]   # 音量循环档位：100% → 50% → 静音
const TOP_N := 10                       # 排行榜容量

var game_id := ""
var max_score := 0
var last_score := 0             # 本局最新分数（submit_score 同步，commit_score 提交入榜）
var scores: Array = []          # 排行榜（降序 top10）
var _dirty := false             # 本局有分数待提交
var combo := 0
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
		max_score = int(cf.get_value("highscores", game_id, 0))
		volume = float(cf.get_value("audio", "volume", 1.0))
		var top: Variant = cf.get_value("highscores", game_id + "_top", [])
		scores = top if top is Array else []
		if scores.is_empty() and max_score > 0:
			scores = [max_score]   # 旧单值档迁移进排行榜
	bgm_on = bool(cf.get_value("audio", "bgm_on", true))
	apply_volume()


## —— 多语言：自包含加载链（不依赖启动器 autoload，各游戏包一份）——
## 合并优先级（后者覆盖前者）：
##   英文层：exe旁 games/_common/en.json → 包内 res://games/<id>/language/en.json → exe旁 games/<id>/en.json
##   当前语言层：同上三处 <code>.json（叠加在英文层之上）
## 编辑器/无头模式下 exe 旁路径不存在自动跳过；全部缺失时回落到代码内默认文案
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


## —— 开发者模式文案（内置，不进外置语言文件）：中文 = zh_CN/zh_TW，其他语言用英文 ——
const DEV_ZH := {
	"dev.life100": "生命 = 100",
	"dev.tip_life100": "生命设为 100",
	"dev.life_up": "生命 +1",
	"dev.tip_life_up": "增加 1 条生命",
	"dev.life_down": "生命 -1",
	"dev.tip_life_down": "减少 1 条生命",
	"dev.multi": "多球",
	"dev.tip_multi": "多球：每个球分裂成 3 个，各自独立运动、持续存在直到离开场地",
	"dev.pierce": "穿透球",
	"dev.tip_pierce": "穿透球：球穿过砖块不反弹，沿途击碎（持续 %d 秒）",
	"dev.fog": "迷雾",
	"dev.tip_fog": "迷雾：中央砖块区域被半透明灰色遮罩覆盖（持续 %d 秒）",
	"dev.invert": "反向操控",
	"dev.tip_invert": "反向操控：鼠标 X/Y 轴与挡板移动方向反转（持续 %d 秒）",
	"dev.clear_level": "清空关卡",
	"dev.tip_clear_level": "清空关卡：立即移除全部砖块并触发清场奖励",
	"dev.ball_speed": "球速",
	"dev.tip_ball_speed": "球速倍率（叠加在减速/加速球效果之上）",
	"dev.paddle_length": "挡板长度",
	"dev.tip_paddle_length": "挡板长度倍率（叠加在加长/缩短挡板效果之上）",
	"dev.drop_rate": "道具掉率",
	"dev.tip_drop_rate": "道具掉落率（砖块被击碎后掉落道具的概率）",
}

## 取译文：dev.* 走内置双语（中文查 DEV_ZH，非中文用代码内英文兜底，不读外置 json）；
## 其余：当前语言字典 → 代码内兜底文案
func t(key: String, fallback: String) -> String:
	if key.begins_with("dev."):
		if lang.begins_with("zh"):
			return String(DEV_ZH.get(key, fallback))
		return fallback
	var v: Variant = _lang_cur.get(key)
	return String(v) if v != null else fallback


## 计分后调用：刷新最高分并落盘（返回是否破纪录）
func submit_score(v: int) -> bool:
	last_score = v
	_dirty = true
	if v > max_score:
		max_score = v
		var cf := ConfigFile.new()
		cf.load(CFG_PATH)
		cf.set_value("highscores", game_id, max_score)
		cf.save(CFG_PATH)
		return true
	return false


## 本局结束提交分数入排行榜，返回名次（1 起；未入榜返回 0）
func commit_score() -> int:
	if not _dirty or last_score <= 0:
		return _rank_of(last_score)
	_dirty = false
	scores.append(last_score)
	scores.sort()
	scores.reverse()
	if scores.size() > TOP_N:
		scores.resize(TOP_N)
	max_score = scores[0]
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)
	cf.set_value("highscores", game_id + "_top", scores)
	cf.set_value("highscores", game_id, max_score)
	cf.save(CFG_PATH)
	return _rank_of(last_score)


## 分数当前名次（1 起，未入榜 0）
func _rank_of(v: int) -> int:
	return scores.find(v) + 1 if v > 0 else 0


## 成功事件：连击 +1，返回当前连击数
func on_success() -> int:
	combo += 1
	return combo


## 失败事件：连击清零
func on_fail() -> void:
	combo = 0


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


## 重开时清连击（最高分保留）
func reset_run() -> void:
	combo = 0


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


## 排行榜弹窗（模态深色面板，重复调用先关旧；弹出时暂停游戏，面板 ALWAYS 不受影响）
## title：面板标题；current/rank：本局分数与名次（rank>0 高亮该名次行；rank==0 且 current>0 时
## 尾行显示 "Your: xx" 表示未入榜；手动查看传 (-1, -1)）；lines 非空时按其逐行显示自定义
## 文本（替代分数列表，用于 dart 这类"按目标分存最少镖数"的特殊成绩体系）
## 唯一按钮 Close（ESC 快捷键等效）
func show_leaderboard(parent: Node, title: String, current: int, rank: int, lines: Array = []) -> void:
	var old := parent.get_node_or_null("LeaderboardPanel")
	if old != null:
		old.queue_free()
	var vp: Vector2 = parent.get_viewport().get_visible_rect().size
	var m := minf(vp.x, vp.y)
	var panel := PanelContainer.new()
	panel.name = "LeaderboardPanel"
	panel.process_mode = Node.PROCESS_MODE_ALWAYS   # 全局暂停时面板仍可响应点击
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.94)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(m * 0.035)
	panel.add_theme_stylebox_override("panel", sb)
	panel.z_index = 220   # 浮于游戏元素之上（飘字/提示/胜利弹窗），低于 DEV 窗口(250)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(m * 0.012))
	panel.add_child(vb)
	var lb := Label.new()
	lb.text = title
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", int(m * 0.05))
	_style_label(lb, Color.WHITE)
	vb.add_child(lb)
	if not lines.is_empty():
		for line: String in lines:   # 自定义行（特殊成绩体系）
			var row := Label.new()
			row.text = line
			row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			row.add_theme_font_size_override("font_size", int(m * 0.032))
			_style_label(row, Color.WHITE)
			vb.add_child(row)
	else:
		if scores.is_empty():
			var empty := Label.new()
			empty.text = t("ui.records_empty", "No records yet")
			empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			empty.add_theme_font_size_override("font_size", int(m * 0.032))
			_style_label(empty, Color(0.8, 0.8, 0.8))
			vb.add_child(empty)
		for i in scores.size():
			var row := Label.new()
			row.text = "%d.  %d" % [i + 1, scores[i]]
			row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			row.add_theme_font_size_override("font_size", int(m * 0.032))
			var hot := (i + 1) == rank   # 本局分数所在名次：金色高亮
			_style_label(row, Color(1.0, 0.85, 0.25) if hot else Color.WHITE)
			vb.add_child(row)
		if rank == 0 and current > 0:   # 本局有分但未入榜
			var tail := Label.new()
			tail.text = t("ui.your_score", "Your score: %d") % current
			tail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			tail.add_theme_font_size_override("font_size", int(m * 0.030))
			_style_label(tail, Color(1.0, 0.85, 0.25))
			vb.add_child(tail)
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
	panel.set_meta("parent", parent)   # 关闭时回调 parent.on_leaderboard_closed()（若存在）
	panel.reset_size()
	panel.position = Vector2(vp.x / 2.0 - panel.size.x / 2.0, vp.y / 2.0 - panel.size.y / 2.0)
	for b: Button in row_box.get_children():
		b.add_theme_font_size_override("font_size", int(m * 0.032))
	parent.get_tree().paused = true   # 暂停游戏（面板 ALWAYS 不受影响，关闭时恢复）


static func _style_label(lb: Label, col: Color) -> void:
	lb.add_theme_color_override("font_color", col)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", 8)


static func _close_lb(p: Control) -> void:
	p.get_tree().paused = false   # 恢复游戏（Replay/Back/Close 都会走到这里）
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
	b.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停中（排行榜/胜利弹窗）顶栏按钮仍可点
	style_button(b)
	return b
