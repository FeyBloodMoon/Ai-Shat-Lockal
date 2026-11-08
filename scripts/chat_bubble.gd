extends HBoxContainer
class_name ChatBubble
## Один пузырь сообщения в чате.
## Сообщение пользователя — справа, ответ модели — слева.
## Умеет «дописываться» на лету при стриминге, показывать статистику и ошибки.

const MarkdownHelper = preload("res://scripts/markdown.gd")

## "user" или "assistant".
var role: String = "assistant"
## Кто/модель — подпись под пузырём.
var meta_prefix: String = ""

var _text: String = ""
var _label: RichTextLabel
var _meta: Label
var _panel: PanelContainer
var _box: VBoxContainer
var _stats: Dictionary = {}
var _finished: bool = false
var _error_mode: bool = false


## Настроить пузырь. Вызывать до add_child(), чтобы _ready() уже знал роль.
##   var bubble = ChatBubbleScript.new()
##   bubble.setup("user", "Привет", "Вы")
##   add_child(bubble)
func setup(p_role: String, p_text: String = "", p_meta: String = "") -> void:
	role = p_role
	_text = p_text
	meta_prefix = p_meta


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Панель не растягивается: её ширина = минимальная ширина текста,
	# но не больше ~76% ширины чата (см. _relayout_width()).
	_panel = PanelContainer.new()
	if role == "user":
		_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	else:
		_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if role == "user":
		_panel.theme_type_variation = &"UserBubble"
	else:
		_panel.theme_type_variation = &"BotBubble"

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 4)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.selection_enabled = true
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.add_theme_font_size_override("normal_font_size", 15)
	_label.add_theme_font_size_override("bold_font_size", 15)
	_label.add_theme_font_size_override("italics_font_size", 15)
	_label.add_theme_font_size_override("mono_font_size", 14)

	_meta = Label.new()
	_meta.theme_type_variation = &"DimLabel"
	_meta.add_theme_font_size_override("font_size", 11)
	_meta.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))

	_box.add_child(_label)
	_box.add_child(_meta)
	margin.add_child(_box)
	_panel.add_child(margin)

	if role == "user":
		add_child(spacer)
		add_child(_panel)
	else:
		add_child(_panel)
		add_child(spacer)

	resized.connect(_on_resized)
	set_text(_text)
	_update_meta()


func _on_resized() -> void:
	# отложенно, чтобы не менять layout внутри его же пересчёта
	call_deferred("_relayout_width")


## Подбирает ширину пузыря под текст: короткие сообщения — узкие,
## длинные упираются в 76% ширины чата и переносятся по словам.
func _relayout_width() -> void:
	if _label == null or not is_instance_valid(_label):
		return
	var available := size.x
	if available <= 1.0:
		return
	var max_width := maxf(240.0, available * 0.76)
	var font := _label.get_theme_font("normal_font")
	var font_size := _label.get_theme_font_size("normal_font_size")
	var natural := 0.0
	for line in _strip_bbcode(_label.text).split("\n"):
		natural = maxf(natural, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var target := clampf(natural + 8.0, 64.0, max_width - 28.0)
	if absf(_label.custom_minimum_size.x - target) > 0.5:
		_label.custom_minimum_size.x = target


func _strip_bbcode(value: String) -> String:
	var re := RegEx.new()
	re.compile("\\[[^\\]]*\\]")
	return re.sub(value, "", true)


## Дописать кусочек текста (стриминг).
func append_piece(piece: String) -> void:
	if piece.is_empty():
		return
	_text += piece
	set_text(_text)


## Полный текст сообщения (без разметки).
func get_plain_text() -> String:
	return _text


## Завершить сообщение и показать статистику.
func finish(stats: Dictionary = {}) -> void:
	_finished = true
	_stats = stats
	if _text.strip_edges().is_empty():
		_text = "_(пустой ответ)_"
	set_text(_text)  # перерисовка без «курсора»
	_update_meta(true)


## Показать ошибку в этом пузыре.
func show_error(message: String) -> void:
	_error_mode = true
	_finished = true
	if _panel != null:
		_panel.theme_type_variation = &"ErrorBubble"
	_text = message
	if _label != null:
		_label.text = "[color=#f87171]⚠ %s[/color]" % message.replace("[", "[lb]")
	call_deferred("_relayout_width")
	_update_meta(true)


func set_meta_prefix(prefix: String) -> void:
	meta_prefix = prefix
	_update_meta()


func set_text(value: String) -> void:
	_text = value
	if _label == null:
		return
	if value.strip_edges().is_empty():
		if _finished:
			_label.text = "[color=#8b97a8]…[/color]"
		else:
			_label.text = "[color=#8b97a8]● ● ●[/color]"
		return
	if role == "user":
		_label.text = value.replace("[", "[lb]")
	else:
		_label.text = MarkdownHelper.to_bbcode(value) + (" [color=#8b97a8]▍[/color]" if not _finished else "")
	_update_meta()


func _update_meta(show_stats: bool = false) -> void:
	if _meta == null:
		return
	var parts: Array[String] = []
	if not meta_prefix.is_empty():
		parts.append(meta_prefix)
	if _finished:
		if show_stats and _stats.has("tok_per_sec"):
			parts.append("%.1f ток/с" % float(_stats["tok_per_sec"]))
		if show_stats and _stats.has("total_sec"):
			parts.append("%.1f с" % float(_stats["total_sec"]))
		if _stats.get("cancelled", false):
			parts.append("остановлено")
	elif role == "assistant":
		parts.append("печатает…")
	_meta.text = " · ".join(parts)
	_meta.visible = not _meta.text.is_empty()
