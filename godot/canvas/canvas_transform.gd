extends RefCounted
## Maps Wacom Slate coordinates (21600x14700) to screen space.
## Rotated 90° clockwise so portrait Slate maps to landscape screen.

const SLATE_W: int = 21600
const SLATE_H: int = 14700


static func wacom_to_screen(wx: int, wy: int, canvas_size: Vector2) -> Vector2:
	# Rotate 90° counter-clockwise: screen_x = (SLATE_H - wy), screen_y = wx
	# Rotated effective dimensions: SLATE_H x SLATE_W
	var rot_x: float = SLATE_H - wy
	var rot_y: float = wx
	var scale := minf(canvas_size.x / SLATE_H, canvas_size.y / SLATE_W)
	var offset := (canvas_size - Vector2(SLATE_H, SLATE_W) * scale) / 2.0
	return Vector2(rot_x, rot_y) * scale + offset


static func get_scale(canvas_size: Vector2) -> float:
	return minf(canvas_size.x / SLATE_H, canvas_size.y / SLATE_W)
