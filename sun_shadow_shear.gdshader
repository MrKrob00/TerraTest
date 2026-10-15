// The still shadow layers' casters (sun_shadows.gd): a vertex in the ground's plane, its height over
// its own ground in UV.x, thrown along the light by that height - the projection onto a horizontal
// plane is a shear, so the light is this one uniform and a turn of the sun builds nothing.
shader_type canvas_item;
render_mode unshaded;

uniform vec2 shear = vec2(0.0);   // pixels a metre of height: light.xz / -light.y x pixels a metre

void vertex() {
	VERTEX += UV.x * shear;
}

void fragment() {
	COLOR = vec4(1.0);
}
