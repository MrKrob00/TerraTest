extends Node

var money = 50

func add_money(value):
	money+= value
	# Заработок двигает задания «заработай денег». Q грузится после G — берём безопасно.
	var q = get_node_or_null("/root/Q")
	if q:
		q.report("money_earned", value)

var block_inventory = []

# ─── Сохранённые сборки машины ────────────────────────────────────────────────
# name -> layout (массив {x,y,z,block,rot_y}, как blocks.get_layout()). Персистится в user://.
var saved_builds: Dictionary = {}
const BUILDS_PATH := "user://vehicle_builds.json"

func _ready() -> void:
	_load_builds()

func save_build(build_name: String, layout: Array) -> void:
	saved_builds[build_name] = layout
	_persist_builds()

func delete_build(build_name: String) -> void:
	saved_builds.erase(build_name)
	_persist_builds()

func _persist_builds() -> void:
	var f = FileAccess.open(BUILDS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(saved_builds))
		f.close()

func _load_builds() -> void:
	if not FileAccess.file_exists(BUILDS_PATH):
		return
	var f = FileAccess.open(BUILDS_PATH, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		saved_builds = data

# Кол-во блоков по типам в раскладке (значения из JSON приходят float — приводим к int).
func layout_counts(layout: Array) -> Dictionary:
	var c: Dictionary = {}
	for e in layout:
		var t := int(e["block"])
		c[t] = c.get(t, 0) + 1
	return c

enum Block {
	EMPTY,
	CABIN,#1
	WHEEL,#2
	BLOCK,#3
	DRILL,#4
	COLLECTOR,#5
	INTAKE,#6
	BELT,#7
	PROCESSOR,#8
	SELLER,#9
	LASER,#10
	GUN,#11
}
@onready var cabin_scene: PackedScene = preload("res://cabin.tscn")
@onready var wheel_scene: PackedScene = preload("res://wheel.tscn")
@onready var block_scene: PackedScene = preload("res://block.tscn")
@onready var drill_scene: PackedScene = preload("res://drill.tscn")
@onready var collector_scene: PackedScene = preload("res://collector.tscn")
@onready var intake_scene: PackedScene = preload("res://intake.tscn")
@onready var belt_scene: PackedScene = preload("res://belt.tscn")
@onready var processor_scene: PackedScene = preload("res://processor.tscn")
@onready var seller_scene: PackedScene = preload("res://seller.tscn")
@onready var laser_scene: PackedScene = preload("res://laser.tscn")
@onready var gun_scene: PackedScene = preload("res://gun.tscn")

func get_scene(block: Block) -> PackedScene:
	match block:
		Block.CABIN:   return cabin_scene
		Block.WHEEL: return wheel_scene
		Block.BLOCK:   return block_scene
		Block.DRILL:   return drill_scene
		Block.COLLECTOR:   return collector_scene
		Block.INTAKE: return intake_scene
		Block.BELT: return belt_scene
		Block.PROCESSOR: return processor_scene
		Block.SELLER: return seller_scene
		Block.LASER: return laser_scene
		Block.GUN: return gun_scene
	return null
