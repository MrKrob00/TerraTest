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
# What is left:
#   • the PREVIEW BUTTONS at the top of the node's inspector (terrain_inspector.gd ->
#     preview_panel.gd): build the real ground in the editor, which is how the ground material's
#     settings are seen while they are tuned. The seed map that stood over them is gone (the
#     player's call);
#   • the EDITOR CAMERA, handed to the node: it has none of its own in the editor, and the preview
#     is built round where the view is.
#
# Саму ноду добавляют обычным «Add Node → ChunkTerrain»: у скрипта есть class_name, и
# регистрировать для этого custom type незачем.

var _inspector: EditorInspectorPlugin = null
var _node: ChunkTerrain = null

func _enter_tree() -> void:
	_inspector = preload("res://addons/LiteTerrain/terrain_inspector.gd").new()
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
