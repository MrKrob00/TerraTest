extends CanvasLayer
# Автолоад Dialogue — субтитры-реплики внизу по центру. Показывает «[Кто]: текст» поверх
# игры и НЕ мешает ездить/стрелять (панель прозрачна для тача). Строки ставятся в очередь и
# сами сменяются по таймеру. Зови откуда угодно:
#   Dialogue.say("Командир", "Впереди враг!")
#   Dialogue.say_lines([["Механик","Собери машину."], ["Механик","Потом за рудой."]])

const NAME_COLOR := "e6a533"          # цвет имени говорящего (оранжевый акцент)
const CHARS_PER_SEC := 22.0           # авто-длительность строки по длине текста
const MIN_DURATION := 2.2
const MAX_DURATION := 7.0

@onready var _box:  PanelContainer = %Box
@onready var _line: RichTextLabel  = %Line

var _queue: Array = []                # [{speaker, text, dur}]
var _timer: float = 0.0

func _ready() -> void:
	_box.visible = false

# Добавить одну реплику. duration <= 0 → авто по длине текста.
func say(speaker: String, text: String, duration: float = 0.0) -> void:
	if duration <= 0.0:
		duration = clampf(text.length() / CHARS_PER_SEC, MIN_DURATION, MAX_DURATION)
	_queue.append({"speaker": speaker, "text": text, "dur": duration})
	if not _box.visible:
		_advance()

# Пачка реплик: [[speaker, text], ...] или [{speaker, text, dur}, ...].
func say_lines(lines: Array) -> void:
	for l: Variant in lines:
		if l is Array and l.size() >= 2:
			say(str(l[0]), str(l[1]), float(l[2]) if l.size() > 2 else 0.0)
		elif l is Dictionary:
			say(str(l.get("speaker", "")), str(l.get("text", "")), float(l.get("dur", 0.0)))

func clear() -> void:
	_queue.clear()
	_box.visible = false

func _advance() -> void:
	if _queue.is_empty():
		_box.visible = false
		return
	var l: Dictionary = _queue.pop_front()
	_line.text = "[color=#%s][%s][/color]: %s" % [NAME_COLOR, l["speaker"], l["text"]]
	_box.visible = true
	_timer = l["dur"]

func _process(delta: float) -> void:
	if not _box.visible:
		return
	_timer -= delta
	if _timer <= 0.0:
		_advance()
