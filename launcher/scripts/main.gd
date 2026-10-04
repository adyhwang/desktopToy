extends Node
## 主程序入口：截取桌面快照作背景（M1）→ 扫描游戏包 → 启动界面 / 游戏切换（M2）
## 项目以最小化启动（不遮挡桌面），启动时用引擎内置 screen_get_image 现场截主屏
## （Windows 走 GDI / Linux X11 走 XGetImage，Godot 4.2+，零外部依赖），截完进全屏
## ——双击主程序即玩，无需任何启动脚本；截屏失败（锁屏/Wayland 会话）降级纯色背景
## 注：快照会含本程序任务栏按钮，运行时被全屏窗口盖住，无视觉影响

const MENU_SCENE := "res://scenes/menu.tscn"
const CURSOR_SIZE := 24.0    # 自定义光标最长边显示尺寸（px，原图 128px 偏大，等比缩小；想调改这里）
const CURSOR_ARROW := "res://assets/ui/cursor/arrow.png"   # 默认箭头指针（热点=左上尖端）
const CURSOR_HAND := "res://assets/ui/cursor/link.png"     # 悬停按钮手型指针（热点=指尖）

@onready var _background: TextureRect = $Background
@onready var _background_color: ColorRect = $BackgroundColor
@onready var _game_host: Node = $GameHost

var _menu: Control = null
var _current_game: Node = null
var _desktop_tex: ImageTexture      # 启动时桌面快照（自定义背景关闭/恢复默认时透出）
var _bg_stretch_default := 0        # 场景原始填充方式（关闭自定义背景时还原）
var _spinner: Control               # 点击游戏后的旋转进度圈（不指示真实进度）
var _spin_t := 0.0                  # 进度圈旋转相位
var _loading := false               # 进游戏加载中（await 帧间隙防重复触发）
var _progress_lbl: PanelContainer   # 右下角加载/下载进度浮字（游戏内也可见，后台下载反馈）
var _progress_text: Label
var _progress_fade: Tween


func _ready() -> void:
	add_to_group("launcher_main")   # 供设置弹窗通知应用背景变更
	# 自定义鼠标指针：默认箭头 / 悬停按钮自动切手型（游戏包按钮 style_button 已设 POINTING_HAND；
	# dart 的 HIDDEN 隐藏指针模式与自定义指针独立，恢复 VISIBLE 后仍显示自定义图）
	_setup_cursor(CURSOR_ARROW, Input.CURSOR_ARROW, Vector2(4, 4))
	_setup_cursor(CURSOR_HAND, Input.CURSOR_POINTING_HAND, Vector2(46, 10))
	# 双保险：project.godot 已设初始位置屏幕外，这里再补一次（防个别窗口管理器把屏外窗口拉回工作区）
	DisplayServer.window_set_position(Vector2i(-32000, -32000), get_window().get_window_id())
	# 代码级显式最小化：Linux X11 下 project 的 minimized 启动 hint 不被 UKWM 处理，
	# 窗口会以无框黑窗显示且位置被钳制回 (0,0)（实测），必须代码置 iconic 才真正隐藏
	get_window().mode = Window.MODE_MINIMIZED
	# Linux 下多为软渲染（llvmpipe，且 V-Sync 不可用导致全速空转），限 30fps 减轻 CPU 负担防卡顿
	if OS.get_name() == "Linux":
		Engine.max_fps = 30
		print("[Main] Linux 软渲染环境，帧率上限 30fps")
	print("[Main] 窗口已最小化 pos=%s（防启动黑窗入镜）" % DisplayServer.window_get_position(get_window().get_window_id()))
	# 现场截屏：窗口全程最小化不遮挡桌面，快照干净；稍候片刻等窗口/任务栏/合成器稳定
	await get_tree().create_timer(0.3).timeout
	print("[Main] 截屏前窗口位置 pos=%s mode=%d" % [DisplayServer.window_get_position(get_window().get_window_id()), get_window().mode])
	var tex: ImageTexture = await ScreenCapture.capture()
	if tex == null:
		# 截屏失败降级：保留深色纯色背景，游戏功能不受影响
		push_warning("截屏失败，降级为纯色背景")
	_desktop_tex = tex
	_bg_stretch_default = _background.stretch_mode
	apply_background_settings()
	# 快照就绪，显示并进入全屏（多屏时固定主屏，与快照截取屏一致）
	get_window().show()
	DisplayServer.window_set_current_screen(0, get_window().get_window_id())
	get_window().mode = Window.MODE_FULLSCREEN
	get_window().grab_focus()
	await get_tree().process_frame
	print("[DPI] fullscreen window=%s canvas=%s screen=%s scale=%.2f" % [get_window().size,
		get_viewport().get_visible_rect().size,
		DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()),
		DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())])

	# 菜单先建（空态），扫描/下载后台进行：游戏逐个就绪即出卡片（game_ready→menu），
	# 右下角浮字显示加载/下载进度，全部就绪后自动淡出——期间即可点卡片进游戏
	GameManager.events().progress.connect(_on_load_progress)
	GameManager.events().all_done.connect(_on_load_done)
	_show_menu()
	GameManager.scan()


func _show_menu() -> void:
	if _menu != null:
		_menu.show()   # 菜单常驻：后台扫描期间新就绪的卡片已在其中
		return
	_menu = (load(MENU_SCENE) as PackedScene).instantiate()
	_menu.game_selected.connect(start_game)
	_game_host.add_child(_menu)


## 应用背景设置（设置弹窗实时调用）：自定义背景关闭时透出桌面快照（原行为）；
## 开启时按 mode 切图片/纯色，fill 映射 TextureRect 填充方式（拉伸/平铺/居中/适应/填充）
func apply_background_settings() -> void:
	var cf := ConfigFile.new()
	var enabled := cf.load("user://settings.cfg") == OK \
			and bool(cf.get_value("background", "enabled", false))
	if not enabled:
		_background.stretch_mode = _bg_stretch_default
		_background.texture = _desktop_tex
		# 无快照（web 无截屏/截屏失败）时兜底纯色：与设置色板默认一致（场景近黑底色不可见）
		_background_color.visible = _desktop_tex == null
		if _desktop_tex == null:
			_background_color.color = Color(0.20, 0.42, 0.75)
		return
	_background.stretch_mode = _fill_stretch(String(cf.get_value("background", "fill", "cover")))
	var tex: Texture2D = null
	if String(cf.get_value("background", "mode", "image")) == "image":
		var path := String(cf.get_value("background", "image", ""))
		if path != "":
			tex = GameCard._load_raw_image(path)
			if tex == null:
				push_warning("自定义背景图失效: %s" % path)
	if tex != null:
		_background.texture = tex
		_background_color.visible = false
	else:
		# 纯色模式或图片失效：回退纯色（未设色时用色板蓝色兜底，不用近黑色）
		_background.texture = null
		_background_color.color = cf.get_value("background", "color", Color(0.20, 0.42, 0.75))
		_background_color.visible = true


## 填充方式 → TextureRect.stretch_mode
func _fill_stretch(fill: String) -> int:
	match fill:
		"stretch":
			return TextureRect.STRETCH_SCALE
		"tile":
			return TextureRect.STRETCH_TILE
		"center":
			return TextureRect.STRETCH_KEEP_CENTERED
		"fit":
			return TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_:
			return TextureRect.STRETCH_KEEP_ASPECT_COVERED


## 自定义光标加载：原图等比缩放到 CURSOR_SIZE（hotspot 为原图像素坐标，按缩放比换算）
func _setup_cursor(path: String, shape: Input.CursorShape, src_hotspot: Vector2) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) != OK:
		return
	var sc := CURSOR_SIZE / maxf(img.get_width(), img.get_height())
	img.resize(maxi(1, int(img.get_width() * sc)), maxi(1, int(img.get_height() * sc)), Image.INTERPOLATE_LANCZOS)
	Input.set_custom_mouse_cursor(ImageTexture.create_from_image(img), shape, src_hotspot * sc)


func start_game(info: Dictionary) -> void:
	if _current_game != null or _loading:
		return
	print("[Main] 启动游戏: %s" % info.id)
	_loading = true
	# 先弹进度圈并画出一帧，再执行可能卡帧的场景构建/资源烘焙（如 desk_wreck 痕迹烘焙）
	_show_spinner(true)
	if _menu != null:
		_menu.hide()   # 菜单常驻不销毁：后台扫描/下载继续建卡，退出游戏即见全部游戏
	await get_tree().process_frame
	await get_tree().process_frame
	var packed: PackedScene = load(info.entry)
	if packed == null:
		push_error("游戏入口场景加载失败: %s" % info.entry)
		_loading = false
		_show_spinner(false)
		_show_menu()
		return
	_current_game = packed.instantiate()
	_game_host.add_child(_current_game)
	print("[Main] 游戏场景已挂载: %s (子节点 %d 个)" % [info.id, _current_game.get_child_count()])
	if _current_game.has_signal("exit_requested"):
		_current_game.exit_requested.connect(stop_game)
	if _current_game.has_method("start"):
		_current_game.start()
	_loading = false
	_show_spinner(false)


## 进度圈：全屏半透明压暗底 + 白色旋转圆弧；MOUSE_FILTER_STOP 挡住加载期间的点击
func _show_spinner(on: bool) -> void:
	if _spinner == null:
		_spinner = Control.new()
		_spinner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_spinner.mouse_filter = Control.MOUSE_FILTER_STOP
		_spinner.draw.connect(_on_spinner_draw)
		add_child(_spinner)   # 末位子节点 = 显示在最上层
	_spin_t = 0.0
	_spinner.visible = on


func _on_spinner_draw() -> void:
	_spinner.draw_rect(Rect2(Vector2.ZERO, _spinner.size), Color(0.0, 0.0, 0.0, 0.22))
	var a0 := _spin_t * 5.0
	_spinner.draw_arc(_spinner.size / 2.0, 30.0, a0, a0 + PI * 1.35, 48, Color.WHITE, 5.0, true)


func _process(delta: float) -> void:
	if _spinner != null and _spinner.visible:
		_spin_t += delta
		_spinner.queue_redraw()


## ===== 右下角进度浮字 =====
## 后台扫描/下载进度反馈：收到 progress 显示并刷新文案；all_done 后停 1s 淡出。
## z_index=1000 浮于一切 UI（游戏元素/弹窗/排行榜）之上；IGNORE 不挡点击；
## 游戏运行中也持续可见（进游戏后主程序后台继续下载的进度提示）

func _on_load_progress(text: String) -> void:
	_ensure_progress_label()
	if _progress_fade != null:
		_progress_fade.kill()
		_progress_fade = null
	_progress_lbl.visible = true
	_progress_lbl.modulate.a = 1.0
	_progress_text.text = text


func _on_load_done() -> void:
	if _progress_lbl == null or not _progress_lbl.visible:
		return
	_progress_fade = create_tween()
	_progress_fade.tween_interval(1.0)
	_progress_fade.tween_property(_progress_lbl, "modulate:a", 0.0, 0.4)
	_progress_fade.tween_callback(func() -> void: _progress_lbl.visible = false)


func _ensure_progress_label() -> void:
	if _progress_lbl != null:
		return
	_progress_lbl = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.19, 0.18, 0.92)   # 与设置/排行榜面板同风格深色圆角
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 8
	_progress_lbl.add_theme_stylebox_override("panel", sb)
	_progress_lbl.z_index = 1000
	_progress_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_lbl.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_progress_lbl.grow_horizontal = Control.GROW_DIRECTION_BEGIN   # 尺寸变化向左/上扩展
	_progress_lbl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_progress_lbl.offset_left = -16.0
	_progress_lbl.offset_top = -16.0
	_progress_lbl.offset_right = -16.0
	_progress_lbl.offset_bottom = -16.0
	_progress_text = Label.new()
	_progress_text.add_theme_color_override("font_color", Color.WHITE)
	_progress_lbl.add_child(_progress_text)
	add_child(_progress_lbl)


func stop_game() -> void:
	get_tree().paused = false   # 暂停态（排行榜/弹窗）下退出须复位，防菜单卡死
	if _current_game == null:
		return
	print("[Main] 退出游戏: %s" % _current_game.name)
	if _current_game.has_method("stop"):
		_current_game.stop()
	_current_game.queue_free()
	_current_game = null
	_show_menu()


func _unhandled_input(event: InputEvent) -> void:
	# ESC 两段式：游戏中返回启动界面；启动界面直接退出进程
	# Web 端禁用 ESC：浏览器内不退出小游戏/退出程序
	if event.is_action_pressed("ui_cancel") and not OS.has_feature("web"):
		if _current_game != null:
			stop_game()
		else:
			get_tree().quit()
