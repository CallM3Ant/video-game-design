@tool
extends VBoxContainer
## The Collab dock: connect/host, see who is here, decide held conflicts, and read the live log.

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")

signal host_requested(port: int, key: String, display_name: String)
signal join_requested(address: String, port: int, key: String, display_name: String)
signal leave_requested()
signal scene_conflict_chosen(scene_path: String, key: String, use_mine: bool)
signal file_conflict_chosen(rel: String, choice: String)
signal settings_changed(settings: Dictionary)
signal join_peer_requested(pid: int)

const LEVEL_COLORS := ["#8a8f98", "#d8dee9", "#ffcc66", "#ff6b6b"]

var _status: Label
var _state_dot: ColorRect
var _name: LineEdit
var _peer_color: ColorPickerButton
var _key: LineEdit
var _port: SpinBox
var _address: LineEdit
var _host_btn: Button
var _join_btn: Button
var _leave_btn: Button
var _lan_hint: Label
var _peers: VBoxContainer
var _peer_search: LineEdit
var _last_peers: Dictionary = {}
var _last_my_pid := 0
var _tabs: TabContainer
var _conflict_box: VBoxContainer
var _conflict_tab_index := 1
var _log_view: RichTextLabel
var _log_lines := 0
var _sync_files: CheckBox
var _verbose: CheckBox
var _max_mb: SpinBox
var _invite_button: Button
var _lan_addresses: Array[String] = []
var _loading := false
var _info: Label


func _init() -> void:
	name = "Collab"
	custom_minimum_size = Vector2(300, 360)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()


func _build() -> void:
	var head := HBoxContainer.new()
	add_child(head)
	_state_dot = ColorRect.new()
	_state_dot.custom_minimum_size = Vector2(12, 12)
	_state_dot.color = Color("8a8f98")
	var dot_box := CenterContainer.new()
	dot_box.add_child(_state_dot)
	head.add_child(dot_box)
	_status = Label.new()
	_status.text = "Offline"
	_status.clip_text = true
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_status)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tabs)
	_tabs.add_child(_build_session_tab())
	_tabs.add_child(_build_conflicts_tab())
	_tabs.add_child(_build_log_tab())
	_tabs.set_tab_title(0, "Session")
	_tabs.set_tab_title(1, "Conflicts")
	_tabs.set_tab_title(2, "Log")


func _row(label_text: String, control: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(70, 0)
	r.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(control)
	return r


func _build_session_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "Session"
	var scroll := ScrollContainer.new()
	scroll.name = "Session"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(box)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name = LineEdit.new()
	_name.placeholder_text = "Your name"
	_name.text_submitted.connect(func(_t): _emit_settings())
	_name.focus_exited.connect(_emit_settings)
	box.add_child(_row("Name", _name))
	_peer_color = ColorPickerButton.new()
	_peer_color.color = Color("4dabf7")
	_peer_color.tooltip_text = "Your color for script cursors, selections, and scene camera markers"
	_peer_color.color_changed.connect(func(_c): _emit_settings())
	box.add_child(_row("Color", _peer_color))
	_key = LineEdit.new()
	_key.placeholder_text = "Shared project code"
	_key.secret = false
	_key.focus_exited.connect(_emit_settings)
	box.add_child(_row("Code", _key))
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = 47600
	_port.value_changed.connect(func(_v): _emit_settings())
	box.add_child(_row("Port", _port))
	_host_btn = Button.new()
	_host_btn.text = "Host this project"
	_host_btn.tooltip_text = "Others join you. You are the reference copy: your files win on a first join."
	_host_btn.pressed.connect(func(): host_requested.emit(int(_port.value), _key.text.strip_edges(), _name.text.strip_edges()))
	box.add_child(_host_btn)
	_lan_hint = Label.new()
	_lan_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lan_hint.add_theme_font_size_override("font_size", 11)
	_lan_hint.modulate = Color(1, 1, 1, 0.65)
	box.add_child(_lan_hint)
	box.add_child(HSeparator.new())
	_address = LineEdit.new()
	_address.placeholder_text = "Host address (e.g. 192.168.1.20 or 127.0.0.1)"
	_address.focus_exited.connect(_emit_settings)
	box.add_child(_row("Host", _address))
	_join_btn = Button.new()
	_join_btn.text = "Join"
	_join_btn.pressed.connect(func(): join_requested.emit(_address.text.strip_edges(), int(_port.value), _key.text.strip_edges(), _name.text.strip_edges()))
	box.add_child(_join_btn)
	_leave_btn = Button.new()
	_leave_btn.text = "Disconnect"
	_leave_btn.disabled = true
	_leave_btn.pressed.connect(func(): leave_requested.emit())
	box.add_child(_leave_btn)
	box.add_child(HSeparator.new())
	var peers_title := Label.new()
	peers_title.text = "People in this session"
	box.add_child(peers_title)
	_peer_search = LineEdit.new()
	_peer_search.placeholder_text = "Find a teammate"
	_peer_search.text_changed.connect(func(_text): set_peers(_last_peers, _last_my_pid))
	box.add_child(_peer_search)
	_peers = VBoxContainer.new()
	_peers.custom_minimum_size = Vector2(0, 50)
	box.add_child(_peers)
	box.add_child(HSeparator.new())
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", 11)
	_info.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_info)
	_sync_files = CheckBox.new()
	_sync_files.text = "Sync project files (assets, add-ons, folders)"
	_sync_files.tooltip_text = "Sends saved project files and empty folders outside addons/ to everyone. Godot caches, exported builds, native libraries, and addons/ are skipped."
	_sync_files.button_pressed = true
	_sync_files.toggled.connect(func(_v): _emit_settings())
	box.add_child(_sync_files)
	_verbose = CheckBox.new()
	_verbose.text = "Verbose log (every operation)"
	_verbose.toggled.connect(func(_v): _emit_settings())
	box.add_child(_verbose)
	_max_mb = SpinBox.new()
	_max_mb.min_value = 1
	_max_mb.max_value = 4096
	_max_mb.value = 128
	_max_mb.suffix = "MB max file"
	_max_mb.value_changed.connect(func(_v): _emit_settings())
	box.add_child(_max_mb)
	var copy_invite := Button.new()
	copy_invite.text = "Copy LAN invite details"
	copy_invite.tooltip_text = "Copies the host address, port, and project code so a friend can paste them into Join."
	copy_invite.pressed.connect(_copy_invite_details)
	box.add_child(copy_invite)
	_invite_button = copy_invite
	_refresh_lan_hint()
	return scroll


func _build_conflicts_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "Conflicts"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_conflict_box = VBoxContainer.new()
	_conflict_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_conflict_box)
	return scroll


func _build_log_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "Log"
	var bar := HBoxContainer.new()
	var copy := Button.new()
	copy.text = "Copy"
	copy.tooltip_text = "Copy the recent log to the clipboard (paste it when reporting a problem)"
	copy.pressed.connect(func(): DisplayServer.clipboard_set(Log.recent_text(600)))
	bar.add_child(copy)
	var open := Button.new()
	open.text = "Open file"
	open.tooltip_text = "Show collab.log in your file manager"
	open.pressed.connect(func(): OS.shell_show_in_file_manager(Log.path()))
	bar.add_child(open)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(_clear_log_view)
	bar.add_child(clear)
	box.add_child(bar)
	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.selection_enabled = true
	_log_view.context_menu_enabled = true
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_view.custom_minimum_size = Vector2(0, 180)
	box.add_child(_log_view)
	for line in Log.lines.slice(maxi(0, Log.lines.size() - 200)):
		_append_line(line, 1)
	return box


# --- public API ----------------------------------------------------------------------------------------------

func load_settings(s: Dictionary) -> void:
	_loading = true
	_name.text = String(s.get("name", OS.get_environment("USERNAME") if OS.has_environment("USERNAME") else "Player"))
	_peer_color.color = Color.html(String(s.get("color", "4dabf7")))
	_key.text = String(s.get("key", ""))
	_port.value = int(s.get("port", 47600))
	_address.text = String(s.get("address", ""))
	_sync_files.button_pressed = bool(s.get("sync_files", true))
	_verbose.button_pressed = bool(s.get("verbose", false))
	_max_mb.value = int(s.get("max_mb", 128))
	_loading = false


func current_settings() -> Dictionary:
	return {
		"name": _name.text.strip_edges(), "color": _peer_color.color.to_html(false), "key": _key.text.strip_edges(), "port": int(_port.value),
		"address": _address.text.strip_edges(), "sync_files": _sync_files.button_pressed,
		"verbose": _verbose.button_pressed, "max_mb": int(_max_mb.value),
	}


func _emit_settings() -> void:
	if not _loading:
		settings_changed.emit(current_settings())


func set_state(state: String, detail: String = "") -> void:
	var colors := {"offline": "8a8f98", "connecting": "fcc419", "reconnecting": "ff922b", "online": "51cf66", "hosting": "4dabf7"}
	_state_dot.color = Color(String(colors.get(state, "8a8f98")))
	var text := state.capitalize()
	if not detail.is_empty():
		text += " - " + detail
	_status.text = text
	_status.tooltip_text = text
	var busy := state != "offline"
	_host_btn.disabled = busy
	_join_btn.disabled = busy
	_leave_btn.disabled = not busy
	_invite_button.disabled = state != "hosting"


func set_info(text: String) -> void:
	_info.text = text


func set_peers(peers: Dictionary, my_pid: int) -> void:
	_last_peers = peers
	_last_my_pid = my_pid
	for child in _peers.get_children():
		child.queue_free()
	var pids := peers.keys()
	pids.sort()
	for pid in pids:
		var p: Dictionary = peers[pid]
		var where := ""
		if not String(p.get("scene", "")).is_empty():
			where += " in %s" % String(p.scene).get_file()
		if not String(p.get("script", "")).is_empty():
			where += " editing %s" % String(p.script).get_file()
		var me := " (you)" if pid == my_pid else ""
		var role := " [host]" if pid == 1 else ""
		var display := "%s%s%s%s" % [String(p.get("name", "?")), role, me, where]
		if not _peer_search.text.strip_edges().is_empty() and not display.to_lower().contains(_peer_search.text.strip_edges().to_lower()):
			continue
		var row := HBoxContainer.new()
		var dot := ColorRect.new()
		dot.color = Color.html(String(p.get("color", "ffffff")))
		dot.custom_minimum_size = Vector2(10, 10)
		row.add_child(dot)
		var label := Label.new()
		label.text = display
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		if pid != my_pid and (bool(p.get("view_3d", false)) or not String(p.get("script", "")).is_empty() or not String(p.get("scene", "")).is_empty()):
			var jump := Button.new()
			jump.text = "Join"
			jump.tooltip_text = "Open what this teammate is working on and jump to their cursor or camera."
			jump.pressed.connect(func(): join_peer_requested.emit(int(pid)))
			row.add_child(jump)
		_peers.add_child(row)
	if _peers.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "Nobody found" if not _peer_search.text.is_empty() else "Nobody yet"
		empty.modulate = Color(1, 1, 1, 0.65)
		_peers.add_child(empty)


func set_conflicts(items: Array) -> void:
	for c in _conflict_box.get_children():
		c.queue_free()
	_tabs.set_tab_title(_conflict_tab_index, "Conflicts" if items.is_empty() else "Conflicts (%d)" % items.size())
	if items.is_empty():
		var l := Label.new()
		l.text = "Nothing to decide. When you and someone else change the same thing while apart, it is held here and nothing is overwritten."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.modulate = Color(1, 1, 1, 0.65)
		_conflict_box.add_child(l)
		return
	_tabs.current_tab = _conflict_tab_index
	for item in items:
		_conflict_box.add_child(_conflict_row(item))


func _conflict_row(item: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	panel.add_child(box)
	var title := Label.new()
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)
	var bar := HBoxContainer.new()
	box.add_child(bar)
	if String(item.get("kind", "")) == "scene":
		title.text = "%s: %s.%s\nyours: %s\ntheirs: %s" % [String(item.scene).get_file(), item.node, item.prop, item.mine, item.theirs]
		var mine := Button.new()
		mine.text = "Keep mine"
		mine.pressed.connect(func(): scene_conflict_chosen.emit(item.scene, item.key, true))
		bar.add_child(mine)
		var theirs := Button.new()
		theirs.text = "Use theirs"
		theirs.pressed.connect(func(): scene_conflict_chosen.emit(item.scene, item.key, false))
		bar.add_child(theirs)
	else:
		title.text = "%s\nchanged by you and by someone else" % String(item.rel)
		var mine2 := Button.new()
		mine2.text = "Keep mine"
		mine2.pressed.connect(func(): file_conflict_chosen.emit(item.rel, "mine"))
		bar.add_child(mine2)
		var theirs2 := Button.new()
		theirs2.text = "Use theirs"
		theirs2.pressed.connect(func(): file_conflict_chosen.emit(item.rel, "theirs"))
		bar.add_child(theirs2)
		if item.get("text", false):
			var markers := Button.new()
			markers.text = "Merge with markers"
			markers.tooltip_text = "Put both versions in the file (<<<<<<< / >>>>>>>) so you can fix it by hand, then save."
			markers.pressed.connect(func(): file_conflict_chosen.emit(item.rel, "markers"))
			bar.add_child(markers)
	return panel


func append_log(line: String, level: int) -> void:
	if _log_view == null or not is_instance_valid(_log_view):
		return
	_append_line(line, level)


func _append_line(line: String, level: int) -> void:
	_log_view.append_text("[color=%s]%s[/color]\n" % [LEVEL_COLORS[clampi(level, 0, 3)], line.replace("[", "[lb]")])
	_log_lines += 1
	if _log_lines > 900:
		_clear_log_view()
		for l in Log.lines.slice(maxi(0, Log.lines.size() - 300)):
			_log_view.append_text("[color=%s]%s[/color]\n" % [LEVEL_COLORS[1], l.replace("[", "[lb]")])
		_log_lines = 300


func _clear_log_view() -> void:
	_log_view.clear()
	_log_lines = 0


func _refresh_lan_hint() -> void:
	_lan_addresses.clear()
	for a in IP.get_local_addresses():
		var s := String(a)
		if s.contains(":") or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		if s.begins_with("192.168.") or s.begins_with("10.") or s.begins_with("172."):
			_lan_addresses.append(s)
	_lan_hint.text = ("Others on your network join with: %s (or 127.0.0.1 on this computer)" % ", ".join(_lan_addresses)) if not _lan_addresses.is_empty() else "Others join with this computer's LAN IP (127.0.0.1 only works on this computer)."


func _copy_invite_details() -> void:
	_refresh_lan_hint()
	if _lan_addresses.is_empty():
		return
	DisplayServer.clipboard_set("Join address: %s\nPort: %d\nProject code: %s" % [_lan_addresses[0], int(_port.value), _key.text.strip_edges()])
	_lan_hint.text = "LAN invite details copied. Send them to your friend."
