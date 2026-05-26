extends PanelContainer
## OCR panel — elegant slide-up with backend toggle.
## Backends: local Ollama (minicpm-v) or NVIDIA cloud.

const PenzTheme = preload("res://ui/theme.gd")

var _text_edit: TextEdit
var _status_label: Label
var _close_btn: Button
var _copy_btn: Button
var _backend_local: Button
var _backend_cloud: Button
var _busy: bool = false

## "local" = Ollama minicpm-v on localhost, "cloud" = NVIDIA API
var _backend: String = "cloud"
var _slide_tween: Tween

const NVIDIA_API_KEY := "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"
const NVIDIA_MODEL := "meta/llama-3.2-90b-vision-instruct"


func _ready() -> void:
	anchors_preset = Control.PRESET_FULL_RECT

	# Main container — anchored to bottom
	var bg := PenzTheme.make_panel_bg()
	bg.set_corner_radius_all(PenzTheme.CORNER_L)
	# Only round top corners
	bg.corner_radius_bottom_left = 0
	bg.corner_radius_bottom_right = 0
	add_theme_stylebox_override("panel", bg)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# Drag handle
	var handle := Control.new()
	handle.custom_minimum_size = Vector2(36, 12)
	handle.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	handle.draw.connect(func():
		handle.draw_rect(Rect2(Vector2(0, 4), Vector2(36, 4)), Color(1, 1, 1, 0.15), false, -1, false)
		handle.draw_rect(Rect2(Vector2(0, 4), Vector2(36, 4)), Color(1, 1, 1, 0.15))
	)
	vbox.add_child(handle)

	# Header row
	var header := HBoxContainer.new()
	vbox.add_child(header)

	_status_label = Label.new()
	_status_label.text = "Transcription"
	_status_label.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_status_label.add_theme_font_size_override("font_size", 16)
	header.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	# Segmented backend toggle
	_backend_local = Button.new()
	_backend_local.text = "Local"
	_backend_local.flat = false
	_backend_local.toggle_mode = true
	_backend_local.add_theme_stylebox_override("normal", _make_toggle_style(false))
	_backend_local.add_theme_stylebox_override("hover", _make_toggle_style(false))
	_backend_local.add_theme_stylebox_override("pressed", _make_toggle_style(true))
	_backend_local.add_theme_font_size_override("font_size", 12)
	_backend_local.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	_backend_local.custom_minimum_size = Vector2(56, 28)
	_backend_local.pressed.connect(_switch_to_local)
	header.add_child(_backend_local)

	_backend_cloud = Button.new()
	_backend_cloud.text = "Cloud"
	_backend_cloud.flat = false
	_backend_cloud.toggle_mode = true
	_backend_cloud.button_pressed = true
	_backend_cloud.add_theme_stylebox_override("normal", _make_toggle_style(true))
	_backend_cloud.add_theme_stylebox_override("hover", _make_toggle_style(true))
	_backend_cloud.add_theme_stylebox_override("pressed", _make_toggle_style(false))
	_backend_cloud.add_theme_font_size_override("font_size", 12)
	_backend_cloud.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_backend_cloud.custom_minimum_size = Vector2(56, 28)
	_backend_cloud.pressed.connect(_switch_to_cloud)
	header.add_child(_backend_cloud)

	# Copy button
	_copy_btn = PenzTheme.make_text_button("Copy", _copy_text)
	header.add_child(_copy_btn)

	# Close button
	_close_btn = PenzTheme.make_icon_button(PenzTheme.ICON_CLOSE, func(): _slide_out())
	header.add_child(_close_btn)

	# Text output — warm paper background
	_text_edit = TextEdit.new()
	_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text_edit.add_theme_color_override("font_color", PenzTheme.TEXT_ON_PAPER)
	_text_edit.add_theme_font_size_override("font_size", 15)
	# Warm paper-like background for text area
	var text_bg := StyleBoxFlat.new()
	text_bg.bg_color = PenzTheme.PAPER_WARM
	text_bg.set_corner_radius_all(PenzTheme.CORNER_M)
	text_bg.content_margin_left = 12
	text_bg.content_margin_right = 12
	text_bg.content_margin_top = 8
	text_bg.content_margin_bottom = 8
	_text_edit.add_theme_stylebox_override("normal", text_bg)
	_text_edit.add_theme_stylebox_override("read_only", text_bg)
	_text_edit.custom_minimum_size = Vector2(0, 140)
	_text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Extra line spacing
	_text_edit.add_theme_constant_override("line_spacing", 4)
	vbox.add_child(_text_edit)

	# Start hidden below screen
	visible = false
	_initial_position()


func _initial_position() -> void:
	# Position off-screen bottom for slide-up
	offset_top = 600


func run_ocr(png_data: PackedByteArray) -> void:
	if _busy:
		return
	_busy = true
	_text_edit.text = ""
	_status_label.text = "Transcription — analyzing..."
	_slide_in()

	# Resize image to max 1200px wide for OCR
	var img := Image.new()
	var err := img.load_png_from_buffer(png_data)
	if err != OK:
		_text_edit.text = "Error: failed to load PNG (%d)" % err
		_busy = false
		return
	if img.get_width() > 1200:
		img.resize(1200, int(1200.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_LANCZOS)
	var resized_png := img.save_png_to_buffer()

	if _backend == "cloud":
		_run_cloud_ocr(resized_png)
	else:
		_run_local_ocr(resized_png)


func _run_local_ocr(png_data: PackedByteArray) -> void:
	var http := HTTPRequest.new()
	http.timeout = 120.0
	add_child(http)
	http.request_completed.connect(_on_local_ocr_response)

	var b64 := Marshalls.raw_to_base64(png_data)
	var body := JSON.stringify({
		"model": "minicpm-v",
		"prompt": "Transcribe all handwritten text exactly as written. Output only the text, no labels or commentary.",
		"images": [b64],
		"stream": false
	})

	var headers := ["Content-Type: application/json"]
	var req_err := http.request("http://localhost:11434/api/generate", headers, HTTPClient.METHOD_POST, body)
	if req_err != OK:
		_text_edit.text = "Error: cannot reach Ollama (err %d). Is it running?" % req_err
		http.queue_free()
		_busy = false


func _run_cloud_ocr(png_data: PackedByteArray) -> void:
	var http := HTTPRequest.new()
	http.timeout = 60.0
	add_child(http)
	http.request_completed.connect(_on_cloud_ocr_response)

	var b64 := Marshalls.raw_to_base64(png_data)
	var body := JSON.stringify({
		"model": NVIDIA_MODEL,
		"messages": [
			{
				"role": "user",
				"content": [
					{"type": "text", "text": "Transcribe all handwritten text in this image exactly as written. Output only the raw text."},
					{"type": "image_url", "image_url": {"url": "data:image/png;base64,%s" % b64}}
				]
			}
		],
		"max_tokens": 1024,
		"temperature": 0.1,
		"top_p": 1.0,
		"stream": false
	})

	var headers := [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % NVIDIA_API_KEY
	]
	var req_err := http.request("https://integrate.api.nvidia.com/v1/chat/completions", headers, HTTPClient.METHOD_POST, body)
	if req_err != OK:
		_text_edit.text = "Error: cloud request failed (err %d)" % req_err
		http.queue_free()
		_busy = false


func _on_local_ocr_response(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	_status_label.text = "Transcription (local)"

	if result != HTTPRequest.RESULT_SUCCESS:
		_text_edit.text = "Error: HTTP request failed (%d)" % result
		return

	var raw := body.get_string_from_utf8()
	var json: Variant = JSON.parse_string(raw)
	if json == null:
		_text_edit.text = "Error: JSON parse failed\n%s" % raw.left(500)
		return
	if json.has("error"):
		_text_edit.text = "Ollama error: %s" % json["error"]
		return
	if json.has("message") and json["message"].has("content"):
		_text_edit.text = json["message"]["content"]
	elif json.has("response"):
		_text_edit.text = json["response"]
	else:
		_text_edit.text = "Error: unexpected response from Ollama\n%s" % raw.left(500)

	_cleanup_http()


func _on_cloud_ocr_response(result: int, _code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	_status_label.text = "Transcription (cloud)"

	if result != HTTPRequest.RESULT_SUCCESS:
		_text_edit.text = "Error: cloud request failed (%d)" % result
		return

	var raw := body.get_string_from_utf8()
	var json: Variant = JSON.parse_string(raw)
	if json == null:
		_text_edit.text = "Error: JSON parse failed\n%s" % raw.left(500)
		return
	if json.has("error"):
		var err_msg: String = json["error"]
		if typeof(json["error"]) == TYPE_DICTIONARY:
			err_msg = json["error"].get("message", str(json["error"]))
		_text_edit.text = "Cloud error: %s" % err_msg
		return
	if json.has("choices") and json["choices"].size() > 0:
		_text_edit.text = json["choices"][0]["message"]["content"]
	else:
		_text_edit.text = "Error: unexpected cloud response\n%s" % raw.left(500)

	_cleanup_http()


func _cleanup_http() -> void:
	for child in get_children():
		if child is HTTPRequest:
			child.queue_free()


func _switch_to_local() -> void:
	_backend = "local"
	_backend_local.button_pressed = true
	_backend_cloud.button_pressed = false
	_backend_local.add_theme_stylebox_override("normal", _make_toggle_style(true))
	_backend_local.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_backend_cloud.add_theme_stylebox_override("normal", _make_toggle_style(false))
	_backend_cloud.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)


func _switch_to_cloud() -> void:
	_backend = "cloud"
	_backend_cloud.button_pressed = true
	_backend_local.button_pressed = false
	_backend_cloud.add_theme_stylebox_override("normal", _make_toggle_style(true))
	_backend_cloud.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_backend_local.add_theme_stylebox_override("normal", _make_toggle_style(false))
	_backend_local.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)


func _copy_text() -> void:
	DisplayServer.clipboard_set(_text_edit.text)
	_copy_btn.text = PenzTheme.ICON_DONE + " Copied"
	_copy_btn.add_theme_color_override("font_color", PenzTheme.ACCENT)
	# Scale pulse feedback
	var tween := create_tween()
	tween.tween_property(_copy_btn, "scale", Vector2(1.08, 1.08), 0.1)
	tween.tween_property(_copy_btn, "scale", Vector2.ONE, 0.1)
	tween.tween_interval(1.2)
	tween.tween_callback(func():
		_copy_btn.text = "Copy"
		_copy_btn.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	)


func _make_toggle_style(active: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if active:
		s.bg_color = PenzTheme.ACCENT
		s.content_margin_left = 8
		s.content_margin_right = 8
		s.content_margin_top = 4
		s.content_margin_bottom = 4
	else:
		s.bg_color = Color(1, 1, 1, 0.06)
		s.content_margin_left = 8
		s.content_margin_right = 8
		s.content_margin_top = 4
		s.content_margin_bottom = 4
	return s


func _slide_in() -> void:
	visible = true
	offset_top = 600  # below screen
	if _slide_tween:
		_slide_tween.kill()
	_slide_tween = create_tween()
	_slide_tween.tween_property(self, "offset_top", 0.0, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _slide_out() -> void:
	if _slide_tween:
		_slide_tween.kill()
	_slide_tween = create_tween()
	_slide_tween.tween_property(self, "offset_top", 600.0, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_slide_tween.tween_callback(func(): visible = false)
