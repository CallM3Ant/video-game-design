
extends Node3D

const GRID_CELLS := 56
const FEATURE_CELL_SIZE := 64.0

const ROCK_TAPER_RATIOS := [0.12, 0.25, 0.40, 0.55]

var chunk_size: int
var rock_material: StandardMaterial3D



static func generate_chunk_data(
	p_origin: Vector3i,
	p_size: int,
	p_terrain_gen: Variant
) -> Dictionary:

	var cell_size := float(p_size) / float(GRID_CELLS)
	var sample_size := GRID_CELLS + 1

	var vertex_cache := PackedVector3Array()
	vertex_cache.resize(sample_size * sample_size)

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

	var vertex_count := GRID_CELLS * GRID_CELLS * 6

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	vertices.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)

	var vertex_index := 0

	for z in range(GRID_CELLS):
		for x in range(GRID_CELLS):

			var p00: Vector3 = vertex_cache[x + z * sample_size]
			var p10: Vector3 = vertex_cache[x + 1 + z * sample_size]
			var p01: Vector3 = vertex_cache[x + (z + 1) * sample_size]
			var p11: Vector3 = vertex_cache[x + 1 + (z + 1) * sample_size]

			if (x + z) % 2 == 0:

				vertex_index = _write_triangle_data(
					vertices, normals, colors,
					p00, p11, p01,
					p_origin, p_terrain_gen,
					vertex_index
				)

				vertex_index = _write_triangle_data(
					vertices, normals, colors,
					p00, p10, p11,
					p_origin, p_terrain_gen,
					vertex_index
				)

			else:

				vertex_index = _write_triangle_data(
					vertices, normals, colors,
					p00, p10, p01,
					p_origin, p_terrain_gen,
					vertex_index
				)

				vertex_index = _write_triangle_data(
					vertices, normals, colors,
					p10, p11, p01,
					p_origin, p_terrain_gen,
					vertex_index
				)

	var rock_transforms := _generate_geological_data(
		p_origin,
		p_size,
		p_terrain_gen
	)

	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"rock_transforms": rock_transforms
	}


static func _write_triangle_data(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	origin: Vector3i,
	generator: Variant,
	vertex_index: int
) -> int:

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

static func _generate_geological_data(
	origin: Vector3i,
	size: int,
	generator: Variant
) -> Array:

	var rock_transforms: Array = [[], [], [], []]

	var min_cell_x := floori(float(origin.x) / FEATURE_CELL_SIZE) - 1
	var min_cell_z := floori(float(origin.z) / FEATURE_CELL_SIZE) - 1

	var max_cell_x := floori(float(origin.x + size) / FEATURE_CELL_SIZE) + 1
	var max_cell_z := floori(float(origin.z + size) / FEATURE_CELL_SIZE) + 1

	var chunk_coord := Vector2i(
		floori(float(origin.x) / float(size)),
		floori(float(origin.z) / float(size))
	)

	for cz in range(min_cell_z, max_cell_z + 1):
		for cx in range(min_cell_x, max_cell_x + 1):

			var rng := RandomNumberGenerator.new()
			rng.seed = int(hash(Vector2i(cx, cz)) + generator.world_seed)

			if rng.randf() > 0.48:
				continue

			var world_x := (
				float(cx) * FEATURE_CELL_SIZE
				+ rng.randf_range(10.0, 54.0)
			)

			var world_z := (
				float(cz) * FEATURE_CELL_SIZE
				+ rng.randf_range(10.0, 54.0)
			)

			var chunk_owner := Vector2i(
				floori(world_x / float(size)),
				floori(world_z / float(size))
			)

			if chunk_owner != chunk_coord:
				continue

			var local_x := world_x - float(origin.x)
			var local_z := world_z - float(origin.z)

			if local_x < 5.0 or local_x > size - 5.0:
				continue

			if local_z < 5.0 or local_z > size - 5.0:
				continue

			_generate_rock_formation(
				Vector2(local_x, local_z),
				rng,
				rock_transforms,
				origin,
				generator
			)

	return rock_transforms


static func _generate_rock_formation(
	center: Vector2,
	rng: RandomNumberGenerator,
	rock_transforms: Array,
	origin: Vector3i,
	generator: Variant
) -> void:

	var pillar_count := rng.randi_range(2, 4)

	for i in range(pillar_count):

		var offset := Vector2(
			rng.randf_range(-3.5, 3.5),
			rng.randf_range(-3.5, 3.5)
		)

		var local_position := center + offset

		var world_x := float(origin.x) + local_position.x
		var world_z := float(origin.z) + local_position.y

		var ground_height: float = generator.get_height(
			world_x,
			world_z
		)

		var height := rng.randf_range(5.0, 15.0)
		var bottom_radius := rng.randf_range(1.0, 2.1)
		var top_radius := rng.randf_range(0.15, 0.65)

		var taper_ratio := top_radius / bottom_radius
		var bucket := _get_nearest_rock_bucket(taper_ratio)

		var rock_rotation := Vector3(
			rng.randf_range(-0.09, 0.09),
			rng.randf_range(0.0, TAU),
			rng.randf_range(-0.09, 0.09)
		)

		var rock_basis := Basis.from_euler(rock_rotation)
		rock_basis = rock_basis.scaled(
			Vector3(bottom_radius, height, bottom_radius)
		)

		var rock_transform := Transform3D(
			rock_basis,
			Vector3(
				local_position.x,
				ground_height + height * 0.5,
				local_position.y
			)
		)

		rock_transforms[bucket].append(rock_transform)


static func _get_nearest_rock_bucket(ratio: float) -> int:

	var best_bucket := 0
	var best_difference := INF

	for i in range(ROCK_TAPER_RATIOS.size()):

		var difference: float = absf(
			ratio - ROCK_TAPER_RATIOS[i]
		)

		if difference < best_difference:
			best_difference = difference
			best_bucket = i

	return best_bucket


func setup_from_data(p_origin: Vector3i,p_size: int,data: Dictionary,p_material: Material) -> void:
	chunk_size = p_size
	position = Vector3(p_origin)
	rock_material = create_rock_material()

	var terrain_mesh_instance := MeshInstance3D.new()
	terrain_mesh_instance.name = "TerrainMesh"
	terrain_mesh_instance.material_override = p_material

	add_child(terrain_mesh_instance)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)

	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_COLOR] = data["colors"]

	var array_mesh := ArrayMesh.new()

	array_mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		arrays
	)

	terrain_mesh_instance.mesh = array_mesh

	var rock_transforms: Array = data["rock_transforms"]

	for bucket in range(ROCK_TAPER_RATIOS.size()):

		if rock_transforms[bucket].is_empty():
			continue

		create_rock_multimesh(
			bucket,
			rock_transforms[bucket]
		)


func create_rock_material() -> StandardMaterial3D:

	var material := StandardMaterial3D.new()

	material.albedo_color = Color(0.48, 0.36, 0.29)
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	return material


func create_rock_multimesh(
	bucket: int,
	transforms: Array
) -> void:

	var rock_mesh := CylinderMesh.new()
	rock_mesh.top_radius = ROCK_TAPER_RATIOS[bucket]
	rock_mesh.bottom_radius = 1.0
	rock_mesh.height = 1.0
	rock_mesh.radial_segments = 5
	rock_mesh.rings = 2

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = rock_mesh
	multimesh.instance_count = transforms.size()

	for i in range(transforms.size()):
		multimesh.set_instance_transform(i, transforms[i])

	multimesh.custom_aabb = AABB(
		Vector3(-10.0, -80.0, -10.0),
		Vector3(chunk_size + 20.0, 240.0, chunk_size + 20.0)
	)

	var rock_batch := MultiMeshInstance3D.new()
	rock_batch.name = "RockBatch_%d" % bucket
	rock_batch.multimesh = multimesh
	rock_batch.material_override = rock_material

	add_child(rock_batch)


func set_chunk_active(is_active: bool) -> void:
	visible = is_active
