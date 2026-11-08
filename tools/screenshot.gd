extends SceneTree
## Делает скриншот интерфейса (для README/превью).
##
## Нужен запущенный мок-сервер (или настоящий Ollama):
##   python3 tools/mock_ollama.py --port 11499 &
##   xvfb-run -s "-screen 0 1280x900x24" godot --path . --script tools/screenshot.gd

const MOCK_HOST := "http://127.0.0.1:11499"

var ui: Control


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	ui = load("res://scenes/main.tscn").instantiate()
	root.add_child(ui)
	await process_frame

	var host_edit: LineEdit = ui.get_node("%HostEdit")
	host_edit.text = MOCK_HOST
	host_edit.text_submitted.emit(MOCK_HOST)
	await _wait_for(func() -> bool: return ui.get_node("%ModelList").item_count > 0, 10.0)

	ui.get_node("%SystemPromptEdit").text = "Отвечай коротко и по делу."
	var input: TextEdit = ui.get_node("%InputEdit")
	input.text = "Привет! Что ты умеешь?"
	ui._send()
	await _wait_for(func() -> bool: return not ui._busy, 20.0)

	await _capture("res://docs/screenshot.png")

	# второй кадр: длинный ответ с заголовками, списком и кодом
	input.text = "Расскажи длинно, как это работает"
	ui._send()
	await _wait_for(func() -> bool: return not ui._busy, 30.0)
	await _capture("res://docs/screenshot-long.png")
	quit()


func _capture(path: String) -> void:
	# даём layout и шрифтам доехать до финального состояния
	for i in 5:
		await process_frame
	await create_timer(0.3).timeout

	var img := root.get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot %s: %s" % [path, "ok" if err == OK else "ошибка %d" % err])


func _wait_for(condition: Callable, timeout: float) -> void:
	var started := Time.get_ticks_msec()
	while not condition.call() and Time.get_ticks_msec() - started < int(timeout * 1000.0):
		await process_frame
