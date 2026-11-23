extends SceneTree

const Wire := preload("res://addons/godot_collab/core/wire.gd")
const SceneDoc := preload("res://addons/godot_collab/core/scene_doc.gd")

var _failed := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("FAIL: " + msg)


func _run() -> void:
	_test_wire_primitives()
	_test_wire_resources()
	_test_scene_doc()
	if _failed > 0:
		printerr("model tests failed: %d of %d" % [_failed, _checks])
		quit(1)
	else:
		print("model tests passed (%d checks)." % _checks)
		quit()


func _round(w: Variant) -> Variant:
	return bytes_to_var(var_to_bytes(w))


func _test_wire_primitives() -> void:
	var wire := Wire.new()
	var samples: Array = [
		1, 2.5, "text", true, Vector2(1, 2), Vector3(1.5, -2, 3.25), Color(0.1, 0.2, 0.3, 0.4),
		Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)), NodePath("A/B"), StringName("sn"),
		PackedFloat32Array([1, 2, 3]), PackedStringArray(["a", "b"]), AABB(Vector3(), Vector3.ONE),
		[1, "two", Vector2.ONE], {"a": 1, "b": [1, 2]}, Rect2(1, 2, 3, 4), Quaternion(0, 0, 0, 1),
	]
	for v in samples:
		var w: Variant = wire.to_wire(v)
		var back: Variant = wire.from_wire(_round(w))
		_expect(Wire.same(back, v), "wire round trip " + str(v))
	var typed: Array[int] = [1, 2, 3]
	var tw: Variant = wire.to_wire(typed)
	var tb: Variant = wire.from_wire(_round(tw))
	_expect(tb is Array and tb.is_typed() and tb == typed, "typed array round trip")
	var td: Dictionary[String, int] = {"a": 1}
	var dw: Variant = wire.to_wire(td)
	var db: Variant = wire.from_wire(_round(dw))
	_expect(db is Dictionary and db.is_typed() and db == td, "typed dictionary round trip")
	_expect(wire.to_wire(Callable()) == null, "callables are not sent")
	_expect(not Wire.same(1, 1.0), "int and float differ")
	_expect(Wire.same(NAN, NAN), "NaN equals NaN")


func _test_wire_resources() -> void:
	var wire := Wire.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 3, 4)
	var w: Variant = wire.to_wire(box)
	_expect(w is Dictionary and w.has("$sub") and w.cls == "BoxShape3D", "embedded resource tagged")
	var other := Wire.new()
	var made: Variant = other.from_wire(_round(w))
	_expect(made is BoxShape3D and made.size == Vector3(2, 3, 4), "embedded resource rebuilt")
	box.size = Vector3(5, 5, 5)
	var w2: Variant = wire.to_wire(box)
	_expect(not Wire.same(w, w2), "changed embedded resource differs")
	var again: Variant = other.from_wire(_round(w2), made)
	_expect(again == made and made.size == Vector3(5, 5, 5), "embedded resource updated in place")
	var adopt_slot := BoxShape3D.new()
	var third := Wire.new()
	var adopted: Variant = third.from_wire(_round(w2), adopt_slot)
	_expect(adopted == adopt_slot and adopt_slot.size == Vector3(5, 5, 5), "existing slot object adopted")
	# Resource ids differ per editor but equal content is equal.
	var box2 := BoxShape3D.new()
	box2.size = Vector3(5, 5, 5)
	_expect(Wire.same(wire.to_wire(box2), w2), "equal embedded resources compare equal despite different ids")
	# External resources are referenced by path.
	var res_path := "res://addons/godot_collab/tests/_wire_tmp.tres"
	var ext := BoxShape3D.new()
	ext.size = Vector3(9, 9, 9)
	ResourceSaver.save(ext, res_path)
	var loaded: Resource = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var ew: Variant = wire.to_wire(loaded)
	_expect(ew is Dictionary and ew.get("$ext", "") == res_path, "external resource by path")
	var eb: Variant = wire.from_wire(_round(ew))
	_expect(eb is BoxShape3D and eb.size == Vector3(9, 9, 9), "external resource loaded")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))
	wire.missing_resource = false
	var missing: Variant = wire.from_wire({"$ext": "res://definitely/not/here.tres"})
	_expect(missing == null and wire.missing_resource, "missing external flagged")
	wire.missing_resource = false
	_expect(wire.from_wire({"$ext": "res://../escape.tres"}) == null and not wire.missing_resource, "unsafe path refused")
	# Node references go through the id callbacks.
	var holder := Node.new()
	holder.name = "Holder"
	var tw2 := Wire.new()
	tw2.node_to_id = func(n: Node) -> String: return "id_" + String(n.name)
	tw2.id_to_node = func(id: String) -> Node: return holder if id == "id_Holder" else null
	var nw: Variant = tw2.to_wire(holder)
	_expect(nw is Dictionary and nw["$node"] == "id_Holder", "node reference by id")
	_expect(tw2.from_wire(nw) == holder, "node reference resolved")
	tw2.unresolved_node = false
	_expect(tw2.from_wire({"$node": "nope"}) == null and tw2.unresolved_node, "unknown node flagged")
	holder.free()


func _rec(id: String, parent: String, name: String, cls: String = "Node3D", props: Dictionary = {}) -> Dictionary:
	return {"id": id, "p": parent, "n": name, "c": cls, "props": props, "groups": [], "conns": []}


func _test_scene_doc() -> void:
	var doc := SceneDoc.new("res://t.tscn")
	var ok := doc.load_snapshot([_rec("r", "", "Root"), _rec("a", "r", "A"), _rec("b", "r", "B"), _rec("a1", "a", "Child")])
	_expect(ok and doc.root_id == "r" and doc.node_count() == 4, "snapshot loaded")
	_expect(doc.path_of("a1") == "A/Child" and doc.path_of("r") == ".", "paths computed")
	_expect(not SceneDoc.new().load_snapshot([_rec("a", "x", "Orphan")]), "orphan snapshot rejected")
	_expect(not SceneDoc.new().load_snapshot([_rec("a", "", "R1"), _rec("b", "", "R2")]), "two roots rejected")
	var added: Variant = doc.apply({"k": "add", "id": "c", "p": "r", "n": "A", "c": "Node3D", "si": 1})
	_expect(added != null and added.get("fixed", false) and added.n == "A2", "duplicate name made unique")
	_expect(doc.children["r"] == ["a", "c", "b"], "inserted at index: " + str(doc.children["r"]))
	_expect(doc.apply({"k": "add", "id": "c", "p": "r", "n": "Dup"}) == null, "duplicate id rejected")
	_expect(doc.apply({"k": "add", "id": "z", "p": "ghost", "n": "Z"}) == null, "unknown parent rejected")
	var moved: Variant = doc.apply({"k": "move", "id": "a1", "p": "b", "si": 0})
	_expect(moved != null and doc.nodes["a1"].p == "b" and doc.children["a"].is_empty(), "reparent")
	_expect(doc.apply({"k": "move", "id": "b", "p": "a1", "si": 0}) == null, "cycle refused")
	_expect(doc.apply({"k": "move", "id": "r", "p": "a", "si": 0}) == null, "root cannot move")
	var renamed: Variant = doc.apply({"k": "name", "id": "b", "n": "A2"})
	_expect(renamed != null and renamed.get("fixed", false) and doc.name_of("b") == "A22" or doc.name_of("b") == "A3", "rename collision fixed: " + doc.name_of("b"))
	doc.apply({"k": "set", "id": "a", "props": {"position": Vector3(1, 2, 3), "visible": false}, "reset": []})
	_expect(doc.nodes["a"].props.position == Vector3(1, 2, 3), "set stores property")
	doc.apply({"k": "set", "id": "a", "props": {}, "reset": ["visible"]})
	_expect(not doc.nodes["a"].props.has("visible"), "reset removes property")
	_expect(doc.apply({"k": "set", "id": "ghost", "props": {}, "reset": []}) == null, "set on unknown node rejected")
	doc.apply({"k": "groups", "id": "a", "groups": ["enemies"]})
	_expect(doc.nodes["a"].groups == ["enemies"], "groups stored")
	doc.apply({"k": "del", "id": "b"})
	_expect(not doc.nodes.has("b") and not doc.nodes.has("a1"), "delete removes the subtree")
	_expect(doc.apply({"k": "del", "id": "r"}) == null, "root cannot be deleted")
	var snap := doc.snapshot()
	var copy := SceneDoc.new("res://copy.tscn")
	_expect(copy.load_snapshot(snap) and copy.node_count() == doc.node_count(), "snapshot round trip")
	_expect(snap[0].id == "r" and snap[0].si == 0, "snapshot is parent-first")
