shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add, shadows_disabled;

// A REPAIR DIGIT: one 0/1 card of the regen's pool (regen.gd `_digits`), flipping as it flies. The
// block moves it on the CPU (instance transform: position and size); the card faces the camera.
// INSTANCE_CUSTOM.x is its brightness, .y its seed. The same 0 and 1 the damage on the blocks
// is written in (block_hp.gdshader), so what flies in is what heals.

uniform vec3  tint : source_color = vec3(0.2, 1.0, 0.35);
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
