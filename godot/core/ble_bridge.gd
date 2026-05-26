extends Node
## BLE abstraction layer — dispatches to platform-specific backend.
## Windows: launches capture.py --json-stdout as subprocess, reads via pipe file.
## Android: calls Kotlin BLE plugin singleton.

signal connected()
signal disconnected()
signal point_received(x: int, y: int, pressure: int)
signal stroke_end_received()
signal status_updated(info: Dictionary)
signal connection_progress(step: String)
signal button_pressed()

var _uuid_hex: String = ""
var _is_connected: bool = false

# Windows subprocess state
var _process_id: int = -1
var _poll_timer: Timer
var _pipe_path: String = ""

# Android plugin reference
var _plugin: Object = null


func _ready() -> void:
	if OS.has_feature("android"):
		_plugin = Engine.get_singleton("PenzBLE")
		if _plugin:
			_plugin.connect("on_point", _on_android_point)
			_plugin.connect("on_stroke_end", _on_android_stroke_end)
			_plugin.connect("on_status", _on_android_status)
			_plugin.connect("on_connected", _on_android_connected)
			_plugin.connect("on_disconnected", _on_android_disconnected)
			_plugin.connect("on_connection_progress", _on_android_progress)
	else:
		_poll_timer = Timer.new()
		_poll_timer.wait_time = 1.0 / 60.0
		_poll_timer.timeout.connect(_poll_subprocess)
		add_child(_poll_timer)
		# Use a fixed temp path both Godot and capture.py can find
		# OS.get_environment returns Windows-style path on Windows
		var temp := OS.get_environment("TEMP")
		if temp == "":
			temp = OS.get_environment("USERPROFILE") + "/AppData/Local/Temp"
		_pipe_path = temp.replace("\\", "/") + "/penz_ble_pipe.jsonl"


func set_uuid(uuid_hex: String) -> void:
	_uuid_hex = uuid_hex


func connect_device(uuid_hex: String = "") -> void:
	if uuid_hex != "":
		_uuid_hex = uuid_hex
	if _uuid_hex == "":
		# Try loading from project data dir
		var uuid_path := ProjectSettings.globalize_path("res://../data/device_uuid.json")
		if FileAccess.file_exists(uuid_path):
			var f := FileAccess.open(uuid_path, FileAccess.READ)
			var json: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if json and json.has("uuid"):
				_uuid_hex = json["uuid"]
	if _uuid_hex == "":
		connection_progress.emit("No device UUID — run register.py first")
		return

	if OS.has_feature("android"):
		_connect_android()
	else:
		_connect_windows()


func disconnect_device() -> void:
	if OS.has_feature("android"):
		if _plugin:
			_plugin.call("disconnectDevice")
	else:
		_disconnect_windows()


func is_connected_to_device() -> bool:
	return _is_connected


func new_page() -> void:
	pass


signal pages_synced(page_paths: PackedStringArray)

var _sync_process_id: int = -1

func sync_pages() -> void:
	if OS.has_feature("android"):
		if _plugin:
			_plugin.call("syncPages")
	else:
		_sync_windows()


# ── Windows sync ────────────────────────────────────────────────────

func _sync_windows() -> void:
	connection_progress.emit("Syncing pages...")

	var sync_pipe := _pipe_path.replace("ble_pipe", "sync_pipe")
	if FileAccess.file_exists(sync_pipe):
		DirAccess.remove_absolute(sync_pipe)

	var script_path := ProjectSettings.globalize_path("res://../sync.py")
	var args := PackedStringArray(["-u", script_path, "--json-stdout", "--pipe", sync_pipe])

	_sync_process_id = OS.create_process("python", args)
	if _sync_process_id == -1:
		connection_progress.emit("Failed to start sync.py")
		return

	# Poll sync pipe
	var sync_timer := Timer.new()
	sync_timer.wait_time = 0.2
	sync_timer.timeout.connect(func(): _poll_sync(sync_pipe, sync_timer))
	add_child(sync_timer)
	sync_timer.start()


func _poll_sync(sync_pipe: String, timer: Timer) -> void:
	if _sync_process_id != -1 and not OS.is_process_running(_sync_process_id):
		_sync_process_id = -1

	if not FileAccess.file_exists(sync_pipe):
		if _sync_process_id == -1:
			timer.stop()
			timer.queue_free()
			connection_progress.emit("Sync complete")
		return

	var f := FileAccess.open(sync_pipe, FileAccess.READ)
	if not f:
		return

	var synced_pages: PackedStringArray = []
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var json: Variant = JSON.parse_string(line)
		if not json:
			continue
		var t: String = json.get("type", "")
		if t == "progress":
			connection_progress.emit(json.get("step", ""))
		elif t == "sync_status":
			var total: int = json.get("total", 0)
			connection_progress.emit("Found %d pages" % total)
		elif t == "page_synced":
			synced_pages.append(json.get("path", ""))
		elif t == "sync_done":
			pages_synced.emit(json.get("pages", []))
			connection_progress.emit("Synced %d pages" % json.get("pages", []).size())
			timer.stop()
			timer.queue_free()
			DirAccess.remove_absolute(sync_pipe)
			return
		elif t == "error":
			connection_progress.emit("Error: " + json.get("message", ""))
	f.close()
	DirAccess.remove_absolute(sync_pipe)


# ── Windows subprocess ──────────────────────────────────────────────

func _connect_windows() -> void:
	connection_progress.emit("Starting capture...")

	# Clean any stale pipe
	if _pipe_path != "" and FileAccess.file_exists(_pipe_path):
		DirAccess.remove_absolute(_pipe_path)

	var script_path := ProjectSettings.globalize_path("res://../capture.py")
	if not FileAccess.file_exists(script_path):
		connection_progress.emit("capture.py not found at: " + script_path)
		return

	var args := PackedStringArray(["-u", script_path, "--json-stdout", "--pipe", _pipe_path])
	if _uuid_hex != "":
		args.append_array(["--uuid", _uuid_hex])

	connection_progress.emit("Launching: python " + " ".join(args))
	_process_id = OS.create_process("python", args)
	if _process_id == -1:
		connection_progress.emit("Failed to start capture.py")
		return

	_poll_timer.start()
	connection_progress.emit("Waiting for BLE...")


func _disconnect_windows() -> void:
	if _process_id != -1:
		OS.kill(_process_id)
		_process_id = -1
	_poll_timer.stop()
	_is_connected = false
	# Clean up pipe
	if _pipe_path != "" and FileAccess.file_exists(_pipe_path):
		DirAccess.remove_absolute(_pipe_path)
	disconnected.emit()


func _poll_subprocess() -> void:
	if _process_id == -1:
		return

	# Check if process is still alive
	if not OS.is_process_running(_process_id):
		_process_id = -1
		_poll_timer.stop()
		if _is_connected:
			_is_connected = false
			disconnected.emit()
		else:
			connection_progress.emit("Process exited unexpectedly")
		return

	# Read from pipe file
	if _pipe_path == "" or not FileAccess.file_exists(_pipe_path):
		return

	var lines := _read_pipe()
	for line in lines:
		_parse_json_line(line)


func _read_pipe() -> PackedStringArray:
	var lines: PackedStringArray = []
	var f := FileAccess.open(_pipe_path, FileAccess.READ)
	if not f:
		return lines

	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "":
			lines.append(line)
	f.close()

	# Clear the pipe after reading
	DirAccess.remove_absolute(_pipe_path)
	return lines


func _parse_json_line(line: String) -> void:
	var json: Variant = JSON.parse_string(line)
	if not json:
		return

	var msg_type: String = json.get("type", "")
	match msg_type:
		"point":
			point_received.emit(int(json["x"]), int(json["y"]), int(json["p"]))
		"stroke_end":
			stroke_end_received.emit()
		"button_press":
			button_pressed.emit()
		"status":
			var info: Dictionary = json.get("info", {})
			status_updated.emit(info)
		"progress":
			connection_progress.emit(json.get("step", ""))
		"connected":
			_is_connected = true
			connected.emit()
		"disconnected":
			_is_connected = false
			disconnected.emit()
		"error":
			connection_progress.emit("Error: " + json.get("message", "unknown"))


# ── Android plugin ──────────────────────────────────────────────────

func _connect_android() -> void:
	if _plugin:
		_plugin.call("scanForDevice", "Bamboo")


func _on_android_point(x: int, y: int, pressure: int) -> void:
	point_received.emit(x, y, pressure)


func _on_android_stroke_end() -> void:
	stroke_end_received.emit()


func _on_android_status(battery: int, mode: String) -> void:
	status_updated.emit({"battery": battery, "mode": mode})


func _on_android_connected() -> void:
	_is_connected = true
	connected.emit()


func _on_android_disconnected() -> void:
	_is_connected = false
	disconnected.emit()


func _on_android_progress(step: String) -> void:
	connection_progress.emit(step)
