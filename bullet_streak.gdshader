// A ROUND AND ITS FIRE STREAK IN ONE SURFACE, ONE MATERIAL, ONE DRAW CALL (bullet_sim.gd _streak_mesh).
// Premultiplied alpha is the trick: ALPHA 1 draws the round opaque over what is behind it, ALPHA 0
// with the same blend (ONE, ONE_MINUS_SRC_ALPHA) ADDS the streak. UV2.x tells the two apart: 1 on
// the round, 0 on the streak (vertex COLOR is not it: on a MultiMesh it read 0 on the round).
// The streak's triangles come first, so the round covers its head.
// Per shot (INSTANCE_CUSTOM): x the streak's length, y the round's stretch (BulletSim trace).
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, shadows_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap;
uniform vec4 albedo : source_color = vec4(1.0);
uniform vec3 origin = vec3(0.0);        // the round mesh's offset inside the bullet
uniform float tail = 0.0;               // the round's back end on +Z, before the stretch
uniform vec3 head_col : source_color = vec3(1.0, 0.95, 0.65);
uniform vec3 mid_col : source_color = vec3(1.0, 0.55, 0.15);
uniform float mid_at = 0.25;

void vertex() {
	if (UV2.x > 0.5) {
		VERTEX.z *= INSTANCE_CUSTOM.y;
		VERTEX += origin;
	} else {
		VERTEX.xy += origin.xy;
		VERTEX.z = origin.z + tail * INSTANCE_CUSTOM.y + VERTEX.z * INSTANCE_CUSTOM.x;
	}
}

void fragment() {
	if (UV2.x > 0.5) {
		ALBEDO = texture(albedo_tex, UV).rgb * albedo.rgb;
		ALPHA = 1.0;
	} else {
		float t = UV.x;
		ALBEDO = t < mid_at ? mix(head_col, mid_col, t / mid_at)
				: mix(mid_col, vec3(0.0), (t - mid_at) / (1.0 - mid_at));
		ALPHA = 0.0;
	}
}
