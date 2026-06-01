#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT_DIR/adapters/mcp/triparty_mcp_adapter.py"

python3 - "$ADAPTER" <<'PY'
import json
import subprocess
import sys

adapter = sys.argv[1]
proc = subprocess.Popen(
    [sys.executable, adapter],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)


def send(payload):
    data = json.dumps(payload).encode("utf-8")
    proc.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii") + data)
    proc.stdin.flush()


def read():
    headers = {}
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("adapter closed stdout")
        line = line.rstrip(b"\r\n")
        if not line:
            break
        key, value = line.decode("utf-8").split(":", 1)
        headers[key.lower()] = value.strip()
    body = proc.stdout.read(int(headers["content-length"]))
    return json.loads(body.decode("utf-8"))


def expect(condition, label, payload=None):
    if condition:
        print(f"PASS: {label}")
    else:
        print(f"FAIL: {label}", file=sys.stderr)
        if payload is not None:
            print(json.dumps(payload, ensure_ascii=False, indent=2), file=sys.stderr)
        proc.kill()
        sys.exit(1)


send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
initialize = read()
expect("result" in initialize, "mcp_initialize", initialize)

send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
tools = read()
names = [tool["name"] for tool in tools["result"]["tools"]]
expect("triparty_status" in names, "mcp_tools_list_status", tools)
expect("triparty_inject" in names, "mcp_tools_list_inject", tools)
expect("triparty_resume" in names, "mcp_tools_list_resume", tools)
expect("triparty_archive" in names, "mcp_tools_list_archive", tools)

send(
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "triparty_status", "arguments": {}},
    }
)
status = read()
expect(status["result"]["isError"] is False, "mcp_status_call", status)

proc.stdin.close()
proc.terminate()
try:
    proc.wait(timeout=3)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()

print("triparty mcp smoke passed")
PY
