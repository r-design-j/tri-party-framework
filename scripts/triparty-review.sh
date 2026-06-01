#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="${TRIPARTY_RUN_DIR:-"$ROOT_DIR/docs/framework/runs/review-$STAMP"}"
REVIEW_TIMEOUT="${TRIPARTY_REVIEW_TIMEOUT:-90}"
REVIEW_RETRIES="${TRIPARTY_REVIEW_RETRIES:-1}"
PROMPT_MAX_CHARS="${TRIPARTY_PROMPT_MAX_CHARS:-6000}"
GEMINI_MODEL="${TRIPARTY_GEMINI_MODEL:-gemini-3.1-pro-preview}"
GEMINI_MCP_ALLOWED="${TRIPARTY_GEMINI_MCP_ALLOWED:-__none__}"
if [ "$#" -gt 0 ]; then
  QUESTION="$1"
  shift
else
  QUESTION="Review the tri-party framework for architecture, logic, and user experience issues."
fi

mkdir -p "$RUN_DIR"
RAW_DIR="$RUN_DIR/raw"
STATUS_DIR="$RUN_DIR/status"
PROMPTS_DIR="$RUN_DIR/prompts"
REPORTS_DIR="$RUN_DIR/reports"
ARTIFACTS_DIR="$RUN_DIR/artifacts"
mkdir -p "$RAW_DIR" "$STATUS_DIR" "$PROMPTS_DIR" "$REPORTS_DIR" "$ARTIFACTS_DIR"

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

write_artifact_metadata() {
  local file="$1"
  local party="$2"
  local channel="$3"
  local generated_at
  local tmp_file
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tmp_file="$(mktemp "$RUN_DIR/artifact.XXXXXX")"
  {
    printf -- '---\n'
    printf 'triparty_artifact: v1\n'
    printf 'party: %s\n' "$party"
    printf 'stage: review\n'
    printf 'origin: automated_cli\n'
    printf 'runner: triparty-review.sh\n'
    printf 'channel: %s\n' "$channel"
    printf 'generated_at: %s\n' "$generated_at"
    printf 'completion_marker: TRIPARTY_REVIEW_COMPLETE\n'
    printf -- '---\n\n'
    cat "$file"
    printf '\n\nTRIPARTY_REVIEW_COMPLETE\n'
  } > "$tmp_file"
  mv "$tmp_file" "$file"
}

write_context() {
  local context_file="$1"
  shift

  {
    printf '# Tri-party Review Context\n\n'
    printf 'Question: %s\n\n' "$QUESTION"

    if [ "$#" -eq 0 ]; then
      set -- "$ROOT_DIR/AGENTS.md" \
        "$ROOT_DIR/docs/framework/tri-party-protocol.md" \
        "$ROOT_DIR/docs/framework/standard-candidates.md"
    fi

    for file in "$@"; do
      if [ -f "$file" ]; then
        printf '\n--- %s ---\n' "$file"
        sed -n '1,260p' "$file"
        printf '\n'
      else
        printf '\n--- Missing file: %s ---\n' "$file"
      fi
    done
  } > "$context_file"
}

write_slim_context() {
  local context_file="$1"
  shift

  {
    printf '# Slim Tri-party Review Context\n\n'
    printf 'Question: %s\n\n' "$QUESTION"
    printf 'Summary:\n'
    printf -- '- Tri-party framework means Codex + Claude + Gemini.\n'
    printf -- '- Codex sub-agents are not Claude or Gemini.\n'
    printf -- '- Source status must be verified before any true tri-party conclusion.\n'
    printf -- '- Capability dispatch: Codex for implementation, Claude for reasoning/autonomy, Gemini for multimodal/Google context.\n'
    printf -- '- Treat probe success and review completion as separate gates.\n\n'

    if [ "$#" -eq 0 ]; then
      printf '\n--- AGENTS.md excerpt ---\n'
      sed -n '22,55p' "$ROOT_DIR/AGENTS.md" 2>/dev/null || true
      printf '\n--- tri-party-protocol.md excerpt ---\n'
      sed -n '1,135p' "$ROOT_DIR/docs/framework/tri-party-protocol.md" 2>/dev/null || true
      sed -n '146,165p' "$ROOT_DIR/docs/framework/tri-party-protocol.md" 2>/dev/null || true
      printf '\n--- standard-candidates.md excerpt ---\n'
      sed -n '1,90p' "$ROOT_DIR/docs/framework/standard-candidates.md" 2>/dev/null || true
      printf '\n--- anti-patterns.md excerpt ---\n'
      sed -n '1,120p' "$ROOT_DIR/docs/framework/anti-patterns.md" 2>/dev/null || true
      return 0
    fi

    for file in "$@"; do
      if [ -f "$file" ]; then
        printf '\n--- %s excerpt ---\n' "$file"
        sed -n '1,90p' "$file"
      fi
    done
  } > "$context_file"
}

write_ultra_slim_context() {
  local context_file="$1"

  cat > "$context_file" <<EOF
# Ultra-slim Tri-party Review Context

Question: $QUESTION

Framework facts:

- Tri-party framework means Codex + Claude + Gemini.
- Codex sub-agents are not valid Claude/Gemini substitutes.
- Codex is implementation owner.
- Claude is reasoning and autonomy owner.
- Gemini is multimodal and Google-context owner.
- Source verification is required before any true tri-party conclusion.
- Probe success and full review completion are separate gates.
- Partial runs must not be synthesized as true tri-party results.
- Mutual cross-audit is required before true tri-party synthesis.
- Known failures: sub-agent mislabel, missed local CLI check, probe success followed by review hang, source-label prompt contamination.
- Current scripts: triparty-preflight.sh, triparty-review.sh, triparty-cross-audit.sh, triparty-merge.sh.
- Current model bindings live in docs/framework/model-binding.yaml.

Review request:

Assess architecture, logic, execution reliability, user experience, failure recovery, and capability-role dispatch. Return concrete issues and iteration suggestions using P0/P1/P2.
EOF
}

sanitize_context() {
  local source_file="$1"
  local target_file="$2"

  grep -v 'Codex-only provisional\|Codex plus Codex sub-agents' "$source_file" > "$target_file" || cp "$source_file" "$target_file"
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
    printf 'E_REVIEW_TIMEOUT'
  elif [ "$status" = "Skipped" ]; then
    printf 'E_REVIEW_SKIPPED'
  else
    printf 'E_REVIEW_FAILED'
  fi
}

run_review_with_retry() {
  local outfile="$1"
  shift

  local attempt=0
  local code=1
  local attempt_file

  while [ "$attempt" -le "$REVIEW_RETRIES" ]; do
    attempt_file="$RAW_DIR/$(basename "$outfile").attempt-$attempt"
    run_with_timeout "$REVIEW_TIMEOUT" "$attempt_file" "$@"
    code=$?
    cp "$attempt_file" "$outfile"

    if [ "$code" -eq 0 ] && [ -s "$outfile" ]; then
      return 0
    fi

    attempt=$((attempt + 1))
  done

  if [ "$code" -eq 0 ]; then
    return 1
  fi

  return "$code"
}

write_handoff_prompt() {
  local party="$1"
  local prompt_file="$2"
  local output_file="$3"

  cat > "$output_file" <<EOF
# ${party} Handoff Prompt

The automated ${party} CLI call did not complete. Paste the prompt below into ${party}, then save the returned output into this run directory and re-run merge.

\`\`\`text
$(cat "$prompt_file")
\`\`\`
EOF
}

"$ROOT_DIR/scripts/triparty-preflight.sh" "$RUN_DIR/preflight" > "$RUN_DIR/preflight-output.txt" 2>&1
PREFLIGHT_CODE=$?

if [ -f "$RUN_DIR/preflight/status.env" ]; then
  # shellcheck disable=SC1091
  . "$RUN_DIR/preflight/status.env"
else
  CLAUDE_STATUS=Unavailable
  GEMINI_STATUS=Unavailable
fi

CONTEXT_FILE="$RUN_DIR/context.md"
write_context "$CONTEXT_FILE" "$@"
MODEL_CONTEXT_FILE="$RUN_DIR/model-context.md"
if [ "$(wc -c < "$CONTEXT_FILE" | tr -d ' ')" -gt "$PROMPT_MAX_CHARS" ]; then
  write_slim_context "$MODEL_CONTEXT_FILE" "$@"
else
  sanitize_context "$CONTEXT_FILE" "$MODEL_CONTEXT_FILE"
fi
if [ "$(wc -c < "$MODEL_CONTEXT_FILE" | tr -d ' ')" -gt "$PROMPT_MAX_CHARS" ]; then
  write_ultra_slim_context "$MODEL_CONTEXT_FILE"
fi

cat > "$RUN_DIR/claude-prompt.txt" <<EOF
You are Claude CLI. Your source label is Claude CLI.
Do not claim to be Codex-only. Do not edit files.
You are one independent party in a larger orchestrated run. The runner, not you, records whether Codex, Claude, and Gemini were called.
Do not state that the overall run is partial, Codex-only, or that another party was not called. If another party's output is not in your prompt, say it is not evaluated in this independent review.
Based only on the provided context, review the tri-party framework itself.
Focus on architecture, logic, user experience, call reliability, process closure, documentation layering, and failure review.
Return Chinese output with P0/P1/P2 priorities, within 1200 Chinese characters.

$(cat "$MODEL_CONTEXT_FILE")
EOF

cat > "$RUN_DIR/gemini-prompt.txt" <<EOF
You are Gemini CLI. Your source label is Gemini CLI.
Do not claim to be Codex-only. Do not edit files.
You are one independent party in a larger orchestrated run. The runner, not you, records whether Codex, Claude, and Gemini were called.
Do not state that the overall run is partial, Codex-only, or that another party was not called. If another party's output is not in your prompt, say it is not evaluated in this independent review.
Based only on the provided context, review the tri-party framework itself.
Focus on architecture, logic, user experience, call reliability, process closure, documentation layering, and failure review.
Return Chinese output with P0/P1/P2 priorities, within 1200 Chinese characters.

$(cat "$MODEL_CONTEXT_FILE")
EOF

CLAUDE_REVIEW_STATUS=Skipped
GEMINI_REVIEW_STATUS=Skipped

if [ "${CLAUDE_STATUS:-Unavailable}" = "Available" ]; then
  run_review_with_retry "$RUN_DIR/claude-review.md" \
    claude -p "$(cat "$RUN_DIR/claude-prompt.txt")" --output-format text --tools "" --no-session-persistence --bare
  CLAUDE_REVIEW_STATUS="$(status_from_code "$?")"
else
  printf 'Claude preflight status: %s\n' "${CLAUDE_STATUS:-Unavailable}" > "$RUN_DIR/claude-review.md"
  write_handoff_prompt "Claude" "$RUN_DIR/claude-prompt.txt" "$RUN_DIR/claude-handoff.md"
fi

if [ "${GEMINI_STATUS:-Unavailable}" = "Available" ]; then
  run_review_with_retry "$RUN_DIR/gemini-review.md" \
    gemini -m "$GEMINI_MODEL" -p "$(cat "$RUN_DIR/gemini-prompt.txt")" --output-format text --skip-trust --allowed-mcp-server-names "$GEMINI_MCP_ALLOWED"
  GEMINI_REVIEW_STATUS="$(status_from_code "$?")"
else
  printf 'Gemini preflight status: %s\n' "${GEMINI_STATUS:-Unavailable}" > "$RUN_DIR/gemini-review.md"
  write_handoff_prompt "Gemini" "$RUN_DIR/gemini-prompt.txt" "$RUN_DIR/gemini-handoff.md"
fi

if [ "$CLAUDE_REVIEW_STATUS" != "Completed" ] && [ ! -f "$RUN_DIR/claude-handoff.md" ]; then
  write_handoff_prompt "Claude" "$RUN_DIR/claude-prompt.txt" "$RUN_DIR/claude-handoff.md"
fi

if [ "$GEMINI_REVIEW_STATUS" != "Completed" ] && [ ! -f "$RUN_DIR/gemini-handoff.md" ]; then
  write_handoff_prompt "Gemini" "$RUN_DIR/gemini-prompt.txt" "$RUN_DIR/gemini-handoff.md"
fi

if [ "$CLAUDE_REVIEW_STATUS" = "Completed" ]; then
  cp "$RUN_DIR/claude-review.md" "$RAW_DIR/claude-review.before-metadata.md"
  write_artifact_metadata "$RUN_DIR/claude-review.md" "Claude" "claude-cli"
fi

if [ "$GEMINI_REVIEW_STATUS" = "Completed" ]; then
  cp "$RUN_DIR/gemini-review.md" "$RAW_DIR/gemini-review.before-metadata.md"
  write_artifact_metadata "$RUN_DIR/gemini-review.md" "Gemini" "gemini-cli"
fi

GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
CLAUDE_REVIEW_SHA256="$(hash_file "$RUN_DIR/claude-review.md")"
GEMINI_REVIEW_SHA256="$(hash_file "$RUN_DIR/gemini-review.md")"
CLAUDE_REVIEW_ERROR_CODE="$(error_from_status "$CLAUDE_REVIEW_STATUS")"
GEMINI_REVIEW_ERROR_CODE="$(error_from_status "$GEMINI_REVIEW_STATUS")"

CONCLUSION_LABEL="Partial review"
if [ "$CLAUDE_REVIEW_STATUS" = "Completed" ] && [ "$GEMINI_REVIEW_STATUS" = "Completed" ]; then
  CONCLUSION_LABEL="Ready for Codex synthesis into true tri-party review"
fi

SOURCE_STATUS_TMP="$RUN_DIR/source-status.md.tmp.$$"
cat > "$SOURCE_STATUS_TMP" <<EOF
# Tri-party Review Source Status

| Party | Preflight | Review | Evidence | Artifact SHA256 | Error Code |
| --- | --- | --- | --- | --- | --- |
| Codex | Available | Current session must synthesize | Current Codex session | n/a | E_OK |
| Claude | ${CLAUDE_STATUS:-Unavailable} | $CLAUDE_REVIEW_STATUS | $RUN_DIR/claude-review.md | $CLAUDE_REVIEW_SHA256 | $CLAUDE_REVIEW_ERROR_CODE |
| Gemini | ${GEMINI_STATUS:-Unavailable} | $GEMINI_REVIEW_STATUS | $RUN_DIR/gemini-review.md | $GEMINI_REVIEW_SHA256 | $GEMINI_REVIEW_ERROR_CODE |

Generated at: $GENERATED_AT
Preflight exit code: $PREFLIGHT_CODE
Review timeout: ${REVIEW_TIMEOUT}s
Review retries: ${REVIEW_RETRIES}
Prompt max chars before slimming: ${PROMPT_MAX_CHARS}
Gemini model: ${GEMINI_MODEL}
Gemini allowed MCP servers: ${GEMINI_MCP_ALLOWED}
Conclusion label: $CONCLUSION_LABEL
EOF
mv "$SOURCE_STATUS_TMP" "$RUN_DIR/source-status.md"

STATUS_ENV_TMP="$RUN_DIR/status.env.tmp.$$"
{
  printf 'GENERATED_AT=%q\n' "$GENERATED_AT"
  printf 'RUN_DIR=%q\n' "$RUN_DIR"
  printf 'CLAUDE_REVIEW_STATUS=%q\n' "$CLAUDE_REVIEW_STATUS"
  printf 'CLAUDE_REVIEW_PATH=%q\n' "$RUN_DIR/claude-review.md"
	  printf 'CLAUDE_REVIEW_SHA256=%q\n' "$CLAUDE_REVIEW_SHA256"
	  printf 'CLAUDE_REVIEW_ERROR_CODE=%q\n' "$CLAUDE_REVIEW_ERROR_CODE"
	  printf 'CLAUDE_REVIEW_PROVENANCE=%q\n' "automated_cli"
	  printf 'GEMINI_REVIEW_STATUS=%q\n' "$GEMINI_REVIEW_STATUS"
	  printf 'GEMINI_REVIEW_PATH=%q\n' "$RUN_DIR/gemini-review.md"
	  printf 'GEMINI_REVIEW_SHA256=%q\n' "$GEMINI_REVIEW_SHA256"
	  printf 'GEMINI_REVIEW_ERROR_CODE=%q\n' "$GEMINI_REVIEW_ERROR_CODE"
	  printf 'GEMINI_REVIEW_PROVENANCE=%q\n' "automated_cli"
	} > "$STATUS_ENV_TMP"
mv "$STATUS_ENV_TMP" "$RUN_DIR/status.env"

cat > "$RUN_DIR/README.md" <<EOF
# Tri-party Review Run

Question: $QUESTION

Read these files:

- source-status.md
- claude-review.md
- gemini-review.md
- claude-handoff.md or gemini-handoff.md when a party is missing
- context.md
- model-context.md

Only call the final result a true tri-party conclusion when Claude and Gemini are both Completed and Codex has synthesized the result with source labels preserved.
EOF

cp "$RUN_DIR/source-status.md" "$STATUS_DIR/source-status.md"
cp "$RUN_DIR/status.env" "$STATUS_DIR/status.env"
cp "$RUN_DIR/preflight-output.txt" "$RAW_DIR/preflight-output.txt"
cp "$RUN_DIR/context.md" "$ARTIFACTS_DIR/context.md"
cp "$RUN_DIR/model-context.md" "$ARTIFACTS_DIR/model-context.md"
cp "$RUN_DIR/claude-prompt.txt" "$PROMPTS_DIR/claude-prompt.txt"
cp "$RUN_DIR/gemini-prompt.txt" "$PROMPTS_DIR/gemini-prompt.txt"
cp "$RUN_DIR/claude-review.md" "$REPORTS_DIR/claude-review.md"
cp "$RUN_DIR/gemini-review.md" "$REPORTS_DIR/gemini-review.md"
if [ -f "$RUN_DIR/claude-handoff.md" ]; then
  cp "$RUN_DIR/claude-handoff.md" "$REPORTS_DIR/claude-handoff.md"
fi
if [ -f "$RUN_DIR/gemini-handoff.md" ]; then
  cp "$RUN_DIR/gemini-handoff.md" "$REPORTS_DIR/gemini-handoff.md"
fi

cat "$RUN_DIR/source-status.md"
printf '\nRun directory: %s\n' "$RUN_DIR"

if [ "$CLAUDE_REVIEW_STATUS" = "Completed" ] && [ "$GEMINI_REVIEW_STATUS" = "Completed" ]; then
  exit 0
fi

exit 1
