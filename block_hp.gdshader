shader_type spatial;
render_mode cull_back, unshaded;
// Постоянный оверлей ХП на блоке (block_fx.hp_overlay): разреженные красные всплывающие 0/1,
// густота/яркость = УРОН (damage 0..1 = 1−hp/max). У смерти — гуще и мерцает.
// Отдельный от block_matrix шейдер намеренно:
//   • НЕ пишем глубину (режим глубины по умолчанию = только opaque-препасс, а материал
//     прозрачный) — иначе постоянный оверлей писал бы «ореол» глубины на ~0.05 м вокруг
//     блока: соседние побитые блоки мерцали бы на стыках, а прочие прозрачные FX (луч
//     лазера, глоу) отсекались бы, проходя рядом;
//   • cull_back (куб замкнут) — вдвое меньше фрагментов, чем cull_disabled у block_matrix
//     (тому нужны обе стороны для тонких пластин вспышки).
// Анимация идёт от TIME; GDScript пишет только `damage` при изменении хп (не по кадрам).
// Триплан в ЛОКАЛЬНЫХ осях куба — сетка едет и вращается вместе с блоком.

uniform float damage : hint_range(0.0, 1.0) = 0.0;        // доля потерянного хп
uniform vec3  color_hp : source_color = vec3(1.0, 0.12, 0.12);
uniform float cells_per_meter = 6.0;                      // покрупнее цифры — читаемо как «хп»
uniform float flip_speed = 7.0;                           // как часто цифры меняются 0<->1
uniform float seed = 0.0;                                 // разный узор у разных блоков

varying vec3 v_local;      // позиция в метрах в осях коробки (= осях блока)
varying vec3 v_lnorm;      // локальная нормаль (у BoxMesh строго по осям)

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
// каждая появляется-гаснет по своему таймеру — образ «всплыло несколько цифр».
float sparse(vec2 cell, float gl, float density, float salt, float pop_speed) {
	float lit   = step(hash(cell + vec2(salt, salt * 1.3)), density);
	float phase = fract(TIME * pop_speed + hash(cell + vec2(salt * 2.1, 5.0)) * 11.0);
	float pop   = smoothstep(0.0, 0.15, phase) * smoothstep(1.0, 0.6, phase);
	return gl * lit * pop;
}

void vertex() {
	vec3 box_scale = vec3(length(MODEL_MATRIX[0].xyz),
			length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	v_local = VERTEX * box_scale;
	v_lnorm = NORMAL;
}

void fragment() {
	vec3 an = abs(v_lnorm);
	vec2 uv;
	if (an.x >= an.y && an.x >= an.z)      uv = v_local.zy;
	else if (an.y >= an.z)                 uv = v_local.xz;
	else                                   uv = v_local.xy;
	uv += seed;

	vec2 grid = uv * cells_per_meter;
	vec2 cell = floor(grid);
	vec2 f    = fract(grid);

	float tstep = floor(TIME * flip_speed);
	float bit   = step(0.5, hash(cell + vec2(tstep * 1.7, tstep * 0.3)));
	float gl    = glyph(f, bit);

	float density = 0.03 + damage * 0.30;                 // доля «живых» ячеек растёт с уроном
	float glow = sparse(cell, gl, density, 3.0, 1.3);
	glow *= 0.6 + 0.4 * sin(TIME * 16.0 + cell.x * 2.0 + cell.y * 1.7);   // лёгкое мерцание
	glow *= step(0.005, damage);                          // самоочистка: при damage≈0 пусто
	float a = clamp(glow * (0.7 + damage * 0.6), 0.0, 1.0);
	if (a < 0.02) {
		discard;
	} else {
		ALBEDO = color_hp * (0.9 + damage * 1.6);
		ALPHA  = a;
	}
}
