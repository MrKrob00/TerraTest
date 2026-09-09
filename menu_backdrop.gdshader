shader_type canvas_item;
render_mode blend_mix, unshaded;

// MENU BACKDROP: a survey chart of ground that does not exist yet.
//
// It stands in for the world while the world is still being computed, and it stands in permanently
// for anyone who switched the menu fight off. So it had to read as THIS game and not as a generic
// loading pattern - hence contour lines: the noise below is the SAME value noise the biome masks
// and the terrain generator are built on (TerrainBiomes.cv_noise), sampled the same way, drawn as a
// topographic map. What drifts past is a real heightfield, just one nobody will drive on.
//
// Deliberately not the loading screen's language (glitch slices, brackets, torn title): that screen
// is a machine booting, this one is a map being surveyed. Two different moments, two looks.
//
// Everything is per-pixel maths - no textures, no particles, nothing to load, which is the point
// for something that has to be on screen before anything else exists.

uniform vec4 col_deep : source_color = vec4(0.008, 0.027, 0.035, 1.0);
uniform vec4 col_high : source_color = vec4(0.043, 0.118, 0.137, 1.0);
uniform vec4 col_line : source_color = vec4(0.35, 0.85, 0.92, 1.0);
uniform vec4 col_warm : source_color = vec4(0.85, 0.45, 0.25, 1.0);
// Contour bands across the field. More lines = a busier chart; below ten it stops reading as one.
uniform float bands = 15.0;
// How far the field drifts, world units per second. Slow: this is a backdrop, not an animation.
uniform float drift = 0.9;
// 1 while the ground is being computed, 0 when the backdrop is only decoration. It drives the
// survey sweep and the warm tint of the deep contours - the screen is BUSY, and it should look it.
uniform float energy = 1.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Three octaves, not the generator's six: at contour-line scale the last three octaves only add
// noise the lines cannot show anyway, and this runs on every pixel of a phone screen.
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		s += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return s;
}

void fragment() {
	// Aspect from the screen itself: the chart must not stretch with the window, and a uniform fed
	// from script is one more thing to keep in sync.
	float ar = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 uv = UV;
	vec2 p = vec2(uv.x * ar, uv.y) * 3.2;
	// The field drifts diagonally and the second octave set drifts slower - the chart never repeats
	// its own frame, which is what stops a static pattern from reading as a frozen screen.
	p += vec2(TIME * drift * 0.011, TIME * drift * 0.004);
	float h = fbm(p) + 0.35 * fbm(p * 2.7 + vec2(11.0, 5.0));

	// CONTOURS. The width is taken from the screen-space derivative, so a line is one pixel wide
	// wherever the field is steep or flat - the usual fract() trick without it gives fat smears on
	// the flats and nothing at all on the slopes.
	float f = h * bands;
	float w = fwidth(f);
	float dist = abs(fract(f) - 0.5) / max(w, 0.0001);
	float line = 1.0 - smoothstep(0.0, 1.4, dist);
	// Every fifth contour is an index line, as on a real chart: it gives the eye a structure to
	// read instead of an even field of stripes.
	float major = step(4.5, mod(floor(f), 5.0));
	line *= 0.35 + 0.65 * major;

	// Ground: darker at the bottom, colder and lighter toward the top - a horizon for the eye.
	vec3 col = mix(col_high.rgb, col_deep.rgb, smoothstep(0.05, 1.0, uv.y));
	// The deep end of the field takes the canyon's warmth, the high end stays cold. The chart then
	// has terrain in it rather than one flat teal.
	vec3 lc = mix(col_warm.rgb, col_line.rgb, smoothstep(0.25, 0.85, h));
	col += lc * line * (0.16 + 0.10 * energy);

	// SURVEY SWEEP: a soft band travelling down the screen, brightening the contours it crosses.
	// This is the whole "something is being computed" signal, so it only runs while `energy` says
	// so - a permanent backdrop that keeps scanning would be a distraction with nothing behind it.
	float sweep = fract(TIME * 0.07);
	// x*x, not pow(x, 2.0): pow() of a negative base is undefined in GLSL, and half of this band
	// is below the sweep line.
	float dy = (uv.y - sweep) * 9.0;
	float band = exp(-dy * dy);
	col += col_line.rgb * band * (0.05 + line * 0.55) * energy;

	// Survey grid: sparse, dim, and squared off against the aspect so the cells stay square.
	vec2 g = fract(vec2(uv.x * ar, uv.y) * 14.0);
	float grid = max(smoothstep(0.985, 1.0, g.x), smoothstep(0.985, 1.0, g.y));
	col += col_line.rgb * grid * 0.05;

	// Vignette last: it pulls the eye to the middle, where the readout sits, and hides the corners
	// where the drifting field is at its least interesting.
	// smoothstep with its edges in order, then inverted: reversed edges are undefined in GLSL even
	// though most drivers happen to ramp the other way.
	float r = length((uv - 0.5) * vec2(ar, 1.0));
	float vig = 1.0 - smoothstep(0.35, 1.05, r);
	col *= mix(0.45, 1.0, vig);

	// ALPHA COMES FROM THE INCOMING COLOR, not from 1.0: a canvas shader that overwrites COLOR
	// throws away the node's modulate, and the whole fade in and out of this backdrop is modulate.
	COLOR = vec4(col, COLOR.a);
}
