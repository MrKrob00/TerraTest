extends Node
# ИКОНКИ БЛОКОВ ПЕЧЁТ САМА ИГРА, ОДИН РАЗ НА УСТАНОВКУ.
#
# Почему не картинки в репозитории: они разойдутся с моделями при первой же замене меша, и
# разойдутся МОЛЧА — иконка останется прежней, а блок в мире станет другим. Плюс полсотни PNG
# в сборке. Здесь источник один и тот же: модель, из которой блок и собран.
#
# Почему при ЗАПУСКЕ, а не при открытии магазина: печь надо единожды на всю игру, а не в тот
# момент, когда игрок чего-то ждёт. Меню — первая сцена, и первые секунды в нём заняты счётом
# земли под фоновым боем; печь туда встаёт бесплатно. Узел — АВТОЛОАД, а не часть меню: игрок
# может нажать ИГРАТЬ через секунду после запуска, и работа обязана пережить смену сцены.
#
# ЧТО ПЕЧЁТСЯ — МОДЕЛЬ, А НЕ РАБОТАЮЩАЯ ДЕТАЛЬ. Живой блок в `_ready` строит купол щита радиусом
# четыре метра, кольца накопителя лазера, облако ремонта и оболочку повреждений; в габарит
# иконки всё это не входит и на картинке не нужно. Поэтому скрипты снимаются ДО добавления в
# дерево, а меши эффектов пропускаются по той же метке `block_fx`, по которой их пропускает
# `_local_aabb`.

## Сторона картинки. 128 — чтобы на планшете плитка не мылилась; в интерфейсе она уменьшается.
const ICON_PX := 128
## Папка в user://: рядом со слотами, но НЕ в слоте — иконки общие для всех трёх миров.
const DIR := "user://icons"
const STAMP := "user://icons/stamp.json"
## Сколько блоков печём за кадр. Один: кадр печи — это ещё и кадр меню, в котором крутится бой.
const PER_FRAME := 1
## Экспозиция и свет фотостудии. Диафрагма и выдержка — те же, что у мира (node_3d.tscn),
## поэтому люксы здесь значат ровно то же, что там.
const APERTURE := 19.0
const SHUTTER := 100.485
const AGX_CONTRAST := 1.7
const KEY_LUX := 90000.0
const FILL_LUX := 32000.0
const AMBIENT := 0.45

var _cache: Dictionary = {}             # тип блока → Texture2D
var _ready_done: bool = false
var _baking: bool = false

signal baked                            # печь закончила: интерфейс может перерисоваться

func _ready() -> void:
	# БЕЗ ЭКРАНА ПЕЧЬ НЕ РАБОТАЕТ, и это не ошибка: dummy-драйвер ничего не рисует, кадр выйдет
	# пустым. Самотест и любой headless-прогон должны просто пройти мимо.
	if DisplayServer.get_name() == "headless":
		return
	_maybe_bake.call_deferred()

## Испечено ли уже и тем ли составом. Метка хранит версию сборки, число иконок и НОМЕР РЕЦЕПТА:
## сменилась версия (значит, могли смениться модели), список блоков или сама съёмка — печём заново.
## Рецепт в метке обязателен: у игрока на диске уже лежит партия, снятая по-старому, а версия
## сборки и число блоков от правки света не меняются — без этого номера он остался бы с ней навсегда.
## 4: the mortar got its model (it was a grey box and a cylinder, and that is what the stamp kept).
## 5: the shotgun and the heavy cannon got theirs. 6: the cannon and the mortar cut to their cell.
## 7: the shield and the repair unit got models. 8: the radar. 9: the hull blocks.
## 10: half blocks became 45-degree triangles; the riser and stabiliser wheels got models.
## 11: the riser became TerraTech's two-cell bracket and swan-neck arm. 12: its heavy mount and cast arm.
## 13: the riser is the placeholder again. 14: the stabiliser without the artist's hub.
## 15: the conveyors got models. 16: the fork's arrows as open chevrons, belt textures lossless.
## 17: both supports got models (jacks). 18: redrawn after the GSO anchor.
## 19: the supports in our palette. 20: their deck blue down to the band.
## 21: armour plates x2 / x4 / x9 got models. 22: each one slab with detail.
## 23: the x2's slab sized to its one-cell height.
## 38: the storage got a model; the supports' decks plain (the fixed one bolted at the corners).
## 39: draft one-cell models for the component plant, the scrapper and the packer.
## 40: the component plant and the scrapper are 2x2x2; the fabricator got its model.
## 41: the plant is its press alone, the fabricator's pipe a short elbow at the front.
## 42: the plant is 2x1x2 with a drawing on its roof; belt mouths as wide as the belt.
## 43: Falsus sign plates on the seller, fabricator, plant and scrapper.
## 44: the battery's model (terminals, a charge gauge on every wall).
## 45: the battery is a cell in a cage; the wireless charger's model.
## 46: no cage: the battery is a cell as wide as the cell, the charger a spool.
## 47: the wireless charger is a Tesla coil on a GSO base.
## 48: the wireless charger after TerraTech's: a dome with a red band and two cyan coils.
## 49: the charger is its coils on a post, mounted by a plate on its back.
## 50: the charger is its two coils alone, held by a shell on the back face.
## 51: the repair unit is a gyro - four rings on six round bearings round the crystal.
## 52: the repair unit is the beacon again (the gyro is kept for Marlit).
## 53: the four Marlit hull blocks. 54: nine more Marlit blocks.
const RECIPE := 54
func _stamp_now() -> Dictionary:
	return {
		"v": String(ProjectSettings.get_setting("application/config/version", "dev")),
		"n": _block_list().size(),
		"r": RECIPE,
	}

func _maybe_bake() -> void:
	if _baking:
		return
	var want: Dictionary = _stamp_now()
	var have: Dictionary = {}
	if FileAccess.file_exists(STAMP):
		var f := FileAccess.open(STAMP, FileAccess.READ)
		if f != null:
			var d = JSON.parse_string(f.get_as_text())
			f.close()
			if d is Dictionary:
				have = d
	if String(have.get("v", "")) == String(want["v"]) and int(have.get("n", -1)) == int(want["n"]) \
			and int(have.get("r", -1)) == int(want["r"]):
		_ready_done = true
		baked.emit()
		return
	_bake_all()

## Блоки, у которых есть сцена. Снятые (RETIRED_BLOCKS) не печём: они существуют только ради
## старых сохранений и в интерфейсе не показываются.
func _block_list() -> Array:
	var out: Array = []
	for bt in G.Block.values():
		var b: int = int(bt)
		if b == G.Block.EMPTY or G.RETIRED_BLOCKS.has(b):
			continue
		if G.get_scene(b) == null:
			continue
		out.append(b)
	return out

func _bake_all() -> void:
	_baking = true
	DirAccess.make_dir_recursive_absolute(DIR)
	var st: Array = _make_studio(Vector2i(ICON_PX, ICON_PX))
	var sv: SubViewport = st[0]
	var cam: Camera3D = st[1]
	var n := 0
	for bt in _block_list():
		await _bake_one(sv, cam, int(bt))
		n += 1
		if n % PER_FRAME == 0:
			await get_tree().process_frame
	sv.queue_free()
	var f := FileAccess.open(STAMP, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_stamp_now()))
		f.close()
	_baking = false
	_ready_done = true
	baked.emit()

## THE PHOTO STUDIO, one for block portraits and machine pictures alike: the light, the exposure
## and the tone mapping are the ones the portraits were tuned with (see the notes inside), and a
## second copy for builds would drift from them at the first touch.
func _make_studio(px: Vector2i) -> Array:
	var sv := SubViewport.new()
	sv.size = px
	sv.transparent_bg = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Печь НЕ ДОЛЖНА ловить ввод и НЕ должна платить за физику: это фотостудия, а не мир.
	sv.own_world_3d = true
	sv.handle_input_locally = false
	sv.physics_object_picking = false
	add_child(sv)
	# СВЕТ В ИГРЕ МЕРЯЕТСЯ В ЛЮКСАХ (project.godot: use_physical_light_units), а люксы имеют смысл
	# только вместе с ЭКСПОЗИЦИЕЙ. Вьюпорт без CameraAttributes нормализации не имеет, солнце
	# приходит как есть, и любая ЗАТЕНЁННАЯ поверхность улетает в чистый белый — что и случилось:
	# половина иконок вышла белыми силуэтами. Текстурные блоки уцелели только потому, что их
	# материалы unshaded и света не видят вовсе.
	#
	# ОТРАЖЕНИЯ ВЫКЛЮЧЕНЫ, а не приглушены: без неба отражать нечего, а запасное «небо» движка
	# белое, и блестящий материал (roughness 0.5 у старых моделей) собирал его всей поверхностью.
	#
	# НЕБА ЗДЕСЬ НЕТ (transparent_bg), поэтому рассеянный свет задан цветом — иначе теневые грани
	# уходят в чёрный, и иконка читается силуэтом.
	var wenv := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.70, 0.82)
	env.ambient_light_energy = AMBIENT
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_agx_contrast = AGX_CONTRAST
	var ca := CameraAttributesPhysical.new()
	ca.exposure_aperture = APERTURE
	ca.exposure_shutter_speed = SHUTTER
	wenv.environment = env
	wenv.camera_attributes = ca
	sv.add_child(wenv)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	sv.add_child(cam)
	# Два источника. Один оставляет теневую грань чёрной, и кубик читается силуэтом, а не деталью.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	key.light_intensity_lux = KEY_LUX
	sv.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-14.0, 140.0, 0.0)
	fill.light_intensity_lux = FILL_LUX
	sv.add_child(fill)

	return [sv, cam]

func _bake_one(sv: SubViewport, cam: Camera3D, bt: int) -> void:
	var scn: PackedScene = G.get_scene(bt)
	if scn == null:
		return
	var src: Node3D = scn.instantiate()
	_strip(src)                              # снимаем скрипты ДО дерева: никаких куполов и колец
	sv.add_child(src)
	await get_tree().process_frame
	# Геометрию переносим в чистый узел: иконке нужны меши, а не работающая деталь с телами,
	# областями и лучом наводки.
	var model := Node3D.new()
	for c in _walk(src):
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible or _is_fx(mi) or _is_glow(mi):
			continue
		var cp := MeshInstance3D.new()
		cp.mesh = mi.mesh
		# The node's own material too, as the build thumbnails already copy it: a part the scene
		# tints (the shield's core, the repair crystal) came out untinted white without it.
		cp.material_override = mi.material_override
		model.add_child(cp)
		cp.global_transform = mi.global_transform
	src.queue_free()
	sv.add_child(model)
	await get_tree().process_frame
	var box: AABB = _aabb(model)
	if box.size.length() < 0.0001:
		model.queue_free()
		return
	# ТРИ ЧЕТВЕРТИ, А НЕ СБОКУ: у куба сбоку виден один квадрат, и кабина от брони ничем не
	# отличается. С угла видно три грани, то есть силуэт.
	var c3: Vector3 = box.get_center()
	var r: float = box.size.length() * 0.5
	var dir := Vector3(1.0, 0.8, 1.0).normalized()
	cam.look_at_from_position(c3 + dir * (r * 4.0), c3, Vector3.UP)
	cam.size = r * 2.05                      # чуть шире габарита: углы не режутся
	cam.near = 0.01
	cam.far = r * 12.0
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = sv.get_texture().get_image()
	# Имя файла — ЭНУМ-КЛЮЧ, как в сохранении (см. G.block_key): по номеру файл однажды достался
	# бы не тому блоку, а перенумерование enum это правка, которую никто не заметит.
	img.save_png("%s/%s.png" % [DIR, G.block_key(bt)])
	_cache.erase(bt)
	model.queue_free()

# ── Saved builds: a picture of the whole machine ────────────────────────────
## A build is shown by its MACHINE, assembled from the layout in the same studio as the portraits
## and photographed three-quarters from the FRONT (a machine drives along -Z). Files are named by
## the layout's CONTENT (`build_key`), not by the build's name: a rename keeps its picture, an
## edited build gets a new one, and the same build saved in two slots is one file. Baked when first
## asked for, one build at a time, and `build_baked` tells an open list to redraw.
signal build_baked
const BUILD_DIR := "user://build_thumbs"
const BUILD_PX := Vector2i(240, 160)
var _build_cache: Dictionary = {}       # key -> Texture2D
var _build_queue: Array = []            # [key, layout]
var _build_busy: bool = false

## The same layout gives the same key whether it came from a live machine (ints) or back from JSON
## (floats) - JSON.stringify would write 5 and 5.0 differently and bake every build twice.
func build_key(layout: Array) -> String:
	var parts: PackedStringArray = []
	for e in layout:
		if not (e is Dictionary):
			continue
		var r: Vector3 = BLOCKS_SCRIPT._read_rot(e)
		parts.append("%d,%d,%d,%s,%.2f,%.2f,%.2f" % [int(e.get("x", 0)), int(e.get("y", 0)),
				int(e.get("z", 0)), str(e.get("block", "")), r.x, r.y, r.z])
	return "%d_%08x" % [RECIPE, ";".join(parts).hash()]

## The picture, or NULL while it is being made. Asking for a missing one starts its bake.
func get_build_thumb(layout: Array) -> Texture2D:
	if layout.is_empty():
		return null
	var key := build_key(layout)
	if _build_cache.has(key):
		return _build_cache[key]
	var path := "%s/%s.png" % [BUILD_DIR, key]
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			var tex := ImageTexture.create_from_image(img)
			_build_cache[key] = tex
			return tex
	for q in _build_queue:
		if q[0] == key:
			return null
	_build_queue.append([key, layout.duplicate(true)])
	if not _build_busy:
		_bake_builds()
	return null

const BLOCKS_SCRIPT := preload("res://blocks.gd")

func _bake_builds() -> void:
	_build_busy = true
	while _baking:
		await get_tree().process_frame     # the portraits first: the shop is waiting on them
	DirAccess.make_dir_recursive_absolute(BUILD_DIR)
	var st: Array = _make_studio(BUILD_PX)
	var sv: SubViewport = st[0]
	var cam: Camera3D = st[1]
	while not _build_queue.is_empty():
		var job: Array = _build_queue.pop_front()
		await _bake_build(sv, cam, job[0], job[1])
		build_baked.emit()
	sv.queue_free()
	_build_busy = false

func _bake_build(sv: SubViewport, cam: Camera3D, key: String, layout: Array) -> void:
	# The machine is put together the way blocks.spawn_block puts it: the block on its anchor cell
	# (CENTER at the origin), turned by the entry's own rotation. Scripts go before the tree, as for
	# a portrait - no domes, no rings, no working parts.
	var src := Node3D.new()
	for e in layout:
		if not (e is Dictionary):
			continue
		var bt: int = G.block_from_key(e.get("block", ""))
		var scn: PackedScene = G.get_scene(bt) if bt != G.Block.EMPTY else null
		if scn == null:
			continue
		var inst: Node3D = scn.instantiate()
		_strip(inst)
		src.add_child(inst)
		inst.position = Vector3(float(e.get("x", 5)) - BLOCKS_SCRIPT.CENTER,
				float(e.get("y", 5)) - BLOCKS_SCRIPT.CENTER,
				float(e.get("z", 5)) - BLOCKS_SCRIPT.CENTER) * BLOCKS_SCRIPT.CELL_SIZE
		inst.rotation = BLOCKS_SCRIPT._read_rot(e)
	sv.add_child(src)
	await get_tree().process_frame
	var model := Node3D.new()
	for c in _walk(src):
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree() or _is_fx(mi) or _is_glow(mi):
			continue
		var cp := MeshInstance3D.new()
		cp.mesh = mi.mesh
		cp.material_override = mi.material_override
		model.add_child(cp)
		cp.global_transform = mi.global_transform
	src.queue_free()
	sv.add_child(model)
	await get_tree().process_frame
	var box: AABB = _aabb(model)
	if box.size.length() < 0.0001:
		model.queue_free()
		return
	var c3: Vector3 = box.get_center()
	var r: float = box.size.length() * 0.5
	var dir := Vector3(1.0, 0.75, -1.0).normalized()
	cam.look_at_from_position(c3 + dir * (r * 4.0), c3, Vector3.UP)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = r * 1.7                       # the frame is wider than tall: height is the limit
	cam.near = 0.01
	cam.far = r * 12.0
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = sv.get_texture().get_image()
	img.save_png("%s/%s.png" % [BUILD_DIR, key])
	_build_cache[key] = ImageTexture.create_from_image(img)
	model.queue_free()

## ЕДИНСТВЕННАЯ ДВЕРЬ НАРУЖУ. Пока не испечено — null, и вызывающий рисует как рисовал: иконка
## это украшение, а не условие работы магазина.
func get_icon(bt: int) -> Texture2D:
	if _cache.has(bt):
		return _cache[bt]
	var path := "%s/%s.png" % [DIR, G.block_key(bt)]
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(img)
	_cache[bt] = tex
	return tex

func is_ready() -> bool:
	return _ready_done

# ── Мелочи ───────────────────────────────────────────────────────────────────
func _strip(n: Node) -> void:
	n.set_script(null)
	for c in n.get_children():
		_strip(c)

## АДДИТИВНЫЙ МЕШ — ЭТО СВЕТ, А НЕ ДЕТАЛЬ. Приёмник и коллектор несут по капсуле в четыре метра
## с `blend_mode = ADD`: в мире это луч всасывания, а в габарите портрета — палка, рядом с которой
## сам блок сжимается в точку. Метки `block_fx` на ней нет и быть не должно (она живёт в сцене
## блока, а не в эффектах), поэтому отличаем по материалу: сложение с фоном рисуют только свечения.
func _is_glow(mi: MeshInstance3D) -> bool:
	for s in mi.mesh.get_surface_count():
		var m: Material = mi.get_surface_override_material(s)
		if m == null:
			m = mi.mesh.surface_get_material(s)
		var bm := m as BaseMaterial3D
		if bm != null and bm.blend_mode == BaseMaterial3D.BLEND_MODE_ADD:
			return true
	return false

func _is_fx(n: Node) -> bool:
	var cur: Node = n
	while cur != null:
		if cur.has_meta("block_fx"):
			return true
		# Купол щита — не эффект, а физическое тело (он ловит снаряды), метки на нём нет.
		# Отличаем его той же дверью, которой это делает вся игра.
		if cur.has_method("struck"):
			return true
		if cur.name == "Ammo":
			return true          # пул снарядов стоит у дула и деталью не является
		cur = cur.get_parent()
	return false

func _aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for c in _walk(n):
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out

func _walk(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_walk(c))
	return out
