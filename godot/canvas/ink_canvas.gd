extends Control
## Main drawing surface — keeps strokes as live Line2D nodes.
## Only rasterizes on export (SVG/PNG), not during drawing.

const CanvasTransform = preload("res://canvas/canvas_transform.gd")
const StrokeStore = preload("res://canvas/stroke_store.gd")

var _store: RefCounted  # StrokeStore
var _active_stroke: Node2D
var _completed_strokes: Array[Node2D] = []
var _canvas_size: Vector2

signal page_saved(path: String)


func _ready() -> void:
	_store = StrokeStore.new()
	resized.connect(_on_resize)
	_on_resize()


func _on_resize() -> void:
	_canvas_size = size


func add_point(x: int, y: int, pressure: int) -> void:
	if _active_stroke == null:
		_active_stroke = _create_stroke_renderer()
		add_child(_active_stroke)

	var screen_pos := CanvasTransform.wacom_to_screen(x, y, _canvas_size)
	_active_stroke.add_point(screen_pos.x, screen_pos.y, pressure)
	_store.add_point(x, y, pressure)


func pen_up() -> void:
	if _active_stroke == null:
		return
	_store.pen_up()
	_completed_strokes.append(_active_stroke)
	_active_stroke = null


func clear() -> void:
	if _active_stroke:
		_active_stroke.queue_free()
		_active_stroke = null
	for s in _completed_strokes:
		s.queue_free()
	_completed_strokes.clear()
	_store.clear()


func save_current_page() -> String:
	if _store.is_empty():
		return ""

	var dir := "user://pages/"
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var path := dir + "page_%s.svg" % timestamp
	_store.save_svg(path)

	# Save PNG thumbnail alongside SVG
	var thumb_path := path.get_basename() + "_thumb.png"
	_save_thumbnail(thumb_path)

	page_saved.emit(path)
	return path


func get_store() -> RefCounted:
	return _store


func export_png() -> PackedByteArray:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	# White background
	var bg := ColorRect.new()
	bg.color = Color.WHITE
	bg.size = size
	vp.add_child(bg)
	# Render all completed strokes
	for s in _completed_strokes:
		var dup: Node2D = s.duplicate()
		vp.add_child(dup)
	# Render active stroke
	if _active_stroke:
		var dup: Node2D = _active_stroke.duplicate()
		vp.add_child(dup)

	add_child(vp)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw

	var img := vp.get_texture().get_image()
	var png: PackedByteArray = img.save_png_to_buffer()
	vp.queue_free()
	return png


func get_stroke_count() -> int:
	return _completed_strokes.size()


func _save_thumbnail(thumb_path: String) -> void:
	var vp := SubViewport.new()
	var thumb_size := Vector2(432, 294)  # 21600/50 x 14700/50
	vp.size = thumb_size
	vp.transparent_bg = false
	var bg := ColorRect.new()
	bg.color = Color.WHITE
	bg.size = thumb_size
	vp.add_child(bg)
	for s in _completed_strokes:
		var dup: Node2D = s.duplicate()
		# Scale stroke renderers from screen coords to thumbnail
		var scale := thumb_size / _canvas_size
		dup.scale = scale
		dup.position = Vector2.ZERO
		vp.add_child(dup)
	if _active_stroke:
		var dup: Node2D = _active_stroke.duplicate()
		var scale := thumb_size / _canvas_size
		dup.scale = scale
		dup.position = Vector2.ZERO
		vp.add_child(dup)
	add_child(vp)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.save_png(thumb_path)
	vp.queue_free()


func _create_stroke_renderer() -> Node2D:
	var node := Node2D.new()
	node.set_script(load("res://canvas/stroke_renderer.gd"))
	return node
