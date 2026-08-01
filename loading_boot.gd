extends Node
## Мини-бут — ГЛАВНАЯ сцена проекта (грузится мгновенно). Поднимает СТОЙКИЙ оверлей загрузки прямо
## в root (сосед current_scene → переживёт смену сцены), а тот сам потоково грузит игру и держится
## сверху, пока карта не построит террейн. Сам Boot будет освобождён при смене сцены — это норм.
func _ready() -> void:
	var overlay := preload("res://loading_screen.gd").new()
	overlay.next_scene = "res://node_3d.tscn"
	get_tree().root.add_child.call_deferred(overlay)
