extends Node

@export var world_scene: PackedScene


func _ready() -> void:
	print("Starting terrain benchmark:")

	var workers: int = await TerrainBenchmark.ensure_benchmarked()

	print("Benchmark finished! Workers: ", workers)
	print("Selected workers: ", workers)

	print("Loading terrain scene!")

	await get_tree().process_frame

	var error := get_tree().change_scene_to_packed(world_scene)
	if error != OK:
		push_error("Failed to load terrain scene AHSDIASHDSAOIDIASHDIOAHSD errors: " + str(error))
