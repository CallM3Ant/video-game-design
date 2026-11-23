extends SceneTree

const Diff3 := preload("res://addons/godot_collab/core/diff3.gd")

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
	var base := "a\nb\nc\nd\ne\nf\n"
	# Independent edits far apart merge cleanly.
	var r: Dictionary = Diff3.merge(base, "A\nb\nc\nd\ne\nf\n", "a\nb\nc\nd\ne\nF\n")
	_expect(r.clean and r.text == "A\nb\nc\nd\ne\nF\n", "far apart edits merge: " + str(r))
	# One side unchanged.
	r = Diff3.merge(base, base, "a\nB\nc\nd\ne\nf\n")
	_expect(r.clean and r.text == "a\nB\nc\nd\ne\nf\n", "unchanged ours takes theirs")
	r = Diff3.merge(base, "a\nB\nc\nd\ne\nf\n", base)
	_expect(r.clean and r.text == "a\nB\nc\nd\ne\nf\n", "unchanged theirs keeps ours")
	# Identical edits are not conflicts.
	r = Diff3.merge(base, "a\nX\nc\nd\ne\nf\n", "a\nX\nc\nd\ne\nf\n")
	_expect(r.clean, "identical edits do not conflict")
	# Overlapping edits conflict and keep both versions.
	r = Diff3.merge(base, "a\nOURS\nc\nd\ne\nf\n", "a\nTHEIRS\nc\nd\ne\nf\n")
	_expect(not r.clean and r.conflicts.size() == 1, "overlapping edits conflict")
	_expect(r.text.contains("<<<<<<<") and r.text.contains("OURS") and r.text.contains("THEIRS") and r.text.contains(">>>>>>>"), "markers keep both: " + r.text.c_escape())
	_expect(r.conflicts[0].base == "b\n" and r.conflicts[0].ours == "OURS\n" and r.conflicts[0].theirs == "THEIRS\n", "conflict regions reported")
	# Insert on one side, delete elsewhere on the other.
	r = Diff3.merge(base, "a\nb\nNEW\nc\nd\ne\nf\n", "a\nb\nc\nd\ne\n")
	_expect(r.clean and r.text == "a\nb\nNEW\nc\nd\ne\n", "insert and delete merge: " + r.text.c_escape())
	# Both append at the end differently: conflict.
	r = Diff3.merge("x\n", "x\nmine\n", "x\ntheirs\n")
	_expect(not r.clean, "competing appends conflict")
	# Empty base (file created on both sides).
	r = Diff3.merge("", "one\n", "two\n")
	_expect(not r.clean, "both created different content conflicts")
	r = Diff3.merge("", "same\n", "same\n")
	_expect(r.clean and r.text == "same\n", "both created same content")
	# CRLF files keep their line endings.
	r = Diff3.merge("a\r\nb\r\nc\r\n", "A\r\nb\r\nc\r\n", "a\r\nb\r\nC\r\n")
	_expect(r.clean and r.text == "A\r\nb\r\nC\r\n", "crlf merge: " + r.text.c_escape())
	# Large file with edits at both ends.
	var big := "line\n".repeat(3000)
	var o := "TOP\n" + big
	var t := big + "BOTTOM\n"
	r = Diff3.merge(big, o, t)
	_expect(r.clean and r.text == "TOP\n" + big + "BOTTOM\n", "large merge")
	if _failed > 0:
		printerr("diff3 tests failed: %d of %d" % [_failed, _checks])
		quit(1)
	else:
		print("diff3 tests passed (%d checks)." % _checks)
		quit()
