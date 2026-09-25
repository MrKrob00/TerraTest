extends Area3D
## A WEAPON'S ROUND, AS DEFINED IN ITS SCENE (Ammo/Bullet). Nothing flies as this node any more:
## BulletSim copies these numbers, the collision mask and the model into a Shot at every shot and
## steps, sweeps and draws all shots in one loop (see bullet_sim.gd). The node stays because it is
## where each weapon's ballistics are authored - WeaponBlock._ballistics reads its speed and drop
## for the lead - and where its model and that model's turn inside the round are set.

## Горизонтальная скорость пули (ед/с). Была 50 → пуля просаживалась под цель ещё на
## боевой дистанции (~15 ед) и «недолетала». Быстрее = меньше времени в полёте = меньше просадка.
@export var speed: float = 120.0
## Падение пули по гравитации (ед/с²-ish). Меньше → траектория ровнее, бьёт дальше прямо.
@export var bullet_gravity: float = 50.0
## Ниже этой высоты по Y (мир) полёт заканчивается — пуля ушла за землю/за окно коллизий.
@export var min_y: float = 0.0
## Жёсткий потолок времени жизни (с) — страховка от «вечных» пуль (напр. строго горизонтальных).
@export var max_lifetime: float = 3.0
## Marks this node as a round (WeaponBlock.fire_bullet checks `"dir" in` the template).
var dir: Vector3 = Vector3.ZERO
