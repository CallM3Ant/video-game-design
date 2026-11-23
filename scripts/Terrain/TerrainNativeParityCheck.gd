extends SceneTree

const SCRIPT_GENERATOR = preload("res://scripts/Terrain/TerrainGen.gd")
const CHUNK = preload("res://scripts/Terrain/TChunk.gd")
const MANAGER = preload("res://scripts/Terrain/ChunkManger.gd")
const GRAPHICS_SETTINGS = preload("res://scripts/Settings.gd")

class ScriptPathAdapter:
	extends RefCounted
	var generator: Object

	func _init(p_generator: Object) -> void:
		generator = p_generator

	func get_height(x: float, z: float) -> float:
		return generator.get_height(x, z)

	func get_vertex_jitter(x: float, z: float, cell_size: float) -> Vector2:
		return generator.get_vertex_jitter(x, z, cell_size)

	func get_triangle_color(x: float, z: float, height: float, normal: Vector3) -> Color:
		return generator.get_triangle_color(x, z, height, normal)

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var script_generator = SCRIPT_GENERATOR.new(12345)
	var native_generator: Object = ClassDB.instantiate(&"TerrainGenerator")
	if native_generator == null:
		push_error("TerrainGenerator GDExtension failed to instantiate.")
		quit(1)
		return
	native_generator.call("initialize", 12345)

	var positions := [
		Vector2.ZERO,
		Vector2(-1000.0, 2500.0),
		Vector2(731.0, 1300.0),
		Vector2(-6400.0, -9200.0),
	]
	for position in positions:
		var script_height: float = script_generator.get_height(position.x, position.y)
		var native_height: float = native_generator.call(
			"get_height", position.x, position.y
		)
		var script_jitter: Vector2 = script_generator.get_vertex_jitter(
			position.x, position.y, 2.0
		)
		var native_jitter: Vector2 = native_generator.call(
			"get_vertex_jitter", position.x, position.y, 2.0
		)
		var normal := Vector3(0.3, 0.9, -0.2).normalized()
		var script_color: Color = script_generator.get_triangle_color(
			position.x, position.y, script_height, normal
		)
		var native_color: Color = native_generator.call(
			"get_triangle_color", position.x, position.y, native_height, normal
		)
		var color_difference := maxf(
			maxf(absf(script_color.r - native_color.r), absf(script_color.g - native_color.g)),
			maxf(absf(script_color.b - native_color.b), absf(script_color.a - native_color.a))
		)
		if absf(script_height - native_height) > 0.001 \
				or script_jitter.distance_to(native_jitter) > 0.001 \
				or color_difference > 0.001:
			push_error(
				"Terrain generator mismatch at %s: height %s vs %s, jitter %s vs %s, color %s vs %s"
				% [position, script_height, native_height, script_jitter, native_jitter, script_color, native_color]
			)
			quit(1)
			return

	if not _check_chunk_pipeline(native_generator) \
			or not _check_lod_topology(native_generator) \
			or not _check_mesh_cache_scheduling() \
			or not _check_lod_settings(native_generator):
		quit(1)
		return
	if not await _check_benchmark_timing(native_generator):
		quit(1)
		return

	print("[TerrainNativeParityCheck] Noise, mesh, cache, and collision checks passed.")
	quit()


func _check_benchmark_timing(generator: Object) -> bool:
	var benchmark: Variant = root.get_node_or_null("TerrainBenchmark")
	if benchmark == null:
		push_error("Terrain benchmark autoload is unavailable.")
		return false
	benchmark._origins = benchmark._make_origins(benchmark.TEST_CHUNKS)
	var generators: Array[Object] = [generator]
	var previous_max_fps := Engine.max_fps
	Engine.max_fps = 2
	await process_frame
	var started := Time.get_ticks_usec()
	var measured_ms: float = await benchmark._run_parallel_round(1, generators)
	var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
	Engine.max_fps = previous_max_fps
	if measured_ms <= 0.0 or wall_ms < 100.0 or measured_ms >= wall_ms * 0.75:
		push_error("Terrain benchmark timing included frame polling: %.2f / %.2f ms." % [
			measured_ms, wall_ms
		])
		return false
	print("[TerrainNativeParityCheck] Worker timing excludes frame polling: %.2f / %.2f ms." % [
		measured_ms, wall_ms
	])
	return true


func _check_mesh_cache_scheduling() -> bool:
	var manager: Variant = MANAGER.new()
	manager.current_center_chunk = Vector2i.ZERO
	manager.render_radius = 1
	manager.mesh_pregen_end_offset = 2
	manager.chunk_unload_offset = 3
	var grid := PackedVector3Array()
	var colors := PackedColorArray()
	grid.resize(29 * 29)
	colors.resize(28 * 28 * 2)
	var cache := {"grid": grid, "face_colors": colors}
	var entry_bytes: int = manager._estimated_mesh_cache_bytes()
	manager.mesh_cache_budget_bytes = entry_bytes * 4
	var far_coords := [
		Vector2i(3, 3), Vector2i(3, 2), Vector2i(3, 1), Vector2i(3, 0)
	]
	for coord in far_coords:
		manager._store_mesh_cache(coord, cache)
	manager._get_mesh_cache(far_coords[0])
	manager.mesh_cache_budget_bytes = entry_bytes * 3
	manager._enforce_mesh_cache_budget()
	if not manager.mesh_cache.has(far_coords[0]) \
			or manager.mesh_cache.has(far_coords[1]):
		push_error("Mesh-cache eviction did not preserve the most recently used entry.")
		manager.free()
		return false
	manager.mesh_cache_budget_bytes = entry_bytes * 4
	manager._store_mesh_cache(far_coords[1], cache)
	manager.visible_chunks[Vector2i.ZERO] = true
	manager._queue_visible_mesh_chunks()
	if manager.pending_chunks[0] != Vector2i.ZERO \
			or manager.pending_pregen_lookup.size() != 4:
		push_error("Bounded pre-generation did not prioritize visible and nearer chunks.")
		manager.free()
		return false
	for coord in manager.pending_pregen_lookup:
		manager._store_pregen_mesh_cache(coord, cache)
	manager._queue_visible_mesh_chunks()
	if not manager.pending_pregen_lookup.is_empty() \
			or manager.mesh_cache_bytes != entry_bytes * 4:
		push_error("Full mesh cache churned or exceeded its budget.")
		manager.free()
		return false
	manager.current_center_chunk = Vector2i(1, 0)
	manager._queue_visible_mesh_chunks()
	if manager.pending_pregen_lookup.is_empty():
		push_error("A full mesh cache did not schedule nearer chunks after movement.")
		manager.free()
		return false
	var next_coord: Vector2i = manager.pending_pregen_lookup.keys()[0]
	manager._store_pregen_mesh_cache(next_coord, cache)
	if not manager.mesh_cache.has(next_coord) \
			or manager.mesh_cache_bytes != entry_bytes * 4:
		push_error("Pre-generation could not replace a farther cache entry.")
		manager.free()
		return false
	manager.mesh_cache_budget_bytes = 0
	manager._queue_visible_mesh_chunks()
	var expected := 0
	for x in range(-3, 4):
		for z in range(-3, 4):
			var coord: Vector2i = manager.current_center_chunk + Vector2i(x, z)
			var distance := maxi(absi(x), absi(z))
			if distance >= 2 and not manager.mesh_cache.has(coord):
				expected += 1
	if manager.pending_pregen_lookup.size() != expected:
		push_error("Unlimited pre-generation did not queue the complete missing band.")
		manager.free()
		return false
	manager.current_center_chunk = Vector2i(1000000, -1000000)
	manager.mesh_cache_budget_bytes = entry_bytes * 4
	manager._queue_visible_mesh_chunks()
	if manager.mesh_cache_distance_buckets.size() != manager.get_unload_radius() + 2 \
			or manager.mesh_cache_distance_buckets[manager.mesh_cache_bucket_limit].size() != 4 \
			or manager._find_farther_mesh_cache(2) == null:
		push_error("Terrain cache distance buckets failed after a large teleport.")
		manager.free()
		return false
	manager.set_chunk_cache_radius_offsets(1, 2)
	manager._queue_visible_mesh_chunks()
	if not manager.mesh_cache.is_empty() \
			or manager.mesh_cache_bucket_limit != manager.get_unload_radius() + 1:
		push_error("Terrain cache distance buckets failed after a radius change.")
		manager.free()
		return false
	manager.free()
	print("[TerrainNativeParityCheck] Bounded, moving, unlimited, and LRU cache checks passed.")
	return true


func _check_lod_settings(generator: Object) -> bool:
	var camera := Camera3D.new()
	root.add_child(camera)
	var manager: Variant = MANAGER.new()
	manager.viewer = camera
	manager.camera = camera
	manager.render_radius = 1
	manager.mesh_pregen_end_offset = 0
	manager.chunk_unload_offset = 1
	manager.terrain_material = StandardMaterial3D.new()
	manager.worker_generators.append(generator)
	manager._setup_outline()
	var settings: Variant = GRAPHICS_SETTINGS.new()
	settings.viewport = root
	settings.chunk_manager = manager
	settings._create_interface()
	var config_path := "user://terrain_lod_regression_%d_%d.cfg" % [
		OS.get_process_id(), Time.get_ticks_usec()
	]
	var config := ConfigFile.new()
	config.set_value("graphics", "grid_cells", 3)
	var config_error := config.save(config_path)
	settings._load_settings(config_path)
	settings.pending["scaling_3d_mode"] = Viewport.SCALING_3D_MODE_BILINEAR
	settings.pending["render_radius"] = 1
	settings.pending["mesh_pregen_end_offset"] = 0
	settings.pending["chunk_unload_offset"] = 1
	settings._refresh_controls()
	settings.original = settings.pending.duplicate(true)
	var toggle: CheckButton = settings.controls["terrain_lod_enabled"]
	var passed: bool = config_error == OK and not toggle.button_pressed \
			and settings.pending["grid_cells"] == 14 \
			and settings.controls["grid_cells"].value == 14
	toggle.button_pressed = true
	passed = bool(settings._apply_graphics()) and passed \
			and manager.terrain_lod_enabled
	passed = bool(settings._save_settings(config_path)) and passed
	toggle.button_pressed = false
	passed = bool(settings._apply_graphics()) and passed \
			and not manager.terrain_lod_enabled
	settings._load_settings(config_path)
	passed = passed and toggle.button_pressed and settings.pending["terrain_lod_enabled"]
	passed = bool(settings._apply_graphics()) and passed \
			and manager.terrain_lod_enabled
	toggle.button_pressed = false
	settings._reset_settings()
	passed = passed and toggle.button_pressed and manager.terrain_lod_enabled
	toggle.button_pressed = false
	passed = bool(settings._apply_graphics()) and passed \
			and not manager.terrain_lod_enabled
	passed = bool(settings._save_settings(config_path)) and passed
	settings._load_settings(config_path)
	passed = passed and not toggle.button_pressed \
			and not settings.pending["terrain_lod_enabled"]
	var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(config_path))
	if remove_error != OK:
		push_error("Could not remove temporary terrain settings: %s." % error_string(remove_error))
		passed = false
	settings.free()
	manager.free()
	camera.free()
	if not passed:
		push_error("Terrain LOD settings apply, discard, or persistence failed.")
		return false
	print("[TerrainNativeParityCheck] Terrain LOD apply, discard, and persistence passed.")
	return true


func _check_chunk_pipeline(generator: Object) -> bool:
	var reference := ScriptPathAdapter.new(generator)
	var cases := [
		{"origin": Vector3i.ZERO, "cells": 14, "seed": 12345},
		{"origin": Vector3i(-128, 0, 192), "cells": 27, "seed": 12345},
		{"origin": Vector3i(256, 0, -320), "cells": 28, "seed": -9876},
		{"origin": Vector3i(-6400, 0, 9216), "cells": 56, "seed": 12345},
		{"origin": Vector3i(1024, 0, -2048), "cells": 100, "seed": 24680},
	]
	for test in cases:
		var origin: Vector3i = test["origin"]
		var cells: int = test["cells"]
		generator.initialize(test["seed"])
		var expected: Dictionary = CHUNK.generate_chunk_data(
			origin, 64, cells, true, reference
		)
		var actual: Dictionary = CHUNK.generate_chunk_data(
			origin, 64, cells, true, generator
		)
		if not _compare_chunk_arrays(expected, actual, "native %s/%d" % [origin, cells]):
			return false

		var from_heights: Dictionary = CHUNK.generate_chunk_data_from_height_cache(
			origin, 64, cells, true, generator, actual["height_cache"]
		)
		if not _compare_chunk_arrays(actual, from_heights, "height cache %s/%d" % [origin, cells]):
			return false
		var from_mesh: Dictionary = CHUNK.generate_chunk_data_from_mesh_cache(
			origin, 64, cells, true, generator, actual["mesh_cache"], actual["height_cache"]
		)
		if not _compare_chunk_arrays(actual, from_mesh, "mesh cache %s/%d" % [origin, cells]):
			return false
		if not CHUNK.generate_chunk_data_from_mesh_cache(
			origin, 64, cells, false, generator,
			{"vertices": PackedByteArray()}, actual["height_cache"]
		).is_empty():
			push_error("Malformed terrain mesh cache was accepted.")
			return false
	return true


func _check_lod_topology(generator: Object) -> bool:
	generator.initialize(12345)
	for cells in [14, 15, 28, 55, 56, 99, 100]:
		var topology: Dictionary = generator.build_lod_topology(cells)
		var base: PackedInt32Array = topology["base"]
		var lods: Dictionary = topology["lods"]
		var medium: PackedInt32Array = lods[0.35]
		var far: PackedInt32Array = lods[1.0]
		if base.size() != cells * cells * 6 \
				or medium.size() >= base.size() / 2 \
				or far.size() >= medium.size() \
				or far.size() >= base.size() * 0.3:
			push_error("Unexpected terrain LOD sizes at %d cells." % cells)
			return false
		for i in range(base.size()):
			if base[i] != i:
				push_error("Terrain base indices changed at %d." % i)
				return false
		if not _check_lod_level(cells, medium) or not _check_lod_level(cells, far):
			return false

		var left: PackedVector3Array = generator.sample_vertex_grid(
			Vector3i(-64, 0, 0), 64, cells, PackedFloat32Array()
		)
		var right: PackedVector3Array = generator.sample_vertex_grid(
			Vector3i.ZERO, 64, cells, PackedFloat32Array()
		)
		for z in range(cells + 1):
			var a := left[z * (cells + 1) + cells] + Vector3(-64, 0, 0)
			var b := right[z * (cells + 1)]
			if a.distance_to(b) > 0.001:
				push_error("Neighboring terrain borders differ at %d/%d." % [cells, z])
				return false
		print("[TerrainNativeParityCheck] LOD %d: %d / %d / %d triangles." % [
			cells, base.size() / 3, medium.size() / 3, far.size() / 3
		])
	return true


func _check_lod_level(cells: int, indices: PackedInt32Array) -> bool:
	if indices.is_empty() or indices.size() % 3 != 0:
		push_error("Terrain LOD indices are empty or incomplete.")
		return false
	var edges: Dictionary = {}
	var area_twice := 0
	for i in range(0, indices.size(), 3):
		var points: Array[Vector2i] = []
		for offset in range(3):
			var index := indices[i + offset]
			if index < 0 or index >= cells * cells * 6:
				push_error("Terrain LOD index out of bounds.")
				return false
			points.append(_grid_coord_from_vertex(index, cells))
		var a := points[0]
		var b := points[1]
		var c := points[2]
		var triangle_area := (b.x - a.x) * (c.y - a.y) \
				- (b.y - a.y) * (c.x - a.x)
		if triangle_area <= 0:
			push_error("Terrain LOD has a degenerate or reversed triangle at %d." % i)
			return false
		area_twice += triangle_area
		_count_edge(edges, a, b)
		_count_edge(edges, b, c)
		_count_edge(edges, c, a)
	if area_twice != 2 * cells * cells:
		push_error("Terrain LOD does not cover the entire chunk at %d cells." % cells)
		return false
	var boundary_edges := 0
	for key in edges:
		var edge: Vector4i = key
		var count: int = edges[key]
		if count == 1:
			var vertical := edge.x == edge.z \
					and (edge.x == 0 or edge.x == cells) \
					and absi(edge.y - edge.w) == 1
			var horizontal := edge.y == edge.w \
					and (edge.y == 0 or edge.y == cells) \
					and absi(edge.x - edge.z) == 1
			if not vertical and not horizontal:
				push_error("Terrain LOD has an unmatched interior edge: %s." % edge)
				return false
			boundary_edges += 1
		elif count != 2:
			push_error("Terrain LOD has an overlapping edge: %s." % edge)
			return false
	if boundary_edges != cells * 4:
		push_error("Terrain LOD did not retain every boundary edge.")
		return false
	return true


func _grid_coord_from_vertex(index: int, cells: int) -> Vector2i:
	var cell := index / 6
	var x := cell % cells
	var z := cell / cells
	var offset := index % 6
	if (x + z) % 2 == 0:
		match offset:
			1: x += 1
			2, 4: x += 1; z += 1
			5: z += 1
	else:
		match offset:
			1, 3: x += 1
			2, 5: z += 1
			4: x += 1; z += 1
	return Vector2i(x, z)


func _count_edge(edges: Dictionary, a: Vector2i, b: Vector2i) -> void:
	if a.x > b.x or (a.x == b.x and a.y > b.y):
		var swap := a
		a = b
		b = swap
	var key := Vector4i(a.x, a.y, b.x, b.y)
	edges[key] = int(edges.get(key, 0)) + 1


func _compare_chunk_arrays(expected: Dictionary, actual: Dictionary, label: String) -> bool:
	if expected.is_empty() or actual.is_empty():
		push_error("%s returned empty chunk data." % label)
		return false
	for key in ["vertices", "normals", "collision_vertices"]:
		var a: PackedVector3Array = expected[key]
		var b: PackedVector3Array = actual[key]
		if a.size() != b.size():
			push_error("%s: %s sizes differ: %d / %d." % [label, key, a.size(), b.size()])
			return false
		for i in range(a.size()):
			if a[i].distance_to(b[i]) > 0.002:
				push_error("%s: %s differ at %d: %s / %s." % [label, key, i, a[i], b[i]])
				return false
	var colors_a: PackedColorArray = expected["colors"]
	var colors_b: PackedColorArray = actual["colors"]
	if colors_a.size() != colors_b.size():
		push_error("%s: color sizes differ." % label)
		return false
	for i in range(colors_a.size()):
		var a := colors_a[i]
		var b := colors_b[i]
		if maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), \
				maxf(absf(a.b - b.b), absf(a.a - b.a))) > 0.002:
			push_error("%s: colors differ at %d: %s / %s." % [label, i, a, b])
			return false
	return true
