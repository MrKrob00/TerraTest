extends RefCounted
class_name FactoryRecipeCatalog

static func list_components() -> Array:
	var out: Array = []
	for i in range(G.COMP_NAME.size()):
		out.append({
			"id": i,
			"kind": "component",
			"name": G.kind_name(G.comp_key(i)),
			"category": "basic" if i < G.COMP_SIMPLE_COUNT else "advanced",
			"recipe": (G.COMP_RECIPE.get(i, {}) as Dictionary).duplicate(),
			"color": G.COMP_COLOR[i] if i < G.COMP_COLOR.size() else Color.WHITE,
		})
	return out

static func list_blocks() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	var lists: Dictionary = {}
	for key in G.BLOCK_CATEGORIES:
		var names: Array = []
		for bt in G.BLOCK_CATEGORIES[key]:
			var block_id: int = int(bt)
			if G.block_recipe(block_id).is_empty():
				continue
			names.append(block_id)
			seen[block_id] = true
		lists[key] = names
	for bt in G.BLOCK_RECIPE:
		var block_id: int = int(bt)
		if seen.has(block_id):
			continue
		if not lists.has("power"):
			lists["power"] = []
		(lists["power"] as Array).append(block_id)
	for key in lists:
		for bt in lists[key]:
			var recipe: Dictionary = (G.BLOCK_RECIPE.get(int(bt), {}) as Dictionary).duplicate()
			if recipe.is_empty():
				continue
			out.append({
				"id": int(bt),
				"kind": "block",
				"name": G.block_name(int(bt)),
				"category": String(key),
				"recipe": recipe,
				"color": Color(0.55, 0.78, 0.82),
			})
	return out

static func entries_for(block: Node) -> Array:
	if block == null or not is_instance_valid(block):
		return []
	if "output_comp" in block:
		return list_components()
	if "output_block" in block:
		return list_blocks()
	return []

static func current_entry_id(block: Node, is_comp: bool) -> int:
	if block == null or not is_instance_valid(block):
		return 0
	if is_comp:
		return int(block.get("output_comp", 0))
	return int(block.get("output_block", 0))
