extends SceneTree

const Session := preload("res://addons/godot_collab/core/session.gd")
const ScriptSync := preload("res://addons/godot_collab/editor/script_sync.gd")
const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")

const PORT := 47933
const SCRIPT := "res://addons/godot_collab/tests/_doc.gd"
const NEWFILE := "res://addons/godot_collab/tests/_doc_new.gd"

var _failed := 0
var _checks := 0
var _peers: Array = []
var _tmp_state := ""


class TextEnv:
	extends RefCounted
	var editors: Array = []
	var rescans: Array = []
	var current_path := ""

	func script_editors() -> Array:
		return editors

	func rescan_file(p: String) -> void:
		rescans.append(p)

	func current_script_path() -> String:
		return current_path


class Peer:
	extends RefCounted
	var name := ""
	var session
	var sync
	var env
	var codes := {}
	var joined_before := false


func _initialize() -> void:
	Log.console = false
	call_deferred("_run")


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("FAIL: " + msg)


func _pump(cond: Callable, timeout_s: float = 5.0) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end:
		_tick()
		if cond.call():
			return true
		await create_timer(0.01).timeout
	_tick()
	return cond.call()


func _tick() -> void:
	for p in _peers:
		p.session.poll()
		p.sync.process()


func _settle(ms: int = 200) -> void:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		_tick()
		await create_timer(0.01).timeout


func _make_peer(peer_name: String, is_host: bool) -> Peer:
	var p := Peer.new()
	p.name = peer_name
	p.session = Session.new()
	p.env = TextEnv.new()
	p.sync = ScriptSync.new()
	p.sync.blocked_prefixes = ["res://.godot/"]
	p.sync.setup(p.session, p.env)
	p.session.message.connect(p.sync.on_message)
	p.session.joined.connect(func():
		if p.joined_before:
			p.sync.session_resumed()
		else:
			p.joined_before = true
			p.sync.session_started())
	p.session.link_lost.connect(func(_r): p.sync.session_lost())
	if is_host:
		p.session.docs.text_provider = func(path: String) -> Variant:
			var abs := ProjectSettings.globalize_path(path)
			if FileAccess.file_exists(abs):
				return FileAccess.get_file_as_string(abs)
			return null
	_peers.append(p)
	return p


func _open_tab(p: Peer, path: String, text: String) -> CodeEdit:
	var code := CodeEdit.new()
	code.text = text
	p.codes[path] = code
	p.env.editors.append({"path": path, "code": code})
	return code


func _type(code: CodeEdit, line: int, col: int, s: String) -> void:
	code.set_caret_line(line)
	code.set_caret_column(col)
	code.insert_text_at_caret(s)


func _connect(p: Peer) -> void:
	p.session.join("127.0.0.1", PORT, "k", p.name)
	await _pump(func(): return p.session.joined_ok)


func _run() -> void:
	if OS.get_environment("GODOT_COLLAB_RESET_ONLY") == "1":
		_scenario_session_tracker_reset()
		quit(1 if _failed > 0 else 0)
		return
	_tmp_state = ProjectSettings.globalize_path("res://").path_join(".godot").path_join("collab_test_state")
	Util.state_dir_override = _tmp_state
	_scenario_session_tracker_reset()
	var abs := ProjectSettings.globalize_path(SCRIPT)
	var f := FileAccess.open(abs, FileAccess.WRITE)
	f.store_string("extends Node\n\nfunc a():\n\tpass\n\nfunc b():\n\tpass\n")
	f.close()
	await _scenario_live_typing()
	await _scenario_offline_typing()
	await _scenario_host_disk()
	await _scenario_first_sync_and_new_file()
	for p in _peers:
		p.sync.teardown()
		p.session.shutdown()
		for c in p.codes.values():
			c.free()
	for path in [SCRIPT, NEWFILE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if DirAccess.dir_exists_absolute(_tmp_state):
		_remove_dir(_tmp_state)
	if _failed > 0:
		printerr("script sync tests failed: %d of %d" % [_failed, _checks])
		quit(1)
	else:
		print("script sync tests passed (%d checks)." % _checks)
		quit()


func _remove_dir(path: String) -> void:
	for fl in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(fl))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)


func _scenario_session_tracker_reset() -> void:
	var p := _make_peer("Reset", false)
	var code := _open_tab(p, SCRIPT, "extends Node\n")
	p.sync._start(SCRIPT, code, false)
	var old_cb: Callable = p.sync.trackers[SCRIPT].cb_text
	_expect(code.text_changed.is_connected(old_cb), "live script tracker connects its edit callback")
	p.sync.reset_session_trackers()
	_expect(not p.sync.trackers.has(SCRIPT) and not code.text_changed.is_connected(old_cb), "switching sessions disconnects the old live-edit callback")
	p.sync._start(SCRIPT, code, false)
	var new_cb: Callable = p.sync.trackers[SCRIPT].cb_text
	var new_callback_count := 0
	for connection in code.text_changed.get_connections():
		if connection.get("callable") == new_cb:
			new_callback_count += 1
	_expect(code.text_changed.is_connected(new_cb) and new_callback_count == 1, "reopening the same editor tab installs exactly one callback")
	p.sync.teardown()
	p.session.shutdown()
	code.free()
	_peers.erase(p)


func _scenario_live_typing() -> void:
	var host := _make_peer("Hana", true)
	host.session.start_host(PORT, "k", "Hana")
	host.sync.session_started()
	host.joined_before = true
	var cole := _make_peer("Cole", false)
	var dana := _make_peer("Dana", false)
	await _connect(cole)
	await _connect(dana)
	var disk_text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(SCRIPT))
	var ca := _open_tab(cole, SCRIPT, disk_text)
	var cb := _open_tab(dana, SCRIPT, disk_text)
	var ok: bool = await _pump(func(): return cole.sync.trackers.has(SCRIPT) and cole.sync.trackers[SCRIPT].ready and dana.sync.trackers[SCRIPT].ready)
	_expect(ok, "both tabs become live")
	_expect(ca.text == disk_text and cb.text == disk_text, "identical text needs no change")
	cole.env.current_path = SCRIPT
	dana.env.current_path = SCRIPT
	ca.select(2, 1, 2, 4)
	ok = await _pump(func():
		var peer_cursors: Dictionary = dana.sync._remote_cursors.get(SCRIPT, {})
		return peer_cursors.has(cole.session.my_pid))
	var cursor_data: Dictionary = dana.sync._remote_cursors.get(SCRIPT, {}).get(cole.session.my_pid, {})
	_expect(ok and cursor_data.get("selection", []) == [2, 1, 2, 4], "a teammate's script caret and selection arrive with the live cursor")
	_expect(dana.sync.trackers[SCRIPT].overlay.entries.size() == 1, "the remote cursor is shown in the matching script editor")
	ca.deselect()
	# Typing shows up live, before any save.
	_type(ca, 0, 12, " # cole")
	ok = await _pump(func(): return cb.text.contains("# cole"))
	_expect(ok, "typing in one tab appears in the other without saving")
	# The reader's caret is not disturbed by a remote edit above it.
	cb.set_caret_line(6)
	cb.set_caret_column(5)
	var caret_text := cb.get_line(6)
	_type(ca, 1, 0, "# new comment line\n")
	ok = await _pump(func(): return cb.text.contains("# new comment line"))
	_expect(ok and cb.get_caret_line() == 7 and cb.get_line(cb.get_caret_line()) == caret_text and cb.get_caret_column() == 5, "remote edit above keeps the caret on the same text: line %d col %d" % [cb.get_caret_line(), cb.get_caret_column()])
	# Concurrent typing in the same spot and different spots converges.
	_type(ca, 3, 0, "\t# A1\n")
	_type(cb, 3, 0, "\t# B1\n")
	_type(ca, 8, 5, "AAA")
	_type(cb, 8, 5, "BBB")
	ok = await _pump(func(): return ca.text == cb.text and ca.text.contains("A1") and ca.text.contains("B1") and not cole.sync.trackers[SCRIPT].client.has_pending() and not dana.sync.trackers[SCRIPT].client.has_pending())
	_expect(ok, "concurrent typing converges: " + ca.text.c_escape())
	_expect(ca.text.contains("AAA") and ca.text.contains("BBB"), "no keystroke lost")
	# Deleting works too.
	ca.select(0, 0, 0, 12)
	ca.delete_selection()
	ok = await _pump(func(): return ca.text == cb.text)
	_expect(ok and not cb.text.begins_with("extends Node"), "deletions sync")
	# A third reader joining late gets the current text.
	var late_code := CodeEdit.new()
	late_code.text = disk_text
	cole.codes["late"] = late_code
	# Host's doc must equal the editors.
	var doc = host.session.docs.texts[SCRIPT]
	_expect(doc.text == ca.text, "the host's document equals what the editors show")
	await _settle(300)
	var sent: int = cole.sync._ops_sent + dana.sync._ops_sent
	await _settle(300)
	_expect(cole.sync._ops_sent + dana.sync._ops_sent == sent, "no echo once everybody agrees")


func _scenario_offline_typing() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	var dana: Peer = _peers[2]
	var ca: CodeEdit = cole.codes[SCRIPT]
	var cb: CodeEdit = dana.codes[SCRIPT]
	cole.session.leave()
	await _settle(100)
	cole.sync.session_lost()
	# While Cole is away: Cole types at the top, Dana types at the bottom.
	_type(ca, 0, 0, "# offline note from cole\n")
	_type(cb, cb.get_line_count() - 1, 0, "# dana wrote this while cole was away\n")
	await _settle(200)
	_expect(not cb.text.contains("offline note"), "offline typing stays local while apart")
	await _connect(cole)
	var ok: bool = await _pump(func(): return ca.text == cb.text and ca.text.contains("offline note") and ca.text.contains("dana wrote this"))
	_expect(ok, "offline typing and the host's newer text merge on reconnect: " + ca.text.c_escape())
	var doc = host.session.docs.texts[SCRIPT]
	_expect(doc.text == ca.text, "document equals the merged text")


func _scenario_host_disk() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	var ca: CodeEdit = cole.codes[SCRIPT]
	# Nobody has a tab open on the host, so the host writes the live text to its own disk.
	_type(ca, 0, 0, "# written through to the host's disk\n")
	var abs := ProjectSettings.globalize_path(SCRIPT)
	var ok: bool = await _pump(func(): return FileAccess.get_file_as_string(abs).contains("written through to the host's disk"), 4.0)
	_expect(ok, "the host persists live text for files it has no tab for")
	_expect(host.env.rescans.has(SCRIPT), "the host tells the editor to refresh the file")


func _scenario_first_sync_and_new_file() -> void:
	var host: Peer = _peers[0]
	var eve := _make_peer("Eve", false)
	await _connect(eve)
	# Eve opens a tab whose unsaved buffer differs from both the disk and the host.
	var abs := ProjectSettings.globalize_path(SCRIPT)
	var host_text: String = host.session.docs.texts[SCRIPT].text
	var eve_code := _open_tab(eve, SCRIPT, "extends Node\n# eve's unsaved work\n")
	var ok: bool = await _pump(func(): return eve.sync.trackers.has(SCRIPT) and eve.sync.trackers[SCRIPT].ready and eve_code.text == host_text)
	_expect(ok, "the host's text wins on the first sync of a tab")
	var found := false
	var backups := _tmp_state.path_join("backups")
	if DirAccess.dir_exists_absolute(backups):
		for stamp in DirAccess.get_directories_at(backups):
			var dir := backups.path_join(stamp).path_join("addons/godot_collab/tests")
			if DirAccess.dir_exists_absolute(dir):
				for fl in DirAccess.get_files_at(dir):
					if fl.begins_with("_doc.gd.buffer") and FileAccess.get_file_as_string(dir.path_join(fl)).contains("eve's unsaved work"):
						found = true
	_expect(found, "Eve's unsaved buffer was backed up before being replaced")
	# A brand-new file typed in an editor becomes a document on the host.
	var new_code := _open_tab(eve, NEWFILE, "extends Node\n# brand new\n")
	await _pump(func(): return eve.sync.trackers.has(NEWFILE) and eve.sync.trackers[NEWFILE].ready)
	await _settle(300)
	var ndoc = host.session.docs.texts.get(NEWFILE)
	_expect(ndoc != null and ndoc.text == "extends Node\n# brand new\n", "a new file is shared as a new document")
	_type(new_code, 1, 0, "# more\n")
	ok = await _pump(func(): return FileAccess.file_exists(ProjectSettings.globalize_path(NEWFILE)) and FileAccess.get_file_as_string(ProjectSettings.globalize_path(NEWFILE)).contains("# more"), 4.0)
	_expect(ok, "the host writes the new file to disk")
