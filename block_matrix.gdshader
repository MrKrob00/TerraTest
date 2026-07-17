shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always;

// «Матрица» на блоке — три независимых режима (см. block_fx.gd):
//   mode 0 — СПАВН: блок МГНОВЕННО (в первый же момент) становится сплошным чёрным
//            силуэтом, дальше ПОСТЕПЕННО (весь ход анимации) по нему снизу вверх
//            проступают светящиеся зелёные 0/1 — «загрузка» блока.
//   mode 1 — УНИЧТОЖЕНИЕ: просто ГЛЮК — хаотично мерцающие красные 0/1 по всей
//            поверхности (без чёрного фона и волны-фронта), гаснущие к концу.
//   mode 2 — ДАМАГ: короткая вспышка ~нескольких красных 0/1 (не сплошная сетка) на
//            маленькой пластине (одна грань блока, см. block_fx.hit) — всплыли и гаснут.
// ПОСТОЯННЫЙ показ хп вынесен в отдельный block_hp.gdshader (у него свой режим глубины,
// чтобы прозрачный оверлей не писал глубину и не мерцал на стыках блоков).
// Триплан в ЛОКАЛЬНЫХ осях коробки/пластины — едет и вращается вместе с блоком.

uniform int   mode = 0;
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

// Разреженные «всплывающие» цифры: горит лишь случайное подмножество ячеек (density),
// и каждая появляется-гаснет по своему таймеру — образ «всплыло несколько цифр», а не
// сплошная сетка. Возвращает яркость 0..1 для ячейки cell с уже посчитанным глифом gl.
float sparse(vec2 cell, float gl, float density, float salt, float pop_speed) {
	float lit   = step(hash(cell + vec2(salt, salt * 1.3)), density);
	float phase = fract(TIME * pop_speed + hash(cell + vec2(salt * 2.1, 5.0)) * 11.0);
	float pop   = smoothstep(0.0, 0.15, phase) * smoothstep(1.0, 0.6, phase);
	return gl * lit * pop;
}

void vertex() {
	// Масштаб коробки/пластины достаём из колонок MODEL_MATRIX: VERTEX единичного
	// BoxMesh (−0.5..0.5) умножаем на него, чтобы cells_per_meter остался «на метр».
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
	vec2 cell = floor(grid);
	vec2 f    = fract(grid);

	// Какая цифра стоит в ячейке — меняется во времени.
	float tstep = floor(TIME * flip_speed);
	float bit   = step(0.5, hash(cell + vec2(tstep * 1.7, tstep * 0.3)));
	float gl    = glyph(f, bit);

	// Godot-шейдер НЕ поддерживает ранний return в fragment() — три режима строго через
	// if / else if / else (взаимоисключающие, без проваливания).
	if (mode == 0) {
		// СПАВН: чёрный фон — ВСЕГДА (мгновенно, без волны). Волна цифр идёт по всему
		// ходу анимации (progress 0..1), снизу вверх.
		float digit_body = step(v_h, progress);
		float digit_wave = smoothstep(0.07, 0.0, abs(v_h - progress));

		float glow = max(gl * digit_body * 0.9, digit_wave * (0.55 + gl * 0.45));
		glow *= 0.82 + 0.18 * sin(TIME * 30.0 + cell.x * 1.3 + cell.y * 0.7);
		glow = clamp(glow, 0.0, 1.0);

		ALBEDO = color_spawn * glow * (1.4 + digit_wave * 3.5);   // 0 между цифрами → чёрный фон
		ALPHA  = 1.0;                                             // непрозрачно, фон не сквозной
	} else if (mode == 1) {
		// УНИЧТОЖЕНИЕ: просто глюк — без чёрного фона и волны-фронта. Полосы съезжают по X,
		// ячейки мерцают/то пропадают, всё вместе гаснет к концу анимации (ALPHA → 0).
		float band = floor(uv.y * 16.0);
		float g = hash(vec2(band, floor(TIME * 11.0)));
		float glitch_amp = g > 0.80 ? (g - 0.4) : 0.0;
		vec2 gcell = floor(vec2(grid.x + glitch_amp * 3.5, grid.y));
		vec2 gf    = fract(vec2(grid.x + glitch_amp * 3.5, grid.y));
		float gbit = step(0.5, hash(gcell + vec2(tstep * 1.7, tstep * 0.3)));
		float ggl  = glyph(gf, gbit);

		float cell_on  = step(0.5, hash(gcell + vec2(floor(TIME * 9.0), 7.0)));   // ячейки то есть, то нет
		float flicker  = 0.5 + 0.5 * hash(vec2(floor(TIME * 22.0), gcell.y));
		float glow     = ggl * cell_on * flicker;

		float fade = clamp(1.0 - progress, 0.0, 1.0);
		float a = fade * (0.35 + glow * 0.65 + glitch_amp * 0.3);
		if (a < 0.02) {
			discard;
		} else {
			ALBEDO = color_destroy * (glow * 2.2 + glitch_amp * 0.6);
			ALPHA  = clamp(a, 0.0, 1.0);
		}
	} else {
		// mode == 2 — ДАМАГ: короткая вспышка НЕСКОЛЬКИХ (не сплошной сетки) красных 0/1 на
		// пластине — всплыли и гаснут (см. block_fx.hit). Разреженный набор + затухание.
		float glow2 = sparse(cell, gl, 0.16, 2.0, 2.2);
		glow2 *= 0.7 + 0.3 * sin(TIME * 40.0 + cell.x + cell.y);
		float fade2 = clamp(1.0 - progress, 0.0, 1.0);
		float a2 = fade2 * glow2 * 1.6;
		if (a2 < 0.02) {
			discard;
		} else {
			ALBEDO = color_destroy * (glow2 * 2.2 + 0.3);
			ALPHA  = clamp(a2, 0.0, 1.0);
		}
	}
}
