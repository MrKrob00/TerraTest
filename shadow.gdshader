shader_type spatial;

uniform float bump_strength: hint_range(0.0, 5.0) = 1.5;
uniform float cell_size: hint_range(0.1, 5.0) = 1.0;

void fragment() {
	// Берём цвет вершины
	vec3 color = COLOR.rgb;

	// Имитируем объём через производную высоты по экрану
	float height = COLOR.r * 0.299 + COLOR.g * 0.587 + COLOR.b * 0.114;
	vec3 dx = dFdx(vec3(VERTEX.x, height * bump_strength, VERTEX.z));
	vec3 dz = dFdy(vec3(VERTEX.x, height * bump_strength, VERTEX.z));
	vec3 bump_normal = normalize(cross(dz, dx));

	ALBEDO = color;
	NORMAL = bump_normal;
	ROUGHNESS = 0.9;
	SPECULAR = 0.0;
}