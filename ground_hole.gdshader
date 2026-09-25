shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// A DIGITAL HOLE WHERE A SHOT HIT THE WORLD (BlockFX.ground_hole). A quad lying on the surface, cut
// into pixel cells: a ragged near-black core - ground that stopped being rendered - with a rim of
// glitch-palette cells, which then heals: the rim goes out first, the core shrinks and drops cells.
//
// NOT a glitch card: those blend ADDITIVELY, and adding black draws nothing, while a hole has to
// darken the ground under it. Hence blend_mix and its own shader.

uniform float progress : hint_range(0.0, 1.0) = 0.0;   // 0 fresh, 1 gone
uniform float seed = 0.0;
uniform float grid = 9.0;                                 // pixels across the quad

float h2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21) + seed * 0.37);
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h2(i), h2(i + vec2(1.0, 0.0)), f.x),
			mix(h2(i + vec2(0.0, 1.0)), h2(i + vec2(1.0, 1.0)), f.x), f.y);
}

// The glitch cards' palette (glitch_card.gdshader), so a hole speaks the same language as a block
// appearing: cyan -> blue -> violet -> magenta.
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

void fragment() {
	vec2 g = floor(UV * grid);
	vec2 c = (g + 0.5) / grid * 2.0 - 1.0;          // cell centre, -1..1
	float r = length(c);
	float edge = 0.42 + 0.38 * vnoise(g * 0.8 + vec2(seed, seed * 1.7));   // ragged outline
	float core = edge * (1.0 - 0.75 * progress);
	float rim = 2.2 / grid;
	if (r > core + rim) {
		discard;
	}
	if (h2(g) < progress * 0.9) {
		discard;                                       // healing: cells drop out one by one
	}
	vec3 col;
	float a;
	if (r < core) {
		col = vec3(0.01, 0.012, 0.03);
		a = 0.9;
	} else {
		col = palette(vnoise(g * 0.45 + vec2(seed * 3.0, 7.0)));
		// The rim flickers per cell and goes out first: a fresh hit is lit, an old one just dark.
		float flick = 0.55 + 0.45 * step(0.5, h2(g + floor(TIME * 10.0)));
		a = flick * (1.0 - smoothstep(0.15, 0.55, progress));
		if (a < 0.03) {
			discard;
		}
	}
	ALBEDO = col;
	ALPHA = a * (1.0 - smoothstep(0.8, 1.0, progress));
}
