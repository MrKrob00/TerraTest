extends Node

# --- НАЛАШТУВАННЯ ---
const TARGET_FPS: float = 55.0       # Цільовий FPS, нижче якого зменшуємо якість
const SAFE_FPS_UP: float = 58.0      # FPS, вище якого можна спробувати ПІДВИЩИТИ якість
const COOLDOWN_TIME: float = 3.0     # Скільки секунд чекати після ПІДВИЩЕННЯ, перш ніж підвищувати знову

const SCALE_MIN: float = 0.5         # Мінімальний масштаб (50%)
const SCALE_MAX: float = 1.0         # Максимальний масштаб (100%)
const SCALE_STEP: float = 0.05       # Крок зміни масштабу (5%)

# --- ВНУТРІШНІ ЗМІННІ ---
var current_scale: float = 1.0
var fps_buffer: Array[float] = []    # Буфер для усереднення кадрів
var buffer_size: int = 30            # Згладжування за останні 30 кадрів (~0.5 сек при 60 FPS)
var cooldown_timer: float = 0.0      # Таймер блокування підвищення

# ── Настройки (управляются вкладкой НАСТРОЙКИ в гараже, персист в user://) ──────
const SETTINGS_PATH := "user://settings.json"
var auto_fps: bool = true            # ВКЛ = авто-скейл по FPS; ВЫКЛ = ручной масштаб
var manual_scale: float = 0.75       # масштаб рендера при выключенном авто

func _ready() -> void:
	current_scale = get_viewport().scaling_3d_scale
	_load_settings()
	if not auto_fps:
		current_scale = manual_scale
		get_viewport().scaling_3d_scale = manual_scale

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
		f.store_string(JSON.stringify({"auto_fps": auto_fps, "manual_scale": manual_scale}))

func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if parsed is Dictionary:
		auto_fps = bool(parsed.get("auto_fps", true))
		manual_scale = clampf(float(parsed.get("manual_scale", 0.75)), SCALE_MIN, SCALE_MAX)

func _process(delta: float) -> void:
	if not auto_fps:
		return                        # ручной режим: масштаб держит игрок
	# 1. Оновлюємо таймер затримки
	if cooldown_timer > 0:
		cooldown_timer -= delta

	# 2. Збираємо статистику FPS (усереднюємо значення)
	fps_buffer.append(Engine.get_frames_per_second())
	if fps_buffer.size() > buffer_size:
		fps_buffer.pop_front()
	
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
		return

	# ПІДВИЩЕННЯ ЯКОСТІ: Тільки якщо FPS стабільно високий ТА пройшов час затримки (cooldown)
	if avg_fps >= SAFE_FPS_UP and current_scale < SCALE_MAX and cooldown_timer <= 0:
		change_scale(SCALE_STEP)
		fps_buffer.clear()
		# Встановлюємо таймаут: не підвищувати якість наступні 3 секунди
		cooldown_timer = COOLDOWN_TIME 

# Функція безпечної зміни масштабу
func change_scale(amount: float) -> void:
	current_scale = clamp(current_scale + amount, SCALE_MIN, SCALE_MAX)
	get_viewport().scaling_3d_scale = current_scale
	# Опціонально: розкоментуйте для увімкнення розумного згладжування AMD FSR
	# get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
