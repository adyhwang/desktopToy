extends Control
## 拼图方块控件：贴图绘制 + 按压/双击事件上抛（拖拽逻辑由主脚本统一驱动）
## 不使用 class_name（包内自包含）

signal piece_pressed(piece: Control, at: Vector2)      # 按下（开始拖拽候选）
signal piece_double_clicked(piece: Control)            # 双击（顺时针旋转 90°）

const PieceData := preload("res://scripts/piece_data.gd")

var piece_id := ""
var color := Color.WHITE
var cells: Array = []          # 当前旋转态 cells（[row, col]）
var rot := 0                   # 0..3
var cell_px := 64.0            # 当前格子像素
var hinted := false            # 提示高亮中
var _texs: Array = []          # 4 旋转态贴图
var _pressed := false


func setup(id: String, pcolor: Color, base_cells: Array, pcell: float, texs: Array) -> void:
	piece_id = id
	color = pcolor
	_texs = texs
	cell_px = pcell
	set_rotation_state(0, base_cells)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_filter = Control.MOUSE_FILTER_STOP


## 设置旋转态并同步控件尺寸（cells 归一化后的 bounds）
func set_rotation_state(new_rot: int, base_cells: Array) -> void:
	rot = new_rot % 4
	cells = PieceData.rot_states(base_cells)[rot]
	var b := PieceData.bounds(cells)
	custom_minimum_size = Vector2(b.x, b.y) * cell_px
	size = custom_minimum_size
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressed = true
				if mb.double_click:
					piece_double_clicked.emit(self)
				else:
					piece_pressed.emit(self, mb.position)
			else:
				_pressed = false
	elif event is InputEventMouseMotion and _pressed:
		# 按住移动即视为拖拽开始
		piece_pressed.emit(self, event.position)


func _draw() -> void:
	if _texs.is_empty() or rot >= _texs.size():
		return
	var tex: Texture2D = _texs[rot]
	if tex != null:
		draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)
	if hinted:
		# 提示脉冲描边（方块自身颜色提亮）
		var t := Time.get_ticks_msec() / 1000.0
		var a := 0.55 + 0.45 * sin(t * 7.0)
		var hc := color.lightened(0.25)
		draw_rect(Rect2(Vector2.ZERO, size), Color(hc.r, hc.g, hc.b, 0.28 * a), true)
		for i in 3:
			var off := float(i) * 3.0
			draw_rect(Rect2(Vector2(-off, -off), size + Vector2(off * 2, off * 2)),
					Color(hc.r, hc.g, hc.b, a * (0.9 - i * 0.25)), false, 3.0)


## 提示脉冲刷新（主脚本 _process 调用）
func tick_hint() -> void:
	if hinted:
		queue_redraw()
