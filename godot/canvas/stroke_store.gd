extends RefCounted
## Stores stroke data and exports SVG (same format as canvas.py).

var strokes: Array = []  # Array of Array[(x, y, pressure)]
var _current: Array = []


func add_point(x: int, y: int, pressure: int) -> void:
	_current.append([x, y, pressure])


func pen_up() -> void:
	if _current.size() > 0:
		strokes.append(_current)
		_current = []


func clear() -> void:
	strokes.clear()
	_current.clear()


func is_empty() -> bool:
	return strokes.is_empty() and _current.is_empty()


func to_svg() -> String:
	var paths: PackedStringArray = []
	for stroke in strokes:
		for i in range(1, stroke.size()):
			var p0 = stroke[i - 1]
			var p1 = stroke[i]
			if p0[2] == 0 and p1[2] == 0:
				continue
			var w: float = maxf(1.0, ((p0[2] + p1[2]) / 2.0) / 200.0)
			paths.append(
				'<line x1="%.0f" y1="%.0f" x2="%.0f" y2="%.0f" stroke-width="%.1f" stroke-linecap="round"/>' % [
					p0[0], p0[1], p1[0], p1[1], w
				]
			)
	var body := "\n  ".join(paths) if paths else ""
	return (
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 21600 14700">\n' +
		'<rect width="100%%" height="100%%" fill="white"/>\n' +
		'<g stroke="black" stroke-linecap="round" stroke-linejoin="round">\n' +
		'  %s\n' +
		'</g>\n</svg>'
	) % body


func save_svg(path: String) -> void:
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(to_svg())
		f.close()
