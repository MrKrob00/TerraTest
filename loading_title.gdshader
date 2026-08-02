shader_type canvas_item;

// Глитч САМОГО НАЗВАНИЯ. Текст рендерится в SubViewport и приходит сюда текстурой — только так
// можно рвать/сдвигать его по-настоящему (у Label «текстура» это атлас шрифта: смещение UV
// вытащило бы соседние глифы, а не сдвинуло надпись).
// Делает: разрыв по горизонтальным полосам, RGB-сплит, выпадение кусков, дрожание яркости —
// в духе glitch_card.gdshader у блоков, но применительно к тексту.

uniform float glitch : hint_range(0.0, 1.0) = 0.0;   // 0 = чисто, 1 = полный развал
uniform float seed = 0.0;
uniform float slices = 22.0;                          // на сколько полос рвём
uniform float split : hint_range(0.0, 0.05) = 0.012;  // сила RGB-сплита
uniform vec3 tint_a : source_color = vec3(0.15, 0.85, 1.00);   // голубой канал
uniform vec3 tint_b : source_color = vec3(0.25, 0.45, 1.00);   // синий канал

float h1(float n) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }

void fragment() {
	vec2 uv = UV;
	float t = floor(TIME * 14.0);                     // ступенчатое время — «кадры» помех

	// ── Разрыв по полосам: каждая полоса едет по X на свою величину ──────────────
	float row = floor(uv.y * slices);
	float rn = h1(row + t * 1.7);
	float shift = (rn - 0.5) * 0.25 * glitch;
	// Рвём не все полосы сразу, а случайные — иначе это просто «дрожь», а не глитч.
	if (h1(row * 3.1 + t) > mix(0.92, 0.35, glitch)) {
		uv.x += shift;
	}

	// ── RGB-сплит: каналы разъезжаются, как на битом сигнале ────────────────────
	float sp = split * (0.35 + glitch);
	vec4 c  = texture(TEXTURE, uv);
	float ca = texture(TEXTURE, uv + vec2(sp, 0.0)).a;
	float cb = texture(TEXTURE, uv - vec2(sp, 0.0)).a;

	// Базовый цвет — из текстуры (там уже мультяшный заголовок с обводкой), плюс подкрашенные
	// «уехавшие» копии по краям: голубая справа, синяя слева.
	vec3 col = c.rgb;
	float alpha = c.a;
	col += tint_a * ca * 0.55 * (0.3 + glitch);
	col += tint_b * cb * 0.55 * (0.3 + glitch);
	alpha = max(alpha, max(ca, cb) * (0.25 + 0.55 * glitch));

	// ── Выпадение кусков: часть полос гаснет целиком (данные «потерялись») ──────
	if (h1(row * 7.3 + t * 2.3) < glitch * 0.22) {
		alpha *= 0.15;
	}

	// Дрожание яркости всей надписи.
	float flick = 1.0 - 0.35 * glitch * h1(t);
	COLOR = vec4(col * flick, alpha) * COLOR;
}
