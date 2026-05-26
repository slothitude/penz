extends HBoxContainer
## Bottom toolbar — floating overlay with icon-first design.

signal connect_pressed()
signal new_page_pressed()
signal sync_pressed()
signal ocr_pressed()
signal font_pressed()

const PenzTheme = preload("res://ui/theme.gd")

const S := PenzTheme.UI_SCALE
const BAR_H := 56.0 * S

var _connect_btn: Control  # Button inside ConnectBtn VBox
var _point_label: Label
var _thickness_label: Label
var _connected := false
var _point_fade_tween: Tween

const THICKNESSES := [0.5, 1.0, 1.5, 2.0, 3.0]
var _thickness_idx: int = 1  # default 1.0


func _ready() -> void:
	# Background — ColorRect in the CanvasLayer
	var bg := ColorRect.new()
	bg.color = PenzTheme.CHROME_BG
	bg.z_index = -1
	bg.name = "TBBg"
	get_parent().call_deferred("add_child", bg)
	_set_bg.call_deferred(bg)

	var pad_l := Control.new()
	pad_l.custom_minimum_size = Vector2(8 * S, 0)
	add_child(pad_l)

	# Group 1: Connect, New, Sync
	_connect_btn = Button.new()  # placeholder, actual button is inside VBox
	var connect_vbox := _make_icon_label(PenzTheme.ICON_CONNECT, "Connect", func(): connect_pressed.emit())
	connect_vbox.name = "ConnectBtn"
	_connect_btn = connect_vbox.get_child(0)
	add_child(connect_vbox)

	_add_divider()

	add_child(_make_icon_label(PenzTheme.ICON_NEW, "New", func(): new_page_pressed.emit()))
	add_child(_make_icon_label(PenzTheme.ICON_SYNC, "Sync", func(): sync_pressed.emit()))

	_add_divider()

	# Group 2: OCR, Font
	add_child(_make_icon_label(PenzTheme.ICON_OCR, "OCR", func(): ocr_pressed.emit()))
	add_child(_make_icon_label(PenzTheme.ICON_FONT, "Font", func(): font_pressed.emit()))

	_add_divider()

	# Group 3: Thickness
	var thick_bg := Panel.new()
	var thick_style := StyleBoxFlat.new()
	thick_style.bg_color = PenzTheme.CHROME_RAISED
	thick_style.set_corner_radius_all(PenzTheme.CORNER_S)
	thick_style.content_margin_left = 4 * S
	thick_style.content_margin_right = 4 * S
	thick_style.content_margin_top = 2 * S
	thick_style.content_margin_bottom = 2 * S
	thick_bg.add_theme_stylebox_override("panel", thick_style)

	var thick_hbox := HBoxContainer.new()
	thick_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	thick_bg.add_child(thick_hbox)

	var minus_btn := _make_icon_btn(PenzTheme.ICON_MINUS, _thinner)
	thick_hbox.add_child(minus_btn)

	_thickness_label = Label.new()
	_thickness_label.text = "1.0x"
	_thickness_label.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_thickness_label.add_theme_font_size_override("font_size", int(13 * S))
	_thickness_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_thickness_label.custom_minimum_size = Vector2(36 * S, 20 * S)
	thick_hbox.add_child(_thickness_label)

	thick_hbox.add_child(_make_icon_btn(PenzTheme.ICON_PLUS, _thicker))

	thick_bg.custom_minimum_size.y = 48 * S
	add_child(thick_bg)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	# Point count — fades when idle
	_point_label = Label.new()
	_point_label.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)
	_point_label.add_theme_font_size_override("font_size", int(12 * S))
	_point_label.text = "0 pts"
	_point_label.modulate.a = 0.3
	add_child(_point_label)

	var pad_r := Control.new()
	pad_r.custom_minimum_size = Vector2(8 * S, 0)
	add_child(pad_r)


func _set_bg(bg: ColorRect) -> void:
	var vp_size := get_viewport().get_visible_rect().size
	bg.position = Vector2(0, vp_size.y - BAR_H)
	bg.size = Vector2(vp_size.x, BAR_H)


func set_connected(connected: bool) -> void:
	_connected = connected
	var connect_vbox: VBoxContainer = get_node_or_null("ConnectBtn")
	if not connect_vbox:
		return
	var btn: Button = connect_vbox.get_child(0)
	var lbl: Label = connect_vbox.get_child(1)
	btn.text = "✕" if connected else PenzTheme.ICON_CONNECT
	lbl.text = "Disc." if connected else "Connect"

	if connected:
		btn.add_theme_color_override("font_color", PenzTheme.ACCENT)
		btn.add_theme_color_override("font_hover_color", PenzTheme.ACCENT_LITE)
		lbl.add_theme_color_override("font_color", PenzTheme.ACCENT)
	else:
		btn.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
		btn.add_theme_color_override("font_hover_color", PenzTheme.TEXT_PRIMARY)
		lbl.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)


func set_point_count(count: int) -> void:
	_point_label.text = "%d pts" % count
	_point_label.modulate.a = 1.0
	if _point_fade_tween:
		_point_fade_tween.kill()
	_point_fade_tween = create_tween()
	_point_fade_tween.tween_interval(2.0)
	_point_fade_tween.tween_property(_point_label, "modulate:a", 0.3, 0.5)


func _thinner() -> void:
	_thickness_idx = max(0, _thickness_idx - 1)
	_apply_thickness()


func _thicker() -> void:
	_thickness_idx = min(THICKNESSES.size() - 1, _thickness_idx + 1)
	_apply_thickness()


func _apply_thickness() -> void:
	var val: float = THICKNESSES[_thickness_idx]
	_thickness_label.text = "%.1fx" % val
	var StrokeRenderer = preload("res://canvas/stroke_renderer.gd")
	StrokeRenderer.thickness_multiplier = val


func _add_divider() -> void:
	var divider := Control.new()
	divider.custom_minimum_size = Vector2(S, 28 * S)
	divider.z_index = 1
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.08)
	line.size = Vector2(S, 28 * S)
	line.position = Vector2(0, 14 * S)
	divider.add_child(line)
	add_child(divider)


func _make_icon_btn(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = false
	btn.add_theme_stylebox_override("normal", PenzTheme.make_button_style())
	btn.add_theme_stylebox_override("hover", PenzTheme.make_button_hover())
	btn.add_theme_stylebox_override("pressed", PenzTheme.make_button_pressed())
	btn.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	btn.add_theme_color_override("font_hover_color", PenzTheme.TEXT_PRIMARY)
	btn.add_theme_font_size_override("font_size", int(14 * S))
	btn.custom_minimum_size = Vector2(28 * S, 28 * S)
	btn.pressed.connect(callback)
	return btn


func _make_icon_label(icon: String, label: String, callback: Callable) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var btn := Button.new()
	btn.text = icon
	btn.flat = false
	btn.add_theme_stylebox_override("normal", PenzTheme.make_button_style())
	btn.add_theme_stylebox_override("hover", PenzTheme.make_button_hover())
	btn.add_theme_stylebox_override("pressed", PenzTheme.make_button_pressed())
	btn.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	btn.add_theme_color_override("font_hover_color", PenzTheme.TEXT_PRIMARY)
	btn.add_theme_font_size_override("font_size", int(14 * S))
	btn.custom_minimum_size = Vector2(36 * S, 28 * S)
	btn.pressed.connect(callback)
	vbox.add_child(btn)

	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)
	lbl.add_theme_font_size_override("font_size", int(9 * S))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	return vbox
