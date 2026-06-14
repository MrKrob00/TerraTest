shader_type spatial; 

uniform vec3 albedo : source_color;

void fragment() {
	ALBEDO = albedo;
}

float fresnel(vec3 normal, vec3 view)
{
	return 1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0);
}

void light() {
	float light = max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION;
	light = round(light * 4.0) / 4.0;
	
	vec3 diffuse = vec3(light) * LIGHT_COLOR / PI;
	
	DIFFUSE_LIGHT += diffuse;

	float rim = fresnel(NORMAL, VIEW);
	rim = step(0.7, rim);
	rim *= light;

    SPECULAR_LIGHT += vec3(rim) * LIGHT_COLOR / PI;
    
    float specular = max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION;
    SPECULAR_LIGHT += vec3(specular) * LIGHT_COLOR / PI;
}