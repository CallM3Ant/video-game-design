extends "res://addons/godot_collab/tests/editor/test_base.gd"
## Client side of the two-editor test (see host_test.gd).

const SCENE := "res://main.tscn"
const SCRIPT := "res://player.gd"
const CPP := "res://src/native.cpp"
const Util := preload("res://addons/godot_collab/core/util.gd")


func start(plugin) -> void:
	setup(plugin, "client")
	var ok: bool = await until(func(): return P.session.joined_ok and not P.session.is_host, 60)
	check("client_connected", ok)
	if not ok:
		await finish()
		return
	var identity_settings: Dictionary = P.dock.current_settings()
	identity_settings["name"] = "Cole Builder"
	identity_settings["color"] = "33cc88"
	identity_settings["address"] = String(P.settings.get("address", "127.0.0.1"))
	identity_settings["port"] = int(P.settings.get("port", 47600))
	identity_settings["key"] = String(P.settings.get("key", ""))
	P._on_settings_changed(identity_settings)
	ok = await until(func(): return P.session.peers.get(P.session.my_pid, {}).get("name", "") == "Cole Builder" and String(P.session.peers.get(P.session.my_pid, {}).get("color", "")) == "33cc88", 10)
	check("custom_collaborator_name_and_color_apply", ok)
	await _scenes()
	await _scripts()
	await _cpp()
	await _files()
	await _offline()
	await finish()


func _scenes() -> void:
	EditorInterface.open_scene_from_path(SCENE)
	await wait(1.0)
	var main := scene_root(SCENE)
	check("client_scene_open", main != null)
	if main == null:
		return
	var ok: bool = await until(func(): return P.scene_sync.trackers.has(SCENE) and P.scene_sync.trackers[SCENE].live, 30)
	check("client_scene_live", ok)
	mark("client_scene_live")
	await wait_mark("host_scene_live")
	await wait(0.5)
	var host_camera_ready: bool = await until(func(): return P.session.peers.get(1, {}).get("view_3d", false) and String(P.session.peers.get(1, {}).get("scene", "")) == SCENE, 10)
	check("host_3d_camera_presence_arrived", host_camera_ready)
	if host_camera_ready:
		var host_camera_pose: Transform3D = P.session.peers[1].camera
		P._on_join_peer_requested(1)
		await wait(0.2)
		var editor_viewport := EditorInterface.get_editor_viewport_3d(0)
		var editor_camera := editor_viewport.get_camera_3d() if editor_viewport != null else null
		check("join_peer_jumps_to_their_scene_camera", editor_camera != null and editor_camera.global_position.distance_to(host_camera_pose.origin) < 1.0)
	var selected_block := main.get_node("Block")
	EditorInterface.get_selection().add_node(selected_block)
	P.scene_sync._sync_local_selection(Util.now_ms())
	mark("client_selected_block")
	await wait_mark("host_scene_selection_checked")
	EditorInterface.get_selection().remove_node(selected_block)
	P.scene_sync._sync_local_selection(Util.now_ms())
	mark("client_deselected_block")
	await wait_mark("host_scene_deselection_checked")

	# 1. Move a block the way the inspector does; nothing is saved.
	var block: Node3D = main.get_node("Block")
	set_prop(block, "position", Vector3(5, 6, 7))
	mark("client_moved_block")

	# 2. Receive the host's new node, rename it.
	await wait_mark("host_added_coin")
	ok = await until(func(): return main.get_node_or_null("Coin") != null, 15)
	check("remote_node_added_live", ok)
	var coin: Node = main.get_node_or_null("Coin")
	check("remote_node_has_properties", coin != null and coin.position == Vector3(4, 4, 4))
	if coin != null:
		set_prop(coin, "name", "Gem")
	mark("client_renamed_coin")
	await wait_mark("host_reparented_gem")
	ok = await until(func(): return main.get_node_or_null("Other/Gem") != null and main.get_node_or_null("Gem") == null, 15)
	check("host_reparent_arrives_live", ok)
	mark("client_reparented_gem")

	# 3. The host deletes it.
	await wait_mark("host_deleted_gem")
	ok = await until(func(): return main.get_node_or_null("Gem") == null and main.get_node_or_null("Coin") == null, 15)
	check("remote_node_deleted_live", ok, tree_text(main))

	# 4. A sub-resource (mesh) is added and then edited in place; plus a visibility change.
	var mesh: MeshInstance3D = main.get_node("Mesh")
	var box := BoxMesh.new()
	set_prop(mesh, "mesh", box)
	await wait(0.6)
	box.size = Vector3(3, 3, 3)
	set_prop(mesh, "visible", false)
	mark("client_changed_mesh")

	# 5. Concurrent edits.
	await wait_mark("host_ready_concurrent")
	mark("client_ready_concurrent")
	set_prop(block, "rotation", Vector3(0, 1, 0))
	var other: Node3D = main.get_node("Other")
	set_prop(other, "position", Vector3(8, 8, 8))
	mark("client_concurrent")
	await wait_mark("host_concurrent")
	ok = await until(func(): return block.scale == Vector3(2, 2, 2) and block.rotation.is_equal_approx(Vector3(0, 1, 0)), 15)
	check("client_sees_both_edits", ok, "scale=%s rot=%s" % [block.scale, block.rotation])
	await wait(1.5)
	write_shared("client_other_position.txt", str(other.position))
	mark("client_wrote_other_position")
	await wait_mark("host_wrote_other_position")

	# 6. The host's undo arrives as a normal edit.
	await wait_mark("host_undid")
	var undo_expected := read_shared("undo_expected_position.txt")
	ok = await until(func(): return str(other.position) == undo_expected, 15)
	check("remote_undo_arrives", ok, str(other.position))
	mark("client_saw_undo")

	# 7. After the host saved, our save produces the same structure.
	await wait_mark("host_saved_scene")
	EditorInterface.save_scene()
	await wait(0.8)
	var saved := FileAccess.get_file_as_string(ProjectSettings.globalize_path(SCENE))
	check("client_saved_scene_matches", saved.contains("Mesh") and not saved.contains("Gem") and saved.contains("BoxMesh"), str(saved.length()))
	mark("client_scene_checks_done")


func _scripts() -> void:
	await until(func(): return plan_done(), 40)
	check("client_file_plan_done", plan_done())
	check("stale_local_script_replaced_by_hosts", read_text(SCRIPT).contains("var speed") and not read_text(SCRIPT).contains("STALE"), read_text(SCRIPT).c_escape())
	EditorInterface.edit_script(load(SCRIPT))
	await wait(1.0)
	mark("client_script_open")
	await wait_mark("host_script_open")
	var code := code_edit_for(SCRIPT)
	check("client_has_code_edit", code != null)
	if code == null:
		return
	var ok: bool = await until(func(): return P.script_sync.trackers.has(SCRIPT) and P.script_sync.trackers[SCRIPT].ready, 20)
	check("client_script_live", ok)
	mark("client_script_live")
	await wait_mark("host_script_live")
	var host_cursor_ready := await wait_mark("host_cursor_selection_sent")
	if host_cursor_ready:
		# Keep a visible selection long enough for the host to verify its overlay.
		code.select(0, 0, 0, mini(5, code.get_line(0).length()))
		P.script_sync.process()
		mark("client_cursor_selection_sent")
		await wait_mark("host_cursor_selection_checked")
		code.deselect()
		P.script_sync.process()
		mark("client_cursor_selection_cleared")
		await wait_mark("host_cursor_clear_checked")
	await wait_mark("host_typed")
	ok = await until(func(): return code.text.contains("# typed by host"), 15)
	check("host_typing_arrived_live", ok)
	code.set_caret_line(code.get_line_count() - 1)
	code.set_caret_column(code.get_line(code.get_line_count() - 1).length())
	code.insert_text_at_caret("\n# typed by client")
	mark("client_typed")
	ok = await until(func(): return code.text.contains("# typed by host") and code.text.contains("# typed by client"), 15)
	check("client_sees_merged_typing", ok)
	mark("client_script_checked")
	await wait_mark("host_script_checked")


func ok_plan_placeholder() -> void:
	pass


func _cpp() -> void:
	P.cpp_editor.open_file(CPP)
	await wait(0.8)
	mark("client_cpp_open")
	await wait_mark("host_cpp_open")
	var code: CodeEdit = P.cpp_editor.current_code()
	check("client_cpp_tab_opened", code != null)
	var ok: bool = await until(func(): return P.script_sync.trackers.has(CPP) and P.script_sync.trackers[CPP].ready, 20)
	check("client_cpp_live", ok)
	mark("client_cpp_live")
	await wait_mark("host_cpp_live")
	await wait_mark("host_cpp_typed")
	ok = await until(func(): return code.text.contains("// host was here"), 15)
	check("cpp_host_typing_arrived", ok)
	code.set_caret_line(code.get_line_count() - 1)
	code.set_caret_column(code.get_line(code.get_line_count() - 1).length())
	code.insert_text_at_caret("\n// client was here")
	mark("client_cpp_typed")
	ok = await until(func(): return code.text.contains("// host was here") and code.text.contains("// client was here"), 15)
	check("cpp_merged_on_client", ok)
	await wait(2.4)
	var disk := FileAccess.get_file_as_string(ProjectSettings.globalize_path(CPP))
	check("cpp_client_autosaved", disk.contains("// host was here") and disk.contains("// client was here"))
	mark("client_cpp_checked")
	await wait_mark("host_cpp_checked")
	P.cpp_editor.close_file(CPP)


func _files() -> void:
	await wait_mark("host_wrote_files")
	var ok: bool = await until(func(): return read_text("res://assets/host_note.txt") == "from the host\n" and FileAccess.file_exists(ProjectSettings.globalize_path("res://assets/host_blob.bin")), 40)
	check("client_received_text_and_binary_files", ok)
	var h := FileAccess.get_sha256(ProjectSettings.globalize_path("res://assets/host_blob.bin"))
	var blob := PackedByteArray()
	blob.resize(300000)
	for i in blob.size():
		blob[i] = (i * 13 + 5) % 253
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(blob)
	check("binary_file_arrived_intact", h == ctx.finish().hex_encode())
	write_text("res://assets/client_note.txt", "from the client\n")
	var client_hash := FileAccess.get_sha256(ProjectSettings.globalize_path("res://assets/client_note.txt"))
	var uploaded: bool = await until(func(): return String(P.file_sync.base.get("assets/client_note.txt", "")) == client_hash, 30)
	check("client_file_acknowledged", uploaded)
	mark("client_files_done")


func _offline() -> void:
	var main := scene_root(SCENE)
	var other: Node3D = main.get_node("Other")
	var mesh: MeshInstance3D = main.get_node("Mesh")
	# Go offline (like closing the connection), make edits, and come back.
	P._on_leave_requested()
	await wait(0.8)
	check("client_is_offline", not P.session.joined_ok)
	set_prop(other, "position", Vector3(-100, 0, 0))
	set_prop(mesh, "rotation", Vector3(0, 0.5, 0))
	mark("client_offline")
	await wait_mark("host_edited_while_apart")
	P._on_join_requested("127.0.0.1", int(P.settings.get("port", 47600)), String(P.settings.get("key", "")), "Client")
	var ok: bool = await until(func(): return P.session.joined_ok and P.scene_sync.trackers[SCENE].live, 30)
	check("client_rejoined", ok)
	await wait(2.0)
	var held: Array = P.scene_sync.held_list()
	check("only_the_property_both_changed_is_held", held.size() == 1 and String(held[0].prop) == "position", str(held))
	check("held_value_kept_locally", other.position == Vector3(-100, 0, 0), str(other.position))
	check("hosts_newer_edit_arrived_on_other_property", mesh.position == Vector3(0, 7, 0), str(mesh.position))
	mark("client_back")
	if not held.is_empty():
		P.scene_sync.resolve_held(SCENE, String(held[0].key), false)
	await wait(0.8)
	check("use_theirs_adopts_host_value", other.position == Vector3(100, 0, 0), str(other.position))
	check("no_held_left", P.scene_sync.held_list().is_empty())
	mark("client_offline_checked")
	await wait_mark("host_offline_checked")
