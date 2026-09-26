"""Loopback-only browser fixtures and synthetic OpenAI-compatible request sink.

This is a developer fixture, not part of the shipped desktop application.
Use only fresh test profiles and synthetic messages; never point normal chats here.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

PAGE = b"""<!doctype html><meta charset="utf-8"><title>TZBox self-test</title>
<h1>TZBox local diagnostic fixture</h1><p id="purpose">Synthetic tests only.</p>"""
WORKER = b"""self.onmessage = async event => {
  try { self.postMessage(await self.eval(event.data.expression)); }
  catch (error) { self.postMessage({fixtureError: String(error)}); }
};"""
SERVICE_WORKER = b"""self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('message', async event => {
  try { event.ports[0].postMessage(await self.eval(event.data.expression)); }
  catch (error) { event.ports[0].postMessage({fixtureError: String(error)}); }
});"""


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, requests_path):
        super().__init__(address, Handler)
        self.requests_path = Path(requests_path)
        self.record_lock = threading.Lock()

    def record(self, payload):
        # Auth headers are deliberately never captured.
        record = {
            "received_at_unix": time.time(),
            "model": payload.get("model"),
            "messages": payload.get("messages", []),
        }
        for field in ("timezone", "time_zone"):
            if field in payload:
                record[field] = payload[field]
        with self.record_lock, self.requests_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send(self, status, data, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type, authorization")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Service-Worker-Allowed", "/")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send(204, b"")

    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ("/", "/page", "/frame"):
            self.send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/worker.js":
            self.send(200, WORKER, "application/javascript")
        elif path == "/service-worker.js":
            self.send(200, SERVICE_WORKER, "application/javascript")
        elif path == "/v1/models":
            self.send(200, json.dumps({"object": "list", "data": [
                {"id": "tzbox-test", "object": "model", "owned_by": "local-fixture"}
            ]}).encode())
        else:
            self.send(404, b'{"error":"unknown fixture path"}')

    def do_POST(self):
        if urlsplit(self.path).path != "/v1/chat/completions":
            self.send(404, b'{"error":"unknown fixture path"}')
            return
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if not isinstance(payload, dict) or not isinstance(payload.get("messages"), list):
                raise TypeError("messages must be an array")
        except (ValueError, TypeError):
            self.send(400, b'{"error":"invalid synthetic request"}')
            return
        self.server.record(payload)
        answer = "TZBox synthetic request received. Inspect the captured request, not this reply."
        if payload.get("stream"):
            chunk = {"id": "tzbox-fixture", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": "tzbox-test", "choices": [{"index": 0, "delta": {"role": "assistant", "content": answer},
                                                       "finish_reason": None}]}
            end = dict(chunk, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])
            events = "".join(f"data: {json.dumps(item)}\n\n" for item in (chunk, end)) + "data: [DONE]\n\n"
            self.send(200, events.encode(), "text/event-stream")
        else:
            response = {"id": "tzbox-fixture", "object": "chat.completion", "created": int(time.time()),
                        "model": "tzbox-test", "choices": [{"index": 0, "message": {"role": "assistant", "content": answer},
                                                          "finish_reason": "stop"}],
                        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}}
            self.send(200, json.dumps(response).encode())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--test-root", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    root = args.test_root.resolve()
    repository = Path(__file__).resolve().parents[2]
    if root.parent != (repository / "tmp").resolve() or not (root / ".codex-tmp").is_file():
        parser.error("--test-root must be a marked task directory directly under repository tmp/")
    server = FixtureServer(("127.0.0.1", args.port), root / "fixture-requests.jsonl")
    address = {"base_url": f"http://127.0.0.1:{server.server_address[1]}", "pid": __import__("os").getpid()}
    (root / "fixture-server.json").write_text(json.dumps(address), encoding="utf-8")
    print(json.dumps(address), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
