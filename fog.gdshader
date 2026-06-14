shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_always;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear;
uniform sampler2D gradient;

uniform float fog_strength : hint_range(0.0, 1.0) = 1.0;
uniform float fog_amount : hint_range(0.0, 1.0) = 0.15;
uniform float fog_near = 1.0;
uniform float fog_far = 150.0;

void vertex() {
    POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
    vec4 original = texture(SCREEN_TEXTURE, SCREEN_UV);
    float raw_depth = texture(DEPTH_TEXTURE, SCREEN_UV).x;

    vec4 clip = vec4(SCREEN_UV * 2.0 - 1.0, raw_depth, 1.0);
    vec4 view = INV_PROJECTION_MATRIX * clip;
    view /= view.w;
    float linear_depth = -view.z;

   
    float fog_factor = clamp((linear_depth - fog_near) / (fog_far - fog_near), 0.0, 1.0);
    fog_factor *= fog_amount;

   
    vec4 fog_color = texture(gradient, vec2(fog_factor, 0.0));

    
    vec3 final_color = mix(original.rgb, fog_color.rgb, fog_color.a * fog_strength);
    ALBEDO = final_color;
}
