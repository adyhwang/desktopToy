class_name GameCard
extends TextureButton
## 启动界面游戏图标：hover 缩放 1.0→1.08 + 透明度 1.0→0.6（0.12s），纯色极简无边框

signal activated(info: Dictionary)

const SIZE := 120.0
const HOVER_SCALE := 1.08
const HOVER_ALPHA := 0.6
const HOVER_TIME := 0.12

static var _fallback: ImageTexture

var _info: Dictionary
var _tween: Tween


static func new_card(info: Dictionary) -> GameCard:
	var card := GameCard.new()
	card._info = info
	card.custom_minimum_size = Vector2(SIZE, SIZE)
	card.ignore_texture_size = true
	card.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	card.texture_normal = _load_icon(info)
	card.mouse_entered.connect(card._on_hover.bind(true))
	card.mouse_exited.connect(card._on_hover.bind(false))
	card.pressed.connect(func() -> void: card.activated.emit(card._info))
	return card


static func _load_icon(info: Dictionary) -> Texture2D:
	var icon_path := String(info.icon)
	if not icon_path.is_empty():
		# 导入型资源（.ctex 等，正式导出包产物）走标准加载
		if ResourceLoader.exists(icon_path):
			var tex: Texture2D = load(icon_path)
			if tex != null:
				return tex
		# pck 内原始图片文件（手打包/zip 直放）无资源 loader，手动解码
		var raw := _load_raw_image(icon_path)
		if raw != null:
			return raw
	return _fallback_icon()


static func _load_raw_image(path: String) -> ImageTexture:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var buf := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	var ok := false
	match path.get_extension().to_lower():
		"png":
			ok = img.load_png_from_buffer(buf) == OK
		"jpg", "jpeg":
			ok = img.load_jpg_from_buffer(buf) == OK
		"webp":
			ok = img.load_webp_from_buffer(buf) == OK
		"bmp":
			ok = img.load_bmp_from_buffer(buf) == OK
		_:
			return null
	if not ok:
		push_warning("图标解码失败: %s" % path)
		return null
	return ImageTexture.create_from_image(img)


## 无图标游戏的占位：浅灰圆盘，运行时生成不落盘
static func _fallback_icon() -> ImageTexture:
	if _fallback == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		var center := Vector2(32, 32)
		for y in 64:
			for x in 64:
				if Vector2(x, y).distance_to(center) < 28.0:
					img.set_pixel(x, y, Color(1, 1, 1, 0.85))
		_fallback = ImageTexture.create_from_image(img)
	return _fallback


func _on_hover(entered: bool) -> void:
	pivot_offset = size / 2.0
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var target := HOVER_SCALE if entered else 1.0
	_tween.tween_property(self, "scale", Vector2.ONE * target, HOVER_TIME)
	_tween.tween_property(self, "modulate:a", HOVER_ALPHA if entered else 1.0, HOVER_TIME)
