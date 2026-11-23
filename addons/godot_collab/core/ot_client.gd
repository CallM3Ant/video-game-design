@tool
extends RefCounted
## Client half of the text OT protocol (the "synchronized / awaiting / awaiting with buffer"
## state machine of ot.js). One instance per open document.
##
## Local edits are applied to the editor immediately and sent to the host one at a time; edits made
## while waiting for the host's acknowledgement are composed into a buffer and sent afterwards.
## Edits from other people are transformed against whatever is still in flight.

const OT := preload("res://addons/godot_collab/core/ot.gd")

signal send_op(rev: int, op: RefCounted, cseq: int)

var rev := 0
var epoch := ""
var cid := ""
var outstanding: RefCounted = null
var outstanding_cseq := 0
var buffer: RefCounted = null
var cseq := 0


func _init() -> void:
	cid = "%08x%04x" % [randi(), randi() & 0xffff]


func reset(new_rev: int, new_epoch: String) -> void:
	rev = new_rev
	epoch = new_epoch
	outstanding = null
	buffer = null


func has_pending() -> bool:
	return outstanding != null


## True when a broadcast op is our own outstanding op coming back (the host's acknowledgement).
func is_own(by: String, my_uid: String, op_cid: String, op_cseq: int) -> bool:
	return outstanding != null and by == my_uid and op_cid == cid and op_cseq == outstanding_cseq


## A local edit was already applied to the editor; queue it for the host.
func apply_client(op: RefCounted) -> void:
	if outstanding == null:
		cseq += 1
		outstanding = op
		outstanding_cseq = cseq
		send_op.emit(rev, op, cseq)
	elif buffer == null:
		buffer = op
	else:
		var composed: RefCounted = buffer.compose(op)
		buffer = composed if composed != null else op


## The host confirmed our outstanding op.
func server_ack() -> void:
	rev += 1
	if buffer != null:
		cseq += 1
		outstanding = buffer
		outstanding_cseq = cseq
		buffer = null
		send_op.emit(rev, outstanding, cseq)
	else:
		outstanding = null


## Someone else's op arrived (already in host terms). Returns the op to apply to the local text,
## or null if the operations do not line up (the caller should resynchronise).
func apply_server(op: RefCounted) -> RefCounted:
	rev += 1
	if outstanding != null:
		var pair: Array = OT.transform(outstanding, op)
		if pair.is_empty():
			return null
		outstanding = pair[0]
		op = pair[1]
		if buffer != null:
			var pair2: Array = OT.transform(buffer, op)
			if pair2.is_empty():
				return null
			buffer = pair2[0]
			op = pair2[1]
	return op


## After a reconnect: send again whatever the host may not have received.
func resend() -> void:
	if outstanding != null:
		send_op.emit(rev, outstanding, outstanding_cseq)
