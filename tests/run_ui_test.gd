extends SceneTree
## Интеграционный тест интерфейса: поднимает main.tscn, переключает адрес на
## мок-сервер, «нажимает» кнопки и проверяет, что сообщения появляются в чате.
##
## Запуск:
##   python3 tools/mock_ollama.py --port 11499 &
##   godot --headless --path . --script tests/run_ui_test.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const MOCK_HOST := "http://127.0.0.1:11499"
const EXPECTED_REPLY := "Привет! Это **тестовый** ответ от мок-сервера.\n\nСписок:\n- первый пункт\n- второй пункт\n\n```gdscript\nprint(\"hello\")\n```\n\nГотово."

var passed := 0
var failed := 0
var ui: Control


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	print("=== тесты интерфейса ===")

	ui = load(MAIN_SCENE).instantiate()
	root.add_child(ui)
	await process_frame

	var host_edit: LineEdit = ui.get_node("%HostEdit")
	host_edit.text = MOCK_HOST
	host_edit.text_submitted.emit(MOCK_HOST)

	var model_list: ItemList = ui.get_node("%ModelList")
	var loaded: bool = await _wait_until(func() -> bool: return model_list.item_count == 2, 10.0)
	_check(loaded, "модели подтянулись в список (%d)" % model_list.item_count)
	_check(ui.get_node("%ModelBadge").text.contains("llama3.2"), "бейдж модели обновился")
	_check(ui.get_node("%StatusLabel").text.contains("mock"), "статус показывает версию сервера")

	# --- обычная отправка со стримингом
	var input: TextEdit = ui.get_node("%InputEdit")
	input.text = "привет"
	ui._send()
	var messages: VBoxContainer = ui.get_node("%Messages")
	var got: bool = await _wait_until(func() -> bool: return not ui._busy and messages.get_child_count() >= 3, 15.0)
	_check(got, "ответ получен, пузыри добавились (%d)" % messages.get_child_count())

	var bubbles := messages.get_children()
	var last: Node = bubbles[bubbles.size() - 1]
	_check(last.get_plain_text() == EXPECTED_REPLY, "текст ответа совпадает")
	_check(messages.size.x > 200.0, "чат занимает место в layout (ширина %.0f)" % messages.size.x)
	_check(ui.history.size() == 2, "в истории 2 сообщения (user + assistant)")
	_check(input.text.is_empty(), "поле ввода очистилось")

	# --- второй запрос: история должна уехать на сервер целиком
	input.text = "а теперь по-другому"
	ui._send()
	await _wait_until(func() -> bool: return not ui._busy and messages.get_child_count() >= 5, 15.0)
	var dump := _read_dump()
	_check(dump.get("messages", []).size() == 3,
		"на сервер ушло 3 сообщения с историей (%d)" % dump.get("messages", []).size())

	# --- ошибка модели
	var before_history: int = ui.history.size()
	ui.client.model = "нет-такой-модели"
	input.text = "сломайся"
	ui._send()
	await _wait_until(func() -> bool: return not ui._busy, 15.0)
	var err_bubble: Node = messages.get_child(messages.get_child_count() - 1)
	_check(err_bubble.get_plain_text().contains("not found"), "ошибка показана в пузыре")
	_check(ui.history.size() == before_history, "лишнее сообщение убрано из истории")

	# --- новый диалог
	ui._new_chat(true)
	await process_frame
	_check(messages.get_child_count() == 1, "новый диалог: остался только приветственный пузырь")
	_check(ui.history.is_empty(), "новый диалог: история очищена")

	# --- пример встраивания чата как игрового меню (Esc)
	var overlay := CanvasLayer.new()
	overlay.set_script(load("res://examples/chat_overlay.gd"))
	root.add_child(overlay)
	await process_frame
	_check(overlay._chat != null and not overlay._chat.visible, "оверлей: чат создан и скрыт")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	overlay._unhandled_input(esc)
	await process_frame
	_check(overlay._chat.visible, "оверлей: Esc открывает чат")
	overlay._unhandled_input(esc)
	await process_frame
	_check(not overlay._chat.visible, "оверлей: Esc закрывает чат")

	print("\nИтого: %d ок, %d провалено" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _read_dump() -> Dictionary:
	var file := FileAccess.open("/tmp/mock_last_request.json", FileAccess.READ)
	if file == null:
		return {}
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return data if typeof(data) == TYPE_DICTIONARY else {}


func _wait_until(condition: Callable, timeout: float = 10.0) -> bool:
	var started := Time.get_ticks_msec()
	while not condition.call():
		if Time.get_ticks_msec() - started > int(timeout * 1000.0):
			return false
		await process_frame
	return true


func _check(condition: bool, name: String) -> void:
	if condition:
		passed += 1
		print("  ok   %s" % name)
	else:
		failed += 1
		print("  FAIL %s" % name)
