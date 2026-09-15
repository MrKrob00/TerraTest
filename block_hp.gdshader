shader_type spatial;
render_mode cull_back, unshaded;
// ПОВРЕЖДЕНИЕ БЛОКА ЦИФРАМИ 0/1, а не «перелив, показывающий хп».
//
// Правило одно: МЕСТО ЦИФРЫ НА БЛОКЕ НЕ ДВИЖЕТСЯ. Клетка либо повреждена, либо нет — это решает
// её собственный хеш против текущего урона, и он не зависит ни от времени, ни от того, сколько
// урона было раньше. Поэтому новый удар ДОБАВЛЯЕТ цифры к тем, что уже горят, а не перетасовывает
// всё заново. Меняется в клетке ровно одно — сам символ, 0 ↔ 1.
//
// Починка показывается ТЕМИ ЖЕ ЦИФРАМИ: клетки, которые перестали быть повреждёнными, зеленеют и
// гаснут за heal_fade секунд. Отдельного зелёного эффекта поверх блока нет — он рисовал бы то же
// самое второй раз и не говорил бы, ЧТО именно починили.
//
// Отдельный от block_matrix шейдер намеренно:
//   • НЕ пишем глубину (материал прозрачный) — иначе постоянный оверлей писал бы «ореол» глубины
//     вокруг блока: соседние побитые блоки мерцали бы на стыках, а прозрачные FX (луч лазера,
//     глоу) отсекались бы, проходя рядом;
//   • cull_back (куб замкнут) — вдвое меньше фрагментов, чем cull_disabled у block_matrix.
// Анимация идёт от TIME; GDScript пишет юниформы только при изменении хп (не по кадрам).
// Триплан в ЛОКАЛЬНЫХ осях куба — сетка едет и вращается вместе с блоком.

uniform float damage : hint_range(0.0, 1.0) = 0.0;        // доля потерянного хп СЕЙЧАС
/// Доля потерянного хп ДО починки. Клетки между damage и heal_from — это то, что только что
/// починили: они горят зелёным и гаснут. Равно damage — зелёного нет.
uniform float heal_from : hint_range(0.0, 1.0) = 0.0;
uniform float heal_age = 999.0;                           // секунд с момента починки (гонит твин)
uniform float heal_fade = 1.4;
uniform vec3  color_hp : source_color = vec3(1.0, 0.12, 0.12);
uniform vec3  color_heal : source_color = vec3(0.25, 1.0, 0.45);
uniform float cells_per_meter = 6.0;                      // покрупнее цифры — читаемо как «хп»
uniform float flip_speed = 7.0;                           // как часто цифры меняются 0<->1
/// Доля клеток, горящих при ПОЛНОСТЬЮ разбитом блоке. Единица означала бы сплошную красную
/// коробку — блока под ней не видно, а цифры перестают читаться как цифры.
uniform float max_density : hint_range(0.1, 1.0) = 0.55;
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

	// Порог клетки — её собственное число, одно на всю жизнь блока. Отсюда и берётся то, что
	// цифры не перескакивают с места на место, когда урона становится больше.
	float r = hash(cell + vec2(7.3, 1.9));
	float hurt_lvl = damage * max_density;
	float heal_lvl = heal_from * max_density;
	float heal_k = clamp(1.0 - heal_age / heal_fade, 0.0, 1.0);

	bool lit = r < hurt_lvl;
	bool healed = !lit && r < heal_lvl && heal_k > 0.0;
	if (!lit && !healed) {
		discard;
	}

	float tstep = floor(TIME * flip_speed);
	float bit = step(0.5, hash(cell + vec2(tstep * 1.7, tstep * 0.3)));
	if (glyph(f, bit) < 0.5) {
		discard;
	}

	// Разнояркость по клеткам — иначе сетка читается как текстура, а не как россыпь символов.
	float var_k = 0.72 + 0.28 * hash(cell + vec2(3.1, 8.7));
	ALBEDO = (lit ? color_hp : color_heal) * (1.4 * var_k);
	ALPHA  = var_k * (lit ? 0.9 : heal_k);
}
