@tool
extends RefCounted
## What the editor modules need from Godot's editor, in one place. Tests substitute a fake with the
## same methods, so the sync code can be exercised without a running editor.

var plugin: EditorPlugin
var _hooked := false
var _editor_paths := {}


func _init(p_plugin: EditorPlugin = null) -> void:
	plugin = p_plugin


func tree() -> SceneTree:
	return plugin.get_tree()


func undo_redo() -> Object:
	return EditorInterface.get_editor_undo_redo()


func open_roots() -> Array:
	return EditorInterface.get_open_scene_roots()


func edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func selected_nodes() -> Array:
	return EditorInterface.get_selection().get_selected_nodes()


func deselect(node: Node) -> void:
	EditorInterface.get_selection().remove_node(node)


func inspected() -> Object:
	return EditorInterface.get_inspector().get_edited_object()


func inspect(obj: Object) -> void:
	EditorInterface.inspect_object(obj)


func mark_unsaved() -> void:
	EditorInterface.mark_scene_as_unsaved()


func is_dragging() -> bool:
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func toast(text: String, severity: int = 0) -> void:
	var toaster := EditorInterface.get_editor_toaster()
	if toaster != null:
		toaster.push_toast(text, severity)


## Open script tabs that are plain text editors: [{"path": res://..., "code": CodeEdit}, ...].
## Godot does not tell a script tab which file it shows, so tabs are paired with the open scripts by
## position (both lists use tab order), falling back to what we learned when a tab became current.
func script_editors() -> Array:
	_hook_script_editor()
	var se := EditorInterface.get_script_editor()
	var tabs: Array = []
	for ed in se.get_open_script_editors():
		if ed != null and ed.get_class() == "ScriptTextEditor":
			tabs.append(ed)
	var scripts := se.get_open_scripts()
	var positional := tabs.size() == scripts.size()
	var out := []
	for i in tabs.size():
		var ed: Object = tabs[i]
		var path := ""
		if positional and scripts[i] != null:
			path = String(scripts[i].resource_path)
		if path.is_empty():
			path = String(_editor_paths.get(ed.get_instance_id(), ""))
		var base: Variant = ed.get_base_editor()
		if path.begins_with("res://") and base is CodeEdit:
			out.append({"path": path, "code": base})
	return out


func current_script_path() -> String:
	var se := EditorInterface.get_script_editor()
	var script: Script = se.get_current_script() if se != null else null
	return String(script.resource_path) if script != null else ""


func _hook_script_editor() -> void:
	if _hooked:
		return
	_hooked = true
	EditorInterface.get_script_editor().editor_script_changed.connect(_on_editor_script_changed)


func _on_editor_script_changed(script: Script) -> void:
	var ed: Object = EditorInterface.get_script_editor().get_current_editor()
	if script != null and ed != null:
		_editor_paths[ed.get_instance_id()] = String(script.resource_path)


func rescan_file(res_path: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and not fs.is_scanning():
		fs.update_file(res_path)


func open_scene_paths() -> PackedStringArray:
	return EditorInterface.get_open_scenes()


func rescan_project() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and not fs.is_scanning():
		fs.scan()
