shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// A PUFF OF THE INTRO'S SMOKE (planetfall.gd), one MultiMesh instance each: a camera-facing card cut
// into a grid of cells like the glitch cards (no particles anywhere, CLAUDE.md rule 11), a ragged
// blob whose cells drop away as it ages. INSTANCE_CUSTOM: x seed, y age 0..1, z heat at birth (an
// ember core while young), w opacity.

global uniform vec4 world_haze;
global uniform vec4 haze_range;

varying float v_seed;
varying float v_age;
varying float v_heat;
varying float v_op;
varying float v_haze;

float h2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h2(i), h2(i + vec2(1.0, 0.0)), f.x), mix(h2(i + vec2(0.0, 1.0)), h2(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	v_seed = INSTANCE_CUSTOM.x;
	v_age = INSTANCE_CUSTOM.y;
	v_heat = INSTANCE_CUSTOM.z;
	v_op = INSTANCE_CUSTOM.w;
	mat4 m = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(m[0].xyz),
			INV_VIEW_MATRIX[1] * length(m[1].xyz),
			INV_VIEW_MATRIX[2] * length(m[2].xyz),
			m[3]);
	v_haze = smoothstep(haze_range.x, haze_range.y, length(m[3].xyz - CAMERA_POSITION_WORLD)) * haze_range.z;
}

void fragment() {
	const float GRID = 9.0;
	vec2 cell = floor(UV * GRID);
	vec2 cc = (cell + 0.5) / GRID * 2.0 - 1.0;
	float r = length(cc);
	float n = vnoise(cell * 0.55 + vec2(v_seed * 0.37, v_seed * 0.91));
	float keep = 1.0 - r + (n - 0.5) * 0.7 - v_age * 0.35;
	if (keep < 0.12) {
		discard;
	}
	float tone = vnoise(cell * 0.8 + vec2(v_seed * 1.3 + 7.0, 3.0));
	vec3 col = mix(vec3(0.055, 0.05, 0.055), vec3(0.2, 0.19, 0.2), tone * 0.8 + v_age * 0.35);
	float ember = v_heat * (1.0 - v_age * 2.5) * smoothstep(0.55, 0.0, r);
	col = mix(col, vec3(1.0, 0.42, 0.08), clamp(ember, 0.0, 1.0));
	float fade = smoothstep(0.0, 0.06, v_age) * (1.0 - smoothstep(0.55, 1.0, v_age));
	ALBEDO = col;
	ALPHA = clamp(fade * v_op * (0.75 + 0.25 * tone), 0.0, 1.0);
	FOG = vec4(world_haze.rgb, v_haze);
}
