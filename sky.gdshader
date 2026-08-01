shader_type sky;

// Дешёвое стилизованное небо для мобилки (gl_compatibility, Adreno 610 — упор в филлрейт).
// Всё — простая арифметика: вертикальный градиент + диск/гало солнца + лёгкие облака в 2 октавы
// value-noise (без текстур, только над горизонтом). Никаких циклов и рейамарша. Все цвета/параметры
// вынесены в uniform — можно крутить в инспекторе материала. cloud_amount = 0 полностью гасит облака.

// ── Небо ──
uniform vec3 zenith_color   : source_color = vec3(0.16, 0.33, 0.62);   // зенит (верх)
uniform vec3 horizon_color  : source_color = vec3(0.66, 0.80, 0.93);   // у горизонта
uniform vec3 ground_color   : source_color = vec3(0.40, 0.42, 0.48);   // ниже горизонта (дымка)
uniform float horizon_falloff : hint_range(1.0, 12.0) = 4.0;           // резкость перехода к зениту

// ── Солнце (берётся из DirectionalLight сцены) ──
uniform vec3 sun_color : source_color = vec3(1.0, 0.94, 0.80);
uniform float sun_radius : hint_range(0.0005, 0.05) = 0.006;           // угловой радиус диска
uniform float sun_glow   : hint_range(2.0, 300.0) = 60.0;              // мягкость гало (больше = уже)
uniform float sun_glow_strength : hint_range(0.0, 1.0) = 0.5;

// ── Облака (2 октавы дешёвого value-noise) ──
uniform float cloud_amount : hint_range(0.0, 1.0) = 0.45;              // 0 = выключить облака совсем
uniform float cloud_scale  : hint_range(0.3, 4.0) = 1.2;
uniform float cloud_speed  : hint_range(0.0, 0.1) = 0.008;
uniform vec3  cloud_color  : source_color = vec3(1.0, 1.0, 1.0);

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);                 // smoothstep-интерполяция
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void sky() {
	vec3 dir = EYEDIR;
	float up = dir.y;

	// Вертикальный градиент: земля → горизонт → зенит.
	float t = pow(clamp(up, 0.0, 1.0), 1.0 / horizon_falloff);
	vec3 col = mix(horizon_color, zenith_color, t);
	col = mix(col, ground_color, clamp(-up * 5.0, 0.0, 1.0));

	// Облака — только над горизонтом, с затуханием к нему. Планарная проекция направления неба.
	if (cloud_amount > 0.001 && up > 0.01) {
		vec2 uv = (dir.xz / max(up, 0.12)) * cloud_scale + vec2(TIME * cloud_speed);
		float n = vnoise(uv) * 0.65 + vnoise(uv * 2.7 + vec2(5.0)) * 0.35;
		float cover = smoothstep(0.5, 0.8, n) * cloud_amount;
		cover *= smoothstep(0.01, 0.3, up);      // у самого горизонта облаков нет
		col = mix(col, cloud_color, cover * 0.9);
	}

	// Солнце: мягкое гало + яркий диск.
	if (LIGHT0_ENABLED) {
		vec3 sun = normalize(-LIGHT0_DIRECTION);
		float d = dot(dir, sun);
		col += sun_color * pow(max(d, 0.0), sun_glow) * sun_glow_strength;
		float disk = smoothstep(1.0 - sun_radius, 1.0 - sun_radius * 0.4, d);
		col = mix(col, sun_color * (1.0 + LIGHT0_ENERGY * 0.4), disk);
	}

	COLOR = col;
}
