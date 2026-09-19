# shield_dome.gd — физический купол щита (StaticBody3D-сфера на слое блоков).
# Снаряды/лучи попадают в него и зовут hurt() — урон пересылается блоку щита,
# который списывает энергию машины вместо HP.
extends StaticBody3D

var owner_vehicle: Node = null   # корень машины-владельца: свои пули купол пропускают

func hurt(damage: int = 10) -> void:
	var shield := get_parent()
	if shield and shield.has_method("absorb"):
		shield.absorb(damage)

## ПОПАДАНИЕ В КУПОЛ — ОДНА ДВЕРЬ, И ОНА ЗДЕСЬ. Оружие звало BlockFX напрямую, и всё, что
## купол показывает на удар, было расписано по стороне стреляющего: добавить туда волну от
## точки удара значило бы держать половину эффекта у пушки, а половину у щита.
func struck(world_pos: Vector3) -> void:
	BlockFX.shield_spark(self, world_pos)
	var shield := get_parent()
	if shield and shield.has_method("mark_hit_point"):
		shield.mark_hit_point(world_pos)
