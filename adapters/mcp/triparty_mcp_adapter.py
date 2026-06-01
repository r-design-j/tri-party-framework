#!/usr/bin/env python3
"""Minimal stdio MCP adapter for the tri-party portable core."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import time
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[2]
TRIPARTY = ROOT_DIR / "scripts" / "triparty.sh"
VERSION_FILE = ROOT_DIR / "VERSION"


def version() -> str:
    if VERSION_FILE.exists():
        return VERSION_FILE.read_text(encoding="utf-8").strip()
    return "0.0.0-dev"


def run_triparty(args: list[str], timeout: int = 3600) -> dict[str, Any]:
    started = time.time()
    try:
        completed = subprocess.run(
            [str(TRIPARTY), *args],
            cwd=str(ROOT_DIR),
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return {
            "ok": completed.returncode == 0,
            "exit_code": completed.returncode,
            "duration_ms": int((time.time() - started) * 1000),
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "exit_code": 124,
            "duration_ms": int((time.time() - started) * 1000),
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or f"command timed out after {timeout}s",
        }


def tool_schema() -> list[dict[str, Any]]:
    string = {"type": "string"}
    integer = {"type": "integer", "minimum": 1}
    boolean = {"type": "boolean"}
    return [
        {
            "name": "triparty_status",
            "description": "Refresh and return tri-party run status.",
            "inputSchema": {"type": "object", "properties": {"run_dir": string}},
        },
        {
            "name": "triparty_run",
            "description": "Run review, cross-audit, merge, and state generation.",
            "inputSchema": {
                "type": "object",
                "required": ["question"],
                "properties": {
                    "question": string,
                    "context_files": {"type": "array", "items": string},
                    "timeout_seconds": integer,
                },
            },
        },
        {
            "name": "triparty_review",
            "description": "Run only the review stage.",
            "inputSchema": {
                "type": "object",
                "required": ["question"],
                "properties": {"question": string, "context_files": {"type": "array", "items": string}},
            },
        },
        {
            "name": "triparty_cross_audit",
            "description": "Run the cross-audit stage for a run.",
            "inputSchema": {"type": "object", "properties": {"run_dir": string}},
        },
        {
            "name": "triparty_merge",
            "description": "Run the merge gate for a run.",
            "inputSchema": {"type": "object", "properties": {"run_dir": string}},
        },
        {
            "name": "triparty_inject",
            "description": "Inject a user-supplied review or cross-audit artifact.",
            "inputSchema": {
                "type": "object",
                "required": ["party", "run_dir", "artifact_file"],
                "properties": {
                    "stage": {"type": "string", "enum": ["review", "cross-audit"]},
                    "party": {"type": "string", "enum": ["claude", "gemini"]},
                    "run_dir": string,
                    "artifact_file": string,
                },
            },
        },
        {
            "name": "triparty_resume",
            "description": "Resume a partial run from the latest safe stage.",
            "inputSchema": {"type": "object", "properties": {"run_dir": string}},
        },
        {
            "name": "triparty_runs",
            "description": "List recent runs.",
            "inputSchema": {"type": "object", "properties": {"limit": integer}},
        },
        {
            "name": "triparty_stats",
            "description": "Return aggregate run statistics.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "triparty_archive",
            "description": "Archive older runs.",
            "inputSchema": {
                "type": "object",
                "properties": {"keep": integer, "dry_run": boolean},
            },
        },
        {
            "name": "triparty_lint",
            "description": "Run framework lint.",
            "inputSchema": {"type": "object", "properties": {}},
        },
        {
            "name": "triparty_regression",
            "description": "Run regression checks.",
            "inputSchema": {"type": "object", "properties": {}},
        },
    ]


def call_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    timeout = int(arguments.get("timeout_seconds", 3600))
    if name == "triparty_status":
        args = ["status"]
        if arguments.get("run_dir"):
            args.append(str(arguments["run_dir"]))
        return run_triparty(args, timeout=120)
    if name == "triparty_run":
        args = ["run", str(arguments["question"]), *arguments.get("context_files", [])]
        return run_triparty(args, timeout=timeout)
    if name == "triparty_review":
        args = ["review", str(arguments["question"]), *arguments.get("context_files", [])]
        return run_triparty(args, timeout=timeout)
    if name == "triparty_cross_audit":
        args = ["cross-audit"]
        if arguments.get("run_dir"):
            args.append(str(arguments["run_dir"]))
        return run_triparty(args, timeout=timeout)
    if name == "triparty_merge":
        args = ["merge"]
        if arguments.get("run_dir"):
            args.append(str(arguments["run_dir"]))
        return run_triparty(args, timeout=timeout)
    if name == "triparty_inject":
        stage = str(arguments.get("stage", "review"))
        args = [
            "inject",
            stage,
            str(arguments["party"]),
            str(arguments["run_dir"]),
            str(arguments["artifact_file"]),
        ]
        return run_triparty(args, timeout=300)
    if name == "triparty_resume":
        args = ["resume"]
        if arguments.get("run_dir"):
            args.append(str(arguments["run_dir"]))
        return run_triparty(args, timeout=timeout)
    if name == "triparty_runs":
        return run_triparty(["runs", str(arguments.get("limit", 20))], timeout=120)
    if name == "triparty_stats":
        return run_triparty(["stats"], timeout=120)
    if name == "triparty_archive":
        args = ["archive"]
        if arguments.get("keep"):
            args.extend(["--keep", str(arguments["keep"])])
        if arguments.get("dry_run", True):
            args.append("--dry-run")
        return run_triparty(args, timeout=300)
    if name == "triparty_lint":
        return run_triparty(["lint"], timeout=300)
    if name == "triparty_regression":
        return run_triparty(["regression"], timeout=300)
    return {"ok": False, "exit_code": 2, "stdout": "", "stderr": f"unknown tool: {name}"}


def read_message() -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.rstrip(b"\r\n")
        if not line:
            break
        key, _, value = line.decode("utf-8").partition(":")
        headers[key.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))


def send_message(payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def response(request: dict[str, Any], result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}


def error_response(request: dict[str, Any], code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": code, "message": message}}


def handle(request: dict[str, Any]) -> dict[str, Any] | None:
    method = request.get("method")
    if method == "notifications/initialized":
        return None
    if method == "initialize":
        return response(
            request,
            {
                "protocolVersion": "2024-11-05",
                "serverInfo": {"name": "triparty-mcp", "version": version()},
                "capabilities": {"tools": {}},
            },
        )
    if method == "tools/list":
        return response(request, {"tools": tool_schema()})
    if method == "tools/call":
        params = request.get("params", {})
        name = params.get("name")
        arguments = params.get("arguments", {})
        result = call_tool(name, arguments)
        return response(
            request,
            {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(result, ensure_ascii=False, indent=2),
                    }
                ],
                "isError": not result.get("ok", False),
            },
        )
    if method == "ping":
        return response(request, {})
    return error_response(request, -32601, f"method not found: {method}")


def main() -> int:
    while True:
        request = read_message()
        if request is None:
            break
        try:
            result = handle(request)
        except Exception as exc:  # noqa: BLE001 - MCP errors must be surfaced as JSON-RPC errors
            result = error_response(request, -32000, str(exc))
        if result is not None:
            send_message(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
