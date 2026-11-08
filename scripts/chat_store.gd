extends RefCounted
class_name ChatStore
## Сохранённые переписки.
##
## Каждая переписка — отдельный JSON-файл в user://chats/. Внутри: заголовок,
## время создания/обновления, персонаж и модель, с которыми шёл диалог, и сами
## сообщения (с подписью говорящего у ответов модели).
##
## Заголовок берётся из первого сообщения пользователя, поэтому переписки
## не нужно называть вручную.
##
## Пример:
##   var store := ChatStore.new()
##   store.load_all()
##   var chat := store.new_chat("", "", "llama3.2:latest")
##   chat["messages"].append({"role": "user", "content": "Привет!"})
##   store.save_chat(chat)
##   print(store.items[0]["title"])

const DEFAULT_DIR := "user://chats"
## Сколько символов первого сообщения попадает в заголовок списка.
const TITLE_LIMIT := 42
const EMPTY_TITLE := "Без названия"

## Куда писать. Тесты подменяют на временную папку.
var dir_path: String = DEFAULT_DIR
## Загруженные переписки, свежие сверху.
var items: Array = []

var _seq: int = 0


# ------------------------------------------------------------------ чтение/запись

## Прочитать все переписки из папки. Битые файлы молча пропускаются.
func load_all() -> void:
	items = []
	_ensure_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		var chat := _read_file(dir_path.path_join(file_name))
		if not chat.is_empty():
			items.append(chat)
	_sort_items()


## Новая переписка в памяти (на диск попадёт после save_chat).
## timestamp нужен тестам, в приложении его не передают.
func new_chat(persona_id: String, persona_name: String, model: String,
		timestamp: float = 0.0) -> Dictionary:
	var now := timestamp if timestamp > 0.0 else Time.get_unix_time_from_system()
	return {
		"id": _new_id(),
		"title": "",
		"created_at": now,
		"updated_at": now,
		"persona_id": persona_id,
		"persona_name": persona_name,
		"model": model,
		"messages": [],
	}


## Записать переписку в файл. Возвращает сохранённую запись или {} при ошибке.
## timestamp нужен тестам, чтобы порядок в списке был предсказуемым.
func save_chat(chat: Dictionary, timestamp: float = 0.0) -> Dictionary:
	var chat_id := str(chat.get("id", "")).strip_edges()
	if chat_id.is_empty():
		chat_id = _new_id()
	var now := timestamp if timestamp > 0.0 else Time.get_unix_time_from_system()
	var existing := get_by_id(chat_id)

	var record := normalize(chat)
	record["id"] = chat_id
	if str(record["title"]).strip_edges().is_empty():
		record["title"] = str(existing.get("title", ""))
	if str(record["title"]).strip_edges().is_empty():
		record["title"] = make_title(record["messages"])
	if float(record["created_at"]) <= 0.0:
		record["created_at"] = float(existing.get("created_at", now))
	record["updated_at"] = now

	_ensure_dir()
	var file := FileAccess.open(_chat_path(chat_id), FileAccess.WRITE)
	if file == null:
		return {}
	file.store_string(JSON.stringify(record, "\t"))
	file.close()

	_upsert(record)
	return record


## Удалить переписку (и её файл).
func delete_chat(chat_id: String) -> bool:
	var known := false
	for i in items.size():
		if str(items[i].get("id", "")) == chat_id:
			items.remove_at(i)
			known = true
			break
	var path := _chat_path(chat_id)
	var removed_file := false
	if FileAccess.file_exists(path):
		removed_file = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
	return known or removed_file


func get_by_id(chat_id: String) -> Dictionary:
	for chat in items:
		if str(chat.get("id", "")) == chat_id:
			return chat
	return {}


func count() -> int:
	return items.size()


## Самая свежая переписка (или {}).
func latest() -> Dictionary:
	return items[0] if not items.is_empty() else {}


func clear() -> void:
	items = []


# ------------------------------------------------------------------ красивый текст

## Заголовок из первого сообщения пользователя.
static func make_title(messages: Array) -> String:
	for entry in messages:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if str(entry.get("role", "")) != "user":
			continue
		var text := str(entry.get("content", "")).strip_edges()
		if text.is_empty():
			continue
		var line := text.split("\n")[0].strip_edges()
		if line.length() > TITLE_LIMIT:
			line = line.substr(0, TITLE_LIMIT - 1).strip_edges() + "…"
		return line
	return EMPTY_TITLE


## «только что», «12 мин назад», «вчера», «08.11.2026».
static func format_when(unix_time: int, now: int = 0) -> String:
	var current := now if now > 0 else int(Time.get_unix_time_from_system())
	var diff := current - unix_time
	if diff < 0:
		diff = 0
	if diff < 60:
		return "только что"
	if diff < 3600:
		return "%d мин назад" % int(diff / 60.0)
	if diff < 86400:
		return "%d ч назад" % int(diff / 3600.0)
	if diff < 172800:
		return "вчера"
	if diff < 604800:
		return "%d дн назад" % int(diff / 86400.0)
	var date := Time.get_date_dict_from_unix_time(unix_time)
	return "%02d.%02d.%04d" % [int(date["day"]), int(date["month"]), int(date["year"])]


## Привести запись из файла к известному виду: только user/assistant,
## только role/content/speaker.
static func normalize(raw: Dictionary) -> Dictionary:
	var messages: Array = []
	var raw_messages: Variant = raw.get("messages", [])
	if typeof(raw_messages) == TYPE_ARRAY:
		for entry in raw_messages:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var role := str(entry.get("role", ""))
			if role != "user" and role != "assistant":
				continue
			var message := {
				"role": role,
				"content": str(entry.get("content", "")),
			}
			var speaker := str(entry.get("speaker", ""))
			if not speaker.is_empty():
				message["speaker"] = speaker
			messages.append(message)
	return {
		"id": str(raw.get("id", "")),
		"title": str(raw.get("title", "")).strip_edges(),
		"created_at": float(raw.get("created_at", 0.0)),
		"updated_at": float(raw.get("updated_at", 0.0)),
		"persona_id": str(raw.get("persona_id", "")),
		"persona_name": str(raw.get("persona_name", "")),
		"model": str(raw.get("model", "")),
		"messages": messages,
	}


# ------------------------------------------------------------------ служебное

func _read_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var raw: Variant = json.data
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var chat := normalize(raw)
	if str(chat["title"]).is_empty():
		chat["title"] = make_title(chat["messages"])
	if str(chat["id"]).is_empty():
		return {}
	return chat


func _upsert(record: Dictionary) -> void:
	for i in items.size():
		if str(items[i].get("id", "")) == str(record.get("id", "")):
			items[i] = record
			_sort_items()
			return
	items.append(record)
	_sort_items()


func _sort_items() -> void:
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("updated_at", 0.0)) > float(b.get("updated_at", 0.0))
	)


func _ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))


func _chat_path(chat_id: String) -> String:
	var safe := ""
	for i in chat_id.length():
		var symbol := chat_id.substr(i, 1)
		if "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-".contains(symbol):
			safe += symbol
		else:
			safe += "_"
	return dir_path.path_join(safe + ".json")


func _new_id() -> String:
	_seq += 1
	var chat_id := "c_%d_%d" % [Time.get_ticks_usec(), _seq]
	while not get_by_id(chat_id).is_empty():
		_seq += 1
		chat_id = "c_%d_%d" % [Time.get_ticks_usec(), _seq]
	return chat_id
