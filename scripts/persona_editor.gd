extends Control
class_name PersonaEditor
## Панель «Новая модель»: имя, основа и темперамент.
##
## Это не обучение модели, а настройка уже установленной: приложение собирает
## из имени + темперамента системный промпт и отправляет его вместе с запросом.
##
## Создаётся кодом (в main.tscn лежит только кнопка «Создать»), кладётся
## поверх интерфейса и перекрывает его затемнением.
##
## Сигналы:
##   saved(persona)  — пользователь нажал «Сохранить»; id есть только при правке;
##   deleted(id)     — подтверждено удаление;
##   cancelled()     — Esc, «Отмена» или клик мимо панели.

signal saved(persona: Dictionary)
signal deleted(persona_id: String)
signal cancelled()

const Personas = preload("res://scripts/personas.gd")

## Поля доступны снаружи (и тестам): name_edit, base_option, trait_buttons…
var name_edit: LineEdit
var base_option: OptionButton
var error_label: Label
var preview_label: RichTextLabel
var save_btn: Button
var cancel_btn: Button
var delete_btn: Button
## id темперамента -> Button (toggle_mode).
var trait_buttons: Dictionary = {}

var _title: Label
var _groups: Dictionary = {}
var _persona: Dictionary = {}
var _models: Array = []
var _taken_names: Array = []
var _delete_armed: bool = false
var _built: bool = false


func _ready() -> void:
	_build()
	hide()


# ------------------------------------------------------------------ открытие

## Открыть пустую форму. taken_names — имена, которые уже заняты.
func open_new(models: Array, default_model: String = "", taken_names: Array = []) -> void:
	_persona = {}
	_taken_names = taken_names
	_delete_armed = false
	_title.text = "Новая модель"
	_save_button_mode(false)
	name_edit.text = ""
	name_edit.placeholder_text = "Например: Бородач"
	_clear_traits()
	_fill_models(models, default_model)
	_show()


## Открыть форму с уже сохранёнными настройками персонажа.
func open_edit(persona: Dictionary, models: Array, taken_names: Array = []) -> void:
	_persona = persona.duplicate(true)
	_taken_names = taken_names
	_delete_armed = false
	_title.text = "Настройка модели"
	_save_button_mode(true)
	name_edit.text = str(persona.get("name", ""))
	name_edit.placeholder_text = "Например: Бородач"
	_clear_traits()
	var traits: Array = persona.get("traits", [])
	for id in traits:
		var button: Button = trait_buttons.get(str(id))
		if button != null:
			button.set_pressed_no_signal(true)
	_fill_models(models, str(persona.get("base_model", "")))
	_show()
	name_edit.select_all()


## Открыта ли форма прямо сейчас.
func is_open() -> bool:
	return visible


## Текст заголовка («Новая модель» / «Настройка модели»).
func title_text() -> String:
	if _title == null:
		return ""
	return _title.text


## Закрыть без сохранения.
func close() -> void:
	_cancel()


# ------------------------------------------------------------------ разметка

func _build() -> void:
	if _built:
		return
	_built = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.045, 0.75)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(_on_dim_input)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"DialogPanel"
	panel.custom_minimum_size = Vector2(600, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 19)
	_title.text = "Новая модель"
	box.add_child(_title)

	var subtitle := _dim_label("Имя, основа и темперамент. Из них соберётся системный промпт.")
	box.add_child(subtitle)

	box.add_child(_section_label("ИМЯ"))
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Например: Бородач"
	name_edit.text_changed.connect(func(_text: String) -> void: _update_preview())
	name_edit.text_submitted.connect(func(_text: String) -> void: _submit())
	box.add_child(name_edit)

	box.add_child(_section_label("ОСНОВА — УСТАНОВЛЕННАЯ МОДЕЛЬ OLLAMA"))
	base_option = OptionButton.new()
	base_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	base_option.item_selected.connect(func(_index: int) -> void: _update_preview())
	box.add_child(base_option)

	box.add_child(_section_label("ТЕМПЕРАМЕНТ"))
	var traits_hint := _dim_label("Кнопки нажимаются и отжимаются. Выбранное уйдёт в промпт.")
	box.add_child(traits_hint)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	_build_trait_buttons(grid)

	box.add_child(_section_label("СИСТЕМНЫЙ ПРОМПТ — ПРЕДПРОСМОТР"))
	preview_label = RichTextLabel.new()
	preview_label.bbcode_enabled = false
	preview_label.scroll_active = true
	preview_label.custom_minimum_size = Vector2(0, 96)
	preview_label.add_theme_font_size_override("normal_font_size", 12)
	preview_label.add_theme_color_override("default_color", Color("#8b97a8"))
	box.add_child(preview_label)

	error_label = Label.new()
	error_label.add_theme_font_size_override("font_size", 12)
	error_label.add_theme_color_override("font_color", Color("#f87171"))
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_label.visible = false
	box.add_child(error_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	delete_btn = Button.new()
	delete_btn.text = "Удалить"
	delete_btn.theme_type_variation = &"DangerButton"
	delete_btn.custom_minimum_size = Vector2(112, 0)
	delete_btn.pressed.connect(_on_delete_pressed)
	row.add_child(delete_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	cancel_btn = Button.new()
	cancel_btn.text = "Отмена"
	cancel_btn.custom_minimum_size = Vector2(110, 0)
	cancel_btn.pressed.connect(_cancel)
	row.add_child(cancel_btn)

	save_btn = Button.new()
	save_btn.text = "Сохранить"
	save_btn.theme_type_variation = &"AccentButton"
	save_btn.custom_minimum_size = Vector2(150, 0)
	save_btn.pressed.connect(_submit)
	row.add_child(save_btn)


func _build_trait_buttons(grid: GridContainer) -> void:
	for entry_item in Personas.TRAITS:
		var id := str(entry_item["id"])
		var button := Button.new()
		button.toggle_mode = true
		button.text = str(entry_item["label"])
		button.tooltip_text = str(entry_item["hint"])
		button.theme_type_variation = &"TraitButton"
		button.custom_minimum_size = Vector2(0, 32)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.clip_text = true
		var group_id := str(entry_item.get("group", ""))
		if not group_id.is_empty():
			button.button_group = _button_group(group_id)
		button.toggled.connect(func(_pressed: bool) -> void: _update_preview())
		grid.add_child(button)
		trait_buttons[id] = button


func _button_group(group_id: String) -> ButtonGroup:
	if _groups.has(group_id):
		return _groups[group_id]
	var group := ButtonGroup.new()
	group.allow_unpress = true
	_groups[group_id] = group
	return group


func _section_label(text: String) -> Label:
	var label := Label.new()
	label.theme_type_variation = &"SectionLabel"
	label.text = text
	return label


func _dim_label(text: String) -> Label:
	var label := Label.new()
	label.theme_type_variation = &"DimLabel"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


# ------------------------------------------------------------------ данные формы

func _show() -> void:
	error_label.visible = false
	error_label.text = ""
	_update_preview()
	visible = true
	name_edit.grab_focus()


func _save_button_mode(editing: bool) -> void:
	delete_btn.visible = editing
	delete_btn.text = "Удалить"


func _clear_traits() -> void:
	for id in trait_buttons:
		var button: Button = trait_buttons[id]
		button.set_pressed_no_signal(false)


func _fill_models(models: Array, preferred: String) -> void:
	_models = models
	base_option.clear()
	base_option.disabled = models.is_empty()
	if models.is_empty():
		base_option.add_item("— моделей нет, обновите список —")
		return
	for model in models:
		base_option.add_item(str(model))
	var index := models.find(preferred)
	if index == -1:
		index = 0
	base_option.select(index)


func _selected_base() -> String:
	if base_option == null or base_option.selected < 0:
		return ""
	if base_option.selected >= base_option.item_count:
		return ""
	if _models.is_empty():
		return ""
	return base_option.get_item_text(base_option.selected)


func _pressed_traits() -> Array:
	var out: Array = []
	for entry_item in Personas.TRAITS:
		var id := str(entry_item["id"])
		var button: Button = trait_buttons.get(id)
		if button != null and button.button_pressed:
			out.append(id)
	return out


func _update_preview() -> void:
	if preview_label == null:
		return
	var preview_name := name_edit.text.strip_edges() if name_edit != null else ""
	if preview_name.is_empty():
		preview_name = "…"
	preview_label.text = Personas.build_system_prompt({
		"name": preview_name,
		"base_model": _selected_base(),
		"traits": _pressed_traits(),
	})


# ------------------------------------------------------------------ действия

func _submit() -> void:
	var persona_name := name_edit.text.strip_edges()
	if persona_name.is_empty():
		_show_error("Введите имя модели.")
		name_edit.grab_focus()
		return
	if _models.is_empty():
		_show_error("Список моделей Ollama пуст. Проверьте соединение и нажмите «Обновить».")
		return
	var base := _selected_base()
	if base.is_empty():
		_show_error("Выберите основу — установленную модель Ollama.")
		return
	if _name_taken(persona_name):
		_show_error("Такое имя уже есть — придумайте другое.")
		return
	_show_error("")
	var data := {
		"name": persona_name,
		"base_model": base,
		"traits": _pressed_traits(),
	}
	if not _persona.is_empty():
		data["id"] = str(_persona.get("id", ""))
	hide()
	saved.emit(data)


func _on_delete_pressed() -> void:
	if _persona.is_empty():
		return
	if not _delete_armed:
		_delete_armed = true
		delete_btn.text = "Точно удалить?"
		return
	var persona_id := str(_persona.get("id", ""))
	hide()
	deleted.emit(persona_id)


func _cancel() -> void:
	if not visible:
		return
	hide()
	cancelled.emit()


func _name_taken(candidate: String) -> bool:
	var needle := candidate.to_lower()
	var own := str(_persona.get("name", "")).to_lower()
	for taken in _taken_names:
		var other := str(taken).strip_edges().to_lower()
		if other.is_empty() or other == own:
			continue
		if other == needle:
			return true
	return false


func _show_error(message: String) -> void:
	error_label.text = message
	error_label.visible = not message.is_empty()


func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_cancel()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			_cancel()
			get_viewport().set_input_as_handled()
