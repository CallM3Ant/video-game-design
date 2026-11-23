@tool
extends RefCounted
## Keeps every project file that is NOT open in a live editor in step across peers: scripts you
## closed, C++ sources, scenes, textures, audio, anything on disk (also files saved by VS Code or
## another tool while Godot is running).
##
## Old changes never overwrite newer ones. For every file we remember the hash both sides last
## agreed on (the "base"). A change is only accepted as a fast-forward of that base:
##   * only you changed it  -> sent to the host, then to everybody
##   * only they changed it -> you receive it
##   * both changed it      -> text files are merged line by line; anything that overlaps (or any
##                             binary file) is HELD and you are asked what to keep. Nothing is lost:
##                             replaced files are backed up in .godot/godot_collab/backups/.
## On the very first join (no common base) the host's copy wins and yours is backed up.

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")
const Diff3 := preload("res://addons/godot_collab/core/diff3.gd")
const OT := preload("res://addons/godot_collab/core/ot.gd")

signal conflicts_changed()
signal files_written(res_paths: Array)

const CHUNK_BYTES := 192 * 1024
const MAX_MERGE_BYTES := 2 * 1024 * 1024
const SCAN_BUDGET_USEC := 4000
const INLINE_HASH_LIMIT := 24 * 1024 * 1024
const MAX_PARALLEL := 4
const IGNORED_DIRS := [".git/", ".godot/", ".import/", ".vscode/", ".idea/", ".mono/", ".svn/", ".vs/", "addons/", "__pycache__/"]
const IGNORED_FILES := ["export_presets.cfg", "export_credentials.cfg", ".DS_Store", "Thumbs.db", "desktop.ini"]
const IGNORED_GLOBS := [
	"*.tmp", "*.TMP", "*.collabtmp", "~*", "*~", "*.swp", "*.lnk",
	# Godot-generated imported translations and exported game packages.
	"*.translation", "*.exe", "*.pck", "*.app", "*.apk", "*.aab", "*.ipa",
	"*.xcodeproj", "*.xcworkspace",
	# Platform-specific native build outputs; each OS/build should provide its own.
	"*.dll", "*.dylib", "*.so", "*.framework", "*.xcframework", "*.dSYM",
	"*.a", "*.lib", "*.o", "*.pdb", "*.ilk", "*.exp", "*.pch",
]
const TEXT_EXTS := ["gd", "gdshader", "gdshaderinc", "tscn", "tres", "cfg", "ini", "json", "txt", "md", "csv", "xml", "yml", "yaml", "toml",
	"cpp", "cc", "cxx", "c", "h", "hh", "hpp", "hxx", "inl", "ipp", "cs", "py", "js", "ts", "glsl", "shader", "import", "uid", "godot", "gdextension",
	"scons", "sconstruct", "cmake", "mm", "m", "java", "kt", "rs", "go", "sh", "bat", "ps1", "html", "css", "svg", "po", "pot", "gitignore", "collabignore"]
const SCENE_EXTS := ["tscn", "scn", "tres", "res"]

var session
var env
## Normally empty (the open project). Tests give each simulated peer its own folders.
var root_dir := ""
var state_dir := ""
var rescan_pause_ms := 1200
## func(res_path: String) -> bool: true while a live editor owns the file (do not touch it).
var busy_checker: Callable
var enabled := true
var max_file_bytes := 128 * 1024 * 1024
var base: Dictionary = {}
var conflicts: Dictionary = {}
var scan_complete := false
var plan_running := false

var _cache: Dictionary = {}
var _dirs: Array = []
var _seen: Dictionary = {}
var _dir_cache: Dictionary = {}
var _dir_base: Dictionary = {}
var _seen_dirs: Dictionary = {}
var _deleted_dirs: Dictionary = {}
var _recreated_dirs: Dictionary = {}
var _pending_dir_deletes: Dictionary = {}
var _cycle_started := false
var _next_cycle_ms := 0
var _user_ignores: Array = []
var _ignores_loaded_ms := 0
var _dirty := false
var _save_at := 0
var _inflight: Dictionary = {}
var _incoming: Dictionary = {}
var _deferred: Dictionary = {}
var _pending_pulls: Dictionary = {}
var _queue: Array = []
var _stats := {"pulled": 0, "pushed": 0, "merged": 0, "deleted": 0}
var _pulled_now: Array = []
var _warned_large: Dictionary = {}
var _state_path := ""
var _was_busy: Dictionary = {}
var _last_plan_ms := 0
var _live_cseq := 1000000


func setup(p_session, p_env) -> void:
	session = p_session
	env = p_env
	_enter()
	_state_path = Util.state_dir().path_join("files.json")
	_load_state()
	session.register_host_handler("file_", _host_handle)


## Tests run several peers (each with its own project folder) in one process: every entry point
## first points the shared path helpers at this instance's folders. In the editor it is a no-op.
func _enter() -> void:
	if not root_dir.is_empty():
		Util.project_dir_override = root_dir
	if not state_dir.is_empty():
		Util.state_dir_override = state_dir


func teardown() -> void:
	_enter()
	_save_state(true)


func _online() -> bool:
	return session != null and session.joined_ok and session.is_online()


# --- persistence ----------------------------------------------------------------------------------------------

func _load_state() -> void:
	var data: Variant = Util.read_json(_state_path, {})
	if data is Dictionary:
		base = data.get("base", {}) if data.get("base") is Dictionary else {}
		conflicts = data.get("conflicts", {}) if data.get("conflicts") is Dictionary else {}
		var c: Variant = data.get("cache")
		_cache = c if c is Dictionary else {}
		_dir_cache = _safe_dir_set(data.get("dir_cache", []))
		_dir_base = _safe_dir_set(data.get("dir_base", []))
		_deleted_dirs = _safe_dir_set(data.get("deleted_dirs", []))
		_recreated_dirs = _safe_dir_set(data.get("recreated_dirs", []))
	Log.info("files", "Loaded file sync state: %d known file(s), %d held conflict(s)" % [base.size(), conflicts.size()])


func _save_state(force: bool = false) -> void:
	if not _dirty and not force:
		return
	if not force and Util.now_ms() < _save_at:
		return
	_dirty = false
	_save_at = Util.now_ms() + 2000
	var err := Util.write_json(_state_path, {
		"base": base,
		"conflicts": conflicts,
		"cache": _cache,
		"dir_cache": _dir_cache.keys(),
		"dir_base": _dir_base.keys(),
		"deleted_dirs": _deleted_dirs.keys(),
		"recreated_dirs": _recreated_dirs.keys(),
	})
	if err != OK:
		Log.error("files", "Could not save file sync state: %s" % error_string(err))


func _mark_dirty() -> void:
	_dirty = true


func _safe_dir_set(value: Variant) -> Dictionary:
	var out := {}
	if value is Array:
		for raw in value:
			var rel := String(raw).trim_suffix("/")
			if _safe_dir_rel(rel):
				out[rel] = true
	return out


func _safe_dir_rel(rel: String) -> bool:
	return not rel.is_empty() and Util.is_safe_rel_path(rel) and not is_ignored(rel) and not is_ignored(rel + "/")


func _dir_paths(rel: String) -> Array:
	var out := []
	var current := ""
	for part in rel.trim_suffix("/").split("/"):
		current = part if current.is_empty() else current.path_join(part)
		if _safe_dir_rel(current):
			out.append(current)
	return out


func _blob_path(hash: String) -> String:
	return Util.state_dir().path_join("blobs").path_join(hash)


func _remember_blob(rel: String, hash: String, bytes: PackedByteArray) -> void:
	if hash.is_empty() or bytes.size() > MAX_MERGE_BYTES or not _is_text_path(rel):
		return
	var p := _blob_path(hash)
	if FileAccess.file_exists(p):
		return
	Util.ensure_dir(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_buffer(bytes)


func _blob_text(hash: String) -> Variant:
	var p := _blob_path(hash)
	if hash.is_empty() or not FileAccess.file_exists(p):
		return null
	return FileAccess.get_file_as_string(p)


func _is_text_path(rel: String) -> bool:
	return rel.get_extension().to_lower() in TEXT_EXTS


# --- ignore rules -----------------------------------------------------------------------------------------------------

func _load_user_ignores() -> void:
	_ignores_loaded_ms = Util.now_ms()
	_user_ignores.clear()
	var p := Util.rel_to_abs(".collabignore")
	if not FileAccess.file_exists(p):
		return
	for line in FileAccess.get_file_as_string(p).split("\n"):
		var s := line.strip_edges()
		if s.is_empty() or s.begins_with("#"):
			continue
		_user_ignores.append(s)


func is_ignored(rel: String) -> bool:
	if Util.now_ms() - _ignores_loaded_ms > 5000:
		_load_user_ignores()
	for d in IGNORED_DIRS:
		if rel.begins_with(d) or rel + "/" == d:
			return true
	var file_name := rel.get_file()
	if file_name in IGNORED_FILES:
		return true
	for g in IGNORED_GLOBS:
		if file_name.to_lower().match(g.to_lower()):
			return true
	for pattern in _user_ignores:
		if pattern.ends_with("/"):
			if rel.begins_with(pattern) or ("/" + rel).contains("/" + pattern):
				return true
		elif rel.match(pattern) or file_name.match(pattern) or rel == pattern:
			return true
	return false


func _is_busy(rel: String) -> bool:
	return busy_checker.is_valid() and busy_checker.call(Util.rel_to_res(rel))


# --- local scanning ------------------------------------------------------------------------------------------------------

## Spreads directory walking and hashing over frames so the editor never stalls.
func process() -> void:
	if not enabled:
		return
	_enter()
	_detect_local_dir_deletions()
	var now := Util.now_ms()
	if not _cycle_started:
		if now < _next_cycle_ms:
			_save_state()
			return
		_cycle_started = true
		_dirs = [""]
		_seen.clear()
		_seen_dirs.clear()
	var t0 := Time.get_ticks_usec()
	while not _dirs.is_empty() and Time.get_ticks_usec() - t0 < SCAN_BUDGET_USEC:
		_scan_dir(_dirs.pop_back())
	if _dirs.is_empty():
		_finish_cycle()
	_flush_queue()
	_save_state()


func _detect_local_dir_deletions() -> void:
	_enter()
	var removed := []
	for rel in _dir_cache.keys():
		if not DirAccess.dir_exists_absolute(Util.rel_to_abs(String(rel))):
			_dir_cache.erase(rel)
			_deleted_dirs[rel] = true
			_mark_dirty()
			removed.append(String(rel))
	removed.sort_custom(func(a: String, b: String) -> bool: return a.count("/") > b.count("/"))
	for rel in removed:
		_announce_dir_deleted(rel)


func _scan_dir(rel_dir: String) -> void:
	var res_dir := Util.rel_to_abs(rel_dir)
	if not DirAccess.dir_exists_absolute(res_dir):
		return
	for d in DirAccess.get_directories_at(res_dir):
		var sub := rel_dir + d + "/"
		if not is_ignored(sub.trim_suffix("/")) and not is_ignored(sub):
			_seen_dirs[sub.trim_suffix("/")] = true
			_dirs.append(sub)
	for fname in DirAccess.get_files_at(res_dir):
		var rel := rel_dir + fname
		if is_ignored(rel):
			continue
		_seen[rel] = true
		_check_file(rel)


func _check_file(rel: String) -> void:
	var abs_path := Util.rel_to_abs(rel)
	var mtime := FileAccess.get_modified_time(abs_path)
	var c: Variant = _cache.get(rel)
	var now_s := int(Time.get_unix_time_from_system())
	if c is Dictionary and int(c.get("m", -1)) == mtime and now_s - mtime > 3:
		return
	var hash := ""
	var size := 0
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return
	size = f.get_length()
	f.close()
	if size > max_file_bytes:
		if not _warned_large.has(rel):
			_warned_large[rel] = true
			Log.warn("files", "%s is %s, over the %s sync limit: skipped" % [rel, Util.format_bytes(size), Util.format_bytes(max_file_bytes)])
		return
	hash = FileAccess.get_sha256(abs_path)
	if hash.is_empty():
		return
	var old_hash := String(c.get("h", "")) if c is Dictionary else ""
	_cache[rel] = {"m": mtime, "h": hash, "s": size}
	if hash != old_hash:
		_mark_dirty()
		_on_local_file(rel, hash)


func _finish_cycle() -> void:
	_cycle_started = false
	_next_cycle_ms = Util.now_ms() + rescan_pause_ms
	if not scan_complete:
		scan_complete = true
		Log.info("files", "Initial scan done: %d file(s) tracked" % _seen.size())
		if _online() and not session.is_host:
			request_plan()
	# Files that vanished since the last cycle were deleted locally.
	for rel in _cache.keys():
		if not FileAccess.file_exists(Util.rel_to_abs(String(rel))):
			_cache.erase(rel)
			_mark_dirty()
			_on_local_deleted(rel)
	_reconcile_local_dirs()
	_process_pending_dir_deletes()
	_deferred_retry()


func _reconcile_local_dirs() -> void:
	_enter()
	var added := []
	var removed := []
	for rel in _seen_dirs:
		# A sync message may delete a directory after this scan visited it. Do not
		# turn that stale scan result into a fresh creation.
		if not _dir_cache.has(rel) and DirAccess.dir_exists_absolute(Util.rel_to_abs(String(rel))):
			var recreated := _deleted_dirs.has(rel) or _recreated_dirs.has(rel)
			# A real local recreation supersedes any remote delete that was queued
			# while this peer was offline.
			_pending_dir_deletes.erase(rel)
			_dir_cache[rel] = true
			if recreated and not _online():
				_recreated_dirs[rel] = true
			else:
				_deleted_dirs.erase(rel)
				_recreated_dirs.erase(rel)
			_mark_dirty()
			added.append({"rel": rel, "recreated": recreated})
	for rel in _dir_cache.keys():
		if not DirAccess.dir_exists_absolute(Util.rel_to_abs(String(rel))):
			_dir_cache.erase(rel)
			_deleted_dirs[rel] = true
			_mark_dirty()
			removed.append(rel)
	added.sort()
	removed.sort_custom(func(a: String, b: String) -> bool: return a.count("/") > b.count("/"))
	for entry in added:
		_announce_dir_created(String(entry.rel), bool(entry.recreated))
	for rel in removed:
		_announce_dir_deleted(String(rel))


func _announce_dir_created(rel: String, recreated: bool = false) -> void:
	if not _online() or not _safe_dir_rel(rel):
		return
	_recreated_dirs.erase(rel)
	_deleted_dirs.erase(rel)
	if session.is_host:
		session.broadcast({"t": "file_dir_created", "dirs": [rel], "recreated": recreated, "by": session.my_uid}, 1)
	else:
		session.send({"t": "file_dir_create", "rel": rel, "recreated": recreated})


func _announce_dir_deleted(rel: String) -> void:
	if not _online() or not _safe_dir_rel(rel):
		return
	if session.is_host:
		_dir_base.erase(rel)
		_deleted_dirs[rel] = true
		_mark_dirty()
		session.broadcast({"t": "file_dir_deleted", "dirs": [rel], "by": session.my_uid}, 1)
		Log.info("files", "Local folder deletion of %s announced" % rel)
	else:
		session.send({"t": "file_dir_delete", "rel": rel})
		Log.info("files", "Asked the host to delete folder %s" % rel)


func _apply_remote_dirs_created(raw_dirs: Variant, recreated: bool = false) -> void:
	if not raw_dirs is Array:
		return
	var dirs := []
	for raw in raw_dirs:
		var rel := String(raw).trim_suffix("/")
		if _safe_dir_rel(rel):
			for parent in _dir_paths(rel):
				if not dirs.has(parent):
					dirs.append(parent)
	dirs.sort_custom(func(a: String, b: String) -> bool: return a.count("/") < b.count("/"))
	for rel in dirs:
		if _deleted_dirs.has(rel) and not recreated:
			_request_dir_delete(rel)
			continue
		# A stale create can arrive between a local delete and the next scan. If we
		# already knew the folder, treat its absence as a delete even before it was
		# recorded in the shared base; recreating it here would undo the user's delete.
		if _dir_cache.has(rel) and not DirAccess.dir_exists_absolute(Util.rel_to_abs(rel)):
			_dir_cache.erase(rel)
			_deleted_dirs[rel] = true
			_mark_dirty()
			_request_dir_delete(rel)
			continue
		DirAccess.make_dir_recursive_absolute(Util.rel_to_abs(rel))
		_dir_cache[rel] = true
		_dir_base[rel] = true
		_deleted_dirs.erase(rel)
		_pending_dir_deletes.erase(rel)
	_mark_dirty()
	if not dirs.is_empty():
		files_written.emit([Util.rel_to_res(String(dirs.back()))])


func _apply_remote_dirs_deleted(raw_dirs: Variant, host_request: bool = false) -> void:
	if not raw_dirs is Array:
		return
	var dirs := []
	for raw in raw_dirs:
		var rel := String(raw).trim_suffix("/")
		if _safe_dir_rel(rel) and not dirs.has(rel):
			dirs.append(rel)
	dirs.sort_custom(func(a: String, b: String) -> bool: return a.count("/") > b.count("/"))
	for rel in dirs:
		_deleted_dirs[rel] = true
		_pending_dir_deletes[rel] = {"announce": host_request}
		_process_one_dir_delete(rel)


func _process_pending_dir_deletes() -> void:
	for rel in _pending_dir_deletes.keys():
		_process_one_dir_delete(String(rel))


func _process_one_dir_delete(rel: String) -> void:
	if not _pending_dir_deletes.has(rel):
		return
	var abs_path := Util.rel_to_abs(rel)
	if DirAccess.dir_exists_absolute(abs_path):
		if not DirAccess.get_files_at(abs_path).is_empty() or not DirAccess.get_directories_at(abs_path).is_empty():
			return
		if DirAccess.remove_absolute(abs_path) != OK:
			return
	var pending: Dictionary = _pending_dir_deletes[rel]
	_pending_dir_deletes.erase(rel)
	_dir_cache.erase(rel)
	_dir_base.erase(rel)
	_deleted_dirs[rel] = true
	_mark_dirty()
	files_written.emit([Util.rel_to_res(rel)])
	if bool(pending.get("announce", false)) and session != null and session.is_host:
		session.broadcast({"t": "file_dir_deleted", "dirs": [rel], "by": session.my_uid}, 1)
	Log.info("files", "Removed empty folder %s" % rel)


func _request_dir_delete(rel: String) -> void:
	if not _online() or not _safe_dir_rel(rel):
		return
	if session.is_host:
		_pending_dir_deletes[rel] = {"announce": true}
		_process_one_dir_delete(rel)
	else:
		session.send({"t": "file_dir_delete", "rel": rel})


func _deferred_retry() -> void:
	for rel in _deferred.keys():
		if not _is_busy(rel):
			_deferred.erase(rel)
			var c: Variant = _cache.get(rel)
			if c is Dictionary:
				_on_local_file(rel, String(c.h))
	# Apply the latest host-side change that arrived while the editor had a file open.
	# Re-requesting the whole manifest here was timing-sensitive and could leave the file stale.
	for rel in _was_busy.keys():
		if _is_busy(rel):
			continue
		var update: Variant = _was_busy[rel]
		_was_busy.erase(rel)
		if update is Dictionary:
			if bool(update.get("deleted", false)):
				_on_remote_deleted(rel)
			else:
				_on_remote_changed(rel, String(update.get("hash", "")))
	var now := Util.now_ms()
	for rel in _pending_pulls.keys():
		if now - int(_pending_pulls[rel].get("t", now)) > 45000:
			Log.warn("files", "No answer from the host for %s; giving up on that transfer" % rel)
			_pending_pulls.erase(rel)
	for key in _incoming.keys():
		if now - int(_incoming[key].started) > 90000:
			_incoming.erase(key)


func local_hash(rel: String) -> String:
	var abs_path := Util.rel_to_abs(rel)
	if not FileAccess.file_exists(abs_path):
		return ""
	var c: Variant = _cache.get(rel)
	var mtime := FileAccess.get_modified_time(abs_path)
	if c is Dictionary and int(c.get("m", -1)) == mtime and int(Time.get_unix_time_from_system()) - mtime > 3:
		return String(c.h)
	var h := FileAccess.get_sha256(abs_path)
	if c is Dictionary or not h.is_empty():
		_cache[rel] = {"m": mtime, "h": h, "s": 0}
	return h


# --- reacting to local changes ---------------------------------------------------------------------------------------

func _on_local_file(rel: String, hash: String) -> void:
	if not _online() or not scan_complete:
		return
	if plan_running and not session.is_host:
		return
	var b := String(base.get(rel, ""))
	if hash == b:
		return
	if session.is_host:
		# The host's own edits are the reference: adopt and announce them.
		base[rel] = hash
		_mark_dirty()
		_remember_after_change(rel, hash)
		session.broadcast({"t": "file_changed", "rel": rel, "hash": hash, "by": session.my_uid}, 1, true)
		Log.info("files", "Local change to %s announced to everybody" % rel)
		return
	if _inflight.get(rel, "") == hash:
		return
	if conflicts.has(rel):
		return
	_push(rel, hash, b)


func _on_local_deleted(rel: String) -> void:
	if not _online() or not scan_complete:
		return
	if _is_busy(rel) or (plan_running and not session.is_host):
		return
	if not base.has(rel):
		return
	# If a file and its parent folders disappeared before the directory watcher
	# recorded them, include the highest missing parent in the delete request.
	# Otherwise the file is deleted remotely but an empty folder can be left behind.
	var parent := rel.get_base_dir()
	var highest_missing_parent := ""
	while not parent.is_empty() and parent != ".":
		if not DirAccess.dir_exists_absolute(Util.rel_to_abs(parent)):
			highest_missing_parent = parent
		parent = parent.get_base_dir()
	if session.is_host:
		base.erase(rel)
		_mark_dirty()
		session.broadcast({"t": "file_deleted", "rel": rel, "base": "", "by": session.my_uid}, 1)
		Log.info("files", "Local deletion of %s announced" % rel)
	else:
		session.send({"t": "file_delete", "rel": rel, "base": String(base.get(rel, ""))})
		Log.info("files", "Asked the host to delete %s" % rel)
	if not highest_missing_parent.is_empty():
		_request_dir_delete(highest_missing_parent)


func _remember_after_change(rel: String, hash: String) -> void:
	if _is_text_path(rel):
		var p := Util.rel_to_abs(rel)
		if FileAccess.file_exists(p) and FileAccess.get_file_as_bytes(p).size() <= MAX_MERGE_BYTES:
			_remember_blob(rel, hash, FileAccess.get_file_as_bytes(p))


# --- transfers --------------------------------------------------------------------------------------------------------

func _queue_job(job: Dictionary) -> void:
	_queue.append(job)


func _flush_queue() -> void:
	var running := _inflight.size() + _pending_pulls.size() + _incoming.size()
	while not _queue.is_empty() and running < MAX_PARALLEL and _online():
		var job: Dictionary = _queue.pop_front()
		running += 1
		match String(job.get("k", "")):
			"pull":
				_request_pull(String(job.rel), String(job.hash), String(job.get("purpose", "pull")))
			"push":
				_push(String(job.rel), String(job.hash), String(job.base))
	if plan_running and _queue.is_empty() and _inflight.is_empty() and _pending_pulls.is_empty() and _incoming.is_empty():
		plan_running = false
		Log.info("files", "Plan finished: %d pulled, %d pushed, %d merged, %d deleted, %d held for you" % [_stats.pulled, _stats.pushed, _stats.merged, _stats.deleted, conflicts.size()])
		_after_plan()


func _after_plan() -> void:
	if not _pulled_now.is_empty():
		files_written.emit(_pulled_now.duplicate())
		_pulled_now.clear()
	# Local changes noticed while the plan ran are handled now.
	for rel in _cache.keys():
		if _cache[rel].h != String(base.get(rel, "")) and not conflicts.has(rel):
			_on_local_file(rel, String(_cache[rel].h))


func _request_pull(rel: String, hash: String, purpose: String) -> void:
	_pending_pulls[rel] = {"hash": hash, "purpose": purpose, "t": Util.now_ms()}
	session.send({"t": "file_get", "rel": rel})
	Log.debug("files", "Requesting %s from the host (%s)" % [rel, purpose])


func _push(rel: String, hash: String, base_hash: String) -> void:
	var abs_path := Util.rel_to_abs(rel)
	if not FileAccess.file_exists(abs_path):
		return
	var bytes := FileAccess.get_file_as_bytes(abs_path)
	var real := Util.sha256_bytes(bytes)
	if real != hash:
		hash = real
	_inflight[rel] = hash
	_remember_blob(rel, hash, bytes)
	_send_blob("file_put", rel, hash, bytes, {"base": base_hash})
	Log.info("files", "Sending %s (%s) to the host" % [rel, Util.format_bytes(bytes.size())])


## Splits a file into chunks and sends them on the low-priority lane. `to_pid` < 0 sends to the host.
func _send_blob(kind: String, rel: String, hash: String, bytes: PackedByteArray, extra: Dictionary, to_pid: int = -1) -> void:
	var count := maxi(1, int(ceil(float(bytes.size()) / CHUNK_BYTES)))
	var head := {"t": kind, "rel": rel, "hash": hash, "size": bytes.size(), "count": count}
	head.merge(extra)
	_deliver(to_pid, head)
	for i in count:
		var chunk := bytes.slice(i * CHUNK_BYTES, mini((i + 1) * CHUNK_BYTES, bytes.size()))
		_deliver(to_pid, {"t": "file_chunk", "rel": rel, "hash": hash, "i": i, "data": chunk})


func _deliver(to_pid: int, msg: Dictionary) -> void:
	if to_pid < 0:
		session.send(msg, true)
	else:
		session.deliver(to_pid, msg, true)


func _begin_incoming(key: String, head: Dictionary, from_pid: int) -> void:
	_incoming[key] = {"head": head, "chunks": {}, "from": from_pid, "got": 0, "started": Util.now_ms()}


func _on_chunk(m: Dictionary, from_pid: int) -> void:
	var key := String(m.get("rel", "")) + "|" + String(m.get("hash", ""))
	var inc: Variant = _incoming.get(key)
	if inc == null:
		return
	if not inc.chunks.has(int(m.get("i", 0))):
		inc.chunks[int(m.get("i", 0))] = m.get("data", PackedByteArray())
		inc.got += 1
	if inc.got >= int(inc.head.get("count", 1)):
		_incoming.erase(key)
		var bytes := PackedByteArray()
		for i in int(inc.head.get("count", 1)):
			bytes.append_array(inc.chunks.get(i, PackedByteArray()))
		_on_blob_complete(inc.head, bytes, from_pid)


func _on_blob_complete(head: Dictionary, bytes: PackedByteArray, from_pid: int) -> void:
	var rel := String(head.get("rel", ""))
	var hash := String(head.get("hash", ""))
	if Util.sha256_bytes(bytes) != hash:
		Log.error("files", "%s arrived corrupted (checksum mismatch); ignoring" % rel)
		_inflight.erase(rel)
		_pending_pulls.erase(rel)
		return
	if String(head.get("t", "")) == "file_put":
		_host_receive_put(from_pid, head, bytes)
	else:
		_client_receive_file(head, bytes)


# --- client side ---------------------------------------------------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	_enter()
	match String(m.get("t", "")):
		"file_manifest":
			_on_manifest(m)
		"file_data":
			var file_rel := String(m.get("rel", ""))
			if not _pending_pulls.has(file_rel):
				Log.debug("files", "Ignoring an unsolicited or stale transfer of %s" % file_rel)
				return
			_begin_incoming(file_rel + "|" + String(m.get("hash", "")), m, 1)
		"file_chunk":
			_on_chunk(m, 1)
		"file_missing":
			var rel := String(m.get("rel", ""))
			_pending_pulls.erase(rel)
			Log.warn("files", "The host no longer has %s" % rel)
		"file_result":
			_on_result(m)
		"file_changed":
			_on_remote_changed(String(m.get("rel", "")), String(m.get("hash", "")))
		"file_deleted":
			_on_remote_deleted(String(m.get("rel", "")))
		"file_dir_created":
			_apply_remote_dirs_created(m.get("dirs", []), bool(m.get("recreated", false)))
		"file_dir_deleted":
			_apply_remote_dirs_deleted(m.get("dirs", []))


func session_started() -> void:
	_enter()
	if session.is_host:
		# The host's files are the reference: whatever is on disk now is the current state.
		for rel in _cache:
			base[rel] = String(_cache[rel].h)
		_mark_dirty()
		return
	if scan_complete:
		request_plan()


func session_lost() -> void:
	_inflight.clear()
	_pending_pulls.clear()
	_incoming.clear()
	_queue.clear()
	plan_running = false


func session_resumed() -> void:
	_enter()
	if scan_complete and not session.is_host:
		request_plan()


func request_plan() -> void:
	if not _online() or session.is_host:
		return
	plan_running = true
	_last_plan_ms = Util.now_ms()
	_stats = {"pulled": 0, "pushed": 0, "merged": 0, "deleted": 0}
	session.send({"t": "file_manifest_req"})
	Log.info("files", "Comparing your project files with the host's...")


func _on_manifest(m: Dictionary) -> void:
	var host: Dictionary = m.get("files", {})
	_reconcile_manifest_dirs(m.get("dirs", []))
	var rels := {}
	for rel in host:
		rels[rel] = true
	for rel in _cache:
		rels[rel] = true
	for rel in base:
		rels[rel] = true
	var pulls := 0
	var pushes := 0
	var skipped_busy := 0
	for rel in rels:
		if is_ignored(rel):
			continue
		var h: String = String(host[rel][0]) if host.has(rel) else ""
		if _is_busy(rel):
			skipped_busy += 1
			_was_busy[rel] = {"hash": h, "deleted": not host.has(rel)}
			continue
		var l: String = String(_cache[rel].h) if _cache.has(rel) else ""
		var b: String = String(base.get(rel, ""))
		if h == l:
			if not h.is_empty() and b != h:
				base[rel] = h
				_mark_dirty()
				_remember_after_change(rel, h)
			continue
		if conflicts.has(rel):
			continue
		if l.is_empty():
			# We do not have it.
			if b.is_empty():
				_queue_job({"k": "pull", "rel": rel, "hash": h})
				pulls += 1
			elif b == h:
				session.send({"t": "file_delete", "rel": rel, "base": b})
				pushes += 1
			else:
				Log.info("files", "%s was deleted here but changed on the host: keeping the host's version" % rel)
				_queue_job({"k": "pull", "rel": rel, "hash": h})
				pulls += 1
		elif h.is_empty():
			if b == l:
				_apply_delete(rel, "the host deleted it")
			elif b.is_empty() or b != l:
				_queue_job({"k": "push", "rel": rel, "hash": l, "base": ""})
				pushes += 1
		elif b == l:
			_queue_job({"k": "pull", "rel": rel, "hash": h})
			pulls += 1
		elif b == h:
			_queue_job({"k": "push", "rel": rel, "hash": l, "base": b})
			pushes += 1
		elif b.is_empty():
			# No common history: the host's copy wins, ours is backed up first.
			var saved := Util.backup_project_file(rel, "first sync")
			Log.warn("files", "%s differs from the host's and has no shared history: host's version wins (yours is backed up: %s)" % [rel, saved.get_file() if not saved.is_empty() else "n/a"])
			_queue_job({"k": "pull", "rel": rel, "hash": h})
			pulls += 1
		else:
			_queue_job({"k": "pull", "rel": rel, "hash": h, "purpose": "merge"})
			pulls += 1
	Log.info("files", "Plan: %d to receive, %d to send%s" % [pulls, pushes, "" if skipped_busy == 0 else ", %d skipped because they are open in an editor" % skipped_busy])
	_mark_dirty()
	_flush_queue()
	if _queue.is_empty() and _pending_pulls.is_empty() and _inflight.is_empty():
		plan_running = false
		Log.info("files", "Everything is already in sync")
		_after_plan()


func _reconcile_manifest_dirs(raw_host_dirs: Variant) -> void:
	var host_dirs := _safe_dir_set(raw_host_dirs)
	var all_dirs := {}
	for rel in host_dirs:
		all_dirs[rel] = true
	for rel in _dir_base:
		all_dirs[rel] = true
	for rel in _dir_cache:
		all_dirs[rel] = true
	for rel in _deleted_dirs:
		all_dirs[rel] = true
	var ordered: Array = all_dirs.keys()
	ordered.sort_custom(func(a: String, b: String) -> bool: return a.count("/") < b.count("/"))
	var create_at_host := []
	for rel in ordered:
		var host_has: bool = host_dirs.has(rel)
		var local_has: bool = DirAccess.dir_exists_absolute(Util.rel_to_abs(rel))
		var was_shared: bool = _dir_base.has(rel)
		Log.debug("files", "Folder plan %s: host=%s local=%s shared=%s deleted=%s" % [rel, host_has, local_has, was_shared, _deleted_dirs.has(rel)])
		if host_has == local_has:
			if host_has:
				_dir_cache[rel] = true
				_dir_base[rel] = true
				_deleted_dirs.erase(rel)
			else:
				_dir_cache.erase(rel)
				_dir_base.erase(rel)
				# Keep the tombstone while both copies are absent. A later local
				# recreation must be marked explicitly so the host can distinguish it
				# from a delayed create message for the deleted folder.
			continue
		if local_has and not host_has:
			if _recreated_dirs.has(rel):
				create_at_host.append({"rel": rel, "recreated": true})
			elif _deleted_dirs.has(rel):
				if not _dir_cache.has(rel):
					# The directory exists again but its old cached copy was already
					# removed. This is a recreation even if the next disk scan has not
					# run yet after reconnect.
					_recreated_dirs[rel] = true
					create_at_host.append({"rel": rel, "recreated": true})
				else:
					_deleted_dirs[rel] = true
					session.send({"t": "file_dir_delete", "rel": rel})
			elif was_shared:
				_pending_dir_deletes[rel] = {"announce": false}
				_process_one_dir_delete(rel)
			else:
				create_at_host.append({"rel": rel, "recreated": false})
			continue
		if host_has and not local_has:
			if _deleted_dirs.has(rel):
				session.send({"t": "file_dir_delete", "rel": rel})
			else:
				_apply_remote_dirs_created([rel])
	if not create_at_host.is_empty():
		for entry in create_at_host:
			_announce_dir_created(String(entry.rel), bool(entry.recreated))
	_mark_dirty()


func _on_remote_changed(rel: String, hash: String) -> void:
	if is_ignored(rel) or not scan_complete:
		return
	if _is_busy(rel):
		_was_busy[rel] = {"hash": hash, "deleted": false}
		Log.debug("files", "%s changed on the host but is open here; the live editor handles it" % rel)
		return
	var l := local_hash(rel)
	var b := String(base.get(rel, ""))
	if l == hash:
		base[rel] = hash
		_mark_dirty()
		return
	if l == b or l.is_empty() and b.is_empty():
		_queue_job({"k": "pull", "rel": rel, "hash": hash})
	elif l.is_empty():
		_queue_job({"k": "pull", "rel": rel, "hash": hash})
	else:
		_queue_job({"k": "pull", "rel": rel, "hash": hash, "purpose": "merge"})
	_flush_queue()


func _on_remote_deleted(rel: String) -> void:
	if is_ignored(rel):
		return
	# A pull started before the deletion can finish after its file_deleted message.
	# Cancel it and discard its partial chunks so an old copy cannot resurrect the file.
	_pending_pulls.erase(rel)
	for key in _incoming.keys():
		if String(key).begins_with(rel + "|"):
			_incoming.erase(key)
	if _is_busy(rel):
		_was_busy[rel] = {"hash": "", "deleted": true}
		return
	var l := local_hash(rel)
	if l.is_empty():
		base.erase(rel)
		return
	if l == String(base.get(rel, "")):
		_apply_delete(rel, "deleted by someone else")
	else:
		Log.warn("files", "%s was deleted on the host but you changed it: keeping your version" % rel)
		session.send({"t": "file_manifest_req"})


func _apply_delete(rel: String, why: String) -> void:
	var saved := Util.backup_project_file(rel, "deleted")
	var err := DirAccess.remove_absolute(Util.rel_to_abs(rel))
	base.erase(rel)
	_cache.erase(rel)
	_mark_dirty()
	_stats.deleted += 1
	Log.info("files", "Deleted %s (%s)%s" % [rel, why, "; backup: " + saved.get_file() if not saved.is_empty() else ""])
	if err == OK:
		files_written.emit([Util.rel_to_res(rel)])


func _client_receive_file(head: Dictionary, bytes: PackedByteArray) -> void:
	var rel := String(head.get("rel", ""))
	var hash := String(head.get("hash", ""))
	var pending: Variant = _pending_pulls.get(rel)
	_pending_pulls.erase(rel)
	if not pending is Dictionary:
		Log.debug("files", "Ignoring a stale completed transfer of %s" % rel)
		return
	var purpose := String(pending.get("purpose", "pull"))
	if purpose == "conflict":
		# Only keep the host's version so "Use theirs" / markers can be offered later.
		_remember_blob(rel, hash, bytes)
		Log.debug("files", "Stored the host's version of %s for the conflict choice" % rel)
		return
	if _is_busy(rel):
		Log.debug("files", "Dropped %s: it became busy" % rel)
		return
	if purpose == "force":
		_write_pulled(rel, hash, bytes)
		return
	var l := local_hash(rel)
	var b := String(base.get(rel, ""))
	if purpose == "merge" and not l.is_empty() and l != hash:
		_merge_with(rel, l, hash, b, bytes)
		return
	if not l.is_empty() and l != b and l != hash and not b.is_empty():
		# Changed locally while it was in flight: merge instead of overwriting.
		_merge_with(rel, l, hash, b, bytes)
		return
	_write_pulled(rel, hash, bytes)


func _write_pulled(rel: String, hash: String, bytes: PackedByteArray) -> void:
	var abs_path := Util.rel_to_abs(rel)
	if FileAccess.file_exists(abs_path) and local_hash(rel) != hash:
		Util.backup_project_file(rel, "replaced by the host's version")
	var err := Util.write_bytes_atomic(abs_path, bytes)
	if err != OK:
		Log.error("files", "Could not write %s: %s" % [rel, error_string(err)])
		return
	base[rel] = hash
	_cache[rel] = {"m": FileAccess.get_modified_time(abs_path), "h": hash, "s": bytes.size()}
	_remember_blob(rel, hash, bytes)
	_mark_dirty()
	_stats.pulled += 1
	_pulled_now.append(Util.rel_to_res(rel))
	Log.info("files", "Received %s (%s)" % [rel, Util.format_bytes(bytes.size())])
	if not plan_running:
		files_written.emit(_pulled_now.duplicate())
		_pulled_now.clear()


func _merge_with(rel: String, local_h: String, host_h: String, base_h: String, host_bytes: PackedByteArray) -> void:
	var abs_path := Util.rel_to_abs(rel)
	var local_bytes := FileAccess.get_file_as_bytes(abs_path)
	_remember_blob(rel, host_h, host_bytes)
	_remember_blob(rel, local_h, local_bytes)
	var base_text: Variant = _blob_text(base_h)
	if _is_text_path(rel) and base_text != null and local_bytes.size() <= MAX_MERGE_BYTES and host_bytes.size() <= MAX_MERGE_BYTES:
		var r: Dictionary = Diff3.merge(String(base_text), local_bytes.get_string_from_utf8(), host_bytes.get_string_from_utf8(), "yours", "host")
		if r.clean:
			var merged_bytes := String(r.text).to_utf8_buffer()
			var err := Util.write_bytes_atomic(abs_path, merged_bytes)
			if err == OK:
				var mh := Util.sha256_bytes(merged_bytes)
				_cache[rel] = {"m": FileAccess.get_modified_time(abs_path), "h": mh, "s": merged_bytes.size()}
				base[rel] = host_h
				_remember_blob(rel, mh, merged_bytes)
				_mark_dirty()
				_stats.merged += 1
				_pulled_now.append(Util.rel_to_res(rel))
				Log.info("files", "%s: your edits and the host's edits were merged automatically" % rel)
				_push(rel, mh, host_h)
				return
	_hold_conflict(rel, local_h, host_h, base_h)


func _hold_conflict(rel: String, local_h: String, host_h: String, base_h: String) -> void:
	conflicts[rel] = {"rel": rel, "local": local_h, "host": host_h, "base": base_h, "text": _is_text_path(rel)}
	_mark_dirty()
	Log.warn("files", "%s was changed by you AND by someone else and cannot be merged automatically: holding it (nothing was overwritten) - choose in the Collab dock" % rel)
	session.notice.emit("Conflict in %s: you and someone else both changed it. Choose which to keep in the Collab dock." % rel.get_file(), 1)
	conflicts_changed.emit()


func _on_result(m: Dictionary) -> void:
	var rel := String(m.get("rel", ""))
	var hash := String(m.get("hash", ""))
	_inflight.erase(rel)
	match String(m.get("status", "")):
		"accepted":
			base[rel] = hash
			_stats.pushed += 1
			_mark_dirty()
			Log.info("files", "The host accepted %s" % rel)
		"merged":
			Log.info("files", "The host merged your %s with a newer version; fetching the result" % rel)
			_stats.merged += 1
		"conflict":
			_hold_conflict(rel, hash, String(m.get("host", "")), String(m.get("base", "")))
			if not String(m.get("host", "")).is_empty():
				_request_pull(rel, String(m.get("host", "")), "conflict")
		"busy":
			_deferred[rel] = true
			Log.info("files", "%s is open live on the host; will retry when it closes" % rel)
		"rejected":
			Log.warn("files", "The host rejected %s: %s" % [rel, String(m.get("reason", ""))])


# --- conflict resolution (called by the dock) -----------------------------------------------------------------------------------

func held_list() -> Array:
	var out := []
	for rel in conflicts:
		var c: Dictionary = conflicts[rel]
		out.append({"kind": "file", "rel": rel, "text": c.get("text", false)})
	return out


func resolve(rel: String, choice: String) -> bool:
	_enter()
	var c: Variant = conflicts.get(rel)
	if c == null:
		return false
	var abs_path := Util.rel_to_abs(rel)
	match choice:
		"mine":
			conflicts.erase(rel)
			if _online():
				_push(rel, local_hash(rel), String(c.host))
			Log.info("files", "Kept your version of %s; sending it to the host" % rel)
		"theirs":
			Util.backup_project_file(rel, "conflict: replaced by theirs")
			conflicts.erase(rel)
			_request_pull(rel, String(c.host), "force")
			Log.info("files", "Using the host's version of %s (yours is backed up)" % rel)
		"markers":
			var base_text: Variant = _blob_text(String(c.base))
			var host_text: Variant = _blob_text(String(c.host))
			if base_text == null or host_text == null:
				return false
			Util.backup_project_file(rel, "conflict: markers")
			var local_text := FileAccess.get_file_as_string(abs_path)
			var r: Dictionary = Diff3.merge(String(base_text), local_text, String(host_text), "yours", "host")
			Util.write_text_atomic(abs_path, r.text)
			base[rel] = String(c.host)
			conflicts.erase(rel)
			_cache.erase(rel)
			files_written.emit([Util.rel_to_res(rel)])
			Log.info("files", "Wrote %s with conflict markers; fix it and save to share the result" % rel)
		_:
			return false
	_mark_dirty()
	conflicts_changed.emit()
	return true


# --- host side ----------------------------------------------------------------------------------------------------------------

func _host_handle(pid: int, uid: String, m: Dictionary) -> void:
	_enter()
	match String(m.get("t", "")):
		"file_manifest_req":
			var files := {}
			for rel in _cache:
				if not is_ignored(rel):
					files[rel] = [String(_cache[rel].h), int(_cache[rel].get("s", 0))]
			var dirs := []
			for rel in _dir_cache:
				if _safe_dir_rel(String(rel)) and DirAccess.dir_exists_absolute(Util.rel_to_abs(String(rel))):
					dirs.append(String(rel))
			dirs.sort()
			session.deliver(pid, {"t": "file_manifest", "files": files, "dirs": dirs})
		"file_get":
			_host_serve(pid, String(m.get("rel", "")))
		"file_put":
			_begin_incoming(String(m.get("rel", "")) + "|" + String(m.get("hash", "")), m, pid)
		"file_chunk":
			_on_chunk(m, pid)
		"file_delete":
			_host_delete(pid, uid, String(m.get("rel", "")), String(m.get("base", "")))
		"file_dir_create":
			_host_create_dir(String(m.get("rel", "")), uid, bool(m.get("recreated", false)))
		"file_dir_delete":
			_host_delete_dir(String(m.get("rel", "")), pid, uid)


func _host_create_dir(rel: String, uid: String, recreated: bool = false) -> void:
	if not _safe_dir_rel(rel):
		return
	var dirs := _dir_paths(rel)
	dirs.sort_custom(func(a: String, b: String) -> bool: return a.count("/") < b.count("/"))
	var created := []
	for dir_rel in dirs:
		if _deleted_dirs.has(dir_rel) and not recreated:
			Log.debug("files", "Ignored stale folder creation for deleted %s" % dir_rel)
			continue
		var abs_path := Util.rel_to_abs(String(dir_rel))
		if not DirAccess.dir_exists_absolute(abs_path):
			var err := DirAccess.make_dir_recursive_absolute(abs_path)
			if err != OK and not DirAccess.dir_exists_absolute(abs_path):
				Log.warn("files", "Could not create folder %s: %s" % [dir_rel, error_string(err)])
				continue
		_dir_cache[dir_rel] = true
		_dir_base[dir_rel] = true
		_deleted_dirs.erase(dir_rel)
		_pending_dir_deletes.erase(dir_rel)
		created.append(String(dir_rel))
	_mark_dirty()
	if not created.is_empty():
		session.broadcast({"t": "file_dir_created", "dirs": created, "recreated": recreated, "by": uid}, 1)
		files_written.emit([Util.rel_to_res(String(created.back()))])


func _host_delete_dir(rel: String, pid: int, uid: String) -> void:
	if not _safe_dir_rel(rel):
		return
	# A directory delete means the whole subtree is gone. Delete its files first and
	# announce each one so clients remove the exact paths before the empty folders.
	var files := _files_under_dir(rel)
	for file_rel in files:
		var hash := local_hash(String(file_rel))
		if not hash.is_empty():
			_host_delete(pid, uid, String(file_rel), hash)
	var dirs := _directories_under_dir(rel)
	dirs.sort_custom(func(a: String, b: String) -> bool: return a.count("/") > b.count("/"))
	for dir_rel in dirs:
		_pending_dir_deletes[String(dir_rel)] = {"announce": true}
		_deleted_dirs[String(dir_rel)] = true
	for dir_rel in dirs:
		_process_one_dir_delete(String(dir_rel))


func _files_under_dir(rel: String) -> Array:
	var out := []
	var abs_path := Util.rel_to_abs(rel)
	if not DirAccess.dir_exists_absolute(abs_path):
		return out
	for name in DirAccess.get_files_at(abs_path):
		var child := rel.path_join(name)
		if _safe_rel(child):
			out.append(child)
	for name in DirAccess.get_directories_at(abs_path):
		var child := rel.path_join(name)
		if _safe_dir_rel(child):
			out.append_array(_files_under_dir(child))
	return out


func _directories_under_dir(rel: String) -> Array:
	var out := [rel]
	var abs_path := Util.rel_to_abs(rel)
	if not DirAccess.dir_exists_absolute(abs_path):
		return out
	for name in DirAccess.get_directories_at(abs_path):
		var child := rel.path_join(name)
		if _safe_dir_rel(child):
			out.append_array(_directories_under_dir(child))
	return out


func _safe_rel(rel: String) -> bool:
	return Util.is_safe_rel_path(rel) and not is_ignored(rel)


func _host_serve(pid: int, rel: String) -> void:
	if not _safe_rel(rel) or not FileAccess.file_exists(Util.rel_to_abs(rel)):
		session.deliver(pid, {"t": "file_missing", "rel": rel})
		return
	var bytes := FileAccess.get_file_as_bytes(Util.rel_to_abs(rel))
	var hash := Util.sha256_bytes(bytes)
	_remember_blob(rel, hash, bytes)
	_send_blob("file_data", rel, hash, bytes, {}, pid)


func _host_receive_put(pid: int, head: Dictionary, bytes: PackedByteArray) -> void:
	var rel := String(head.get("rel", ""))
	var hash := String(head.get("hash", ""))
	var base_h := String(head.get("base", ""))
	var who: String = session.peer_name(pid)
	if not _safe_rel(rel):
		session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "rejected", "reason": "path not allowed"})
		return
	if bytes.size() > max_file_bytes:
		session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "rejected", "reason": "too large"})
		return
	var res_path := Util.rel_to_res(rel)
	if _is_busy(rel) and rel.get_extension().to_lower() in SCENE_EXTS:
		session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "busy"})
		return
	var live_doc: Variant = session.docs.texts.get(res_path)
	if live_doc != null and not live_doc.watchers.is_empty() and _is_text_path(rel):
		var verdict := _host_apply_to_live_doc(rel, hash, base_h, bytes, live_doc, who)
		verdict["t"] = "file_result"
		verdict["rel"] = rel
		verdict["hash"] = hash
		session.deliver(pid, verdict)
		return
	var hh := local_hash(rel)
	_remember_blob(rel, hash, bytes)
	if hh == hash:
		base[rel] = hash
		_mark_dirty()
		session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "accepted"})
		return
	var fast_forward := hh == base_h
	if not fast_forward:
		var base_text: Variant = _blob_text(base_h)
		var host_bytes := FileAccess.get_file_as_bytes(Util.rel_to_abs(rel)) if not hh.is_empty() else PackedByteArray()
		if _is_text_path(rel) and base_text != null and not hh.is_empty() and bytes.size() <= MAX_MERGE_BYTES:
			var r: Dictionary = Diff3.merge(String(base_text), host_bytes.get_string_from_utf8(), bytes.get_string_from_utf8(), "host", who)
			if r.clean:
				var merged := String(r.text).to_utf8_buffer()
				if _host_write(rel, merged, "merged edits from %s" % who):
					session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "merged"})
					var mh := Util.sha256_bytes(merged)
					session.broadcast({"t": "file_changed", "rel": rel, "hash": mh, "by": session.my_uid}, 1, true)
					Log.info("files", "Merged %s's edit of %s with a newer version on the host" % [who, rel])
					return
		Log.warn("files", "%s's change to %s conflicts with a newer version here; it was NOT applied" % [who, rel])
		session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "conflict", "host": hh, "base": base_h})
		return
	if not _host_write(rel, bytes, "update from %s" % who):
		session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "rejected", "reason": "write failed"})
		return
	session.deliver(pid, {"t": "file_result", "rel": rel, "hash": hash, "status": "accepted"})
	for other in session.peers:
		if other != pid and other != 1:
			session.deliver(other, {"t": "file_changed", "rel": rel, "hash": hash, "by": String(session.peers[pid].get("uid", ""))}, true)
	Log.info("files", "Accepted %s from %s (%s) and passed it on" % [rel, who, Util.format_bytes(bytes.size())])


## A closed file was pushed while somebody has it open live: the change joins the live document
## (merged with what people typed meanwhile) instead of touching the disk behind their backs.
func _host_apply_to_live_doc(rel: String, hash: String, base_h: String, bytes: PackedByteArray, doc, who: String) -> Dictionary:
	var pushed := Util.norm_text(bytes.get_string_from_utf8())
	if pushed == doc.text:
		return {"status": "accepted"}
	var base_text: Variant = _blob_text(base_h)
	var conflict := {"status": "conflict", "host": local_hash(rel), "base": base_h}
	if base_text == null:
		return conflict
	var r: Dictionary = Diff3.merge(Util.norm_text(String(base_text)), doc.text, pushed, "live", who)
	if not r.clean:
		Log.warn("files", "%s's change to %s overlaps what is being typed live: held as a conflict" % [who, rel])
		return conflict
	var op: RefCounted = OT.diff_lines(doc.text, String(r.text))
	_live_cseq += 1
	var transformed: Variant = doc.receive(doc.rev, op, session.my_uid, _live_cseq, "file")
	if transformed == null:
		return conflict
	var out := {"t": "tx_op", "path": doc.path, "by": session.my_uid, "cid": "file", "cseq": _live_cseq, "op": transformed.to_array(), "rev": doc.rev}
	for w in doc.watchers:
		session.deliver(w, out)
	session.docs.text_doc_changed.emit(doc.path)
	Log.info("files", "%s's change to %s was merged into the live document" % [who, rel])
	return {"status": "accepted" if String(r.text) == pushed else "merged"}


func _host_write(rel: String, bytes: PackedByteArray, why: String) -> bool:
	var abs_path := Util.rel_to_abs(rel)
	if FileAccess.file_exists(abs_path):
		Util.backup_project_file(rel, why)
	var err := Util.write_bytes_atomic(abs_path, bytes)
	if err != OK:
		Log.error("files", "Could not write %s: %s" % [rel, error_string(err)])
		return false
	var hash := Util.sha256_bytes(bytes)
	base[rel] = hash
	_cache[rel] = {"m": FileAccess.get_modified_time(abs_path), "h": hash, "s": bytes.size()}
	_remember_blob(rel, hash, bytes)
	_mark_dirty()
	var res_path := Util.rel_to_res(rel)
	files_written.emit([res_path])
	return true


func _host_delete(pid: int, uid: String, rel: String, base_h: String) -> void:
	if not _safe_rel(rel) or _is_busy(rel):
		return
	var hh := local_hash(rel)
	if hh.is_empty():
		base.erase(rel)
		return
	if hh != base_h:
		Log.warn("files", "%s asked to delete %s but it changed on the host since: kept" % [session.peer_name(pid), rel])
		return
	Util.backup_project_file(rel, "deleted by " + session.peer_name(pid))
	DirAccess.remove_absolute(Util.rel_to_abs(rel))
	base.erase(rel)
	_cache.erase(rel)
	_mark_dirty()
	files_written.emit([Util.rel_to_res(rel)])
	for other in session.peers:
		if other != pid and other != 1:
			session.deliver(other, {"t": "file_deleted", "rel": rel, "by": uid})
	Log.info("files", "Deleted %s at %s's request (backup kept)" % [rel, session.peer_name(pid)])
