extends PanelContainer
## OCR panel — slides up from bottom, shows extracted text from handwriting.
## Backends: local Ollama (minicpm-v) or NVIDIA cloud (mistral-large-3).

var _text_edit: TextEdit
var _status_label: Label
var _close_btn: Button
var _copy_btn: Button
var _backend_btn: Button
var _busy: bool = false

## "local" = Ollama minicpm-v on localhost, "cloud" = NVIDIA API
var _backend: String = "cloud"

const BG_COLOR := Color(0.12, 0.12, 0.12, 0.95)
const ACCENT := Color(0.3, 0.8, 0.4)

const NVIDIA_API_KEY := "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"
const NVIDIA_MODEL := "meta/llama-3.2-90b-vision-instruct"


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

	_backend_btn = Button.new()
	_backend_btn.text = "Cloud"
	_backend_btn.flat = true
	_backend_btn.add_theme_color_override("font_color", ACCENT)
	_backend_btn.pressed.connect(_toggle_backend)
	header.add_child(_backend_btn)

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


func _on_local_ocr_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	_status_label.text = "OCR (local)"

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


func _on_cloud_ocr_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	_status_label.text = "OCR (cloud)"

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


func _toggle_backend() -> void:
	if _backend == "cloud":
		_backend = "local"
		_backend_btn.text = "Local"
	else:
		_backend = "cloud"
		_backend_btn.text = "Cloud"


func _copy_text() -> void:
	DisplayServer.clipboard_set(_text_edit.text)
	_copy_btn.text = "Copied!"
	var t := get_tree().create_timer(1.5)
	t.timeout.connect(func(): _copy_btn.text = "Copy")
