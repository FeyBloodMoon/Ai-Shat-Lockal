extends SceneTree
## Headless-тесты проекта: разбор Markdown, клиент Ollama (стриминг, ошибки, отмена).
##
## Запуск:
##   python3 tools/mock_ollama.py --port 11499 &
##   godot --headless --path . --script tests/run_tests.gd

const ClientScript = preload("res://scripts/ollama_client.gd")
const MarkdownHelper = preload("res://scripts/markdown.gd")
const PersonaStoreScript = preload("res://scripts/personas.gd")

const HOST := "http://127.0.0.1:11499"
const DUMP := "/tmp/mock_last_request.json"
const EXPECTED_REPLY := "Привет! Это **тестовый** ответ от мок-сервера.\n\nСписок:\n- первый пункт\n- второй пункт\n\n```gdscript\nprint(\"hello\")\n```\n\nГотово."

var passed := 0
var failed := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame  # даём сцене войти в дерево, как в реальном приложении
	print("=== тесты клиента Ollama ===")
	_test_markdown()
	_test_personas()
	await _test_models()
	await _test_connection()
	await _test_stream_chat()
	await _test_nonstream_chat()
	await _test_model_missing()
	await _test_cancel()
	await _test_unreachable()
	await _test_payload_has_system_and_options()
	print("\nИтого: %d ок, %d провалено" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ------------------------------------------------------------------ Markdown

func _test_markdown() -> void:
	var bold := MarkdownHelper.to_bbcode("это **жирный** текст")
	_check(bold.contains("[b]жирный[/b]"), "markdown: **жирный**")

	var italic := MarkdownHelper.to_bbcode("это *курсив* тут")
	_check(italic.contains("[i]курсив[/i]"), "markdown: *курсив*")

	var inline := MarkdownHelper.to_bbcode("код `print(1)` inline")
	_check(inline.contains("[code]print(1)[/code]"), "markdown: `код`")

	var block := MarkdownHelper.to_bbcode("```gdscript\nvar a = 1\n```")
	_check(block.contains("[code]") and not block.contains("```"), "markdown: блок кода скрывает ```")

	var lst := MarkdownHelper.to_bbcode("- один\n- два")
	_check(lst.contains("• один") and lst.contains("• два"), "markdown: список → буллиты")

	var heading := MarkdownHelper.to_bbcode("## Заголовок")
	_check(heading.contains("[b]") and heading.contains("Заголовок"), "markdown: заголовок → жирный")

	var escaped := MarkdownHelper.to_bbcode("массив [0] и [b]")
	_check(escaped.contains("[lb]0]"), "markdown: квадратные скобки экранируются")

	var link := MarkdownHelper.to_bbcode("см. [доки](https://example.com)")
	_check(link.contains("[url=https://example.com]"), "markdown: ссылка → url-bbcode")


# ------------------------------------------------------------------ персонажи

func _test_personas() -> void:
	print("--- персонажи ---")
	var file := "user://test_personas.json"
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))

	var store = PersonaStoreScript.new()
	store.file_path = file
	store.load_all()
	_check(store.count() == 0, "персонажи: старт с пустого списка")

	var created: Dictionary = store.add("Бородач", "llama3.2:latest", ["friendly", "brief", "нет-такой"])
	_check(not created.is_empty() and not str(created.get("id", "")).is_empty(), "персонажи: создан с id")
	_check(created.get("traits", []) == ["friendly", "brief"],
		"персонажи: неизвестные черты отброшены (%s)" % [created.get("traits", [])])
	_check(store.count() == 1, "персонажи: в списке один")

	var prompt: String = PersonaStoreScript.build_system_prompt(created)
	_check(prompt.contains("Бородач"), "персонажи: в промпте есть имя")
	_check(prompt.contains("llama3.2:latest"), "персонажи: в промпте есть основа")
	_check(prompt.contains("дружелюбно"), "персонажи: в промпте черта «дружелюбный»")
	_check(prompt.contains("коротко"), "персонажи: в промпте черта «коротко»")
	_check(not prompt.contains("сарказм"), "персонажи: выключенные черты в промпт не попали")
	_check(PersonaStoreScript.describe(created) == "Дружелюбный · Коротко",
		"персонажи: подпись темперамента (%s)" % PersonaStoreScript.describe(created))

	_check(store.add("", "llama3.2", []).is_empty(), "персонажи: пустое имя не создаётся")
	store.clear()

	var first: Dictionary = store.add("Бородач", "llama3.2:latest", ["friendly", "brief"])
	_check(store.save() == OK, "персонажи: сохранение прошло")
	_check(FileAccess.file_exists(file), "персонажи: файл появился")

	var reloaded = PersonaStoreScript.new()
	reloaded.file_path = file
	reloaded.load_all()
	_check(reloaded.count() == 1, "персонажи: прочитан один")
	var restored: Dictionary = reloaded.get_by_id(str(first.get("id", "")))
	_check(str(restored.get("name", "")) == "Бородач", "персонажи: имя пережило запись")
	_check(str(restored.get("base_model", "")) == "llama3.2:latest", "персонажи: основа пережила запись")
	_check(restored.get("traits", []) == ["friendly", "brief"], "персонажи: темперамент пережил запись")

	_check(reloaded.update_persona(str(first.get("id", "")), "Старина", "qwen2.5-coder:7b",
		["sarcastic"]), "персонажи: правка прошла")
	var edited: Dictionary = reloaded.get_by_id(str(first.get("id", "")))
	_check(str(edited.get("name", "")) == "Старина", "персонажи: новое имя на месте")
	_check(str(edited.get("base_model", "")) == "qwen2.5-coder:7b", "персонажи: новая основа на месте")
	_check(edited.get("traits", []) == ["sarcastic"], "персонажи: темперамент заменён")
	_check(not reloaded.update_persona("нет-такого", "Кто-то", "llama3.2"),
		"персонажи: правка несуществующего — false")
	_check(str(reloaded.find_by_name("старина").get("name", "")) == "Старина",
		"персонажи: поиск имени без учёта регистра")

	_check(reloaded.remove_persona(str(first.get("id", ""))), "персонажи: удаление прошло")
	_check(reloaded.count() == 0, "персонажи: после удаления пусто")

	# битый файл не должен ронять приложение
	var broken := FileAccess.open(file, FileAccess.WRITE)
	broken.store_string("{это совсем не json")
	broken.close()
	var tolerant = PersonaStoreScript.new()
	tolerant.file_path = file
	tolerant.load_all()
	_check(tolerant.count() == 0, "персонажи: битый файл читается без падения")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


# ------------------------------------------------------------------ клиент

func _new_client() -> Node:
	var client = ClientScript.new()
	root.add_child(client)
	client.host = HOST
	client.request_timeout = 20.0
	return client


func _wait_until(condition: Callable, timeout: float = 15.0) -> bool:
	var started := Time.get_ticks_msec()
	while not condition.call():
		if Time.get_ticks_msec() - started > int(timeout * 1000.0):
			return false
		await process_frame
	return true


func _test_models() -> void:
	var client := _new_client()
	var state := {"models": [], "error": "", "done": false}
	client.models_loaded.connect(func(m: Array) -> void:
		state.models = m
		state.done = true)
	client.models_error.connect(func(m: String) -> void:
		state.error = m
		state.done = true)

	client.fetch_models()
	var finished: bool = await _wait_until(func() -> bool: return state.done)
	_check(finished, "модели: ответ получен")
	_check(state.models.size() == 2, "модели: получено 2 модели (%s)" % [state.models])
	_check(state.models.has("llama3.2:latest"), "модели: есть llama3.2:latest")
	client.queue_free()


func _test_connection() -> void:
	var client := _new_client()
	var state := {"ok": false, "version": "", "done": false}
	client.connection_checked.connect(func(ok: bool, version: String) -> void:
		state.ok = ok
		state.version = version
		state.done = true)

	client.check_connection()
	var finished: bool = await _wait_until(func() -> bool: return state.done)
	_check(finished, "версия: ответ получен")
	_check(state.ok and state.version == "0.0.0-mock", "версия: %s" % state.version)
	client.queue_free()


func _test_stream_chat() -> void:
	var client := _new_client()
	client.model = "llama3.2:latest"
	var state := {"text": "", "deltas": 0, "stats": {}, "error": "", "done": false}
	client.chat_delta.connect(func(piece: String) -> void:
		state.text += piece
		state.deltas += 1)
	client.chat_done.connect(func(full: String, stats: Dictionary) -> void:
		state.text = full
		state.stats = stats
		state.done = true)
	client.chat_error.connect(func(message: String) -> void:
		state.error = message
		state.done = true)

	client.send_chat([{"role": "user", "content": "привет"}])
	var finished: bool = await _wait_until(func() -> bool: return state.done)
	_check(finished, "стриминг: завершился")
	_check(state.error.is_empty(), "стриминг: без ошибок (%s)" % state.error)
	_check(state.deltas > 5, "стриминг: пришло несколько кусков (%d)" % state.deltas)
	_check(state.text == EXPECTED_REPLY, "стриминг: текст собран целиком")
	_check(state.stats.has("tok_per_sec"), "стриминг: есть статистика ток/с")
	_check(not client.is_busy(), "стриминг: клиент освободился")
	client.queue_free()


func _test_nonstream_chat() -> void:
	var client := _new_client()
	client.model = "llama3.2:latest"
	client.stream = false
	var state := {"text": "", "deltas": 0, "error": "", "done": false}
	client.chat_delta.connect(func(_p: String) -> void: state.deltas += 1)
	client.chat_done.connect(func(full: String, _stats: Dictionary) -> void:
		state.text = full
		state.done = true)
	client.chat_error.connect(func(message: String) -> void:
		state.error = message
		state.done = true)

	client.send_chat([{"role": "user", "content": "привет"}])
	var finished: bool = await _wait_until(func() -> bool: return state.done)
	_check(finished, "без стриминга: завершился")
	_check(state.error.is_empty(), "без стриминга: без ошибок (%s)" % state.error)
	_check(state.text == EXPECTED_REPLY, "без стриминга: текст совпадает")
	_check(state.deltas == 0, "без стриминга: chat_delta не рассылается")
	client.queue_free()


func _test_model_missing() -> void:
	var client := _new_client()
	client.model = "нет-такой-модели"
	var state := {"error": "", "done": false, "text": ""}
	client.chat_done.connect(func(full: String, _s: Dictionary) -> void:
		state.text = full
		state.done = true)
	client.chat_error.connect(func(message: String) -> void:
		state.error = message
		state.done = true)

	client.send_chat([{"role": "user", "content": "привет"}])
	var finished: bool = await _wait_until(func() -> bool: return state.done)
	_check(finished, "ошибка модели: ответ пришёл")
	_check(state.error.contains("not found"), "ошибка модели: текст ошибки «%s»" % state.error)
	_check(state.text.is_empty(), "ошибка модели: текста ответа нет")
	_check(not client.is_busy(), "ошибка модели: клиент освободился")
	client.queue_free()


func _test_cancel() -> void:
	var client := _new_client()
	client.model = "llama3.2:latest"
	var state := {"partial": "", "cancelled": false, "done": false, "deltas": 0}
	client.chat_delta.connect(func(_p: String) -> void: state.deltas += 1)
	client.chat_cancelled.connect(func(partial: String) -> void:
		state.partial = partial
		state.cancelled = true)
	client.chat_done.connect(func(_f: String, _s: Dictionary) -> void: state.done = true)

	# "медленно" включает в мок-сервере медленный поток: гарантированно
	# отменяем генерацию на середине, а не после её завершения
	client.send_chat([{"role": "user", "content": "медленно"}])
	var streaming: bool = await _wait_until(func() -> bool:
		return state.deltas > 0 or state.done, 10.0)
	_check(streaming and not state.done, "отмена: стриминг начался до отмены")
	client.cancel()
	_check(state.cancelled, "отмена: пришёл chat_cancelled")
	_check(not state.partial.is_empty(), "отмена: есть частичный текст (%d симв.)" % state.partial.length())
	_check(not state.done, "отмена: chat_done не приходит")
	_check(not client.is_busy(), "отмена: клиент свободен")
	var deltas_at_cancel: int = state.deltas
	await create_timer(0.6).timeout
	_check(not state.done, "отмена: после паузы chat_done не приходит")
	_check(state.deltas == deltas_at_cancel, "отмена: новые куски текста не приходят")
	client.queue_free()


func _test_unreachable() -> void:
	var client := _new_client()
	client.host = "http://127.0.0.1:1"
	client.model = "llama3.2:latest"
	var state := {"error": "", "done": false}
	client.chat_done.connect(func(_f: String, _s: Dictionary) -> void: state.done = true)
	client.chat_error.connect(func(message: String) -> void:
		state.error = message
		state.done = true)

	client.send_chat([{"role": "user", "content": "привет"}])
	var finished: bool = await _wait_until(func() -> bool: return state.done, 10.0)
	_check(finished, "недоступный сервер: ошибка пришла быстро")
	_check(not state.error.is_empty(), "недоступный сервер: понятный текст («%s»)" % state.error)
	client.queue_free()


func _test_payload_has_system_and_options() -> void:
	var client := _new_client()
	client.model = "llama3.2:latest"
	client.system_prompt = "Ты пират"
	client.temperature = 0.35
	var state := {"done": false}
	client.chat_done.connect(func(_f: String, _s: Dictionary) -> void: state.done = true)
	client.send_chat([{"role": "user", "content": "привет"}])
	await _wait_until(func() -> bool: return state.done)

	var file := FileAccess.open(DUMP, FileAccess.READ)
	_check(file != null, "запрос: дамп сохранён")
	if file != null:
		var data: Dictionary = JSON.parse_string(file.get_as_text())
		file.close()
		var messages: Array = data.get("messages", [])
		_check(messages.size() == 2, "запрос: 2 сообщения (system + user)")
		if messages.size() == 2:
			_check(messages[0].get("role", "") == "system", "запрос: первым идёт system")
			_check(messages[0].get("content", "") == "Ты пират", "запрос: системный промпт на месте")
			_check(messages[1].get("role", "") == "user", "запрос: после system идёт user")
		_check(absf(float(data.get("options", {}).get("temperature", -1.0)) - 0.35) < 0.001,
			"запрос: температура передана")
		_check(data.get("stream", false) == true, "запрос: stream = true")
		_check(str(data.get("keep_alive", "")) == "10m", "запрос: keep_alive передан")
	client.queue_free()


func _check(condition: bool, name: String) -> void:
	if condition:
		passed += 1
		print("  ok   %s" % name)
	else:
		failed += 1
		print("  FAIL %s" % name)
