extends RefCounted
class_name UiTheme
## Собирает тёмную тему интерфейса кодом — чтобы .tscn оставался читаемым,
## а цвета/радиусы правились в одном месте.

const BG := Color("#0f1318")
const PANEL := Color("#161c24")
const PANEL_ALT := Color("#1e2632")
const BORDER := Color("#232c39")
const TEXT := Color("#e6ebf2")
const DIM := Color("#8b97a8")
const ACCENT := Color("#3b82f6")
const ACCENT_HOVER := Color("#4f90f8")
const USER_BUBBLE := Color("#1d4ed8")
const BOT_BUBBLE := Color("#1a222d")
const ERROR := Color("#f87171")


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = 15

	# --- Label
	t.set_color("font_color", "Label", TEXT)
	t.set_type_variation("DimLabel", "Label")
	t.set_color("font_color", "DimLabel", DIM)
	t.set_font_size("font_size", "DimLabel", 13)
	t.set_type_variation("SectionLabel", "Label")
	t.set_color("font_color", "SectionLabel", DIM)
	t.set_font_size("font_size", "SectionLabel", 11)

	# --- PanelContainer
	var panel := _box(PANEL, 12, BORDER, 1)
	panel.content_margin_left = 2
	panel.content_margin_right = 2
	panel.content_margin_top = 2
	panel.content_margin_bottom = 2
	t.set_stylebox("panel", "PanelContainer", panel)

	# --- окно настройки модели (персонажа)
	t.set_type_variation("DialogPanel", "PanelContainer")
	t.set_stylebox("panel", "DialogPanel", _box(PANEL, 16, BORDER, 1))

	# --- Пузыри сообщений
	t.set_type_variation("UserBubble", "PanelContainer")
	t.set_stylebox("panel", "UserBubble", _box(USER_BUBBLE, 14))
	t.set_type_variation("BotBubble", "PanelContainer")
	t.set_stylebox("panel", "BotBubble", _box(BOT_BUBBLE, 14, BORDER, 1))
	t.set_type_variation("ErrorBubble", "PanelContainer")
	t.set_stylebox("panel", "ErrorBubble", _box(Color("#3a1d22"), 14, ERROR, 1))

	# --- кнопки
	t.set_stylebox("normal", "Button", _box(PANEL_ALT, 8, BORDER, 1))
	t.set_stylebox("hover", "Button", _box(PANEL_ALT.lightened(0.07), 8, BORDER.lightened(0.1), 1))
	t.set_stylebox("pressed", "Button", _box(PANEL_ALT.darkened(0.15), 8))
	t.set_stylebox("disabled", "Button", _box(PANEL_ALT.darkened(0.4), 8))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", DIM.darkened(0.1))

	t.set_type_variation("AccentButton", "Button")
	t.set_stylebox("normal", "AccentButton", _box(ACCENT, 8))
	t.set_stylebox("hover", "AccentButton", _box(ACCENT_HOVER, 8))
	t.set_stylebox("pressed", "AccentButton", _box(ACCENT.darkened(0.15), 8))
	t.set_stylebox("disabled", "AccentButton", _box(ACCENT.darkened(0.55), 8))
	t.set_color("font_color", "AccentButton", Color.WHITE)
	t.set_color("font_hover_color", "AccentButton", Color.WHITE)
	t.set_color("font_disabled_color", "AccentButton", Color(1, 1, 1, 0.45))

	# --- кнопки темперамента: нажатая подсвечивается акцентом
	t.set_type_variation("TraitButton", "Button")
	t.set_stylebox("normal", "TraitButton", _box(PANEL_ALT, 8, BORDER, 1))
	t.set_stylebox("hover", "TraitButton", _box(PANEL_ALT.lightened(0.08), 8, BORDER.lightened(0.12), 1))
	t.set_stylebox("pressed", "TraitButton", _box(ACCENT.darkened(0.05), 8, ACCENT_HOVER, 1))
	t.set_stylebox("hover_pressed", "TraitButton", _box(ACCENT, 8, ACCENT_HOVER, 1))
	t.set_stylebox("disabled", "TraitButton", _box(PANEL_ALT.darkened(0.4), 8))
	t.set_color("font_color", "TraitButton", DIM)
	t.set_color("font_hover_color", "TraitButton", TEXT)
	t.set_color("font_pressed_color", "TraitButton", Color.WHITE)
	t.set_color("font_hover_pressed_color", "TraitButton", Color.WHITE)

	# --- «Удалить»
	t.set_type_variation("DangerButton", "Button")
	t.set_stylebox("normal", "DangerButton", _box(Color("#3a1d22"), 8, ERROR, 1))
	t.set_stylebox("hover", "DangerButton", _box(Color("#4a232a"), 8, ERROR, 1))
	t.set_stylebox("pressed", "DangerButton", _box(Color("#2c1519"), 8, ERROR, 1))
	t.set_color("font_color", "DangerButton", Color("#fca5a5"))
	t.set_color("font_hover_color", "DangerButton", Color("#fecaca"))
	t.set_color("font_pressed_color", "DangerButton", Color("#fca5a5"))

	# --- поля ввода
	t.set_stylebox("normal", "LineEdit", _box(Color("#0c1015"), 8, BORDER, 1))
	t.set_stylebox("focus", "LineEdit", _box(Color("#0c1015"), 8, ACCENT, 1))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", DIM.darkened(0.15))
	t.set_color("caret_color", "LineEdit", TEXT)

	t.set_stylebox("normal", "TextEdit", _box(Color("#0c1015"), 8, BORDER, 1))
	t.set_stylebox("focus", "TextEdit", _box(Color("#0c1015"), 8, ACCENT, 1))
	t.set_color("font_color", "TextEdit", TEXT)
	t.set_color("font_placeholder_color", "TextEdit", DIM.darkened(0.15))
	t.set_color("caret_color", "TextEdit", TEXT)
	t.set_color("selection_color", "TextEdit", Color(ACCENT, 0.35))

	# --- список моделей
	t.set_stylebox("panel", "ItemList", _box(Color("#0c1015"), 8, BORDER, 1))
	t.set_stylebox("selected", "ItemList", _box(Color(ACCENT, 0.28), 6))
	t.set_stylebox("selected_focus", "ItemList", _box(Color(ACCENT, 0.35), 6))
	t.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	t.set_color("font_color", "ItemList", TEXT)
	t.set_color("font_selected_color", "ItemList", Color.WHITE)
	t.set_constant("v_separation", "ItemList", 4)
	t.set_constant("h_separation", "ItemList", 2)

	# --- чекбокс
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", Color.WHITE)
	t.set_color("font_pressed_color", "CheckBox", TEXT)

	# --- слайдер
	t.set_stylebox("slider", "HSlider", _box(Color("#0c1015"), 4))
	t.set_stylebox("grabber_area", "HSlider", _box(ACCENT, 4))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(ACCENT_HOVER, 4))

	# --- разделители
	var sep := StyleBoxLine.new()
	sep.color = BORDER
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 8)

	# --- текст сообщений
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_constant("line_separation", "RichTextLabel", 4)

	# --- прокрутка
	t.set_stylebox("scroll", "VScrollBar", _box(Color(1, 1, 1, 0.03), 4))
	t.set_stylebox("grabber", "VScrollBar", _box(Color(1, 1, 1, 0.13), 4))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color(1, 1, 1, 0.22), 4))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(Color(1, 1, 1, 0.28), 4))

	# --- подсказки
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("panel", "TooltipPanel", _box(PANEL_ALT, 8, BORDER, 1))

	return t


static func _box(color: Color, radius: int, border_color: Color = Color.TRANSPARENT, border: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	if border > 0:
		sb.border_color = border_color
		sb.set_border_width_all(border)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	sb.anti_aliasing = true
	return sb
