
extends Node3D

const GRID_CELLS := 12
const FEATURE_CELL_SIZE := 64.0

var chunk_origin: Vector3i
var chunk_size: int
var terrain_gen: Variant
var cell_size: float
var sample_size: int

var vertex_cache := PackedVector3Array()
var terrain_mesh_instance: MeshInstance3D

var rock_material: StandardMaterial3D


func setup(
	p_origin: Vector3i,
	p_size: int,
	p_terrain_gen: Variant,
	p_material: Material
) -> void:

	chunk_origin = p_origin
	chunk_size = p_size
	terrain_gen = p_terrain_gen

	cell_size = float(chunk_size) / float(GRID_CELLS)
	position = Vector3(chunk_origin)

	rock_material = create_rock_material()

	terrain_mesh_instance = MeshInstance3D.new()
	terrain_mesh_instance.name = "TerrainMesh"
	terrain_mesh_instance.material_override = p_material
	add_child(terrain_mesh_instance)

	build_vertex_cache()
	build_surface_mesh()
	generate_geological_features()


func create_rock_material() -> StandardMaterial3D:

	var material := StandardMaterial3D.new()

	material.albedo_color = Color(0.48, 0.36, 0.29)
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	return material


func set_chunk_active(is_active: bool) -> void:
	visible = is_active


func build_vertex_cache() -> void:

	sample_size = GRID_CELLS + 1
	vertex_cache.resize(sample_size * sample_size)

	for z in range(sample_size):
		for x in range(sample_size):

			var base_x := float(x) * cell_size
			var base_z := float(z) * cell_size

			var world_x := float(chunk_origin.x) + base_x
			var world_z := float(chunk_origin.z) + base_z

			var jitter: Vector2 = terrain_gen.get_vertex_jitter(
				world_x,
				world_z,
				cell_size
			)

			var sample_x := world_x + jitter.x
			var sample_z := world_z + jitter.y

			var height: float = terrain_gen.get_height(
				sample_x,
				sample_z
			)

			vertex_cache[get_vertex_index(x, z)] = Vector3(
				base_x + jitter.x,
				height,
				base_z + jitter.y
			)


func get_vertex_index(x: int, z: int) -> int:
	return x + z * sample_size


func get_vertex(x: int, z: int) -> Vector3:
	return vertex_cache[get_vertex_index(x, z)]


func build_surface_mesh() -> void:

	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z in range(GRID_CELLS):
		for x in range(GRID_CELLS):

			var p00 := get_vertex(x, z)
			var p10 := get_vertex(x + 1, z)
			var p01 := get_vertex(x, z + 1)
			var p11 := get_vertex(x + 1, z + 1)

			if (x + z) % 2 == 0:
				add_flat_triangle(surface_tool, p00, p11, p01)
				add_flat_triangle(surface_tool, p00, p10, p11)
			else:
				add_flat_triangle(surface_tool, p00, p10, p01)
				add_flat_triangle(surface_tool, p10, p11, p01)

	terrain_mesh_instance.mesh = surface_tool.commit()


func add_flat_triangle(
	surface_tool: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3
) -> void:

	var normal := (c - a).cross(b - a).normalized()

	if normal.y < 0.0:
		normal = -normal

	var center := (a + b + c) / 3.0

	var world_x := float(chunk_origin.x) + center.x
	var world_z := float(chunk_origin.z) + center.z

	var color: Color = terrain_gen.get_triangle_color(
		world_x,
		world_z,
		center.y,
		normal
	)

	surface_tool.set_normal(normal)
	surface_tool.set_color(color)
	surface_tool.add_vertex(a)

	surface_tool.set_normal(normal)
	surface_tool.set_color(color)
	surface_tool.add_vertex(b)

	surface_tool.set_normal(normal)
	surface_tool.set_color(color)
	surface_tool.add_vertex(c)




func generate_geological_features() -> void:

	var min_cell_x := floori(
		float(chunk_origin.x) / FEATURE_CELL_SIZE
	) - 1

	var min_cell_z := floori(
		float(chunk_origin.z) / FEATURE_CELL_SIZE
	) - 1

	var max_cell_x := floori(
		float(chunk_origin.x + chunk_size) / FEATURE_CELL_SIZE
	) + 1

	var max_cell_z := floori(
		float(chunk_origin.z + chunk_size) / FEATURE_CELL_SIZE
	) + 1

	var chunk_coord := Vector2i(
		floori(float(chunk_origin.x) / float(chunk_size)),
		floori(float(chunk_origin.z) / float(chunk_size))
	)

	for cz in range(min_cell_z, max_cell_z + 1):
		for cx in range(min_cell_x, max_cell_x + 1):

			var rng := RandomNumberGenerator.new()

			rng.seed = int(
				hash(Vector2i(cx, cz)) + terrain_gen.world_seed
			)
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

			var owner := Vector2i(
				floori(world_x / float(chunk_size)),
				floori(world_z / float(chunk_size))
			)

			if owner != chunk_coord:
				continue

			var local_x := world_x - float(chunk_origin.x)
			var local_z := world_z - float(chunk_origin.z)

			if local_x < 5.0 or local_x > chunk_size - 5.0:
				continue

			if local_z < 5.0 or local_z > chunk_size - 5.0:
				continue

			create_rock_formation(
				Vector2(local_x, local_z),
				rng
			)


func create_rock_formation(
	center: Vector2,
	rng: RandomNumberGenerator
) -> void:

	var pillar_count := rng.randi_range(2, 4)

	for i in range(pillar_count):

		var offset := Vector2(
			rng.randf_range(-3.5, 3.5),
			rng.randf_range(-3.5, 3.5)
		)

		var local_position := center + offset

		var world_x := float(chunk_origin.x) + local_position.x
		var world_z := float(chunk_origin.z) + local_position.y

		var ground_height: float = terrain_gen.get_height(
			world_x,
			world_z
		)

		var height := rng.randf_range(5.0, 15.0)
		var bottom_radius := rng.randf_range(1.0, 2.1)
		var top_radius := rng.randf_range(0.15, 0.65)

		var rock_mesh := CylinderMesh.new()

		rock_mesh.top_radius = top_radius
		rock_mesh.bottom_radius = bottom_radius
		rock_mesh.height = height
		rock_mesh.radial_segments = 5
		rock_mesh.rings = 2
		rock_mesh.top_radius = top_radius
		rock_mesh.bottom_radius = bottom_radius
		rock_mesh.height = height
		rock_mesh.radial_segments = 5
		rock_mesh.rings = 2

		var rock := MeshInstance3D.new()
		rock.mesh = rock_mesh
		rock.material_override = rock_material

		rock.position = Vector3(
			local_position.x,
			ground_height + height * 0.5,
			local_position.y
		)

		rock.rotation = Vector3(
			rng.randf_range(-0.09, 0.09),
			rng.randf_range(0.0, TAU),
			rng.randf_range(-0.09, 0.09)
		)

		add_child(rock)
		rock.material_override = rock_material
