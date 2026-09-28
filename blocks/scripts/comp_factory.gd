extends FactoryBlock

# COMPONENT FACTORY — варит КОМПОНЕНТЫ (G.Comp) из двух разных материалов и отдаёт их
# дальше по ленте.
#
# Отличие от фабрикатора одно, но принципиальное: тот выбрасывает БЛОК в мир — это конец
# цепочки, готовая вещь, которую игрок подбирает руками. Компонент же полуфабрикат, он обязан
# ехать дальше (в другой Component Factory за компонентом второго яруса или в фабрикатор), и
# потому уходит через push_item, а не под ноги.
#
# Правило двух разных материалов — то же и по той же причине: приёмник различает входы по
# виду материала. Рецепты лежат в G.COMP_RECIPE, здесь их нет.

const RESOURCE_SCENE: String = "res://resource.tscn"
## Пауза между попытками отдать готовое. Каждый кадр незачем: приёмник освобождается редко.
const PUSH_INTERVAL: float = 0.35

## Что варим — индекс G.Comp. Не тип G.Comp: enum живёт в автолоаде, в @export его не
## подставить. В игре это переключает игрок — долгое нажатие по блоку открывает выбор
## (factory_picker.gd), а сам выбор хранится в карте машины, чтобы пережить сейв.
@export var output_comp: int = 0
## Пауза варки, секунд.
@export var craft_time: float = 2.0

var _need: Dictionary = {}          # ключ материала → сколько надо
var _have: Dictionary = {}          # ключ материала → сколько лежит
var _crafting: bool = false
var _ready_count: int = 0           # сварено и ждёт отправки
var _push_t: float = 0.0
var _res_scene: PackedScene = null

func _ready() -> void:
	super._ready()
	_res_scene = load(RESOURCE_SCENE) as PackedScene
	_need = G.COMP_RECIPE.get(output_comp, {}).duplicate()

func try_receive(item: Node3D) -> bool:
	if not _factory_active() or _crafting or _need.is_empty():
		return false
	if item == null or not is_instance_valid(item):
		return false
	var kind: String = item.kind_key() if item.has_method("kind_key") else ""
	if not _need.has(kind):
		return false                       # не наш материал — пусть едет дальше
	var have: int = int(_have.get(kind, 0))
	if have >= int(_need[kind]):
		return false
	_have[kind] = have + 1
	item.queue_free()
	if _recipe_full():
		_start_craft()
	return true

## Продукт сменили — перечитываем рецепт, уже набранное сохраняем по тем же правилам,
## что и у фабрикатора (см. fabricator.reload_recipe).
func reload_recipe() -> void:
	_need = (G.COMP_RECIPE.get(output_comp, {}) as Dictionary).duplicate()
	for k in _have.keys():
		if _need.has(k):
			_have[k] = mini(int(_have[k]), int(_need[k]))
		else:
			_have.erase(k)

func _recipe_full() -> bool:
	for k in _need:
		if int(_have.get(k, 0)) < int(_need[k]):
			return false
	return true

func _start_craft() -> void:
	_crafting = true
	await get_tree().create_timer(craft_time).timeout
	if not is_instance_valid(self):
		return
	_have.clear()
	_crafting = false
	_ready_count += 1

# Готовое НЕ выбрасываем в мир, а ставим в очередь на ленту: пока принять некому, компонент
# ждёт внутри. Так цепочка не роняет деталь под гусеницы, когда следующий блок занят.
func _physics_process(delta: float) -> void:
	if _ready_count <= 0:
		return
	_push_t -= delta
	if _push_t > 0.0:
		return
	_push_t = PUSH_INTERVAL
	if not _factory_active():
		return                             # вне якоря фабрика стоит — готовое подождёт
	var item: Node3D = _make_item()
	if item == null:
		return
	# Предмет обязан быть в дереве до try_receive: приёмник его репарентит (как в storage).
	get_parent().add_child(item)
	item.global_position = global_position
	if push_item(item):
		_ready_count -= 1
	else:
		item.queue_free()                  # никто не принял — не плодим тела в мире

func _make_item() -> Node3D:
	if _res_scene == null:
		return null
	var it: Node3D = _res_scene.instantiate() as Node3D
	if it != null and it.has_method("set_component"):
		it.set_component(output_comp)
	return it
