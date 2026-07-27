shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always;

// ГЛИТЧ «битых данных» на блоке — сине-фиолетовые ЧАНКОВЫЕ пиксели (cyan/magenta/тёмный),
// мерцают и светятся (unshaded → цвет = свечение). Три режима (см. block_fx.gd):
//   mode 0 — ПОЯВЛЕНИЕ: блок «собирается» из глитч-пикселей СНИЗУ ВВЕРХ (по progress),
//            яркий фронт волны; между пикселями тёмный силуэт.
//   mode 1 — ИСЧЕЗНОВЕНИЕ: пиксели хаотично мерцают/съезжают полосами и гаснут (ALPHA→0).
//   mode 2 — ДАМАГ: короткая разреженная вспышка глитч-пикселей на грани (block_fx.hit).
// Триплан в ЛОКАЛЬНЫХ осях коробки — едет и вращается вместе с блоком.

uniform int   mode = 0;
uniform float progress : hint_range(0.0, 1.0) = 0.0;      // 0..1 ход анимации
uniform vec3  glitch_a : source_color = vec3(0.15, 0.85, 1.0);   // cyan
uniform vec3  glitch_b : source_color = vec3(0.72, 0.16, 1.0);   // magenta
uniform float cells_per_meter = 6.0;                     // размер «пикселя» глитча (чанковость)
uniform float flip_speed = 8.0;                          // частота мерцания цвета пикселя
uniform float glow_mul = 1.6;                            // сила свечения
uniform float seed = 0.0;                                // разный узор у разных блоков

varying vec3  v_local;      // позиция в метрах в осях коробки (= осях блока)
varying vec3  v_lnorm;      // локальная нормаль (у BoxMesh строго по осям)
varying float v_h;          // локальная высота 0..1

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Цвет глитч-пикселя: cyan / magenta / тёмный «бит». tt — временной шаг (мерцание).
vec3 glitch_color(vec2 cell, float tt) {
	float n = hash(cell + vec2(tt * 1.7, tt * 0.9));
	if (n < 0.42) return glitch_a;
	if (n < 0.84) return glitch_b;
	return vec3(0.02, 0.02, 0.05);
}

void vertex() {
	vec3 box_scale = vec3(length(MODEL_MATRIX[0].xyz),
			length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	v_local = VERTEX * box_scale;
	v_lnorm = NORMAL;
	v_h = VERTEX.y + 0.5;
}

void fragment() {
	// Триплан: 2 координаты по доминирующей оси ЛОКАЛЬНОЙ нормали → одинаковая сетка на всех гранях.
	vec3 an = abs(v_lnorm);
	vec2 uv;
	if (an.x >= an.y && an.x >= an.z)      uv = v_local.zy;
	else if (an.y >= an.z)                 uv = v_local.xz;
	else                                   uv = v_local.xy;
	uv += seed;

	vec2 grid = uv * cells_per_meter;
	float tt  = floor(TIME * flip_speed);

	if (mode == 0) {
		// ПОЯВЛЕНИЕ: пиксели «загружаются» снизу вверх (v_h ниже фронта progress — уже есть),
		// на фронте — яркая вспышка. Рваные клетки (не все горят).
		vec2 cell = floor(grid);
		float body = step(v_h, progress);
		float wave = smoothstep(0.12, 0.0, abs(v_h - progress));
		float lit  = step(0.22, hash(cell + vec2(3.0)));
		vec3  g    = glitch_color(cell, tt);
		float on   = max(body * lit, wave);
		float flick = 0.8 + 0.2 * hash(vec2(floor(TIME * 20.0), cell.y));
		ALBEDO = g * on * flick * (glow_mul + wave * 2.5);
		ALPHA  = 1.0;                       // непрозрачно: тёмный силуэт + глитч-пиксели
	} else if (mode == 1) {
		// ИСЧЕЗНОВЕНИЕ: полосы съезжают по X, клетки мерцают, всё гаснет (ALPHA→0).
		float band = floor(uv.y * 16.0);
		float gg = hash(vec2(band, floor(TIME * 11.0)));
		float shift = gg > 0.80 ? (gg - 0.4) * 3.5 : 0.0;
		vec2 cell = floor(vec2(grid.x + shift, grid.y));
		vec3 g = glitch_color(cell, tt);
		float on = step(0.5, hash(cell + vec2(floor(TIME * 9.0), 7.0)));
		float flicker = 0.5 + 0.5 * hash(vec2(floor(TIME * 22.0), cell.y));
		float glow = on * flicker;
		float fade = clamp(1.0 - progress, 0.0, 1.0);
		float a = fade * (0.3 + glow * 0.7);
		if (a < 0.02) {
			discard;
		} else {
			ALBEDO = g * (glow * glow_mul + 0.25);
			ALPHA  = clamp(a, 0.0, 1.0);
		}
	} else {
		// ДАМАГ: разреженная вспышка глитч-пикселей на пластине — всплыли и гаснут.
		vec2 cell = floor(grid);
		float lit   = step(hash(cell + vec2(2.0, 2.6)), 0.18);
		float phase = fract(TIME * 2.4 + hash(cell + vec2(4.2, 5.0)) * 11.0);
		float pop   = smoothstep(0.0, 0.15, phase) * smoothstep(1.0, 0.6, phase);
		float glow2 = lit * pop;
		vec3  g     = glitch_color(cell, tt);
		float fade2 = clamp(1.0 - progress, 0.0, 1.0);
		float a2 = fade2 * glow2 * 1.8;
		if (a2 < 0.02) {
			discard;
		} else {
			ALBEDO = g * (glow2 * glow_mul + 0.3);
			ALPHA  = clamp(a2, 0.0, 1.0);
		}
	}
}
