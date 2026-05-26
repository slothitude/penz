extends PanelContainer
## Gallery overlay — grid of saved pages with view, delete, merge.

const PageStore = preload("res://core/page_store.gd")

var _store: RefCounted
var _grid: GridContainer
var _viewer: PanelContainer
var _viewer_label: Label
var _viewer_image: TextureRect
var _selected: Dictionary = {}  # path -> true
var _merge_btn: Button

const BG_COLOR := Color(0.1, 0.1, 0.1, 0.98)
const ACCENT := Color(0.3, 0.8, 0.4)
const SEL_COLOR := Color(0.2, 0.5, 0.8, 0.3)


func _ready() -> void:
	_store = PageStore.new()

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
	title.text = "Gallery"
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_merge_btn = _make_btn("Merge Selected", _on_merge)
	_merge_btn.visible = false
	header.add_child(_merge_btn)

	var close_btn := _make_btn("Close", func(): visible = false)
	header.add_child(close_btn)

	# Scrollable grid
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)

	# Full-screen viewer
	_viewer = PanelContainer.new()
	_viewer.anchors_preset = Control.PRESET_FULL_RECT
	var vbg := StyleBoxFlat.new()
	vbg.bg_color = Color(0.05, 0.05, 0.05, 0.98)
	_viewer.add_theme_stylebox_override("panel", vbg)

	var vvbox := VBoxContainer.new()
	_viewer.add_child(vvbox)

	var vclose := _make_btn("Close", func(): _viewer.visible = false)
	vvbox.add_child(vclose)

	_viewer_image = TextureRect.new()
	_viewer_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewer_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_viewer_image.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	vvbox.add_child(_viewer_image)

	_viewer_label = Label.new()
	_viewer_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_viewer_label.add_theme_font_size_override("font_size", 12)
	vvbox.add_child(_viewer_label)

	add_child(_viewer)
	_viewer.visible = false


func refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	_selected.clear()
	_merge_btn.visible = false

	var pages: PackedStringArray = _store.list_pages()
	if pages.is_empty():
		var empty := Label.new()
		empty.text = "No saved pages"
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_grid.add_child(empty)
		return

	for page_path in pages:
		_grid.add_child(_create_card(page_path))


func _create_card(page_path: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(160, 130)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.18, 0.18)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(0.3, 0.3, 0.3)
	card.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	card.add_child(vbox)

	# SVG thumbnail
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(140, 95)
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var tex := _load_svg_thumbnail(page_path)
	if tex:
		icon.texture = tex
		# White background behind the SVG
		var bg_rect := ColorRect.new()
		bg_rect.color = Color.WHITE
		bg_rect.custom_minimum_size = Vector2(140, 95)
		icon.add_child(bg_rect)
		icon.move_child(bg_rect, 0)
	else:
		# Fallback
		icon.texture = null
		var fb := ColorRect.new()
		fb.color = Color(0.25, 0.25, 0.25)
		fb.custom_minimum_size = Vector2(140, 95)
		vbox.add_child(fb)
	vbox.add_child(icon)

	# Name
	var name_label := Label.new()
	name_label.text = _store.page_name(page_path)
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	name_label.add_theme_font_size_override("font_size", 11)
	vbox.add_child(name_label)

	# Button row
	var btn_row := HBoxContainer.new()
	vbox.add_child(btn_row)

	btn_row.add_child(_make_small_btn("View", func(): _show_page(page_path)))
	btn_row.add_child(_make_small_btn("Del", func(): _delete_page(page_path, card)))
	btn_row.add_child(_make_small_btn("Sel", func(): _toggle_select(page_path, card)))

	return card


func _show_page(path: String) -> void:
	var tex := _load_svg_thumbnail(path)
	if tex:
		_viewer_image.texture = tex
		_viewer_label.text = path.get_file()
	else:
		_viewer_image.texture = null
		_viewer_label.text = path.get_file() + " (could not load)"
	_viewer.visible = true


func _delete_page(path: String, card: Control) -> void:
	_store.delete_page(path)
	_selected.erase(path)
	card.queue_free()
	_update_merge_btn()


func _toggle_select(path: String, card: Control) -> void:
	if _selected.has(path):
		_selected.erase(path)
		# Reset card border
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.18, 0.18, 0.18)
		style.set_corner_radius_all(8)
		style.set_border_width_all(1)
		style.border_color = Color(0.3, 0.3, 0.3)
		card.add_theme_stylebox_override("panel", style)
	else:
		_selected[path] = true
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.15, 0.25, 0.4)
		style.set_corner_radius_all(8)
		style.set_border_width_all(2)
		style.border_color = ACCENT
		card.add_theme_stylebox_override("panel", style)
	_update_merge_btn()


func _update_merge_btn() -> void:
	_merge_btn.visible = _selected.size() >= 2
	_merge_btn.text = "Merge %d" % _selected.size()


func _on_merge() -> void:
	if _selected.size() < 2:
		return

	# Load and merge SVGs
	var merged_strokes: Array = []
	var paths := _selected.keys()

	for path in paths:
		var svg_path: String = path
		if not FileAccess.file_exists(svg_path):
			continue
		# Parse the stroke data from the SVG — extract line elements
		var f := FileAccess.open(svg_path, FileAccess.READ)
		var svg_text := f.get_as_text()
		f.close()

		# Simple approach: collect all <line .../> elements
		var lines := svg_text.split("<line ")
		for i in range(1, lines.size()):
			var line_text: String = lines[i].split("/>")[0]
			merged_strokes.append(line_text)

	if merged_strokes.is_empty():
		return

	# Build merged SVG
	var body := "\n  ".join(merged_strokes)
	var merged_svg := (
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 21600 14700">\n' +
		'<rect width="100%%" height="100%%" fill="white"/>\n' +
		'<g stroke="black" stroke-linecap="round" stroke-linejoin="round">\n' +
		'  %s\n' +
		'</g>\n</svg>'
	) % body

	# Save merged page
	var dir := "user://pages/"
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var out_path := dir + "merged_%s.svg" % timestamp
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(merged_svg)
	f.close()

	# Generate PNG thumbnail for merged page by loading the SVG as an image
	var thumb_path := out_path.get_basename() + "_thumb.png"
	var svg_img := Image.new()
	if svg_img.load(out_path) == OK:
		svg_img.save_png(thumb_path)

	# Delete source pages
	for path in paths:
		_store.delete_page(path)

	_selected.clear()
	refresh()


func _load_svg_thumbnail(path: String) -> Texture2D:
	# Try PNG thumbnail first (saved alongside SVG on page save)
	var thumb_path := path.get_basename() + "_thumb.png"
	if FileAccess.file_exists(thumb_path):
		var img := Image.new()
		if img.load(thumb_path) == OK:
			var tex := ImageTexture.create_from_image(img)
			if tex:
				return tex
	# Fallback: try loading SVG directly (works for imported resources)
	if FileAccess.file_exists(path):
		var tex: Texture2D = ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE)
		if tex:
			return tex
	return null


func _make_btn(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", ACCENT)
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(callback)
	return btn


func _make_small_btn(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	btn.add_theme_color_override("font_hover_color", ACCENT)
	btn.add_theme_font_size_override("font_size", 12)
	btn.custom_minimum_size = Vector2(40, 24)
	btn.pressed.connect(callback)
	return btn
