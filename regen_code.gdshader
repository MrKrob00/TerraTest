shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

// ПОЛЕ РЕМОНТА: ЦИФРЫ, ЛЕТАЮЩИЕ ВНУТРИ ОБЪЁМА ВОКРУГ БЛОКА.
//
// Раньше это была СФЕРА, а цифры рисовались по её поверхности. Отсюда и «это не оболочка
// шара»: узор на оболочке всегда остаётся узором на оболочке, сколько его ни двигай — внутрь
// объёма он не попадёт никак. Летать внутри может только то, что там и находится.
//
// Частиц в проекте нет и не будет, поэтому цифры — это MultiMesh из карточек-билбордов: ОДИН
// узел, ОДИН вызов отрисовки на всё поле, и ни строчки пересчёта на кадре. Орбита каждой
// цифры считается здесь, из TIME и её собственных четырёх чисел (INSTANCE_CUSTOM), а на
// стороне игры лежат только эти числа, записанные один раз при создании.
//
// ЗАОДНО ЭТО ДЕШЕВЛЕ ПРЕЖНЕГО. Сфера радиусом 4.6 м с аддитивным смешением и cull_disabled —
// это два прохода по половине экрана с хешами в каждом пикселе, на телефоне, у которого и
// так было 23 кадра. Полтора десятка мелких карточек столько не стоят.

uniform vec3  tint : source_color = vec3(0.25, 1.0, 0.45);
uniform float radius = 4.6;                          // радиус поля в метрах
uniform float spin = 1.0;                            // общий множитель скорости облёта
uniform float flip_rate = 3.0;                       // как часто цифра перещёлкивается 0↔1
uniform float active : hint_range(0.0, 1.0) = 1.0;   // поле работает

varying float v_seed;
varying float v_fade;

float h1(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

// Те же нуль и единица, которыми говорит урон на блоках.
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
	float seed = INSTANCE_CUSTOM.w * 97.0;
	v_seed = seed;
	float r = (0.35 + 0.65 * INSTANCE_CUSTOM.z) * radius;
	// Половина цифр летит в одну сторону, половина в другую: одинаковое направление читается
	// как одна вращающаяся текстура, а нужно ощущение нескольких независимых потоков.
	float dir = INSTANCE_CUSTOM.y < 0.5 ? -1.0 : 1.0;
	float sp = dir * (0.35 + fract(INSTANCE_CUSTOM.y * 2.0) * 0.85) * spin;
	float a = INSTANCE_CUSTOM.x * 6.2831853 + TIME * sp;

	// Своя плоскость орбиты у каждой цифры — иначе все они лягут в один диск.
	vec3 ax = normalize(vec3(h1(seed), h1(seed + 1.7), h1(seed + 3.1)) * 2.0 - 1.0);
	vec3 up = abs(ax.y) > 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 u = normalize(cross(ax, up));
	vec3 v = cross(ax, u);
	vec3 off = (u * cos(a) + v * sin(a)) * r;

	// Билборд: карточка всегда лицом к камере. Базис берём из обратной матрицы вида, смещение
	// прибавляем к МИРОВОМУ положению узла — так цифра летает вокруг блока, а не вокруг нуля.
	mat4 m = mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	m[3].xyz += off;
	MODELVIEW_MATRIX = VIEW_MATRIX * m;

	// Цифра разгорается в начале круга и гаснет в конце. Без этого видно, что их горстка и
	// что они ходят по кругу; с ним в кадре их пять-шесть и каждая появляется заново.
	float lap = fract(a * 0.15915494);
	v_fade = smoothstep(0.0, 0.12, lap) * smoothstep(0.45, 0.30, lap);
}

void fragment() {
	float bit = step(0.5, h1(v_seed + floor(TIME * flip_rate) * 1.37));
	float g = glyph(UV, bit);
	float a = g * v_fade * active;
	// При unshaded в кадр идёт ALBEDO, а EMISSION не добавляет ничего (см. shield_dome.gdshader).
	// Поднимать цвет выше единицы тут нельзя: множитель обрезается по каналам и съедает оттенок —
	// зелёный уходил в бледный циан. Яркость цифры несёт ALPHA, а её потолок и так единица.
	ALBEDO   = tint;
	EMISSION = tint;
	ALPHA    = clamp(a, 0.0, 1.0);
}
