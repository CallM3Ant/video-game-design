
extends RefCounted

var world_seed: int

var continental_noise: FastNoiseLite
var hill_noise: FastNoiseLite
var mountain_mask_noise: FastNoiseLite
var ridge_noise: FastNoiseLite

var chasm_noise: FastNoiseLite
var chasm_mask_noise: FastNoiseLite
var valley_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var warp_x_noise: FastNoiseLite
var warp_z_noise: FastNoiseLite
var color_noise: FastNoiseLite
var jitter_noise: FastNoiseLite
var mountain_style_noise: FastNoiseLite

var rolling_noise: FastNoiseLite
var large_hill_noise: FastNoiseLite

const LOWLAND_COLOR := Color(0.30, 0.245, 0.24)
const MIDLAND_COLOR := Color(0.235, 0.225, 0.25)
const HIGHLAND_COLOR := Color(0.102, 0.121, 0.139, 1.0)
const DARK_ROCK_COLOR := Color(0.105, 0.11, 0.14)
const LIGHT_ROCK_COLOR := Color(0.34, 0.29, 0.28)



func _init(p_seed: int = 12345) -> void:
	world_seed = p_seed
	continental_noise = make_noise(0, 0.0008, 3, 0.50)

	chasm_noise = make_noise(1500, 0.0020, 2, 0.50)
	chasm_mask_noise = make_noise(1600, 0.0001, 2, 0.50)
	hill_noise = make_noise(100, 0.0035, 4, 0.50)
	mountain_mask_noise = make_noise(200, 0.0012, 3, 0.50)
	ridge_noise = make_noise(300, 0.006, 5, 0.52)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	valley_noise = make_noise(400, 0.009, 3, 0.50)
	mountain_style_noise = make_noise(1200, 0.0010, 2, 0.50)
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
	if value <= start:
		return 0.0
	if value >= finish:
		return 1.0

	var t := (value - start) / (finish - start)
	return t * t * (3.0 - 2.0 * t)



func get_height(world_x: float, world_z: float) -> float:

	var warped_x: float = world_x + warp_x_noise.get_noise_2d(world_x, world_z) * 22.0
	var warped_z: float = world_z + warp_z_noise.get_noise_2d(world_x, world_z) * 22.0

	var continents: float = continental_noise.get_noise_2d(warped_x, warped_z)
	var hills: float = hill_noise.get_noise_2d(warped_x, warped_z)
	var rolling: float = rolling_noise.get_noise_2d(warped_x, warped_z)
	var large_hills: float = large_hill_noise.get_noise_2d(warped_x, warped_z)
	var detail: float = detail_noise.get_noise_2d(warped_x, warped_z)

	var base_height: float = (
		12.0
		+ continents * 15.0
		+ hills * 4.0
		+ rolling * 4.0
		+ large_hills * 8.0
		+ detail * 1.5
	)

	var region_val: float = mountain_mask_noise.get_noise_2d(warped_x, warped_z)
	var region_mask: float = smooth_range(region_val, -0.15, 0.35)

	var flatness_factor: float = 1.0 - smooth_range(region_mask, 0.0, 0.2)

	if flatness_factor > 0.0:
		var chasm_mask_val: float = chasm_mask_noise.get_noise_2d(warped_x, warped_z)
	
		if chasm_mask_val > 0.01:
			var chasm_val: float = absf(chasm_noise.get_noise_2d(warped_x, warped_z))
		
			if chasm_val < 0.06:
				var t_ch: float = chasm_val / 0.06
			
				var chasm_depth: float = (1.0 - t_ch) * 85.0
				base_height -= chasm_depth * flatness_factor

	if region_mask <= 0.001:
		return base_height

	var style_val: float = mountain_style_noise.get_noise_2d(warped_x, warped_z)
	
	var w_mesa: float = smooth_range(-style_val, 0.1, 0.5)
	var w_spire: float = smooth_range(style_val, 0.1, 0.5)
	var w_regular: float = clampf(1.0 - w_mesa - w_spire, 0.0, 1.0)

	var ridges: float = ridge_noise.get_noise_2d(warped_x, warped_z)
	ridges = clampf((ridges + 1.0) * 0.5, 0.0, 1.0)

	var h_regular: float = pow(ridges, 1.8) * 55.0
	var h_mesa: float = floor(ridges * sqrt(ridges) * 6.0) / 6.0 * 60.0
	var h_spire: float = ridges * ridges * ridges * 85.0

	var mountain_height: float = (h_regular * w_regular) + (h_mesa * w_mesa) + (h_spire * w_spire)

	var cliff_blend: float = w_mesa + w_spire
	if cliff_blend > 0.1 and region_mask > 0.4:
		var stepped_mtn: float = floor(mountain_height / 8.0) * 8.0
		mountain_height = lerp(mountain_height, stepped_mtn, (region_mask - 0.4) * 1.66 * cliff_blend)

	var valley_field: float = 1.0 - absf(valley_noise.get_noise_2d(warped_x, warped_z))
	var valley_strength: float = smooth_range(valley_field, 0.82, 0.98)
	var valley_carve: float = valley_strength * region_mask * 20.0

	return base_height + (mountain_height * region_mask) - valley_carve


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
	var variation := color_noise.get_noise_2d(world_x, world_z)

	var mid_transition := smooth_range(height, 18.0, 43.0)
	var high_transition := smooth_range(height, 43.0, 72.0)

	var result := LOWLAND_COLOR.lerp(MIDLAND_COLOR, mid_transition)
	result = result.lerp(HIGHLAND_COLOR, high_transition * 0.85)

	var mottling := smooth_range(variation, -0.6, 0.6)
	var mineral_color := DARK_ROCK_COLOR.lerp(LIGHT_ROCK_COLOR, mottling)
	result = result.lerp(mineral_color, 0.18)

	var slope := smooth_range(1.0 - normal.y, 0.12, 0.65)
	result = result.lerp(DARK_ROCK_COLOR, slope * 0.38)

	return result
