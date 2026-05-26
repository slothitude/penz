extends PanelContainer
## Connection progress overlay — shows steps during BLE connection.

var _label: Label
var _steps: PackedStringArray = []
const ACCENT := Color(0.3, 0.8, 0.4)
const BG_COLOR := Color(0.15, 0.15, 0.15, 0.95)


func _ready() -> void:
	# Centered overlay
	anchors_preset = Control.PRESET_CENTER
	offset_left = -200
	offset_top = -80
	offset_right = 200
	offset_bottom = 80

	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	bg.set_corner_radius_all(12)
	bg.border_color = Color(0.3, 0.3, 0.3)
	bg.set_border_width_all(1)
	add_theme_stylebox_override("panel", bg)

	var vbox := VBoxContainer.new()
	add_child(vbox)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_font_size_override("font_size", 16)
	_label.text = "Connecting..."
	vbox.add_child(_label)

	# Spinning indicator label
	var spinner := Label.new()
	spinner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spinner.add_theme_color_override("font_color", ACCENT)
	spinner.text = "o"
	spinner.name = "Spinner"
	vbox.add_child(spinner)


func show_progress() -> void:
	_steps.clear()
	_label.text = "Starting..."
	visible = true


func set_step(step: String) -> void:
	_steps.append(step)
	_label.text = step


func show_connected() -> void:
	_label.text = "Connected!"
	_label.add_theme_color_override("font_color", ACCENT)
	# Auto-hide after a moment
	var t := get_tree().create_timer(1.0)
	t.timeout.connect(_dismiss)


func _dismiss() -> void:
	visible = false
	_label.add_theme_color_override("font_color", Color.WHITE)
