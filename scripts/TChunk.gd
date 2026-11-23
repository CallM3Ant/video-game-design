
extends Node3D

const COLLISION_GRID_CELLS := 28

var chunk_size: int
var collision_vertices: PackedVector3Array
var collision_shape_node: CollisionShape3D
var collision_body: StaticBody3D
var _collision_built := false




static func generate_chunk_data(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_want_collision: bool,
	p_terrain_gen: Variant,
) -> Dictionary:

	var sample_size := p_grid_cells + 1

	var vertex_cache := _sample_vertex_grid(
		p_origin, p_size, p_grid_cells, p_terrain_gen
	)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for z in range(p_grid_cells):
		for x in range(p_grid_cells):
			var p00: Vector3 = vertex_cache[x + z * sample_size]
			var p10: Vector3 = vertex_cache[x + 1 + z * sample_size]
			var p01: Vector3 = vertex_cache[x + (z + 1) * sample_size]
			var p11: Vector3 = vertex_cache[x + 1 + (z + 1) * sample_size]

			if (x + z) % 2 == 0:
				_append_triangle_data(vertices, normals, colors, indices, p00, p10, p11, p_origin, p_terrain_gen)
				_append_triangle_data(vertices, normals, colors, indices, p00, p11, p01, p_origin, p_terrain_gen)
			else:
				_append_triangle_data(vertices, normals, colors, indices, p00, p10, p01, p_origin, p_terrain_gen)
				_append_triangle_data(vertices, normals, colors, indices, p10, p11, p01, p_origin, p_terrain_gen)

	var collision_verts := PackedVector3Array()
	if p_want_collision:
		if p_grid_cells == COLLISION_GRID_CELLS:
			collision_verts = vertices
		else:
			# a second pass at fixed 28² resolution i think
			var collision_cache := _sample_vertex_grid(
				p_origin, p_size, COLLISION_GRID_CELLS, p_terrain_gen
			)
			collision_verts = _build_collision_faces(
				collision_cache, COLLISION_GRID_CELLS
			)

	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"indices": indices,
		"collision_vertices": collision_verts,
	}


static func _sample_vertex_grid(
	p_origin: Vector3i,
	p_size: int,
	p_grid_cells: int,
	p_terrain_gen: Variant,
) -> PackedVector3Array:

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


static func _build_collision_faces(
	vertex_cache: PackedVector3Array,
	p_grid_cells: int,
) -> PackedVector3Array:

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


static func _append_triangle_data(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	origin: Vector3i,
	generator: Variant,
) -> void:

	var normal := (c - a).cross(b - a).normalized()

	if normal.y < 0.0:
		normal = -normal

	var center := (a + b + c) / 3.0

	var color: Color = generator.get_triangle_color(
		float(origin.x) + center.x,
		float(origin.z) + center.z,
		center.y,
		normal
	)


	var vertex_start := vertices.size()

	vertices.append(a)
	vertices.append(b)
	vertices.append(c)

	normals.append(normal)
	normals.append(normal)
	normals.append(normal)

	colors.append(color)
	colors.append(color)
	colors.append(color)

	indices.append(vertex_start)
	indices.append(vertex_start + 1)
	indices.append(vertex_start + 2)




func setup_from_data(
	p_origin: Vector3i,
	p_size: int,
	data: Dictionary,
	p_material: Material,
	p_rock_material: StandardMaterial3D
) -> void:

	chunk_size = p_size
	position = Vector3(p_origin)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_COLOR]  = data["colors"]
	arrays[Mesh.ARRAY_INDEX]  = data["indices"]

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var terrain_instance := MeshInstance3D.new()
	terrain_instance.name = "TerrainMesh"
	terrain_instance.mesh = array_mesh
	terrain_instance.material_override = p_material
	add_child(terrain_instance)
	collision_vertices = data.get("collision_vertices", PackedVector3Array())


func set_collision_enabled(is_enabled: bool) -> void:
	if is_enabled:
		if not _collision_built:
			_build_collision_shape()
			_collision_built = true
		if collision_shape_node != null:
			collision_shape_node.disabled = false
			# print("[TChunk] Enabled collision at ", global_position)
		else:
			printerr("[TChunk] Tried to enable collision, but shape is null! (Vertices empty?)")
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
