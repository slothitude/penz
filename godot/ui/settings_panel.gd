extends PanelContainer
## Settings panel — UUID config, device info.

signal uuid_loaded(uuid_hex: String)
signal closed()

const UUID_PATH := "user://device_uuid.json"
const FALLBACK_UUID_PATH := "res://../data/device_uuid.json"

var _uuid_edit: LineEdit
var _uuid: String = ""


func _ready() -> void:
	anchors_preset = Control.PRESET_CENTER
	offset_left = -200
	offset_top = -150
	offset_right = 200
	offset_bottom = 150

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.15, 0.15, 0.98)
	bg.set_corner_radius_all(12)
	bg.border_color = Color(0.3, 0.3, 0.3)
	bg.set_border_width_all(1)
	add_theme_stylebox_override("panel", bg)

	var vbox := VBoxContainer.new()
	add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# UUID field
	var uuid_label := Label.new()
	uuid_label.text = "Device UUID:"
	uuid_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(uuid_label)

	_uuid_edit = LineEdit.new()
	_uuid_edit.placeholder_text = "bc57e7c5bcd6"
	vbox.add_child(_uuid_edit)

	# Save button
	var save_btn := Button.new()
	save_btn.text = "Save UUID"
	save_btn.pressed.connect(_save_uuid)
	vbox.add_child(save_btn)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): visible = false)
	vbox.add_child(close_btn)

	# Load existing UUID
	_load_uuid()


func get_uuid_hex() -> String:
	if _uuid != "":
		return _uuid
	return _uuid_edit.text.strip_edges()


func _load_uuid() -> void:
	# Try user dir first, then project data dir
	var paths := [UUID_PATH, FALLBACK_UUID_PATH]
	for path in paths:
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			var text := f.get_as_text()
			f.close()
			var json: Variant = JSON.parse_string(text)
			if json and json.has("uuid"):
				_uuid = json["uuid"]
				_uuid_edit.text = _uuid
				uuid_loaded.emit(_uuid)
				return


func _save_uuid() -> void:
	var hex := _uuid_edit.text.strip_edges()
	if hex == "":
		return
	_uuid = hex
	var data := {"uuid": hex}
	var f := FileAccess.open(UUID_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()
	visible = false
