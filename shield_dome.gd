# shield_dome.gd — физический купол щита (StaticBody3D-сфера на слое блоков).
# Снаряды/лучи попадают в него и зовут hurt() — урон пересылается блоку щита,
# который списывает энергию машины вместо HP.
extends StaticBody3D

var owner_vehicle: Node = null   # корень машины-владельца: свои пули купол пропускают

func hurt(damage: int = 10) -> void:
	var shield := get_parent()
	if shield and shield.has_method("absorb"):
		shield.absorb(damage)
