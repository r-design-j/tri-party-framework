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
    printf 'GEMINI_AUTH_STATUS=%q\n' "authenticated"
    printf 'GEMINI_AUTH_OUTPUT=%q\n' "$run_dir/preflight/gemini-auth-doctor.txt"
    printf 'GEMINI_AUTH_TIMEOUT=%q\n' "12"
    printf 'GEMINI_AUTH_DOCTOR_CODE=%q\n' "0"
  } > "$run_dir/preflight/status.env"
  printf 'GEMINI_AUTH_OK\n' > "$run_dir/preflight/gemini-auth-doctor.txt"

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
RUNS_RELEASE_LATEST="$TMP_ROOT/release-latest-runs"
mkdir -p "$RUNS_RELEASE_LATEST"
cp -R "$RUN_OK" "$RUNS_RELEASE_LATEST/review-20260601-000001"
mkdir -p "$RUNS_RELEASE_LATEST/review-20260601-000002/preflight"
printf 'preflight only\n' > "$RUNS_RELEASE_LATEST/review-20260601-000002/preflight-output.txt"
run_expect pass "release_gate_skips_incomplete_latest_run" env TRIPARTY_RUNS_DIR="$RUNS_RELEASE_LATEST" "$RELEASE_GATE"
if grep -q '"true_triparty_ready": true' "$RUN_OK/state.json" && grep -q '"phase": "merged_ready"' "$RUN_OK/state.json"; then
  printf 'PASS: state_json_marks_ready_run\n'
else
  printf 'FAIL: state_json_marks_ready_run\n' >&2
  sed -n '1,160p' "$RUN_OK/state.json" >&2
  FAILED=1
fi

CONTINUITY_DIR="$TMP_ROOT/continuity"
run_expect pass "continuity_checkpoint_writes_handoff" "$TRIPARTY" continuity checkpoint --out-dir "$CONTINUITY_DIR" --workstream "regression" --goal "regression continuity goal" --run-dir "$RUN_OK"
if [ -f "$CONTINUITY_DIR/current.yml" ] && [ -f "$CONTINUITY_DIR/handoff.md" ] && [ -f "$CONTINUITY_DIR/bootstrap.md" ] && [ -f "$CONTINUITY_DIR/manifest.json" ]; then
  printf 'PASS: continuity_files_created\n'
else
  printf 'FAIL: continuity_files_created\n' >&2
  find "$CONTINUITY_DIR" -maxdepth 2 -type f 2>/dev/null >&2 || true
  FAILED=1
fi
run_expect pass "continuity_bootstrap_verifies_manifest" "$TRIPARTY" continuity bootstrap --out-dir "$CONTINUITY_DIR"
printf 'tampered\n' >> "$CONTINUITY_DIR/current.yml"
run_expect fail "continuity_bootstrap_rejects_hash_mismatch" "$TRIPARTY" continuity bootstrap --out-dir "$CONTINUITY_DIR"

CODEX_CONTINUITY_DIR="$TMP_ROOT/codex-continuity"
mkdir -p "$CODEX_CONTINUITY_DIR"
printf 'schema: codex-session-continuity/v1\n' > "$CODEX_CONTINUITY_DIR/current.yml"
printf '# Session Continuity Handoff\n' > "$CODEX_CONTINUITY_DIR/handoff.md"
printf '# Resume This Codex Workstream\n' > "$CODEX_CONTINUITY_DIR/bootstrap.md"
printf '{"generated_at":"2026-06-01T00:00:00Z","event":"checkpoint"}\n' > "$CODEX_CONTINUITY_DIR/events.jsonl"
cat > "$CODEX_CONTINUITY_DIR/manifest.json" <<EOF
{
  "schema": "codex-session-continuity/v1",
  "generated_at": "2026-06-01T00:00:00Z",
  "root": "$TMP_ROOT",
  "revision": 1,
  "files": {
    "current.yml": {
      "sha256": "$(hash_file "$CODEX_CONTINUITY_DIR/current.yml")",
      "bytes": 38
    },
    "handoff.md": {
      "sha256": "$(hash_file "$CODEX_CONTINUITY_DIR/handoff.md")",
      "bytes": 29
    },
    "bootstrap.md": {
      "sha256": "$(hash_file "$CODEX_CONTINUITY_DIR/bootstrap.md")",
      "bytes": 31
    },
    "events.jsonl": {
      "sha256": "$(hash_file "$CODEX_CONTINUITY_DIR/events.jsonl")",
      "bytes": 66
    }
  }
}
EOF
run_expect pass "continuity_bootstrap_accepts_codex_session_manifest" "$TRIPARTY" continuity bootstrap --out-dir "$CODEX_CONTINUITY_DIR"

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

RUNS_FALLBACK_DEFAULT="$TMP_ROOT/default-runs-unwritable"
RUNS_FALLBACK_TARGET="$TMP_ROOT/fallback-runs"
FAKE_OK_BIN="$TMP_ROOT/fake-ok-bin"
mkdir -p "$FAKE_OK_BIN"
cat > "$FAKE_OK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'fake-claude 1.0\n'
  exit 0
fi
printf 'CLAUDE_OK\n'
EOF
cat > "$FAKE_OK_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'fake-gemini 1.0\n'
  exit 0
fi
printf 'GEMINI_AUTH_OK\nGEMINI_OK\n'
EOF
chmod +x "$FAKE_OK_BIN/claude" "$FAKE_OK_BIN/gemini"
mkdir -p "$RUNS_FALLBACK_DEFAULT"
chmod 500 "$RUNS_FALLBACK_DEFAULT"
run_expect pass "preflight_falls_back_when_default_runs_unwritable" env PATH="$FAKE_OK_BIN:$PATH" TRIPARTY_REPO_RUNS_DIR="$RUNS_FALLBACK_DEFAULT" TRIPARTY_RUNS_FALLBACK_DIR="$RUNS_FALLBACK_TARGET" TRIPARTY_PROBE_TIMEOUT=1 TRIPARTY_PROBE_RETRIES=0 TRIPARTY_GEMINI_AUTH_TIMEOUT=1 "$TRIPARTY" preflight
chmod 700 "$RUNS_FALLBACK_DEFAULT"
if find "$RUNS_FALLBACK_TARGET" -maxdepth 1 -type d -name 'preflight-*' | grep -q .; then
  printf 'PASS: fallback_preflight_dir_created\n'
else
  printf 'FAIL: fallback_preflight_dir_created\n' >&2
  FAILED=1
fi

GEMINI_FAKE_BIN="$TMP_ROOT/fake-bin"
GEMINI_FAKE_OUT="$TMP_ROOT/fake-gemini-auth.txt"
mkdir -p "$GEMINI_FAKE_BIN"
cat > "$GEMINI_FAKE_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
printf 'Please sign in with a browser to continue.\n' >&2
exit 1
EOF
chmod +x "$GEMINI_FAKE_BIN/gemini"
run_expect fail "gemini_auth_doctor_reports_interactive_auth" env PATH="$GEMINI_FAKE_BIN:$PATH" TRIPARTY_GEMINI_AUTH_TIMEOUT=2 "$ROOT_DIR/scripts/triparty-gemini-auth-doctor.sh" "$GEMINI_FAKE_OUT"
if env PATH="$GEMINI_FAKE_BIN:$PATH" TRIPARTY_GEMINI_AUTH_TIMEOUT=2 "$ROOT_DIR/scripts/triparty-gemini-auth-doctor.sh" "$GEMINI_FAKE_OUT" 2>/dev/null | grep -q 'status=interactive-auth-required'; then
  printf 'PASS: gemini_auth_doctor_status_interactive_auth_required\n'
else
  printf 'FAIL: gemini_auth_doctor_status_interactive_auth_required\n' >&2
  FAILED=1
fi

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

RUN_DIRECT_CALL_MENTION="$TMP_ROOT/direct-call-mention"
write_complete_run "$RUN_DIRECT_CALL_MENTION" "Completed" "Completed" "1"
write_artifact "$RUN_DIRECT_CALL_MENTION/claude-review.md" "Claude" "review" "TRIPARTY_REVIEW_COMPLETE" "This review says the slash adapter must not directly call claude or gemini. It discusses adapter purity, not whether Claude or Gemini participated in this run."
claude_sha="$(hash_file "$RUN_DIRECT_CALL_MENTION/claude-review.md")"
sed -i.bak "s|CLAUDE_REVIEW_SHA256=.*|CLAUDE_REVIEW_SHA256=$claude_sha|" "$RUN_DIRECT_CALL_MENTION/status.env"
rm -f "$RUN_DIRECT_CALL_MENTION/status.env.bak"
run_expect pass "merge_accepts_descriptive_direct_model_call_mentions" "$MERGE" "$RUN_DIRECT_CALL_MENTION"

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
