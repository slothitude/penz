extends PanelContainer
## Connection progress overlay — animated step list with spinner.

const PenzTheme = preload("res://ui/theme.gd")

var _title_label: Label
var _steps_container: VBoxContainer
var _step_labels: Array[Label] = []
var _current_step: int = -1
var _spinner_angle: float = 0.0
var _spinner_control: Control
var _scrim: ColorRect


func _ready() -> void:
	# Full-screen scrim behind dialog
	anchors_preset = Control.PRESET_FULL_RECT

	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.0)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scrim)

	# Dialog box — centered
	var dialog := PanelContainer.new()
	dialog.anchors_preset = Control.PRESET_CENTER
	dialog.offset_left = -240
	dialog.offset_top = -140
	dialog.offset_right = 240
	dialog.offset_bottom = 140
	dialog.add_theme_stylebox_override("panel", PenzTheme.make_panel_bg())
	add_child(dialog)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	dialog.add_child(vbox)

	# Title
	_title_label = Label.new()
	_title_label.text = "Connecting"
	_title_label.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title_label)

	# Spacer
	var sep := HSeparator.new()
	sep.add_theme_stylebox_override("separator", _make_line_style())
	vbox.add_child(sep)

	# Step list container
	_steps_container = VBoxContainer.new()
	_steps_container.add_theme_constant_override("separation", 6)
	vbox.add_child(_steps_container)

	# Spinner (custom drawn arc)
	_spinner_control = Control.new()
	_spinner_control.custom_minimum_size = Vector2(32, 32)
	_spinner_control.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_spinner_control.visible = false
	# Use a script to draw the spinning arc
	_spinner_control.draw.connect(_draw_spinner)
	vbox.add_child(_spinner_control)

	visible = false


func _process(delta: float) -> void:
	if visible and _spinner_control.visible:
		_spinner_angle += delta * 360.0
		_spinner_control.queue_redraw()


func _draw_spinner() -> void:
	if not _spinner_control.visible:
		return
	var center := Vector2(16, 16)
	var radius := 10.0
	var start := deg_to_rad(_spinner_angle)
	var end := start + PI * 1.2
	var color := PenzTheme.ACCENT
	_spinner_control.draw_arc(center, radius, start, end, 20, color, 2.0, true)
	# Dot at the end
	var dot_pos := center + Vector2(cos(end), sin(end)) * radius
	_spinner_control.draw_circle(dot_pos, 3, color)


func show_progress() -> void:
	_step_labels.clear()
	_current_step = -1
	_title_label.text = "Connecting"
	_title_label.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_spinner_control.visible = true

	# Clear old steps
	for child in _steps_container.get_children():
		child.queue_free()

	# Fade in scrim
	_scrim.color = Color(0, 0, 0, 0.0)
	var tween := create_tween()
	tween.tween_property(_scrim, "color", Color(0, 0, 0, 0.4), 0.2)

	visible = true


func set_step(step: String) -> void:
	_current_step += 1

	# Mark previous step as done
	if _current_step > 0 and _current_step - 1 < _step_labels.size():
		var prev: Label = _step_labels[_current_step - 1]
		prev.text = PenzTheme.ICON_DONE + " " + prev.text.substr(2)
		prev.add_theme_color_override("font_color", PenzTheme.ACCENT)

	# Add new step with pending icon
	var label := Label.new()
	label.text = "  " + step  # space for spinner
	label.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	label.add_theme_font_size_override("font_size", 14)
	_steps_container.add_child(label)
	_step_labels.append(label)

	# Spinner draws next to current step
	_spinner_control.visible = true


func show_connected() -> void:
	# Mark all steps done
	for i in _step_labels.size():
		var lbl: Label = _step_labels[i]
		if not lbl.text.begins_with(PenzTheme.ICON_DONE):
			lbl.text = PenzTheme.ICON_DONE + " " + lbl.text.substr(2)
			lbl.add_theme_color_override("font_color", PenzTheme.ACCENT)

	_spinner_control.visible = false
	_title_label.text = "Connected!"
	_title_label.add_theme_color_override("font_color", PenzTheme.ACCENT)

	# Scale pulse
	var dialog: PanelContainer = get_child(1)
	var tween := create_tween()
	tween.tween_property(dialog, "scale", Vector2(1.03, 1.03), 0.15).set_ease(Tween.EASE_OUT)
	tween.tween_property(dialog, "scale", Vector2(1.0, 1.0), 0.15).set_ease(Tween.EASE_IN)

	# Fade out after delay
	tween.tween_interval(0.6)
	tween.parallel().tween_property(_scrim, "color", Color(0, 0, 0, 0.0), 0.4)
	tween.parallel().tween_property(dialog, "modulate:a", 0.0, 0.4)
	tween.tween_callback(_dismiss)


func _dismiss() -> void:
	visible = false
	# Reset for next use
	var dialog: PanelContainer = get_child(1)
	dialog.modulate.a = 1.0
	dialog.scale = Vector2.ONE


func _make_line_style() -> StyleBoxLine:
	var s := StyleBoxLine.new()
	s.color = Color(1, 1, 1, 0.08)
	s.thickness = 1
	return s
