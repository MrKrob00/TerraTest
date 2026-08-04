shader_type spatial;
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
uniform float texture_blend    : hint_range(0.0, 1.0)    = 0.06;

// Квантизация v_pixel_uv к сетке, чтобы шум и трава были стабильны по ячейке, а не мерцали
// по фрагментам. Константа, а не uniform — это не настройка вида.
const float PIXELS_PER_TILE = 16.0;

group_uniforms Colors;
uniform vec4 color_sand  : source_color = vec4(0.87, 0.74, 0.49, 1.0);  // тёплый золотистый песок (пустыня)
uniform vec4 color_grass : source_color = vec4(0.33, 0.56, 0.23, 1.0);  // сочная зелень (луг)
uniform vec4 color_snow  : source_color = vec4(0.94, 0.96, 1.00, 1.0);
uniform vec4 color_rock  : source_color = vec4(0.40, 0.41, 0.43, 1.0);  // холодно-серый (каньон-скала контрастнее)

group_uniforms Terrain;
uniform float height_grass_start : hint_range(-200.0, 500.0) = 20.0;
uniform float height_snow_start  : hint_range(-200.0, 500.0) = 70.0;
uniform float zone_blend         : hint_range(0.1,   30.0)   =  5.0;
uniform float rock_threshold     : hint_range(0.0, 1.0)      = 0.7;
uniform float rock_blend         : hint_range(0.0, 0.5)      = 0.15;
uniform float color_variation    : hint_range(0.0, 0.3)      = 0.06;

group_uniforms Biomes;
uniform float biome_scale       : hint_range(30.0, 1000.0) = 230.0;  // размер пятна биома (мельче → видно несколько биомов на экране)
uniform float biome_blend       : hint_range(0.02, 0.5)    = 0.07;   // резкость границы биомов (уже → чётче, не «мешанина»)
uniform float biome_grass_bias  : hint_range(0.0, 1.0)     = 0.5;    // порог (>0.5 = больше песка)
uniform float sand_grass        : hint_range(0.0, 0.5)     = 0.0;    // травы в ПУСТЫНЕ нет (сухой песок)
// КАНЬОН-биом: терракотовые регионы (свой шум). Перекрывает песок/траву, суша, без травы.
uniform vec4  color_canyon      : source_color = vec4(0.70, 0.30, 0.15, 1.0);  // терракота (горячее/насыщеннее)
uniform float canyon_scale      : hint_range(30.0, 1000.0) = 250.0;  // размер пятна каньона (мельче → много мес)
uniform float canyon_threshold  : hint_range(0.0, 1.0)     = 0.70;   // выше = реже каньоны (~21% при 160)
uniform float canyon_edge       : hint_range(0.02, 0.5)    = 0.05;   // резкость границы (уже → отвеснее внешняя стена)
uniform float canyon_band_h     : hint_range(2.0, 12.0)    = 6.0;    // высота страты-полосы (== террасе геометрии в plugin.gd)

group_uniforms Grass;
uniform float grass_density     : hint_range(0.0, 1.0)    = 0.4;
uniform float grass_height      : hint_range(0.0, 1.0)    = 0.15;
uniform float grass_min_height  : hint_range(-10.0, 10.0) = -2.0;
uniform float grass_max_height  : hint_range(-10.0, 10.0) = 5.0;
uniform float bend_radius       : hint_range(0.1, 10.0)   = 1.5;
uniform float lod_grass_enabled : hint_range(0.0, 1.0)    = 1.0;
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

group_uniforms Corruption;
// Зоны «битых данных» (лор цифровой симуляции): сине-фиолетовый ЧАНКОВЫЙ глитч поверх земли —
// пятнами по миру (свой шум), мерцает во времени, СВЕТИТСЯ (EMISSION). Тюнинг в редакторе.
uniform float corrupt_amount    : hint_range(0.0, 1.0)    = 1.0;    // мастер (0 = выкл)
// Зоны — из СТАН-КАРТЫ (её ведёт grass.gd: изначально пусто, редко +чанк, лечится у игрока
// НАВСЕГДА). Красный канал = степень корруптации чанка. filter_linear → мягкие края зон.
uniform sampler2D corrupt_map : hint_default_black, filter_linear;
uniform vec2  corrupt_world_center = vec2(0.0);   // мировой XZ-центр карты
uniform float corrupt_world_size   = 1984.0;      // мировой размер карты (единиц)
uniform float glitch_cell       : hint_range(0.3, 4.0)    = 1.0;    // размер «пикселя» глитча (мир)
uniform float glitch_speed      : hint_range(0.0, 20.0)   = 7.0;    // частота мерцания
uniform vec3  corrupt_cyan    : source_color = vec3(0.15, 0.85, 1.0);
uniform vec3  corrupt_magenta : source_color = vec3(0.72, 0.16, 1.0);
uniform float corrupt_glow      : hint_range(0.0, 4.0)    = 1.6;    // сила свечения
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
varying vec2  v_world_xz;     // мир XZ — для чанкового глитча корруптации во фрагменте
varying float v_corrupt;      // сила зоны битых данных (0..1)

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

    // Зона «битых данных» — из СТАН-КАРТЫ (grass.gd): красный канал чанка = степень корруптации.
    // Изначально пусто; редко +чанк; вблизи игрока лечится НАВСЕГДА (карта обнуляет чанк).
    v_world_xz  = world_pos.xz;
    float cstate = 0.0;
    // Uniform-ветка: при corrupt_amount == 0 вершинной выборки текстуры (VTF) нет вообще.
    if (corrupt_amount > 0.001) {
        vec2 cuv = (world_pos.xz - corrupt_world_center) / corrupt_world_size + vec2(0.5);
        if (cuv.x >= 0.0 && cuv.x <= 1.0 && cuv.y >= 0.0 && cuv.y <= 1.0) {
            cstate = textureLod(corrupt_map, cuv, 0.0).r;
        }
    }
    v_corrupt   = cstate * corrupt_amount;

    float biome_grass = COLOR.b;
    float canyon  = COLOR.g;
    float mountain = COLOR.a;                                          // биом ГОР (снежные, высокие)
    // Терракота ПОЛОСАМИ по высоте (страты каньона): плоский тред → одна полоса цвета.
    float band_id    = floor(wy / canyon_band_h);
    float bh         = hash2D(vec2(band_id, 7.3));                    // 0..1 на каждую полосу, стабильно
    vec3  canyon_col = mix(color_canyon.rgb * 0.72,
                           clamp(color_canyon.rgb * vec3(1.18, 1.06, 0.90), 0.0, 1.0), bh);
    vec3  zone    = mix(color_sand.rgb, color_grass.rgb, biome_grass);  // пустыня ↔ луг
    zone          = mix(zone,           canyon_col,       canyon);      // каньон поверх
    zone          = mix(zone,           color_snow.rgb,   mountain);    // снежные горы поверх (белый)
    float ny      = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
    float rock_t  = 1.0 - smoothstep(rock_threshold - rock_blend, rock_threshold + rock_blend, ny);
    vec3  rock_col = mix(color_rock.rgb, color_canyon.rgb * 0.55, canyon);   // скалы: каньон темнее, на снегу — тёмная порода
    v_base_col    = mix(zone, rock_col, rock_t);

    v_is_grass = 0.0;
    // COLOR.r < 0.5 помечает вершины на границе чанка: там смещение травы пропускаем, чтобы
    // шов (особенно на границе LOD) остался на сшитой базовой поверхности. lod_grass_enabled=1
    // только на ближнем LOD-0 материале — трава смещается лишь вблизи, где её видно.
    if (lod_grass_enabled > 0.5 && COLOR.r > 0.5) {
        // Трава ТОЛЬКО в ЛУГУ (biome_grass). В ПУСТЫНЕ sand_grass=0 → сухой песок без травы. НЕТ
        // на камне (rock_t) и в каньоне. Без высотного гейта. amount масштабирует высоту и плотность.
        float amount = mix(sand_grass, 1.0, biome_grass) * (1.0 - rock_t) * (1.0 - canyon) * (1.0 - mountain);
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
    ALBEDO    = base_col * mix(0.78, grass_shade, v_is_grass);
    ROUGHNESS = 0.9;

    // ── Зоны «битых данных»: сине-фиолетовый ЧАНКОВЫЙ глитч ──────────────────────
    // Квантуем мир в клетки glitch_cell → на клетку хеш (+ время = мерцание) выбирает
    // cyan / magenta / тёмный «бит». Рваными пятнами (второй хеш), светится (EMISSION).
    EMISSION = vec3(0.0);
    if (v_corrupt > 0.01) {
        vec2 cell = floor(v_world_xz / glitch_cell);
        float t = floor(TIME * glitch_speed);
        float n = hash2D(cell + vec2(t * 1.7, t * 0.9));
        vec3 g = (n < 0.42) ? corrupt_cyan : (n < 0.84 ? corrupt_magenta : vec3(0.02, 0.02, 0.05));
        float k = v_corrupt * step(0.25, hash2D(cell * 1.3 + vec2(5.0)));   // не сплошняк
        ALBEDO   = mix(ALBEDO, g, k);
        EMISSION = g * corrupt_glow * k;
    }
}
