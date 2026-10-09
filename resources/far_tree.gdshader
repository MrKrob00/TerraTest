shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform, shadows_disabled;

// THE FAR TREE CARD (far_trees.gd): a picture of the tree, turned about the vertical to face the
// camera, showing the side the camera stands on in the tree's own frame. The instance carries the
// tree's point and size (MODEL_MATRIX) and in INSTANCE_CUSTOM its yaw (r) and kind (g); the card's
// frame per kind is `tiles` (width, height, bottom in model units, far_trees.tile_for).
uniform sampler2D atlas : filter_linear_mipmap, repeat_disable;
uniform vec4 tiles[3];
uniform float views = 8.0;
uniform float kinds = 3.0;
// the layer's far edge: cards dissolve from fade_from to fade_to, pixel by pixel, instead of ending
uniform float fade_from = 340.0;
uniform float fade_to = 400.0;

// the world's haze, as the trees and the ground have it
global uniform vec4 world_haze;
global uniform vec4 haze_range;

varying vec2 v_uv;
varying float v_fade;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	int kind = clamp(int(INSTANCE_CUSTOM.g + 0.5), 0, 2);
	vec4 t = tiles[kind];
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - origin;
	to_cam.y = 0.0;
	float d = length(to_cam);
	vec3 f = d > 0.001 ? to_cam / d : vec3(0.0, 0.0, 1.0);
	vec3 right = vec3(f.z, 0.0, -f.x);
	vec3 world = origin + right * (VERTEX.x * t.x * s) + vec3(0.0, (t.z + VERTEX.y * t.y) * s, 0.0);
	// which picture: the camera's angle round the tree, in the tree's frame (a yaw turns the model
	// by that much, so the frame's angle is the world's minus the yaw)
	float ang = atan(f.x, f.z) - INSTANCE_CUSTOM.r;
	float frame = mod(floor(ang / (6.2831853 / views) + 0.5), views);
	v_uv = vec2((frame + UV.x) / views, (float(kind) + UV.y) / kinds);
	v_fade = 1.0 - smoothstep(fade_from, fade_to, d);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(f, 0.0)).xyz);
}

void fragment() {
	vec4 c = texture(atlas, v_uv);
	// a screen-door fade: whole pixels drop out as the card nears the far edge (no blending, no sort)
	float n = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (c.a < 0.5 || n > v_fade) {
		discard;
	}
	// the picture holds what the trees' shader put on screen (sRGB), so it goes out the way their
	// vertex colour does (resources/resource.gdshader): untouched where the renderer writes sRGB
	vec3 col = c.rgb;
	if (!OUTPUT_IS_SRGB) {
		col = mix(col / 12.92, pow((col + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), col));
	}
	ALBEDO = col;
	FOG = vec4(world_haze.rgb, smoothstep(haze_range.x, haze_range.y, length(VERTEX.xz)) * haze_range.z);
}
