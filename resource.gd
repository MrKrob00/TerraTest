# resource_item.gd
extends RigidBody3D

enum Type { ORE, INGOT, COAL, CHUNK, COMPONENT }

# ВИД материала — это НЕ отдельная сцена, а поле на этой же. Руд четыре, слитков четыре,
# компонентов шесть — шестнадцать сцен ради шестнадцати видов держали бы в памяти шестнадцать
# копий одного и того же тела с одним и тем же коллайдером. Здесь всё различие — индекс и
# материал меша, а когда для каждого вида появится своя модель, она встанет сюда же: меш
# подменяется в _update_visual, физика и логика не трогаются вовсе.
#
# metal = индекс G.Metal, живёт у ORE и INGOT. -1 — старый ресурс без вида (сейвы и жилы,
# заданные до появления металлов): он честно остаётся «просто рудой», а не притворяется
# первым металлом, иначе одна такая руда молча стала бы Ferrite.
@export var metal: int = -1
## Индекс G.Comp — только у Type.COMPONENT.
@export var component: int = 0

# ЧАНК — предмет-КОНТЕЙНЕР: внутри до CHUNK_MAX блоков ОДНОГО типа. Нужен затем, чтобы
# блоки ездили по конвейеру, не будучи блоками: сами они RigidBody с коллизией и весом, и
# двадцать четыре штуки на ленте — это двадцать четыре физических тела. В чанке же на ленте
# всегда ОДИН предмет, сколько бы блоков в нём ни лежало, и ни лента, ни приёмник, ни склад
# о его существовании знать не обязаны — для них это обычный ресурс.
const CHUNK_MAX := 24
@export var chunk_block: int = 0     # G.Block внутри (0 = не чанк)
@export var chunk_count: int = 0     # сколько штук

@export var type: Type = Type.ORE

# Материалы для каждого типа — назначаешь в инспекторе
@export var ore_material: Material
@export var ingot_material: Material

## Вдали от игрока коллизия чанков не прогружена → ресурс проваливался «за окно коллизий»
## в пустоту. Вместо коллизии под каждым (сотни!) — прижимаем ресурс к ПОВЕРХНОСТИ heightmap
## (map.terrain_height_at, дешёвый сэмпл, есть всегда): он ложится на землю и, погасив
## скорость, засыпает — не жрёт физику. freeze НЕ трогаем — коллектор его собирает как обычно.
@export var rest_offset: float = 0.3          # приподнять над поверхностью, чтобы не тонул
var _map_cache: Node = null

func _map() -> Node:
	if _map_cache != null and is_instance_valid(_map_cache):
		return _map_cache
	var scene := get_tree().current_scene
	if scene:
		for c in scene.get_children():
			if c.has_method("terrain_height_at"):
				_map_cache = c
				return _map_cache
	_map_cache = get_node_or_null("/root/Main/map")
	return _map_cache

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var map := _map()
	if map == null:
		return
	var origin: Vector3 = state.transform.origin
	var h: float = map.terrain_height_at(origin) + rest_offset
	if origin.y < h:                          # опустились до/ниже поверхности — держим на ней
		var t := state.transform
		t.origin.y = h
		state.transform = t
		var v := state.linear_velocity
		if v.y < 0.0:
			v.y = 0.0                         # дальше не проваливаемся
		v.x *= 0.5
		v.z *= 0.5                            # опоры-трения нет — гасим скольжение → уснёт
		state.linear_velocity = v

# Тинт под цвет жилы, из которой выпала руда (ставит resource_node.set_tint).
# Материалы кешируются по цвету (static), чтобы руда одного цвета батчилась одним материалом.
static var _tint_mats: Dictionary = {}
var _tint: Color = Color.WHITE
var _has_tint: bool = false

func _ready() -> void:
	add_to_group("grass_benders")
	_update_visual()

# Красим руду под цвет жилы (вызывает жила при выбросе).
func set_tint(c: Color) -> void:
	_tint = c
	_has_tint = true
	_update_visual()

## Назначить металл (индекс G.Metal). Цвет берётся из общей таблицы, чтобы руда, слиток и
## сама жила были одного цвета: игрок узнаёт материал по виду, а не по подписи.
func set_metal(m: int) -> void:
	metal = m
	if m >= 0 and m < G.METAL_COLOR.size():
		set_tint(G.METAL_COLOR[m])
	else:
		_update_visual()

## Назначить компонент (индекс G.Comp).
func set_component(c: int) -> void:
	type = Type.COMPONENT
	component = c
	if c >= 0 and c < G.COMP_COLOR.size():
		set_tint(G.COMP_COLOR[c])
	else:
		_update_visual()

## Устойчивый ключ «что это за материал» — им говорят рецепты (G.BLOCK_RECIPE, G.COMP_RECIPE),
## по нему же фабрикатор различает свои два входа, а склад — что ему можно класть.
##
## Ключи слитка и компонента совпадают с G.metal_key/G.comp_key НЕ случайно: рецепт пишется
## один раз строкой вида "m0", и ни фабрикатору, ни складу не приходится знать, из чего эта
## строка сложена.
func kind_key() -> String:
	# У чанка «вид» — это ЧТО В НЁМ ЛЕЖИТ: чанки с разными блоками нельзя ссыпать вместе,
	# и склад с фабрикатором должны различать их так же, как слитки разных металлов.
	if type == Type.CHUNK:
		return "chunk:%d" % chunk_block
	if type == Type.COMPONENT:
		return G.comp_key(component)
	if type == Type.COAL:
		return "coal"
	if metal >= 0:
		# Руда и слиток одного металла — РАЗНЫЕ виды: рецепты просят слиток, и руда, попав
		# в фабрикатор, не должна засчитаться вместо него.
		return G.metal_key(metal) if type == Type.INGOT else "ore%d" % metal
	# Старый ресурс без металла: различаем по типу и тинту, как различали раньше.
	if not _has_tint:
		return str(type)
	return "%d#%08x" % [type, _tint.to_rgba32()]

## Настроить предмет ПО КЛЮЧУ вида — обратная kind_key. Нужна тем, кто хранит не предмет, а
## его вид: склад держит один показательный предмет и счётчик, Scrapper — очередь возврата.
func set_kind_key(key: String) -> void:
	# «chunk:» и «coal» разбираем ДО общего «c…», иначе они ушли бы в компоненты.
	if key.begins_with("chunk:"):
		type = Type.CHUNK
		chunk_block = int(key.substr(6))
		_update_visual()
	elif key.begins_with("ore"):
		type = Type.ORE
		set_metal(int(key.substr(3)))
	elif key == "coal":
		type = Type.COAL
		_update_visual()
	elif key.begins_with("m"):
		type = Type.INGOT
		set_metal(int(key.substr(1)))
	elif key.begins_with("c"):
		set_component(int(key.substr(1)))
	else:
		_update_visual()

# Вызывается Processor-ом. Металл при переплавке СОХРАНЯЕТСЯ: слиток из ферритовой руды —
# ферритовый, иначе четыре руды сошлись бы в один безликий слиток и рецепты стали бы фикцией.
func upgrade() -> void:
	match type:
		Type.ORE:
			type = Type.INGOT
		# COAL слитка НЕ имеет — процессор его не переплавляет, уголь остаётся углём.
		# КОМПОНЕНТЫ процессор не трогает: их варит только Component Factory по рецепту.
	_update_visual()

func _update_visual() -> void:
	var mesh = get_node_or_null("MeshInstance3D/ResourceMesh")
	if mesh == null:
		return
	# Форма: руда — шар, слиток — примятый (сплющенный) шар внутри внешней сферы.
	# Внешний шар (MeshInstance3D) не трогаем — меняем только внутренний ResourceMesh.
	# Чанк — кубик: видно, что это упаковка, а не руда. Сколько внутри, показывает склад
	# своей табличкой; рисовать счётчик на каждом едущем предмете было бы дорого.
	if type == Type.CHUNK:
		mesh.scale = Vector3(0.8, 0.8, 0.8)
		return
	# Компонент — вытянутая «деталь»: по силуэту сразу видно, что это уже не сырьё. Металл
	# различается цветом, а вот руда/слиток/деталь должны читаться и на расстоянии, где цвет
	# сливается, — поэтому у каждой ступени переработки своя форма.
	if type == Type.COMPONENT:
		mesh.scale = Vector3(0.5, 0.9, 1.2)
		if component >= 0 and component < G.COMP_COLOR.size():
			mesh.material_override = _tint_material(G.COMP_COLOR[component])
		return
	mesh.scale = Vector3(1.3, 0.3, 1.3) if type == Type.INGOT else Vector3.ONE
	# Уголь всегда тёмный (тинт жилы к нему не применяется).
	if type == Type.COAL:
		mesh.material_override = _coal_material()
		return
	if _has_tint:
		mesh.material_override = _tint_material(_tint)
		return
	match type:
		Type.ORE:
			if ore_material:
				mesh.material_override = ore_material
		Type.INGOT:
			if ingot_material:
				mesh.material_override = ingot_material

func _tint_material(c: Color) -> StandardMaterial3D:
	var key := c.to_rgba32()
	var cached = _tint_mats.get(key)
	if cached == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.emission_enabled = true
		m.emission = c * 0.4
		_tint_mats[key] = m
		cached = m
	return cached

static var _coal_mat: StandardMaterial3D = null
static func _coal_material() -> StandardMaterial3D:
	if _coal_mat == null:
		_coal_mat = StandardMaterial3D.new()
		_coal_mat.albedo_color = Color(0.12, 0.12, 0.14)
		_coal_mat.roughness = 0.95
	return _coal_mat
