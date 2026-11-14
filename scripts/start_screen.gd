extends Control
class_name StartScreen
## Стартовый экран диалога: «С кем поговорим?»
##
## Показывается, когда переписка ещё не начата: при запуске, после «+ Диалог»
## и после удаления открытой переписки. Даёт выбрать персонажа, обычную модель
## или вернуться к последней переписке — без копания в списках слева.
##
## Содержимое пересобирается при каждом refresh(): персонажей и моделей немного,
## зато список всегда актуальный.

signal persona_chosen(persona_id: String)
signal model_chosen(model: String)
signal create_persona_requested()
signal continue_requested(chat_id: String)

const Personas = preload("res://scripts/personas.gd")
const ChatStoreScript = preload("res://scripts/chat_store.gd")

## id персонажа -> Button (для тестов и подсказок).
var persona_buttons: Dictionary = {}
## имя модели -> Button.
var model_buttons: Dictionary = {}
var continue_btn: Button = null
var create_persona_btn: Button = null
var empty_models_label: Label = null

var _scroll: ScrollContainer
var _content: VBoxContainer
var _continue_box: VBoxContainer
var _personas_box: VBoxContainer
var _models_grid: GridContainer


func _ready() -> void:
	_build()
	hide()


# ------------------------------------------------------------------ содержимое

## Пересобрать экран. latest_chat — переписка для кнопки «Продолжить» (может быть {}).
func refresh(persona_list: Array, model_list: Array, latest_chat: Dictionary) -> void:
	if _content == null:
		return

	_clear(_continue_box)
	continue_btn = null
	if not latest_chat.is_empty():
		_continue_box.add_child(_section("ПРОДОЛЖИТЬ"))
		var chat_id := str(latest_chat.get("id", ""))
		var title := str(latest_chat.get("title", ChatStoreScript.EMPTY_TITLE))
		var when := ChatStoreScript.format_when(int(latest_chat.get("updated_at", 0)))
		continue_btn = Button.new()
		continue_btn.theme_type_variation = &"AccentButton"
		continue_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		continue_btn.text = "Продолжить «%s» · %s" % [title, when]
		continue_btn.tooltip_text = "Открыть последнюю переписку"
		continue_btn.pressed.connect(func() -> void: continue_requested.emit(chat_id))
		_continue_box.add_child(continue_btn)

	_clear(_personas_box)
	persona_buttons.clear()
	if persona_list.is_empty():
		_personas_box.add_child(_dim("Пока нет персонажей — создайте первого: имя, основа, темперамент."))
	for persona in persona_list:
		var persona_id := str(persona.get("id", ""))
		var button := Button.new()
		button.theme_type_variation = &"CardButton"
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text = "%s   ·   %s" % [
			str(persona.get("name", "")), str(persona.get("base_model", ""))
		]
		button.tooltip_text = _persona_tooltip(persona)
		button.custom_minimum_size = Vector2(0, 44)
		button.pressed.connect(func() -> void: persona_chosen.emit(persona_id))
		_personas_box.add_child(button)
		persona_buttons[persona_id] = button

	_clear(_models_grid)
	model_buttons.clear()
	for model in model_list:
		var model_name := str(model)
		var button := Button.new()
		button.text = model_name
		button.clip_text = true
		button.custom_minimum_size = Vector2(0, 36)
		button.tooltip_text = "Обычный диалог без персонажа"
		button.pressed.connect(func() -> void: model_chosen.emit(model_name))
		_models_grid.add_child(button)
		model_buttons[model_name] = button
	empty_models_label.visible = model_list.is_empty()

	_scroll.scroll_vertical = 0


# ------------------------------------------------------------------ разметка

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 20)
	_scroll.add_child(margin)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 10)
	margin.add_child(_content)

	var title := Label.new()
	title.text = "С кем поговорим?"
	title.add_theme_font_size_override("font_size", 24)
	_content.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Выберите персонажа или модель — и напишите первое сообщение."
	subtitle.theme_type_variation = &"DimLabel"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(subtitle)

	_continue_box = VBoxContainer.new()
	_continue_box.add_theme_constant_override("separation", 8)
	_content.add_child(_continue_box)

	_content.add_child(_section("ПЕРСОНАЖИ"))
	_personas_box = VBoxContainer.new()
	_personas_box.add_theme_constant_override("separation", 6)
	_content.add_child(_personas_box)

	create_persona_btn = Button.new()
	create_persona_btn.text = "+ Создать персонажа"
	create_persona_btn.pressed.connect(func() -> void: create_persona_requested.emit())
	_content.add_child(create_persona_btn)

	_content.add_child(_section("ИЛИ ПРОСТО МОДЕЛЬ"))
	_models_grid = GridContainer.new()
	_models_grid.columns = 2
	_models_grid.add_theme_constant_override("h_separation", 6)
	_models_grid.add_theme_constant_override("v_separation", 6)
	_content.add_child(_models_grid)

	empty_models_label = _dim("Модели не загружены. Запустите «ollama serve» и нажмите «Обновить список моделей» слева.")
	empty_models_label.visible = false
	_content.add_child(empty_models_label)

	var footnote := _dim("Персонажа можно создать или настроить в любой момент — кнопки слева.")
	footnote.add_theme_font_size_override("font_size", 11)
	_content.add_child(footnote)


func _section(text: String) -> Label:
	var label := Label.new()
	label.theme_type_variation = &"SectionLabel"
	label.text = text
	return label


func _dim(text: String) -> Label:
	var label := Label.new()
	label.theme_type_variation = &"DimLabel"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _persona_tooltip(persona: Dictionary) -> String:
	var text := "Основа: " + str(persona.get("base_model", ""))
	var traits := Personas.describe(persona)
	if not traits.is_empty():
		text += "\nТемперамент: " + traits
	return text


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
