@tool
extends RefCounted
## Live scene editing (the editor half; the host half is SceneDoc/HostDocs).
##
## For every open scene a Tracker gives each node a stable id and remembers the last synced state
## (the "cache"). Local edits are found by diffing the live tree against the cache and are sent to
## the host as small ops; the host orders them and broadcasts them to everybody. Ops from other
## people are applied straight to the nodes (outside your undo history, so Ctrl+Z only undoes your
## own work).
##
## Old changes never silently overwrite newer ones: while the link is down the cache keeps the last
## state both sides agreed on. When the link returns, every property is merged three ways
## (agreed state / what you have / what the host has now). Only properties that BOTH sides changed
## differently are held for you to decide ("Keep mine" / "Use theirs"); everything else merges.
##
## The tracker design follows the MIT-licensed godot-coop add-on (see NOTICE.md).

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")
const Wire := preload("res://addons/godot_collab/core/wire.gd")

signal held_changed()
signal scene_changed(path: String)
signal remote_selection_changed()

const SKIP_PROPS := ["name", "owner", "scene_file_path", "_import_path", "multiplayer"]
const SELECTION_POLL_MS := 80
const STRUCTURE_POLL_MS := 250
const ROLLING_PER_FRAME := 30
const FULL_DIFF_LIMIT := 400
const CHURN_LIMIT := 6
const CHURN_GAP_MS := 400
const CHURN_QUIET_MS := 1500
const ABSENT := "\u0001absent"


class Tracker:
	extends RefCounted
	var path := ""
	var root: Node = null
	var root_iid := 0
	var ids := {}             # instance id -> node id
	var nodes := {}           # node id -> instance id
	var cache := {}           # node id -> record {p, n, c, inst, props, groups, conns}
	var order := {}           # parent id -> [child ids] (last synced order)
	var ready := false        # a document state has been received and applied
	var live := false         # the host knows we have this scene open right now
	var synced_once := false  # we have shared a state with the host before (enables 3-way merges)
	var epoch := ""
	var rev := 0
	var pending := {}         # "id/key" -> count of unacknowledged local changes
	var batches := {}         # cseq -> {"ops": [], "before": {}, "keys": []}
	var wire = null
	var graveyard: Array = []
	var failed: Array = []    # [id, prop, wire] values that could not be applied yet (missing file)
	var held := {}            # "id/key" -> {"mine", "theirs", "node", "prop"}
	var rolling := 0
	var unsaved_pending := false
	var missing_files := false
	var open_sent_ms := 0
	var resync_at := 0


var session
var env
var trackers: Dictionary = {}
var applying := false
var _capture_due := false
var _structure_due := false
var _last_sel_poll := 0
var _last_structure_poll := 0
var _last_refresh := 0
var _class_defaults := {}
var _script_props := {}
var _instance_base := {}
var _connected_signals := false
var _churn := {}
var _next_cseq := int(Time.get_unix_time_from_system() * 1000.0)
var _ops_sent := 0
var _ops_received := 0
var remote_selections: Dictionary = {} # scene path -> peer id -> {nodes, name, color, seen}
var _local_selection_path := ""
var _local_selection_signature := ""
var _last_selection_send := 0


func setup(p_session, p_env) -> void:
	session = p_session
	env = p_env
	var ur: Object = env.undo_redo()
	if ur != null:
		ur.version_changed.connect(_on_undo_version)
		ur.history_changed.connect(_on_undo_version)
	var tree: SceneTree = env.tree()
	tree.node_added.connect(_on_tree_node_added)
	tree.node_removed.connect(_on_tree_node_removed)
	tree.node_renamed.connect(_on_tree_node_renamed)
	_connected_signals = true


func teardown() -> void:
	if _connected_signals:
		var ur: Object = env.undo_redo()
		if ur != null and ur.version_changed.is_connected(_on_undo_version):
			ur.version_changed.disconnect(_on_undo_version)
			ur.history_changed.disconnect(_on_undo_version)
		var tree: SceneTree = env.tree()
		if tree.node_added.is_connected(_on_tree_node_added):
			tree.node_added.disconnect(_on_tree_node_added)
			tree.node_removed.disconnect(_on_tree_node_removed)
			tree.node_renamed.disconnect(_on_tree_node_renamed)
		_connected_signals = false
	for path in trackers:
		_free_graveyard(trackers[path], true)
	trackers.clear()


func _online() -> bool:
	return session != null and session.joined_ok and session.is_online()


# --- session lifecycle ----------------------------------------------------------------------------

func session_started() -> void:
	trackers.clear()
	_refresh_open_scenes(true)


## The link dropped: the cache stays as the last state both sides agreed on.
func session_lost() -> void:
	for path in trackers:
		trackers[path].live = false
	Log.info("scene", "Link lost: %d scene(s) will be merged with the host's copy when it returns" % trackers.size())


func session_resumed() -> void:
	for path in trackers:
		var tr: Tracker = trackers[path]
		tr.live = false
		_send_open(tr)


func status_text() -> String:
	var live := 0
	for path in trackers:
		if trackers[path].live:
			live += 1
	return "%d scene(s) tracked, %d live" % [trackers.size(), live]


# --- bookkeeping -------------------------------------------------------------------------------------------

func _on_undo_version() -> void:
	if not applying:
		_capture_due = true


func _in_edited_scene(node: Node) -> bool:
	for path in trackers:
		var root: Node = trackers[path].root
		if is_instance_valid(root) and (node == root or root.is_ancestor_of(node)):
			return true
	return false


func _on_tree_node_added(node: Node) -> void:
	if not applying and _in_edited_scene(node):
		_structure_due = true


func _on_tree_node_removed(node: Node) -> void:
	if not applying and _in_edited_scene(node):
		_structure_due = true


func _on_tree_node_renamed(node: Node) -> void:
	if not applying and _in_edited_scene(node):
		_structure_due = true


func current_tracker() -> Tracker:
	var root: Node = env.edited_root()
	if root == null:
		return null
	var tr: Tracker = trackers.get(root.scene_file_path)
	if tr != null and tr.root == root:
		return tr
	return null


func _new_tracker(path: String, root: Node) -> Tracker:
	var tr := Tracker.new()
	tr.path = path
	tr.root = root
	tr.root_iid = root.get_instance_id()
	tr.wire = Wire.new()
	tr.wire.node_to_id = func(n: Node) -> String: return String(tr.ids.get(n.get_instance_id(), ""))
	tr.wire.id_to_node = func(id: String) -> Node: return _node_by_id(tr, id)
	return tr


func _free_graveyard(tr: Tracker, now: bool = false) -> void:
	for n in tr.graveyard:
		if is_instance_valid(n) and n.get_parent() == null:
			if now:
				n.free()
			else:
				n.queue_free()
	tr.graveyard.clear()


## Keeps trackers in line with the editor's open scene tabs (opens, closes, reloads).
func _refresh_open_scenes(force: bool = false) -> void:
	var now := Util.now_ms()
	if not force and now - _last_refresh < 400:
		return
	_last_refresh = now
	var open := {}
	for root in env.open_roots():
		if root == null or not is_instance_valid(root):
			continue
		var path: String = root.scene_file_path
		if path.is_empty() or not path.begins_with("res://"):
			continue
		open[path] = root
	for path in trackers.keys():
		if not open.has(path):
			_close_tracker(path)
	for path in open:
		var root: Node = open[path]
		var tr: Tracker = trackers.get(path)
		if tr == null:
			if not _online():
				continue
			tr = _new_tracker(path, root)
			trackers[path] = tr
			Log.info("scene", "Tracking %s" % path)
			_send_open(tr)
		elif tr.root_iid != root.get_instance_id() or not is_instance_valid(tr.root):
			# The scene was reloaded from disk: start over with the new root and let the host's copy win.
			Log.info("scene", "%s was reloaded; resyncing" % path)
			_free_graveyard(tr)
			var fresh := _new_tracker(path, root)
			trackers[path] = fresh
			if _online():
				_send_open(fresh)


func _close_tracker(path: String) -> void:
	var tr: Tracker = trackers.get(path)
	trackers.erase(path)
	if tr != null:
		_free_graveyard(tr)
		Log.info("scene", "Stopped tracking %s" % path)
	if _online():
		session.send({"t": "sc_close", "path": path})


func _send_open(tr: Tracker) -> void:
	if not _online():
		return
	var snapshot := _snapshot(tr)
	tr.open_sent_ms = Util.now_ms()
	tr.ready = tr.ready and tr.synced_once
	session.send({"t": "sc_open", "path": tr.path, "snapshot": snapshot})
	Log.debug("scene", "Opened %s with the host (%d nodes)" % [tr.path, snapshot.size()])


# --- node ids ----------------------------------------------------------------------------------------------------

func _node_by_id(tr: Tracker, id: String) -> Node:
	if not tr.nodes.has(id):
		return null
	var obj: Object = instance_from_id(tr.nodes[id])
	if obj == null or not is_instance_valid(obj) or not obj is Node:
		return null
	return obj


func _register(tr: Tracker, node: Node, id: String) -> void:
	var old: Variant = tr.nodes.get(id)
	if old != null and tr.ids.get(old) == id:
		tr.ids.erase(old)
	var iid := node.get_instance_id()
	var previous: Variant = tr.ids.get(iid)
	if previous != null and previous != id and tr.nodes.get(previous) == iid:
		tr.nodes.erase(previous)
	tr.ids[iid] = id
	tr.nodes[id] = iid


func id_of(tr: Tracker, node: Node, create: bool = true) -> String:
	var iid := node.get_instance_id()
	if tr.ids.has(iid):
		return tr.ids[iid]
	if not create:
		return ""
	var id := Util.random_hex(6)
	_register(tr, node, id)
	return id


## Root + every node saved in this scene, parents before children, siblings in order.
func _synced_nodes(tr: Tracker) -> Array:
	var out := []
	if tr.root == null or not is_instance_valid(tr.root):
		return out
	var stack: Array = [tr.root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		var kids := n.get_children()
		for i in range(kids.size() - 1, -1, -1):
			var c: Node = kids[i]
			if c.owner == tr.root:
				stack.append(c)
	return out


# --- describing a node ------------------------------------------------------------------------------------------

func _class_default(cls: String, prop: String) -> Variant:
	var d: Dictionary = _class_defaults.get(cls, {})
	if d.is_empty():
		_class_defaults[cls] = d
	if not d.has(prop):
		d[prop] = ClassDB.class_get_property_default_value(cls, prop)
	return d[prop]


func _script_prop_set(script: Script) -> Dictionary:
	var key := script.get_instance_id()
	if _script_props.has(key):
		return _script_props[key]
	var s := {}
	for p in script.get_script_property_list():
		s[p.name] = true
	_script_props[key] = s
	return s


func _instance_info(path: String) -> Dictionary:
	if _instance_base.has(path):
		return _instance_base[path]
	var info := {"props": {}, "groups": []}
	if ResourceLoader.exists(path):
		var ps: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if ps is PackedScene:
			var st: SceneState = ps.get_state()
			if st.get_node_count() > 0:
				for i in st.get_node_property_count(0):
					info.props[String(st.get_node_property_name(0, i))] = st.get_node_property_value(0, i)
				for g in st.get_node_groups(0):
					info.groups.append(String(g))
	_instance_base[path] = info
	return info


func invalidate_instance_cache(path: String = "") -> void:
	if path.is_empty():
		_instance_base.clear()
	else:
		_instance_base.erase(path)
	_script_props.clear()


func _is_instance(tr: Tracker, node: Node) -> bool:
	return node != tr.root and not node.scene_file_path.is_empty()


## What a property is when nobody touched it (instanced scene's value, script default, class default).
func _base_value(tr: Tracker, node: Node, prop: String) -> Variant:
	if node is Node3D:
		if prop == "position" or prop == "rotation":
			return Vector3.ZERO
		if prop == "scale":
			return Vector3.ONE
	if _is_instance(tr, node):
		var info := _instance_info(node.scene_file_path)
		if info.props.has(prop):
			return info.props[prop]
	var scr: Variant = node.get_script()
	if scr is Script and _script_prop_set(scr).has(prop):
		return scr.get_property_default_value(prop)
	return _class_default(node.get_class(), prop)


func _props_of(tr: Tracker, node: Node) -> Dictionary:
	var out := {}
	for p in node.get_property_list():
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE):
			continue
		var name: String = p.name
		if name in SKIP_PROPS:
			continue
		var v: Variant = node.get(name)
		if name == "script":
			if v != null:
				out[name] = tr.wire.to_wire(v)
			continue
		var base: Variant = _base_value(tr, node, name)
		if Util.same(v, base):
			continue
		out[name] = tr.wire.to_wire(v)
	# Node3D stores one combined "transform"; syncing position, rotation and scale separately lets
	# two people change different parts of the same node's transform without conflicting.
	if node is Node3D and node.rotation_edit_mode == Node3D.ROTATION_EDIT_MODE_EULER:
		out.erase("transform")
		var pos: Vector3 = node.position
		var rot: Vector3 = node.rotation
		var scl: Vector3 = node.scale
		if pos != Vector3.ZERO:
			out["position"] = pos
		if rot != Vector3.ZERO:
			out["rotation"] = rot
		if scl != Vector3.ONE:
			out["scale"] = scl
	return out


func _groups_of(tr: Tracker, node: Node) -> Array:
	var out := []
	var base: Array = _instance_info(node.scene_file_path).groups if _is_instance(tr, node) else []
	for g in node.get_groups():
		var s := String(g)
		if s.begins_with("_") or base.has(s):
			continue
		out.append(s)
	out.sort()
	return out


func _conns_of(tr: Tracker, node: Node) -> Array:
	var out := []
	for c in node.get_incoming_connections():
		var flags := int(c.flags)
		if not (flags & CONNECT_PERSIST):
			continue
		var sig: Signal = c.signal
		var src: Object = sig.get_object()
		if not src is Node or not tr.ids.has(src.get_instance_id()):
			continue
		var cb: Callable = c.callable
		if cb.get_object() != node:
			continue
		out.append([
			tr.ids[src.get_instance_id()], String(sig.get_name()), String(cb.get_method()),
			flags & (CONNECT_DEFERRED | CONNECT_ONE_SHOT | CONNECT_APPEND_SOURCE_OBJECT),
			tr.wire.to_wire(cb.get_bound_arguments()), cb.get_unbound_arguments_count()
		])
	out.sort_custom(func(a, b): return str(a) < str(b))
	return out


func _record(tr: Tracker, node: Node, parent_id: String) -> Dictionary:
	return {
		"p": parent_id, "n": String(node.name), "c": node.get_class(),
		"inst": node.scene_file_path if _is_instance(tr, node) else "",
		"props": _props_of(tr, node), "groups": _groups_of(tr, node), "conns": _conns_of(tr, node),
	}


## Full snapshot (parent-first, with sibling indices). Read-only: the cache is only ever replaced
## by a document state from the host, so it always means "the last state both sides agreed on".
func _snapshot(tr: Tracker) -> Array:
	var list := []
	var nodes := _synced_nodes(tr)
	for n in nodes:
		id_of(tr, n)
	var counters := {}
	for n in nodes:
		var id := id_of(tr, n)
		var pid := "" if n == tr.root else id_of(tr, n.get_parent())
		var si: int = counters.get(pid, 0)
		counters[pid] = si + 1
		var out := _record(tr, n, pid)
		out["id"] = id
		out["si"] = si
		list.append(out)
	return list


## Host side: the snapshot to create a document from. Uses the host's live scene when it is open,
## otherwise the file on disk (loaded detached, never shown).
func provide_snapshot(path: String) -> Variant:
	var tr: Tracker = trackers.get(path)
	if tr != null and is_instance_valid(tr.root):
		return _snapshot(tr)
	if not ResourceLoader.exists(path):
		return null
	var ps: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not ps is PackedScene:
		return null
	var inst: Node = ps.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if inst == null:
		return null
	var temp := _new_tracker(path, inst)
	var snap := _snapshot(temp)
	inst.free()
	return snap


# --- detecting local edits ----------------------------------------------------------------------------------------

func process() -> void:
	if trackers.is_empty() and not _online():
		return
	_refresh_open_scenes()
	_retry_open()
	var now := Util.now_ms()
	_sync_local_selection(now)
	_prune_remote_selections(now)
	var tr := current_tracker()
	if tr != null and tr.unsaved_pending:
		tr.unsaved_pending = false
		env.mark_unsaved()
	if tr == null or not tr.ready or not tr.live or applying:
		return
	# The editor's tree and undo signals cover normal edits, but some editor plugins and
	# scripted tree changes do not emit them consistently. Periodically diff the active scene
	# so add/remove/rename/reparent/reorder changes still reach collaborators.
	if now - _last_structure_poll >= STRUCTURE_POLL_MS:
		_last_structure_poll = now
		_structure_due = true
	var dragging: bool = env.is_dragging()
	var ops := []
	if _structure_due or _capture_due:
		var full := _capture_due and tr.cache.size() <= FULL_DIFF_LIMIT
		ops.append_array(_diff_structure(tr))
		var targets := {}
		for n in env.selected_nodes():
			targets[n.get_instance_id()] = n
		if full:
			for n in _synced_nodes(tr):
				targets[n.get_instance_id()] = n
		ops.append_array(_diff_props(tr, targets.values(), not _capture_due and not dragging))
		_structure_due = false
		_capture_due = false
		_last_sel_poll = now
	elif now - _last_sel_poll > SELECTION_POLL_MS:
		_last_sel_poll = now
		var sel: Array = env.selected_nodes()
		if not sel.is_empty():
			ops.append_array(_diff_props(tr, sel, not dragging))
	else:
		var all := _synced_nodes(tr)
		if not all.is_empty():
			var chunk := []
			for i in mini(ROLLING_PER_FRAME, all.size()):
				tr.rolling = (tr.rolling + 1) % all.size()
				chunk.append(all[tr.rolling])
			ops.append_array(_diff_props(tr, chunk, not dragging))
	if not ops.is_empty():
		_submit(tr, ops)


func _retry_open() -> void:
	if not _online():
		return
	var now := Util.now_ms()
	for path in trackers:
		var tr: Tracker = trackers[path]
		if not tr.live and tr.open_sent_ms > 0 and now - tr.open_sent_ms > 4000 and tr.resync_at == 0:
			tr.resync_at = now
			Log.warn("scene", "No answer from the host for %s; asking again" % path)
			_send_open(tr)
			tr.resync_at = 0
		if tr.missing_files and tr.live:
			tr.missing_files = false
			session.send({"t": "sc_get", "path": path})
		if not tr.failed.is_empty():
			_retry_failed(tr)


## Captures local edits that are still waiting for this frame's diff, so they count as ours
## (pending) before a teammate's changes are applied on top.
func _capture_pending(tr: Tracker) -> void:
	if tr != current_tracker() or not tr.ready or not tr.live or applying or not (_structure_due or _capture_due):
		return
	var ops := _diff_structure(tr)
	var targets := {}
	for n in env.selected_nodes():
		targets[n.get_instance_id()] = n
	if _capture_due and tr.cache.size() <= FULL_DIFF_LIMIT:
		for n in _synced_nodes(tr):
			targets[n.get_instance_id()] = n
	ops.append_array(_diff_props(tr, targets.values()))
	_structure_due = false
	_capture_due = false
	if not ops.is_empty():
		_submit(tr, ops)


## Forces a full comparison of the live tree against the cache (used after reconciling and in tests).
func capture_now(path: String) -> void:
	var tr: Tracker = trackers.get(path)
	if tr == null or not tr.ready or not tr.live or applying:
		return
	var ops := _diff_structure(tr)
	ops.append_array(_diff_props(tr, _synced_nodes(tr)))
	if not ops.is_empty():
		_submit(tr, ops)


func _volatile(key: String, value: Variant, passive: bool) -> bool:
	var now := Util.now_ms()
	var e: Dictionary = _churn.get(key, {})
	if e.is_empty() or not passive:
		_churn[key] = {"v": value, "last": now, "n": 0}
		return false
	if not Wire.same(value, e.v):
		e.n = int(e.n) + 1 if now - int(e.last) < CHURN_GAP_MS else 1
		e.v = value
		e.last = now
	return int(e.n) >= CHURN_LIMIT and now - int(e.last) < CHURN_QUIET_MS


func _diff_structure(tr: Tracker) -> Array:
	var ops := []
	var nodes := _synced_nodes(tr)
	var local_order := {}
	var parent_of := {}
	var seen := {}
	for n in nodes:
		var id := id_of(tr, n)
		var pid := "" if n == tr.root else id_of(tr, n.get_parent())
		seen[id] = true
		parent_of[id] = pid
		if not local_order.has(pid):
			local_order[pid] = []
		local_order[pid].append(id)
	var sim := {}
	for pid in tr.order:
		sim[pid] = tr.order[pid].duplicate()
	# Deletions (only top-most deleted nodes). Children that are still in the scene stay: "Change
	# Type" and similar replace a node and move its children onto the replacement.
	var dels := []
	var gone := {}
	for id in tr.cache.keys():
		if seen.has(id) or not tr.cache.has(id):
			continue
		var p := String(tr.cache[id].p)
		if not tr.cache.has(p) or seen.has(p) or p.is_empty():
			var del_op := {"k": "del", "id": id, "_b": {id + "/$x": tr.cache[id].duplicate(true)}}
			dels.append(del_op)
			if not gone.has(p):
				gone[p] = {}
			gone[p][String(tr.cache[id].n)] = true
		_forget_subtree(tr, id, sim, seen)
	var renames := []
	for n in nodes:
		var id := id_of(tr, n)
		var pid: String = parent_of[id]
		var si: int = local_order[pid].find(id)
		if not tr.cache.has(id):
			var rec := _record(tr, n, pid)
			var op := rec.duplicate(true)
			op["k"] = "add"
			op["id"] = id
			op["si"] = si
			op["_b"] = {id + "/$x": ABSENT}
			ops.append(op)
			tr.cache[id] = rec
			if not sim.has(pid):
				sim[pid] = []
			sim[pid].insert(mini(si, sim[pid].size()), id)
			if gone.get(pid, {}).has(rec.n):
				renames.append({"k": "name", "id": id, "n": rec.n})
			continue
		var old: Dictionary = tr.cache[id]
		if String(old.p) != pid:
			ops.append({"k": "move", "id": id, "p": pid, "si": si, "_b": {id + "/$p": String(old.p)}})
			if sim.has(old.p):
				sim[old.p].erase(id)
			if not sim.has(pid):
				sim[pid] = []
			sim[pid].insert(mini(si, sim[pid].size()), id)
			old.p = pid
			if gone.get(pid, {}).has(String(n.name)):
				renames.append({"k": "name", "id": id, "n": String(n.name)})
		if String(old.n) != String(n.name):
			ops.append({"k": "name", "id": id, "n": String(n.name), "_b": {id + "/$n": String(old.n)}})
			old.n = String(n.name)
	ops.append_array(dels)
	for pid in local_order:
		var want: Array = local_order[pid]
		var have: Array = sim.get(pid, [])
		if have != want or gone.has(pid):
			for i in want.size():
				ops.append({"k": "move", "id": want[i], "p": pid, "si": i})
	ops.append_array(renames)
	tr.order = local_order
	return ops


func _forget_subtree(tr: Tracker, id: String, sim: Dictionary, keep: Dictionary = {}) -> void:
	if not tr.cache.has(id) or keep.has(id):
		return
	var p := String(tr.cache[id].p)
	if sim.has(p):
		sim[p].erase(id)
	for cid in tr.order.get(id, []):
		_forget_subtree(tr, cid, sim, keep)
	sim.erase(id)
	tr.cache.erase(id)
	tr.order.erase(id)
	var iid: Variant = tr.nodes.get(id)
	tr.nodes.erase(id)
	if iid != null and tr.ids.get(iid) == id:
		tr.ids.erase(iid)


func _diff_props(tr: Tracker, nodes: Array, passive: bool = false) -> Array:
	var ops := []
	for n in nodes:
		if not n is Node or not is_instance_valid(n) or not tr.ids.has(n.get_instance_id()):
			continue
		var id: String = tr.ids[n.get_instance_id()]
		if not tr.cache.has(id):
			continue
		var old: Dictionary = tr.cache[id]
		var props := _props_of(tr, n)
		var changed := {}
		var reset := []
		var old_props: Dictionary = old.props
		for k in props:
			if tr.held.has(id + "/" + String(k)):
				continue
			if not old_props.has(k) or not Wire.same(props[k], old_props[k]):
				if not _volatile(id + "/" + String(k), props[k], passive):
					changed[k] = props[k]
		for k in old_props:
			if not props.has(k) and not tr.held.has(id + "/" + String(k)):
				reset.append(k)
		if not changed.is_empty() or not reset.is_empty():
			var before := {}
			for k in changed:
				before[id + "/" + String(k)] = old_props.get(k, ABSENT)
			for k in reset:
				before[id + "/" + String(k)] = old_props[k]
			ops.append({"k": "set", "id": id, "props": changed, "reset": reset, "_b": before})
			for k in changed:
				old_props[k] = changed[k]
			for k in reset:
				old_props.erase(k)
		var groups := _groups_of(tr, n)
		if groups != Array(old.groups):
			ops.append({"k": "groups", "id": id, "groups": groups, "_b": {id + "/$g": Array(old.groups)}})
			old.groups = groups
		var conns := _conns_of(tr, n)
		if conns != Array(old.conns):
			ops.append({"k": "conns", "id": id, "conns": conns, "_b": {id + "/$c": Array(old.conns)}})
			old.conns = conns
	return ops


static func _op_keys(op: Dictionary) -> Array:
	var id := String(op.get("id", ""))
	match String(op.get("k", "")):
		"add", "del":
			return [id + "/$x"]
		"move":
			return [id + "/$p"]
		"name":
			return [id + "/$n"]
		"groups":
			return [id + "/$g"]
		"conns":
			return [id + "/$c"]
		"set":
			var keys := []
			for k in op.get("props", {}):
				keys.append(id + "/" + String(k))
			for k in op.get("reset", []):
				keys.append(id + "/" + String(k))
			return keys
	return []


func _submit(tr: Tracker, ops: Array) -> void:
	_next_cseq += 1
	var cseq := _next_cseq
	var keys := []
	var before := {}
	for op in ops:
		keys.append_array(_op_keys(op))
		var b: Variant = op.get("_b")
		if b is Dictionary:
			for k in b:
				if not before.has(k):
					before[k] = b[k]
		op.erase("_b")
	for k in keys:
		tr.pending[k] = int(tr.pending.get(k, 0)) + 1
	tr.batches[cseq] = {"ops": ops, "keys": keys, "before": before}
	_ops_sent += ops.size()
	if _online():
		session.send({"t": "sc_ops", "path": tr.path, "epoch": tr.epoch, "cseq": cseq, "ops": ops})
		Log.debug("scene", "%s: sent %d op(s): %s" % [tr.path.get_file(), ops.size(), _describe_ops(tr, ops)])


func _describe_ops(tr: Tracker, ops: Array) -> String:
	var parts := PackedStringArray()
	for op in ops.slice(0, 4):
		var id := String(op.get("id", ""))
		var label := String(tr.cache[id].n) if tr.cache.has(id) else id
		var k := String(op.get("k", ""))
		if k == "set":
			var names := PackedStringArray()
			for p in op.get("props", {}):
				names.append("%s=%s" % [p, Wire.brief(op.props[p], 28)])
			for p in op.get("reset", []):
				names.append("%s reset" % p)
			parts.append("%s.%s" % [label, ",".join(names)])
		else:
			parts.append("%s %s" % [k, label])
	if ops.size() > 4:
		parts.append("+%d more" % (ops.size() - 4))
	return "; ".join(parts)


func _ack(tr: Tracker, cseq: int) -> Dictionary:
	var b: Dictionary = tr.batches.get(cseq, {})
	tr.batches.erase(cseq)
	for k in b.get("keys", []):
		var n := int(tr.pending.get(k, 0)) - 1
		if n <= 0:
			tr.pending.erase(k)
		else:
			tr.pending[k] = n
	return b


# --- messages from the host --------------------------------------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	var t := String(m.get("t", ""))
	var path := String(m.get("path", ""))
	if t == "sc_selection":
		_on_remote_selection(m)
		return
	var tr: Tracker = trackers.get(path)
	if tr == null:
		return
	match t:
		"sc_state":
			_on_state(tr, m)
		"sc_ops":
			if not tr.ready:
				return
			tr.rev = int(m.get("rev", tr.rev))
			var ops: Array = m.get("ops", [])
			if String(m.get("by", "")) == session.my_uid:
				_ack(tr, int(m.get("cseq", 0)))
				_apply_fixups(tr, ops)
			else:
				_capture_pending(tr)
				_ops_received += ops.size()
				Log.debug("scene", "%s: %d op(s) from %s: %s" % [path.get_file(), ops.size(), session.uid_name(String(m.get("by", ""))), _describe_ops(tr, ops)])
				_apply_remote(tr, ops)
		"sc_reject":
			_ack(tr, int(m.get("cseq", 0)))
			Log.warn("scene", "Host rejected an edit to %s (%s); re-syncing it" % [path, String(m.get("reason", "?"))])
			session.send({"t": "sc_get", "path": path})


func _sync_local_selection(now: int) -> void:
	if not _online():
		return
	var tr := current_tracker()
	var path := ""
	var selected_paths: Array = []
	if tr != null and tr.ready and tr.live:
		path = tr.path
		for node in env.selected_nodes():
			if node == tr.root or tr.root.is_ancestor_of(node):
				selected_paths.append("." if node == tr.root else String(tr.root.get_path_to(node)))
	selected_paths.sort()
	if path != _local_selection_path:
		if not _local_selection_path.is_empty():
			session.send({"t": "sc_selection", "path": _local_selection_path, "nodes": []})
		_local_selection_path = path
		_local_selection_signature = ""
	if path.is_empty():
		return
	var signature := JSON.stringify(selected_paths)
	if signature == _local_selection_signature and now - _last_selection_send < 1000:
		return
	_local_selection_signature = signature
	_last_selection_send = now
	session.send({"t": "sc_selection", "path": path, "nodes": selected_paths})


func _on_remote_selection(m: Dictionary) -> void:
	var path := String(m.get("path", ""))
	var pid := int(m.get("pid", 0))
	if pid == 0 or pid == int(session.my_pid) or not trackers.has(path):
		return
	var peers: Dictionary = remote_selections.get(path, {})
	var nodes: Variant = m.get("nodes", [])
	if not nodes is Array or nodes.is_empty():
		peers.erase(pid)
	else:
		var safe_nodes: Array[String] = []
		for raw in nodes:
			var node_path := String(raw)
			if node_path == "." or not node_path.is_empty() and not node_path.begins_with("/") and not node_path.contains(".."):
				safe_nodes.append(node_path)
		peers[pid] = {
			"pid": pid,
			"nodes": safe_nodes,
			"name": String(m.get("name", "Teammate")),
			"color": Color.html(String(m.get("color", "66ccff"))),
			"seen": Util.now_ms(),
		}
	if peers.is_empty():
		remote_selections.erase(path)
	else:
		remote_selections[path] = peers
	remote_selection_changed.emit()


func _prune_remote_selections(now: int) -> void:
	var changed := false
	for path in remote_selections.keys():
		var peers: Dictionary = remote_selections[path]
		for pid in peers.keys():
			if now - int(peers[pid].get("seen", 0)) > 5000:
				peers.erase(pid)
				changed = true
		if peers.is_empty():
			remote_selections.erase(path)
	if changed:
		remote_selection_changed.emit()


func has_remote_selections() -> bool:
	return not remote_selections.is_empty()


func _remote_selected_nodes(path: String, root: Node) -> Array:
	var out := []
	for peer in remote_selections.get(path, {}).values():
		for raw in peer.get("nodes", []):
			var node: Node = root if String(raw) == "." else root.get_node_or_null(NodePath(String(raw)))
			if node != null and (node == root or root.is_ancestor_of(node)):
				out.append({"node": node, "name": String(peer.name), "color": peer.color})
	return out


func draw_remote_selection_2d(overlay: Control) -> void:
	var tr := current_tracker()
	if tr == null or not is_instance_valid(tr.root):
		return
	for entry in _remote_selected_nodes(tr.path, tr.root):
		var node: Node = entry.node
		if not node is CanvasItem:
			continue
		var color: Color = entry.color
		var rect := Rect2()
		if node is Control:
			var control := node as Control
			rect = control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)
		elif node is Sprite2D:
			var sprite := node as Sprite2D
			rect = sprite.get_global_transform_with_canvas() * sprite.get_rect()
		else:
			var canvas_item := node as CanvasItem
			var point := canvas_item.get_global_transform_with_canvas().origin
			rect = Rect2(point - Vector2(10, 10), Vector2(20, 20))
		if rect.size.x < 2 or rect.size.y < 2:
			rect = Rect2(rect.position - Vector2(10, 10), Vector2(20, 20))
		overlay.draw_rect(rect, color, false, 2.0)
		var font := overlay.get_theme_default_font()
		overlay.draw_string(font, rect.position + Vector2(2, -4), String(entry.name), HORIZONTAL_ALIGNMENT_LEFT, -1, overlay.get_theme_default_font_size(), color)


func draw_remote_selection_3d(overlay: Control) -> void:
	var tr := current_tracker()
	if tr == null or not is_instance_valid(tr.root):
		return
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	var camera := viewport.get_camera_3d() if viewport != null else null
	if camera == null:
		return
	for pid in session.peers:
		if int(pid) == int(session.my_pid):
			continue
		var peer: Dictionary = session.peers[pid]
		if String(peer.get("scene", "")) != tr.path or not bool(peer.get("view_3d", false)) or not peer.get("camera") is Transform3D:
			continue
		var peer_camera: Transform3D = peer.camera
		if camera.is_position_behind(peer_camera.origin):
			continue
		var origin := camera.unproject_position(peer_camera.origin)
		var forward := -peer_camera.basis.z.normalized()
		var tip_world := peer_camera.origin + forward * 2.0
		var tip := camera.unproject_position(tip_world) if not camera.is_position_behind(tip_world) else origin + Vector2(0, -18)
		var peer_color: Color = session.peer_color(int(pid))
		overlay.draw_line(origin, tip, peer_color, 3.0, true)
		overlay.draw_circle(origin, 6.0, peer_color)
		overlay.draw_arc(origin, 9.0, 0.0, TAU, 20, Color(peer_color, 0.8), 2.0, true)
		overlay.draw_string(overlay.get_theme_default_font(), origin + Vector2(9, -8), session.peer_name(int(pid)), HORIZONTAL_ALIGNMENT_LEFT, -1, overlay.get_theme_default_font_size(), peer_color)
	for entry in _remote_selected_nodes(tr.path, tr.root):
		var node: Node = entry.node
		if not node is Node3D:
			continue
		var target := node as Node3D
		var points: Array[Vector2] = []
		if target is GeometryInstance3D:
			var geometry := target as GeometryInstance3D
			var bounds := geometry.get_aabb()
			for x in [bounds.position.x, bounds.end.x]:
				for y in [bounds.position.y, bounds.end.y]:
					for z in [bounds.position.z, bounds.end.z]:
						var world := target.global_transform * Vector3(x, y, z)
						if not camera.is_position_behind(world):
							points.append(camera.unproject_position(world))
		if points.is_empty() and not camera.is_position_behind(target.global_position):
			var center := camera.unproject_position(target.global_position)
			points = [center - Vector2(10, 10), center + Vector2(10, 10)]
		if points.is_empty():
			continue
		var left := points[0].x
		var top := points[0].y
		var right := left
		var bottom := top
		for point in points:
			left = minf(left, point.x)
			top = minf(top, point.y)
			right = maxf(right, point.x)
			bottom = maxf(bottom, point.y)
		var rect := Rect2(Vector2(left, top), Vector2(maxf(8.0, right - left), maxf(8.0, bottom - top)))
		var color: Color = entry.color
		overlay.draw_rect(rect, color, false, 2.0)
		overlay.draw_string(overlay.get_theme_default_font(), rect.position + Vector2(2, -4), String(entry.name), HORIZONTAL_ALIGNMENT_LEFT, -1, overlay.get_theme_default_font_size(), color)


func _on_state(tr: Tracker, m: Dictionary) -> void:
	if bool(m.get("missing", false)):
		Log.warn("scene", "The host has no copy of %s yet; will retry" % tr.path)
		tr.live = false
		return
	var nodes: Array = m.get("nodes", [])
	var acked := int(m.get("acked", 0))
	# Batches the host already processed are part of its state; the rest were never applied there.
	var overrides := {}
	var cs: Array = tr.batches.keys()
	cs.sort()
	for c in cs:
		if int(c) <= acked:
			_ack(tr, c)
			continue
		for k in tr.batches[c].get("before", {}):
			if not overrides.has(k):
				overrides[k] = tr.batches[c].before[k]
	tr.batches.clear()
	tr.pending.clear()
	tr.epoch = String(m.get("epoch", ""))
	tr.rev = int(m.get("rev", 0))
	var first := not tr.synced_once
	var stats := _reconcile(tr, nodes, first, overrides)
	tr.ready = true
	tr.live = true
	tr.synced_once = true
	if stats.changed:
		tr.unsaved_pending = true
		if first:
			_backup_scene(tr.path)
	Log.info("scene", "%s: synced with the host (rev %d, %d nodes)%s%s" % [
		tr.path, tr.rev, nodes.size(),
		"" if not stats.changed else ", %d change(s) pulled in" % stats.changes,
		"" if tr.held.is_empty() else ", %d held for your decision" % tr.held.size()])
	scene_changed.emit(tr.path)
	# Anything of ours that the host does not have yet (kept edits) goes out now.
	capture_now(tr.path)
	held_changed.emit()


func _backup_scene(path: String) -> void:
	var rel := Util.res_to_rel(path)
	var saved := Util.backup_project_file(rel, "scene differed from the host on first sync")
	if not saved.is_empty():
		Log.warn("scene", "Your copy of %s differed from the host's; the host's version was applied. Your file is backed up at %s" % [path, saved])
		if session != null:
			session.notice.emit("Your copy of %s differed from the host's and was replaced. A backup of your file is in %s" % [path.get_file(), saved.get_base_dir()], 1)


# --- applying remote changes ---------------------------------------------------------------------------------------------

func _is_absent(v: Variant) -> bool:
	return typeof(v) == TYPE_STRING and v == ABSENT


## The host renamed one of our nodes to keep sibling names unique.
func _apply_fixups(tr: Tracker, ops: Array) -> void:
	var fixed := {}
	for op in ops:
		if not op is Dictionary or not op.has("n"):
			continue
		var id := String(op.get("id", ""))
		if not (op.get("fixed", false) or (String(op.get("k", "")) == "name" and fixed.has(id))):
			continue
		fixed[id] = true
		var n := _node_by_id(tr, id)
		if n == null:
			continue
		applying = true
		if String(n.name) != String(op.n):
			_make_room(tr, n.get_parent(), String(op.n), n)
			n.name = String(op.n)
		applying = false
		if tr.cache.has(id):
			tr.cache[id].n = String(n.name)


## Someone's node is about to take the name `wanted` under `parent`. If one of our own unconfirmed
## nodes has that name, step it aside; the host gave the name to them and will tell us our final name.
func _make_room(tr: Tracker, parent: Node, wanted: String, except: Node = null) -> bool:
	if parent == null or wanted.is_empty():
		return true
	var other := parent.get_node_or_null(NodePath(wanted))
	if other == null or other == except or other.get_parent() != parent:
		return true
	var oid := String(tr.ids.get(other.get_instance_id(), ""))
	if oid.is_empty() or not (tr.pending.has(oid + "/$x") or tr.pending.has(oid + "/$n") or tr.pending.has(oid + "/$p")):
		return false
	other.name = wanted + "_" + Util.random_hex(2)
	if tr.cache.has(oid):
		tr.cache[oid].n = String(other.name)
	return true


func _apply_remote(tr: Tracker, ops: Array) -> void:
	if not is_instance_valid(tr.root):
		return
	applying = true
	var need_resync := false
	var touched := {}
	var late := []
	tr.wire.unresolved_node = false
	if not ops.is_empty():
		tr.unsaved_pending = true
	for op in ops:
		if not op is Dictionary:
			continue
		var id := String(op.get("id", ""))
		var pend := func(key: String) -> bool: return tr.pending.has(id + "/" + key)
		match String(op.get("k", "")):
			"add":
				if _node_by_id(tr, id) != null and tr.cache.has(id):
					continue
				var parent := _node_by_id(tr, String(op.get("p", "")))
				var n := _instantiate(op)
				if parent == null or n == null:
					if n == null and _inst_missing(op):
						tr.missing_files = true
					else:
						need_resync = true
					if n != null:
						n.free()
					continue
				n.name = String(op.get("n", "Node"))
				if not _make_room(tr, parent, String(n.name)):
					need_resync = true
				parent.add_child(n, true)
				n.owner = tr.root
				_set_index(tr, parent, n, int(op.get("si", 0)))
				_register(tr, n, id)
				_apply_props(tr, n, id, op.get("props", {}), [], true)
				tr.cache[id] = {"p": String(op.get("p", "")), "n": String(n.name), "c": String(op.get("c", "")), "inst": String(op.get("inst", "")), "props": {}, "groups": [], "conns": []}
				var pid := String(op.get("p", ""))
				if not tr.order.has(pid):
					tr.order[pid] = []
				tr.order[pid].insert(mini(int(op.get("si", 0)), tr.order[pid].size()), id)
				late.append(["groups", n, id, op.get("groups", [])])
				late.append(["conns", n, id, op.get("conns", [])])
				touched[id] = n
			"del":
				if pend.call("$x"):
					continue
				var n2 := _node_by_id(tr, id)
				if n2 != null and n2 != tr.root:
					_remove_node(tr, n2)
				var dummy := {}
				_forget_subtree(tr, id, dummy)
				for pid2 in tr.order:
					tr.order[pid2].erase(id)
			"move":
				if pend.call("$p"):
					continue
				var n3 := _node_by_id(tr, id)
				var parent3 := _node_by_id(tr, String(op.get("p", "")))
				if n3 == null or parent3 == null or n3 == tr.root or n3.is_ancestor_of(parent3):
					need_resync = true
					continue
				if n3.get_parent() != parent3:
					_make_room(tr, parent3, String(op.get("n", n3.name)), n3)
					_reparent(tr, n3, parent3)
				if op.has("n") and String(n3.name) != String(op.n):
					_make_room(tr, parent3, String(op.n), n3)
					n3.name = String(op.n)
				_set_index(tr, parent3, n3, int(op.get("si", 0)))
				if tr.cache.has(id):
					var oldp := String(tr.cache[id].p)
					if tr.order.has(oldp):
						tr.order[oldp].erase(id)
					tr.cache[id].p = String(op.get("p", ""))
					tr.cache[id].n = String(n3.name)
				var np := String(op.get("p", ""))
				if not tr.order.has(np):
					tr.order[np] = []
				tr.order[np].insert(mini(int(op.get("si", 0)), tr.order[np].size()), id)
			"name":
				if pend.call("$n"):
					continue
				var n4 := _node_by_id(tr, id)
				if n4 == null:
					need_resync = true
					continue
				if not _make_room(tr, n4.get_parent(), String(op.get("n", n4.name)), n4):
					need_resync = true
				n4.name = String(op.get("n", n4.name))
				if tr.cache.has(id):
					tr.cache[id].n = String(n4.name)
			"set":
				var n5 := _node_by_id(tr, id)
				if n5 == null:
					need_resync = true
					continue
				var props := {}
				var src: Dictionary = op.get("props", {})
				for k in src:
					if not pend.call(String(k)) and not tr.held.has(id + "/" + String(k)):
						props[k] = src[k]
				var reset := []
				for k in op.get("reset", []):
					if not pend.call(String(k)) and not tr.held.has(id + "/" + String(k)):
						reset.append(k)
				_apply_props(tr, n5, id, props, reset, false)
				touched[id] = n5
			"groups":
				if not pend.call("$g"):
					var n6 := _node_by_id(tr, id)
					if n6 != null:
						late.append(["groups", n6, id, op.get("groups", [])])
			"conns":
				if not pend.call("$c"):
					var n7 := _node_by_id(tr, id)
					if n7 != null:
						late.append(["conns", n7, id, op.get("conns", [])])
	for l in late:
		if not is_instance_valid(l[1]):
			continue
		if l[0] == "groups":
			_apply_groups(tr, l[1], l[3])
		else:
			_apply_conns(tr, l[1], l[3])
	if tr.wire.unresolved_node:
		for id in touched:
			var n8: Node = touched[id]
			if is_instance_valid(n8):
				for op in ops:
					if op is Dictionary and String(op.get("id", "")) == id and op.has("props"):
						_apply_props(tr, n8, id, op.props, [], true)
	# The cache mirrors what is actually in the tree now, so nothing is echoed back.
	for id in touched:
		var n9: Node = touched[id]
		if is_instance_valid(n9) and tr.cache.has(id):
			var c: Dictionary = tr.cache[id]
			c.props = _props_of(tr, n9)
			c.groups = _groups_of(tr, n9)
			c.conns = _conns_of(tr, n9)
	applying = false
	_refresh_inspector(touched)
	scene_changed.emit(tr.path)
	if need_resync:
		session.send({"t": "sc_get", "path": tr.path})


func _prop_names(n: Node) -> Dictionary:
	var scr: Variant = n.get_script()
	var key := n.get_class() + "|" + (str(scr.get_instance_id()) if scr != null else "")
	if _prop_cache.has(key):
		return _prop_cache[key]
	var names := {}
	for p in n.get_property_list():
		names[String(p.name)] = true
	_prop_cache[key] = names
	return names


var _prop_cache := {}


func _apply_props(tr: Tracker, n: Node, id: String, props: Dictionary, reset: Array, is_new: bool) -> void:
	tr.wire.missing_resource = false
	if props.has("script"):
		tr.wire.missing_resource = false
		var s: Variant = tr.wire.from_wire(props["script"])
		if tr.wire.missing_resource:
			tr.failed.append([id, "script", props["script"]])
			tr.wire.missing_resource = false
		elif n.get_script() != s:
			n.set_script(s)
			_prop_cache.clear()
	elif not is_new and reset.has("script"):
		n.set_script(null)
		_prop_cache.clear()
	var names := _prop_names(n)
	for k in props:
		if k == "script":
			continue
		if not names.has(String(k)):
			# Properties such as surface_material_override/0 appear only after another property is set.
			_prop_cache.clear()
			names = _prop_names(n)
			if not names.has(String(k)):
				Log.debug("scene", "%s has no property '%s' here (skipped)" % [n.name, k])
				continue
		var cur: Variant = n.get(k)
		tr.wire.missing_resource = false
		var v: Variant = tr.wire.from_wire(props[k], cur)
		if tr.wire.missing_resource:
			tr.failed.append([id, k, props[k]])
		if typeof(v) != typeof(cur) or v != cur:
			n.set(k, v)
	for k in reset:
		if k == "script" or not names.has(String(k)):
			continue
		n.set(k, _base_value(tr, n, String(k)))


## Retries property values that referenced files we did not have yet.
func _retry_failed(tr: Tracker) -> void:
	var items := tr.failed.duplicate()
	tr.failed.clear()
	applying = true
	var touched := {}
	for f in items:
		var n := _node_by_id(tr, f[0])
		if n != null:
			_apply_props(tr, n, f[0], {f[1]: f[2]}, [], true)
			touched[f[0]] = n
	for id in touched:
		if tr.cache.has(id):
			tr.cache[id].props = _props_of(tr, touched[id])
	applying = false


func _apply_groups(tr: Tracker, n: Node, groups: Array) -> void:
	var want := {}
	for g in groups:
		want[String(g)] = true
	for g in _groups_of(tr, n):
		if not want.has(g):
			n.remove_from_group(g)
	for g in want:
		if not n.is_in_group(g):
			n.add_to_group(g, true)
	var nid := String(tr.ids.get(n.get_instance_id(), ""))
	if tr.cache.has(nid):
		tr.cache[nid].groups = _groups_of(tr, n)


func _conn_key(tr: Tracker, c: Dictionary) -> String:
	var sig: Signal = c.signal
	var src: Object = sig.get_object()
	var cb: Callable = c.callable
	return str([tr.ids[src.get_instance_id()], String(sig.get_name()), String(cb.get_method()),
		int(c.flags) & (CONNECT_DEFERRED | CONNECT_ONE_SHOT | CONNECT_APPEND_SOURCE_OBJECT),
		tr.wire.to_wire(cb.get_bound_arguments()), cb.get_unbound_arguments_count()])


func _apply_conns(tr: Tracker, target: Node, conns: Array) -> void:
	var have := _conns_of(tr, target)
	var want_keys := {}
	for c in conns:
		want_keys[str(c)] = c
	var have_keys := {}
	for c in have:
		have_keys[str(c)] = c
	for c in target.get_incoming_connections():
		if not (int(c.flags) & CONNECT_PERSIST):
			continue
		var sig: Signal = c.signal
		var src: Object = sig.get_object()
		if not src is Node or not tr.ids.has(src.get_instance_id()):
			continue
		var cb: Callable = c.callable
		if cb.get_object() != target:
			continue
		if not want_keys.has(_conn_key(tr, c)):
			src.disconnect(sig.get_name(), cb)
	for key in want_keys:
		if have_keys.has(key):
			continue
		var c: Array = want_keys[key]
		if c.size() < 6:
			continue
		var src2 := _node_by_id(tr, String(c[0]))
		if src2 == null or not src2.has_signal(String(c[1])):
			continue
		var cb2 := Callable(target, StringName(String(c[2])))
		var binds: Variant = tr.wire.from_wire(c[4])
		if binds is Array and not binds.is_empty():
			cb2 = cb2.bindv(binds)
		if int(c[5]) > 0:
			cb2 = cb2.unbind(int(c[5]))
		if not src2.is_connected(String(c[1]), cb2):
			src2.connect(String(c[1]), cb2, int(c[3]) | CONNECT_PERSIST)
	var nid := String(tr.ids.get(target.get_instance_id(), ""))
	if tr.cache.has(nid):
		tr.cache[nid].conns = _conns_of(tr, target)


func _fix_owner(tr: Tracker, n: Node) -> void:
	if n.owner != tr.root and n.owner == null:
		n.owner = tr.root
	if n.scene_file_path.is_empty():
		for c in n.get_children():
			if c.owner == null or c.owner == tr.root:
				_fix_owner(tr, c)


func _collect_owned(n: Node, root: Node, out: Array) -> void:
	if n.owner == root:
		out.append(n)
	for c in n.get_children():
		_collect_owned(c, root, out)


## Moves a node (with its subtree) under a new parent while keeping scene ownership consistent.
func _reparent(tr: Tracker, n: Node, new_parent: Node) -> void:
	var owned: Array = []
	_collect_owned(n, tr.root, owned)
	for x in owned:
		x.owner = null
	n.get_parent().remove_child(n)
	new_parent.add_child(n, true)
	for x in owned:
		x.owner = tr.root


func _set_index(tr: Tracker, parent: Node, node: Node, si: int) -> void:
	var sibs := []
	for c in parent.get_children():
		if c != node and c.owner == tr.root:
			sibs.append(c)
	var target := 0
	if si < sibs.size():
		target = sibs[si].get_index()
	elif not sibs.is_empty():
		target = sibs[-1].get_index() + 1
	else:
		target = node.get_index()
	if node.get_index() < target:
		target -= 1
	target = clampi(target, 0, parent.get_child_count() - 1)
	if node.get_index() != target:
		parent.move_child(node, target)


func _remove_node(tr: Tracker, n: Node) -> void:
	var sel: Array = env.selected_nodes()
	var stack: Array = [n]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		if sel.has(x):
			env.deselect(x)
		stack.append_array(x.get_children())
	var insp: Object = env.inspected()
	if insp is Node and (insp == n or n.is_ancestor_of(insp)):
		env.inspect(tr.root)
	if n.get_parent() != null:
		n.get_parent().remove_child(n)
	# Keep the node alive: the editor's own undo history may still point at it.
	tr.graveyard.append(n)


func _refresh_inspector(touched: Dictionary) -> void:
	var obj: Object = env.inspected()
	if obj == null:
		return
	for id in touched:
		if touched[id] == obj and is_instance_valid(obj):
			obj.notify_property_list_changed()
			return


static func _inst_missing(op: Dictionary) -> bool:
	var inst := String(op.get("inst", ""))
	return not inst.is_empty() and Util.is_safe_res_path(inst) and not ResourceLoader.exists(inst)


func _instantiate(op: Dictionary) -> Node:
	var inst := String(op.get("inst", ""))
	if not inst.is_empty():
		if not Util.is_safe_res_path(inst) or not ResourceLoader.exists(inst):
			return null
		var ps: Variant = ResourceLoader.load(inst)
		if not ps is PackedScene:
			return null
		return ps.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var cls := String(op.get("c", ""))
	if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls) or not ClassDB.is_parent_class(cls, "Node"):
		return null
	return ClassDB.instantiate(cls)


func _same_kind(tr: Tracker, n: Node, rec: Dictionary) -> bool:
	var inst := n.scene_file_path if _is_instance(tr, n) else ""
	return inst == String(rec.get("inst", "")) and n.get_class() == String(rec.get("c", ""))


# --- reconciling with the host's copy -----------------------------------------------------------------------------------------

## Makes the local tree match the host's document, three-way merging against `tr.cache` (the last
## state both sides agreed on) unless this is the first sync, when the host's copy simply wins.
## Properties that both sides changed differently are kept as local values and recorded in `tr.held`.
func _reconcile(tr: Tracker, list: Array, first: bool, overrides: Dictionary) -> Dictionary:
	applying = true
	var stats := {"changed": false, "changes": 0}
	tr.wire.unresolved_node = false
	var doc := {}
	var order_ids := []
	var kids := {}
	for r in list:
		if not r is Dictionary:
			continue
		var rid := String(r.get("id", ""))
		if rid.is_empty():
			continue
		doc[rid] = r
		order_ids.append(rid)
		var rp := String(r.get("p", ""))
		if not kids.has(rp):
			kids[rp] = []
		kids[rp].append(rid)
	if order_ids.is_empty() or not is_instance_valid(tr.root):
		applying = false
		return stats
	var doc_path := {}
	var root_doc_id := ""
	for rid in order_ids:
		var r2: Dictionary = doc[rid]
		var p2 := String(r2.get("p", ""))
		if p2.is_empty():
			doc_path[rid] = "."
			root_doc_id = rid
		else:
			var pp := String(doc_path.get(p2, "?"))
			doc_path[rid] = String(r2.get("n", "")) if pp == "." else pp + "/" + String(r2.get("n", ""))
	# 1. Match local nodes to document nodes: by known id first, then by path.
	var node_of := {}
	var claimed := {}
	var local_nodes := _synced_nodes(tr)
	for n in local_nodes:
		var lid: String = tr.ids.get(n.get_instance_id(), "")
		if not lid.is_empty() and doc.has(lid) and not node_of.has(lid):
			node_of[lid] = n
			claimed[n.get_instance_id()] = lid
	if not node_of.has(root_doc_id):
		node_of[root_doc_id] = tr.root
		claimed[tr.root.get_instance_id()] = root_doc_id
		_register(tr, tr.root, root_doc_id)
	for rid in order_ids:
		if node_of.has(rid):
			continue
		var rec: Dictionary = doc[rid]
		var cand: Node = tr.root.get_node_or_null(NodePath(String(doc_path[rid])))
		if cand != null and cand != tr.root and not claimed.has(cand.get_instance_id()) and cand.owner == tr.root and _same_kind(tr, cand, rec):
			node_of[rid] = cand
			claimed[cand.get_instance_id()] = rid
			_register(tr, cand, rid)
	# 2. Create nodes the host has and we lack (unless we deleted them while apart and they are unchanged).
	var created := {}
	var kept_deleted := {}
	for rid in order_ids:
		if node_of.has(rid):
			continue
		var rec2: Dictionary = doc[rid]
		if not first and tr.cache.has(rid) and _same_record(rec2, tr.cache[rid]):
			kept_deleted[rid] = true
			continue
		var parent: Node = node_of.get(String(rec2.get("p", "")))
		if parent == null:
			continue
		var made := _instantiate(rec2)
		if made == null:
			if _inst_missing(rec2):
				tr.missing_files = true
			continue
		made.name = String(rec2.get("n", "Node"))
		parent.add_child(made, true)
		made.owner = tr.root
		_register(tr, made, rid)
		node_of[rid] = made
		created[rid] = true
		stats.changes += 1
	# 3. Reparent claimed nodes whose parent differs (unless only we moved them).
	for rid in order_ids:
		if created.has(rid) or not node_of.has(rid) or rid == root_doc_id:
			continue
		var n3: Node = node_of[rid]
		var want_parent: Node = node_of.get(String(doc[rid].get("p", "")))
		if want_parent == null or n3.get_parent() == want_parent:
			continue
		if not first and tr.cache.has(rid):
			var base_p: String = String(overrides.get(rid + "/$p", tr.cache[rid].p))
			var local_pid: String = tr.ids.get(n3.get_parent().get_instance_id(), "")
			if local_pid != base_p and String(doc[rid].get("p", "")) == base_p:
				continue
		if n3.is_ancestor_of(want_parent):
			continue
		_reparent(tr, n3, want_parent)
		stats.changes += 1
	# 4. Remove local nodes the host does not have (it deleted them; on first sync the host's copy wins).
	var drop: Array = []
	for n in local_nodes:
		if n == tr.root or claimed.has(n.get_instance_id()) or not is_instance_valid(n):
			continue
		var lid2: String = tr.ids.get(n.get_instance_id(), "")
		if first or (not lid2.is_empty() and tr.cache.has(lid2)):
			drop.append(n)
	for n in drop:
		if not is_instance_valid(n) or n.get_parent() == null:
			continue
		var covered := false
		for other in drop:
			if other != n and is_instance_valid(other) and other.is_ancestor_of(n):
				covered = true
				break
		if covered:
			continue
		_remove_node(tr, n)
		stats.changes += 1
	# 5. Names (two phases so swapping names between siblings cannot collide).
	var renames: Array = []
	for rid in order_ids:
		if created.has(rid) or not node_of.has(rid):
			continue
		var n5: Node = node_of[rid]
		var want_name := String(doc[rid].get("n", ""))
		if String(n5.name) == want_name:
			continue
		if not first and tr.cache.has(rid):
			var base_n: String = String(overrides.get(rid + "/$n", tr.cache[rid].n))
			if String(n5.name) != base_n and want_name == base_n:
				continue
		renames.append([n5, want_name, rid])
	for item in renames:
		item[0].name = "~collab_" + String(item[2])
	for item in renames:
		item[0].name = String(item[1])
		stats.changes += 1
	for rid in created:
		var cn: Node = node_of[rid]
		var cname := String(doc[rid].get("n", ""))
		if String(cn.name) != cname:
			cn.name = cname
	# 6. Sibling order.
	for pid in kids:
		var pnode: Node = node_of.get(pid)
		if pnode == null:
			continue
		var idx := 0
		for cid in kids[pid]:
			var cnode: Node = node_of.get(cid)
			if cnode == null or cnode.get_parent() != pnode:
				continue
			_set_index(tr, pnode, cnode, idx)
			idx += 1
	# 7. Properties, groups and connections.
	for rid in order_ids:
		if not node_of.has(rid):
			continue
		var n7: Node = node_of[rid]
		var rec7: Dictionary = doc[rid]
		stats.changes += _merge_props(tr, n7, rid, rec7, first, created.has(rid), overrides, String(doc_path[rid]))
	var late_groups := []
	for rid in order_ids:
		if not node_of.has(rid):
			continue
		var n8: Node = node_of[rid]
		var theirs_groups: Array = doc[rid].get("groups", [])
		if first or created.has(rid) or not tr.cache.has(rid) or Array(tr.cache[rid].groups) == _groups_of(tr, n8):
			late_groups.append([n8, theirs_groups])
	for g in late_groups:
		_apply_groups(tr, g[0], g[1])
	for rid in order_ids:
		if node_of.has(rid) and (first or created.has(rid) or not tr.cache.has(rid) or Array(tr.cache[rid].conns) == _conns_of(tr, node_of[rid])):
			_apply_conns(tr, node_of[rid], doc[rid].get("conns", []))
	# 8. The cache becomes the host's document (kept local differences are then sent as new edits).
	var new_cache := {}
	var new_order := {}
	for rid in order_ids:
		var r8: Dictionary = doc[rid]
		new_cache[rid] = {
			"p": String(r8.get("p", "")), "n": String(r8.get("n", "")), "c": String(r8.get("c", "")),
			"inst": String(r8.get("inst", "")), "props": r8.get("props", {}).duplicate(true),
			"groups": Array(r8.get("groups", [])), "conns": Array(r8.get("conns", [])),
		}
	for pid2 in kids:
		new_order[pid2] = kids[pid2].duplicate()
	tr.cache = new_cache
	tr.order = new_order
	for rid in order_ids:
		if node_of.has(rid):
			_register(tr, node_of[rid], rid)
	stats.changed = stats.changes > 0
	applying = false
	var inspected: Object = env.inspected()
	if inspected != null and is_instance_valid(inspected):
		inspected.notify_property_list_changed()
	return stats


static func _same_record(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("p", "")) == String(b.get("p", "")) and String(a.get("n", "")) == String(b.get("n", "")) \
		and Wire.same(a.get("props", {}), b.get("props", {})) and Array(a.get("groups", [])) == Array(b.get("groups", []))


func _merge_props(tr: Tracker, n: Node, id: String, rec: Dictionary, first: bool, created: bool, overrides: Dictionary, node_path: String) -> int:
	var theirs: Dictionary = rec.get("props", {})
	if created:
		_apply_props(tr, n, id, theirs, [], true)
		return 0
	var mine := _props_of(tr, n)
	var has_base := tr.cache.has(id) and not first
	var base: Dictionary = tr.cache[id].props if has_base else {}
	var keys := {}
	for k in theirs:
		keys[k] = true
	for k in mine:
		keys[k] = true
	var to_set := {}
	var to_reset := []
	var held_new := 0
	for k in keys:
		var key := id + "/" + String(k)
		var t: Variant = theirs.get(k, ABSENT)
		var m: Variant = mine.get(k, ABSENT)
		if tr.held.has(key):
			if Wire.same(m, t):
				tr.held.erase(key)
			else:
				tr.held[key]["theirs"] = t
			continue
		if Wire.same(m, t):
			continue
		var b: Variant = ABSENT
		if overrides.has(key):
			b = overrides[key]
		elif base.has(k):
			b = base[k]
		if first or not has_base or Wire.same(m, b):
			if _is_absent(t):
				to_reset.append(k)
			else:
				to_set[k] = t
		elif Wire.same(t, b):
			continue
		else:
			tr.held[key] = {"id": id, "prop": String(k), "node": node_path, "mine": m, "theirs": t}
			held_new += 1
			Log.warn("scene", "%s: '%s.%s' was changed by you AND by someone else while apart - holding it for your decision (yours: %s, theirs: %s)" % [
				tr.path.get_file(), node_path, k, Wire.brief(m, 40), Wire.brief(t, 40)])
	_apply_props(tr, n, id, to_set, to_reset, false)
	return to_set.size() + to_reset.size()


# --- held conflicts ---------------------------------------------------------------------------------------------------------------

## Every property that both sides changed while apart and that still awaits a decision.
func held_list() -> Array:
	var out := []
	for path in trackers:
		var tr: Tracker = trackers[path]
		for key in tr.held:
			var h: Dictionary = tr.held[key]
			out.append({
				"kind": "scene", "scene": path, "key": key, "node": h.get("node", ""), "prop": h.get("prop", ""),
				"mine": Wire.brief(h.get("mine"), 60), "theirs": Wire.brief(h.get("theirs"), 60),
			})
	return out


func resolve_held(scene_path: String, key: String, use_mine: bool) -> bool:
	var tr: Tracker = trackers.get(scene_path)
	if tr == null or not tr.held.has(key):
		return false
	var h: Dictionary = tr.held[key]
	tr.held.erase(key)
	if use_mine:
		Log.info("scene", "Kept your value for %s.%s; sending it to everyone" % [h.get("node", ""), h.get("prop", "")])
		capture_now(scene_path)
	else:
		var n := _node_by_id(tr, String(h.get("id", "")))
		if n != null:
			applying = true
			var theirs: Variant = h.get("theirs")
			if _is_absent(theirs):
				_apply_props(tr, n, String(h.id), {}, [h.prop], false)
			else:
				_apply_props(tr, n, String(h.id), {h.prop: theirs}, [], false)
			if tr.cache.has(h.id):
				tr.cache[h.id].props = _props_of(tr, n)
			applying = false
			_refresh_inspector({h.id: n})
		Log.info("scene", "Used the other value for %s.%s" % [h.get("node", ""), h.get("prop", "")])
	held_changed.emit()
	return true
