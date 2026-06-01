#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_DIR="${TRIPARTY_RUNS_DIR:-"$ROOT_DIR/docs/framework/runs"}"
CORE_VERSION="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || printf '0.0.0-dev')"
MODEL_BINDING_FILE="$ROOT_DIR/docs/framework/model-binding.yaml"

usage() {
  cat <<'EOF'
Usage:
  scripts/triparty.sh run "<question>" [context-files...]
  scripts/triparty.sh review "<question>" [context-files...]
  scripts/triparty.sh cross-audit [run-dir]
  scripts/triparty.sh merge [run-dir]
  scripts/triparty.sh status [run-dir]
  scripts/triparty.sh preflight [out-dir]
  scripts/triparty.sh inject [review|cross-audit] <claude|gemini> <run-dir> <artifact-file>
  scripts/triparty.sh resume [run-dir]
  scripts/triparty.sh runs [limit]
  scripts/triparty.sh stats
  scripts/triparty.sh archive [--keep N] [--dry-run]
  scripts/triparty.sh lint
  scripts/triparty.sh regression

The run command executes review -> cross-audit -> merge and writes state.json.
When run-dir is omitted, status/cross-audit/merge use the latest review run.
EOF
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

latest_run_dir() {
  find "$RUNS_DIR" -maxdepth 1 -type d -name 'review-*' 2>/dev/null | sort | tail -n 1
}

resolve_run_dir() {
  local run_dir="${1:-}"
  if [ -z "$run_dir" ]; then
    run_dir="$(latest_run_dir)"
  fi

  if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
    printf 'Missing run directory. Provide one or create a review run first.\n' >&2
    exit 2
  fi

  printf '%s\n' "$run_dir"
}

json_escape() {
  awk '
    BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      gsub(/\n/, "\\n")
      print
    }
  '
}

json_string() {
  printf '%s' "$1" | json_escape
}

json_nullable_string() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_string "$1")"
  else
    printf 'null'
  fi
}

hash_file() {
  local file="$1"
  if [ -f "$file" ]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

absolute_path() {
  local file="$1"
  local dir
  local base
  dir="$(cd "$(dirname "$file")" && pwd -P)"
  base="$(basename "$file")"
  printf '%s/%s\n' "$dir" "$base"
}

validate_inject_artifact() {
  local file="$1"
  local max_bytes="${TRIPARTY_INJECT_MAX_BYTES:-5242880}"
  local size
  if [ ! -s "$file" ]; then
    printf 'Inject artifact missing or empty: %s\n' "$file" >&2
    exit 2
  fi
  size="$(wc -c < "$file" | tr -d ' ')"
  if [ "$size" -gt "$max_bytes" ]; then
    printf 'Inject artifact too large: %s bytes, max %s bytes\n' "$size" "$max_bytes" >&2
    exit 2
  fi
}

write_injected_artifact() {
  local source_file="$1"
  local target_file="$2"
  local party="$3"
  local stage="$4"
  local injected_at="$5"
  local source_path="$6"
  local source_sha="$7"
  local marker="TRIPARTY_REVIEW_COMPLETE"
  local metadata_party="$party"
  local tmp_file
  if [ "$stage" = "cross-audit" ]; then
    marker="TRIPARTY_CROSS_AUDIT_COMPLETE"
  fi
  if [ "$party" = "claude" ]; then
    metadata_party="Claude"
  elif [ "$party" = "gemini" ]; then
    metadata_party="Gemini"
  fi
  tmp_file="$(mktemp "$(dirname "$target_file")/artifact.XXXXXX")"
  {
    printf -- '---\n'
    printf 'triparty_artifact: v1\n'
    printf 'party: %s\n' "$metadata_party"
    printf 'stage: %s\n' "$stage"
    printf 'origin: user_supplied\n'
    printf 'runner: triparty.sh inject\n'
    printf 'source_path: %s\n' "$source_path"
    printf 'source_sha256: %s\n' "$source_sha"
    printf 'generated_at: %s\n' "$injected_at"
    printf 'completion_marker: %s\n' "$marker"
    printf -- '---\n\n'
    cat "$source_file"
    printf '\n\n%s\n' "$marker"
  } > "$tmp_file"
  mv "$tmp_file" "$target_file"
}

load_env_if_present() {
  local file="$1"
  if [ -f "$file" ]; then
    # shellcheck disable=SC1090
    . "$file"
  fi
}

merge_conclusion() {
  local run_dir="$1"
  if [ -f "$run_dir/merge-status.md" ]; then
    awk -F': ' '/^Conclusion label:/ { value=$2 } END { print value }' "$run_dir/merge-status.md"
  fi
}

provenance_detail_json() {
  local origin="$1"
  local injected_at="$2"
  local source_path="$3"
  local source_sha256="$4"
  local artifact_sha256="$5"
  printf '{"origin":"%s","injected_at":%s,"source_path":%s,"source_sha256":%s,"artifact_sha256":"%s"}' \
    "$(json_string "$origin")" \
    "$(json_nullable_string "$injected_at")" \
    "$(json_nullable_string "$source_path")" \
    "$(json_nullable_string "$source_sha256")" \
    "$(json_string "$artifact_sha256")"
}

status_error_code() {
  local stage="$1"
  local status="$2"
  case "$status" in
    Available|Completed)
      printf 'E_OK'
      ;;
    Missing)
      printf 'E_%s_MISSING' "$stage"
      ;;
    TimedOut)
      printf 'E_%s_TIMEOUT' "$stage"
      ;;
    Skipped)
      printf 'E_%s_SKIPPED' "$stage"
      ;;
    Failed|Unavailable)
      printf 'E_%s_FAILED' "$stage"
      ;;
    *)
      printf 'E_%s_%s' "$stage" "$status" | tr '[:lower:]' '[:upper:]'
      ;;
  esac
}

computed_phase() {
  local conclusion="$1"
  if [ "$conclusion" = "Ready for true tri-party synthesis" ]; then
    printf 'merged_ready'
  elif [ -f "$CURRENT_RUN_DIR/merge-status.md" ]; then
    printf 'merged_partial'
  elif { [ "${CLAUDE_CROSS_STATUS:-Missing}" != "Missing" ] && [ "${CLAUDE_CROSS_STATUS:-Missing}" != "Completed" ]; } \
    || { [ "${GEMINI_CROSS_STATUS:-Missing}" != "Missing" ] && [ "${GEMINI_CROSS_STATUS:-Missing}" != "Completed" ]; }; then
    printf 'cross_audit_failed'
  elif [ "${CLAUDE_CROSS_STATUS:-Missing}" = "Completed" ] && [ "${GEMINI_CROSS_STATUS:-Missing}" = "Completed" ]; then
    printf 'cross_audited'
  elif { [ "${CLAUDE_REVIEW_STATUS:-Missing}" != "Missing" ] && [ "${CLAUDE_REVIEW_STATUS:-Missing}" != "Completed" ]; } \
    || { [ "${GEMINI_REVIEW_STATUS:-Missing}" != "Missing" ] && [ "${GEMINI_REVIEW_STATUS:-Missing}" != "Completed" ]; }; then
    printf 'review_failed'
  elif [ "${CLAUDE_REVIEW_STATUS:-Missing}" = "Completed" ] && [ "${GEMINI_REVIEW_STATUS:-Missing}" = "Completed" ]; then
    printf 'reviewed'
  elif [ -f "$CURRENT_RUN_DIR/source-status.md" ]; then
    printf 'review_partial'
  else
    printf 'created'
  fi
}

state_errors_json() {
  local first=1
  local code
  local message
  printf '['

  emit_error() {
    local stage="$1"
    local party="$2"
    local error_code="$3"
    local error_message="$4"
    if [ -z "$error_code" ] || [ "$error_code" = "E_OK" ] || [ "$error_code" = "n/a" ]; then
      return
    fi
    if [ "$first" -eq 0 ]; then
      printf ','
    fi
    first=0
    printf '{"stage":"%s","party":"%s","code":"%s","message":"%s"}' \
      "$(json_string "$stage")" \
      "$(json_string "$party")" \
      "$(json_string "$error_code")" \
      "$(json_string "$error_message")"
  }

  code="${CLAUDE_ERROR_CODE:-$(status_error_code PREFLIGHT "${CLAUDE_STATUS:-Missing}")}"
  emit_error "preflight" "claude" "$code" "Claude preflight status: ${CLAUDE_STATUS:-Missing}"
  code="${GEMINI_ERROR_CODE:-$(status_error_code PREFLIGHT "${GEMINI_STATUS:-Missing}")}"
  emit_error "preflight" "gemini" "$code" "Gemini preflight status: ${GEMINI_STATUS:-Missing}"

  code="${CLAUDE_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${CLAUDE_REVIEW_STATUS:-Missing}")}"
  emit_error "review" "claude" "$code" "Claude review status: ${CLAUDE_REVIEW_STATUS:-Missing}"
  code="${GEMINI_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${GEMINI_REVIEW_STATUS:-Missing}")}"
  emit_error "review" "gemini" "$code" "Gemini review status: ${GEMINI_REVIEW_STATUS:-Missing}"

  code="${CLAUDE_CROSS_ERROR_CODE:-$(status_error_code CROSS "${CLAUDE_CROSS_STATUS:-Missing}")}"
  emit_error "cross_audit" "claude" "$code" "Claude cross-audit status: ${CLAUDE_CROSS_STATUS:-Missing}"
  code="${GEMINI_CROSS_ERROR_CODE:-$(status_error_code CROSS "${GEMINI_CROSS_STATUS:-Missing}")}"
  emit_error "cross_audit" "gemini" "$code" "Gemini cross-audit status: ${GEMINI_CROSS_STATUS:-Missing}"

  if [ -f "$CURRENT_RUN_DIR/merge-status.md" ] && [ "$(merge_conclusion "$CURRENT_RUN_DIR")" != "Ready for true tri-party synthesis" ]; then
    message="$(merge_conclusion "$CURRENT_RUN_DIR")"
    emit_error "merge" "codex" "E_MERGE_PARTIAL" "${message:-Merge gate did not pass}"
  fi

  printf ']'
}

write_state() {
  local run_dir="$1"
  CURRENT_RUN_DIR="$run_dir"

  CODEX_STATUS="Available"
  CLAUDE_STATUS="Missing"
  GEMINI_STATUS="Missing"
  CLAUDE_REVIEW_STATUS="Missing"
  GEMINI_REVIEW_STATUS="Missing"
  CLAUDE_REVIEW_SHA256=""
  GEMINI_REVIEW_SHA256=""
  CLAUDE_REVIEW_ERROR_CODE=""
  GEMINI_REVIEW_ERROR_CODE=""
  CLAUDE_REVIEW_PROVENANCE="automated_cli"
  GEMINI_REVIEW_PROVENANCE="automated_cli"
  CLAUDE_REVIEW_INJECTED_AT=""
  GEMINI_REVIEW_INJECTED_AT=""
  CLAUDE_REVIEW_SOURCE_PATH=""
  GEMINI_REVIEW_SOURCE_PATH=""
  CLAUDE_REVIEW_SOURCE_SHA256=""
  GEMINI_REVIEW_SOURCE_SHA256=""
  CLAUDE_CROSS_STATUS="Missing"
  GEMINI_CROSS_STATUS="Missing"
  CLAUDE_CROSS_SHA256=""
  GEMINI_CROSS_SHA256=""
  CLAUDE_CROSS_ERROR_CODE=""
  GEMINI_CROSS_ERROR_CODE=""
  CLAUDE_CROSS_PROVENANCE="automated_cli"
  GEMINI_CROSS_PROVENANCE="automated_cli"
  CLAUDE_CROSS_INJECTED_AT=""
  GEMINI_CROSS_INJECTED_AT=""
  CLAUDE_CROSS_SOURCE_PATH=""
  GEMINI_CROSS_SOURCE_PATH=""
  CLAUDE_CROSS_SOURCE_SHA256=""
  GEMINI_CROSS_SOURCE_SHA256=""

  load_env_if_present "$run_dir/preflight/status.env"
  load_env_if_present "$run_dir/status.env"
  load_env_if_present "$run_dir/status/status.env"
  load_env_if_present "$run_dir/cross-audit.env"
  load_env_if_present "$run_dir/status/cross-audit.env"

  local conclusion
  conclusion="$(merge_conclusion "$run_dir")"
  if [ -z "$conclusion" ]; then
    conclusion="Not merged"
  fi

  local phase
  phase="$(computed_phase "$conclusion")"

  local true_ready=false
  if [ "$conclusion" = "Ready for true tri-party synthesis" ]; then
    true_ready=true
  fi

  local state_file="$run_dir/state.json"
  local tmp_state_file="$run_dir/state.json.tmp.$$"
	  cat > "$tmp_state_file" <<EOF
{
  "schema_version": "triparty.state.v1",
  "core_version": "$(json_string "$CORE_VERSION")",
  "generated_at": "$(now_utc)",
  "run_dir": "$(json_string "$run_dir")",
  "phase": "$(json_string "$phase")",
  "true_triparty_ready": $true_ready,
  "conclusion": "$(json_string "$conclusion")",
  "model_binding_sha256": "$(json_string "$(hash_file "$MODEL_BINDING_FILE")")",
  "errors": $(state_errors_json),
  "parties": {
    "codex": {
      "status": "$(json_string "${CODEX_STATUS:-Available}")",
      "role": "final_synthesis"
    },
    "claude": {
      "preflight": "$(json_string "${CLAUDE_STATUS:-Missing}")",
      "review": "$(json_string "${CLAUDE_REVIEW_STATUS:-Missing}")",
      "review_error_code": "$(json_string "${CLAUDE_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${CLAUDE_REVIEW_STATUS:-Missing}")}")",
      "review_provenance": "$(json_string "${CLAUDE_REVIEW_PROVENANCE:-automated_cli}")",
      "review_sha256": "$(json_string "${CLAUDE_REVIEW_SHA256:-$(hash_file "$run_dir/claude-review.md")}")",
      "review_provenance_detail": $(provenance_detail_json "${CLAUDE_REVIEW_PROVENANCE:-automated_cli}" "${CLAUDE_REVIEW_INJECTED_AT:-}" "${CLAUDE_REVIEW_SOURCE_PATH:-}" "${CLAUDE_REVIEW_SOURCE_SHA256:-}" "${CLAUDE_REVIEW_SHA256:-$(hash_file "$run_dir/claude-review.md")}"),
      "cross_audit": "$(json_string "${CLAUDE_CROSS_STATUS:-Missing}")",
      "cross_audit_error_code": "$(json_string "${CLAUDE_CROSS_ERROR_CODE:-$(status_error_code CROSS "${CLAUDE_CROSS_STATUS:-Missing}")}")",
      "cross_audit_provenance": "$(json_string "${CLAUDE_CROSS_PROVENANCE:-automated_cli}")",
      "cross_audit_sha256": "$(json_string "${CLAUDE_CROSS_SHA256:-$(hash_file "$run_dir/claude-cross-audit.md")}")",
      "cross_audit_provenance_detail": $(provenance_detail_json "${CLAUDE_CROSS_PROVENANCE:-automated_cli}" "${CLAUDE_CROSS_INJECTED_AT:-}" "${CLAUDE_CROSS_SOURCE_PATH:-}" "${CLAUDE_CROSS_SOURCE_SHA256:-}" "${CLAUDE_CROSS_SHA256:-$(hash_file "$run_dir/claude-cross-audit.md")}")
    },
    "gemini": {
      "preflight": "$(json_string "${GEMINI_STATUS:-Missing}")",
      "review": "$(json_string "${GEMINI_REVIEW_STATUS:-Missing}")",
      "review_error_code": "$(json_string "${GEMINI_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${GEMINI_REVIEW_STATUS:-Missing}")}")",
      "review_provenance": "$(json_string "${GEMINI_REVIEW_PROVENANCE:-automated_cli}")",
      "review_sha256": "$(json_string "${GEMINI_REVIEW_SHA256:-$(hash_file "$run_dir/gemini-review.md")}")",
      "review_provenance_detail": $(provenance_detail_json "${GEMINI_REVIEW_PROVENANCE:-automated_cli}" "${GEMINI_REVIEW_INJECTED_AT:-}" "${GEMINI_REVIEW_SOURCE_PATH:-}" "${GEMINI_REVIEW_SOURCE_SHA256:-}" "${GEMINI_REVIEW_SHA256:-$(hash_file "$run_dir/gemini-review.md")}"),
      "cross_audit": "$(json_string "${GEMINI_CROSS_STATUS:-Missing}")",
      "cross_audit_error_code": "$(json_string "${GEMINI_CROSS_ERROR_CODE:-$(status_error_code CROSS "${GEMINI_CROSS_STATUS:-Missing}")}")",
      "cross_audit_provenance": "$(json_string "${GEMINI_CROSS_PROVENANCE:-automated_cli}")",
      "cross_audit_sha256": "$(json_string "${GEMINI_CROSS_SHA256:-$(hash_file "$run_dir/gemini-cross-audit.md")}")",
      "cross_audit_provenance_detail": $(provenance_detail_json "${GEMINI_CROSS_PROVENANCE:-automated_cli}" "${GEMINI_CROSS_INJECTED_AT:-}" "${GEMINI_CROSS_SOURCE_PATH:-}" "${GEMINI_CROSS_SOURCE_SHA256:-}" "${GEMINI_CROSS_SHA256:-$(hash_file "$run_dir/gemini-cross-audit.md")}")
    }
  },
  "artifacts": {
    "source_status": "$(json_string "$run_dir/source-status.md")",
    "cross_audit_status": "$(json_string "$run_dir/cross-audit-status.md")",
    "merge_status": "$(json_string "$run_dir/merge-status.md")",
    "merge_input": "$(json_string "$run_dir/merge-input.md")"
  }
}
EOF
  mv "$tmp_state_file" "$state_file"

  if [ -d "$run_dir/status" ]; then
    cp "$state_file" "$run_dir/status/state.json.tmp.$$"
    mv "$run_dir/status/state.json.tmp.$$" "$run_dir/status/state.json"
  fi
}

render_source_status() {
  local run_dir="$1"
  mkdir -p "$run_dir/status"
  cat > "$run_dir/source-status.md" <<EOF
# Tri-party Review Source Status

| Party | Preflight | Review | Evidence | Artifact SHA256 | Error Code |
| --- | --- | --- | --- | --- | --- |
| Codex | Available | Current session must synthesize | Current Codex session | n/a | E_OK |
| Claude | ${CLAUDE_STATUS:-Missing} | ${CLAUDE_REVIEW_STATUS:-Missing} | $run_dir/claude-review.md | ${CLAUDE_REVIEW_SHA256:-$(hash_file "$run_dir/claude-review.md")} | ${CLAUDE_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${CLAUDE_REVIEW_STATUS:-Missing}")} |
| Gemini | ${GEMINI_STATUS:-Missing} | ${GEMINI_REVIEW_STATUS:-Missing} | $run_dir/gemini-review.md | ${GEMINI_REVIEW_SHA256:-$(hash_file "$run_dir/gemini-review.md")} | ${GEMINI_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${GEMINI_REVIEW_STATUS:-Missing}")} |

Generated at: $(now_utc)
Source status renderer: triparty.sh
EOF
  cp "$run_dir/source-status.md" "$run_dir/status/source-status.md"
}

write_review_env() {
  local run_dir="$1"
  local tmp_env="$run_dir/status.env.tmp.$$"
  {
    printf 'RUN_DIR=%q\n' "$run_dir"
    printf 'CLAUDE_REVIEW_STATUS=%q\n' "${CLAUDE_REVIEW_STATUS:-Missing}"
    printf 'CLAUDE_REVIEW_PATH=%q\n' "$run_dir/claude-review.md"
    printf 'CLAUDE_REVIEW_SHA256=%q\n' "${CLAUDE_REVIEW_SHA256:-$(hash_file "$run_dir/claude-review.md")}"
    printf 'CLAUDE_REVIEW_ERROR_CODE=%q\n' "${CLAUDE_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${CLAUDE_REVIEW_STATUS:-Missing}")}"
    printf 'CLAUDE_REVIEW_PROVENANCE=%q\n' "${CLAUDE_REVIEW_PROVENANCE:-automated_cli}"
    printf 'CLAUDE_REVIEW_INJECTED_AT=%q\n' "${CLAUDE_REVIEW_INJECTED_AT:-}"
    printf 'CLAUDE_REVIEW_SOURCE_PATH=%q\n' "${CLAUDE_REVIEW_SOURCE_PATH:-}"
    printf 'CLAUDE_REVIEW_SOURCE_SHA256=%q\n' "${CLAUDE_REVIEW_SOURCE_SHA256:-}"
    printf 'GEMINI_REVIEW_STATUS=%q\n' "${GEMINI_REVIEW_STATUS:-Missing}"
    printf 'GEMINI_REVIEW_PATH=%q\n' "$run_dir/gemini-review.md"
    printf 'GEMINI_REVIEW_SHA256=%q\n' "${GEMINI_REVIEW_SHA256:-$(hash_file "$run_dir/gemini-review.md")}"
    printf 'GEMINI_REVIEW_ERROR_CODE=%q\n' "${GEMINI_REVIEW_ERROR_CODE:-$(status_error_code REVIEW "${GEMINI_REVIEW_STATUS:-Missing}")}"
    printf 'GEMINI_REVIEW_PROVENANCE=%q\n' "${GEMINI_REVIEW_PROVENANCE:-automated_cli}"
    printf 'GEMINI_REVIEW_INJECTED_AT=%q\n' "${GEMINI_REVIEW_INJECTED_AT:-}"
    printf 'GEMINI_REVIEW_SOURCE_PATH=%q\n' "${GEMINI_REVIEW_SOURCE_PATH:-}"
    printf 'GEMINI_REVIEW_SOURCE_SHA256=%q\n' "${GEMINI_REVIEW_SOURCE_SHA256:-}"
  } > "$tmp_env"
  mv "$tmp_env" "$run_dir/status.env"
  mkdir -p "$run_dir/status"
  cp "$run_dir/status.env" "$run_dir/status/status.env.tmp.$$"
  mv "$run_dir/status/status.env.tmp.$$" "$run_dir/status/status.env"
}

render_cross_status() {
  local run_dir="$1"
  mkdir -p "$run_dir/status"
  cat > "$run_dir/cross-audit-status.md" <<EOF
# Tri-party Cross-audit Status

| Party | Cross-audit Target | Status | Artifact | SHA256 |
| --- | --- | --- | --- | --- |
| Claude | Gemini review | ${CLAUDE_CROSS_STATUS:-Missing} | $run_dir/claude-cross-audit.md | ${CLAUDE_CROSS_SHA256:-$(hash_file "$run_dir/claude-cross-audit.md")} |
| Gemini | Claude review | ${GEMINI_CROSS_STATUS:-Missing} | $run_dir/gemini-cross-audit.md | ${GEMINI_CROSS_SHA256:-$(hash_file "$run_dir/gemini-cross-audit.md")} |
| Codex | Final synthesis | Pending in active session | Current Codex session | n/a |

Generated at: $(now_utc)
Cross-audit status renderer: triparty.sh
EOF
  cp "$run_dir/cross-audit-status.md" "$run_dir/status/cross-audit-status.md"
}

write_cross_env() {
  local run_dir="$1"
  local tmp_env="$run_dir/cross-audit.env.tmp.$$"
  {
    printf 'CLAUDE_CROSS_STATUS=%q\n' "${CLAUDE_CROSS_STATUS:-Missing}"
    printf 'CLAUDE_CROSS_PATH=%q\n' "$run_dir/claude-cross-audit.md"
    printf 'CLAUDE_CROSS_SHA256=%q\n' "${CLAUDE_CROSS_SHA256:-$(hash_file "$run_dir/claude-cross-audit.md")}"
    printf 'CLAUDE_CROSS_ERROR_CODE=%q\n' "${CLAUDE_CROSS_ERROR_CODE:-$(status_error_code CROSS "${CLAUDE_CROSS_STATUS:-Missing}")}"
    printf 'CLAUDE_CROSS_PROVENANCE=%q\n' "${CLAUDE_CROSS_PROVENANCE:-automated_cli}"
    printf 'CLAUDE_CROSS_INJECTED_AT=%q\n' "${CLAUDE_CROSS_INJECTED_AT:-}"
    printf 'CLAUDE_CROSS_SOURCE_PATH=%q\n' "${CLAUDE_CROSS_SOURCE_PATH:-}"
    printf 'CLAUDE_CROSS_SOURCE_SHA256=%q\n' "${CLAUDE_CROSS_SOURCE_SHA256:-}"
    printf 'GEMINI_CROSS_STATUS=%q\n' "${GEMINI_CROSS_STATUS:-Missing}"
    printf 'GEMINI_CROSS_PATH=%q\n' "$run_dir/gemini-cross-audit.md"
    printf 'GEMINI_CROSS_SHA256=%q\n' "${GEMINI_CROSS_SHA256:-$(hash_file "$run_dir/gemini-cross-audit.md")}"
    printf 'GEMINI_CROSS_ERROR_CODE=%q\n' "${GEMINI_CROSS_ERROR_CODE:-$(status_error_code CROSS "${GEMINI_CROSS_STATUS:-Missing}")}"
    printf 'GEMINI_CROSS_PROVENANCE=%q\n' "${GEMINI_CROSS_PROVENANCE:-automated_cli}"
    printf 'GEMINI_CROSS_INJECTED_AT=%q\n' "${GEMINI_CROSS_INJECTED_AT:-}"
    printf 'GEMINI_CROSS_SOURCE_PATH=%q\n' "${GEMINI_CROSS_SOURCE_PATH:-}"
    printf 'GEMINI_CROSS_SOURCE_SHA256=%q\n' "${GEMINI_CROSS_SOURCE_SHA256:-}"
  } > "$tmp_env"
  mv "$tmp_env" "$run_dir/cross-audit.env"
  mkdir -p "$run_dir/status"
  cp "$run_dir/cross-audit.env" "$run_dir/status/cross-audit.env.tmp.$$"
  mv "$run_dir/status/cross-audit.env.tmp.$$" "$run_dir/status/cross-audit.env"
}

load_run_env() {
  local run_dir="$1"
  CODEX_STATUS="Available"
  CLAUDE_STATUS="Missing"
  GEMINI_STATUS="Missing"
  CLAUDE_REVIEW_STATUS="Missing"
  GEMINI_REVIEW_STATUS="Missing"
  CLAUDE_REVIEW_SHA256=""
  GEMINI_REVIEW_SHA256=""
  CLAUDE_REVIEW_ERROR_CODE=""
  GEMINI_REVIEW_ERROR_CODE=""
  CLAUDE_REVIEW_PROVENANCE="automated_cli"
  GEMINI_REVIEW_PROVENANCE="automated_cli"
  CLAUDE_REVIEW_INJECTED_AT=""
  GEMINI_REVIEW_INJECTED_AT=""
  CLAUDE_REVIEW_SOURCE_PATH=""
  GEMINI_REVIEW_SOURCE_PATH=""
  CLAUDE_REVIEW_SOURCE_SHA256=""
  GEMINI_REVIEW_SOURCE_SHA256=""
  CLAUDE_CROSS_STATUS="Missing"
  GEMINI_CROSS_STATUS="Missing"
  CLAUDE_CROSS_SHA256=""
  GEMINI_CROSS_SHA256=""
  CLAUDE_CROSS_ERROR_CODE=""
  GEMINI_CROSS_ERROR_CODE=""
  CLAUDE_CROSS_PROVENANCE="automated_cli"
  GEMINI_CROSS_PROVENANCE="automated_cli"
  CLAUDE_CROSS_INJECTED_AT=""
  GEMINI_CROSS_INJECTED_AT=""
  CLAUDE_CROSS_SOURCE_PATH=""
  GEMINI_CROSS_SOURCE_PATH=""
  CLAUDE_CROSS_SOURCE_SHA256=""
  GEMINI_CROSS_SOURCE_SHA256=""
  load_env_if_present "$run_dir/preflight/status.env"
  load_env_if_present "$run_dir/status.env"
  load_env_if_present "$run_dir/status/status.env"
  load_env_if_present "$run_dir/cross-audit.env"
  load_env_if_present "$run_dir/status/cross-audit.env"
}

inject_artifact() {
  local stage="$1"
  local party="$2"
  local run_dir="$3"
  local source_file="$4"

  if [ "$party" != "claude" ] && [ "$party" != "gemini" ]; then
    printf 'Inject party must be claude or gemini.\n' >&2
    exit 2
  fi
  validate_inject_artifact "$source_file"

  mkdir -p "$run_dir/reports" "$run_dir/status"
  load_run_env "$run_dir"
  local injected_at
  local source_path
  local source_sha
  injected_at="$(now_utc)"
  source_path="$(absolute_path "$source_file")"
  source_sha="$(hash_file "$source_file")"

  if [ "$stage" = "review" ]; then
    write_injected_artifact "$source_file" "$run_dir/${party}-review.md" "$party" "$stage" "$injected_at" "$source_path" "$source_sha"
    cp "$run_dir/${party}-review.md" "$run_dir/reports/${party}-review.md"
    if [ "$party" = "claude" ]; then
      CLAUDE_REVIEW_STATUS="Completed"
      CLAUDE_REVIEW_SHA256="$(hash_file "$run_dir/claude-review.md")"
      CLAUDE_REVIEW_ERROR_CODE="E_USER_SUPPLIED"
      CLAUDE_REVIEW_PROVENANCE="user_supplied"
      CLAUDE_REVIEW_INJECTED_AT="$injected_at"
      CLAUDE_REVIEW_SOURCE_PATH="$source_path"
      CLAUDE_REVIEW_SOURCE_SHA256="$source_sha"
    else
      GEMINI_REVIEW_STATUS="Completed"
      GEMINI_REVIEW_SHA256="$(hash_file "$run_dir/gemini-review.md")"
      GEMINI_REVIEW_ERROR_CODE="E_USER_SUPPLIED"
      GEMINI_REVIEW_PROVENANCE="user_supplied"
      GEMINI_REVIEW_INJECTED_AT="$injected_at"
      GEMINI_REVIEW_SOURCE_PATH="$source_path"
      GEMINI_REVIEW_SOURCE_SHA256="$source_sha"
    fi
    write_review_env "$run_dir"
    render_source_status "$run_dir"
    rm -f "$run_dir/merge-status.md" "$run_dir/merge-input.md" "$run_dir/partial-report.md"
  elif [ "$stage" = "cross-audit" ]; then
    write_injected_artifact "$source_file" "$run_dir/${party}-cross-audit.md" "$party" "$stage" "$injected_at" "$source_path" "$source_sha"
    cp "$run_dir/${party}-cross-audit.md" "$run_dir/reports/${party}-cross-audit.md"
    if [ "$party" = "claude" ]; then
      CLAUDE_CROSS_STATUS="Completed"
      CLAUDE_CROSS_SHA256="$(hash_file "$run_dir/claude-cross-audit.md")"
      CLAUDE_CROSS_ERROR_CODE="E_USER_SUPPLIED"
      CLAUDE_CROSS_PROVENANCE="user_supplied"
      CLAUDE_CROSS_INJECTED_AT="$injected_at"
      CLAUDE_CROSS_SOURCE_PATH="$source_path"
      CLAUDE_CROSS_SOURCE_SHA256="$source_sha"
    else
      GEMINI_CROSS_STATUS="Completed"
      GEMINI_CROSS_SHA256="$(hash_file "$run_dir/gemini-cross-audit.md")"
      GEMINI_CROSS_ERROR_CODE="E_USER_SUPPLIED"
      GEMINI_CROSS_PROVENANCE="user_supplied"
      GEMINI_CROSS_INJECTED_AT="$injected_at"
      GEMINI_CROSS_SOURCE_PATH="$source_path"
      GEMINI_CROSS_SOURCE_SHA256="$source_sha"
    fi
    write_cross_env "$run_dir"
    render_cross_status "$run_dir"
    rm -f "$run_dir/merge-status.md" "$run_dir/merge-input.md" "$run_dir/partial-report.md"
  else
    printf 'Inject stage must be review or cross-audit.\n' >&2
    exit 2
  fi

  write_state "$run_dir"
  print_status "$run_dir"
}

resume_run() {
  local run_dir="$1"
  load_run_env "$run_dir"

  local cross_code=0
  if [ "${CLAUDE_REVIEW_STATUS:-Missing}" = "Completed" ] && [ "${GEMINI_REVIEW_STATUS:-Missing}" = "Completed" ]; then
    if [ "${CLAUDE_CROSS_STATUS:-Missing}" != "Completed" ] || [ "${GEMINI_CROSS_STATUS:-Missing}" != "Completed" ]; then
      "$ROOT_DIR/scripts/triparty-cross-audit.sh" "$run_dir"
      cross_code=$?
    fi
  else
    printf 'Cannot resume cross-audit until both reviews are Completed. Use inject for missing party artifacts.\n' >&2
  fi

  "$ROOT_DIR/scripts/triparty-merge.sh" "$run_dir"
  local merge_code=$?
  write_state "$run_dir"
  print_status "$run_dir"

  if [ "$cross_code" -ne 0 ]; then
    exit "$cross_code"
  fi
  exit "$merge_code"
}

list_runs() {
  local limit="${1:-20}"
  find "$RUNS_DIR" -maxdepth 1 -type d -name 'review-*' 2>/dev/null | sort | tail -n "$limit" | while read -r run_dir; do
    write_state "$run_dir" >/dev/null 2>&1 || true
    local phase="unknown"
    local ready="false"
    local conclusion="Not merged"
    if [ -f "$run_dir/state.json" ]; then
      phase="$(awk -F'"' '/"phase"/ {print $4; exit}' "$run_dir/state.json")"
      ready="$(awk -F': ' '/"true_triparty_ready"/ {gsub(/,/, "", $2); print $2; exit}' "$run_dir/state.json")"
      conclusion="$(awk -F'"' '/"conclusion"/ {print $4; exit}' "$run_dir/state.json")"
    fi
    printf '%s\t%s\t%s\t%s\n' "$run_dir" "$phase" "$ready" "$conclusion"
  done
}

stats_runs() {
  local total=0
  local ready=0
  local partial=0
  local review_failed=0
  local cross_failed=0
  local other=0

  while read -r run_dir; do
    [ -z "$run_dir" ] && continue
    total=$((total + 1))
    write_state "$run_dir" >/dev/null 2>&1 || true
    phase="$(awk -F'"' '/"phase"/ {print $4; exit}' "$run_dir/state.json" 2>/dev/null || printf 'unknown')"
    case "$phase" in
      merged_ready) ready=$((ready + 1)) ;;
      merged_partial|review_partial) partial=$((partial + 1)) ;;
      review_failed) review_failed=$((review_failed + 1)) ;;
      cross_audit_failed) cross_failed=$((cross_failed + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done <<EOF
$(find "$RUNS_DIR" -maxdepth 1 -type d -name 'review-*' 2>/dev/null | sort)
EOF

  cat <<EOF
total=$total
merged_ready=$ready
partial=$partial
review_failed=$review_failed
cross_audit_failed=$cross_failed
other=$other
EOF
}

archive_runs() {
  local keep=20
  local dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep)
        keep="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        printf 'Unknown archive option: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  mkdir -p "$RUNS_DIR/archive"
  local total
  total="$(find "$RUNS_DIR" -maxdepth 1 -type d -name 'review-*' 2>/dev/null | wc -l | tr -d ' ')"
  local move_count=$((total - keep))
  if [ "$move_count" -le 0 ]; then
    printf 'No runs to archive. total=%s keep=%s\n' "$total" "$keep"
    return 0
  fi

  find "$RUNS_DIR" -maxdepth 1 -type d -name 'review-*' 2>/dev/null | sort | head -n "$move_count" | while read -r run_dir; do
    if [ "$dry_run" -eq 1 ]; then
      printf 'Would archive %s\n' "$run_dir"
    else
      printf 'Archiving %s\n' "$run_dir"
      mv "$run_dir" "$RUNS_DIR/archive/"
    fi
  done
}

print_status() {
  local run_dir="$1"
  write_state "$run_dir"

  local conclusion
  conclusion="$(merge_conclusion "$run_dir")"
  if [ -z "$conclusion" ]; then
    conclusion="Not merged"
  fi

  printf 'Run: %s\n' "$run_dir"
  printf 'Conclusion: %s\n' "$conclusion"
  printf 'Claude: preflight=%s review=%s cross_audit=%s\n' "${CLAUDE_STATUS:-Missing}" "${CLAUDE_REVIEW_STATUS:-Missing}" "${CLAUDE_CROSS_STATUS:-Missing}"
  printf 'Gemini: preflight=%s review=%s cross_audit=%s\n' "${GEMINI_STATUS:-Missing}" "${GEMINI_REVIEW_STATUS:-Missing}" "${GEMINI_CROSS_STATUS:-Missing}"
  printf 'State: %s\n' "$run_dir/state.json"
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
  usage
  exit 2
fi
shift

case "$cmd" in
  preflight)
    "$ROOT_DIR/scripts/triparty-preflight.sh" "$@"
    exit $?
    ;;
  lint)
    "$ROOT_DIR/scripts/triparty-lint.sh"
    exit $?
    ;;
  regression)
    "$ROOT_DIR/scripts/triparty-regression.sh"
    exit $?
    ;;
  review)
    if [ "$#" -lt 1 ]; then
      usage >&2
      exit 2
    fi
    run_dir="${TRIPARTY_RUN_DIR:-"$RUNS_DIR/review-$(timestamp)"}"
    TRIPARTY_RUN_DIR="$run_dir" "$ROOT_DIR/scripts/triparty-review.sh" "$@"
    code=$?
    write_state "$run_dir"
    printf 'State: %s\n' "$run_dir/state.json"
    exit "$code"
    ;;
  cross-audit)
    run_dir="$(resolve_run_dir "${1:-}")"
    "$ROOT_DIR/scripts/triparty-cross-audit.sh" "$run_dir"
    code=$?
    write_state "$run_dir"
    printf 'State: %s\n' "$run_dir/state.json"
    exit "$code"
    ;;
  merge)
    run_dir="$(resolve_run_dir "${1:-}")"
    "$ROOT_DIR/scripts/triparty-merge.sh" "$run_dir"
    code=$?
    write_state "$run_dir"
    printf 'State: %s\n' "$run_dir/state.json"
    exit "$code"
    ;;
  status)
    run_dir="$(resolve_run_dir "${1:-}")"
    print_status "$run_dir"
    ;;
  inject)
    if [ "$#" -eq 3 ]; then
      stage="review"
      party="$1"
      run_dir="$(resolve_run_dir "$2")"
      source_file="$3"
    elif [ "$#" -eq 4 ]; then
      stage="$1"
      party="$2"
      run_dir="$(resolve_run_dir "$3")"
      source_file="$4"
    else
      usage >&2
      exit 2
    fi
    inject_artifact "$stage" "$party" "$run_dir" "$source_file"
    ;;
  resume)
    run_dir="$(resolve_run_dir "${1:-}")"
    resume_run "$run_dir"
    ;;
  runs)
    list_runs "${1:-20}"
    ;;
  stats)
    stats_runs
    ;;
  archive)
    archive_runs "$@"
    ;;
  run)
    if [ "$#" -lt 1 ]; then
      usage >&2
      exit 2
    fi
    run_dir="${TRIPARTY_RUN_DIR:-"$RUNS_DIR/review-$(timestamp)"}"
    TRIPARTY_RUN_DIR="$run_dir" "$ROOT_DIR/scripts/triparty-review.sh" "$@"
    review_code=$?

    cross_code=1
    if [ "$review_code" -eq 0 ]; then
      "$ROOT_DIR/scripts/triparty-cross-audit.sh" "$run_dir"
      cross_code=$?
    fi

    "$ROOT_DIR/scripts/triparty-merge.sh" "$run_dir"
    merge_code=$?
    write_state "$run_dir"
    print_status "$run_dir"

    if [ "$review_code" -ne 0 ]; then
      exit "$review_code"
    fi
    if [ "$cross_code" -ne 0 ]; then
      exit "$cross_code"
    fi
    exit "$merge_code"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    printf 'Unknown command: %s\n' "$cmd" >&2
    usage >&2
    exit 2
    ;;
esac
