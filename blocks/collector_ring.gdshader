shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

// THE COLLECTOR'S REACH ON THE GROUND (collector.gd builds the ribbon on the terrain's heights):
// dashes running round the ring. UV.x goes once round (0..1), UV.y across the ribbon. BLENDED, NOT
// ADDED: cyan added to the desert's sand came out white, measured on the real driver.
uniform vec4 color : source_color = vec4(0.12, 0.78, 1.0, 0.9);
uniform float dashes = 28.0;
uniform float spin = 0.06;            // turns a second
// The ribbon lies on the PHYSICS ground and the meadow is drawn up to G.grass_lift() over it: the
// vertices slide toward the camera along their own view ray, as the ground marks do
// (ground_wave.gdshader) - on screen the ring stays where it is, in depth it clears the grass.
uniform float depth_lift = 0.0;

void vertex() {
	// POSITION on every path (CLAUDE.md, Weapons): written in a branch, the other path leaves
	// GLES3's clip position uninitialised.
	vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	if (depth_lift > 0.0) {
		float d = length(vp.xyz);
		vec3 n = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
		float pull = depth_lift / max(abs(dot(vp.xyz / d, n)), 0.25);
		vp.xyz *= max(d - pull, 0.05) / d;
	}
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	// fract first: TIME grows for the whole session, and a large product loses the dash's edge
	float turn = fract(TIME * spin);
	float u = fract((UV.x - turn) * dashes);
	float dash = smoothstep(0.0, 0.08, u) * (1.0 - smoothstep(0.5, 0.58, u));
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	ALBEDO = color.rgb;
	ALPHA = color.a * dash * smoothstep(0.0, 0.45, across);
}
