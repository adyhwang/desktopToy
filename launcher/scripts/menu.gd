extends Control
## 启动界面（M2）：屏幕正中主 Banner 图 + 下方水平游戏 Logo 列（hover 显示游戏名）
## 右上按钮排：Option（设置面板：音量/背景音/自定义背景/语言）/ About / Exit
## 设置与关于面板为自绘 Control（深色底白字 + 模态遮罩），不用 AcceptDialog/OptionButton/
## ColorPickerButton 等窗口类：无边框 always-on-top 全屏主窗下子窗口栈不可靠（文字不显示、
## 下拉被面板遮挡），自绘面板与游戏内排行榜同套绘制路径，稳定可控
## 全部文案经 L10n 取词（英文兜底），语言切换实时重刷；游戏名动态读各游戏语言文件 game.name

signal game_selected(info: Dictionary)

const BANNER_H_RATIO := 0.42   # Banner 显示高度 = 视口高 × 此值（保持宽高比）
const MENU_CENTER_Y := 0.44    # Banner 中心 y / 视口高（整体上移偏正中）
const ICONS_GAP := 0.06        # Logo 行顶部 = Banner 底部下方 视口高 × 此值
const CARD_FALL_RATIO := 0.5   # 卡片初始估算下落起点（视口高 × 此值，_place_card 会精确校正为 Banner 顶）
const CARD_FALL_TIME := 0.5    # 入场下落时长（TRANS_BOUNCE 落地弹跳，0.5s 后入位）
const CARD_FADE_TIME := 0.3    # 淡入时长（全透明 → 0.3s 后不透明）
const CARD_CASCADE := 0.05     # 相邻卡片入场错开间隔
const CARD_Z := 20             # 动画期间卡片 z：浮于 Banner 之上（结束恢复 0）

const CFG_PATH := "user://settings.cfg"
const FILLS := ["stretch", "tile", "center", "fit", "cover"]
const FILL_KEYS := ["opt.fill_stretch", "opt.fill_tile", "opt.fill_center", "opt.fill_fit", "opt.fill_cover"]
const BG_COLORS := [   # 自定义背景预设纯色（替代 ColorPickerButton 弹窗）
	Color(0.12, 0.14, 0.16), Color(0.05, 0.05, 0.07), Color(0.94, 0.94, 0.94), Color(0.90, 0.86, 0.76),
	Color(0.20, 0.42, 0.75), Color(0.20, 0.68, 0.72), Color(0.25, 0.62, 0.35), Color(0.92, 0.76, 0.25),
	Color(0.90, 0.52, 0.18), Color(0.80, 0.22, 0.18), Color(0.52, 0.32, 0.75), Color(0.88, 0.48, 0.66),
]

@onready var _banner: TextureRect = $Banner
@onready var _empty_hint: Label = $EmptyHint
@onready var _icons: HFlowContainer = $IconsScroll/Icons
@onready var _icons_scroll: ScrollContainer = $IconsScroll
@onready var _option_btn: Button = $Banner/BannerActions/OptionBtn
@onready var _about_btn: Button = $Banner/BannerActions/AboutBtn
@onready var _exit_btn: Button = $Banner/BannerActions/ExitBtn

var _about_layer: Control      # 关于面板（懒创建，复用）
var _option_layer: Control     # 设置面板（懒创建，复用）
var _i18n_nodes: Array = []    # 面板内需随语言刷新的 [Control, key, fallback] 列表
# 设置面板控件引用（懒创建后缓存）
var _vol_slider: HSlider
var _vol_pct: Label
var _bgm_check: CheckBox
var _bg_enable: CheckBox
var _bg_body: VBoxContainer
var _mode_btns: Array = []     # 背景 [图片/纯色] 切换按钮组
var _img_row: HBoxContainer
var _color_row: HBoxContainer
var _bg_img_btn: Button        # 选择图片按钮
var _bg_img_name: Label        # 当前图片文件名
var _color_btns: Array = []    # 预设色板按钮组
var _fill_btns: Array = []     # 填充方式按钮组
var _lang_btns: Array = []     # 语言按钮组
var _panel: PanelContainer     # 设置面板主体（语言切换后重新居中用）
# 选图文件浏览器（自绘，替代 FileDialog：原生窗口/嵌入弹层在无边框置顶主窗下层级不可靠）
var _fp_layer: Control
var _fp_dir := ""              # 当前目录（空串=Windows 驱动器列表模式）
var _fp_last_dir := ""         # 上次浏览目录（下次打开回位）
var _fp_path_lbl: Label
var _fp_list: ItemList
var _card_ids := {}             # 已建卡游戏 id（game_ready 增量触发，去重防重复建卡）

const FP_EXTS := ["png", "jpg", "jpeg", "webp", "bmp"]


func _ready() -> void:
	get_viewport().size_changed.connect(_layout)
	# 卡片入场动画要飞出容器顶（到 Banner 顶部），关闭滚动区裁剪，否则下落段被裁掉不可见
	_icons_scroll.clip_contents = false
	for info in GameManager.games:
		_add_card(info, false)
	# 空态提示延后到扫描结束判定（加载进行中不闪 "No games"）
	_empty_hint.visible = false
	GameManager.events().game_ready.connect(_on_game_ready)
	GameManager.events().all_done.connect(_on_all_done)
	_option_btn.pressed.connect(_show_options)
	if OS.has_feature("web"):
		# Web：Option 窗口（音量/截图等桌面配置）、退出按钮无意义，隐藏入口
		_option_btn.visible = false
		_exit_btn.visible = false
	_about_btn.pressed.connect(_show_about)
	_exit_btn.pressed.connect(get_tree().quit)
	for b: Button in [_option_btn, _about_btn, _exit_btn]:
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.text = L10n.t({ _option_btn: "menu.option", _about_btn: "menu.about", _exit_btn: "menu.exit" }[b], String(b.text))
	_empty_hint.text = L10n.t("menu.empty", "No games · Drop .pck in games folder")
	L10n.language_changed.connect(_on_language_changed)
	_layout()


func _exit_tree() -> void:
	GameManager.events().game_ready.disconnect(_on_game_ready)
	GameManager.events().all_done.disconnect(_on_all_done)


func _on_game_ready(info: Dictionary) -> void:
	_add_card(info, true)


## 扫描结束仍无游戏才显示空态提示
func _on_all_done() -> void:
	_empty_hint.visible = GameManager.games.is_empty()
	_icons.visible = not GameManager.games.is_empty()


## 增量建卡：animated=true 时经 wrapper 做"从天而降"入场——卡片图层浮于 Banner 之上，
## 从 Banner 顶部下落（全透明 → 0.3s 不透明，0.5s 落位弹跳）
## （HFlowContainer 会接管子节点 position，卡片动画须包一层普通 Control 才自由）
func _add_card(info: Dictionary, animated: bool) -> void:
	var id := String(info.id)
	if _card_ids.has(id):
		return
	_card_ids[id] = true
	var card := GameCard.new_card(info)
	card.set_meta("info", info)
	card.tooltip_text = _game_name(info)
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND   # 悬停切手型指针
	card.activated.connect(game_selected.emit)
	if _card_ids.size() == 1:
		_empty_hint.visible = false
		_icons.visible = true
	if not animated:
		_icons.add_child(card)
		return
	var wrapper := Control.new()
	wrapper.custom_minimum_size = Vector2(GameCard.SIZE, GameCard.SIZE)
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.add_child(card)
	# 手动定尺寸（不用 anchors：容器首帧 resize 会重置 anchored 子节点 position，破坏入场动画）
	card.size = Vector2(GameCard.SIZE, GameCard.SIZE)
	_icons.add_child(wrapper)
	# 初始态：悬在 Banner 顶上方（精确起点在动画启动那刻由 _place_card 校正——
	# wrapper 此刻尚未被容器布局，全局坐标还不可用），全透明，浮于 Banner 之上
	var vp := get_viewport_rect().size
	card.position.y = -vp.y * CARD_FALL_RATIO
	card.modulate.a = 0.0
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.z_index = CARD_Z
	# 从天而降：级联间隔 → 落点校正 → 下落 0.5s 弹跳入位，同时 0.3s 淡入
	var tw := create_tween()
	tw.tween_interval(CARD_CASCADE * (_card_ids.size() - 1))
	tw.tween_callback(_place_card.bind(card, wrapper))
	tw.tween_property(card, "position:y", 0.0, CARD_FALL_TIME) \
			.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(card, "modulate:a", 1.0, CARD_FADE_TIME)
	tw.tween_callback(_finish_card_anim.bind(card))


## 动画启动那刻校正下落起点：Banner 顶部（视口系）- wrapper 顶部（视口系）
## = 卡片相对 wrapper 的局部起点 y，此刻容器布局已稳定
func _place_card(card: GameCard, wrapper: Control) -> void:
	if not is_instance_valid(card) or not is_instance_valid(wrapper):
		return
	card.position.y = _banner.global_position.y - wrapper.global_position.y
	card.modulate.a = 0.0


func _finish_card_anim(card: GameCard) -> void:
	if is_instance_valid(card):
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.position = Vector2.ZERO
		card.modulate.a = 1.0
		card.z_index = 0


func _game_name(info: Dictionary) -> String:
	var id := String(info.id)
	var v := _read_game_name(id, L10n.language)
	if v.is_empty() and L10n.language != "en":
		v = _read_game_name(id, "en")   # 当前语言缺失时回落英文
	return v if not v.is_empty() else String(info.name)   # 最后回落 manifest 名


## 游戏本地化名：游戏自己的语言文件 "game.name" 键
## 读取顺序：exe旁 games/<id>/<code>.json → 包内 res://games/<id>/language/<code>.json
func _read_game_name(id: String, code: String) -> String:
	var exe := OS.get_executable_path().get_base_dir()
	for p: String in [
		exe.path_join("games/%s/%s.json" % [id, code]),
		"res://games/%s/language/%s.json" % [id, code],
	]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var data: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if data is Dictionary and data.has("game.name"):
			return String(data["game.name"])
	return ""


## 语言切换实时刷新：按钮/提示/卡片提示/打开中的设置面板就地重刷；关于面板销毁待重建
func _on_language_changed() -> void:
	_option_btn.text = L10n.t("menu.option", "Option")
	_about_btn.text = L10n.t("menu.about", "About")
	_exit_btn.text = L10n.t("menu.exit", "Exit")
	_empty_hint.text = L10n.t("menu.empty", "No games · Drop .pck in games folder")
	for child in _icons.get_children():
		var card := child as GameCard
		if card == null and child.get_child_count() > 0:
			card = child.get_child(0) as GameCard   # 入场动画卡片包在 wrapper 里
		if card != null:
			card.tooltip_text = _game_name(card.get_meta("info"))
	if _about_layer != null:
		_about_layer.queue_free()
		_about_layer = null
	if _option_layer != null and _option_layer.visible:
		_refresh_option_texts()


# ===== 面板通用样式（深色底白字，选中金色；与游戏排行榜同风格）=====

const COL_PANEL := Color(0.16, 0.19, 0.18, 0.96)
const COL_ROW := Color(0.22, 0.26, 0.25)
const COL_ROW_SEL := Color(0.30, 0.34, 0.32)
const COL_GOLD := Color(1.0, 0.85, 0.25)


## 模态遮罩层：全屏深色半透明，点击空白处关闭
func _make_overlay() -> Control:
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			layer.visible = false)
	layer.add_child(dim)
	return layer


## 面板主体：居中深色圆角容器（调用方 add_child 后调 _center_panel）
func _make_panel(layer: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(26)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	return panel


func _center_panel(panel: PanelContainer) -> void:
	panel.reset_size()
	var vp: Vector2 = get_viewport_rect().size
	panel.position = ((vp - panel.size) / 2.0).floor()


## 行标签（白字，右侧内容对齐）：返回标签并把 [node, key, fallback] 登记进刷新表
func _row_label(txt: String, key: String, fallback: String, w := 150.0) -> Label:
	var lb := Label.new()
	lb.text = L10n.t(key, fallback)
	lb.custom_minimum_size = Vector2(w, 0.0)
	lb.add_theme_color_override("font_color", Color.WHITE)
	_i18n_nodes.append([lb, key, fallback])
	return lb


## 平铺切换按钮（替代 OptionButton 下拉）：toggle 模式，选中金边金字
func _toggle_btn(txt: String, tooltip := "") -> Button:
	var b := Button.new()
	b.text = txt
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if tooltip != "":
		b.tooltip_text = tooltip
	_apply_btn_style(b, false)
	return b


func _apply_btn_style(b: Button, sel: bool) -> void:
	for st in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = COL_ROW_SEL if sel else COL_ROW
		if st == "hover" and not sel:
			sb.bg_color = COL_ROW_SEL
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 4
		sb.content_margin_bottom = 6
		if sel:
			sb.set_border_width_all(2)
			sb.border_color = COL_GOLD
		b.add_theme_stylebox_override(st, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var col := COL_GOLD if sel else Color.WHITE
	for c in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color"]:
		b.add_theme_color_override(c, col)


## 按钮组选中态刷新
func _mark_selected(btns: Array, idx: int) -> void:
	for i in btns.size():
		var b: Button = btns[i]
		b.set_pressed_no_signal(i == idx)
		_apply_btn_style(b, i == idx)


## 复选框统一样式（白字）
func _style_check(c: CheckBox, txt: String, key: String, fallback: String) -> void:
	c.text = L10n.t(key, fallback)
	c.add_theme_color_override("font_color", Color.WHITE)
	c.add_theme_color_override("font_hover_color", Color.WHITE)
	c.add_theme_color_override("font_pressed_color", Color.WHITE)
	_i18n_nodes.append([c, key, fallback])


# ===== 关于面板 =====

func _show_about() -> void:
	if _about_layer == null:
		_about_layer = _make_overlay()
		var panel := _make_panel(_about_layer)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 10)
		panel.add_child(vb)
		var title := Label.new()
		title.text = L10n.t("dlg.about_title", "About")
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 24)
		title.add_theme_color_override("font_color", COL_GOLD)
		vb.add_child(title)
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.fit_content = true
		rt.custom_minimum_size = Vector2(320.0, 0.0)
		rt.add_theme_color_override("default_color", Color.WHITE)
		rt.text = "desktopToy · v0.1\nby adyhwang \n[url=https://adyhwang.github.io/demo/]https://adyhwang.github.io/demo/[/url]"
		rt.meta_clicked.connect(func(meta: Variant) -> void: OS.shell_open(String(meta)))
		vb.add_child(rt)
		for info in GameManager.games:   # 游戏列表：小图标 + 本地化名
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			var icon := TextureRect.new()
			icon.texture = GameCard._load_icon(info)
			icon.custom_minimum_size = Vector2(18.0, 18.0)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(icon)
			var lbl := Label.new()
			lbl.text = _game_name(info)
			lbl.add_theme_color_override("font_color", Color.WHITE)
			row.add_child(lbl)
			vb.add_child(row)
		vb.add_child(_close_btn(_about_layer))
		add_child(_about_layer)
		_center_panel(panel)
	_about_layer.visible = true


## 面板底部关闭按钮（居中）
func _close_btn(layer: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var b := Button.new()
	b.text = L10n.t("dlg.close", "Close")
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_apply_btn_style(b, false)
	b.pressed.connect(func() -> void: layer.visible = false)
	row.add_child(b)
	return row


# ===== 设置面板（Option）=====

func _show_options() -> void:
	if _option_layer == null:
		_build_option_layer()
	_sync_options_ui()
	_option_layer.visible = true


func _build_option_layer() -> void:
	_option_layer = _make_overlay()
	_panel = _make_panel(_option_layer)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.custom_minimum_size = Vector2(470.0, 0.0)
	_panel.add_child(vb)
	var title := Label.new()
	title.text = L10n.t("opt.title", "Options")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COL_GOLD)
	_i18n_nodes.append([title, "opt.title", "Options"])
	vb.add_child(title)

	# 音量：滑杆 0-100，实时生效（写 settings.cfg [audio] volume，与游戏共用）
	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 10)
	vol_row.add_child(_row_label(L10n.t("opt.volume", "Volume"), "opt.volume", "Volume"))
	_vol_slider = HSlider.new()
	_vol_slider.min_value = 0.0
	_vol_slider.max_value = 100.0
	_vol_slider.step = 5.0
	_vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vol_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_vol_slider.value_changed.connect(_on_volume_changed)
	vol_row.add_child(_vol_slider)
	_vol_pct = Label.new()
	_vol_pct.custom_minimum_size = Vector2(52.0, 0.0)
	_vol_pct.add_theme_color_override("font_color", COL_GOLD)
	vol_row.add_child(_vol_pct)
	vb.add_child(vol_row)

	# 背景音开关
	_bgm_check = CheckBox.new()
	_style_check(_bgm_check, "", "opt.bgm", "Background music")
	_bgm_check.toggled.connect(_on_bgm_toggled)
	vb.add_child(_bgm_check)

	vb.add_child(HSeparator.new())

	# 自定义背景：勾选展开子面板（图片/纯色 + 填充方式，类系统桌面背景设置）
	_bg_enable = CheckBox.new()
	_style_check(_bg_enable, "", "opt.custom_bg", "Custom background")
	_bg_enable.toggled.connect(_on_bg_enable_toggled)
	vb.add_child(_bg_enable)
	_bg_body = VBoxContainer.new()
	_bg_body.add_theme_constant_override("separation", 8)
	vb.add_child(_bg_body)
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 10)
	mode_row.add_child(_row_label(L10n.t("opt.bg_mode", "Background mode"), "opt.bg_mode", "Background mode"))
	for i in 2:
		var txt: String = L10n.t("opt.bg_image", "Image") if i == 0 else L10n.t("opt.bg_color", "Solid color")
		var b := _toggle_btn(txt)
		b.pressed.connect(_on_mode_btn.bind(i))
		_i18n_nodes.append([b, "opt.bg_image" if i == 0 else "opt.bg_color", "Image" if i == 0 else "Solid color"])
		_mode_btns.append(b)
		mode_row.add_child(b)
	_bg_body.add_child(mode_row)
	var img_row := HBoxContainer.new()
	img_row.add_theme_constant_override("separation", 10)
	_img_row = img_row
	_bg_img_btn = Button.new()
	_bg_img_btn.text = L10n.t("opt.bg_choose_image", "Choose image...")
	_bg_img_btn.focus_mode = Control.FOCUS_NONE
	_bg_img_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_apply_btn_style(_bg_img_btn, false)
	_bg_img_btn.pressed.connect(_on_pick_image)
	img_row.add_child(_bg_img_btn)
	_i18n_nodes.append([_bg_img_btn, "opt.bg_choose_image", "Choose image..."])
	_bg_img_name = Label.new()
	_bg_img_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bg_img_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_bg_img_name.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	img_row.add_child(_bg_img_name)
	_bg_body.add_child(img_row)
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 8)
	_color_row = color_row
	color_row.add_child(_row_label(L10n.t("opt.bg_color", "Solid color"), "opt.bg_color", "Solid color"))
	for col: Color in BG_COLORS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(26.0, 26.0)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.pressed.connect(_on_color_btn.bind(col))
		_color_btns.append(b)
		color_row.add_child(b)
	_bg_body.add_child(color_row)
	var fill_row := HBoxContainer.new()
	fill_row.add_theme_constant_override("separation", 8)
	fill_row.add_child(_row_label(L10n.t("opt.bg_fill", "Fill"), "opt.bg_fill", "Fill"))
	for i in FILL_KEYS.size():
		var b := _toggle_btn(L10n.t(FILL_KEYS[i], FILLS[i]))
		b.pressed.connect(_on_fill_btn.bind(i))
		_i18n_nodes.append([b, FILL_KEYS[i], FILLS[i]])
		_fill_btns.append(b)
		fill_row.add_child(b)
	_bg_body.add_child(fill_row)

	vb.add_child(HSeparator.new())

	# 语言：平铺按钮网格（4 列），当前语言金色高亮
	var lang_row := HBoxContainer.new()
	lang_row.add_theme_constant_override("separation", 10)
	lang_row.add_child(_row_label(L10n.t("opt.language", "Language"), "opt.language", "Language", 150.0))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	lang_row.add_child(grid)
	for code: String in L10n.available():
		var b := _toggle_btn(L10n.lang_display(code))
		b.set_meta("lang", code)
		b.pressed.connect(_on_lang_btn.bind(code))
		_lang_btns.append(b)
		grid.add_child(b)
	vb.add_child(lang_row)

	vb.add_child(_close_btn(_option_layer))
	add_child(_option_layer)


## 打开面板 / 语言切换后：从 settings.cfg 同步各控件状态与选中态，并重新居中
func _sync_options_ui() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		cf = null
	var vol := float(cf.get_value("audio", "volume", 1.0)) if cf != null else 1.0
	_vol_slider.set_value_no_signal(roundf(vol * 100.0))
	_vol_pct.text = "%d%%" % int(roundf(vol * 100.0))
	_bgm_check.set_pressed_no_signal(bool(cf.get_value("audio", "bgm_on", true)) if cf != null else true)
	var enabled := bool(cf.get_value("background", "enabled", false)) if cf != null else false
	_bg_enable.set_pressed_no_signal(enabled)
	_bg_body.visible = enabled
	var mode := String(cf.get_value("background", "mode", "image")) if cf != null else "image"
	_mark_selected(_mode_btns, 1 if mode == "color" else 0)
	_img_row.visible = mode != "color"
	_color_row.visible = mode == "color"
	_bg_img_name.text = String(cf.get_value("background", "image", "")).get_file() if cf != null else ""
	var cur_col: Color = cf.get_value("background", "color", Color(0.20, 0.42, 0.75)) if cf != null else Color(0.20, 0.42, 0.75)
	_mark_color(cur_col)
	var fill := String(cf.get_value("background", "fill", "cover")) if cf != null else "cover"
	_mark_selected(_fill_btns, maxi(FILLS.find(fill), 0))
	for i in _lang_btns.size():
		var b: Button = _lang_btns[i]
		_apply_btn_style(b, String(b.get_meta("lang")) == L10n.language)
		b.set_pressed_no_signal(String(b.get_meta("lang")) == L10n.language)
	_center_panel(_panel)


## 色板选中态：与当前颜色一致的色块金边（无完全一致时不标）
func _mark_color(cur: Color) -> void:
	for i in _color_btns.size():
		var b: Button = _color_btns[i]
		var sel := cur.is_equal_approx(BG_COLORS[i])
		var sb := StyleBoxFlat.new()
		sb.bg_color = BG_COLORS[i]
		sb.set_corner_radius_all(6)
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		sb.content_margin_left = 2
		sb.content_margin_right = 2
		if sel:
			sb.set_border_width_all(2)
			sb.border_color = COL_GOLD
		for st in ["normal", "hover", "pressed"]:
			b.add_theme_stylebox_override(st, sb)
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.set_pressed_no_signal(sel)


## 语言切换后就地刷新设置面板全部文案与选中态
func _refresh_option_texts() -> void:
	if _option_layer == null:
		return
	for entry: Array in _i18n_nodes:
		var n: Node = entry[0]
		if is_instance_valid(n):
			n.set("text", L10n.t(String(entry[1]), String(entry[2])))
	_sync_options_ui()


func _cfg_set(section: String, key: String, value: Variant) -> void:
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)
	cf.set_value(section, key, value)
	cf.save(CFG_PATH)


func _on_volume_changed(v: float) -> void:
	_vol_pct.text = "%d%%" % int(v)
	var vol := v / 100.0
	_cfg_set("audio", "volume", vol)
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(bus, vol <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(vol, 0.001)))


func _on_bgm_toggled(on: bool) -> void:
	_cfg_set("audio", "bgm_on", on)


func _on_bg_enable_toggled(on: bool) -> void:
	_bg_body.visible = on
	_cfg_set("background", "enabled", on)
	_apply_background()


func _on_mode_btn(i: int) -> void:
	_cfg_set("background", "mode", "color" if i == 1 else "image")
	_mark_selected(_mode_btns, i)
	_img_row.visible = i != 1
	_color_row.visible = i == 1
	_apply_background()


func _on_color_btn(col: Color) -> void:
	_cfg_set("background", "color", col)
	_cfg_set("background", "mode", "color")
	_mark_color(col)
	_mark_selected(_mode_btns, 1)
	_img_row.visible = false
	_color_row.visible = true
	_apply_background()


func _on_fill_btn(i: int) -> void:
	_cfg_set("background", "fill", FILLS[i])
	_mark_selected(_fill_btns, i)
	_apply_background()


## 选择图片：打开自绘文件浏览器（FileDialog 原生窗口/嵌入弹层在无边框置顶主窗下不可靠）
func _on_pick_image() -> void:
	if _fp_layer == null:
		_fp_build()
	# 初始目录：上次浏览 → 系统图片 → 系统桌面 → 根目录
	_fp_dir = _fp_last_dir
	if not DirAccess.dir_exists_absolute(_fp_dir):
		_fp_dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if not DirAccess.dir_exists_absolute(_fp_dir):
		_fp_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	if not DirAccess.dir_exists_absolute(_fp_dir):
		_fp_dir = "C:/" if OS.get_name() == "Windows" else "/"
	_fp_refresh()
	_fp_layer.visible = true


func _fp_build() -> void:
	_fp_layer = _make_overlay()
	var panel := _make_panel(_fp_layer)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.custom_minimum_size = Vector2(560.0, 0.0)
	panel.add_child(vb)
	var title := Label.new()
	title.text = L10n.t("opt.pick_title", "Choose background image")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COL_GOLD)
	_i18n_nodes.append([title, "opt.pick_title", "Choose background image"])
	vb.add_child(title)
	# 快捷目录行
	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 8)
	for q: Array in [
		[OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP), "opt.dir_desktop", "Desktop"],
		[OS.get_system_dir(OS.SYSTEM_DIR_PICTURES), "opt.dir_pictures", "Pictures"],
		["__drives__", "opt.dir_drives", "Drives"],
	]:
		var b := _toggle_btn(L10n.t(String(q[1]), String(q[2])))
		b.toggle_mode = false
		b.pressed.connect(_fp_quick.bind(String(q[0])))
		_i18n_nodes.append([b, String(q[1]), String(q[2])])
		quick.add_child(b)
	vb.add_child(quick)
	# 当前路径
	_fp_path_lbl = Label.new()
	_fp_path_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_fp_path_lbl.custom_minimum_size = Vector2(520.0, 0.0)
	_fp_path_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	vb.add_child(_fp_path_lbl)
	# 文件列表（双击进入目录 / 选择图片）
	_fp_list = ItemList.new()
	_fp_list.custom_minimum_size = Vector2(520.0, 320.0)
	_fp_list.item_activated.connect(_fp_activated)
	vb.add_child(_fp_list)
	# 底部：上级 + 提示 + 关闭
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	var up := _toggle_btn("..")
	up.toggle_mode = false
	up.tooltip_text = L10n.t("opt.pick_up", "Up")
	up.pressed.connect(_fp_go_up)
	_i18n_nodes.append([up, "opt.pick_up", "Up"])
	bottom.add_child(up)
	var hint := Label.new()
	hint.text = L10n.t("opt.pick_hint", "Double-click to open / pick")
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_i18n_nodes.append([hint, "opt.pick_hint", "Double-click to open / pick"])
	bottom.add_child(hint)
	var close := _toggle_btn(L10n.t("dlg.close", "Close"))
	close.toggle_mode = false
	close.pressed.connect(func() -> void: _fp_layer.visible = false)
	_i18n_nodes.append([close, "dlg.close", "Close"])
	bottom.add_child(close)
	vb.add_child(bottom)
	add_child(_fp_layer)


func _fp_quick(target: String) -> void:
	_fp_dir = "" if target == "__drives__" else target
	_fp_refresh()


func _fp_go_up() -> void:
	if _fp_dir.is_empty():
		return
	var base := _fp_dir.get_base_dir()
	if base == _fp_dir or base.is_empty():
		if OS.get_name() != "Windows":
			return   # 已到文件系统根
		_fp_dir = ""   # 已到盘根，切驱动器列表
	else:
		_fp_dir = base
	_fp_refresh()


## 列出当前目录（空串=Windows 驱动器列表）：文件夹金色在前、图片白色在后
func _fp_refresh() -> void:
	_fp_list.clear()
	_fp_path_lbl.text = L10n.t("opt.dir_drives", "Drives") if _fp_dir.is_empty() else _fp_dir
	var dirs: Array[String] = []
	var files: Array[String] = []
	if _fp_dir.is_empty():
		for i in 26:
			var drv: String = char(65 + i) + ":/"
			if DirAccess.dir_exists_absolute(drv):
				dirs.append(drv)
	else:
		var d := DirAccess.open(_fp_dir)
		if d != null:
			d.list_dir_begin()
			var f := d.get_next()
			while f != "":
				if d.current_is_dir():
					dirs.append(f)
				elif FP_EXTS.has(f.get_extension().to_lower()):
					files.append(f)
				f = d.get_next()
			d.list_dir_end()
	dirs.sort()
	files.sort()
	for x in dirs:
		_fp_list.add_item(x)
		var i := _fp_list.get_item_count() - 1
		_fp_list.set_item_custom_fg_color(i, COL_GOLD)
		_fp_list.set_item_metadata(i, x if _fp_dir.is_empty() else _fp_dir.path_join(x))
	for x in files:
		_fp_list.add_item(x)
		var i := _fp_list.get_item_count() - 1
		_fp_list.set_item_custom_fg_color(i, Color.WHITE)
		_fp_list.set_item_metadata(i, _fp_dir.path_join(x))


## 双击：进入文件夹 / 选中图片（回填设置面板并应用背景）
func _fp_activated(idx: int) -> void:
	var p := String(_fp_list.get_item_metadata(idx))
	if p.is_empty():
		return
	if DirAccess.dir_exists_absolute(p):
		_fp_dir = p
		_fp_refresh()
	elif FileAccess.file_exists(p):
		_fp_last_dir = _fp_dir
		_fp_layer.visible = false
		_on_image_selected(p)


func _on_image_selected(path: String) -> void:
	var ext := path.get_extension().to_lower()
	var dst := "user://custom_bg." + ext
	var src := FileAccess.open(path, FileAccess.READ)
	if src != null:
		var out := FileAccess.open(dst, FileAccess.WRITE)
		if out != null:
			out.store_buffer(src.get_buffer(src.get_length()))
			out.close()
		src.close()
	_cfg_set("background", "image", dst)
	_cfg_set("background", "mode", "image")
	_bg_img_name.text = dst.get_file()
	_mark_selected(_mode_btns, 0)
	_img_row.visible = true
	_color_row.visible = false
	_apply_background()


## 通知主程序应用背景设置（主程序在 launcher_main 组）
func _apply_background() -> void:
	var main := get_tree().get_first_node_in_group("launcher_main")
	if main != null and main.has_method("apply_background_settings"):
		main.apply_background_settings()


func _on_lang_btn(code: String) -> void:
	L10n.set_language(code)


func _layout() -> void:
	var vp := get_viewport_rect().size
	# Banner：屏幕正中，保持宽高比
	var bh := vp.y * BANNER_H_RATIO
	var bw := bh * 777.0 / 422.0
	if bw > vp.x * 0.9:  # 竖屏兜底：宽度不超视口 90%，高度跟随
		bw = vp.x * 0.9
		bh = bw * 422.0 / 777.0
	_banner.anchor_left = 0.5
	_banner.anchor_right = 0.5
	_banner.anchor_top = MENU_CENTER_Y
	_banner.anchor_bottom = MENU_CENTER_Y
	_banner.offset_left = -bw / 2.0
	_banner.offset_right = bw / 2.0
	_banner.offset_top = -bh / 2.0
	_banner.offset_bottom = bh / 2.0
	var center_y := vp.y * MENU_CENTER_Y
	var sc_y := center_y + bh / 2.0 + vp.y * ICONS_GAP
	# Logo 流式滚动区：全宽，Banner 下方到屏底；换行居中，内容超屏底时滚轮滚动（隐藏滚动条）
	_icons_scroll.anchor_left = 0.0
	_icons_scroll.anchor_right = 1.0
	_icons_scroll.anchor_top = 0.0
	_icons_scroll.anchor_bottom = 1.0
	_icons_scroll.offset_left = 0.0
	_icons_scroll.offset_right = 0.0
	_icons_scroll.offset_top = sc_y
	_icons_scroll.offset_bottom = 0.0
	# 空状态提示：全宽水平居中，Logo 行位置
	_empty_hint.anchor_left = 0.0
	_empty_hint.anchor_right = 1.0
	_empty_hint.offset_left = 0.0
	_empty_hint.offset_right = 0.0
	_empty_hint.offset_top = sc_y
	_empty_hint.offset_bottom = _empty_hint.offset_top + 40.0
