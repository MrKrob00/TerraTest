shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

group_uniforms Texture;
// The cell of the per-pixel colour noise and of the grass, in world units (PIXELS_PER_TILE cells to
// one). Derived from world coordinates, so it matches between the game and the editor.
uniform float tile_world_size  : hint_range(0.1, 100.0) = 1.0;

// THE GROUND'S DETAIL (art/ground_detail.py): four tileable masks read in the ONE fetch the old
// tile used - R cracked earth, G sand ripples, B grass clumps, A broad patches. Masks, not colour:
// no source_color. Set by TerrainBiomes.apply_to_material. Each biome takes its own channel, after
// TerraTech's ground (the player's screenshots): the desert rippled, the meadow tufted, everything
// a little patchy, so no ground is one flat colour.
uniform sampler2D ground_detail : hint_default_white, filter_nearest_mipmap, repeat_enable;
uniform float detail_world_size : hint_range(1.0, 40.0)  = 9.0;
uniform float ripple_strength   : hint_range(0.0, 1.0)   = 0.55;
uniform float grass_detail      : hint_range(0.0, 1.0)   = 0.45;
uniform float patch_strength    : hint_range(0.0, 0.5)   = 0.10;

// Quantising to a grid keeps the noise and the grass steady per cell instead of flickering per
// fragment.
const float PIXELS_PER_TILE = 16.0;

group_uniforms Colors;
uniform vec4 color_sand  : source_color = vec4(0.87, 0.74, 0.49, 1.0);  // warm golden sand (desert)
uniform vec4 color_grass : source_color = vec4(0.33, 0.56, 0.23, 1.0);  // lush green (meadow)
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
// SNOW FOLLOWS HEIGHT, not just the mountain mask. The mask says WHERE the mountain region is;
// it says nothing about how high the ground actually got there. Painting by the mask alone put
// white patches on flat ground inside that region — the colour and the landform disagreed, and
// the map read as broken. snow_line is the world height where snow starts, snow_blend the
// softness of that edge.
//
// BOTH ARE METRES AND BOTH ARE COMPUTED, not authored: the biome resource holds them as a share of
// the world's Height and multiplies it out (TerrainBiomes.snow_line_at). Metres set by hand only
// ever match the one map they were set for.
uniform float snow_line  : hint_range(-100.0, 400.0) = 60.0;
uniform float snow_blend : hint_range(1.0, 120.0)    = 25.0;
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
// SALT FLATS: a dried lake bed, cracked into tiles (the ground detail's R channel). Its mask rides
// in COLOR.r with the grass flag (chunk_terrain SEAM_ON / SALT_SPAN): r >= SEAM_TEST is a grass
// vertex with r - SEAM_ON of salt, below it a seam vertex with r of salt.
uniform vec4  color_salt        : source_color = vec4(0.86, 0.75, 0.58, 1.0);
uniform float crack_strength    : hint_range(0.0, 1.0)     = 0.65;
const float SEAM_TEST = 0.55;
const float SEAM_ON = 0.6;
const float SALT_SPAN = 0.4;

group_uniforms Grass;
uniform float grass_density     : hint_range(0.0, 1.0)    = 1.0;   // см. TerrainBiomes: всегда, а не по настройке
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
// colour noise and the detail masks.
//
// THE HAZE costs one smoothstep a VERTEX: the engine's fog was tried and cost 5-7 fps of 23 on
// the device (CLAUDE.md, Look and light), for the one thing wanted - far ground going into the
// horizon's colour. Where it is nearly solid (HAZE_FLAT) the per-pixel detail is not drawn at all,
// and the far chunks are most of the frame.
// THE HAZE IS THE WORLD'S, NOT THIS MATERIAL'S (project.godot [shader_globals]): `world_haze` is
// its colour - day_cycle.gd moves it with the hour, warm cream by day, orange at dusk, deep blue at
// night - and the sky's horizon IS that colour, so far ground melts into the sky as TerraTech's does
// (the player's screenshot). `haze_range` = begin, end (m), strength. The trees read the same two.
// It is written to FOG, which the renderer mixes in AFTER the lighting, in this same pass: mixed
// into ALBEDO it was lit again, and a far slope in shade came out a dark smudge in bright haze.
global uniform vec4 world_haze;
global uniform vec4 haze_range;
const float HAZE_FLAT = 0.9;
varying float v_haze;

varying vec3  v_base_col;
varying float v_is_grass;
varying float v_desert;       // bare sand: what the ripples are drawn on
varying float v_salt;         // the salt flat: what the cracks are drawn on
varying vec3  v_wpos;         // world position — the corruption glitch and the wall UV below
varying vec3  v_wnrm;         // world normal — which plane the surface faces (see fragment)
varying float v_corrupt;      // strength of the corrupted zone (0..1)

float hash2D(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void vertex() {
    vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
    float wy = world_pos.y;
    // THE GRASS GRID: on XZ and quantised. Grass grows in this stage and only on gentle ground, so
    // it needs no projection onto walls; the fragment's noise picks its own plane (wall_uv there).
    vec2 pixel_uv = floor(world_pos.xz / tile_world_size * PIXELS_PER_TILE) / PIXELS_PER_TILE;
    vec3 wn       = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    v_wpos     = world_pos.xyz;
    v_wnrm     = wn;
    // Расстояние меряем ПО ЗЕМЛЕ, без высоты: иначе гора под камерой, до которой сто метров
    // вниз, тонула бы в дымке наравне с горизонтом.
    v_haze = smoothstep(haze_range.x, haze_range.y,
            length(world_pos.xz - CAMERA_POSITION_WORLD.xz));

    // Corrupted zone, read from the state map (grass.gd): the chunk's red channel is how
    // corrupted it is. Empty to begin with; grows a chunk at a time; heals near the player.
    float cstate = 0.0;
    // Uniform branch: with corrupt_amount == 0 there is no vertex texture fetch at all.
    if (corrupt_amount > 0.001) {
        vec2 cuv = (world_pos.xz - corrupt_world_center) / corrupt_world_size + vec2(0.5);
        if (cuv.x >= 0.0 && cuv.x <= 1.0 && cuv.y >= 0.0 && cuv.y <= 1.0) {
            cstate = textureLod(corrupt_map, cuv, 0.0).r;
        }
    }
    v_corrupt   = cstate * corrupt_amount;

    // The biome masks are baked into the vertex COLOR by the terrain (chunk_terrain._biome_colour).
    float biome_grass = COLOR.b;
    float canyon  = COLOR.g;
    float mountain = COLOR.a;                                          // MOUNTAIN biome (snowy, high)
    // Terracotta in BANDS by height (the canyon strata): a flat tread gets one colour band.
    float band_id    = floor(wy / canyon_band_h);
    float bh         = hash2D(vec2(band_id, 7.3));                    // 0..1 per band, stable
    vec3  canyon_col = mix(color_canyon.rgb * 0.72,
                           clamp(color_canyon.rgb * vec3(1.18, 1.06, 0.90), 0.0, 1.0), bh);
    bool  grass_vtx = COLOR.r >= SEAM_TEST;
    float salt    = clamp(grass_vtx ? (COLOR.r - SEAM_ON) / SALT_SPAN : COLOR.r / SALT_SPAN, 0.0, 1.0);
    vec3  zone    = mix(color_sand.rgb, color_grass.rgb, biome_grass);  // desert ↔ meadow
    zone          = mix(zone,           color_salt.rgb,   salt);        // the salt flat on the desert
    zone          = mix(zone,           canyon_col,       canyon);      // canyon on top
    float snow    = mountain * smoothstep(snow_line - snow_blend, snow_line + snow_blend, wy);
    zone          = mix(zone,           color_snow.rgb,   snow);        // snow only up high
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend, rock_threshold + rock_blend, wn.y);
    vec3  rock_col = mix(color_rock.rgb, color_canyon.rgb * 0.55, canyon);   // canyon cliffs are darker
    v_base_col    = mix(zone, rock_col, rock_t);

    // ТОН ЛУГА СЧИТАЕТСЯ ОТ БИОМА, А НЕ ОТ ТОГО, ПОДНЯЛАСЬ ЛИ ЭТА ВЕРШИНА.
    //
    // Раньше v_is_grass ставился только там, где вершину реально приподняли, а поднимают её лишь
    // на ближнем уровне LOD и лишь по броску хеша. Значит умножение на grass_shade доставалось
    // случайной части вершин: вблизи луг шёл пятнами двух тонов, а дальше первого уровня
    // становился ровным третьим. Игрок это и увидел — «два цвета, а вдали будет ещё один».
    //
    // Долю травы знает КАЖДЫЙ уровень: она выводится из маски биома в COLOR.b и из уклона. Тон
    // теперь берётся из неё, поэтому луг одного цвета на всей дистанции. Подъём вершин остаётся
    // ниже и остаётся геометрией — он и должен быть виден только вблизи.
    float grass_amount = mix(sand_grass, 1.0, biome_grass)
            * (1.0 - rock_t) * (1.0 - canyon) * (1.0 - mountain) * (1.0 - salt);
    v_is_grass = clamp(grass_amount, 0.0, 1.0);
    v_desert = clamp((1.0 - biome_grass) * (1.0 - canyon) * (1.0 - snow) * (1.0 - rock_t) * (1.0 - salt), 0.0, 1.0);
    v_salt = clamp(salt * (1.0 - canyon) * (1.0 - rock_t), 0.0, 1.0);
    // COLOR.r < SEAM_TEST marks a vertex on a chunk border: the grass offset is skipped there, or
    // the seam between differing LODs pulls apart. lod_grass_enabled is 1 only on the near
    // LOD-0 material.
    if (lod_grass_enabled > 0.5 && grass_vtx) {
        // Grass grows in the MEADOW only. In the desert sand_grass = 0 means bare sand. None on
        // rock, in the canyon or on mountains. amount scales both height and density.
        float amount = grass_amount;
        if (amount > 0.03 && hash2D(pixel_uv) < grass_density * amount) {
            vec3 offset = NORMAL * grass_height * amount;
            vec2 t_uv = (world_pos.xz - trample_center) / trample_size + vec2(0.5);
            if (t_uv.x >= 0.0 && t_uv.x <= 1.0 && t_uv.y >= 0.0 && t_uv.y <= 1.0) {
                float press = texture(trample_map, t_uv).r;
                offset.y -= clamp(press, 0.0, 1.0) * grass_height * amount * 2.0;
            }
            VERTEX += offset;
        }
    }
}

void fragment() {
    vec3 base_col = v_base_col;

    // Per-pixel only: the colour noise and the detail masks.
    //
    // THE UV IS TAKEN ON THE PLANE THE FACE LOOKS ALONG, not always XZ: on a canyon wall or a cliff
    // XZ degenerates and the detail smears into vertical stripes. The plane is picked HARD, not
    // blended - a full triplanar is three fetches a pixel on a fill-bound GPU - and the switch falls
    // on faces steeper than 45 deg, where both projections read alike. Per FRAGMENT: picked per
    // vertex, one triangle's corners would sit in different planes.
    // Под сплошной дымкой попиксельной детали не видно — не считаем её вовсе (см. шапку).
    if (v_haze < HAZE_FLAT) {
        vec2 wall = abs(v_wnrm.y) > 0.5
                ? v_wpos.xz                                                  // пол и склоны
                : (abs(v_wnrm.x) > abs(v_wnrm.z) ? v_wpos.zy : v_wpos.xy);   // стенки
        vec2 noise_uv = floor(wall / tile_world_size * PIXELS_PER_TILE) / PIXELS_PER_TILE;
        base_col = clamp(base_col + (hash2D(noise_uv) - 0.5) * color_variation, 0.0, 1.0);
        // one fetch: the detail masks (see the uniforms)
        vec4 dt = texture(ground_detail, wall / detail_world_size);
        float k = 1.0 + (dt.a - 0.5) * 2.0 * patch_strength;
        k *= mix(1.0, 0.84 + 0.30 * dt.g, v_desert * ripple_strength);
        k *= mix(1.0, 0.78 + 0.40 * dt.b, v_is_grass * grass_detail);
        // the lake bed: a tone per tile, dark in the cracks
        k *= mix(1.0, mix(0.35, 1.08, dt.r), v_salt * crack_strength);
        base_col = clamp(base_col * k, 0.0, 1.0);
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
        vec2 cell = floor(v_wpos.xz / glitch_cell);
        float t = floor(TIME * glitch_speed);
        float n = hash2D(cell + vec2(t * 1.7, t * 0.9));
        vec3 g = (n < 0.42) ? corrupt_cyan : (n < 0.84 ? corrupt_magenta : vec3(0.02, 0.02, 0.05));
        float k = v_corrupt * step(0.25, hash2D(cell * 1.3 + vec2(5.0)));   // not a solid fill
        ALBEDO   = mix(ALBEDO, g, k);
        EMISSION = g * corrupt_glow * k;
    }

    // ДЫМКА ПОСЛЕДНЕЙ, поверх всего: она про воздух между камерой и поверхностью, а значит
    // гасит и глитч заражённой зоны тоже — иначе на горизонте светились бы клетки, у которых
    // сама земля уже растворилась.
    EMISSION = EMISSION * (1.0 - v_haze);
    FOG = vec4(world_haze.rgb, v_haze * haze_range.z);
}
