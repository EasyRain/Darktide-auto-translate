#!/usr/bin/env python3
"""A local stand-in for a translation endpoint, for testing the custom API engine.

Answers two shapes, so both halves of the configuration can be exercised without a real
service and without a key:

    POST /v1/chat    OpenAI-compatible: reads the JSON body (which proves the mod's
                     templating produced valid JSON), takes the user message, and answers
                     {"choices":[{"message":{"content":"<echo>"}}]}
    GET  /translate  query style: answers {"translatedText": "..."} built from ?q=

    python tools/custom_api_stub.py [port]      (default 8791)

The reply is the request text with a marker, so a test can assert what arrived as well as
what came back.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote

MARK = "[stub]"


class Handler(BaseHTTPRequestHandler):
    def _send(self, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fail(self, status: int, message: str) -> None:
        body = json.dumps({"error": {"message": message}}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception as exc:  # the point of the test: the body must parse
            self._fail(400, f"invalid JSON body: {exc}")
            return

        messages = data.get("messages") or []
        text = ""
        system = ""
        for message in messages:
            if message.get("role") == "system":
                system = message.get("content", "")
            elif message.get("role") == "user":
                text = message.get("content", "")
        if not text and isinstance(data.get("text"), str):
            text = data["text"]

        self._send({
            "choices": [{"index": 0, "message": {"role": "assistant", "content": f"{MARK} {text}"}}],
            "received": {"model": data.get("model"), "system": system, "text": text},
        })

    def do_GET(self) -> None:
        query = ""
        if "?" in self.path:
            query = self.path.split("?", 1)[1]
        values = {}
        for pair in query.split("&"):
            if "=" in pair:
                key, value = pair.split("=", 1)
                # A real service decodes its query string; echo the decoded value so a test
                # can tell "the client encoded it correctly" from "the client sent %20".
                values[key] = unquote(value)
        text = values.get("q") or values.get("text") or ""
        self._send({"translatedText": f"{MARK} {text}", "received": values})

    def log_message(self, *args) -> None:
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
    print(f"custom API stub on http://127.0.0.1:{port}", flush=True)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
