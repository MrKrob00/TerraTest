shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

// «Глитч-патч»: плоский БИЛБОРД (лицом к камере), на нём СЕТКА grid_cells×grid_cells клеток,
// заполнена СВЯЗНЫМ случайным пятном (без разрывов) — соседние клетки коррелированы через
// гладкий шум, поэтому «единицы» слипаются в цельную фигуру, а не разбросаны. Разные патчи
// имеют разный размер сетки (4×4 / 6×6), цвет (cyan/magenta), пульсируют, гаснут к концу.
// Много таких патчей на разной глубине/размере = объёмный глитч вокруг блока (BlockFX.play).

uniform vec3  card_color : source_color = vec3(0.15, 0.85, 1.0);
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;
uniform float grid_cells = 4.0;          // 4×4 или 6×6 (задаёт BlockFX на карточку)
uniform float fill_threshold = 0.5;      // выше = меньше заполнено
uniform float flicker_speed = 12.0;

float h1(float n) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }

float h2(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Гладкий value-noise: соседние точки близки → порог даёт СВЯЗНЫЕ пятна (без разрывов).
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

void vertex() {
	// Билборд: убираем поворот модели, оставляем позицию и масштаб (квад лицом к камере).
	mat4 m = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(length(m[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(m[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(m[2].xyz), 0.0),
			m[3]);
}

void fragment() {
	vec2 g = UV * grid_cells;
	vec2 cell = floor(g);
	vec2 f = fract(g);
	// Связное заполнение: гладкий шум по клеткам (масштаб < 1/клетка → соседи слипаются).
	float n = vnoise(cell * 0.5 + vec2(seed * 0.13, seed * 0.29));
	if (n < fill_threshold) {
		discard;                          // пустая клетка (но пятно связное — шум гладкий)
	}
	// Тонкий зазор между «пикселями», чтобы читались отдельные квадраты.
	float gap = step(0.08, f.x) * step(0.08, 1.0 - f.x) * step(0.08, f.y) * step(0.08, 1.0 - f.y);
	if (gap < 0.5) {
		discard;
	}
	// Пульсация (патч мерцает, но не пропадает целиком) + затухание к концу анимации.
	float flick = 0.55 + 0.45 * h1(floor(TIME * flicker_speed));
	float a = (1.0 - progress) * flick;
	if (a < 0.04) {
		discard;
	}
	ALBEDO   = card_color;
	EMISSION = card_color * 2.0;
	ALPHA    = a;
}
