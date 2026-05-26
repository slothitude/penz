extends HBoxContainer
## Top HUD bar — floating overlay with gradient background.
## Part of CanvasLayer — draws over the ink canvas.

signal gallery_pressed()
signal settings_pressed()
signal hw_button_pressed()

var _status_dot: ColorRect
var _battery_label: Label
var _mode_label: Label
var _bg_panel: Panel
var _message_label: Label
var _message_timer: Timer
var _hw_button: Button
var _hw_flash_timer: Timer

const FONT_COLOR := Color(0.7, 0.7, 0.7)
const ACCENT := Color(0.3, 0.8, 0.4)
const BG_COLOR := Color(0.08, 0.08, 0.08, 0.85)


func _ready() -> void:
	# Semi-transparent gradient background
	_bg_panel = Panel.new()
	_bg_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	bg.set_corner_radius_all(0)
	_bg_panel.add_theme_stylebox_override("panel", bg)
	add_child(_bg_panel)

	# Status LED dot
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.color = Color.GRAY
	add_child(_status_dot)

	# Title
	var title := Label.new()
	title.text = "  Penz"
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_font_size_override("font_size", 18)
	add_child(title)

	# Hardware button (mirrors Slate physical button)
	_hw_button = Button.new()
	_hw_button.text = "BTN"
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.25, 0.25, 0.25)
	btn_style.set_corner_radius_all(6)
	_hw_button.add_theme_stylebox_override("normal", btn_style)
	var btn_hover := StyleBoxFlat.new()
	btn_hover.bg_color = Color(0.35, 0.35, 0.35)
	btn_hover.set_corner_radius_all(6)
	_hw_button.add_theme_stylebox_override("hover", btn_hover)
	_hw_button.add_theme_color_override("font_color", Color.WHITE)
	_hw_button.add_theme_font_size_override("font_size", 13)
	_hw_button.custom_minimum_size = Vector2(48, 32)
	_hw_button.pressed.connect(func(): hw_button_pressed.emit())
	add_child(_hw_button)

	# Flash timer for button animation
	_hw_flash_timer = Timer.new()
	_hw_flash_timer.one_shot = true
	_hw_flash_timer.wait_time = 0.3
	_hw_flash_timer.timeout.connect(_on_flash_end)
	add_child(_hw_flash_timer)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	# Mode label
	_mode_label = Label.new()
	_mode_label.add_theme_color_override("font_color", FONT_COLOR)
	_mode_label.add_theme_font_size_override("font_size", 13)
	_mode_label.text = ""
	add_child(_mode_label)

	# Battery label
	_battery_label = Label.new()
	_battery_label.add_theme_color_override("font_color", FONT_COLOR)
	_battery_label.add_theme_font_size_override("font_size", 13)
	_battery_label.text = ""
	add_child(_battery_label)

	# Gallery button
	var gallery_btn := _make_icon_button("Gallery", func(): gallery_pressed.emit())
	add_child(gallery_btn)

	# Settings button
	var settings_btn := _make_icon_button("Settings", func(): settings_pressed.emit())
	add_child(settings_btn)

	# Padding
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(8, 0)
	add_child(pad)

	# Message label (auto-fades)
	_message_label = Label.new()
	_message_label.add_theme_color_override("font_color", ACCENT)
	_message_label.add_theme_font_size_override("font_size", 15)
	_message_label.text = ""
	add_child(_message_label)
	_message_timer = Timer.new()
	_message_timer.one_shot = true
	_message_timer.wait_time = 2.0
	_message_timer.timeout.connect(func(): _message_label.text = "")
	add_child(_message_timer)


func set_battery(percent: int) -> void:
	if percent < 0:
		_battery_label.text = ""
		return
	_battery_label.text = "%d%%  " % percent
	if percent < 20:
		_battery_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	elif percent < 50:
		_battery_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
	else:
		_battery_label.add_theme_color_override("font_color", FONT_COLOR)


func set_mode(mode: String) -> void:
	_mode_label.text = mode + "  "
	match mode:
		"live":
			_status_dot.color = Color(0.2, 0.6, 1.0)
		"idle":
			_status_dot.color = Color.GRAY
		"paper":
			_status_dot.color = ACCENT
		_:
			_status_dot.color = Color.GRAY


func set_connected(connected: bool) -> void:
	_status_dot.color = ACCENT if connected else Color.GRAY


func _make_icon_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_color_override("font_color", FONT_COLOR)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)
	btn.custom_minimum_size = Vector2(64, 36)
	btn.pressed.connect(callback)
	return btn


func show_message(text: String) -> void:
	_message_label.text = text
	_message_timer.start()


func flash_button() -> void:
	# Visual feedback when Slate hardware button is pressed
	_hw_button.add_theme_color_override("font_color", ACCENT)
	_hw_flash_timer.start()


func _on_flash_end() -> void:
	_hw_button.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
