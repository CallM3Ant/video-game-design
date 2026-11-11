
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
var rolling_noise: FastNoiseLite
var large_hill_noise: FastNoiseLite



func _init(p_seed: int = 12345) -> void:
	world_seed = p_seed
	continental_noise = make_noise(0, 0.0008, 3, 0.50)
	hill_noise = make_noise(100, 0.0035, 4, 0.50)
	mountain_mask_noise = make_noise(200, 0.0012, 3, 0.50)
	ridge_noise = make_noise(300, 0.006, 5, 0.52)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	valley_noise = make_noise(400, 0.009, 3, 0.50)
	detail_noise = make_noise(500, 0.025, 3, 0.45)
	warp_x_noise = make_noise(600, 0.0015, 3, 0.50)
	warp_z_noise = make_noise(700, 0.0015, 3, 0.50)
	color_noise = make_noise(800, 0.018, 2, 0.40)
	jitter_noise = make_noise(900, 0.035, 2, 0.40)
	rolling_noise = make_noise(1000, 0.006, 4, 0.5)
	
	large_hill_noise = make_noise(1100, 0.0025, 3, 0.5)
	


func make_noise(offset: int, frequency: float, octaves: int,gain: float) -> FastNoiseLite:
	
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




func get_height(world_x: float, world_z: float) -> float:

	var warped_x := world_x + warp_x_noise.get_noise_2d(world_x, world_z) * 22.0
	var warped_z := world_z + warp_z_noise.get_noise_2d(world_x, world_z) * 22.0

	var continents := continental_noise.get_noise_2d(warped_x, warped_z)
	var hills := hill_noise.get_noise_2d(warped_x, warped_z)
	var rolling := rolling_noise.get_noise_2d(warped_x, warped_z)
	var large_hills := large_hill_noise.get_noise_2d(warped_x, warped_z)

	var mountain_region := smooth_range(
		mountain_mask_noise.get_noise_2d(warped_x, warped_z),
		-0.25,
		0.45
	)

	var mountain_height := 0.0
	var valley_carve := 0.0

	if mountain_region > 0.001:

		var ridges := ridge_noise.get_noise_2d(warped_x, warped_z)
		ridges = clampf((ridges + 1.0) * 0.5, 0.0, 1.0)
		ridges = pow(ridges, 1.8)

		var valley_field := 1.0 - absf(
			valley_noise.get_noise_2d(warped_x, warped_z)
		)

		var valley_strength := smooth_range(
			valley_field,
			0.82,
			0.98
		)

		mountain_height = ridges * 55.0 * mountain_region
		valley_carve = valley_strength * mountain_region * 12.0

	var detail := detail_noise.get_noise_2d(warped_x, warped_z)

	return (
		12.0
		+ continents * 22.0
		+ hills * 12.0
		+ rolling * 11.0
		+ large_hills * 20.0
		+ mountain_height
		- valley_carve
		+ detail * 2.0
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

	var dusty_ground := Color(0.19, 0.14, 0.14)
	var warm_sandstone := Color(0.34, 0.22, 0.15)
	var elevated_rock := Color(0.18, 0.13, 0.14)
	var cliff_rock := Color(0.09, 0.07, 0.10)
	var deep_rock := Color(0.035, 0.029, 0.045)
	var elevation := smooth_range(
		height,
		20.0,
		65.0
	)

	var slope := smooth_range(
		1.0 - normal.y,
		0.12,
		0.65
	)

	var result := dusty_ground

	result = result.lerp(
		elevated_rock,
		elevation * 0.65
	)

	var warm_variation := smooth_range(
		variation,
		-0.05,
		0.75
	)

	result = result.lerp(
		warm_sandstone,
		warm_variation * 0.16
	)

	result = result.lerp(
		cliff_rock,
		slope * 0.55
	)

	result = result.lerp(
		deep_rock,
		smooth_range(slope, 0.55, 0.95) * 0.30
	)

	var brightness := clampf(
		1.0 + variation * 0.035,
		0.97,
		1.03
	)

	return result * brightness
