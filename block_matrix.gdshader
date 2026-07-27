shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always;

// Эффект на блоке — три режима (см. block_fx.gd):
//   mode 0 — ПОЯВЛЕНИЕ: блок «собирается» из сине-фиолетового ГЛИТЧА снизу вверх. Глитч
//            РАЗНОМАСШТАБНЫЙ — пятна разного размера (не одинаковые квадраты), cyan/magenta.
//   mode 1 — ИСЧЕЗНОВЕНИЕ: тот же разномасштабный глитч мерцает/съезжает полосами и гаснет.
//   mode 2 — ДАМАГ: КАК РАНЬШЕ — короткая вспышка красных 0/1 (цифры) на грани.
// Триплан в ЛОКАЛЬНЫХ осях коробки — едет и вращается вместе с блоком.

uniform int   mode = 0;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec3  glitch_a : source_color = vec3(0.15, 0.85, 1.0);   // cyan
uniform vec3  glitch_b : source_color = vec3(0.72, 0.16, 1.0);   // magenta
uniform vec3  color_damage : source_color = vec3(1.0, 0.12, 0.12); // красный (урон, цифры)
// Глитч появления/исчезновения — «пятна разного размера»: регион выбирает крупный/средний/мелкий
// размер пикселя. cells_* — сколько пикселей на метр для трёх размеров.
uniform float cells_coarse = 3.0;
uniform float cells_mid    = 6.0;
uniform float cells_fine   = 10.0;
uniform float region_freq  = 1.6;    // как часто меняется размер (регионов на метр)
uniform float damage_cells = 8.0;    // плотность цифр урона (mode 2)
uniform float flip_speed = 8.0;
uniform float glow_mul = 1.6;
uniform float seed = 0.0;

varying vec3  v_local;
varying vec3  v_lnorm;
varying float v_h;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Цвет глитч-пикселя: cyan / magenta / тёмный «бит».
vec3 glitch_color(vec2 cell, float tt) {
	float n = hash(cell + vec2(tt * 1.7, tt * 0.9));
	if (n < 0.42) return glitch_a;
	if (n < 0.84) return glitch_b;
	return vec3(0.02, 0.02, 0.05);
}

// Размер «пикселя» глитча РАЗНЫЙ по регионам (3 размера) → не одинаковые квадраты.
float region_cpm(vec2 uv) {
	vec2 reg = floor(uv * region_freq);
	float s = floor(hash(reg + vec2(9.0)) * 3.0);      // 0 / 1 / 2
	if (s < 0.5) return cells_coarse;
	if (s < 1.5) return cells_mid;
	return cells_fine;
}

// Цифра 0/1 в ячейке (для урона).
float glyph(vec2 uv, float bit) {
	vec2 d = abs(uv - 0.5);
	if (bit > 0.5) {
		return step(d.x, 0.11) * step(d.y, 0.34);
	}
	float outer = step(d.x, 0.25) * step(d.y, 0.34);
	float inner = step(d.x, 0.13) * step(d.y, 0.20);
	return clamp(outer - inner, 0.0, 1.0);
}

void vertex() {
	vec3 box_scale = vec3(length(MODEL_MATRIX[0].xyz),
			length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	v_local = VERTEX * box_scale;
	v_lnorm = NORMAL;
	v_h = VERTEX.y + 0.5;
}

void fragment() {
	vec3 an = abs(v_lnorm);
	vec2 uv;
	if (an.x >= an.y && an.x >= an.z)      uv = v_local.zy;
	else if (an.y >= an.z)                 uv = v_local.xz;
	else                                   uv = v_local.xy;
	uv += seed;

	float tt = floor(TIME * flip_speed);

	if (mode == 0) {
		// ПОЯВЛЕНИЕ: разномасштабный глитч «загружается» снизу вверх, яркий фронт волны.
		float cpm = region_cpm(uv);
		vec2 cell = floor(uv * cpm);
		float body = step(v_h, progress);
		float wave = smoothstep(0.12, 0.0, abs(v_h - progress));
		float lit  = step(0.22, hash(cell + vec2(3.0)));
		vec3  g    = glitch_color(cell, tt);
		float on   = max(body * lit, wave);
		float flick = 0.8 + 0.2 * hash(vec2(floor(TIME * 20.0), cell.y));
		ALBEDO = g * on * flick * (glow_mul + wave * 2.5);
		ALPHA  = 1.0;
	} else if (mode == 1) {
		// ИСЧЕЗНОВЕНИЕ: разномасштабный глитч, полосы съезжают по X, гаснет.
		float cpm = region_cpm(uv);
		float band = floor(uv.y * 12.0);
		float gg = hash(vec2(band, floor(TIME * 11.0)));
		float shift = gg > 0.80 ? (gg - 0.4) * 3.5 : 0.0;
		vec2 cell = floor(vec2(uv.x * cpm + shift, uv.y * cpm));
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
		// ДАМАГ (как раньше): разреженная вспышка КРАСНЫХ цифр 0/1.
		vec2 grid = uv * damage_cells;
		vec2 cell = floor(grid);
		vec2 fpart = fract(grid);
		float bit  = step(0.5, hash(cell + vec2(tt * 1.7, tt * 0.3)));
		float gl   = glyph(fpart, bit);
		float lit   = step(hash(cell + vec2(2.0, 2.6)), 0.16);
		float phase = fract(TIME * 2.2 + hash(cell + vec2(4.2, 5.0)) * 11.0);
		float pop   = smoothstep(0.0, 0.15, phase) * smoothstep(1.0, 0.6, phase);
		float glow2 = gl * lit * pop;
		float fade2 = clamp(1.0 - progress, 0.0, 1.0);
		float a2 = fade2 * glow2 * 1.8;
		if (a2 < 0.02) {
			discard;
		} else {
			ALBEDO = color_damage * (glow2 * 2.2 + 0.2);
			ALPHA  = clamp(a2, 0.0, 1.0);
		}
	}
}
