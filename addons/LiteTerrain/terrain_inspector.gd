@tool
extends EditorInspectorPlugin

# Puts the ground's preview buttons (preview_panel.gd) at the top of the chunked ground's inspector,
# the way the face cube stands at the top of a block's.

## Чанковая земля узнаётся ПО УМЕНИЮ, а не по классу: `is` по пути скрипта — это ещё одна строка,
## которая разъедется при переносе файла.
func _can_handle(object: Object) -> bool:
	return object != null and object.has_method("preview_build")

func _parse_begin(object: Object) -> void:
	var ed := preload("res://addons/LiteTerrain/preview_panel.gd").new()
	ed.setup(object as Node)
	add_custom_control(ed)
