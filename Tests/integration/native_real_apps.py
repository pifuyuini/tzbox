"""Opt-in macOS integration test for the production NativeLauncher.

Run with repository .venv/bin/python and an already-built TZBoxDiagnostics binary.
The diagnostic session driver is the only component that starts, restarts, or quits
applications. CDP only observes time and operates synthetic test pages / the
application's own chat API; no Emulation calls or clock replacement are used.
All browser profiles, Cherry home/configuration, and evidence are task-owned.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import platform
import re
import select
import shutil
import socket
import struct
import subprocess
import threading
import time
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

LOGGER = logging.getLogger(__name__)
REPOSITORY = Path(__file__).resolve().parents[2]
SNAPSHOT = """(() => {
 const now=Date.now(); const sample=value=>{const d=new Date(value);return {
 timestamp:value,offset:d.getTimezoneOffset(),
 local:[d.getFullYear(),d.getMonth()+1,d.getDate(),d.getHours(),d.getMinutes(),d.getSeconds()]}};
 return {zone:Intl.DateTimeFormat().resolvedOptions().timeZone,now,
 offset:new Date(now).getTimezoneOffset(),
 samples:[1704152700000,1705320000000,1721044800000,1710053999000,1710054000000,
 1730613599000,1730613600000].map(sample)};
})()"""
SENTINEL = "tzbox-synthetic-persistence"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def unused_loopback_port():
    with socket.socket() as stream:
        stream.bind(("127.0.0.1", 0))
        return stream.getsockname()[1]


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        return json.load(response)


def wait_for(get, description, seconds=25):
    deadline = time.monotonic() + seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = get()
            if result:
                return result
        except (OSError, ValueError, StopIteration, RuntimeError) as error:
            last_error = error
        time.sleep(0.1)
    raise TimeoutError(f"{description}: {last_error or 'not ready'}")


class CDP:
    """Small stdlib WebSocket client for local developer test endpoints only."""

    def __init__(self, endpoint):
        parts = urlsplit(endpoint)
        if parts.hostname != "127.0.0.1" or parts.scheme != "ws":
            raise ValueError("Only loopback ws endpoints are permitted")
        self.stream = socket.create_connection((parts.hostname, parts.port), timeout=15)
        self.buffer = b""
        self.serial = 0
        self.methods = []
        self.await_promises = True
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {parts.path} HTTP/1.1\r\nHost: {parts.netloc}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.stream.sendall(request.encode())
        while b"\r\n\r\n" not in self.buffer:
            chunk = self.stream.recv(4096)
            if not chunk:
                raise EOFError("WebSocket handshake closed")
            self.buffer += chunk
        header, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        if not header.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(header.decode())

    def take(self, count):
        while len(self.buffer) < count:
            chunk = self.stream.recv(max(4096, count - len(self.buffer)))
            if not chunk:
                raise EOFError("CDP socket closed")
            self.buffer += chunk
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def send(self, payload, opcode=1):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        mask = os.urandom(4)
        length = len(data)
        encoded = (
            bytes([length | 128])
            if length < 126
            else b"\xfe" + struct.pack(">H", length)
            if length < 65536
            else b"\xff" + struct.pack(">Q", length)
        )
        self.stream.sendall(
            bytes([128 | opcode])
            + encoded
            + mask
            + bytes(c ^ mask[i % 4] for i, c in enumerate(data))
        )

    def receive(self):
        fragments = []
        while True:
            flags, size = self.take(2)
            length = size & 127
            if length == 126:
                length = struct.unpack(">H", self.take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.take(8))[0]
            mask = self.take(4) if size & 128 else None
            payload = self.take(length)
            if mask:
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
            opcode = flags & 15
            if opcode == 8:
                raise EOFError("CDP closed")
            if opcode == 9:
                self.send(payload, 10)
                continue
            if opcode == 10:
                continue
            fragments.append(payload)
            if flags & 128:
                return json.loads(b"".join(fragments))

    def call(self, method, params=None, session=None):
        self.serial += 1
        request = {"id": self.serial, "method": method, "params": params or {}}
        if session:
            request["sessionId"] = session
        self.methods.append(method)
        self.send(request)
        while True:
            response = self.receive()
            if response.get("id") == self.serial:
                if "error" in response:
                    raise RuntimeError(response["error"])
                return response.get("result", {})

    def evaluate(self, expression, session=None):
        before = time.time() * 1000
        response = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": self.await_promises,
            },
            session,
        )
        after = time.time() * 1000
        if "exceptionDetails" in response:
            raise RuntimeError(response["exceptionDetails"])
        return {
            "hostBefore": before,
            "hostAfter": after,
            "value": response.get("result", {}).get("value"),
        }

    def value(self, expression, session=None):
        return self.evaluate(expression, session)["value"]

    def close(self):
        self.stream.close()


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, status, body, kind="application/json"):
        payload = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type, authorization")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self):
        self.respond(204, "")

    def do_GET(self):
        path = urlsplit(self.path).path
        kind = "application/javascript"
        if path == "/frame":
            body = f'<script>parent.postMessage({{kind:"tzbox-frame",value:{SNAPSHOT}}},"*")</script>'
            kind = "text/html"
        elif path == "/worker.js":
            body = f"self.onmessage=()=>self.postMessage({SNAPSHOT});"
        elif path == "/shared.js":
            body = f"self.onconnect=e=>{{const p=e.ports[0];p.onmessage=()=>p.postMessage({SNAPSHOT});p.start()}};"
        elif path == "/sw.js":
            body = (
                "self.oninstall=()=>self.skipWaiting();"
                "self.onactivate=e=>e.waitUntil(self.clients.claim());"
                f"self.onmessage=e=>e.ports[0].postMessage({SNAPSHOT});"
            )
        else:
            body = "<!doctype html><title>TZBox integration</title><p>Synthetic test only.</p>"
            kind = "text/html; charset=utf-8"
        self.respond(200, body, kind)

    def do_POST(self):
        if urlsplit(self.path).path != "/v1/chat/completions":
            self.respond(404, '{"error":"unknown synthetic fixture path"}')
            return
        payload = json.loads(
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
        )
        record = {
            "received_at_unix": time.time(),
            "model": payload.get("model"),
            "messages": payload.get("messages", []),
        }
        for key in ("timezone", "time_zone"):
            if key in payload:
                record[key] = payload[key]
        # Deliberately omit headers, credentials and unrelated request fields.
        with self.server.record_lock:
            self.server.records.append(record)
            with self.server.requests_path.open("a") as stream:
                stream.write(json.dumps(record, ensure_ascii=False) + "\n")
        answer = "TZBox synthetic request received. Validate the captured request."
        result = {
            "id": "tzbox-fixture",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": "tzbox-test",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": answer},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        self.respond(200, json.dumps(result))


class SessionDriver:
    def __init__(self, binary, app, control, options, manifest):
        self.control = control
        control.mkdir()
        (control / ".codex-tmp").write_text(
            "Owned child of native_real_apps integration task\n"
        )
        write_json(control / "launch-options.json", options)
        self.stderr = (control / "driver-stderr.log").open("w")
        environment = dict(os.environ)
        environment.pop("TZ", None)  # Observe the real system zone on restore.
        self.process = subprocess.Popen(
            [str(binary), "session", str(app), str(control)],
            cwd=REPOSITORY,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            text=True,
            bufsize=1,
        )
        self.history = []
        self.pids = set()
        manifest[app.name] = {
            "driverPID": self.process.pid,
            "controlRoot": str(control),
            "launchOptions": options,
        }
        self.closed = False

    def command(self, action, **parameters):
        request = {"action": action, **parameters}
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], 55)
        if not readable:
            raise TimeoutError(f"session driver timed out: {action}")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"session driver exited during {action}")
        response = json.loads(line)
        self.history.append({"request": request, "response": response})
        write_json(self.control / "driver-history.json", self.history)
        if response.get("processID") and response.get("ok"):
            self.pids.add(response["processID"])
        if not response.get("ok"):
            raise RuntimeError(response.get("error", response))
        return response

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            if self.process.poll() is None:
                self.command("quit")
                self.command("exit")
                self.process.wait(timeout=15)
        finally:
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()  # EOF asks this driver to normally quit only its own app.
            if self.process.poll() is None:
                self.process.wait(timeout=15)
            self.stderr.close()


class Evidence:
    def __init__(self, root):
        self.root = root
        self.checks = []

    def check(self, name, condition):
        self.checks.append({"name": name, "passed": bool(condition)})
        if not condition:
            raise AssertionError(name)

    def snapshot(self, label, sample, zone_id):
        value = sample["value"]
        zone = ZoneInfo(zone_id)
        expected = datetime.fromtimestamp(value["now"] / 1000, zone)
        self.check(
            label + ": current offset",
            value["offset"] == -int(expected.utcoffset().total_seconds() / 60),
        )
        self.check(
            label + ": real clock",
            sample["hostBefore"] - 100 <= value["now"] <= sample["hostAfter"] + 100,
        )
        actual_zone = ZoneInfo(value["zone"])
        compatible = True
        for historical in value["samples"]:
            instant = historical["timestamp"] / 1000
            date = datetime.fromtimestamp(instant, zone)
            compatible &= historical["offset"] == -int(
                date.utcoffset().total_seconds() / 60
            )
            compatible &= historical["local"] == [
                date.year,
                date.month,
                date.day,
                date.hour,
                date.minute,
                date.second,
            ]
        self.check(label + ": historical conversions", compatible)
        self.check(
            label + ": equivalent IANA zone",
            all(
                datetime.fromtimestamp(
                    item["timestamp"] / 1000, actual_zone
                ).utcoffset()
                == datetime.fromtimestamp(item["timestamp"] / 1000, zone).utcoffset()
                for item in value["samples"]
            ),
        )
        return sample


def open_page(cdp, url):
    target = cdp.call("Target.createTarget", {"url": url})["targetId"]
    session = cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True})[
        "sessionId"
    ]
    wait_for(
        lambda: cdp.value(
            f"location.href==={json.dumps(url)}&&document.readyState==='complete'",
            session,
        ),
        "page ready",
    )
    return session


def chrome_observations(evidence, step, zone, debug_port, base, write_sentinel):
    endpoint = wait_for(
        lambda: fetch_json(f"http://127.0.0.1:{debug_port}/json/version"), "Chrome CDP"
    )["webSocketDebuggerUrl"]
    cdp = CDP(endpoint)
    result = {"version": cdp.call("Browser.getVersion"), "observations": {}}
    try:
        page = open_page(cdp, base + "/page")
        state = cdp.value(
            "({local:localStorage.getItem('tzbox-test'),cookie:document.cookie})", page
        )
        result["persistenceBefore"] = state
        if write_sentinel:
            cdp.value(
                f"localStorage.setItem('tzbox-test',{json.dumps(SENTINEL)});document.cookie='tzbox_test={SENTINEL}; Path=/; Max-Age=3600';true",
                page,
            )
        else:
            evidence.check(
                f"Chrome {step}: localStorage persisted", state["local"] == SENTINEL
            )
            evidence.check(
                f"Chrome {step}: cookie persisted",
                "tzbox_test=" + SENTINEL in state["cookie"],
            )
        contexts = {
            "page": (SNAPSHOT, page),
            "newTab": (SNAPSHOT, open_page(cdp, base + "/new-tab")),
        }
        frame_url = base.replace("127.0.0.1", "localhost") + "/frame"
        contexts["crossOriginIframe"] = (
            f"""new Promise((resolve,reject)=>{{const timer=setTimeout(()=>reject(new Error('iframe timeout')),6000);window.addEventListener('message',function receive(e){{if(e.data?.kind==='tzbox-frame'){{clearTimeout(timer);window.removeEventListener('message',receive);resolve(e.data.value)}}}});const f=document.createElement('iframe');f.src={json.dumps(frame_url)};document.body.appendChild(f)}})""",
            page,
        )
        contexts["dedicatedWorker"] = (
            """new Promise((resolve,reject)=>{const w=new Worker('/worker.js');const t=setTimeout(()=>{w.terminate();reject(new Error('worker timeout'))},6000);w.onmessage=e=>{clearTimeout(t);w.terminate();resolve(e.data)};w.postMessage(null)})""",
            page,
        )
        contexts["sharedWorker"] = (
            """new Promise((resolve,reject)=>{const w=new SharedWorker('/shared.js');const t=setTimeout(()=>{w.port.close();reject(new Error('shared timeout'))},6000);w.port.onmessage=e=>{clearTimeout(t);w.port.close();resolve(e.data)};w.port.start();w.port.postMessage(null)})""",
            page,
        )
        contexts["serviceWorker"] = (
            """(async()=>{const r=await navigator.serviceWorker.register('/sw.js');try{const w=r.active||r.waiting||r.installing;if(w.state!=='activated')await new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(new Error('activation timeout')),6000);w.addEventListener('statechange',()=>{if(w.state==='activated'){clearTimeout(t);resolve()}})});return await new Promise((resolve,reject)=>{const c=new MessageChannel();const t=setTimeout(()=>reject(new Error('service timeout')),6000);c.port1.onmessage=e=>{clearTimeout(t);c.port1.close();resolve(e.data)};w.postMessage(null,[c.port2])})}finally{await r.unregister()}})()""",
            page,
        )
        popup_url = base + "/popup"
        popup_result = cdp.call(
            "Runtime.evaluate",
            {
                "expression": f"window.open({json.dumps(popup_url)})!==null",
                "returnByValue": True,
                "userGesture": True,
            },
            page,
        )
        evidence.check(
            f"Chrome {step}: popup opened", popup_result["result"].get("value") is True
        )
        popup = wait_for(
            lambda: next(
                (
                    item
                    for item in cdp.call("Target.getTargets")["targetInfos"]
                    if item["url"] == popup_url
                ),
                None,
            ),
            "popup target",
        )
        popup_session = cdp.call(
            "Target.attachToTarget", {"targetId": popup["targetId"], "flatten": True}
        )["sessionId"]
        contexts["popup"] = (SNAPSHOT, popup_session)
        for name, (expression, session) in contexts.items():
            result["observations"][name] = evidence.snapshot(
                f"Chrome {step}/{name}", cdp.evaluate(expression, session), zone
            )
    finally:
        result["cdpMethods"] = sorted(set(cdp.methods))
        cdp.close()
        write_json(evidence.root / f"chrome-{step}.json", result)
    return result


def cherry_data(cdp, method, path, body=None):
    request = {
        "id": "tzbox-synthetic-" + str(time.time_ns()),
        "method": method,
        "path": path,
    }
    if body is not None:
        request["body"] = body
    response = cdp.value("window.api.dataApi.request(" + json.dumps(request) + ")")
    if response.get("error"):
        raise RuntimeError(response["error"])
    return response.get("data")


def setup_cherry(cdp, base):
    cherry_data(
        cdp,
        "POST",
        "/providers",
        {
            "providerId": "tzbox-fixture",
            "name": "TZBox Local Fixture",
            "defaultChatEndpoint": "openai-chat-completions",
            "endpointConfigs": {"openai-chat-completions": {"baseUrl": base + "/v1"}},
            "apiKeys": [
                {
                    "id": "tzbox-synthetic-key",
                    "key": "tzbox-synthetic-not-a-real-key",
                    "isEnabled": True,
                }
            ],
        },
    )
    cherry_data(cdp, "PATCH", "/providers/tzbox-fixture", {"isEnabled": True})
    cherry_data(
        cdp,
        "POST",
        "/models",
        [
            {
                "providerId": "tzbox-fixture",
                "modelId": "tzbox-test",
                "name": "TZBox Synthetic Test",
                "capabilities": [],
                "inputModalities": ["text"],
                "outputModalities": ["text"],
                "endpointTypes": ["openai-chat-completions"],
                "supportsStreaming": True,
            }
        ],
    )
    return cherry_data(
        cdp,
        "POST",
        "/assistants",
        {
            "name": "TZBox Synthetic Date Probe",
            "modelId": "tzbox-fixture::tzbox-test",
            "prompt": "TZBox synthetic only. DATE={{date}} | TIME={{time}} | DATETIME={{datetime}} | TIMEZONE={{timezone}}. Fixed acknowledgement only.",
        },
    )["id"]


def cherry_observations(
    evidence,
    step,
    zone,
    inspector_port,
    renderer_port,
    home,
    profile,
    fixture,
    assistant_id,
):
    node_target = wait_for(
        lambda: fetch_json(f"http://127.0.0.1:{inspector_port}/json/list")[0],
        "Cherry main inspector",
    )
    main = CDP(node_target["webSocketDebuggerUrl"])
    main.await_promises = False  # All Node observations here are synchronous.
    renderer = None
    result = {}
    try:
        wait_for(
            lambda: main.value(
                "typeof process!=='undefined'&&!!process.mainModule?.exports?.application&&process.mainModule.require('electron').app.isReady()"
            ),
            "Cherry main initialization",
        )
        paths = main.value(
            "(()=>{const a=process.mainModule.require('electron').app;return {pid:process.pid,version:a.getVersion(),electron:process.versions.electron,home:process.mainModule.require('os').homedir(),userData:a.getPath('userData'),sessionData:a.getPath('sessionData'),logs:a.getPath('logs'),appData:a.getPath('appData'),TZ:process.env.TZ??null}})()"
        )
        result["paths"] = paths
        evidence.check(f"Cherry {step}: isolated HOME", paths["home"] == str(home))
        evidence.check(
            f"Cherry {step}: isolated userData",
            paths["userData"] == str(profile) and paths["sessionData"] == str(profile),
        )
        evidence.check(
            f"Cherry {step}: isolated support/logs",
            all(Path(paths[key]).is_relative_to(home) for key in ("appData", "logs")),
        )
        result["main"] = evidence.snapshot(
            f"Cherry {step}/main", main.evaluate(SNAPSHOT), zone
        )
        result["childDate"] = main.value(
            "process.mainModule.require('child_process').execFileSync('/bin/date',['+%s|%Z|%z'],{encoding:'utf8'}).trim()"
        )
        target = wait_for(
            lambda: next(
                (
                    item
                    for item in fetch_json(
                        f"http://127.0.0.1:{renderer_port}/json/list"
                    )
                    if "/windows/main/" in item.get("url", "")
                ),
                None,
            ),
            "Cherry renderer",
        )
        renderer = CDP(target["webSocketDebuggerUrl"])
        wait_for(
            lambda: renderer.value("typeof window.api?.dataApi?.request==='function'"),
            "Cherry IPC ready",
        )
        result["renderer"] = evidence.snapshot(
            f"Cherry {step}/renderer", renderer.evaluate(SNAPSHOT), zone
        )
        if assistant_id is None:
            assistant_id = setup_cherry(
                renderer, f"http://127.0.0.1:{fixture.server_port}"
            )
        else:
            persisted = cherry_data(renderer, "GET", "/assistants/" + assistant_id)
            evidence.check(
                f"Cherry {step}: assistant persisted", persisted["id"] == assistant_id
            )
        result["assistantID"] = assistant_id
        request = {
            "assistantId": assistant_id,
            "uniqueModelId": "tzbox-fixture::tzbox-test",
            "prompt": f"TZBox synthetic {step} request. No real user content.",
            "requestOptions": {"maxRetries": 0},
        }
        count_before = len(fixture.records)
        generated = renderer.value(
            "window.api.ipcApi.request('ai.text.generate'," + json.dumps(request) + ")"
        )
        evidence.check(
            f"Cherry {step}: real generation completed", generated.get("ok") is True
        )
        evidence.check(
            f"Cherry {step}: actual HTTP request captured",
            len(fixture.records) == count_before + 1,
        )
        captured = fixture.records[-1]
        result["generationResponse"] = generated
        result["capturedRequest"] = captured
        system = next(
            item["content"] for item in captured["messages"] if item["role"] == "system"
        )
        match = re.search(r"DATETIME=(.*?) \| TIMEZONE=", system)
        parsed = datetime.strptime(match[1], "%a, %m/%d/%Y, %I:%M:%S %p").replace(
            tzinfo=ZoneInfo(zone)
        )
        delta = captured["received_at_unix"] - parsed.timestamp()
        result["requestTimeDeltaSeconds"] = delta
        evidence.check(
            f"Cherry {step}: actual request timezone conversion", 0 <= delta < 2
        )
        evidence.check(
            f"Cherry {step}: actual request date/time variables expanded",
            all(
                token not in system
                for token in ("{{date}}", "{{time}}", "{{datetime}}")
            ),
        )
        result["timezonePlaceholderSupported"] = "{{timezone}}" not in system
        result["explicitTimezoneFieldPresent"] = (
            "timezone" in captured or "time_zone" in captured
        )
    finally:
        result["nodeInspectorMethods"] = sorted(set(main.methods))
        main.close()
        if renderer:
            result["rendererCDPMethods"] = sorted(set(renderer.methods))
            renderer.close()
        write_json(evidence.root / f"cherry-{step}.json", result)
    return assistant_id, result["paths"]


def run_app(kind, binary, root, fixture, evidence, manifest, excluded_chrome_pids):
    control = root / (kind + "-control")
    app_root = root / kind
    app_root.mkdir()
    profile = app_root / "profile"
    profile.mkdir()
    debug_port = unused_loopback_port()
    environment = {}
    flags = [
        f"--user-data-dir={profile}",
        "--remote-debugging-address=127.0.0.1",
        f"--remote-debugging-port={debug_port}",
        "--no-first-run",
    ]
    if kind == "chrome":
        app = Path("/Applications/Google Chrome.app")
        flags += [
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-session-crashed-bubble",
            "--use-mock-keychain",
        ]
    else:
        app = Path("/Applications/Cherry Studio.app")
        home = app_root / "home"
        home.mkdir()
        crash = app_root / "crashes"
        crash.mkdir()
        temporary = app_root / "temp"
        temporary.mkdir()
        inspector_port = unused_loopback_port()
        flags += [
            f"--inspect=127.0.0.1:{inspector_port}",
            f"--crash-dumps-dir={crash}",
            f"--log-file={app_root / 'chromium.log'}",
        ]
        environment = {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "TMPDIR": str(temporary) + "/",
        }
    launch_options = {"arguments": flags, "environment": environment}
    existing_pids = excluded_chrome_pids if kind == "chrome" else []
    if existing_pids:
        launch_options["excludedProcessIDs"] = existing_pids
    original_alive = {str(pid): alive(pid) for pid in existing_pids}
    driver = SessionDriver(binary, app, control, launch_options, manifest)
    write_json(root / "manifest.json", manifest)
    assistant_id = None
    previous_pid = None
    result = {
        "kind": kind,
        "steps": [],
        "errors": [],
        "preExistingProcessesAliveBefore": original_alive,
    }
    try:
        for pid in existing_pids:
            evidence.check(
                f"{kind}: excluded pre-existing PID {pid} is running",
                original_alive[str(pid)],
            )
        for step, target in (
            ("new-york", "America/New_York"),
            ("kolkata", "Asia/Kolkata"),
            ("restored-system", None),
        ):
            response = (
                driver.command("apply", timeZoneID=target)
                if target
                else driver.command("restore")
            )
            pid = response.get("processID")
            result["steps"].append({"step": step, "driver": response})
            evidence.check(
                f"{kind} {step}: process running",
                response.get("isRunning") is True and alive(pid),
            )
            evidence.check(
                f"{kind} {step}: managed state",
                response.get("isManaged") is (target is not None),
            )
            if previous_pid:
                evidence.check(
                    f"{kind} {step}: previous own instance closed",
                    not alive(previous_pid) and pid != previous_pid,
                )
            previous_pid = pid
            expected_zone = target or response.get("systemTimeZoneID")
            if not expected_zone:
                raise RuntimeError(
                    "restore response must provide systemTimeZoneID for independent verification"
                )
            if kind == "chrome":
                observed = chrome_observations(
                    evidence,
                    step,
                    expected_zone,
                    debug_port,
                    f"http://127.0.0.1:{fixture.server_port}",
                    target == "America/New_York",
                )
                result["applicationVersion"] = observed["version"]["product"]
                result["verifiedExecutionContexts"] = list(observed["observations"])
            else:
                assistant_id, version_info = cherry_observations(
                    evidence,
                    step,
                    expected_zone,
                    inspector_port,
                    debug_port,
                    home,
                    profile,
                    fixture,
                    assistant_id,
                )
                result["applicationVersion"] = version_info["version"]
                result["electronVersion"] = version_info["electron"]
    except Exception as error:
        LOGGER.exception("Real-app integration failed for %s", kind)
        result["errors"].append(str(error))
    finally:
        try:
            driver.close()
        except Exception as error:
            LOGGER.exception("Normal cleanup failed for %s", kind)
            result["errors"].append("normal cleanup: " + str(error))
        result["ownProcessIDs"] = sorted(driver.pids)
        result["allOwnApplicationsClosed"] = all(not alive(pid) for pid in driver.pids)
        result["driverExited"] = driver.process.poll() is not None
        result["preExistingProcessesAliveAfter"] = {
            str(pid): alive(pid) for pid in existing_pids
        }
        for pid in existing_pids:
            preserved = result["preExistingProcessesAliveAfter"][str(pid)]
            evidence.checks.append(
                {
                    "name": f"{kind}: pre-existing PID {pid} remains running",
                    "passed": preserved,
                }
            )
            if not preserved:
                result["errors"].append(
                    f"Pre-existing PID {pid} was no longer running at test end"
                )
        write_json(root / (kind + "-summary.json"), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--app", choices=("all", "chrome", "cherry"), default="all")
    parser.add_argument(
        "--exclude-existing-chrome-pid",
        type=int,
        action="append",
        default=[],
        help="Developer-only: exclude an explicitly identified personal Chrome PID from discovery; never close it",
    )
    options = parser.parse_args()
    binary = options.driver.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--driver must name an already-built executable")
    root = (
        REPOSITORY
        / "tmp"
        / (datetime.now().astimezone().strftime("%Y%m%d-%H%M%S") + "-native-real-apps")
    )
    root.mkdir(parents=True, exist_ok=False)
    (root / ".codex-tmp").write_text(
        "Created by Tests/integration/native_real_apps.py; synthetic profiles and evidence only.\n"
    )
    source_binary = binary
    driver_copy = root / "driver"
    driver_copy.mkdir()
    binary = driver_copy / source_binary.name
    shutil.copy2(source_binary, binary)
    library = source_binary.parent / "libTZBoxCore.dylib"
    shutil.copy2(library, driver_copy / library.name)
    manifest = {
        "createdBy": "Tests/integration/native_real_apps.py",
        "root": str(root),
        "driver": str(binary),
        "driverSource": str(source_binary),
        "copiedArtifacts": [binary.name, library.name],
        "startedUnix": time.time(),
        "macOSVersion": subprocess.check_output(
            ["/usr/bin/sw_vers", "-productVersion"], text=True
        ).strip(),
        "architecture": platform.machine(),
    }
    write_json(root / "manifest.json", manifest)
    fixture = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    fixture.daemon_threads = True
    fixture.record_lock = threading.Lock()
    fixture.records = []
    fixture.requests_path = root / "fixture-requests.jsonl"
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    evidence = Evidence(root)
    host_before = subprocess.check_output(["/bin/date", "+%Z %z"], text=True).strip()
    results = []
    try:
        for kind in ("chrome", "cherry") if options.app == "all" else (options.app,):
            results.append(
                run_app(
                    kind,
                    binary,
                    root,
                    fixture,
                    evidence,
                    manifest,
                    options.exclude_existing_chrome_pid,
                )
            )
    finally:
        fixture.shutdown()
        fixture.server_close()
    host_after = subprocess.check_output(["/bin/date", "+%Z %z"], text=True).strip()
    evidence.check("host system timezone unchanged", host_before == host_after)
    summary = {
        "root": str(root),
        "macOSVersion": manifest["macOSVersion"],
        "architecture": manifest["architecture"],
        "systemZoneBefore": host_before,
        "systemZoneAfter": host_after,
        "applications": results,
        "checks": evidence.checks,
        "passed": sum(item["passed"] for item in evidence.checks),
        "total": len(evidence.checks),
        "actualModelRequests": len(fixture.records),
        "serverClosed": True,
        "allOwnApplicationsClosed": all(
            item["allOwnApplicationsClosed"] for item in results
        ),
        "success": all(item["passed"] for item in evidence.checks)
        and all(
            not item["errors"]
            and item["driverExited"]
            and item["allOwnApplicationsClosed"]
            for item in results
        ),
        "limitations": [
            "Explicitly opt-in real app integration test using task-owned profiles.",
            "Cherry generation is called through its own installed IPC API; GUI onboarding is not accepted.",
            "No personal profile, account, real model key or external model endpoint is used.",
        ],
    }
    write_json(root / "summary.json", summary)
    print(
        json.dumps(
            {
                key: value
                for key, value in summary.items()
                if key not in ("checks", "applications")
            },
            ensure_ascii=False,
        )
    )
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
