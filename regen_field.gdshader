shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

// ПОЛЕ РЕМОНТА: КОД, ЛЕТАЮЩИЙ ПО ОРБИТЕ ВОКРУГ БЛОКА.
//
// Было ровной зелёной сферой на фиксированной альфе. Она честно показывала радиус и больше
// ничего: по ней нельзя было понять, работает поле сейчас или просто висит.
//
// ЧАСТИЦ В ПРОЕКТЕ НЕТ И НЕ БУДЕТ (правило 11), поэтому код рисуется ТЕМ ЖЕ МЕШЕМ, что и раньше:
// ни одного нового узла, ни одного лишнего вызова отрисовки.
//
// КОД ЛЕТАЕТ ПО ОРБИТЕ, а не поднимается вверх. Сфера разбита на широтные кольца; горят не все,
// а редкие, и каждое горящее кольцо ВРАЩАЕТСЯ вокруг блока со своей скоростью и в свою сторону.
// Снаружи это читается как несколько потоков кода, облетающих деталь, — при том что меш стоит
// на месте и вращать нечего.
//
// РЕДКО И НЕРОВНО. Если зажечь все кольца и все клетки в них, выйдет зелёная стена: узор обязан
// быть разрежённым, иначе он снова превращается в заливку, от которой уходили.
//
// Край ярче середины (френель), как у купола щита: так сфера читается оболочкой, а не шаром, и
// не закрывает собой машину, которую чинит.

uniform vec3  tint : source_color = vec3(0.25, 1.0, 0.45);
uniform float cells = 18.0;                          // клеток по высоте сферы
uniform float density : hint_range(0.0, 1.0) = 0.22; // доля горящих клеток внутри кольца
uniform float rings_lit : hint_range(0.0, 1.0) = 0.34;  // доля колец, которые вообще горят
uniform float speed = 0.22;                          // базовая скорость облёта
uniform float rim_pow : hint_range(0.5, 8.0) = 3.0;
uniform float rim_gain : hint_range(0.0, 2.0) = 0.5;
uniform float active : hint_range(0.0, 1.0) = 1.0;   // поле чинит прямо сейчас

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Те же нуль и единица, которыми говорит урон на блоках (block_matrix.glyph).
float glyph(vec2 uv, float bit) {
	vec2 d = abs(uv - 0.5);
	if (bit > 0.5) {
		return step(d.x, 0.11) * step(d.y, 0.34);
	}
	float outer = step(d.x, 0.25) * step(d.y, 0.34);
	float inner = step(d.x, 0.13) * step(d.y, 0.20);
	return clamp(outer - inner, 0.0, 1.0);
}

void fragment() {
	// Широта выравнивает горизонтальный шаг: без неё клетки сходятся в иглы на полюсах.
	float lat = max(sin(UV.y * 3.14159265), 0.10);

	// Номер кольца — по широте. Он же решает, горит ли кольцо и как оно летит.
	float row = floor(UV.y * cells);
	float rh = hash(vec2(row, 7.0));
	float ring_on = step(rh, rings_lit);
	// Своя скорость и своя сторона у каждого кольца: одинаковые превратили бы всё в одну
	// вращающуюся текстуру, а нужно ощущение нескольких независимых потоков.
	float dir = rh < 0.5 ? -1.0 : 1.0;
	float rate = speed * (0.55 + 1.9 * hash(vec2(row, 19.0))) * dir;

	// ОБЛЁТ: со временем сдвигается долгота, широта стоит. Меш при этом неподвижен.
	float u = UV.x + TIME * rate;
	vec2 g = vec2(u * cells * lat * 2.0, UV.y * cells);
	vec2 id = floor(g);
	vec2 fpart = fract(g);

	float lit = ring_on * step(hash(id + vec2(0.0, rh * 13.0)), density);

	// Символ перещёлкивается 0↔1, но не каждый кадр: строка должна успеть прочитаться.
	float bit = step(0.5, hash(id + vec2(floor(TIME * 3.0 + rh * 10.0), 11.0)));
	float gl = glyph(fpart, bit);

	// Полюса гасим: там кольца вырождаются в точку и код сбивался бы в комок на макушке.
	float fade = smoothstep(0.03, 0.22, UV.y) * smoothstep(0.97, 0.78, UV.y);

	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_pow);

	float a = (gl * lit * fade * 0.9 + fres * rim_gain) * active;
	ALBEDO   = tint;
	EMISSION = tint * (gl * lit * fade * 1.6 + fres * rim_gain) * active;
	ALPHA    = clamp(a, 0.0, 1.0);
}
