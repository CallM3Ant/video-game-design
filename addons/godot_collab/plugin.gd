@tool
extends EditorPlugin
## Godot Collab: live LAN collaboration for scenes, scripts, C++ and project files.
## This file only wires the pieces together; the work is done in core/ and editor/.

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")
const Session := preload("res://addons/godot_collab/core/session.gd")
const FileSync := preload("res://addons/godot_collab/core/file_sync.gd")
const EditorEnv := preload("res://addons/godot_collab/editor/editor_env.gd")
const SceneSync := preload("res://addons/godot_collab/editor/scene_sync.gd")
const ScriptSync := preload("res://addons/godot_collab/editor/script_sync.gd")
const CppEditor := preload("res://addons/godot_collab/editor/cpp_editor.gd")
const Dock := preload("res://addons/godot_collab/editor/dock.gd")

var env
var session
var scene_sync
var script_sync
var file_sync
var cpp_editor
var dock
var settings := {}
var _joined_before := false
var _session_identity := ""
var _presence_at := 0
var _info_at := 0
var _overlay_at := 0
var _dock_peers_at := 0
var _rescan_due_at := 0
var _test_script: Object = null


func _enter_tree() -> void:
	Log.setup()
	settings = _load_settings()
	Log.verbose = bool(settings.get("verbose", false)) or OS.get_environment("GODOT_COLLAB_VERBOSE") == "1"
	Log.info("plugin", "Godot Collab starting in %s" % ProjectSettings.globalize_path("res://"))

	env = EditorEnv.new(self)
	session = Session.new()
	scene_sync = SceneSync.new()
	script_sync = ScriptSync.new()
	file_sync = FileSync.new()
	cpp_editor = CppEditor.new()
	dock = Dock.new()

	scene_sync.setup(session, env)
	script_sync.setup(session, env)
	file_sync.setup(session, env)
	file_sync.busy_checker = _is_busy
	file_sync.enabled = bool(settings.get("sync_files", true))
	file_sync.max_file_bytes = int(settings.get("max_mb", 128)) * 1024 * 1024
	session.docs.scene_provider = scene_sync.provide_snapshot
	session.docs.file_exists = func(path: String) -> bool: return FileAccess.file_exists(path)
	session.docs.text_provider = _provide_text

	session.message.connect(_on_session_message)
	session.joined.connect(_on_joined)
	session.link_lost.connect(_on_link_lost)
	session.state_changed.connect(_on_state_changed)
	session.peers_changed.connect(_on_peers_changed)
	session.notice.connect(_on_notice)
	scene_sync.held_changed.connect(_refresh_conflicts)
	scene_sync.remote_selection_changed.connect(func(): update_overlays())
	file_sync.conflicts_changed.connect(_refresh_conflicts)
	file_sync.files_written.connect(_on_files_written)

	dock.load_settings(settings)
	dock.host_requested.connect(_on_host_requested)
	dock.join_requested.connect(_on_join_requested)
	dock.leave_requested.connect(_on_leave_requested)
	dock.join_peer_requested.connect(_on_join_peer_requested)
	dock.scene_conflict_chosen.connect(func(scene: String, key: String, mine: bool): scene_sync.resolve_held(scene, key, mine))
	dock.file_conflict_chosen.connect(func(rel: String, choice: String): file_sync.resolve(rel, choice))
	dock.settings_changed.connect(_on_settings_changed)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	Log.add_listener(dock.append_log)

	cpp_editor.setup(session, script_sync, env)
	EditorInterface.get_editor_main_screen().add_child(cpp_editor)
	cpp_editor.visible = false

	_on_state_changed(session.state)
	_refresh_conflicts()
	set_process(true)
	call_deferred("_startup")


func _exit_tree() -> void:
	set_process(false)
	Log.info("plugin", "Godot Collab shutting down")
	Log.remove_listener(dock.append_log)
	if _test_script != null and _test_script is Node:
		_test_script.queue_free()
	scene_sync.teardown()
	script_sync.teardown()
	file_sync.teardown()
	cpp_editor.teardown()
	session.shutdown()
	if is_instance_valid(cpp_editor):
		cpp_editor.get_parent().remove_child(cpp_editor)
		cpp_editor.queue_free()
	remove_control_from_docks(dock)
	dock.queue_free()
	Log.close()


# --- main-screen C++ tab ---------------------------------------------------------------------------

func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if cpp_editor != null:
		cpp_editor.visible = visible
		if visible:
			cpp_editor.refresh_tree()


func _get_plugin_name() -> String:
	return "C++"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Script", "EditorIcons")


func _forward_canvas_draw_over_viewport(overlay: Control) -> void:
	scene_sync.draw_remote_selection_2d(overlay)


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	scene_sync.draw_remote_selection_3d(overlay)


# --- settings and startup ----------------------------------------------------------------------------

func _settings_path() -> String:
	return Util.state_dir().path_join("settings.json")


func _load_settings() -> Dictionary:
	var data: Variant = Util.read_json(_settings_path(), {})
	return data if data is Dictionary else {}


func _save_settings() -> void:
	var err := Util.write_json(_settings_path(), settings)
	if err != OK:
		Log.error("plugin", "Could not save settings: %s" % error_string(err))


func _startup() -> void:
	var launch_json := OS.get_environment("GODOT_COLLAB_LAUNCH")
	if not launch_json.is_empty():
		var launch: Variant = JSON.parse_string(launch_json)
		if launch is Dictionary:
			Log.info("plugin", "Launch request from environment: %s" % launch_json)
			if String(launch.get("mode", "")) == "host":
				_on_host_requested(int(launch.get("port", 47600)), String(launch.get("key", "test")), String(launch.get("name", "Host")))
			elif String(launch.get("mode", "")) == "join":
				_on_join_requested(String(launch.get("address", "127.0.0.1")), int(launch.get("port", 47600)), String(launch.get("key", "test")), String(launch.get("name", "Guest")))
	elif bool(settings.get("auto_join", false)) and not String(settings.get("address", "")).is_empty():
		Log.info("plugin", "Re-joining the last host %s:%d" % [settings.address, int(settings.get("port", 47600))])
		_on_join_requested(String(settings.address), int(settings.get("port", 47600)), String(settings.get("key", "")), String(settings.get("name", "Player")))
	var test_path := OS.get_environment("GODOT_COLLAB_TEST")
	if not test_path.is_empty():
		var script: Variant = load(test_path)
		if script is GDScript:
			_test_script = script.new()
			Log.info("plugin", "Running test script %s" % test_path)
			_test_script.start(self)


func _on_settings_changed(s: Dictionary) -> void:
	for k in s:
		settings[k] = s[k]
	Log.verbose = bool(settings.get("verbose", false))
	file_sync.enabled = bool(settings.get("sync_files", true))
	file_sync.max_file_bytes = int(settings.get("max_mb", 128)) * 1024 * 1024
	session.update_identity(String(settings.get("name", "Player")), String(settings.get("color", "4dabf7")))
	_save_settings()


# --- connecting ------------------------------------------------------------------------------------------

func _on_host_requested(port: int, key: String, display_name: String) -> void:
	if key.is_empty():
		key = Util.random_hex(3)
		dock.load_settings(dock.current_settings().merged({"key": key}, true))
		Log.info("plugin", "No project code entered: generated '%s'" % key)
	if display_name.is_empty():
		display_name = "Host"
	settings["key"] = key
	settings["port"] = port
	settings["name"] = display_name
	settings["auto_join"] = false
	_save_settings()
	_use_identity("host:%d:%s" % [port, key])
	session.start_host(port, key, display_name, String(settings.get("color", "4dabf7")))


func _on_join_requested(address: String, port: int, key: String, display_name: String) -> void:
	if address.is_empty():
		address = "127.0.0.1"
	if display_name.is_empty():
		display_name = "Player"
	settings["address"] = address
	settings["port"] = port
	settings["key"] = key
	settings["name"] = display_name
	settings["auto_join"] = true
	_save_settings()
	_use_identity("join:%s:%d:%s" % [address, port, key])
	session.join(address, port, key, display_name, String(settings.get("color", "4dabf7")))


## Rejoining the same session keeps the open documents so old edits are merged, not replaced.
func _use_identity(identity: String) -> void:
	if _joined_before and identity != _session_identity:
		_reset_for_new_session()
	_session_identity = identity


func _on_leave_requested() -> void:
	settings["auto_join"] = false
	_save_settings()
	session.leave()
	if _joined_before:
		_on_link_lost("you disconnected")


func _reset_for_new_session() -> void:
	_joined_before = false
	scene_sync.trackers.clear()
	script_sync.reset_session_trackers()


func _on_joined() -> void:
	if _joined_before:
		Log.info("plugin", "Reconnected: resuming live documents")
		scene_sync.session_resumed()
		script_sync.session_resumed()
		file_sync.session_resumed()
	else:
		_joined_before = true
		scene_sync.session_started()
		script_sync.session_started()
		file_sync.session_started()


func _on_link_lost(_reason: String) -> void:
	scene_sync.session_lost()
	script_sync.session_lost()
	file_sync.session_lost()


func _on_state_changed(state: String) -> void:
	var detail := ""
	if state == "hosting":
		detail = "port %d" % int(settings.get("port", 47600))
	elif state == "online":
		detail = "joined %s" % session.host_name
	elif state == "offline" and not session.last_reject.is_empty():
		detail = session.last_reject
	dock.set_state(state, detail)


func _on_peers_changed() -> void:
	var now := Util.now_ms()
	if _dock_peers_at == 0 or now - _dock_peers_at > 500:
		_dock_peers_at = now
		dock.set_peers(session.peers, session.my_pid)
	update_overlays()


func _on_join_peer_requested(pid: int) -> void:
	var peer: Dictionary = session.peers.get(pid, {})
	if peer.is_empty():
		return
	var script_path := String(peer.get("script", ""))
	if not script_path.is_empty():
		var script: Resource = load(script_path)
		if script is Script:
			var cursor: Dictionary = script_sync._remote_cursors.get(script_path, {}).get(pid, {})
			EditorInterface.edit_script(script, int(cursor.get("line", 0)), int(cursor.get("column", 0)), true)
			return
	var scene_path := String(peer.get("scene", ""))
	if not scene_path.is_empty():
		call_deferred("_jump_to_peer_scene", pid, scene_path)


func _jump_to_peer_scene(pid: int, scene_path: String) -> void:
	if not EditorInterface.get_open_scenes().has(scene_path):
		EditorInterface.open_scene_from_path(scene_path)
		await get_tree().process_frame
		await get_tree().create_timer(0.2).timeout
	var peer: Dictionary = session.peers.get(pid, {})
	if peer.is_empty() or not bool(peer.get("view_3d", false)) or not peer.get("camera") is Transform3D:
		return
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	var camera := viewport.get_camera_3d() if viewport != null else null
	if camera != null:
		camera.global_transform = peer.camera


func _on_notice(text: String, severity: int) -> void:
	if severity >= 1:
		env.toast(text, severity)


func _on_session_message(m: Dictionary) -> void:
	var t := String(m.get("t", ""))
	if t.begins_with("sc_"):
		scene_sync.on_message(m)
	elif t.begins_with("tx_"):
		script_sync.on_message(m)
	elif t.begins_with("file_"):
		file_sync.on_message(m)


func _is_busy(res_path: String) -> bool:
	if script_sync.is_open(res_path) or cpp_editor.is_open(res_path):
		return true
	if scene_sync.trackers.has(res_path):
		return true
	return env.open_scene_paths().has(res_path)


func _provide_text(res_path: String) -> Variant:
	if not FileAccess.file_exists(res_path):
		return null
	return Util.norm_text(FileAccess.get_file_as_string(res_path))


func _on_files_written(_paths: Array) -> void:
	_rescan_due_at = Util.now_ms() + 400


func _refresh_conflicts() -> void:
	var items: Array = scene_sync.held_list()
	items.append_array(file_sync.held_list())
	dock.set_conflicts(items)


# --- per frame ----------------------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	session.poll()
	scene_sync.process()
	script_sync.process()
	file_sync.process()
	cpp_editor.process()
	var now := Util.now_ms()
	if _rescan_due_at > 0 and now >= _rescan_due_at:
		_rescan_due_at = 0
		env.rescan_project()
	if now - _presence_at > 120 and session.is_online():
		_presence_at = now
		var root: Node = env.edited_root()
		var scene_path: String = root.scene_file_path if root != null else ""
		var script_path := ""
		var se := EditorInterface.get_script_editor()
		var cur := se.get_current_script() if se != null else null
		if cur != null:
			script_path = cur.resource_path
		var camera_transform := Transform3D.IDENTITY
		var view_3d := false
		if root is Node3D:
			var viewport := EditorInterface.get_editor_viewport_3d(0)
			var camera := viewport.get_camera_3d() if viewport != null else null
			if camera != null:
				camera_transform = camera.global_transform
				view_3d = true
		session.set_presence(scene_path, script_path, camera_transform, view_3d)
	if now - _info_at > 1000:
		_info_at = now
		dock.set_info("%s\n%s\nfiles: %d known, %d held" % [scene_sync.status_text(), script_sync.status_text(), file_sync.base.size(), file_sync.conflicts.size()])
	if scene_sync.has_remote_selections() and now - _overlay_at > 120:
		_overlay_at = now
		update_overlays()
