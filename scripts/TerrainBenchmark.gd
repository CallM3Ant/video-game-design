# AI SCRIPT
extends Node

const TERRAIN_GEN_SCRIPT = preload("res://scripts/TerrainGen.gd")

const WORLD_SEED: int = 12345

const CHUNK_SIZE: int = 64
const GRID_CELLS: int = 28

const TEST_CHUNKS: int = 16
const WARMUP_ROUNDS: int = 1
const TEST_ROUNDS: int = 3

const ACCEPTABLE_DIFFERENCE: float = 0.05

const DEBUG_BENCHMARK: bool = true

# Increase this whenever the benchmark's generation code changes.
const BENCHMARK_VERSION: int = 3

# Rebenchmark after this many launches.
const REBENCHMARK_EVERY: int = 5

const CACHE_PATH: String = "user://terrain_worker_benchmark.cfg"

var optimal_worker_count: int = 1
var detected_logical_threads: int = 1

var is_benchmarking: bool = false
var benchmark_progress: float = 0.0

var _benchmark_finished := false
var _origins: Array[Vector2i] = []


func _ready() -> void:
	print("[Terrain] Autoload loaded!")


func ensure_benchmarked() -> int:
	detected_logical_threads = maxi(1, OS.get_processor_count())

	if is_benchmarking:
		while is_benchmarking:
			await get_tree().process_frame
		return optimal_worker_count

	if _load_cached_result():
		var launches := _get_launch_count() + 1
		_set_launch_count(launches)

		if launches < REBENCHMARK_EVERY:
			if DEBUG_BENCHMARK:
				print("[Terrain] Using cached result: %d workers (%d/%d launches)" % [
					optimal_worker_count,
					launches,
					REBENCHMARK_EVERY
				])
			return optimal_worker_count

		if DEBUG_BENCHMARK:
			print("[Terrain] Scheduled rebenchmark.")

	return await run_benchmark()


func run_benchmark() -> int:
	if is_benchmarking:
		while is_benchmarking:
			await get_tree().process_frame
		return optimal_worker_count

	is_benchmarking = true
	benchmark_progress = 0.0

	detected_logical_threads = maxi(1, OS.get_processor_count())
	_origins = _make_origins(TEST_CHUNKS)

	if DEBUG_BENCHMARK:
		print("")
		print("========== TERRAIN BENCHMARK ==========")
		print("CPU threads : %d" % detected_logical_threads)
		print("Test chunks : %d" % TEST_CHUNKS)
		print("Warmup      : %d" % WARMUP_ROUNDS)
		print("Test rounds : %d" % TEST_ROUNDS)
		print("=======================================")
		print("")

	var worker_counts: Array[int] = _get_worker_counts()
	var results: Dictionary = {}

	for i in range(worker_counts.size()):
		var worker_count: int = worker_counts[i]

		if DEBUG_BENCHMARK:
			print("[Terrain] Testing %d workers..." % worker_count)

		for warmup_index in range(WARMUP_ROUNDS):
			await _run_parallel_round(worker_count)

		var measurements: Array[float] = []

		for round_index in range(TEST_ROUNDS):
			var elapsed_ms: float = await _run_parallel_round(worker_count)
			measurements.append(elapsed_ms)

			if DEBUG_BENCHMARK:
				print("  Run %d: %.2f ms" % [round_index + 1, elapsed_ms])

		var median_ms: float = _get_median(measurements)
		results[worker_count] = median_ms

		if DEBUG_BENCHMARK:
			print("  Median: %.2f ms" % median_ms)
			print("")

		benchmark_progress = float(i + 1) / float(worker_counts.size())

	var fastest_time: float = INF

	for worker_count in worker_counts:
		fastest_time = minf(fastest_time, float(results[worker_count]))

	var acceptable_time: float = fastest_time * (1.0 + ACCEPTABLE_DIFFERENCE)

	optimal_worker_count = worker_counts[worker_counts.size() - 1]

	for worker_count in worker_counts:
		if float(results[worker_count]) <= acceptable_time:
			optimal_worker_count = worker_count
			break

	_save_cached_result()
	_set_launch_count(0)

	is_benchmarking = false
	benchmark_progress = 1.0

	if DEBUG_BENCHMARK:
		print("========== BENCHMARK DONE =============")
		print("Fastest time : %.2f ms" % fastest_time)
		print("5%% limit     : %.2f ms" % acceptable_time)
		print("CPU threads  : %d" % detected_logical_threads)
		print("Using        : %d workers" % optimal_worker_count)
		print("Next test    : in %d launches" % REBENCHMARK_EVERY)
		print("=======================================")
		print("")

	return optimal_worker_count


func _get_worker_counts() -> Array[int]:
	var candidates: Array[int] = [1, 2, 4, 8, 12, 16, 24, 32]

	if not candidates.has(detected_logical_threads):
		candidates.append(detected_logical_threads)

	var valid_counts: Array[int] = []

	for count in candidates:
		if count <= detected_logical_threads and count <= TEST_CHUNKS:
			if not valid_counts.has(count):
				valid_counts.append(count)

	valid_counts.sort()
	return valid_counts


func _run_parallel_round(worker_count: int) -> float:
	var task_ids: Array[int] = []
	var outputs: Array[Dictionary] = []
	var generators: Array = []

	for worker_index in range(worker_count):
		generators.append(TERRAIN_GEN_SCRIPT.new(WORLD_SEED))

	var start_time: int = Time.get_ticks_usec()

	for worker_index in range(worker_count):
		var output: Dictionary = {}
		outputs.append(output)

		var task_id: int = WorkerThreadPool.add_task(
			Callable(self, "_worker_batch").bind(
				worker_index,
				worker_count,
				_origins,
				generators[worker_index],
				output
			),
			false,
			"Terrain benchmark worker " + str(worker_index)
		)

		task_ids.append(task_id)

	var all_completed := false

	while not all_completed:
		all_completed = true

		for task_id in task_ids:
			if not WorkerThreadPool.is_task_completed(task_id):
				all_completed = false
				break

		if not all_completed:
			await get_tree().process_frame

	for task_id in task_ids:
		WorkerThreadPool.wait_for_task_completion(task_id)

	var end_time: int = Time.get_ticks_usec()

	var checksum: float = 0.0

	for output in outputs:
		checksum += float(output.get("checksum", 0.0))

	if checksum == -INF:
		push_warning("Unexpected benchmark checksum.")

	return float(end_time - start_time) / 1000.0


func _worker_batch(
	worker_index: int,
	worker_count: int,
	origins: Array[Vector2i],
	generator: Variant,
	output: Dictionary
) -> void:
	var checksum: float = 0.0
	var chunk_index: int = worker_index

	while chunk_index < origins.size():
		checksum += _generate_chunk_cpu(origins[chunk_index], generator)
		chunk_index += worker_count

	output["checksum"] = checksum


func _generate_chunk_cpu(
	origin: Vector2i,
	generator: Variant
) -> float:
	var cell_size: float = float(CHUNK_SIZE) / float(GRID_CELLS)
	var side: int = GRID_CELLS + 1

	var vertex_cache := PackedVector3Array()
	vertex_cache.resize(side * side)

	for x in range(side):
		for z in range(side):
			var world_x: float = float(origin.x) + float(x) * cell_size
			var world_z: float = float(origin.y) + float(z) * cell_size

			var jitter: Vector2 = generator.get_vertex_jitter(
				world_x, world_z, cell_size
			)

			var height: float = generator.get_height(
				world_x + jitter.x,
				world_z + jitter.y
			)

			vertex_cache[x * side + z] = Vector3(
				float(x) * cell_size + jitter.x,
				height,
				float(z) * cell_size + jitter.y
			)

	var total_vertices: int = GRID_CELLS * GRID_CELLS * 6

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	vertices.resize(total_vertices)
	normals.resize(total_vertices)
	colors.resize(total_vertices)

	var vertex_index := 0

	for x in range(GRID_CELLS):
		for z in range(GRID_CELLS):
			var v00: Vector3 = vertex_cache[x * side + z]
			var v01: Vector3 = vertex_cache[x * side + z + 1]
			var v10: Vector3 = vertex_cache[(x + 1) * side + z]
			var v11: Vector3 = vertex_cache[(x + 1) * side + z + 1]

			if (x + z) % 2 == 0:
				vertex_index = _write_triangle(v00, v01, v11, origin, generator, vertices, normals, colors, vertex_index)
				vertex_index = _write_triangle(v00, v11, v10, origin, generator, vertices, normals, colors, vertex_index)
			else:
				vertex_index = _write_triangle(v00, v01, v10, origin, generator, vertices, normals, colors, vertex_index)
				vertex_index = _write_triangle(v10, v01, v11, origin, generator, vertices, normals, colors, vertex_index)

	var checksum := 0.0

	for i in range(0, vertices.size(), 17):
		checksum += vertices[i].y
		checksum += normals[i].y
		checksum += colors[i].r
		checksum += colors[i].g

	return checksum


func _write_triangle(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	origin: Vector2i,
	generator: Variant,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	vertex_index: int
) -> int:
	var normal: Vector3 = (c - a).cross(b - a).normalized()

	if normal.y < 0.0:
		normal = -normal

	var center: Vector3 = (a + b + c) / 3.0

	var color: Color = generator.get_triangle_color(
		float(origin.x) + center.x,
		float(origin.y) + center.z,
		center.y,
		normal
	)

	vertices[vertex_index] = a
	vertices[vertex_index + 1] = b
	vertices[vertex_index + 2] = c

	normals[vertex_index] = normal
	normals[vertex_index + 1] = normal
	normals[vertex_index + 2] = normal

	colors[vertex_index] = color
	colors[vertex_index + 1] = color
	colors[vertex_index + 2] = color

	return vertex_index + 3


func _get_median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0

	var sorted_values: Array[float] = values.duplicate()
	sorted_values.sort()

	var middle: int = sorted_values.size() / 2

	if sorted_values.size() % 2 == 1:
		return sorted_values[middle]

	return (sorted_values[middle - 1] + sorted_values[middle]) * 0.5


func _make_origins(count: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var width: int = ceili(sqrt(float(count)))

	for i in range(count):
		var x: int = i % width
		var z: int = int(i / width)

		result.append(Vector2i(x * CHUNK_SIZE, z * CHUNK_SIZE))

	return result


func _get_launch_count() -> int:
	var config := ConfigFile.new()

	if config.load(CACHE_PATH) != OK:
		return 0

	return int(config.get_value("benchmark", "launch_count", 0))


func _set_launch_count(count: int) -> void:
	var config := ConfigFile.new()

	config.load(CACHE_PATH)
	config.set_value("benchmark", "launch_count", count)

	var error := config.save(CACHE_PATH)

	if error != OK:
		push_warning("Could not update terrain benchmark launch count.")


func _load_cached_result() -> bool:
	var config := ConfigFile.new()

	if config.load(CACHE_PATH) != OK:
		return false

	var saved_version: int = int(config.get_value("benchmark", "version", -1))
	var saved_threads: int = int(config.get_value("benchmark", "logical_threads", -1))
	var saved_workers: int = int(config.get_value("benchmark", "workers", 0))

	if saved_version != BENCHMARK_VERSION:
		return false

	if saved_threads != detected_logical_threads:
		return false

	if saved_workers < 1 or saved_workers > detected_logical_threads:
		return false

	optimal_worker_count = saved_workers
	return true


func _save_cached_result() -> void:
	var config := ConfigFile.new()

	config.set_value("benchmark", "version", BENCHMARK_VERSION)
	config.set_value("benchmark", "logical_threads", detected_logical_threads)
	config.set_value("benchmark", "workers", optimal_worker_count)
	config.set_value("benchmark", "launch_count", 0)

	var error: Error = config.save(CACHE_PATH)

	if error != OK:
		push_warning("Could not save terrain benchmark result.")
