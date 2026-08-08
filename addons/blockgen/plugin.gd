@tool
extends EditorPlugin

# Регистрирует импортёр .blockgen. Больше плагин ничего не делает: вся работа в
# import_block.gd, а форму блока строит BlockBuilder.

var _importer: EditorImportPlugin = null

func _enter_tree() -> void:
	_importer = preload("res://addons/blockgen/import_block.gd").new()
	add_import_plugin(_importer)

func _exit_tree() -> void:
	if _importer != null:
		remove_import_plugin(_importer)
		_importer = null
