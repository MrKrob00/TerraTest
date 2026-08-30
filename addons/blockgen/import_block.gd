@tool
extends EditorImportPlugin

# A .blockgen file (a small JSON of block parameters) is imported as a Mesh resource. That makes
# a block behave like any other asset: it sits in the file dock, drags into the Mesh field of any
# MeshInstance3D, and REBUILDS ITSELF as soon as the description or BlockBuilder changes. No
# wrapper scene, no script on the node, no baking by hand.
#
# The material (an in-memory texture plus a nearest filter) is put inside the mesh and saved with
# it, so the asset stays crisp wherever it is assigned.

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
		push_error("BlockGen: could not read %s" % source_file)
		return ERR_CANT_OPEN
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("BlockGen: %s — expected a JSON object" % source_file)
		return ERR_PARSE_ERROR
	var mesh: ArrayMesh = BlockBuilder.new(parsed).build()
	if mesh == null:
		push_error("BlockGen: could not build a mesh from %s" % source_file)
		return ERR_CANT_CREATE
	return ResourceSaver.save(mesh, "%s.%s" % [save_path, _get_save_extension()])
