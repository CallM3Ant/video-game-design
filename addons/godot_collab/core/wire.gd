@tool
extends RefCounted
## Converts property values to plain data ("wire form") that is safe to send, store and compare,
## and back again. Objects become tagged dictionaries:
##   {"$ext": "res://path"}                            external resource (a file in the project)
##   {"$sub": rid, "cls": "BoxShape3D", "p": {...}}    resource embedded in the scene
##   {"$node": id}                                     reference to a synced node
##   {"$arr": [...], "tb": ..., "tc": ..., "ts": ...}  typed array
##   {"$dict": [k, v, ...], "kt": [...], "vt": [...]}  dictionary
## Embedded resources are matched by id (or adopted in place), so editing a shape's size updates the
## shape that already exists instead of replacing it.
##
## The wire/tracker split is modelled after the MIT-licensed godot-coop add-on (see NOTICE.md).

const Util := preload("res://addons/godot_collab/core/util.gd")
const MAX_DEPTH := 12
const SKIP_RES_PROPS := ["resource_path", "resource_scene_unique_id"]

var node_to_id: Callable
var id_to_node: Callable
## Set when from_wire met a res:// file that does not exist (yet): the caller retries later.
var missing_resource := false
## Set when from_wire met a node id that does not exist (yet).
var unresolved_node := false

var _res_by_rid := {}
var _rid_by_obj := {}
var _shared_rids := {}


func rid_for(res: Resource) -> String:
	var iid := res.get_instance_id()
	if _rid_by_obj.has(iid):
		return _rid_by_obj[iid]
	var rid := Util.random_hex(6)
	_rid_by_obj[iid] = rid
	_res_by_rid[rid] = res
	return rid


func _register(rid: String, res: Resource, take_over: bool = false) -> void:
	_res_by_rid[rid] = res
	_shared_rids[rid] = true
	if take_over or not _rid_by_obj.has(res.get_instance_id()):
		_rid_by_obj[res.get_instance_id()] = rid


## Equality that treats embedded resources as equal when only their (locally invented) ids differ.
static func same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary:
		if a.has("$sub") and b.has("$sub"):
			return String(a.get("cls", "")) == String(b.get("cls", "")) and same(a.get("p", {}), b.get("p", {}))
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not same(a[k], b[k]):
				return false
		return true
	if a is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not same(a[i], b[i]):
				return false
		return true
	if typeof(a) == TYPE_FLOAT:
		return a == b or (is_nan(a) and is_nan(b))
	return a == b


static func is_external(res: Resource) -> bool:
	var p := res.resource_path
	return not p.is_empty() and p.find("::") == -1


func to_wire(v: Variant, depth: int = 0) -> Variant:
	match typeof(v):
		TYPE_OBJECT:
			if v == null or not is_instance_valid(v):
				return null
			if v is Resource:
				return _res_to_wire(v, depth)
			if v is Node:
				return {"$node": node_to_id.call(v) if node_to_id.is_valid() else ""}
			return null
		TYPE_ARRAY:
			var arr: Array = v
			var out := []
			if depth < MAX_DEPTH:
				for e in arr:
					out.append(to_wire(e, depth + 1))
			if arr.is_typed():
				var script: Variant = arr.get_typed_script()
				return {
					"$arr": out,
					"tb": arr.get_typed_builtin(),
					"tc": String(arr.get_typed_class_name()),
					"ts": script.resource_path if script is Script else ""
				}
			return out
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var kv := []
			if depth < MAX_DEPTH:
				for k in d:
					kv.append(to_wire(k, depth + 1))
					kv.append(to_wire(d[k], depth + 1))
			var w := {"$dict": kv}
			if d.is_typed():
				var ks: Variant = d.get_typed_key_script()
				var vs: Variant = d.get_typed_value_script()
				w["kt"] = [d.get_typed_key_builtin(), String(d.get_typed_key_class_name()), ks.resource_path if ks is Script else ""]
				w["vt"] = [d.get_typed_value_builtin(), String(d.get_typed_value_class_name()), vs.resource_path if vs is Script else ""]
			return w
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return null
		_:
			return v


func _res_to_wire(res: Resource, depth: int) -> Variant:
	if is_external(res):
		return {"$ext": res.resource_path}
	if depth > MAX_DEPTH:
		return null
	var props := {}
	for p in res.get_property_list():
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE):
			continue
		var name: String = p.name
		if name in SKIP_RES_PROPS:
			continue
		props[name] = to_wire(res.get(name), depth + 1)
	return {"$sub": rid_for(res), "cls": res.get_class(), "p": props}


## `current` is the value presently in the slot; embedded resources of the same class are updated
## in place instead of being replaced.
func from_wire(w: Variant, current: Variant = null) -> Variant:
	match typeof(w):
		TYPE_DICTIONARY:
			if w.has("$ext"):
				return _load_ext(String(w["$ext"]))
			if w.has("$sub"):
				return _sub_from_wire(w, current)
			if w.has("$node"):
				var target: Variant = id_to_node.call(String(w["$node"])) if id_to_node.is_valid() else null
				if target == null and not String(w["$node"]).is_empty():
					unresolved_node = true
				return target
			if w.has("$arr"):
				var items := []
				for e in w["$arr"]:
					items.append(from_wire(e))
				var type_script: Variant = _load_ext(String(w.get("ts", ""))) if not String(w.get("ts", "")).is_empty() else null
				return Array(items, int(w.get("tb", 0)), StringName(w.get("tc", "")), type_script)
			if w.has("$dict"):
				var kv: Array = w["$dict"]
				var d := {}
				var i := 0
				while i + 1 < kv.size():
					d[from_wire(kv[i])] = from_wire(kv[i + 1])
					i += 2
				if w.has("kt") and w.has("vt"):
					var kt: Array = w["kt"]
					var vt: Array = w["vt"]
					var key_script: Variant = _load_ext(String(kt[2])) if not String(kt[2]).is_empty() else null
					var value_script: Variant = _load_ext(String(vt[2])) if not String(vt[2]).is_empty() else null
					return Dictionary(d, int(kt[0]), StringName(kt[1]), key_script, int(vt[0]), StringName(vt[1]), value_script)
				return d
			return null
		TYPE_ARRAY:
			var out := []
			for e in w:
				out.append(from_wire(e))
			return out
		_:
			return w


func _load_ext(path: String) -> Variant:
	if not Util.is_safe_res_path(path):
		return null
	if ResourceLoader.exists(path):
		var r: Resource = ResourceLoader.load(path)
		if r != null:
			return r
	missing_resource = true
	return null


func _sub_from_wire(w: Dictionary, current: Variant) -> Variant:
	var rid := String(w.get("$sub", ""))
	var cls := String(w.get("cls", ""))
	var res: Resource = _res_by_rid.get(rid)
	if res != null and res.get_class() != cls:
		res = null
	# Adopt the object already in the slot (first sync of an existing scene), unless peers already
	# know it under another id: then other slots share it and this slot's copy was made unique.
	if res == null and current is Resource and current.get_class() == cls and not is_external(current):
		var known: Variant = _rid_by_obj.get(current.get_instance_id())
		if known == null or known == rid or not _shared_rids.has(known):
			res = current
			_register(rid, res, true)
	if res == null:
		if not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls) or not ClassDB.is_parent_class(cls, "Resource"):
			return null
		res = ClassDB.instantiate(cls)
		if res == null:
			return null
		_register(rid, res)
	var props: Variant = w.get("p", {})
	if not props is Dictionary:
		return res
	if props.has("script"):
		var script: Variant = from_wire(props["script"])
		if res.get_script() != script:
			res.set_script(script)
	if res is Animation:
		res.clear()
	for k in props:
		if k == "script":
			continue
		var cur: Variant = res.get(k)
		var nv: Variant = from_wire(props[k], cur)
		if typeof(nv) != typeof(cur) or nv != cur:
			res.set(k, nv)
	if res is Script and (props.has("script/source") or props.has("source_code")):
		res.reload()
	return res


## Short human-readable rendering of a wire value for log lines.
static func brief(w: Variant, max_len: int = 70) -> String:
	var s: String
	if w is Dictionary and w.has("$ext"):
		s = "res(%s)" % w["$ext"]
	elif w is Dictionary and w.has("$sub"):
		s = "sub(%s)" % w.get("cls", "?")
	elif w is Dictionary and w.has("$node"):
		s = "node(%s)" % w["$node"]
	else:
		s = var_to_str(w).replace("\n", " ")
	if s.length() > max_len:
		s = s.substr(0, max_len - 3) + "..."
	return s
