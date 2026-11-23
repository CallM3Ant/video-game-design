#include "terrain_generator.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

namespace godot {

namespace {

float clamp_value(float p_value, float p_minimum, float p_maximum) {
	if (p_value < p_minimum) {
		return p_minimum;
	}
	if (p_value > p_maximum) {
		return p_maximum;
	}
	return p_value;
}

int32_t grid_vertex_index(int32_t p_x, int32_t p_z, int32_t p_cells) {
	if (p_x < p_cells && p_z < p_cells) {
		return (p_z * p_cells + p_x) * 6;
	}
	if (p_z < p_cells) {
		return (p_z * p_cells + p_cells - 1) * 6 + 1;
	}
	if (p_x < p_cells) {
		const int32_t cell_z = p_cells - 1;
		const int32_t base = (cell_z * p_cells + p_x) * 6;
		return base + ((p_x + cell_z) % 2 == 0 ? 5 : 2);
	}
	return (p_cells * p_cells - 1) * 6 + 2;
}

PackedInt32Array make_lod_indices(int32_t p_cells, int32_t p_step) {
	std::vector<int32_t> anchors;
	for (int32_t coord = 1; coord < p_cells - 1; coord += p_step) {
		anchors.push_back(coord);
	}
	anchors.push_back(p_cells - 1);

	std::vector<int32_t> indices;
	indices.reserve(p_cells * p_cells * 6);
	const auto triangle = [&](int32_t ax, int32_t az, int32_t bx, int32_t bz,
								  int32_t cx, int32_t cz) {
		const int32_t winding = (bx - ax) * (cz - az) - (bz - az) * (cx - ax);
		if (winding < 0) {
			std::swap(bx, cx);
			std::swap(bz, cz);
		}
		indices.push_back(grid_vertex_index(ax, az, p_cells));
		indices.push_back(grid_vertex_index(bx, bz, p_cells));
		indices.push_back(grid_vertex_index(cx, cz, p_cells));
	};

	for (size_t z = 0; z + 1 < anchors.size(); ++z) {
		for (size_t x = 0; x + 1 < anchors.size(); ++x) {
			const int32_t x0 = anchors[x];
			const int32_t x1 = anchors[x + 1];
			const int32_t z0 = anchors[z];
			const int32_t z1 = anchors[z + 1];
			triangle(x0, z0, x1, z0, x1, z1);
			triangle(x0, z0, x1, z1, x0, z1);
		}
	}

	// Keep every original edge sample, so neighboring chunks at different LODs meet.
	for (size_t i = 0; i + 1 < anchors.size(); ++i) {
		const int32_t a = anchors[i];
		const int32_t b = anchors[i + 1];
		for (int32_t c = a; c < b; ++c) {
			triangle(a, 1, c, 0, c + 1, 0);
			triangle(a, p_cells - 1, c, p_cells, c + 1, p_cells);
			triangle(1, a, 0, c, 0, c + 1);
			triangle(p_cells - 1, a, p_cells, c, p_cells, c + 1);
		}
		triangle(a, 1, b, 0, b, 1);
		triangle(a, p_cells - 1, b, p_cells, b, p_cells - 1);
		triangle(1, a, 0, b, 1, b);
		triangle(p_cells - 1, a, p_cells, b, p_cells - 1, b);
	}

	for (int32_t z : { 0, p_cells - 1 }) {
		for (int32_t x : { 0, p_cells - 1 }) {
			if ((x + z) % 2 == 0) {
				triangle(x, z, x + 1, z, x + 1, z + 1);
				triangle(x, z, x + 1, z + 1, x, z + 1);
			} else {
				triangle(x, z, x + 1, z, x, z + 1);
				triangle(x + 1, z, x + 1, z + 1, x, z + 1);
			}
		}
	}

	PackedInt32Array result;
	ERR_FAIL_COND_V_MSG(result.resize(indices.size()) != 0,
			PackedInt32Array(), "Could not allocate terrain LOD indices.");
	std::copy(indices.begin(), indices.end(), result.ptrw());
	return result;
}

} // namespace

void TerrainGenerator::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("initialize", "seed"),
			&TerrainGenerator::initialize
	);
	ClassDB::bind_method(
			D_METHOD("get_height", "world_x", "world_z"),
			&TerrainGenerator::get_height
	);
	ClassDB::bind_method(
			D_METHOD("get_vertex_jitter", "world_x", "world_z", "cell_size"),
			&TerrainGenerator::get_vertex_jitter
	);
	ClassDB::bind_method(
			D_METHOD("get_triangle_color", "world_x", "world_z", "height", "normal"),
			&TerrainGenerator::get_triangle_color
	);
	ClassDB::bind_method(
			D_METHOD("sample_vertex_grid", "origin", "size", "grid_cells", "heights"),
			&TerrainGenerator::sample_vertex_grid
	);
	ClassDB::bind_method(
			D_METHOD("compress_vertex_heights", "vertices"),
			&TerrainGenerator::compress_vertex_heights
	);
	ClassDB::bind_method(
			D_METHOD("build_chunk_arrays", "origin", "grid_cells", "vertex_grid", "cached_colors"),
			&TerrainGenerator::build_chunk_arrays
	);
	ClassDB::bind_method(
			D_METHOD("build_collision_faces", "grid_cells", "vertex_grid"),
			&TerrainGenerator::build_collision_faces
	);
	ClassDB::bind_method(
			D_METHOD("build_lod_topology", "grid_cells"),
			&TerrainGenerator::build_lod_topology
	);
}

TerrainGenerator::TerrainGenerator() {
	initialize(world_seed);
}

Ref<FastNoiseLite> TerrainGenerator::make_noise(
		int32_t p_offset,
		float p_frequency,
		int32_t p_octaves,
		float p_gain
) const {
	Ref<FastNoiseLite> noise;
	noise.instantiate();
	noise->set_seed(static_cast<int32_t>(world_seed + p_offset));
	noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	noise->set_frequency(p_frequency);
	noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
	noise->set_fractal_octaves(p_octaves);
	noise->set_fractal_gain(p_gain);
	noise->set_fractal_lacunarity(2.0f);
	return noise;
}

void TerrainGenerator::initialize(int64_t p_seed) {
	if (p_seed == world_seed && continental_noise.is_valid()) {
		return;
	}
	world_seed = p_seed;
	continental_noise = make_noise(0, 0.0008f, 3, 0.50f);
	chasm_noise = make_noise(1500, 0.0020f, 2, 0.50f);
	chasm_mask_noise = make_noise(1600, 0.0001f, 2, 0.50f);
	hill_noise = make_noise(100, 0.0035f, 4, 0.50f);
	mountain_mask_noise = make_noise(200, 0.0012f, 3, 0.50f);
	ridge_noise = make_noise(300, 0.006f, 5, 0.52f);
	ridge_noise->set_fractal_type(FastNoiseLite::FRACTAL_RIDGED);
	valley_noise = make_noise(400, 0.009f, 3, 0.50f);
	mountain_style_noise = make_noise(1200, 0.0010f, 2, 0.50f);
	detail_noise = make_noise(500, 0.025f, 3, 0.45f);
	warp_x_noise = make_noise(600, 0.0015f, 3, 0.50f);
	warp_z_noise = make_noise(700, 0.0015f, 3, 0.50f);
	color_noise = make_noise(800, 0.018f, 2, 0.40f);
	jitter_noise = make_noise(900, 0.035f, 2, 0.40f);
	rolling_noise = make_noise(1000, 0.006f, 4, 0.50f);
	large_hill_noise = make_noise(1100, 0.0025f, 3, 0.50f);
}

float TerrainGenerator::smooth_range(
		float p_value,
		float p_start,
		float p_finish
) const {
	if (p_value <= p_start) {
		return 0.0f;
	}
	if (p_value >= p_finish) {
		return 1.0f;
	}

	const float t = (p_value - p_start) / (p_finish - p_start);
	return t * t * (3.0f - 2.0f * t);
}

float TerrainGenerator::get_height(float p_world_x, float p_world_z) const {
	const float warped_x = p_world_x +
			warp_x_noise->get_noise_2d(p_world_x, p_world_z) * 22.0f;
	const float warped_z = p_world_z +
			warp_z_noise->get_noise_2d(p_world_x, p_world_z) * 22.0f;

	const float continents = continental_noise->get_noise_2d(warped_x, warped_z);
	const float hills = hill_noise->get_noise_2d(warped_x, warped_z);
	const float rolling = rolling_noise->get_noise_2d(warped_x, warped_z);
	const float large_hills = large_hill_noise->get_noise_2d(warped_x, warped_z);
	const float detail = detail_noise->get_noise_2d(warped_x, warped_z);

	float base_height = 12.0f + continents * 15.0f + hills * 4.0f +
			rolling * 4.0f + large_hills * 8.0f + detail * 1.5f;

	const float region_val = mountain_mask_noise->get_noise_2d(warped_x, warped_z);
	const float region_mask = smooth_range(region_val, -0.15f, 0.35f);
	const float flatness_factor = 1.0f - smooth_range(region_mask, 0.0f, 0.2f);

	if (flatness_factor > 0.0f) {
		const float chasm_mask_val = chasm_mask_noise->get_noise_2d(warped_x, warped_z);
		if (chasm_mask_val > 0.01f) {
			const float chasm_val = std::abs(
					chasm_noise->get_noise_2d(warped_x, warped_z)
			);
			if (chasm_val < 0.06f) {
				const float t_ch = chasm_val / 0.06f;
				const float chasm_depth = (1.0f - t_ch) * 85.0f;
				base_height -= chasm_depth * flatness_factor;
			}
		}
	}

	if (region_mask <= 0.001f) {
		return base_height;
	}

	const float style_val = mountain_style_noise->get_noise_2d(warped_x, warped_z);
	const float w_mesa = smooth_range(-style_val, 0.1f, 0.5f);
	const float w_spire = smooth_range(style_val, 0.1f, 0.5f);
	const float w_regular = clamp_value(1.0f - w_mesa - w_spire, 0.0f, 1.0f);

	float ridges = ridge_noise->get_noise_2d(warped_x, warped_z);
	ridges = clamp_value((ridges + 1.0f) * 0.5f, 0.0f, 1.0f);

	const float h_regular = std::pow(ridges, 1.8f) * 55.0f;
	const float h_mesa = std::floor(ridges * std::sqrt(ridges) * 6.0f) /
			6.0f * 60.0f;
	const float h_spire = ridges * ridges * ridges * 85.0f;
	float mountain_height = h_regular * w_regular + h_mesa * w_mesa + h_spire * w_spire;

	const float cliff_blend = w_mesa + w_spire;
	if (cliff_blend > 0.1f && region_mask > 0.4f) {
		const float stepped_mountain = std::floor(mountain_height / 8.0f) * 8.0f;
		const float blend = (region_mask - 0.4f) * 1.66f * cliff_blend;
		mountain_height += (stepped_mountain - mountain_height) * blend;
	}

	const float valley_field = 1.0f -
			std::abs(valley_noise->get_noise_2d(warped_x, warped_z));
	const float valley_strength = smooth_range(valley_field, 0.82f, 0.98f);
	const float valley_carve = valley_strength * region_mask * 20.0f;
	return base_height + mountain_height * region_mask - valley_carve;
}

Vector2 TerrainGenerator::get_vertex_jitter(
		float p_world_x,
		float p_world_z,
		float p_cell_size
) const {
	const float x = jitter_noise->get_noise_2d(p_world_x, p_world_z);
	const float z = jitter_noise->get_noise_2d(
			p_world_x + 419.0f,
			p_world_z - 673.0f
	);
	return Vector2(
			x * p_cell_size * 0.10f,
			z * p_cell_size * 0.10f
	);
}

Color TerrainGenerator::get_triangle_color(
		float p_world_x,
		float p_world_z,
		float p_height,
		const Vector3 &p_normal
) const {
	const Color lowland_color(0.30f, 0.245f, 0.24f);
	const Color midland_color(0.235f, 0.225f, 0.25f);
	const Color highland_color(0.102f, 0.121f, 0.139f, 1.0f);
	const Color dark_rock_color(0.105f, 0.11f, 0.14f);
	const Color light_rock_color(0.34f, 0.29f, 0.28f);

	const float variation = color_noise->get_noise_2d(p_world_x, p_world_z);
	const float mid_transition = smooth_range(p_height, 18.0f, 43.0f);
	const float high_transition = smooth_range(p_height, 43.0f, 72.0f);

	Color result = lowland_color.lerp(midland_color, mid_transition);
	result = result.lerp(highland_color, high_transition * 0.85f);

	const float mottling = smooth_range(variation, -0.6f, 0.6f);
	const Color mineral_color = dark_rock_color.lerp(light_rock_color, mottling);
	result = result.lerp(mineral_color, 0.18f);

	const float slope = smooth_range(1.0f - p_normal.y, 0.12f, 0.65f);
	return result.lerp(dark_rock_color, slope * 0.38f);
}

PackedVector3Array TerrainGenerator::sample_vertex_grid(
		const Vector3i &p_origin,
		int32_t p_size,
		int32_t p_grid_cells,
		const PackedFloat32Array &p_heights
) const {
	ERR_FAIL_COND_V_MSG(p_size <= 0 || p_grid_cells <= 0 || p_grid_cells > 100,
			PackedVector3Array(), "Invalid terrain chunk dimensions.");
	const int32_t sample_size = p_grid_cells + 1;
	const int32_t sample_count = sample_size * sample_size;
	ERR_FAIL_COND_V_MSG(!p_heights.is_empty() && p_heights.size() != sample_count,
			PackedVector3Array(), "Terrain height count does not match the grid.");

	PackedVector3Array vertices;
	ERR_FAIL_COND_V_MSG(vertices.resize(sample_count) != 0,
			PackedVector3Array(), "Could not allocate terrain vertex grid.");
	Vector3 *vertex_data = vertices.ptrw();
	const float *height_data = p_heights.is_empty() ? nullptr : p_heights.ptr();
	const double cell_size = static_cast<double>(p_size) / p_grid_cells;

	for (int32_t z = 0; z < sample_size; ++z) {
		for (int32_t x = 0; x < sample_size; ++x) {
			const double base_x = x * cell_size;
			const double base_z = z * cell_size;
			const double world_x = static_cast<double>(p_origin.x) + base_x;
			const double world_z = static_cast<double>(p_origin.z) + base_z;
			const Vector2 jitter = get_vertex_jitter(
					static_cast<float>(world_x),
					static_cast<float>(world_z),
					static_cast<float>(cell_size)
			);
			const int32_t index = x + z * sample_size;
			const float height = height_data == nullptr ?
					get_height(static_cast<float>(world_x + jitter.x),
							static_cast<float>(world_z + jitter.y)) :
					height_data[index];
			vertex_data[index] = Vector3(
					static_cast<real_t>(base_x + jitter.x),
					height,
					static_cast<real_t>(base_z + jitter.y)
			);
		}
	}

	return vertices;
}

PackedByteArray TerrainGenerator::compress_vertex_heights(
		const PackedVector3Array &p_vertices
) const {
	ERR_FAIL_COND_V_MSG(p_vertices.is_empty(),
			PackedByteArray(), "Cannot compress an empty terrain vertex grid.");
	PackedFloat32Array heights;
	ERR_FAIL_COND_V_MSG(heights.resize(p_vertices.size()) != 0,
			PackedByteArray(), "Could not allocate terrain heights.");
	const Vector3 *vertices = p_vertices.ptr();
	float *height_data = heights.ptrw();
	for (int64_t index = 0; index < p_vertices.size(); ++index) {
		height_data[index] = vertices[index].y;
	}
	return heights.to_byte_array().compress(FileAccess::COMPRESSION_ZSTD);
}

Dictionary TerrainGenerator::build_chunk_arrays(
		const Vector3i &p_origin,
		int32_t p_grid_cells,
		const PackedVector3Array &p_vertex_grid,
		const PackedColorArray &p_cached_colors
) const {
	ERR_FAIL_COND_V_MSG(p_grid_cells <= 0 || p_grid_cells > 100,
			Dictionary(), "Invalid terrain grid size.");
	const int32_t sample_size = p_grid_cells + 1;
	ERR_FAIL_COND_V_MSG(p_vertex_grid.size() != sample_size * sample_size,
			Dictionary(), "Terrain vertex count does not match the grid.");
	const int32_t vertex_count = p_grid_cells * p_grid_cells * 6;
	const int32_t triangle_count = vertex_count / 3;
	ERR_FAIL_COND_V_MSG(!p_cached_colors.is_empty() && p_cached_colors.size() != triangle_count,
			Dictionary(), "Terrain cached color count does not match the grid.");

	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedColorArray colors;
	PackedColorArray face_colors = p_cached_colors;
	ERR_FAIL_COND_V_MSG(vertices.resize(vertex_count) != 0 ||
					normals.resize(vertex_count) != 0 ||
					colors.resize(vertex_count) != 0 ||
					(p_cached_colors.is_empty() && face_colors.resize(triangle_count) != 0),
			Dictionary(), "Could not allocate terrain mesh arrays.");
	Vector3 *vertex_data = vertices.ptrw();
	Vector3 *normal_data = normals.ptrw();
	Color *color_data = colors.ptrw();
	const Color *cached_colors = p_cached_colors.is_empty() ? nullptr : p_cached_colors.ptr();
	Color *new_face_colors = cached_colors == nullptr ? face_colors.ptrw() : nullptr;
	const Vector3 *grid = p_vertex_grid.ptr();
	int32_t vertex_index = 0;

	const auto write_triangle = [&](const Vector3 &a, const Vector3 &b, const Vector3 &c) {
		Vector3 normal = (c - a).cross(b - a).normalized();
		if (normal.y < 0.0f) {
			normal = -normal;
		}
		const int32_t face_index = vertex_index / 3;
		Color color;
		if (cached_colors == nullptr) {
			const Vector3 center = (a + b + c) / 3.0f;
			color = get_triangle_color(
					static_cast<float>(static_cast<double>(p_origin.x) + center.x),
					static_cast<float>(static_cast<double>(p_origin.z) + center.z),
					center.y,
					normal
			);
			new_face_colors[face_index] = color;
		} else {
			color = cached_colors[face_index];
		}
		vertex_data[vertex_index] = a;
		vertex_data[vertex_index + 1] = b;
		vertex_data[vertex_index + 2] = c;
		for (int32_t i = 0; i < 3; ++i) {
			normal_data[vertex_index + i] = normal;
			color_data[vertex_index + i] = color;
		}
		vertex_index += 3;
	};

	for (int32_t z = 0; z < p_grid_cells; ++z) {
		for (int32_t x = 0; x < p_grid_cells; ++x) {
			const Vector3 &p00 = grid[x + z * sample_size];
			const Vector3 &p10 = grid[x + 1 + z * sample_size];
			const Vector3 &p01 = grid[x + (z + 1) * sample_size];
			const Vector3 &p11 = grid[x + 1 + (z + 1) * sample_size];
			if ((x + z) % 2 == 0) {
				write_triangle(p00, p10, p11);
				write_triangle(p00, p11, p01);
			} else {
				write_triangle(p00, p10, p01);
				write_triangle(p10, p11, p01);
			}
		}
	}

	Dictionary result;
	result["vertices"] = vertices;
	result["normals"] = normals;
	result["colors"] = colors;
	Dictionary mesh_cache;
	mesh_cache["grid"] = p_vertex_grid;
	mesh_cache["face_colors"] = face_colors;
	result["mesh_cache"] = mesh_cache;
	return result;
}

PackedVector3Array TerrainGenerator::build_collision_faces(
		int32_t p_grid_cells,
		const PackedVector3Array &p_vertex_grid
) const {
	ERR_FAIL_COND_V_MSG(p_grid_cells <= 0 || p_grid_cells > 100,
			PackedVector3Array(), "Invalid terrain collision grid size.");
	const int32_t sample_size = p_grid_cells + 1;
	ERR_FAIL_COND_V_MSG(p_vertex_grid.size() != sample_size * sample_size,
			PackedVector3Array(), "Terrain collision vertex count does not match the grid.");
	PackedVector3Array faces;
	ERR_FAIL_COND_V_MSG(faces.resize(p_grid_cells * p_grid_cells * 6) != 0,
			PackedVector3Array(), "Could not allocate terrain collision faces.");
	Vector3 *face_data = faces.ptrw();
	const Vector3 *grid = p_vertex_grid.ptr();
	int32_t index = 0;
	for (int32_t z = 0; z < p_grid_cells; ++z) {
		for (int32_t x = 0; x < p_grid_cells; ++x) {
			const Vector3 &p00 = grid[x + z * sample_size];
			const Vector3 &p10 = grid[x + 1 + z * sample_size];
			const Vector3 &p01 = grid[x + (z + 1) * sample_size];
			const Vector3 &p11 = grid[x + 1 + (z + 1) * sample_size];
			if ((x + z) % 2 == 0) {
				face_data[index] = p00;
				face_data[index + 1] = p10;
				face_data[index + 2] = p11;
				face_data[index + 3] = p00;
				face_data[index + 4] = p11;
				face_data[index + 5] = p01;
			} else {
				face_data[index] = p00;
				face_data[index + 1] = p10;
				face_data[index + 2] = p01;
				face_data[index + 3] = p10;
				face_data[index + 4] = p11;
				face_data[index + 5] = p01;
			}
			index += 6;
		}
	}
	return faces;
}

Dictionary TerrainGenerator::build_lod_topology(int32_t p_grid_cells) const {
	ERR_FAIL_COND_V_MSG(p_grid_cells < 14 || p_grid_cells > 100,
			Dictionary(), "Invalid terrain LOD grid size.");
	const int32_t count = p_grid_cells * p_grid_cells * 6;
	PackedInt32Array full_indices;
	ERR_FAIL_COND_V_MSG(full_indices.resize(count) != 0,
			Dictionary(), "Could not allocate terrain base indices.");
	int32_t *full_data = full_indices.ptrw();
	for (int32_t i = 0; i < count; ++i) {
		full_data[i] = i;
	}
	const PackedInt32Array medium_indices = make_lod_indices(p_grid_cells, 2);
	const PackedInt32Array far_indices = make_lod_indices(p_grid_cells, 4);
	ERR_FAIL_COND_V_MSG(medium_indices.is_empty() || far_indices.is_empty(),
			Dictionary(), "Could not build terrain LOD indices.");

	Dictionary lods;
	lods[0.35] = medium_indices;
	lods[1.0] = far_indices;
	Dictionary result;
	result["base"] = full_indices;
	result["lods"] = lods;
	return result;
}

} // namespace godot
