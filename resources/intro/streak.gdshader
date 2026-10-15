shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// THE SPEED STREAKS ROUND THE FALLING CAPSULE (planetfall.gd): thin crossed strips along the flight,
// added over the sky, bright in the middle and gone at both ends. INSTANCE_CUSTOM.x brightness.

varying float v_b;

void vertex() {
	v_b = INSTANCE_CUSTOM.x;
}

void fragment() {
	float along = sin(UV.y * 3.14159);
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	ALBEDO = vec3(0.92, 0.96, 1.0);
	ALPHA = clamp(along * across * v_b, 0.0, 1.0);
}
