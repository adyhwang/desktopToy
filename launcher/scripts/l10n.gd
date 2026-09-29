extends Node
## 多语言服务（autoload 单例 L10n）：主程序界面文案
## 语言文件：主程序所在目录 Language/<lang>.json（开发期为 launcher/Language/），JSON 扁平键值
## 行业习惯命名：en.json（默认）/ zh_CN.json / ja.json ...；"_name" 键存语言自显名
## 切换实时生效：set_language 发 language_changed，界面连接后即时重刷文案
## 选择持久化：user://settings.cfg [general] language（与各游戏共用同一配置）

signal language_changed

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULT_LANG := "en"

var language := DEFAULT_LANG
var _cur: Dictionary = {}
var _en: Dictionary = {}


func _ready() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		language = String(cf.get_value("general", "language", DEFAULT_LANG))
	if not available().has(language):
		language = DEFAULT_LANG
	_load_dicts()


## 可用语言列表（Language 目录下全部 .json 文件名去扩展名，排序，默认语言置顶）
func available() -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(_lang_dir())
	if d != null:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if not d.current_is_dir() and f.get_extension() == "json":
				out.append(f.get_basename())
			f = d.get_next()
		d.list_dir_end()
	if out.has(DEFAULT_LANG):   # 默认语言排最前，其余按字母序
		out.erase(DEFAULT_LANG)
	out.sort()
	out.insert(0, DEFAULT_LANG)
	return out


## 语言自显名（文件内 "_name" 键，缺失回退语言代码）
func lang_display(code: String) -> String:
	var data := _read_file(code)
	return String(data.get("_name", code))


func set_language(code: String) -> void:
	if code == language or not available().has(code):
		return
	language = code
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("general", "language", code)
	cf.save(SETTINGS_PATH)
	_load_dicts()
	language_changed.emit()


## 取文案：当前语言 → 英文 → fallback
func t(key: String, fallback: String = "") -> String:
	return String(_cur.get(key, _en.get(key, fallback)))


func _load_dicts() -> void:
	_en = _read_file(DEFAULT_LANG)
	_cur = _en if language == DEFAULT_LANG else _read_file(language)
	if _cur.is_empty() and language != DEFAULT_LANG:
		language = DEFAULT_LANG
		_cur = _en


func _read_file(code: String) -> Dictionary:
	var f := FileAccess.open(_lang_dir().path_join(code + ".json"), FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_DICTIONARY else {}


## 语言目录：编辑器期用项目内 Language/，发布后用主程序旁 Language/
func _lang_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://Language")
	return OS.get_executable_path().get_base_dir().path_join("Language")
