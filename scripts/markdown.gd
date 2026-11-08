extends RefCounted
class_name Markdown
## Очень лёгкий конвертер Markdown → BBCode для RichTextLabel.
## Локальные модели почти всегда отвечают в Markdown, поэтому без этого
## в чате видны «сырые» звёздочки и решётки.
##
## Поддерживается: **жирный**, *курсив*, `код`, ```блоки кода```,
## # заголовки (→ жирный), списки (- / * / +), цитаты (>), ссылки [текст](url), --- (линия).
##
## Порядок важен: сначала «прячем» блоки кода и ссылки в плейсхолдеры,
## потом экранируем квадратные скобки, потом применяем инлайн-разметку,
## и только в конце возвращаем плейсхолдеры на место уже в виде BBCode.


static func to_bbcode(md: String) -> String:
	var text := md.replace("\r\n", "\n").replace("\r", "\n")

	# 1. Прячем блоки кода и ссылки, чтобы их содержимое не форматировалось.
	var code_blocks: Array[String] = []
	text = _extract_code_blocks(text, code_blocks)
	var links: Array[Dictionary] = []
	text = _extract_links(text, links)

	# 2. Экранируем квадратные скобки, чтобы текст не ломал BBCode.
	text = text.replace("[", "[lb]")

	# 3. Инлайн-форматирование.
	text = _inline_code(text)
	text = _bold(text)
	text = _italic(text)

	# 4. Построчно: заголовки, списки, цитаты, горизонтальные линии.
	var out: Array[String] = []
	for raw_line in text.split("\n"):
		var trimmed := raw_line.strip_edges()
		if trimmed.begins_with("```"):
			continue  # остатки заборов, если блок не закрыт
		if trimmed == "---" or trimmed == "***" or trimmed == "___":
			out.append("[color=#3a4453]────────────────[/color]")
			continue
		if trimmed.begins_with("#"):
			var level := 0
			while level < trimmed.length() and trimmed[level] == "#":
				level += 1
			var heading := trimmed.substr(level).strip_edges()
			var size := clampi(22 - level, 15, 21)
			out.append("[b][font_size=%d]%s[/font_size][/b]" % [size, heading])
			continue
		if trimmed.begins_with("- ") or trimmed.begins_with("* ") or trimmed.begins_with("+ "):
			out.append("  • " + trimmed.substr(2))
			continue
		if trimmed.begins_with("> "):
			out.append("[color=#8b97a8]▎ %s[/color]" % trimmed.substr(2))
			continue
		out.append(raw_line)

	var result := "\n".join(out)

	# 5. Возвращаем ссылки.
	for i in links.size():
		var link: Dictionary = links[i]
		var label: String = str(link["label"]).replace("[", "[lb]")
		var url: String = str(link["url"])
		result = result.replace("<<LINK%d>>" % i,
			"[url=%s][color=#60a5fa]%s[/color][/url]" % [url, label])

	# 6. Возвращаем блоки кода.
	for i in code_blocks.size():
		var code := code_blocks[i].replace("[", "[lb]")
		result = result.replace("<<CODEBLOCK%d>>" % i,
			"[bgcolor=#0b1119][color=#9ecbff][code]" + code + "[/code][/color][/bgcolor]")

	return result


static func _extract_code_blocks(text: String, storage: Array[String]) -> String:
	var result := ""
	var rest := text
	while true:
		var open_idx := rest.find("```")
		if open_idx == -1:
			result += rest
			break
		result += rest.substr(0, open_idx)
		var after := rest.substr(open_idx + 3)
		var first_nl := after.find("\n")
		if first_nl == -1:
			# блок ещё не начался (стриминг только что прислал ```)
			result += "<<CODEBLOCK%d>>" % storage.size()
			storage.append("")
			rest = ""
			break
		var body := after.substr(first_nl + 1)  # язык после ``` отбрасываем
		var close_idx := body.find("```")
		var code := body
		if close_idx == -1:
			rest = ""
		else:
			code = body.substr(0, close_idx)
			rest = body.substr(close_idx + 3)
		result += "<<CODEBLOCK%d>>" % storage.size()
		storage.append(code.strip_edges(false, true))
	return result


static func _extract_links(text: String, storage: Array[Dictionary]) -> String:
	var re := RegEx.new()
	re.compile("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
	var out := ""
	var pos := 0
	for m in re.search_all(text):
		out += text.substr(pos, m.get_start() - pos)
		out += "<<LINK%d>>" % storage.size()
		storage.append({"label": m.get_string(1), "url": m.get_string(2)})
		pos = m.get_end()
	out += text.substr(pos)
	return out


static func _inline_code(text: String) -> String:
	var out := ""
	var rest := text
	while true:
		var open_idx := rest.find("`")
		if open_idx == -1:
			out += rest
			break
		var after := rest.substr(open_idx + 1)
		var close_idx := after.find("`")
		if close_idx == -1:
			out += rest
			break
		out += rest.substr(0, open_idx) + "[code]" + after.substr(0, close_idx) + "[/code]"
		rest = after.substr(close_idx + 1)
	return out


static func _bold(text: String) -> String:
	var re := RegEx.new()
	re.compile("\\*\\*(.+?)\\*\\*")
	return re.sub(text, "[b]$1[/b]", true)


static func _italic(text: String) -> String:
	var re := RegEx.new()
	re.compile("(^|[^*\\w])\\*(?!\\s)([^*]+?)\\*(?!\\*)")
	return re.sub(text, "$1[i]$2[/i]", true)
