shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

// «Глитч-патч»: плоский БИЛБОРД (лицом к камере). Сетка grid_cells×grid_cells клеток,
// заполнена СВЯЗНЫМ пятном (гладкий шум → без разрывов). Цвет клетки — из палитры по ГЛАДКОМУ
// шуму: соседние клетки близки по цвету (ПЛАВНЫЙ переход, не резкий рандом). Клетки БЕЗ
// зазоров (квадраты стыкуются). Пульсирует, гаснет к концу (progress→1).

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;
uniform float grid_cells = 4.0;          // 4×4 или 6×6 (задаёт BlockFX)
uniform float fill_threshold = 0.42;     // выше = меньше заполнено (форма пятна)
uniform float flicker_speed = 12.0;

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

// Палитра «битых данных»: cyan → синий → фиолет → magenta (плавно).
vec3 palette(float t) {
	vec3 c0 = vec3(0.15, 0.85, 1.0);
	vec3 c1 = vec3(0.25, 0.45, 1.0);
	vec3 c2 = vec3(0.60, 0.20, 1.0);
	vec3 c3 = vec3(0.85, 0.15, 0.95);
	t = clamp(t, 0.0, 1.0) * 3.0;
	if (t < 1.0) return mix(c0, c1, t);
	if (t < 2.0) return mix(c1, c2, t - 1.0);
	return mix(c2, c3, t - 2.0);
}

void vertex() {
	// Настоящий БИЛБОРД (лицом к КАМЕРЕ): берём оси камеры (INV_VIEW_MATRIX), масштабируем их
	// размером карточки, позиция — из модели (m[3]). VIEW·(оси камеры) = единичный базис в
	// экране → квад строго перпендикулярен взгляду и поворачивается за камерой.
	mat4 m = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(m[0].xyz),
			INV_VIEW_MATRIX[1] * length(m[1].xyz),
			INV_VIEW_MATRIX[2] * length(m[2].xyz),
			m[3]);
}

void fragment() {
	vec2 g = UV * grid_cells;
	vec2 cell = floor(g);
	// Связная форма пятна (гладкий шум по клеткам → без разрывов).
	float fill = vnoise(cell * 0.5 + vec2(seed * 0.13, seed * 0.29));
	if (fill < fill_threshold) {
		discard;                          // пустая клетка (край пятна)
	}
	// Цвет клетки — гладкий шум (другой масштаб/оффсет) → соседи близки, ПЛАВНЫЙ переход.
	float cn = vnoise(cell * 0.35 + vec2(seed * 0.71 + 10.0, seed * 0.53 + 20.0));
	vec3 col = palette(cn);
	// Активность по ходу анимации: МНОГО в начале, ЕЩЁ больше в середине, к концу все гаснут.
	// A растёт 0.6→1.0 к середине, потом 1.0→0. Карточка со своим «рангом» ct появляется/
	// исчезает по мере роста/спада A → часть гаснет раньше, часть позже (постепенно).
	float A = (progress < 0.5) ? mix(0.6, 1.0, progress / 0.5) : mix(1.0, 0.0, (progress - 0.5) / 0.5);
	float ct = fract(seed * 0.371 + 0.13);
	float vis = clamp((A - ct) / 0.12, 0.0, 1.0);
	float flick = 0.6 + 0.4 * h1(floor(TIME * flicker_speed));
	float a = vis * flick;
	if (a < 0.04) {
		discard;
	}
	ALBEDO   = col;
	EMISSION = col * 2.0;
	ALPHA    = a;
}
