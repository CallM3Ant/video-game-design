@tool
extends RefCounted
## Line-based three-way merge (diff3) with real conflict detection. Used when two people changed
## the same closed file independently. Non-overlapping edits merge; overlapping edits are reported
## as conflicts so somebody can decide instead of silently losing work.

const MAX_LCS_CELLS := 6000000


static func split_lines(text: String) -> PackedStringArray:
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


## For each line of `a`, the index of the matching line in `b` (longest common subsequence) or -1.
static func _match_lines(a: PackedStringArray, b: PackedStringArray) -> PackedInt32Array:
	var map := PackedInt32Array()
	map.resize(a.size())
	map.fill(-1)
	var head := 0
	while head < a.size() and head < b.size() and a[head] == b[head]:
		map[head] = head
		head += 1
	var tail := 0
	while tail < a.size() - head and tail < b.size() - head and a[a.size() - 1 - tail] == b[b.size() - 1 - tail]:
		map[a.size() - 1 - tail] = b.size() - 1 - tail
		tail += 1
	var n := a.size() - head - tail
	var m := b.size() - head - tail
	if n <= 0 or m <= 0 or n * m > MAX_LCS_CELLS:
		return map
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
			map[head + i2] = head + j2
			i2 += 1
			j2 += 1
		elif table[(i2 + 1) * w + j2] >= table[i2 * w + j2 + 1]:
			i2 += 1
		else:
			j2 += 1
	return map


static func _join(lines: PackedStringArray, from: int, to: int) -> String:
	if to <= from:
		return ""
	return "".join(lines.slice(from, to))


## Returns {"text": merged text (conflicts rendered with <<<<<<< markers), "clean": bool,
## "conflicts": Array of {"base","ours","theirs"} strings}.
static func merge(base: String, ours: String, theirs: String, ours_label: String = "mine", theirs_label: String = "theirs") -> Dictionary:
	if ours == theirs:
		return {"text": ours, "clean": true, "conflicts": []}
	if base == ours:
		return {"text": theirs, "clean": true, "conflicts": []}
	if base == theirs:
		return {"text": ours, "clean": true, "conflicts": []}
	var b := split_lines(base)
	var o := split_lines(ours)
	var t := split_lines(theirs)
	var om := _match_lines(b, o)
	var tm := _match_lines(b, t)
	var out := PackedStringArray()
	var conflicts: Array = []
	var bp := 0
	var op := 0
	var tp := 0
	var i := 0
	while i <= b.size():
		var sync := i == b.size() or (om[i] >= 0 and tm[i] >= 0 and om[i] >= op and tm[i] >= tp)
		if not sync:
			i += 1
			continue
		var bi := i
		var oi := o.size() if i == b.size() else om[i]
		var ti := t.size() if i == b.size() else tm[i]
		var base_chunk := _join(b, bp, bi)
		var ours_chunk := _join(o, op, oi)
		var theirs_chunk := _join(t, tp, ti)
		if ours_chunk == base_chunk:
			out.append(theirs_chunk)
		elif theirs_chunk == base_chunk or ours_chunk == theirs_chunk:
			out.append(ours_chunk)
		else:
			conflicts.append({"base": base_chunk, "ours": ours_chunk, "theirs": theirs_chunk})
			var o_text := ours_chunk if ours_chunk.is_empty() or ours_chunk.ends_with("\n") else ours_chunk + "\n"
			var t_text := theirs_chunk if theirs_chunk.is_empty() or theirs_chunk.ends_with("\n") else theirs_chunk + "\n"
			out.append("<<<<<<< %s\n%s=======\n%s>>>>>>> %s\n" % [ours_label, o_text, t_text, theirs_label])
		if i < b.size():
			out.append(b[i])
			bp = i + 1
			op = oi + 1
			tp = ti + 1
		i += 1
	return {"text": "".join(out), "clean": conflicts.is_empty(), "conflicts": conflicts}
