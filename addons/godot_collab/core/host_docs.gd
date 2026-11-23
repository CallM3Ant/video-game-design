@tool
extends RefCounted
## Host-side registry of live documents: scenes (SceneDoc) and text files (TextDoc). It receives the
## "sc_*" and "tx_*" messages from peers (the host's own editor is peer 1), orders them, and
## broadcasts the result to everybody who has the document open.

const Log := preload("res://addons/godot_collab/core/log.gd")
const Util := preload("res://addons/godot_collab/core/util.gd")
const OT := preload("res://addons/godot_collab/core/ot.gd")
const SceneDoc := preload("res://addons/godot_collab/core/scene_doc.gd")
const TextDoc := preload("res://addons/godot_collab/core/text_doc.gd")

signal text_doc_changed(path: String)
signal scene_doc_changed(path: String)

const MAX_OPS_PER_BATCH := 20000

var session
var scenes: Dictionary = {}
var texts: Dictionary = {}
## func(path) -> Array of node records (the host's live or on-disk copy) or null.
var scene_provider: Callable
## func(path) -> String (the host's copy of the file) or null if the host does not have it.
var text_provider: Callable
## func(path) -> bool: whether the host has this file on disk.
var file_exists: Callable


func _init(p_session = null) -> void:
	session = p_session


func peer_left(pid: int) -> void:
	for path in scenes:
		scenes[path].watchers.erase(pid)
	for path in texts:
		texts[path].watchers.erase(pid)


func reset() -> void:
	scenes.clear()
	texts.clear()


func handle(pid: int, uid: String, msg: Dictionary) -> void:
	var t := String(msg.get("t", ""))
	var path := String(msg.get("path", ""))
	if not Util.is_safe_res_path(path):
		Log.warn("docs", "Ignoring %s with unsafe path '%s'" % [t, path])
		return
	match t:
		"sc_open":
			_sc_open(pid, uid, msg, path)
		"sc_get":
			_sc_open(pid, uid, {}, path)
		"sc_ops":
			_sc_ops(pid, uid, msg, path)
		"sc_close":
			if scenes.has(path):
				scenes[path].watchers.erase(pid)
				Log.debug("docs", "%s closed %s" % [session.peer_name(pid), path])
		"tx_open":
			_tx_open(pid, uid, msg, path)
		"tx_op":
			_tx_op(pid, uid, msg, path)
		"tx_close":
			if texts.has(path):
				texts[path].watchers.erase(pid)
				Log.debug("docs", "%s closed text %s" % [session.peer_name(pid), path])
		"tx_cursor":
			var doc: TextDoc = texts.get(path)
			if doc != null and doc.watchers.has(pid):
				var cursor_out := msg.duplicate()
				cursor_out["pid"] = pid
				cursor_out["name"] = session.peer_name(pid)
				cursor_out["color"] = session.peer_color(pid).to_html(false)
				for w in doc.watchers:
					if w != pid:
						session.deliver(w, cursor_out)
		"sc_selection":
			var scene: SceneDoc = scenes.get(path)
			if scene != null and scene.watchers.has(pid):
				var selection_out := msg.duplicate()
				selection_out["pid"] = pid
				selection_out["name"] = session.peer_name(pid)
				selection_out["color"] = session.peer_color(pid).to_html(false)
				for w in scene.watchers:
					if w != pid:
						session.deliver(w, selection_out)


# --- scenes -----------------------------------------------------------------------------------

func _sc_open(pid: int, uid: String, msg: Dictionary, path: String) -> void:
	var doc: SceneDoc = scenes.get(path)
	if doc == null:
		var nodes: Variant = null
		var source := ""
		var offered: Variant = msg.get("snapshot")
		if pid == 1 and offered is Array:
			nodes = offered
			source = "the host's open scene"
		if nodes == null and scene_provider.is_valid():
			nodes = scene_provider.call(path)
			source = "host copy"
		if nodes == null and offered is Array and not (file_exists.is_valid() and file_exists.call(path)):
			nodes = offered
			source = "snapshot offered by %s" % session.peer_name(pid)
		if nodes == null:
			Log.info("docs", "No scene document for %s (host has no copy)" % path)
			session.deliver(pid, {"t": "sc_state", "path": path, "missing": true})
			return
		doc = SceneDoc.new(path)
		if not doc.load_snapshot(nodes):
			Log.warn("docs", "Rejected malformed scene snapshot for %s" % path)
			session.deliver(pid, {"t": "sc_state", "path": path, "missing": true})
			return
		scenes[path] = doc
		Log.info("docs", "Scene document %s created from %s (%d nodes, epoch %s)" % [path, source, doc.node_count(), doc.epoch])
		scene_doc_changed.emit(path)
	doc.watchers[pid] = true
	_send_scene_state(pid, uid, doc)


func _send_scene_state(pid: int, uid: String, doc: SceneDoc) -> void:
	session.deliver(pid, {
		"t": "sc_state",
		"path": doc.path,
		"epoch": doc.epoch,
		"rev": doc.rev,
		"nodes": doc.snapshot(),
		"acked": int(doc.last_cseq.get(uid, 0)),
	})
	Log.debug("docs", "Sent %s state rev %d to %s" % [doc.path, doc.rev, session.peer_name(pid)])


func _sc_ops(pid: int, uid: String, msg: Dictionary, path: String) -> void:
	var doc: SceneDoc = scenes.get(path)
	var cseq := int(msg.get("cseq", 0))
	if doc == null:
		session.deliver(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "nodoc"})
		return
	if String(msg.get("epoch", "")) != doc.epoch:
		Log.info("docs", "%s sent ops for an old epoch of %s; resyncing them" % [session.peer_name(pid), path])
		session.deliver(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "epoch"})
		return
	var ops: Variant = msg.get("ops", [])
	if not ops is Array or ops.size() > MAX_OPS_PER_BATCH:
		session.deliver(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "malformed"})
		return
	if cseq <= int(doc.last_cseq.get(uid, 0)):
		Log.debug("docs", "Duplicate batch %d from %s on %s re-acknowledged" % [cseq, session.peer_name(pid), path])
		session.deliver(pid, {"t": "sc_ops", "path": path, "by": uid, "cseq": cseq, "rev": doc.rev, "ops": []})
		return
	var applied: Array = []
	var failed_op: Variant = null
	for op in ops:
		if not op is Dictionary:
			failed_op = op
			break
		var result: Variant = doc.apply(op)
		if result == null:
			failed_op = op
			break
		applied.append(result)
	doc.rev += 1
	doc.last_cseq[uid] = cseq
	var out := {"t": "sc_ops", "path": path, "by": uid, "cseq": cseq, "rev": doc.rev, "ops": applied}
	for w in doc.watchers:
		session.deliver(w, out)
	Log.debug("docs", "%s: %d op(s) from %s applied (rev %d)%s" % [path.get_file(), applied.size(), session.peer_name(pid), doc.rev, "" if failed_op == null else ", 1 rejected"])
	if failed_op != null:
		Log.warn("docs", "Rejected op from %s on %s: %s" % [session.peer_name(pid), path, Util.brief(failed_op, 120)])
		session.deliver(pid, {"t": "sc_reject", "path": path, "cseq": cseq, "reason": "invalid"})
	scene_doc_changed.emit(path)


# --- text -------------------------------------------------------------------------------------

func _tx_open(pid: int, uid: String, msg: Dictionary, path: String) -> void:
	var doc: TextDoc = texts.get(path)
	if doc == null:
		var text: Variant = null
		if pid == 1 and msg.get("text") is String:
			text = msg.get("text")
		elif text_provider.is_valid():
			text = text_provider.call(path)
		doc = TextDoc.new(path, "" if text == null else String(text))
		doc.missing = text == null
		texts[path] = doc
		Log.info("docs", "Text document %s created (%d chars%s)" % [path, doc.text.length(), ", new file" if doc.missing else ""])
	doc.watchers[pid] = true
	if msg.has("epoch") and String(msg.get("epoch")) == doc.epoch and msg.has("rev"):
		var since: Variant = doc.ops_since(int(msg.get("rev", 0)))
		if since != null:
			session.deliver(pid, {"t": "tx_state", "path": path, "epoch": doc.epoch, "from_rev": int(msg.get("rev", 0)), "rev": doc.rev, "since": since})
			Log.debug("docs", "%s resumed %s (%d ops behind)" % [session.peer_name(pid), path, since.size()])
			return
	session.deliver(pid, {"t": "tx_state", "path": path, "epoch": doc.epoch, "rev": doc.rev, "text": doc.text, "missing": doc.missing})
	Log.debug("docs", "Sent %s text rev %d (%d chars) to %s" % [path, doc.rev, doc.text.length(), session.peer_name(pid)])


func _tx_op(pid: int, uid: String, msg: Dictionary, path: String) -> void:
	var doc: TextDoc = texts.get(path)
	if doc == null or String(msg.get("epoch", "")) != doc.epoch:
		session.deliver(pid, {"t": "tx_reject", "path": path, "reason": "epoch"})
		return
	var cid := String(msg.get("cid", ""))
	var cseq := int(msg.get("cseq", 0))
	if doc.is_duplicate(uid, cseq, cid):
		return
	var op: Variant = OT.from_array(msg.get("op"))
	if op == null:
		session.deliver(pid, {"t": "tx_reject", "path": path, "reason": "malformed"})
		return
	var transformed: Variant = doc.receive(int(msg.get("rev", -1)), op, uid, cseq, cid)
	if transformed == null:
		Log.warn("docs", "Could not apply a text edit from %s on %s (rev %s vs %d); resyncing them" % [session.peer_name(pid), path, str(msg.get("rev")), doc.rev])
		session.deliver(pid, {"t": "tx_reject", "path": path, "reason": "history"})
		return
	var out := {"t": "tx_op", "path": path, "by": uid, "cid": cid, "cseq": cseq, "op": transformed.to_array(), "rev": doc.rev}
	for w in doc.watchers:
		session.deliver(w, out)
	text_doc_changed.emit(path)
