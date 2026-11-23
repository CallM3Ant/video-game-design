shader_type spatial;

uniform float shadow_threshold : hint_range(0.0, 1.0) = 0.1;
uniform float highlight_threshold : hint_range(0.0, 1.0) = 0.45;
uniform float shadow_band : hint_range(0.0, 1.0) = 0.4;
uniform float mid_band : hint_range(0.0, 1.0) = 0.8;
uniform float ambient_fill : hint_range(0.0, 1.0) = 0.11;
uniform vec3 ambient_tint = vec3(0.9, 1.25, 1.65);
uniform float specular_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float specular_strength : hint_range(0.0, 1.0) = 0.0;
uniform float specular_exponent : hint_range(1.0, 128.0) = 48.0;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = specular_strength;
	EMISSION = ALBEDO * ambient_fill * ambient_tint;
}

void light() {
	float lambert = max(dot(NORMAL, LIGHT), 0.0);
	float light_amount = lambert * ATTENUATION;
	float band = shadow_band;
	if (light_amount >= highlight_threshold) {
		band = 1.0;
	} else if (light_amount >= shadow_threshold) {
		band = mid_band;
	}

	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * (band / PI);

	vec3 half_sum = LIGHT + VIEW;
	float half_sum_length_squared = dot(half_sum, half_sum);
	float specular_shape = 0.0;
	if (half_sum_length_squared > 0.000001) {
		vec3 half_vector = half_sum * inversesqrt(half_sum_length_squared);
		specular_shape = pow(
			max(dot(NORMAL, half_vector), 0.0),
			specular_exponent
		);
	}
	float specular_band = step(specular_threshold, specular_shape);
	SPECULAR_LIGHT += LIGHT_COLOR * (specular_strength * SPECULAR_AMOUNT
			* specular_band * ATTENUATION / PI);
}
