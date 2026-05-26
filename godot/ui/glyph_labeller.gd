extends PanelContainer
## Glyph labeller — grid of segmented glyphs for confirming/correcting labels.
## Launched after fontmaker.py segment, before fontmaker.py build.

signal font_built(path: String)
signal closed()

var _grid: GridContainer
var _glyphs: Array = []  # [{path, label_edit, texture_rect}]
var _status_label: Label
var _preview_label: Label
var _busy: bool = false

const BG_COLOR := Color(0.1, 0.1, 0.1, 0.98)
const ACCENT := Color(0.3, 0.8, 0.4)


func _ready() -> void:
	anchors_preset = Control.PRESET_FULL_RECT
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	add_theme_stylebox_override("panel", bg)

	var vbox := VBoxContainer.new()
	add_child(vbox)

	# Header
	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Font Maker — Label Glyphs"
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", ACCENT)
	header.add_child(_status_label)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.flat = true
	close_btn.pressed.connect(func(): visible = false; closed.emit())
	header.add_child(close_btn)

	# Scrollable grid area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 5
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	scroll.add_child(_grid)

	# Bottom actions
	var actions := HBoxContainer.new()
	vbox.add_child(actions)

	var build_btn := Button.new()
	build_btn.text = "Build Font"
	build_btn.pressed.connect(_build_font)
	actions.add_child(build_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear All Labels"
	clear_btn.pressed.connect(_clear_labels)
	actions.add_child(clear_btn)

	# Font preview area
	_preview_label = Label.new()
	_preview_label.text = "The quick brown fox jumps over the lazy dog 0123456789"
	_preview_label.add_theme_color_override("font_color", Color.WHITE)
	_preview_label.add_theme_font_size_override("font_size", 20)
	_preview_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preview_label.custom_minimum_size = Vector2(0, 40)
	vbox.add_child(_preview_label)


func load_glyphs(glyph_paths: Array, ocr_hints: PackedStringArray = []) -> void:
	# Clear existing
	for child in _grid.get_children():
		child.queue_free()
	_glyphs.clear()

	for i in range(glyph_paths.size()):
		var path: String = glyph_paths[i]
		var card := _create_glyph_card(path, i, ocr_hints[i] if i < ocr_hints.size() else "")
		_grid.add_child(card)


func _create_glyph_card(glyph_path: String, index: int, hint: String) -> VBoxContainer:
	var card := VBoxContainer.new()

	# Glyph image
	var tex := _load_glyph_texture(glyph_path)
	var img := TextureRect.new()
	img.texture = tex
	img.custom_minimum_size = Vector2(80, 80)
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	card.add_child(img)

	# Label input
	var label_edit := LineEdit.new()
	label_edit.text = hint
	label_edit.placeholder_text = "?"
	label_edit.max_length = 2
	label_edit.custom_minimum_size = Vector2(60, 30)
	label_edit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	label_edit.add_theme_color_override("font_color", Color.WHITE)
	card.add_child(label_edit)

	_glyphs.append({"path": glyph_path, "label_edit": label_edit, "index": index})
	return card


func _load_glyph_texture(path: String) -> ImageTexture:
	var img := Image.load_from_file(path)
	if img:
		return ImageTexture.create_from_image(img)
	# Fallback: empty texture
	img = Image.create(80, 80, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.2, 0.2))
	return ImageTexture.create_from_image(img)


func _build_font() -> void:
	if _busy:
		return
	_busy = true
	_status_label.text = "Building font..."

	# Collect labels
	var labels: PackedStringArray = []
	for g in _glyphs:
		var text: String = g["label_edit"].text.strip_edges()
		if text == "":
			text = "?"
		labels.append(text)

	var label_str := ",".join(labels)
	var glyphs_dir := ""
	if _glyphs.size() > 0:
		glyphs_dir = _glyphs[0]["path"].get_base_dir()

	# Launch fontmaker.py build as subprocess
	var script := ProjectSettings.globalize_path("res://fontmaker.py")
	var output := ProjectSettings.globalize_path("user://fonts/")
	var args := PackedStringArray([
		script, "build",
		"--glyphs", glyphs_dir,
		"--labels", label_str,
		"--output", output + "handwriting.ttf"
	])

	var pid := OS.create_process("python", args)
	if pid == -1:
		_status_label.text = "Failed to start fontmaker.py"
		_busy = false
		return

	# Wait for completion (poll)
		await _wait_for_build(pid, output + "handwriting.ttf")


func _wait_for_build(pid: int, output_path: String) -> void:
	# Poll for process completion
	for i in range(300):  # 30s timeout
		await get_tree().create_timer(0.1).timeout
		if not OS.is_process_running(pid):
			break

	_busy = false
	if FileAccess.file_exists(output_path):
		_status_label.text = "Font built: " + output_path.get_file()
		_load_font_preview(output_path)
		font_built.emit(output_path)
	else:
		_status_label.text = "Build failed — check console"


func _clear_labels() -> void:
	for g in _glyphs:
		g["label_edit"].text = ""


func _load_font_preview(font_path: String) -> void:
	var font := FontFile.new()
	if font.load_dynamic_font(font_path) == OK:
		_preview_label.add_theme_font_override("font", font)
		_preview_label.add_theme_color_override("font_color", ACCENT)
	else:
		_preview_label.text = "(Preview unavailable)"
