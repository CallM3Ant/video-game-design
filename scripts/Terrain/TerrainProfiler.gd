extends SceneTree

const TERRAIN_GEN_SCRIPT = preload("res://scripts/Terrain/TerrainGen.gd")
const ACTIVE_CHUNK_SCRIPT = preload("res://scripts/Terrain/TChunk.gd")
const LEGACY_CHUNK_SCRIPT = preload("res://scripts/TChunk.gd")
const CHUNK_MANAGER_SCRIPT = preload("res://scripts/Terrain/ChunkManger.gd")
const GRAPHICS_SETTINGS_SCRIPT = preload("res://scripts/Settings.gd")

const WORLD_SEED := 12345
const CHUNK_SIZE := 64
const GRID_CELLS := 28
const DEFAULT_RADII: Array[int] = [4, 8, 12, 16, 20]
const QUICK_RADII: Array[int] = [4, 8]
const AREA_BATCH_SIZE := 64
const INTEGRATION_FIXTURE_COUNT := 64
const COLLISION_FIXTURE_COUNT := 25
const PROFILE_WAIT_SECONDS := 1.0
const PROFILE_OUTPUT_PREFIX := "user://terrain_profile_"

var _results: Array[Dictionary] = []
var _frame_samples: Array[Dictionary] = []
var _concurrency_levels: Array[int] = []
var _radii: Array[int] = []
var _sample_count := 12000
var _chunk_sample_count := 12
var _quick_mode := false
var _skip_area := false
var _skip_streaming := false
var _profile_id := ""
var _json_path := ""
var _csv_path := ""
var _frame_csv_path := ""
var _best_concurrency := 1
var _last_frame_sample_usec := 0
var _report: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run_profile")


func _run_profile() -> void:
	if not ClassDB.class_exists("TerrainGenerator"):
		push_error("[Profiler] TerrainGenerator extension is not available.")
		quit(1)
		return
	_read_arguments()
	_profile_id = "%d_%d" % [
		int(Time.get_unix_time_from_system()),
		Time.get_ticks_msec(),
	]
	_json_path = PROFILE_OUTPUT_PREFIX + _profile_id + ".json"
	_csv_path = PROFILE_OUTPUT_PREFIX + _profile_id + ".csv"
	_frame_csv_path = PROFILE_OUTPUT_PREFIX + _profile_id + "_frames.csv"
	_concurrency_levels = _get_concurrency_levels()
	_radii = QUICK_RADII.duplicate() if _quick_mode else DEFAULT_RADII.duplicate()

	_report = {
		"profile_id": _profile_id,
		"started_unix_time": Time.get_unix_time_from_system(),
		"engine": Engine.get_version_info(),
		"display_server": DisplayServer.get_name(),
		"logical_processors": OS.get_processor_count(),
		"seed": WORLD_SEED,
		"chunk_size": CHUNK_SIZE,
		"grid_cells": GRID_CELLS,
		"render_radii": _radii,
		"concurrency_levels": _concurrency_levels,
		"quick_mode": _quick_mode,
		"sampling_context": "Standalone SceneTree profiler; timings are not gameplay-scene FPS. Raw frame samples are in the frame CSV.",
		"frame_samples_csv": ProjectSettings.globalize_path(_frame_csv_path),
		"results": _results,
	}

	print("")
	print("========== TERRAIN PROFILE ==========")
	print("Profile ID      : %s" % _profile_id)
	print("Logical CPUs    : %d" % OS.get_processor_count())
	print("Concurrency     : %s" % str(_concurrency_levels))
	print("Render radii    : %s" % str(_radii))
	print("Grid            : %d x %d" % [GRID_CELLS, GRID_CELLS])
	print("Quick mode      : %s" % str(_quick_mode))
	print("JSON output     : %s" % ProjectSettings.globalize_path(_json_path))
	print("CSV output      : %s" % ProjectSettings.globalize_path(_csv_path))
	print("Frame CSV       : %s" % ProjectSettings.globalize_path(_frame_csv_path))
	print("=====================================")
	await _pause_for_operator("Starting math and coordinate tests.")

	await _profile_math()
	_save_report()
	await _pause_for_operator("Math tests done. Next: compare active and legacy chunk builders.")

	await _profile_chunk_builders()
	await _profile_generation_stages()
	_save_report()
	await _pause_for_operator("Chunk builder tests done. Next: cache and collision tests.")

	await _profile_cache_restore()
	await _profile_mesh_cache_budget()
	_profile_mesh_cache_radius_offsets()
	_profile_settings_unload_floor()
	_profile_settings_diffuse_modes()
	await _profile_collision_generation()
	_save_report()
	await _pause_for_operator("Cache and collision tests done. Next: mesh integration.")

	await _profile_mesh_integration()
	_save_report()
	await _pause_for_operator("Mesh integration done. Next: full-area generation sweep.")

	if not _skip_area:
		await _profile_full_areas()
		_save_report()
	else:
		print("[Profiler] Full-area sweep skipped by option.")

	if not _skip_streaming:
		await _profile_live_streaming()
		_save_report()
	else:
		print("[Profiler] Live streaming sweep skipped by option.")

	_report["completed_unix_time"] = Time.get_unix_time_from_system()
	_report["frame_summary"] = _summarize_frames()
	_report["frame_summary_by_phase"] = _summarize_frames_by_phase()
	_save_report(true)

	print("")
	print("========== PROFILE COMPLETE =========")
	print("JSON: %s" % ProjectSettings.globalize_path(_json_path))
	print("CSV : %s" % ProjectSettings.globalize_path(_csv_path))
	print("Frames: %s" % ProjectSettings.globalize_path(_frame_csv_path))
	print("Rows: %d" % _results.size())
	print("Frames sampled: %d" % _frame_samples.size())
	print("Best tested concurrency: %d" % _best_concurrency)
	print("=====================================")
	quit(0)


func _read_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--quick":
			_quick_mode = true
			_sample_count = 2000
			_chunk_sample_count = 4
		elif argument == "--skip-area":
			_skip_area = true
		elif argument == "--skip-streaming":
			_skip_streaming = true
		elif argument.begins_with("--samples="):
			_sample_count = maxi(100, int(argument.get_slice("=", 1)))
		elif argument.begins_with("--chunks="):
			_chunk_sample_count = maxi(1, int(argument.get_slice("=", 1)))


func _get_concurrency_levels() -> Array[int]:
	var logical_count := maxi(1, OS.get_processor_count())
	var candidates: Array[int] = [1, 2, 4, 8, 12, 16, logical_count - 1, logical_count]
	var result: Array[int] = []
	for candidate in candidates:
		var count := clampi(candidate, 1, logical_count)
		if not result.has(count):
			result.append(count)
	result.sort()
	return result


func _pause_for_operator(message: String) -> void:
	print("")
	print("[Profiler] %s Waiting %.1f seconds; use this pause to note the phase." % [
		message, PROFILE_WAIT_SECONDS
	])
	var end_time := Time.get_ticks_msec() + int(PROFILE_WAIT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < end_time:
		await _next_profile_frame("operator_pause")


func _next_profile_frame(phase: String) -> void:
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	_record_frame_sample(phase)


func _record_frame_sample(phase: String) -> void:
	var now_usec := Time.get_ticks_usec()
	var interval_ms := -1.0
	if _last_frame_sample_usec > 0:
		interval_ms = float(now_usec - _last_frame_sample_usec) / 1000.0
	_last_frame_sample_usec = now_usec
	_frame_samples.append({
		"phase": phase,
		"sample_interval_ms": interval_ms,
		"process_monitor_ms": float(Performance.get_monitor(
			Performance.TIME_PROCESS
		)) * 1000.0,
		"physics_monitor_ms": float(Performance.get_monitor(
			Performance.TIME_PHYSICS_PROCESS
		)) * 1000.0,
		"draw_calls": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		)),
		"primitives": int(Performance.get_monitor(
			Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
		)),
		"static_memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"unix_time": Time.get_unix_time_from_system(),
	})


func _wait_for_tasks(
	task_ids: Array[int],
	outputs: Array[Dictionary],
	phase: String
) -> void:
	var last_report_ms := Time.get_ticks_msec()
	while true:
		var all_completed := true
		for task_id in task_ids:
			if not WorkerThreadPool.is_task_completed(task_id):
				all_completed = false
				break
		if all_completed:
			break

		await _next_profile_frame(phase)
		var now := Time.get_ticks_msec()
		if now - last_report_ms >= 3000:
			print("[Profiler] %s still running..." % phase)
			last_report_ms = now

	for task_id in task_ids:
		var wait_error: Error = WorkerThreadPool.wait_for_task_completion(task_id)
		if wait_error != OK:
			push_error("[Profiler] Task %d failed: %s" % [
				task_id, error_string(wait_error)
			])


func _record_result(
	phase: String,
	scenario: String,
	algorithm: String,
	concurrency: int,
	units: int,
	wall_ms: float,
	worker_ms: float,
	checksum: float,
	detail: String
) -> void:
	_results.append({
		"phase": phase,
		"scenario": scenario,
		"algorithm": algorithm,
		"concurrency": concurrency,
		"units": units,
		"wall_ms": wall_ms,
		"worker_ms_sum": worker_ms,
		"average_ms_per_unit": wall_ms / float(maxi(1, units)),
		"checksum": checksum,
		"detail": detail,
	})


func _profile_math() -> void:
	print("[Profiler] Stage 1/7: isolated native scalar calls (production uses bulk generation).")
	var scenarios: Array[String] = ["near", "far", "random"]
	for scenario in scenarios:
		var points := _make_points(scenario, _sample_count)
		var generator: Variant = _create_native_generator()
		var serial_output: Dictionary = {}
		var serial_start := Time.get_ticks_usec()
		_math_worker(points, 0, 1, generator, serial_output)
		var serial_wall := float(Time.get_ticks_usec() - serial_start) / 1000.0
		_record_result(
			"math_serial", scenario, "native_scalar_height+jitter+color",
			1, points.size(), serial_wall,
			float(serial_output.get("worker_ms", 0.0)),
			float(serial_output.get("checksum", 0.0)),
			"Scalar script-to-native calls; production uses bulk native generation. Sub-function timings are in detail."
		)
		_results[_results.size() - 1]["height_ms"] = serial_output.get("height_ms", 0.0)
		_results[_results.size() - 1]["jitter_ms"] = serial_output.get("jitter_ms", 0.0)
		_results[_results.size() - 1]["color_ms"] = serial_output.get("color_ms", 0.0)
		print("  %s serial: %.2f ms (%d points)" % [
			scenario, serial_wall, points.size()
		])

		for concurrency in _concurrency_levels:
			var parallel := await _run_math_parallel(
				points, concurrency, scenario
			)
			_record_result(
				"math_parallel", scenario, "native_scalar_height+jitter+color",
				concurrency, points.size(),
				float(parallel["wall_ms"]),
				float(parallel["worker_ms"]),
				float(parallel["checksum"]),
				"Scalar calls, not bulk generation; worker wall time excludes frame-polling delay."
			)
			print("  %s %d concurrent jobs: %.2f ms" % [
				scenario, concurrency, float(parallel["wall_ms"])
			])


func _math_worker(
	points: Array[Vector2],
	worker_index: int,
	worker_count: int,
	generator: Variant,
	output: Dictionary
) -> void:
	var checksum := 0.0
	var started := Time.get_ticks_usec()
	for index in range(worker_index, points.size(), worker_count):
		var point: Vector2 = points[index]
		checksum += generator.get_height(point.x, point.y)
	var height_ms := float(Time.get_ticks_usec() - started) / 1000.0

	started = Time.get_ticks_usec()
	var cell_size := float(CHUNK_SIZE) / float(GRID_CELLS)
	for index in range(worker_index, points.size(), worker_count):
		var point: Vector2 = points[index]
		var jitter: Vector2 = generator.get_vertex_jitter(
			point.x, point.y, cell_size
		)
		checksum += jitter.x + jitter.y
	var jitter_ms := float(Time.get_ticks_usec() - started) / 1000.0

	started = Time.get_ticks_usec()
	for index in range(worker_index, points.size(), worker_count):
		var point: Vector2 = points[index]
		checksum += generator.get_triangle_color(
			point.x, point.y, 20.0, Vector3.UP
		).r
	var color_ms := float(Time.get_ticks_usec() - started) / 1000.0

	output["height_ms"] = height_ms
	output["jitter_ms"] = jitter_ms
	output["color_ms"] = color_ms
	output["worker_ms"] = height_ms + jitter_ms + color_ms
	output["checksum"] = checksum
	output["completed_usec"] = Time.get_ticks_usec()


func _run_math_parallel(
	points: Array[Vector2],
	concurrency: int,
	scenario: String
) -> Dictionary:
	var task_count := mini(concurrency, points.size())
	var task_ids: Array[int] = []
	var outputs: Array[Dictionary] = []
	var generators := _create_profile_generators(task_count, true)
	var start := Time.get_ticks_usec()

	for worker_index in range(task_count):
		var output: Dictionary = {}
		outputs.append(output)
		var task_id := WorkerThreadPool.add_task(
			Callable(self, "_math_worker").bind(
				points, worker_index, task_count, generators[worker_index], output
			),
			false,
			"Terrain profile math %s %d" % [scenario, worker_index]
		)
		if task_id < 0:
			push_error("[Profiler] Could not schedule math task.")
			return {"wall_ms": 0.0, "worker_ms": 0.0, "checksum": 0.0}
		task_ids.append(task_id)

	await _wait_for_tasks(task_ids, outputs, "math_" + scenario)
	var wall_ms := float(_latest_worker_finish(outputs) - start) / 1000.0
	var worker_ms := 0.0
	var checksum := 0.0
	for output in outputs:
		worker_ms += float(output.get("worker_ms", 0.0))
		checksum += float(output.get("checksum", 0.0))
	return {
		"wall_ms": wall_ms,
		"worker_ms": worker_ms,
		"checksum": checksum,
	}


func _profile_chunk_builders() -> void:
	print("[Profiler] Stage 2/7: native production builder vs legacy GDScript builder.")
	var scenarios: Array[String] = ["near", "far", "random"]
	var levels: Array[int] = []
	for candidate in _concurrency_levels:
		if candidate <= _chunk_sample_count:
			levels.append(candidate)

	var equivalence_ok := _check_builder_equivalence()
	_report["builder_outputs_equivalent"] = equivalence_ok
	_report["builder_equivalence_context"] = \
			"GDScript reference vs legacy; native parity is checked by TerrainNativeParityCheck."
	if not equivalence_ok:
		push_warning("[Profiler] Active and legacy builder outputs differ; inspect the JSON report.")

	for scenario in scenarios:
		var origins := _make_origins(scenario, _chunk_sample_count)
		for algorithm_index in range(2):
			var algorithm := "active_native"
			if algorithm_index == 1:
				algorithm = "legacy_append_indexed"
			for concurrency in levels:
				var result := await _run_chunk_parallel(
					origins, concurrency, algorithm_index, false,
					"chunk_" + scenario
				)
				_record_result(
					"chunk_generation", scenario, algorithm, concurrency,
					origins.size(), float(result["wall_ms"]),
					float(result["worker_ms"]), float(result["checksum"]),
					"Active uses native bulk generation; legacy uses GDScript. Wall time excludes generator setup and frame polling."
				)
				print("  %s / %s / %d jobs: %.2f ms" % [
					scenario, algorithm, concurrency,
					float(result["wall_ms"])
				])

	_best_concurrency = _choose_best_concurrency()
	print("[Profiler] Selected comparison level: %d concurrent jobs." % _best_concurrency)


func _profile_generation_stages() -> void:
	print("[Profiler] Timing terrain sampling and mesh/color stages separately.")
	var origin := Vector3i(256, 0, -320)
	var generator: Variant = _create_native_generator()
	var repetitions := 3 if not _quick_mode else 2
	var sample_times: Array[float] = []
	var compression_times: Array[float] = []
	var mesh_times: Array[float] = []
	var checksum := 0.0

	for repetition in range(repetitions):
		var started := Time.get_ticks_usec()
		var vertex_grid: PackedVector3Array = ACTIVE_CHUNK_SCRIPT._sample_vertex_grid(
			origin, CHUNK_SIZE, GRID_CELLS, generator
		)
		sample_times.append(float(Time.get_ticks_usec() - started) / 1000.0)

		started = Time.get_ticks_usec()
		var height_cache: PackedByteArray = (
			ACTIVE_CHUNK_SCRIPT._compress_vertex_heights(vertex_grid, generator)
		)
		compression_times.append(float(Time.get_ticks_usec() - started) / 1000.0)

		started = Time.get_ticks_usec()
		var mesh_data: Dictionary = ACTIVE_CHUNK_SCRIPT._build_chunk_data(
			origin,
			CHUNK_SIZE,
			GRID_CELLS,
			false,
			generator,
			vertex_grid,
			height_cache
		)
		mesh_times.append(float(Time.get_ticks_usec() - started) / 1000.0)
		checksum += float(mesh_data["vertices"].size())
		mesh_data.clear()
		vertex_grid.clear()
		height_cache.clear()
		await _next_profile_frame("generation_stages")

	_record_result(
		"generation_stage",
		"single_chunk",
		"native_vertex_height_sampling",
		1,
		repetitions,
		_median(sample_times),
		_sum(sample_times),
		checksum,
		"Height sampling includes jitter and all get_height noise evaluations; p50=%.3f ms p95=%.3f ms max=%.3f ms." % [
			_percentile(sample_times, 0.50),
			_percentile(sample_times, 0.95),
			_maximum(sample_times),
		]
	)
	_record_result(
		"generation_stage",
		"single_chunk",
		"native_height_cache_compression",
		1,
		repetitions,
		_median(compression_times),
		_sum(compression_times),
		0.0,
		"ZSTD compression of sampled heights; p50=%.3f ms." % [
			_median(compression_times),
		]
	)
	_record_result(
		"generation_stage",
		"single_chunk",
		"native_mesh_normals_colors_and_cache",
		1,
		repetitions,
		_median(mesh_times),
		_sum(mesh_times),
		checksum,
		"Mesh building includes triangle normals, per-triangle color noise, and compact mesh-cache data; p50=%.3f ms p95=%.3f ms max=%.3f ms." % [
			_percentile(mesh_times, 0.50),
			_percentile(mesh_times, 0.95),
			_maximum(mesh_times),
		]
	)
	print("  Height sampling: %.2f ms; mesh/color: %.2f ms per chunk." % [
		_median(sample_times), _median(mesh_times),
	])
func _check_builder_equivalence() -> bool:
	var origin := Vector3i(-128, 0, 192)
	var generator = TERRAIN_GEN_SCRIPT.new(WORLD_SEED)
	var active: Dictionary = ACTIVE_CHUNK_SCRIPT.generate_chunk_data(
		origin, CHUNK_SIZE, GRID_CELLS, true, generator
	)
	var legacy: Dictionary = LEGACY_CHUNK_SCRIPT.generate_chunk_data(
		origin, CHUNK_SIZE, GRID_CELLS, true, generator
	)
	for key in ["vertices", "normals", "colors", "collision_vertices"]:
		if active[key] != legacy[key]:
			return false
	return true


func _run_chunk_parallel(
	origins: Array[Vector3i],
	concurrency: int,
	algorithm_index: int,
	want_collision: bool,
	phase: String
) -> Dictionary:
	var task_count := mini(concurrency, origins.size())
	var task_ids: Array[int] = []
	var outputs: Array[Dictionary] = []
	var generators := _create_profile_generators(task_count, algorithm_index == 0)
	var start := Time.get_ticks_usec()

	for worker_index in range(task_count):
		var output: Dictionary = {}
		outputs.append(output)
		var task_id := WorkerThreadPool.add_task(
			Callable(self, "_chunk_worker").bind(
				origins, worker_index, task_count, algorithm_index,
				want_collision, generators[worker_index], output
			),
			false,
			"Terrain profile chunks %s %d" % [phase, worker_index]
		)
		if task_id < 0:
			push_error("[Profiler] Could not schedule chunk task.")
			return {"wall_ms": 0.0, "worker_ms": 0.0, "checksum": 0.0}
		task_ids.append(task_id)

	await _wait_for_tasks(task_ids, outputs, phase)
	var wall_ms := float(_latest_worker_finish(outputs) - start) / 1000.0
	var worker_ms := 0.0
	var checksum := 0.0
	for output in outputs:
		worker_ms += float(output.get("worker_ms", 0.0))
		checksum += float(output.get("checksum", 0.0))
	return {
		"wall_ms": wall_ms,
		"worker_ms": worker_ms,
		"checksum": checksum,
	}


func _chunk_worker(
	origins: Array[Vector3i],
	worker_index: int,
	worker_count: int,
	algorithm_index: int,
	want_collision: bool,
	generator: Variant,
	output: Dictionary
) -> void:
	var checksum := 0.0
	var completed := 0
	var started := Time.get_ticks_usec()
	for index in range(worker_index, origins.size(), worker_count):
		var origin: Vector3i = origins[index]
		var data: Dictionary
		if algorithm_index == 0:
			data = ACTIVE_CHUNK_SCRIPT.generate_chunk_data(
				origin, CHUNK_SIZE, GRID_CELLS, want_collision, generator
			)
		else:
			data = LEGACY_CHUNK_SCRIPT.generate_chunk_data(
				origin, CHUNK_SIZE, GRID_CELLS, want_collision, generator
			)
		var vertices: PackedVector3Array = data["vertices"]
		var normals: PackedVector3Array = data["normals"]
		for sample_index in range(0, vertices.size(), 31):
			checksum += vertices[sample_index].y + normals[sample_index].y
		completed += 1
		data.clear()
	output["worker_ms"] = float(Time.get_ticks_usec() - started) / 1000.0
	output["completed_chunks"] = completed
	output["checksum"] = checksum
	output["completed_usec"] = Time.get_ticks_usec()


func _profile_cache_restore() -> void:
	print("[Profiler] Stage 3/7: full generation vs compact-height and mesh-cache restore.")
	var origin := Vector3i(256, 0, -320)
	var generator: Variant = _create_native_generator()
	var data: Dictionary = ACTIVE_CHUNK_SCRIPT.generate_chunk_data(
		origin, CHUNK_SIZE, GRID_CELLS, true, generator
	)
	var mesh_cache: Dictionary = data["mesh_cache"]
	var height_cache: PackedByteArray = data["height_cache"]
	var repetitions := 3 if not _quick_mode else 1

	for mode in ["full_generation", "height_cache_restore", "mesh_cache_restore"]:
		var measurements: Array[float] = []
		var checksum := 0.0
		for repetition in range(repetitions):
			var start := Time.get_ticks_usec()
			var restored: Dictionary
			if mode == "full_generation":
				restored = ACTIVE_CHUNK_SCRIPT.generate_chunk_data(
					origin, CHUNK_SIZE, GRID_CELLS, true, generator
				)
			elif mode == "height_cache_restore":
				restored = ACTIVE_CHUNK_SCRIPT.generate_chunk_data_from_height_cache(
					origin, CHUNK_SIZE, GRID_CELLS, true,
					generator, height_cache
				)
			else:
				restored = ACTIVE_CHUNK_SCRIPT.generate_chunk_data_from_mesh_cache(
					origin, CHUNK_SIZE, GRID_CELLS, true,
					generator, mesh_cache, height_cache
				)
			var elapsed := float(Time.get_ticks_usec() - start) / 1000.0
			measurements.append(elapsed)
			checksum += float(restored["vertices"].size())
			restored.clear()
			await _next_profile_frame("cache_restore")
		_record_result(
			"cache_restore", "single_chunk", mode, 1, repetitions,
			_median(measurements), _sum(measurements), checksum,
			"Median wall time across repeated restores; compare with full_generation."
		)
		print("  %s median: %.2f ms" % [mode, _median(measurements)])


func _profile_mesh_cache_budget() -> void:
	print("[Profiler] Checking bounded and unlimited mesh-cache budgets.")
	var manager: Variant = CHUNK_MANAGER_SCRIPT.new()
	manager.current_center_chunk = Vector2i.ZERO
	manager.set_mesh_cache_budget_mib(1)
	var cache_data := _make_test_mesh_cache_data()
	manager._store_mesh_cache(Vector2i(0, 0), cache_data)
	manager._store_mesh_cache(Vector2i(1, 0), cache_data)

	var bounded_bytes: int = manager.mesh_cache_bytes
	var bounded_entries: int = manager.mesh_cache.size()
	var bounded_ok := bounded_bytes <= 1024 * 1024 and bounded_entries == 1

	manager.set_mesh_cache_budget_mib(0)
	manager._store_mesh_cache(Vector2i(2, 0), cache_data)
	var unlimited_ok: bool = manager.mesh_cache_bytes > 1024 * 1024
	var passed := bounded_ok and unlimited_ok
	_record_result(
		"mesh_cache_budget",
		"1_mib_then_unlimited",
		"lru_eviction_and_zero_limit",
		1,
		manager.mesh_cache.size(),
		0.0,
		0.0,
		float(manager.mesh_cache_bytes),
		"bounded_bytes=%d bounded_entries=%d unlimited_bytes=%d passed=%s" % [
			bounded_bytes, bounded_entries,
			manager.mesh_cache_bytes, str(passed),
		]
	)
	if not passed:
		push_error("[Profiler] Mesh-cache budget behavior failed.")
	manager.free()


func _make_test_mesh_cache_data() -> Dictionary:
	var grid := PackedVector3Array()
	var face_colors := PackedColorArray()
	grid.resize(20 * 1024)
	face_colors.resize(30 * 1024)
	return {
		"grid": grid,
		"face_colors": face_colors,
	}


func _profile_mesh_cache_radius_offsets() -> void:
	var manager: Variant = CHUNK_MANAGER_SCRIPT.new()
	manager.render_radius = 8
	manager.current_center_chunk = Vector2i.ZERO
	manager.set_chunk_cache_radius_offsets(20, 21)
	var cache_data := _make_test_mesh_cache_data()
	var height_data := PackedByteArray()
	height_data.resize(1)
	manager._store_mesh_cache(Vector2i(15, 0), cache_data)
	manager._store_mesh_cache(Vector2i(17, 0), cache_data)
	manager._store_mesh_cache(Vector2i(25, 0), cache_data)
	manager._store_height_cache(Vector2i(15, 0), height_data)
	manager._store_height_cache(Vector2i(17, 0), height_data)
	manager._store_height_cache(Vector2i(25, 0), height_data)
	manager.set_chunk_cache_radius_offsets(6, 7)
	manager._store_mesh_cache(Vector2i(16, 0), cache_data)
	manager._store_height_cache(Vector2i(16, 0), height_data)
	manager.set_chunk_cache_radius_offsets(20, 7)

	var passed: bool = (
		manager.get_mesh_pregen_start_radius() == 9
		and manager.get_preload_radius() == 28
		and manager.get_unload_radius() == 29
		and manager.mesh_cache.has(Vector2i(15, 0))
		and not manager.mesh_cache.has(Vector2i(25, 0))
		and not manager.mesh_cache.has(Vector2i(16, 0))
		and manager.height_cache.has(Vector2i(15, 0))
		and not manager.height_cache.has(Vector2i(25, 0))
		and not manager.height_cache.has(Vector2i(16, 0))
	)
	_record_result(
		"mesh_cache_radii",
		"custom_offsets",
		"pregen_start_end_and_unload",
		1,
		3,
		0.0,
		0.0,
		float(manager.get_preload_radius()),
		"start=%d end=%d unload=%d mesh_pruned=%s height_pruned=%s unload_min_enforced=%s passed=%s" % [
			manager.get_mesh_pregen_start_radius(),
			manager.get_preload_radius(),
			manager.get_unload_radius(),
			str(not manager.mesh_cache.has(Vector2i(25, 0))),
			str(not manager.height_cache.has(Vector2i(25, 0))),
			str(manager.chunk_unload_offset >= manager.mesh_pregen_end_offset + 1),
			str(passed),
		]
	)
	if not passed:
		push_error("[Profiler] Terrain cache radius offsets failed.")
	manager.free()


func _profile_settings_unload_floor() -> void:
	var settings: Variant = GRAPHICS_SETTINGS_SCRIPT.new()
	settings.pending = {
		"mesh_pregen_end_offset": 20,
		"chunk_unload_offset": 21,
	}
	var unload_slider := HSlider.new()
	unload_slider.max_value = 101
	unload_slider.value = 21
	var unload_label := Label.new()
	settings.controls = {
		"chunk_unload_offset": unload_slider,
		"chunk_unload_offset_label": unload_label,
	}

	settings.pending["mesh_pregen_end_offset"] = 30
	settings._sync_chunk_unload_minimum()
	unload_slider.value = 25
	var passed: bool = (
		int(settings.pending["chunk_unload_offset"]) == 31
		and int(unload_slider.min_value) == 31
		and int(unload_slider.value) == 31
		and unload_label.text == "31"
	)
	_record_result(
		"settings_unload_floor",
		"pregen_end_increase",
		"raise_and_lock_unload_slider",
		1,
		1,
		0.0,
		0.0,
		float(settings.pending["chunk_unload_offset"]),
		"minimum=31 slider_min=%d slider_value=%d passed=%s" % [
			int(unload_slider.min_value),
			int(unload_slider.value),
			str(passed),
		]
	)
	if not passed:
		push_error("[Profiler] Graphics unload slider minimum failed.")
	unload_slider.free()
	unload_label.free()
	settings.free()


func _profile_settings_diffuse_modes() -> void:
	var manager: Variant = CHUNK_MANAGER_SCRIPT.new()
	var camera := Camera3D.new()
	root.add_child(camera)
	manager.viewer = camera
	manager.camera = camera
	manager.render_radius = 1
	manager.mesh_pregen_end_offset = 0
	manager.chunk_unload_offset = 1
	manager.terrain_material = StandardMaterial3D.new()
	manager._setup_outline()
	var material: StandardMaterial3D = manager.terrain_material
	var settings: Variant = GRAPHICS_SETTINGS_SCRIPT.new()
	settings.viewport = root
	settings.chunk_manager = manager
	settings._create_interface()
	settings.pending = {
		"scaling_3d_scale": 0.75,
		"scaling_3d_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		"directional_size": 1024,
		"directional_quality": RenderingServer.SHADOW_QUALITY_HARD,
		"terrain_diffuse_mode": BaseMaterial3D.DIFFUSE_TOON,
		"outline_mode": 0,
		"outline_width": 1.0,
		"outline_threshold": 0.04,
		"render_radius": 1,
		"grid_cells": manager.grid_cells,
		"terrain_lod_enabled": false,
		"mesh_cache_budget_mib": 64,
		"mesh_pregen_end_offset": 0,
		"chunk_unload_offset": 1,
	}
	var dropdown: OptionButton = settings.controls["terrain_diffuse_mode"]
	var passed := dropdown.item_count == 4
	for index in range(dropdown.item_count):
		dropdown.select(index)
		dropdown.item_selected.emit(index)
		var applied: bool = settings._apply_graphics()
		passed = passed and applied \
				and material.diffuse_mode == settings.TERRAIN_DIFFUSE_VALUES[index] \
				and manager.terrain_material == material
	settings.original = settings.pending.duplicate(true)
	dropdown.select(0)
	dropdown.item_selected.emit(0)
	settings._reset_settings()
	passed = passed and dropdown.selected == 3 \
			and material.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON
	var outline_dropdown: OptionButton = settings.controls["outline_mode"]
	outline_dropdown.select(1)
	outline_dropdown.item_selected.emit(1)
	settings.controls["outline_width"].value = 6.0
	settings.controls["outline_threshold"].value = 0.08
	settings.controls["outline_width"].value_changed.emit(6.0)
	settings.controls["outline_threshold"].value_changed.emit(0.08)
	var outline_applied: bool = settings._apply_graphics()
	var outline_material := manager.outline_instance.material_override as ShaderMaterial
	var outline_passed: bool = outline_applied and manager.outline_instance.visible \
			and is_equal_approx(outline_material.get_shader_parameter("outline_width"), 6.0) \
			and is_equal_approx(outline_material.get_shader_parameter("edge_threshold"), 0.08)
	if not outline_passed:
		push_error("[Profiler] Outline apply mismatch: applied=%s visible=%s width=%s threshold=%s." % [
			str(outline_applied), str(manager.outline_instance.visible),
			str(outline_material.get_shader_parameter("outline_width")),
			str(outline_material.get_shader_parameter("edge_threshold")),
		])
	settings._reset_settings()
	outline_passed = outline_passed and not manager.outline_instance.visible \
			and outline_dropdown.selected == 0 \
			and is_equal_approx(outline_material.get_shader_parameter("outline_width"), 1.0)
	_record_result(
		"settings_diffuse_modes", "terrain", "apply_and_discard",
		1, dropdown.item_count, 0.0, 0.0, 0.0,
		"Built-in diffuse modes apply and discard correctly; passed=%s." % str(passed)
	)
	if not passed:
		push_error("[Profiler] Terrain diffuse mode settings failed.")
	_record_result(
		"settings_outlines", "screen_space", "apply_and_discard",
		1, 1, 0.0, 0.0, 0.0,
		"Outline on/off, width, threshold and discard; passed=%s." % str(outline_passed)
	)
	if not outline_passed:
		push_error("[Profiler] Screen-space outline settings failed.")
	settings.free()
	manager.free()
	camera.free()


func _profile_collision_generation() -> void:
	print("[Profiler] Stage 4/7: collision-data generation and shape construction.")
	var origins := _make_origins("near", COLLISION_FIXTURE_COUNT)
	var result := await _run_collision_parallel(
		origins, _best_concurrency, "collision_faces"
	)
	_record_result(
		"collision_generation", "nearby_25_chunks",
		"generate_collision_data", _best_concurrency, origins.size(),
		float(result["wall_ms"]), float(result["worker_ms"]),
		float(result["checksum"]), "Collision face data generated on workers."
	)
	print("  Collision data for %d chunks: %.2f ms." % [
		origins.size(), float(result["wall_ms"])
	])
	await _profile_collision_shapes(origins.slice(0, 9))


func _run_collision_parallel(
	origins: Array[Vector3i],
	concurrency: int,
	phase: String
) -> Dictionary:
	var task_count := mini(concurrency, origins.size())
	var task_ids: Array[int] = []
	var outputs: Array[Dictionary] = []
	var generators := _create_profile_generators(task_count, true)
	var start := Time.get_ticks_usec()
	for worker_index in range(task_count):
		var output: Dictionary = {}
		outputs.append(output)
		var task_id := WorkerThreadPool.add_task(
			Callable(self, "_collision_worker").bind(
				origins, worker_index, task_count, generators[worker_index], output
			),
			false,
			"Terrain profile collision %d" % worker_index
		)
		if task_id < 0:
			push_error("[Profiler] Could not schedule collision task.")
			return {"wall_ms": 0.0, "worker_ms": 0.0, "checksum": 0.0}
		task_ids.append(task_id)
	await _wait_for_tasks(task_ids, outputs, phase)

	var worker_ms := 0.0
	var checksum := 0.0
	for output in outputs:
		worker_ms += float(output.get("worker_ms", 0.0))
		checksum += float(output.get("checksum", 0.0))
	return {
		"wall_ms": float(_latest_worker_finish(outputs) - start) / 1000.0,
		"worker_ms": worker_ms,
		"checksum": checksum,
	}


func _collision_worker(
	origins: Array[Vector3i],
	worker_index: int,
	worker_count: int,
	generator: Variant,
	output: Dictionary
) -> void:
	var checksum := 0.0
	var started := Time.get_ticks_usec()
	for index in range(worker_index, origins.size(), worker_count):
		var faces: PackedVector3Array = ACTIVE_CHUNK_SCRIPT.generate_collision_data(
			origins[index], CHUNK_SIZE, generator
		)
		checksum += float(faces.size())
	output["worker_ms"] = float(Time.get_ticks_usec() - started) / 1000.0
	output["checksum"] = checksum
	output["completed_usec"] = Time.get_ticks_usec()


func _profile_collision_shapes(origins: Array[Vector3i]) -> void:
	var task_count := mini(_best_concurrency, origins.size())
	var task_ids: Array[int] = []
	var outputs: Array[Dictionary] = []
	var started := Time.get_ticks_usec()
	for worker_index in range(task_count):
		var generator: Variant = _create_native_generator()
		var output: Dictionary = {}
		outputs.append(output)
		var task_id := WorkerThreadPool.add_task(
			Callable(self, "_collision_fixture_worker").bind(
				origins, worker_index, task_count, generator, output
			),
			false,
			"Terrain collision fixture %d" % worker_index
		)
		if task_id < 0:
			push_error("[Profiler] Could not schedule collision fixture.")
			return
		task_ids.append(task_id)
	await _wait_for_tasks(task_ids, outputs, "collision_shape_fixtures")

	var collision_fixtures: Array[PackedVector3Array] = []
	var worker_ms := 0.0
	for output in outputs:
		worker_ms += float(output.get("worker_ms", 0.0))
		collision_fixtures.append_array(output.get("faces", []))

	var build_times: Array[float] = []
	var bodies: Array[StaticBody3D] = []
	for index in range(collision_fixtures.size()):
		var body := StaticBody3D.new()
		body.position = Vector3(origins[index])
		var collision_node := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		var build_start := Time.get_ticks_usec()
		shape.set_faces(collision_fixtures[index])
		shape.backface_collision = true
		collision_node.shape = shape
		body.add_child(collision_node)
		root.add_child(body)
		build_times.append(float(Time.get_ticks_usec() - build_start) / 1000.0)
		bodies.append(body)
		if (index + 1) % 3 == 0:
			await _next_profile_frame("collision_shape_build")

	var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
	_record_result(
		"collision_shape_build", "nearby_9_chunks",
		"ConcavePolygonShape3D.set_faces", 1, build_times.size(),
		wall_ms, _sum(build_times), float(collision_fixtures.size()),
		"Per-shape p50=%.3f ms p95=%.3f ms max=%.3f ms; fixture worker time sum=%.2f ms." % [
			_percentile(build_times, 0.50),
			_percentile(build_times, 0.95),
			_maximum(build_times),
			worker_ms,
		]
	)
	for body in bodies:
		body.queue_free()
	await process_frame


func _collision_fixture_worker(
	origins: Array[Vector3i],
	worker_index: int,
	worker_count: int,
	generator: Variant,
	output: Dictionary
) -> void:
	var faces_array: Array[PackedVector3Array] = []
	var started := Time.get_ticks_usec()
	for index in range(worker_index, origins.size(), worker_count):
		faces_array.append(
			ACTIVE_CHUNK_SCRIPT.generate_collision_data(
				origins[index], CHUNK_SIZE, generator
			)
		)
	output["faces"] = faces_array
	output["worker_ms"] = float(Time.get_ticks_usec() - started) / 1000.0


func _profile_mesh_integration() -> void:
	print("[Profiler] Stage 5/7: production mesh integration on the main thread.")
	var origins := _make_origins("near", INTEGRATION_FIXTURE_COUNT)
	var generated := await _generate_integration_fixtures(origins, _best_concurrency)
	var fixture_wall := float(generated["wall_ms"])
	var fixture_data: Array[Dictionary] = generated["data"]
	_record_result(
		"integration_fixture_generation", "64_chunks",
		"active_native", _best_concurrency,
		fixture_data.size(), fixture_wall,
		float(generated["worker_ms"]), float(generated["checksum"]),
		"Worker-generated fixture data prepared before main-thread integration."
	)

	var terrain_material := StandardMaterial3D.new()
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.roughness = 1.0
	terrain_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var rock_material := StandardMaterial3D.new()
	rock_material.roughness = 1.0
	rock_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var integrated: Array[Node] = []
	var times: Array[float] = []
	var stage_start := Time.get_ticks_usec()

	for index in range(fixture_data.size()):
		var chunk_data: Dictionary = fixture_data[index]
		var chunk: Variant = ACTIVE_CHUNK_SCRIPT.new()
		chunk.name = "ProfileMesh_%d" % index
		root.add_child(chunk)
		var start := Time.get_ticks_usec()
		chunk.setup_from_data(
			origins[index], CHUNK_SIZE, chunk_data,
			terrain_material, rock_material
		)
		times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		chunk.set_chunk_active(false)
		integrated.append(chunk)
		chunk_data.clear()

		if (index + 1) % 4 == 0:
			await _next_profile_frame("mesh_integration")
			print("  Integrated %d/%d meshes." % [
				index + 1, fixture_data.size()
			])

	var total_integration_ms := float(Time.get_ticks_usec() - stage_start) / 1000.0
	_record_result(
		"mesh_integration", "64_chunks",
		"TChunk.setup_from_data_ArrayMesh", 1, times.size(),
		total_integration_ms, _sum(times), _sum(times),
		"Per-chunk p50=%.3f ms p95=%.3f ms max=%.3f ms; includes ArrayMesh and shadow mesh creation." % [
			_percentile(times, 0.50),
			_percentile(times, 0.95),
			_maximum(times),
		]
	)
	for chunk in integrated:
		chunk.queue_free()
	await process_frame
	await process_frame


func _generate_integration_fixtures(
	origins: Array[Vector3i],
	concurrency: int
) -> Dictionary:
	var task_count := mini(concurrency, origins.size())
	var task_ids: Array[int] = []
	var outputs: Array[Dictionary] = []
	var generators := _create_profile_generators(task_count, true)
	var start := Time.get_ticks_usec()
	for worker_index in range(task_count):
		var output: Dictionary = {}
		outputs.append(output)
		var task_id := WorkerThreadPool.add_task(
			Callable(self, "_integration_fixture_worker").bind(
				origins, worker_index, task_count, generators[worker_index], output
			),
			false,
			"Terrain profile integration fixture %d" % worker_index
		)
		if task_id < 0:
			push_error("[Profiler] Could not schedule integration fixture.")
			return {"wall_ms": 0.0, "worker_ms": 0.0, "data": [], "checksum": 0.0}
		task_ids.append(task_id)
	await _wait_for_tasks(task_ids, outputs, "integration_fixture")

	var worker_ms := 0.0
	var checksum := 0.0
	var all_data: Array[Dictionary] = []
	for output in outputs:
		worker_ms += float(output.get("worker_ms", 0.0))
		checksum += float(output.get("checksum", 0.0))
		all_data.append_array(output.get("data", []))
	return {
		"wall_ms": float(_latest_worker_finish(outputs) - start) / 1000.0,
		"worker_ms": worker_ms,
		"data": all_data,
		"checksum": checksum,
	}


func _integration_fixture_worker(
	origins: Array[Vector3i],
	worker_index: int,
	worker_count: int,
	generator: Variant,
	output: Dictionary
) -> void:
	var data_array: Array[Dictionary] = []
	var checksum := 0.0
	var started := Time.get_ticks_usec()
	for index in range(worker_index, origins.size(), worker_count):
		var data: Dictionary = ACTIVE_CHUNK_SCRIPT.generate_chunk_data(
			origins[index], CHUNK_SIZE, GRID_CELLS, false, generator
		)
		checksum += float(data["vertices"].size())
		data_array.append(data)
	output["data"] = data_array
	output["checksum"] = checksum
	output["worker_ms"] = float(Time.get_ticks_usec() - started) / 1000.0
	output["completed_usec"] = Time.get_ticks_usec()


func _profile_full_areas() -> void:
	print("[Profiler] Stage 6/7: full square-area generation at each render distance.")
	for radius in _radii:
		var all_origins: Array[Vector3i] = []
		for z_offset in range(-radius, radius + 1):
			for x_offset in range(-radius, radius + 1):
				all_origins.append(Vector3i(
					x_offset * CHUNK_SIZE, 0, z_offset * CHUNK_SIZE
				))

		var started := Time.get_ticks_usec()
		var worker_ms := 0.0
		var checksum := 0.0
		var completed := 0
		while completed < all_origins.size():
			var batch_end := mini(completed + AREA_BATCH_SIZE, all_origins.size())
			var batch: Array[Vector3i] = all_origins.slice(completed, batch_end)
			var batch_result := await _run_chunk_parallel(
				batch, _best_concurrency, 0, false,
				"full_area_r%d" % radius
			)
			worker_ms += float(batch_result["worker_ms"])
			checksum += float(batch_result["checksum"])
			completed = batch_end
			if completed == all_origins.size() or completed % (AREA_BATCH_SIZE * 4) == 0:
				print("  Radius %d: %d/%d chunks generated." % [
					radius, completed, all_origins.size()
				])
				_save_report()
				await _short_pause()

		var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
		_record_result(
			"full_area_generation", "square_radius_%d" % radius,
			"active_native", _best_concurrency,
			all_origins.size(), wall_ms, worker_ms, checksum,
			"Full square generation; arrays are discarded in batches to bound memory."
		)
		print("  Radius %d: %d chunks in %.1f seconds (%.2f ms/chunk)." % [
			radius, all_origins.size(), wall_ms / 1000.0,
			wall_ms / float(all_origins.size())
		])
		await _pause_for_operator("Area radius %d complete." % radius)


func _profile_live_streaming() -> void:
	print("[Profiler] Stage 7/7: actual ChunkManager streaming, turning, and retention.")
	for radius in _radii:
		await _profile_one_stream_radius(radius)
		_save_report()
		await _pause_for_operator("Live streaming radius %d complete." % radius)


func _profile_one_stream_radius(radius: int) -> void:
	var benchmark: Node = root.get_node_or_null("TerrainBenchmark")
	if benchmark != null:
		benchmark.set("optimal_worker_count", _best_concurrency)

	var camera := Camera3D.new()
	camera.name = "TerrainProfileCamera"
	camera.position = Vector3(32.0, 30.0, 32.0)
	camera.current = true
	root.add_child(camera)
	await process_frame

	var manager: Variant = CHUNK_MANAGER_SCRIPT.new()
	manager.name = "TerrainProfileChunkManager"
	manager.viewer_path = NodePath("../TerrainProfileCamera")
	manager.render_radius = radius
	manager.forward_cone_angle = 180.0
	manager.nearby_keep_radius = 1
	manager.world_seed = WORLD_SEED
	manager.grid_cells = GRID_CELLS
	root.add_child(manager)

	var phase := "stream_radius_%d" % radius
	var started := Time.get_ticks_usec()
	var last_message := Time.get_ticks_msec()
	var timed_out := false
	while not _manager_visible_work_is_done(manager):
		await _next_profile_frame(phase)
		var elapsed_ms := Time.get_ticks_msec() - last_message
		if elapsed_ms >= 3000:
			print("  Radius %d loading: visible=%d live=%d jobs=%d pending=%d" % [
				radius, manager.visible_chunks.size(),
				manager.chunks.size() + manager.cached_chunks.size(),
				manager.in_flight_lookup.size(),
				manager.pending_chunks.size() - manager.pending_head,
			])
			last_message = Time.get_ticks_msec()
		if Time.get_ticks_usec() - started > 600000000:
			timed_out = true
			break

	var initial_live: int = manager.chunks.size() + manager.cached_chunks.size()
	var initial_visible: int = manager.visible_chunks.size()
	_record_result(
		"live_streaming_load",
		"render_radius_%d" % radius,
		"ChunkManager_180_degree_view", int(manager.worker_count),
		initial_visible, float(Time.get_ticks_usec() - started) / 1000.0,
		0.0, float(initial_live),
		"live=%d visible=%d timeout=%s" % [
			initial_live, initial_visible, str(timed_out)
		]
	)
	print("  Radius %d loaded: visible=%d live=%d elapsed=%.1fs timeout=%s" % [
		radius, initial_visible, initial_live,
		float(Time.get_ticks_usec() - started) / 1000000.0,
		str(timed_out),
	])

	var pregen_started := Time.get_ticks_usec()
	var pregen_wait_started := Time.get_ticks_msec()
	while _manager_pregen_cache_count(manager) < 1 \
			and not _manager_pregen_work_is_done(manager) \
			and Time.get_ticks_msec() - pregen_wait_started < 10000:
		await _next_profile_frame("mesh_cache_pregen")
	if _manager_pregen_cache_count(manager) > 0:
		camera.position.x += 3.0
		camera.force_update_transform()
		await _next_profile_frame("mesh_cache_pregen_refresh")
	while _manager_pregen_cache_count(manager) < 5 \
			and not _manager_pregen_work_is_done(manager) \
			and Time.get_ticks_msec() - pregen_wait_started < 10000:
		await _next_profile_frame("mesh_cache_pregen")
	var pregen_cache_count := _manager_pregen_cache_count(manager)
	var pregen_node_count := _manager_pregen_node_count(manager)
	var pregen_wait_ms := float(Time.get_ticks_usec() - pregen_started) / 1000.0
	_record_result(
		"mesh_cache_pregen",
		"render_radius_%d" % radius,
		"cache_only_mesh_generation",
		int(manager.worker_count),
		pregen_cache_count,
		pregen_wait_ms,
		0.0,
		float(manager.mesh_cache_bytes),
		"preload_mesh_caches=%d preload_chunk_nodes=%d mesh_cache_bytes=%d" % [
			pregen_cache_count, pregen_node_count, manager.mesh_cache_bytes,
		]
	)
	if pregen_cache_count < 5 or pregen_node_count != 0:
		push_error("[Profiler] Cache-only mesh pre-generation failed for radius %d." % radius)

	if radius == 4:
		await _profile_live_lod_toggle(manager)

	var turn_coord := Vector2i(0, -3)
	var turn_chunk: Variant = manager.chunks.get(turn_coord)
	var original_instance_id := 0
	if turn_chunk != null:
		original_instance_id = turn_chunk.get_instance_id()
		camera.rotation.y = PI
		camera.force_update_transform()
		await _wait_for_visibility_transition(manager, turn_coord, false, phase)
		var retained_after_turn: bool = manager.cached_chunks.has(turn_coord)
		camera.rotation.y = 0.0
		camera.force_update_transform()
		await _wait_for_visibility_transition(manager, turn_coord, true, phase)
		var restored_chunk: Variant = manager.chunks.get(turn_coord)
		var same_instance: bool = restored_chunk != null \
				and restored_chunk.get_instance_id() == original_instance_id
		_record_result(
			"turnaround_retention", "render_radius_%d" % radius,
			"resident_chunk_node", int(manager.worker_count), 1,
			0.0, 0.0, float(initial_live),
			"retained_behind=%s same_node_restored=%s live_after=%d" % [
				str(retained_after_turn), str(same_instance),
				manager.chunks.size() + manager.cached_chunks.size(),
			]
		)
		print("  Turnaround: retained_behind=%s same_node_restored=%s" % [
			str(retained_after_turn), str(same_instance)
		])
	else:
		_record_result(
			"turnaround_retention", "render_radius_%d" % radius,
			"resident_chunk_node", int(manager.worker_count), 0,
			0.0, 0.0, 0.0,
			"Chosen test chunk was outside the initial visible sector."
		)

	var live_after_turn: int = manager.chunks.size() + manager.cached_chunks.size()
	_record_result(
		"streaming_residency", "render_radius_%d" % radius,
		"visible_plus_cached_nodes", int(manager.worker_count),
		manager.visible_chunks.size(), 0.0, 0.0,
		float(live_after_turn),
		"mesh_cache=%d height_cache=%d mesh_cache_bytes=%d height_cache_bytes=%d" % [
			manager.mesh_cache.size(), manager.height_cache.size(),
			manager.mesh_cache_bytes, manager.height_cache_bytes,
		]
	)
	if radius == 4:
		await _profile_lod_grid_change(manager)
	manager.set_process(false)
	manager.height_cache_targets.clear()
	manager.pending_height_chunks.clear()
	manager.pending_height_lookup.clear()
	manager.pending_chunks.clear()
	manager.pending_lookup.clear()
	manager.pending_pregen_lookup.clear()
	manager.pending_head = 0
	manager.pending_collision_chunks.clear()
	manager.pending_collision_lookup.clear()
	var cleanup_started := Time.get_ticks_msec()
	while not manager.in_flight_jobs.is_empty() \
			and Time.get_ticks_msec() - cleanup_started < 30000:
		await _next_profile_frame(phase + "_cleanup")
		manager._collect_completed_jobs()
	if not manager.in_flight_jobs.is_empty():
		push_error("[Profiler] Terrain jobs did not finish before radius %d cleanup." % radius)
	manager.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame


func _profile_live_lod_toggle(manager: Variant) -> void:
	var coord: Vector2i = manager.current_center_chunk
	var chunk: Variant = manager.chunks.get(coord)
	var wait_start := Time.get_ticks_msec()
	while chunk != null and chunk.collision_shape_node == null \
			and Time.get_ticks_msec() - wait_start < 3000:
		await _next_profile_frame("lod_collision_wait")
	if chunk == null or chunk.collision_shape_node == null:
		push_error("[Profiler] No collision shape available for live LOD test.")
		return
	var collision_id: int = chunk.collision_shape_node.shape.get_instance_id()
	var cache_hit: bool = manager.mesh_cache.has(coord)
	manager._remove_mesh_cache(coord)
	var started := Time.get_ticks_usec()
	var passed: bool = manager.set_terrain_lod_enabled(true)
	await _wait_for_lod_queue(manager)
	passed = passed and manager.pending_lod_chunks.is_empty() \
			and chunk.terrain_lod_enabled \
			and chunk.terrain_mesh_instance.mesh.surface_get_array_index_len(0) \
					== GRID_CELLS * GRID_CELLS * 6
	passed = bool(manager.set_terrain_lod_enabled(false)) and passed
	passed = bool(manager.set_terrain_lod_enabled(true)) and passed
	await _wait_for_lod_queue(manager)
	for live_chunk in manager.chunks.values() + manager.cached_chunks.values():
		passed = passed and live_chunk.terrain_lod_enabled
	passed = bool(manager.set_terrain_lod_enabled(false)) and passed
	await _wait_for_lod_queue(manager)
	var collision_unchanged: bool = chunk.collision_shape_node != null \
			and chunk.collision_shape_node.shape.get_instance_id() == collision_id
	passed = passed and manager.pending_lod_chunks.is_empty() \
			and not chunk.terrain_lod_enabled \
			and chunk.terrain_mesh_instance.mesh.surface_get_array_index_len(0) == 0 \
			and collision_unchanged and cache_hit
	_record_result(
		"live_lod_toggle", "cached_and_uncached_chunks",
		"enable_rapid_toggle_disable", 1, manager.chunks.size(),
		float(Time.get_ticks_usec() - started) / 1000.0, 0.0, 0.0,
		"cache_hit=%s collision_unchanged=%s passed=%s" % [
			str(cache_hit), str(collision_unchanged), str(passed)
		]
	)
	if not passed:
		push_error("[Profiler] Live terrain LOD toggle failed.")


func _wait_for_lod_queue(manager: Variant) -> void:
	var started := Time.get_ticks_msec()
	while not manager.pending_lod_chunks.is_empty() \
			and Time.get_ticks_msec() - started < 10000:
		await _next_profile_frame("live_lod_toggle")


func _profile_lod_grid_change(manager: Variant) -> void:
	var enabled: bool = manager.set_terrain_lod_enabled(true)
	var in_flight: int = manager.in_flight_jobs.size()
	var changed: bool = manager.set_grid_cells(15)
	var started := Time.get_ticks_usec()
	while not _manager_visible_work_is_done(manager) \
			and Time.get_ticks_usec() - started < 30000000:
		await _next_profile_frame("lod_grid_change")
	var chunk: Variant = manager.chunks.get(manager.current_center_chunk)
	var passed: bool = enabled and changed \
			and _manager_visible_work_is_done(manager) \
			and chunk != null and chunk.terrain_lod_enabled
	if passed:
		passed = chunk.terrain_mesh_instance.mesh.surface_get_array_index_len(0) \
				== 15 * 15 * 6
	_record_result(
		"live_lod_grid_change", "28_to_15_cells",
		"rebuild_with_lod_and_in_flight_jobs", int(manager.worker_count),
		manager.chunks.size(), float(Time.get_ticks_usec() - started) / 1000.0,
		0.0, float(in_flight),
		"in_flight_before_change=%d passed=%s" % [in_flight, str(passed)]
	)
	if not passed:
		push_error("[Profiler] Terrain LOD grid-size change failed.")


func _manager_visible_work_is_done(manager: Variant) -> bool:
	for coord in manager.visible_chunks:
		if not manager.chunks.has(coord):
			return false
	if not manager.pending_collision_chunks.is_empty():
		return false
	if not manager.in_flight_collision_lookup.is_empty():
		return false
	for task_id in manager.in_flight_jobs:
		var job: Dictionary = manager.in_flight_jobs[task_id]
		if job.get("kind", "chunk") == "chunk":
			return false
	if manager.completed_head < manager.completed_chunk_data.size():
		return false
	return true


func _manager_pregen_work_is_done(manager: Variant) -> bool:
	return manager.pending_pregen_lookup.is_empty() \
			and manager.in_flight_pregen_lookup.is_empty()


func _manager_pregen_cache_count(manager: Variant) -> int:
	var count := 0
	for coord in manager.mesh_cache:
		var distance: int = manager._chunk_distance(
			coord, manager.current_center_chunk
		)
		if not manager.visible_chunks.has(coord) \
				and distance >= manager.get_mesh_pregen_start_radius() \
				and distance <= mini(
					manager.get_preload_radius(), manager.get_unload_radius()
				):
			count += 1
	return count


func _manager_pregen_node_count(manager: Variant) -> int:
	var count := 0
	for coord in manager.chunks:
		var distance: int = manager._chunk_distance(
			coord, manager.current_center_chunk
		)
		if not manager.visible_chunks.has(coord) \
				and distance >= manager.get_mesh_pregen_start_radius() \
				and distance <= mini(
					manager.get_preload_radius(), manager.get_unload_radius()
				):
			count += 1
	for coord in manager.cached_chunks:
		var distance: int = manager._chunk_distance(
			coord, manager.current_center_chunk
		)
		if not manager.visible_chunks.has(coord) \
				and distance >= manager.get_mesh_pregen_start_radius() \
				and distance <= mini(
					manager.get_preload_radius(), manager.get_unload_radius()
				):
			count += 1
	return count


func _wait_for_visibility_transition(
	manager: Variant,
	coord: Vector2i,
	want_visible: bool,
	phase: String
) -> void:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 3000:
		await _next_profile_frame(phase)
		if want_visible and manager.chunks.has(coord):
			return
		if not want_visible and manager.cached_chunks.has(coord):
			return


func _make_points(scenario: String, count: int) -> Array[Vector2]:
	var points: Array[Vector2] = []
	var random := RandomNumberGenerator.new()
	random.seed = WORLD_SEED + scenario.hash()
	for index in range(count):
		if scenario == "near":
			points.append(Vector2(
				float((index % 129) * 32),
				float((index / 129) * 32)
			))
		elif scenario == "far":
			points.append(Vector2(
				1000000.0 + float(index % 4096) * 64.0,
				-1000000.0 + float(index / 4096) * 64.0
			))
		else:
			points.append(Vector2(
				random.randf_range(-1000000.0, 1000000.0),
				random.randf_range(-1000000.0, 1000000.0)
			))
	return points


func _make_origins(scenario: String, count: int) -> Array[Vector3i]:
	var origins: Array[Vector3i] = []
	var random := RandomNumberGenerator.new()
	random.seed = WORLD_SEED + scenario.hash()
	for index in range(count):
		var x := 0
		var z := 0
		if scenario == "near":
			x = (index % 8) * CHUNK_SIZE
			z = (index / 8) * CHUNK_SIZE
		elif scenario == "far":
			x = 1000000 + (index % 8) * CHUNK_SIZE
			z = -1000000 + (index / 8) * CHUNK_SIZE
		else:
			x = random.randi_range(-1000000, 1000000)
			z = random.randi_range(-1000000, 1000000)
		origins.append(Vector3i(x, 0, z))
	return origins


func _choose_best_concurrency() -> int:
	var timings_by_level: Dictionary = {}
	for result in _results:
		if result["phase"] != "chunk_generation" \
				or result["algorithm"] != "active_native":
			continue
		var level := int(result["concurrency"])
		if not timings_by_level.has(level):
			timings_by_level[level] = []
		timings_by_level[level].append(float(result["wall_ms"]))
	var best_count := 1
	var best_time := INF
	for concurrency in timings_by_level:
		var values: Array[float] = []
		for value in timings_by_level[concurrency]:
			values.append(float(value))
		var elapsed := _median(values)
		if elapsed < best_time:
			best_time = elapsed
			best_count = int(concurrency)
	return best_count


func _create_native_generator() -> Variant:
	var generator: Variant = ClassDB.instantiate("TerrainGenerator")
	generator.initialize(WORLD_SEED)
	return generator


func _create_profile_generators(count: int, native: bool) -> Array:
	var generators: Array = []
	for worker_index in range(count):
		generators.append(
			_create_native_generator() if native else TERRAIN_GEN_SCRIPT.new(WORLD_SEED)
		)
	return generators


func _latest_worker_finish(outputs: Array[Dictionary]) -> int:
	var latest := 0
	for output in outputs:
		if not output.has("completed_usec"):
			push_error("[Profiler] Terrain worker returned no completion time.")
			return 0
		latest = maxi(latest, int(output["completed_usec"]))
	return latest


func _short_pause() -> void:
	await create_timer(0.05).timeout


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var middle := sorted_values.size() / 2
	if sorted_values.size() % 2 == 1:
		return sorted_values[middle]
	return (sorted_values[middle - 1] + sorted_values[middle]) * 0.5


func _percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var index := clampi(
		ceili(float(sorted_values.size() - 1) * percentile),
		0,
		sorted_values.size() - 1
	)
	return sorted_values[index]


func _maximum(values: Array[float]) -> float:
	var maximum := 0.0
	for value in values:
		maximum = maxf(maximum, value)
	return maximum


func _sum(values: Array[float]) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total


func _summarize_frames() -> Dictionary:
	var intervals: Array[float] = []
	var process_monitor_times: Array[float] = []
	var physics_monitor_times: Array[float] = []
	var operator_pause_samples := 0
	for sample in _frame_samples:
		if sample["phase"] == "operator_pause":
			operator_pause_samples += 1
			continue
		var interval := float(sample["sample_interval_ms"])
		if interval >= 0.0:
			intervals.append(interval)
		process_monitor_times.append(float(sample["process_monitor_ms"]))
		physics_monitor_times.append(float(sample["physics_monitor_ms"]))
	return {
		"sample_count": intervals.size(),
		"operator_pause_samples_excluded": operator_pause_samples,
		"sample_interval_p50_ms": _percentile(intervals, 0.50),
		"sample_interval_p95_ms": _percentile(intervals, 0.95),
		"sample_interval_p99_ms": _percentile(intervals, 0.99),
		"sample_interval_max_ms": _maximum(intervals),
		"process_monitor_p95_ms": _percentile(process_monitor_times, 0.95),
		"process_monitor_max_ms": _maximum(process_monitor_times),
		"physics_monitor_p95_ms": _percentile(physics_monitor_times, 0.95),
		"physics_monitor_max_ms": _maximum(physics_monitor_times),
	}


func _summarize_frames_by_phase() -> Dictionary:
	var grouped: Dictionary = {}
	for sample in _frame_samples:
		var phase := str(sample["phase"])
		if not grouped.has(phase):
			grouped[phase] = {
				"intervals": [],
				"process_monitors": [],
				"physics_monitors": [],
			}
		var group: Dictionary = grouped[phase]
		var interval := float(sample["sample_interval_ms"])
		if interval >= 0.0:
			group["intervals"].append(interval)
		group["process_monitors"].append(float(sample["process_monitor_ms"]))
		group["physics_monitors"].append(float(sample["physics_monitor_ms"]))
		grouped[phase] = group

	var summaries: Dictionary = {}
	for phase in grouped:
		var group: Dictionary = grouped[phase]
		var intervals: Array[float] = []
		var process_times: Array[float] = []
		var physics_times: Array[float] = []
		for value in group["intervals"]:
			intervals.append(float(value))
		for value in group["process_monitors"]:
			process_times.append(float(value))
		for value in group["physics_monitors"]:
			physics_times.append(float(value))
		summaries[phase] = {
			"sample_count": process_times.size(),
			"sample_interval_p50_ms": _percentile(intervals, 0.50),
			"sample_interval_p95_ms": _percentile(intervals, 0.95),
			"sample_interval_max_ms": _maximum(intervals),
			"process_monitor_p95_ms": _percentile(process_times, 0.95),
			"process_monitor_max_ms": _maximum(process_times),
			"physics_monitor_p95_ms": _percentile(physics_times, 0.95),
			"physics_monitor_max_ms": _maximum(physics_times),
		}
	return summaries


func _save_report(write_frame_csv: bool = false) -> void:
	_report["results"] = _results
	_report["frame_sample_count"] = _frame_samples.size()
	_report["frame_summary"] = _summarize_frames()
	_report["frame_summary_by_phase"] = _summarize_frames_by_phase()
	var json_file := FileAccess.open(_json_path, FileAccess.WRITE)
	if json_file == null:
		push_error("[Profiler] Could not write JSON report: %s" % error_string(
			FileAccess.get_open_error()
		))
	else:
		json_file.store_string(JSON.stringify(_report, "\t"))
		json_file.close()

	var csv_file := FileAccess.open(_csv_path, FileAccess.WRITE)
	if csv_file == null:
		push_error("[Profiler] Could not write CSV report: %s" % error_string(
			FileAccess.get_open_error()
		))
		return
	csv_file.store_line(
		"phase,scenario,algorithm,concurrency,units,wall_ms,worker_ms_sum,average_ms_per_unit,checksum,detail"
	)
	for result in _results:
		var fields: Array[String] = []
		for key in [
			"phase", "scenario", "algorithm", "concurrency",
			"units", "wall_ms", "worker_ms_sum",
			"average_ms_per_unit", "checksum", "detail",
		]:
			fields.append(_csv_escape(str(result.get(key, ""))))
		csv_file.store_line(",".join(fields))
	csv_file.close()

	if not write_frame_csv:
		return

	var frame_file := FileAccess.open(_frame_csv_path, FileAccess.WRITE)
	if frame_file == null:
		push_error("[Profiler] Could not write frame CSV: %s" % error_string(
			FileAccess.get_open_error()
		))
		return
	frame_file.store_line(
		"phase,sample_interval_ms,process_monitor_ms,physics_monitor_ms,draw_calls,primitives,static_memory_bytes,unix_time"
	)
	for sample in _frame_samples:
		var fields: Array[String] = []
		for key in [
			"phase", "sample_interval_ms", "process_monitor_ms",
			"physics_monitor_ms", "draw_calls", "primitives",
			"static_memory_bytes", "unix_time",
		]:
			fields.append(_csv_escape(str(sample.get(key, ""))))
		frame_file.store_line(",".join(fields))
	frame_file.close()


func _csv_escape(value: String) -> String:
	return "\"" + value.replace("\"", "\"\"") + "\""
