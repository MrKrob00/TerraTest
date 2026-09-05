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

# ── Умный размер интерфейса ────────────────────────────────────────────────────
# project.godot [display] = canvas_items: HUD масштабируется ЛИНЕЙНО с разрешением, и на
# больших планшетах кнопки раздувало. Гасим это: эффективный масштаб растёт как √(растяжения)
# и ограничен сверху — большой экран даёт лишь слегка больший UI, а не гигантский; маленький
# — не крохотный. Сверху ещё пользовательский множитель ui_scale (слайдер в настройках).
const UI_BASE := Vector2(1280, 720)  # = window/size/viewport_* в project.godot
const UI_SCALE_MIN := 0.7
const UI_SCALE_MAX := 1.4
## Эталонная диагональ экрана в дюймах — планшет, на котором раскладка выглядит правильно.
## Меньше эталона (телефон) → интерфейс УВЕЛИЧИВАЕМ, иначе кнопка под пальцем мельчает
## физически, даже если в пикселях она та же.
const UI_REF_INCHES := 9.5
const UI_PHYS_MIN := 0.95
const UI_PHYS_MAX := 1.55
var ui_scale: float = 1.0            # ручной множитель размера UI (слайдер)
var fullscreen: bool = false         # полноэкранный; иначе — плавающее окно (тянется мышью, UI сам подстраивается)

# ══════════════════════════════════════════════════════════════════════════════
# ОТЛАДОЧНЫЕ ПЕРЕКЛЮЧАТЕЛИ
# ══════════════════════════════════════════════════════════════════════════════
# Один список в одном месте: включить/выключить кусок мира, не трогая код. Проверить цепочку
# без врагов на голове, посмотреть биом с одним типом руды, погонять по карте без обучения.
#
# ЧИТАЮТ ИХ ЧЕРЕЗ `G.debug("имя_флага")`, а не напрямую: флаги живут на узле сцены, и половина
# читателей (жилы, спавнер, ИИ врага, рейды) должна работать и без него — в тестовой сцене,
# в редакторе, в мире, где Main ещё не готов. Аксессор возвращает ЗНАЧЕНИЕ ПО УМОЛЧАНИЮ, если
# спросить не у кого, поэтому «нет Main» никогда не значит «выключено».
#
# МАСТЕР-ВЫКЛЮЧАТЕЛЬ СНЯТ ПО УМОЛЧАНИЮ, и это не перестраховка: собранная игра обязана вести
# себя как игра, даже если кто-то забыл вернуть галочку на место. Пока он снят, весь список
# ниже не значит ничего.
@export_group("Отладка")
@export var debug_overrides: bool = false

@export_subgroup("Руда")
## Какие типы жил кладутся на карту. Снятый тип не заменяется другим — жила просто не появится:
## так видно, сколько именно её на карте, а не «сколько осталось после подмены».
@export var ore_ferrite: bool = true
@export var ore_cuprite: bool = true
@export var ore_silicate: bool = true
@export var ore_titanite: bool = true
@export var ore_coal: bool = true

@export_subgroup("Враги")
## Общий поток врагов вокруг игрока. КВЕСТОВЫЕ машины он не трогает: задание, которое молча
## не может начаться, отлаживать хуже, чем лишнего врага в поле.
@export var enemy_spawn: bool = true
## ИИ: цели, погоня, патруль, стрельба. Выключенный враг стоит на месте целым — по нему удобно
## смотреть сборку и попадания.
@export var enemy_ai: bool = true
## Укреплённые точки на карте (outposts.gd) и налёты на базу игрока (raids.gd).
@export var outposts: bool = true
@export var raids: bool = true
## Редкое событие «проверка сектора» с захватчиком.
@export var sector_scan: bool = true

@export_subgroup("Игрок")
## Блоки машин игрока не получают урона. Ремонт, разбор и снятие блоков работают как обычно —
## это именно «не бьётся», а не «бессмертная сцена».
@export var player_invulnerable: bool = false
## Энергия не тратится: щит, реген, фабрика и шахтёр работают без панелей и аккумуляторов.
@export var infinite_energy: bool = false

@export_subgroup("Мир")
## Обучение на новом сейве. Снято — игрок сразу в мире, а первый враг приходит общим потоком.
@export var tutorial: bool = true
## Панель профиля открыта с самого старта, без тапа по счётчику FPS.
@export var profiler_on_start: bool = false

func _ready() -> void:
	current_scale = get_viewport().scaling_3d_scale
	_load_settings()
	_apply_window_mode()
	if not auto_fps:
		current_scale = manual_scale
		get_viewport().scaling_3d_scale = manual_scale
	_apply_shadows()
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
	var target: float = clampf(sqrt(stretch), 0.85, 1.0)
	var csf: float = (target / stretch) * ui_scale * _physical_ui_factor()
	# Guard от возможной петли (смена csf могла бы дёрнуть size_changed).
	if not is_equal_approx(win.content_scale_factor, csf):
		win.content_scale_factor = csf

## Поправка на ФИЗИЧЕСКИЙ размер экрана.
##
## Масштаб выше считается только от разрешения, а палец меряет не пиксели, а миллиметры.
## Телефон 2400×1080 и планшет 2000×1200 дают почти одинаковый множитель, но диагональ у
## них отличается вдвое — и кнопка, удобная на планшете, на телефоне оказывается мелкой.
## Отсюда правило: чем меньше диагональ, тем крупнее интерфейс. Корень, а не прямая
## пропорция: иначе на маленьком экране кнопки съели бы его целиком.
func _physical_ui_factor() -> float:
	var dpi: int = DisplayServer.screen_get_dpi()
	# DPI на части платформ приходит заглушкой (72) или мусором — тогда поправку не делаем
	# вовсе: лучше прежний размер, чем случайный.
	if dpi < 100 or dpi > 800:
		return 1.0
	var px := Vector2(DisplayServer.screen_get_size())
	if px.x < 1.0 or px.y < 1.0:
		return 1.0
	var inches: float = px.length() / float(dpi)
	if inches < 3.0 or inches > 40.0:
		return 1.0
	return clampf(sqrt(UI_REF_INCHES / inches), UI_PHYS_MIN, UI_PHYS_MAX)

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

func _setup_pc_input_map() -> void:
	_bind_key("Take", KEY_E)
	_bind_key("TakeOff", KEY_Q)
	_bind_key("Building", KEY_B)
	_bind_key("Movement", KEY_ESCAPE)
	_bind_key("ModeToggle", KEY_TAB)    # то же, что тап по единственной кнопке режима на HUD
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
