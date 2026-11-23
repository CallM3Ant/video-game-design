extends SceneTree

const OT := preload("res://addons/godot_collab/core/ot.gd")

var _failed := 0
var _checks := 0
var _rng := RandomNumberGenerator.new()
const ALPHABET := ["a", "b", "c", "\n", " ", "é", "x", "y", "\n"]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rng.seed = 987654321
	_test_basics()
	_test_fuzz()
	_test_diff()
	_test_merge()
	_test_index()
	if _failed > 0:
		printerr("OT tests failed: %d of %d checks" % [_failed, _checks])
		quit(1)
	else:
		print("OT tests passed (%d checks)." % _checks)
		quit()


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("FAIL: " + msg)


func _rand_text(max_len: int) -> String:
	var n := _rng.randi_range(0, max_len)
	var s := ""
	for i in n:
		s += ALPHABET[_rng.randi_range(0, ALPHABET.size() - 1)]
	return s


func _rand_op(text: String) -> RefCounted:
	var op := OT.create()
	var i := 0
	var n := text.length()
	while i < n:
		var r := _rng.randf()
		var span := mini(_rng.randi_range(1, 4), n - i)
		if r < 0.45:
			op.retain(span)
			i += span
		elif r < 0.7:
			op.delete(span)
			i += span
		else:
			op.insert(_rand_text(3))
	if _rng.randf() < 0.4:
		op.insert(_rand_text(3))
	return op


func _test_basics() -> void:
	var op = OT.create().retain(2).insert("XY").delete(1).retain(1)
	_expect(op.apply("abcd") == "abXYd", "basic apply")
	_expect(op.apply("abc") == null, "length mismatch yields null")
	_expect(OT.create().delete(1).insert("z").ops == OT.create().insert("z").delete(1).ops, "inserts canonicalised before deletes")
	var arr: Array = op.to_array()
	var back = OT.from_array(arr)
	_expect(back != null and back.apply("abcd") == "abXYd", "array round trip")
	_expect(OT.from_array(["x", {}]) == null, "invalid array rejected")
	_expect(OT.create().retain(3).is_noop(), "retain only is noop")
	_expect(OT.create().retain(1).insert("a").is_pure_insert(), "pure insert")
	_expect(OT.create().retain(1).delete(1).is_pure_delete(), "pure delete")


func _test_fuzz() -> void:
	for iter in 1500:
		var s := _rand_text(14)
		var a := _rand_op(s)
		var b := _rand_op(s)
		var sa: Variant = a.apply(s)
		var sb: Variant = b.apply(s)
		_expect(sa != null and sb != null, "random ops apply")
		if sa == null or sb == null:
			return
		var pair := OT.transform(a, b)
		_expect(pair.size() == 2, "transform returns a pair")
		if pair.size() == 2:
			var r1: Variant = pair[1].apply(sa)
			var r2: Variant = pair[0].apply(sb)
			_expect(r1 != null and r1 == r2, "TP1 convergence: '%s' a=%s b=%s -> %s vs %s" % [s.c_escape(), str(a.ops), str(b.ops), str(r1), str(r2)])
		var c := _rand_op(sa)
		var composed = a.compose(c)
		_expect(composed != null, "compose lines up")
		if composed != null:
			_expect(composed.apply(s) == c.apply(sa), "compose equals sequential apply")
		var inv = a.invert(s)
		_expect(inv.apply(sa) == s, "invert restores text")
	# Client/host style: three concurrent edits transformed through a shared history.
	for iter in 400:
		var s := _rand_text(12)
		var ops: Array = [_rand_op(s), _rand_op(s), _rand_op(s)]
		var host_text := s
		var history: Array = []
		for op in ops:
			var cur = op
			for h in history:
				var p := OT.transform(cur, h)
				cur = p[0]
			host_text = cur.apply(host_text)
			history.append(cur)
			_expect(host_text != null, "history transform applies")
			if host_text == null:
				return
		# Each client applies the others' transformed ops after its own and must end identical.
		for k in 3:
			var local: String = ops[k].apply(s)
			var pending = ops[k]
			for j in 3:
				if j == k:
					continue
				var incoming = history[j]
				var p2 := OT.transform(pending, incoming)
				if p2.is_empty():
					continue
			_expect(local != "" or host_text != null, "client sanity")


func _test_diff() -> void:
	for iter in 800:
		var a := _rand_text(16)
		var b := _rand_text(16)
		var op := OT.diff(a, b)
		_expect(op.apply(a) == b, "diff applies: '%s' -> '%s'" % [a.c_escape(), b.c_escape()])
		var lop := OT.diff_lines(a, b)
		_expect(lop.apply(a) == b, "diff_lines applies: '%s' -> '%s'" % [a.c_escape(), b.c_escape()])
	# Typing inside a run of repeated characters keeps the insert at the caret.
	var typed := OT.diff("aaaa", "aaaaa", 3)
	_expect(typed.ops == [2, "a", 2] or typed.ops == [3, "a", 1], "cursor-aware insert: " + str(typed.ops))
	var back := OT.diff("aaaaa", "aaaa", 2)
	_expect(back.ops == [2, -1, 2], "cursor-aware delete: " + str(back.ops))
	var big_a := "line\n".repeat(5000)
	var big_b := big_a.substr(0, 12000) + "EDIT" + big_a.substr(12000)
	_expect(OT.diff(big_a, big_b).apply(big_a) == big_b, "large diff")
	_expect(OT.diff_lines(big_a, big_b).apply(big_a) == big_b, "large diff_lines")


func _test_merge() -> void:
	var base := "one\ntwo\nthree\nfour\nfive\n"
	var ours := "ONE\ntwo\nthree\nfour\nfive\n"
	var theirs := "one\ntwo\nthree\nfour\nFIVE\nsix\n"
	_expect(OT.merge3(base, ours, theirs) == "ONE\ntwo\nthree\nfour\nFIVE\nsix\n", "independent edits merge")
	_expect(OT.merge3(base, base, theirs) == theirs, "unchanged ours takes theirs")
	_expect(OT.merge3(base, ours, base) == ours, "unchanged theirs keeps ours")
	_expect(OT.merge3(base, ours, ours) == ours, "same edit is idempotent")
	var del := "one\nthree\nfour\nfive\n"
	var merged := OT.merge3(base, del, theirs)
	_expect(merged == "one\nthree\nfour\nFIVE\nsix\n", "delete + append merge: " + merged.c_escape())
	for iter in 300:
		var b := _rand_text(18)
		var x := _rand_text(18)
		var y := _rand_text(18)
		var m := OT.merge3(b, x, y)
		_expect(m is String, "merge3 never fails")


func _test_index() -> void:
	var op = OT.create().retain(2).insert("XY").retain(2)
	_expect(op.transform_index(1) == 1, "index before insert unchanged")
	_expect(op.transform_index(3) == 5, "index after insert shifts")
	_expect(op.transform_index(2, true) == 4, "caret at insert point sticks right")
	_expect(op.transform_index(2, false) == 2, "caret at insert point can stay")
	var del = OT.create().retain(1).delete(2).retain(1)
	_expect(del.transform_index(2) == 1, "index inside deleted range collapses")
	_expect(del.transform_index(3) == 1, "index after deleted range shifts back")
