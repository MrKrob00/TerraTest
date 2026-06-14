shader_type spatial;

// Настройки цвета руды
uniform vec3 ore_color : source_color = vec3(1.0, 0.75, 0.0); // Желтый
uniform vec3 emission_color : source_color = vec3(0.4, 0.25, 0.0); // Золотое свечение
uniform float emission_amount = 0.5;

// Настройки анимации
uniform float hit_duration = 0.35;
uniform float shake_intensity = 0.15;
uniform float shake_speed = 40.0;

// Переменная-мост для передачи времени удара из vertex во fragment
varying float v_last_hit_time;

void vertex() {
    float last_hit_time = INSTANCE_CUSTOM.r;
    float hp_percent = INSTANCE_CUSTOM.g; // 1.0 (целая) -> 0.0 (сломана)
    float respawn_time = INSTANCE_CUSTOM.b;
    
    v_last_hit_time = last_hit_time;
    
    // Если игра только запустилась, считаем руду целой
    if (hp_percent == 0.0 && last_hit_time == 0.0) {
        hp_percent = 1.0;
    }
    
    // Платформа на Y = 0 стоит смирно, а верхняя часть анимируется
    float y_factor = max(0.0, VERTEX.y);
    
    // Базовый масштаб по умолчанию
    float current_scale_y = mix(0.15, 1.0, hp_percent);
    float current_scale_xz = mix(1.4, 1.0, hp_percent);
    
    // 1. АНИМАЦИЯ ВОЗРОЖДЕНИЯ (ВЫРАСТАНИЕ ИЗ ЗЕМЛИ)
    if (respawn_time > 0.0) {
        float respawn_age = TIME - respawn_time;
        if (respawn_age < 0.6) {
            // Прогресс роста от 0.0 до 1.0
            float growth = smoothstep(0.0, 1.0, respawn_age / 0.6);
            
            // Руда плавно переходит от расплющенного состояния (0.15) до полного (1.0)
            current_scale_y = mix(0.15, 1.0, growth);
            // Ширина плавно сужается обратно от 1.4 до 1.0
            current_scale_xz = mix(1.4, 1.0, growth);
        }
    }
    
    // 2. ПРИМЕНЕНИЕ МАСШТАБА И ИСПРАВЛЕНИЕ ЗАВИСАНИЯ
    // Принудительно смещаем вершины вниз по мере изменения масштаба Y, чтобы они прижимались к платформе
    VERTEX.y = (VERTEX.y * current_scale_y) - (1.0 - current_scale_y);
    VERTEX.xz *= current_scale_xz;

    // 3. АНИМАЦИЯ ТРЯСКИ ПРИ УДАРЕ
    if (last_hit_time > 0.0) {
        float time_since_hit = TIME - last_hit_time;
        if (time_since_hit < hit_duration) {
            float fade = 1.0 - (time_since_hit / hit_duration);
            float wave = sin(time_since_hit * shake_speed) * shake_intensity * fade;
            
            VERTEX.x += wave * y_factor;
            VERTEX.z += cos(time_since_hit * shake_speed) * (shake_intensity * 0.5) * fade * y_factor;
        }
    }
}

void fragment() {
    // Принудительно генерируем плоские Low-Poly нормали для граней
    vec3 flat_normal = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
    NORMAL = (VIEW_MATRIX * vec4(flat_normal, 0.0)).xyz;

    ALBEDO = ore_color;
    ROUGHNESS = 0.4;
    METALLIC = 0.2;
    EMISSION = emission_color * emission_amount;
    
    // Белая вспышка при получении урона
    float time_since_hit = TIME - v_last_hit_time;
    if (v_last_hit_time > 0.0 && time_since_hit < 0.15) {
        float flash = (1.0 - (time_since_hit / 0.15)) * 0.6;
        ALBEDO += vec3(flash);
    }
}
