@tool
extends EditorInspectorPlugin

# Ставит кубик первым делом в инспекторе любого блока (VehicleBlock и всё, что от него
# наследуется). Галочки граней остаются на своих местах ниже — кубик их не подменяет, а
# показывает то же самое так, чтобы не приходилось держать в голове, где у блока «зад».

var undo_redo = null      # EditorUndoRedoManager, отдаёт плагин при регистрации

func _can_handle(object: Object) -> bool:
	return object is VehicleBlock

func _parse_begin(object: Object) -> void:
	var ed := preload("res://addons/blockfaces/faces_editor.gd").new()
	ed.setup(object as VehicleBlock, undo_redo)
	add_custom_control(ed)
