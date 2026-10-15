shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

// THE RE-ENTRY GLOW ROUND THE CAPSULE'S NOSE (planetfall.gd): a unit sphere stretched along the
// flight, brightest at the nose (local -Y) and gone by the neck, hotter at the rim, flickering. Added
// over the sky, so it reads as white-hot with an orange edge. `heat` 0..1 drives it from the script.

uniform float heat = 1.0;
uniform vec3 hot : source_color = vec3(1.0, 0.86, 0.55);
uniform vec3 edge : source_color = vec3(1.0, 0.38, 0.08);
uniform float reach = 0.55;           // how far back along the shell the glow runs (0..1)

varying vec3 v_local;

float h1(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	float front = clamp((0.5 - v_local.y * 0.5) / reach - (1.0 / reach - 1.0), 0.0, 1.0);
	float rim = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float band = 0.75 + 0.25 * sin(v_local.y * 9.0 - TIME * 30.0 + v_local.x * 4.0);
	float flick = 0.82 + 0.18 * h1(floor(TIME * 24.0));
	float a = front * (0.45 + 0.55 * rim) * band * flick * heat;
	ALBEDO = mix(edge, hot, front * (1.0 - rim * 0.6));
	ALPHA = clamp(a, 0.0, 1.0);
}
