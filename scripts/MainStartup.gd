extends Control

@export var world_scene: PackedScene

func _ready() -> void:
	var workers: int = await TerrainBenchmark.ensure_benchmarked()

	print("Terrain workers selected: ", workers)

	get_tree().change_scene_to_packed(world_scene)
