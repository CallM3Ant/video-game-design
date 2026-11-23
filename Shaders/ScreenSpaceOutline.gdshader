shader_type spatial;
render_mode unshaded, fog_disabled, depth_draw_never, depth_test_disabled, cull_disabled, blend_mix;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform float outline_width : hint_range(1.0, 8.0, 0.5) = 1.0;
uniform float edge_threshold : hint_range(0.01, 0.2, 0.01) = 0.04;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 0.85);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float view_depth(vec2 uv, mat4 inv_projection) {
	float depth = texture(depth_texture, uv).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	depth = depth * 2.0 - 1.0;
#endif
	vec4 view = inv_projection * vec4(0.0, 0.0, depth, 1.0);
	return -view.z / view.w;
}

void fragment() {
	vec2 texel = outline_width / vec2(textureSize(depth_texture, 0));
	float center = view_depth(SCREEN_UV, INV_PROJECTION_MATRIX);
	float farthest = max(view_depth(SCREEN_UV + texel, INV_PROJECTION_MATRIX),
		view_depth(SCREEN_UV - texel, INV_PROJECTION_MATRIX));
	float edge = max(farthest - center, 0.0) / max(center, 0.001);
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a * smoothstep(edge_threshold, edge_threshold * 1.5, edge);
}
