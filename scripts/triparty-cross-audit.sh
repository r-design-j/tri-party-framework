#!/usr/bin/env bash
set -u

if [ "$#" -lt 1 ]; then
  printf 'Usage: %s <run-dir>\n' "$0" >&2
  exit 2
fi

RUN_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CROSS_TIMEOUT="${TRIPARTY_CROSS_TIMEOUT:-240}"
CROSS_RETRIES="${TRIPARTY_CROSS_RETRIES:-2}"
CROSS_RETRY_BACKOFF="${TRIPARTY_CROSS_RETRY_BACKOFF:-10}"
GEMINI_MODEL="${TRIPARTY_GEMINI_MODEL:-gemini-3.1-pro-preview}"
GEMINI_MCP_ALLOWED="${TRIPARTY_GEMINI_MCP_ALLOWED:-__none__}"
GEMINI_APPROVAL_MODE="${TRIPARTY_GEMINI_APPROVAL_MODE:-plan}"
GEMINI_POLICY_FILE="${TRIPARTY_GEMINI_POLICY_FILE:-"$ROOT_DIR/docs/framework/gemini-headless-policy.toml"}"
GEMINI_TERM="${TRIPARTY_GEMINI_TERM:-xterm-256color}"
GEMINI_SANITIZER_VERSION="${TRIPARTY_GEMINI_SANITIZER_VERSION:-gemini-sanitize-v2}"

RAW_DIR="$RUN_DIR/raw"
STATUS_DIR="$RUN_DIR/status"
PROMPTS_DIR="$RUN_DIR/prompts"
REPORTS_DIR="$RUN_DIR/reports"
mkdir -p "$RAW_DIR" "$STATUS_DIR" "$PROMPTS_DIR" "$REPORTS_DIR"

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

sanitize_gemini_output() {
  local file="$1"
  local tmp_file="$file.sanitized.$$"

  awk '
    /^Warning: Basic terminal detected/ { next }
    /^Warning: 256-color support/ { next }
    /^Warning: True color \(24-bit\) support not detected/ { next }
    /^Ripgrep is not available/ { next }
    /^Attempt [0-9]+ failed with status 429/ { skip = "gaxios"; next }
    skip == "gaxios" && /Symbol\(gaxios-gaxios-error\)/ { skip = "gaxios-close"; next }
    skip == "gaxios-close" && /^}$/ { skip = ""; next }
    skip == "gaxios" || skip == "gaxios-close" { next }
    /^Error executing tool (read_file|run_shell_command):/ { next }
    /^\(Use `node --trace-deprecation/ { next }
    /^\(node:[0-9]+\).*DeprecationWarning/ { next }
    /^\[LocalAgentExecutor\] Blocked call:/ { next }
    { print }
  ' "$file" > "$tmp_file"

  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    return 1
  fi

  if cmp -s "$file" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$file"
  return 0
}

write_artifact_metadata() {
  local file="$1"
  local party="$2"
  local target="$3"
  local channel="$4"
  local generated_at
  local tmp_file
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tmp_file="$(mktemp "$RUN_DIR/artifact.XXXXXX")"
  {
    printf -- '---\n'
    printf 'triparty_artifact: v1\n'
    printf 'party: %s\n' "$party"
    printf 'stage: cross-audit\n'
    printf 'target: %s\n' "$target"
    printf 'origin: automated_cli\n'
    printf 'runner: triparty-cross-audit.sh\n'
    printf 'channel: %s\n' "$channel"
    printf 'generated_at: %s\n' "$generated_at"
    printf 'completion_marker: TRIPARTY_CROSS_AUDIT_COMPLETE\n'
    printf -- '---\n\n'
    cat "$file"
    printf '\n\nTRIPARTY_CROSS_AUDIT_COMPLETE\n'
  } > "$tmp_file"
  mv "$tmp_file" "$file"
}

status_from_code() {
  local code="$1"
  if [ "$code" -eq 0 ]; then
    printf 'Completed'
  elif [ "$code" -eq 124 ]; then
    printf 'TimedOut'
  else
    printf 'Failed'
  fi
}

error_from_status() {
  local status="$1"
  if [ "$status" = "Completed" ]; then
    printf 'E_OK'
  elif [ "$status" = "TimedOut" ]; then
    printf 'E_CROSS_TIMEOUT'
  else
    printf 'E_CROSS_FAILED'
  fi
}

run_with_retry() {
  local outfile="$1"
  shift

  local attempt=0
  local code=1
  local attempt_file
  RUN_LAST_ATTEMPT=0
  while [ "$attempt" -le "$CROSS_RETRIES" ]; do
    attempt_file="$RAW_DIR/$(basename "$outfile").attempt-$attempt"
    run_with_timeout "$CROSS_TIMEOUT" "$attempt_file" "$@"
    code=$?
    RUN_LAST_ATTEMPT="$attempt"
    cp "$attempt_file" "$outfile"
    if [ "$code" -eq 0 ] && [ -s "$outfile" ]; then
      return 0
    fi
    if [ "$attempt" -lt "$CROSS_RETRIES" ]; then
      sleep $((CROSS_RETRY_BACKOFF * (attempt + 1)))
    fi
    attempt=$((attempt + 1))
  done

  if [ "$code" -eq 0 ]; then
    return 1
  fi
  return "$code"
}

if [ ! -s "$RUN_DIR/claude-review.md" ] || [ ! -s "$RUN_DIR/gemini-review.md" ]; then
  printf 'Missing Claude or Gemini review artifacts in %s\n' "$RUN_DIR" >&2
  exit 2
fi

cat > "$PROMPTS_DIR/claude-cross-audit-prompt.txt" <<EOF
You are Claude CLI. Your task is to audit Gemini CLI's review and the shared run status.
Do not rewrite your source label. Do not edit files.
Do not call tools, shell commands, file readers, or MCP tools. Use only the provided prompt context.
Do not penalize an independent review for not evaluating other party outputs; review-stage prompts intentionally hide other party outputs. Cross-audit is the comparison stage.
Return Chinese output with: Agreement, Disagreement, Risks Gemini missed, Risks Claude may have missed, Final blocking concerns. Keep under 900 Chinese characters.

## Source Status

$(cat "$RUN_DIR/source-status.md" 2>/dev/null)

## Gemini Review To Audit

$(cat "$RUN_DIR/gemini-review.md")
EOF

cat > "$PROMPTS_DIR/gemini-cross-audit-prompt.txt" <<EOF
You are Gemini CLI. Your task is to audit Claude CLI's review and the shared run status.
Do not rewrite your source label. Do not edit files.
Do not call tools, shell commands, file readers, or MCP tools. Use only the provided prompt context.
Do not penalize an independent review for not evaluating other party outputs; review-stage prompts intentionally hide other party outputs. Cross-audit is the comparison stage.
Return Chinese output with: Agreement, Disagreement, Risks Claude missed, Risks Gemini may have missed, Final blocking concerns. Keep under 900 Chinese characters.

## Source Status

$(cat "$RUN_DIR/source-status.md" 2>/dev/null)

## Claude Review To Audit

$(cat "$RUN_DIR/claude-review.md")
EOF

run_with_retry "$RUN_DIR/claude-cross-audit.md" \
  claude -p "$(cat "$PROMPTS_DIR/claude-cross-audit-prompt.txt")" --output-format text --tools "" --no-session-persistence --bare
CLAUDE_CROSS_STATUS="$(status_from_code "$?")"

run_with_retry "$RUN_DIR/gemini-cross-audit.md" \
  env TERM="$GEMINI_TERM" gemini -m "$GEMINI_MODEL" -p "$(cat "$PROMPTS_DIR/gemini-cross-audit-prompt.txt")" --output-format text --skip-trust --approval-mode "$GEMINI_APPROVAL_MODE" --allowed-mcp-server-names "$GEMINI_MCP_ALLOWED" --policy "$GEMINI_POLICY_FILE"
GEMINI_CROSS_STATUS="$(status_from_code "$?")"
GEMINI_CROSS_ATTEMPT="$RUN_LAST_ATTEMPT"

GEMINI_CROSS_CAPACITY_EVENTS="$(capacity_event_count "$RUN_DIR/gemini-cross-audit.md")"
GEMINI_CROSS_TOOL_BLOCK_EVENTS="$(diagnostic_count "$RUN_DIR/gemini-cross-audit.md" 'ignored by configured ignore patterns|Unauthorized tool call|Tool .* not found|Error executing tool')"
GEMINI_CROSS_SANITIZED=0

if [ "$CLAUDE_CROSS_STATUS" = "Completed" ]; then
  cp "$RUN_DIR/claude-cross-audit.md" "$RAW_DIR/claude-cross-audit.before-metadata.md"
  write_artifact_metadata "$RUN_DIR/claude-cross-audit.md" "Claude" "Gemini review" "claude-cli"
fi

if [ "$GEMINI_CROSS_STATUS" = "Completed" ]; then
  cp "$RUN_DIR/gemini-cross-audit.md" "$RAW_DIR/gemini-cross-audit.before-sanitize.md"
  if sanitize_gemini_output "$RUN_DIR/gemini-cross-audit.md"; then
    GEMINI_CROSS_SANITIZED=1
  fi
  cp "$RUN_DIR/gemini-cross-audit.md" "$RAW_DIR/gemini-cross-audit.before-metadata.md"
  write_artifact_metadata "$RUN_DIR/gemini-cross-audit.md" "Gemini" "Claude review" "gemini-cli"
fi

CLAUDE_CROSS_SHA256="$(hash_file "$RUN_DIR/claude-cross-audit.md")"
GEMINI_CROSS_SHA256="$(hash_file "$RUN_DIR/gemini-cross-audit.md")"
CLAUDE_CROSS_ERROR_CODE="$(error_from_status "$CLAUDE_CROSS_STATUS")"
GEMINI_CROSS_ERROR_CODE="$(error_from_status "$GEMINI_CROSS_STATUS")"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

CROSS_STATUS_TMP="$RUN_DIR/cross-audit-status.md.tmp.$$"
cat > "$CROSS_STATUS_TMP" <<EOF
# Tri-party Cross-audit Status

| Party | Cross-audit Target | Status | Artifact | SHA256 | Diagnostics |
| --- | --- | --- | --- | --- | --- |
| Claude | Gemini review | $CLAUDE_CROSS_STATUS | $RUN_DIR/claude-cross-audit.md | $CLAUDE_CROSS_SHA256 | n/a |
| Gemini | Claude review | $GEMINI_CROSS_STATUS | $RUN_DIR/gemini-cross-audit.md | $GEMINI_CROSS_SHA256 | capacity_events=${GEMINI_CROSS_CAPACITY_EVENTS:-0}; tool_block_events=${GEMINI_CROSS_TOOL_BLOCK_EVENTS:-0}; sanitized=${GEMINI_CROSS_SANITIZED:-0}; final_attempt=${GEMINI_CROSS_ATTEMPT:-0}; sanitizer_version=${GEMINI_SANITIZER_VERSION} |
| Codex | Final synthesis | Pending in active session | Current Codex session | n/a | n/a |

Generated at: $GENERATED_AT
Cross timeout: ${CROSS_TIMEOUT}s
Cross retries: ${CROSS_RETRIES}
Cross retry backoff: ${CROSS_RETRY_BACKOFF}s
Gemini approval mode: ${GEMINI_APPROVAL_MODE}
Gemini policy file: ${GEMINI_POLICY_FILE}
EOF
mv "$CROSS_STATUS_TMP" "$RUN_DIR/cross-audit-status.md"

CROSS_ENV_TMP="$RUN_DIR/cross-audit.env.tmp.$$"
{
  printf 'CLAUDE_CROSS_STATUS=%q\n' "$CLAUDE_CROSS_STATUS"
	  printf 'CLAUDE_CROSS_PATH=%q\n' "$RUN_DIR/claude-cross-audit.md"
	  printf 'CLAUDE_CROSS_SHA256=%q\n' "$CLAUDE_CROSS_SHA256"
	  printf 'CLAUDE_CROSS_ERROR_CODE=%q\n' "$CLAUDE_CROSS_ERROR_CODE"
	  printf 'CLAUDE_CROSS_PROVENANCE=%q\n' "automated_cli"
	  printf 'GEMINI_CROSS_STATUS=%q\n' "$GEMINI_CROSS_STATUS"
	  printf 'GEMINI_CROSS_PATH=%q\n' "$RUN_DIR/gemini-cross-audit.md"
	  printf 'GEMINI_CROSS_SHA256=%q\n' "$GEMINI_CROSS_SHA256"
	  printf 'GEMINI_CROSS_ERROR_CODE=%q\n' "$GEMINI_CROSS_ERROR_CODE"
	  printf 'GEMINI_CROSS_PROVENANCE=%q\n' "automated_cli"
	  printf 'GEMINI_CROSS_ATTEMPT=%q\n' "${GEMINI_CROSS_ATTEMPT:-0}"
	  printf 'GEMINI_CROSS_CAPACITY_EVENTS=%q\n' "${GEMINI_CROSS_CAPACITY_EVENTS:-0}"
	  printf 'GEMINI_CROSS_TOOL_BLOCK_EVENTS=%q\n' "${GEMINI_CROSS_TOOL_BLOCK_EVENTS:-0}"
	  printf 'GEMINI_CROSS_SANITIZED=%q\n' "${GEMINI_CROSS_SANITIZED:-0}"
	  printf 'GEMINI_CROSS_SANITIZER_VERSION=%q\n' "$GEMINI_SANITIZER_VERSION"
	} > "$CROSS_ENV_TMP"
mv "$CROSS_ENV_TMP" "$RUN_DIR/cross-audit.env"

cp "$RUN_DIR/cross-audit-status.md" "$STATUS_DIR/cross-audit-status.md"
cp "$RUN_DIR/cross-audit.env" "$STATUS_DIR/cross-audit.env"
cp "$RUN_DIR/claude-cross-audit.md" "$REPORTS_DIR/claude-cross-audit.md"
cp "$RUN_DIR/gemini-cross-audit.md" "$REPORTS_DIR/gemini-cross-audit.md"

cat "$RUN_DIR/cross-audit-status.md"

if [ "$CLAUDE_CROSS_STATUS" = "Completed" ] && [ "$GEMINI_CROSS_STATUS" = "Completed" ]; then
  exit 0
fi

exit 1
