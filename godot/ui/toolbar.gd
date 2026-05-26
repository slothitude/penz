extends HBoxContainer
## Bottom toolbar — floating overlay with thickness control.

signal connect_pressed()
signal new_page_pressed()
signal sync_pressed()
signal ocr_pressed()
signal font_pressed()

var _connect_btn: Button
var _point_label: Label
var _thickness_label: Label

const BG_COLOR := Color(0.08, 0.08, 0.08, 0.85)
const ACCENT := Color(0.3, 0.8, 0.4)

const THICKNESSES := [0.5, 1.0, 1.5, 2.0, 3.0]
var _thickness_idx: int = 1  # default 1.0


func _ready() -> void:
	# Background
	var bg_panel := Panel.new()
	bg_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	bg.set_corner_radius_all(0)
	bg_panel.add_theme_stylebox_override("panel", bg)
	add_child(bg_panel)

	var pad_l := Control.new()
	pad_l.custom_minimum_size = Vector2(6, 0)
	add_child(pad_l)

	_connect_btn = _make_button("Connect", func(): connect_pressed.emit())
	add_child(_connect_btn)

	add_child(_make_button("New", func(): new_page_pressed.emit()))
	add_child(_make_button("Sync", func(): sync_pressed.emit()))
	add_child(_make_button("OCR", func(): ocr_pressed.emit()))
	add_child(_make_button("Font", func(): font_pressed.emit()))

	# Thickness controls
	add_child(_make_button("-", _thinner))

	_thickness_label = Label.new()
	_thickness_label.text = "1.0x"
	_thickness_label.add_theme_color_override("font_color", ACCENT)
	_thickness_label.add_theme_font_size_override("font_size", 14)
	_thickness_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_thickness_label.custom_minimum_size = Vector2(32, 20)
	add_child(_thickness_label)

	add_child(_make_button("+", _thicker))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	_point_label = Label.new()
	_point_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_point_label.add_theme_font_size_override("font_size", 13)
	_point_label.text = "0 pts"
	add_child(_point_label)

	var pad_r := Control.new()
	pad_r.custom_minimum_size = Vector2(6, 0)
	add_child(pad_r)


func set_connected(connected: bool) -> void:
	_connect_btn.text = "Disconnect" if connected else "Connect"
	_connect_btn.add_theme_color_override("font_color", ACCENT if connected else Color.WHITE)


func set_point_count(count: int) -> void:
	_point_label.text = "%d pts" % count


func _thinner() -> void:
	_thickness_idx = max(0, _thickness_idx - 1)
	_apply_thickness()


func _thicker() -> void:
	_thickness_idx = min(THICKNESSES.size() - 1, _thickness_idx + 1)
	_apply_thickness()


func _apply_thickness() -> void:
	var val: float = THICKNESSES[_thickness_idx]
	_thickness_label.text = "%.1fx" % val
	# Update the static variable used by all stroke renderers
	var StrokeRenderer = load("res://canvas/stroke_renderer.gd")
	StrokeRenderer.set("thickness_multiplier", val)


func _make_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", ACCENT)
	btn.add_theme_font_size_override("font_size", 14)
	btn.custom_minimum_size = Vector2(48, 36)
	btn.pressed.connect(callback)
	return btn
