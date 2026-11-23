shader_type sky;

uniform sampler2D baked_sky   : source_color, filter_linear_mipmap, repeat_enable;
// Change this line:
uniform sampler2D baked_stars : filter_linear_mipmap, repeat_enable;

uniform float sky_energy      = 1.0;
uniform float star_brightness = 1.0;
uniform float star_twinkle    = 0.15;

const vec2 INV_TWO_PI_PI = vec2(0.15915494, 0.31830989);

void sky() {
    vec3 dir = EYEDIR;
    
    // 1. Calculate UVs
    float latitude = asin(clamp(dir.y, -1.0, 1.0));
    float longitude = atan(dir.x, dir.z);
    vec2 tex_uv = vec2(longitude, latitude) * INV_TWO_PI_PI + 0.5;
    
    // 2. Seam Fix for both textures
    vec2 dx = dFdx(tex_uv);
    vec2 dy = dFdy(tex_uv);
    if (abs(dx.x) > 0.5) dx.x = 0.0;
    if (abs(dy.x) > 0.5) dy.x = 0.0;
    
    // 3. Sample the Baked Sky
    vec3 color = textureGrad(baked_sky, tex_uv, dx, dy).rgb;
    
    // 4. Sample and Twinkle the Stars
    if (star_brightness > 0.0) {
        vec4 star_data = textureGrad(baked_stars, tex_uv, dx, dy);
        
        float phase = star_data.r * 6.28318;
        float speed = mix(0.6, 1.4, star_data.g);
        float core  = star_data.b;
        
        // Only calculate sine if there is actually a star here
        if (core > 0.0) {
            float tw = 1.0 + star_twinkle * 0.5 * (sin(TIME * speed + phase) - 1.0);
            color += vec3(0.8, 0.9, 1.0) * (core * tw * star_brightness);
        }
    }
    
    COLOR = color * sky_energy;
}