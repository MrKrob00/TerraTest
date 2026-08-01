extends Node

# --- НАЛАШТУВАННЯ ---
const TARGET_FPS: float = 55.0       # Цільовий FPS, нижче якого зменшуємо якість
const SAFE_FPS_UP: float = 58.0      # FPS, вище якого можна спробувати ПІДВИЩИТИ якість
const COOLDOWN_TIME: float = 3.0     # Скільки секунд чекати після ПІДВИЩЕННЯ, перш ніж підвищувати знову

const SCALE_MIN: float = 0.25        # Мінімальний масштаб (25%)
const SCALE_MAX: float = 2.0         # Максимальний масштаб (200% — супер-семплінг для топових пристроїв)
const SCALE_STEP: float = 0.1        # Крок зміни масштабу (10%)

# --- ВНУТРІШНІ ЗМІННІ ---
var current_scale: float = 1.0
var fps_buffer: Array[float] = []    # Буфер для усереднення кадрів
var buffer_size: int = 30            # Згладжування за останні 30 кадрів (~0.5 сек при 60 FPS)
var cooldown_timer: float = 0.0      # Таймер блокування підвищення

const SETTLE_TIME: float = 0.5       # Пауза после ЛЮБОЙ смены масштаба, пока буфер не наполнится заново
var settle_timer: float = 0.0        # реальными кадрами — иначе следующий тик судит по 1 кадру и сразу

# ── Настройки (управляются вкладкой НАСТРОЙКИ в гараже, персист в user://) ──────
const SETTINGS_PATH := "user://settings.json"
var auto_fps: bool = true            # ВКЛ = авто-скейл по FPS; ВЫКЛ = ручной масштаб
var manual_scale: float = 0.75       # масштаб рендера при выключенном авто
var shadows_enabled: bool = true     # тени от DirectionalLight3D2 (самая тяжёлая настройка на мобилке)
var terrain_low_quality: bool = false  # низкое качество рельефа (шейдер без попиксельного шума/тайла) — +FPS

# ── Умный размер интерфейса ────────────────────────────────────────────────────
# project.godot [display] = canvas_items: HUD масштабируется ЛИНЕЙНО с разрешением, и на
# больших планшетах кнопки раздувало. Гасим это: эффективный масштаб растёт как √(растяжения)
# и ограничен сверху — большой экран даёт лишь слегка больший UI, а не гигантский; маленький
# — не крохотный. Сверху ещё пользовательский множитель ui_scale (слайдер в настройках).
const UI_BASE := Vector2(1280, 720)  # = window/size/viewport_* в project.godot
const UI_SCALE_MIN := 0.7
const UI_SCALE_MAX := 1.4
var ui_scale: float = 1.0            # ручной множитель размера UI (слайдер)
var fullscreen: bool = false         # полноэкранный; иначе — плавающее окно (тянется мышью, UI сам подстраивается)

func _ready() -> void:
	current_scale = get_viewport().scaling_3d_scale
	_load_settings()
	_apply_window_mode()
	if not auto_fps:
		current_scale = manual_scale
		get_viewport().scaling_3d_scale = manual_scale
	_apply_shadows()
	_apply_terrain_quality()
	get_window().size_changed.connect(_apply_ui_scale)
	_apply_ui_scale()
	_setup_pc_input_map()

# Пересчёт content_scale_factor под текущее окно. Зовётся на старте и на каждый ресайз.
func _apply_ui_scale() -> void:
	var win := get_window()
	if win == null:
		return
	var size := Vector2(win.size)
	var stretch: float = minf(size.x / UI_BASE.x, size.y / UI_BASE.y)
	if stretch <= 0.0:
		stretch = 1.0
	# ПРИЧИНА бывшей «раздутости»: почти любой экран БОЛЬШЕ базы 1280×720 (stretch>1), а sqrt(stretch)
	# при stretch>1 даёт >1 → UI на 100% авто-увеличивался ВЫШЕ базового 1:1 у всех (у кого-то +5%,
	# на 1080p-телефоне +22%). Чиним: потолок авто-увеличения = 1.0 → на 100% ВСЕГДА ровно базовый
	# размер, а на мелких экранах (stretch<1) остаётся мягкий шринк для читаемости. Крупнее — ползунком.
	var target: float = clampf(sqrt(stretch), 0.85, 1.0)
	var csf: float = (target / stretch) * ui_scale
	# Guard от возможной петли (смена csf могла бы дёрнуть size_changed).
	if not is_equal_approx(win.content_scale_factor, csf):
		win.content_scale_factor = csf

# Полноэкранный ↔ ПЛАВАЮЩЕЕ ОКНО (только на ПК; мобилка всегда полноэкранная). В оконном режиме
# окно свободно тянется мышью, а UI подстраивается сам (size_changed → _apply_ui_scale + expand).
func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_window_mode()
	_save_settings()

func _apply_window_mode() -> void:
	if not OS.has_feature("pc"):
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen \
			else DisplayServer.WINDOW_MODE_WINDOWED)

func set_ui_scale(v: float) -> void:
	ui_scale = clampf(v, UI_SCALE_MIN, UI_SCALE_MAX)
	_apply_ui_scale()
	_save_settings()

# ── ПК-управление ──────────────────────────────────────────────────────────────
# Take/TakeOff/Building/Movement/Attack уже существуют как Input-действия (их проверяют
# event.is_action_pressed(...) / Input.is_action_pressed(...) в vehicle_body_3d.gd — код
# там не трогаем) но у них не было ни одной клавиши, только тач-кнопки. Плюс 4 новых
# действия для WASD/стрелок (движение читает Input.get_vector — см. vehicle_body_3d.gd).
# Биндим В КОДЕ, а не в project.godot: это идемпотентно (безопасно звать каждый старт) и
# не требует руками собирать текстовый ресурс InputMap, который тут негде прогнать через
# редактор и проверить, что он вообще парсится.
# Attack — Ctrl, не Space: Space это дефолтный ui_accept, и висел бы на любой сфокусированной
# кнопке гаража (клик по вкладке — и Space одновременно жмёт кнопку И стреляет).
# Движение — только WASD, без стрелок: стрелки в Godot по умолчанию уже листают фокус
# (ui_up/down/left/right), с ними вместе получалось бы «двигаю машину, листая список».
func _setup_pc_input_map() -> void:
	_bind_key("Take", KEY_E)
	_bind_key("TakeOff", KEY_Q)
	_bind_key("Building", KEY_B)
	_bind_key("Movement", KEY_ESCAPE)
	_bind_key("Attack", KEY_CTRL)
	_bind_key("move_forward", KEY_W)
	_bind_key("move_back", KEY_S)
	_bind_key("move_left", KEY_A)
	_bind_key("move_right", KEY_D)

func _bind_key(action: StringName, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)

# Вкл/выкл тени солнца. Самая тяжёлая графическая настройка на слабых GPU (Adreno 610) —
# отдельный тумблер, независимый от авто-FPS/масштаба рендера.
func set_shadows_enabled(on: bool) -> void:
	shadows_enabled = on
	_apply_shadows()
	_save_settings()

func _apply_shadows() -> void:
	var light := get_node_or_null("DirectionalLight3D2") as DirectionalLight3D
	if light:
		light.shadow_enabled = shadows_enabled

# Вкл/выкл низкое качество рельефа. Шейдер террейна пропускает попиксельный шум цвета и тайл-текстуру
# (самое дорогое во фрагменте) — заметный +FPS ценой мелкой детализации земли. Отдельный тумблер.
func set_terrain_low_quality(on: bool) -> void:
	terrain_low_quality = on
	_apply_terrain_quality()
	_save_settings()

func _apply_terrain_quality() -> void:
	var m := get_node_or_null("map")
	if m == null:
		for c in get_children():
			if c.has_method("set_terrain_low_quality"):
				m = c
				break
	if m != null and m.has_method("set_terrain_low_quality"):
		m.set_terrain_low_quality(terrain_low_quality)

# Вкл/выкл авто-FPS. При выключении сразу применяется ручной масштаб.
func set_auto_fps(on: bool) -> void:
	auto_fps = on
	if not on:
		current_scale = manual_scale
		get_viewport().scaling_3d_scale = manual_scale
	fps_buffer.clear()
	_save_settings()

# Ручной масштаб рендера (работает при выключенном авто).
func set_manual_scale(v: float) -> void:
	manual_scale = clampf(v, SCALE_MIN, SCALE_MAX)
	if not auto_fps:
		current_scale = manual_scale
		get_viewport().scaling_3d_scale = manual_scale
	_save_settings()

func _save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"auto_fps": auto_fps,
			"manual_scale": manual_scale,
			"shadows_enabled": shadows_enabled,
			"terrain_low_quality": terrain_low_quality,
			"ui_scale": ui_scale,
			"fullscreen": fullscreen,
		}))

func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if parsed is Dictionary:
		auto_fps = bool(parsed.get("auto_fps", true))
		manual_scale = clampf(float(parsed.get("manual_scale", 0.75)), SCALE_MIN, SCALE_MAX)
		shadows_enabled = bool(parsed.get("shadows_enabled", true))
		terrain_low_quality = bool(parsed.get("terrain_low_quality", false))
		ui_scale = clampf(float(parsed.get("ui_scale", 1.0)), UI_SCALE_MIN, UI_SCALE_MAX)
		fullscreen = bool(parsed.get("fullscreen", false))

func _process(delta: float) -> void:
	if not auto_fps:
		return                        # ручной режим: масштаб держит игрок
	# 1. Оновлюємо таймер затримки
	if cooldown_timer > 0:
		cooldown_timer -= delta
	if settle_timer > 0:
		settle_timer -= delta

	# 2. Збираємо статистику FPS (усереднюємо значення)
	fps_buffer.append(Engine.get_frames_per_second())
	if fps_buffer.size() > buffer_size:
		fps_buffer.pop_front()

	# Пока не улеглось после последней смены масштаба — не судим по свежему буферу
	# (1-2 кадра сразу после ресайза — не показатель, буфер ещё не набрал реальных значений)
	if settle_timer > 0:
		return

	# Обчислюємо середній FPS за останні пів секунди
	var sum: float = 0.0
	for f in fps_buffer:
		sum += f
	var avg_fps: float = sum / fps_buffer.size()

	# 3. ЛОГІКА ЗМІНИ РОЗДІЛЬНОЇ ЗДАТНОСТІ

	# КРИТИЧНЕ ПАДІННЯ: Якщо FPS впав нижче цілі — реагуємо МИТТЄВО
	if avg_fps < TARGET_FPS and current_scale > SCALE_MIN:
		change_scale(-SCALE_STEP)
		# Скидаємо буфер, щоб система оцінила новий FPS вже з новою роздільною здатністю
		fps_buffer.clear()
		settle_timer = SETTLE_TIME
		return

	# ПІДВИЩЕННЯ ЯКОСТІ: Тільки якщо FPS стабільно високий ТА пройшов час затримки (cooldown)
	if avg_fps >= SAFE_FPS_UP and current_scale < SCALE_MAX and cooldown_timer <= 0:
		change_scale(SCALE_STEP)
		fps_buffer.clear()
		settle_timer = SETTLE_TIME
		# Встановлюємо таймаут: не підвищувати якість наступні 3 секунди
		cooldown_timer = COOLDOWN_TIME

# Функція безпечної зміни масштабу
func change_scale(amount: float) -> void:
	current_scale = clamp(current_scale + amount, SCALE_MIN, SCALE_MAX)
	get_viewport().scaling_3d_scale = current_scale
	# Опціонально: розкоментуйте для увімкнення розумного згладжування AMD FSR
	# get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
