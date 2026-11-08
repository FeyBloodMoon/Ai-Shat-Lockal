extends Control
## Главный экран чата: связывает интерфейс и OllamaClient.

const OllamaClientScript = preload("res://scripts/ollama_client.gd")
const ChatBubbleScript = preload("res://scripts/chat_bubble.gd")
const UiThemeScript = preload("res://scripts/ui_theme.gd")

const SETTINGS_PATH := "user://ollama_chat.cfg"
## Сколько последних сообщений отправлять модели (чтобы не раздувать контекст).
const MAX_HISTORY_MESSAGES := 40
const HINT_TEXT := "Enter — отправить · Shift+Enter — новая строка · Ctrl+Enter — тоже отправить"

@onready var _model_list: ItemList = %ModelList
@onready var _host_edit: LineEdit = %HostEdit
@onready var _system_prompt: TextEdit = %SystemPromptEdit
@onready var _temp_slider: HSlider = %TempSlider
@onready var _temp_value: Label = %TempValue
@onready var _stream_check: CheckBox = %StreamCheck
@onready var _input: TextEdit = %InputEdit
@onready var _messages: VBoxContainer = %Messages
@onready var _scroll: ScrollContainer = %ChatScroll
@onready var _send_btn: Button = %SendBtn
@onready var _stop_btn: Button = %StopBtn
@onready var _status_dot: Label = %StatusDot
@onready var _status_label: Label = %StatusLabel
@onready var _model_badge: Label = %ModelBadge
@onready var _hint: Label = %Hint

var client: OllamaClientScript
var history: Array = []
var _assistant_bubble: ChatBubbleScript = null
var _busy: bool = false
var _version: String = ""
var _saved_model: String = ""
var _hint_token: int = 0


func _ready() -> void:
	theme = UiThemeScript.build()

	client = OllamaClientScript.new()
	client.request_timeout = 300.0
	add_child(client)
	client.models_loaded.connect(_on_models_loaded)
	client.models_error.connect(_on_models_error)
	client.connection_checked.connect(_on_connection_checked)
	client.chat_delta.connect(_on_chat_delta)
	client.chat_done.connect(_on_chat_done)
	client.chat_cancelled.connect(_on_chat_cancelled)
	client.chat_error.connect(_on_chat_error)

	_wire_events()
	_load_settings()
	_set_busy(false)
	_new_chat(true)
	_input.grab_focus()
	_check_connection()


func _wire_events() -> void:
	%RefreshBtn.pressed.connect(_refresh_models)
	%NewChatBtn.pressed.connect(func() -> void: _new_chat(true))
	_send_btn.pressed.connect(_send)
	_stop_btn.pressed.connect(_stop)
	_model_list.item_selected.connect(_on_model_selected)
	_host_edit.text_submitted.connect(func(_t: String) -> void: _apply_host())
	_host_edit.focus_exited.connect(_apply_host)
	_temp_slider.value_changed.connect(_on_temperature_changed)
	_stream_check.toggled.connect(func(_p: bool) -> void: _save_settings())
	_system_prompt.focus_exited.connect(_save_settings)
	_input.gui_input.connect(_on_input_gui_input)
	_input.text_changed.connect(_on_input_text_changed)


# ------------------------------------------------------------------ соединение

func _check_connection() -> void:
	client.host = _host_edit.text.strip_edges()
	_set_status("подключение…", "wait")
	client.check_connection()


func _apply_host() -> void:
	var new_host := _host_edit.text.strip_edges()
	if new_host.is_empty():
		_host_edit.text = client.host
		return
	if new_host == client.host:
		return
	_save_settings()
	_check_connection()


func _refresh_models() -> void:
	%RefreshBtn.disabled = true
	client.host = _host_edit.text.strip_edges()
	client.fetch_models()


func _on_connection_checked(ok: bool, version: String) -> void:
	if ok:
		_version = version
		var status_text := "Ollama подключён"
		if not version.is_empty():
			status_text = "Ollama %s" % version
		_set_status(status_text, "ok")
		_refresh_models()
	else:
		%RefreshBtn.disabled = false
		_set_status("нет соединения", "error")
		_show_toast("Ollama не отвечает. Запустите «ollama serve».", "error")


func _on_models_loaded(models: Array) -> void:
	%RefreshBtn.disabled = false
	_model_list.clear()
	for m in models:
		_model_list.add_item(str(m))

	if models.is_empty():
		_set_status("Ollama подключён, моделей нет", "error")
		_show_toast("Нет ни одной модели. В терминале: ollama pull llama3.2", "error")
		_model_badge.text = "модель: —"
		return

	var index := 0
	if not _saved_model.is_empty():
		var found := models.find(_saved_model)
		if found != -1:
			index = found
	_model_list.select(index)
	_on_model_selected(index)


func _on_models_error(message: String) -> void:
	%RefreshBtn.disabled = false
	_set_status("нет соединения", "error")
	_show_toast(message, "error")


func _on_model_selected(index: int) -> void:
	if index < 0 or index >= _model_list.item_count:
		return
	var model_name := _model_list.get_item_text(index)
	client.model = model_name
	_model_badge.text = "модель: " + model_name
	_saved_model = model_name
	_save_settings()


# ------------------------------------------------------------------ отправка

func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if (key == KEY_ENTER or key == KEY_KP_ENTER) and not (event as InputEventKey).shift_pressed:
			_input.accept_event()
			_send()


func _on_input_text_changed() -> void:
	var lines := _input.get_line_count()
	_input.custom_minimum_size.y = clampf(24.0 * float(lines) + 22.0, 64.0, 190.0)


func _send() -> void:
	if _busy:
		return
	var text := _input.text.strip_edges()
	if text.is_empty():
		return
	if client.model.strip_edges().is_empty():
		_show_toast("Сначала выберите модель в списке слева.", "error")
		return

	_input.text = ""
	_on_input_text_changed()
	_history_add("user", text)
	_add_bubble("user", text, "Вы")

	_assistant_bubble = ChatBubbleScript.new()
	_assistant_bubble.setup("assistant", "", client.model)
	_messages.add_child(_assistant_bubble)
	_scroll_to_bottom()

	client.temperature = float(_temp_slider.value)
	client.stream = _stream_check.button_pressed
	client.system_prompt = _system_prompt.text.strip_edges()
	_set_busy(true)
	client.send_chat(_history_window(), client.model)


func _stop() -> void:
	client.cancel()


func _on_chat_delta(piece: String) -> void:
	if is_instance_valid(_assistant_bubble):
		_assistant_bubble.append_piece(piece)
		_scroll_to_bottom()


func _on_chat_done(full_text: String, stats: Dictionary) -> void:
	if is_instance_valid(_assistant_bubble):
		_assistant_bubble.finish(stats)
	_history_add("assistant", full_text)
	_set_busy(false)
	_scroll_to_bottom()
	_input.grab_focus()


func _on_chat_cancelled(partial_text: String) -> void:
	if is_instance_valid(_assistant_bubble):
		_assistant_bubble.finish({"cancelled": true})
	if not partial_text.strip_edges().is_empty():
		_history_add("assistant", partial_text)
	_set_busy(false)
	_show_toast("Генерация остановлена.", "info")


func _on_chat_error(message: String) -> void:
	if is_instance_valid(_assistant_bubble):
		_assistant_bubble.show_error(message)
	# Последнее сообщение пользователя осталось без ответа — убираем из истории,
	# чтобы при повторной отправке оно не дублировалось.
	if not history.is_empty() and history[-1].get("role", "") == "user":
		history.pop_back()
	_set_busy(false)
	_show_toast(message, "error")
	_scroll_to_bottom()


# ------------------------------------------------------------------ вспомогательное

func _set_busy(busy: bool) -> void:
	_busy = busy
	_send_btn.disabled = busy
	_stop_btn.disabled = not busy


func _history_add(role: String, content: String) -> void:
	history.append({"role": role, "content": content})


func _history_window() -> Array:
	var start := maxi(0, history.size() - MAX_HISTORY_MESSAGES)
	return history.slice(start)


func _add_bubble(role: String, text: String, meta: String = "") -> ChatBubbleScript:
	var bubble = ChatBubbleScript.new()
	bubble.setup(role, text, meta)
	_messages.add_child(bubble)
	return bubble


func _new_chat(add_welcome: bool = true) -> void:
	if client != null and client.is_busy():
		client.cancel()
	for child in _messages.get_children():
		child.queue_free()
	history.clear()
	_assistant_bubble = null
	_set_busy(false)
	if add_welcome:
		_welcome_message()


func _welcome_message() -> void:
	var text := """Привет! Я чат внутри Godot, а отвечает **локальная модель** через Ollama.

Как пользоваться:
1. Запустите сервер: `ollama serve`
2. Скачайте модель: `ollama pull llama3.2`
3. Выберите модель в списке слева и напишите сообщение.

Сервер по умолчанию — `http://localhost:11434`, его можно поменять в настройках."""
	var bubble := _add_bubble("assistant", text, "подсказка")
	bubble.finish({})


func _set_status(text: String, kind: String) -> void:
	var color := Color("#fbbf24")
	match kind:
		"ok":
			color = Color("#4ade80")
		"error":
			color = Color("#f87171")
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)
	_status_dot.add_theme_color_override("font_color", color)


func _show_toast(message: String, kind: String = "info") -> void:
	_hint_token += 1
	var token := _hint_token
	var color := Color("#8b97a8")
	match kind:
		"error":
			color = Color("#f87171")
		"ok":
			color = Color("#4ade80")
	_hint.text = message
	_hint.add_theme_color_override("font_color", color)
	await get_tree().create_timer(6.0).timeout
	if token == _hint_token:
		_hint.text = HINT_TEXT
		_hint.add_theme_color_override("font_color", Color("#8b97a8"))


func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if not is_instance_valid(_scroll):
		return
	var bar := _scroll.get_v_scroll_bar()
	_scroll.scroll_vertical = int(maxf(0.0, bar.max_value))


# ------------------------------------------------------------------ настройки

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		_temp_value.text = "%.2f" % _temp_slider.value
		return
	_host_edit.text = str(cfg.get_value("server", "host", _host_edit.text))
	_saved_model = str(cfg.get_value("server", "model", ""))
	_system_prompt.text = str(cfg.get_value("chat", "system_prompt", ""))
	_temp_slider.set_value_no_signal(float(cfg.get_value("chat", "temperature", 0.8)))
	_temp_value.text = "%.2f" % _temp_slider.value
	_stream_check.set_pressed_no_signal(bool(cfg.get_value("chat", "stream", true)))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "host", _host_edit.text.strip_edges())
	cfg.set_value("server", "model", _saved_model)
	cfg.set_value("chat", "system_prompt", _system_prompt.text)
	cfg.set_value("chat", "temperature", float(_temp_slider.value))
	cfg.set_value("chat", "stream", _stream_check.button_pressed)
	cfg.save(SETTINGS_PATH)


func _on_temperature_changed(value: float) -> void:
	_temp_value.text = "%.2f" % value
	_save_settings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready():
		_save_settings()
