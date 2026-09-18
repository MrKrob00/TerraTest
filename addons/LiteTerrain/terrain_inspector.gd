@tool
extends EditorInspectorPlugin

# Ставит карту сида на самый верх инспектора чанковой земли (см. seed_browser.gd) — так же, как
# кубик граней стоит наверху инспектора блока.
#
# ПОЧЕМУ ИМЕННО В ИНСПЕКТОРЕ, А НЕ В ДОКЕ. Сид — свойство НОДЫ, и смотреть на него надо там же,
# где его правят. Пока он жил в доке, приходилось помнить, какая нода сейчас выбрана и тому ли
# миру принадлежит число в поле; в инспекторе этот вопрос не возникает вовсе.

var undo_redo = null      # EditorUndoRedoManager, выдаёт плагин при регистрации

## Чанковая земля узнаётся ПО УМЕНИЮ, а не по классу: у неё нет class_name, а `is` по пути
## скрипта — это ещё одна строка, которая разъедется при переносе файла.
func _can_handle(object: Object) -> bool:
	return object != null and object.has_method("preview_build")

func _parse_begin(object: Object) -> void:
	var ed := preload("res://addons/LiteTerrain/seed_browser.gd").new()
	ed.setup(object as Node, undo_redo)
	add_custom_control(ed)
