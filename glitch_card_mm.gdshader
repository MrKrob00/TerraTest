shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;

// THE GLITCH CARD OF glitch_card.gdshader, ONE MULTIMESH INSTANCE EACH (card_burst.gd). What was a
// uniform per card's own material now rides in the instance: INSTANCE_CUSTOM.x the seed, .y the grid
// (4 or 6 cells), .z the fill threshold, .w the progress (0 -> 1 over the cloud's life). The palette
// is the MultiMesh's: one material per palette, so one draw call for every cloud of it. The card is
// a billboard sized by its instance transform, as the single card is by its node's scale. Keep the
// look in step with glitch_card.gdshader: the two draw the same card.

uniform float flicker_speed = 12.0;
uniform float gain : hint_range(1.0, 3.0) = 1.5;
uniform bool use_tint = false;
uniform vec3 glitch_a : source_color = vec3(0.15, 0.85, 1.0);
uniform vec3 glitch_b : source_color = vec3(0.85, 0.15, 0.95);

varying float v_seed;
varying float v_grid;
varying float v_fill;
varying float v_prog;

float h1(float n, float seed) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }

float h2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = h2(i);
	float b = h2(i + vec2(1.0, 0.0));
	float c = h2(i + vec2(0.0, 1.0));
	float d = h2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 palette(float t) {
	vec3 c0 = vec3(0.15, 0.85, 1.0);
	vec3 c1 = vec3(0.25, 0.45, 1.0);
	vec3 c2 = vec3(0.60, 0.20, 1.0);
	vec3 c3 = vec3(0.85, 0.15, 0.95);
	t = clamp(t, 0.0, 1.0) * 3.0;
	if (t < 1.0) return mix(c0, c1, t);
	if (t < 2.0) return mix(c1, c2, t - 1.0);
	return mix(c2, c3, t - 2.0);
}

void vertex() {
	v_seed = INSTANCE_CUSTOM.x;
	v_grid = INSTANCE_CUSTOM.y;
	v_fill = INSTANCE_CUSTOM.z;
	v_prog = INSTANCE_CUSTOM.w;
	mat4 m = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(m[0].xyz),
			INV_VIEW_MATRIX[1] * length(m[1].xyz),
			INV_VIEW_MATRIX[2] * length(m[2].xyz),
			m[3]);
}

void fragment() {
	vec2 g = UV * v_grid;
	vec2 cell = floor(g);
	float fill = vnoise(cell * 0.5 + vec2(v_seed * 0.13, v_seed * 0.29));
	if (fill < v_fill) {
		discard;
	}
	float cn = vnoise(cell * 0.35 + vec2(v_seed * 0.71 + 10.0, v_seed * 0.53 + 20.0));
	vec3 col = use_tint ? mix(glitch_a, glitch_b, cn) : palette(cn);
	float A = (v_prog < 0.5) ? mix(0.6, 1.0, v_prog / 0.5) : mix(1.0, 0.0, (v_prog - 0.5) / 0.5);
	float ct = fract(v_seed * 0.371 + 0.13);
	float vis = clamp((A - ct) / 0.12, 0.0, 1.0);
	float flick = 0.6 + 0.4 * h1(floor(TIME * flicker_speed), v_seed);
	float a = vis * flick;
	if (a < 0.04) {
		discard;
	}
	ALBEDO = col * gain;
	ALPHA = a;
}
