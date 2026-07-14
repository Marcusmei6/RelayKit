#!/usr/bin/env python3
"""Public-safe loopback fixture for the RC1 native Responses proof."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


BIND_HOST = "127.0.0.1"
UPSTREAM_MODEL = "native-upstream"
DEFAULT_MARKER = "RELAYKIT_NATIVE_RESPONSES_OK"
MARKER_PATTERN = re.compile(r"RELAYKIT_[A-Z0-9_]{4,128}")
LOG_FIELDS = ["run_id", "method", "path", "model_rewrite", "auth_present", "event_types"]


def print_contract() -> None:
    print(
        json.dumps(
            {
                "bind": BIND_HOST,
                "paths": ["/v1/models", "/v1/responses"],
                "modes": ["plain", "markdown", "tool", "function_call_output"],
                "supports_nonstream": True,
                "supports_sse": True,
                "log_fields": LOG_FIELDS,
            },
            sort_keys=True,
        )
    )


def atomic_write(path: Path, value: str, mode: int = 0o600) -> None:
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_text(value, encoding="utf-8")
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def message_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(message_text(item) for item in value)
    if isinstance(value, dict):
        return "\n".join(
            message_text(value.get(key))
            for key in ("input", "content", "text", "output")
            if key in value
        )
    return ""


def contains_function_call_output(value: Any) -> bool:
    if isinstance(value, list):
        return any(contains_function_call_output(item) for item in value)
    if isinstance(value, dict):
        if value.get("type") == "function_call_output":
            return True
        return any(contains_function_call_output(item) for item in value.values())
    return False


def response_mode(body: dict[str, Any]) -> str:
    if contains_function_call_output(body.get("input")):
        return "function_call_output"
    metadata = body.get("metadata")
    if isinstance(metadata, dict):
        requested = metadata.get("relaykit_fixture_mode")
        if requested in {"plain", "markdown", "tool", "function_call_output"}:
            return requested
    text = message_text(body.get("input")).lower()
    if "markdown" in text or "native responses" in text and "table" in text:
        return "markdown"
    if "printf" in text or "shell tool" in text:
        return "tool"
    return "plain"


def response_marker(body: dict[str, Any]) -> str:
    match = MARKER_PATTERN.search(message_text(body.get("input")))
    return match.group(0) if match else DEFAULT_MARKER


def text_for_mode(mode: str, marker: str, body: dict[str, Any]) -> str:
    if mode == "markdown":
        return (
            "## RelayKit Rich Text Check\n\n"
            "1. First route check\n"
            "2. Second route check\n\n"
            "| status | route |\n"
            "| --- | --- |\n"
            "| ready | official |\n"
            "| ready | provider |\n\n"
            "```bash\n"
            "echo relaykit\n"
            "```\n\n"
            "**RELAYKIT_FORMAT_OK**\n\n"
            f"{marker}"
        )
    if mode == "function_call_output":
        output_text = message_text(body.get("input"))
        output_marker = MARKER_PATTERN.search(output_text)
        marker = output_marker.group(0) if output_marker else marker
        pwd_line = next((line for line in output_text.splitlines() if line.startswith("/")), "/tmp/relaykit-fixture")
        return f"{marker}\n{pwd_line}"
    return marker


def message_item(text: str) -> dict[str, Any]:
    return {
        "id": "msg_fixture",
        "type": "message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text}],
    }


def function_item(marker: str) -> dict[str, Any]:
    command = f"printf '{marker}\\n'; pwd"
    return {
        "id": "fc_fixture",
        "type": "function_call",
        "call_id": "call_fixture",
        "name": "exec_command",
        "arguments": json.dumps({"cmd": command}, separators=(",", ":")),
        "status": "completed",
    }


def response_object(mode: str, marker: str, body: dict[str, Any]) -> dict[str, Any]:
    output = [function_item(marker)] if mode == "tool" else [message_item(text_for_mode(mode, marker, body))]
    return {
        "id": "resp_fixture",
        "object": "response",
        "status": "completed",
        "model": UPSTREAM_MODEL,
        "output": output,
        "usage": {"input_tokens": 2, "output_tokens": 2, "total_tokens": 4},
    }


def streaming_events(mode: str, marker: str, body: dict[str, Any]) -> list[dict[str, Any]]:
    response = response_object(mode, marker, body)
    created = {key: response[key] for key in ("id", "object", "status", "model")}
    events: list[dict[str, Any]] = [{"type": "response.created", "response": created}]
    item = response["output"][0]
    events.append({"type": "response.output_item.added", "output_index": 0, "item": item})
    if item["type"] == "message":
        text = item["content"][0]["text"]
        events.extend(
            [
                {
                    "type": "response.content_part.added",
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": ""},
                },
                {
                    "type": "response.output_text.delta",
                    "output_index": 0,
                    "content_index": 0,
                    "delta": text,
                },
                {
                    "type": "response.output_text.done",
                    "output_index": 0,
                    "content_index": 0,
                    "text": text,
                },
                {
                    "type": "response.content_part.done",
                    "output_index": 0,
                    "content_index": 0,
                    "part": item["content"][0],
                },
            ]
        )
    events.append({"type": "response.output_item.done", "output_index": 0, "item": item})
    events.append({"type": "response.completed", "response": response})
    return events


class FixtureState:
    def __init__(self, run_id: str, events_path: Path, synthetic_key: str) -> None:
        self.run_id = run_id
        self.events_path = events_path
        self.synthetic_key = synthetic_key
        self.lock = threading.Lock()

    def append_event(
        self,
        method: str,
        path: str,
        model_rewrite: bool,
        auth_present: bool,
        event_types: list[str],
    ) -> None:
        event = {
            "run_id": self.run_id,
            "method": method,
            "path": path,
            "model_rewrite": model_rewrite,
            "auth_present": auth_present,
            "event_types": event_types,
        }
        with self.lock:
            with self.events_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n")


def handler_type(state: FixtureState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_args: object) -> None:
            return

        def send_json(self, status: int, value: dict[str, Any]) -> None:
            payload = json.dumps(value, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:  # noqa: N802
            if self.path != "/v1/models":
                self.send_error(404)
                return
            state.append_event("GET", self.path, False, bool(self.headers.get("Authorization")), ["models.list"])
            self.send_json(
                200,
                {"object": "list", "data": [{"id": UPSTREAM_MODEL, "object": "model", "owned_by": "fixture"}]},
            )

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/v1/responses":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self.send_json(400, {"error": {"type": "invalid_request_error"}})
                return
            authorization = self.headers.get("Authorization", "")
            auth_present = authorization in {state.synthetic_key, f"Bearer {state.synthetic_key}"}
            if not auth_present:
                state.append_event("POST", self.path, False, False, ["response.failed"])
                self.send_json(401, {"error": {"type": "auth_failed"}})
                return
            mode = response_mode(body)
            marker = response_marker(body)
            events = streaming_events(mode, marker, body)
            state.append_event(
                "POST",
                self.path,
                body.get("model") == UPSTREAM_MODEL,
                True,
                [event["type"] for event in events],
            )
            if body.get("stream") is True:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                for event in events:
                    encoded = json.dumps(event, separators=(",", ":"))
                    self.wfile.write(f"event: {event['type']}\ndata: {encoded}\n\n".encode())
                    self.wfile.flush()
                return
            self.send_json(200, response_object(mode, marker, body))

    return Handler


def serve(args: argparse.Namespace) -> None:
    port_file = Path(args.port_file)
    events_path = Path(args.events)
    if not port_file.is_absolute() or not events_path.is_absolute():
        raise SystemExit("fixture paths must be absolute")
    port_file.parent.mkdir(parents=True, exist_ok=True)
    events_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(events_path, "")
    state = FixtureState(args.run_id, events_path, args.synthetic_key)
    server = ThreadingHTTPServer((BIND_HOST, 0), handler_type(state))
    atomic_write(port_file, f"{server.server_address[1]}\n")

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever()
    server.server_close()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(add_help=True)
    result.add_argument("--print-contract", action="store_true")
    subparsers = result.add_subparsers(dest="command")
    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--port-file", required=True)
    serve_parser.add_argument("--events", required=True)
    serve_parser.add_argument("--run-id", required=True)
    serve_parser.add_argument("--synthetic-key", required=True)
    return result


def main() -> None:
    args = parser().parse_args()
    if args.print_contract:
        print_contract()
        return
    if args.command == "serve":
        serve(args)
        return
    raise SystemExit(2)


if __name__ == "__main__":
    main()
