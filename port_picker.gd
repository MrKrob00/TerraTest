extends Control
class_name PortPicker

# ПОРТЫ многоклеточного фабричного блока: показываем, какая клетка какой стороны — вход, а
# какая — выход. ТОЛЬКО ПОКАЗЫВАЕМ: настраиваются они в сцене блока (плагин addons/blockfaces),
# и в игре их менять нельзя — см. комментарий у куба ниже.
#
# У односкеточного блока сторона и есть коннектор. А у блока 2×2×2 одна сторона это ЧЕТЫРЕ
# клетки, и «вход слева» означало бы вход во все четыре левые клетки сразу: подвести две разные
# ленты с одной стороны было бы нельзя — ради этого поклеточность и делалась.
#
# Окно показывает САМ БЛОК кубиком (port_cube.gd). Кубов два, они смотрят с противоположных
# углов, поэтому все шесть сторон видны сразу и вертеть ничего не нужно.
#
# Грани здесь — в осях КАРТЫ, как и сами порты (см. FactoryBlock): футпринт многоклеточного
# блока от поворота не зависит, и показывать его в локальных осях значило бы врать игроку
# про то, где у блока «лево».

## ОКНО — СЦЕНА, а не двести строк .new(). Узлами описано всё, что СТОИТ: затемнение,
## центрирование, панель, заголовок, подсказка, легенда (её цвета — те же, что у состояний
## кубика, см. port_cube.colors), кнопка CLOSE и сам кубик. Кодом осталось то, что зависит от
## блока и от РАЗМЕРА ЭКРАНА: имя блока в заголовке, ширина панели и высота кубика (их считают
## от вьюпорта — на низком экране зашитые числа выносили CLOSE за край), плюс подписки и опрос
## состояния граней.
##
## ЗАГРУЖАЕМ ЛЕНИВО, а не preload: сцена держит ЭТОТ ЖЕ скрипт, и preload сцены из её
## собственного скрипта — это цикл «скрипт → сцена → скрипт» на этапе компиляции. load() ходит
## в кеш ResourceLoader, то есть со второго открытия стоит поиск по словарю.
const SCENE_PATH := "res://port_picker.tscn"

const PANEL_W: float = 460.0

var _block: FactoryBlock = null
var _blocks_root: Node = null
var _offsets: Array = []          # смещения клеток футпринта от якоря

## Открыть для блока. null — блок не фабричный, односкеточный или не нашли его машину.
static func open_for(host: Node, block: Node) -> PortPicker:
	if not (block is FactoryBlock):
		return null
	var root: Node = block.get_parent()
	while root != null and not root.has_method("set_block_port"):
		root = root.get_parent()
	if root == null:
		return null
	var offs: Array = root.footprint_offsets(block)
	if offs.size() <= 1:
		return null                # односкеточному блоку хватает галочек: настраивать нечего
	var p: PortPicker = (load(SCENE_PATH) as PackedScene).instantiate()
	p._block = block as FactoryBlock
	p._blocks_root = root
	p._offsets = offs
	host.add_child(p)
	p._build()
	return p

func _build() -> void:
	var vp: Vector2 = get_viewport_rect().size
	# Панель НЕ ШИРЕ ЭКРАНА: на телефоне 460 точек не влезают, и окно уезжало за край.
	var panel: PanelContainer = %Panel
	panel.custom_minimum_size = Vector2(minf(PANEL_W, vp.x - 48.0), 0.0)
	(%Title as Label).text = "PORTS — %s" % G.block_name(int(_block.block))

	# Тап МИМО окна закрывает его — это на затемнении, а не на самом окне: окно ловит тапы
	# (mouse_filter STOP у корня), иначе они уходили бы в мир под ним.
	(%Dim as ColorRect).gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and e.pressed) or (e is InputEventScreenTouch and e.pressed):
			close())
	(%CloseButton as Button).pressed.connect(close)

	# САМ БЛОК, а не список сторон. Шесть подписанных сеток заставляли держать в голове, где
	# у блока «зад» и «низ», и сверять это с тем, как он стоит на машине. На кубе тыкаешь в
	# ту грань, которую видишь; два куба смотрят с противоположных углов, поэтому видны все
	# шесть сторон сразу и крутить ничего не надо.
	var cube: PortCube = %Cube
	cube.cells = _offsets
	cube.custom_minimum_size = Vector2(0.0, clampf(vp.y - 260.0, 170.0, 380.0))
	cube.state_of = func(off: Vector3i, di: int) -> int:
		return _block.port_state(off, di) if is_instance_valid(_block) else 0
	cube.queue_redraw()
	# on_click НЕ ставим намеренно: в игре окно только ПОКАЗЫВАЕТ, где у блока вход и выход.
	# Стороны блока — свойство самого блока, а не машины: их задают в сцене (плагин
	# addons/blockfaces), и цепочку строят под известную деталь, а не перенастраивают деталь
	# под цепочку. Правка в игре означала бы, что один и тот же блок у двух игроков работает
	# по-разному, а разбирать конвейер, который «почему-то не идёт», пришлось бы вслепую.

func close() -> void:
	queue_free()
