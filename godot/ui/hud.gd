extends HBoxContainer
## Top HUD bar — premium paper-computer aesthetic.
## Part of CanvasLayer — draws over the ink canvas.

signal gallery_pressed()
signal settings_pressed()
signal hw_button_pressed()

const PenzTheme = preload("res://ui/theme.gd")

const S := PenzTheme.UI_SCALE
const BAR_H := 48.0 * S

var _hw_button: Control
var _hw_pressed := false
var _message_label: Label
var _message_timer: Timer
var _battery_control: Control
var _battery_percent: int = -1
var _mode_label: Label
var _led_control: Control
var _glow_alpha: float = 0.0
var _glow_tween: Tween
var _connected := false
var _toast_label: Label
var _toast_tween: Tween


func _ready() -> void:
	# Background — ColorRect in the CanvasLayer (not child of HBoxContainer)
	# because _draw() clips to the HBoxContainer's actual rect which is too small.
	var bg := ColorRect.new()
	bg.color = PenzTheme.CHROME_BG
	bg.z_index = -1
	bg.name = "HUBBg"
	get_parent().call_deferred("add_child", bg)
	# Deferred sizing after viewport is ready
	_set_bg.call_deferred(bg)

	# Status LED — custom drawn
	_led_control = Control.new()
	_led_control.custom_minimum_size = Vector2(16 * S, 16 * S)
	_led_control.z_index = 1
	_led_control.draw.connect(_draw_led)
	add_child(_led_control)

	# Title — lowercase, quiet
	var title := Label.new()
	title.text = "  penz"
	title.add_theme_color_override("font_color", PenzTheme.TEXT_TERTIARY)
	title.add_theme_font_size_override("font_size", int(16 * S))
	add_child(title)

	# Hardware button — drawn circle outline
	_hw_button = Control.new()
	_hw_button.custom_minimum_size = Vector2(36 * S, 36 * S)
	_hw_button.z_index = 1
	_hw_button.draw.connect(_draw_hw_button)
	_hw_button.gui_input.connect(_on_hw_input)
	add_child(_hw_button)

	# Flash timer for button animation
	var flash_timer := Timer.new()
	flash_timer.one_shot = true
	flash_timer.wait_time = 0.3
	flash_timer.timeout.connect(_on_flash_end)
	flash_timer.name = "FlashTimer"
	add_child(flash_timer)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	# Mode label
	_mode_label = Label.new()
	_mode_label.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	_mode_label.add_theme_font_size_override("font_size", int(12 * S))
	_mode_label.text = ""
	add_child(_mode_label)

	# Battery — custom drawn
	_battery_control = Control.new()
	_battery_control.custom_minimum_size = Vector2(48 * S, 20 * S)
	_battery_control.z_index = 1
	_battery_control.draw.connect(_draw_battery)
	add_child(_battery_control)

	# Small spacer
	var sep := Control.new()
	sep.custom_minimum_size = Vector2(4 * S, 0)
	add_child(sep)

	# Gallery button
	add_child(PenzTheme.make_icon_button(PenzTheme.ICON_GALLERY, func(): gallery_pressed.emit()))

	# Settings button
	add_child(PenzTheme.make_icon_button(PenzTheme.ICON_SETTINGS, func(): settings_pressed.emit()))

	# Padding
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(8 * S, 0)
	add_child(pad)

	# Toast label — floating, auto-fades
	_toast_label = Label.new()
	_toast_label.add_theme_color_override("font_color", PenzTheme.ACCENT_LITE)
	_toast_label.add_theme_font_size_override("font_size", int(14 * S))
	_toast_label.text = ""
	_toast_label.visible = false
	_toast_label.z_index = 10
	add_child(_toast_label)

	# Legacy message label (kept for compat with main.gd show_message calls)
	_message_label = Label.new()
	_message_label.add_theme_color_override("font_color", PenzTheme.ACCENT_LITE)
	_message_label.add_theme_font_size_override("font_size", int(14 * S))
	_message_label.text = ""
	_message_label.visible = false
	add_child(_message_label)
	_message_timer = Timer.new()
	_message_timer.one_shot = true
	_message_timer.wait_time = 2.0
	_message_timer.timeout.connect(func(): _message_label.visible = false)
	add_child(_message_timer)


func _set_bg(bg: ColorRect) -> void:
	var vp_size := get_viewport().get_visible_rect().size
	bg.position = Vector2.ZERO
	bg.size = Vector2(vp_size.x, BAR_H)


func _draw_led() -> void:
	var center := Vector2(8 * S, 8 * S)
	var base_color := PenzTheme.TEXT_TERTIARY
	if _connected:
		base_color = PenzTheme.ACCENT
	if _glow_alpha > 0:
		_led_control.draw_circle(center, 10 * S, Color(base_color.r, base_color.g, base_color.b, _glow_alpha * 0.3))
	_led_control.draw_circle(center, 4 * S, base_color)
	_led_control.draw_circle(center, 2 * S, Color(base_color.r + 0.2, base_color.g + 0.2, base_color.b + 0.2, 0.8))


func _draw_hw_button() -> void:
	var center := Vector2(18 * S, 18 * S)
	var btn_color := PenzTheme.TEXT_TERTIARY
	if _hw_pressed:
		btn_color = PenzTheme.ACCENT
	_hw_button.draw_arc(center, 12 * S, 0, TAU, 24, btn_color, 1.5 * S, true)
	if _hw_pressed:
		_hw_button.draw_circle(center, 4 * S, PenzTheme.ACCENT)


func _draw_battery() -> void:
	if _battery_percent < 0:
		return
	var bx := 2.0 * S
	var by := 4.0 * S
	_battery_control.draw_rect(Rect2(bx, by, 28 * S, 12 * S), PenzTheme.TEXT_TERTIARY, false, S)
	var fill_w := 26.0 * S * (_battery_percent / 100.0)
	var fill_color := PenzTheme.TEXT_SECONDARY
	if _battery_percent < 20:
		fill_color = PenzTheme.ERROR_RED
	elif _battery_percent < 50:
		fill_color = Color(0.85, 0.75, 0.3)
	_battery_control.draw_rect(Rect2(bx + S, by + S, fill_w, 10 * S), fill_color)
	_battery_control.draw_rect(Rect2(bx + 28 * S, by + 3 * S, 3 * S, 6 * S), PenzTheme.TEXT_TERTIARY)
	var font := ThemeDB.fallback_font
	_battery_control.draw_string(font, Vector2(bx + 34 * S, by + 10 * S), "%d%%" % _battery_percent,
		HORIZONTAL_ALIGNMENT_LEFT, -1, int(10 * S), PenzTheme.TEXT_SECONDARY)


func set_battery(percent: int) -> void:
	_battery_percent = percent
	_battery_control.queue_redraw()


func set_mode(mode: String) -> void:
	_mode_label.text = mode + "  "


func set_connected(connected: bool) -> void:
	_connected = connected
	if connected:
		_start_glow_pulse()
	else:
		_stop_glow_pulse()
		_glow_alpha = 0.0
	_led_control.queue_redraw()


func show_message(text: String) -> void:
	_toast_label.text = text
	_toast_label.visible = true
	_toast_label.modulate.a = 0.0
	_toast_label.position = Vector2((get_viewport().get_visible_rect().size.x - _toast_label.get_minimum_size().x) / 2.0, BAR_H)

	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast_label, "modulate:a", 1.0, 0.2)
	_toast_tween.tween_interval(1.6)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(func(): _toast_label.visible = false)

	_message_label.text = text
	_message_label.visible = true
	_message_timer.start()


func flash_button() -> void:
	_hw_pressed = true
	_hw_button.queue_redraw()
	var timer: Timer = get_node_or_null("FlashTimer")
	if timer:
		timer.start()


func _on_flash_end() -> void:
	_hw_pressed = false
	_hw_button.queue_redraw()


func _on_hw_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		hw_button_pressed.emit()
		flash_button()


func _start_glow_pulse() -> void:
	if _glow_tween:
		_glow_tween.kill()
	_glow_tween = create_tween()
	_glow_tween.set_loops()
	_glow_tween.tween_property(self, "_glow_alpha", 1.0, 1.2).set_ease(Tween.EASE_IN_OUT)
	_glow_tween.tween_property(self, "_glow_alpha", 0.0, 1.2).set_ease(Tween.EASE_IN_OUT)
	_glow_tween.step_finished.connect(func(_s): _led_control.queue_redraw())


func _stop_glow_pulse() -> void:
	if _glow_tween:
		_glow_tween.kill()
		_glow_tween = null
