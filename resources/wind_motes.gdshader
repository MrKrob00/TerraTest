// THE WIND'S MOTES (world_wind.gd): leaves, snow lumps, sand, dust, flown by a gust. One MultiMesh
// of quads, and EVERYTHING ABOUT THEIR FLIGHT IS HERE: a mote is a seed in INSTANCE_CUSTOM, its place
// is that seed in a box round the camera, carried by the wind's travel (`wind_t`) and fluttered by
// TIME, and wrapped back into the box when it leaves - so it stands in the world and the camera can
// turn and move through it, and the CPU writes a few uniforms a frame and nothing per mote.
// OPAQUE, CUT BY ALPHA SCISSOR: a shape with a hard edge needs no blending and no sorting.
shader_type spatial;
render_mode unshaded, cull_disabled, world_vertex_coords;

uniform vec3 cam_pos;
uniform float box = 24.0;            // metres, the cube the motes live in, centred on the camera
uniform float wind_t = 0.0;          // seconds of travel, integrated on the CPU (a gust eases in/out)
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_speed = 6.0;
uniform float fall = 0.4;            // m/s down, on top of the wind
uniform float amount = 0.0;          // 0..1: the share of motes alive (the gust's strength)
uniform int kind = 0;                // 0 leaves, 1 snow lumps, 2 sand, 3 dust
uniform vec2 size_range = vec2(0.08, 0.18);
uniform vec3 col_a : source_color = vec3(0.16, 0.22, 0.10);
uniform vec3 col_b : source_color = vec3(0.30, 0.26, 0.12);

varying vec3 v_col;
varying float v_seed;

float h1(float n) { return fract(sin(n) * 43758.5453); }

mat3 axis_angle(vec3 a, float t) {
	float c = cos(t);
	float s = sin(t);
	float k = 1.0 - c;
	return mat3(
		vec3(c + a.x * a.x * k, a.y * a.x * k + a.z * s, a.z * a.x * k - a.y * s),
		vec3(a.x * a.y * k - a.z * s, c + a.y * a.y * k, a.z * a.y * k + a.x * s),
		vec3(a.x * a.z * k + a.y * s, a.y * a.z * k - a.x * s, c + a.z * a.z * k));
}

void vertex() {
	vec4 sd = INSTANCE_CUSTOM;
	v_seed = sd.x;
	// alive: the gust's strength decides how many, the seed decides which
	float alive = clamp((amount - sd.w) * 10.0, 0.0, 1.0);
	float own = 0.7 + 0.6 * h1(sd.x * 91.7);
	vec3 p = sd.xyz * box;
	vec3 w = vec3(wind_dir.x, 0.0, wind_dir.y);
	p += w * wind_t * wind_speed * own;
	float tt = TIME + sd.y * 40.0;
	p += vec3(sin(tt * 1.3) * 0.9, sin(tt * 2.1 + sd.z * 9.0) * 0.6 - fall * wind_t * own, cos(tt * 1.7) * 0.9);
	vec3 o = cam_pos - vec3(box * 0.5);
	p = o + mod(p - o, vec3(box));
	// out to the box's sphere it thins away; right at the lens it does too
	float d = length(p - cam_pos);
	float fade = smoothstep(box * 0.5, box * 0.36, d) * smoothstep(0.5, 1.4, d);
	float size = mix(size_range.x, size_range.y, h1(sd.z * 53.1)) * alive * fade;
	vec2 q = VERTEX.xy;                          // the quad's corner, -0.5..0.5
	vec3 corner;
	if (kind == 0) {
		// a leaf TUMBLES: its own axis, its own rate - edge-on it is a sliver, face-on a leaf
		vec3 ax = normalize(vec3(h1(sd.x * 13.1), h1(sd.y * 17.3), h1(sd.z * 19.7)) - 0.5);
		mat3 r = axis_angle(ax, TIME * (2.0 + 4.0 * h1(sd.w * 23.0)) + sd.x * 6.28);
		corner = r * vec3(q.x * 0.55, q.y, 0.0);
	} else {
		// lumps and grains face the eye; sand is streaked along the wind
		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		vec2 qq = kind == 2 ? vec2(q.x * 3.0, q.y) : q;
		corner = right * qq.x + up * qq.y;
	}
	VERTEX = p + corner * size;
	v_col = mix(col_a, col_b, h1(sd.y * 71.3));
}

void fragment() {
	vec2 u = UV * 2.0 - 1.0;
	float a;
	vec3 c = v_col;
	if (kind == 0) {
		// a pointed leaf: wide in the middle, sharp at both ends, a darker midrib
		a = step(abs(u.x), 1.0 - u.y * u.y);
		c *= 1.0 - 0.35 * step(abs(u.x), 0.08);
		c *= FRONT_FACING ? 1.0 : 0.75;
	} else {
		// a lump with a ragged edge, lit from above and shaded under, so it reads round - and a
		// white lump reads against white snow only by that shade (a flat white disc vanished)
		float ang = atan(u.y, u.x);
		float edge = 0.78 + 0.16 * sin(ang * 3.0 + v_seed * 20.0) * sin(ang * 5.0 + v_seed * 7.0);
		float r = length(u);
		a = step(r, edge);
		float lit = clamp(0.55 + 0.45 * dot(normalize(u + vec2(0.0001)), vec2(-0.45, 0.89)) * (r / edge), 0.0, 1.0);
		c *= mix(0.62, 1.05, lit) * mix(1.0, 0.86, smoothstep(0.75, 1.0, r / edge));
	}
	ALBEDO = c;
	ALPHA = a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
