#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_DIR="${TRIPARTY_RUNS_DIR:-"$ROOT_DIR/docs/framework/runs"}"

usage() {
  cat <<'EOF'
Usage:
  scripts/triparty-release-gate.sh [run-dir]

Verifies that a run is eligible to support a public push/release claim.
When run-dir is omitted, the latest review run is used.
EOF
}

latest_run_dir() {
  find "$RUNS_DIR" -maxdepth 1 -type d -name 'review-*' 2>/dev/null \
    | while IFS= read -r candidate; do
        if [ -f "$candidate/source-status.md" ]; then
          printf '%s\n' "$candidate"
        fi
      done \
    | sort \
    | tail -n 1
}

run_dir="${1:-}"
if [ "${run_dir:-}" = "-h" ] || [ "${run_dir:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "$run_dir" ]; then
  run_dir="$(latest_run_dir)"
fi

if [ -z "$run_dir" ] || [ ! -d "$run_dir" ]; then
  printf 'Release gate failed: no review run found. Run scripts/triparty.sh run first.\n' >&2
  exit 2
fi

merge_log="$(mktemp "${TMPDIR:-/tmp}/triparty-release-merge.XXXXXX")"
status_log="$(mktemp "${TMPDIR:-/tmp}/triparty-release-status.XXXXXX")"
trap 'rm -f "$merge_log" "$status_log"' EXIT

if ! "$ROOT_DIR/scripts/triparty-merge.sh" "$run_dir" > "$merge_log" 2>&1; then
  cat "$merge_log" >&2
  printf 'Release gate failed: merge gate did not pass for %s\n' "$run_dir" >&2
  exit 1
fi

if ! "$ROOT_DIR/scripts/triparty.sh" status "$run_dir" > "$status_log" 2>&1; then
  cat "$status_log" >&2
  printf 'Release gate failed: could not refresh state for %s\n' "$run_dir" >&2
  exit 1
fi

state_file="$run_dir/state.json"
if [ ! -s "$state_file" ]; then
  printf 'Release gate failed: missing state file %s\n' "$state_file" >&2
  exit 1
fi

if ! "$ROOT_DIR/scripts/triparty-validate-state.py" --release "$state_file" > "$status_log" 2>&1; then
  cat "$status_log" >&2
  printf 'Release gate failed: state validation did not pass for %s\n' "$state_file" >&2
  exit 1
fi

if ! grep -Eq '"true_triparty_ready"[[:space:]]*:[[:space:]]*true' "$state_file"; then
  cat "$state_file" >&2
  printf 'Release gate failed: true_triparty_ready is not true in %s\n' "$state_file" >&2
  exit 1
fi

if ! grep -Eq '"conclusion"[[:space:]]*:[[:space:]]*"Ready for true tri-party synthesis"' "$state_file"; then
  cat "$state_file" >&2
  printf 'Release gate failed: conclusion is not ready in %s\n' "$state_file" >&2
  exit 1
fi

if ! grep -Eq '"errors"[[:space:]]*:[[:space:]]*\[\]' "$state_file"; then
  cat "$state_file" >&2
  printf 'Release gate failed: state has errors in %s\n' "$state_file" >&2
  exit 1
fi

printf 'triparty release gate passed: %s\n' "$run_dir"
printf 'state: %s\n' "$state_file"
