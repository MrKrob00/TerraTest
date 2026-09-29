shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, blend_add, shadows_disabled;

// THE REPAIR FIELD'S BOUNDARY: a sphere of exactly the field's radius, so the player sees at a
// glance what it reaches. A bright rim, a thin grid of parallels and meridians fading toward the
// middle of the disc (so it never veils the machine inside), and a slow band running up and down
// the sphere that lights the grid as it passes. What the field is DOING is said by the digits
// flying to the blocks it mends (regen_digit.gdshader); `pulse` is the field answering each one.
//
// Back faces are culled: from inside the field it is invisible, which at its radius the camera
// almost never is, and half the fragments of a transparent sphere is the whole of its cost.
// Unshaded, so ALBEDO carries the colour; blend_add, so ALPHA is how much of it is added.

uniform vec3  tint : source_color = vec3(0.25, 1.0, 0.45);
uniform float active : hint_range(0.0, 1.0) = 1.0;   // eased on and off by the block
uniform float pulse : hint_range(0.0, 1.0) = 0.0;    // a repair just landed

varying vec3 v_dir;

void vertex() {
	v_dir = normalize(VERTEX);
}

float line(float x, float w) {
	return 1.0 - smoothstep(0.0, w, abs(fract(x) - 0.5));
}

void fragment() {
	float facing = abs(dot(NORMAL, VIEW));
	float rim = pow(1.0 - facing, 3.0);
	float lat = line(v_dir.y * 5.0, 0.05);
	float lon = line(atan(v_dir.z, v_dir.x) * 1.9098593, 0.04);   // twelve meridians
	float grid = max(lat, lon);
	// The band: a soft ring sliding between the poles.
	float band = exp(-pow((v_dir.y - sin(TIME * 0.55)) * 5.0, 2.0));
	float a = rim * 0.55
		+ grid * (0.06 + 0.22 * rim)
		+ grid * band * 0.35
		+ rim * pulse * 0.45;
	ALBEDO = tint;
	ALPHA = clamp(a * active, 0.0, 1.0);
}
