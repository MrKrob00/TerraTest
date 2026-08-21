@tool
extends EditorPlugin

# Добавляет в инспектор БЛОКА кубик с кнопками (см. faces_editor.gd). Больше плагин ничего
# не делает: он только регистрирует свой EditorInspectorPlugin и отдаёт ему общий стек
# отмены редактора — правка граней обязана отменяться Ctrl+Z, как любая другая.

var _ip: EditorInspectorPlugin = null

func _enter_tree() -> void:
	_ip = preload("res://addons/blockfaces/faces_inspector.gd").new()
	_ip.undo_redo = get_undo_redo()
	add_inspector_plugin(_ip)

func _exit_tree() -> void:
	if _ip != null:
		remove_inspector_plugin(_ip)
		_ip = null
