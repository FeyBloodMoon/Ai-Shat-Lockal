extends CanvasLayer
## Пример: чат как меню поверх игры, открывается по Esc.
##
## Как использовать:
##   1. Создайте в своей сцене узел CanvasLayer.
##   2. Повесьте на него этот скрипт (или на любой другой узел, если нужен не оверлей).
##   3. Запустите игру — Esc открывает/закрывает чат.

const ChatScene := preload("res://scenes/main.tscn")

var _chat: Control


func _ready() -> void:
	layer = 10
	# Меню должно работать, даже если игра на паузе
	process_mode = Node.PROCESS_MODE_ALWAYS
	_chat = ChatScene.instantiate()
	add_child(_chat)
	_chat.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		toggle()


## Открыть/закрыть чат.
func toggle() -> void:
	_chat.visible = not _chat.visible
	if _chat.visible:
		var input := _chat.get_node_or_null("%InputEdit")
		if input != null:
			input.grab_focus()
	get_viewport().set_input_as_handled()
