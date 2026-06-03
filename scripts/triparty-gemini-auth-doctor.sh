#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${1:-}"
AUTH_TIMEOUT="${TRIPARTY_GEMINI_AUTH_TIMEOUT:-12}"
GEMINI_MODEL="${TRIPARTY_GEMINI_MODEL:-gemini-3.1-pro-preview}"
GEMINI_MCP_ALLOWED="${TRIPARTY_GEMINI_MCP_ALLOWED:-__none__}"
GEMINI_APPROVAL_MODE="${TRIPARTY_GEMINI_APPROVAL_MODE:-plan}"
GEMINI_POLICY_FILE="${TRIPARTY_GEMINI_POLICY_FILE:-"$ROOT_DIR/docs/framework/gemini-headless-policy.toml"}"
GEMINI_TERM="${TRIPARTY_GEMINI_TERM:-xterm-256color}"

if [ -z "$OUT_FILE" ]; then
  OUT_FILE="${TMPDIR:-/tmp}/triparty-gemini-auth-doctor-$$.txt"
fi

run_with_timeout() {
  local timeout_seconds="$1"
  local outfile="$2"
  shift 2

  : > "$outfile"
  "$@" > "$outfile" 2>&1 &
  local pid=$!
  local elapsed=0

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid"
}

classify_output() {
  local file="$1"
  if grep -Eiq 'GEMINI_AUTH_OK|RESOURCE_EXHAUSTED|MODEL_CAPACITY_EXHAUSTED|No capacity available|429|rateLimitExceeded|quota' "$file"; then
    printf 'authenticated'
    return
  fi
  if grep -Eiq 'login|log in|oauth|auth|authenticate|browser|sign in|signin|credential|token|not authenticated|Please.*authenticate|Run.*auth' "$file"; then
    printf 'interactive-auth-required'
    return
  fi
  printf 'interactive-auth-required'
}

path="$(command -v gemini 2>/dev/null || true)"
if [ -z "$path" ]; then
  : > "$OUT_FILE"
  printf 'status=binary-missing\n'
  printf 'path=not found\n'
  printf 'output=%s\n' "$OUT_FILE"
  exit 2
fi

run_with_timeout "$AUTH_TIMEOUT" "$OUT_FILE" \
  env TERM="$GEMINI_TERM" gemini -m "$GEMINI_MODEL" -p "Return exactly: GEMINI_AUTH_OK" --output-format text --skip-trust --approval-mode "$GEMINI_APPROVAL_MODE" --allowed-mcp-server-names "$GEMINI_MCP_ALLOWED" --policy "$GEMINI_POLICY_FILE"
code=$?

if [ "$code" -eq 124 ]; then
  status="timeout"
elif [ "$code" -eq 0 ] && grep -q "GEMINI_AUTH_OK" "$OUT_FILE"; then
  status="authenticated"
else
  status="$(classify_output "$OUT_FILE")"
fi

printf 'status=%s\n' "$status"
printf 'path=%s\n' "$path"
printf 'output=%s\n' "$OUT_FILE"

case "$status" in
  authenticated)
    exit 0
    ;;
  binary-missing)
    exit 2
    ;;
  timeout)
    exit 124
    ;;
  *)
    exit 1
    ;;
esac
