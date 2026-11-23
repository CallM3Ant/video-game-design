@tool
extends RefCounted
## Live script co-editing: everybody types in the same file at once (operational transformation, as
## in Google Docs). Works for scripts open in Godot's script editor and for the add-on's own C++
## editor tab (anything that exposes a CodeEdit).
##
## Each open tab becomes an STracker with an OT client. Typing is turned into small operations as
## you type - nothing waits for a save. Teammates' operations are applied to the buffer without
## moving your caret. If the link drops while you keep typing, the buffer is merged three ways
## (last agreed text / your buffer / the host's text) when it returns.

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")
const OT := preload("res://addons/godot_collab/core/ot.gd")
const OTClient := preload("res://addons/godot_collab/core/ot_client.gd")

signal text_applied(path: String)

const MAX_LIVE_CHARS := 600000
const DISK_WRITE_DELAY_MS := 800
const CURSOR_SEND_MS := 120
const CURSOR_EXPIRE_MS := 5000


class CursorOverlay:
	extends Control
	var code: CodeEdit
	var entries: Array = []

	func _draw() -> void:
		if not is_instance_valid(code):
			return
		var font := get_theme_default_font()
		var font_size := get_theme_default_font_size()
		for entry in entries:
			var color: Color = entry.get("color", Color.CYAN)
			var selection: Array = entry.get("selection", [])
			if selection.size() == 4:
				var from_line := clampi(int(selection[0]), 0, code.get_line_count() - 1)
				var from_col := clampi(int(selection[1]), 0, code.get_line(from_line).length())
				var to_line := clampi(int(selection[2]), 0, code.get_line_count() - 1)
				var to_col := clampi(int(selection[3]), 0, code.get_line(to_line).length())
				if from_line > to_line or from_line == to_line and from_col > to_col:
					var swap_line := from_line
					var swap_col := from_col
					from_line = to_line
					from_col = to_col
					to_line = swap_line
					to_col = swap_col
				var tint := color
				tint.a = 0.22
				for line in range(from_line, to_line + 1):
					var left_col := from_col if line == from_line else 0
					var right_col := to_col if line == to_line else code.get_line(line).length()
					var left := code.get_rect_at_line_column(line, left_col)
					var right := code.get_rect_at_line_column(line, right_col)
					if left.position.x < 0 or left.position.y < 0:
						continue
					var width := maxf(3.0, float(right.position.x - left.position.x))
					draw_rect(Rect2(left.position, Vector2(width, maxf(2.0, left.size.y))), tint)
			var line := clampi(int(entry.get("line", 0)), 0, code.get_line_count() - 1)
			var column := clampi(int(entry.get("column", 0)), 0, code.get_line(line).length())
			var caret_rect := code.get_rect_at_line_column(line, column)
			if caret_rect.position.x < 0 or caret_rect.position.y < 0:
				continue
			var caret := Vector2(caret_rect.position)
			var height := maxf(12.0, float(caret_rect.size.y))
			draw_line(caret, caret + Vector2(0, height), color, 2.0, true)
			var label := String(entry.get("name", "Teammate"))
			var label_width := maxf(48.0, font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 12.0)
			var label_pos := caret + Vector2(2, -18)
			if label_pos.y < 0:
				label_pos.y = caret.y + height
			draw_rect(Rect2(label_pos, Vector2(label_width, 18)), color)
			draw_string(font, label_pos + Vector2(6, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


class STracker:
	extends RefCounted
	var path := ""
	var code: CodeEdit = null
	var client = null
	var known := ""
	var ready := false
	var synced_once := false
	var external := false
	var seen_version := -1
	var cb_text: Callable
	var opened_ms := 0
	var overlay: CursorOverlay


var session
var env
var trackers: Dictionary = {}
var _last_scan := 0
var _disk_writes: Dictionary = {}
var _ops_sent := 0
var _ops_received := 0
var _remote_cursors: Dictionary = {} # path -> peer id -> cursor data
var _active_cursor_path := ""
var _last_cursor_sent := 0
var _last_cursor_payload := ""
## Paths nobody should live-edit through this module (the add-on's own sources, caches).
var blocked_prefixes: Array = ["res://addons/godot_collab/", "res://.godot/"]


func setup(p_session, p_env) -> void:
	session = p_session
	env = p_env
	if session.docs.has_signal("text_doc_changed"):
		session.docs.text_doc_changed.connect(_on_host_doc_changed)


func teardown() -> void:
	for path in trackers.keys():
		_drop(path, false)
	if session != null and session.docs != null and session.docs.text_doc_changed.is_connected(_on_host_doc_changed):
		session.docs.text_doc_changed.disconnect(_on_host_doc_changed)
	_remote_cursors.clear()


func _online() -> bool:
	return session != null and session.joined_ok and session.is_online()


func is_live(path: String) -> bool:
	return trackers.has(path)


func is_open(path: String) -> bool:
	if trackers.has(path):
		return true
	for e in env.script_editors():
		if e.path == path:
			return true
	return false


func status_text() -> String:
	var live := 0
	for p in trackers:
		if trackers[p].ready:
			live += 1
	return "%d script(s) open, %d live" % [trackers.size(), live]


# --- session lifecycle -----------------------------------------------------------------------------------

func session_started() -> void:
	_scan_editors(true)
	for path in trackers:
		var tr: STracker = trackers[path]
		if _online() and not tr.ready and tr.opened_ms == 0:
			_send_open(tr)


func session_lost() -> void:
	for path in trackers:
		trackers[path].ready = false
	if not trackers.is_empty():
		Log.info("text", "Link lost: %d open script(s) keep working locally and will be merged on reconnect" % trackers.size())


func session_resumed() -> void:
	for path in trackers:
		var tr: STracker = trackers[path]
		_flush_pending_local(tr)
		_send_open(tr)


## Drops session-owned tabs cleanly before switching to a different collaboration session.
## Keep external CodeEdits (the add-on's C++ tabs) attached.
func reset_session_trackers() -> void:
	for path in trackers.keys():
		var tr: STracker = trackers[path]
		if not tr.external:
			_drop(String(path), false)


func _send_open(tr: STracker) -> void:
	var msg := {"t": "tx_open", "path": tr.path}
	if tr.client != null and not tr.client.epoch.is_empty() and tr.synced_once:
		msg["epoch"] = tr.client.epoch
		msg["rev"] = tr.client.rev
	if session.is_host and is_instance_valid(tr.code):
		# The host's own buffer (maybe unsaved) is what a new document starts from.
		msg["text"] = Util.norm_text(tr.code.text)
	tr.ready = false
	tr.opened_ms = Util.now_ms()
	session.send(msg)


# --- editors <-> trackers ---------------------------------------------------------------------------------------

func _syncable(path: String) -> bool:
	if not path.begins_with("res://"):
		return false
	for pre in blocked_prefixes:
		if path.begins_with(pre):
			return false
	return Util.is_safe_res_path(path)


## Starts/stops live documents to match the open script tabs.
func _scan_editors(force: bool = false) -> void:
	var now := Util.now_ms()
	if not force and now - _last_scan < 500:
		return
	_last_scan = now
	var live := {}
	for e in env.script_editors():
		if _syncable(e.path):
			live[e.path] = e.code
	for path in trackers.keys():
		var tr: STracker = trackers[path]
		if tr.external:
			continue
		if not live.has(path) or tr.code != live[path] or not is_instance_valid(tr.code):
			_drop(path, true)
	if not _online():
		return
	for path in live:
		if not trackers.has(path):
			_start(path, live[path], false)


## Lets another component (the C++ editor) put its own CodeEdit under live sync.
func attach(path: String, code: CodeEdit) -> void:
	if trackers.has(path):
		if trackers[path].code == code:
			return
		_drop(path, true)
	if _syncable(path):
		_start(path, code, true)


func detach(path: String) -> void:
	if trackers.has(path):
		_drop(path, true)


func _start(path: String, code: CodeEdit, external: bool) -> void:
	# The editor can report the same script editor through both its tab scan and
	# an external attach path. Keep tracking idempotent so one CodeEdit gets only
	# one live text callback and overlay.
	if trackers.has(path):
		var existing: STracker = trackers[path]
		if existing.code == code and is_instance_valid(code):
			return
		_drop(path, true)
	if code.text.length() > MAX_LIVE_CHARS:
		Log.warn("text", "%s is too large for live editing (%d chars); it syncs on save instead" % [path, code.text.length()])
		return
	var tr := STracker.new()
	tr.path = path
	tr.code = code
	tr.external = external
	tr.known = Util.norm_text(code.text)
	tr.client = OTClient.new()
	var me := tr
	tr.client.send_op.connect(func(rev: int, op: RefCounted, cseq: int):
		_ops_sent += 1
		session.send({"t": "tx_op", "path": me.path, "rev": rev, "op": op.to_array(), "cseq": cseq, "cid": me.client.cid, "epoch": me.client.epoch}))
	tr.cb_text = _on_text_changed.bind(tr)
	if not code.text_changed.is_connected(tr.cb_text):
		code.text_changed.connect(tr.cb_text)
	tr.overlay = CursorOverlay.new()
	tr.overlay.code = code
	tr.overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.overlay.focus_mode = Control.FOCUS_NONE
	tr.overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	code.add_child(tr.overlay)
	trackers[path] = tr
	Log.info("text", "Live editing %s" % path)
	if _online():
		_send_open(tr)


func _drop(path: String, notify: bool) -> void:
	var tr: STracker = trackers.get(path)
	trackers.erase(path)
	if tr == null:
		return
	if is_instance_valid(tr.code) and tr.code.text_changed.is_connected(tr.cb_text):
		tr.code.text_changed.disconnect(tr.cb_text)
	if is_instance_valid(tr.overlay):
		tr.overlay.queue_free()
	if _active_cursor_path == path:
		_active_cursor_path = ""
	_remote_cursors.erase(path)
	if notify and _online():
		session.send({"t": "tx_close", "path": path})
	Log.info("text", "Stopped live editing %s" % path)


# --- local edits ----------------------------------------------------------------------------------------------------

func _on_text_changed(tr: STracker) -> void:
	_flush_local(tr)


func _flush_pending_local(_tr: STracker) -> void:
	pass


## Turns whatever changed in the editor since we last looked into an operation.
func _flush_local(tr: STracker) -> void:
	if not tr.ready or not is_instance_valid(tr.code):
		return
	var v := tr.code.get_version()
	if v == tr.seen_version:
		return
	tr.seen_version = v
	var now_text := Util.norm_text(tr.code.text)
	if now_text == tr.known:
		return
	var cursor := _lc_to_offset(now_text, tr.code.get_caret_line(), tr.code.get_caret_column())
	var op: RefCounted = OT.diff(tr.known, now_text, cursor)
	tr.known = now_text
	tr.client.apply_client(op)


# --- messages from the host ---------------------------------------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	if String(m.get("t", "")) == "tx_cursor":
		_on_remote_cursor(m)
		return
	var path := String(m.get("path", ""))
	var tr: STracker = trackers.get(path)
	if tr == null or not is_instance_valid(tr.code):
		return
	match String(m.get("t", "")):
		"tx_state":
			_on_state(tr, m)
		"tx_op":
			if not tr.ready:
				return
			_ops_received += 1
			if tr.client.is_own(String(m.get("by", "")), session.my_uid, String(m.get("cid", "")), int(m.get("cseq", 0))):
				tr.client.server_ack()
			else:
				var op: RefCounted = OT.from_array(m.get("op"))
				var local_op: RefCounted = tr.client.apply_server(op) if op != null else null
				if local_op == null:
					_resync(tr, "operations did not line up")
					return
				_apply_to_editor(tr, local_op)
		"tx_reject":
			_resync(tr, String(m.get("reason", "rejected")))


func _resync(tr: STracker, why: String) -> void:
	Log.warn("text", "%s: re-syncing the whole file (%s)" % [tr.path, why])
	tr.client.reset(0, "")
	tr.synced_once = false if why == "epoch" else tr.synced_once
	_send_open(tr)


func _on_state(tr: STracker, m: Dictionary) -> void:
	# Resume: the host replays what we missed while the link was down.
	var since: Variant = m.get("since")
	var epoch := String(m.get("epoch", ""))
	if since is Array and tr.client.epoch == epoch and int(m.get("from_rev", -1)) == tr.client.rev:
		tr.ready = true
		_catch_up_local(tr)
		var me := String(session.my_uid)
		for h in since:
			var own: bool = h.size() >= 4 and String(h[1]) == me and String(h[3]) == tr.client.cid
			if own and tr.client.is_own(me, me, tr.client.cid, int(h[2])):
				tr.client.server_ack()
			else:
				var lop: RefCounted = tr.client.apply_server(OT.from_array(h[0]))
				if lop == null:
					_resync(tr, "replay did not line up")
					return
				_apply_to_editor(tr, lop)
		tr.client.resend()
		Log.info("text", "%s: resumed (%d missed operation(s) replayed)" % [tr.path, since.size()])
		return
	var doc_text := String(m.get("text", ""))
	tr.client.reset(int(m.get("rev", 0)), epoch)
	var local := Util.norm_text(tr.code.text)
	tr.ready = true
	var rel := Util.res_to_rel(tr.path)
	if local == doc_text:
		tr.known = doc_text
	elif bool(m.get("missing", false)) and doc_text.is_empty():
		# The host has no such file yet: what we have becomes the document.
		tr.known = doc_text
		_share(tr, doc_text, local)
		Log.info("text", "%s: shared as a new file" % tr.path)
	elif tr.synced_once:
		# We were typing while apart: merge our buffer with the host's text.
		var merged := OT.merge3(tr.known, local, doc_text)
		tr.known = doc_text
		_set_text_keep_view(tr, merged)
		_share(tr, doc_text, merged)
		Log.info("text", "%s: merged your offline typing with the host's text" % tr.path)
	else:
		# First sync of this tab: the host's text wins; an unsaved difference is backed up.
		var disk := Util.norm_text(Util.read_text(Util.rel_to_abs(rel)))
		if local != disk and local != doc_text:
			var saved := Util.backup_text(rel, local)
			if not saved.is_empty():
				Log.warn("text", "%s: your unsaved buffer differed from the host's text; it was replaced. Backup: %s" % [tr.path, saved])
				session.notice.emit("%s: your unsaved text differed from the host's and was replaced. Backup: %s" % [tr.path.get_file(), saved.get_file()], 1)
		tr.known = doc_text
		_set_text_keep_view(tr, doc_text)
		Log.info("text", "%s: loaded the live text from the host (%d chars)" % [tr.path, doc_text.length()])
	tr.synced_once = true
	tr.seen_version = -1
	text_applied.emit(tr.path)


## While reconnecting with a resume: whatever was typed meanwhile becomes one outstanding edit.
func _catch_up_local(tr: STracker) -> void:
	var now_text := Util.norm_text(tr.code.text)
	if now_text != tr.known:
		var op: RefCounted = OT.diff(tr.known, now_text)
		tr.known = now_text
		tr.client.apply_client(op)
	tr.seen_version = -1


## The editor shows `local` while the document is `doc_text`: send the difference as our edit.
func _share(tr: STracker, doc_text: String, local: String) -> void:
	tr.known = local
	if local != doc_text:
		tr.client.apply_client(OT.diff(doc_text, local))


func _set_text_keep_view(tr: STracker, text: String) -> void:
	var line := tr.code.get_caret_line()
	var col := tr.code.get_caret_column()
	var scroll := tr.code.scroll_vertical
	tr.code.text = text
	tr.code.clear_undo_history()
	tr.code.set_caret_line(mini(line, tr.code.get_line_count() - 1), false)
	tr.code.set_caret_column(col, false)
	tr.code.scroll_vertical = scroll
	tr.seen_version = tr.code.get_version()


## Applies `op` (relative to tr.known) to the CodeEdit with minimal edits so carets stay in place.
func _apply_to_editor(tr: STracker, op: RefCounted) -> void:
	var old := tr.known
	var new_text: Variant = op.apply(old)
	if new_text == null:
		_resync(tr, "operation did not fit the text")
		return
	var edits := []
	var idx := 0
	for c in op.ops:
		if typeof(c) == TYPE_INT and c > 0:
			idx += c
		elif typeof(c) == TYPE_STRING:
			edits.append([idx, idx, c])
		else:
			if not edits.is_empty() and edits[-1][1] == idx and edits[-1][0] == idx:
				edits[-1][1] = idx - c
			else:
				edits.append([idx, idx - c, ""])
			idx -= c
	# Lines inserted or removed above the view would make the text under the reader jump.
	var first_line := tr.code.get_first_visible_line()
	var first_off := _lc_to_offset(old, first_line, 0)
	var shift := 0
	for e in edits:
		if e[0] < first_off:
			var cut_end := mini(e[1], first_off)
			shift += String(e[2]).count("\n") - (old.count("\n", e[0], cut_end) if cut_end > e[0] else 0)
	tr.code.begin_complex_operation()
	for i in range(edits.size() - 1, -1, -1):
		var e: Array = edits[i]
		var a := _offset_to_lc(old, e[0])
		if e[1] > e[0]:
			var b := _offset_to_lc(old, e[1])
			tr.code.remove_text(a.x, a.y, b.x, b.y)
		if not String(e[2]).is_empty():
			tr.code.insert_text(e[2], a.x, a.y, false, false)
	tr.code.end_complex_operation()
	# Godot's own undo must not be able to bring back text that teammates changed.
	tr.code.clear_undo_history()
	if shift != 0:
		tr.code.set_line_as_first_visible(clampi(first_line + shift, 0, tr.code.get_line_count() - 1))
	tr.known = new_text
	if Util.norm_text(tr.code.text) != new_text:
		_set_text_keep_view(tr, new_text)
	tr.seen_version = tr.code.get_version()
	text_applied.emit(tr.path)


static func _offset_to_lc(text: String, off: int) -> Vector2i:
	off = clampi(off, 0, text.length())
	var line := text.count("\n", 0, off) if off > 0 else 0
	var start := text.rfind("\n", off - 1) + 1 if off > 0 else 0
	return Vector2i(line, off - start)


static func _lc_to_offset(text: String, line: int, col: int) -> int:
	var off := 0
	for i in line:
		var nl := text.find("\n", off)
		if nl == -1:
			return text.length()
		off = nl + 1
	var eol := text.find("\n", off)
	if eol == -1:
		eol = text.length()
	return mini(off + col, eol)


# --- per-frame work ---------------------------------------------------------------------------------------------------------

func process() -> void:
	_scan_editors()
	var now := Util.now_ms()
	_sync_cursors(now)
	for path in trackers:
		var tr: STracker = trackers[path]
		if is_instance_valid(tr.code) and tr.ready:
			_flush_local(tr)
		elif _online() and not tr.ready and tr.opened_ms > 0 and now - tr.opened_ms > 4000:
			Log.warn("text", "No answer from the host for %s; asking again" % path)
			_send_open(tr)
	_flush_disk_writes(now)


func _active_script_path() -> String:
	if env != null and env.has_method("current_script_path"):
		var current := String(env.call("current_script_path"))
		if trackers.has(current):
			return current
	for path in trackers:
		var tr: STracker = trackers[path]
		if is_instance_valid(tr.code) and tr.code.has_focus():
			return path
	return ""


func _cursor_payload(tr: STracker) -> Dictionary:
	var data := {
		"line": tr.code.get_caret_line(),
		"column": tr.code.get_caret_column(),
		"selection": [],
	}
	if tr.code.has_selection():
		data["selection"] = [
			tr.code.get_selection_from_line(),
			tr.code.get_selection_from_column(),
			tr.code.get_selection_to_line(),
			tr.code.get_selection_to_column(),
		]
	return data


func _sync_cursors(now: int) -> void:
	for path in _remote_cursors.keys():
		var peers: Dictionary = _remote_cursors[path]
		for pid in peers.keys():
			if now - int(peers[pid].get("seen", 0)) > CURSOR_EXPIRE_MS:
				peers.erase(pid)
				_update_cursor_overlay(String(path))
		if peers.is_empty():
			_remote_cursors.erase(path)
	var path := _active_script_path()
	if path != _active_cursor_path:
		if not _active_cursor_path.is_empty() and _online():
			session.send({"t": "tx_cursor", "path": _active_cursor_path, "active": false})
		_active_cursor_path = path
		_last_cursor_payload = ""
	if path.is_empty() or not _online() or not trackers.has(path):
		return
	var tr: STracker = trackers[path]
	if not tr.ready or not is_instance_valid(tr.code):
		return
	var payload := _cursor_payload(tr)
	var signature := JSON.stringify(payload)
	if signature == _last_cursor_payload and now - _last_cursor_sent < CURSOR_SEND_MS:
		return
	_last_cursor_payload = signature
	_last_cursor_sent = now
	session.send({"t": "tx_cursor", "path": path, "active": true, "line": payload.line, "column": payload.column, "selection": payload.selection})


func _update_cursor_overlay(path: String) -> void:
	var tr: STracker = trackers.get(path)
	if tr == null or not is_instance_valid(tr.overlay):
		return
	var peers: Dictionary = _remote_cursors.get(path, {})
	tr.overlay.entries = peers.values()
	tr.overlay.queue_redraw()


func _on_remote_cursor(m: Dictionary) -> void:
	var path := String(m.get("path", ""))
	var pid := int(m.get("pid", 0))
	if pid == 0 or pid == int(session.my_pid) or not trackers.has(path):
		return
	var peers: Dictionary = _remote_cursors.get(path, {})
	if not bool(m.get("active", true)):
		peers.erase(pid)
	else:
		var tr: STracker = trackers[path]
		if not is_instance_valid(tr.code):
			return
		var line := clampi(int(m.get("line", 0)), 0, tr.code.get_line_count() - 1)
		var column := clampi(int(m.get("column", 0)), 0, tr.code.get_line(line).length())
		var selection: Variant = m.get("selection", [])
		if not selection is Array or selection.size() != 4:
			selection = []
		peers[pid] = {
			"pid": pid,
			"line": line,
			"column": column,
			"selection": selection,
			"name": String(m.get("name", "Teammate")),
			"color": Color.html(String(m.get("color", "66ccff"))),
			"seen": Util.now_ms(),
		}
	if peers.is_empty():
		_remote_cursors.erase(path)
	else:
		_remote_cursors[path] = peers
	_update_cursor_overlay(path)


# --- host: keep files on disk in step with documents nobody has open here ---------------------------------------------------

func _on_host_doc_changed(path: String) -> void:
	if not session.is_host or trackers.has(path):
		return
	_disk_writes[path] = Util.now_ms() + DISK_WRITE_DELAY_MS


func _flush_disk_writes(now: int) -> void:
	if _disk_writes.is_empty() or not session.is_host:
		return
	for path in _disk_writes.keys():
		if now < int(_disk_writes[path]):
			continue
		_disk_writes.erase(path)
		var doc = session.docs.texts.get(path)
		if doc == null or trackers.has(path):
			continue
		var abs_path := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path) and Util.norm_text(Util.read_text(abs_path)) == doc.text:
			continue
		var err := Util.write_text_atomic(abs_path, doc.text)
		if err == OK:
			Log.info("text", "Wrote the live text of %s to disk (%d chars)" % [path, doc.text.length()])
			env.rescan_file(path)
		else:
			Log.error("text", "Could not write %s: %s" % [path, error_string(err)])
