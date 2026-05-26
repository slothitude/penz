extends Node2D
## Renders a single ink stroke as a thick Line2D.
## Width is based on running average pressure for consistency.

var _points: Array[Vector3] = []  # (x, y, pressure) in screen coords
var _line: Line2D
var _pressure_sum: float = 0.0

const INK_COLOR := Color.BLACK
const BASE_MIN_WIDTH := 2.0
const PRESSURE_DIVISOR := 200.0

## Global thickness multiplier — set by toolbar
static var thickness_multiplier: float = 1.0


func _ready() -> void:
	_line = Line2D.new()
	_line.default_color = INK_COLOR
	_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	_line.joint_mode = Line2D.LINE_JOINT_ROUND
	_line.width = BASE_MIN_WIDTH * thickness_multiplier
	add_child(_line)


func add_point(sx: float, sy: float, pressure: int) -> void:
	_points.append(Vector3(sx, sy, pressure))
	_line.add_point(Vector2(sx, sy))
	if pressure > 0:
		_pressure_sum += pressure
	# Use running average pressure for consistent stroke width
	var count := _points.size()
	if count >= 2:
		var avg_p := _pressure_sum / count
		_line.width = maxf(BASE_MIN_WIDTH, avg_p / PRESSURE_DIVISOR) * thickness_multiplier


func get_point_count() -> int:
	return _points.size()


func get_raw_points() -> Array[Vector3]:
	return _points
