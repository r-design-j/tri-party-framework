#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT_DIR/scripts/triparty-merge.sh"
TRIPARTY="$ROOT_DIR/scripts/triparty.sh"
RELEASE_GATE="$ROOT_DIR/scripts/triparty-release-gate.sh"
TMP_ROOT="${TMPDIR:-/tmp}/triparty-regression-$$"
FAILED=0

mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

write_artifact() {
  local file="$1"
  local party="$2"
  local stage="$3"
  local marker="$4"
  shift 4
  {
    printf -- '---\n'
    printf 'triparty_artifact: v1\n'
    printf 'party: %s\n' "$party"
    printf 'stage: %s\n' "$stage"
    printf 'origin: automated_cli\n'
    printf 'runner: triparty-regression.sh\n'
    printf 'generated_at: 2026-06-01T00:00:00Z\n'
    printf 'completion_marker: %s\n' "$marker"
    printf -- '---\n\n'
    printf '%s\n' "$*"
    printf '\n%s\n' "$marker"
  } > "$file"
}

write_complete_run() {
  local run_dir="$1"
  local claude_status="${2:-Completed}"
  local gemini_status="${3:-Completed}"
  local include_cross="${4:-1}"

  mkdir -p "$run_dir/status"
  write_artifact "$run_dir/claude-review.md" "Claude" "review" "TRIPARTY_REVIEW_COMPLETE" "Claude review body."
  write_artifact "$run_dir/gemini-review.md" "Gemini" "review" "TRIPARTY_REVIEW_COMPLETE" "Gemini review body."

  local test_cli_path
  local test_cli_sha
  local policy_sha
  test_cli_path="$(command -v sh 2>/dev/null || command -v bash)"
  test_cli_sha="$(hash_file "$test_cli_path")"
  policy_sha="$(hash_file "$ROOT_DIR/docs/framework/gemini-headless-policy.toml")"

  mkdir -p "$run_dir/preflight"
  {
    printf 'CLAUDE_STATUS=%q\n' "Available"
    printf 'CLAUDE_PATH=%q\n' "$test_cli_path"
    printf 'CLAUDE_VERSION=%q\n' "test-cli"
    printf 'CLAUDE_BIN_SHA256=%q\n' "$test_cli_sha"
    printf 'CLAUDE_ERROR_CODE=%q\n' "E_OK"
    printf 'GEMINI_STATUS=%q\n' "Available"
    printf 'GEMINI_PATH=%q\n' "$test_cli_path"
    printf 'GEMINI_VERSION=%q\n' "test-cli"
    printf 'GEMINI_BIN_SHA256=%q\n' "$test_cli_sha"
    printf 'GEMINI_POLICY_SHA256=%q\n' "$policy_sha"
    printf 'GEMINI_ERROR_CODE=%q\n' "E_OK"
  } > "$run_dir/preflight/status.env"

  local claude_sha
  local gemini_sha
  claude_sha="$(hash_file "$run_dir/claude-review.md")"
  gemini_sha="$(hash_file "$run_dir/gemini-review.md")"

  cat > "$run_dir/source-status.md" <<EOF
# Tri-party Review Source Status

| Party | Preflight | Review | Evidence | Artifact SHA256 | Error Code |
| --- | --- | --- | --- | --- | --- |
| Codex | Available | Current session must synthesize | Current Codex session | n/a | E_OK |
| Claude | Available | $claude_status | $run_dir/claude-review.md | $claude_sha | E_OK |
| Gemini | Available | $gemini_status | $run_dir/gemini-review.md | $gemini_sha | E_OK |
EOF

  {
    printf 'CLAUDE_REVIEW_STATUS=%q\n' "$claude_status"
    printf 'CLAUDE_REVIEW_PATH=%q\n' "$run_dir/claude-review.md"
    printf 'CLAUDE_REVIEW_SHA256=%q\n' "$claude_sha"
    printf 'GEMINI_REVIEW_STATUS=%q\n' "$gemini_status"
    printf 'GEMINI_REVIEW_PATH=%q\n' "$run_dir/gemini-review.md"
    printf 'GEMINI_REVIEW_SHA256=%q\n' "$gemini_sha"
  } > "$run_dir/status.env"

  if [ "$include_cross" = "1" ]; then
    write_artifact "$run_dir/claude-cross-audit.md" "Claude" "cross-audit" "TRIPARTY_CROSS_AUDIT_COMPLETE" "Claude cross-audit body."
    write_artifact "$run_dir/gemini-cross-audit.md" "Gemini" "cross-audit" "TRIPARTY_CROSS_AUDIT_COMPLETE" "Gemini cross-audit body."
    local claude_cross_sha
    local gemini_cross_sha
    claude_cross_sha="$(hash_file "$run_dir/claude-cross-audit.md")"
    gemini_cross_sha="$(hash_file "$run_dir/gemini-cross-audit.md")"
    {
      printf 'CLAUDE_CROSS_STATUS=%q\n' "Completed"
      printf 'CLAUDE_CROSS_PATH=%q\n' "$run_dir/claude-cross-audit.md"
      printf 'CLAUDE_CROSS_SHA256=%q\n' "$claude_cross_sha"
      printf 'GEMINI_CROSS_STATUS=%q\n' "Completed"
      printf 'GEMINI_CROSS_PATH=%q\n' "$run_dir/gemini-cross-audit.md"
      printf 'GEMINI_CROSS_SHA256=%q\n' "$gemini_cross_sha"
    } > "$run_dir/cross-audit.env"
  fi
}

run_expect() {
  local expected="$1"
  local label="$2"
  shift 2

  "$@" > "$TMP_ROOT/${label}.out" 2>&1
  local code=$?

  if grep -Eq 'syntax error|command substitution' "$TMP_ROOT/${label}.out"; then
    printf 'FAIL: %s emitted shell template error\n' "$label" >&2
    sed -n '1,160p' "$TMP_ROOT/${label}.out" >&2
    FAILED=1
    return
  fi

  if [ "$expected" = "pass" ] && [ "$code" -eq 0 ]; then
    printf 'PASS: %s\n' "$label"
    return
  fi

  if [ "$expected" = "fail" ] && [ "$code" -ne 0 ]; then
    printf 'PASS: %s\n' "$label"
    return
  fi

  printf 'FAIL: %s returned %s\n' "$label" "$code" >&2
  sed -n '1,160p' "$TMP_ROOT/${label}.out" >&2
  FAILED=1
}

expect_absent() {
  local file="$1"
  local label="$2"
  if [ -e "$file" ]; then
    printf 'FAIL: %s left stale file %s\n' "$label" "$file" >&2
    FAILED=1
  else
    printf 'PASS: %s\n' "$label"
  fi
}

RUN_OK="$TMP_ROOT/ok"
write_complete_run "$RUN_OK" "Completed" "Completed" "1"
printf 'stale partial\n' > "$RUN_OK/partial-report.md"
run_expect pass "merge_accepts_complete_cross_audited_run" "$MERGE" "$RUN_OK"
expect_absent "$RUN_OK/partial-report.md" "merge_success_removes_stale_partial_report"
run_expect pass "unified_status_writes_state_json" "$TRIPARTY" status "$RUN_OK"
run_expect pass "resume_accepts_already_cross_audited_run" "$TRIPARTY" resume "$RUN_OK"
run_expect pass "release_gate_accepts_ready_run" "$RELEASE_GATE" "$RUN_OK"
if grep -q '"true_triparty_ready": true' "$RUN_OK/state.json" && grep -q '"phase": "merged_ready"' "$RUN_OK/state.json"; then
  printf 'PASS: state_json_marks_ready_run\n'
else
  printf 'FAIL: state_json_marks_ready_run\n' >&2
  sed -n '1,160p' "$RUN_OK/state.json" >&2
  FAILED=1
fi

RUN_INJECT="$TMP_ROOT/inject"
write_complete_run "$RUN_INJECT" "TimedOut" "Completed" "0"
printf 'Injected Claude review.\n' > "$TMP_ROOT/injected-claude.md"
run_expect pass "inject_review_user_supplied" "$TRIPARTY" inject review claude "$RUN_INJECT" "$TMP_ROOT/injected-claude.md"
if grep -q '"review_provenance": "user_supplied"' "$RUN_INJECT/state.json" && grep -q 'CLAUDE_REVIEW_ERROR_CODE=E_USER_SUPPLIED' "$RUN_INJECT/status.env"; then
  printf 'PASS: inject_records_user_supplied_provenance\n'
else
  printf 'FAIL: inject_records_user_supplied_provenance\n' >&2
  sed -n '1,180p' "$RUN_INJECT/state.json" >&2
  FAILED=1
fi
if grep -q '"review_provenance_detail": {"origin":"user_supplied"' "$RUN_INJECT/state.json" \
  && grep -q '"source_sha256":"' "$RUN_INJECT/state.json" \
  && grep -q 'CLAUDE_REVIEW_SOURCE_SHA256=' "$RUN_INJECT/status.env"; then
  printf 'PASS: inject_records_detailed_provenance\n'
else
  printf 'FAIL: inject_records_detailed_provenance\n' >&2
  sed -n '1,220p' "$RUN_INJECT/state.json" >&2
  FAILED=1
fi
: > "$TMP_ROOT/empty-inject.md"
run_expect fail "inject_rejects_empty_artifact" "$TRIPARTY" inject review gemini "$RUN_INJECT" "$TMP_ROOT/empty-inject.md"
run_expect fail "inject_rejects_unknown_party" "$TRIPARTY" inject review llama "$RUN_INJECT" "$TMP_ROOT/injected-claude.md"
run_expect fail "inject_rejects_unknown_stage" "$TRIPARTY" inject transcript claude "$RUN_INJECT" "$TMP_ROOT/injected-claude.md"

RUN_INJECT_HASH="$TMP_ROOT/inject-hash-guard"
write_complete_run "$RUN_INJECT_HASH" "Completed" "Completed" "1"
printf 'Injected fresh Claude review.\n' > "$TMP_ROOT/injected-fresh-claude.md"
run_expect pass "inject_review_for_hash_guard" "$TRIPARTY" inject review claude "$RUN_INJECT_HASH" "$TMP_ROOT/injected-fresh-claude.md"
printf 'tampered after inject\n' >> "$RUN_INJECT_HASH/claude-review.md"
run_expect fail "merge_rejects_injected_hash_mismatch" "$MERGE" "$RUN_INJECT_HASH"

RUNS_FAKE="$TMP_ROOT/runs"
mkdir -p "$RUNS_FAKE"
write_complete_run "$RUNS_FAKE/review-000001" "Completed" "Completed" "1"
"$MERGE" "$RUNS_FAKE/review-000001" >/dev/null 2>&1 || true
run_expect pass "runs_lists_recent_runs" env TRIPARTY_RUNS_DIR="$RUNS_FAKE" "$TRIPARTY" runs 5
run_expect pass "stats_summarizes_runs" env TRIPARTY_RUNS_DIR="$RUNS_FAKE" "$TRIPARTY" stats
run_expect pass "archive_dry_run" env TRIPARTY_RUNS_DIR="$RUNS_FAKE" "$TRIPARTY" archive --keep 1 --dry-run

RUN_MISSING_CROSS="$TMP_ROOT/missing-cross"
write_complete_run "$RUN_MISSING_CROSS" "Completed" "Completed" "0"
printf 'stale merge input\n' > "$RUN_MISSING_CROSS/merge-input.md"
run_expect fail "merge_rejects_missing_cross_audit" "$MERGE" "$RUN_MISSING_CROSS"
expect_absent "$RUN_MISSING_CROSS/merge-input.md" "merge_failure_removes_stale_merge_input"

RUN_PARTIAL="$TMP_ROOT/partial"
write_complete_run "$RUN_PARTIAL" "Completed" "TimedOut" "1"
run_expect fail "merge_rejects_partial_review" "$MERGE" "$RUN_PARTIAL"
run_expect fail "release_gate_rejects_partial_run" "$RELEASE_GATE" "$RUN_PARTIAL"

RUN_HASH="$TMP_ROOT/hash-mismatch"
write_complete_run "$RUN_HASH" "Completed" "Completed" "1"
printf 'tampered\n' >> "$RUN_HASH/gemini-review.md"
run_expect fail "merge_rejects_review_hash_mismatch" "$MERGE" "$RUN_HASH"

RUN_RUNTIME_NOISE="$TMP_ROOT/runtime-noise"
write_complete_run "$RUN_RUNTIME_NOISE" "Completed" "Completed" "1"
printf 'GaxiosError: MODEL_CAPACITY_EXHAUSTED\n' >> "$RUN_RUNTIME_NOISE/gemini-review.md"
gemini_sha="$(hash_file "$RUN_RUNTIME_NOISE/gemini-review.md")"
sed -i.bak "s|GEMINI_REVIEW_SHA256=.*|GEMINI_REVIEW_SHA256=$gemini_sha|" "$RUN_RUNTIME_NOISE/status.env"
rm -f "$RUN_RUNTIME_NOISE/status.env.bak"
run_expect fail "merge_rejects_runtime_noise" "$MERGE" "$RUN_RUNTIME_NOISE"
run_expect fail "release_gate_rejects_runtime_noise" "$RELEASE_GATE" "$RUN_RUNTIME_NOISE"

RUN_CAPACITY="$TMP_ROOT/capacity-threshold"
write_complete_run "$RUN_CAPACITY" "Completed" "Completed" "1"
{
  printf 'GEMINI_REVIEW_CAPACITY_EVENTS=%q\n' "4"
  printf 'GEMINI_CROSS_CAPACITY_EVENTS=%q\n' "0"
} >> "$RUN_CAPACITY/status.env"
run_expect fail "release_gate_rejects_capacity_threshold" "$RELEASE_GATE" "$RUN_CAPACITY"

RUN_POLICY_HASH="$TMP_ROOT/policy-hash"
write_complete_run "$RUN_POLICY_HASH" "Completed" "Completed" "1"
printf 'GEMINI_POLICY_SHA256=%q\n' "0000000000000000000000000000000000000000000000000000000000000000" >> "$RUN_POLICY_HASH/preflight/status.env"
run_expect fail "release_gate_rejects_policy_hash_mismatch" "$RELEASE_GATE" "$RUN_POLICY_HASH"

RUN_METADATA_MISSING="$TMP_ROOT/metadata-missing"
write_complete_run "$RUN_METADATA_MISSING" "Completed" "Completed" "1"
sed -i.bak '/triparty_artifact: v1/d' "$RUN_METADATA_MISSING/claude-review.md"
rm -f "$RUN_METADATA_MISSING/claude-review.md.bak"
claude_sha="$(hash_file "$RUN_METADATA_MISSING/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_METADATA_MISSING/status.env"
rm -f "$RUN_METADATA_MISSING/status.env.bak"
run_expect fail "merge_rejects_missing_metadata" "$MERGE" "$RUN_METADATA_MISSING"

RUN_METADATA_PARTY="$TMP_ROOT/metadata-party-mismatch"
write_complete_run "$RUN_METADATA_PARTY" "Completed" "Completed" "1"
sed -i.bak 's/^party: Claude$/party: Gemini/' "$RUN_METADATA_PARTY/claude-review.md"
rm -f "$RUN_METADATA_PARTY/claude-review.md.bak"
claude_sha="$(hash_file "$RUN_METADATA_PARTY/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_METADATA_PARTY/status.env"
rm -f "$RUN_METADATA_PARTY/status.env.bak"
run_expect fail "merge_rejects_party_metadata_mismatch" "$MERGE" "$RUN_METADATA_PARTY"

RUN_COMPLETION_MISSING="$TMP_ROOT/completion-missing"
write_complete_run "$RUN_COMPLETION_MISSING" "Completed" "Completed" "1"
sed -i.bak '/^TRIPARTY_REVIEW_COMPLETE$/d' "$RUN_COMPLETION_MISSING/claude-review.md"
rm -f "$RUN_COMPLETION_MISSING/claude-review.md.bak"
claude_sha="$(hash_file "$RUN_COMPLETION_MISSING/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_COMPLETION_MISSING/status.env"
rm -f "$RUN_COMPLETION_MISSING/status.env.bak"
run_expect fail "merge_rejects_missing_completion_marker" "$MERGE" "$RUN_COMPLETION_MISSING"

RUN_LABEL="$TMP_ROOT/label-contamination"
write_complete_run "$RUN_LABEL" "Completed" "Completed" "1"
printf 'Codex-only provisional\n' > "$RUN_LABEL/claude-review.md"
claude_sha="$(hash_file "$RUN_LABEL/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_LABEL/status.env"
rm -f "$RUN_LABEL/status.env.bak"
run_expect fail "merge_rejects_source_label_contamination" "$MERGE" "$RUN_LABEL"

RUN_LABEL_MENTION="$TMP_ROOT/label-mention"
write_complete_run "$RUN_LABEL_MENTION" "Completed" "Completed" "1"
write_artifact "$RUN_LABEL_MENTION/claude-review.md" "Claude" "review" "TRIPARTY_REVIEW_COMPLETE" "This review discusses AP-009: Shipping a Codex-only wrapper as a risk, a Gemini CLI model name as configuration, and Source Status management as a feature, but does not claim that Claude is Codex or Gemini."
claude_sha="$(hash_file "$RUN_LABEL_MENTION/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_LABEL_MENTION/status.env"
rm -f "$RUN_LABEL_MENTION/status.env.bak"
run_expect pass "merge_accepts_descriptive_codex_only_mentions" "$MERGE" "$RUN_LABEL_MENTION"

RUN_FALSE_SOURCE="$TMP_ROOT/false-source-status"
write_complete_run "$RUN_FALSE_SOURCE" "Completed" "Completed" "1"
printf '来源状态：Codex = 上下文文档；Claude = 当前 Claude CLI 直答；Gemini = 未调用。非真三方结论。\n' > "$RUN_FALSE_SOURCE/claude-review.md"
claude_sha="$(hash_file "$RUN_FALSE_SOURCE/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_FALSE_SOURCE/status.env"
rm -f "$RUN_FALSE_SOURCE/status.env.bak"
run_expect fail "merge_rejects_party_source_status_self_assessment" "$MERGE" "$RUN_FALSE_SOURCE"

RUN_CROSS_HASH="$TMP_ROOT/cross-hash-mismatch"
write_complete_run "$RUN_CROSS_HASH" "Completed" "Completed" "1"
printf 'tampered\n' >> "$RUN_CROSS_HASH/claude-cross-audit.md"
run_expect fail "merge_rejects_cross_audit_hash_mismatch" "$MERGE" "$RUN_CROSS_HASH"

if [ "$FAILED" -eq 0 ]; then
  printf 'triparty regression passed\n'
  exit 0
fi

printf 'triparty regression failed\n' >&2
exit 1
