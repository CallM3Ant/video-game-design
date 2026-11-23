
extends Node3D

const ChunkScript = preload("res://scripts/Terrain/TChunk.gd")
const OutlineShader = preload("res://Shaders/ScreenSpaceOutline.gdshader")
const CHUNK_SIZE := 64
const COLLISION_GRID_CELLS := 28
@export_range(14, 100, 1) var grid_cells: int = CHUNK_SIZE * 0.4375
@export var viewer_path: NodePath
@export_range(1, 60, 1) var render_radius: int = 4

@export_range(30.0, 360.0) var forward_cone_angle: float = 180
@export_range(0, 5) var nearby_keep_radius: int = 1
@export var world_seed: int = 12345
var rock_material: StandardMaterial3D






var camera: Camera3D
var last_visibility_position := Vector2.ZERO
var last_visibility_forward := Vector2.ZERO
var last_visibility_cone_angle := -1.0
var last_visibility_nearby_radius := -1
var has_visibility_state := false

var terrain_material: StandardMaterial3D
var outline_instance: MeshInstance3D
var viewer: Node3D
var stats_label: Label

var chunks: Dictionary = {}
var cached_chunks: Dictionary = {}
var mesh_pregen_end_offset := 20
var chunk_unload_offset := 21
var height_cache: Dictionary = {}
var height_cache_bytes := 0
var height_cache_clock := 0
var mesh_cache: Dictionary = {}
var mesh_cache_bytes := 0
var mesh_cache_budget_bytes := 64 * 1024 * 1024
var mesh_cache_distance_buckets: Array[Dictionary] = []
var mesh_cache_bucket_center := Vector2i(999999, 999999)
var mesh_cache_bucket_limit := -1
var height_cache_targets: Dictionary = {}
var pending_height_chunks: Array[Vector2i] = []
var pending_height_lookup: Dictionary = {}
var pending_height_head := 0
var in_flight_height_lookup: Dictionary = {}
var prefetch_direction := Vector2(0.0, -1.0)
var last_prefetch_center := Vector2i(999999, 999999)

var pending_chunks: Array[Vector2i] = []
var pending_lookup: Dictionary = {}
var pending_pregen_lookup: Dictionary = {}
var pending_head := 0
var in_flight_pregen_lookup: Dictionary = {}

var worker_count: int = 1
var worker_generators: Array = []
var available_worker_slots: Array[int] = []

var in_flight_jobs: Dictionary = {}
var in_flight_lookup: Dictionary = {}

var completed_chunk_data: Array[Dictionary] = []
var completed_lookup: Dictionary = {}
var completed_head := 0

var terrain_lod_enabled := false
var terrain_lod_topology: Dictionary = {}
var pending_lod_chunks: Array[Vector2i] = []
var pending_lod_head := 0

var pending_collision_chunks: Array[Vector2i] = []
var pending_collision_lookup: Dictionary = {}
var in_flight_collision_lookup: Dictionary = {}

var visible_chunks: Dictionary = {}

var current_center_chunk := Vector2i(999999, 999999)
var last_render_radius := -1
var stats_update_timer := 0.0
const STATS_UPDATE_INTERVAL := 0.25
const MAX_CHUNKS_INTEGRATED_PER_FRAME := 4
const MAX_LOD_UPDATES_PER_FRAME := 2
const LOD_UPDATE_BUDGET_USEC := 2000
const MAX_COLLISION_SHAPES_PREPARED_PER_FRAME := 2
const HEIGHT_CACHE_BUDGET_BYTES := 16 * 1024 * 1024
const MAX_MESH_CACHE_BUDGET_MIB := 4096
const MAX_CHUNK_UNLOAD_OFFSET := 101
const PREFETCH_EXTRA_CHUNKS := 4
const MAX_MESH_PREGEN_JOBS_IN_FLIGHT := 1
const MAX_PREFETCH_JOBS_IN_FLIGHT := 1
const HEIGHT_CACHE_VERSION := 2
const MESH_CACHE_VERSION := 5
const VISIBILITY_REFRESH_POSITION_SQUARED := 4.0
const VISIBILITY_REFRESH_FORWARD_DOT := 0.9993908270190958
const VISIBILITY_CULL_MARGIN_RADIANS := 0.05235987755982989



	
func _ready() -> void:

	viewer = get_node_or_null(viewer_path) as Node3D
	camera = viewer as Camera3D

	if camera == null:
		push_error("Viewer Path must point to a Camera3D.")
		set_process(false)
		return
	_initialize_workers()

	terrain_material = StandardMaterial3D.new()
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.albedo_color = Color.WHITE
	terrain_material.roughness = 1.0
	terrain_material.metallic_specular= 0
	terrain_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	terrain_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	terrain_material.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	_setup_outline()
	
	rock_material = StandardMaterial3D.new()
	rock_material.albedo_color = Color(0.48, 0.36, 0.29)
	rock_material.roughness = 1.0
	rock_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	create_stats_display()
	update_loaded_chunks(true)


func _setup_outline() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var material := ShaderMaterial.new()
	material.shader = OutlineShader
	outline_instance = MeshInstance3D.new()
	outline_instance.name = "ScreenSpaceOutline"
	outline_instance.mesh = quad
	outline_instance.material_override = material
	outline_instance.position.z = -1.0
	outline_instance.extra_cull_margin = 2.0
	outline_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outline_instance.visible = false
	camera.add_child(outline_instance)


func _process(_delta: float) -> void:
	update_loaded_chunks(false)
	update_directional_visibility()

	_collect_completed_jobs()
	_prepare_collision_shapes()
	_integrate_completed_chunks()
	_update_terrain_lod_chunks()
	_dispatch_pending_jobs()
	stats_update_timer += _delta
	if stats_update_timer >= STATS_UPDATE_INTERVAL:
		stats_update_timer = 0.0
		update_stats_display()


func _initialize_workers() -> void:
	var selected_workers := 1
	var benchmark := get_node_or_null("/root/TerrainBenchmark")

	if benchmark != null:
		selected_workers = int(benchmark.get("optimal_worker_count"))

	worker_count = clampi(
		selected_workers,
		1,
		maxi(1, OS.get_processor_count())
	)

	worker_generators.clear()
	available_worker_slots.clear()

	for slot in range(worker_count):
		var generator: Object = ClassDB.instantiate(&"TerrainGenerator")
		if generator == null:
			push_error("Failed to instantiate the TerrainGenerator GDExtension class.")
			set_process(false)
			return
		generator.call("initialize", world_seed)
		worker_generators.append(generator)
		available_worker_slots.append(slot)

	print("[ChunkManager] Initialized %d terrain worker slots." % worker_count)


func _run_chunk_worker(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_want_collision: bool,
	p_generator: Variant,
	p_cached_mesh: Dictionary,
	p_cached_heights: PackedByteArray,
	p_output: Dictionary
) -> void:
	if not p_cached_mesh.is_empty():
		var cached_data := ChunkScript.generate_chunk_data_from_mesh_cache(
			p_origin,
			p_size,
			p_grid_cells,
			p_want_collision,
			p_generator,
			p_cached_mesh,
			p_cached_heights
		)
		if not cached_data.is_empty():
			p_output["data"] = cached_data
			return
		push_warning("Invalid cached mesh data for chunk at %s; regenerating terrain." % str(p_origin))

	if p_cached_heights.is_empty():
		p_output["data"] = ChunkScript.generate_chunk_data(
			p_origin,
			p_size,
			p_grid_cells,
			p_want_collision,
			p_generator
		)
	else:
		var cached_data := ChunkScript.generate_chunk_data_from_height_cache(
			p_origin,
			p_size,
			p_grid_cells,
			p_want_collision,
			p_generator,
			p_cached_heights
		)
		if not cached_data.is_empty():
			p_output["data"] = cached_data
		else:
			push_warning("Invalid cached height data for chunk at %s; regenerating terrain." % str(p_origin))
			p_output["data"] = ChunkScript.generate_chunk_data(
				p_origin, p_size, p_grid_cells, p_want_collision, p_generator
			)


func _run_height_cache_worker(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_generator: Variant,
	p_output: Dictionary
) -> void:
	p_output["data"] = ChunkScript.generate_height_cache(
		p_origin, p_size, p_grid_cells, p_generator
	)


func _run_collision_worker(
	p_origin: Vector3i,
	p_size: int,
	p_generator: Variant,
	p_output: Dictionary
) -> void:
	p_output["data"] = ChunkScript.generate_collision_data(
		p_origin,
		p_size,
		p_generator
	)


func get_preload_radius() -> int:
	return render_radius + mesh_pregen_end_offset


func get_prefetch_radius() -> int:
	return get_preload_radius() + PREFETCH_EXTRA_CHUNKS


func get_unload_radius() -> int:
	return render_radius + chunk_unload_offset


func get_mesh_pregen_start_radius() -> int:
	return get_visible_radius() + 1


func set_chunk_cache_radius_offsets(
	pregen_end_offset: int,
	unload_offset: int
) -> void:
	mesh_pregen_end_offset = clampi(pregen_end_offset, 0, 100)
	chunk_unload_offset = clampi(
		unload_offset,
		mesh_pregen_end_offset + 1,
		MAX_CHUNK_UNLOAD_OFFSET
	)
	_prune_coordinate_caches()


func get_visible_radius() -> int:
	return render_radius


func update_loaded_chunks(force_update: bool) -> void:
	var center: Vector2i = world_to_chunk_coord(viewer.global_position)

	if not force_update:
		if center == current_center_chunk and last_render_radius == render_radius:
			return

	var radius_changed := render_radius != last_render_radius
	var center_changed := center != current_center_chunk
	var had_center := current_center_chunk.x != 999999
	var previous_center := current_center_chunk

	current_center_chunk = center
	last_render_radius = render_radius

	if center_changed and had_center:
		var movement := Vector2(
			float(center.x - previous_center.x),
			float(center.y - previous_center.y)
		)
		if movement.length_squared() > 0.0:
			prefetch_direction = movement.normalized()
	elif not has_visibility_state:
		var camera_forward := -camera.global_basis.z
		var forward_xz := Vector2(camera_forward.x, camera_forward.z)
		if forward_xz.length_squared() > 0.000001:
			prefetch_direction = forward_xz.normalized()

	if center_changed:
		pending_collision_chunks.clear()
		pending_collision_lookup.clear()

	update_directional_visibility(
		force_update or center_changed or radius_changed
	)

	for coord in chunks:
		var chunk: Variant = chunks[coord]
		if _needs_collision_data(coord, center) and not chunk.has_collision_data():
			_request_collision_data(coord)
		chunk.set_collision_enabled(_is_in_collision_radius(coord, center))
	for chunk in cached_chunks.values():
		chunk.set_collision_enabled(false)
	_prune_cached_chunks()
	_prune_coordinate_caches()


func _queue_visible_mesh_chunks() -> void:
	pending_chunks.clear()
	pending_lookup.clear()
	pending_pregen_lookup.clear()
	pending_head = 0

	var radius := get_visible_radius()
	for ring in range(radius + 1):
		if ring == 0:
			_add_visible_mesh_target(current_center_chunk)
			continue

		for x_offset in range(-ring, ring + 1):
			_add_visible_mesh_target(current_center_chunk + Vector2i(x_offset, -ring))
			_add_visible_mesh_target(current_center_chunk + Vector2i(x_offset, ring))
		for z_offset in range(-ring + 1, ring):
			_add_visible_mesh_target(current_center_chunk + Vector2i(-ring, z_offset))
			_add_visible_mesh_target(current_center_chunk + Vector2i(ring, z_offset))

	var pregen_start_radius := get_mesh_pregen_start_radius()
	var pregen_radius := mini(get_preload_radius(), get_unload_radius())
	var free_slots := 0
	var farther_cached := 0
	if mesh_cache_budget_bytes > 0:
		var bytes_per_chunk := _estimated_mesh_cache_bytes()
		if bytes_per_chunk > mesh_cache_budget_bytes:
			return
		free_slots = maxi(
			0,
			int((mesh_cache_budget_bytes - mesh_cache_bytes) / bytes_per_chunk)
		)
		_ensure_mesh_cache_distance_buckets()
		farther_cached = mesh_cache.size()
		for distance in range(pregen_start_radius):
			farther_cached -= mesh_cache_distance_buckets[distance].size()

	for ring in range(pregen_start_radius, pregen_radius + 1):
		var pregen_capacity := -1
		if mesh_cache_budget_bytes > 0:
			farther_cached -= mesh_cache_distance_buckets[ring].size()
			pregen_capacity = maxi(
				0, free_slots + farther_cached - in_flight_pregen_lookup.size()
			)
		for x_offset in range(-ring, ring + 1):
			if pregen_capacity >= 0 and pending_pregen_lookup.size() >= pregen_capacity:
				return
			_add_mesh_pregen_target(x_offset, -ring)
			if pregen_capacity >= 0 and pending_pregen_lookup.size() >= pregen_capacity:
				return
			_add_mesh_pregen_target(x_offset, ring)
		for z_offset in range(-ring + 1, ring):
			if pregen_capacity >= 0 and pending_pregen_lookup.size() >= pregen_capacity:
				return
			_add_mesh_pregen_target(-ring, z_offset)
			if pregen_capacity >= 0 and pending_pregen_lookup.size() >= pregen_capacity:
				return
			_add_mesh_pregen_target(ring, z_offset)


func _add_visible_mesh_target(coord: Vector2i) -> void:
	if not visible_chunks.has(coord):
		return
	if chunks.has(coord) or cached_chunks.has(coord) \
			or in_flight_lookup.has(coord):
		return
	if completed_lookup.has(coord) or pending_lookup.has(coord):
		return
	pending_chunks.append(coord)
	pending_lookup[coord] = true


func _add_mesh_pregen_target(x_offset: int, z_offset: int) -> void:
	var coord := current_center_chunk + Vector2i(x_offset, z_offset)
	if mesh_cache.has(coord) or chunks.has(coord) or cached_chunks.has(coord) \
			or in_flight_lookup.has(coord) or completed_lookup.has(coord) \
			or pending_lookup.has(coord):
		return
	pending_chunks.append(coord)
	pending_lookup[coord] = true
	pending_pregen_lookup[coord] = true


func _refresh_height_prefetch() -> void:
	pending_height_chunks.clear()
	pending_height_lookup.clear()
	pending_height_head = 0
	height_cache_targets.clear()

	var inner_radius := get_preload_radius()
	var outer_radius := mini(get_prefetch_radius(), get_unload_radius())

	for ring in range(inner_radius + 1, outer_radius + 1):
		for x_offset in range(-ring, ring + 1):
			for z_offset in [-ring, ring]:
				_add_height_prefetch_target(x_offset, z_offset)
		for z_offset in range(-ring + 1, ring):
			for x_offset in [-ring, ring]:
				_add_height_prefetch_target(x_offset, z_offset)


func _add_height_prefetch_target(
	x_offset: int,
	z_offset: int
) -> void:
	var offset := Vector2(float(x_offset), float(z_offset))
	var distance := offset.length()
	if distance <= 0.0 or offset.dot(prefetch_direction) < distance * 0.5:
		return

	var coord := current_center_chunk + Vector2i(x_offset, z_offset)
	if mesh_cache.has(coord):
		return
	if _chunk_distance(coord, current_center_chunk) > get_unload_radius():
		return
	if visible_chunks.has(coord) or height_cache.has(coord):
		return
	height_cache_targets[coord] = true
	if in_flight_lookup.has(coord) or pending_height_lookup.has(coord):
		return

	pending_height_chunks.append(coord)
	pending_height_lookup[coord] = true


func _store_height_cache(coord: Vector2i, data: PackedByteArray) -> void:
	if data.is_empty() or data.size() > HEIGHT_CACHE_BUDGET_BYTES:
		return
	if _chunk_distance(coord, current_center_chunk) > get_unload_radius():
		return
	_remove_height_cache(coord)

	height_cache_clock += 1
	height_cache[coord] = {
		"data": data,
		"bytes": data.size(),
		"last_used": height_cache_clock,
		"grid_cells": grid_cells,
		"world_seed": world_seed,
		"version": HEIGHT_CACHE_VERSION,
	}
	height_cache_bytes += data.size()

	while height_cache_bytes > HEIGHT_CACHE_BUDGET_BYTES:
		var oldest_coord := Vector2i.ZERO
		var oldest_time := height_cache_clock + 1
		for cached_coord in height_cache:
			var entry: Dictionary = height_cache[cached_coord]
			var used_at := int(entry["last_used"])
			if used_at < oldest_time:
				oldest_time = used_at
				oldest_coord = cached_coord
		_remove_height_cache(oldest_coord)


func _store_mesh_cache(
	coord: Vector2i,
	data: Dictionary
) -> void:
	var grid: PackedVector3Array = data.get("grid", PackedVector3Array())
	var face_colors: PackedColorArray = data.get("face_colors", PackedColorArray())
	var byte_count := grid.size() * 12 + face_colors.size() * 16
	if grid.is_empty() or face_colors.is_empty() \
			or (mesh_cache_budget_bytes > 0 \
			and byte_count > mesh_cache_budget_bytes):
		return
	if _chunk_distance(coord, current_center_chunk) > get_unload_radius():
		return
	_remove_mesh_cache(coord)
	_ensure_mesh_cache_distance_buckets()

	mesh_cache[coord] = {
		"data": data,
		"bytes": byte_count,
		"grid_cells": grid_cells,
		"world_seed": world_seed,
		"version": MESH_CACHE_VERSION,
	}
	mesh_cache_bytes += byte_count
	var distance := mini(
		_chunk_distance(coord, mesh_cache_bucket_center), mesh_cache_bucket_limit
	)
	mesh_cache_distance_buckets[distance][coord] = true
	_enforce_mesh_cache_budget()


func _estimated_mesh_cache_bytes() -> int:
	var grid_samples := (grid_cells + 1) * (grid_cells + 1)
	return grid_samples * 12 + grid_cells * grid_cells * 2 * 16


func _ensure_mesh_cache_distance_buckets() -> void:
	var limit := maxi(get_preload_radius(), get_unload_radius()) + 1
	if mesh_cache_bucket_center == current_center_chunk \
			and mesh_cache_bucket_limit == limit:
		return
	mesh_cache_bucket_center = current_center_chunk
	mesh_cache_bucket_limit = limit
	mesh_cache_distance_buckets.clear()
	for distance in range(limit + 1):
		mesh_cache_distance_buckets.append({})
	for coord in mesh_cache:
		var distance := mini(_chunk_distance(coord, current_center_chunk), limit)
		mesh_cache_distance_buckets[distance][coord] = true


func _find_farther_mesh_cache(distance: int) -> Variant:
	_ensure_mesh_cache_distance_buckets()
	for bucket_index in range(mesh_cache_bucket_limit, distance, -1):
		for coord in mesh_cache_distance_buckets[bucket_index]:
			return coord
	return null


func _store_pregen_mesh_cache(coord: Vector2i, data: Dictionary) -> void:
	var grid: PackedVector3Array = data.get("grid", PackedVector3Array())
	var face_colors: PackedColorArray = data.get("face_colors", PackedColorArray())
	var byte_count := grid.size() * 12 + face_colors.size() * 16
	if grid.is_empty() or face_colors.is_empty() \
			or (mesh_cache_budget_bytes > 0 and byte_count > mesh_cache_budget_bytes):
		return
	if mesh_cache_budget_bytes > 0:
		var distance := _chunk_distance(coord, current_center_chunk)
		while mesh_cache_bytes + byte_count > mesh_cache_budget_bytes:
			var farther: Variant = _find_farther_mesh_cache(distance)
			if farther == null:
				return
			_remove_mesh_cache(farther)
	_store_mesh_cache(coord, data)


func _enforce_mesh_cache_budget() -> void:
	while mesh_cache_budget_bytes > 0 \
			and mesh_cache_bytes > mesh_cache_budget_bytes \
			and not mesh_cache.is_empty():
		# Insertion order is LRU order; cache hits reinsert at the end.
		var oldest_coord := Vector2i.ZERO
		for cached_coord in mesh_cache:
			oldest_coord = cached_coord
			break
		_remove_mesh_cache(oldest_coord)


func set_mesh_cache_budget_mib(value: int) -> void:
	var budget_mib := clampi(value, 0, MAX_MESH_CACHE_BUDGET_MIB)
	mesh_cache_budget_bytes = budget_mib * 1024 * 1024
	_enforce_mesh_cache_budget()


func _prune_coordinate_caches() -> void:
	var expired_mesh_coords: Array[Vector2i] = []
	for coord in mesh_cache:
		if _chunk_distance(coord, current_center_chunk) > get_unload_radius():
			expired_mesh_coords.append(coord)
	for coord in expired_mesh_coords:
		_remove_mesh_cache(coord)

	var expired_height_coords: Array[Vector2i] = []
	for coord in height_cache:
		if _chunk_distance(coord, current_center_chunk) > get_unload_radius():
			expired_height_coords.append(coord)
	for coord in expired_height_coords:
		_remove_height_cache(coord)


func _remove_height_cache(coord: Vector2i) -> void:
	if not height_cache.has(coord):
		return
	var entry: Dictionary = height_cache[coord]
	height_cache_bytes -= int(entry["bytes"])
	height_cache.erase(coord)


func _remove_mesh_cache(coord: Vector2i) -> void:
	if not mesh_cache.has(coord):
		return
	var entry: Dictionary = mesh_cache[coord]
	mesh_cache_bytes -= int(entry["bytes"])
	if mesh_cache_bucket_limit >= 0:
		var distance := mini(
			_chunk_distance(coord, mesh_cache_bucket_center), mesh_cache_bucket_limit
		)
		mesh_cache_distance_buckets[distance].erase(coord)
	mesh_cache.erase(coord)


func _get_height_cache(coord: Vector2i) -> PackedByteArray:
	if not height_cache.has(coord):
		return PackedByteArray()
	var entry: Dictionary = height_cache[coord]
	if int(entry["grid_cells"]) != grid_cells \
			or int(entry["world_seed"]) != world_seed \
			or int(entry["version"]) != HEIGHT_CACHE_VERSION:
		_remove_height_cache(coord)
		return PackedByteArray()
	height_cache_clock += 1
	entry["last_used"] = height_cache_clock
	height_cache[coord] = entry
	var data: PackedByteArray = entry["data"]
	return data


func _get_mesh_cache(coord: Vector2i) -> Dictionary:
	if not mesh_cache.has(coord):
		return {}
	var entry: Dictionary = mesh_cache[coord]
	if int(entry["grid_cells"]) != grid_cells \
			or int(entry["world_seed"]) != world_seed \
			or int(entry["version"]) != MESH_CACHE_VERSION:
		_remove_mesh_cache(coord)
		return {}
	mesh_cache.erase(coord)
	mesh_cache[coord] = entry
	var data: Dictionary = entry["data"]
	return data


func _prune_cached_chunks() -> void:
	var expired_chunks: Array[Vector2i] = []
	for coord in cached_chunks:
		if _chunk_distance(coord, current_center_chunk) > get_unload_radius():
			expired_chunks.append(coord)

	for coord in expired_chunks:
		var chunk: Variant = cached_chunks[coord]
		chunk.set_chunk_active(false)
		chunk.set_collision_enabled(false)
		cached_chunks.erase(coord)
		_store_height_cache(coord, chunk.height_cache_data)
		chunk.queue_free()


func update_directional_visibility(force_update: bool = false) -> void:
	var camera_position := camera.global_position
	var camera_position_xz := Vector2(camera_position.x, camera_position.z)
	var camera_forward := -camera.global_basis.z
	var forward := Vector2(camera_forward.x, camera_forward.z)
	if forward.length_squared() > 0.000001:
		forward = forward.normalized()
	elif has_visibility_state:
		forward = last_visibility_forward
	else:
		forward = Vector2(0.0, -1.0)

	var half_angle := minf(
		deg_to_rad(forward_cone_angle * 0.5) + VISIBILITY_CULL_MARGIN_RADIANS,
		PI
	)
	var settings_changed := (
		forward_cone_angle != last_visibility_cone_angle
		or nearby_keep_radius != last_visibility_nearby_radius
	)
	if not force_update and has_visibility_state and not settings_changed:
		var position_changed := (
			camera_position_xz.distance_squared_to(last_visibility_position)
			>= VISIBILITY_REFRESH_POSITION_SQUARED
		)
		var direction_changed := (
			forward.dot(last_visibility_forward)
			< VISIBILITY_REFRESH_FORWARD_DOT
		)
		if not position_changed and not direction_changed:
			return

	last_visibility_position = camera_position_xz
	last_visibility_forward = forward
	last_visibility_cone_angle = forward_cone_angle
	last_visibility_nearby_radius = nearby_keep_radius
	has_visibility_state = true
	if current_center_chunk == last_prefetch_center:
		prefetch_direction = forward
	last_prefetch_center = current_center_chunk

	var cos_half_angle := cos(half_angle)
	var sin_half_angle := sin(half_angle)
	var max_distance := float(get_visible_radius() * CHUNK_SIZE)
	var max_distance_squared := max_distance * max_distance

	var next_visible_chunks: Dictionary = {}
	var visible_radius := get_visible_radius()
	var always_visible_radius := maxi(nearby_keep_radius, get_collision_radius())
	for z_offset in range(-visible_radius, visible_radius + 1):
		for x_offset in range(-visible_radius, visible_radius + 1):
			var coord := current_center_chunk + Vector2i(x_offset, z_offset)
			var distance := maxi(absi(x_offset), absi(z_offset))
			if distance <= always_visible_radius or is_chunk_in_forward_cone(
				coord,
				camera_position_xz,
				forward,
				half_angle,
				cos_half_angle,
				sin_half_angle,
				max_distance_squared
			):
				next_visible_chunks[coord] = true

	for coord in next_visible_chunks:
		if cached_chunks.has(coord):
			chunks[coord] = cached_chunks[coord]
			cached_chunks.erase(coord)
		var chunk: Variant = chunks.get(coord)
		if chunk != null:
			chunk.set_chunk_active(true)

	visible_chunks = next_visible_chunks
	for coord in chunks.keys():
		if visible_chunks.has(coord):
			continue
		var chunk: Variant = chunks[coord]
		chunk.set_chunk_active(false)
		chunk.set_collision_enabled(false)
		chunks.erase(coord)
		if _chunk_distance(coord, current_center_chunk) <= get_unload_radius():
			cached_chunks[coord] = chunk
		else:
			_store_height_cache(coord, chunk.height_cache_data)
			chunk.queue_free()

	_prune_cached_chunks()
	_queue_visible_mesh_chunks()
	_refresh_height_prefetch()

func is_chunk_in_forward_cone(
	coord: Vector2i,
	camera_position: Vector2,
	forward: Vector2,
	half_angle: float,
	cos_half_angle: float,
	sin_half_angle: float,
	max_distance_squared: float
) -> bool:

	var chunk_center := Vector2(
		(float(coord.x) + 0.5) * CHUNK_SIZE,
		(float(coord.y) + 0.5) * CHUNK_SIZE
	)

	var to_chunk := chunk_center - camera_position
	var distance_squared := to_chunk.length_squared()

	if distance_squared < 0.000001:
		return true

	if distance_squared > max_distance_squared:
		return false

	var chunk_radius := CHUNK_SIZE * 0.7072
	var chunk_radius_squared := chunk_radius * chunk_radius
	if distance_squared <= chunk_radius_squared or half_angle >= PI:
		return true

	if half_angle > PI * 0.5:
		var sin_remainder := sin(PI - half_angle)
		if chunk_radius_squared >= distance_squared * sin_remainder * sin_remainder:
			return true

	var cos_limit := (
		cos_half_angle * sqrt(distance_squared - chunk_radius_squared)
		- sin_half_angle * chunk_radius
	)
	return to_chunk.dot(forward) >= cos_limit
	


func get_collision_radius() -> int:
	return 1 if render_radius <= 1 else 2


func get_collision_build_radius() -> int:
	return get_collision_radius() + 1


func _chunk_distance(coord: Vector2i, center: Vector2i) -> int:
	return maxi(absi(coord.x - center.x), absi(coord.y - center.y))


func _is_in_collision_radius(coord: Vector2i, center: Vector2i) -> bool:
	return _chunk_distance(coord, center) <= get_collision_radius()


func _request_collision_data(coord: Vector2i) -> void:
	if not chunks.has(coord) and not cached_chunks.has(coord):
		return

	var chunk: Variant = chunks.get(coord, cached_chunks.get(coord))
	if chunk.has_collision_data():
		return
	if in_flight_collision_lookup.has(coord) or pending_collision_lookup.has(coord):
		return

	pending_collision_chunks.append(coord)
	pending_collision_lookup[coord] = true


func _needs_collision_data(coord: Vector2i, center: Vector2i) -> bool:
	return _chunk_distance(coord, center) <= get_collision_build_radius()


func _dispatch_pending_jobs() -> void:
	var completed_backlog := completed_chunk_data.size() - completed_head
	var max_completed_backlog := maxi(1, worker_count * 2)

	while not available_worker_slots.is_empty():
		if not pending_collision_chunks.is_empty():
			var collision_coord: Vector2i = pending_collision_chunks.pop_front()
			pending_collision_lookup.erase(collision_coord)
			var collision_chunk: Variant = chunks.get(
				collision_coord, cached_chunks.get(collision_coord)
			)

			if collision_chunk == null or not is_instance_valid(collision_chunk):
				continue
			if collision_chunk.has_collision_data():
				continue

			var collision_origin := Vector3i(
				collision_coord.x * CHUNK_SIZE,
				0,
				collision_coord.y * CHUNK_SIZE
			)
			var collision_slot: int = available_worker_slots.pop_back()
			var collision_generator: Variant = worker_generators[collision_slot]
			var collision_output: Dictionary = {"data": PackedVector3Array()}
			var collision_task_id: int = WorkerThreadPool.add_task(
				Callable(self, "_run_collision_worker").bind(
					collision_origin,
					CHUNK_SIZE,
					collision_generator,
					collision_output
				),
				false,
				"Terrain collision %d,%d" % [collision_coord.x, collision_coord.y]
			)

			if collision_task_id < 0:
				available_worker_slots.append(collision_slot)
				pending_collision_chunks.push_front(collision_coord)
				pending_collision_lookup[collision_coord] = true
				push_error("Failed to schedule terrain collision task for chunk %s." % str(collision_coord))
				break

			in_flight_jobs[collision_task_id] = {
				"kind": "collision",
				"coord": collision_coord,
				"slot": collision_slot,
				"output": collision_output
			}
			in_flight_collision_lookup[collision_coord] = collision_task_id
			continue

		if completed_backlog >= max_completed_backlog:
			break

		if pending_head < pending_chunks.size():
			var coord: Vector2i = pending_chunks[pending_head]
			var is_pregen_job := pending_pregen_lookup.has(coord)
			if is_pregen_job \
					and in_flight_pregen_lookup.size() \
					>= MAX_MESH_PREGEN_JOBS_IN_FLIGHT:
				break
			pending_head += 1
			pending_lookup.erase(coord)
			pending_pregen_lookup.erase(coord)
			var is_visible_job := visible_chunks.has(coord)
			if not is_visible_job and not is_pregen_job:
				continue
			if is_pregen_job \
					and (_chunk_distance(coord, current_center_chunk) \
					< get_mesh_pregen_start_radius() \
					or _chunk_distance(coord, current_center_chunk) \
					> mini(get_preload_radius(), get_unload_radius())):
				continue
			if chunks.has(coord) or cached_chunks.has(coord) \
					or in_flight_lookup.has(coord):
				continue
			if completed_lookup.has(coord):
				continue
			var pregen_mesh_bytes := _estimated_mesh_cache_bytes()
			if is_pregen_job \
					and mesh_cache_budget_bytes > 0 \
					and mesh_cache_bytes + pregen_mesh_bytes \
					> mesh_cache_budget_bytes:
				if _find_farther_mesh_cache(
					_chunk_distance(coord, current_center_chunk)
				) == null:
					continue

			var origin := Vector3i(
				coord.x * CHUNK_SIZE,
				0,
				coord.y * CHUNK_SIZE
			)
			var slot: int = available_worker_slots.pop_back()
			var generator: Variant = worker_generators[slot]
			var cached_mesh := _get_mesh_cache(coord)
			var cached_heights := _get_height_cache(coord)
			var output: Dictionary = {"data": {}}
			var want_collision := is_visible_job \
					and _needs_collision_data(coord, current_center_chunk)
			var task_id: int = WorkerThreadPool.add_task(
				Callable(self, "_run_chunk_worker").bind(
					origin,
					CHUNK_SIZE,
					grid_cells,
					want_collision,
					generator,
					cached_mesh,
					cached_heights,
					output
				),
				false,
				"Terrain chunk %d,%d" % [coord.x, coord.y]
			)

			if task_id < 0:
				available_worker_slots.append(slot)
				pending_head -= 1
				pending_lookup[coord] = true
				if is_pregen_job:
					pending_pregen_lookup[coord] = true
				push_error("Failed to schedule terrain worker task for chunk %s." % str(coord))
				break

			in_flight_jobs[task_id] = {
				"kind": "pregen" if is_pregen_job else "chunk",
				"coord": coord,
				"origin": origin,
				"slot": slot,
				"output": output,
				"grid_cells": grid_cells,
				"world_seed": world_seed,
			}
			in_flight_lookup[coord] = task_id
			if is_pregen_job:
				in_flight_pregen_lookup[coord] = task_id
			continue

		if pending_height_head >= pending_height_chunks.size():
			break
		if in_flight_height_lookup.size() >= MAX_PREFETCH_JOBS_IN_FLIGHT:
			break

		var height_coord: Vector2i = pending_height_chunks[pending_height_head]
		pending_height_head += 1
		pending_height_lookup.erase(height_coord)
		if not height_cache_targets.has(height_coord) \
				or visible_chunks.has(height_coord) \
				or height_cache.has(height_coord) \
				or in_flight_lookup.has(height_coord):
			continue

		var height_origin := Vector3i(
			height_coord.x * CHUNK_SIZE,
			0,
			height_coord.y * CHUNK_SIZE
		)
		var height_slot: int = available_worker_slots.pop_back()
		var height_generator: Variant = worker_generators[height_slot]
		var height_output: Dictionary = {"data": PackedByteArray()}
		var height_task_id: int = WorkerThreadPool.add_task(
			Callable(self, "_run_height_cache_worker").bind(
				height_origin,
				CHUNK_SIZE,
				grid_cells,
				height_generator,
				height_output
			),
			false,
			"Terrain height cache %d,%d" % [height_coord.x, height_coord.y]
		)
		if height_task_id < 0:
			available_worker_slots.append(height_slot)
			pending_height_head -= 1
			pending_height_lookup[height_coord] = true
			push_error("Failed to schedule terrain height-cache task for chunk %s." % str(height_coord))
			break

		in_flight_jobs[height_task_id] = {
			"kind": "height",
			"coord": height_coord,
			"slot": height_slot,
			"output": height_output,
			"grid_cells": grid_cells,
			"world_seed": world_seed,
			"version": HEIGHT_CACHE_VERSION,
		}
		in_flight_lookup[height_coord] = height_task_id
		in_flight_height_lookup[height_coord] = height_task_id

	compact_pending_queue()
	_compact_pending_height_queue()

func set_terrain_lod_enabled(enabled: bool) -> bool:
	if enabled and terrain_lod_topology.is_empty():
		terrain_lod_topology = _make_lod_topology(grid_cells)
		if terrain_lod_topology.is_empty():
			return false
	if terrain_lod_enabled == enabled:
		return true
	terrain_lod_enabled = enabled
	if not enabled:
		terrain_lod_topology.clear()
	pending_lod_chunks.clear()
	pending_lod_head = 0
	for coord in chunks:
		pending_lod_chunks.append(coord)
	for coord in cached_chunks:
		pending_lod_chunks.append(coord)
	return true


func _make_lod_topology(cells: int) -> Dictionary:
	if worker_generators.is_empty() \
			or not worker_generators[0].has_method("build_lod_topology"):
		push_error("Terrain LOD requires the current TerrainGenerator extension.")
		return {}
	var topology: Dictionary = worker_generators[0].build_lod_topology(cells)
	if topology.is_empty():
		push_error("Failed to build terrain LOD topology for %d cells." % cells)
	return topology


func _update_terrain_lod_chunks() -> void:
	if pending_lod_head >= pending_lod_chunks.size():
		return
	var started := Time.get_ticks_usec()
	var processed := 0
	while pending_lod_head < pending_lod_chunks.size() \
			and processed < MAX_LOD_UPDATES_PER_FRAME:
		var coord: Vector2i = pending_lod_chunks[pending_lod_head]
		pending_lod_head += 1
		processed += 1
		var chunk: Variant = chunks.get(coord, cached_chunks.get(coord))
		if chunk == null or not is_instance_valid(chunk) \
				or chunk.terrain_lod_enabled == terrain_lod_enabled:
			continue
		if not chunk.set_terrain_lod(
			terrain_lod_enabled, terrain_lod_topology, _get_mesh_cache(coord),
			grid_cells, worker_generators[0]
		):
			push_error("Failed to update terrain LOD for chunk %s." % str(coord))
		if Time.get_ticks_usec() - started >= LOD_UPDATE_BUDGET_USEC:
			break
	if pending_lod_head >= pending_lod_chunks.size():
		pending_lod_chunks.clear()
		pending_lod_head = 0


func set_grid_cells(value: int) -> bool:
	var new_value := clampi(value, 14, 100)

	if new_value == grid_cells:
		return true

	var next_lod_topology: Dictionary = {}
	if terrain_lod_enabled:
		next_lod_topology = _make_lod_topology(new_value)
		if next_lod_topology.is_empty():
			return false

	grid_cells = new_value
	terrain_lod_topology = next_lod_topology
	pending_lod_chunks.clear()
	pending_lod_head = 0

	for chunk in chunks.values():
		chunk.set_collision_enabled(false)
		chunk.queue_free()
	for chunk in cached_chunks.values():
		chunk.set_collision_enabled(false)
		chunk.queue_free()

	chunks.clear()
	cached_chunks.clear()
	height_cache.clear()
	height_cache_bytes = 0
	height_cache_clock = 0
	mesh_cache.clear()
	mesh_cache_bytes = 0
	mesh_cache_distance_buckets.clear()
	mesh_cache_bucket_limit = -1
	height_cache_targets.clear()
	pending_height_chunks.clear()
	pending_height_lookup.clear()
	pending_height_head = 0

	completed_chunk_data.clear()
	completed_lookup.clear()
	completed_head = 0
	pending_chunks.clear()
	pending_lookup.clear()
	pending_pregen_lookup.clear()
	pending_head = 0

	update_loaded_chunks(true)
	return true


func _collect_completed_jobs() -> void:
	var needs_refresh := false
	var completed_pregen := false

	for task_id_value in in_flight_jobs.keys():
		var task_id := int(task_id_value)

		if not WorkerThreadPool.is_task_completed(task_id):
			continue

		var job: Dictionary = in_flight_jobs[task_id]
		var wait_error: Error = WorkerThreadPool.wait_for_task_completion(task_id)

		in_flight_jobs.erase(task_id)

		var coord: Vector2i = job["coord"]

		if in_flight_lookup.get(coord, -1) == task_id:
			in_flight_lookup.erase(coord)
		if in_flight_pregen_lookup.get(coord, -1) == task_id:
			in_flight_pregen_lookup.erase(coord)

		available_worker_slots.append(int(job["slot"]))

		if job.get("kind", "chunk") == "collision":
			if in_flight_collision_lookup.get(coord, -1) == task_id:
				in_flight_collision_lookup.erase(coord)
			if wait_error != OK:
				push_error("Could not collect terrain collision task %d: %s" % [task_id, error_string(wait_error)])
				continue

			var collision_output: Dictionary = job["output"]
			var collision_data: PackedVector3Array = collision_output.get(
				"data",
				PackedVector3Array()
			)
			if collision_data.is_empty():
				push_error("Terrain worker returned no collision data for chunk %s." % str(coord))
				continue

			var collision_chunk: Variant = chunks.get(
				coord, cached_chunks.get(coord)
			)
			if collision_chunk != null and is_instance_valid(collision_chunk):
				collision_chunk.set_collision_data(collision_data)
			continue

		if job.get("kind", "chunk") == "height":
			if in_flight_height_lookup.get(coord, -1) == task_id:
				in_flight_height_lookup.erase(coord)
			if wait_error != OK:
				push_error("Could not collect terrain height-cache task %d: %s" % [task_id, error_string(wait_error)])
				continue

			var height_grid_matches := int(job["grid_cells"]) == grid_cells
			var height_seed_matches := int(job["world_seed"]) == world_seed
			if not height_grid_matches or not height_seed_matches \
					or int(job["version"]) != HEIGHT_CACHE_VERSION:
				if visible_chunks.has(coord):
					_queue_visible_mesh_chunks()
				continue

			var height_output: Dictionary = job["output"]
			var height_data: PackedByteArray = height_output.get(
				"data", PackedByteArray()
			)
			if height_data.is_empty():
				push_error("Terrain worker returned no height-cache data for chunk %s." % str(coord))
				continue

			if height_cache_targets.has(coord) or visible_chunks.has(coord):
				_store_height_cache(coord, height_data)
			if visible_chunks.has(coord):
				_queue_visible_mesh_chunks()
			continue

		if int(job["grid_cells"]) != grid_cells \
				or int(job["world_seed"]) != world_seed:
			needs_refresh = true
			continue

		if wait_error != OK:
			push_error("Could not collect terrain task %d: %s" % [task_id, error_string(wait_error)])
			continue

		var output: Dictionary = job["output"]
		var data: Dictionary = output.get("data", {})

		if data.is_empty():
			push_error("Terrain worker returned no data for chunk %s." % str(coord))
			continue

		if job.get("kind") == "pregen":
			completed_pregen = true
		if chunks.has(coord) or cached_chunks.has(coord):
			continue

		if job.get("kind") == "pregen" and not visible_chunks.has(coord):
			if _chunk_distance(coord, current_center_chunk) <= get_preload_radius():
				_store_pregen_mesh_cache(coord, data.get("mesh_cache", {}))
				_store_height_cache(
					coord, data.get("height_cache", PackedByteArray())
				)
			continue

		var keep_loaded := visible_chunks.has(coord) \
				or _chunk_distance(coord, current_center_chunk) <= get_unload_radius()
		if not keep_loaded:
			_store_mesh_cache(coord, data.get("mesh_cache", {}))
			_store_height_cache(coord, data.get("height_cache", PackedByteArray()))
			continue

		completed_chunk_data.append({
			"coord": coord,
			"origin": job["origin"],
			"data": data
		})

		completed_lookup[coord] = true

	if needs_refresh:
		update_loaded_chunks(true)
	elif completed_pregen and pending_pregen_lookup.is_empty():
		_queue_visible_mesh_chunks()

func _integrate_completed_chunks() -> void:
	var integrated_count := 0

	while completed_head < completed_chunk_data.size() \
			and integrated_count < MAX_CHUNKS_INTEGRATED_PER_FRAME:
		var result: Dictionary = completed_chunk_data[completed_head]
		completed_head += 1

		var coord: Vector2i = result["coord"]
		completed_lookup.erase(coord)

		var is_visible := visible_chunks.has(coord)
		var keep_loaded := is_visible \
				or _chunk_distance(coord, current_center_chunk) <= get_unload_radius()
		if not keep_loaded:
			_store_mesh_cache(
				coord,
				result["data"].get("mesh_cache", {})
			)
			_store_height_cache(
				coord,
				result["data"].get("height_cache", PackedByteArray())
			)
			continue

		if chunks.has(coord) or cached_chunks.has(coord):
			continue

		_store_mesh_cache(
			coord,
			result["data"].get("mesh_cache", {})
		)
		var chunk: Variant = ChunkScript.new()
		chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]

		add_child(chunk)
		var setup_ok: bool = chunk.setup_from_data(
			result["origin"],
			CHUNK_SIZE,
			result["data"],
			terrain_material,
			rock_material,
			terrain_lod_topology if terrain_lod_enabled else {}
		)
		if not setup_ok:
			push_error("Failed to create terrain mesh for chunk %s." % str(coord))
			chunk.queue_free()
			continue

		chunk.set_chunk_active(is_visible)
		var needs_collision := is_visible and _is_in_collision_radius(
			coord, current_center_chunk
		)
		if needs_collision:
			chunk.prepare_collision_shape()
		chunk.set_collision_enabled(needs_collision)
		if is_visible and _needs_collision_data(coord, current_center_chunk) \
				and not chunk.has_collision_data():
			chunks[coord] = chunk
			_request_collision_data(coord)
		elif is_visible:
			chunks[coord] = chunk
		else:
			cached_chunks[coord] = chunk
		integrated_count += 1

	_compact_completed_queue()


func _prepare_collision_shapes() -> void:
	var prepared_count := 0
	var radius := get_collision_radius()

	for z_offset in range(-radius, radius + 1):
		for x_offset in range(-radius, radius + 1):
			var coord := current_center_chunk + Vector2i(x_offset, z_offset)
			var chunk: Variant = chunks.get(coord)
			if chunk == null:
				continue

			if not chunk.has_collision_data() or chunk.collision_shape_node != null:
				continue

			chunk.prepare_collision_shape()
			chunk.set_collision_enabled(true)
			prepared_count += 1
			if prepared_count >= MAX_COLLISION_SHAPES_PREPARED_PER_FRAME:
				return


func _compact_completed_queue() -> void:
	if completed_head >= completed_chunk_data.size():
		completed_chunk_data.clear()
		completed_head = 0
		return

	if completed_head >= 64 and completed_head * 2 >= completed_chunk_data.size():
		completed_chunk_data = completed_chunk_data.slice(completed_head)
		completed_head = 0


func compact_pending_queue() -> void:
	if pending_head >= pending_chunks.size():
		pending_chunks.clear()
		pending_head = 0
		return

	if pending_head >= 256 and pending_head * 2 >= pending_chunks.size():
		pending_chunks = pending_chunks.slice(pending_head)
		pending_head = 0


func _compact_pending_height_queue() -> void:
	if pending_height_head >= pending_height_chunks.size():
		pending_height_chunks.clear()
		pending_height_head = 0
		return

	if pending_height_head >= 256 \
			and pending_height_head * 2 >= pending_height_chunks.size():
		pending_height_chunks = pending_height_chunks.slice(pending_height_head)
		pending_height_head = 0


func world_to_chunk_coord(world_position: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_position.x / float(CHUNK_SIZE)),
		floori(world_position.z / float(CHUNK_SIZE))
	)


func create_stats_display() -> void:
	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 10
	add_child(canvas_layer)

	stats_label = Label.new()
	stats_label.position = Vector2(12, 12)
	stats_label.add_theme_font_size_override("font_size", 20)
	stats_label.add_theme_color_override("font_color", Color.WHITE)
	stats_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	stats_label.add_theme_constant_override("shadow_offset_x", 2)
	stats_label.add_theme_constant_override("shadow_offset_y", 2)

	canvas_layer.add_child(stats_label)
	update_stats_display()


func update_stats_display() -> void:

	var video_bytes := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED))
	var buffer_bytes := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_BUFFER_MEM_USED))
	var draw_calls := int(Performance.get_monitor(
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var primitives := int(Performance.get_monitor(
		Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))

	var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0

	var static_bytes := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var object_count := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var node_count := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))

	var collision_on := 0
	for chunk in chunks.values():
		if chunk._collision_built \
				and chunk.collision_shape_node != null \
				and not chunk.collision_shape_node.disabled:
			collision_on += 1

	stats_label.text = (
		"FPS: %d   Proc: %.2f ms   Phys: %.2f ms\n" +
		"Render Distance: %d   Center: (%d, %d)\n" +
		"Preload: %d   Prefetch: %d\n" +
		"Workers: %d   Running: %d   Completed: %d\n" +
		"Loaded: %d   Mesh Cache: %d (%s)\n" +
		"Height Cache: %d (%s)   Visible: %d   Collision: %d\n" +
		"Terrain LOD: %s   Updates: %d\n" +
		"Pending: %d\n" +
		"Video: %s   Buffer: %s   Static: %s\n" +
		"Nodes: %d   Objects: %d   Orphans: %d\n" +
		"Draw Calls: %d   Primitives: %d"
	) % [
		Engine.get_frames_per_second(),
		process_ms, physics_ms,
		render_radius,
		current_center_chunk.x, current_center_chunk.y,
		get_preload_radius(), get_prefetch_radius(),
		worker_count, in_flight_jobs.size(),
		completed_chunk_data.size() - completed_head,
		chunks.size() + cached_chunks.size(), mesh_cache.size(),
		String.humanize_size(mesh_cache_bytes),
		height_cache.size(),
		String.humanize_size(height_cache_bytes),
		visible_chunks.size(), collision_on,
		"On" if terrain_lod_enabled else "Off",
		pending_lod_chunks.size() - pending_lod_head,
		pending_chunks.size() - pending_head,
		String.humanize_size(video_bytes),
		String.humanize_size(buffer_bytes),
		String.humanize_size(static_bytes),
		node_count, object_count, orphans,
		draw_calls, primitives
	]
func _exit_tree() -> void:
	for task_id_value in in_flight_jobs.keys():
		WorkerThreadPool.wait_for_task_completion(int(task_id_value))
