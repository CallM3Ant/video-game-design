#pragma once

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {

class TerrainGenerator : public RefCounted {
	GDCLASS(TerrainGenerator, RefCounted)

	int64_t world_seed = 12345;
	Ref<FastNoiseLite> continental_noise;
	Ref<FastNoiseLite> hill_noise;
	Ref<FastNoiseLite> mountain_mask_noise;
	Ref<FastNoiseLite> ridge_noise;
	Ref<FastNoiseLite> chasm_noise;
	Ref<FastNoiseLite> chasm_mask_noise;
	Ref<FastNoiseLite> valley_noise;
	Ref<FastNoiseLite> detail_noise;
	Ref<FastNoiseLite> warp_x_noise;
	Ref<FastNoiseLite> warp_z_noise;
	Ref<FastNoiseLite> color_noise;
	Ref<FastNoiseLite> jitter_noise;
	Ref<FastNoiseLite> mountain_style_noise;
	Ref<FastNoiseLite> rolling_noise;
	Ref<FastNoiseLite> large_hill_noise;

	static void _bind_methods();
	float smooth_range(float p_value, float p_start, float p_finish) const;
	Ref<FastNoiseLite> make_noise(
			int32_t p_offset,
			float p_frequency,
			int32_t p_octaves,
			float p_gain
	) const;

public:
	TerrainGenerator();

	void initialize(int64_t p_seed);
	float get_height(float p_world_x, float p_world_z) const;
	Vector2 get_vertex_jitter(
			float p_world_x,
			float p_world_z,
			float p_cell_size
	) const;
	Color get_triangle_color(
			float p_world_x,
			float p_world_z,
			float p_height,
			const Vector3 &p_normal
	) const;
	PackedVector3Array sample_vertex_grid(
			const Vector3i &p_origin,
			int32_t p_size,
			int32_t p_grid_cells,
			const PackedFloat32Array &p_heights
	) const;
	PackedByteArray compress_vertex_heights(const PackedVector3Array &p_vertices) const;
	Dictionary build_chunk_arrays(
			const Vector3i &p_origin,
			int32_t p_grid_cells,
			const PackedVector3Array &p_vertex_grid,
			const PackedColorArray &p_cached_colors
	) const;
	PackedVector3Array build_collision_faces(
			int32_t p_grid_cells,
			const PackedVector3Array &p_vertex_grid
	) const;
	Dictionary build_lod_topology(int32_t p_grid_cells) const;
};

} // namespace godot
