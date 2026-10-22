shader_type canvas_item;

// World bootstrap title glitch: the title is rendered to a SubViewport and then torn apart with a
// restrained signal, so it feels like a system recovering from a temporary mismatch rather than a
// failed or broken interface.
// The effect is intentionally lighter than a hard destruction glitch: drift, RGB split and a few
// broken strips, not a violent full-screen shatter.

uniform float glitch : hint_range(0.0, 1.0) = 0.0;   // 0 = clean, 1 = strong disruption
uniform float seed = 0.0;
uniform float slices = 22.0;                         // how many horizontal strips we split into
uniform float split : hint_range(0.0, 0.05) = 0.008;  // lower split for a softer system glitch
uniform vec3 tint_a : source_color = vec3(0.15, 0.85, 1.00);   // cyan channel
uniform vec3 tint_b : source_color = vec3(0.25, 0.45, 1.00);   // blue channel

float h1(float n) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }

void fragment() {
	vec2 uv = UV;
	float t = floor(TIME * 14.0);

	// Split the title into a few wide horizontal strips, but keep the motion restrained and sparse.
	float row = floor(uv.y * slices);
	float rn = h1(row + t * 1.7);
	float shift = (rn - 0.5) * 0.17 * glitch;
	if (h1(row * 3.1 + t) > mix(0.94, 0.38, glitch)) {
		uv.x += shift;
	}

	// Mild RGB drift to read as system signal noise without jarring the logo into unreadability.
	float sp = split * (0.35 + glitch);
	vec4 c  = texture(TEXTURE, uv);
	float ca = texture(TEXTURE, uv + vec2(sp, 0.0)).a;
	float cb = texture(TEXTURE, uv - vec2(sp, 0.0)).a;

	vec3 col = c.rgb;
	float alpha = c.a;
	col += tint_a * ca * 0.42 * (0.3 + glitch);
	col += tint_b * cb * 0.42 * (0.3 + glitch);
	alpha = max(alpha, max(ca, cb) * (0.20 + 0.40 * glitch));

	// Only some strips vanish; the rest stay legible to preserve the idea of recovery, not failure.
	if (h1(row * 7.3 + t * 2.3) < glitch * 0.16) {
		alpha *= 0.2;
	}

	float flick = 1.0 - 0.24 * glitch * h1(t);
	COLOR = vec4(col * flick, alpha) * COLOR;
}
