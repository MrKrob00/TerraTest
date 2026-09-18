@tool
extends EditorPlugin

# ВЕСЬ ПЛАГИН — ЭТО ОДНА ПАНЕЛЬ В ИНСПЕКТОРЕ И КАМЕРА ВЬЮПОРТА. Больше ему делать нечего.
#
# Здесь был док на полторы тысячи строк: кисть с режимами и силой, генерация карты высот по
# семнадцати ползункам, окно прогресса с оценкой времени и кнопкой «Стоп», запекание в .res, в
# поток и в серый PNG, кнопка «создать ноду рельефа». Всё это обслуживало ОДИН тип земли —
# запечённую карту высот из файла (map.gd), и её в проекте больше нет: и мир, и фон меню стоят
# на чанковой земле, которая считается из сида и никаких файлов не читает.
#
# Что осталось:
#   • КАРТА СИДА в инспекторе ноды (terrain_inspector.gd → seed_browser.gd) — то, ради чего
#     существовала генерация: посмотреть, что даёт сид, не запуская игру;
#   • КАМЕРА РЕДАКТОРА, которую надо отдать ноде: своей в редакторе у неё нет, а превью
#     строится вокруг того, куда смотрят.
#
# Саму ноду добавляют обычным «Add Node → ChunkTerrain»: у скрипта есть class_name, и
# регистрировать для этого custom type незачем.

var _inspector: EditorInspectorPlugin = null
var _node: ChunkTerrain = null

func _enter_tree() -> void:
	_inspector = preload("res://addons/LiteTerrain/terrain_inspector.gd").new()
	_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector)

func _exit_tree() -> void:
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null

func _handles(object) -> bool:
	return object is ChunkTerrain

func _edit(object) -> void:
	_node = object as ChunkTerrain

## Камеру вьюпорта отдаём ноде и ничего больше не трогаем: ввод проходит дальше, как будто
## плагина нет. Превью по ней выбирает, какие узлы строить и где.
func _forward_3d_gui_input(viewport_camera: Camera3D, _event: InputEvent) -> int:
	if _node != null and is_instance_valid(_node):
		_node.set_editor_camera(viewport_camera)
	return EditorPlugin.AFTER_GUI_INPUT_PASS
