shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

// THE SMOULDERING GROUND WHERE A NEW WORLD'S PLAYER WAKES (crash_site.gd builds the patch on the
// terrain's heights; the player's picture: charred plates with weakly glowing cracks). ITS OWN MESH
// AND ITS OWN SHADER, NEVER THE GROUND'S: code in the ground's fragment costs every ground pixel on
// a fill-bound phone, taken or not (18 -> 34 fps once the first embers were out of it). Here it is ONE
// fetch (resources/ember_cracks.png, art/ember_cracks.py: R crack distance, G the plate's number, B
// grain) and a few multiplies, over a 13 m patch only. The grass under it is pressed flat by the
// trample map (grass.gd `press_zone`), so the patch lies a few centimetres over the ground and no
// blade grows through the coals.
uniform sampler2D cracks : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float tile = 6.0;              // metres one texture tile spans (7 plates a side)
uniform float heat = 1.0;              // 1 fresh, cools to crash_site.COOL_FLOOR
uniform float depth_lift = 0.04;       // toward the camera, against z-fighting with the ground

global uniform vec4 ground_amb;        // the fast ground's own light (day_cycle._ground_light)
global uniform vec4 ground_sun;
global uniform vec4 sun_dir;
global uniform vec4 world_haze;
global uniform vec4 haze_range;

varying vec2 v_wxz;
varying float v_r;                     // 0 at the middle, 1 at the patch's radius
varying vec3 v_light;
varying float v_haze;

void vertex() {
	vec4 wp = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_wxz = wp.xz;
	v_r = length(UV);
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float ndl = dot(wn, normalize(sun_dir.xyz));
	v_light = ground_amb.rgb + ground_sun.rgb * clamp((ndl + ground_sun.a) / (1.0 + ground_sun.a), 0.0, 1.0);
	v_haze = smoothstep(haze_range.x, haze_range.y, length(wp.xz - CAMERA_POSITION_WORLD.xz));
	// POSITION on every path (CLAUDE.md, Weapons)
	vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float d = length(vp.xyz);
	vp.xyz *= max(d - depth_lift * (1.0 + d * 0.02), 0.05) / d;
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	vec3 t = texture(cracks, v_wxz / tile).rgb;
	float ragged = (t.b - 0.5) * 0.35;
	float edge = 1.0 - smoothstep(0.62, 1.0, v_r + ragged);
	// hotter toward the middle, cold ash at the rim, and whole stretches of crack gone cold (the
	// grain's broad swell), or the patch reads as one even net of lava
	float hot = heat * (1.0 - smoothstep(0.15, 0.9, v_r + ragged)) * smoothstep(0.22, 0.6, t.b);
	float core = 1.0 - smoothstep(0.035, 0.11, t.r);
	float halo = 1.0 - smoothstep(0.0, 0.5, t.r);
	// every plate's cracks breathe on their own beat
	float breathe = 0.68 + 0.32 * sin(TIME * (0.7 + 0.8 * t.g) + t.g * 6.283);
	vec3 plate = mix(vec3(0.07, 0.065, 0.07), vec3(0.24, 0.22, 0.21), t.g * 0.5 + t.b * 0.5);
	// toward the rim the charcoal turns to grey-brown ash, so the patch fades into the meadow
	// instead of ending in a black smudge
	plate = mix(plate, vec3(0.33, 0.3, 0.26) * (0.8 + 0.4 * t.b), smoothstep(0.45, 0.95, v_r + ragged));
	plate *= v_light;
	vec3 glow = mix(vec3(0.7, 0.07, 0.02), vec3(1.0, 0.5, 0.1), core * core);
	ALBEDO = plate + glow * (core * 0.95 + halo * 0.22) * hot * breathe;
	ALPHA = edge;
	FOG = vec4(world_haze.rgb, v_haze * haze_range.z);
}
