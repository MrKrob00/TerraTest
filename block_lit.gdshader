shader_type spatial;
// THE BLOCKS ARE LIT BY THE SUN, CHEAPLY (the player, after TerraTech: "their machines have a lit side
// and a shade side, ours are flat"). The block materials stay UNSHADED - no light pass, no shadow
// sampling, no per-vertex lighting from the engine - and this shader multiplies the painted texel by
// one lambert term against the world's sun (`sun_dir`, `sun_light`, project.godot [shader_globals],
// moved by day_cycle.gd). MachineBatch and LooseBatch hand it to every batched block in place of its
// StandardMaterial (`MachineBatch.lit_material`), keeping the texture, the colour and the filter.
//
// THE NORMAL IS THE FACE'S OWN, FROM THE SCREEN-SPACE DERIVATIVES OF THE POSITION, NOT THE MESH'S.
// The artist's plates carry INVERTED normals (CLAUDE.md, the armour plates) and every block is drawn
// double-sided, so a mesh normal would light half the hull from the wrong side; the derivative
// normal is flat per face - which is the low-poly look anyway - and is turned to face the eye.
render_mode unshaded, cull_disabled;

uniform sampler2D albedo_texture : source_color, hint_default_white, filter_nearest_mipmap;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_vertex_color = false;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);

global uniform vec4 sun_dir;     // xyz toward the sun (by night the moon), w unused
global uniform vec4 sun_light;   // rgb the light's tint and strength on a lit face, a the shade floor
global uniform vec4 world_haze;
global uniform vec4 haze_range;

const float SKY_UP = 0.06;       // a face looking up catches the sky a little more

void fragment() {
	vec4 tex = texture(albedo_texture, UV * uv_scale.xy + uv_offset.xy) * albedo_color;
	if (use_vertex_color) {
		tex *= COLOR;
	}
	vec3 fn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(fn, VERTEX) > 0.0) {
		fn = -fn;                         // toward the eye: the side we see is the side lit
	}
	vec3 wn = (INV_VIEW_MATRIX * vec4(fn, 0.0)).xyz;
	float lam = max(dot(wn, normalize(sun_dir.xyz)), 0.0);
	vec3 k = mix(vec3(sun_light.a), sun_light.rgb, lam) + vec3(SKY_UP * max(wn.y, 0.0));
	ALBEDO = tex.rgb * k;
	FOG = vec4(world_haze.rgb, smoothstep(haze_range.x, haze_range.y, length(VERTEX)) * haze_range.z);
}
