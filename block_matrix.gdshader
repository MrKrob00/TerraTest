shader_type spatial;
render_mode blend_add, cull_disabled, unshaded, depth_draw_never;

// «Матрица» для появления/уничтожения блока: сетка зелёных (спавн) или красных (глюк,
// уничтожение) цифр 0/1 по ВСЕМ сторонам (триплан по мировым координатам, ~8 цифр на метр),
// плавная волна-фронт снизу вверх (спавн) или сверху вниз (растворение). Рисуется на
// коробке-оболочке чуть больше блока (см. block_fx.gd), сам блок под ней виден как есть.

uniform int   mode = 0;                                   // 0 = спавн (зелёный), 1 = уничтожение (красный+глюк)
uniform float progress : hint_range(0.0, 1.0) = 0.0;      // 0..1 ход анимации
uniform vec3  color_spawn   : source_color = vec3(0.15, 1.0, 0.35);
uniform vec3  color_destroy : source_color = vec3(1.0, 0.12, 0.12);
uniform float cells_per_meter = 8.0;                      // плотность цифр в мире
uniform float flip_speed = 7.0;                           // как часто цифры меняются 0<->1

varying vec3  v_world;
varying vec3  v_wnorm;
varying float v_h;          // локальная высота 0..1 (для BoxMesh size=1 это VERTEX.y+0.5)

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Символ в ячейке: uv 0..1 по ячейке, bit=1 → «1» (палочка), 0 → «0» (рамка). Яркость 0..1.
float glyph(vec2 uv, float bit) {
	vec2 d = abs(uv - 0.5);
	if (bit > 0.5) {
		return step(d.x, 0.11) * step(d.y, 0.34);                      // «1»
	}
	float outer = step(d.x, 0.25) * step(d.y, 0.34);
	float inner = step(d.x, 0.13) * step(d.y, 0.20);
	return clamp(outer - inner, 0.0, 1.0);                             // «0»
}

void vertex() {
	vec4 wp = MODEL_MATRIX * vec4(VERTEX, 1.0);
	v_world = wp.xyz;
	v_wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_h = VERTEX.y + 0.5;
}

void fragment() {
	// Триплан: 2 координаты по доминирующей оси мировой нормали → одинаковая сетка на всех гранях.
	vec3 an = abs(v_wnorm);
	vec2 uv;
	if (an.x >= an.y && an.x >= an.z)      uv = v_world.zy;
	else if (an.y >= an.z)                 uv = v_world.xz;
	else                                   uv = v_world.xy;

	vec2 grid = uv * cells_per_meter;

	// Глюк при уничтожении: случайные горизонтальные полосы съезжают по X + рвётся яркость.
	float glitch_amp = 0.0;
	if (mode == 1) {
		float band = floor(uv.y * 16.0);
		float g = hash(vec2(band, floor(TIME * 11.0)));
		glitch_amp = g > 0.80 ? (g - 0.4) : 0.0;
		grid.x += glitch_amp * 3.5;
	}

	vec2 cell = floor(grid);
	vec2 f    = fract(grid);

	// Какая цифра стоит в ячейке — меняется во времени.
	float tstep = floor(TIME * flip_speed);
	float bit   = step(0.5, hash(cell + vec2(tstep * 1.7, tstep * 0.3)));
	float gl    = glyph(f, bit);

	// Фронт волны по локальной высоте. Спавн: снизу вверх, тело ниже фронта. Уничтожение:
	// фронт идёт сверху вниз, «съедая» блок.
	float edge = (mode == 0) ? progress : (1.0 - progress);
	float body = step(v_h, edge);
	float wave = smoothstep(0.07, 0.0, abs(v_h - edge));

	vec3 col = (mode == 0) ? color_spawn : color_destroy;

	// Альфа: цифры в теле + яркая линия на фронте. Плюс мерцание.
	float a = max(gl * body * 0.9, wave * (0.55 + gl * 0.45));
	a *= 0.82 + 0.18 * sin(TIME * 30.0 + cell.x * 1.3 + cell.y * 0.7);
	if (mode == 1) {
		a *= 0.55 + 0.45 * hash(vec2(floor(TIME * 22.0), cell.y));     // рваное мерцание глюка
		a += glitch_amp * gl * 0.5;
	}

	if (a < 0.02) discard;

	ALBEDO = col * (1.4 + wave * 3.5);   // на blend_add ярче = сильнее свечение (нужен glow в окружении)
	ALPHA  = clamp(a, 0.0, 1.0);
}
