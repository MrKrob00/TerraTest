shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always;

uniform int   mode = 0;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec3  glitch_a : source_color = vec3(0.15, 0.85, 1.0);     // cyan (вайрфрейм)
uniform vec3  glitch_b : source_color = vec3(0.72, 0.16, 1.0);     // magenta (missing texture)
uniform vec3  color_damage : source_color = vec3(1.0, 0.12, 0.12); // красный (урон, цифры)
uniform float cells_per_meter = 5.0;                              // размер «текселя» разрендера
uniform float damage_cells = 8.0;                                // плотность цифр урона (mode 2)
uniform float flip_speed = 8.0;
uniform float glow_mul = 1.5;
uniform float seed = 0.0;

varying vec3  v_local;
varying vec3  v_lnorm;
varying float v_h;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec3 glitch_color(vec2 cell, float tt) {
	float n = hash(cell + vec2(tt * 1.7, tt * 0.9));
	if (n < 0.42) return glitch_a;
	if (n < 0.84) return glitch_b;
	return vec3(0.02, 0.02, 0.05);
}

// Вайрфрейм-сетка + missing-texture шахматка + мерцающий глитч. bright — усиление на линиях.
vec3 derender_col(vec2 uv, float tt, out float bright) {
	vec2 grid = uv * cells_per_meter;
	vec2 cell = floor(grid);
	vec2 f = fract(grid);
	float line = max(smoothstep(0.07, 0.0, min(f.x, 1.0 - f.x)),
			smoothstep(0.07, 0.0, min(f.y, 1.0 - f.y)));
	float checker = mod(cell.x + cell.y, 2.0);
	vec3 col = mix(vec3(0.02, 0.0, 0.05), glitch_b, checker * 0.6);   // missing texture (magenta/чёрный)
	col = mix(col, glitch_a, line);                                  // вайрфрейм (cyan линии)
	col = mix(col, glitch_color(cell, tt), 0.35);                    // лёгкий мерцающий глитч
	bright = 0.5 + line * 0.9;
	return col;
}

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
		// ПОЯВЛЕНИЕ: собирается снизу вверх. Ниже фронта — discard (настоящий блок виден).
		float front = smoothstep(0.09, 0.0, abs(v_h - progress));
		if (v_h < progress - 0.02 && front < 0.02) {
			discard;
		}
		float br;
		vec3 col = derender_col(uv, tt, br);
		ALBEDO = col * (br * glow_mul + front * 2.5);
		ALPHA  = 1.0;
	} else if (mode == 1) {
		// ИСЧЕЗНОВЕНИЕ: разрендер с выпадающими клетками, гаснет.
		float br;
		vec3 col = derender_col(uv, tt, br);
		float drop = step(0.3, hash(floor(uv * cells_per_meter) + vec2(floor(TIME * 10.0), 3.0)));
		float fade = clamp(1.0 - progress, 0.0, 1.0);
		float a = fade * (0.55 + drop * 0.45);
		if (a < 0.03) {
			discard;
		} else {
			ALBEDO = col * (br * glow_mul + 0.4);
			ALPHA  = clamp(a, 0.0, 1.0);
		}
	} else {
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
