shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// A FLAT WAVE OF RED PIXELS WHERE A MACHINE LANDED HARD (BlockFX.ground_wave). A quad lying on the
// ground, cut into square cells of `cell` metres; a ring of them runs outward from the middle and
// thins as it goes: the back of the ring dims, cells drop out at random, the whole ring fades.
// Cells are in METRES, not in UV, so a big landing has more pixels rather than bigger ones.

uniform float progress : hint_range(0.0, 1.0) = 0.0;   // where the front is, 0..1 of the radius
uniform float radius_m = 5.0;
uniform float cell = 0.4;
uniform float seed = 0.0;
uniform vec3 color : source_color = vec3(1.0, 0.13, 0.1);
uniform float ring = 0.22;                                // ring thickness, share of the radius
// LIFTED OUT OF THE GRASS IN DEPTH, as the shot marks are (glitch_card.gdshader): the wave lies on
// the PHYSICS ground and the drawn meadow stands G.grass_lift() over it, so it was buried in the
// grass. The vertices slide toward the camera along their own view ray: on screen the wave stays
// where it is, in depth it clears the lift (more at a grazing view).
uniform float depth_lift = 0.0;

void vertex() {
	if (depth_lift > 0.0) {
		vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		float d = length(vp.xyz);
		vec3 n = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
		float pull = depth_lift / max(abs(dot(vp.xyz / d, n)), 0.25);
		vp.xyz *= max(d - pull, 0.05) / d;
		POSITION = PROJECTION_MATRIX * vp;
	}
}

float h2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21) + seed * 0.37);
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 * radius_m;
	vec2 g = floor(p / cell);
	float d = length((g + 0.5) * cell) / radius_m;         // cell centre, 0 middle .. 1 edge
	float behind = progress - d;                            // how far the front has passed it
	if (behind < 0.0 || behind > ring) {
		discard;
	}
	if (h2(g) < 0.25 + 0.5 * progress) {
		discard;                                           // the wave thins as it spreads
	}
	float lead = 1.0 - behind / ring;                       // brightest at the front
	float flick = 0.7 + 0.3 * step(0.5, h2(g + floor(TIME * 14.0)));
	ALBEDO = color;
	ALPHA = lead * flick * (1.0 - smoothstep(0.6, 1.0, progress));
}
