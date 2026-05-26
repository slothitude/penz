extends PanelContainer
## OCR panel — slides up from bottom, shows extracted text from handwriting.
## Uses Ollama glm-ocr model for local OCR (no API key needed).

var _text_edit: TextEdit
var _status_label: Label
var _close_btn: Button
var _copy_btn: Button
var _busy: bool = false

const BG_COLOR := Color(0.12, 0.12, 0.12, 0.95)
const ACCENT := Color(0.3, 0.8, 0.4)


func _ready() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	bg.set_corner_radius_all(12)
	bg.border_color = Color(0.3, 0.3, 0.3)
	bg.set_border_width_all(1)
	add_theme_stylebox_override("panel", bg)

	var vbox := VBoxContainer.new()
	add_child(vbox)

	# Header
	var header := HBoxContainer.new()
	vbox.add_child(header)

	_status_label = Label.new()
	_status_label.text = "OCR"
	_status_label.add_theme_color_override("font_color", Color.WHITE)
	_status_label.add_theme_font_size_override("font_size", 16)
	header.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_copy_btn = Button.new()
	_copy_btn.text = "Copy"
	_copy_btn.flat = true
	_copy_btn.add_theme_color_override("font_color", ACCENT)
	_copy_btn.pressed.connect(_copy_text)
	header.add_child(_copy_btn)

	_close_btn = Button.new()
	_close_btn.text = "Close"
	_close_btn.flat = true
	_close_btn.pressed.connect(func(): visible = false)
	header.add_child(_close_btn)

	# Text output
	_text_edit = TextEdit.new()
	_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text_edit.add_theme_color_override("font_color", Color.WHITE)
	_text_edit.add_theme_font_size_override("font_size", 15)
	_text_edit.custom_minimum_size = Vector2(0, 120)
	_text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_text_edit)


func run_ocr(png_data: PackedByteArray) -> void:
	if _busy:
		return
	_busy = true
	_text_edit.text = ""
	_status_label.text = "OCR — analyzing..."
	visible = true

	# Resize image to max 800px wide for faster OCR inference
	var img := Image.new()
	var err := img.load_png_from_buffer(png_data)
	if err != OK:
		_text_edit.text = "Error: failed to load PNG (%d)" % err
		_busy = false
		return
	if img.get_width() > 800:
		img.resize(800, int(800.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_LANCZOS)
	var resized_png := img.save_png_to_buffer()

	# Call Ollama glm-ocr via HTTP API (runs on localhost:11434)
	var http := HTTPRequest.new()
	http.timeout = 120.0
	add_child(http)
	http.request_completed.connect(_on_ocr_response)

	var b64 := Marshalls.raw_to_base64(resized_png)
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


func _on_ocr_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	_status_label.text = "OCR"

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
	# /api/chat returns message.content, /api/generate returns response
	if json.has("message") and json["message"].has("content"):
		_text_edit.text = json["message"]["content"]
	elif json.has("response"):
		_text_edit.text = json["response"]
	else:
		_text_edit.text = "Error: unexpected response from Ollama\n%s" % raw.left(500)

	# Clean up HTTPRequest
	for child in get_children():
		if child is HTTPRequest:
			child.queue_free()


func _copy_text() -> void:
	DisplayServer.clipboard_set(_text_edit.text)
	_copy_btn.text = "Copied!"
	var t := get_tree().create_timer(1.5)
	t.timeout.connect(func(): _copy_btn.text = "Copy")
