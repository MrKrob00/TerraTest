shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

// «Глитч-карточка»: плоский БИЛБОРД (2D-картинка лицом к камере), светится (additive),
// хаотично мерцает по своему seed, к концу анимации исчезает (progress→1). Много таких
// карточек разного размера на разной глубине образуют объёмный глитч вокруг блока
// (см. BlockFX.play — появление/исчезновение блока).

uniform vec3  card_color : source_color = vec3(0.15, 0.85, 1.0);
uniform float progress : hint_range(0.0, 1.0) = 0.0;    // 0..1 ход анимации (в конце гаснет)
uniform float seed = 0.0;
uniform float flicker_speed = 16.0;

float hash1(float n) {
	return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453);
}

void vertex() {
	// Билборд: убираем поворот модели, оставляем позицию и масштаб (квад лицом к камере).
	mat4 m = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(length(m[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(m[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(m[2].xyz), 0.0),
			m[3]);
}

void fragment() {
	// Мерцание: карточка то есть, то нет (свой ритм по seed).
	float t = floor(TIME * flicker_speed);
	float on = step(0.4, hash1(t));
	float env = 1.0 - progress;                 // к концу анимации исчезает
	float a = on * env;
	if (a < 0.04) {
		discard;
	}
	// Лёгкая «битая» кромка: центр ярче краёв.
	vec2 d = abs(UV - 0.5);
	float edge = 1.0 - smoothstep(0.35, 0.5, max(d.x, d.y));
	ALBEDO   = card_color;
	EMISSION = card_color * (1.8 * edge + 0.4);
	ALPHA    = a * (0.5 + edge * 0.5);
}
