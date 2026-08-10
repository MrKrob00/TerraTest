shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

group_uniforms Quality;
// Low quality for weak, fill-bound hardware: drops the per-pixel noise and the tile texture.
uniform bool low_quality = false;

group_uniforms Texture;
// filter_nearest_MIPMAP: the mipmaps are essential — without them distant and grazing tiles
// read scattered texels and miss the cache. nearest keeps the pixel look up close.
uniform sampler2D tile_texture : source_color, filter_nearest_mipmap;
// Tile size in world units. Tiling is derived from world XZ (see vertex()), so it adapts to
// any map size and matches between the game and the editor.
uniform float tile_world_size  : hint_range(0.1, 100.0) = 1.0;
uniform float texture_blend    : hint_range(0.0, 1.0)    = 0.06;

// Quantising v_pixel_uv to a grid keeps the noise and the grass steady per cell instead of
// flickering per fragment.
const float PIXELS_PER_TILE = 16.0;

group_uniforms Colors;
uniform vec4 color_sand  : source_color = vec4(0.87, 0.74, 0.49, 1.0);  // warm golden sand (desert)
uniform vec4 color_grass : source_color = vec4(0.33, 0.56, 0.23, 1.0);  // lush green (meadow)
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
uniform vec4 color_rock  : source_color = vec4(0.40, 0.41, 0.43, 1.0);  // cold grey (contrasts with canyon rock)

group_uniforms Terrain;
uniform float rock_threshold     : hint_range(0.0, 1.0)      = 0.7;
uniform float rock_blend         : hint_range(0.0, 0.5)      = 0.15;
uniform float color_variation    : hint_range(0.0, 0.3)      = 0.06;

group_uniforms Biomes;
uniform float sand_grass        : hint_range(0.0, 0.5)     = 0.0;    // no grass in the DESERT (dry sand)
// CANYON biome: terracotta regions. Overrides sand and meadow, dry land, no grass.
uniform vec4  color_canyon      : source_color = vec4(0.70, 0.30, 0.15, 1.0);
uniform float canyon_band_h     : hint_range(2.0, 12.0)    = 6.0;    // stratum height (matches the geometry terrace)

group_uniforms Grass;
uniform float grass_density     : hint_range(0.0, 1.0)    = 0.4;
uniform float grass_height      : hint_range(0.0, 1.0)    = 0.15;
uniform float lod_grass_enabled : hint_range(0.0, 1.0)    = 1.0;
uniform float grass_shade       : hint_range(0.4, 1.2)    = 0.62;

group_uniforms Trample;
// Grass flatten map (fed by grass.gd through a SubViewport). Black by default = no effect,
// so it can be left unconnected.
uniform sampler2D trample_map : hint_default_black, filter_linear;
uniform vec2  trample_center = vec2(0.0);
uniform float trample_size   = 130.0;
group_uniforms;

group_uniforms Corruption;
// "Corrupted data" zones: a blue-violet per-cell glitch over the ground, in patches across
// the world, flickering over time and GLOWING (EMISSION).
uniform float corrupt_amount    : hint_range(0.0, 1.0)    = 1.0;    // master (0 = off)
// The zones come from a state map (maintained by grass.gd). Its red channel is how corrupted
// the chunk is; filter_linear softens the zone edges.
uniform sampler2D corrupt_map : hint_default_black, filter_linear;
uniform vec2  corrupt_world_center = vec2(0.0);   // world XZ centre of the map
uniform float corrupt_world_size   = 1984.0;      // world size of the map, in units
uniform float glitch_cell       : hint_range(0.3, 4.0)    = 1.0;    // glitch "pixel" size, in world units
uniform float glitch_speed      : hint_range(0.0, 20.0)   = 7.0;    // flicker rate
uniform vec3  corrupt_cyan    : source_color = vec3(0.15, 0.85, 1.0);
uniform vec3  corrupt_magenta : source_color = vec3(0.72, 0.16, 1.0);
uniform float corrupt_glow      : hint_range(0.0, 4.0)    = 1.6;    // glow strength
group_uniforms;

// The zone colour and the slope-driven fade into rock are computed in the VERTEX stage
// (v_base_col) and interpolated: the terrain is fill-bound and there are orders of magnitude
// fewer vertices than pixels. The fragment stage keeps only what has to be per-pixel — the
// noise and the tile texture.
varying vec2  v_pixel_uv;    // quantised (floored to the grid) — for steady noise and grass
varying vec2  v_tile_uv;     // SMOOTH — for the tile texture: the mip level comes from its
                             // derivatives, and a quantised one would give stepped derivatives.
varying vec3  v_base_col;
varying float v_is_grass;
varying vec2  v_world_xz;     // world XZ — for the per-cell corruption glitch in the fragment
varying float v_corrupt;      // strength of the corrupted zone (0..1)

float hash2D(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
    float wy = world_pos.y;
    v_tile_uv  = world_pos.xz / tile_world_size;                                  // smooth (texture + mip)
    v_pixel_uv = floor(v_tile_uv * PIXELS_PER_TILE) / PIXELS_PER_TILE;            // quantised (noise / grass)

    // Corrupted zone, read from the state map (grass.gd): the chunk's red channel is how
    // corrupted it is. Empty to begin with; grows a chunk at a time; heals near the player.
    v_world_xz  = world_pos.xz;
    float cstate = 0.0;
    // Uniform branch: with corrupt_amount == 0 there is no vertex texture fetch at all.
    if (corrupt_amount > 0.001) {
        vec2 cuv = (world_pos.xz - corrupt_world_center) / corrupt_world_size + vec2(0.5);
        if (cuv.x >= 0.0 && cuv.x <= 1.0 && cuv.y >= 0.0 && cuv.y <= 1.0) {
            cstate = textureLod(corrupt_map, cuv, 0.0).r;
        }
    }
    v_corrupt   = cstate * corrupt_amount;

    // The biome masks are baked into the vertex COLOR by map.gd — the shader only reads them.
    float biome_grass = COLOR.b;
    float canyon  = COLOR.g;
    float mountain = COLOR.a;                                          // MOUNTAIN biome (snowy, high)
    // Terracotta in BANDS by height (the canyon strata): a flat tread gets one colour band.
    float band_id    = floor(wy / canyon_band_h);
    float bh         = hash2D(vec2(band_id, 7.3));                    // 0..1 per band, stable
    vec3  canyon_col = mix(color_canyon.rgb * 0.72,
                           clamp(color_canyon.rgb * vec3(1.18, 1.06, 0.90), 0.0, 1.0), bh);
    vec3  zone    = mix(color_sand.rgb, color_grass.rgb, biome_grass);  // desert ↔ meadow
    zone          = mix(zone,           canyon_col,       canyon);      // canyon on top
    zone          = mix(zone,           color_snow.rgb,   mountain);    // snowy mountains on top
    float ny      = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend, rock_threshold + rock_blend, ny);
    vec3  rock_col = mix(color_rock.rgb, color_canyon.rgb * 0.55, canyon);   // canyon cliffs are darker
    v_base_col    = mix(zone, rock_col, rock_t);

    v_is_grass = 0.0;
    // COLOR.r < 0.5 marks a vertex on a chunk border: the grass offset is skipped there, or
    // the seam between differing LODs pulls apart. lod_grass_enabled is 1 only on the near
    // LOD-0 material.
    if (lod_grass_enabled > 0.5 && COLOR.r > 0.5) {
        // Grass grows in the MEADOW only. In the desert sand_grass = 0 means bare sand. None on
        // rock, in the canyon or on mountains. amount scales both height and density.
        float amount = mix(sand_grass, 1.0, biome_grass) * (1.0 - rock_t) * (1.0 - canyon) * (1.0 - mountain);
        if (amount > 0.03 && hash2D(v_pixel_uv) < grass_density * amount) {
            vec3 offset = NORMAL * grass_height * amount;
            vec2 t_uv = (world_pos.xz - trample_center) / trample_size + vec2(0.5);
            if (t_uv.x >= 0.0 && t_uv.x <= 1.0 && t_uv.y >= 0.0 && t_uv.y <= 1.0) {
                float press = texture(trample_map, t_uv).r;
                offset.y -= clamp(press, 0.0, 1.0) * grass_height * amount * 2.0;
            }
            VERTEX    += offset;
            v_is_grass = amount;                            // continuous, for a soft shade in the fragment
        }
    }
}

void fragment() {
    vec3 base_col = v_base_col;

    // Per-pixel only: colour noise plus the tile texture. low_quality skips both to save fill.
    if (!low_quality) {
        base_col = clamp(base_col + (hash2D(v_pixel_uv) - 0.5) * color_variation, 0.0, 1.0);
        if (texture_blend > 0.001) {
            base_col = mix(base_col, texture(tile_texture, v_tile_uv).rgb, texture_blend);
        }
    }

    // Below grass_shade 0.65 the grass sits slightly darker than the ground — a soft shadow at
    // the root rather than a bright patch.
    ALBEDO    = base_col * mix(0.78, grass_shade, v_is_grass);
    ROUGHNESS = 0.9;

    // ── Corrupted zones: a blue-violet per-cell glitch ────────────────────────────
    // Quantise the world into glitch_cell squares, then hash each cell (plus time, which makes
    // it flicker) into cyan / magenta / a dark "bit". Patchy via a second hash, and it glows.
    EMISSION = vec3(0.0);
    if (v_corrupt > 0.01) {
        vec2 cell = floor(v_world_xz / glitch_cell);
        float t = floor(TIME * glitch_speed);
        float n = hash2D(cell + vec2(t * 1.7, t * 0.9));
        vec3 g = (n < 0.42) ? corrupt_cyan : (n < 0.84 ? corrupt_magenta : vec3(0.02, 0.02, 0.05));
        float k = v_corrupt * step(0.25, hash2D(cell * 1.3 + vec2(5.0)));   // not a solid fill
        ALBEDO   = mix(ALBEDO, g, k);
        EMISSION = g * corrupt_glow * k;
    }
}
