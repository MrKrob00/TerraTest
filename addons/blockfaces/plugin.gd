@tool
extends EditorPlugin

# Adds a button-covered cube to a BLOCK's inspector (see faces_editor.gd). The plugin does
# nothing else: it registers its EditorInspectorPlugin and hands it the editor's shared undo
# stack — editing faces has to be undoable with Ctrl+Z like any other change.

var _ip: EditorInspectorPlugin = null

func _enter_tree() -> void:
	_ip = preload("res://addons/blockfaces/faces_inspector.gd").new()
	_ip.undo_redo = get_undo_redo()
	add_inspector_plugin(_ip)

func _exit_tree() -> void:
	if _ip != null:
		remove_inspector_plugin(_ip)
		_ip = null
