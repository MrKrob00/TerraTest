@tool
extends EditorPlugin

# Registers the .blockgen importer. The plugin does nothing else: the work is in
# import_block.gd, and the block's shape is built by BlockBuilder.

var _importer: EditorImportPlugin = null

func _enter_tree() -> void:
	_importer = preload("res://addons/blockgen/import_block.gd").new()
	add_import_plugin(_importer)

func _exit_tree() -> void:
	if _importer != null:
		remove_import_plugin(_importer)
		_importer = null
