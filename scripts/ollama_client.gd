extends Node
class_name OllamaClient
## Клиент к локальному Ollama и к любому OpenAI-совместимому API.
## Полностью асинхронный, без блокировки кадра. Два режима (переменная provider):
##
##   "ollama" — локальный сервер:
##       список моделей        GET  /api/tags
##       проверка соединения   GET  /api/version
##       чат                   POST /api/chat          (NDJSON, stream: true)
##
##   "openai" — OpenAI-совместимый API (Ollama Cloud, OpenAI, Groq, OpenRouter…):
##       список моделей        GET  /models
##       чат                   POST /chat/completions  (SSE, stream: true)
##       адрес указывается вместе с версией, например "https://ollama.com/v1",
##       ключ уходит в заголовке Authorization: Bearer <api_key>
##
## Умеет также: потоковую выдачу токен за токеном и отмену на середине ответа.
##
## Пример:
##   var client := OllamaClient.new()
##   add_child(client)
##   client.chat_delta.connect(func(piece): print(piece))
##   client.chat_done.connect(func(text, stats): print("\n[готово] ", stats))
##   client.send_chat([{"role": "user", "content": "Привет!"}], "llama3.2")

## Список моделей получен (имена в формате "llama3.2:latest").
signal models_loaded(models: Array)
## Не удалось получить список моделей.
signal models_error(message: String)
## Проверка соединения: ok + версия сервера (например "0.3.4").
signal connection_checked(ok: bool, version: String)

## Чат начался (запрос ушёл на сервер).
signal chat_started()
## Очередной кусочек ответа (при stream = true их много, иначе не будет вовсе).
signal chat_delta(piece: String)
## Ответ завершён: полный текст + статистика (tok_per_sec, eval_count, total_sec).
signal chat_done(full_text: String, stats: Dictionary)
## Запрос отменён пользователем; partial_text — то, что успело прийти.
signal chat_cancelled(partial_text: String)
## Ошибка: сервер недоступен, модель не найдена и т.п.
signal chat_error(message: String)

## Адрес сервера. Можно указать порт и путь: "http://192.168.1.10:11434".
## Для OpenAI-совместимого провайдера — вместе с версией: "https://ollama.com/v1".
var host: String = "http://localhost:11434"
## Провайдер: "ollama" — локальный сервер, "openai" — OpenAI-совместимый API.
var provider: String = "ollama"
## API-ключ для OpenAI-совместимого провайдера (для локального Ollama не нужен).
var api_key: String = ""
## Имя модели, например "llama3.2" или "qwen2.5-coder:7b".
var model: String = ""
## Температура сэмплирования (0.0 — строго, 1.0+ — креативно).
var temperature: float = 0.8
## Системный промпт, добавляется в начало истории.
var system_prompt: String = ""
## Стриминг ответа (true — текст «печатается» по мере генерации).
var stream: bool = true
## Сколько держать модель в памяти после ответа ("10m", "0" — выгрузить сразу).
var keep_alive: String = "10m"
## Общий таймаут одного запроса в секундах.
var request_timeout: float = 180.0

enum Phase { IDLE, CONNECTING, WAITING, READING }

var _req: HTTPRequest                 # обычные (не потоковые) запросы
var _req_op: String = ""
var _http: HTTPClient                 # потоковый чат
var _phase: int = Phase.IDLE
var _addr: String = ""
var _port: int = 11434
var _tls: bool = false
var _base_path: String = ""
var _body: String = ""
var _line_buf: String = ""
var _acc: String = ""
var _stats: Dictionary = {}
var _elapsed: float = 0.0
var _busy: bool = false
var _http_code: int = 0
var _stream_failed: bool = false


func _ready() -> void:
	_ensure_req()


func _exit_tree() -> void:
	cancel()


## Идёт ли сейчас генерация / запрос.
func is_busy() -> bool:
	return _busy


# ---------------------------------------------------------------- публичное API

## Ленивая инициализация HTTPRequest: методы клиента можно вызывать
## сразу после new(), не дожидаясь _ready().
func _ensure_req() -> void:
	if _req != null:
		return
	_req = HTTPRequest.new()
	_req.use_threads = true
	_req.timeout = request_timeout
	add_child(_req)
	_req.request_completed.connect(_on_request_completed)

## Запросить список моделей. Ответ придёт в models_loaded / models_error.
func fetch_models() -> void:
	_plain_request("models", HTTPClient.METHOD_GET, "/models" if is_openai() else "/api/tags")


## Проверить, что сервер доступен. Ответ в connection_checked.
func check_connection() -> void:
	_plain_request("version", HTTPClient.METHOD_GET, "/models" if is_openai() else "/api/version")


## Работаем с OpenAI-совместимым API (а не с «родным» API Ollama).
func is_openai() -> bool:
	return provider == "openai"


## Отправить историю сообщений модели.
## messages: [{"role": "user"|"assistant"|"system", "content": "текст"}, ...]
func send_chat(messages: Array, p_model: String = "") -> void:
	if not p_model.strip_edges().is_empty():
		model = p_model
	if model.strip_edges().is_empty():
		chat_error.emit("Не выбрана модель. Выберите модель в списке слева.")
		return
	if _busy:
		return

	var payload := _build_payload(messages)
	_busy = true
	_acc = ""
	_stats = {}
	_stream_failed = false
	_http_code = 0

	if stream:
		_start_stream(payload)
	else:
		_plain_request("chat", HTTPClient.METHOD_POST,
			"/chat/completions" if is_openai() else "/api/chat", payload)
		chat_started.emit()


## Прервать текущую генерацию (кнопка «Стоп»).
func cancel() -> void:
	if not _busy:
		return
	_busy = false
	if _http != null and _http.get_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.close()
	if _req != null and _req.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_req.cancel_request()
	var partial := _acc
	_phase = Phase.IDLE
	chat_cancelled.emit(partial)


# ---------------------------------------------------------------- потоковый чат

func _start_stream(payload: Dictionary) -> void:
	_parse_host()
	_body = JSON.stringify(payload)
	_line_buf = ""
	_elapsed = 0.0

	_http = HTTPClient.new()
	var tls_options: TLSOptions = TLSOptions.client() if _tls else null
	var err := _http.connect_to_host(_addr, _port, tls_options)
	if err != OK:
		_fail("Не удалось начать подключение к %s (код %d)." % [host, err])
		return
	_phase = Phase.CONNECTING
	chat_started.emit()


func _process(delta: float) -> void:
	if _phase == Phase.IDLE:
		return

	_elapsed += delta
	if _elapsed > request_timeout:
		_fail("Таймаут: сервер не ответил за %d с. Для больших моделей увеличьте request_timeout." % int(request_timeout))
		return

	_http.poll()
	var status := _http.get_status()

	match _phase:
		Phase.CONNECTING:
			match status:
				HTTPClient.STATUS_CONNECTED:
					var err := _http.request(
						HTTPClient.METHOD_POST,
						_base_path + ("/chat/completions" if is_openai() else "/api/chat"),
						_stream_headers(),
						_body)
					if err != OK:
						_fail("Не удалось отправить запрос (код %d)." % err)
					else:
						_phase = Phase.WAITING
						_elapsed = 0.0
				HTTPClient.STATUS_CANT_RESOLVE:
					_fail("Не удалось разрешить адрес «%s». Проверьте имя хоста." % _addr)
				HTTPClient.STATUS_CANT_CONNECT:
					_fail("%s не отвечает на %s. %s" % [_server_name(), host, _offline_hint()])
				HTTPClient.STATUS_CONNECTION_ERROR:
					_fail("Ошибка соединения с %s." % host)
				HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
					_fail("Ошибка TLS. Проверьте адрес (https) и сертификат сервера.")

		Phase.WAITING:
			if status == HTTPClient.STATUS_BODY:
				_http_code = _http.get_response_code()
				_phase = Phase.READING
			elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR:
				_fail("Соединение прервано до получения ответа.")

		Phase.READING:
			while _phase == Phase.READING and _http.get_status() == HTTPClient.STATUS_BODY and _http.has_response():
				var chunk := _http.read_response_body_chunk()
				if chunk.is_empty():
					break
				_consume(chunk.get_string_from_utf8())
			if _phase == Phase.READING and _http.get_status() != HTTPClient.STATUS_BODY:
				_finish_stream()


## Разбираем поток: режем на строки, каждая строка — отдельный JSON (NDJSON).
func _consume(text: String) -> void:
	_line_buf += text
	while true:
		var nl := _line_buf.find("\n")
		if nl == -1:
			break
		var line := _line_buf.substr(0, nl).strip_edges()
		_line_buf = _line_buf.substr(nl + 1)
		if not line.is_empty():
			_handle_line(line)


func _handle_line(line: String) -> void:
	var text := line
	if is_openai():
		# формат Server-Sent Events: "data: {...}" и завершающее "data: [DONE]"
		if text.begins_with(":") or text.begins_with("event:"):
			return
		if text.begins_with("data:"):
			text = text.substr(5).strip_edges()
		if text.is_empty() or text == "[DONE]":
			return

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed

	if data.has("error"):
		_fail(_error_for_code(_http_code, _error_text(data["error"])))
		return

	if is_openai():
		var choices: Variant = data.get("choices", [])
		if typeof(choices) == TYPE_ARRAY and not choices.is_empty():
			var first: Variant = choices[0]
			if typeof(first) == TYPE_DICTIONARY:
				var piece := ""
				var delta: Variant = first.get("delta", {})
				if typeof(delta) == TYPE_DICTIONARY:
					piece = str(delta.get("content", ""))
				if piece.is_empty():
					var message: Variant = first.get("message", {})
					if typeof(message) == TYPE_DICTIONARY:
						piece = str(message.get("content", ""))
				if not piece.is_empty():
					_acc += piece
					chat_delta.emit(piece)
		_merge_usage(data)
		return

	var msg: Variant = data.get("message", {})
	if typeof(msg) == TYPE_DICTIONARY and msg.has("content"):
		var piece := str(msg["content"])
		if not piece.is_empty():
			_acc += piece
			chat_delta.emit(piece)

	if data.get("done", false) == true:
		_stats = _extract_stats(data)


func _finish_stream() -> void:
	if not _busy:
		return
	if _http != null and _http.get_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.close()
	_phase = Phase.IDLE
	_busy = false

	# Дошли до конца, но «хвост» последней строки не был закрыт переводом строки.
	_consume("\n")
	if _phase != Phase.IDLE or _stream_failed:
		return

	if _http_code != 0 and (_http_code < 200 or _http_code >= 300):
		_fail("HTTP %d от сервера (%s)." % [_http_code, host])
		return

	if _acc.strip_edges().is_empty():
		chat_error.emit("Модель вернула пустой ответ.")
		return

	chat_done.emit(_acc, _stats)


# ---------------------------------------------------------------- обычные запросы

func _plain_request(op: String, method: int, path: String, payload: Dictionary = {}) -> void:
	_ensure_req()
	if not is_inside_tree():
		# вызвали слишком рано (например, из _init) — отложим до первого кадра
		call_deferred("_plain_request", op, method, path, payload)
		return
	if _req.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_req.cancel_request()
	_req_op = op
	_req.timeout = request_timeout
	var headers := _headers()
	var url := host.strip_edges().trim_suffix("/") + path
	var err := OK
	if method == HTTPClient.METHOD_GET:
		err = _req.request(url, headers, HTTPClient.METHOD_GET)
	else:
		err = _req.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		_emit_error(op, "Не удалось отправить запрос (код %d). Проверьте адрес сервера." % err)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var op := _req_op
	_req_op = ""

	if result != HTTPRequest.RESULT_SUCCESS:
		var msg := "Ошибка запроса (%d)." % result
		match result:
			HTTPRequest.RESULT_CANT_CONNECT:
				msg = "%s недоступен по адресу %s. %s" % [_server_name(), host, _offline_hint()]
			HTTPRequest.RESULT_CANT_RESOLVE:
				msg = "Не удалось разрешить адрес «%s»." % host
			HTTPRequest.RESULT_CONNECTION_ERROR:
				msg = "Соединение с %s прервано." % host
			HTTPRequest.RESULT_TIMEOUT:
				msg = "Таймаут: сервер не ответил за %d с." % int(request_timeout)
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
				msg = "Ошибка TLS-рукопожатия. Проверьте сертификат сервера."
		_emit_error(op, msg)
		return

	var text := body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)

	if code < 200 or code >= 300:
		var detail := "HTTP %d" % code
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("error"):
			detail = _error_text(parsed["error"])
		_emit_error(op, _error_for_code(code, detail))
		return

	if typeof(parsed) != TYPE_DICTIONARY:
		_emit_error(op, "Некорректный ответ сервера (ожидался JSON).")
		return
	var data: Dictionary = parsed

	match op:
		"models":
			var names: Array = []
			if is_openai():
				for m in data.get("data", []):
					if typeof(m) == TYPE_DICTIONARY and m.has("id"):
						names.append(str(m["id"]))
				names.sort()
			else:
				for m in data.get("models", []):
					if typeof(m) == TYPE_DICTIONARY and m.has("name"):
						names.append(str(m["name"]))
			models_loaded.emit(names)

		"version":
			connection_checked.emit(true, str(data.get("version", "")))

		"chat":
			_busy = false
			_acc = _extract_content(data)
			_stats = _extract_stats(data)
			_merge_usage(data)
			if _acc.strip_edges().is_empty():
				chat_error.emit("Модель вернула пустой ответ.")
			else:
				chat_done.emit(_acc, _stats)


# ---------------------------------------------------------------- служебное

func _emit_error(op: String, message: String) -> void:
	match op:
		"models":
			models_error.emit(message)
		"version":
			connection_checked.emit(false, "")
		"chat":
			_busy = false
			_phase = Phase.IDLE
			chat_error.emit(message)


func _fail(message: String) -> void:
	if _http != null and _http.get_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.close()
	_busy = false
	_phase = Phase.IDLE
	_stream_failed = true
	chat_error.emit(message)


## Тело запроса: у Ollama свои поля (options, keep_alive), у OpenAI-совместимых — плоские.
func _build_payload(messages: Array) -> Dictionary:
	if is_openai():
		return {
			"model": model,
			"messages": _with_system(messages),
			"stream": stream,
			"temperature": temperature,
		}
	return {
		"model": model,
		"messages": _with_system(messages),
		"stream": stream,
		"options": {"temperature": temperature},
		"keep_alive": keep_alive,
	}


## Заголовки обычного запроса. Для облака добавляется ключ.
func _headers() -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json"])
	var key := api_key.strip_edges()
	if is_openai() and not key.is_empty():
		headers.append("Authorization: Bearer " + key)
	return headers


## Заголовки потокового запроса: формат ответа зависит от провайдера.
func _stream_headers() -> PackedStringArray:
	var headers := _headers()
	headers.append("Accept: text/event-stream" if is_openai() else "Accept: application/x-ndjson")
	return headers


## Понятный текст для типичных кодов ошибок облачного API.
func _error_for_code(code: int, fallback: String) -> String:
	if not is_openai():
		return fallback
	match code:
		401:
			return "Неверный API-ключ (HTTP 401). Проверьте ключ в настройках."
		403:
			return "Доступ запрещён (HTTP 403). Проверьте ключ и права аккаунта."
		429:
			return "Слишком много запросов (HTTP 429). Подождите немного и повторите."
	return fallback


## Текст ошибки из ответа сервера: строка или {"error": {"message": …}}.
func _error_text(value: Variant) -> String:
	if typeof(value) == TYPE_DICTIONARY:
		var data: Dictionary = value
		if data.has("message"):
			return str(data["message"])
		if data.has("error"):
			return str(data["error"])
		return JSON.stringify(data)
	return str(value)


## Текст ответа из JSON (разные форматы у Ollama и OpenAI-совместимых API).
func _extract_content(data: Dictionary) -> String:
	if is_openai():
		var choices: Variant = data.get("choices", [])
		if typeof(choices) == TYPE_ARRAY and not choices.is_empty():
			var first: Variant = choices[0]
			if typeof(first) == TYPE_DICTIONARY:
				var message: Variant = first.get("message", {})
				if typeof(message) == TYPE_DICTIONARY:
					return str(message.get("content", ""))
		return ""
	var msg: Variant = data.get("message", {})
	if typeof(msg) == TYPE_DICTIONARY:
		return str(msg.get("content", ""))
	return ""


## Статистика из блока usage (OpenAI-совместимые API).
func _merge_usage(data: Dictionary) -> void:
	var usage: Variant = data.get("usage", {})
	if typeof(usage) != TYPE_DICTIONARY:
		return
	var counts: Dictionary = usage
	if counts.has("completion_tokens"):
		_stats["eval_count"] = int(counts["completion_tokens"])
	if counts.has("prompt_tokens"):
		_stats["prompt_tokens"] = int(counts["prompt_tokens"])


## Как называть сервер в сообщениях об ошибках.
func _server_name() -> String:
	return "Сервер" if is_openai() else "Ollama"


## Подсказка, что делать, если сервер не отвечает.
func _offline_hint() -> String:
	if is_openai():
		return "Проверьте адрес API (он должен заканчиваться на /v1), ключ и интернет."
	return "Запущен ли сервер? Используйте «ollama serve»."


## Копия истории с системным промптом в начале (если он задан).
func _with_system(messages: Array) -> Array:
	var out: Array = []
	var has_system := false
	for m in messages:
		if typeof(m) == TYPE_DICTIONARY and str(m.get("role", "")) == "system":
			has_system = true
		out.append(m)
	if not system_prompt.strip_edges().is_empty() and not has_system:
		out.push_front({"role": "system", "content": system_prompt.strip_edges()})
	return out


func _extract_stats(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if data.has("eval_count"):
		out["eval_count"] = int(data["eval_count"])
	if data.has("prompt_eval_count"):
		out["prompt_tokens"] = int(data["prompt_eval_count"])
	if data.has("total_duration"):
		out["total_sec"] = float(data["total_duration"]) / 1e9
	if data.has("eval_duration") and int(data["eval_duration"]) > 0 and out.has("eval_count"):
		out["tok_per_sec"] = float(out["eval_count"]) / (float(data["eval_duration"]) / 1e9)
	return out


## Разбираем "http(s)://host:port/base" на части для HTTPClient.
func _parse_host() -> void:
	var h := host.strip_edges()
	_tls = false
	_base_path = ""
	if h.begins_with("https://"):
		_tls = true
		h = h.substr(8)
	elif h.begins_with("http://"):
		h = h.substr(7)

	var slash := h.find("/")
	if slash != -1:
		_base_path = h.substr(slash).trim_suffix("/")
		h = h.substr(0, slash)

	_port = 443 if _tls else 11434
	var colon := h.rfind(":")
	if colon != -1:
		var port_str := h.substr(colon + 1)
		if port_str.is_valid_int():
			_port = int(port_str)
			h = h.substr(0, colon)

	_addr = h
