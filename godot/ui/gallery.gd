extends PanelContainer
## Gallery overlay — paper cards with tap/long-press, merge support.

const PenzTheme = preload("res://ui/theme.gd")
const PageStore = preload("res://core/page_store.gd")

var _store: RefCounted
var _grid: GridContainer
var _viewer: PanelContainer
var _viewer_label: Label
var _viewer_image: TextureRect
var _selected: Dictionary = {}  # path -> true
var _merge_btn: Button
var _long_press_timer: Timer
var _long_press_target: String = ""


func _ready() -> void:
	_store = PageStore.new()

	anchors_preset = Control.PRESET_FULL_RECT
	# Scrim background
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(PenzTheme.CHROME_BG.r, PenzTheme.CHROME_BG.g, PenzTheme.CHROME_BG.b, 0.0)
	add_theme_stylebox_override("panel", bg)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	# Header
	var header := HBoxContainer.new()
	vbox.add_child(header)

	var pad_l := Control.new()
	pad_l.custom_minimum_size = Vector2(PenzTheme.PAD_L, 0)
	header.add_child(pad_l)

	var title := Label.new()
	title.text = "Pages"
	title.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	title.add_theme_font_size_override("font_size", 22)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_merge_btn = _make_accent_btn("Merge", _on_merge)
	_merge_btn.visible = false
	header.add_child(_merge_btn)

	var delete_btn := _make_danger_btn("Delete", _delete_selected)
	delete_btn.visible = false
	delete_btn.name = "DeleteBtn"
	header.add_child(delete_btn)

	header.add_child(PenzTheme.make_icon_button(PenzTheme.ICON_CLOSE, func(): visible = false))

	var pad_r := Control.new()
	pad_r.custom_minimum_size = Vector2(PenzTheme.PAD_M, 0)
	header.add_child(pad_r)

	# Scrollable grid
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)

	# Full-screen viewer — dark bg with paper page
	_viewer = PanelContainer.new()
	_viewer.anchors_preset = Control.PRESET_FULL_RECT
	var vbg := StyleBoxFlat.new()
	vbg.bg_color = PenzTheme.VIEWER_BG
	_viewer.add_theme_stylebox_override("panel", vbg)

	var vvbox := VBoxContainer.new()
	_viewer.add_child(vvbox)

	var vheader := HBoxContainer.new()
	vvbox.add_child(vheader)
	vheader.add_child(PenzTheme.make_icon_button(PenzTheme.ICON_CLOSE, func(): _viewer.visible = false))

	_viewer_image = TextureRect.new()
	_viewer_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewer_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_viewer_image.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	vvbox.add_child(_viewer_image)

	_viewer_label = Label.new()
	_viewer_label.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)
	_viewer_label.add_theme_font_size_override("font_size", 12)
	_viewer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vvbox.add_child(_viewer_label)

	add_child(_viewer)
	_viewer.visible = false

	# Long press timer for card selection
	_long_press_timer = Timer.new()
	_long_press_timer.one_shot = true
	_long_press_timer.wait_time = 0.5
	_long_press_timer.timeout.connect(_on_long_press)
	add_child(_long_press_timer)


func refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	_selected.clear()
	_merge_btn.visible = false
	_update_delete_btn()

	var pages: PackedStringArray = _store.list_pages()
	if pages.is_empty():
		# Empty state — pen icon + message
		var empty_vbox := VBoxContainer.new()
		empty_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		var pen_icon := Label.new()
		pen_icon.text = "✎"
		pen_icon.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)
		pen_icon.add_theme_font_size_override("font_size", 40)
		pen_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_vbox.add_child(pen_icon)
		var msg := Label.new()
		msg.text = "No pages yet"
		msg.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)
		msg.add_theme_font_size_override("font_size", 14)
		msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_vbox.add_child(msg)
		_grid.add_child(empty_vbox)
		return

	for page_path in pages:
		_grid.add_child(_create_card(page_path))


func _create_card(page_path: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(160, 160)
	card.set_meta("page_path", page_path)
	card.add_theme_stylebox_override("panel", PenzTheme.make_card_bg(false))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	card.add_child(vbox)

	# Padding top
	var pad_t := Control.new()
	pad_t.custom_minimum_size = Vector2(0, 2)
	vbox.add_child(pad_t)

	# SVG thumbnail
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(140, 100)
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var tex := _load_svg_thumbnail(page_path)
	if tex:
		icon.texture = tex
	vbox.add_child(icon)

	# Name — human-readable date
	var name_label := Label.new()
	name_label.text = _format_page_name(page_path)
	name_label.add_theme_color_override("font_color", PenzTheme.TEXT_ON_PAPER)
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_label)

	# Tap = view, long-press = select
	var click_guard := Control.new()
	click_guard.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_guard.z_index = 10
	click_guard.gui_input.connect(func(event: InputEvent):
		var is_press: bool = (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed)
		var is_release: bool = (event is InputEventMouseButton and not event.pressed) or (event is InputEventScreenTouch and not event.pressed)
		if is_press:
			_long_press_target = page_path
			_long_press_timer.start()
		elif is_release:
			if _long_press_timer.is_stopped():
				pass
			else:
				_long_press_timer.stop()
				_show_page(page_path)
	)
	card.add_child(click_guard)

	# Selection badge (hidden by default)
	var badge := Label.new()
	badge.text = " " + PenzTheme.ICON_DONE + " "
	badge.add_theme_color_override("font_color", Color.WHITE)
	badge.add_theme_font_size_override("font_size", 12)
	var badge_bg := StyleBoxFlat.new()
	badge_bg.bg_color = PenzTheme.ACCENT
	badge_bg.set_corner_radius_all(10)
	badge.add_theme_stylebox_override("normal", badge_bg)
	badge.position = Vector2(card.custom_minimum_size.x - 28, 4)
	badge.z_index = 20
	badge.visible = false
	badge.name = "Badge"
	card.add_child(badge)

	return card


func _format_page_name(page_path: String) -> String:
	# Convert "page_2026-05-27_14-30-22" → "May 27, 14:30"
	var fname := page_path.get_file().get_basename()
	var pattern := "page_"
	if not fname.begins_with(pattern):
		return fname
	var date_str := fname.substr(pattern.length())
	var parts := date_str.split("_")
	if parts.size() < 2:
		return date_str
	var date_part: String = parts[0]
	var time_part: String = parts[1]
	var dparts := date_part.split("-")
	var tparts := time_part.split("-")
	if dparts.size() < 3 or tparts.size() < 2:
		return date_str
	var month_names := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var month_idx := dparts[1].to_int() - 1
	if month_idx < 0 or month_idx >= 12:
		return date_str
	return "%s %s, %s:%s" % [month_names[month_idx], dparts[2], tparts[0], tparts[1]]


func _on_long_press() -> void:
	if _long_press_target == "":
		return
	_toggle_select(_long_press_target)
	_long_press_target = ""


func _show_page(path: String) -> void:
	var tex := _load_svg_thumbnail(path)
	if tex:
		_viewer_image.texture = tex
		_viewer_label.text = _format_page_name(path)
	else:
		_viewer_image.texture = null
		_viewer_label.text = path.get_file() + " (could not load)"
	_viewer.visible = true


func _delete_page(path: String) -> void:
	_store.delete_page(path)
	_selected.erase(path)
	_update_merge_btn()
	_update_delete_btn()
	refresh()


func _toggle_select(path: String) -> void:
	if _selected.has(path):
		_selected.erase(path)
	else:
		_selected[path] = true
	_update_card_styles()
	_update_merge_btn()
	_update_delete_btn()


func _update_card_styles() -> void:
	# Find all cards in grid and update their styles
	for child in _grid.get_children():
		if not child is PanelContainer:
			continue
		var card: PanelContainer = child
		# Find the page path from the click guard
		# We need a way to map cards to paths — use metadata
		var page_path: String = card.get_meta("page_path", "")
		if page_path == "":
			continue
		var is_selected := _selected.has(page_path)
		card.add_theme_stylebox_override("panel", PenzTheme.make_card_bg(is_selected))
		# Update badge visibility
		var badge: Label = card.get_node_or_null("Badge")
		if badge:
			badge.visible = is_selected


func _delete_selected() -> void:
	var paths := _selected.keys()
	for path in paths:
		_store.delete_page(path)
	_selected.clear()
	_update_merge_btn()
	_update_delete_btn()
	refresh()


func _update_merge_btn() -> void:
	_merge_btn.visible = _selected.size() >= 2
	_merge_btn.text = "Merge %d" % _selected.size()


func _update_delete_btn() -> void:
	var btn: Button = get_node_or_null("DeleteBtn")
	if btn:
		btn.visible = _selected.size() >= 1


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
		var fh := FileAccess.open(svg_path, FileAccess.READ)
		var svg_text := fh.get_as_text()
		fh.close()

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

	var dir := "user://pages/"
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var out_path := dir + "merged_%s.svg" % timestamp
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(merged_svg)
	f.close()

	# Generate PNG thumbnail
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
	# Try PNG thumbnail first
	var thumb_path := path.get_basename() + "_thumb.png"
	if FileAccess.file_exists(thumb_path):
		var img := Image.new()
		if img.load(thumb_path) == OK:
			var tex := ImageTexture.create_from_image(img)
			if tex:
				return tex
	# Fallback: try loading SVG directly
	if FileAccess.file_exists(path):
		var tex: Texture2D = ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE)
		if tex:
			return tex
	return null


func _make_accent_btn(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = false
	btn.add_theme_stylebox_override("normal", PenzTheme.make_accent_button())
	btn.add_theme_stylebox_override("hover", PenzTheme.make_accent_button())
	btn.add_theme_stylebox_override("pressed", PenzTheme.make_accent_button())
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)
	btn.pressed.connect(callback)
	return btn


func _make_danger_btn(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", PenzTheme.ERROR_RED)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.4, 0.4))
	btn.add_theme_font_size_override("font_size", 13)
	btn.pressed.connect(callback)
	return btn
