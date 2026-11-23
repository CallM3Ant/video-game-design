@tool
extends RefCounted
## Operational transformation for plain text (the algorithm popularised by ot.js).
##
## An operation is a list of components: a positive int retains n characters, a negative int
## deletes n characters and a String inserts text. The host orders operations and every client
## transforms concurrent edits against each other, so all copies converge on the same text.
##
## Offsets are Godot String indices (Unicode code points). Text must use "\n" line endings.

const SELF_PATH := "res://addons/godot_collab/core/ot.gd"
const FAST_COMPARE_CHUNK := 256
const MAX_LCS_CELLS := 4000000

static var _cls: GDScript = null

var ops: Array = []
var base_length := 0
var target_length := 0


static func create() -> RefCounted:
	if _cls == null:
		_cls = load(SELF_PATH)
	return _cls.new()


static func _is_retain(c: Variant) -> bool:
	return typeof(c) == TYPE_INT and c > 0


static func _is_delete(c: Variant) -> bool:
	return typeof(c) == TYPE_INT and c < 0


static func _is_insert(c: Variant) -> bool:
	return typeof(c) == TYPE_STRING


static func _at(arr: Array, i: int) -> Variant:
	return arr[i] if i < arr.size() else null


func retain(n: int) -> RefCounted:
	if n <= 0:
		return self
	base_length += n
	target_length += n
	if not ops.is_empty() and _is_retain(ops[-1]):
		ops[-1] += n
	else:
		ops.append(n)
	return self


func insert(s: String) -> RefCounted:
	if s.is_empty():
		return self
	target_length += s.length()
	if not ops.is_empty() and _is_insert(ops[-1]):
		ops[-1] += s
	elif not ops.is_empty() and _is_delete(ops[-1]):
		# Canonical form keeps inserts in front of deletes so equal operations compare equal.
		if ops.size() >= 2 and _is_insert(ops[-2]):
			ops[-2] += s
		else:
			var last: Variant = ops[-1]
			ops[-1] = s
			ops.append(last)
	else:
		ops.append(s)
	return self


func delete(n: int) -> RefCounted:
	if n == 0:
		return self
	if n > 0:
		n = -n
	base_length -= n
	if not ops.is_empty() and _is_delete(ops[-1]):
		ops[-1] += n
	else:
		ops.append(n)
	return self


func is_noop() -> bool:
	return ops.is_empty() or (ops.size() == 1 and _is_retain(ops[0]))


func is_pure_insert() -> bool:
	for c in ops:
		if _is_delete(c):
			return false
	return not is_noop()


func is_pure_delete() -> bool:
	for c in ops:
		if _is_insert(c):
			return false
	return not is_noop()


## Applies the operation. Returns null when the text length does not match the operation.
func apply(text: String) -> Variant:
	if text.length() != base_length:
		return null
	var parts := PackedStringArray()
	var idx := 0
	for c in ops:
		if _is_retain(c):
			if idx + c > text.length():
				return null
			parts.append(text.substr(idx, c))
			idx += c
		elif _is_insert(c):
			parts.append(c)
		else:
			idx -= c
	if idx != text.length():
		return null
	return "".join(parts)


## The operation that undoes this one when applied to the text it produced.
func invert(text: String) -> RefCounted:
	var inv := create()
	var idx := 0
	for c in ops:
		if _is_retain(c):
			inv.retain(c)
			idx += c
		elif _is_insert(c):
			inv.delete(c.length())
		else:
			inv.insert(text.substr(idx, -c))
			idx -= c
	return inv


## Maps an offset in the old text to the matching offset in the new text.
## `stick_right` decides whether a caret exactly at an insertion point moves after the insert.
func transform_index(index: int, stick_right: bool = true) -> int:
	var old_pos := 0
	var new_pos := 0
	for c in ops:
		if _is_retain(c):
			if index < old_pos + c:
				return new_pos + (index - old_pos)
			old_pos += c
			new_pos += c
		elif _is_insert(c):
			if index == old_pos and not stick_right:
				return new_pos
			new_pos += c.length()
		else:
			if index < old_pos - c:
				return new_pos
			old_pos -= c
	return new_pos + (index - old_pos)


## Equivalent to applying self and then `other`; null if they do not line up.
func compose(other: RefCounted) -> RefCounted:
	if target_length != other.base_length:
		return null
	var out := create()
	var ops1: Array = ops
	var ops2: Array = other.ops
	var i1 := 0
	var i2 := 0
	var op1: Variant = _at(ops1, i1)
	i1 += 1
	var op2: Variant = _at(ops2, i2)
	i2 += 1
	while true:
		if op1 == null and op2 == null:
			break
		if _is_delete(op1):
			out.delete(op1)
			op1 = _at(ops1, i1)
			i1 += 1
			continue
		if _is_insert(op2):
			out.insert(op2)
			op2 = _at(ops2, i2)
			i2 += 1
			continue
		if op1 == null or op2 == null:
			return null
		if _is_retain(op1) and _is_retain(op2):
			if op1 > op2:
				out.retain(op2)
				op1 = op1 - op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == op2:
				out.retain(op1)
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				out.retain(op1)
				op2 = op2 - op1
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_insert(op1) and _is_delete(op2):
			if op1.length() > -op2:
				op1 = op1.substr(-op2)
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1.length() == -op2:
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				op2 = op2 + op1.length()
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_insert(op1) and _is_retain(op2):
			if op1.length() > op2:
				out.insert(op1.substr(0, op2))
				op1 = op1.substr(op2)
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1.length() == op2:
				out.insert(op1)
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				out.insert(op1)
				op2 = op2 - op1.length()
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_retain(op1) and _is_delete(op2):
			if op1 > -op2:
				out.delete(op2)
				op1 = op1 + op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == -op2:
				out.delete(op2)
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				out.delete(op1)
				op2 = op2 + op1
				op1 = _at(ops1, i1)
				i1 += 1
		else:
			return null
	return out


## For two operations made concurrently on the same text returns [a', b'] such that
## apply(apply(s, a), b') == apply(apply(s, b), a'). Returns [] when they do not line up.
## When both insert at the same position, `a`'s text goes first.
static func transform(a: RefCounted, b: RefCounted) -> Array:
	if a.base_length != b.base_length:
		return []
	var a2 := create()
	var b2 := create()
	var ops1: Array = a.ops
	var ops2: Array = b.ops
	var i1 := 0
	var i2 := 0
	var op1: Variant = _at(ops1, i1)
	i1 += 1
	var op2: Variant = _at(ops2, i2)
	i2 += 1
	while true:
		if op1 == null and op2 == null:
			break
		if _is_insert(op1):
			a2.insert(op1)
			b2.retain(op1.length())
			op1 = _at(ops1, i1)
			i1 += 1
			continue
		if _is_insert(op2):
			a2.retain(op2.length())
			b2.insert(op2)
			op2 = _at(ops2, i2)
			i2 += 1
			continue
		if op1 == null or op2 == null:
			return []
		var minl := 0
		if _is_retain(op1) and _is_retain(op2):
			if op1 > op2:
				minl = op2
				op1 = op1 - op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == op2:
				minl = op2
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				minl = op1
				op2 = op2 - op1
				op1 = _at(ops1, i1)
				i1 += 1
			a2.retain(minl)
			b2.retain(minl)
		elif _is_delete(op1) and _is_delete(op2):
			if -op1 > -op2:
				op1 = op1 - op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == op2:
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				op2 = op2 - op1
				op1 = _at(ops1, i1)
				i1 += 1
		elif _is_delete(op1) and _is_retain(op2):
			if -op1 > op2:
				minl = op2
				op1 = op1 + op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif -op1 == op2:
				minl = op2
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				minl = -op1
				op2 = op2 + op1
				op1 = _at(ops1, i1)
				i1 += 1
			a2.delete(minl)
		elif _is_retain(op1) and _is_delete(op2):
			if op1 > -op2:
				minl = -op2
				op1 = op1 + op2
				op2 = _at(ops2, i2)
				i2 += 1
			elif op1 == -op2:
				minl = op1
				op1 = _at(ops1, i1)
				i1 += 1
				op2 = _at(ops2, i2)
				i2 += 1
			else:
				minl = op1
				op2 = op2 + op1
				op1 = _at(ops1, i1)
				i1 += 1
			b2.delete(minl)
		else:
			return []
	return [a2, b2]


# --- serialisation --------------------------------------------------------------------------

func to_array() -> Array:
	return ops.duplicate()


static func from_array(arr: Variant) -> RefCounted:
	if not arr is Array:
		return null
	var op := create()
	for c in arr:
		if typeof(c) == TYPE_INT or typeof(c) == TYPE_FLOAT:
			var n := int(c)
			if n > 0:
				op.retain(n)
			elif n < 0:
				op.delete(-n)
		elif typeof(c) == TYPE_STRING:
			op.insert(c)
		else:
			return null
	return op


# --- building operations from two texts -------------------------------------------------------

## One operation turning `before` into `after`: common prefix/suffix kept, the middle replaced.
## `cursor` (caret offset in `after`) disambiguates where inserted/deleted text really was when
## it sits inside a run of repeated characters.
static func diff(before: String, after: String, cursor: int = -1) -> RefCounted:
	var op := create()
	var bl := before.length()
	var al := after.length()
	if before == after:
		op.retain(bl)
		return op
	var minl := mini(bl, al)
	var p := 0
	while p + FAST_COMPARE_CHUNK <= minl and before.substr(p, FAST_COMPARE_CHUNK) == after.substr(p, FAST_COMPARE_CHUNK):
		p += FAST_COMPARE_CHUNK
	while p < minl and before.unicode_at(p) == after.unicode_at(p):
		p += 1
	var s := 0
	var room := minl - p
	while s + FAST_COMPARE_CHUNK <= room and before.substr(bl - s - FAST_COMPARE_CHUNK, FAST_COMPARE_CHUNK) == after.substr(al - s - FAST_COMPARE_CHUNK, FAST_COMPARE_CHUNK):
		s += FAST_COMPARE_CHUNK
	while s < room and before.unicode_at(bl - 1 - s) == after.unicode_at(al - 1 - s):
		s += 1
	if cursor >= 0:
		if bl == p + s and al > bl:
			var d := al - bl
			var q := cursor - d
			if q >= 0 and q <= bl and q != p and before.substr(0, q) + after.substr(q, d) + before.substr(q) == after:
				p = q
				s = bl - q
		elif al == p + s and bl > al:
			var d2 := bl - al
			var q2 := cursor
			if q2 >= 0 and q2 + d2 <= bl and q2 != p and before.substr(0, q2) + before.substr(q2 + d2) == after:
				p = q2
				s = bl - q2 - d2
	op.retain(p)
	op.delete(bl - p - s)
	op.insert(after.substr(p, al - p - s))
	op.retain(s)
	return op


static func _split_lines(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var pos := 0
	var n := text.length()
	while pos < n:
		var nl := text.find("\n", pos)
		if nl == -1:
			out.append(text.substr(pos))
			break
		out.append(text.substr(pos, nl - pos + 1))
		pos = nl + 1
	return out


## Line-granular diff (longest common subsequence of lines). Good for merging independent edits.
static func diff_lines(before: String, after: String) -> RefCounted:
	var op := create()
	if before == after:
		op.retain(before.length())
		return op
	var a := _split_lines(before)
	var b := _split_lines(after)
	var head := 0
	while head < a.size() and head < b.size() and a[head] == b[head]:
		head += 1
	var tail := 0
	while tail < a.size() - head and tail < b.size() - head and a[a.size() - 1 - tail] == b[b.size() - 1 - tail]:
		tail += 1
	var head_chars := 0
	for i in head:
		head_chars += a[i].length()
	var tail_chars := 0
	for i in tail:
		tail_chars += a[a.size() - 1 - i].length()
	op.retain(head_chars)
	var n := a.size() - head - tail
	var m := b.size() - head - tail
	if n * m > MAX_LCS_CELLS or n == 0 or m == 0:
		for i in n:
			op.delete(a[head + i].length())
		for j in m:
			op.insert(b[head + j])
	else:
		var w := m + 1
		var table := PackedInt32Array()
		table.resize((n + 1) * w)
		for i in range(n - 1, -1, -1):
			for j in range(m - 1, -1, -1):
				if a[head + i] == b[head + j]:
					table[i * w + j] = table[(i + 1) * w + j + 1] + 1
				else:
					table[i * w + j] = maxi(table[(i + 1) * w + j], table[i * w + j + 1])
		var i2 := 0
		var j2 := 0
		while i2 < n and j2 < m:
			if a[head + i2] == b[head + j2]:
				op.retain(a[head + i2].length())
				i2 += 1
				j2 += 1
			elif table[(i2 + 1) * w + j2] >= table[i2 * w + j2 + 1]:
				op.delete(a[head + i2].length())
				i2 += 1
			else:
				op.insert(b[head + j2])
				j2 += 1
		while i2 < n:
			op.delete(a[head + i2].length())
			i2 += 1
		while j2 < m:
			op.insert(b[head + j2])
			j2 += 1
	op.retain(tail_chars)
	return op


## Merges two independent edits of `base` without ever failing: every non-overlapping change from
## both sides survives; where both sides rewrote the same lines both rewrites are kept.
static func merge3(base: String, ours: String, theirs: String) -> String:
	if ours == theirs:
		return ours
	if base == ours:
		return theirs
	if base == theirs:
		return ours
	var a := diff_lines(base, ours)
	var b := diff_lines(base, theirs)
	var pair := transform(a, b)
	if pair.is_empty():
		return ours
	var merged: Variant = pair[1].apply(ours)
	if merged == null:
		return ours
	return merged
