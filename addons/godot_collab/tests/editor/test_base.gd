extends RefCounted
## Shared helpers for the two-editor integration test scripts (run inside real headless editors).

var P                        # the Godot Collab EditorPlugin
var shared := ""
var results := {}
var log_lines := []
var role := ""


func setup(plugin, who: String) -> void:
	P = plugin
	role = who
	shared = OS.get_environment("GODOT_COLLAB_SHARED")


func say(s: String) -> void:
	var line := "[%s %.1f] %s" % [role, Time.get_ticks_msec() / 1000.0, s]
	print(line)
	log_lines.append(line)


func check(name: String, ok: bool, detail: String = "") -> void:
	results[name] = ok
	say(("PASS " if ok else "FAIL ") + name + ("" if detail.is_empty() else " - " + detail))


func until(cond: Callable, timeout: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout * 1000)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await P.get_tree().create_timer(0.1).timeout
	return cond.call()


func wait(sec: float) -> void:
	await P.get_tree().create_timer(sec).timeout


func mark(name: String) -> void:
	var f := FileAccess.open(shared.path_join(name), FileAccess.WRITE)
	f.store_string("1")
	f.close()
	say("mark " + name)


func wait_mark(name: String, timeout: float = 90.0) -> bool:
	var ok: bool = await until(func(): return FileAccess.file_exists(shared.path_join(name)), timeout)
	if not ok:
		say("timed out waiting for " + name)
	return ok


func clear_mark(name: String) -> void:
	var p := shared.path_join(name)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func finish() -> void:
	var f := FileAccess.open(shared.path_join(role + "_results.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"results": results, "log": log_lines}, "\t"))
	f.close()
	mark(role + "_done")
	await wait(1.0)
	P.get_tree().quit()


func scene_root(path: String) -> Node:
	for r in EditorInterface.get_open_scene_roots():
		if r != null and r.scene_file_path == path:
			return r
	return null


## Edits the way the inspector does, through the editor's undo/redo.
func set_prop(obj: Object, prop: String, value: Variant) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: set " + prop)
	ur.add_do_property(obj, prop, value)
	ur.add_undo_property(obj, prop, obj.get(prop))
	ur.commit_action()


func add_node(parent: Node, node: Node, owner: Node) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: add node")
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", owner)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()


func delete_node(node: Node) -> void:
	var parent := node.get_parent()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: delete node")
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node, true)
	ur.add_undo_method(node, "set_owner", node.owner)
	ur.add_undo_reference(node)
	ur.commit_action()


func reparent_node(node: Node, new_parent: Node, scene_owner: Node) -> void:
	var old_parent := node.get_parent()
	var old_owner := node.owner
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("test: reparent node")
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", scene_owner)
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node, true)
	ur.add_undo_method(node, "set_owner", old_owner)
	ur.commit_action()


func code_edit_for(path: String) -> CodeEdit:
	for e in P.env.script_editors():
		if e.path == path:
			return e.code
	return null


func child_names(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		out.append(String(c.name))
	out.sort()
	return out


func tree_text(root: Node) -> String:
	var out := []
	for n in root.find_children("*", "", true, false):
		if n.owner == root:
			out.append("%s<%s" % [n.name, n.get_parent().name])
	out.sort()
	return ",".join(out)


func write_text(res_path: String, text: String) -> void:
	var abs_path := ProjectSettings.globalize_path(res_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read_text(res_path: String) -> String:
	var abs_path := ProjectSettings.globalize_path(res_path)
	return FileAccess.get_file_as_string(abs_path) if FileAccess.file_exists(abs_path) else "<missing>"


func write_shared(name: String, text: String) -> void:
	var f := FileAccess.open(shared.path_join(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func read_shared(name: String) -> String:
	var p := shared.path_join(name)
	return FileAccess.get_file_as_string(p) if FileAccess.file_exists(p) else "<none>"


func plan_done() -> bool:
	return P.file_sync.scan_complete and not P.file_sync.plan_running
