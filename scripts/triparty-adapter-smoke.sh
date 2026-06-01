#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT_DIR/adapters/http/triparty_http_adapter.py"
FAILED=0

PORT="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"

OUT_FILE="${TMPDIR:-/tmp}/triparty-http-adapter-$PORT.log"
python3 "$ADAPTER" --host 127.0.0.1 --port "$PORT" --quiet > "$OUT_FILE" 2>&1 &
PID=$!

cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  python3 - "$method" "http://127.0.0.1:$PORT$path" "$body" <<'PY'
import json
import sys
import urllib.request

method, url, body = sys.argv[1:4]
data = body.encode("utf-8") if body else None
headers = {"Content-Type": "application/json"}
request = urllib.request.Request(url, data=data, headers=headers, method=method)
with urllib.request.urlopen(request, timeout=30) as response:
    payload = response.read().decode("utf-8")
    parsed = json.loads(payload)
    print(json.dumps(parsed, ensure_ascii=False))
PY
}

expect_json_field() {
  local label="$1"
  local json_text="$2"
  local expr="$3"
  if python3 - "$json_text" "$expr" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expr = sys.argv[2]
value = payload
for part in expr.split("."):
    value = value[part]
if value:
    sys.exit(0)
sys.exit(1)
PY
  then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n%s\n' "$label" "$json_text" >&2
    FAILED=1
  fi
}

HEALTH="$(request GET /health)"
expect_json_field "http_adapter_health" "$HEALTH" "ok"

RUNS="$(request GET /runs)"
expect_json_field "http_adapter_runs" "$RUNS" "ok"

STATS="$(request GET /stats)"
expect_json_field "http_adapter_stats" "$STATS" "ok"

STATUS="$(request GET /status)"
expect_json_field "http_adapter_status" "$STATUS" "ok"
expect_json_field "http_adapter_status_state" "$STATUS" "state.schema_version"
expect_json_field "http_adapter_state_validation" "$STATUS" "state_validation.ok"

LINT="$(request POST /lint '{}')"
expect_json_field "http_adapter_lint" "$LINT" "ok"

if python3 "$ADAPTER" --host 0.0.0.0 --port "$PORT" --quiet > /dev/null 2>&1; then
  printf 'FAIL: http_adapter_rejects_non_loopback_without_auth\n' >&2
  FAILED=1
else
  printf 'PASS: http_adapter_rejects_non_loopback_without_auth\n'
fi

if [ "$FAILED" -eq 0 ]; then
  printf 'triparty adapter smoke passed\n'
  exit 0
fi

printf 'triparty adapter smoke failed\n' >&2
sed -n '1,120p' "$OUT_FILE" >&2 || true
exit 1
