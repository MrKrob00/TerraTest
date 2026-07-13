shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always;

// «Матрица» для появления/уничтожения блока: сетка зелёных (спавн) или красных (глюк,
// уничтожение) цифр 0/1 по ВСЕМ сторонам (триплан в ЛОКАЛЬНЫХ осях коробки, ~8 цифр на
// метр), плавная волна-фронт снизу вверх (спавн) или сверху вниз (растворение). Рисуется
// на коробке-оболочке чуть больше блока (см. block_fx.gd), она ориентирована ПО БЛОКУ —
// поэтому локальные координаты дают сетку, которая едет и ВРАЩАЕТСЯ вместе с блоком
// (мировые координаты «плыли» по граням при движении и не учитывали поворот).

uniform int   mode = 0;                                   // 0 = спавн (зелёный), 1 = уничтожение (красный+глюк)
uniform float progress : hint_range(0.0, 1.0) = 0.0;      // 0..1 ход анимации
uniform vec3  color_spawn   : source_color = vec3(0.15, 1.0, 0.35);
uniform vec3  color_destroy : source_color = vec3(1.0, 0.12, 0.12);
uniform float cells_per_meter = 8.0;                      // плотность цифр (на метр)
uniform float flip_speed = 7.0;                           // как часто цифры меняются 0<->1
uniform float seed = 0.0;                                 // разный узор у разных блоков

varying vec3  v_local;      // позиция в метрах в осях коробки (= осях блока)
varying vec3  v_lnorm;      // локальная нормаль (у BoxMesh строго по осям)
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
	// Масштаб коробки достаём из колонок MODEL_MATRIX: VERTEX единичного BoxMesh (−0.5..0.5)
	// умножаем на него, чтобы cells_per_meter остался «на метр» реального размера блока.
	vec3 box_scale = vec3(length(MODEL_MATRIX[0].xyz),
			length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	v_local = VERTEX * box_scale;
	v_lnorm = NORMAL;
	v_h = VERTEX.y + 0.5;
}

void fragment() {
	// Триплан: 2 координаты по доминирующей оси ЛОКАЛЬНОЙ нормали → одинаковая сетка на всех
	// гранях, прибитая к блоку (едет и вращается с ним).
	vec3 an = abs(v_lnorm);
	vec2 uv;
	if (an.x >= an.y && an.x >= an.z)      uv = v_local.zy;
	else if (an.y >= an.z)                 uv = v_local.xz;
	else                                   uv = v_local.xy;
	uv += seed;

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

	// Прогресс теперь в ДВЕ ПОСЛЕДОВАТЕЛЬНЫЕ фазы (по половине хода каждая):
	//  • фаза 1 (0..0.5): волна закрашивает блок в сплошной чёрный, ЦИФР ЕЩЁ НЕТ;
	//  • фаза 2 (0.5..1): вторая волна проявляет светящиеся цифры УЖЕ НА чёрном.
	// Спавн — снизу вверх, уничтожение — сверху вниз (обе фазы, как и раньше).
	float black_t = clamp(progress * 2.0, 0.0, 1.0);
	float digit_t = clamp(progress * 2.0 - 1.0, 0.0, 1.0);

	float black_edge = (mode == 0) ? black_t : (1.0 - black_t);
	float black_body = step(v_h, black_edge);
	float black_wave = smoothstep(0.07, 0.0, abs(v_h - black_edge));

	// Фаза 1 ещё не дошла (или уже прошла, для уничтожения) — тут ничего не рисуем,
	// настоящий блок виден как есть.
	if (black_body < 0.5 && black_wave < 0.02) discard;

	// Волна цифр идёт ТОЛЬКО там, где чернота уже легла (black_body) — иначе на
	// уничтожении цифры обгоняли бы черноту и светились бы там, где блок ещё цел.
	float digit_edge = (mode == 0) ? digit_t : (1.0 - digit_t);
	float digit_body = step(v_h, digit_edge) * black_body;
	float digit_wave = smoothstep(0.07, 0.0, abs(v_h - digit_edge)) * black_body;

	vec3 col = (mode == 0) ? color_spawn : color_destroy;

	// Яркость цифр/фронта — множитель поверх чёрного фона (фон = ALPHA 1, ALBEDO 0).
	float glow = max(gl * digit_body * 0.9, digit_wave * (0.55 + gl * 0.45));
	glow *= 0.82 + 0.18 * sin(TIME * 30.0 + cell.x * 1.3 + cell.y * 0.7);
	if (mode == 1) {
		glow *= 0.55 + 0.45 * hash(vec2(floor(TIME * 22.0), cell.y));     // рваное мерцание глюка
		glow += glitch_amp * gl * digit_body * 0.5;
	}
	glow = clamp(glow, 0.0, 1.0);

	// Пока идёт фаза 1 (цифры ещё не начались) — тонкая подсветка на фронте закраски,
	// чтобы граница «заливки» не выглядела сухой линией.
	float paint_glow = black_wave * step(digit_t, 0.001) * 0.4;

	ALBEDO = col * (glow * (1.4 + digit_wave * 3.5) + paint_glow);
	ALPHA  = 1.0;                                 // непрозрачно: фон чёрный, не сквозной
}
