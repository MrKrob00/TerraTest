@tool
extends EditorImportPlugin

# Файл .blockgen (небольшой JSON с параметрами блока) импортируется как ресурс Mesh.
# Благодаря этому блок ведёт себя как любой другой ассет: лежит в файловой панели,
# перетаскивается в поле Mesh любого MeshInstance3D и ПЕРЕСОБИРАЕТСЯ САМ, стоит поправить
# описание или BlockBuilder. Ни сцены-обёртки, ни скрипта на ноде, ни ручной «выпечки».
#
# Материал (текстура в памяти + фильтр nearest) кладётся внутрь меша и сохраняется вместе
# с ним, поэтому ассет остаётся резким, куда бы его ни назначили.

func _get_importer_name() -> String:
	return "worldtech.blockgen"

func _get_visible_name() -> String:
	return "WorldTech Block"

func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["blockgen"])

func _get_save_extension() -> String:
	return "res"

func _get_resource_type() -> String:
	return "Mesh"

func _get_priority() -> float:
	return 1.0

func _get_import_order() -> int:
	return 0

func _get_preset_count() -> int:
	return 1

func _get_preset_name(_preset_index: int) -> String:
	return "Default"

func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return []

func _get_option_visibility(_path: String, _option_name: StringName, _options: Dictionary) -> bool:
	return true

func _import(source_file: String, save_path: String, _options: Dictionary,
		_platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var text: String = FileAccess.get_file_as_string(source_file)
	if text.is_empty():
		push_error("BlockGen: не удалось прочитать %s" % source_file)
		return ERR_CANT_OPEN
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("BlockGen: %s — ожидался объект JSON" % source_file)
		return ERR_PARSE_ERROR
	var mesh: ArrayMesh = BlockBuilder.new(parsed).build()
	if mesh == null:
		push_error("BlockGen: не удалось собрать меш из %s" % source_file)
		return ERR_CANT_CREATE
	return ResourceSaver.save(mesh, "%s.%s" % [save_path, _get_save_extension()])
