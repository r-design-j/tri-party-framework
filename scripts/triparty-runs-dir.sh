#!/usr/bin/env bash

triparty_repo_runs_dir() {
  local root_dir="$1"
  printf '%s\n' "${TRIPARTY_REPO_RUNS_DIR:-"$root_dir/docs/framework/runs"}"
}

triparty_fallback_runs_dir() {
  printf '%s\n' "${TRIPARTY_RUNS_FALLBACK_DIR:-"${TMPDIR:-/tmp}/triparty-runs"}"
}

triparty_is_writable_dir() {
  local dir="$1"
  local probe
  mkdir -p "$dir" 2>/dev/null || return 1
  [ -d "$dir" ] || return 1
  probe="$dir/.triparty-write-test.$$"
  : > "$probe" 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null || true
  return 0
}

triparty_resolve_runs_dir() {
  local root_dir="$1"
  local preferred="${TRIPARTY_RUNS_DIR:-"$(triparty_repo_runs_dir "$root_dir")"}"
  local fallback

  if triparty_is_writable_dir "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi

  fallback="$(triparty_fallback_runs_dir)"
  if triparty_is_writable_dir "$fallback"; then
    printf '%s\n' "$fallback"
    return 0
  fi

  printf 'No writable tri-party runs directory. preferred=%s fallback=%s\n' "$preferred" "$fallback" >&2
  return 2
}

triparty_candidate_runs_dirs() {
  local root_dir="$1"
  local resolved="${2:-}"
  local repo
  local fallback

  if [ -n "${TRIPARTY_RUNS_DIR:-}" ]; then
    [ -n "$resolved" ] && printf '%s\n' "$resolved"
    return 0
  fi

  repo="$(triparty_repo_runs_dir "$root_dir")"
  fallback="$(triparty_fallback_runs_dir)"

  {
    [ -n "$resolved" ] && printf '%s\n' "$resolved"
    printf '%s\n' "$repo"
    printf '%s\n' "$fallback"
  } | awk 'NF && !seen[$0]++'
}
