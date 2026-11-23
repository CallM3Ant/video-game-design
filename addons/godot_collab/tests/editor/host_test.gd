extends "res://addons/godot_collab/tests/editor/test_base.gd"
## Host side of the two-editor test. The client runs client_test.gd; marks keep them in step.

const SCENE := "res://main.tscn"
const SCRIPT := "res://player.gd"
const CPP := "res://src/native.cpp"
const Util := preload("res://addons/godot_collab/core/util.gd")
var _client_pid := 0


func start(plugin) -> void:
	setup(plugin, "host")
	say("waiting for the client to join")
	var ok: bool = await until(func(): return P.session.is_host and P.session.peers.size() >= 2, 60)
	check("client_joined", ok)
	if not ok:
		await finish()
		return
	for pid in P.session.peers:
		if int(pid) != 1:
			_client_pid = int(pid)
	ok = await until(func(): return P.session.peer_name(_client_pid) == "Cole Builder" and P.session.peer_color(_client_pid).to_html(false) == "33cc88", 10)
	check("custom_collaborator_name_and_color_arrive", ok)
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
	check("host_scene_open", main != null)
	if main == null:
		return
	var ok: bool = await until(func(): return P.scene_sync.trackers.has(SCENE) and P.scene_sync.trackers[SCENE].live, 20)
	check("host_scene_live", ok)
	mark("host_scene_live")
	await wait_mark("client_scene_live")
	await wait(0.5)
	check("no_changes_on_identical_first_sync", not P.scene_sync.trackers[SCENE].unsaved_pending)
	await wait_mark("client_selected_block")
	ok = await until(func(): return P.scene_sync.remote_selections.get(SCENE, {}).has(_client_pid), 10)
	var remote_nodes: Array = P.scene_sync._remote_selected_nodes(SCENE, main)
	check("remote_scene_selection_arrived", ok and not remote_nodes.is_empty() and remote_nodes[0].node.name == "Block")
	mark("host_scene_selection_checked")
	await wait_mark("client_deselected_block")
	ok = await until(func(): return not P.scene_sync.remote_selections.get(SCENE, {}).has(_client_pid), 10)
	check("remote_scene_selection_cleared", ok)
	mark("host_scene_deselection_checked")

	# 1. The client's inspector-style edit shows up here, live (the scene is not saved).
	await wait_mark("client_moved_block")
	var block: Node3D = main.get_node("Block")
	ok = await until(func(): return block.position == Vector3(5, 6, 7), 15)
	check("remote_property_edit_live", ok, str(block.position))
	check("scene_not_saved_yet", main.scene_file_path == SCENE and EditorInterface.get_open_scenes().has(SCENE))

	# 2. Add a node with properties here; the client sees it, renames it, we see the rename.
	var coin := Node3D.new()
	coin.name = "Coin"
	coin.position = Vector3(4, 4, 4)
	add_node(main, coin, main)
	mark("host_added_coin")
	await wait_mark("client_renamed_coin")
	ok = await until(func(): return main.get_node_or_null("Gem") != null and main.get_node("Gem").position == Vector3(4, 4, 4), 15)
	check("remote_rename_keeps_properties", ok)
	var gem_to_move := main.get_node_or_null("Gem")
	if gem_to_move != null:
		reparent_node(gem_to_move, main.get_node("Other"), main)
	mark("host_reparented_gem")
	await wait_mark("client_reparented_gem")
	ok = await until(func(): return main.get_node_or_null("Other/Gem") != null and main.get_node_or_null("Gem") == null, 15)
	check("reparented_node_keeps_its_name_and_moves_live", ok)

	# 3. Delete it here; the client checks it's gone.
	var gem := main.get_node_or_null("Other/Gem")
	if gem != null:
		delete_node(gem)
	mark("host_deleted_gem")

	# 4. Sub-resources and several properties from the client.
	await wait_mark("client_changed_mesh")
	var mesh: MeshInstance3D = main.get_node("Mesh")
	ok = await until(func(): return mesh.mesh is BoxMesh and mesh.mesh.size == Vector3(3, 3, 3) and mesh.visible == false, 15)
	check("remote_subresource_and_visibility", ok, str(mesh.mesh.size if mesh.mesh is BoxMesh else mesh.mesh))

	# 5. Both edit at once: different properties of one node, and the same property of another.
	mark("host_ready_concurrent")
	await wait_mark("client_ready_concurrent")
	set_prop(block, "scale", Vector3(2, 2, 2))
	var other := main.get_node("Other") as Node3D
	var position_before_host_action := other.position
	set_prop(main.get_node("Other"), "position", Vector3(9, 9, 9))
	mark("host_concurrent")
	await wait_mark("client_concurrent")
	ok = await until(func(): return block.scale == Vector3(2, 2, 2) and block.rotation.is_equal_approx(Vector3(0, 1, 0)), 15)
	check("concurrent_different_properties_merge", ok, "scale=%s rot=%s" % [block.scale, block.rotation])
	await wait(1.5)
	write_shared("host_other_position.txt", str(other.position))
	mark("host_wrote_other_position")
	await wait_mark("client_wrote_other_position")
	check("concurrent_same_property_converges", read_shared("host_other_position.txt") == read_shared("client_other_position.txt"), read_shared("host_other_position.txt") + " vs " + read_shared("client_other_position.txt"))
	check("no_conflict_prompts_for_live_edits", P.scene_sync.held_list().is_empty())

	# 6. Our own undo reverts our own last edit, and that revert syncs like any edit.
	var undo_id := EditorInterface.get_editor_undo_redo().get_object_history_id(main)
	EditorInterface.get_editor_undo_redo().get_history_undo_redo(undo_id).undo()
	await wait(0.8)
	check("local_undo_works", other.position == position_before_host_action, str(other.position))
	write_shared("undo_expected_position.txt", str(position_before_host_action))
	mark("host_undid")
	await wait_mark("client_saw_undo")

	# 7. Saving the scene writes a valid file that matches what we see.
	EditorInterface.save_scene()
	await wait(0.8)
	var saved := FileAccess.get_file_as_string(ProjectSettings.globalize_path(SCENE))
	check("saved_scene_has_synced_nodes", saved.contains("Mesh") and not saved.contains("Gem"), str(saved.length()))
	mark("host_saved_scene")
	await wait_mark("client_scene_checks_done")


func _scripts() -> void:
	EditorInterface.edit_script(load(SCRIPT))
	await wait(1.0)
	mark("host_script_open")
	await wait_mark("client_script_open")
	var code := code_edit_for(SCRIPT)
	check("host_has_code_edit", code != null)
	if code == null:
		return
	var ok: bool = await until(func(): return P.script_sync.trackers.has(SCRIPT) and P.script_sync.trackers[SCRIPT].ready, 20)
	check("host_script_live", ok)
	mark("host_script_live")
	await wait_mark("client_script_live")
	code.select(0, 0, 0, mini(5, code.get_line(0).length()))
	P.script_sync.process()
	mark("host_cursor_selection_sent")
	await wait_mark("client_cursor_selection_sent")
	var cursor_ok: bool = await until(func(): return P.script_sync._remote_cursors.get(SCRIPT, {}).has(_client_pid), 10)
	var cursor_data: Dictionary = P.script_sync._remote_cursors.get(SCRIPT, {}).get(_client_pid, {})
	check("remote_script_selection_arrived", cursor_ok and cursor_data.get("selection", []).size() == 4)
	check("remote_script_cursor_overlay_created", P.script_sync.trackers[SCRIPT].overlay.entries.size() == 1)
	mark("host_cursor_selection_checked")
	await wait_mark("client_cursor_selection_cleared")
	cursor_ok = await until(func(): return P.script_sync._remote_cursors.get(SCRIPT, {}).get(_client_pid, {}).get("selection", []).is_empty(), 10)
	check("remote_script_selection_cleared", cursor_ok)
	mark("host_cursor_clear_checked")
	code.deselect()
	var start_text := code.text
	code.set_caret_line(code.get_line_count() - 1)
	code.set_caret_column(code.get_line(code.get_line_count() - 1).length())
	code.insert_text_at_caret("\n# typed by host")
	mark("host_typed")
	await wait_mark("client_typed")
	ok = await until(func(): return code.text.contains("# typed by host") and code.text.contains("# typed by client"), 15)
	check("typing_syncs_live_without_saving", ok, code.text.c_escape().right(120))
	check("no_stale_text_pushed", code.text.contains("var speed") and not code.text.contains("STALE"), str(start_text.length()))
	mark("host_script_checked")
	await wait_mark("client_script_checked")


func _cpp() -> void:
	P.cpp_editor.open_file(CPP)
	await wait(0.8)
	mark("host_cpp_open")
	await wait_mark("client_cpp_open")
	var code: CodeEdit = P.cpp_editor.current_code()
	check("host_cpp_tab_opened", code != null and code.text.contains("int main"))
	var ok: bool = await until(func(): return P.script_sync.trackers.has(CPP) and P.script_sync.trackers[CPP].ready, 20)
	check("host_cpp_live", ok)
	mark("host_cpp_live")
	await wait_mark("client_cpp_live")
	code.set_caret_line(0)
	code.set_caret_column(0)
	code.insert_text_at_caret("// host was here\n")
	mark("host_cpp_typed")
	await wait_mark("client_cpp_typed")
	ok = await until(func(): return code.text.contains("// host was here") and code.text.contains("// client was here"), 15)
	check("cpp_editing_syncs_live", ok, code.text.c_escape().left(100))
	await wait(2.4)
	var disk := FileAccess.get_file_as_string(ProjectSettings.globalize_path(CPP))
	check("cpp_autosaved_to_disk", disk.contains("// host was here") and disk.contains("// client was here"))
	mark("host_cpp_checked")
	await wait_mark("client_cpp_checked")


func _files() -> void:
	write_text("res://assets/host_note.txt", "from the host\n")
	var blob := PackedByteArray()
	blob.resize(300000)
	for i in blob.size():
		blob[i] = (i * 13 + 5) % 253
	var f := FileAccess.open(ProjectSettings.globalize_path("res://assets/host_blob.bin"), FileAccess.WRITE)
	f.store_buffer(blob)
	f.close()
	mark("host_wrote_files")
	var ok: bool = await until(func(): return read_text("res://assets/client_note.txt") == "from the client\n", 30)
	check("host_received_client_file", ok)
	var client_hash := FileAccess.get_sha256(ProjectSettings.globalize_path("res://assets/client_note.txt"))
	ok = await until(func(): return String(P.file_sync.base.get("assets/client_note.txt", "")) == client_hash, 30)
	check("client_file_acknowledged", ok)
	mark("host_files_done")
	await wait_mark("client_files_done")


func _offline() -> void:
	var main := scene_root(SCENE)
	var other: Node3D = main.get_node("Other")
	var mesh: MeshInstance3D = main.get_node("Mesh")
	await wait_mark("client_offline")
	# While the client is away: change Other.position (the client will change it too) and Mesh.position.
	set_prop(other, "position", Vector3(100, 0, 0))
	set_prop(mesh, "position", Vector3(0, 7, 0))
	mark("host_edited_while_apart")
	await wait_mark("client_back")
	await wait(1.5)
	var held: Array = P.scene_sync.held_list()
	check("host_unaffected_by_client_old_edit", other.position == Vector3(100, 0, 0), str(other.position))
	check("client_offline_edit_of_other_property_arrived", mesh.rotation.is_equal_approx(Vector3(0, 0.5, 0)), str(mesh.rotation))
	check("host_has_no_prompts", held.is_empty())
	mark("host_offline_checked")
	await wait_mark("client_offline_checked")
