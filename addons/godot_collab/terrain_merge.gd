extends RefCounted

var _seen_operations: Dictionary = {}
var _height_deltas: Dictionary = {}
var _cell_values: Dictionary = {}


func apply_operation(operation: Dictionary) -> Dictionary:
	var operation_id := str(operation.get("id", ""))
	if operation_id.is_empty():
		return {"status": "invalid", "reason": "Operation id is required."}
	if _seen_operations.has(operation_id):
		return {"status": "duplicate"}

	var kind := str(operation.get("kind", ""))
	var cell_value: Variant = operation.get("cell", null)
	if not cell_value is Array or cell_value.size() != 2:
		return {"status": "invalid", "reason": "Terrain cell must contain two integer coordinates."}
	if typeof(cell_value[0]) != TYPE_INT or typeof(cell_value[1]) != TYPE_INT:
		return {"status": "invalid", "reason": "Terrain cell coordinates must be integers."}
	var cell := Vector2i(int(cell_value[0]), int(cell_value[1]))
	var cell_key := "%d,%d" % [cell.x, cell.y]

	match kind:
		"height_delta":
			var delta_value: Variant = operation.get("delta", null)
			if not delta_value is float and not delta_value is int:
				return {"status": "invalid", "reason": "Height delta must be a number."}
			var delta := float(delta_value)
			if not is_finite(delta):
				return {"status": "invalid", "reason": "Height delta must be finite."}
			var deltas: Dictionary = _height_deltas.get(cell_key, {})
			deltas[operation_id] = delta
			_height_deltas[cell_key] = deltas
			_seen_operations[operation_id] = true
			return {"status": "merged", "cell": cell}

		"cell_value":
			var channel := str(operation.get("channel", ""))
			var actor := str(operation.get("actor", ""))
			var base_revision := int(operation.get("base_revision", -1))
			if channel.is_empty() or channel.length() > 128 or not operation.has("value"):
				return {"status": "invalid", "reason": "Cell value needs a channel and value."}
			if actor.is_empty() or base_revision < 0:
				return {"status": "invalid", "reason": "Cell value needs an actor and non-negative base revision."}
			var value_key := cell_key + "|" + channel
			var writes: Array = _cell_values.get(value_key, [])
			for previous in writes:
				if (
					int(previous.get("base_revision", -1)) == int(operation.get("base_revision", -2))
					and str(previous.get("actor", "")) != str(operation.get("actor", ""))
					and previous.get("value") != operation.get("value")
				):
					writes.append(operation.duplicate(true))
					_cell_values[value_key] = writes
					_seen_operations[operation_id] = true
					return {
						"status": "conflict",
						"cell": cell,
						"channel": channel,
						"operations": writes.duplicate(true)
					}
			writes.append(operation.duplicate(true))
			_cell_values[value_key] = writes
			_seen_operations[operation_id] = true
			return {"status": "applied", "cell": cell, "channel": channel}

		_:
			return {"status": "invalid", "reason": "Unsupported terrain operation: %s" % kind}


func height_at(cell: Vector2i, base_height: float) -> float:
	var cell_key := "%d,%d" % [cell.x, cell.y]
	var deltas: Dictionary = _height_deltas.get(cell_key, {})
	var operation_ids: Array = deltas.keys()
	operation_ids.sort()
	var height := base_height
	for operation_id in operation_ids:
		height += float(deltas[operation_id])
	return height


func reset() -> void:
	_seen_operations.clear()
	_height_deltas.clear()
	_cell_values.clear()
