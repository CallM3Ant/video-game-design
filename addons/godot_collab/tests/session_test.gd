extends SceneTree

const Session := preload("res://addons/godot_collab/core/session.gd")
const Log := preload("res://addons/godot_collab/core/log.gd")
const OT := preload("res://addons/godot_collab/core/ot.gd")
const OTClient := preload("res://addons/godot_collab/core/ot_client.gd")

const PORT := 47931

var _failed := 0
var _checks := 0
var _all: Array = []


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
		for s in _all:
			s.poll()
		if cond.call():
			return true
		await create_timer(0.01).timeout
	for s in _all:
		s.poll()
	return cond.call()


func _make() -> Session:
	var s := Session.new()
	_all.append(s)
	return s


func _run() -> void:
	await _test_handshake()
	await _test_host_shutdown()
	await _test_scene_docs()
	await _test_text_docs()
	for s in _all:
		s.shutdown()
	if _failed > 0:
		printerr("session tests failed: %d of %d" % [_failed, _checks])
		quit(1)
	else:
		print("session tests passed (%d checks)." % _checks)
		quit()


func _test_handshake() -> void:
	var host := _make()
	_expect(host.start_host(PORT, "secret", "Hana", "55aaee") == OK, "host starts")
	var good := _make()
	good.join("127.0.0.1", PORT, "secret", "Cole", "ff6633")
	var ok: bool = await _pump(func(): return good.joined_ok)
	_expect(ok and good.state == "online", "client joins with the right code")
	_expect(host.peers.size() == 2, "host sees two peers")
	_expect(good.peers.size() == 2 and good.host_name == "Hana", "client learns the peer list")
	_expect(host.peer_color(1).to_html(false) == "55aaee" and host.peer_color(good.my_pid).to_html(false) == "ff6633", "the session uses each collaborator's chosen highlight color")
	good.update_identity("Cole Two", "33cc88")
	ok = await _pump(func(): return host.peer_name(good.my_pid) == "Cole Two" and host.peer_color(good.my_pid).to_html(false) == "33cc88")
	_expect(ok, "a collaborator can change their display name and highlight color while connected")
	var camera_pose := Transform3D(Basis.IDENTITY, Vector3(8, 5, -3))
	good.set_presence("res://terrain.tscn", "", camera_pose, true)
	ok = await _pump(func(): return host.peers.has(good.my_pid) and host.peers[good.my_pid].get("view_3d", false) and host.peers[good.my_pid].camera.origin == camera_pose.origin)
	_expect(ok, "3D camera presence is sent to the host with the current scene")
	var bad := _make()
	bad.join("127.0.0.1", PORT, "wrong", "Eve")
	ok = await _pump(func(): return not bad.last_reject.is_empty())
	_expect(ok and bad.last_reject.contains("project code") and not bad.joined_ok, "wrong project code rejected: " + bad.last_reject)
	var dup := _make()
	dup.join("127.0.0.1", PORT, "secret", "Cole Two")
	ok = await _pump(func(): return dup.joined_ok)
	_expect(ok and dup.peers.values().any(func(p): return p.name == "Cole Two (2)"), "duplicate display names are made unique")
	dup.leave()
	ok = await _pump(func(): return host.peers.size() == 2)
	_expect(ok, "host notices a peer leaving")
	good.leave()
	ok = await _pump(func(): return host.peers.size() == 1)
	_expect(ok, "a client disconnect removes its peer entry before the socket closes")
	host.leave()
	await _pump(func(): return false, 0.2)


func _test_host_shutdown() -> void:
	var host := _make()
	var client := _make()
	host.start_host(PORT, "closing", "Host")
	client.join("127.0.0.1", PORT, "closing", "Client")
	var joined: bool = await _pump(func(): return client.joined_ok)
	host.shutdown()
	var closed: bool = await _pump(func(): return not client.joined_ok and client.state == "offline", 2.0)
	_expect(joined and closed, "a closing host tells its clients to disconnect instead of retrying")
	client.shutdown()


func _rec(id: String, parent: String, name: String, props: Dictionary = {}) -> Dictionary:
	return {"id": id, "p": parent, "n": name, "c": "Node3D", "props": props, "groups": [], "conns": []}


func _test_scene_docs() -> void:
	var host := _make()
	host.start_host(PORT, "k", "Host")
	host.docs.scene_provider = func(path: String) -> Variant:
		if path == "res://a.tscn":
			return [_rec("r", "", "Root"), _rec("n1", "r", "Block", {"position": Vector3(1, 0, 0)})]
		return null
	host.docs.file_exists = func(path: String) -> bool: return path == "res://a.tscn"
	var host_inbox: Array = []
	host.message.connect(func(m): host_inbox.append(m))
	var c1 := _make()
	var c2 := _make()
	var in1: Array = []
	var in2: Array = []
	c1.message.connect(func(m): in1.append(m))
	c2.message.connect(func(m): in2.append(m))
	c1.join("127.0.0.1", PORT, "k", "One")
	c2.join("127.0.0.1", PORT, "k", "Two")
	await _pump(func(): return c1.joined_ok and c2.joined_ok)
	c1.send({"t": "sc_open", "path": "res://a.tscn"})
	var ok: bool = await _pump(func(): return in1.any(func(m): return m.t == "sc_state"))
	_expect(ok, "client receives scene state")
	var state: Dictionary = in1.filter(func(m): return m.t == "sc_state")[0]
	_expect(state.nodes.size() == 2 and state.rev == 0 and state.acked == 0, "scene state content")
	var epoch: String = state.epoch
	c2.send({"t": "sc_open", "path": "res://a.tscn"})
	await _pump(func(): return in2.any(func(m): return m.t == "sc_state"))
	in1.clear()
	in2.clear()
	c1.send({"t": "sc_ops", "path": "res://a.tscn", "epoch": epoch, "cseq": 1, "ops": [
		{"k": "set", "id": "n1", "props": {"position": Vector3(5, 5, 5)}, "reset": []},
		{"k": "add", "id": "n2", "p": "r", "n": "Block", "c": "Node3D", "si": 1},
	]})
	ok = await _pump(func(): return in1.any(func(m): return m.t == "sc_ops") and in2.any(func(m): return m.t == "sc_ops"))
	_expect(ok, "ops reach every watcher including the sender")
	var got: Dictionary = in2.filter(func(m): return m.t == "sc_ops")[0]
	_expect(got.by == c1.my_uid and got.cseq == 1 and got.rev == 1 and got.ops.size() == 2, "broadcast carries sender, batch and revision")
	_expect(got.ops[1].n == "Block2" and got.ops[1].get("fixed", false), "host fixes duplicate names")
	# A stale epoch is refused.
	in1.clear()
	c1.send({"t": "sc_ops", "path": "res://a.tscn", "epoch": "stale", "cseq": 2, "ops": []})
	ok = await _pump(func(): return in1.any(func(m): return m.t == "sc_reject"))
	_expect(ok and in1[0].reason == "epoch", "old epoch rejected")
	# An invalid op rejects but keeps the valid prefix consistent for everyone.
	in1.clear()
	in2.clear()
	c1.send({"t": "sc_ops", "path": "res://a.tscn", "epoch": epoch, "cseq": 3, "ops": [
		{"k": "name", "id": "n1", "n": "Renamed"},
		{"k": "del", "id": "ghost"},
	]})
	ok = await _pump(func(): return in1.any(func(m): return m.t == "sc_reject") and in2.any(func(m): return m.t == "sc_ops"))
	_expect(ok, "invalid op rejected while the valid prefix is broadcast")
	_expect(in2.filter(func(m): return m.t == "sc_ops")[0].ops.size() == 1, "only the applied prefix is broadcast")
	# Duplicate batch numbers (a resend after reconnect) are acknowledged without re-applying.
	in1.clear()
	c1.send({"t": "sc_ops", "path": "res://a.tscn", "epoch": epoch, "cseq": 3, "ops": [{"k": "name", "id": "n1", "n": "Again"}]})
	ok = await _pump(func(): return in1.any(func(m): return m.t == "sc_ops"))
	_expect(ok and in1[0].ops.is_empty(), "duplicate batch re-acknowledged")
	# The host's own editor is peer 1 and gets the same stream.
	host.send({"t": "sc_open", "path": "res://a.tscn"})
	_expect(host_inbox.any(func(m): return m.t == "sc_state" and m.nodes.size() == 3), "host editor gets scene state via loopback")
	host_inbox.clear()
	c2.send({"t": "sc_ops", "path": "res://a.tscn", "epoch": epoch, "cseq": 1, "ops": [{"k": "set", "id": "n1", "props": {"visible": false}, "reset": []}]})
	ok = await _pump(func(): return host_inbox.any(func(m): return m.t == "sc_ops"))
	_expect(ok, "host editor receives peers' ops")
	# Unsafe paths and unknown scenes are handled.
	in1.clear()
	c1.send({"t": "sc_open", "path": "res://../evil.tscn"})
	c1.send({"t": "sc_open", "path": "res://nothing.tscn"})
	ok = await _pump(func(): return in1.any(func(m): return m.t == "sc_state" and m.get("missing", false)))
	_expect(ok, "unknown scene reported missing")
	# A client may seed a scene the host does not have at all.
	in1.clear()
	c1.send({"t": "sc_open", "path": "res://new.tscn", "snapshot": [_rec("x", "", "NewRoot")]})
	ok = await _pump(func(): return in1.any(func(m): return m.t == "sc_state" and m.nodes.size() == 1))
	_expect(ok, "client can create a scene document the host lacks")
	for s in [c1, c2, host]:
		s.leave()
	await _pump(func(): return false, 0.2)


# Simulated editors: each peer holds text + an OTClient and obeys the protocol messages.
class Editor:
	extends RefCounted
	var session
	var path := "res://s.gd"
	var text := ""
	var client: RefCounted
	var inbox: Array = []
	var OTc
	var OTm

	func _init(s, ot_client_script, ot_script) -> void:
		session = s
		OTc = ot_client_script
		OTm = ot_script
		client = OTc.new()
		client.send_op.connect(func(rev: int, op, cseq: int):
			session.send({"t": "tx_op", "path": path, "rev": rev, "op": op.to_array(), "cseq": cseq, "cid": client.cid, "epoch": client.epoch}))
		session.message.connect(_on_message)

	func open() -> void:
		session.send({"t": "tx_open", "path": path})

	func type_at(index: int, s: String) -> void:
		var before := text
		text = before.substr(0, index) + s + before.substr(index)
		client.apply_client(OTm.diff(before, text))

	func _on_message(m: Dictionary) -> void:
		if m.get("path", "") != path:
			return
		match m.t:
			"tx_state":
				if m.has("text"):
					text = m.text
					client.reset(int(m.rev), String(m.epoch))
			"tx_op":
				if client.is_own(String(m.by), session.my_uid, String(m.cid), int(m.cseq)):
					client.server_ack()
				else:
					var op = client.apply_server(OTm.from_array(m.op))
					var nt = op.apply(text)
					text = nt


func _test_text_docs() -> void:
	var host := _make()
	host.start_host(PORT, "k", "Host")
	host.docs.text_provider = func(path: String) -> Variant:
		return "alpha\nbeta\ngamma\n" if path == "res://s.gd" else null
	var a := _make()
	var b := _make()
	a.join("127.0.0.1", PORT, "k", "A")
	b.join("127.0.0.1", PORT, "k", "B")
	await _pump(func(): return a.joined_ok and b.joined_ok)
	var ea := Editor.new(a, OTClient, OT)
	var eb := Editor.new(b, OTClient, OT)
	ea.open()
	eb.open()
	var ok: bool = await _pump(func(): return ea.text != "" and eb.text != "")
	_expect(ok and ea.text == "alpha\nbeta\ngamma\n" and eb.text == ea.text, "both editors load the host's text")
	# Concurrent typing in different places and at the same place.
	ea.type_at(0, "A-")
	eb.type_at(eb.text.length(), "B-end\n")
	ea.type_at(8, "X")
	eb.type_at(8, "Y")
	ok = await _pump(func(): return not ea.client.has_pending() and not eb.client.has_pending() and ea.text == eb.text and ea.text.contains("B-end"))
	_expect(ok and ea.text == eb.text, "concurrent edits converge: %s vs %s" % [ea.text.c_escape(), eb.text.c_escape()])
	_expect(ea.text.begins_with("A-alpha") and ea.text.contains("X") and ea.text.contains("Y") and ea.text.ends_with("B-end\n"), "all concurrent edits survive: " + ea.text.c_escape())
	# Resume after a dropped connection: the host replays what was missed.
	var epoch: String = eb.client.epoch
	var rev: int = eb.client.rev
	b.leave()
	ea.type_at(0, "while-away ")
	await _pump(func(): return not ea.client.has_pending())
	b.join("127.0.0.1", PORT, "k", "B")
	await _pump(func(): return b.joined_ok)
	var seen: Array = []
	b.message.connect(func(m): seen.append(m))
	b.send({"t": "tx_open", "path": "res://s.gd", "epoch": epoch, "rev": rev})
	ok = await _pump(func(): return seen.any(func(m): return m.t == "tx_state"))
	_expect(ok, "resume answered")
	var st: Dictionary = seen.filter(func(m): return m.t == "tx_state")[0]
	_expect(st.has("since") and st.since.size() == 1 and not st.has("text"), "resume replays only the missed operations")
	# A stale epoch gets a full state instead.
	seen.clear()
	b.send({"t": "tx_open", "path": "res://s.gd", "epoch": "other", "rev": 0})
	ok = await _pump(func(): return seen.any(func(m): return m.t == "tx_state"))
	_expect(ok and seen[0].has("text") and seen[0].text == ea.text, "unknown epoch gets the full text")
	# Ops for an unknown epoch are rejected.
	seen.clear()
	b.send({"t": "tx_op", "path": "res://s.gd", "rev": 0, "op": [1], "cseq": 1, "cid": "x", "epoch": "nope"})
	ok = await _pump(func(): return seen.any(func(m): return m.t == "tx_reject"))
	_expect(ok, "op with the wrong epoch rejected")
	for s in [a, b, host]:
		s.leave()
	await _pump(func(): return false, 0.2)
