shader_type spatial;
render_mode unshaded, cull_back;

// THE MINED PART OF A VEIN (art/vein_models.gd): the ore's crystals, or a tree. The rock and the
// stump under it are plain vertex colour and never move.
//
// Per instance (resource_node.gd writes it): R the last hit's time (shake, flash), G the HP share
// (1 whole -> 0 mined out), B the time it came back (grows), A the type - a metal's index into
// ore_colors, the last one being wood.
//
// Vertex colour: alpha 1 is TINTED - the metal's colour times the facet's tone (rgb, stored divided
// by TINT_GAIN so a lit facet can go over the metal's own colour); alpha 0 is a fixed colour.
// Unshaded: the facets carry their own tone, and EMISSION does nothing under unshaded in
// Compatibility (CLAUDE.md, Look and light).
const int MAX_ORE_TYPES = 8;
const float TINT_GAIN = 1.4;
const float TINT_LIN = 2.096;            // TINT_GAIN to the 2.4-ish of sRGB: the gain in linear
uniform vec3 ore_colors[MAX_ORE_TYPES];   // linear RGB, filled by resource_nodes.gd
uniform float hit_duration = 0.35;
uniform float shake_intensity = 0.15;
uniform float shake_speed = 40.0;
// The ground in the vein's frame: what the crystals shrink into and the tree turns about.
uniform float base_y = -0.25;
// A tree FALLS as it is chopped (leans by the share gone, lies down at zero) instead of shrinking.
uniform bool fells = false;
uniform float fall_angle = 1.45;
// What is left of a mined-out crystal: stubs, so the vein still says what it holds while it rests.
uniform float stub = 0.22;
uniform float grow_time = 0.6;

varying float v_hit;
varying vec3 v_tint;

void vertex() {
	float last_hit = INSTANCE_CUSTOM.r;
	float hp = INSTANCE_CUSTOM.g;
	float respawn = INSTANCE_CUSTOM.b;
	int t = clamp(int(INSTANCE_CUSTOM.a + 0.5), 0, MAX_ORE_TYPES - 1);
	v_tint = ore_colors[t];
	if (v_tint == vec3(0.0)) {
		v_tint = vec3(1.0, 0.75, 0.0);
	}
	v_hit = last_hit;
	if (hp == 0.0 && last_hit == 0.0) {
		hp = 1.0;                       // an empty slot reads as whole
	}
	float grow = 1.0;
	if (respawn > 0.0) {
		float age = TIME - respawn;
		if (age >= 0.0 && age < grow_time) {
			grow = smoothstep(0.0, 1.0, age / grow_time);
		}
	}
	vec3 p = VERTEX - vec3(0.0, base_y, 0.0);
	float h = max(p.y, 0.0);
	if (fells) {
		float a = (1.0 - hp) * fall_angle;
		float c = cos(a);
		float s = sin(a);
		p = vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
		p *= mix(0.05, 1.0, grow);
	} else {
		p *= mix(stub, 1.0, hp) * mix(stub, 1.0, grow);
	}
	if (last_hit > 0.0) {
		float since = TIME - last_hit;
		if (since >= 0.0 && since < hit_duration) {
			float fade = 1.0 - since / hit_duration;
			float k = h * shake_intensity * fade;
			p.x += sin(since * shake_speed) * k;
			p.z += cos(since * shake_speed) * k * 0.5;
		}
	}
	VERTEX = p + vec3(0.0, base_y, 0.0);
}

void fragment() {
	// vertex colours are authored in sRGB, ore_colors arrive linear
	vec3 c = COLOR.rgb;
	c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
	vec3 col = mix(c, c * TINT_LIN * v_tint, COLOR.a);
	float since = TIME - v_hit;
	if (v_hit > 0.0 && since >= 0.0 && since < 0.15) {
		col += vec3((1.0 - since / 0.15) * 0.6);
	}
	ALBEDO = col;
}
