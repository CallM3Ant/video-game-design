
extends RefCounted

var world_seed: int

var continental_noise: FastNoiseLite
var hill_noise: FastNoiseLite
var mountain_mask_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var valley_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var warp_x_noise: FastNoiseLite
var warp_z_noise: FastNoiseLite
var color_noise: FastNoiseLite
var jitter_noise: FastNoiseLite


func _init(p_seed: int = 12345) -> void:
	world_seed = p_seed

	continental_noise = make_noise(0, 0.0018, 3, 0.48)
	hill_noise = make_noise(100, 0.006, 3, 0.48)

	mountain_mask_noise = make_noise(200, 0.0017, 2, 0.5)

	ridge_noise = make_noise(300, 0.009, 4, 0.52)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED

	valley_noise = make_noise(400, 0.0035, 2, 0.45)

	detail_noise = make_noise(500, 0.025, 2, 0.35)

	warp_x_noise = make_noise(600, 0.0025, 2, 0.5)
	warp_z_noise = make_noise(700, 0.0025, 2, 0.5)

	color_noise = make_noise(800, 0.018, 2, 0.4)
	jitter_noise = make_noise(900, 0.035, 2, 0.4)


func make_noise(
	offset: int,
	frequency: float,
	octaves: int,
	gain: float
) -> FastNoiseLite:

	var noise := FastNoiseLite.new()

	noise.seed = world_seed + offset
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = gain
	noise.fractal_lacunarity = 2.0

	return noise


func smooth_range(value: float, start: float, finish: float) -> float:
	var t := clampf(
		(value - start) / (finish - start),
		0.0,
		1.0
	)
	return t * t * (3.0 - 2.0 * t)


func get_warped_position(x: float, z: float) -> Vector2:

	var warp_x := warp_x_noise.get_noise_2d(x, z)
	var warp_z := warp_z_noise.get_noise_2d(x, z)

	return Vector2(
		x + warp_x * 22.0,
		z + warp_z * 22.0
	)


func get_height(world_x: float, world_z: float) -> float:

	var p := get_warped_position(world_x, world_z)

	var x := p.x
	var z := p.y


	var continents := continental_noise.get_noise_2d(x, z)


	var hills := hill_noise.get_noise_2d(x, z)


	var mountain_region := smooth_range(
		mountain_mask_noise.get_noise_2d(x, z),
		0.02,
		0.58
	)


	var ridges := ridge_noise.get_noise_2d(x, z)
	ridges = clampf(ridges, 0.0, 1.0)

	ridges = pow(ridges, 1.65)



	var valley_field := 1.0 - absf(
		valley_noise.get_noise_2d(x, z)
	)

	var valley_strength := smooth_range(
		valley_field,
		0.78,
		0.96
	)

	var valley_carve := (
		valley_strength
		* mountain_region
		* 4.5
	)


	var detail := detail_noise.get_noise_2d(x, z)


	var continental_height := continents * 5.5
	var hill_height := hills * 4.0

	var mountain_height := (
		ridges * 23.0 * mountain_region
	)

	var surface_height := detail * 0.55

	return (
		10.0
		+ continental_height
		+ hill_height
		+ mountain_height
		- valley_carve
		+ surface_height
	)


func get_vertex_jitter(
	world_x: float,
	world_z: float,
	cell_size: float
) -> Vector2:

	var x := jitter_noise.get_noise_2d(world_x, world_z)
	var z := jitter_noise.get_noise_2d(
		world_x + 419.0,
		world_z - 673.0
	)

	return Vector2(
		x * cell_size * 0.10,
		z * cell_size * 0.10
	)


func get_triangle_color(
	world_x: float,
	world_z: float,
	height: float,
	normal: Vector3
) -> Color:

	var variation := color_noise.get_noise_2d(
		world_x,
		world_z
	)

	var pale_sand := Color(0.69, 0.55, 0.43)
	var warm_sand := Color(0.59, 0.43, 0.33)
	var sandstone := Color(0.49, 0.36, 0.29)
	var dark_rock := Color(0.32, 0.27, 0.25)
	var highland := Color(0.56, 0.46, 0.39)

	var result: Color

	if normal.y < 0.72:
		result = dark_rock
	elif height > 26.0:
		result = highland
	elif height > 18.0:
		result = sandstone
	elif variation > 0.18:
		result = warm_sand
	else:
		result = pale_sand

	var brightness := clampf(
		0.98 + variation * 0.07,
		0.91,
		1.05
	)

	return result * brightness
