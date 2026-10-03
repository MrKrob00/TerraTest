shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

// A VEIN'S HIT DIGIT (vein_digits.gd): the repair digit's card (regen_digit.gdshader), BLENDED, NOT
// ADDED - added red over a green meadow came out orange, and these have to read red on any ground.
// INSTANCE_CUSTOM.x is its opacity, .y its seed.

uniform vec3  tint : source_color = vec3(1.0, 0.18, 0.12);
uniform float flip_rate = 7.0;

varying float v_alpha;
varying float v_seed;

float h1(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

float glyph(vec2 uv, float bit) {
	vec2 d = abs(uv - 0.5);
	if (bit > 0.5) {
		return step(d.x, 0.11) * step(d.y, 0.34);
	}
	float outer = step(d.x, 0.25) * step(d.y, 0.34);
	float inner = step(d.x, 0.13) * step(d.y, 0.20);
	return clamp(outer - inner, 0.0, 1.0);
}

void vertex() {
	v_alpha = INSTANCE_CUSTOM.x;
	v_seed = INSTANCE_CUSTOM.y * 97.0;
	float s = length(MODEL_MATRIX[0].xyz);
	mat4 m = mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * m;
}

void fragment() {
	float bit = step(0.5, h1(v_seed + floor(TIME * flip_rate) * 1.37));
	ALBEDO = tint;
	ALPHA = clamp(glyph(UV, bit) * v_alpha, 0.0, 1.0);
}
