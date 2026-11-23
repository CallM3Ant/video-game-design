@tool
extends RefCounted
## Host-side live text document (one per file somebody has open in an editor). It orders edits and
## transforms late ones against everything that happened since the revision the sender had seen.

const OT := preload("res://addons/godot_collab/core/ot.gd")
const MAX_HISTORY := 4000

var path := ""
var epoch := ""
var text := ""
var rev := 0
## history[i] = [op, by_uid, cseq, cid] moved the document from revision (history_base + i).
var history: Array = []
var history_base := 0
var watchers := {}       # peer id -> true
var last_cseq := {}      # "uid|cid" -> highest cseq applied (drops duplicates after reconnects)
var missing := false     # created for a file the host does not have yet


func _init(p_path: String = "", p_text: String = "") -> void:
	path = p_path
	text = p_text.replace("\r\n", "\n")
	epoch = "%x%x" % [randi(), Time.get_ticks_usec()]


## Returns the op transformed into current-document terms, or null if it cannot be applied.
func receive(client_rev: int, op: RefCounted, by_uid: String, cseq: int, cid: String = "") -> RefCounted:
	if client_rev < history_base or client_rev > rev:
		return null
	for i in range(client_rev - history_base, history.size()):
		var pair: Array = OT.transform(op, history[i][0])
		if pair.is_empty():
			return null
		op = pair[0]
	var next_text: Variant = op.apply(text)
	if next_text == null:
		return null
	text = next_text
	history.append([op, by_uid, cseq, cid])
	rev += 1
	missing = false
	last_cseq[by_uid + "|" + cid] = cseq
	if history.size() > MAX_HISTORY:
		history.pop_front()
		history_base += 1
	return op


func is_duplicate(by_uid: String, cseq: int, cid: String = "") -> bool:
	return cseq <= int(last_cseq.get(by_uid + "|" + cid, 0))


## Operations since `from_rev` as wire data, or null if that history has been dropped.
func ops_since(from_rev: int) -> Variant:
	if from_rev < history_base or from_rev > rev:
		return null
	var out := []
	for i in range(from_rev - history_base, history.size()):
		var h: Array = history[i]
		out.append([h[0].to_array(), h[1], h[2], h[3]])
	return out
