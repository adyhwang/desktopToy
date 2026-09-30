extends RefCounted
## 方块形状与颜色数据（无 class_name，包内自包含）
## cells 以 [row, col] 格子坐标表示，仅存基础朝向（rot 0），
## 其余 3 个旋转态由 rot_states() 按顺时针公式实时生成。

# ===== 经典方块：标准 7 种 tetromino（I/O/T/S/Z/J/L）=====
const CLASSIC: Array = [
	{"id": "i", "color": Color(0.13, 0.72, 0.78), "cells": [[0, 0], [0, 1], [0, 2], [0, 3]]},
	{"id": "o", "color": Color(0.95, 0.77, 0.06), "cells": [[0, 0], [0, 1], [1, 0], [1, 1]]},
	{"id": "t", "color": Color(0.60, 0.36, 0.80), "cells": [[0, 0], [0, 1], [0, 2], [1, 1]]},
	{"id": "s", "color": Color(0.36, 0.75, 0.29), "cells": [[0, 1], [0, 2], [1, 0], [1, 1]]},
	{"id": "z", "color": Color(0.87, 0.26, 0.25), "cells": [[0, 0], [0, 1], [1, 1], [1, 2]]},
	{"id": "j", "color": Color(0.22, 0.48, 0.85), "cells": [[0, 1], [1, 1], [2, 1], [2, 0]]},
	{"id": "l", "color": Color(0.95, 0.53, 0.13), "cells": [[0, 0], [1, 0], [2, 0], [2, 1]]},
]

# ===== 棱镜方块：16 种异形拼图块，黄 / 绿 / 蓝 / 红 四色各 4 块 =====
const PRISM: Array = [
	# —— 黄组 ——
	{"id": "y1", "color": Color(0.91, 0.70, 0.24), "cells": [[0, 0], [0, 1], [0, 2], [0, 3]]},                     # 光条（4 格直条）
	{"id": "y2", "color": Color(0.91, 0.70, 0.24), "cells": [[0, 1], [0, 2], [1, 0], [1, 1], [2, 1], [2, 2]]},     # 旋梯（6 格）
	{"id": "y3", "color": Color(0.91, 0.70, 0.24), "cells": [[0, 1], [1, 0], [1, 1], [1, 2], [2, 1]]},             # 十字星（5 格）
	{"id": "y4", "color": Color(0.91, 0.70, 0.24), "cells": [[0, 3], [0, 2], [1, 2], [0, 1], [1, 1], [1, 0]]},     # 叠浪（6 格错排）
	# —— 绿组 ——
	{"id": "g1", "color": Color(0.43, 0.71, 0.43), "cells": [[0, 0], [1, 0], [1, 1], [1, 2], [2, 0]]},             # 侧勾（5 格）
	{"id": "g2", "color": Color(0.43, 0.71, 0.43), "cells": [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1]]},             # 方舟（5 格 P 形）
	{"id": "g3", "color": Color(0.43, 0.71, 0.43), "cells": [[0, 2], [1, 1], [1, 2], [2, 0], [2, 1]]},             # 飞阶（5 格斜梯）
	{"id": "g4", "color": Color(0.43, 0.71, 0.43), "cells": [[0, 0], [0, 3], [1, 0], [1, 1], [1, 2], [1, 3]]},     # 凹槽（6 格 U 形）
	# —— 蓝组 ——
	{"id": "b1", "color": Color(0.29, 0.61, 0.83), "cells": [[0, 1], [0, 2], [1, 0], [1, 1], [1, 2], [1, 3]]},     # 拱桥（6 格）
	{"id": "b2", "color": Color(0.29, 0.61, 0.83), "cells": [[0, 0], [0, 1], [0, 2], [1, 2], [2, 2]]},             # 直角尺（5 格 L 角）
	{"id": "b3", "color": Color(0.29, 0.61, 0.83), "cells": [[0, 1], [1, 0], [1, 1], [1, 2], [1, 3], [2, 1]]},     # 长十字（6 格）
	{"id": "b4", "color": Color(0.29, 0.61, 0.83), "cells": [[0, 1], [0, 2], [1, 0], [1, 1]]},                     # 小弯（4 格 S 形）
	# —— 红组 ——
	{"id": "r1", "color": Color(0.85, 0.36, 0.31), "cells": [[0, 3], [1, 0], [1, 1], [1, 2], [1, 3]]},             # 长尾勾（5 格）
	{"id": "r2", "color": Color(0.85, 0.36, 0.31), "cells": [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [2, 0]]},     # 城垛（6 格）
	{"id": "r3", "color": Color(0.85, 0.36, 0.31), "cells": [[0, 1], [1, 0], [1, 1], [1, 2], [2, 1], [2, 2]]},     # 大旋梯（6 格）
	{"id": "r4", "color": Color(0.85, 0.36, 0.31), "cells": [[0, 0], [0, 2], [1, 0], [1, 1], [1, 2]]},             # 跳板（5 格）
]


## 顺时针旋转 90°：(r, c) -> (c, max_r - r)，max_r 取旋转前行数 - 1
static func rot_cw(cells: Array) -> Array:
	var max_r := 0
	for c: Array in cells:
		max_r = maxi(max_r, int(c[0]))
	var out: Array = []
	for c: Array in cells:
		out.append([int(c[1]), max_r - int(c[0])])
	return normalize(out)


## 归一化：平移到最小行 / 列为 0
static func normalize(cells: Array) -> Array:
	var min_r := 9999
	var min_c := 9999
	for c: Array in cells:
		min_r = mini(min_r, int(c[0]))
		min_c = mini(min_c, int(c[1]))
	var out: Array = []
	for c: Array in cells:
		out.append([int(c[0]) - min_r, int(c[1]) - min_c])
	return out


## 4 个旋转态（rot 0..3，顺时针），已各自归一化
static func rot_states(base: Array) -> Array:
	var states: Array = [normalize(base)]
	for i in 3:
		states.append(rot_cw(states[i]))
	return states


## 包围盒尺寸（宽=列数，高=行数）
static func bounds(cells: Array) -> Vector2i:
	var max_r := 0
	var max_c := 0
	for c: Array in cells:
		max_r = maxi(max_r, int(c[0]))
		max_c = maxi(max_c, int(c[1]))
	return Vector2i(max_c + 1, max_r + 1)


## cells 转 Vector2i 集合（用于快速成员判断）
static func cell_set(cells: Array) -> Dictionary:
	var s := {}
	for c: Array in cells:
		s[Vector2i(int(c[1]), int(c[0]))] = true   # key = (col, row)
	return s
