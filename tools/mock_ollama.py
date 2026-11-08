#!/usr/bin/env python3
"""Мини-заглушка Ollama API — чтобы тестировать чат без установленной модели.

Реализует то же поведение, что и настоящий сервер:
    GET  /api/version  -> {"version": "0.0.0-mock"}
    GET  /api/tags     -> список моделей
    POST /api/chat     -> stриминг NDJSON (chunked) или обычный JSON, если stream=false
                          для неизвестной модели отдаёт 404 + {"error": ...}

Запуск:  python3 tools/mock_ollama.py [--port 11434]
"""
import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["llama3.2:latest", "qwen2.5-coder:7b"]
REPLY = (
    "Привет! Это **тестовый** ответ от мок-сервера.\n\n"
    "Список:\n- первый пункт\n- второй пункт\n\n"
    "```gdscript\nprint(\"hello\")\n```\n\nГотово."
)
LONG_REPLY = (
    "## Коротко\n\n"
    "Чтобы подключить локальную модель, Godot-приложению достаточно обычного HTTP: "
    "никаких SDK и Python-обвязок не нужно, потому что Ollama поднимает локальный "
    "REST API на `http://localhost:11434`.\n\n"
    "### Что происходит по шагам\n\n"
    "1. Godot отправляет `POST /api/chat` с историей сообщений.\n"
    "2. Ollama стримит ответ кусками NDJSON — по одной строке на токен.\n"
    "3. Клиент разбирает строки, склеивает `message.content` и отдаёт в UI через сигналы.\n\n"
    "```gdscript\n"
    "client.chat_delta.connect(func(piece: String): bubble.append_piece(piece))\n"
    "client.send_chat(messages, \"llama3.2\")\n"
    "```\n\n"
    "Главный плюс такого подхода: **приложение остаётся полностью офлайн**, "
    "а данные не покидают машину. Минус — модель занимает место на диске "
    "и требует памяти, поэтому на слабом ноутбуке лучше брать варианты на 1–3 B параметров."
)

DUMP_PATH = os.environ.get("MOCK_DUMP", "/tmp/mock_last_request.json")
CHUNK_DELAY = float(os.environ.get("MOCK_DELAY", "0.02"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # тишина в логах
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _chunk(self, data: bytes):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()

    def do_GET(self):
        if self.path == "/api/version":
            self._json({"version": "0.0.0-mock"})
        elif self.path == "/api/tags":
            self._json({"models": [{"name": m, "model": m, "size": 123} for m in MODELS]})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._json({"error": "invalid json"}, 400)

        with open(DUMP_PATH, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)

        if self.path != "/api/chat":
            return self._json({"error": "not found"}, 404)

        model = payload.get("model", "")
        if model not in MODELS:
            return self._json(
                {"error": f"model '{model}' not found, try pulling it first"}, 404
            )

        # длинный ответ — если в последнем сообщении пользователя есть "длинно"
        last_user = ""
        for message in payload.get("messages", []):
            if message.get("role") == "user":
                last_user = message.get("content", "")
        reply = LONG_REPLY if "длинно" in last_user else REPLY
        # "медленно" — специально медленный поток, чтобы тест отмены успел сработать
        delay = 0.15 if "медленно" in last_user else CHUNK_DELAY

        if not payload.get("stream", True):
            return self._json({
                "model": model,
                "message": {"role": "assistant", "content": reply},
                "done": True,
                "eval_count": 42,
                "prompt_eval_count": 12,
                "eval_duration": 1_000_000_000,
                "total_duration": 1_500_000_000,
            })

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for i in range(0, len(reply), 3):
                line = json.dumps({
                    "model": model,
                    "message": {"role": "assistant", "content": reply[i:i + 3]},
                    "done": False,
                }, ensure_ascii=False) + "\n"
                self._chunk(line.encode("utf-8"))
                time.sleep(delay)
            final = json.dumps({
                "model": model,
                "message": {"role": "assistant", "content": ""},
                "done": True,
                "eval_count": 42,
                "prompt_eval_count": 12,
                "eval_duration": 800_000_000,
                "total_duration": 1_200_000_000,
            }, ensure_ascii=False) + "\n"
            self._chunk(final.encode("utf-8"))
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=11434)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"mock ollama на http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
