extends PanelContainer
## Settings panel — UUID config, device info.

signal uuid_loaded(uuid_hex: String)

const PenzTheme = preload("res://ui/theme.gd")

const UUID_PATH := "user://device_uuid.json"
const FALLBACK_UUID_PATH := "res://../data/device_uuid.json"

var _uuid_edit: LineEdit
var _uuid: String = ""
var _scrim: ColorRect


func _ready() -> void:
	anchors_preset = Control.PRESET_FULL_RECT

	# Scrim overlay
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.0)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.z_index = -1
	add_child(_scrim)

	# Dialog box
	var dialog := PanelContainer.new()
	dialog.anchors_preset = Control.PRESET_CENTER
	dialog.offset_left = -220
	dialog.offset_top = -150
	dialog.offset_right = 220
	dialog.offset_bottom = 150
	dialog.add_theme_stylebox_override("panel", PenzTheme.make_panel_bg())
	dialog.z_index = 1
	add_child(dialog)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	dialog.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	# UUID field
	var uuid_label := Label.new()
	uuid_label.text = "Device UUID"
	uuid_label.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	uuid_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(uuid_label)

	_uuid_edit = LineEdit.new()
	_uuid_edit.placeholder_text = "bc57e7c5bcd6"
	# Accent underline style
	var edit_bg := StyleBoxFlat.new()
	edit_bg.bg_color = Color(1, 1, 1, 0.04)
	edit_bg.set_corner_radius_all(PenzTheme.CORNER_S)
	edit_bg.border_color = PenzTheme.ACCENT
	edit_bg.set_border_width(SIDE_BOTTOM, 2)
	_uuid_edit.add_theme_stylebox_override("normal", edit_bg)
	_uuid_edit.add_theme_stylebox_override("focus", edit_bg)
	_uuid_edit.add_theme_color_override("font_color", PenzTheme.TEXT_PRIMARY)
	_uuid_edit.add_theme_color_override("caret_color", PenzTheme.ACCENT)
	vbox.add_child(_uuid_edit)

	# Button row
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)

	# Cancel — ghost button
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.flat = false
	cancel_btn.add_theme_stylebox_override("normal", PenzTheme.make_ghost_button())
	cancel_btn.add_theme_stylebox_override("hover", PenzTheme.make_ghost_button())
	cancel_btn.add_theme_color_override("font_color", PenzTheme.TEXT_SECONDARY)
	cancel_btn.add_theme_color_override("font_hover_color", PenzTheme.TEXT_PRIMARY)
	cancel_btn.add_theme_font_size_override("font_size", 13)
	cancel_btn.pressed.connect(func(): visible = false)
	btn_row.add_child(cancel_btn)

	# Save — accent button
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.flat = false
	save_btn.add_theme_stylebox_override("normal", PenzTheme.make_accent_button())
	save_btn.add_theme_stylebox_override("hover", PenzTheme.make_accent_button())
	save_btn.add_theme_color_override("font_color", Color.WHITE)
	save_btn.add_theme_font_size_override("font_size", 13)
	save_btn.pressed.connect(_save_uuid)
	btn_row.add_child(save_btn)

	btn_row.add_child(spacer.duplicate())

	# Load existing UUID
	_load_uuid()


func get_uuid_hex() -> String:
	if _uuid != "":
		return _uuid
	return _uuid_edit.text.strip_edges()


func _load_uuid() -> void:
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
