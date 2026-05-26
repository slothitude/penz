extends Control
## Main entry point — CanvasLayer overlay architecture.
## InkCanvas fills the screen, HUD/toolbar float over it.

@onready var ble = $BLEBridge
@onready var ink_canvas = $InkCanvas
@onready var hud_layer: CanvasLayer = $HUDLayer
@onready var hud = $HUDLayer/HUD
@onready var toolbar_layer: CanvasLayer = $ToolbarLayer
@onready var toolbar = $ToolbarLayer/Toolbar
@onready var dialog_layer: CanvasLayer = $DialogLayer
@onready var connect_dialog = $DialogLayer/ConnectDialog
@onready var gallery = $DialogLayer/Gallery
@onready var settings_panel = $DialogLayer/SettingsPanel
@onready var ocr_panel = $DialogLayer/OCRPanel
@onready var glyph_labeller = $DialogLayer/GlyphLabeller

var _point_count: int = 0
var _hud_visible: bool = true
var _page_just_saved: bool = false
var _executing: bool = false
var _press_count: int = 0
var _press_timer: Timer


func _ready() -> void:
	# Wire BLE signals
	ble.connected.connect(_on_ble_connected)
	ble.disconnected.connect(_on_ble_disconnected)
	ble.point_received.connect(_on_point)
	ble.stroke_end_received.connect(_on_stroke_end)
	ble.status_updated.connect(_on_status)
	ble.connection_progress.connect(_on_connection_progress)
	ble.button_pressed.connect(_on_button_pressed)
	ble.pages_synced.connect(_on_pages_synced)

	# Wire UI signals
	toolbar.connect_pressed.connect(_on_connect)
	toolbar.new_page_pressed.connect(_on_new_page)
	toolbar.sync_pressed.connect(_on_sync)
	toolbar.ocr_pressed.connect(_on_ocr)
	toolbar.font_pressed.connect(_on_font)
	hud.gallery_pressed.connect(_show_gallery)
	hud.settings_pressed.connect(_show_settings)
	hud.hw_button_pressed.connect(_on_button_pressed)

	connect_dialog.visible = false
	gallery.visible = false
	settings_panel.visible = false
	ocr_panel.visible = false
	glyph_labeller.visible = false

	# Button gesture timer
	_press_timer = Timer.new()
	_press_timer.one_shot = true
	_press_timer.wait_time = 0.4
	_press_timer.timeout.connect(_on_press_timeout)
	add_child(_press_timer)

	# Load saved UUID
	settings_panel.uuid_loaded.connect(ble.set_uuid)

	# Auto-hide HUD on Android after 3s of no drawing
	if OS.has_feature("android"):
		_schedule_hud_auto_hide()


func _input(event: InputEvent) -> void:
	# Toggle HUD visibility on tap (Android) or right-click (desktop)
	if event is InputEventScreenTouch and event.pressed:
		if not _is_over_ui(event.position):
			_toggle_hud()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_toggle_hud()


func _toggle_hud() -> void:
	_hud_visible = not _hud_visible
	hud_layer.visible = _hud_visible
	toolbar_layer.visible = _hud_visible


func _is_over_ui(pos: Vector2) -> bool:
	# Check if touch is on HUD or toolbar area
	var hud_rect := Rect2(Vector2.ZERO, Vector2(size.x, 48))
	var tb_rect := Rect2(Vector2(0, size.y - 52), Vector2(size.x, 52))
	return hud_rect.has_point(pos) or tb_rect.has_point(pos)


func _schedule_hud_auto_hide() -> void:
	var t := get_tree().create_timer(3.0)
	t.timeout.connect(func():
		if _point_count > 0:
			_hud_visible = false
			hud_layer.visible = false
			toolbar_layer.visible = false
	)


# ── BLE callbacks ───────────────────────────────────────────────────

func _on_connect() -> void:
	if ble.is_connected_to_device():
		ble.disconnect_device()
		toolbar.set_connected(false)
		return
	connect_dialog.show_progress()
	ble.connect_device(settings_panel.get_uuid_hex())


func _on_ble_connected() -> void:
	connect_dialog.show_connected()
	toolbar.set_connected(true)
	hud.set_connected(true)


func _on_ble_disconnected() -> void:
	connect_dialog.visible = false
	toolbar.set_connected(false)
	hud.set_connected(false)
	if _page_just_saved:
		_page_just_saved = false
		return
	# Auto-save page on disconnect
	if not ink_canvas.get_store().is_empty():
		var path: String = ink_canvas.save_current_page()
		if path != "":
			print("Page saved: ", path)
		ink_canvas.clear()
		_point_count = 0
		toolbar.set_point_count(0)


func _on_point(x: int, y: int, pressure: int) -> void:
	ink_canvas.add_point(x, y, pressure)
	_point_count += 1
	toolbar.set_point_count(_point_count)


func _on_stroke_end() -> void:
	ink_canvas.pen_up()


func _on_status(info: Dictionary) -> void:
	hud.set_battery(info.get("battery", -1))
	hud.set_mode(info.get("mode", "unknown"))


func _on_connection_progress(step: String) -> void:
	connect_dialog.set_step(step)


func _on_new_page() -> void:
	# Called from toolbar "New" button — immediate save, no gesture delay
	_press_timer.stop()
	_press_count = 0
	_page_just_saved = true
	ink_canvas.save_current_page()
	ink_canvas.clear()
	_point_count = 0
	toolbar.set_point_count(0)


func _on_button_pressed() -> void:
	# Called from BLE 0xCB or GUI button — gesture detection
	if _executing:
		return
	hud.flash_button()
	_press_count += 1
	hud.show_message("Button x%d" % _press_count)
	if _press_count == 1:
		_press_timer.start()
	elif _press_count >= 2:
		_press_timer.stop()
		_press_count = 0
		_execute_double_press()


func _on_press_timeout() -> void:
	var presses := _press_count
	_press_count = 0
	if presses == 1:
		_execute_single_press()


func _execute_single_press() -> void:
	_executing = true
	hud.show_message("Saved")
	_page_just_saved = true
	ink_canvas.save_current_page()
	ink_canvas.clear()
	_point_count = 0
	toolbar.set_point_count(0)
	_executing = false


func _execute_double_press() -> void:
	_executing = true
	hud.show_message("OCR + Save")
	_page_just_saved = true
	# Run OCR before clearing
	var png_data: PackedByteArray = await ink_canvas.export_png()
	if png_data.size() > 0:
		ocr_panel.run_ocr(png_data)
	ink_canvas.save_current_page()
	ink_canvas.clear()
	_point_count = 0
	toolbar.set_point_count(0)
	_executing = false


func _on_sync() -> void:
	ble.sync_pages()


func _on_pages_synced(page_paths: PackedStringArray) -> void:
	if page_paths.size() > 0:
		hud.show_message("Synced %d pages" % page_paths.size())
		gallery.refresh()


func _on_ocr() -> void:
	var png_data: PackedByteArray = await ink_canvas.export_png()
	if png_data.size() > 0:
		ocr_panel.run_ocr(png_data)


func _show_gallery() -> void:
	gallery.refresh()
	gallery.visible = true


func _show_settings() -> void:
	settings_panel.visible = true


# ── Font maker ──────────────────────────────────────────────────────

var _segment_pid: int = -1
var _segment_timer: Timer


func _on_font() -> void:
	if ink_canvas.get_store().is_empty():
		hud.show_message("Draw glyphs first")
		return
	hud.show_message("Segmenting...")
	var png_data: PackedByteArray = await ink_canvas.export_png()
	if png_data.size() == 0:
		hud.show_message("Export failed")
		return

	# Save PNG to temp file for fontmaker.py
	var tmp_dir := ProjectSettings.globalize_path("user://tmp")
	if not DirAccess.dir_exists_absolute(tmp_dir):
		DirAccess.make_dir_recursive_absolute(tmp_dir)
	var img_path := tmp_dir + "/font_input.png"
	var f := FileAccess.open(img_path, FileAccess.WRITE)
	if not f:
		hud.show_message("Cannot write temp")
		return
	f.store_buffer(png_data)
	f.close()

	var outdir := tmp_dir + "/glyphs"
	# Clean old glyphs
	if DirAccess.dir_exists_absolute(outdir):
		var da := DirAccess.open(outdir)
		if da:
			da.list_dir_begin()
			var fn := da.get_next()
			while fn != "":
				if not da.current_is_dir():
					da.remove(fn)
				fn = da.get_next()

	var script := ProjectSettings.globalize_path("res://fontmaker.py")
	var args := PackedStringArray([
		script, "segment",
		"--input", img_path,
		"--outdir", outdir
	])

	_segment_pid = OS.create_process("python", args)
	if _segment_pid == -1:
		hud.show_message("Cannot start fontmaker")
		return

	# Poll for completion
	if _segment_timer:
		_segment_timer.stop()
	_segment_timer = Timer.new()
	_segment_timer.wait_time = 0.2
	_segment_timer.timeout.connect(_poll_segment.bind(outdir))
	add_child(_segment_timer)
	_segment_timer.start()


func _poll_segment(outdir: String) -> void:
	if _segment_pid != -1 and OS.is_process_running(_segment_pid):
		return
	_segment_timer.stop()
	_segment_timer.queue_free()
	_segment_timer = null

	# Collect glyph PNGs
	if not DirAccess.dir_exists_absolute(outdir):
		hud.show_message("Segment failed")
		_segment_pid = -1
		return

	var da := DirAccess.open(outdir)
	if not da:
		hud.show_message("Cannot read glyphs")
		_segment_pid = -1
		return

	var paths: Array = []
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if fn.ends_with(".png"):
			paths.append(outdir + "/" + fn)
		fn = da.get_next()

	if paths.is_empty():
		hud.show_message("No glyphs found")
		_segment_pid = -1
		return

	paths.sort()
	glyph_labeller.load_glyphs(paths)
	glyph_labeller.visible = true
	hud.show_message("Found %d glyphs" % paths.size())
	_segment_pid = -1
