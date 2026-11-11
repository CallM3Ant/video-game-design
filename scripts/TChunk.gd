
extends Node3D

const GRID_CELLS := 28
var chunk_size: int



static func generate_chunk_data(
	p_origin: Vector3i,
	p_size: int,
	p_terrain_gen: Variant,
) -> Dictionary:

	var cell_size := float(p_size) / float(GRID_CELLS)
	var sample_size := GRID_CELLS + 1

	var vertex_cache := PackedVector3Array()
	vertex_cache.resize(sample_size * sample_size)

	# Generate terrain vertices.
	for z in range(sample_size):
		for x in range(sample_size):

			var base_x := float(x) * cell_size
			var base_z := float(z) * cell_size

			var world_x := float(p_origin.x) + base_x
			var world_z := float(p_origin.z) + base_z

			var jitter: Vector2 = p_terrain_gen.get_vertex_jitter(
				world_x,
				world_z,
				cell_size
			)

			var height: float = p_terrain_gen.get_height(
				world_x + jitter.x,
				world_z + jitter.y
			)

			vertex_cache[x + z * sample_size] = Vector3(
				base_x + jitter.x,
				height,
				base_z + jitter.y
			)

	# Prepare mesh arrays.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# Generate triangles from the vertex cache.
	for z in range(GRID_CELLS):
		for x in range(GRID_CELLS):

			var p00: Vector3 = vertex_cache[
				x + z * sample_size
			]

			var p10: Vector3 = vertex_cache[
				x + 1 + z * sample_size
			]

			var p01: Vector3 = vertex_cache[
				x + (z + 1) * sample_size
			]

			var p11: Vector3 = vertex_cache[
				x + 1 + (z + 1) * sample_size
			]

			# Alternate diagonals to reduce visible grid patterns.
			if (x + z) % 2 == 0:

				_append_triangle_data(
					vertices, normals, colors, indices,
					p00, p10, p11,
					p_origin, p_terrain_gen
				)

				_append_triangle_data(
					vertices, normals, colors, indices,
					p00, p11, p01,
					p_origin, p_terrain_gen
				)

			else:

				_append_triangle_data(
					vertices, normals, colors, indices,
					p00, p10, p01,
					p_origin, p_terrain_gen
				)

				_append_triangle_data(
					vertices, normals, colors, indices,
					p10, p11, p01,
					p_origin, p_terrain_gen
				)

	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"indices": indices
	}



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
	arrays[Mesh.ARRAY_COLOR] = data["colors"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		arrays
	)

	var terrain_instance := MeshInstance3D.new()
	terrain_instance.name = "TerrainMesh"
	terrain_instance.mesh = array_mesh
	terrain_instance.material_override = p_material

	add_child(terrain_instance)


func set_chunk_active(is_active: bool) -> void:
	visible = is_active
