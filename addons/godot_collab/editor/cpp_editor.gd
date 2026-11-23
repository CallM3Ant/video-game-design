@tool
extends VBoxContainer
## A C/C++ code editor inside Godot (main-screen tab "C++"). Godot's own script editor does not
## open .cpp/.h files; this tab does, with syntax highlighting, search and saving, and it plugs into
## the same live typing sync as scripts: whatever you type is merged live with your teammates.

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")

const CPP_EXTS := ["cpp", "cc", "cxx", "c", "h", "hh", "hpp", "hxx", "inl", "ipp", "tpp"]
const EXTRA_EXTS := ["txt", "md", "json", "cfg", "py", "cs", "glsl", "cmake", "scons", "sh", "bat", "gdextension", "toml", "yml", "yaml", "xml", "ini"]
const IGNORED_DIRS := [".git", ".godot", ".import", ".vscode", ".idea", "addons/godot_collab", ".svn", "__pycache__"]
const AUTOSAVE_MS := 1500
const MAX_OPEN_BYTES := 3 * 1024 * 1024

const KEYWORDS_CONTROL := ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "try", "catch", "throw", "co_await", "co_return", "co_yield"]
const KEYWORDS := ["class", "struct", "enum", "union", "namespace", "template", "typename", "typedef", "using", "public", "private", "protected", "virtual", "override", "final",
	"static", "const", "constexpr", "consteval", "constinit", "inline", "extern", "volatile", "explicit", "friend", "operator", "new", "delete", "this", "nullptr", "true", "false",
	"sizeof", "alignof", "alignas", "decltype", "auto", "mutable", "noexcept", "static_assert", "register", "thread_local", "concept", "requires", "export", "import", "module",
	"asm", "and", "or", "not", "xor", "bitand", "bitor", "compl", "static_cast", "dynamic_cast", "const_cast", "reinterpret_cast", "NULL"]
const TYPES := ["void", "bool", "char", "char8_t", "char16_t", "char32_t", "wchar_t", "short", "int", "long", "float", "double", "signed", "unsigned", "size_t", "ssize_t",
	"int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "ptrdiff_t", "std", "string", "vector", "map", "unordered_map",
	"set", "shared_ptr", "unique_ptr", "optional", "variant", "array", "pair", "tuple", "function", "godot", "Object", "RefCounted", "Resource", "Node", "Node2D", "Node3D", "Ref",
	"Variant", "String", "StringName", "NodePath", "Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Color", "Transform2D", "Transform3D", "Basis", "Quaternion", "Array",
	"Dictionary", "PackedByteArray", "PackedFloat32Array", "PackedVector3Array", "PackedStringArray", "Callable", "Signal", "ClassDB", "UtilityFunctions", "Engine", "Input"]
const MACROS := ["GDCLASS", "GDREGISTER_CLASS", "GDREGISTER_ABSTRACT_CLASS", "GDREGISTER_VIRTUAL_CLASS", "GDREGISTER_RUNTIME_CLASS", "GDVIRTUAL", "GDVIRTUAL0", "GDVIRTUAL1",
	"BIND_METHOD", "D_METHOD", "ADD_PROPERTY", "ADD_SIGNAL", "ADD_GROUP", "BIND_ENUM_CONSTANT", "BIND_CONSTANT", "VARIANT_ENUM_CAST", "PropertyInfo", "MethodInfo", "GDEXTENSION_INIT",
	"GDExtensionBinding", "ERR_FAIL_COND", "ERR_FAIL_COND_V", "ERR_FAIL_NULL", "ERR_FAIL_V", "ERR_FAIL_INDEX", "ERR_PRINT", "WARN_PRINT", "print_line", "print_error", "memnew", "memdelete",
	"_bind_methods", "_ready", "_process", "_physics_process", "_enter_tree", "_exit_tree", "_notification", "_input", "_unhandled_input", "UNLIKELY", "LIKELY", "CRASH_COND"]

signal file_opened(res_path: String)
signal file_closed(res_path: String)

var session
var script_sync
var env
var autosave := true

var _tree: Tree
var _filter: LineEdit
var _show_all: CheckBox
var _tabs: TabBar
var _stack: Control
var _find_bar: HBoxContainer
var _find_edit: LineEdit
var _case_box: CheckBox
var _status: Label
var _sync_label: Label
var _banner: HBoxContainer
var _banner_label: Label
var _open: Dictionary = {}        # res path -> {"code": CodeEdit, "disk_mtime": int, "saved_version": int, "dirty_at": int}
var _order: Array = []            # res paths in tab order
var _tree_items: Dictionary = {}
var _last_refresh := 0
var _new_dialog: ConfirmationDialog
var _new_edit: LineEdit
var _last_disk_check := 0
var _highlighter: CodeHighlighter


func _init() -> void:
	name = "C++"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build()


func setup(p_session, p_script_sync, p_env) -> void:
	session = p_session
	script_sync = p_script_sync
	env = p_env
	script_sync.text_applied.connect(_on_text_applied)
	refresh_tree()


func teardown() -> void:
	for path in _open.keys():
		if script_sync != null:
			script_sync.detach(path)
	_open.clear()
	_order.clear()


func is_open(res_path: String) -> bool:
	return _open.has(res_path)


func open_paths() -> Array:
	return _order.duplicate()


# --- UI ------------------------------------------------------------------------------------------------

func _build() -> void:
	var bar := HBoxContainer.new()
	add_child(bar)
	var save := Button.new()
	save.text = "Save"
	save.tooltip_text = "Save the current file (Ctrl+S)"
	save.pressed.connect(save_current)
	bar.add_child(save)
	var save_all := Button.new()
	save_all.text = "Save all"
	save_all.pressed.connect(save_all_files)
	bar.add_child(save_all)
	var new_btn := Button.new()
	new_btn.text = "New file..."
	new_btn.pressed.connect(_ask_new_file)
	bar.add_child(new_btn)
	var auto := CheckBox.new()
	auto.text = "Auto-save"
	auto.button_pressed = true
	auto.tooltip_text = "Write the file to disk shortly after it changes (yours or a teammate's)."
	auto.toggled.connect(func(v: bool): autosave = v)
	bar.add_child(auto)
	_sync_label = Label.new()
	_sync_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sync_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sync_label.modulate = Color(1, 1, 1, 0.7)
	bar.add_child(_sync_label)

	_banner = HBoxContainer.new()
	_banner.visible = false
	_banner_label = Label.new()
	_banner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_banner.add_child(_banner_label)
	var reload := Button.new()
	reload.text = "Reload from disk"
	reload.pressed.connect(_reload_current)
	_banner.add_child(reload)
	var keep := Button.new()
	keep.text = "Keep mine"
	keep.pressed.connect(func(): _banner.visible = false; _remember_mtime(_current_path()))
	_banner.add_child(keep)
	add_child(_banner)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(230, 0)
	split.add_child(left)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter files..."
	_filter.clear_button_enabled = true
	_filter.text_changed.connect(func(_t): refresh_tree())
	left.add_child(_filter)
	_show_all = CheckBox.new()
	_show_all.text = "Show other text files"
	_show_all.toggled.connect(func(_v): refresh_tree())
	left.add_child(_show_all)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_tree_activated)
	left.add_child(_tree)
	var refresh := Button.new()
	refresh.text = "Refresh list"
	refresh.pressed.connect(refresh_tree)
	left.add_child(refresh)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	_tabs = TabBar.new()
	_tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	_tabs.tab_changed.connect(_on_tab_changed)
	_tabs.tab_close_pressed.connect(func(i: int): close_file(String(_order[i])))
	right.add_child(_tabs)
	_find_bar = HBoxContainer.new()
	_find_bar.visible = false
	_find_edit = LineEdit.new()
	_find_edit.placeholder_text = "Find"
	_find_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_find_edit.text_submitted.connect(func(_t): _find(true))
	_find_bar.add_child(_find_edit)
	var prev := Button.new()
	prev.text = "Prev"
	prev.pressed.connect(func(): _find(false))
	_find_bar.add_child(prev)
	var next := Button.new()
	next.text = "Next"
	next.pressed.connect(func(): _find(true))
	_find_bar.add_child(next)
	_case_box = CheckBox.new()
	_case_box.text = "Match case"
	_find_bar.add_child(_case_box)
	var close_find := Button.new()
	close_find.text = "x"
	close_find.pressed.connect(func(): _find_bar.visible = false)
	_find_bar.add_child(close_find)
	right.add_child(_find_bar)
	_stack = Control.new()
	_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stack.clip_contents = true
	right.add_child(_stack)
	_status = Label.new()
	_status.modulate = Color(1, 1, 1, 0.7)
	_status.text = "Open a C/C++ file from the list. Edits sync live with everyone in the session."
	right.add_child(_status)

	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New file"
	_new_edit = LineEdit.new()
	_new_edit.placeholder_text = "src/my_node.cpp"
	_new_dialog.add_child(_new_edit)
	_new_dialog.confirmed.connect(_create_new_file)
	add_child(_new_dialog)


# --- file list -------------------------------------------------------------------------------------------------

func _wanted_ext(ext: String) -> bool:
	ext = ext.to_lower()
	return ext in CPP_EXTS or (_show_all != null and _show_all.button_pressed and ext in EXTRA_EXTS)


func _collect(rel_dir: String, out: Array, depth: int = 0) -> void:
	if depth > 12 or out.size() > 5000:
		return
	var abs_dir := Util.rel_to_abs(rel_dir)
	for d in DirAccess.get_directories_at(abs_dir):
		var sub := rel_dir + d
		var skip := false
		for ig in IGNORED_DIRS:
			if sub == ig or sub.begins_with(ig + "/") or d == ig:
				skip = true
				break
		if not skip:
			_collect(sub + "/", out, depth + 1)
	for f in DirAccess.get_files_at(abs_dir):
		if _wanted_ext(f.get_extension()):
			out.append(rel_dir + f)


func refresh_tree() -> void:
	if _tree == null:
		return
	_last_refresh = Util.now_ms()
	_tree.clear()
	_tree_items.clear()
	var root := _tree.create_item()
	var files: Array = []
	_collect("", files)
	files.sort()
	var needle := _filter.text.strip_edges().to_lower()
	var dirs := {}
	for rel in files:
		if not needle.is_empty() and not String(rel).to_lower().contains(needle):
			continue
		var parent := root
		var dir_path := ""
		var parts := String(rel).split("/")
		for i in parts.size() - 1:
			dir_path += parts[i] + "/"
			if not dirs.has(dir_path):
				var d := _tree.create_item(parent)
				d.set_text(0, parts[i])
				d.set_selectable(0, false)
				d.collapsed = needle.is_empty() and i > 0
				dirs[dir_path] = d
			parent = dirs[dir_path]
		var item := _tree.create_item(parent)
		item.set_text(0, parts[-1])
		item.set_metadata(0, Util.rel_to_res(rel))
		item.set_tooltip_text(0, rel)
		_tree_items[Util.rel_to_res(rel)] = item
	if files.is_empty():
		var hint := _tree.create_item(root)
		hint.set_text(0, "(no C/C++ files found)")
		hint.set_selectable(0, false)


func _on_tree_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var path: Variant = item.get_metadata(0)
	if path is String:
		open_file(path)


# --- tabs and buffers ----------------------------------------------------------------------------------------

func _current_path() -> String:
	var i := _tabs.current_tab
	return String(_order[i]) if i >= 0 and i < _order.size() else ""


func current_code() -> CodeEdit:
	var p := _current_path()
	return _open[p].code if _open.has(p) else null


func open_file(res_path: String) -> void:
	if not Util.is_safe_res_path(res_path):
		return
	if _open.has(res_path):
		_tabs.current_tab = _order.find(res_path)
		return
	var abs_path := ProjectSettings.globalize_path(res_path)
	var text := ""
	if FileAccess.file_exists(abs_path):
		var bytes := FileAccess.get_file_as_bytes(abs_path)
		if bytes.size() > MAX_OPEN_BYTES:
			_status.text = "%s is too large to edit here (%s)." % [res_path.get_file(), Util.format_bytes(bytes.size())]
			return
		text = Util.norm_text(bytes.get_string_from_utf8())
	var code := _make_code_edit(res_path)
	code.text = text
	code.clear_undo_history()
	code.tag_saved_version()
	_stack.add_child(code)
	code.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_open[res_path] = {"code": code, "disk_mtime": FileAccess.get_modified_time(abs_path), "dirty_at": 0}
	_order.append(res_path)
	_tabs.add_tab(res_path.get_file())
	_tabs.set_tab_tooltip(_order.size() - 1, res_path)
	_tabs.current_tab = _order.size() - 1
	_on_tab_changed(_tabs.current_tab)
	code.text_changed.connect(_on_code_changed.bind(res_path))
	if script_sync != null:
		script_sync.attach(res_path, code)
	if session != null:
		session.set_presence(session.peers.get(session.my_pid, {}).get("scene", ""), res_path)
	Log.info("cpp", "Opened %s (%d chars)" % [res_path, text.length()])
	file_opened.emit(res_path)
	_update_tab_titles()


func close_file(res_path: String) -> void:
	if not _open.has(res_path):
		return
	var info: Dictionary = _open[res_path]
	var code: CodeEdit = info.code
	if code.get_version() != code.get_saved_version():
		_write(res_path)
	if script_sync != null:
		script_sync.detach(res_path)
	var idx := _order.find(res_path)
	_open.erase(res_path)
	_order.erase(res_path)
	code.queue_free()
	if idx >= 0:
		_tabs.remove_tab(idx)
	_on_tab_changed(_tabs.current_tab)
	Log.info("cpp", "Closed %s" % res_path)
	file_closed.emit(res_path)


func _on_tab_changed(idx: int) -> void:
	for i in _order.size():
		var c: CodeEdit = _open[_order[i]].code
		c.visible = i == idx
	_banner.visible = false
	var path := _current_path()
	if _open.has(path):
		var c2: CodeEdit = _open[path].code
		c2.grab_focus.call_deferred()
		_status.text = path
	_update_sync_label()


func _make_code_edit(res_path: String) -> CodeEdit:
	var ce := CodeEdit.new()
	ce.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ce.syntax_highlighter = _get_highlighter()
	ce.gutters_draw_line_numbers = true
	ce.gutters_zero_pad_line_numbers = false
	ce.line_folding = true
	ce.gutters_draw_fold_gutter = true
	ce.indent_use_spaces = false
	ce.indent_size = 4
	ce.auto_brace_completion_enabled = true
	ce.auto_brace_completion_highlight_matching = true
	ce.highlight_current_line = true
	ce.highlight_all_occurrences = true
	ce.draw_tabs = true
	ce.minimap_draw = true
	ce.caret_blink = true
	ce.scroll_smooth = false
	ce.delimiter_comments = ["//", "/* */"]
	ce.delimiter_strings = ["\" \"", "' '"]
	ce.code_completion_enabled = false
	ce.symbol_lookup_on_click = false
	ce.use_default_word_separators = true
	ce.gui_input.connect(_on_code_input.bind(res_path))
	_apply_editor_theme(ce)
	return ce


func _editor_color(setting: String, fallback: Color) -> Color:
	if Engine.is_editor_hint() and env != null:
		var es: Variant = EditorInterface.get_editor_settings()
		if es != null and es.has_setting(setting):
			var v: Variant = es.get_setting(setting)
			if v is Color:
				return v
	return fallback


func _apply_editor_theme(ce: CodeEdit) -> void:
	ce.add_theme_color_override("background_color", _editor_color("text_editor/theme/highlighting/background_color", Color("1f2430")))
	ce.add_theme_color_override("font_color", _editor_color("text_editor/theme/highlighting/text_color", Color("d8dee9")))
	ce.add_theme_color_override("caret_color", _editor_color("text_editor/theme/highlighting/caret_color", Color("ffffff")))
	ce.add_theme_color_override("selection_color", _editor_color("text_editor/theme/highlighting/selection_color", Color(0.3, 0.45, 0.7, 0.45)))
	ce.add_theme_color_override("current_line_color", _editor_color("text_editor/theme/highlighting/current_line_color", Color(1, 1, 1, 0.06)))
	ce.add_theme_color_override("line_number_color", _editor_color("text_editor/theme/highlighting/line_number_color", Color(1, 1, 1, 0.35)))
	ce.add_theme_color_override("word_highlighted_color", _editor_color("text_editor/theme/highlighting/word_highlighted_color", Color(1, 1, 1, 0.12)))
	ce.add_theme_color_override("brace_mismatch_color", Color("ff6b6b"))
	var font_size := 14
	if Engine.is_editor_hint() and env != null:
		var es: Variant = EditorInterface.get_editor_settings()
		if es != null and es.has_setting("interface/editor/code_font_size"):
			font_size = int(es.get_setting("interface/editor/code_font_size"))
		font_size = int(font_size * EditorInterface.get_editor_scale())
	ce.add_theme_font_size_override("font_size", font_size)


func _get_highlighter() -> CodeHighlighter:
	if _highlighter != null:
		return _highlighter
	var h := CodeHighlighter.new()
	var kw := _editor_color("text_editor/theme/highlighting/keyword_color", Color("ff7085"))
	var flow := _editor_color("text_editor/theme/highlighting/control_flow_keyword_color", Color("ff8ccc"))
	var types := _editor_color("text_editor/theme/highlighting/base_type_color", Color("42ffc2"))
	var macro := _editor_color("text_editor/theme/highlighting/user_type_color", Color("c7ffed"))
	var comment := _editor_color("text_editor/theme/highlighting/comment_color", Color(0.8, 0.81, 0.82, 0.5))
	var string_c := _editor_color("text_editor/theme/highlighting/string_color", Color("ffeda1"))
	var number := _editor_color("text_editor/theme/highlighting/number_color", Color("a1ffe0"))
	var symbol := _editor_color("text_editor/theme/highlighting/symbol_color", Color("abc9ff"))
	var func_c := _editor_color("text_editor/theme/highlighting/function_color", Color("57b3ff"))
	var pre := _editor_color("text_editor/theme/highlighting/gdscript/annotation_color", Color("ffb373"))
	h.number_color = number
	h.symbol_color = symbol
	h.function_color = func_c
	h.member_variable_color = Color(0.8, 0.85, 0.95)
	for k in KEYWORDS_CONTROL:
		h.add_keyword_color(k, flow)
	for k in KEYWORDS:
		h.add_keyword_color(k, kw)
	for k in TYPES:
		h.add_keyword_color(k, types)
	for k in MACROS:
		h.add_keyword_color(k, macro)
	h.add_color_region("//", "", comment, true)
	h.add_color_region("/*", "*/", comment, false)
	h.add_color_region("#", "", pre, true)
	h.add_color_region("\"", "\"", string_c, true)
	h.add_color_region("'", "'", string_c, true)
	_highlighter = h
	return h


# --- editing ---------------------------------------------------------------------------------------------------------

func _on_code_input(event: InputEvent, _res_path: String) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var ctrl: bool = event.ctrl_pressed or event.meta_pressed
		if ctrl and event.keycode == KEY_S:
			if event.shift_pressed:
				save_all_files()
			else:
				save_current()
			get_viewport().set_input_as_handled()
		elif ctrl and event.keycode == KEY_F:
			_find_bar.visible = true
			var code := current_code()
			if code != null and code.has_selection():
				_find_edit.text = code.get_selected_text()
			_find_edit.grab_focus()
			_find_edit.select_all()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F3:
			_find(not event.shift_pressed)
			get_viewport().set_input_as_handled()
		elif ctrl and event.keycode == KEY_SLASH:
			_toggle_comment()
			get_viewport().set_input_as_handled()


func _toggle_comment() -> void:
	var code := current_code()
	if code == null:
		return
	var from := code.get_selection_from_line() if code.has_selection() else code.get_caret_line()
	var to := code.get_selection_to_line() if code.has_selection() else from
	var all_commented := true
	for l in range(from, to + 1):
		var s := code.get_line(l).strip_edges(true, false)
		if not s.is_empty() and not s.begins_with("//"):
			all_commented = false
	code.begin_complex_operation()
	for l in range(from, to + 1):
		var line := code.get_line(l)
		if all_commented:
			var idx := line.find("//")
			if idx >= 0:
				var cut := 3 if line.substr(idx, 3) == "// " else 2
				code.set_line(l, line.substr(0, idx) + line.substr(idx + cut))
		elif not line.strip_edges().is_empty():
			code.set_line(l, "// " + line)
	code.end_complex_operation()


func _find(forward: bool) -> void:
	var code := current_code()
	var needle := _find_edit.text
	if code == null or needle.is_empty():
		return
	var flags := 0
	if _case_box.button_pressed:
		flags |= TextEdit.SEARCH_MATCH_CASE
	if not forward:
		flags |= TextEdit.SEARCH_BACKWARDS
	var line := code.get_caret_line()
	var col := code.get_caret_column()
	if code.has_selection():
		line = code.get_selection_to_line() if forward else code.get_selection_from_line()
		col = code.get_selection_to_column() if forward else code.get_selection_from_column()
	var r := code.search(needle, flags, line, col)
	if r.x < 0:
		r = code.search(needle, flags, 0 if forward else code.get_line_count() - 1, 0 if forward else code.get_line(code.get_line_count() - 1).length())
	if r.x >= 0:
		code.select(r.y, r.x, r.y, r.x + needle.length())
		code.center_viewport_to_caret()
		_status.text = "Found at line %d" % (r.y + 1)
	else:
		_status.text = "Not found: %s" % needle


func _on_code_changed(res_path: String) -> void:
	if _open.has(res_path):
		_open[res_path]["dirty_at"] = Util.now_ms()
	_update_tab_titles()


func _on_text_applied(res_path: String) -> void:
	if _open.has(res_path):
		_open[res_path]["dirty_at"] = Util.now_ms()
	_update_tab_titles()


func _update_tab_titles() -> void:
	for i in _order.size():
		var p: String = _order[i]
		var c: CodeEdit = _open[p].code
		var dirty := c.get_version() != c.get_saved_version()
		_tabs.set_tab_title(i, p.get_file() + (" *" if dirty else ""))
	_update_sync_label()


func _update_sync_label() -> void:
	if _sync_label == null:
		return
	var p := _current_path()
	if p.is_empty():
		_sync_label.text = ""
		return
	if script_sync != null and script_sync.trackers.has(p) and script_sync.trackers[p].ready:
		_sync_label.text = "● live with %d other(s)" % maxi(0, session.peers.size() - 1)
	elif session != null and session.is_online():
		_sync_label.text = "○ connecting..."
	else:
		_sync_label.text = "○ offline (syncs when you reconnect)"


func save_current() -> void:
	var p := _current_path()
	if not p.is_empty():
		_write(p)


func save_all_files() -> void:
	for p in _order:
		_write(p)


func _write(res_path: String) -> void:
	var info: Variant = _open.get(res_path)
	if info == null:
		return
	var code: CodeEdit = info.code
	var abs_path := ProjectSettings.globalize_path(res_path)
	var err := Util.write_text_atomic(abs_path, code.text)
	if err != OK:
		_status.text = "Could not save %s: %s" % [res_path.get_file(), error_string(err)]
		Log.error("cpp", "Could not save %s: %s" % [res_path, error_string(err)])
		return
	code.tag_saved_version()
	info["disk_mtime"] = FileAccess.get_modified_time(abs_path)
	info["dirty_at"] = 0
	_update_tab_titles()
	_status.text = "Saved %s" % res_path
	if env != null:
		env.rescan_file(res_path)


func _remember_mtime(res_path: String) -> void:
	if _open.has(res_path):
		_open[res_path]["disk_mtime"] = FileAccess.get_modified_time(ProjectSettings.globalize_path(res_path))


func _reload_current() -> void:
	var p := _current_path()
	if not _open.has(p):
		return
	var code: CodeEdit = _open[p].code
	var text := Util.norm_text(FileAccess.get_file_as_string(ProjectSettings.globalize_path(p)))
	code.text = text
	code.tag_saved_version()
	_remember_mtime(p)
	_banner.visible = false
	_update_tab_titles()


func _ask_new_file() -> void:
	_new_edit.text = ""
	_new_dialog.popup_centered(Vector2i(420, 110))
	_new_edit.grab_focus()


func _create_new_file() -> void:
	var rel := _new_edit.text.strip_edges().trim_prefix("res://").trim_prefix("/")
	if rel.is_empty() or not Util.is_safe_rel_path(rel):
		_status.text = "That is not a valid project path."
		return
	var abs_path := Util.rel_to_abs(rel)
	if not FileAccess.file_exists(abs_path):
		var stub := ""
		var ext := rel.get_extension().to_lower()
		if ext in ["h", "hpp", "hh", "hxx"]:
			var guard := rel.get_file().get_basename().to_upper().replace(".", "_").replace("-", "_") + "_H"
			stub = "#ifndef %s\n#define %s\n\n\n\n#endif // %s\n" % [guard, guard, guard]
		elif ext in CPP_EXTS:
			stub = "#include \"%s.h\"\n\n" % rel.get_file().get_basename()
		var err := Util.write_text_atomic(abs_path, stub)
		if err != OK:
			_status.text = "Could not create %s: %s" % [rel, error_string(err)]
			return
		Log.info("cpp", "Created %s" % rel)
	refresh_tree()
	open_file(Util.rel_to_res(rel))


# --- per-frame ---------------------------------------------------------------------------------------------------------------

func process() -> void:
	var now := Util.now_ms()
	if not visible_in_tree() and _open.is_empty():
		return
	if autosave:
		for p in _open.keys():
			var info: Dictionary = _open[p]
			var code: CodeEdit = info.code
			if code.get_version() != code.get_saved_version() and now - int(info.get("dirty_at", now)) > AUTOSAVE_MS and int(info.get("dirty_at", 0)) > 0:
				_write(p)
	if now - _last_disk_check > 1000:
		_last_disk_check = now
		_check_disk_changes()
		_update_sync_label()


func visible_in_tree() -> bool:
	return is_visible_in_tree()


## A file changed on disk behind the tab's back (VS Code, git...). With live sync on, the shared
## document is the truth, so only offline tabs are affected.
func _check_disk_changes() -> void:
	for p in _open.keys():
		var info: Dictionary = _open[p]
		var abs_path := ProjectSettings.globalize_path(p)
		var mtime := FileAccess.get_modified_time(abs_path)
		if mtime == int(info.disk_mtime) or mtime == 0:
			continue
		var code: CodeEdit = info.code
		if script_sync != null and script_sync.trackers.has(p) and script_sync.trackers[p].ready:
			info["disk_mtime"] = mtime
			continue
		var disk_text := Util.norm_text(FileAccess.get_file_as_string(abs_path))
		if disk_text == Util.norm_text(code.text):
			info["disk_mtime"] = mtime
		elif code.get_version() == code.get_saved_version():
			var line := code.get_caret_line()
			code.text = disk_text
			code.tag_saved_version()
			code.set_caret_line(mini(line, code.get_line_count() - 1))
			info["disk_mtime"] = mtime
			_status.text = "%s was changed on disk and reloaded" % p.get_file()
			Log.info("cpp", "%s changed on disk; reloaded" % p)
		elif p == _current_path():
			_banner_label.text = "%s changed on disk and you have unsaved edits." % p.get_file()
			_banner.visible = true
