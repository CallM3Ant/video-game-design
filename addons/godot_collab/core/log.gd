@tool
extends RefCounted
## Everything the add-on does is logged here: to the Godot output panel, to a rotating log file at
## res://.godot/godot_collab/collab.log (easy to attach to a bug report) and to an in-memory ring
## buffer that the Collab dock shows.
##
## Usage: Log.info("scene", "applied 3 ops"), Log.warn(...), Log.error(...), Log.debug(...)

const MAX_LINES := 3000
const MAX_FILE_BYTES := 4 * 1024 * 1024

enum Level { DEBUG, INFO, WARN, ERROR }

static var lines: Array[String] = []
static var verbose := false
static var console := true
static var _file: FileAccess = null
static var _path := ""
static var _listeners: Array[Callable] = []
static var _bytes_written := 0


static func setup(log_path: String = "") -> void:
	close()
	if log_path.is_empty():
		log_path = ProjectSettings.globalize_path("res://.godot").path_join("godot_collab").path_join("collab.log")
	_path = log_path
	DirAccess.make_dir_recursive_absolute(log_path.get_base_dir())
	if FileAccess.file_exists(log_path) and FileAccess.get_file_as_bytes(log_path).size() > MAX_FILE_BYTES:
		var old := log_path + ".1"
		if FileAccess.file_exists(old):
			DirAccess.remove_absolute(old)
		DirAccess.rename_absolute(log_path, old)
	_file = FileAccess.open(log_path, FileAccess.READ_WRITE if FileAccess.file_exists(log_path) else FileAccess.WRITE)
	if _file != null:
		_file.seek_end()
	_bytes_written = 0
	info("log", "---- Godot Collab log started (Godot %s, %s) ----" % [Engine.get_version_info().get("string", "?"), OS.get_name()])


static func close() -> void:
	if _file != null:
		_file.flush()
		_file = null


static func path() -> String:
	return _path


static func add_listener(cb: Callable) -> void:
	if not _listeners.has(cb):
		_listeners.append(cb)


static func remove_listener(cb: Callable) -> void:
	_listeners.erase(cb)


static func debug(category: String, message: String) -> void:
	_emit(Level.DEBUG, category, message)


static func info(category: String, message: String) -> void:
	_emit(Level.INFO, category, message)


static func warn(category: String, message: String) -> void:
	_emit(Level.WARN, category, message)


static func error(category: String, message: String) -> void:
	_emit(Level.ERROR, category, message)


static func _emit(level: int, category: String, message: String) -> void:
	if level == Level.DEBUG and not verbose:
		return
	var tag: String = ["DEBUG", "INFO", "WARN", "ERROR"][level]
	var t := Time.get_datetime_dict_from_system()
	var stamp := "%02d:%02d:%02d.%03d" % [t.hour, t.minute, t.second, Time.get_ticks_msec() % 1000]
	var line := "%s %-5s [%s] %s" % [stamp, tag, category, message]
	lines.append(line)
	if lines.size() > MAX_LINES:
		lines = lines.slice(lines.size() - MAX_LINES)
	if _file != null:
		_file.store_line(line)
		_bytes_written += line.length() + 1
		if level >= Level.WARN or _bytes_written > 4096:
			_file.flush()
			_bytes_written = 0
	if console:
		match level:
			Level.WARN:
				print("[Collab] ", line)
			Level.ERROR:
				printerr("[Collab] ", line)
			_:
				print("[Collab] ", line)
	for cb in _listeners:
		if cb.is_valid():
			cb.call(line, level)


static func recent_text(max_lines: int = 400) -> String:
	var from := maxi(0, lines.size() - max_lines)
	return "\n".join(lines.slice(from))
