class_name GameManager
## 游戏包扫描与挂载（M2）
## 来源：games/ 目录下的 .pck / .zip（zip 内含 .pck，先解包再挂载）
## 注册：每个包挂载后扫描 res://games/*/manifest.json 注册新出现的游戏，按 id 去重
## 规范：游戏包所有资源强制置于 games/<id>/ 前缀下，manifest 的 icon/entry 为包内相对路径
## 事件化加载：逐个游戏就绪即发 game_ready（菜单增量建卡，先出的先玩），
## progress 携带右下角浮字文案（加载计数/下载百分比），全部处理完发 all_done
## 静态类不能持有信号（信号为实例成员），事件经内部 Events 实例转发

## 加载事件总线（调用方 GameManager.events().game_ready.connect(...)）
class Events extends RefCounted:
	signal game_ready(info: Dictionary)
	signal progress(text: String)
	signal all_done()

const GAMES_SUBDIR := "games"
const ZIP_CACHE_DIR := "user://cache"
const CACHE_VER := "user://cache/version.txt"
const MANIFEST_NAME := "manifest.json"

## 扫描结果：Array[Dictionary]，字段 {id, name, icon, entry, version}
## icon/entry 已拼接为完整 res:// 路径
static var games: Array[Dictionary] = []

static var _events: Events


## 事件总线（懒创建；调用方在 scan() 前连接）
static func events() -> Events:
	if _events == null:
		_events = Events.new()
	return _events


## 扫描并挂载全部游戏包：逐个就绪即发信号，全部完成后返回。
## 可作后台任务发起（不 await）——已就绪的游戏立即可玩，其余后台继续
static func scan() -> Array[Dictionary]:
	games.clear()
	if OS.has_feature("web"):
		# Web：游戏包为部署目录旁路文件（games/*.pck，控制主包单文件体积），
		# 启动时逐个 HTTP 下载到 user://cache 再挂载；index.txt / version.txt
		# 构建期生成并打进主包，version.txt 作缓存指纹，未变则免重复下载
		await _load_packs_web()
	else:
		await _load_packs_desktop()
	print("[GameManager] 已注册游戏 %d 个:" % games.size())
	for g in games:
		print("[GameManager]   %s v%s — %s" % [g.id, g.version, g.name])
	events().all_done.emit()
	return games


## 游戏包来源目录：导出后为 exe 旁 games/，开发期为项目内 res://games
static func _packs_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://" + GAMES_SUBDIR)
	return OS.get_executable_path().get_base_dir().path_join(GAMES_SUBDIR)


## 桌面：逐个挂载 games/ 下的 pck/zip，挂一个注册一个（卡片即时可点）
static func _load_packs_desktop() -> void:
	var dir := _packs_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return
	var d := DirAccess.open(dir)
	if d == null:
		push_warning("games 目录无法打开: %s" % dir)
		return
	var files: Array[String] = []
	d.list_dir_begin()
	var file := d.get_next()
	while file != "":
		if not d.current_is_dir() \
				and (file.get_extension() == "pck" or file.get_extension() == "zip"):
			files.append(file)
		file = d.get_next()
	d.list_dir_end()
	files.sort()
	var tree := Engine.get_main_loop() as SceneTree
	var total := files.size()
	var n := 0
	for f in files:
		n += 1
		events().progress.emit(_tr("load.games", "Loading games %d/%d") % [n, total])
		if f.get_extension() == "pck":
			_mount_pack(dir.path_join(f))
		else:
			_mount_zip(dir.path_join(f))
		_register_mounted_games()
		if tree != null:
			await tree.process_frame   # 让 UI 渲染新卡片，入场动画级联错开


## 挂载后扫描 res://games/ 各目录 manifest.json，注册新出现的游戏（pck 文件名
## 与游戏 id 不一致也能发现）；目录缺 manifest 静默跳过（挂载前目录可能仅有语言文件）
static func _register_mounted_games() -> void:
	var games_root := "res://" + GAMES_SUBDIR
	var d := DirAccess.open(games_root)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir() and not name.begins_with("."):
			var info := _read_manifest(games_root.path_join(name).path_join(MANIFEST_NAME))
			if not info.is_empty():
				_register(info)
		name = d.get_next()
	d.list_dir_end()


## 去重注册并发 game_ready
static func _register(info: Dictionary) -> void:
	for g in games:
		if g.id == info.id:
			return
	games.append(info)
	events().game_ready.emit(info)


static func _mount_pack(path: String) -> void:
	if ProjectSettings.load_resource_pack(path, false):
		print("[GameManager] 挂载成功: %s" % path.get_file())
	else:
		push_error("挂载失败: %s" % path)


static func _mount_zip(path: String) -> void:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		push_error("zip 打开失败: %s" % path)
		return
	DirAccess.make_dir_recursive_absolute(ZIP_CACHE_DIR)
	for inner in zip.get_files():
		if inner.get_extension() != "pck":
			continue
		var out_path := ZIP_CACHE_DIR.path_join(inner.get_file())
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			push_error("zip 内 pck 落盘失败: %s" % inner)
			continue
		f.store_buffer(zip.read_file(inner))
		f.close()
		_mount_pack(ProjectSettings.globalize_path(out_path))
	zip.close()


static func _read_manifest(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("manifest 解析失败: %s" % path)
		return {}
	# id / entry 必填，name / icon / version 提供缺省
	if data.get("id", "").is_empty() or data.get("entry", "").is_empty():
		return {}
	var base := path.get_base_dir() + "/"
	return {
		"id": data.id,
		"name": data.get("name", data.id),
		"icon": base + data.icon if not data.get("icon", "").is_empty() else "",
		"entry": base + data.entry,
		"version": data.get("version", "1.0.0"),
	}


## ===== Web 分支 =====
## 游戏包不在主包内（单文件体积限制），部署在 dt.html 旁 games/ 目录下。
## 按 index.txt 逐个下载到 user://cache 挂载（version.txt 未变且有缓存则跳过下载），
## 沙箱不能列目录，全部按清单驱动；每个游戏就绪立即注册发信号。

static func _load_packs_web() -> void:
	var txt := FileAccess.get_file_as_string("res://" + GAMES_SUBDIR + "/index.txt")
	if txt.is_empty():
		push_warning("Web: games/index.txt 缺失或为空（需在导出前生成）")
		return
	DirAccess.make_dir_recursive_absolute(ZIP_CACHE_DIR)
	var stamp := FileAccess.get_file_as_string("res://games/version.txt").strip_edges()
	var cache_hit := stamp != "" and FileAccess.get_file_as_string(CACHE_VER) == stamp
	var packs: Array[String] = []
	for line in txt.split("\n", false):
		var pack := line.strip_edges()
		if not pack.is_empty() and pack.ends_with(".pck"):
			packs.append(pack)
	var tree := Engine.get_main_loop() as SceneTree
	var total := packs.size()
	var n := 0
	for pack in packs:
		n += 1
		events().progress.emit(_tr("load.games", "Loading games %d/%d") % [n, total])
		var cache_path := ZIP_CACHE_DIR.path_join(pack)
		if not (cache_hit and FileAccess.file_exists(cache_path)):
			var buf := await _http_download(GAMES_SUBDIR + "/" + pack, pack)
			if buf.is_empty():
				push_error("Web: 游戏包下载失败，跳过 " + pack)
				continue
			var f := FileAccess.open(cache_path, FileAccess.WRITE)
			if f == null:
				push_error("Web: 游戏包落盘失败 " + cache_path)
				continue
			f.store_buffer(buf)
			f.close()
		_mount_pack(cache_path)
		_register_mounted_games()
		if tree != null:
			await tree.process_frame
	if stamp != "":
		var vf := FileAccess.open(CACHE_VER, FileAccess.WRITE)
		if vf != null:
			vf.store_string(stamp)
			vf.close()


## Web 下载部署目录相对路径文件，返回字节（失败返回空）。title 用于浮字进度文案。
## 不用 HTTPRequest：其 web 端内部实现（godot_js_fetch）在部分 HTTPS/HTTP2 CDN
## 环境（如 GitHub Pages）整条链路报 RESULT_REQUEST_FAILED（result=8 code=200）。
## 改用页面原生 fetch（引擎 wasm 即由此加载，实测可用）：body.getReader() 逐块
## 读取并回写 received/total，GDScript 轮询期间发 progress 供浮字显示百分比。
static func _http_download(rel_path: String, title: String) -> PackedByteArray:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return PackedByteArray()
	var raw = JavaScriptBridge.eval("new URL('./%s', window.location.href).href" % rel_path, true)
	if raw == null:
		print("[GameManager] URL 解析失败: %s" % rel_path)
		return PackedByteArray()
	var url := String(raw)
	JavaScriptBridge.eval("""
window.__dtFetch = { done: false, ok: false, data: null, received: 0, total: 0 };
fetch('%s').then(function(r) {
	if (!r.ok) { window.__dtFetch.done = true; return; }
	window.__dtFetch.total = parseInt(r.headers.get('Content-Length') || '0', 10) || 0;
	var body = r.body;
	if (!body || !body.getReader) {
		return r.arrayBuffer().then(function(b) {
			window.__dtFetch.received = b.byteLength;
			window.__dtFetch.total = b.byteLength;
			window.__dtFetch.ok = true;
			window.__dtFetch.data = new Uint8Array(b);
			window.__dtFetch.done = true;
		});
	}
	var reader = body.getReader();
	var chunks = [];
	var pump = function() {
		return reader.read().then(function(res) {
			if (res.done) {
				var arr = new Uint8Array(window.__dtFetch.received);
				var off = 0;
				for (var i = 0; i < chunks.length; i++) { arr.set(chunks[i], off); off += chunks[i].length; }
				window.__dtFetch.ok = true;
				window.__dtFetch.data = arr;
				window.__dtFetch.done = true;
				return;
			}
			chunks.push(res.value);
			window.__dtFetch.received += res.value.length;
			return pump();
		});
	};
	return pump();
}).catch(function() {
	window.__dtFetch.done = true;
});
""" % url, true)
	for i in 600:
		var st := String(JavaScriptBridge.eval(
			"window.__dtFetch.done+','+window.__dtFetch.received+','+window.__dtFetch.total", true))
		var parts := st.split(",")
		if parts.size() >= 3:
			events().progress.emit(_fmt_download(title, int(parts[1]), int(parts[2])))
			if parts[0] == "true":
				break
		await tree.create_timer(0.1).timeout
	if not bool(JavaScriptBridge.eval("window.__dtFetch.ok", true)):
		print("[GameManager] 下载失败(%s)" % rel_path)
		return PackedByteArray()
	var data = JavaScriptBridge.eval("window.__dtFetch.data", true)
	if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
		print("[GameManager] 下载数据类型异常(%s)" % rel_path)
		return PackedByteArray()
	return data


## 浮字下载文案：无 Content-Length 时只显示已收 MB
static func _fmt_download(title: String, received: int, total: int) -> String:
	var mb := "%.1f" % (received / 1048576.0)
	if total > 0:
		var pct := int(float(received) / float(total) * 100.0)
		return _tr("load.download", "Downloading %s %d%% (%s/%s MB)") % [title, pct, mb, "%.1f" % (total / 1048576.0)]
	return _tr("load.download_mb", "Downloading %s (%s MB)") % [title, mb]


## 静态上下文取 L10n 文案（autoload 经主循环根节点查找，规避静态访问限制）
static func _tr(key: String, fallback: String) -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root.has_node("L10n"):
		return String(tree.root.get_node("L10n").call("t", key, fallback))
	return fallback
