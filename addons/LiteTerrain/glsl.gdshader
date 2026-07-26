shader_type spatial;
// specular_disabled: террейн матовый (SPECULAR=0) — убираем расчёт спекуляра из пайплайна.
render_mode diffuse_lambert, specular_disabled;

group_uniforms Quality;
// Низкое качество для слабого железа (fill-bound): выключает попиксельный шум и тайл-текстуру.
uniform bool low_quality = false;

group_uniforms Texture;
// filter_nearest_MIPMAP — ключ к FPS: без мипов дальние/наклонные тайлы читают разнесённые
// тексели → сплошные промахи кэша текстур (главный fill-пожиратель, подтверждено тем, что
// low_quality — он выключает эту выборку — давал +14 FPS). С мипами дальние пиксели берут
// маленькие уровни → попадание в кэш, дёшево и без муара; вблизи nearest сохраняет пиксельность.
uniform sampler2D tile_texture : source_color, filter_nearest_mipmap;
// Размер тайла в мировых юнитах. Тайлинг считается из мировых XZ (см. vertex()), поэтому
// подстраивается под любой размер карты и одинаков в игре и в редакторе.
uniform float tile_world_size  : hint_range(0.1, 100.0) = 1.0;
uniform float texture_blend    : hint_range(0.0, 1.0)    = 0.1;

// Квантизация v_pixel_uv к сетке, чтобы шум и трава были стабильны по ячейке, а не мерцали
// по фрагментам. Константа, а не uniform — это не настройка вида.
const float PIXELS_PER_TILE = 16.0;

group_uniforms Colors;
uniform vec4 color_sand  : source_color = vec4(0.76, 0.66, 0.48, 1.0);
uniform vec4 color_grass : source_color = vec4(0.29, 0.48, 0.23, 1.0);
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
uniform vec4 color_rock  : source_color = vec4(0.44, 0.38, 0.31, 1.0);

group_uniforms Terrain;
uniform float height_grass_start : hint_range(-200.0, 500.0) = 20.0;
uniform float height_snow_start  : hint_range(-200.0, 500.0) = 70.0;
uniform float zone_blend         : hint_range(0.1,   30.0)   =  5.0;
uniform float rock_threshold     : hint_range(0.0, 1.0)      = 0.7;
uniform float rock_blend         : hint_range(0.0, 0.5)      = 0.15;
uniform float color_variation    : hint_range(0.0, 0.3)      = 0.06;

group_uniforms Biomes;
// Песок/трава теперь по БИОМАМ (регионам), а не по высоте. Биом задаётся низкочастотным
// шумом по миру XZ: крупные пятна травяного и песчаного биома. Снег остаётся по высоте (пики).
uniform float biome_scale       : hint_range(30.0, 1000.0) = 320.0;  // размер пятна биома (единиц мира)
uniform float biome_blend       : hint_range(0.02, 0.5)    = 0.16;   // резкость границы биомов
uniform float biome_grass_bias  : hint_range(0.0, 1.0)     = 0.5;    // порог (>0.5 = больше песка)
uniform float sand_grass        : hint_range(0.0, 0.5)     = 0.2;    // сила травы в ПЕСЧАНОМ биоме (~0.2 макс)

group_uniforms Grass;
uniform float grass_density     : hint_range(0.0, 1.0)    = 0.4;
uniform float grass_height      : hint_range(0.0, 1.0)    = 0.15;
uniform float grass_min_height  : hint_range(-10.0, 10.0) = -2.0;
uniform float grass_max_height  : hint_range(-10.0, 10.0) = 5.0;
uniform float bend_radius       : hint_range(0.1, 10.0)   = 1.5;
uniform float lod_grass_enabled : hint_range(0.0, 1.0)    = 1.0;
// Яркость травы ОТНОСИТЕЛЬНО подстилки (подстилка = 0.65). Было 1.0 → трава была светлее и
// «выскакивала» на границе. 0.62 = трава чуть темнее земли (мягкая тень у корня), не пятном.
uniform float grass_shade       : hint_range(0.4, 1.2)    = 0.62;
// Сколько травы на СНЕГУ относительно травяной зоны (0 = снег голый, 1 = столько же). На снегу
// трава реже и короче (масштаб высоты = этому же множителю). В песке/воде и на КАМНЕ травы нет.
uniform float snow_grass        : hint_range(0.0, 1.0)    = 0.35;

group_uniforms Trample;
// Карта примятия травы (кормит grass.gd через SubViewport). Чёрная по умолчанию = нет
// эффекта, можно не подключать.
uniform sampler2D trample_map : hint_default_black, filter_linear;
uniform vec2  trample_center = vec2(0.0);
uniform float trample_size   = 130.0;
group_uniforms;

// FILL-ОПТИМИЗАЦИЯ: цвет зон по высоте + переход в камень по склону считается в ВЕРШИНЕ
// (v_base_col) и интерполируется, а не пересчитывается на каждый пиксель. Террейн — fill-bound
// (тяжёл именно попиксельно), а вершин на порядки меньше. Механики те же; на границах зон
// переход становится линейным (вблизи, где сетка плотная, — незаметно; вдали и так мелко).
// Во фрагменте остаётся только то, что обязано быть per-pixel: шум и тайл-текстура.
varying vec2  v_pixel_uv;    // квантованный (floor к сетке) — для стабильного шума и травы
varying vec2  v_tile_uv;     // ГЛАДКИЙ — для выборки тайл-текстуры: только по нему GPU может
                             // правильно выбрать мип-уровень (по производным ddx/ddy); от
                             // квантованного v_pixel_uv производные ступенчатые → мип ломался.
varying vec3  v_base_col;
varying float v_is_grass;

float hash2D(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Гладкий value-noise [0..1] для БИОМОВ: билинейная интерполяция hash по узлам сетки со
// smoothstep-сглаживанием. Низкая частота (world/biome_scale) → крупные пятна биомов.
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash2D(i);
    float b = hash2D(i + vec2(1.0, 0.0));
    float c = hash2D(i + vec2(0.0, 1.0));
    float d = hash2D(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
    vec4 world_pos = MODEL_MATRIX * vec4(VERTEX, 1.0);
    float wy = world_pos.y;
    v_tile_uv  = world_pos.xz / tile_world_size;                                  // гладкий (текстура + мип)
    v_pixel_uv = floor(v_tile_uv * PIXELS_PER_TILE) / PIXELS_PER_TILE;            // квантованный (шум/трава)

    // БИОМ: песок/трава по регионам (низкочастотный шум), а НЕ по высоте. biome_grass=1 —
    // травяной биом, 0 — песчаный. Ниже уровня воды (height_grass_start) — всегда песок
    // (пляж/дно), биом туда траву не тянет. Снег остаётся по ВЫСОТЕ (пики гор).
    float biome_n     = vnoise(world_pos.xz / biome_scale);
    float above_water = smoothstep(height_grass_start - zone_blend, height_grass_start + zone_blend, wy);
    float biome_grass = smoothstep(biome_grass_bias - biome_blend, biome_grass_bias + biome_blend, biome_n) * above_water;
    float t_snow  = smoothstep(height_snow_start - zone_blend, height_snow_start + zone_blend, wy);
    vec3  zone    = mix(color_sand.rgb, color_grass.rgb, biome_grass);
    zone          = mix(zone,           color_snow.rgb,  t_snow);
    float ny      = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend, rock_threshold + rock_blend, ny);
    v_base_col    = mix(zone, color_rock.rgb, rock_t);

    v_is_grass = 0.0;
    // COLOR.r < 0.5 помечает вершины на границе чанка: там смещение травы пропускаем, чтобы
    // шов (особенно на границе LOD) остался на сшитой базовой поверхности. lod_grass_enabled=1
    // только на ближнем LOD-0 материале — трава смещается лишь вблизи, где её видно.
    if (lod_grass_enabled > 0.5 && COLOR.r > 0.5 && wy >= grass_min_height) {
        // По БИОМУ: в травяном биоме трава полная, в ПЕСЧАНОМ — очень слабая (sand_grass~0.2
        // макс, редкая и низкая), на снегу реже/короче (snow_grass), НЕТ на камне (rock_t
        // зануляет — «на скалу не приминается»). amount масштабирует и высоту, и плотность.
        float land   = mix(sand_grass, 1.0, biome_grass) * (1.0 - t_snow);
        float amount = max(land, t_snow * snow_grass) * (1.0 - rock_t);
        if (amount > 0.03 && hash2D(v_pixel_uv) < grass_density * amount) {
            vec3 offset = NORMAL * grass_height * amount;   // выше в траве, ниже на снегу
            vec2 t_uv = (world_pos.xz - trample_center) / trample_size + vec2(0.5);
            if (t_uv.x >= 0.0 && t_uv.x <= 1.0 && t_uv.y >= 0.0 && t_uv.y <= 1.0) {
                float press = texture(trample_map, t_uv).r;
                offset.y -= clamp(press, 0.0, 1.0) * grass_height * amount * 2.0;
            }
            VERTEX    += offset;
            v_is_grass = amount;                            // плавно, для мягкой тени во фрагменте
        }
    }
}

void fragment() {
    vec3 base_col = v_base_col;

    // Только per-pixel: шум цвета + тайл-текстура. В low_quality пропускаем (экономия fill).
    if (!low_quality) {
        base_col = clamp(base_col + (hash2D(v_pixel_uv) - 0.5) * color_variation, 0.0, 1.0);
        if (texture_blend > 0.001) {
            base_col = mix(base_col, texture(tile_texture, v_tile_uv).rgb, texture_blend);
        }
    }

    // Трава НЕ ярче подстилки (чинит «выскакивание»): при grass_shade<0.65 трава чуть темнее
    // земли — мягкая тень у корня, а не светлое пятно. Крутится uniform-ом grass_shade.
    ALBEDO    = base_col * mix(0.65, grass_shade, v_is_grass);
    ROUGHNESS = 0.9;
}
