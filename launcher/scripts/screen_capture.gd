class_name ScreenCapture
## 桌面截屏（假桌面方案）：主程序以最小化启动不遮挡桌面。
## 首选引擎内置 screen_get_image（Godot 4.2+；Windows 走 GDI、Linux X11 走 XGetImage，零外部依赖）；
## Linux 上引擎截屏失败时依次尝试系统工具（scrot / ImageMagick import / gnome-screenshot /
## kylin-screenshot / mate-screenshot），输出 png 后按字节解码；全部失败返回 null（降级纯色背景）


## 截取主屏，返回贴图；失败返回 null（调用方降级纯色背景）
## 主流程将全屏窗口固定在主屏（main.gd），快照屏与游戏显示屏始终一致
static func capture() -> ImageTexture:
	if OS.has_feature("web"):
		# Web：无截屏能力，直接走壁纸兜底（旁路 HTTP 优先，主包内置次之）
		print("[Capture] Web 平台：跳过截屏链，尝试壁纸兜底 ...")
		var wt := await _load_wallpaper_web()
		if wt != null:
			return wt
		var wb := _load_wallpaper_res()
		if wb != null:
			return wb
		print("[Capture] Web 无 wallpaper.png/jpg（部署目录或主包内），启动后将为纯色背景")
		return null
	var img := DisplayServer.screen_get_image(0)
	if img != null and not img.is_empty():
		print("[Capture] 引擎截屏成功 %dx%d" % [img.get_width(), img.get_height()])
		return ImageTexture.create_from_image(img)
	print("[Capture] 引擎截屏失败，尝试系统截屏工具 ...")
	img = await _capture_by_tools()
	if img != null:
		return ImageTexture.create_from_image(img)
	img = _load_wallpaper()
	if img != null:
		return ImageTexture.create_from_image(img)
	print("[Capture] 所有截屏方式均失败且无 wallpaper.png，启动后将为纯色背景")
	return null


## Linux 兜底：依次尝试系统截屏工具，输出 png 后解码
static func _capture_by_tools() -> Image:
	if OS.get_name() != "Linux":
		return null
	if OS.get_environment("DISPLAY") == "":
		print("[Capture] DISPLAY 未设置（Wayland 会话？），系统工具兜底不可用")
		return null
	var out := ProjectSettings.globalize_path("user://desktop_capture.png")
	DirAccess.remove_absolute(out)   # 清旧产物，防误读上次文件
	var tools := [
		["scrot", ["-o", out]],
		["import", ["-window", "root", out]],
		["gnome-screenshot", ["-f", out]],
		["mate-screenshot", ["-f", out]],
	]
	for t: Array in tools:
		var code := OS.execute(t[0], PackedStringArray(t[1]), [], false, true)
		if code != 0 or not FileAccess.file_exists(out):
			if code == 127:
				print("[Capture] %s 未安装" % t[0])
			elif code == 0:
				print("[Capture] %s 已执行但未生成文件（该工具不支持保存到指定路径的命令行参数）" % t[0])
			else:
				print("[Capture] %s 不可用 (exit=%d)" % [t[0], code])
			continue
		var img := _load_png_file(out)
		if img != null:
			print("[Capture] %s 截屏成功 %dx%d" % [t[0], img.get_width(), img.get_height()])
			return img
		print("[Capture] %s 输出解码失败" % t[0])
	return await _capture_by_kylin(out)


## kylin-screenshot 专用分支（麒麟 V10 实测：Spectacle 内核 + 精简 CLI）：
## 首选裸 full——实测静默保存到 ~/图片（-o/--output 参数已被精简砍掉），
## 轮询扫描默认图片目录取执行后最新 png；失败才短等试探 Spectacle 标准输出参数
static func _capture_by_kylin(out: String) -> Image:
	if OS.execute("kylin-screenshot", PackedStringArray(["--help"]), [], false, true) != 0:
		return null
	print("[Capture] 检测到 kylin-screenshot（Spectacle 风格 CLI），执行 full ...")
	var t0 := int(Time.get_unix_time_from_system()) - 1.0
	var tree := Engine.get_main_loop() as SceneTree
	# 首选裸 full：异步执行防弹窗挂死，0.1s 步进轮询（最多 3s），命中即删源文件
	OS.execute("kylin-screenshot", PackedStringArray(["full"]), [], false, false)
	for i in 30:
		await tree.create_timer(0.1).timeout
		var recent := _scan_recent_screenshot(t0)
		if recent != "":
			var img := _load_png_file(recent)
			if img != null:
				DirAccess.remove_absolute(recent)   # 用完即删：不往用户图片目录留游戏截图
				print("[Capture] kylin-screenshot 截图 %s 读取成功 %dx%d（源文件已删）" % [recent, img.get_width(), img.get_height()])
				return img
	# 兜底：其他 Spectacle 环境可能保留 options，各短等 2s 试探输出路径参数
	for t: Array in [["full", "-b", "-n", "-o", out], ["full", "--output", out]]:
		DirAccess.remove_absolute(out)
		if OS.execute("kylin-screenshot", PackedStringArray(t), [], false, false) < 0:
			continue
		for i in 20:
			await tree.create_timer(0.1).timeout
			var img := _load_png_file(out)
			if img != null:
				DirAccess.remove_absolute(out)   # 用完即删
				print("[Capture] kylin-screenshot %s 截屏成功 %dx%d（源文件已删）" % [" ".join(PackedStringArray(t)), img.get_width(), img.get_height()])
				return img
		print("[Capture] kylin-screenshot 参数 %s 未产出文件" % " ".join(PackedStringArray(t)))
	print("[Capture] kylin-screenshot 未找到新截图文件")
	return null


## 扫描常见截图保存目录，返回 t0 之后修改时间最新的 png（找不到返回空串）
static func _scan_recent_screenshot(t0: int) -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		return ""
	var best := ""
	var best_m := 0
	for d: String in [home.path_join("图片"), home.path_join("Pictures"), home.path_join("桌面"), home.path_join("Desktop")]:
		var da := DirAccess.open(d)
		if da == null:
			continue
		da.list_dir_begin()
		var fname := da.get_next()
		while fname != "":
			if not da.current_is_dir() and fname.to_lower().ends_with(".png"):
				var full := d.path_join(fname)
				var m := FileAccess.get_modified_time(full)
				if m >= t0 and m > best_m:
					best = full
					best_m = m
			fname = da.get_next()
		da.list_dir_end()
	return best


## 按字节读取并解码 png 文件（失败返回 null）
static func _load_png_file(path: String) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	if img.load_png_from_buffer(buf) == OK and not img.is_empty():
		return img
	return null


## 末级兜底：程序目录用户自备壁纸（虚拟机/特殊驱动下截屏链全断时，保证"假桌面"背景效果）
static func _load_wallpaper() -> Image:
	var base := OS.get_executable_path().get_base_dir()
	for fname: String in ["wallpaper.png", "wallpaper.jpg"]:
		var f := FileAccess.open(base.path_join(fname), FileAccess.READ)
		if f == null:
			continue
		var buf := f.get_buffer(f.get_length())
		f.close()
		var img := Image.new()
		var ok := false
		if fname.ends_with(".png"):
			ok = img.load_png_from_buffer(buf) == OK
		else:
			ok = img.load_jpg_from_buffer(buf) == OK
		if ok and not img.is_empty():
			print("[Capture] 使用自备壁纸 %s (%dx%d)" % [fname, img.get_width(), img.get_height()])
			return img
	return null


## Web：FileAccess 读不到部署目录旁路文件，按部署页相对路径（原生 JS fetch，走
## GameManager._http_download——HTTPRequest 在 GitHub Pages 等 HTTPS/HTTP2 CDN 下会失败）
## 拉取壁纸；相对路径经浏览器 URL 解析成绝对地址，自动适配任意部署子目录
static func _load_wallpaper_web() -> ImageTexture:
	for fname: String in ["wallpaper.png", "wallpaper.jpg"]:
		var buf := await GameManager._http_download(fname)
		if buf.is_empty():
			print("[Capture] Web 壁纸请求失败(%s)（部署目录无此文件？）" % fname)
			continue
		var img := Image.new()
		var ok := img.load_png_from_buffer(buf) if fname.ends_with(".png") else img.load_jpg_from_buffer(buf)
		if ok == OK and not img.is_empty():
			print("[Capture] 使用壁纸 %s (%dx%d)" % [fname, img.get_width(), img.get_height()])
			return ImageTexture.create_from_image(img)
		print("[Capture] Web 壁纸解码失败 %s（渐进式 JPEG 不受支持？）" % fname)
	return null


## Web 次级兜底：主包内置壁纸（需在导出 include_filter 中包含 *.jpg/*.png 才会打进主包）
static func _load_wallpaper_res() -> ImageTexture:
	for fname: String in ["res://wallpaper.png", "res://wallpaper.jpg"]:
		if not FileAccess.file_exists(fname):
			continue
		var f := FileAccess.open(fname, FileAccess.READ)
		if f == null:
			continue
		var buf := f.get_buffer(f.get_length())
		f.close()
		var img := Image.new()
		var ok := img.load_png_from_buffer(buf) if fname.ends_with(".png") else img.load_jpg_from_buffer(buf)
		if ok == OK and not img.is_empty():
			print("[Capture] 使用主包内置壁纸 %s (%dx%d)" % [fname, img.get_width(), img.get_height()])
			return ImageTexture.create_from_image(img)
	return null
