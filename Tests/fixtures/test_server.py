import json
import os
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import FixtureServer


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ["TZBOX_TEST_ROOT"])
        self.capture = self.root / "fixture-requests.jsonl"
        self.server = FixtureServer(("127.0.0.1", 0), self.capture)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.capture.unlink(missing_ok=True)

    def post(self, payload):
        request = Request(self.base + "/v1/chat/completions", json.dumps(payload).encode(),
                          {"Content-Type": "application/json", "Authorization": "Bearer synthetic-do-not-record"})
        return urlopen(request, timeout=3)

    def test_request_sink_records_input_without_credentials(self):
        messages = [{"role": "system", "content": "Synthetic time 09:30, Asia/Tokyo"}]
        with self.post({"model": "tzbox-test", "messages": messages, "timezone": "Asia/Tokyo"}) as response:
            self.assertEqual(response.status, 200)
        text = self.capture.read_text()
        captured = json.loads(text)
        self.assertEqual(captured["messages"], messages)
        self.assertEqual(captured["timezone"], "Asia/Tokyo")
        self.assertNotIn("synthetic-do-not-record", text)

    def test_streaming_response_terminates(self):
        with self.post({"messages": [], "stream": True}) as response:
            self.assertEqual(response.headers["Content-Type"], "text/event-stream")
            self.assertTrue(response.read().endswith(b"data: [DONE]\n\n"))

    def test_fixture_pages_and_workers(self):
        for path in ("/page", "/frame", "/worker.js", "/service-worker.js", "/v1/models"):
            with urlopen(self.base + path, timeout=3) as response:
                self.assertEqual(response.status, 200)
                self.assertGreater(len(response.read()), 0)

    def test_invalid_payload_is_not_recorded(self):
        with self.assertRaises(HTTPError) as error:
            self.post({"messages": "wrong"})
        self.assertEqual(error.exception.code, 400)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
