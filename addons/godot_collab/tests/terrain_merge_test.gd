extends SceneTree

const TerrainMerge = preload("res://addons/godot_collab/terrain_merge.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var merge := TerrainMerge.new()
	var first := {
		"id": "raise-a",
		"kind": "height_delta",
		"cell": [10, 4],
		"delta": 2.5
	}
	var second := {
		"id": "raise-b",
		"kind": "height_delta",
		"cell": [10, 4],
		"delta": 1.25
	}
	var other_cell := {
		"id": "raise-c",
		"kind": "height_delta",
		"cell": [11, 4],
		"delta": 9.0
	}
	_expect(merge.apply_operation(first).get("status") == "merged", "First sculpt delta should apply.")
	_expect(merge.apply_operation(second).get("status") == "merged", "Overlapping sculpt deltas should merge.")
	_expect(is_equal_approx(merge.height_at(Vector2i(10, 4), 20.0), 23.75), "Same-cell deltas should add.")
	_expect(is_equal_approx(merge.height_at(Vector2i(11, 4), 20.0), 20.0), "Other cells should remain unchanged.")
	_expect(merge.apply_operation(first).get("status") == "duplicate", "Replayed operations should be idempotent.")
	_expect(merge.apply_operation(other_cell).get("status") == "merged", "Disjoint-cell edits should merge.")
	var reverse_merge := TerrainMerge.new()
	reverse_merge.apply_operation(second)
	reverse_merge.apply_operation(first)
	_expect(
		is_equal_approx(
			reverse_merge.height_at(Vector2i(10, 4), 20.0),
			merge.height_at(Vector2i(10, 4), 20.0)
		),
		"Overlapping sculpt deltas should converge regardless of arrival order."
	)

	var paint_a := {
		"id": "paint-a",
		"kind": "cell_value",
		"cell": [2, 8],
		"channel": "material",
		"value": "basalt",
		"actor": "alice",
		"base_revision": 5
	}
	var paint_b := {
		"id": "paint-b",
		"kind": "cell_value",
		"cell": [2, 8],
		"channel": "material",
		"value": "sandstone",
		"actor": "bob",
		"base_revision": 5
	}
	_expect(merge.apply_operation(paint_a).get("status") == "applied", "First material paint should apply.")
	_expect(merge.apply_operation(paint_b).get("status") == "conflict", "Concurrent different paints should be preserved as a conflict.")
	if _failed:
		quit(1)
	else:
		print("Terrain merge tests passed.")
		quit()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)
