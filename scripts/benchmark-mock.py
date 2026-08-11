#!/usr/bin/env python3
"""Deterministic OpenAI-compatible HTTP mock for vision race benchmarks."""

import argparse
import json
import math
import os
import re
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


DEFAULT_DELAYS_MS = {
    "glm-4v-flash": 100.0,
    "agnes-2.5-flash": 250.0,
    "agnes-2.0-flash": 400.0,
    "glm-4.1v-thinking-flash": 550.0,
}
RUN_ID_PATTERN = re.compile(r"BENCH_RUN_ID\s*[:=]\s*([A-Za-z0-9._-]{1,128})")
EXPECTED_AUTHORIZATION = "Bearer benchmark-dummy-key"


def _json_bytes(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("utf-8")


def _valid_delay(value, label):
    try:
        delay = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid delay for %s: %r" % (label, value)) from exc
    if not math.isfinite(delay) or delay < 0 or delay > 300000:
        raise ValueError("delay for %s must be between 0 and 300000 ms" % label)
    return delay


def _load_delay_json(raw):
    if not raw:
        return {}
    source = raw
    if raw.startswith("@"):
        source = Path(raw[1:]).read_text(encoding="utf-8")
    elif Path(raw).is_file():
        source = Path(raw).read_text(encoding="utf-8")
    value = json.loads(source)
    if not isinstance(value, dict):
        raise ValueError("--delays-json must contain a JSON object")
    return {str(model): _valid_delay(delay, str(model)) for model, delay in value.items()}


def _parse_delay_option(raw):
    if "=" not in raw:
        raise ValueError("--delay must use MODEL=MILLISECONDS")
    model, value = raw.split("=", 1)
    model = model.strip()
    if not model:
        raise ValueError("--delay model cannot be empty")
    return model, _valid_delay(value.strip(), model)


def _extract_run_id(payload):
    messages = payload.get("messages") if isinstance(payload, dict) else None
    if not isinstance(messages, list):
        return "unknown"
    for message in messages:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        texts = []
        if isinstance(content, str):
            texts.append(content)
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    texts.append(part["text"])
        for prompt_text in texts:
            match = RUN_ID_PATTERN.search(prompt_text)
            if match:
                return match.group(1)
    return "unknown"


class BenchmarkState:
    def __init__(self, delays_ms, unknown_delay_ms):
        self.delays_ms = dict(delays_ms)
        self.unknown_delay_ms = unknown_delay_ms
        self._events = []
        self._lock = threading.Lock()

    def add_event(self, event):
        with self._lock:
            self._events.append(event)

    def update_event(self, request_id, **changes):
        with self._lock:
            for event in self._events:
                if event["request_id"] == request_id:
                    event.update(changes)
                    return

    def stats(self, run_id):
        with self._lock:
            events = [dict(event) for event in self._events if event["run_id"] == run_id]
        events.sort(key=lambda event: (event["accepted_ns"], event["request_id"]))
        accepted = [event["accepted_ns"] for event in events]
        ready = [event for event in events if event.get("response_ready_ns") is not None]
        first_accepted = min(accepted) if accepted else None
        first_ready = min(ready, key=lambda event: event["response_ready_ns"]) if ready else None
        fanout_spread_ms = None
        if accepted:
            fanout_spread_ms = (max(accepted) - min(accepted)) / 1000000.0
        race_latency_ms = None
        if first_accepted is not None and first_ready is not None:
            race_latency_ms = (first_ready["response_ready_ns"] - first_accepted) / 1000000.0
        return {
            "run_id": run_id,
            "request_count": len(events),
            "unique_models": sorted({event["model"] for event in events}),
            "fanout_spread_ms": fanout_spread_ms,
            "race_latency_ms": race_latency_ms,
            "first_ready_model": first_ready["model"] if first_ready else None,
            "events": events,
        }


class BenchmarkServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler_class, state, max_body_bytes):
        super().__init__(server_address, handler_class)
        self.state = state
        self.max_body_bytes = max_body_bytes


class BenchmarkHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ds-vision-benchmark-mock/1"

    def log_message(self, _format, *args):
        return

    def _send_json(self, status, payload):
        body = _json_bytes(payload)
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            return False

    def _read_json_body(self):
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("missing Content-Length")
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length < 0 or length > self.server.max_body_bytes:
            raise ValueError("request body size is outside the allowed range")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("incomplete request body")
        value = json.loads(body.decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("request JSON must be an object")
        return value

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send_json(
                200,
                {
                    "status": "ok",
                    "delays_ms": self.server.state.delays_ms,
                    "unknown_delay_ms": self.server.state.unknown_delay_ms,
                },
            )
            return
        if parsed.path == "/stats":
            run_values = parse_qs(parsed.query, keep_blank_values=True).get("run_id")
            if not run_values or not run_values[0]:
                self._send_json(400, {"error": "run_id query parameter is required"})
                return
            self._send_json(200, self.server.state.stats(run_values[0]))
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        accepted_ns = time.perf_counter_ns()
        parsed_path = urlparse(self.path).path
        if parsed_path == "/shutdown":
            self._send_json(200, {"status": "shutting_down"})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not parsed_path.endswith("/chat/completions"):
            self._send_json(404, {"error": "not found"})
            return

        try:
            payload = self._read_json_body()
            body_parsed_ns = time.perf_counter_ns()
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                raise ValueError("model must be a non-empty string")
            run_id = _extract_run_id(payload)
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._send_json(400, {"error": str(exc)})
            return

        delay_ms = self.server.state.delays_ms.get(model, self.server.state.unknown_delay_ms)
        request_id = uuid.uuid4().hex
        event = {
            "request_id": request_id,
            "run_id": run_id,
            "model": model,
            "client_is_loopback": self.client_address[0] == "127.0.0.1",
            "authorization_ok": self.headers.get("Authorization") == EXPECTED_AUTHORIZATION,
            "accepted_ns": accepted_ns,
            "body_parsed_ns": body_parsed_ns,
            "delay_ms": delay_ms,
            "response_ready_ns": None,
            "response_sent_ns": None,
            "write_ok": None,
        }
        self.server.state.add_event(event)

        time.sleep(delay_ms / 1000.0)
        response = {
            "id": "bench-" + request_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "BENCH_OK:%s:%s" % (model, run_id),
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        response_ready_ns = time.perf_counter_ns()
        self.server.state.update_event(request_id, response_ready_ns=response_ready_ns)
        write_ok = self._send_json(200, response)
        self.server.state.update_event(
            request_id,
            response_sent_ns=time.perf_counter_ns(),
            write_ok=write_ok,
        )


def _write_ready_file(path, server, state):
    ready_path = Path(path).resolve()
    ready_path.parent.mkdir(parents=True, exist_ok=True)
    value = {
        "host": server.server_address[0],
        "port": server.server_address[1],
        "pid": os.getpid(),
        "delays_ms": state.delays_ms,
        "unknown_delay_ms": state.unknown_delay_ms,
    }
    temporary_path = ready_path.with_name(ready_path.name + ".tmp-%d" % os.getpid())
    temporary_path.write_text(json.dumps(value, ensure_ascii=True, separators=(",", ":")), encoding="ascii")
    os.replace(str(temporary_path), str(ready_path))
    return ready_path


def _build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="listen port; 0 selects a free port")
    parser.add_argument("--ready-file", required=True, help="atomic JSON readiness file")
    parser.add_argument(
        "--delays-json",
        default="",
        help="JSON object, JSON file path, or @JSON_FILE overriding default model delays",
    )
    parser.add_argument(
        "--delay",
        action="append",
        default=[],
        metavar="MODEL=MILLISECONDS",
        help="override one model delay; may be repeated and is applied last",
    )
    parser.add_argument("--unknown-delay-ms", type=float, default=1000.0)
    parser.add_argument("--max-body-bytes", type=int, default=32 * 1024 * 1024)
    return parser


def main(argv=None):
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        if args.port < 0 or args.port > 65535:
            raise ValueError("--port must be between 0 and 65535")
        if args.max_body_bytes < 1:
            raise ValueError("--max-body-bytes must be positive")
        delays_ms = dict(DEFAULT_DELAYS_MS)
        delays_ms.update(_load_delay_json(args.delays_json))
        for raw_delay in args.delay:
            model, delay = _parse_delay_option(raw_delay)
            delays_ms[model] = delay
        unknown_delay_ms = _valid_delay(args.unknown_delay_ms, "unknown model")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))

    state = BenchmarkState(delays_ms, unknown_delay_ms)
    server = BenchmarkServer((args.host, args.port), BenchmarkHandler, state, args.max_body_bytes)
    ready_path = None

    def request_shutdown(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, request_shutdown)
    if hasattr(signal, "SIGINT"):
        signal.signal(signal.SIGINT, request_shutdown)

    try:
        ready_path = _write_ready_file(args.ready_file, server, state)
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        if ready_path is not None:
            try:
                current = json.loads(ready_path.read_text(encoding="ascii"))
                if current.get("pid") == os.getpid():
                    ready_path.unlink()
            except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
