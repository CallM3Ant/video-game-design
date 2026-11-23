@tool
extends RefCounted
## Small shared helpers (paths, hashing, JSON, deep comparison).

const STATE_DIR_NAME := "godot_collab"


static func now_ms() -> int:
	return Time.get_ticks_msec()


static func unix_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


static func random_hex(bytes: int = 8) -> String:
	return Crypto.new().generate_random_bytes(bytes).hex_encode()


static var state_dir_override := ""


## Folder for all collaboration state of this project copy (logs, base hashes, backups).
static func state_dir() -> String:
	if not state_dir_override.is_empty():
		return state_dir_override
	return ProjectSettings.globalize_path("res://.godot").path_join(STATE_DIR_NAME)


static func ensure_dir(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		DirAccess.make_dir_recursive_absolute(abs_path)


static func res_to_rel(res_path: String) -> String:
	return res_path.trim_prefix("res://")


static func rel_to_res(rel: String) -> String:
	return "res://" + rel


static var project_dir_override := ""


static func project_dir() -> String:
	if not project_dir_override.is_empty():
		return project_dir_override
	return ProjectSettings.globalize_path("res://")


static func rel_to_abs(rel: String) -> String:
	return project_dir().path_join(rel)


## Only plain project-relative res:// paths without traversal or script-resource suffixes.
static func is_safe_res_path(path: String) -> bool:
	if not path.begins_with("res://") or path.length() > 400:
		return false
	var rel := path.trim_prefix("res://")
	return is_safe_rel_path(rel)


static func is_safe_rel_path(rel: String) -> bool:
	if rel.is_empty() or rel.length() > 400:
		return false
	if rel.begins_with("/") or rel.begins_with("\\") or rel.contains("\\") or rel.contains("::"):
		return false
	if rel.contains(":"):
		return false
	for part in rel.split("/"):
		if part == ".." or part == "." or part.is_empty():
			return false
	return true


## Copies a project file into .godot/godot_collab/backups/<run stamp>/<rel> before it is replaced.
## Returns the absolute backup path, or "" if there was nothing to back up.
static var _backup_stamp := ""


static func backup_project_file(rel: String, _reason: String = "") -> String:
	var src := rel_to_abs(rel)
	if not FileAccess.file_exists(src):
		return ""
	if _backup_stamp.is_empty():
		_backup_stamp = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dest := state_dir().path_join("backups").path_join(_backup_stamp).path_join(rel)
	var n := 1
	while FileAccess.file_exists(dest):
		dest = state_dir().path_join("backups").path_join(_backup_stamp).path_join(rel + "." + str(n))
		n += 1
	ensure_dir(dest.get_base_dir())
	if DirAccess.copy_absolute(src, dest) != OK:
		return ""
	return dest


## Saves text that is about to be replaced (for example an unsaved editor buffer) next to the file backups.
static func backup_text(rel: String, text: String) -> String:
	if _backup_stamp.is_empty():
		_backup_stamp = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dest := state_dir().path_join("backups").path_join(_backup_stamp).path_join(rel + ".buffer")
	var n := 1
	while FileAccess.file_exists(dest):
		dest = state_dir().path_join("backups").path_join(_backup_stamp).path_join(rel + ".buffer" + str(n))
		n += 1
	ensure_dir(dest.get_base_dir())
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(text)
	return dest


static func read_text(abs_path: String) -> String:
	if not FileAccess.file_exists(abs_path):
		return ""
	return FileAccess.get_file_as_string(abs_path)


static func read_bytes(abs_path: String) -> PackedByteArray:
	if not FileAccess.file_exists(abs_path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(abs_path)


## Writes through a temporary file so a crash never leaves a half-written project file.
static func write_bytes_atomic(abs_path: String, bytes: PackedByteArray) -> Error:
	ensure_dir(abs_path.get_base_dir())
	var tmp := abs_path + ".collabtmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.flush()
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return err
	if FileAccess.file_exists(abs_path):
		var rm := DirAccess.remove_absolute(abs_path)
		if rm != OK:
			DirAccess.remove_absolute(tmp)
			return rm
	return DirAccess.rename_absolute(tmp, abs_path)


static func write_text_atomic(abs_path: String, text: String) -> Error:
	return write_bytes_atomic(abs_path, text.to_utf8_buffer())


static func read_json(abs_path: String, fallback: Variant = {}) -> Variant:
	if not FileAccess.file_exists(abs_path):
		return fallback
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(abs_path))
	if parsed == null:
		return fallback
	return parsed


static func write_json(abs_path: String, data: Variant) -> Error:
	return write_text_atomic(abs_path, JSON.stringify(data, "\t"))


static func sha256_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func sha256_text(text: String) -> String:
	return text.sha256_text()


## Deep equality for wire values (dictionaries, arrays, floats). NaN equals NaN; null equals null.
static func same(a: Variant, b: Variant) -> bool:
	if a == null and b == null:
		return true
	var ta := typeof(a)
	if ta != typeof(b):
		return false
	match ta:
		TYPE_DICTIONARY:
			if a.size() != b.size():
				return false
			for k in a:
				if not b.has(k) or not same(a[k], b[k]):
					return false
			return true
		TYPE_ARRAY:
			if a.size() != b.size():
				return false
			for i in a.size():
				if not same(a[i], b[i]):
					return false
			return true
		TYPE_FLOAT:
			return a == b or (is_nan(a) and is_nan(b))
		_:
			return a == b


## Short single-line rendering of a value for log messages.
static func brief(v: Variant, max_len: int = 80) -> String:
	var s := var_to_str(v).replace("\n", " ").replace("\t", " ")
	if s.length() > max_len:
		s = s.substr(0, max_len - 3) + "..."
	return s


static func format_bytes(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KiB" % (n / 1024.0)
	return "%.1f MiB" % (n / 1048576.0)


## Normalises a file's text to the "\n" form CodeEdit uses.
static func norm_text(text: String) -> String:
	return text.replace("\r\n", "\n")
