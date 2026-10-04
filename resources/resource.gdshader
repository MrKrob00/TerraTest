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
// A tree LEANS a little as it is chopped and, at zero, falls and is gone in `fall_time`, leaving
// its stump (the player's call: a felled tree lying there for the rest was wrong).
uniform bool fells = false;
uniform float lean_max = 0.30;
uniform float fall_angle = 1.45;
uniform float fall_time = 0.9;
uniform float grow_time = 0.6;
// THE VEINS' CLOCK, written every frame by resource_nodes (`shader_now`), the same function that
// writes the hit and regrow times. NOT `TIME`: that is the renderer's clock, built from frame steps,
// and it ran seconds behind the wall clock after a slow load - a felled tree's "since" stayed
// negative, so it leaned and never fell or went (the player: "after felling the tree does not go").
uniform float now = 0.0;

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
	if (hp == 0.0 && last_hit == 0.0) {
		hp = 1.0;                       // an empty slot reads as whole
	}
	float grow = 1.0;
	if (respawn > 0.0) {
		float age = now - respawn;
		if (age >= 0.0 && age < grow_time) {
			grow = smoothstep(0.0, 1.0, age / grow_time);
		}
	}
	vec3 p = VERTEX - vec3(0.0, base_y, 0.0);
	float h = max(p.y, 0.0);
	// An ORE VEIN BREAKS, IT DOES NOT SHRINK (the player's call): UV.x is each part's break point
	// (art/vein_models.gd), and a part is drawn only while the HP share is above it - one part goes
	// with each ore thrown out, the rubble (UV.x below 0) stays. A broken part collapses to one point,
	// so its triangles have no area and draw nothing. On the TREE UV.x marks what falls; the stump stays.
	bool broken = !fells && hp <= UV.x;
	if (broken) {
		p = vec3(0.0);
	} else if (UV.x > 0.5 || !fells) {
		if (fells) {
			float a = (1.0 - hp) * lean_max;
			float keep = 1.0;
			if (hp <= 0.001) {
				// felled: tips over from where it leaned, then sinks out of sight
				float since = max(now - last_hit, 0.0);
				a = mix(lean_max, fall_angle, smoothstep(0.0, fall_time * 0.6, since));
				keep = 1.0 - smoothstep(fall_time * 0.5, fall_time, since);
			}
			float c = cos(a);
			float s = sin(a);
			p = vec3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
			p *= keep * mix(0.05, 1.0, grow);
		} else {
			p *= mix(0.05, 1.0, grow);          // back from the rest: the whole vein grows in again
		}
		if (last_hit > 0.0) {
			float since = now - last_hit;
			if (since >= 0.0 && since < hit_duration) {
				float fade = 1.0 - since / hit_duration;
				float k = h * shake_intensity * fade;
				p.x += sin(since * shake_speed) * k;
				p.z += cos(since * shake_speed) * k * 0.5;
			}
		}
	}
	VERTEX = p + vec3(0.0, base_y, 0.0);
}

// the world's haze, as the ground has it (addons/LiteTerrain/glsl.gdshader): a far tree in it
global uniform vec4 world_haze;
global uniform vec4 haze_range;

void fragment() {
	// Vertex colours are authored in sRGB, ore_colors arrive linear. Which space ALBEDO is in is the
	// renderer's: where it writes sRGB straight out (OUTPUT_IS_SRGB, as here in Compatibility) the
	// vertex colour goes through untouched and the metal goes back to sRGB - the same branch a
	// StandardMaterial with vertex_color_is_srgb takes. Converting always made the rock black and
	// the metals a shade darker and redder than G.METAL_COLOR, measured on the real driver.
	vec3 c = COLOR.rgb;
	vec3 tint = v_tint;
	float gain = TINT_LIN;
	if (OUTPUT_IS_SRGB) {
		tint = mix(tint * 12.92, 1.055 * pow(max(tint, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), tint));
		gain = TINT_GAIN;
	} else {
		c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
	}
	// no white flash on a hit (the player called it a placeholder): a hit throws red digits instead,
	// resource_node.hurt -> BlockFX.vein_digits
	ALBEDO = mix(c, c * gain * tint, COLOR.a);
	FOG = vec4(world_haze.rgb, smoothstep(haze_range.x, haze_range.y, length(VERTEX.xz)) * haze_range.z);
}
