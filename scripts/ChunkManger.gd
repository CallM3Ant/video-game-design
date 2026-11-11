
extends Node3D

const TerrainGenScript = preload("res://scripts/TerrainGen.gd")
const ChunkScript = preload("res://scripts/TChunk.gd")

const CHUNK_SIZE := 64

@export var viewer_path: NodePath
@export_range(2, 60) var render_radius: int = 20



@export_range(30.0, 360.0) var forward_cone_angle: float = 180
@export_range(0, 5) var nearby_keep_radius: int = 1
@export var world_environment_path: NodePath

@export_range(0.0, 0.95, 0.01) var fog_start_ratio := 0.65
@export_range(0.05, 1.0, 0.01) var fog_end_ratio := 0.95

var fog_environment: Environment
@export var world_seed: int = 12345
var rock_material: StandardMaterial3D


var camera: Camera3D
var last_visibility_transform := Transform3D.IDENTITY
var has_visibility_transform := false

var terrain_material: StandardMaterial3D
var viewer: Node3D
var stats_label: Label

var chunks: Dictionary = {}

var cached_chunks: Dictionary = {}

var pending_chunks: Array[Vector2i] = []
var pending_lookup: Dictionary = {}
var pending_head := 0

var worker_count: int = 1
var worker_generators: Array = []
var available_worker_slots: Array[int] = []

var in_flight_jobs: Dictionary = {}
var in_flight_lookup: Dictionary = {}

var completed_chunk_data: Array[Dictionary] = []
var completed_lookup: Dictionary = {}
var completed_head := 0

var visible_chunks: Dictionary = {}
var preload_chunks: Dictionary = {}

var current_center_chunk := Vector2i(999999, 999999)
var last_render_radius := -1



	
func _ready() -> void:
	viewer = get_node_or_null(viewer_path) as Node3D
	camera = viewer as Camera3D

	if camera == null:
		push_error("Viewer Path must point to a Camera3D.")
		set_process(false)
		return
	var world_environment := get_node_or_null(
		world_environment_path
	) as WorldEnvironment

	if world_environment != null:
		fog_environment = world_environment.environment

		if fog_environment != null:
			fog_environment.fog_enabled = true
			fog_environment.fog_mode = Environment.FOG_MODE_DEPTH

	_initialize_workers()

	terrain_material = StandardMaterial3D.new()
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.albedo_color = Color.WHITE
	terrain_material.roughness = 1.0
	terrain_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	terrain_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	
	rock_material = StandardMaterial3D.new()
	rock_material.albedo_color = Color(0.48, 0.36, 0.29)
	rock_material.roughness = 1.0
	rock_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	create_stats_display()
	update_loaded_chunks(true)


func _process(_delta: float) -> void:
	update_loaded_chunks(false)
	update_directional_visibility(true)

	_collect_completed_jobs()
	_integrate_completed_chunks()
	_dispatch_pending_jobs()

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
		worker_generators.append(TerrainGenScript.new(world_seed))
		available_worker_slots.append(slot)

	print("[ChunkManager] Initialized %d terrain worker slots." % worker_count)


func _run_chunk_worker(
	p_origin: Vector3i,
	p_size: int,
	p_generator: Variant,
	p_output: Dictionary
) -> void:
	p_output["data"] = ChunkScript.generate_chunk_data(
		p_origin,
		p_size,
		p_generator,
	)
func update_fog_distance() -> void:

	if fog_environment == null:
		return

	var max_distance := float(CHUNK_SIZE * get_visible_radius())

	fog_environment.fog_depth_begin = (
		max_distance * fog_start_ratio
	)

	fog_environment.fog_depth_end = (
		max_distance * fog_end_ratio
	)

func get_preload_radius() -> int:
	return render_radius + 2


func get_unload_radius() -> int:
	return render_radius + 4
func get_visible_radius() -> int:
	return render_radius


func update_loaded_chunks(force_update: bool) -> void:
	var center: Vector2i = world_to_chunk_coord(viewer.global_position)

	if not force_update:
		if center == current_center_chunk and last_render_radius == render_radius:
			return

	var radius_changed := render_radius != last_render_radius

	current_center_chunk = center
	last_render_radius = render_radius

	if radius_changed:
		update_fog_distance()


	preload_chunks.clear()

	var preload_radius := get_preload_radius()

	for z_offset in range(-preload_radius, preload_radius + 1):
		for x_offset in range(-preload_radius, preload_radius + 1):
			var coord := center + Vector2i(x_offset, z_offset)
			preload_chunks[coord] = true

	update_directional_visibility()


	for coord in cached_chunks.keys():
		if preload_chunks.has(coord):
			var chunk: Variant = cached_chunks[coord]

			chunks[coord] = chunk
			cached_chunks.erase(coord)

	for coord in chunks.keys():
		var chunk: Variant = chunks[coord]
		chunk.set_chunk_active(visible_chunks.has(coord))

	var chunks_to_cache: Array[Vector2i] = []

	for coord in chunks.keys():
		if not preload_chunks.has(coord):
			chunks_to_cache.append(coord)

	for coord in chunks_to_cache:
		var chunk: Variant = chunks[coord]

		chunk.set_chunk_active(false)

		cached_chunks[coord] = chunk
		chunks.erase(coord)

	var chunks_to_unload: Array[Vector2i] = []

	for coord in cached_chunks.keys():
		var distance := maxi(
			absi(coord.x - center.x),
			absi(coord.y - center.y)
		)

		if distance > get_unload_radius():
			chunks_to_unload.append(coord)

	for coord in chunks_to_unload:
		cached_chunks[coord].queue_free()
		cached_chunks.erase(coord)


	pending_chunks.clear()
	pending_lookup.clear()
	pending_head = 0

	var candidates: Array[Vector2i] = []

	for ring in range(preload_radius + 1):

		if ring == 0:
			candidates.append(center)
			continue

		for x_offset in range(-ring, ring + 1):
			candidates.append(
				center + Vector2i(x_offset, -ring)
			)

			candidates.append(
				center + Vector2i(x_offset, ring)
			)

		for z_offset in range(-ring + 1, ring):
			candidates.append(
				center + Vector2i(-ring, z_offset)
			)

			candidates.append(
				center + Vector2i(ring, z_offset)
			)

	for want_visible in [true, false]:

		for coord in candidates:

			var is_visible := visible_chunks.has(coord)

			if is_visible != want_visible:
				continue

			if chunks.has(coord):
				continue

			if cached_chunks.has(coord):
				continue

			if in_flight_lookup.has(coord):
				continue

			if completed_lookup.has(coord):
				continue

			if pending_lookup.has(coord):
				continue

			pending_chunks.append(coord)
			pending_lookup[coord] = true




func update_directional_visibility(force_update: bool = false) -> void:
	var current_transform := camera.global_transform

	if not force_update and has_visibility_transform:
		if current_transform == last_visibility_transform:
			return

	last_visibility_transform = current_transform
	has_visibility_transform = true

	visible_chunks.clear()

	var camera_position := camera.global_position

	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()

	for coord in preload_chunks.keys():
		var offset: Vector2i = coord - current_center_chunk

		var distance := maxi(
			absi(offset.x),
			absi(offset.y)
		)

		if distance > get_visible_radius():
			continue

		if distance <= nearby_keep_radius:
			visible_chunks[coord] = true
			continue

		if is_chunk_in_forward_cone(
			coord,
			camera_position,
			forward
		):
			visible_chunks[coord] = true

	for coord in chunks.keys():
		var chunk: Variant = chunks[coord]
		chunk.set_chunk_active(visible_chunks.has(coord))

func is_chunk_in_forward_cone(
	coord: Vector2i,
	camera_position: Vector3,
	forward: Vector3
) -> bool:

	var chunk_center := Vector3(
		(float(coord.x) + 0.5) * CHUNK_SIZE,
		camera_position.y,
		(float(coord.y) + 0.5) * CHUNK_SIZE
	)

	var to_chunk := chunk_center - camera_position
	to_chunk.y = 0.0

	var distance := to_chunk.length()

	if distance < 0.001:
		return true

	var max_distance := float(get_visible_radius() * CHUNK_SIZE)

	if distance > max_distance:
		return false

	var direction := to_chunk / distance

	var dot := clampf(
		direction.dot(forward),
		-1.0,
		1.0
	)
	var half_angle := deg_to_rad(forward_cone_angle * 0.5)


	var chunk_radius := CHUNK_SIZE * 0.7072
	var extra_angle := asin(
		clampf(chunk_radius / maxf(distance, chunk_radius), 0.0, 1.0)
	)

	return acos(dot) <= half_angle + extra_angle
	





func _dispatch_pending_jobs() -> void:
	var completed_backlog := completed_chunk_data.size() - completed_head
	var max_completed_backlog := maxi(1, worker_count * 2)

	while not available_worker_slots.is_empty():
		if completed_backlog >= max_completed_backlog:
			break

		if pending_head >= pending_chunks.size():
			break

		var coord: Vector2i = pending_chunks[pending_head]
		pending_head += 1
		pending_lookup.erase(coord)

		if not preload_chunks.has(coord):
			continue

		if chunks.has(coord) or cached_chunks.has(coord):
			continue

		if in_flight_lookup.has(coord) or completed_lookup.has(coord):
			continue

		var origin := Vector3i(
			coord.x * CHUNK_SIZE,
			0,
			coord.y * CHUNK_SIZE
		)

		var slot: int = available_worker_slots.pop_back()
		var generator: Variant = worker_generators[slot]

		var output: Dictionary = {"data": {}}

		var task_id: int = WorkerThreadPool.add_task(
			Callable(self, "_run_chunk_worker").bind(
				origin,
				CHUNK_SIZE,
				generator,
				output
			),
			false,
			"Terrain chunk %d,%d" % [coord.x, coord.y]
		)

		if task_id < 0:
			available_worker_slots.append(slot)
			pending_head -= 1
			pending_lookup[coord] = true
			push_error("Failed to schedule terrain worker task for chunk %s." % str(coord))
			break

		in_flight_jobs[task_id] = {
			"coord": coord,
			"origin": origin,
			"slot": slot,
			"output": output
		}
		in_flight_lookup[coord] = task_id

	compact_pending_queue()


func _collect_completed_jobs() -> void:
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

		available_worker_slots.append(int(job["slot"]))

		if wait_error != OK:
			push_error("Could not collect terrain task %d: %s" % [task_id, error_string(wait_error)])
			continue

		var output: Dictionary = job["output"]
		var data: Dictionary = output.get("data", {})

		if data.is_empty():
			push_error("Terrain worker returned no data for chunk %s." % str(coord))
			continue

		if not preload_chunks.has(coord):
			continue

		if chunks.has(coord) or cached_chunks.has(coord):
			continue

		completed_chunk_data.append({
			"coord": coord,
			"origin": job["origin"],
			"data": data
		})
		completed_lookup[coord] = true


func _integrate_completed_chunks() -> void:

	while completed_head < completed_chunk_data.size():
		var result: Dictionary = completed_chunk_data[completed_head]
		completed_head += 1

		var coord: Vector2i = result["coord"]
		completed_lookup.erase(coord)

		if not preload_chunks.has(coord):
			continue

		if chunks.has(coord) or cached_chunks.has(coord):
			continue

		var chunk: Variant = ChunkScript.new()
		chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]

		add_child(chunk)
		chunk.setup_from_data(
			result["origin"],
			CHUNK_SIZE,
			result["data"],
			terrain_material,
			rock_material
		)

		chunks[coord] = chunk
		chunk.set_chunk_active(visible_chunks.has(coord))

	_compact_completed_queue()


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


func update_stats_display() -> void:
	var buffer_memory_mb := float(
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_BUFFER_MEM_USED
		)
	) / 1048576.0

	var video_memory_mb := float(
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_VIDEO_MEM_USED
		)
	) / 1048576.0

	var draw_calls := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	)

	var primitives := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)

	stats_label.text = (
		"FPS: %d\n" +
		"Render Distance: %d rings\n" +
		"Preload Radius: %d\n" +
		"Unload Radius: %d\n" +
		"Worker Slots: %d\n" +
		"Running Jobs: %d\n" +
		"Completed Waiting: %d\n" +
		"Loaded: %d\n" +
		"Cached: %d\n" +
		"Visible: %d\n" +
		"Pending: %d\n" +
		"GPU Buffers: %.1f MB\n" +
		"GPU Total: %.1f MB\n" +
		"Draw Calls: %d\n" +
		"Primitives: %d"
	) % [
		Engine.get_frames_per_second(),
		render_radius,
		get_preload_radius(),
		get_unload_radius(),
		worker_count,
		in_flight_jobs.size(),
		completed_chunk_data.size() - completed_head,
		chunks.size(),
		cached_chunks.size(),
		visible_chunks.size(),
		pending_chunks.size() - pending_head,
		buffer_memory_mb,
		video_memory_mb,
		draw_calls,
		primitives
	]


func _exit_tree() -> void:
	for task_id_value in in_flight_jobs.keys():
		WorkerThreadPool.wait_for_task_completion(int(task_id_value))
