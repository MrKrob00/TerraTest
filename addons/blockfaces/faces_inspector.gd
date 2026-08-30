@tool
extends EditorInspectorPlugin

# Puts the cube at the very top of any block's inspector (VehicleBlock and everything derived
# from it). The face checkboxes stay where they are below — the cube does not replace them, it
# shows the same thing in a way that does not require remembering which side is the block's back.

var undo_redo = null      # EditorUndoRedoManager, handed over by the plugin at registration

func _can_handle(object: Object) -> bool:
	return object is VehicleBlock

func _parse_begin(object: Object) -> void:
	var ed := preload("res://addons/blockfaces/faces_editor.gd").new()
	ed.setup(object as VehicleBlock, undo_redo)
	add_custom_control(ed)
