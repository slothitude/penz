extends PanelContainer
## Glyph labeller — grid of segmented glyphs for confirming/correcting labels.

signal font_built(path: String)
signal closed()

const PenzTheme = preload("res://ui/theme.gd")

var _grid: GridContainer
var _glyphs: Array = []  # [{path, label_edit, texture_rect}]
var _status_label: Label
var _preview_label: Label
var _busy: bool = false


func _ready() -> void:
	anchors_preset = Control.PRESET_FULL_RECT
	add_theme_stylebox_override("panel", PenzTheme.make_panel_bg())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	# Header
	var header := HBoxContainer.new()
	vbox.add_child(header)

	var pad_l := Control.new()
	pad_l.custom_minimum_size = Vector2(PenzTheme.PAD_M, 0)
	header.add_child(pad_l)

	var title := Label.new()
	title.text = "Font Maker"
	title.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", PenzTheme.ACCENT)
	_status_label.add_theme_font_size_override("font_size", 13)
	header.add_child(_status_label)

	header.add_child(PenzTheme.make_icon_button(PenzTheme.ICON_CLOSE, func(): visible = false; closed.emit()))

	var pad_r := Control.new()
	pad_r.custom_minimum_size = Vector2(PenzTheme.PAD_M, 0)
	header.add_child(pad_r)

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
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(actions)

	var clear_btn := Button.new()
	clear_btn.text = "Clear Labels"
	clear_btn.flat = false
	clear_btn.add_theme_stylebox_override("normal", PenzTheme.make_ghost_button())
	clear_btn.add_theme_stylebox_override("hover", PenzTheme.make_ghost_button())
	clear_btn.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	clear_btn.add_theme_font_size_override("font_size", 13)
	clear_btn.pressed.connect(_clear_labels)
	actions.add_child(clear_btn)

	var act_spacer := Control.new()
	act_spacer.custom_minimum_size = Vector2(12, 0)
	actions.add_child(act_spacer)

	var build_btn := Button.new()
	build_btn.text = "Build Font"
	build_btn.flat = false
	build_btn.add_theme_stylebox_override("normal", PenzTheme.make_accent_button())
	build_btn.add_theme_stylebox_override("hover", PenzTheme.make_accent_button())
	build_btn.add_theme_color_override("font_color", Color.WHITE)
	build_btn.add_theme_font_size_override("font_size", 14)
	build_btn.pressed.connect(_build_font)
	actions.add_child(build_btn)

	# Font preview area — paper strip
	var preview_bg := Panel.new()
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = PenzTheme.PAPER_WARM
	preview_style.set_corner_radius_all(PenzTheme.CORNER_S)
	preview_style.content_margin_left = 12
	preview_style.content_margin_right = 12
	preview_style.content_margin_top = 8
	preview_style.content_margin_bottom = 8
	preview_bg.add_theme_stylebox_override("panel", preview_style)
	preview_bg.custom_minimum_size = Vector2(0, 48)
	vbox.add_child(preview_bg)

	_preview_label = Label.new()
	_preview_label.text = "The quick brown fox jumps over the lazy dog 0123456789"
	_preview_label.add_theme_color_override("font_color", PenzTheme.INK)
	_preview_label.add_theme_font_size_override("font_size", 20)
	_preview_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preview_label.anchors_preset = Control.PRESET_FULL_RECT
	preview_bg.add_child(_preview_label)


func load_glyphs(glyph_paths: Array, ocr_hints: PackedStringArray = []) -> void:
	for child in _grid.get_children():
		child.queue_free()
	_glyphs.clear()

	for i in range(glyph_paths.size()):
		var path: String = glyph_paths[i]
		var card := _create_glyph_card(path, i, ocr_hints[i] if i < ocr_hints.size() else "")
		_grid.add_child(card)


func _create_glyph_card(glyph_path: String, index: int, hint: String) -> VBoxContainer:
	var card := VBoxContainer.new()
	card.alignment = BoxContainer.ALIGNMENT_CENTER

	# Card background
	var card_bg := Panel.new()
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = PenzTheme.CHROME_RAISED
	card_style.set_corner_radius_all(PenzTheme.CORNER_S)
	card_bg.add_theme_stylebox_override("panel", card_style)
	card_bg.custom_minimum_size = Vector2(88, 88)

	# Glyph image
	var tex := _load_glyph_texture(glyph_path)
	var img := TextureRect.new()
	img.texture = tex
	img.custom_minimum_size = Vector2(70, 70)
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.anchors_preset = Control.PRESET_FULL_RECT
	card_bg.add_child(img)

	card.add_child(card_bg)

	# Label input — accent underline
	var label_edit := LineEdit.new()
	label_edit.text = hint
	label_edit.placeholder_text = "?"
	label_edit.max_length = 2
	label_edit.custom_minimum_size = Vector2(60, 28)
	label_edit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	label_edit.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	label_edit.add_theme_color_override("caret_color", PenzTheme.ACCENT)
	var edit_bg := StyleBoxFlat.new()
	edit_bg.bg_color = Color(1, 1, 1, 0.04)
	edit_bg.set_corner_radius_all(PenzTheme.CORNER_S)
	edit_bg.border_color = PenzTheme.ACCENT
	edit_bg.set_border_width(SIDE_BOTTOM, 2)
	label_edit.add_theme_stylebox_override("normal", edit_bg)
	label_edit.add_theme_stylebox_override("focus", edit_bg)
	card.add_child(label_edit)

	_glyphs.append({"path": glyph_path, "label_edit": label_edit, "index": index})
	return card


func _load_glyph_texture(path: String) -> ImageTexture:
	var img := Image.load_from_file(path)
	if img:
		return ImageTexture.create_from_image(img)
	img = Image.create(80, 80, false, Image.FORMAT_RGBA8)
	img.fill(PenzTheme.CHROME_RAISED)
	return ImageTexture.create_from_image(img)


func _build_font() -> void:
	if _busy:
		return
	_busy = true
	_status_label.text = "Building font..."

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

	_wait_for_build(pid, output + "handwriting.ttf")


func _wait_for_build(pid: int, output_path: String) -> void:
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
		_preview_label.add_theme_color_override("font_color", PenzTheme.INK)
	else:
		_preview_label.text = "(Preview unavailable)"
