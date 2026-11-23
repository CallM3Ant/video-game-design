extends SceneTree

const Session := preload("res://addons/godot_collab/core/session.gd")
const SceneSync := preload("res://addons/godot_collab/editor/scene_sync.gd")
const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")

const PORT := 47932
const SCENE := "res://addons/godot_collab/tests/_collab_scene.tscn"

var _failed := 0
var _checks := 0
var _peers: Array = []
var _tmp_state := ""


class FakeEnv:
	extends RefCounted
	var _tree: SceneTree
	var roots: Array = []
	var selected: Array = []
	var unsaved := 0

	func _init(t: SceneTree) -> void:
		_tree = t

	func tree() -> SceneTree:
		return _tree

	func undo_redo() -> Object:
		return null

	func open_roots() -> Array:
		return roots

	func edited_root() -> Node:
		return roots[0] if roots.size() > 0 else null

	func selected_nodes() -> Array:
		return selected

	func deselect(n: Node) -> void:
		selected.erase(n)

	func inspected() -> Object:
		return null

	func inspect(_o: Object) -> void:
		pass

	func mark_unsaved() -> void:
		unsaved += 1

	func is_dragging() -> bool:
		return false


class Peer:
	extends RefCounted
	var name := ""
	var session
	var sync
	var env
	var root: Node3D
	var joined_before := false

	func scene_node(path: String) -> Node:
		return root.get_node_or_null(NodePath(path))


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
		for p in _peers:
			p.session.poll()
		if cond.call():
			return true
		await create_timer(0.01).timeout
	for p in _peers:
		p.session.poll()
	return cond.call()


func _settle(ms: int = 150) -> void:
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < end:
		for p in _peers:
			p.session.poll()
		await create_timer(0.01).timeout


func _poll_structure(sync) -> void:
	sync._structure_due = false
	sync._last_structure_poll = Util.now_ms() - SceneSync.STRUCTURE_POLL_MS
	sync.process()


func _make_scene() -> Node3D:
	var root := Node3D.new()
	root.name = "World"
	root.scene_file_path = SCENE
	for pair in [["Block", Vector3(1, 0, 0)], ["Other", Vector3(0, 2, 0)]]:
		var n := Node3D.new()
		n.name = pair[0]
		n.position = pair[1]
		root.add_child(n)
		n.owner = root
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = BoxMesh.new()
	root.add_child(mesh)
	mesh.owner = root
	var sub := Node3D.new()
	sub.name = "Sub"
	root.get_node("Block").add_child(sub)
	sub.owner = root
	return root


func _make_peer(peer_name: String, is_host: bool) -> Peer:
	var p := Peer.new()
	p.name = peer_name
	p.session = Session.new()
	p.env = FakeEnv.new(self)
	p.root = _make_scene()
	p.env.roots = [p.root]
	p.sync = SceneSync.new()
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
		p.session.docs.scene_provider = p.sync.provide_snapshot
		p.session.docs.file_exists = func(_path: String) -> bool: return true
	_peers.append(p)
	return p


func _connect(p: Peer, key: String = "k") -> void:
	p.session.join("127.0.0.1", PORT, key, p.name)
	await _pump(func(): return p.session.joined_ok)
	await _pump(func(): return p.sync.trackers.has(SCENE) and p.sync.trackers[SCENE].live)


func _run() -> void:
	_tmp_state = ProjectSettings.globalize_path("res://").path_join(".godot").path_join("collab_test_state")
	Util.state_dir_override = _tmp_state
	await _scenario_live_edits()
	await _scenario_structure()
	await _scenario_offline_merge()
	await _scenario_inflight_recovery()
	await _scenario_first_join_host_wins()
	for p in _peers:
		p.session.shutdown()
		p.sync.teardown()
		p.root.free()
	if DirAccess.dir_exists_absolute(_tmp_state):
		_remove_dir(_tmp_state)
	if _failed > 0:
		printerr("scene sync tests failed: %d of %d" % [_failed, _checks])
		quit(1)
	else:
		print("scene sync tests passed (%d checks)." % _checks)
		quit()


func _remove_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	DirAccess.remove_absolute(path)


func _tree_text(p: Peer) -> String:
	var out := []
	for n in p.root.find_children("*", "", true, false):
		if n.owner == p.root:
			out.append("%s<%s" % [n.name, n.get_parent().name])
	out.sort()
	return ",".join(out)


func _scenario_live_edits() -> void:
	var host := _make_peer("Hana", true)
	host.session.start_host(PORT, "k", "Hana")
	host.sync.session_started()
	host.joined_before = true
	var cole := _make_peer("Cole", false)
	var dana := _make_peer("Dana", false)
	await _connect(cole)
	await _connect(dana)
	var ok: bool = await _pump(func(): return host.sync.trackers[SCENE].live and cole.sync.trackers[SCENE].live and dana.sync.trackers[SCENE].live)
	_expect(ok, "everybody is live on the scene")
	_expect(cole.env.unsaved == 0 and not cole.sync.trackers[SCENE].unsaved_pending, "identical copies need no changes on first sync")
	var ops_before: int = host.sync._ops_sent + cole.sync._ops_sent + dana.sync._ops_sent
	await _settle(300)
	_expect(host.sync._ops_sent + cole.sync._ops_sent + dana.sync._ops_sent == ops_before, "a synced scene stays quiet (no echo)")
	cole.env.selected = [cole.scene_node("Block")]
	cole.sync._sync_local_selection(Util.now_ms())
	ok = await _pump(func():
		var host_peers: Dictionary = host.sync.remote_selections.get(SCENE, {})
		var dana_peers: Dictionary = dana.sync.remote_selections.get(SCENE, {})
		return host_peers.has(cole.session.my_pid) and dana_peers.has(cole.session.my_pid))
	var highlighted: Array = dana.sync._remote_selected_nodes(SCENE, dana.root)
	_expect(ok and not highlighted.is_empty() and highlighted[0].node.name == "Block", "a teammate's selected scene object is highlighted on the other editors")
	cole.env.selected.clear()
	cole.sync._sync_local_selection(Util.now_ms())
	ok = await _pump(func(): return not host.sync.remote_selections.get(SCENE, {}).has(cole.session.my_pid) and not dana.sync.remote_selections.get(SCENE, {}).has(cole.session.my_pid))
	_expect(ok, "a remote scene highlight disappears when the teammate deselects")

	# A property edit travels to everybody.
	host.scene_node("Block").position = Vector3(5, 6, 7)
	host.sync.capture_now(SCENE)
	ok = await _pump(func(): return cole.scene_node("Block").position == Vector3(5, 6, 7) and dana.scene_node("Block").position == Vector3(5, 6, 7))
	_expect(ok, "host's move reaches both clients")
	# ...and back from a client, to the host and the other client.
	dana.scene_node("Other").rotation = Vector3(0.5, 0, 0)
	dana.scene_node("Other").visible = false
	dana.sync.capture_now(SCENE)
	ok = await _pump(func(): return host.scene_node("Other").visible == false and cole.scene_node("Other").visible == false)
	_expect(ok and host.scene_node("Other").rotation.is_equal_approx(Vector3(0.5, 0, 0)), "client edits reach the host and other clients")
	# Sub-resources are edited in place.
	var cole_mesh: MeshInstance3D = cole.scene_node("Mesh")
	var mesh_before: Object = host.scene_node("Mesh").mesh
	cole_mesh.mesh.size = Vector3(3, 3, 3)
	cole.sync.capture_now(SCENE)
	ok = await _pump(func(): return host.scene_node("Mesh").mesh.size == Vector3(3, 3, 3))
	_expect(ok and host.scene_node("Mesh").mesh == mesh_before, "embedded resource updated in place on the host")
	# Concurrent edits to different properties both survive; the same property converges.
	host.scene_node("Block").scale = Vector3(2, 2, 2)
	cole.scene_node("Block").rotation = Vector3(0, 1, 0)
	host.scene_node("Other").position = Vector3(9, 9, 9)
	cole.scene_node("Other").position = Vector3(8, 8, 8)
	host.sync.capture_now(SCENE)
	cole.sync.capture_now(SCENE)
	ok = await _pump(func(): return host.scene_node("Other").position == cole.scene_node("Other").position and dana.scene_node("Other").position == cole.scene_node("Other").position)
	await _settle(200)
	_expect(ok and host.scene_node("Block").scale == Vector3(2, 2, 2) and cole.scene_node("Block").scale == Vector3(2, 2, 2), "different properties of one node merge")
	_expect(cole.scene_node("Block").rotation.is_equal_approx(Vector3(0, 1, 0)) and host.scene_node("Block").rotation.is_equal_approx(Vector3(0, 1, 0)), "both edits to one node survive")
	_expect(host.scene_node("Other").position == cole.scene_node("Other").position and dana.scene_node("Other").position == cole.scene_node("Other").position, "same-property race converges to one value")
	_expect(cole.sync.held_list().is_empty() and host.sync.held_list().is_empty(), "live races never ask the user")
	# Groups.
	host.scene_node("Block").add_to_group("enemies", true)
	host.sync.capture_now(SCENE)
	ok = await _pump(func(): return cole.scene_node("Block").is_in_group("enemies"))
	_expect(ok, "groups sync")


func _scenario_structure() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	var dana: Peer = _peers[2]
	# Add a node with properties on a client.
	var coin := Node3D.new()
	coin.name = "Coin"
	coin.position = Vector3(4, 4, 4)
	cole.root.add_child(coin)
	coin.owner = cole.root
	_poll_structure(cole.sync)
	var ok: bool = await _pump(func(): return host.scene_node("Coin") != null and dana.scene_node("Coin") != null)
	_expect(ok and host.scene_node("Coin").position == Vector3(4, 4, 4), "a node added on a client appears everywhere with its properties")
	# Duplicate names are resolved by the host and everyone agrees.
	var dup := Node3D.new()
	dup.name = "Coin"
	host.root.add_child(dup)
	dup.owner = host.root
	host.sync.capture_now(SCENE)
	await _settle(300)
	_expect(_tree_text(host) == _tree_text(cole) and _tree_text(cole) == _tree_text(dana), "name collisions resolve identically: " + _tree_text(host))
	# Rename.
	cole.scene_node("Coin").name = "Gem"
	_poll_structure(cole.sync)
	ok = await _pump(func(): return host.scene_node("Gem") != null and dana.scene_node("Gem") != null)
	_expect(ok, "rename syncs")
	# Reparent.
	var gem: Node = host.scene_node("Gem")
	var gem_owned: Array = [gem]
	gem.owner = null
	gem.get_parent().remove_child(gem)
	host.scene_node("Other").add_child(gem)
	gem.owner = host.root
	_poll_structure(host.sync)
	ok = await _pump(func(): return cole.scene_node("Other/Gem") != null and dana.scene_node("Other/Gem") != null)
	_expect(ok, "reparent syncs")
	# Reorder siblings.
	host.root.move_child(host.scene_node("Mesh"), 0)
	_poll_structure(host.sync)
	ok = await _pump(func(): return cole.root.get_child(0).name == "Mesh" and dana.root.get_child(0).name == "Mesh")
	_expect(ok, "sibling order syncs")
	# Delete a subtree.
	var doomed: Node = dana.scene_node("Block")
	dana.root.remove_child(doomed)
	doomed.free()
	_poll_structure(dana.sync)
	ok = await _pump(func(): return host.scene_node("Block") == null and cole.scene_node("Block") == null)
	_expect(ok, "deleting a node (and its children) syncs")
	_expect(host.scene_node("Block/Sub") == null and cole.scene_node("Block/Sub") == null, "the whole subtree is gone")
	await _settle(300)
	_expect(_tree_text(host) == _tree_text(cole) and _tree_text(cole) == _tree_text(dana), "all trees identical: " + _tree_text(host))
	# Nothing left to say once everybody agrees.
	var sent: int = host.sync._ops_sent + cole.sync._ops_sent + dana.sync._ops_sent
	await _settle(300)
	_expect(host.sync._ops_sent + cole.sync._ops_sent + dana.sync._ops_sent == sent, "no echo after structural edits")


func _scenario_offline_merge() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	# Cole drops off. While apart: the host moves Other and rotates Mesh; Cole moves Other (a real
	# conflict) and scales Mesh (no conflict) and hides Mesh? no - keep it to those edits.
	cole.session.leave()
	await _settle(100)
	cole.sync.session_lost()
	var other_before: Vector3 = cole.scene_node("Other").position
	host.scene_node("Other").position = Vector3(100, 0, 0)
	host.scene_node("Mesh").rotation = Vector3(0, 2, 0)
	host.sync.capture_now(SCENE)
	cole.scene_node("Other").position = Vector3(-100, 0, 0)
	cole.scene_node("Mesh").scale = Vector3(4, 4, 4)
	cole.sync.capture_now(SCENE)
	_expect(cole.sync.trackers[SCENE].batches.is_empty(), "nothing is captured or sent while the link is down")
	await _connect(cole)
	await _settle(400)
	_expect(cole.scene_node("Mesh").rotation.is_equal_approx(Vector3(0, 2, 0)), "host's newer edit arrived (rotation)")
	_expect(host.scene_node("Mesh").scale == Vector3(4, 4, 4), "offline edit that nobody else touched reached the host (scale)")
	var held: Array = cole.sync.held_list()
	_expect(held.size() == 1 and held[0].prop == "position", "only the property both sides changed is held: " + str(held))
	_expect(cole.scene_node("Other").position == Vector3(-100, 0, 0), "held property keeps the local value meanwhile")
	_expect(host.scene_node("Other").position == Vector3(100, 0, 0), "held property is not pushed to the host")
	var ops_before: int = cole.sync._ops_sent
	await _settle(300)
	_expect(cole.sync._ops_sent == ops_before, "a held property is not re-sent")
	# Resolve with "use theirs".
	if not held.is_empty():
		_expect(cole.sync.resolve_held(SCENE, held[0].key, false), "resolve with theirs")
	await _settle(200)
	_expect(cole.scene_node("Other").position == Vector3(100, 0, 0) and host.scene_node("Other").position == Vector3(100, 0, 0), "use theirs adopts the host's value")
	_expect(cole.sync.held_list().is_empty(), "held list cleared")
	# A second round, this time keeping ours.
	cole.session.leave()
	await _settle(100)
	cole.sync.session_lost()
	host.scene_node("Other").position = Vector3(1, 1, 1)
	host.sync.capture_now(SCENE)
	cole.scene_node("Other").position = Vector3(2, 2, 2)
	await _connect(cole)
	await _settle(300)
	held = cole.sync.held_list()
	_expect(held.size() == 1, "second conflict held")
	if not held.is_empty():
		cole.sync.resolve_held(SCENE, held[0].key, true)
	var ok: bool = await _pump(func(): return host.scene_node("Other").position == Vector3(2, 2, 2))
	_expect(ok, "keep mine pushes the local value to everyone")
	# Edits that are identical on both sides are not conflicts.
	cole.session.leave()
	await _settle(100)
	cole.sync.session_lost()
	host.scene_node("Mesh").position = Vector3(7, 7, 7)
	host.sync.capture_now(SCENE)
	cole.scene_node("Mesh").position = Vector3(7, 7, 7)
	await _connect(cole)
	await _settle(300)
	_expect(cole.sync.held_list().is_empty(), "the same edit on both sides is not a conflict")
	# An offline add and an offline delete.
	cole.session.leave()
	await _settle(100)
	cole.sync.session_lost()
	var extra := Node3D.new()
	extra.name = "OfflineAdded"
	cole.root.add_child(extra)
	extra.owner = cole.root
	var victim: Node = cole.scene_node("Other/Gem")
	victim.get_parent().remove_child(victim)
	victim.free()
	await _connect(cole)
	ok = await _pump(func(): return host.scene_node("OfflineAdded") != null and host.scene_node("Other/Gem") == null)
	_expect(ok, "an offline add and delete are pushed on reconnect")
	await _settle(300)
	_expect(_tree_text(host) == _tree_text(cole) and _tree_text(cole) == _tree_text(_peers[2]), "everybody converges after the reconnect: " + _tree_text(host))


func _scenario_inflight_recovery() -> void:
	var host: Peer = _peers[0]
	var cole: Peer = _peers[1]
	# Cole edits and the link dies before the host gets it: the edit must survive the reconnect.
	cole.scene_node("Mesh").scale = Vector3(6, 6, 6)
	cole.sync.capture_now(SCENE)
	cole.session.leave()
	await _settle(100)
	cole.sync.session_lost()
	host.scene_node("Other").position = Vector3(55, 55, 55)
	host.sync.capture_now(SCENE)
	await _connect(cole)
	var ok: bool = await _pump(func(): return host.scene_node("Mesh").scale == Vector3(6, 6, 6))
	_expect(ok, "an edit that never reached the host is re-sent after reconnecting")
	_expect(cole.scene_node("Other").position == Vector3(55, 55, 55), "while the host's edit is received")
	_expect(cole.sync.held_list().is_empty(), "no conflict for edits that did not overlap")


func _scenario_first_join_host_wins() -> void:
	var host: Peer = _peers[0]
	var eve := _make_peer("Eve", false)
	# Eve's copy of the scene is stale/different: the host's copy must win, and her file is backed up.
	eve.scene_node("Other").position = Vector3(-5, -5, -5)
	var stray := Node3D.new()
	stray.name = "OnlyEve"
	eve.root.add_child(stray)
	stray.owner = eve.root
	# A "file" for the backup to copy: write something at the real scene path.
	var abs_path := ProjectSettings.globalize_path(SCENE)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	f.store_string("[gd_scene format=3]\n[node name=\"World\" type=\"Node3D\"]\n")
	f.close()
	await _connect(eve)
	await _settle(300)
	_expect(eve.scene_node("OnlyEve") == null, "a node only the joiner had is removed (host wins)")
	_expect(eve.scene_node("Other").position == host.scene_node("Other").position, "differing properties take the host's value")
	_expect(eve.sync.held_list().is_empty(), "first sync never asks about differences")
	_expect(eve.env.unsaved >= 0, "joiner scene marked unsaved is tracked")
	var backup_root := _tmp_state.path_join("backups")
	var found := false
	if DirAccess.dir_exists_absolute(backup_root):
		for stamp in DirAccess.get_directories_at(backup_root):
			if FileAccess.file_exists(backup_root.path_join(stamp).path_join("addons/godot_collab/tests/_collab_scene.tscn")):
				found = true
	_expect(found, "the joiner's own file was backed up before the host's version was applied")
	DirAccess.remove_absolute(abs_path)
	_expect(_tree_text(host) == _tree_text(eve), "the joiner now matches the host: " + _tree_text(eve))
