shader_type spatial;
render_mode unshaded, depth_draw_never, blend_add;

// КУПОЛ ЩИТА. Весь узор приходит ГОТОВЫМ из меша (shield_hex.gd): пластины там настоящие
// многоугольники многогранника Голдберга, а не разметка, натянутая на сферу. Поэтому здесь не
// осталось ни хеша на пиксель, ни mod, ни atan — только то, что сделать в вершинах нельзя.
//
// Что лежит в вершине:
//   UV.x    — доля пути от центра пластины к её ребру (0 в центре, 1 на ребре);
//   UV.y    — место вдоль ребра, 0 и 1 на углах, 0.5 в центре;
//   COLOR.rgb — направление на центр СВОЕЙ пластины, упакованное в 0..1;
//   COLOR.a — случайное число пластины, постоянное между запусками.
//
// ЗАРЯД РЕШАЕТ, СКОЛЬКО ПЛАСТИН СТОИТ, а не насколько купол бледный: осыпающаяся решётка
// читается как «щита осталось на столько», бледнеющая — как «эффект гаснет».
//
// А ГДЕ ИМЕННО ОНИ СТОЯТ, РЕШАЕТ ПОСЛЕДНЕЕ ПОПАДАНИЕ. Порядок по случайному числу пластины был
// постоянным, но ни о чём не говорил: щит осыпался равномерно и с той стороны, куда никто не
// стрелял, тоже. Теперь пластины держатся ШАПКОЙ вокруг hit_cell, и садящийся щит показывает,
// откуда по нему бьют. Шапка никогда не пустеет: keep_cos приходит с той стороны (shield.gd)
// посчитанным по реальным центрам пластин так, чтобы в ней осталось не меньше семи — сама
// пластина попадания и весь её ряд соседей. У двенадцати пятиугольников соседей пять, поэтому
// порог для них свой: одно число на весь купол дало бы там шесть.
//
// ЗАЛИВКА ПОЧТИ НУЛЕВАЯ. Купол обязан оставаться прозрачным, сквозь него видно машину; светятся
// швы, углы и кольцо по касательной.
//
// РИСУЕТСЯ ТОЛЬКО БЛИЖНЯЯ ПОЛОВИНА — обычным отсечением задних граней. С cull_disabled дальняя
// решётка складывалась с ближней при аддитивном смешении: узор удваивался, купол мутнел, и
// фрагментов было вдвое больше на телефоне. Заодно исчезает вопрос «ближняя или дальняя», на
// котором тут уже ломались и FRONT_FACING, и NORMAL — оба зависят от обхода вершин.
// Цена: изнутри купола его не видно. Радиус четыре метра, камера почти всегда снаружи.

uniform vec3  tint : source_color = vec3(0.30, 0.66, 1.0);
uniform float line_w : hint_range(0.02, 0.6) = 0.20;     // доля пластины под шов
uniform float fill : hint_range(0.0, 0.4) = 0.07;        // заливка пластины
uniform float corner_w : hint_range(0.0, 0.4) = 0.14;    // размер точки на углу
uniform float rim_pow : hint_range(1.0, 12.0) = 3.0;
uniform float rim_gain : hint_range(0.0, 3.0) = 1.7;
uniform float halo_pow : hint_range(0.5, 6.0) = 2.4;
uniform float halo_gain : hint_range(0.0, 2.0) = 0.22;
uniform float energy : hint_range(0.0, 1.0) = 1.0;
// Свежее попадание: 1 в момент удара, едет к нулю. hit_cell — центр ТОЙ ОДНОЙ пластины, в
// которую пришёл снаряд; её выбирает щит из списка центров. Купол целиком не мигает: вспышка
// на всю оболочку не говорит, куда попали, и на частом огне превращается в мигание экрана.
uniform float hit : hint_range(0.0, 1.0) = 0.0;
uniform vec3  hit_cell = vec3(0.0, 1.0, 0.0);
/// Косинус, ниже которого пластина уже не в шапке попадания. Считает shield.gd по центрам
/// пластин под КОНКРЕТНУЮ hit_cell, чтобы в шапке гарантированно было seven и на пятиугольнике.
uniform float keep_cos : hint_range(-1.0, 1.0) = 0.88;
/// Насколько рваный край у шапки. Ноль дал бы идеальный круг, а это читается как маска поверх
/// купола, а не как осыпающаяся решётка. Внутрь шапки не пускаем — иначе минимум не гарантирован.
uniform float keep_jitter : hint_range(0.0, 0.4) = 0.10;
uniform vec3  glitch_a : source_color = vec3(0.15, 0.85, 1.0);
uniform vec3  glitch_b : source_color = vec3(0.72, 0.16, 1.0);
uniform float glitch_rate = 22.0;
// RIPPLE: a ring of plates running out across the dome from the struck one (shield.gd starts it in
// mark_hit_point). Its own clock, not `hit`: the flare fades in 0.22 s, too short to watch anything
// travel. 1.0 is "no ripple", and the branch below is on that uniform, so an untouched dome pays
// nothing. It lights plates the charge has turned off as well - for a moment the dome shows all of
// itself, which is exactly what a ripple across a shield says.
uniform float ripple : hint_range(0.0, 1.0) = 1.0;
uniform vec3  ripple_cell = vec3(0.0, 1.0, 0.0);
uniform float ripple_reach = 1.9;     // radians the ring travels, about 110 degrees
uniform float ripple_band = 0.30;     // radians: about one ring of plates at 92 cells
// OVERLAPPING DOMES DRAW AS ONE HULL. Each neighbour dome of the same side that reaches into this one
// arrives here as (centre in THIS dome's model space, radius squared); a fragment inside any of them
// is thrown away, so what is left of two or three domes is only their common outer envelope.
// shield.gd fills it (`_update_cuts`); CUT_MAX there must match the array size.
uniform vec4 cut[4];
uniform int cut_n = 0;

varying vec3 v_cell;
varying float v_rnd;
varying vec2 v_uv;
varying vec3 v_wpos;
varying vec3 v_wout;
varying vec3 v_lpos;

void vertex() {
	v_cell = COLOR.rgb * 2.0 - 1.0;
	v_rnd = COLOR.a;
	v_uv = UV;
	v_lpos = VERTEX;
	// Наружное направление и мировая точка считаются здесь САМИ. Встроенный NORMAL приходит
	// вывернутым (у меша, собранного кодом, обход вершин обратный, и движок доворачивает
	// нормаль по своему соглашению) — измерено: ближняя полусфера уходила в множитель дальней.
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wout = normalize((MODEL_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
}

void fragment() {
	for (int i = 0; i < 4; i++) {
		if (i >= cut_n) {
			break;
		}
		vec3 d = v_lpos - cut[i].xyz;
		if (dot(d, d) < cut[i].w) {
			discard;
		}
	}
	float t = v_uv.x;
	float edge_pos = min(v_uv.y, 1.0 - v_uv.y);

	// ПОЛОСА С ПЛАТО, А НЕ СКЛОН. smoothstep до самой единицы достигает её ровно НА ребре, то
	// есть шов был ярким в одну линию пикселей, а всё остальное — растяжкой: решётка читалась
	// тусклой при любых множителях. Здесь полоса выходит на полную яркость заранее.
	float seam = smoothstep(1.0 - line_w, 1.0 - line_w + 0.05, t);
	float body = 1.0 - seam;
	float corner = smoothstep(corner_w, 0.0, edge_pos) * smoothstep(1.0 - line_w * 2.0, 1.0, t);

	// ЧТО СТОИТ, А ЧТО ОСЫПАЛОСЬ. Близость к попаданию — скалярное произведение центров; внутри
	// пластины центр постоянен, так что число одно на всю пластину и края не рвутся.
	//
	// Шапка (core) стоит ВСЕГДА, вплоть до нулевого заряда: пустая решётка неотличима от
	// выключенного щита, а он ещё работает, и по этим семи пластинам видно, с какой стороны его
	// дожимают. Остальное садится порогом, который едет от «всё» при полном заряде к границе
	// шапки при пустом.
	float near = dot(normalize(v_cell), normalize(hit_cell));
	float core = step(keep_cos, near);
	// ЗАРЯД ТЯНЕТ РАДИУС ШАПКИ НА ЭКРАНЕ, А НЕ КОСИНУС И НЕ УГОЛ. Купол виден как КРУГ, и шапка
	// половинного угла θ занимает на нём радиус sin θ — то есть по косинусу шкала врёт вдвойне.
	// Сначала порог ехал линейно по косинусу до −1: полшкалы уходило на дальнюю, отсечённую
	// половину, и кадры на заряде 1.0 и 0.6 не отличались НИ ОДНИМ пикселем (измерено). Потом до
	// −0.17, ближней полусферы: лучше, но верх шкалы всё равно съедал край силуэта, который виден
	// с ребра и ничего не весит. Здесь линеен сам ЭКРАННЫЙ радиус: половина заряда — круг вдвое
	// уже, и это видно сразу.
	float s_keep = sqrt(max(1.0 - keep_cos * keep_cos, 0.0));
	float s = mix(s_keep, 1.0, clamp(energy, 0.0, 1.0));
	float thr = sqrt(max(1.0 - s * s, 0.0));
	float cap = step(thr, near + (v_rnd - 0.5) * keep_jitter);
	// А ЩИТ ВСЁ-ТАКИ ОКРУЖАЕТ МАШИНУ ЦЕЛИКОМ. Одной шапки мало: получив в корму, игрок смотрел
	// бы вперёд и не видел там вообще ничего. Поэтому поверх шапки идёт прежний равномерный
	// порог по случайному числу пластины. Он же вытягивает середину шкалы: пластин всего 92, они
	// лежат кольцами вокруг любой выбранной, и между первым кольцом и вторым по косинусу провал
	// — шапка растёт скачками 7 → 13 → 22, а рассыпанные по оболочке пластины заполняют
	// промежутки. Вместе это читается так: густо там, куда бьют, редко по остальной оболочке.
	float spread = step(v_rnd, clamp(energy, 0.0, 1.0));
	float up = max(core, max(cap, spread));

	// БЛИЖНЯЯ ПОЛУСФЕРА ИЛИ ДАЛЬНЯЯ — ЧИСТАЯ ГЕОМЕТРИЯ: наружное направление против направления
	// на камеру. Ни FRONT_FACING, ни NORMAL здесь не годятся — оба зависят от обхода вершин, а
	// он у собранного кодом меша обратный, и оба врали наоборот.
	//
	// И abs, А НЕ clamp СНИЗУ: у дальней полусферы скалярное произведение отрицательно, обрезка
	// в ноль давала френель, горящий по ВСЕЙ задней половине разом — ровная заливка поверх
	// купола, та самая «молочная» сфера, из-за которой не было видно ни машины, ни узора.
	float ndv = 1.0 - clamp(dot(v_wout, normalize(CAMERA_POSITION_WORLD - v_wpos)), 0.0, 1.0);
	float rim = pow(ndv, rim_pow) * rim_gain + pow(ndv, halo_pow) * halo_gain;

	// Ветка по ЮНИФОРМУ: пока по щиту не попали, она не считается ни на одном пикселе.
	vec3 col = tint;
	float flare = 0.0;
	if (hit > 0.001) {
		// Своя пластина или нет — сравнением центров. Внутри пластины центр постоянен, так что
		// это точное «да/нет», а не расстояние по куполу.
		float mine = step(0.99, dot(normalize(v_cell), normalize(hit_cell)));
		flare = mine * hit;
		float gt = floor(TIME * glitch_rate);
		float g = fract(sin(gt * 12.9898 + v_rnd * 78.233) * 43758.5453);
		col = mix(tint, g < 0.5 ? glitch_a : glitch_b, mine);
	}

	// Per plate: v_cell is constant across a plate, so the ring steps hex by hex, not as a band.
	float wave = 0.0;
	if (ripple < 0.999) {
		float ang = acos(clamp(dot(normalize(v_cell), normalize(ripple_cell)), -1.0, 1.0));
		float on = 1.0 - smoothstep(0.0, ripple_band, abs(ang - ripple * ripple_reach));
		// Strong for most of the way and gone at the end: a linear fade halved it before it had
		// crossed two rings, and on a half-charged dome it was hard to see at all.
		wave = on * (1.0 - ripple * ripple);
		float gw = fract(sin(floor(TIME * glitch_rate) * 7.13 + v_rnd * 91.7) * 43758.5453);
		col = mix(col, gw < 0.5 ? glitch_a : glitch_b, wave * 0.85);
	}

	// Пробитая пластина загорается, даже если заряд её погасил: попадание важнее.
	float shell = max(max(up, flare), wave);
	// The ring fills the plate FACE, not only its seams: a lit plate otherwise changed by a shade.
	float lattice = (seam + corner * 0.6 + body * (fill + wave * 0.45)) * shell;
	// КОЛЬЦО ТОЖЕ ПРИНАДЛЕЖИТ ПЛАСТИНЕ. Оно считалось по всей сфере и не спрашивало, стоит ли
	// здесь пластина: на разряженном щите решётка гасла, а голубая подсветка оболочки
	// оставалась висеть шаром. Теперь на месте погасшей пластины нет ничего, и осыпающийся
	// купол виден по силуэту — он становится дырявым, а не бледным.
	rim *= shell;

	// ЯРКОСТЬ ИДЁТ В ALBEDO, А НЕ В EMISSION. При render_mode unshaded компат-рендерер в кадр
	// кладёт ALBEDO, а EMISSION не добавляет ничего — измерено: альбедо 0.2 даёт 0.498, эмиссия
	// 0.8 даёт 0.302, а вместе ровно те же 0.498. Любые множители на EMISSION здесь были
	// украшением кода. Строку оставляем верной на случай, если glow когда-нибудь вернётся.
	float bright = lattice * 0.75 + rim * 0.9 + flare * 1.8 + wave * 1.4;
	ALBEDO   = col * (0.15 + bright);
	EMISSION = col * bright;
	ALPHA    = clamp(lattice + rim + flare * 1.2, 0.0, 1.0);
}
