extends Node
## 主程序入口：扫描游戏包 → 启动界面 / 游戏切换
## 透明窗口方案：无框 + 逐像素透明，真实桌面/视频直接透出窗口（不启用鼠标穿透）。
## 三级背景兜底：① 透明正常 → BgLayer 整体隐藏；② 透明失效（黑屏自检触发）→ 显示启动快照；
## ③ 截屏链全断 → exe 同级 wallpaper.png/jpg（ScreenCapture.capture 内置该链）→ 纯色蓝底末级。
## 启动时窗口屏外静默首拍（Windows 不入镜；Linux 需最小化避让），快照仅兜底用、平时不可见；
## 最小化期间每 2s 重截保持快照新鲜（_process）。自定义背景开启时盖住透明（用户显式选择）

const MENU_SCENE := "res://scenes/menu.tscn"
const CURSOR_SIZE := 24.0    # 自定义光标最长边显示尺寸（px，原图 128px 偏大，等比缩小；想调改这里）
const CURSOR_ARROW := "res://assets/ui/cursor/arrow.png"   # 默认箭头指针（热点=左上尖端）
const CURSOR_HAND := "res://assets/ui/cursor/link.png"     # 悬停按钮手型指针（热点=指尖）
const BLACK_LUMA := 0.04   # 透明自检近黑阈值（每通道 <10/255 判黑；误判代价=显示快照，可放心调）

# 背景层在独立 CanvasLayer（layer=-1）：游戏相机的 canvas 变换（平移/缩放）只作用于 layer 0，
# 不再连带壁纸变形（曾出现游戏内镜头上移/缩放时壁纸跟着位移缩小）
@onready var _background: TextureRect = $BgLayer/Background
@onready var _background_color: ColorRect = $BgLayer/BackgroundColor
@onready var _game_host: Node = $GameHost

var _menu: Control = null
var _current_game: Node = null
var _desktop_tex: ImageTexture      # 启动静默首拍（透明失效时的降级背景；capture 内含 wallpaper 兜底链）
var _bg_stretch_default := 0        # 场景原始填充方式（关闭自定义背景时还原）
var _top_layer: CanvasLayer         # 顶层独立层（加载圈/进度浮字）：游戏相机只影响 layer 0，此层不受镜头平移/缩放影响
var _spinner: Control               # 点击游戏后的旋转进度圈（不指示真实进度）
var _spin_t := 0.0                  # 进度圈旋转相位
var _loading := false               # 进游戏加载中（await 帧间隙防重复触发）
var _progress_lbl: PanelContainer   # 右下角加载/下载进度浮字（游戏内也可见，后台下载反馈）
var _progress_text: Label
var _progress_fade: Tween
var _snapshot_ready := false         # 启动首拍完成前不启用最小化重截（避免与启动截屏重复）
var _fallback_active := false        # 透明失效已降级（BgLayer 显示快照/壁纸/纯色，不再追求透明）
var _was_minimized := false          # 最小化跟踪（最小化期间定期重截桌面，恢复即见新背景）
var _recap_t := 0.0                  # 最小化期间重截倒计时（首拍 0.8s，此后每 2s）


func _ready() -> void:
	add_to_group("launcher_main")   # 供设置弹窗通知应用背景变更
	_top_layer = CanvasLayer.new()
	_top_layer.layer = 1000   # 浮于游戏 UI（layer 1）/菜单之上，且不受游戏相机 canvas 变换影响
	add_child(_top_layer)
	# 自定义鼠标指针：默认箭头 / 悬停按钮自动切手型（游戏包按钮 style_button 已设 POINTING_HAND；
	# dart 的 HIDDEN 隐藏指针模式与自定义指针独立，恢复 VISIBLE 后仍显示自定义图）
	_setup_cursor(CURSOR_ARROW, Input.CURSOR_ARROW, Vector2(4, 4))
	_setup_cursor(CURSOR_HAND, Input.CURSOR_POINTING_HAND, Vector2(46, 10))
	# Linux 下多为软渲染（llvmpipe，且 V-Sync 不可用导致全速空转），限 30fps 减轻 CPU 负担防卡顿
	if OS.get_name() == "Linux":
		Engine.max_fps = 30
		print("[Main] Linux 软渲染环境，帧率上限 30fps")
	# 透明窗口初始化：无框 + 逐像素透明，真实桌面/视频直接透出（需 project.godot 同步开启透明设置）
	_setup_transparent_window()
	# 双保险：project.godot 已设初始位置屏幕外，这里再补一次（防个别窗口管理器把屏外窗口拉回工作区）
	DisplayServer.window_set_position(Vector2i(-32000, -32000), get_window().get_window_id())
	# 静默首拍（三级兜底第二级）：窗口屏外未显示不入镜，直接截屏；capture 内部自带
	# 「引擎截屏→Linux 系统工具→exe 同级 wallpaper」降级链。快照仅透明失效时由自检启用
	if OS.get_name() == "Linux":
		# UKWM 会把屏外窗口钳回工作区（实测），最小化避让后再截；恢复交给后面 show()/全屏
		get_window().mode = Window.MODE_MINIMIZED
		await get_tree().create_timer(0.3).timeout
	_desktop_tex = await ScreenCapture.capture()
	_snapshot_ready = true
	_bg_stretch_default = _background.stretch_mode
	apply_background_settings()
	# 显示并进入全屏（多屏时固定主屏）
	get_window().show()
	get_window().grab_focus()
	DisplayServer.window_set_current_screen(0, get_window().get_window_id())
	get_window().mode = Window.MODE_FULLSCREEN
	await get_tree().process_frame
	print("[DPI] fullscreen window=%s canvas=%s screen=%s scale=%.2f" % [get_window().size,
		get_viewport().get_visible_rect().size,
		DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()),
		DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())])
	# Web 无透明概念：恒走快照/壁纸兜底（capture 在 web 内部已拉取部署目录 wallpaper）
	if OS.has_feature("web"):
		_enable_fallback_background()

	# 菜单先建（空态），扫描/下载后台进行：游戏逐个就绪即出卡片（game_ready→menu），
	# 右下角浮字显示加载/下载进度，全部就绪后自动淡出——期间即可点卡片进游戏
	GameManager.events().progress.connect(_on_load_progress)
	GameManager.events().all_done.connect(_on_load_done)
	_show_menu()
	GameManager.scan()
	# 透明失效自检（异步不阻塞）：全屏稳定后 5×5 网格采样物理屏，全黑即降级快照/壁纸；
	# 自定义背景开启时窗口本就不透明，自检无意义直接跳过
	if not OS.has_feature("web") and not _custom_bg_enabled():
		_self_check_transparent()


## ===== 透明窗口初始化（Windows）=====
## 无边框 + 逐像素透明：窗口未绘制区域透出真实桌面/视频；游戏内容照常绘制、照常点击。
## 不设置 WINDOW_FLAG_MOUSE_PASSTHROUGH——窗口正常接收鼠标，UI 点击不受影响。
## 三重保险：Window 属性 + Viewport.transparent_bg + RenderingServer/DisplayServer 底层标志；
## 但决定性的是 project.godot 的 size/transparent + per_pixel_transparency/allowed（创建时生效）。
func _setup_transparent_window() -> void:
	var win := get_window()
	if win == null:
		return
	# 无边框窗口（project.godot 已设，代码级双保险）
	win.borderless = true
	# 窗口逐像素透明
	win.transparent = true
	# 视口透明背景：场景未绘制区域 alpha=0
	var vp := get_viewport()
	if vp:
		vp.transparent_bg = true
		# RenderingServer 再次确保透明背景生效
		RenderingServer.viewport_set_transparent_background(vp.get_viewport_rid(), true)
	# DisplayServer 窗口透明标志兜底
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, true, win.get_window_id())
	# 需要悬浮在视频上层时按需启用（当前置顶=false：置顶会盖住任务栏导致无法最小化，勿随意打开）：
	# DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true, win.get_window_id())


## ===== 透明失效自检（三级兜底的触发器）=====
## 全屏稳定后对物理主屏做 5×5 网格采样：全部近黑即判定透明失效（失效时本窗黑屏盖住整屏；
## 正常时透出真实桌面/视频，25 点全黑概率极低）。纯黑壁纸/黑屏保护会误判，代价仅是把
## "几乎一样的真实画面"换成快照，视觉无害。采样失败（Wayland 等）不降级——宁透明勿误伤
func _self_check_transparent() -> void:
	if _fallback_active:
		return   # 已降级：BgLayer 恒可见不透明，无需再采样
	await get_tree().create_timer(0.6).timeout
	var img := DisplayServer.screen_get_image(0)
	if img == null or img.is_empty():
		print("[Main] 透明自检：物理屏采样失败，保持透明不降级")
		return
	var w := img.get_width()
	var h := img.get_height()
	for gy in 5:
		for gx in 5:
			var c := img.get_pixel(int(w * (0.1 + 0.2 * gx)), int(h * (0.1 + 0.2 * gy)))
			if c.r > BLACK_LUMA or c.g > BLACK_LUMA or c.b > BLACK_LUMA:
				return   # 任一点非黑：透明正常
	print("[Main] 透明自检：25 点全黑，判定透明失效")
	_enable_fallback_background()


## 降级启用：BgLayer 恢复显示，apply_background_settings 按「快照→wallpaper→纯色」取背景；
## 之后最小化重截（_process）会持续刷新快照，恢复窗口即见新背景（与旧快照方案行为一致）
func _enable_fallback_background() -> void:
	if _fallback_active:
		return
	_fallback_active = true
	print("[Main] 透明窗口失效，降级为快照/壁纸背景（三级兜底）")
	apply_background_settings()


## 自定义背景开关（settings.cfg [background] enabled）：设置弹窗写入，透明自检的前置判断
func _custom_bg_enabled() -> bool:
	var cf := ConfigFile.new()
	return cf.load("user://settings.cfg") == OK \
			and bool(cf.get_value("background", "enabled", false))


func _show_menu() -> void:
	if _menu != null:
		_menu.show()   # 菜单常驻：后台扫描期间新就绪的卡片已在其中
		return
	_menu = (load(MENU_SCENE) as PackedScene).instantiate()
	_menu.game_selected.connect(start_game)
	_game_host.add_child(_menu)


## 应用背景设置（设置弹窗实时调用）：
## - 自定义背景关闭 + 透明正常：整个 BgLayer 隐藏，透出真实桌面/视频；
## - 自定义背景关闭 + 透明失效（_fallback_active）：显示启动快照（capture 内含 exe 同级
##   wallpaper 末级兜底），无快照退纯色蓝底；
## - 自定义背景开启：按 mode 切图片/纯色，fill 映射 TextureRect 填充方式（拉伸/平铺/居中/适应/填充）
func apply_background_settings() -> void:
	var cf := ConfigFile.new()
	var enabled := cf.load("user://settings.cfg") == OK \
			and bool(cf.get_value("background", "enabled", false))
	if not enabled and not _fallback_active:
		# 透明窗口：背景层整体隐藏（含纯色兜底），未绘制区域 alpha=0 直接透出真实桌面/视频
		_background.visible = false
		_background_color.visible = false
		return
	_background.visible = true
	if not enabled:
		# 透明失效降级：显示启动快照（含 wallpaper 兜底链的产出）；无快照退纯色蓝底
		_background.stretch_mode = _bg_stretch_default
		_background.texture = _desktop_tex
		_background_color.visible = _desktop_tex == null
		if _desktop_tex == null:
			_background_color.color = Color(0.20, 0.42, 0.75)
		return
	# 用户显式开启自定义背景：恢复显示（此时窗口被自选背景覆盖，不再透出桌面）
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
		_top_layer.add_child(_spinner)   # 独立顶层：不随游戏相机变换
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
	# 最小化期间定期重截桌面：窗口隐藏时不遮挡屏幕，可截到干净画面；
	# 恢复显示时背景即最新快照（截屏只能在隐藏时做——恢复后再截会截到自己）
	if _snapshot_ready and not OS.has_feature("web"):
		var minimized := get_window().mode == Window.MODE_MINIMIZED
		if minimized and not _was_minimized:
			_recap_t = 0.8   # 刚最小化：等任务栏/合成器动画结束再首拍
		elif not minimized and _was_minimized:
			_on_window_restored()   # Windows 透明窗恢复后 DWM 可能停合成 alpha（整窗黑），重放透明
		_was_minimized = minimized
		if minimized:
			_recap_t -= delta
			if _recap_t <= 0.0:
				_recap_t = 2.0
				_refresh_desktop_snapshot()


## 最小化期间重截桌面快照（异步）：仅当窗口仍处于最小化时才采用结果
## （截屏 await 期间用户可能已恢复——恢复途中截到的画面会含本窗口）
func _refresh_desktop_snapshot() -> void:
	if get_window().mode != Window.MODE_MINIMIZED:
		return
	var tex := await ScreenCapture.capture(false)
	if tex != null and get_window().mode == Window.MODE_MINIMIZED:
		_desktop_tex = tex
		apply_background_settings()   # 自定义背景关闭时立即透出新快照


## ===== 恢复后透明重放 =====
## Windows 已知问题：无框透明窗口最小化→恢复后，DWM 可能不再合成窗口 alpha（整窗变不透明黑；
## BgLayer 此时隐藏，视觉即"黑屏、无透明、无快照"）。恢复时三连手段：
## ① transparent 标志关→开（触发 DisplayServer 重建窗口样式与 DWM 关联，值未变会被跳过故必须关开）；
## ② hide→show 两个帧窗口（强制 DWM 销毁重建窗口合成面——最强兜底；透明正常时隐藏的 1-2 帧
##    看到的还是同一桌面，视觉近乎无缝；标志开关在部分驱动上不生效，此步保证有效）；
## ③ 异步重跑黑屏自检——仍无效则自动降级快照背景，保证恢复后永不出纯黑窗
func _on_window_restored() -> void:
	await get_tree().create_timer(0.2).timeout   # 等恢复动画/DWM 稳定后再重放
	print("[Main] 窗口恢复：重放透明初始化（toggle + hide/show + 自检）")
	_reapply_transparent_window()
	var win := get_window()
	win.hide()
	await get_tree().process_frame
	await get_tree().process_frame
	win.show()
	win.grab_focus()
	if win.mode != Window.MODE_FULLSCREEN:
		win.mode = Window.MODE_FULLSCREEN   # 恢复可能落在其他模式，强制回全屏
	if not _custom_bg_enabled():
		_self_check_transparent()   # 0.6s 后采样；仍黑则降级快照


func _reapply_transparent_window() -> void:
	var win := get_window()
	if win == null:
		return
	win.borderless = true
	# 关→开各触发一次窗口样式/DWM 重应用（值未变直接设 true 会被跳过）
	win.transparent = false
	win.transparent = true
	var vp := get_viewport()
	if vp:
		vp.transparent_bg = true
		RenderingServer.viewport_set_transparent_background(vp.get_viewport_rid(), true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_TRANSPARENT, true, win.get_window_id())


## ===== 右下角进度浮字 =====
## 后台扫描/下载进度反馈：收到 progress 显示并刷新文案；all_done 后停 1s 淡出。
## 挂 _top_layer（CanvasLayer layer=1000）浮于一切 UI/游戏层之上，且不随游戏相机变换；
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
	_top_layer.add_child(_progress_lbl)


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
