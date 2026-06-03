#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/triparty-runs-dir.sh
. "$ROOT_DIR/scripts/triparty-runs-dir.sh"
RUNS_DIR="$(triparty_resolve_runs_dir "$ROOT_DIR")" || exit $?
STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT_DIR="${1:-"$RUNS_DIR/preflight-$STAMP"}"
PROBE_TIMEOUT="${TRIPARTY_PROBE_TIMEOUT:-40}"
PROBE_RETRIES="${TRIPARTY_PROBE_RETRIES:-2}"
PROBE_RETRY_BACKOFF="${TRIPARTY_PROBE_RETRY_BACKOFF:-10}"
GEMINI_AUTH_TIMEOUT="${TRIPARTY_GEMINI_AUTH_TIMEOUT:-12}"
GEMINI_MODEL="${TRIPARTY_GEMINI_MODEL:-gemini-3.1-pro-preview}"
GEMINI_MCP_ALLOWED="${TRIPARTY_GEMINI_MCP_ALLOWED:-__none__}"
GEMINI_APPROVAL_MODE="${TRIPARTY_GEMINI_APPROVAL_MODE:-plan}"
GEMINI_POLICY_FILE="${TRIPARTY_GEMINI_POLICY_FILE:-"$ROOT_DIR/docs/framework/gemini-headless-policy.toml"}"
GEMINI_TERM="${TRIPARTY_GEMINI_TERM:-xterm-256color}"
VERSION_TIMEOUT="${TRIPARTY_VERSION_TIMEOUT:-8}"
MODEL_BINDING_FILE="$ROOT_DIR/docs/framework/model-binding.yaml"

mkdir -p "$OUT_DIR"

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

hash_file() {
  local file="$1"
  if [ -f "$file" ]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

diagnostic_count() {
  local file="$1"
  local pattern="$2"
  if [ -f "$file" ]; then
    grep -Eci "$pattern" "$file" 2>/dev/null || true
  else
    printf '0'
  fi
}

capacity_event_count() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf '0'
    return
  fi

  if grep -Eq '^Attempt [0-9]+ failed with status 429' "$file"; then
    grep -Ec '^Attempt [0-9]+ failed with status 429' "$file" 2>/dev/null || true
    return
  fi

  diagnostic_count "$file" '429|RESOURCE_EXHAUSTED|MODEL_CAPACITY_EXHAUSTED|rateLimitExceeded|No capacity available'
}

command_version() {
  local outfile="$1"
  shift

  run_with_timeout "$VERSION_TIMEOUT" "$outfile" "$@"
  if [ "$?" -eq 0 ]; then
    tr '\n' ' ' < "$outfile" | sed 's/[[:space:]]*$//'
  else
    printf 'unavailable'
  fi
}

probe_cli() {
  local name="$1"
  local command_name="$2"
  local expected="$3"
  local outfile="$4"
  shift 4

  local path
  path="$(command -v "$command_name" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    printf '%s|Unavailable|not found||missing|0|E_CLI_MISSING\n' "$name"
    return 0
  fi

  local bin_sha
  bin_sha="$(hash_file "$path")"

  local attempt=0
  local code=1
  local attempt_file
  while [ "$attempt" -le "$PROBE_RETRIES" ]; do
    attempt_file="${outfile}.attempt-$attempt"
    run_with_timeout "$PROBE_TIMEOUT" "$attempt_file" "$@"
    code=$?
    cp "$attempt_file" "$outfile"

    if [ "$code" -ne 124 ] && grep -q "$expected" "$outfile"; then
      printf '%s|Available|%s|%s|%s|%s|E_OK\n' "$name" "$path" "$outfile" "$bin_sha" "$attempt"
      return 0
    fi

    if [ "$attempt" -lt "$PROBE_RETRIES" ]; then
      sleep $((PROBE_RETRY_BACKOFF * (attempt + 1)))
    fi
    attempt=$((attempt + 1))
  done

  if [ "$code" -eq 124 ]; then
    printf '%s|TimedOut|%s|%s|%s|%s|E_PROBE_TIMEOUT\n' "$name" "$path" "$outfile" "$bin_sha" "$PROBE_RETRIES"
    return 0
  fi

  printf '%s|Failed|%s|%s|%s|%s|E_PROBE_FAILED\n' "$name" "$path" "$outfile" "$bin_sha" "$PROBE_RETRIES"
}

CLAUDE_OUT="$OUT_DIR/claude-probe.txt"
GEMINI_OUT="$OUT_DIR/gemini-probe.txt"

CLAUDE_RESULT="$(probe_cli "Claude" "claude" "CLAUDE_OK" "$CLAUDE_OUT" \
  claude -p "Return exactly: CLAUDE_OK" --output-format text --tools "" --no-session-persistence --bare)"

parse_field() {
  printf '%s' "$1" | awk -F '|' -v idx="$2" '{print $idx}'
}

parse_doctor_field() {
  printf '%s\n' "$1" | awk -F '=' -v key="$2" '$1 == key { print substr($0, length(key) + 2); exit }'
}

gemini_result_from_auth_doctor() {
  local status="$1"
  local path="$2"
  local output="$3"
  local bin_sha="missing"

  if [ -n "$path" ] && [ "$path" != "not found" ] && [ -f "$path" ]; then
    bin_sha="$(hash_file "$path")"
  fi

  case "$status" in
    binary-missing)
      printf 'Gemini|Unavailable|not found|%s|missing|0|E_GEMINI_BINARY_MISSING\n' "$output"
      ;;
    timeout)
      printf 'Gemini|TimedOut|%s|%s|%s|0|E_GEMINI_AUTH_TIMEOUT\n' "$path" "$output" "$bin_sha"
      ;;
    interactive-auth-required)
      printf 'Gemini|Unavailable|%s|%s|%s|0|E_GEMINI_INTERACTIVE_AUTH_REQUIRED\n' "$path" "$output" "$bin_sha"
      ;;
    *)
      printf 'Gemini|Failed|%s|%s|%s|0|E_GEMINI_AUTH_FAILED\n' "$path" "$output" "$bin_sha"
      ;;
  esac
}

CLAUDE_STATUS="$(parse_field "$CLAUDE_RESULT" 2)"
CLAUDE_PATH="$(parse_field "$CLAUDE_RESULT" 3)"
CLAUDE_BIN_SHA256="$(parse_field "$CLAUDE_RESULT" 5)"
CLAUDE_ATTEMPT="$(parse_field "$CLAUDE_RESULT" 6)"
CLAUDE_ERROR_CODE="$(parse_field "$CLAUDE_RESULT" 7)"

GEMINI_AUTH_OUT="$OUT_DIR/gemini-auth-doctor.txt"
GEMINI_AUTH_DOCTOR_RESULT="$("$ROOT_DIR/scripts/triparty-gemini-auth-doctor.sh" "$GEMINI_AUTH_OUT")"
GEMINI_AUTH_DOCTOR_CODE=$?
GEMINI_AUTH_STATUS="$(parse_doctor_field "$GEMINI_AUTH_DOCTOR_RESULT" status)"
GEMINI_AUTH_OUTPUT="$(parse_doctor_field "$GEMINI_AUTH_DOCTOR_RESULT" output)"
GEMINI_AUTH_PATH="$(parse_doctor_field "$GEMINI_AUTH_DOCTOR_RESULT" path)"
if [ -z "$GEMINI_AUTH_STATUS" ]; then
  GEMINI_AUTH_STATUS="interactive-auth-required"
fi
if [ -z "$GEMINI_AUTH_OUTPUT" ]; then
  GEMINI_AUTH_OUTPUT="$GEMINI_AUTH_OUT"
fi
if [ -z "$GEMINI_AUTH_PATH" ]; then
  GEMINI_AUTH_PATH="$(command -v gemini 2>/dev/null || printf 'not found')"
fi

if [ "$GEMINI_AUTH_STATUS" = "authenticated" ]; then
  GEMINI_RESULT="$(probe_cli "Gemini" "gemini" "GEMINI_OK" "$GEMINI_OUT" \
    env TERM="$GEMINI_TERM" gemini -m "$GEMINI_MODEL" -p "Return exactly: GEMINI_OK" --output-format text --skip-trust --approval-mode "$GEMINI_APPROVAL_MODE" --allowed-mcp-server-names "$GEMINI_MCP_ALLOWED" --policy "$GEMINI_POLICY_FILE")"
else
  cp "$GEMINI_AUTH_OUTPUT" "$GEMINI_OUT" 2>/dev/null || true
  GEMINI_RESULT="$(gemini_result_from_auth_doctor "$GEMINI_AUTH_STATUS" "$GEMINI_AUTH_PATH" "$GEMINI_AUTH_OUTPUT")"
fi

GEMINI_STATUS="$(parse_field "$GEMINI_RESULT" 2)"
GEMINI_PATH="$(parse_field "$GEMINI_RESULT" 3)"
GEMINI_BIN_SHA256="$(parse_field "$GEMINI_RESULT" 5)"
GEMINI_ATTEMPT="$(parse_field "$GEMINI_RESULT" 6)"
GEMINI_ERROR_CODE="$(parse_field "$GEMINI_RESULT" 7)"
GEMINI_CAPACITY_EVENTS="$(capacity_event_count "$GEMINI_OUT")"
GEMINI_TOOL_BLOCK_EVENTS="$(diagnostic_count "$GEMINI_OUT" 'ignored by configured ignore patterns|Unauthorized tool call|Tool .* not found|Error executing tool')"

CLAUDE_VERSION="unavailable"
GEMINI_VERSION="unavailable"
if [ "$CLAUDE_PATH" != "not found" ]; then
  CLAUDE_VERSION="$(command_version "$OUT_DIR/claude-version.txt" claude --version)"
fi
if [ "$GEMINI_PATH" != "not found" ]; then
  GEMINI_VERSION="$(command_version "$OUT_DIR/gemini-version.txt" gemini --version)"
fi
MODEL_BINDING_SHA256="$(hash_file "$MODEL_BINDING_FILE")"
GEMINI_POLICY_SHA256="$(hash_file "$GEMINI_POLICY_FILE")"

SOURCE_STATUS_TMP="$OUT_DIR/source-status.md.tmp.$$"
cat > "$SOURCE_STATUS_TMP" <<EOF
# Tri-party Source Status

| Party | Status | Evidence | Version | Binary SHA256 | Final Attempt | Error Code |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | Available | Current Codex session | current | n/a | 0 | E_OK |
| Claude | $CLAUDE_STATUS | $CLAUDE_PATH | $CLAUDE_VERSION | ${CLAUDE_BIN_SHA256:-missing} | ${CLAUDE_ATTEMPT:-0} | ${CLAUDE_ERROR_CODE:-E_UNKNOWN} |
| Gemini | $GEMINI_STATUS | $GEMINI_PATH | $GEMINI_VERSION | ${GEMINI_BIN_SHA256:-missing} | ${GEMINI_ATTEMPT:-0} | ${GEMINI_ERROR_CODE:-E_UNKNOWN} |

Probe timeout: ${PROBE_TIMEOUT}s
Probe retries: ${PROBE_RETRIES}
Probe retry backoff: ${PROBE_RETRY_BACKOFF}s
Gemini model: ${GEMINI_MODEL}
Gemini allowed MCP servers: ${GEMINI_MCP_ALLOWED}
Gemini approval mode: ${GEMINI_APPROVAL_MODE}
Gemini policy file: ${GEMINI_POLICY_FILE}
Gemini policy SHA256: ${GEMINI_POLICY_SHA256}
Gemini auth doctor: status=${GEMINI_AUTH_STATUS}, timeout=${GEMINI_AUTH_TIMEOUT}s, exit_code=${GEMINI_AUTH_DOCTOR_CODE}, output=${GEMINI_AUTH_OUTPUT}
Gemini diagnostics: capacity_events=${GEMINI_CAPACITY_EVENTS}, tool_block_events=${GEMINI_TOOL_BLOCK_EVENTS}
Model binding SHA256: ${MODEL_BINDING_SHA256}
EOF
mv "$SOURCE_STATUS_TMP" "$OUT_DIR/source-status.md"

STATUS_ENV_TMP="$OUT_DIR/status.env.tmp.$$"
{
  printf 'CODEX_STATUS=%q\n' "Available"
  printf 'CLAUDE_STATUS=%q\n' "$CLAUDE_STATUS"
  printf 'CLAUDE_PATH=%q\n' "$CLAUDE_PATH"
  printf 'CLAUDE_VERSION=%q\n' "$CLAUDE_VERSION"
  printf 'CLAUDE_BIN_SHA256=%q\n' "${CLAUDE_BIN_SHA256:-missing}"
  printf 'CLAUDE_ATTEMPT=%q\n' "${CLAUDE_ATTEMPT:-0}"
  printf 'CLAUDE_ERROR_CODE=%q\n' "${CLAUDE_ERROR_CODE:-E_UNKNOWN}"
  printf 'GEMINI_STATUS=%q\n' "$GEMINI_STATUS"
  printf 'GEMINI_PATH=%q\n' "$GEMINI_PATH"
  printf 'GEMINI_VERSION=%q\n' "$GEMINI_VERSION"
  printf 'GEMINI_BIN_SHA256=%q\n' "${GEMINI_BIN_SHA256:-missing}"
  printf 'GEMINI_ATTEMPT=%q\n' "${GEMINI_ATTEMPT:-0}"
  printf 'GEMINI_ERROR_CODE=%q\n' "${GEMINI_ERROR_CODE:-E_UNKNOWN}"
  printf 'GEMINI_AUTH_STATUS=%q\n' "$GEMINI_AUTH_STATUS"
  printf 'GEMINI_AUTH_OUTPUT=%q\n' "$GEMINI_AUTH_OUTPUT"
  printf 'GEMINI_AUTH_TIMEOUT=%q\n' "$GEMINI_AUTH_TIMEOUT"
  printf 'GEMINI_AUTH_DOCTOR_CODE=%q\n' "$GEMINI_AUTH_DOCTOR_CODE"
  printf 'GEMINI_CAPACITY_EVENTS=%q\n' "${GEMINI_CAPACITY_EVENTS:-0}"
  printf 'GEMINI_TOOL_BLOCK_EVENTS=%q\n' "${GEMINI_TOOL_BLOCK_EVENTS:-0}"
  printf 'GEMINI_MODEL=%q\n' "$GEMINI_MODEL"
  printf 'GEMINI_MCP_ALLOWED=%q\n' "$GEMINI_MCP_ALLOWED"
  printf 'GEMINI_APPROVAL_MODE=%q\n' "$GEMINI_APPROVAL_MODE"
  printf 'GEMINI_POLICY_FILE=%q\n' "$GEMINI_POLICY_FILE"
  printf 'GEMINI_POLICY_SHA256=%q\n' "$GEMINI_POLICY_SHA256"
  printf 'MODEL_BINDING_SHA256=%q\n' "$MODEL_BINDING_SHA256"
  printf 'OUT_DIR=%q\n' "$OUT_DIR"
} > "$STATUS_ENV_TMP"
mv "$STATUS_ENV_TMP" "$OUT_DIR/status.env"

cat "$OUT_DIR/source-status.md"

if [ "$CLAUDE_STATUS" = "Available" ] && [ "$GEMINI_STATUS" = "Available" ]; then
  exit 0
fi

exit 1
