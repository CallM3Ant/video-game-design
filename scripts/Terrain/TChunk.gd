
extends Node3D

const COLLISION_GRID_CELLS := 28

var chunk_size: int
var collision_vertices: PackedVector3Array
var height_cache_data := PackedByteArray()
var collision_shape_node: CollisionShape3D
var collision_body: StaticBody3D
var _collision_built := false
var terrain_mesh_instance: MeshInstance3D
var terrain_lod_enabled := false




static func generate_chunk_data(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_want_collision: bool,
	p_terrain_gen: Variant,
) -> Dictionary:
	var vertex_cache := _sample_vertex_grid(
		p_origin, p_size, p_grid_cells, p_terrain_gen
	)
	var height_cache := _compress_vertex_heights(vertex_cache, p_terrain_gen)
	return _build_chunk_data(
		p_origin, p_size, p_grid_cells, p_want_collision,
		p_terrain_gen, vertex_cache, height_cache
	)

static func generate_chunk_data_from_height_cache(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_want_collision: bool,
	p_terrain_gen: Variant,
	p_height_cache: PackedByteArray,
) -> Dictionary:
	var sample_count := (p_grid_cells + 1) * (p_grid_cells + 1)
	var raw_heights := p_height_cache.decompress(
		sample_count * 4, FileAccess.COMPRESSION_ZSTD
	)
	if raw_heights.size() != sample_count * 4:
		return {}

	var heights := raw_heights.to_float32_array()
	if heights.size() != sample_count:
		return {}

	var vertex_cache := _sample_vertex_grid_with_heights(
		p_origin, p_size, p_grid_cells, p_terrain_gen, heights
	)
	return _build_chunk_data(
		p_origin, p_size, p_grid_cells, p_want_collision,
		p_terrain_gen, vertex_cache, p_height_cache
	)


static func generate_chunk_data_from_mesh_cache(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_want_collision: bool,
	p_terrain_gen: Variant,
	p_mesh_cache: Dictionary,
	p_height_cache: PackedByteArray,
) -> Dictionary:
	if typeof(p_mesh_cache.get("grid")) != TYPE_PACKED_VECTOR3_ARRAY \
			or typeof(p_mesh_cache.get("face_colors")) != TYPE_PACKED_COLOR_ARRAY:
		return {}

	var grid: PackedVector3Array = p_mesh_cache["grid"]
	var face_colors: PackedColorArray = p_mesh_cache["face_colors"]
	if grid.size() != (p_grid_cells + 1) * (p_grid_cells + 1) \
			or face_colors.size() != p_grid_cells * p_grid_cells * 2:
		return {}
	var arrays: Dictionary
	if p_terrain_gen.has_method("build_chunk_arrays"):
		arrays = p_terrain_gen.build_chunk_arrays(
			p_origin, p_grid_cells, grid, face_colors
		)
	else:
		arrays = _build_chunk_arrays_script(
			p_origin, p_grid_cells, p_terrain_gen, grid, face_colors
		)
	if arrays.is_empty():
		return {}
	var vertices: PackedVector3Array = arrays["vertices"]
	var normals: PackedVector3Array = arrays["normals"]
	var colors: PackedColorArray = arrays["colors"]

	var collision_verts := PackedVector3Array()
	if p_want_collision:
		if p_grid_cells == COLLISION_GRID_CELLS:
			collision_verts = vertices
		else:
			var collision_cache := _sample_vertex_grid(
				p_origin, p_size, COLLISION_GRID_CELLS, p_terrain_gen
			)
			collision_verts = _build_collision_faces(
				collision_cache, COLLISION_GRID_CELLS, p_terrain_gen
			)
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"collision_vertices": collision_verts,
		"height_cache": p_height_cache,
		"mesh_cache": p_mesh_cache,
	}


static func generate_height_cache(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_terrain_gen: Variant,
) -> PackedByteArray:
	var vertex_cache := _sample_vertex_grid(
		p_origin, p_size, p_grid_cells, p_terrain_gen
	)
	return _compress_vertex_heights(vertex_cache, p_terrain_gen)

static func _compress_vertex_heights(
	vertex_cache: PackedVector3Array,
	p_terrain_gen: Variant = null,
) -> PackedByteArray:
	if p_terrain_gen != null and p_terrain_gen.has_method("compress_vertex_heights"):
		return p_terrain_gen.compress_vertex_heights(vertex_cache)
	var heights := PackedFloat32Array()
	heights.resize(vertex_cache.size())
	for index in range(vertex_cache.size()):
		heights[index] = vertex_cache[index].y
	return heights.to_byte_array().compress(FileAccess.COMPRESSION_ZSTD)


static func _make_mesh_cache(
	grid: PackedVector3Array,
	colors: PackedColorArray,
) -> Dictionary:
	var face_colors := PackedColorArray()
	face_colors.resize(colors.size() / 3)
	for index in range(face_colors.size()):
		face_colors[index] = colors[index * 3]
	return {
		"grid": grid,
		"face_colors": face_colors,
	}


static func _build_chunk_data(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_want_collision: bool,
	p_terrain_gen: Variant,
	vertex_cache: PackedVector3Array,
	height_cache: PackedByteArray,
) -> Dictionary:
	var arrays: Dictionary
	if p_terrain_gen.has_method("build_chunk_arrays"):
		arrays = p_terrain_gen.build_chunk_arrays(
			p_origin, p_grid_cells, vertex_cache, PackedColorArray()
		)
	else:
		arrays = _build_chunk_arrays_script(
			p_origin, p_grid_cells, p_terrain_gen, vertex_cache, PackedColorArray()
		)
	if arrays.is_empty():
		return {}
	var vertices: PackedVector3Array = arrays["vertices"]
	var normals: PackedVector3Array = arrays["normals"]
	var colors: PackedColorArray = arrays["colors"]
	var mesh_cache: Dictionary
	if arrays.has("mesh_cache"):
		mesh_cache = arrays["mesh_cache"]
	else:
		mesh_cache = _make_mesh_cache(vertex_cache, colors)

	var collision_verts := PackedVector3Array()

	if p_want_collision:
		if p_grid_cells == COLLISION_GRID_CELLS:
			collision_verts = vertices
		else:
			var collision_cache := _sample_vertex_grid(
				p_origin, p_size, COLLISION_GRID_CELLS, p_terrain_gen
			)
			collision_verts = _build_collision_faces(
				collision_cache, COLLISION_GRID_CELLS, p_terrain_gen
			)

	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"collision_vertices": collision_verts,
		"height_cache": height_cache,
		"mesh_cache": mesh_cache,
	}


static func _build_chunk_arrays_script(
	p_origin: Vector3i,
	p_grid_cells: int,
	p_terrain_gen: Variant,
	vertex_cache: PackedVector3Array,
	p_cached_colors: PackedColorArray,
) -> Dictionary:
	var sample_size := p_grid_cells + 1
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var vertex_count := p_grid_cells * p_grid_cells * 6
	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	var vertex_index := 0
	for z in range(p_grid_cells):
		for x in range(p_grid_cells):
			var p00: Vector3 = vertex_cache[x + z * sample_size]
			var p10: Vector3 = vertex_cache[x + 1 + z * sample_size]
			var p01: Vector3 = vertex_cache[x + (z + 1) * sample_size]
			var p11: Vector3 = vertex_cache[x + 1 + (z + 1) * sample_size]
			if (x + z) % 2 == 0:
				vertex_index = _write_triangle_data(
					vertices, normals, colors, vertex_index,
					p00, p10, p11, p_origin, p_terrain_gen, p_cached_colors
				)
				vertex_index = _write_triangle_data(
					vertices, normals, colors, vertex_index,
					p00, p11, p01, p_origin, p_terrain_gen, p_cached_colors
				)
			else:
				vertex_index = _write_triangle_data(
					vertices, normals, colors, vertex_index,
					p00, p10, p01, p_origin, p_terrain_gen, p_cached_colors
				)
				vertex_index = _write_triangle_data(
					vertices, normals, colors, vertex_index,
					p10, p11, p01, p_origin, p_terrain_gen, p_cached_colors
				)
	return {"vertices": vertices, "normals": normals, "colors": colors}


static func generate_collision_data(
	p_origin: Vector3i,
	p_size: int,
	p_terrain_gen: Variant,
) -> PackedVector3Array:
	var collision_cache := _sample_vertex_grid(
		p_origin, p_size, COLLISION_GRID_CELLS, p_terrain_gen
	)
	return _build_collision_faces(
		collision_cache, COLLISION_GRID_CELLS, p_terrain_gen
	)


static func _sample_vertex_grid(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_terrain_gen: Variant,
) -> PackedVector3Array:
	if p_terrain_gen.has_method("sample_vertex_grid"):
		return p_terrain_gen.sample_vertex_grid(
			p_origin, p_size, p_grid_cells, PackedFloat32Array()
		)
	var cell_size := float(p_size) / float(p_grid_cells)
	var sample_size := p_grid_cells + 1
	var vertex_cache := PackedVector3Array()
	vertex_cache.resize(sample_size * sample_size)

	for z in range(sample_size):
		for x in range(sample_size):
			var base_x := float(x) * cell_size
			var base_z := float(z) * cell_size
			var world_x := float(p_origin.x) + base_x
			var world_z := float(p_origin.z) + base_z

			var jitter: Vector2 = p_terrain_gen.get_vertex_jitter(
				world_x, world_z, cell_size
			)
			var height: float = p_terrain_gen.get_height(
				world_x + jitter.x, world_z + jitter.y
			)

			vertex_cache[x + z * sample_size] = Vector3(
				base_x + jitter.x, height, base_z + jitter.y
			)

	return vertex_cache


static func _sample_vertex_grid_with_heights(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_terrain_gen: Variant,
	heights: PackedFloat32Array,
) -> PackedVector3Array:
	if p_terrain_gen.has_method("sample_vertex_grid"):
		return p_terrain_gen.sample_vertex_grid(
			p_origin, p_size, p_grid_cells, heights
		)
	var cell_size := float(p_size) / float(p_grid_cells)
	var sample_size := p_grid_cells + 1
	var vertex_cache := PackedVector3Array()
	vertex_cache.resize(sample_size * sample_size)

	for z in range(sample_size):
		for x in range(sample_size):
			var base_x := float(x) * cell_size
			var base_z := float(z) * cell_size
			var world_x := float(p_origin.x) + base_x
			var world_z := float(p_origin.z) + base_z
			var jitter: Vector2 = p_terrain_gen.get_vertex_jitter(
				world_x, world_z, cell_size
			)
			var index := x + z * sample_size
			vertex_cache[index] = Vector3(
				base_x + jitter.x, heights[index], base_z + jitter.y
			)

	return vertex_cache


static func _build_collision_faces(
	vertex_cache: PackedVector3Array,
	p_grid_cells: int,
	p_terrain_gen: Variant = null,
) -> PackedVector3Array:
	if p_terrain_gen != null and p_terrain_gen.has_method("build_collision_faces"):
		return p_terrain_gen.build_collision_faces(p_grid_cells, vertex_cache)
	var sample_size := p_grid_cells + 1
	var faces := PackedVector3Array()
	faces.resize(p_grid_cells * p_grid_cells * 6)
	var idx := 0

	for z in range(p_grid_cells):
		for x in range(p_grid_cells):
			var p00: Vector3 = vertex_cache[x + z * sample_size]
			var p10: Vector3 = vertex_cache[x + 1 + z * sample_size]
			var p01: Vector3 = vertex_cache[x + (z + 1) * sample_size]
			var p11: Vector3 = vertex_cache[x + 1 + (z + 1) * sample_size]

			if (x + z) % 2 == 0:
				faces[idx] = p00; faces[idx + 1] = p10; faces[idx + 2] = p11
				faces[idx + 3] = p00; faces[idx + 4] = p11; faces[idx + 5] = p01
			else:
				faces[idx] = p00; faces[idx + 1] = p10; faces[idx + 2] = p01
				faces[idx + 3] = p10; faces[idx + 4] = p11; faces[idx + 5] = p01
			idx += 6

	return faces


static func _write_triangle_data(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	vertex_start: int,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	origin: Vector3i,
	generator: Variant,
	cached_colors: PackedColorArray,
) -> int:

	var normal := (c - a).cross(b - a).normalized()

	if normal.y < 0.0:
		normal = -normal

	var color: Color
	if cached_colors.is_empty():
		var center := (a + b + c) / 3.0
		color = generator.get_triangle_color(
			float(origin.x) + center.x,
			float(origin.z) + center.z,
			center.y,
			normal
		)
	else:
		color = cached_colors[vertex_start / 3]


	vertices[vertex_start] = a
	vertices[vertex_start + 1] = b
	vertices[vertex_start + 2] = c

	normals[vertex_start] = normal
	normals[vertex_start + 1] = normal
	normals[vertex_start + 2] = normal

	colors[vertex_start] = color
	colors[vertex_start + 1] = color
	colors[vertex_start + 2] = color

	return vertex_start + 3




func setup_from_data(
	p_origin: Vector3i,
	p_size: int,
	data: Dictionary,
	p_material: Material,
	p_rock_material: StandardMaterial3D,
	p_lod_topology: Dictionary = {},
) -> bool:

	chunk_size = p_size
	position = Vector3(p_origin)
	height_cache_data = data.get("height_cache", PackedByteArray())

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_COLOR]  = data["colors"]

	var array_mesh := _create_terrain_mesh(arrays, p_lod_topology)
	if array_mesh == null:
		return false

	terrain_mesh_instance = MeshInstance3D.new()
	terrain_mesh_instance.name = "TerrainMesh"
	terrain_mesh_instance.mesh = array_mesh
	terrain_mesh_instance.material_override = p_material
	add_child(terrain_mesh_instance)
	terrain_lod_enabled = not p_lod_topology.is_empty()
	collision_vertices = data.get("collision_vertices", PackedVector3Array())
	return true


func set_terrain_lod(
	enabled: bool,
	topology: Dictionary,
	mesh_cache: Dictionary,
	p_grid_cells: int,
	p_terrain_gen: Variant,
) -> bool:
	if terrain_lod_enabled == enabled:
		return true
	if terrain_mesh_instance == null or not terrain_mesh_instance.mesh is ArrayMesh:
		push_error("[TChunk] Cannot update LOD without a terrain mesh.")
		return false
	var current_mesh := terrain_mesh_instance.mesh as ArrayMesh
	var arrays: Array
	var cached_data: Dictionary = {}
	if not mesh_cache.is_empty():
		cached_data = generate_chunk_data_from_mesh_cache(
			Vector3i(position), chunk_size, p_grid_cells, false,
			p_terrain_gen, mesh_cache, height_cache_data
		)
	if not cached_data.is_empty():
		arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = cached_data["vertices"]
		arrays[Mesh.ARRAY_NORMAL] = cached_data["normals"]
		arrays[Mesh.ARRAY_COLOR] = cached_data["colors"]
	else:
		if not mesh_cache.is_empty():
			push_warning("[TChunk] Invalid mesh cache during LOD update; reading the existing mesh.")
		arrays = current_mesh.surface_get_arrays(0)
	var next_mesh := _create_terrain_mesh(arrays, topology if enabled else {})
	if next_mesh == null:
		return false
	terrain_mesh_instance.mesh = next_mesh
	terrain_lod_enabled = enabled
	return true


func _create_terrain_mesh(arrays: Array, topology: Dictionary) -> ArrayMesh:
	var lods: Dictionary = {}
	arrays[Mesh.ARRAY_INDEX] = null
	if not topology.is_empty():
		if typeof(topology.get("base")) != TYPE_PACKED_INT32_ARRAY \
				or typeof(topology.get("lods")) != TYPE_DICTIONARY:
			push_error("[TChunk] Invalid terrain LOD topology.")
			return null
		var base: PackedInt32Array = topology["base"]
		lods = topology["lods"]
		if base.size() != arrays[Mesh.ARRAY_VERTEX].size() or lods.is_empty():
			push_error("[TChunk] Terrain LOD topology does not match the mesh.")
			return null
		arrays[Mesh.ARRAY_INDEX] = base
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods)
	if array_mesh.get_surface_count() != 1:
		push_error("[TChunk] Failed to create the terrain mesh.")
		return null
	return array_mesh


func has_collision_data() -> bool:
	return _collision_built or not collision_vertices.is_empty()


func prepare_collision_shape() -> void:
	if _collision_built or collision_vertices.is_empty():
		return

	_build_collision_shape()
	_collision_built = collision_shape_node != null


func set_collision_data(vertices: PackedVector3Array) -> void:
	collision_vertices = vertices


func set_collision_enabled(is_enabled: bool) -> void:
	if is_enabled:
		if not has_collision_data():
			return
		if collision_shape_node != null:
			collision_shape_node.disabled = false
	else:
		if collision_shape_node != null:
			collision_shape_node.disabled = true

func _build_collision_shape() -> void:
	if collision_vertices.is_empty():
		printerr("[TChunk] FAILED to build shape: collision_vertices is EMPTY!")
		return
	
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(collision_vertices)
	shape.backface_collision = true

	collision_vertices = PackedVector3Array()

	collision_shape_node = CollisionShape3D.new()
	collision_shape_node.name = "TerrainCollisionShape"
	collision_shape_node.shape = shape
	collision_shape_node.disabled = true

	collision_body = StaticBody3D.new()
	collision_body.name = "TerrainBody"
	collision_body.collision_layer = 1  
	collision_body.collision_mask = 0 
	collision_body.add_child(collision_shape_node)
	add_child(collision_body)


func set_chunk_active(is_active: bool) -> void:
	visible = is_active
