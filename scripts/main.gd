extends Control
## Главный экран чата: связывает интерфейс, OllamaClient, переписки и персонажей.
##
## Переписка — это сохранённый диалог (user://chats/<id>.json): заголовок,
## персонаж, модель и сообщения. Она пишется на диск после каждого ответа
## модели, а при запуске открывается последняя.
##
## Персонаж (он же «своя модель») — сохранённая настройка уже установленной
## модели: имя, основа (какая модель Ollama отвечает) и темперамент. Из имени и
## темперамента собирается системный промпт, он уходит на сервер вместе с чатом.

const OllamaClientScript = preload("res://scripts/ollama_client.gd")
const ChatBubbleScript = preload("res://scripts/chat_bubble.gd")
const UiThemeScript = preload("res://scripts/ui_theme.gd")
const PersonaStoreScript = preload("res://scripts/personas.gd")
const PersonaEditorScript = preload("res://scripts/persona_editor.gd")
const ChatStoreScript = preload("res://scripts/chat_store.gd")

const SETTINGS_PATH := "user://ollama_chat.cfg"
## Сколько последних сообщений отправлять модели (чтобы не раздувать контекст).
const MAX_HISTORY_MESSAGES := 40
const HINT_TEXT := "Enter — отправить · Shift+Enter — новая строка · Ctrl+Enter — тоже отправить"
const PLAIN_MODE_HINT := "Модель настраивается один раз: имя, основа и темперамент."

@onready var _chat_list: ItemList = %ChatList
@onready var _new_chat_btn: Button = %NewChatBtn
@onready var _delete_chat_btn: Button = %DeleteChatBtn
@onready var _persona_list: ItemList = %PersonaList
@onready var _create_persona_btn: Button = %CreatePersonaBtn
@onready var _edit_persona_btn: Button = %EditPersonaBtn
@onready var _persona_hint: Label = %PersonaHint
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
var personas: PersonaStoreScript
var chats: ChatStoreScript
var history: Array = []
var _persona_editor: PersonaEditorScript
## id выбранного персонажа; пустая строка — обычный режим без персонажа.
var _selected_persona_id: String = ""
## id открытой переписки; пустая строка — новый диалог, ещё не сохранённый.
var _current_chat_id: String = ""
var _delete_chat_armed: bool = false
## Есть ли в текущей переписке несохранённые изменения.
var _chat_dirty: bool = false
var _models: Array = []
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
	_setup_personas()
	_setup_chats()
	_load_settings()
	_restore_persona()
	_set_busy(false)
	_restore_chat()
	_input.grab_focus()
	_check_connection()


func _wire_events() -> void:
	%RefreshBtn.pressed.connect(_refresh_models)
	_new_chat_btn.pressed.connect(func() -> void: _new_chat(true))
	_delete_chat_btn.pressed.connect(_on_delete_chat_pressed)
	_chat_list.item_selected.connect(_on_chat_selected)
	_create_persona_btn.pressed.connect(func() -> void: _open_persona_editor(""))
	_edit_persona_btn.pressed.connect(func() -> void: _open_persona_editor(_selected_persona_id))
	_persona_list.item_selected.connect(_on_persona_selected)
	_persona_list.item_activated.connect(_on_persona_activated)
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


# ------------------------------------------------------------------ переписки

func _setup_chats() -> void:
	chats = ChatStoreScript.new()
	chats.load_all()
	_refresh_chat_list()


## Открыть последнюю переписку или начать новую, если сохранённых нет.
func _restore_chat() -> void:
	if chats.count() == 0:
		_current_chat_id = ""
		_new_chat(true)
		return
	var chat_id := _current_chat_id
	if chat_id.is_empty() or chats.get_by_id(chat_id).is_empty():
		chat_id = str(chats.latest().get("id", ""))
	_open_chat(chat_id)


func _refresh_chat_list() -> void:
	if _chat_list == null:
		return
	_chat_list.clear()
	if chats.items.is_empty():
		_chat_list.add_item("Пока нет переписок")
		_chat_list.set_item_metadata(0, "")
		_chat_list.set_item_disabled(0, true)
		_delete_chat_btn.disabled = true
		return

	for chat in chats.items:
		var index := _chat_list.item_count
		var chat_id := str(chat.get("id", ""))
		var title := str(chat.get("title", ChatStoreScript.EMPTY_TITLE))
		var when := ChatStoreScript.format_when(int(chat.get("updated_at", 0)))
		_chat_list.add_item("%s · %s" % [title, when])
		_chat_list.set_item_metadata(index, chat_id)
		_chat_list.set_item_tooltip(index, _chat_tooltip(chat))
		if chat_id == _current_chat_id:
			_chat_list.select(index)
	_delete_chat_btn.disabled = _current_chat_id.is_empty()


func _chat_tooltip(chat: Dictionary) -> String:
	var parts: Array[String] = []
	var persona_name := str(chat.get("persona_name", ""))
	var model := str(chat.get("model", ""))
	if not persona_name.is_empty():
		parts.append("персонаж: " + persona_name)
	if not model.is_empty():
		parts.append("модель: " + model)
	var messages: Array = chat.get("messages", [])
	parts.append("сообщений: %d" % messages.size())
	return "\n".join(PackedStringArray(parts))


func _on_chat_selected(index: int) -> void:
	if index < 0 or index >= _chat_list.item_count:
		return
	var chat_id := str(_chat_list.get_item_metadata(index))
	if chat_id.is_empty() or chat_id == _current_chat_id:
		return
	_open_chat(chat_id)


func _open_chat(chat_id: String) -> void:
	var chat := chats.get_by_id(chat_id)
	if chat.is_empty():
		_show_toast("Переписка не найдена.", "error")
		return
	if _busy:
		_show_toast("Дождитесь ответа модели или нажмите «Стоп».", "error")
		_refresh_chat_list()
		return

	_persist_current_chat()
	_current_chat_id = chat_id
	_delete_chat_armed = false
	_delete_chat_btn.text = "Удалить"
	_apply_chat_context(chat)

	_clear_messages()
	var messages: Array = chat.get("messages", [])
	history = messages.duplicate(true)
	_chat_dirty = false
	_render_history()
	_refresh_chat_list()
	_save_settings()
	_scroll_to_bottom()


## Вернуть персонажа и модель, с которыми шла эта переписка.
func _apply_chat_context(chat: Dictionary) -> void:
	var persona_id := str(chat.get("persona_id", ""))
	if not persona_id.is_empty() and not personas.get_by_id(persona_id).is_empty():
		_selected_persona_id = persona_id
		_apply_persona(persona_id)
		return
	_selected_persona_id = ""
	_apply_chat_plain_model(chat)


func _apply_chat_plain_model(chat: Dictionary) -> void:
	var model := str(chat.get("model", ""))
	if model.is_empty():
		_apply_plain_model()
		_refresh_persona_hint()
		return

	_saved_model = model
	var found := _models.find(model)
	if found != -1:
		_model_list.select(found)
		_apply_plain_model()
		_refresh_persona_hint()
		return
	if _models.is_empty():
		# список моделей ещё не пришёл — просто помним модель переписки
		client.model = model
		_model_badge.text = "модель: " + model
		_refresh_persona_hint()
		return
	_apply_plain_model()
	_refresh_persona_hint()


func _render_history() -> void:
	for entry in history:
		var role := str(entry.get("role", ""))
		if role != "user" and role != "assistant":
			continue
		var speaker := "Вы"
		if role == "assistant":
			speaker = str(entry.get("speaker", ""))
			if speaker.is_empty():
				speaker = _current_speaker_name()
		var bubble := _add_bubble(role, str(entry.get("content", "")), speaker)
		bubble.finish({})


## Дописать текущую переписку на диск (если в ней есть что сохранять).
func _persist_current_chat() -> void:
	if history.is_empty() or chats == null:
		return
	if not _chat_dirty and not _current_chat_id.is_empty():
		return
	if _current_chat_id.is_empty():
		var fresh := chats.new_chat(_selected_persona_id, _current_persona_name(), client.model)
		_current_chat_id = str(fresh.get("id", ""))
	var saved := chats.save_chat({
		"id": _current_chat_id,
		"persona_id": _selected_persona_id,
		"persona_name": _current_persona_name(),
		"model": client.model,
		"messages": history,
	})
	if saved.is_empty():
		_show_toast("Не удалось сохранить переписку.", "error")
		return
	_chat_dirty = false
	_refresh_chat_list()


func _drop_current_chat() -> void:
	if _current_chat_id.is_empty():
		return
	chats.delete_chat(_current_chat_id)
	_current_chat_id = ""
	_refresh_chat_list()
	_save_settings()


func _on_delete_chat_pressed() -> void:
	if _current_chat_id.is_empty():
		_show_toast("Нет открытой переписки.", "info")
		return
	if not _delete_chat_armed:
		_delete_chat_armed = true
		_delete_chat_btn.text = "Точно?"
		return
	chats.delete_chat(_current_chat_id)
	_current_chat_id = ""
	_delete_chat_armed = false
	_delete_chat_btn.text = "Удалить"
	_clear_messages()
	history.clear()
	_chat_dirty = false
	_set_busy(false)
	_refresh_chat_list()
	_save_settings()
	_welcome_message()
	_show_toast("Переписка удалена.", "info")


func _clear_messages() -> void:
	for child in _messages.get_children():
		child.queue_free()
	_assistant_bubble = null


func _current_persona_name() -> String:
	var persona := _current_persona()
	if persona.is_empty():
		return ""
	return str(persona.get("name", ""))


func _current_speaker_name() -> String:
	var persona_name := _current_persona_name()
	if not persona_name.is_empty():
		return persona_name
	return client.model


# ------------------------------------------------------------------ персонажи

func _setup_personas() -> void:
	personas = PersonaStoreScript.new()
	personas.load_all()

	_persona_editor = PersonaEditorScript.new()
	_persona_editor.visible = false
	add_child(_persona_editor)
	_persona_editor.saved.connect(_on_persona_saved)
	_persona_editor.deleted.connect(_on_persona_deleted)

	_refresh_persona_list()
	_refresh_persona_hint()


func _refresh_persona_list() -> void:
	if _persona_list == null:
		return
	_persona_list.clear()
	_persona_list.add_item("— без персонажа —")
	_persona_list.set_item_metadata(0, "")
	for persona in personas.items:
		var index := _persona_list.item_count
		_persona_list.add_item(_persona_row_text(persona))
		_persona_list.set_item_metadata(index, str(persona.get("id", "")))
	var row := _persona_row_index(_selected_persona_id)
	if row >= 0:
		_persona_list.select(row)


func _persona_row_text(persona: Dictionary) -> String:
	var persona_name := str(persona.get("name", ""))
	var base := str(persona.get("base_model", ""))
	var text := persona_name
	if not base.is_empty():
		text += " · " + base
	if not base.is_empty() and not _models.is_empty() and not _models.has(base):
		text = "⚠ " + text
	return text


func _persona_row_index(persona_id: String) -> int:
	if persona_id.is_empty():
		return 0
	for i in _persona_list.item_count:
		if str(_persona_list.get_item_metadata(i)) == persona_id:
			return i
	return -1


func _current_persona() -> Dictionary:
	if _selected_persona_id.is_empty() or personas == null:
		return {}
	return personas.get_by_id(_selected_persona_id)


func _restore_persona() -> void:
	if not _selected_persona_id.is_empty() and personas.get_by_id(_selected_persona_id).is_empty():
		_selected_persona_id = ""
	if _selected_persona_id.is_empty():
		_persona_list.select(0)
		_refresh_persona_hint()
	else:
		_apply_persona(_selected_persona_id)


func _on_persona_selected(index: int) -> void:
	if index < 0 or index >= _persona_list.item_count:
		return
	var persona_id := str(_persona_list.get_item_metadata(index))
	if persona_id == _selected_persona_id:
		return
	_selected_persona_id = persona_id
	if persona_id.is_empty():
		_apply_plain_model()
		_refresh_persona_hint()
		_show_toast("Обычный режим: без персонажа.", "info")
	else:
		_apply_persona(persona_id)
		var persona := _current_persona()
		_show_toast("Персонаж «%s» на основе %s." % [
			str(persona.get("name", "")), str(persona.get("base_model", ""))
		], "ok")
	_save_settings()


func _on_persona_activated(index: int) -> void:
	var persona_id := str(_persona_list.get_item_metadata(index))
	if not persona_id.is_empty():
		_open_persona_editor(persona_id)


func _apply_persona(persona_id: String) -> void:
	var persona := personas.get_by_id(persona_id)
	if persona.is_empty():
		_apply_plain_model()
		return
	_selected_persona_id = persona_id
	var base := str(persona.get("base_model", ""))
	if not base.is_empty():
		client.model = base
		_saved_model = base
	_model_badge.text = "%s · %s" % [str(persona.get("name", "")), base]
	_edit_persona_btn.disabled = false
	var row := _persona_row_index(persona_id)
	if row >= 0:
		_persona_list.select(row)
	if not base.is_empty() and not _models.is_empty():
		var found := _models.find(base)
		if found != -1:
			_model_list.select(found)
	_refresh_persona_hint()


func _apply_plain_model() -> void:
	var selected := _model_list.get_selected_items()
	if selected.is_empty():
		client.model = ""
		_model_badge.text = "модель: —"
		return
	var model_name := _model_list.get_item_text(selected[0])
	client.model = model_name
	_model_badge.text = "модель: " + model_name


func _refresh_persona_hint() -> void:
	var persona := _current_persona()
	if persona.is_empty():
		_edit_persona_btn.disabled = true
		_persona_hint.text = PLAIN_MODE_HINT
		_persona_hint.tooltip_text = ""
		return
	_edit_persona_btn.disabled = false
	var traits := PersonaStoreScript.describe(persona)
	if traits.is_empty():
		traits = "без темперамента"
	_persona_hint.text = "«%s»: %s" % [str(persona.get("name", "")), traits]
	_persona_hint.tooltip_text = PersonaStoreScript.build_system_prompt(persona)


func _open_persona_editor(persona_id: String) -> void:
	if _persona_editor == null:
		return
	if _busy:
		_show_toast("Дождитесь ответа модели или нажмите «Стоп».", "error")
		return
	var taken := personas.names()
	if persona_id.is_empty():
		_persona_editor.open_new(_models, _default_base_model(), taken)
		return
	var persona := personas.get_by_id(persona_id)
	if persona.is_empty():
		return
	_persona_editor.open_edit(persona, _models, taken)


func _default_base_model() -> String:
	if not client.model.strip_edges().is_empty():
		return client.model
	if not _saved_model.is_empty():
		return _saved_model
	if not _models.is_empty():
		return str(_models[0])
	return ""


func _on_persona_saved(data: Dictionary) -> void:
	var persona_name := str(data.get("name", "")).strip_edges()
	var base := str(data.get("base_model", "")).strip_edges()
	var traits: Array = data.get("traits", [])
	var persona_id := str(data.get("id", ""))
	var message := ""

	if persona_id.is_empty():
		var created := personas.add(persona_name, base, traits)
		if created.is_empty():
			_show_toast("Не удалось создать модель: пустое имя.", "error")
			return
		persona_id = str(created.get("id", ""))
		message = "Модель «%s» создана · основа %s." % [persona_name, base]
	else:
		if not personas.update_persona(persona_id, persona_name, base, traits):
			_show_toast("Не удалось сохранить настройки модели.", "error")
			return
		message = "Настройки «%s» сохранены." % persona_name

	personas.save()
	_selected_persona_id = persona_id
	_refresh_persona_list()
	_apply_persona(persona_id)
	_save_settings()
	_show_toast(message, "ok")


func _on_persona_deleted(persona_id: String) -> void:
	var persona := personas.get_by_id(persona_id)
	if persona.is_empty():
		return
	var persona_name := str(persona.get("name", ""))
	personas.remove_persona(persona_id)
	personas.save()
	if _selected_persona_id == persona_id:
		_selected_persona_id = ""
		_apply_plain_model()
	_refresh_persona_list()
	_refresh_persona_hint()
	_save_settings()
	_show_toast("Модель «%s» удалена." % persona_name, "info")


func _compose_system_prompt() -> String:
	var parts: Array[String] = []
	var persona := _current_persona()
	if not persona.is_empty():
		parts.append(PersonaStoreScript.build_system_prompt(persona))
	var extra := _system_prompt.text.strip_edges()
	if not extra.is_empty():
		parts.append("Дополнительные указания пользователя:\n" + extra)
	if parts.is_empty():
		return ""
	return "\n\n".join(PackedStringArray(parts))


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
	_models = models
	_model_list.clear()
	for m in models:
		_model_list.add_item(str(m))

	if models.is_empty():
		_set_status("Ollama подключён, моделей нет", "error")
		_show_toast("Нет ни одной модели. В терминале: ollama pull llama3.2", "error")
		_model_badge.text = "модель: —"
		_refresh_persona_list()
		return

	var persona := _current_persona()
	if not persona.is_empty():
		var base := str(persona.get("base_model", ""))
		var found := models.find(base)
		if found != -1:
			_model_list.select(found)
		_apply_persona(_selected_persona_id)
	else:
		var index := 0
		if not _saved_model.is_empty():
			var found := models.find(_saved_model)
			if found != -1:
				index = found
		_model_list.select(index)
		_on_model_selected(index)
	_refresh_persona_list()


func _on_models_error(message: String) -> void:
	%RefreshBtn.disabled = false
	_set_status("нет соединения", "error")
	_show_toast(message, "error")


func _on_model_selected(index: int) -> void:
	if index < 0 or index >= _model_list.item_count:
		return
	var model_name := _model_list.get_item_text(index)
	_saved_model = model_name
	var persona := _current_persona()
	if persona.is_empty():
		client.model = model_name
		_model_badge.text = "модель: " + model_name
	else:
		if str(persona.get("base_model", "")) != model_name:
			personas.set_base_model(_selected_persona_id, model_name)
			personas.save()
			_refresh_persona_list()
			_apply_persona(_selected_persona_id)
			_show_toast("Основа «%s» теперь %s." % [
				str(persona.get("name", "")), model_name
			], "ok")
		_model_badge.text = "%s · %s" % [str(persona.get("name", "")), model_name]
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
	# сообщение сразу попадает в сохранённую переписку — не потеряется при сбое
	_persist_current_chat()

	var speaker := _current_speaker_name()
	_assistant_bubble = ChatBubbleScript.new()
	_assistant_bubble.setup("assistant", "", speaker)
	_messages.add_child(_assistant_bubble)
	_scroll_to_bottom()

	client.temperature = float(_temp_slider.value)
	client.stream = _stream_check.button_pressed
	client.system_prompt = _compose_system_prompt()
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
	_persist_current_chat()
	_set_busy(false)
	_scroll_to_bottom()
	_input.grab_focus()


func _on_chat_cancelled(partial_text: String) -> void:
	if is_instance_valid(_assistant_bubble):
		_assistant_bubble.finish({"cancelled": true})
	if not partial_text.strip_edges().is_empty():
		_history_add("assistant", partial_text)
		_persist_current_chat()
	_set_busy(false)
	_show_toast("Генерация остановлена.", "info")


func _on_chat_error(message: String) -> void:
	if is_instance_valid(_assistant_bubble):
		_assistant_bubble.show_error(message)
	# Последнее сообщение пользователя осталось без ответа — убираем из истории,
	# чтобы при повторной отправке оно не дублировалось.
	if not history.is_empty() and history[-1].get("role", "") == "user":
		history.pop_back()
	if history.is_empty():
		# переписка состояла из одного неудачного сообщения — не храним пустую
		_drop_current_chat()
	else:
		_chat_dirty = true
		_persist_current_chat()
	_set_busy(false)
	_show_toast(message, "error")
	_scroll_to_bottom()


# ------------------------------------------------------------------ вспомогательное

func _set_busy(busy: bool) -> void:
	_busy = busy
	_send_btn.disabled = busy
	_stop_btn.disabled = not busy


func _history_add(role: String, content: String) -> void:
	var entry := {"role": role, "content": content}
	if role == "assistant":
		entry["speaker"] = _current_speaker_name()
	history.append(entry)
	_chat_dirty = true


func _history_window() -> Array:
	var start := maxi(0, history.size() - MAX_HISTORY_MESSAGES)
	var out: Array = []
	for entry in history.slice(start):
		out.append({
			"role": str(entry.get("role", "")),
			"content": str(entry.get("content", "")),
		})
	return out


func _add_bubble(role: String, text: String, meta: String = "") -> ChatBubbleScript:
	var bubble = ChatBubbleScript.new()
	bubble.setup(role, text, meta)
	_messages.add_child(bubble)
	return bubble


func _new_chat(add_welcome: bool = true) -> void:
	if client != null and client.is_busy():
		client.cancel()
	_persist_current_chat()
	_current_chat_id = ""
	_delete_chat_armed = false
	_delete_chat_btn.text = "Удалить"
	_clear_messages()
	history.clear()
	_chat_dirty = false
	_set_busy(false)
	_refresh_chat_list()
	_save_settings()
	if add_welcome:
		_welcome_message()


func _welcome_message() -> void:
	var persona := _current_persona()
	var text := ""
	var meta := "подсказка"
	if persona.is_empty():
		text = """Привет! Я чат внутри Godot, а отвечает **локальная модель** через Ollama.

Как пользоваться:
1. Запустите сервер: `ollama serve`
2. Скачайте модель: `ollama pull llama3.2`
3. Выберите модель в списке слева и напишите сообщение.

Сервер по умолчанию — `http://localhost:11434`, его можно поменять в настройках.

Переписки сохраняются сами: вернуться к любой можно в списке слева.
Хотите характер — нажмите «+ Создать»: имя, основа и темперамент."""
	else:
		var persona_name := str(persona.get("name", ""))
		var persona_base := str(persona.get("base_model", ""))
		var traits := PersonaStoreScript.describe(persona)
		meta = persona_name
		text = "Привет! Я **%s** — персонаж на основе модели `%s`.\n\n" % [persona_name, persona_base]
		if not traits.is_empty():
			text += "Мой темперамент: %s.\n\n" % traits
		text += "Напишите сообщение. Настройки персонажа — кнопкой «Настроить» слева."
	var bubble := _add_bubble("assistant", text, meta)
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
	_selected_persona_id = str(cfg.get_value("persona", "selected", ""))
	_current_chat_id = str(cfg.get_value("chat", "current", ""))
	_system_prompt.text = str(cfg.get_value("chat", "system_prompt", ""))
	_temp_slider.set_value_no_signal(float(cfg.get_value("chat", "temperature", 0.8)))
	_temp_value.text = "%.2f" % _temp_slider.value
	_stream_check.set_pressed_no_signal(bool(cfg.get_value("chat", "stream", true)))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("server", "host", _host_edit.text.strip_edges())
	cfg.set_value("server", "model", _saved_model)
	cfg.set_value("persona", "selected", _selected_persona_id)
	cfg.set_value("chat", "current", _current_chat_id)
	cfg.set_value("chat", "system_prompt", _system_prompt.text)
	cfg.set_value("chat", "temperature", float(_temp_slider.value))
	cfg.set_value("chat", "stream", _stream_check.button_pressed)
	cfg.save(SETTINGS_PATH)


func _on_temperature_changed(value: float) -> void:
	_temp_value.text = "%.2f" % value
	_save_settings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_node_ready():
		_persist_current_chat()
		_save_settings()
