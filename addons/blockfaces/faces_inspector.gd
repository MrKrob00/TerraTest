@tool
extends EditorInspectorPlugin

# Puts the cube at the very top of any block's inspector (VehicleBlock and everything derived
# from it). It is now the ONLY way to set those values: the properties behind it are
# `@export_storage` (stored in the scene, no inspector widget of their own), because a second
# set of checkboxes beside the cube would be a second control for the same number — and one of
# the two would end up lying. The cube also spares you remembering which side is the block's back.

var undo_redo = null      # EditorUndoRedoManager, handed over by the plugin at registration

func _can_handle(object: Object) -> bool:
	return object is VehicleBlock

func _parse_begin(object: Object) -> void:
	var ed := preload("res://addons/blockfaces/faces_editor.gd").new()
	ed.setup(object as VehicleBlock, undo_redo)
	add_custom_control(ed)
