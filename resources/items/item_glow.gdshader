shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// The loose item's glow (resource.gd): one quad turned to the camera, a soft disc in the item's
// colour with a faint pulse. It replaced a metre-wide additive sphere of 256 triangles.
uniform vec3 tint : source_color = vec3(0.4, 1.0, 0.5);
uniform float strength = 0.55;
uniform float pulse = 0.15;

void vertex() {
	// billboard: keep the node's position and scale, drop its rotation
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
}

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = pow(clamp(1.0 - d, 0.0, 1.0), 2.0);
	float p = 1.0 + pulse * sin(TIME * 3.0);
	ALBEDO = tint * a * strength * p;
}
