class_name GameManager
## 游戏包扫描与挂载（M2）
## 来源：games/ 目录下的 .pck / .zip（zip 内含 .pck，先解包再挂载）
## 注册：挂载后统一遍历 res://games/*/manifest.json，按 id 去重
## 规范：游戏包所有资源强制置于 games/<id>/ 前缀下，manifest 的 icon/entry 为包内相对路径

const GAMES_SUBDIR := "games"
const ZIP_CACHE_DIR := "user://cache"
const CACHE_VER := "user://cache/version.txt"
const MANIFEST_NAME := "manifest.json"

## 扫描结果：Array[Dictionary]，字段 {id, name, icon, entry, version}
## icon/entry 已拼接为完整 res:// 路径
static var games: Array[Dictionary] = []


static func scan() -> Array[Dictionary]:
	games.clear()
	if OS.has_feature("web"):
		# Web：游戏包为部署目录旁路文件（games/*.pck，控制主包单文件体积），
		# 启动时逐个 HTTP 下载到 user://cache 再挂载；index.txt / version.txt
		# 构建期生成并打进主包，version.txt 作缓存指纹，未变则免重复下载
		await _mount_packs_web()
		_collect_manifests_web()
	else:
		_mount_packs()
		_collect_manifests()
	print("[GameManager] 已注册游戏 %d 个:" % games.size())
	for g in games:
		print("[GameManager]   %s v%s — %s" % [g.id, g.version, g.name])
	return games


## 游戏包来源目录：导出后为 exe 旁 games/，开发期为项目内 res://games
static func _packs_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://" + GAMES_SUBDIR)
	return OS.get_executable_path().get_base_dir().path_join(GAMES_SUBDIR)


static func _mount_packs() -> void:
	var dir := _packs_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return
	var d := DirAccess.open(dir)
	if d == null:
		push_warning("games 目录无法打开: %s" % dir)
		return
	d.list_dir_begin()
	var file := d.get_next()
	while file != "":
		if not d.current_is_dir():
			var full := dir.path_join(file)
			if file.get_extension() == "pck":
				_mount_pack(full)
			elif file.get_extension() == "zip":
				_mount_zip(full)
		file = d.get_next()
	d.list_dir_end()


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


## 遍历 res://games/ 下每个子目录的 manifest.json（含挂载包贡献的路径），按 id 去重
static func _collect_manifests() -> void:
	var games_root := "res://" + GAMES_SUBDIR
	if not DirAccess.dir_exists_absolute(games_root):
		return
	var seen := {}
	var d := DirAccess.open(games_root)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir() and not name.begins_with("."):
			var info := _read_manifest(games_root.path_join(name).path_join(MANIFEST_NAME))
			if info.is_empty():
				push_warning("跳过无效游戏目录: %s" % name)
			elif seen.has(info.id):
				push_warning("重复游戏 id 已忽略: %s" % info.id)
			else:
				seen[info.id] = true
				games.append(info)
		name = d.get_next()
	d.list_dir_end()


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
## 沙箱不能列目录，全部按清单驱动；随后逐个读取 manifest。

static func _mount_packs_web() -> void:
	var txt := FileAccess.get_file_as_string("res://" + GAMES_SUBDIR + "/index.txt")
	if txt.is_empty():
		push_warning("Web: games/index.txt 缺失或为空（需在导出前生成）")
		return
	DirAccess.make_dir_recursive_absolute(ZIP_CACHE_DIR)
	var stamp := FileAccess.get_file_as_string("res://games/version.txt").strip_edges()
	var cache_hit := stamp != "" and FileAccess.get_file_as_string(CACHE_VER) == stamp
	for line in txt.split("\n", false):
		var id := line.strip_edges()
		if id.is_empty() or not id.ends_with(".pck"):
			continue
		var cache_path := ZIP_CACHE_DIR.path_join(id)
		if not (cache_hit and FileAccess.file_exists(cache_path)):
			var buf := await _http_download(GAMES_SUBDIR + "/" + id)
			if buf.is_empty():
				push_error("Web: 游戏包下载失败，跳过 " + id)
				continue
			var f := FileAccess.open(cache_path, FileAccess.WRITE)
			if f == null:
				push_error("Web: 游戏包落盘失败 " + cache_path)
				continue
			f.store_buffer(buf)
			f.close()
		_mount_pack(cache_path)
	if stamp != "":
		var vf := FileAccess.open(CACHE_VER, FileAccess.WRITE)
		if vf != null:
			vf.store_string(stamp)
			vf.close()


## Web 下载部署目录相对路径文件，返回字节（失败返回空）。
## 不用 HTTPRequest：其 web 端内部实现（godot_js_fetch）在部分 HTTPS/HTTP2 CDN
## 环境（如 GitHub Pages）整条链路报 RESULT_REQUEST_FAILED（result=8 code=200）。
## 改用页面原生 fetch（引擎 wasm 即由此加载，实测可用）+ js_buffer_to_packed_byte_array 取回字节，
## fetch 为异步而 eval 同步，结果暂存 window 后轮询等待。
static func _http_download(rel_path: String) -> PackedByteArray:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return PackedByteArray()
	var raw = JavaScriptBridge.eval("new URL('./%s', window.location.href).href" % rel_path, true)
	if raw == null:
		print("[GameManager] URL 解析失败: %s" % rel_path)
		return PackedByteArray()
	var url := String(raw)
	JavaScriptBridge.eval("""
window.__dtFetch = { done: false, ok: false, data: null };
fetch('%s').then(function(r) {
	return r.arrayBuffer().then(function(b) {
		window.__dtFetch.done = true;
		window.__dtFetch.ok = r.ok;
		window.__dtFetch.data = new Uint8Array(b);
	});
}).catch(function() {
	window.__dtFetch.done = true;
	window.__dtFetch.ok = false;
});
""" % url, true)
	for i in 600:
		if bool(JavaScriptBridge.eval("window.__dtFetch.done", true)):
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


static func _collect_manifests_web() -> void:
	var seen := {}
	for g in games:
		seen[g.id] = true
	# 清单里登记的 pck id（文件名去扩展名）
	var txt := FileAccess.get_file_as_string("res://" + GAMES_SUBDIR + "/index.txt")
	if txt.is_empty():
		return
	for line in txt.split("\n", false):
		var pack := line.strip_edges()
		if pack.is_empty() or not pack.ends_with(".pck"):
			continue
		var id := String(pack.get_basename())
		if seen.has(id):
			continue
		var info := _read_manifest("res://" + GAMES_SUBDIR + "/" + id + "/" + MANIFEST_NAME)
		if info.is_empty():
			push_warning("Web: %s manifest 读取失败" % id)
			continue
		if seen.has(info.id):
			continue
		seen[info.id] = true
		games.append(info)
