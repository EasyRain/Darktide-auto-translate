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
        raw = self.rfile.read(length).decode("utf-8", "replace")
        content_type = (self.headers.get("Content-Type") or "").lower()

        # A form body is what a DeepL-shaped request sends; a JSON body is accepted too, so
        # the template field stays general. Anything else is a 400 - which is exactly the
        # signal the test wants when the mod's escaping is wrong.
        if "json" in content_type:
            try:
                data = json.loads(raw)
            except Exception as exc:
                self._fail(400, f"invalid JSON body: {exc}")
                return
            messages = data.get("messages") or []
            text = next((m.get("content", "") for m in messages if m.get("role") == "user"), "")
            if not text:
                text = data.get("text") or data.get("q") or ""
            system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
            self._send({
                "choices": [{"index": 0, "message": {"role": "assistant", "content": f"{MARK} {text}"}}],
                "received": {"system": system, "text": text},
            })
            return

        values = {}
        for pair in raw.split("&"):
            if "=" in pair:
                key, value = pair.split("=", 1)
                values[unquote(key)] = unquote(value)
        text = values.get("text") or values.get("q") or ""
        self._send({
            "translations": [{"detected_source_language": values.get("source_lang", "EN").upper(),
                              "text": f"{MARK} {text}"}],
            "received": values,
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
