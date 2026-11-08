extends SceneTree
## Интеграционный тест интерфейса: поднимает main.tscn, переключает адрес на
## мок-сервер, «нажимает» кнопки и проверяет, что сообщения появляются в чате.
##
## Запуск:
##   python3 tools/mock_ollama.py --port 11499 &
##   godot --headless --path . --script tests/run_ui_test.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const MOCK_HOST := "http://127.0.0.1:11499"
const USER_FILES := ["user://personas.json", "user://ollama_chat.cfg"]
const EXPECTED_REPLY := "Привет! Это **тестовый** ответ от мок-сервера.\n\nСписок:\n- первый пункт\n- второй пункт\n\n```gdscript\nprint(\"hello\")\n```\n\nГотово."

var passed := 0
var failed := 0
var ui: Control


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	print("=== тесты интерфейса ===")
	_isolate_user_files()

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

	await _test_personas(ui, input, model_list)

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

	_restore_user_files()
	print("\nИтого: %d ок, %d провалено" % [passed, failed])
	quit(0 if failed == 0 else 1)


## Тесты работают в чистом профиле: рабочие настройки и персонажи временно
## откладываются в *.uitest и возвращаются на место в конце.
func _isolate_user_files() -> void:
	for path in USER_FILES:
		var backup: String = str(path) + ".uitest"
		if FileAccess.file_exists(backup):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
		if FileAccess.file_exists(path):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(path),
				ProjectSettings.globalize_path(backup))


func _restore_user_files() -> void:
	for path in USER_FILES:
		var backup: String = str(path) + ".uitest"
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(backup),
				ProjectSettings.globalize_path(path))


func _option_index(option: OptionButton, text: String) -> int:
	for i in option.item_count:
		if option.get_item_text(i) == text:
			return i
	return -1


## Создание, правка, использование в чате и удаление «своей модели».
func _test_personas(ui: Control, input: TextEdit, model_list: ItemList) -> void:
	var persona_list: ItemList = ui.get_node("%PersonaList")
	var editor = ui._persona_editor

	# --- форма открывается по кнопке «+ Создать»
	ui.get_node("%CreatePersonaBtn").pressed.emit()
	await process_frame
	_check(editor.visible, "редактор: форма создания открылась")
	_check(editor.title_text() == "Новая модель", "редактор: заголовок создания")
	_check(editor.base_option.item_count == model_list.item_count,
		"редактор: в «основе» все установленные модели (%d)" % editor.base_option.item_count)
	_check(editor.preview_label.text.contains("Особых требований"),
		"редактор: без темперамента промпт нейтральный")

	# --- пустое имя не сохраняется
	editor.save_btn.pressed.emit()
	await process_frame
	_check(editor.visible and editor.error_label.visible, "редактор: без имени не сохраняет")

	# --- имя + основа + темперамент
	editor.name_edit.text = "Бородач"
	var base_index := _option_index(editor.base_option, "qwen2.5-coder:7b")
	editor.base_option.select(base_index)
	editor.base_option.item_selected.emit(base_index)
	editor.trait_buttons["friendly"].button_pressed = true
	editor.trait_buttons["brief"].button_pressed = true
	_check(editor.preview_label.text.contains("Бородач"), "редактор: предпросмотр знает имя")
	_check(editor.preview_label.text.contains("дружелюбно"), "редактор: предпросмотр знает темперамент")

	# --- тон — взаимоисключающие кнопки
	editor.trait_buttons["sarcastic"].button_pressed = true
	_check(not editor.trait_buttons["friendly"].button_pressed,
		"редактор: «Сарказм» отпустил «Дружелюбный»")
	editor.trait_buttons["friendly"].button_pressed = true

	editor.save_btn.pressed.emit()
	await process_frame
	_check(not editor.visible, "редактор: закрылся после сохранения")
	_check(ui.personas.count() == 1, "персонажи: сохранено 1 (%d)" % ui.personas.count())
	_check(persona_list.item_count == 2, "персонажи: «без персонажа» + своя модель")
	_check(persona_list.get_item_text(1).contains("Бородач"), "персонажи: имя в списке")
	_check(ui.get_node("%ModelBadge").text.contains("Бородач"),
		"персонажи: бейдж показывает персонажа (%s)" % ui.get_node("%ModelBadge").text)
	_check(ui.get_node("%PersonaHint").text.contains("Дружелюбный"),
		"персонажи: подпись показывает темперамент")
	_check(ui.client.model == "qwen2.5-coder:7b", "персонажи: клиент переключён на основу")

	# --- чат идёт на основу персонажа с собранным промптом
	var persona_name := str(ui.personas.items[0].get("name", ""))
	var persona_id := str(ui.personas.items[0].get("id", ""))
	input.text = "привет"
	ui._send()
	await _wait_until(func() -> bool: return not ui._busy, 15.0)
	var dump := _read_dump()
	_check(str(dump.get("model", "")) == "qwen2.5-coder:7b",
		"персонажи: запрос ушёл на основу (%s)" % dump.get("model", ""))
	var sent: Array = dump.get("messages", [])
	_check(sent.size() == 2, "персонажи: system + user (%d)" % sent.size())
	if sent.size() == 2:
		_check(sent[0].get("role", "") == "system", "персонажи: первым идёт system")
		var system_text := str(sent[0].get("content", ""))
		_check(system_text.contains(persona_name), "персонажи: в промпте имя")
		_check(system_text.contains("дружелюбно"), "персонажи: в промпте темперамент")

	# --- правка: меняем темперамент, второй персонаж не появляется
	ui._open_persona_editor(persona_id)
	await process_frame
	_check(editor.name_edit.text == persona_name, "редактор: имя подставилось")
	_check(editor.trait_buttons["friendly"].button_pressed, "редактор: кнопки вернулись нажатыми")
	_check(editor.delete_btn.visible, "редактор: «Удалить» видна при правке")
	editor.trait_buttons["friendly"].button_pressed = false
	editor.trait_buttons["sarcastic"].button_pressed = true
	editor.save_btn.pressed.emit()
	await process_frame
	_check(ui.personas.count() == 1, "редактор: правка не создала второго")
	_check(ui.personas.items[0].get("traits", []) == ["sarcastic", "brief"],
		"редактор: темперамент обновлён (%s)" % [ui.personas.items[0].get("traits", [])])

	# --- переключение «персонаж ↔ без персонажа»
	persona_list.select(0)
	persona_list.item_selected.emit(0)
	await process_frame
	_check(ui._selected_persona_id.is_empty(), "персонажи: переключение в обычный режим")
	_check(ui.client.model == "qwen2.5-coder:7b",
		"персонажи: в обычном режиме отвечает выбранная базовая модель (%s)" % ui.client.model)
	persona_list.select(1)
	persona_list.item_selected.emit(1)
	await process_frame
	_check(ui._selected_persona_id == persona_id, "персонажи: возврат к своему персонажу")

	# --- клик по базовой модели меняет основу персонажа
	var llama_index := 0
	for i in model_list.item_count:
		if model_list.get_item_text(i) == "llama3.2:latest":
			llama_index = i
	model_list.select(llama_index)
	model_list.item_selected.emit(llama_index)
	await process_frame
	_check(ui.personas.items[0].get("base_model", "") == "llama3.2:latest",
		"персонажи: основа меняется кликом по списку моделей")
	_check(ui.get_node("%ModelBadge").text.contains("llama3.2"), "персонажи: бейдж обновился")

	# --- одинаковые имена запрещены
	ui._open_persona_editor("")
	await process_frame
	editor.name_edit.text = persona_name
	editor.save_btn.pressed.emit()
	await process_frame
	_check(editor.visible and editor.error_label.text.contains("уже есть"),
		"редактор: одинаковые имена запрещены")
	editor.cancel_btn.pressed.emit()
	await process_frame
	_check(not editor.visible, "редактор: «Отмена» закрывает")

	# --- Esc закрывает без сохранения
	ui._open_persona_editor("")
	await process_frame
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	editor._input(esc)
	await process_frame
	_check(not editor.visible, "редактор: Esc закрывает")

	# --- удаление в два нажатия
	ui._open_persona_editor(persona_id)
	await process_frame
	editor.delete_btn.pressed.emit()
	_check(editor.visible, "удаление: первое нажатие только спрашивает")
	editor.delete_btn.pressed.emit()
	await process_frame
	_check(ui.personas.count() == 0, "удаление: персонаж удалён")
	_check(ui._selected_persona_id.is_empty(), "удаление: выбор сброшен")
	_check(persona_list.item_count == 1, "удаление: остался только обычный режим")
	_check(ui.client.model == "llama3.2:latest",
		"удаление: клиент остался на подсвеченной модели (%s)" % ui.client.model)

	ui._new_chat(true)
	await process_frame


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
