shader_type sky;
// THE WORLD'S SKY (the player: "the sky is boring - a blue backdrop and a white sun, no clouds, no
// day and night"). CHEAP BY CONSTRUCTION: it is drawn only on background pixels, and since nothing
// is lit BY the sky (ambient is a flat colour, reflections are off - CLAUDE.md, Look and light) the
// renderer never builds a radiance map from it, so TIME and per-frame uniforms cost nothing more.
// Two texture fetches a pixel (art/sky_clouds.py: R cumulus, G detail), one hash for the stars.
//
// day_cycle.gd drives `night`, `sun_dir` and `moon_dir`; without it (the menu) the sun is the
// scene's directional light (LIGHT0) and it is day. The lower half stays DARK on purpose: a hole in
// the ground opens onto it, and a pale one reads as a torn world (CLAUDE.md).

uniform vec3 zenith_day : source_color = vec3(0.16, 0.36, 0.72);
uniform vec3 horizon_day : source_color = vec3(0.62, 0.78, 0.92);
uniform vec3 zenith_night : source_color = vec3(0.012, 0.02, 0.06);
uniform vec3 horizon_night : source_color = vec3(0.05, 0.08, 0.16);
uniform vec3 sunset_glow : source_color = vec3(1.0, 0.48, 0.2);
uniform vec3 ground_bottom : source_color = vec3(0.2, 0.21, 0.23);
uniform vec3 ground_horizon : source_color = vec3(0.3, 0.33, 0.37);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.82);
uniform vec3 moon_color : source_color = vec3(0.78, 0.84, 0.95);

uniform sampler2D cloud_tex : repeat_enable, filter_linear_mipmap;
uniform float cloud_scale = 0.22;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.48;
uniform vec2 cloud_wind = vec2(0.006, 0.0025);

uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform bool manual_sun = false;
uniform vec3 sun_dir = vec3(0.836, 0.402, 0.374);
uniform vec3 moon_dir = vec3(-0.836, -0.402, -0.374);

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 sun = manual_sun ? normalize(sun_dir) : (LIGHT0_ENABLED ? LIGHT0_DIRECTION : normalize(sun_dir));
	float day = 1.0 - night;
	// the sun near the horizon, either side of it: the dusk and the dawn
	float dusk = 1.0 - smoothstep(0.0, 0.32, abs(sun.y + 0.04));

	if (dir.y < 0.0) {
		vec3 g = mix(ground_horizon, ground_bottom, pow(-dir.y, 0.4));
		COLOR = g * mix(1.0, 0.35, night);
	} else {
		float up = pow(dir.y, 0.5);
		vec3 col = mix(mix(horizon_day, zenith_day, up), mix(horizon_night, zenith_night, up), night);
		// the horizon reddens toward the sun at dusk and dawn
		vec2 hz = normalize(dir.xz + vec2(1e-4));
		vec2 sz = normalize(sun.xz + vec2(1e-4));
		float toward = max(dot(hz, sz), 0.0);
		float low = pow(1.0 - dir.y, 5.0);
		col = mix(col, sunset_glow, dusk * low * (0.35 + 0.65 * toward * toward));
		col = mix(col, col * vec3(0.62, 0.55, 0.78), dusk * up * (1.0 - night));   // the zenith deepens

		// the sun and its glow; at night the moon
		float ds = max(dot(dir, sun), 0.0);
		col += sun_color * (smoothstep(0.9993, 0.9996, ds) * 6.0 + pow(ds, 300.0) * 0.8 + pow(ds, 12.0) * 0.12) * day;
		vec3 moon = normalize(moon_dir);
		float dm = max(dot(dir, moon), 0.0);
		col += moon_color * (smoothstep(0.99955, 0.9998, dm) * 1.6 + pow(dm, 200.0) * 0.15) * night;

		// stars, under the clouds
		vec3 cell = floor(dir * 220.0);
		float star = step(0.9965, hash3(cell)) * night * smoothstep(0.05, 0.3, dir.y);
		star *= 0.6 + 0.4 * sin(TIME * 2.0 + hash3(cell + 7.0) * 40.0);

		// clouds: one plane over the world, seen through the dome
		vec2 p = dir.xz / (dir.y + 0.12) * cloud_scale + cloud_wind * TIME;
		float body = texture(cloud_tex, p).r;
		float detail = texture(cloud_tex, p * 3.3 + cloud_wind * TIME * 1.7).g;
		float dens = body - detail * 0.3;
		float th = 1.0 - cloud_cover;
		float c = smoothstep(th - 0.06, th + 0.12, dens) * smoothstep(0.02, 0.22, dir.y);
		float thick = smoothstep(th, th + 0.35, dens);
		vec3 lit = mix(vec3(1.0), sunset_glow * 1.15 + vec3(0.15), dusk * 0.8);
		vec3 cloud = mix(lit, lit * 0.62, thick);
		cloud += sun_color * pow(ds, 6.0) * 0.35 * (1.0 - thick) * day;       // a silver edge toward the sun
		cloud = mix(cloud, vec3(0.1, 0.12, 0.2), night * 0.85);
		col = mix(col + vec3(star), cloud, c * mix(0.95, 0.7, night));
		COLOR = col;
	}
}
