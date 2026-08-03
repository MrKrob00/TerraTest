shader_type canvas_item;
render_mode blend_add;

uniform float progress : hint_range(0.0, 1.0) = 0.0;   // 0 = появление, 1 = развал
uniform float intensity : hint_range(0.0, 1.0) = 1.0;  // общая сила эффекта
uniform float grid_cells = 22.0;
uniform float fill_threshold = 0.52;
uniform float flicker_speed = 12.0;
uniform float seed = 0.0;
uniform vec2 cell_aspect = vec2(1.0, 0.35);            // клетки шире, чем выше (полосы данных)

float h1(float n) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }

float h2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = h2(i);
	float b = h2(i + vec2(1.0, 0.0));
	float c = h2(i + vec2(0.0, 1.0));
	float d = h2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Палитра «битых данных», сине-голубая ветка: голубой → циан → синий → индиго.
vec3 palette(float t) {
	vec3 c0 = vec3(0.55, 0.95, 1.00);
	vec3 c1 = vec3(0.15, 0.85, 1.00);
	vec3 c2 = vec3(0.20, 0.45, 1.00);
	vec3 c3 = vec3(0.35, 0.25, 0.95);
	t = clamp(t, 0.0, 1.0) * 3.0;
	if (t < 1.0) return mix(c0, c1, t);
	if (t < 2.0) return mix(c1, c2, t - 1.0);
	return mix(c2, c3, t - 2.0);
}

void fragment() {
	vec2 g = UV * grid_cells * cell_aspect * vec2(1.0, 1.0 / max(cell_aspect.y, 0.001));
	g = UV * vec2(grid_cells, grid_cells * cell_aspect.y);
	vec2 cell = floor(g);

	// Связная форма пятна (гладкий шум по клеткам → цельные «куски данных», не рябь).
	float fill = vnoise(cell * 0.5 + vec2(seed * 0.13, seed * 0.29));
	if (fill < fill_threshold) {
		discard;
	}
	// Цвет клетки — гладкий шум другого масштаба → соседние клетки близки по цвету.
	float cn = vnoise(cell * 0.35 + vec2(seed * 0.71 + 10.0, seed * 0.53 + 20.0));
	vec3 col = palette(cn);

	// Та же кривая, что у блоков: много в начале, пик к середине, к концу всё гаснет.
	float A = (progress < 0.5) ? mix(0.6, 1.0, progress / 0.5) : mix(1.0, 0.0, (progress - 0.5) / 0.5);
	float ct = fract(h2(cell) * 0.371 + 0.13);
	float vis = clamp((A - ct) / 0.12, 0.0, 1.0);
	float flick = 0.6 + 0.4 * h1(floor(TIME * flicker_speed) + cell.y);
	float a = vis * flick * intensity;
	if (a < 0.04) {
		discard;
	}
	COLOR = vec4(col, a);
}
