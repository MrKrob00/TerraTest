shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

// WHERE A MACHINE WILL LAND (drop_ring.gd builds two ribbons on the terrain's heights). UV.x goes
// once round (0..1), UV.y across the ribbon. Dashes run round; the COUNTDOWN is an arc that fills
// the ring as `progress` goes 0..1, standing still while the dashes turn, so the ring says both
// "here" and "how long". Blended, as the reach ring: a bright colour added to sand comes out white.
uniform vec4 color : source_color = vec4(1.0, 0.28, 0.12, 0.95);
uniform float dashes = 24.0;
uniform float spin = 0.25;            // turns a second; negative turns the other way
uniform float progress = 0.0;         // 0..1 over the warning
uniform float fade = 1.0;             // 1 shown, 0 gone (in and out)
// Lifted out of the grass in depth, as the ground marks and the reach ring (collector_ring.gdshader).
uniform float depth_lift = 0.0;

void vertex() {
	// POSITION on every path (CLAUDE.md, Weapons).
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
	// the spin speeds up as the drop nears
	float turn = fract(TIME * spin * (1.0 + 1.5 * progress));
	float u = fract((UV.x - turn) * dashes);
	float dash = smoothstep(0.0, 0.08, u) * (1.0 - smoothstep(0.55, 0.63, u));
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float filled = 1.0 - smoothstep(progress - 0.004, progress + 0.004, UV.x);
	// the last second blinks: four beats a second, getting harder
	float beat = 0.5 + 0.5 * sin(TIME * 25.0);
	float blink = mix(1.0, 0.55 + 0.45 * beat, smoothstep(0.66, 1.0, progress));
	ALBEDO = mix(color.rgb, vec3(1.0, 0.85, 0.6), filled * 0.35);
	ALPHA = color.a * fade * blink * max(dash * 0.6, filled * 0.9) * smoothstep(0.0, 0.4, across);
}
