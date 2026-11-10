
extends Node3D

const TerrainGenScript = preload("res://scripts/TerrainGen.gd")
const ChunkScript = preload("res://scripts/TChunk.gd")

const CHUNK_SIZE := 32

@export var viewer_path: NodePath
@export_range(1, 20) var render_radius: int = 4
@export_range(1, 16) var chunks_generated_per_frame: int = 1
@export var world_seed: int = 12345

var terrain_gen: Variant
var terrain_material: StandardMaterial3D
var viewer: Node3D
var stats_label: Label

var chunks: Dictionary = {}
var cached_chunks: Dictionary = {}

var pending_chunks: Array[Vector2i] = []

var visible_chunks: Dictionary = {}
var preload_chunks: Dictionary = {}

var current_center_chunk := Vector2i(999999, 999999)
var last_render_radius := -1


func _ready() -> void:
	viewer = get_node_or_null(viewer_path) as Node3D

	if viewer == null:
		push_error("Assign Camera3D to ChunkManager's Viewer Path.")
		set_process(false)
		return

	terrain_gen = TerrainGenScript.new(world_seed)

	terrain_material = StandardMaterial3D.new()
	terrain_material.vertex_color_use_as_albedo = true
	terrain_material.albedo_color = Color.WHITE
	terrain_material.roughness = 1.0
	terrain_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	terrain_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	create_stats_display()
	update_loaded_chunks(true)


func _process(_delta: float) -> void:

	if viewer == null:
		return

	update_loaded_chunks(false)

	for i in range(chunks_generated_per_frame):
		create_next_chunk()

	update_stats_display()


func get_preload_radius() -> int:
	return render_radius + 2


func get_unload_radius() -> int:
	return render_radius + 4


func update_loaded_chunks(force_update: bool) -> void:

	var center := world_to_chunk_coord(viewer.global_position)

	if not force_update:
		if center == current_center_chunk and last_render_radius == render_radius:
			return

	current_center_chunk = center
	last_render_radius = render_radius

	visible_chunks.clear()
	preload_chunks.clear()

	var preload_radius := get_preload_radius()

	for z_offset in range(-preload_radius, preload_radius + 1):
		for x_offset in range(-preload_radius, preload_radius + 1):

			var coord := center + Vector2i(x_offset, z_offset)

			preload_chunks[coord] = true

			if maxi(absi(x_offset), absi(z_offset)) <= render_radius:
				visible_chunks[coord] = true

	
	for coord in visible_chunks.keys():

		if cached_chunks.has(coord):

			var cached_chunk: Variant = cached_chunks[coord]

			cached_chunk.set_chunk_active(true)

			chunks[coord] = cached_chunk
			cached_chunks.erase(coord)

	
	var chunks_to_cache: Array[Vector2i] = []

	for old_coord in chunks.keys():

		if not visible_chunks.has(old_coord):
			chunks_to_cache.append(old_coord)

	for old_coord in chunks_to_cache:

		var chunk: Variant = chunks[old_coord]

		chunk.set_chunk_active(false)

		cached_chunks[old_coord] = chunk
		chunks.erase(old_coord)


	var chunks_to_unload: Array[Vector2i] = []

	for cached_coord in cached_chunks.keys():

		var distance := maxi(
			absi(cached_coord.x - center.x),
			absi(cached_coord.y - center.y)
		)

		if distance > get_unload_radius():
			chunks_to_unload.append(cached_coord)

	for coord in chunks_to_unload:

		cached_chunks[coord].queue_free()
		cached_chunks.erase(coord)


	for ring in range(preload_radius + 1):

		for z_offset in range(-preload_radius, preload_radius + 1):
			for x_offset in range(-preload_radius, preload_radius + 1):

				if maxi(absi(x_offset), absi(z_offset)) != ring:
					continue

				var coord := center + Vector2i(x_offset, z_offset)

				if chunks.has(coord):
					continue

				if cached_chunks.has(coord):
					continue

				if pending_chunks.has(coord):
					continue

				pending_chunks.append(coord)


func create_next_chunk() -> void:

	while not pending_chunks.is_empty():

		var coord: Vector2i = pending_chunks.pop_front()

		if not preload_chunks.has(coord):
			continue

		if chunks.has(coord) or cached_chunks.has(coord):
			continue

		var origin := Vector3i(
			coord.x * CHUNK_SIZE,
			0,
			coord.y * CHUNK_SIZE
		)

		
		var chunk: Variant = ChunkScript.new()

		chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]


		add_child(chunk)


		chunk.setup(origin, 32, terrain_gen, terrain_material)

		if visible_chunks.has(coord):
			chunks[coord] = chunk
		else:
			chunk.set_chunk_active(false)
			cached_chunks[coord] = chunk

		return


		if visible_chunks.has(coord):
			chunks[coord] = chunk
		else:
			chunk.set_chunk_active(false)
			cached_chunks[coord] = chunk

		return


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

	stats_label.add_theme_font_size_override(
		"font_size", 20
	)

	stats_label.add_theme_color_override(
		"font_color", Color.WHITE
	)

	stats_label.add_theme_color_override(
		"font_shadow_color", Color.BLACK
	)

	stats_label.add_theme_constant_override(
		"shadow_offset_x", 2
	)

	stats_label.add_theme_constant_override(
		"shadow_offset_y", 2
	)

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
		"Render Radius: %d\n" +
		"Preload Radius: %d\n" +
		"Unload Radius: %d\n" +
		"Chunks Per Frame: %d\n" +
		"Active: %d\n" +
		"Cached: %d\n" +
		"Total: %d\n" +
		"GPU Buffers: %.1f MB\n" +
		"GPU Total: %.1f MB\n" +
		"Draw Calls: %d\n" +
		"Primitives: %d"
	) % [
		Engine.get_frames_per_second(),
		render_radius,
		get_preload_radius(),
		get_unload_radius(),
		chunks_generated_per_frame,
		chunks.size(),
		cached_chunks.size(),
		chunks.size() + cached_chunks.size(),
		buffer_memory_mb,
		video_memory_mb,
		draw_calls,
		primitives
	]
