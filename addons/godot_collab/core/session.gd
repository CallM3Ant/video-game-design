@tool
extends RefCounted
## One collaboration session: either the host (accepts peers and orders every document) or a client
## (joined to a host). The host's own editor talks to the same host logic as peer 1, so a host and a
## client behave identically from the point of view of the editor modules.
##
## Editor modules call send() and listen to the `message` signal. The host-only routing lives in
## HostDocs (scenes + live text) and in handlers registered with register_host_handler().

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")
const Net := preload("res://addons/godot_collab/core/net.gd")
const HostDocs := preload("res://addons/godot_collab/core/host_docs.gd")

signal state_changed(state: String)
signal message(msg: Dictionary)
signal peers_changed()
signal joined()
signal link_lost(reason: String)
signal notice(text: String, severity: int)

const PROTOCOL_VERSION := 5
const DEFAULT_PORT := 47600
const HOST_PID := 1
const COLORS := ["ff6b6b", "4dabf7", "51cf66", "fcc419", "cc5de8", "ff922b", "22b8cf", "f06595"]

var net := Net.new()
var docs: HostDocs
var is_host := false
var state := "offline"
var joined_ok := false
var my_uid := ""
var my_name := "Player"
var my_color := "4dabf7"
var my_pid := 0
var project_key := ""
var host_name := ""
var host_epoch := ""
var peers: Dictionary = {}
var last_reject := ""
var _host_handlers: Dictionary = {}
var _address := ""
var _port := 0
var _presence_at := 0


func _init() -> void:
	my_uid = Util.random_hex(8)
	docs = HostDocs.new(self)
	net.state_changed.connect(_on_net_state)
	net.peer_connected.connect(_on_net_peer_connected)
	net.peer_closed.connect(_on_net_peer_closed)
	net.message.connect(_on_net_message)


## Breaks the session <-> docs reference cycle so both can be freed.
func shutdown() -> void:
	leave()
	docs.session = null


func is_online() -> bool:
	return state == "hosting" or state == "online"


func register_host_handler(prefix: String, cb: Callable) -> void:
	_host_handlers[prefix] = cb


func poll() -> void:
	net.poll()


# --- starting and stopping ----------------------------------------------------------------------

func start_host(port: int, key: String, display_name: String, display_color: String = "4dabf7") -> Error:
	leave()
	project_key = key
	my_name = display_name
	my_color = _normalize_color(display_color, "4dabf7")
	var err := net.start_host(port)
	if err != OK:
		notice.emit("Could not host on port %d: %s" % [port, error_string(err)], 2)
		return err
	is_host = true
	my_pid = HOST_PID
	host_name = display_name
	host_epoch = Util.random_hex(6)
	peers = {HOST_PID: _new_peer(my_uid, display_name, HOST_PID, my_color)}
	joined_ok = true
	docs.reset()
	_set_state("hosting")
	Log.info("session", "Hosting as '%s' on port %d (session %s)" % [display_name, port, host_epoch])
	peers_changed.emit()
	joined.emit()
	return OK


func join(address: String, port: int, key: String, display_name: String, display_color: String = "4dabf7") -> Error:
	leave()
	project_key = key
	my_name = display_name
	my_color = _normalize_color(display_color, "4dabf7")
	_address = address
	_port = port
	last_reject = ""
	is_host = false
	var err := net.connect_to(address, port, true)
	if err != OK:
		return err
	_set_state("connecting")
	Log.info("session", "Joining %s:%d as '%s'" % [address, port, display_name])
	return OK


func leave() -> void:
	var was := state
	if is_host and joined_ok:
		net.graceful_stop({"t": "session_closing"})
	elif joined_ok:
		net.graceful_stop({"t": "session_leave"})
	else:
		net.stop()
	docs.reset()
	is_host = false
	joined_ok = false
	peers.clear()
	my_pid = 0
	if was != "offline":
		Log.info("session", "Left the session")
	_set_state("offline")
	peers_changed.emit()


func _set_state(s: String) -> void:
	if state != s:
		state = s
		state_changed.emit(s)


# --- sending ----------------------------------------------------------------------------------------

## Sends a message from this editor to the host (the host handles it directly).
func send(msg: Dictionary, low_priority: bool = false) -> bool:
	if is_host:
		_host_receive(HOST_PID, my_uid, msg)
		return true
	if not joined_ok:
		return false
	return net.send_to_host(msg, low_priority)


## Host only: sends to one peer (peer 1 is the host's own editor).
func deliver(pid: int, msg: Dictionary, low_priority: bool = false) -> void:
	if pid == HOST_PID:
		message.emit(msg)
	else:
		net.send_to(pid, msg, low_priority)


## Host only: sends to every joined peer including the host's own editor.
func broadcast(msg: Dictionary, except_pid: int = -1, low_priority: bool = false) -> void:
	net.broadcast(msg, except_pid, low_priority)
	if except_pid != HOST_PID:
		message.emit(msg)


func peer_name(pid: int) -> String:
	var p: Dictionary = peers.get(pid, {})
	return String(p.get("name", "peer %d" % pid))


func peer_color(pid: int) -> Color:
	var p: Dictionary = peers.get(pid, {})
	return Color.html(String(p.get("color", "ffffff")))


func update_identity(display_name: String, display_color: String) -> void:
	var cleaned_name := display_name.strip_edges().left(32)
	if cleaned_name.is_empty():
		cleaned_name = "Player"
	var cleaned_color := _normalize_color(display_color, my_color)
	if cleaned_name == my_name and cleaned_color == my_color:
		return
	my_name = cleaned_name
	my_color = cleaned_color
	if is_host:
		host_name = my_name
		peers[HOST_PID]["name"] = my_name
		peers[HOST_PID]["color"] = my_color
		_broadcast_peers()
		peers_changed.emit()
	elif joined_ok:
		var local_peer: Dictionary = peers.get(my_pid, {})
		if not local_peer.is_empty():
			local_peer["name"] = my_name
			local_peer["color"] = my_color
		send({"t": "identity", "name": my_name, "color": my_color})
		peers_changed.emit()


static func _normalize_color(raw: String, fallback: String) -> String:
	var value := raw.strip_edges().trim_prefix("#").to_lower()
	if value.length() != 6 and value.length() != 8:
		return fallback
	for character in value:
		if not "0123456789abcdef".contains(character):
			return fallback
	return value.left(6)


func uid_name(uid: String) -> String:
	for pid in peers:
		if String(peers[pid].get("uid", "")) == uid:
			return String(peers[pid].get("name", uid))
	return uid


func set_presence(scene_path: String, script_path: String, camera: Transform3D = Transform3D.IDENTITY, view_3d: bool = false) -> void:
	var now := Util.now_ms()
	var p: Dictionary = peers.get(my_pid, {})
	var old_camera: Variant = p.get("camera", Transform3D.IDENTITY)
	var camera_changed := view_3d != bool(p.get("view_3d", false)) or not old_camera is Transform3D
	if not camera_changed and view_3d:
		camera_changed = old_camera.origin.distance_to(camera.origin) > 0.12 or old_camera.basis.x.distance_to(camera.basis.x) > 0.025 or old_camera.basis.y.distance_to(camera.basis.y) > 0.025 or old_camera.basis.z.distance_to(camera.basis.z) > 0.025
	var same_docs: bool = p.get("scene", "") == scene_path and p.get("script", "") == script_path
	if same_docs and not camera_changed and now - _presence_at < 2000:
		return
	if same_docs and camera_changed and now - _presence_at < 100:
		return
	_presence_at = now
	send({"t": "presence", "scene": scene_path, "script": script_path, "camera": camera, "view_3d": view_3d})


# --- compatibility --------------------------------------------------------------------------------

static func compat_info() -> Dictionary:
	var v := Engine.get_version_info()
	return {
		"proto": PROTOCOL_VERSION,
		"major": int(v.get("major", -1)),
		"minor": int(v.get("minor", -1)),
		"version": str(ProjectSettings.get_setting("application/config/version", "")).strip_edges(),
	}


static func proof_for(nonce: String, key: String) -> String:
	return (nonce + ":" + key).sha256_text()


func _compat_error(hello: Dictionary) -> String:
	var mine := compat_info()
	if int(hello.get("proto", -1)) != int(mine["proto"]):
		return "Different Godot Collab version (host protocol %d, yours %d). Update the add-on on both machines." % [mine["proto"], int(hello.get("proto", -1))]
	if int(hello.get("major", -1)) != int(mine["major"]) or int(hello.get("minor", -1)) != int(mine["minor"]):
		return "Godot version mismatch (host %d.%d, yours %d.%d). Use the same Godot 4.x release." % [mine["major"], mine["minor"], int(hello.get("major", -1)), int(hello.get("minor", -1))]
	if str(hello.get("version", "")) != str(mine["version"]):
		return "Project version mismatch (host '%s', yours '%s')." % [mine["version"], str(hello.get("version", ""))]
	return ""


# --- net events -------------------------------------------------------------------------------------

func _on_net_state(s: String) -> void:
	if is_host:
		return
	match s:
		"connecting", "connected":
			if not joined_ok:
				_set_state("connecting")
		"reconnecting":
			_set_state("reconnecting")
		"offline":
			if state != "offline" and last_reject.is_empty():
				_set_state("offline")


func _on_net_peer_connected(pid: int) -> void:
	if is_host:
		net.send_to(pid, {"t": "challenge", "nonce": net.peer_nonce(pid), "proto": PROTOCOL_VERSION})


func _on_net_peer_closed(pid: int, reason: String) -> void:
	if is_host:
		docs.peer_left(pid)
		if peers.has(pid):
			var name := peer_name(pid)
			peers.erase(pid)
			Log.info("session", "%s left (%s)" % [name, reason])
			notice.emit("%s left the session." % name, 0)
			_broadcast_peers()
			peers_changed.emit()
	elif pid == HOST_PID:
		var was_joined := joined_ok
		joined_ok = false
		if was_joined:
			Log.warn("session", "Lost connection to the host (%s). Local edits are kept and will be re-synced." % reason)
			notice.emit("Lost connection to the host. Your edits are kept and will sync when it returns.", 1)
			link_lost.emit(reason)
		peers.clear()
		peers_changed.emit()


func _on_net_message(pid: int, msg: Dictionary) -> void:
	if is_host:
		_host_on_net_message(pid, msg)
	else:
		_client_on_message(msg)


# --- client side ----------------------------------------------------------------------------------------

func _client_on_message(msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"challenge":
			var c := compat_info()
			net.send_to_host({
				"t": "hello", "proto": c["proto"], "major": c["major"], "minor": c["minor"], "version": c["version"],
				"proof": proof_for(String(msg.get("nonce", "")), project_key),
			"uid": my_uid, "name": my_name, "color": my_color,
			})
		"welcome":
			my_pid = int(msg.get("pid", 0))
			host_name = String(msg.get("host_name", "host"))
			var new_epoch := String(msg.get("session", ""))
			var host_restarted := not host_epoch.is_empty() and host_epoch != new_epoch
			host_epoch = new_epoch
			peers = _peers_from_wire(msg.get("peers", {}))
			my_name = String(peers.get(my_pid, {}).get("name", my_name))
			my_color = String(peers.get(my_pid, {}).get("color", my_color))
			joined_ok = true
			net.mark_connected()
			_set_state("online")
			Log.info("session", "Joined %s's session as peer %d%s" % [host_name, my_pid, " (host was restarted)" if host_restarted else ""])
			notice.emit("Connected to %s." % host_name, 0)
			peers_changed.emit()
			joined.emit()
		"reject":
			last_reject = String(msg.get("reason", "Rejected by host."))
			Log.error("session", "Host rejected us: " + last_reject)
			notice.emit("Could not join: " + last_reject, 2)
			net.stop()
			_set_state("offline")
		"peers":
			peers = _peers_from_wire(msg.get("list", {}))
			peers_changed.emit()
		"session_closing":
			var was_joined := joined_ok
			joined_ok = false
			peers.clear()
			docs.reset()
			net.stop()
			_set_state("offline")
			peers_changed.emit()
			if was_joined:
				link_lost.emit("host closed the session")
				notice.emit("The host closed the collaboration session.", 0)
		_:
			message.emit(msg)


func _peers_from_wire(w: Variant) -> Dictionary:
	var out := {}
	if w is Dictionary:
		for k in w:
			out[int(k)] = w[k]
	return out


# --- host side ---------------------------------------------------------------------------------------------

func _new_peer(uid: String, name: String, pid: int, color: String = "") -> Dictionary:
	var peer_color: String = _normalize_color(color, COLORS[pid % COLORS.size()]) if not color.is_empty() else COLORS[pid % COLORS.size()]
	return {"uid": uid, "name": name, "color": peer_color, "scene": "", "script": "", "camera": Transform3D.IDENTITY, "view_3d": false}


func _broadcast_peers() -> void:
	net.broadcast({"t": "peers", "list": peers})


func _host_on_net_message(pid: int, msg: Dictionary) -> void:
	var t := String(msg.get("t", ""))
	if not net.is_authorized(pid):
		if t != "hello":
			return
		var err := ""
		var expected := proof_for(net.peer_nonce(pid), project_key)
		if String(msg.get("proof", "")) != expected:
			err = "Wrong project code."
		else:
			err = _compat_error(msg)
		if not err.is_empty():
			Log.warn("session", "Rejected peer %d: %s" % [pid, err])
			net.send_to(pid, {"t": "reject", "reason": err})
			net.close_peer(pid, "rejected")
			return
		var uid := String(msg.get("uid", ""))
		for other in peers.keys():
			if other != pid and other != HOST_PID and String(peers[other].get("uid", "")) == uid:
				Log.info("session", "Peer %d replaces its own stale connection %d" % [pid, other])
				docs.peer_left(other)
				peers.erase(other)
				net.close_peer(other, "replaced by a new connection", false)
		var name := String(msg.get("name", "Player")).strip_edges().left(32)
		if name.is_empty():
			name = "Player"
		var base := name
		var n := 2
		while _name_taken(name, pid):
			name = "%s (%d)" % [base, n]
			n += 1
		net.authorize(pid)
		peers[pid] = _new_peer(uid, name, pid, String(msg.get("color", "")))
		net.send_to(pid, {"t": "welcome", "pid": pid, "host_name": host_name, "session": host_epoch, "peers": peers})
		Log.info("session", "%s joined (peer %d from %s)" % [name, pid, net.peer_address(pid)])
		notice.emit("%s joined the session." % name, 0)
		_broadcast_peers()
		peers_changed.emit()
		return
	var p: Dictionary = peers.get(pid, {})
	_host_receive(pid, String(p.get("uid", "")), msg)


func _name_taken(name: String, except_pid: int) -> bool:
	for pid in peers:
		if pid != except_pid and String(peers[pid].get("name", "")) == name:
			return true
	return false


func _host_receive(pid: int, uid: String, msg: Dictionary) -> void:
	var t := String(msg.get("t", ""))
	if t == "session_leave":
		net.close_peer(pid, "left the session", false)
		return
	if t == "presence":
		var p: Dictionary = peers.get(pid, {})
		if not p.is_empty():
			p["scene"] = String(msg.get("scene", ""))
			p["script"] = String(msg.get("script", ""))
			p["camera"] = msg.get("camera", Transform3D.IDENTITY)
			p["view_3d"] = bool(msg.get("view_3d", false))
			_broadcast_peers()
			peers_changed.emit()
		return
	if t == "identity":
		var p: Dictionary = peers.get(pid, {})
		if not p.is_empty():
			var base_name := String(msg.get("name", "Player")).strip_edges().left(32)
			if base_name.is_empty():
				base_name = "Player"
			var next_name := base_name
			var suffix := 2
			while _name_taken(next_name, pid):
				next_name = "%s (%d)" % [base_name, suffix]
				suffix += 1
			p["name"] = next_name
			p["color"] = _normalize_color(String(msg.get("color", "")), String(p.get("color", "ffffff")))
			_broadcast_peers()
			peers_changed.emit()
		return
	if t.begins_with("sc_") or t.begins_with("tx_"):
		docs.handle(pid, uid, msg)
		return
	for prefix in _host_handlers:
		if t.begins_with(prefix):
			_host_handlers[prefix].call(pid, uid, msg)
			return
	Log.debug("session", "Host ignored unknown message '%s' from %s" % [t, peer_name(pid)])
