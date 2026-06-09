#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT_DIR/scripts/triparty-merge.sh"
TRIPARTY="$ROOT_DIR/scripts/triparty.sh"
RELEASE_GATE="$ROOT_DIR/scripts/triparty-release-gate.sh"
TMP_ROOT="${TMPDIR:-/tmp}/triparty-regression-$$"
export AGENTPARTY_LOCK_DIR="$TMP_ROOT/agentparty-managed-install-locks"
FAILED=0

mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

normalize_lock_path_for_test() {
  local path="$1"
  local parent
  local base
  local physical_parent
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  case "$path" in
    /*)
      ;;
    *)
      path="$(pwd -P)/$path"
      ;;
  esac
  if [ -d "$path" ]; then
    (cd -P "$path" 2>/dev/null && pwd -P) && return 0
  fi
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$parent" ]; then
    physical_parent="$(cd -P "$parent" 2>/dev/null && pwd -P)" || physical_parent="$parent"
    printf '%s/%s\n' "$physical_parent" "$base"
    return 0
  fi
  printf '%s\n' "$path"
}

current_boot_id_for_test() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '\r\n' < /proc/sys/kernel/random/boot_id
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/darwin-boot-\1/p'
  fi
}
managed_lock_dir() {
  local config_dir="$1"
  local lock_id
  lock_id="$(hash_text "$(normalize_lock_path_for_test "$config_dir")")"
  printf '%s/%s.lock' "$(normalize_lock_path_for_test "$AGENTPARTY_LOCK_DIR")" "$lock_id"
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

AGENTPARTY="$ROOT_DIR/scripts/agentparty.sh"
AGENTPARTY_RUNS="$TMP_ROOT/agentparty-runs"
run_expect pass "agentparty_triparty_install_plan_supported_path" "$AGENTPARTY" install-plan --pack triparty --target-os macos
if grep -q 'triparty preflight' "$TMP_ROOT/agentparty_triparty_install_plan_supported_path.out" \
  && grep -q 'Run supported: true' "$TMP_ROOT/agentparty_triparty_install_plan_supported_path.out"; then
  printf 'PASS: agentparty_triparty_install_plan_lists_executable_commands\n'
else
  printf 'FAIL: agentparty_triparty_install_plan_lists_executable_commands\n' >&2
  sed -n '1,180p' "$TMP_ROOT/agentparty_triparty_install_plan_supported_path.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_triparty_install_plan_windows_native_roadmap" "$AGENTPARTY" install-plan --pack triparty --target-os windows_powershell --json
if grep -q '"executable_status": "roadmap"' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out" \
  && grep -q '"run_supported": false' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out" \
  && grep -q 'uninstall-triparty-global-bootstrap.ps1' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out"; then
  printf 'PASS: agentparty_triparty_install_plan_blocks_native_windows_run\n'
else
  printf 'FAIL: agentparty_triparty_install_plan_blocks_native_windows_run\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out" >&2
  FAILED=1
fi
if grep -q -- '-DryRun' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out" \
  && grep -q -- '-Execute' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out"; then
  printf 'PASS: agentparty_windows_install_plan_exposes_powershell_uninstall\n'
else
  printf 'FAIL: agentparty_windows_install_plan_exposes_powershell_uninstall\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_triparty_install_plan_windows_native_roadmap.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_install_plan_windows_native_prompt_only" "$AGENTPARTY" install-plan --pack claude-code-feishu-claw --target-os windows_powershell --json
if grep -q '"prompt_supported": true' "$TMP_ROOT/agentparty_claw_install_plan_windows_native_prompt_only.out" \
  && grep -q '"evidence_import_supported": false' "$TMP_ROOT/agentparty_claw_install_plan_windows_native_prompt_only.out" \
  && grep -q '"true_triparty_ready_allowed": false' "$TMP_ROOT/agentparty_claw_install_plan_windows_native_prompt_only.out"; then
  printf 'PASS: agentparty_claw_install_plan_keeps_native_windows_prompt_only\n'
else
  printf 'FAIL: agentparty_claw_install_plan_keeps_native_windows_prompt_only\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_install_plan_windows_native_prompt_only.out" >&2
  FAILED=1
fi
if "$AGENTPARTY" install-plan --pack triparty --target-os macos | grep -q 'scripts/uninstall-triparty-global-bootstrap.sh --dry-run'; then
  printf 'PASS: agentparty_install_plan_exposes_uninstall_dry_run\n'
else
  printf 'FAIL: agentparty_install_plan_exposes_uninstall_dry_run\n' >&2
  FAILED=1
fi
run_expect pass "agentparty_info_accepts_positional_pack" "$AGENTPARTY" info triparty --json
if grep -q '"id": "triparty"' "$TMP_ROOT/agentparty_info_accepts_positional_pack.out" \
  && grep -q '"ready_label": "true_triparty_ready"' "$TMP_ROOT/agentparty_info_accepts_positional_pack.out"; then
  printf 'PASS: agentparty_info_positional_pack_verified\n'
else
  printf 'FAIL: agentparty_info_positional_pack_verified\n' >&2
  sed -n '1,160p' "$TMP_ROOT/agentparty_info_accepts_positional_pack.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_info_accepts_pack_flag" "$AGENTPARTY" info --pack claude-code-feishu-claw --json
if grep -q '"id": "claude-code-feishu-claw"' "$TMP_ROOT/agentparty_info_accepts_pack_flag.out" \
  && grep -q '"ready_label": "pack_ready"' "$TMP_ROOT/agentparty_info_accepts_pack_flag.out" \
  && grep -q '"true_triparty_ready"' "$TMP_ROOT/agentparty_info_accepts_pack_flag.out"; then
  printf 'PASS: agentparty_info_pack_flag_verified\n'
else
  printf 'FAIL: agentparty_info_pack_flag_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/agentparty_info_accepts_pack_flag.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_info_rejects_pack_conflict" "$AGENTPARTY" info triparty --pack claude-code-feishu-claw --json
if grep -q 'E_PACK_CONFLICT' "$TMP_ROOT/agentparty_info_rejects_pack_conflict.out"; then
  printf 'PASS: agentparty_info_pack_conflict_guard\n'
else
  printf 'FAIL: agentparty_info_pack_conflict_guard\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_info_rejects_pack_conflict.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_quickstart_triparty_supported_path" "$AGENTPARTY" quickstart --pack triparty --target-os macos --json
if grep -q '"schema_version": "agentparty.quickstart.v1"' "$TMP_ROOT/agentparty_quickstart_triparty_supported_path.out" \
  && grep -q '"run_supported": true' "$TMP_ROOT/agentparty_quickstart_triparty_supported_path.out" \
  && grep -q 'scripts/agentparty.sh install --pack triparty --target-os auto --execute' "$TMP_ROOT/agentparty_quickstart_triparty_supported_path.out" \
  && grep -q 'triparty preflight' "$TMP_ROOT/agentparty_quickstart_triparty_supported_path.out"; then
  printf 'PASS: agentparty_quickstart_triparty_supported_boundary\n'
else
  printf 'FAIL: agentparty_quickstart_triparty_supported_boundary\n' >&2
  sed -n '1,240p' "$TMP_ROOT/agentparty_quickstart_triparty_supported_path.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_onboard_triparty_supported_path" "$AGENTPARTY" onboard --pack triparty --target-os macos --json
if grep -q '"schema_version": "agentparty.onboard.v1"' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && grep -q '"stage": "ready_for_managed_install_or_run"' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && grep -q 'triparty run' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && grep -q 'triparty release-gate' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && grep -q '"probe_success_is_not_completion": true' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && grep -q '"completion_boundary"' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && ! grep -q '"true_triparty_ready": true' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" \
  && ! grep -q '"phase": "merged_ready"' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out"; then
  printf 'PASS: agentparty_onboard_triparty_supported_boundary\n'
else
  printf 'FAIL: agentparty_onboard_triparty_supported_boundary\n' >&2
  sed -n '1,260p' "$TMP_ROOT/agentparty_onboard_triparty_supported_path.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_quickstart_triparty_windows_native_handoff" "$AGENTPARTY" quickstart --pack triparty --target-os windows_powershell --json
if grep -q '"target_os": "windows_powershell"' "$TMP_ROOT/agentparty_quickstart_triparty_windows_native_handoff.out" \
  && grep -q '"run_supported": false' "$TMP_ROOT/agentparty_quickstart_triparty_windows_native_handoff.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_quickstart_triparty_windows_native_handoff.out" \
  && grep -q 'install --pack triparty --target-os windows_powershell --execute' "$TMP_ROOT/agentparty_quickstart_triparty_windows_native_handoff.out"; then
  printf 'PASS: agentparty_quickstart_triparty_windows_native_boundary\n'
else
  printf 'FAIL: agentparty_quickstart_triparty_windows_native_boundary\n' >&2
  sed -n '1,260p' "$TMP_ROOT/agentparty_quickstart_triparty_windows_native_handoff.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_quickstart_claw_windows_native_handoff" "$AGENTPARTY" quickstart --pack claude-code-feishu-claw --target-os windows_powershell --json
if grep -q '"ready_label": "pack_ready"' "$TMP_ROOT/agentparty_quickstart_claw_windows_native_handoff.out" \
  && grep -q '"true_triparty_ready_allowed": false' "$TMP_ROOT/agentparty_quickstart_claw_windows_native_handoff.out" \
  && grep -q 'Feishu connector/auth 自动化仍是 roadmap' "$TMP_ROOT/agentparty_quickstart_claw_windows_native_handoff.out" \
  && grep -q 'evidence --pack claude-code-feishu-claw' "$TMP_ROOT/agentparty_quickstart_claw_windows_native_handoff.out" \
  && ! grep -q 'true_triparty_ready=true' "$TMP_ROOT/agentparty_quickstart_claw_windows_native_handoff.out"; then
  printf 'PASS: agentparty_quickstart_claw_windows_native_boundary\n'
else
  printf 'FAIL: agentparty_quickstart_claw_windows_native_boundary\n' >&2
  sed -n '1,280p' "$TMP_ROOT/agentparty_quickstart_claw_windows_native_handoff.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_force_native_windows_quickstart_auto_handoff" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" quickstart --pack triparty --target-os auto --json
if grep -q '"target_os": "windows_powershell"' "$TMP_ROOT/agentparty_force_native_windows_quickstart_auto_handoff.out" \
  && grep -q '"run_supported": false' "$TMP_ROOT/agentparty_force_native_windows_quickstart_auto_handoff.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_force_native_windows_quickstart_auto_handoff.out"; then
  printf 'PASS: agentparty_force_native_windows_quickstart_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_quickstart_boundary\n' >&2
  sed -n '1,260p' "$TMP_ROOT/agentparty_force_native_windows_quickstart_auto_handoff.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_force_native_windows_onboard_auto_handoff" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" onboard --pack triparty --target-os auto --json
if grep -q '"target_os": "windows_powershell"' "$TMP_ROOT/agentparty_force_native_windows_onboard_auto_handoff.out" \
  && grep -q '"stage": "windows_wsl2_handoff_required"' "$TMP_ROOT/agentparty_force_native_windows_onboard_auto_handoff.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_force_native_windows_onboard_auto_handoff.out" \
  && grep -q '"native_powershell_execution": "roadmap; use WSL2 for current Windows execution"' "$TMP_ROOT/agentparty_force_native_windows_onboard_auto_handoff.out"; then
  printf 'PASS: agentparty_force_native_windows_onboard_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_onboard_boundary\n' >&2
  sed -n '1,260p' "$TMP_ROOT/agentparty_force_native_windows_onboard_auto_handoff.out" >&2
  FAILED=1
fi
if grep -q -- '-Execute' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'Skip modified' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'does not enable native PowerShell run/evidence execution' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1"; then
  printf 'PASS: powershell_uninstaller_static_safety_contract\n'
else
  printf 'FAIL: powershell_uninstaller_static_safety_contract\n' >&2
  FAILED=1
fi
if grep -q 'fsync_lock_metadata' "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh" \
  && grep -q 'fsync_lock_metadata' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" \
  && grep -q 'Sync-ManagedLockMetadata' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'LOCK_OWNER_ID' "$ROOT_DIR/docs/framework/agentparty-managed-install-lifecycle.md"; then
  printf 'PASS: global_bootstrap_owner_metadata_static_contract\n'
else
  printf 'FAIL: global_bootstrap_owner_metadata_static_contract\n' >&2
  FAILED=1
fi
if grep -q 'lock_owner_fingerprint_from_dir' "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh" \
  && grep -q 'lock_owner_fingerprint_from_dir' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" \
  && grep -q 'Get-ManagedLockOwnerFingerprint' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'stale lock reclaim race' "$ROOT_DIR/docs/framework/agentparty-managed-install-lifecycle.md"; then
  printf 'PASS: global_bootstrap_stale_reclaim_static_contract\n'
else
  printf 'FAIL: global_bootstrap_stale_reclaim_static_contract\n' >&2
  FAILED=1
fi
if grep -q 'E_UNVERIFIED_FS' "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh" \
  && grep -q 'E_UNVERIFIED_FS' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" \
  && grep -q 'E_UNVERIFIED_FS' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'is_verified_local_lock_filesystem' "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh" \
  && grep -q 'is_verified_local_lock_filesystem' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" \
  && grep -q 'E_UNVERIFIED_FS' "$ROOT_DIR/docs/framework/agentparty-managed-install-lifecycle.md"; then
  printf 'PASS: global_bootstrap_unverified_filesystem_static_contract\n'
else
  printf 'FAIL: global_bootstrap_unverified_filesystem_static_contract\n' >&2
  FAILED=1
fi
if grep -q 'AGENTPARTY_CMD=.*command -v agentparty' "$ROOT_DIR/.claude/commands/agentparty-claw.md" \
  && grep -q 'exit 1' "$ROOT_DIR/.claude/commands/agentparty-claw.md" \
  && grep -q 'AGENTPARTY_CMD=.*command -v agentparty' "$ROOT_DIR/.claude/commands/ap-claw.md" \
  && grep -q 'exit 1' "$ROOT_DIR/.claude/commands/ap-claw.md"; then
  printf 'PASS: claw_slash_resolver_static_nonzero_boundary\n'
else
  printf 'FAIL: claw_slash_resolver_static_nonzero_boundary\n' >&2
  FAILED=1
fi
if grep -q 'Remove-ManagedClaudeCommand' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'AGENTPARTY_MANAGED_COMMAND: agentparty-claw' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'AGENTPARTY_MANAGED_COMMAND: ap-claw' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'description: Short alias for /agentparty-claw.' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1" \
  && grep -q 'Run the same workflow as' "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.ps1"; then
  printf 'PASS: powershell_uninstaller_static_claw_history_cleanup\n'
else
  printf 'FAIL: powershell_uninstaller_static_claw_history_cleanup\n' >&2
  FAILED=1
fi

INSTALL_HOME="$TMP_ROOT/agentparty-install-home"
INSTALL_CODEX="$INSTALL_HOME/codex"
INSTALL_CLAUDE="$INSTALL_HOME/claude"
INSTALL_CONFIG="$INSTALL_HOME/triparty-config"
INSTALL_BIN="$INSTALL_HOME/bin"
mkdir -p "$INSTALL_HOME"
run_expect pass "agentparty_install_dry_run_noop" env HOME="$INSTALL_HOME" CODEX_HOME="$INSTALL_CODEX" CLAUDE_CONFIG_DIR="$INSTALL_CLAUDE" TRIPARTY_CONFIG_DIR="$INSTALL_CONFIG" TRIPARTY_BIN_DIR="$INSTALL_BIN" "$AGENTPARTY" install --pack triparty --target-os macos
if grep -q 'No changes made. Re-run with --execute' "$TMP_ROOT/agentparty_install_dry_run_noop.out" \
  && [ ! -e "$INSTALL_BIN/triparty" ] \
  && [ ! -e "$INSTALL_CONFIG/config" ]; then
  printf 'PASS: agentparty_install_dry_run_keeps_artifacts_absent\n'
else
  printf 'FAIL: agentparty_install_dry_run_keeps_artifacts_absent\n' >&2
  find "$INSTALL_HOME" -maxdepth 4 -type f -print >&2
  sed -n '1,180p' "$TMP_ROOT/agentparty_install_dry_run_noop.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_install_execute_installs_managed_bootstrap" env HOME="$INSTALL_HOME" CODEX_HOME="$INSTALL_CODEX" CLAUDE_CONFIG_DIR="$INSTALL_CLAUDE" TRIPARTY_CONFIG_DIR="$INSTALL_CONFIG" TRIPARTY_BIN_DIR="$INSTALL_BIN" "$AGENTPARTY" install --pack triparty --target-os macos --execute
if [ -x "$INSTALL_BIN/triparty" ] \
  && [ -x "$INSTALL_BIN/agentparty" ] \
  && [ -f "$INSTALL_CONFIG/config" ] \
  && grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$INSTALL_CODEX/AGENTS.md" \
  && grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$INSTALL_CLAUDE/CLAUDE.md"; then
  printf 'PASS: agentparty_install_execute_artifacts_present\n'
else
  printf 'FAIL: agentparty_install_execute_artifacts_present\n' >&2
  find "$INSTALL_HOME" -maxdepth 4 -type f -print >&2
  FAILED=1
fi
run_expect fail "agentparty_install_blocks_windows_native_execute" "$AGENTPARTY" install --pack triparty --target-os windows_powershell --execute --json
if grep -q '"install_supported": false' "$TMP_ROOT/agentparty_install_blocks_windows_native_execute.out" \
  && grep -q 'E_BLOCKED_OS' "$TMP_ROOT/agentparty_install_blocks_windows_native_execute.out" \
  && grep -q 'Windows non-WSL AgentParty install execute is roadmap' "$TMP_ROOT/agentparty_install_blocks_windows_native_execute.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_install_blocks_windows_native_execute.out"; then
  printf 'PASS: agentparty_install_windows_native_execute_boundary\n'
else
  printf 'FAIL: agentparty_install_windows_native_execute_boundary\n' >&2
  sed -n '1,180p' "$TMP_ROOT/agentparty_install_blocks_windows_native_execute.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_force_native_windows_blocks_auto_install_execute" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" install --pack triparty --target-os auto --execute --json
if grep -q '"detected_os": "windows_powershell"' "$TMP_ROOT/agentparty_force_native_windows_blocks_auto_install_execute.out" \
  && grep -q '"install_supported": false' "$TMP_ROOT/agentparty_force_native_windows_blocks_auto_install_execute.out" \
  && grep -q 'E_BLOCKED_OS' "$TMP_ROOT/agentparty_force_native_windows_blocks_auto_install_execute.out"; then
  printf 'PASS: agentparty_force_native_windows_install_execute_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_install_execute_boundary\n' >&2
  sed -n '1,180p' "$TMP_ROOT/agentparty_force_native_windows_blocks_auto_install_execute.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_force_native_windows_blocks_run" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" run --pack claude-code-feishu-claw --task "native Windows run block"
if grep -q 'E_BLOCKED_OS' "$TMP_ROOT/agentparty_force_native_windows_blocks_run.out" \
  && grep -q 'Windows non-WSL AgentParty run is roadmap' "$TMP_ROOT/agentparty_force_native_windows_blocks_run.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_force_native_windows_blocks_run.out"; then
  printf 'PASS: agentparty_force_native_windows_run_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_run_boundary\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_force_native_windows_blocks_run.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_force_native_windows_blocks_claw_e2e" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" claw-e2e --pack claude-code-feishu-claw --task "native Windows e2e block" --out "$TMP_ROOT/native-claw-e2e"
if grep -q 'E_BLOCKED_OS' "$TMP_ROOT/agentparty_force_native_windows_blocks_claw_e2e.out" \
  && grep -q 'Windows non-WSL AgentParty claw e2e is roadmap' "$TMP_ROOT/agentparty_force_native_windows_blocks_claw_e2e.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_force_native_windows_blocks_claw_e2e.out"; then
  printf 'PASS: agentparty_force_native_windows_claw_e2e_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_claw_e2e_boundary\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_force_native_windows_blocks_claw_e2e.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_force_native_windows_blocks_deep_doctor" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" doctor --pack triparty --deep
if grep -q 'E_BLOCKED_OS' "$TMP_ROOT/agentparty_force_native_windows_blocks_deep_doctor.out" \
  && grep -q 'Windows non-WSL AgentParty deep doctor is roadmap' "$TMP_ROOT/agentparty_force_native_windows_blocks_deep_doctor.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_force_native_windows_blocks_deep_doctor.out"; then
  printf 'PASS: agentparty_force_native_windows_deep_doctor_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_deep_doctor_boundary\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_force_native_windows_blocks_deep_doctor.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_install_blocks_target_os_spoof_execute" "$AGENTPARTY" install --pack triparty --target-os windows_wsl2 --execute --json
if grep -q '"target_matches_host": false' "$TMP_ROOT/agentparty_install_blocks_target_os_spoof_execute.out" \
  && grep -q 'AgentParty install execute target mismatch' "$TMP_ROOT/agentparty_install_blocks_target_os_spoof_execute.out"; then
  printf 'PASS: agentparty_install_target_os_spoof_execute_boundary\n'
else
  printf 'FAIL: agentparty_install_target_os_spoof_execute_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_install_blocks_target_os_spoof_execute.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_install_dry_run_keeps_pack_boundary" "$AGENTPARTY" install --pack claude-code-feishu-claw --target-os macos --json
if grep -q '"true_triparty_ready_allowed": false' "$TMP_ROOT/agentparty_claw_install_dry_run_keeps_pack_boundary.out" \
  && grep -q 'native Feishu Claw connector collection is roadmap' "$TMP_ROOT/agentparty_claw_install_dry_run_keeps_pack_boundary.out" \
  && grep -q 'claw-e2e command can automate Claude Code + Feishu CLI evidence collection' "$TMP_ROOT/agentparty_claw_install_dry_run_keeps_pack_boundary.out"; then
  printf 'PASS: agentparty_claw_install_dry_run_keeps_pack_boundary_note\n'
else
  printf 'FAIL: agentparty_claw_install_dry_run_keeps_pack_boundary_note\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_install_dry_run_keeps_pack_boundary.out" >&2
  FAILED=1
fi
FAKE_E2E_BIN="$TMP_ROOT/fake-e2e-bin"
mkdir -p "$FAKE_E2E_BIN"
cat > "$FAKE_E2E_BIN/claude" <<'EOF'
#!/usr/bin/env sh
printf 'AgentParty fake Claude plan/review: final label pack_ready; true_triparty_ready=false; source_mode=feishu_cli_e2e.\n'
EOF
cat > "$FAKE_E2E_BIN/feishu" <<'EOF'
#!/usr/bin/env sh
if [ "$1" = "docx" ] && [ "$2" = "create" ]; then
  printf '{"url":"https://mi.feishu.cn/docx/FAKE_AGENTPARTY_E2E","token":"FAKE_AGENTPARTY_E2E"}\n'
  exit 0
fi
if [ "$1" = "fetch" ]; then
  printf '{"type":"docx","token":"FAKE_AGENTPARTY_E2E","markdown":"# AgentParty fake E2E\\n\\n这是 AgentParty Claude Code + Feishu Claw pack 的端到端测试文档。"}\n'
  exit 0
fi
printf 'unexpected fake feishu args: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$FAKE_E2E_BIN/claude" "$FAKE_E2E_BIN/feishu"
CLAW_E2E_OUT="$TMP_ROOT/claw-e2e-run"
run_expect pass "agentparty_claw_e2e_fake_feishu_cli_pack_ready" env PATH="$FAKE_E2E_BIN:$PATH" "$AGENTPARTY" claw-e2e --pack claude-code-feishu-claw --task "fake e2e" --out "$CLAW_E2E_OUT" --title "AgentParty fake E2E" --content "# AgentParty fake E2E"
if grep -q '"completion_label": "pack_ready"' "$CLAW_E2E_OUT/state.json" \
  && grep -q '"pack_ready": true' "$CLAW_E2E_OUT/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_E2E_OUT/state.json" \
  && grep -q '"source_mode": "feishu_cli_e2e"' "$CLAW_E2E_OUT/evidence/agentparty-claw-evidence.json" \
  && grep -q '"native_claw_connector": false' "$CLAW_E2E_OUT/e2e-result.json" \
  && ! grep -q '"true_triparty_ready": true' "$CLAW_E2E_OUT/state.json"; then
  printf 'PASS: agentparty_claw_e2e_fake_feishu_cli_boundary\n'
else
  printf 'FAIL: agentparty_claw_e2e_fake_feishu_cli_boundary\n' >&2
  sed -n '1,220p' "$CLAW_E2E_OUT/state.json" >&2
  sed -n '1,220p' "$CLAW_E2E_OUT/e2e-result.json" >&2
  FAILED=1
fi
run_expect pass "agentparty_release_check_quick_passes" "$AGENTPARTY" release-check --json
if grep -q '"status": "passed"' "$TMP_ROOT/agentparty_release_check_quick_passes.out" \
  && grep -q '"label": "triparty regression"' "$TMP_ROOT/agentparty_release_check_quick_passes.out" \
  && grep -q '"status": "skipped"' "$TMP_ROOT/agentparty_release_check_quick_passes.out"; then
  printf 'PASS: agentparty_release_check_quick_gate_verified\n'
else
  printf 'FAIL: agentparty_release_check_quick_gate_verified\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_release_check_quick_passes.out" >&2
  FAILED=1
fi
BAD_WEB_INDEX="$TMP_ROOT/web-index-bad-command.html"
sed 's#scripts/agentparty.sh release-check --full#scripts/agentparty.sh release-check --bad#g' "$ROOT_DIR/web/index.html" > "$BAD_WEB_INDEX"
run_expect fail "agentparty_release_check_rejects_bad_web_command" env AGENTPARTY_WEB_INDEX="$BAD_WEB_INDEX" "$AGENTPARTY" release-check --json
if grep -q 'missing command-card copy commands' "$TMP_ROOT/agentparty_release_check_rejects_bad_web_command.out" \
  && grep -q 'unexpected command-card copy commands' "$TMP_ROOT/agentparty_release_check_rejects_bad_web_command.out"; then
  printf 'PASS: agentparty_release_check_web_command_negative_guard\n'
else
  printf 'FAIL: agentparty_release_check_web_command_negative_guard\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_release_check_rejects_bad_web_command.out" >&2
  FAILED=1
fi
PACKAGE_OUT="$TMP_ROOT/agentparty-release"
run_expect pass "agentparty_package_creates_release_bundle" "$AGENTPARTY" package --out "$PACKAGE_OUT" --archive --json
if [ -f "$PACKAGE_OUT/agentparty-package-manifest.json" ] \
  && [ -f "$PACKAGE_OUT/INSTALL.md" ] \
  && [ -f "$PACKAGE_OUT/scripts/agentparty.py" ] \
  && [ -f "$PACKAGE_OUT/scripts/agentparty.ps1" ] \
  && [ -f "$PACKAGE_OUT/.claude/skills/triparty/SKILL.md" ] \
  && [ -f "$PACKAGE_OUT/.claude/commands/agentparty-claw.md" ] \
  && [ -f "$PACKAGE_OUT/.claude/commands/ap-claw.md" ] \
  && [ -f "$PACKAGE_OUT.tar.gz" ] \
  && tar -tzf "$PACKAGE_OUT.tar.gz" | grep -q 'agentparty-release/INSTALL.md'; then
  printf 'PASS: agentparty_package_release_bundle_files_present\n'
else
  printf 'FAIL: agentparty_package_release_bundle_files_present\n' >&2
  find "$PACKAGE_OUT" -maxdepth 4 -type f -print >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_package_creates_release_bundle.out" >&2
  FAILED=1
fi
if grep -q '"schema_version": "agentparty.package.v1"' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"id": "triparty"' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"id": "claude-code-feishu-claw"' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"packaging_host": {' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"platform_status": "read_only_packaging_supported"' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q 'docs/framework/agentparty-managed-install-lifecycle.md' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"max_completion_label": "pack_ready"' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"true_triparty_ready_allowed": false' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"native_powershell_execution": "roadmap for install --execute, run, doctor --deep, evidence import, and claw-e2e"' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"claw_true_triparty_ready": false' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q 'Feishu Claw auth and connector collection are not automated' "$PACKAGE_OUT/INSTALL.md" \
  && ! grep -q 'docs/framework/runs' "$PACKAGE_OUT/agentparty-package-manifest.json" \
  && ! grep -q '.agent/continuity' "$PACKAGE_OUT/agentparty-package-manifest.json"; then
  printf 'PASS: agentparty_package_manifest_preserves_boundaries\n'
else
  printf 'FAIL: agentparty_package_manifest_preserves_boundaries\n' >&2
  sed -n '1,260p' "$PACKAGE_OUT/agentparty-package-manifest.json" >&2
  FAILED=1
fi
run_expect fail "agentparty_package_refuses_nonempty_overwrite" "$AGENTPARTY" package --out "$PACKAGE_OUT" --json
if grep -q 'package output directory is not empty' "$TMP_ROOT/agentparty_package_refuses_nonempty_overwrite.out"; then
  printf 'PASS: agentparty_package_overwrite_guard\n'
else
  printf 'FAIL: agentparty_package_overwrite_guard\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_package_refuses_nonempty_overwrite.out" >&2
  FAILED=1
fi
NATIVE_PACKAGE_OUT="$TMP_ROOT/native-agentparty-release"
run_expect pass "agentparty_force_native_windows_package_read_only" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" package --out "$NATIVE_PACKAGE_OUT" --json
if grep -q '"package_dir":' "$TMP_ROOT/agentparty_force_native_windows_package_read_only.out" \
  && grep -q '"platform_status": "read_only_packaging_supported_execution_blocked"' "$NATIVE_PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"native_powershell_execution": "blocked"' "$NATIVE_PACKAGE_OUT/agentparty-package-manifest.json" \
  && grep -q '"native_powershell_execution": "roadmap for install --execute, run, doctor --deep, evidence import, and claw-e2e"' "$TMP_ROOT/agentparty_force_native_windows_package_read_only.out"; then
  printf 'PASS: agentparty_native_windows_package_read_only_boundary\n'
else
  printf 'FAIL: agentparty_native_windows_package_read_only_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_force_native_windows_package_read_only.out" >&2
  FAILED=1
fi

BOOT_BLOCK_HOME="$TMP_ROOT/bootstrap-block-native-home"
BOOT_BLOCK_CODEX="$BOOT_BLOCK_HOME/codex"
BOOT_BLOCK_CLAUDE="$BOOT_BLOCK_HOME/claude"
BOOT_BLOCK_CONFIG="$BOOT_BLOCK_HOME/triparty-config"
BOOT_BLOCK_BIN="$BOOT_BLOCK_HOME/bin"
mkdir -p "$BOOT_BLOCK_HOME"
run_expect fail "global_bootstrap_blocks_forced_native_windows_shell" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 HOME="$BOOT_BLOCK_HOME" CODEX_HOME="$BOOT_BLOCK_CODEX" CLAUDE_CONFIG_DIR="$BOOT_BLOCK_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_BLOCK_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BLOCK_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_BLOCKED_OS' "$TMP_ROOT/global_bootstrap_blocks_forced_native_windows_shell.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/global_bootstrap_blocks_forced_native_windows_shell.out" \
  && [ ! -e "$BOOT_BLOCK_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_forced_native_windows_boundary\n'
else
  printf 'FAIL: global_bootstrap_forced_native_windows_boundary\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_bootstrap_blocks_forced_native_windows_shell.out" >&2
  FAILED=1
fi
run_expect fail "global_uninstall_blocks_forced_native_windows_shell" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 HOME="$BOOT_BLOCK_HOME" CODEX_HOME="$BOOT_BLOCK_CODEX" CLAUDE_CONFIG_DIR="$BOOT_BLOCK_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_BLOCK_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BLOCK_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if grep -q 'E_BLOCKED_OS' "$TMP_ROOT/global_uninstall_blocks_forced_native_windows_shell.out" \
  && grep -q 'uninstall-triparty-global-bootstrap.ps1' "$TMP_ROOT/global_uninstall_blocks_forced_native_windows_shell.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/global_uninstall_blocks_forced_native_windows_shell.out"; then
  printf 'PASS: global_uninstall_forced_native_windows_boundary\n'
else
  printf 'FAIL: global_uninstall_forced_native_windows_boundary\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_uninstall_blocks_forced_native_windows_shell.out" >&2
  FAILED=1
fi

UNKNOWN_FS_BIN="$TMP_ROOT/fake-unknown-fs-bin"
mkdir -p "$UNKNOWN_FS_BIN"
cat > "$UNKNOWN_FS_BIN/stat" <<'EOF'
#!/usr/bin/env sh
printf 'mysteryfs\n'
exit 0
EOF
chmod +x "$UNKNOWN_FS_BIN/stat"
BOOT_UNKNOWN_FS_HOME="$TMP_ROOT/bootstrap-unknown-fs-home"
BOOT_UNKNOWN_FS_CODEX="$BOOT_UNKNOWN_FS_HOME/codex"
BOOT_UNKNOWN_FS_CLAUDE="$BOOT_UNKNOWN_FS_HOME/claude"
BOOT_UNKNOWN_FS_CONFIG="$BOOT_UNKNOWN_FS_HOME/triparty-config"
BOOT_UNKNOWN_FS_BIN="$BOOT_UNKNOWN_FS_HOME/bin"
mkdir -p "$BOOT_UNKNOWN_FS_HOME"
run_expect fail "global_bootstrap_unknown_filesystem_fails_closed" env PATH="$UNKNOWN_FS_BIN:$PATH" HOME="$BOOT_UNKNOWN_FS_HOME" CODEX_HOME="$BOOT_UNKNOWN_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_UNKNOWN_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_UNKNOWN_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_UNKNOWN_FS_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_UNVERIFIED_FS' "$TMP_ROOT/global_bootstrap_unknown_filesystem_fails_closed.out" \
  && grep -q 'mysteryfs' "$TMP_ROOT/global_bootstrap_unknown_filesystem_fails_closed.out" \
  && [ ! -e "$BOOT_UNKNOWN_FS_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_unknown_filesystem_fail_closed_verified\n'
else
  printf 'FAIL: global_bootstrap_unknown_filesystem_fail_closed_verified\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_bootstrap_unknown_filesystem_fails_closed.out" >&2
  FAILED=1
fi

EMPTY_FS_BIN="$TMP_ROOT/fake-empty-fs-bin"
mkdir -p "$EMPTY_FS_BIN"
cat > "$EMPTY_FS_BIN/stat" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
cat > "$EMPTY_FS_BIN/df" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
cat > "$EMPTY_FS_BIN/mount" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
chmod +x "$EMPTY_FS_BIN/stat" "$EMPTY_FS_BIN/df" "$EMPTY_FS_BIN/mount"
BOOT_EMPTY_FS_HOME="$TMP_ROOT/bootstrap-empty-fs-home"
BOOT_EMPTY_FS_CODEX="$BOOT_EMPTY_FS_HOME/codex"
BOOT_EMPTY_FS_CLAUDE="$BOOT_EMPTY_FS_HOME/claude"
BOOT_EMPTY_FS_CONFIG="$BOOT_EMPTY_FS_HOME/triparty-config"
BOOT_EMPTY_FS_BIN="$BOOT_EMPTY_FS_HOME/bin"
mkdir -p "$BOOT_EMPTY_FS_HOME"
run_expect fail "global_bootstrap_empty_filesystem_fails_closed" env PATH="$EMPTY_FS_BIN:$PATH" HOME="$BOOT_EMPTY_FS_HOME" CODEX_HOME="$BOOT_EMPTY_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_EMPTY_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_EMPTY_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_EMPTY_FS_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_UNVERIFIED_FS' "$TMP_ROOT/global_bootstrap_empty_filesystem_fails_closed.out" \
  && grep -q 'unknown' "$TMP_ROOT/global_bootstrap_empty_filesystem_fails_closed.out" \
  && [ ! -e "$BOOT_EMPTY_FS_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_empty_filesystem_fail_closed_verified\n'
else
  printf 'FAIL: global_bootstrap_empty_filesystem_fail_closed_verified\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_bootstrap_empty_filesystem_fails_closed.out" >&2
  FAILED=1
fi

BSD_FS_BIN="$TMP_ROOT/fake-bsd-fs-bin"
mkdir -p "$BSD_FS_BIN"
cat > "$BSD_FS_BIN/stat" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
cat > "$BSD_FS_BIN/df" <<'EOF'
#!/usr/bin/env sh
if [ "$1" = "-T" ] && [ "$2" = "apfs" ]; then
  printf 'Filesystem 512-blocks Used Available Capacity Mounted on\n'
  printf '/dev/disk-test 100 1 99 1%% /tmp\n'
  exit 0
fi
exit 1
EOF
chmod +x "$BSD_FS_BIN/stat" "$BSD_FS_BIN/df"
BOOT_BSD_FS_HOME="$TMP_ROOT/bootstrap-bsd-fs-home"
BOOT_BSD_FS_CODEX="$BOOT_BSD_FS_HOME/codex"
BOOT_BSD_FS_CLAUDE="$BOOT_BSD_FS_HOME/claude"
BOOT_BSD_FS_CONFIG="$BOOT_BSD_FS_HOME/triparty-config"
BOOT_BSD_FS_BIN="$BOOT_BSD_FS_HOME/bin"
mkdir -p "$BOOT_BSD_FS_HOME"
run_expect pass "global_bootstrap_bsd_df_candidate_fallback_installs" env PATH="$BSD_FS_BIN:$PATH" HOME="$BOOT_BSD_FS_HOME" CODEX_HOME="$BOOT_BSD_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_BSD_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_BSD_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BSD_FS_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if [ -f "$BOOT_BSD_FS_CONFIG/managed-install.env" ] && [ -x "$BOOT_BSD_FS_BIN/triparty" ]; then
  printf 'PASS: global_bootstrap_bsd_df_candidate_fallback_verified\n'
else
  printf 'FAIL: global_bootstrap_bsd_df_candidate_fallback_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_bsd_df_candidate_fallback_installs.out" >&2
  FAILED=1
fi
run_expect pass "global_uninstall_bsd_df_candidate_fallback_cleans" env PATH="$BSD_FS_BIN:$PATH" HOME="$BOOT_BSD_FS_HOME" CODEX_HOME="$BOOT_BSD_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_BSD_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_BSD_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BSD_FS_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ ! -e "$BOOT_BSD_FS_BIN/triparty" ] && [ ! -e "$BOOT_BSD_FS_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_uninstall_bsd_df_candidate_fallback_verified\n'
else
  printf 'FAIL: global_uninstall_bsd_df_candidate_fallback_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_uninstall_bsd_df_candidate_fallback_cleans.out" >&2
  FAILED=1
fi

NFS_FS_BIN="$TMP_ROOT/fake-nfs-fs-bin"
mkdir -p "$NFS_FS_BIN"
cat > "$NFS_FS_BIN/stat" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
cat > "$NFS_FS_BIN/df" <<'EOF'
#!/usr/bin/env sh
if [ "$1" = "-T" ] && [ "$2" = "nfs" ]; then
  printf 'Filesystem 512-blocks Used Available Capacity Mounted on\n'
  printf 'nfs-test 100 1 99 1%% /tmp\n'
  exit 0
fi
exit 1
EOF
chmod +x "$NFS_FS_BIN/stat" "$NFS_FS_BIN/df"
BOOT_NFS_FS_HOME="$TMP_ROOT/bootstrap-nfs-fs-home"
BOOT_NFS_FS_CODEX="$BOOT_NFS_FS_HOME/codex"
BOOT_NFS_FS_CLAUDE="$BOOT_NFS_FS_HOME/claude"
BOOT_NFS_FS_CONFIG="$BOOT_NFS_FS_HOME/triparty-config"
BOOT_NFS_FS_BIN="$BOOT_NFS_FS_HOME/bin"
mkdir -p "$BOOT_NFS_FS_HOME"
run_expect fail "global_bootstrap_nfs_df_candidate_fallback_fails_closed" env PATH="$NFS_FS_BIN:$PATH" HOME="$BOOT_NFS_FS_HOME" CODEX_HOME="$BOOT_NFS_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_NFS_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_NFS_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_NFS_FS_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_UNVERIFIED_FS' "$TMP_ROOT/global_bootstrap_nfs_df_candidate_fallback_fails_closed.out" \
  && grep -q 'nfs filesystems' "$TMP_ROOT/global_bootstrap_nfs_df_candidate_fallback_fails_closed.out" \
  && [ ! -e "$BOOT_NFS_FS_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_nfs_df_candidate_fallback_fail_closed_verified\n'
else
  printf 'FAIL: global_bootstrap_nfs_df_candidate_fallback_fail_closed_verified\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_bootstrap_nfs_df_candidate_fallback_fails_closed.out" >&2
  FAILED=1
fi

if [ "$(uname -s 2>/dev/null || printf unknown)" = "Darwin" ]; then
  DARWIN_STAT_FAIL_BIN="$TMP_ROOT/fake-darwin-stat-fail-bin"
  mkdir -p "$DARWIN_STAT_FAIL_BIN"
  cat > "$DARWIN_STAT_FAIL_BIN/stat" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
  chmod +x "$DARWIN_STAT_FAIL_BIN/stat"
  BOOT_DARWIN_FS_HOME="$TMP_ROOT/bootstrap-darwin-fs-home"
  BOOT_DARWIN_FS_CODEX="$BOOT_DARWIN_FS_HOME/codex"
  BOOT_DARWIN_FS_CLAUDE="$BOOT_DARWIN_FS_HOME/claude"
  BOOT_DARWIN_FS_CONFIG="$BOOT_DARWIN_FS_HOME/triparty-config"
  BOOT_DARWIN_FS_BIN="$BOOT_DARWIN_FS_HOME/bin"
  mkdir -p "$BOOT_DARWIN_FS_HOME"
  run_expect pass "global_bootstrap_darwin_df_candidate_fallback_installs" env PATH="$DARWIN_STAT_FAIL_BIN:$PATH" HOME="$BOOT_DARWIN_FS_HOME" CODEX_HOME="$BOOT_DARWIN_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_DARWIN_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_DARWIN_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_DARWIN_FS_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
  if [ -f "$BOOT_DARWIN_FS_CONFIG/managed-install.env" ] && [ -x "$BOOT_DARWIN_FS_BIN/triparty" ]; then
    printf 'PASS: global_bootstrap_darwin_df_candidate_fallback_verified\n'
  else
    printf 'FAIL: global_bootstrap_darwin_df_candidate_fallback_verified\n' >&2
    sed -n '1,180p' "$TMP_ROOT/global_bootstrap_darwin_df_candidate_fallback_installs.out" >&2
    FAILED=1
  fi
  run_expect pass "global_uninstall_darwin_df_candidate_fallback_cleans" env PATH="$DARWIN_STAT_FAIL_BIN:$PATH" HOME="$BOOT_DARWIN_FS_HOME" CODEX_HOME="$BOOT_DARWIN_FS_CODEX" CLAUDE_CONFIG_DIR="$BOOT_DARWIN_FS_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_DARWIN_FS_CONFIG" TRIPARTY_BIN_DIR="$BOOT_DARWIN_FS_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
  if [ ! -e "$BOOT_DARWIN_FS_BIN/triparty" ] && [ ! -e "$BOOT_DARWIN_FS_CONFIG/managed-install.env" ]; then
    printf 'PASS: global_uninstall_darwin_df_candidate_fallback_verified\n'
  else
    printf 'FAIL: global_uninstall_darwin_df_candidate_fallback_verified\n' >&2
    sed -n '1,180p' "$TMP_ROOT/global_uninstall_darwin_df_candidate_fallback_cleans.out" >&2
    FAILED=1
  fi
else
  printf 'PASS: global_bootstrap_darwin_df_candidate_fallback_installs_skipped_non_darwin\n'
fi

BOOT_LOCK_HOME="$TMP_ROOT/bootstrap-lock-home"
BOOT_LOCK_CODEX="$BOOT_LOCK_HOME/codex"
BOOT_LOCK_CLAUDE="$BOOT_LOCK_HOME/claude"
BOOT_LOCK_CONFIG="$BOOT_LOCK_HOME/triparty-config"
BOOT_LOCK_BIN="$BOOT_LOCK_HOME/bin"
mkdir -p "$BOOT_LOCK_HOME" "$BOOT_LOCK_CONFIG"
BOOT_LOCK_DIR="$(managed_lock_dir "$BOOT_LOCK_CONFIG")"
mkdir -p "$BOOT_LOCK_DIR"
run_expect fail "global_bootstrap_lock_blocks_concurrent_install" env HOME="$BOOT_LOCK_HOME" CODEX_HOME="$BOOT_LOCK_CODEX" CLAUDE_CONFIG_DIR="$BOOT_LOCK_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_LOCK_CONFIG" TRIPARTY_BIN_DIR="$BOOT_LOCK_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_lock_blocks_concurrent_install.out" \
  && [ ! -e "$BOOT_LOCK_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_lock_boundary\n'
else
  printf 'FAIL: global_bootstrap_lock_boundary\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_bootstrap_lock_blocks_concurrent_install.out" >&2
  FAILED=1
fi
run_expect fail "global_uninstall_lock_blocks_concurrent_cleanup" env HOME="$BOOT_LOCK_HOME" CODEX_HOME="$BOOT_LOCK_CODEX" CLAUDE_CONFIG_DIR="$BOOT_LOCK_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_LOCK_CONFIG" TRIPARTY_BIN_DIR="$BOOT_LOCK_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if grep -q 'E_LOCKED' "$TMP_ROOT/global_uninstall_lock_blocks_concurrent_cleanup.out"; then
  printf 'PASS: global_uninstall_lock_boundary\n'
else
  printf 'FAIL: global_uninstall_lock_boundary\n' >&2
  sed -n '1,160p' "$TMP_ROOT/global_uninstall_lock_blocks_concurrent_cleanup.out" >&2
  FAILED=1
fi

BOOT_STALE_HOME="$TMP_ROOT/bootstrap-stale-lock-home"
BOOT_STALE_CODEX="$BOOT_STALE_HOME/codex"
BOOT_STALE_CLAUDE="$BOOT_STALE_HOME/claude"
BOOT_STALE_CONFIG="$BOOT_STALE_HOME/triparty-config"
BOOT_STALE_BIN="$BOOT_STALE_HOME/bin"
mkdir -p "$BOOT_STALE_HOME" "$BOOT_STALE_CONFIG"
BOOT_STALE_LOCK_DIR="$(managed_lock_dir "$BOOT_STALE_CONFIG")"
mkdir -p "$BOOT_STALE_LOCK_DIR"
cat > "$BOOT_STALE_LOCK_DIR/owner.env" <<EOF
SCHEMA=agentparty.managed-install-lock.v1
PID=999999
HOSTNAME=$(hostname 2>/dev/null || printf 'unknown')
CONFIG_DIR=$BOOT_STALE_CONFIG
LOCK_SOURCE=$(normalize_lock_path_for_test "$BOOT_STALE_CONFIG")
PROCESS_STARTED_AT=stale-process
CREATED_AT=2026-06-01T00:00:00Z
EOF
run_expect pass "global_bootstrap_recovers_stale_lock" env HOME="$BOOT_STALE_HOME" CODEX_HOME="$BOOT_STALE_CODEX" CLAUDE_CONFIG_DIR="$BOOT_STALE_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_STALE_CONFIG" TRIPARTY_BIN_DIR="$BOOT_STALE_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'Recover stale AgentParty managed install lock' "$TMP_ROOT/global_bootstrap_recovers_stale_lock.out" \
  && [ -x "$BOOT_STALE_BIN/triparty" ] \
  && [ ! -d "$BOOT_STALE_LOCK_DIR" ]; then
  printf 'PASS: global_bootstrap_stale_lock_recovery_verified\n'
else
  printf 'FAIL: global_bootstrap_stale_lock_recovery_verified\n' >&2
  find "$BOOT_STALE_HOME" -maxdepth 4 -type f -print >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_recovers_stale_lock.out" >&2
  FAILED=1
fi

BOOT_LIVE_HOME="$TMP_ROOT/bootstrap-live-lock-home"
BOOT_LIVE_CODEX="$BOOT_LIVE_HOME/codex"
BOOT_LIVE_CLAUDE="$BOOT_LIVE_HOME/claude"
BOOT_LIVE_CONFIG="$BOOT_LIVE_HOME/triparty-config"
BOOT_LIVE_BIN="$BOOT_LIVE_HOME/bin"
mkdir -p "$BOOT_LIVE_HOME" "$BOOT_LIVE_CONFIG"
BOOT_LIVE_LOCK_DIR="$(managed_lock_dir "$BOOT_LIVE_CONFIG")"
mkdir -p "$BOOT_LIVE_LOCK_DIR"
cat > "$BOOT_LIVE_LOCK_DIR/owner.env" <<EOF
SCHEMA=agentparty.managed-install-lock.v1
LOCK_OWNER_ID=live-owner
PID=$$
HOSTNAME=$(hostname 2>/dev/null || printf 'unknown')
CONFIG_DIR=$BOOT_LIVE_CONFIG
LOCK_SOURCE=$(normalize_lock_path_for_test "$BOOT_LIVE_CONFIG")
PROCESS_STARTED_AT=deliberately-not-current
PROCESS_IDENTITY=live-test
BOOT_ID=$(current_boot_id_for_test)
CREATED_AT=2026-06-01T00:00:00Z
EOF
run_expect fail "global_bootstrap_live_pid_lock_fails_safe" env HOME="$BOOT_LIVE_HOME" CODEX_HOME="$BOOT_LIVE_CODEX" CLAUDE_CONFIG_DIR="$BOOT_LIVE_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_LIVE_CONFIG" TRIPARTY_BIN_DIR="$BOOT_LIVE_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_live_pid_lock_fails_safe.out" \
  && [ -d "$BOOT_LIVE_LOCK_DIR" ] \
  && [ ! -e "$BOOT_LIVE_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_live_pid_lock_fails_safe_verified\n'
else
  printf 'FAIL: global_bootstrap_live_pid_lock_fails_safe_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_live_pid_lock_fails_safe.out" >&2
  FAILED=1
fi

BOOT_FOREIGN_HOME="$TMP_ROOT/bootstrap-foreign-lock-home"
BOOT_FOREIGN_CODEX="$BOOT_FOREIGN_HOME/codex"
BOOT_FOREIGN_CLAUDE="$BOOT_FOREIGN_HOME/claude"
BOOT_FOREIGN_CONFIG="$BOOT_FOREIGN_HOME/triparty-config"
BOOT_FOREIGN_BIN="$BOOT_FOREIGN_HOME/bin"
mkdir -p "$BOOT_FOREIGN_HOME" "$BOOT_FOREIGN_CONFIG"
BOOT_FOREIGN_LOCK_DIR="$(managed_lock_dir "$BOOT_FOREIGN_CONFIG")"
mkdir -p "$BOOT_FOREIGN_LOCK_DIR"
cat > "$BOOT_FOREIGN_LOCK_DIR/owner.env" <<EOF
SCHEMA=agentparty.managed-install-lock.v1
LOCK_OWNER_ID=foreign-owner
PID=999999
HOSTNAME=agentparty-foreign-host
CONFIG_DIR=$BOOT_FOREIGN_CONFIG
LOCK_SOURCE=$(normalize_lock_path_for_test "$BOOT_FOREIGN_CONFIG")
PROCESS_STARTED_AT=stale-process
PROCESS_IDENTITY=foreign-test
BOOT_ID=$(current_boot_id_for_test)
CREATED_AT=2026-06-01T00:00:00Z
EOF
run_expect fail "global_bootstrap_foreign_host_lock_fails_safe" env HOME="$BOOT_FOREIGN_HOME" CODEX_HOME="$BOOT_FOREIGN_CODEX" CLAUDE_CONFIG_DIR="$BOOT_FOREIGN_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_FOREIGN_CONFIG" TRIPARTY_BIN_DIR="$BOOT_FOREIGN_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_foreign_host_lock_fails_safe.out" \
  && [ -d "$BOOT_FOREIGN_LOCK_DIR" ] \
  && [ ! -e "$BOOT_FOREIGN_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_foreign_host_lock_fails_safe_verified\n'
else
  printf 'FAIL: global_bootstrap_foreign_host_lock_fails_safe_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_foreign_host_lock_fails_safe.out" >&2
  FAILED=1
fi

BOOT_EQ_HOME="$TMP_ROOT/bootstrap-lock-equivalence-home"
BOOT_EQ_CODEX="$BOOT_EQ_HOME/codex"
BOOT_EQ_CLAUDE="$BOOT_EQ_HOME/claude"
BOOT_EQ_CONFIG="$BOOT_EQ_HOME/triparty-config"
BOOT_EQ_BIN="$BOOT_EQ_HOME/bin"
mkdir -p "$BOOT_EQ_HOME" "$BOOT_EQ_CONFIG"
BOOT_EQ_LOCK_DIR="$(managed_lock_dir "$BOOT_EQ_CONFIG")"
mkdir -p "$BOOT_EQ_LOCK_DIR"
run_expect fail "global_bootstrap_config_trailing_slash_lock_equivalence" env HOME="$BOOT_EQ_HOME" CODEX_HOME="$BOOT_EQ_CODEX" CLAUDE_CONFIG_DIR="$BOOT_EQ_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_EQ_CONFIG/" TRIPARTY_BIN_DIR="$BOOT_EQ_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_config_trailing_slash_lock_equivalence.out" \
  && [ ! -e "$BOOT_EQ_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_config_trailing_slash_lock_equivalence_verified\n'
else
  printf 'FAIL: global_bootstrap_config_trailing_slash_lock_equivalence_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_config_trailing_slash_lock_equivalence.out" >&2
  FAILED=1
fi

BOOT_REL_HOME="$TMP_ROOT/bootstrap-lock-relative-home"
BOOT_REL_CODEX="$BOOT_REL_HOME/codex"
BOOT_REL_CLAUDE="$BOOT_REL_HOME/claude"
BOOT_REL_CONFIG="$BOOT_REL_HOME/triparty-config"
BOOT_REL_BIN="$BOOT_REL_HOME/bin"
mkdir -p "$BOOT_REL_HOME/sub" "$BOOT_REL_CONFIG"
BOOT_REL_LOCK_DIR="$(managed_lock_dir "$BOOT_REL_CONFIG")"
mkdir -p "$BOOT_REL_LOCK_DIR"
run_expect fail "global_bootstrap_relative_parent_lock_equivalence" env HOME="$BOOT_REL_HOME" CODEX_HOME="$BOOT_REL_CODEX" CLAUDE_CONFIG_DIR="$BOOT_REL_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_REL_HOME/sub/../triparty-config" TRIPARTY_BIN_DIR="$BOOT_REL_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_relative_parent_lock_equivalence.out" \
  && [ ! -e "$BOOT_REL_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_relative_parent_lock_equivalence_verified\n'
else
  printf 'FAIL: global_bootstrap_relative_parent_lock_equivalence_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_relative_parent_lock_equivalence.out" >&2
  FAILED=1
fi

BOOT_SYM_HOME="$TMP_ROOT/bootstrap-lock-symlink-home"
BOOT_SYM_CODEX="$BOOT_SYM_HOME/codex"
BOOT_SYM_CLAUDE="$BOOT_SYM_HOME/claude"
BOOT_SYM_REAL_CONFIG="$BOOT_SYM_HOME/real-triparty-config"
BOOT_SYM_LINK_CONFIG="$BOOT_SYM_HOME/link-triparty-config"
BOOT_SYM_BIN="$BOOT_SYM_HOME/bin"
mkdir -p "$BOOT_SYM_HOME" "$BOOT_SYM_REAL_CONFIG"
ln -s "$BOOT_SYM_REAL_CONFIG" "$BOOT_SYM_LINK_CONFIG"
BOOT_SYM_LOCK_DIR="$(managed_lock_dir "$BOOT_SYM_REAL_CONFIG")"
mkdir -p "$BOOT_SYM_LOCK_DIR"
run_expect fail "global_bootstrap_symlink_config_lock_equivalence" env HOME="$BOOT_SYM_HOME" CODEX_HOME="$BOOT_SYM_CODEX" CLAUDE_CONFIG_DIR="$BOOT_SYM_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_SYM_LINK_CONFIG" TRIPARTY_BIN_DIR="$BOOT_SYM_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_symlink_config_lock_equivalence.out" \
  && [ ! -e "$BOOT_SYM_REAL_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_symlink_config_lock_equivalence_verified\n'
else
  printf 'FAIL: global_bootstrap_symlink_config_lock_equivalence_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_symlink_config_lock_equivalence.out" >&2
  FAILED=1
fi

BOOT_ROOT_EQ_HOME="$TMP_ROOT/bootstrap-lock-root-equivalence-home"
BOOT_ROOT_EQ_CODEX="$BOOT_ROOT_EQ_HOME/codex"
BOOT_ROOT_EQ_CLAUDE="$BOOT_ROOT_EQ_HOME/claude"
BOOT_ROOT_EQ_CONFIG="$BOOT_ROOT_EQ_HOME/triparty-config"
BOOT_ROOT_EQ_BIN="$BOOT_ROOT_EQ_HOME/bin"
mkdir -p "$BOOT_ROOT_EQ_HOME" "$BOOT_ROOT_EQ_CONFIG"
BOOT_ROOT_EQ_LOCK_DIR="$(managed_lock_dir "$BOOT_ROOT_EQ_CONFIG")"
mkdir -p "$BOOT_ROOT_EQ_LOCK_DIR"
run_expect fail "global_bootstrap_lock_root_trailing_slash_equivalence" env AGENTPARTY_LOCK_DIR="$AGENTPARTY_LOCK_DIR/" HOME="$BOOT_ROOT_EQ_HOME" CODEX_HOME="$BOOT_ROOT_EQ_CODEX" CLAUDE_CONFIG_DIR="$BOOT_ROOT_EQ_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_ROOT_EQ_CONFIG" TRIPARTY_BIN_DIR="$BOOT_ROOT_EQ_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if grep -q 'E_LOCKED' "$TMP_ROOT/global_bootstrap_lock_root_trailing_slash_equivalence.out" \
  && [ ! -e "$BOOT_ROOT_EQ_CONFIG/managed-install.env" ]; then
  printf 'PASS: global_bootstrap_lock_root_trailing_slash_equivalence_verified\n'
else
  printf 'FAIL: global_bootstrap_lock_root_trailing_slash_equivalence_verified\n' >&2
  sed -n '1,180p' "$TMP_ROOT/global_bootstrap_lock_root_trailing_slash_equivalence.out" >&2
  FAILED=1
fi

BOOT_HOME="$TMP_ROOT/bootstrap-home"
BOOT_CODEX="$BOOT_HOME/codex"
BOOT_CLAUDE="$BOOT_HOME/claude"
BOOT_CONFIG="$BOOT_HOME/triparty-config"
BOOT_BIN="$BOOT_HOME/bin"
mkdir -p "$BOOT_HOME"
run_expect pass "global_bootstrap_installs_temp_artifacts" env HOME="$BOOT_HOME" CODEX_HOME="$BOOT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
if [ -x "$BOOT_BIN/triparty" ] \
  && [ -x "$BOOT_BIN/agentparty" ] \
  && [ -f "$BOOT_CONFIG/config" ] \
  && [ -f "$BOOT_CONFIG/managed-install.env" ] \
  && [ -f "$BOOT_CLAUDE/commands/agentparty-claw.md" ] \
  && [ -f "$BOOT_CLAUDE/commands/ap-claw.md" ] \
  && grep -q 'SCHEMA=agentparty.managed-install.v1' "$BOOT_CONFIG/managed-install.env" \
  && grep -q 'CLAUDE_AGENTPARTY_CLAW_COMMAND_SHA256=' "$BOOT_CONFIG/managed-install.env" \
  && grep -q 'CLAUDE_AP_CLAW_COMMAND_SHA256=' "$BOOT_CONFIG/managed-install.env" \
  && grep -q 'AGENTPARTY_MANAGED_COMMAND: agentparty-claw' "$BOOT_CLAUDE/commands/agentparty-claw.md" \
  && grep -q 'AGENTPARTY_MANAGED_COMMAND: ap-claw' "$BOOT_CLAUDE/commands/ap-claw.md" \
  && grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_CODEX/AGENTS.md" \
  && grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_CLAUDE/CLAUDE.md" \
  && grep -q '/agentparty-claw' "$BOOT_CLAUDE/CLAUDE.md"; then
  printf 'PASS: global_bootstrap_temp_artifacts_present\n'
else
  printf 'FAIL: global_bootstrap_temp_artifacts_present\n' >&2
  find "$BOOT_HOME" -maxdepth 4 -type f -print >&2
  FAILED=1
fi
run_expect pass "global_uninstall_dry_run_keeps_artifacts" env HOME="$BOOT_HOME" CODEX_HOME="$BOOT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --dry-run
if [ -x "$BOOT_BIN/triparty" ] && grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_CODEX/AGENTS.md"; then
  printf 'PASS: global_uninstall_dry_run_noop_verified\n'
else
  printf 'FAIL: global_uninstall_dry_run_noop_verified\n' >&2
  FAILED=1
fi
run_expect pass "global_uninstall_execute_removes_managed_artifacts" env HOME="$BOOT_HOME" CODEX_HOME="$BOOT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ ! -e "$BOOT_BIN/triparty" ] \
  && [ ! -e "$BOOT_BIN/agentparty" ] \
  && [ ! -e "$BOOT_CONFIG/config" ] \
  && [ ! -d "$BOOT_CONFIG" ] \
  && [ ! -e "$BOOT_CONFIG/managed-install.env" ] \
  && ! grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_CODEX/AGENTS.md" \
  && ! grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_CLAUDE/CLAUDE.md" \
  && [ ! -e "$BOOT_CLAUDE/commands/triparty.md" ] \
  && [ ! -e "$BOOT_CLAUDE/commands/tp.md" ] \
  && [ ! -e "$BOOT_CLAUDE/commands/agentparty-claw.md" ] \
  && [ ! -e "$BOOT_CLAUDE/commands/ap-claw.md" ]; then
  printf 'PASS: global_uninstall_execute_cleanup_verified\n'
else
  printf 'FAIL: global_uninstall_execute_cleanup_verified\n' >&2
  find "$BOOT_HOME" -maxdepth 4 -type f -print >&2
  FAILED=1
fi
run_expect pass "global_uninstall_execute_is_idempotent" env HOME="$BOOT_HOME" CODEX_HOME="$BOOT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute

BOOT_INTERRUPT_HOME="$TMP_ROOT/bootstrap-interrupted-cleanup-home"
BOOT_INTERRUPT_CODEX="$BOOT_INTERRUPT_HOME/codex"
BOOT_INTERRUPT_CLAUDE="$BOOT_INTERRUPT_HOME/claude"
BOOT_INTERRUPT_CONFIG="$BOOT_INTERRUPT_HOME/triparty-config"
BOOT_INTERRUPT_BIN="$BOOT_INTERRUPT_HOME/bin"
mkdir -p "$BOOT_INTERRUPT_HOME"
run_expect pass "global_bootstrap_installs_interrupted_cleanup_fixture" env HOME="$BOOT_INTERRUPT_HOME" CODEX_HOME="$BOOT_INTERRUPT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_INTERRUPT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_INTERRUPT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_INTERRUPT_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
rm -f "$BOOT_INTERRUPT_BIN/triparty" "$BOOT_INTERRUPT_CLAUDE/commands/tp.md"
run_expect pass "global_uninstall_resumes_after_interrupted_cleanup" env HOME="$BOOT_INTERRUPT_HOME" CODEX_HOME="$BOOT_INTERRUPT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_INTERRUPT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_INTERRUPT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_INTERRUPT_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ ! -e "$BOOT_INTERRUPT_BIN/triparty" ] \
  && [ ! -e "$BOOT_INTERRUPT_BIN/agentparty" ] \
  && [ ! -e "$BOOT_INTERRUPT_CONFIG/config" ] \
  && [ ! -d "$BOOT_INTERRUPT_CONFIG" ] \
  && [ ! -e "$BOOT_INTERRUPT_CONFIG/managed-install.env" ] \
  && [ ! -e "$BOOT_INTERRUPT_CLAUDE/commands/triparty.md" ] \
  && [ ! -e "$BOOT_INTERRUPT_CLAUDE/commands/tp.md" ] \
  && [ ! -e "$BOOT_INTERRUPT_CLAUDE/commands/agentparty-claw.md" ] \
  && [ ! -e "$BOOT_INTERRUPT_CLAUDE/commands/ap-claw.md" ] \
  && ! grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_INTERRUPT_CODEX/AGENTS.md" \
  && ! grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_INTERRUPT_CLAUDE/CLAUDE.md"; then
  printf 'PASS: global_uninstall_interrupted_cleanup_resume_verified\n'
else
  printf 'FAIL: global_uninstall_interrupted_cleanup_resume_verified\n' >&2
  find "$BOOT_INTERRUPT_HOME" -maxdepth 4 -type f -print >&2
  sed -n '1,180p' "$TMP_ROOT/global_uninstall_resumes_after_interrupted_cleanup.out" >&2
  FAILED=1
fi

BOOT_LEGACY_HOME="$TMP_ROOT/bootstrap-legacy-claw-home"
BOOT_LEGACY_CODEX="$BOOT_LEGACY_HOME/codex"
BOOT_LEGACY_CLAUDE="$BOOT_LEGACY_HOME/claude"
BOOT_LEGACY_CONFIG="$BOOT_LEGACY_HOME/triparty-config"
BOOT_LEGACY_BIN="$BOOT_LEGACY_HOME/bin"
mkdir -p "$BOOT_LEGACY_CLAUDE/commands" "$BOOT_LEGACY_CODEX" "$BOOT_LEGACY_CONFIG" "$BOOT_LEGACY_BIN"
cat > "$BOOT_LEGACY_CLAUDE/commands/agentparty-claw.md" <<'EOF'
---
description: Create or inspect a Claude Code + Feishu Claw AgentParty handoff kit.
---
Use the existing AgentParty portable framework.
Do not set or claim `true_triparty_ready=true`.
EOF
cat > "$BOOT_LEGACY_CLAUDE/commands/ap-claw.md" <<'EOF'
---
description: Short alias for /agentparty-claw.
---
Run the same workflow as `/agentparty-claw` with these arguments.
Do not claim `true_triparty_ready=true`.
EOF
run_expect pass "global_uninstall_cleans_legacy_claw_commands" env HOME="$BOOT_LEGACY_HOME" CODEX_HOME="$BOOT_LEGACY_CODEX" CLAUDE_CONFIG_DIR="$BOOT_LEGACY_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_LEGACY_CONFIG" TRIPARTY_BIN_DIR="$BOOT_LEGACY_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ ! -e "$BOOT_LEGACY_CLAUDE/commands/agentparty-claw.md" ] \
  && [ ! -e "$BOOT_LEGACY_CLAUDE/commands/ap-claw.md" ] \
  && grep -q 'remove managed historical Claude AgentParty Claw command file' "$TMP_ROOT/global_uninstall_cleans_legacy_claw_commands.out" \
  && grep -q 'remove managed historical Claude ap-claw command file' "$TMP_ROOT/global_uninstall_cleans_legacy_claw_commands.out"; then
  printf 'PASS: global_uninstall_legacy_claw_cleanup_verified\n'
else
  printf 'FAIL: global_uninstall_legacy_claw_cleanup_verified\n' >&2
  find "$BOOT_LEGACY_HOME" -maxdepth 4 -type f -print >&2
  sed -n '1,160p' "$TMP_ROOT/global_uninstall_cleans_legacy_claw_commands.out" >&2
  FAILED=1
fi

BOOT_ABSENT_HOME="$TMP_ROOT/bootstrap-absent-manifest-home"
BOOT_ABSENT_CODEX="$BOOT_ABSENT_HOME/codex"
BOOT_ABSENT_CLAUDE="$BOOT_ABSENT_HOME/claude"
BOOT_ABSENT_CONFIG="$BOOT_ABSENT_HOME/triparty-config"
BOOT_ABSENT_BIN="$BOOT_ABSENT_HOME/bin"
mkdir -p "$BOOT_ABSENT_CLAUDE/commands" "$BOOT_ABSENT_CODEX" "$BOOT_ABSENT_CONFIG" "$BOOT_ABSENT_BIN"
cat > "$BOOT_ABSENT_CLAUDE/commands/agentparty-claw.md" <<'EOF'
---
description: Create or inspect a Claude Code + Feishu Claw AgentParty handoff kit.
---
Use the existing AgentParty portable framework.
Do not set or claim `true_triparty_ready=true`.
EOF
cat > "$BOOT_ABSENT_CONFIG/managed-install.env" <<EOF
SCHEMA=agentparty.managed-install.v1
ROOT_DIR=$ROOT_DIR
CLAUDE_AGENTPARTY_CLAW_COMMAND_PATH=$BOOT_ABSENT_CLAUDE/commands/agentparty-claw.md
CLAUDE_AGENTPARTY_CLAW_COMMAND_STATE=absent
CLAUDE_AGENTPARTY_CLAW_COMMAND_SHA256=ABSENT
EOF
run_expect pass "global_uninstall_respects_absent_manifest_state" env HOME="$BOOT_ABSENT_HOME" CODEX_HOME="$BOOT_ABSENT_CODEX" CLAUDE_CONFIG_DIR="$BOOT_ABSENT_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_ABSENT_CONFIG" TRIPARTY_BIN_DIR="$BOOT_ABSENT_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ -f "$BOOT_ABSENT_CLAUDE/commands/agentparty-claw.md" ] \
  && grep -q 'Skip Claude AgentParty Claw command because install manifest records it absent' "$TMP_ROOT/global_uninstall_respects_absent_manifest_state.out"; then
  printf 'PASS: global_uninstall_absent_manifest_preserves_file\n'
else
  printf 'FAIL: global_uninstall_absent_manifest_preserves_file\n' >&2
  find "$BOOT_ABSENT_HOME" -maxdepth 4 -type f -print >&2
  sed -n '1,160p' "$TMP_ROOT/global_uninstall_respects_absent_manifest_state.out" >&2
  FAILED=1
fi

BOOT_MOD_HOME="$TMP_ROOT/bootstrap-modified-home"
BOOT_MOD_CODEX="$BOOT_MOD_HOME/codex"
BOOT_MOD_CLAUDE="$BOOT_MOD_HOME/claude"
BOOT_MOD_CONFIG="$BOOT_MOD_HOME/triparty-config"
BOOT_MOD_BIN="$BOOT_MOD_HOME/bin"
mkdir -p "$BOOT_MOD_HOME"
run_expect pass "global_bootstrap_installs_modified_skip_fixture" env HOME="$BOOT_MOD_HOME" CODEX_HOME="$BOOT_MOD_CODEX" CLAUDE_CONFIG_DIR="$BOOT_MOD_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_MOD_CONFIG" TRIPARTY_BIN_DIR="$BOOT_MOD_BIN" "$ROOT_DIR/scripts/install-triparty-global-bootstrap.sh"
printf '\n# user customization\n' >> "$BOOT_MOD_CLAUDE/commands/triparty.md"
printf '\n# user customization\n' >> "$BOOT_MOD_CLAUDE/commands/agentparty-claw.md"
run_expect pass "global_uninstall_skips_modified_claude_command" env HOME="$BOOT_MOD_HOME" CODEX_HOME="$BOOT_MOD_CODEX" CLAUDE_CONFIG_DIR="$BOOT_MOD_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_MOD_CONFIG" TRIPARTY_BIN_DIR="$BOOT_MOD_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ -f "$BOOT_MOD_CLAUDE/commands/triparty.md" ] \
  && [ -f "$BOOT_MOD_CLAUDE/commands/agentparty-claw.md" ] \
  && grep -q 'user customization' "$BOOT_MOD_CLAUDE/commands/triparty.md" \
  && grep -q 'user customization' "$BOOT_MOD_CLAUDE/commands/agentparty-claw.md" \
  && grep -q 'Skip modified Claude triparty command file' "$TMP_ROOT/global_uninstall_skips_modified_claude_command.out" \
  && grep -q 'Skip modified Claude AgentParty Claw command file' "$TMP_ROOT/global_uninstall_skips_modified_claude_command.out"; then
  printf 'PASS: global_uninstall_modified_user_file_preserved\n'
else
  printf 'FAIL: global_uninstall_modified_user_file_preserved\n' >&2
  find "$BOOT_MOD_HOME" -maxdepth 4 -type f -print >&2
  sed -n '1,160p' "$TMP_ROOT/global_uninstall_skips_modified_claude_command.out" >&2
  FAILED=1
fi

BOOT_PARTIAL_HOME="$TMP_ROOT/bootstrap-partial-home"
BOOT_PARTIAL_CODEX="$BOOT_PARTIAL_HOME/codex"
BOOT_PARTIAL_CLAUDE="$BOOT_PARTIAL_HOME/claude"
BOOT_PARTIAL_CONFIG="$BOOT_PARTIAL_HOME/triparty-config"
BOOT_PARTIAL_BIN="$BOOT_PARTIAL_HOME/bin"
mkdir -p "$BOOT_PARTIAL_CODEX" "$BOOT_PARTIAL_CLAUDE" "$BOOT_PARTIAL_CONFIG" "$BOOT_PARTIAL_BIN"
cat > "$BOOT_PARTIAL_CODEX/AGENTS.md" <<EOF
# Global Codex Working Agreements
<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->
managed partial block
<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->
EOF
cat > "$BOOT_PARTIAL_BIN/triparty" <<EOF
#!/usr/bin/env bash
exec "$ROOT_DIR/scripts/triparty.sh" "\$@"
EOF
chmod +x "$BOOT_PARTIAL_BIN/triparty"
run_expect pass "global_uninstall_cleans_partial_install" env HOME="$BOOT_PARTIAL_HOME" CODEX_HOME="$BOOT_PARTIAL_CODEX" CLAUDE_CONFIG_DIR="$BOOT_PARTIAL_CLAUDE" TRIPARTY_CONFIG_DIR="$BOOT_PARTIAL_CONFIG" TRIPARTY_BIN_DIR="$BOOT_PARTIAL_BIN" "$ROOT_DIR/scripts/uninstall-triparty-global-bootstrap.sh" --execute
if [ ! -e "$BOOT_PARTIAL_BIN/triparty" ] \
  && [ ! -d "$BOOT_PARTIAL_CONFIG" ] \
  && ! grep -q 'BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP' "$BOOT_PARTIAL_CODEX/AGENTS.md"; then
  printf 'PASS: global_uninstall_partial_cleanup_verified\n'
else
  printf 'FAIL: global_uninstall_partial_cleanup_verified\n' >&2
  find "$BOOT_PARTIAL_HOME" -maxdepth 4 -type f -print >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_run_scaffolds_partial" env AGENTPARTY_RUNS_DIR="$AGENTPARTY_RUNS" "$AGENTPARTY" run --pack claude-code-feishu-claw --task "整理飞书发布检查清单"
CLAW_RUN="$(sed -n 's/^AgentParty pack run created: //p' "$TMP_ROOT/agentparty_claw_run_scaffolds_partial.out")"
if [ -n "$CLAW_RUN" ] && grep -q '"completion_label": "partial"' "$CLAW_RUN/state.json" && grep -q '"true_triparty_ready": false' "$CLAW_RUN/state.json"; then
  printf 'PASS: agentparty_claw_initial_state_is_partial\n'
else
  printf 'FAIL: agentparty_claw_initial_state_is_partial\n' >&2
  sed -n '1,160p' "$CLAW_RUN/state.json" 2>/dev/null >&2 || true
  FAILED=1
fi
run_expect pass "agentparty_claw_validate_partial_state" "$AGENTPARTY" validate-run --run-dir "$CLAW_RUN"
run_expect pass "agentparty_claw_guide_partial_next_steps" "$AGENTPARTY" guide --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --json
if grep -q '"next_label": "collect_claw_evidence"' "$TMP_ROOT/agentparty_claw_guide_partial_next_steps.out" \
  && grep -q 'evidence-template --pack claude-code-feishu-claw' "$TMP_ROOT/agentparty_claw_guide_partial_next_steps.out" \
  && grep -q '"true_triparty_ready": false' "$TMP_ROOT/agentparty_claw_guide_partial_next_steps.out"; then
  printf 'PASS: agentparty_claw_guide_partial_boundary\n'
else
  printf 'FAIL: agentparty_claw_guide_partial_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_guide_partial_next_steps.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_force_native_windows_allows_guide_prep" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" guide --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --json
if grep -q '"target_os": "windows_powershell"' "$TMP_ROOT/agentparty_force_native_windows_allows_guide_prep.out" \
  && grep -q 'Import filled bundle inside WSL2' "$TMP_ROOT/agentparty_force_native_windows_allows_guide_prep.out" \
  && grep -q 'native PowerShell evidence import is roadmap' "$TMP_ROOT/agentparty_force_native_windows_allows_guide_prep.out"; then
  printf 'PASS: agentparty_force_native_windows_guide_prep_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_guide_prep_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_force_native_windows_allows_guide_prep.out" >&2
  FAILED=1
fi
CLAW_BUNDLE="$TMP_ROOT/claw-evidence-bundle"
run_expect pass "agentparty_claw_evidence_template_creates_bundle" "$AGENTPARTY" evidence-template --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --out "$CLAW_BUNDLE"
if [ -f "$CLAW_BUNDLE/agentparty-claw-evidence.json" ] \
  && [ -f "$CLAW_BUNDLE/feishu-claw-transcript.txt" ] \
  && grep -q 'agentparty.claw-evidence-bundle.v1' "$CLAW_BUNDLE/agentparty-claw-evidence.json" \
  && grep -q 'TODO_AGENTPARTY_REPLACE' "$CLAW_BUNDLE/feishu-claw-transcript.txt"; then
  printf 'PASS: agentparty_claw_evidence_template_files_present\n'
else
  printf 'FAIL: agentparty_claw_evidence_template_files_present\n' >&2
  find "$CLAW_BUNDLE" -maxdepth 1 -type f -print >&2
  FAILED=1
fi
CLAW_NATIVE_BUNDLE="$TMP_ROOT/claw-native-prep-bundle"
run_expect pass "agentparty_force_native_windows_allows_evidence_template_prep" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" evidence-template --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --out "$CLAW_NATIVE_BUNDLE"
if [ -f "$CLAW_NATIVE_BUNDLE/agentparty-claw-evidence.json" ]; then
  printf 'PASS: agentparty_force_native_windows_evidence_template_prep_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_evidence_template_prep_boundary\n' >&2
  find "$CLAW_NATIVE_BUNDLE" -maxdepth 1 -type f -print >&2
  FAILED=1
fi
CLAW_FILL_BUNDLE="$TMP_ROOT/claw-evidence-fill-bundle"
run_expect pass "agentparty_claw_evidence_template_for_fill" "$AGENTPARTY" evidence-template --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --out "$CLAW_FILL_BUNDLE"
run_expect fail "agentparty_claw_evidence_fill_rejects_noop" "$AGENTPARTY" evidence-fill --pack claude-code-feishu-claw --bundle "$CLAW_FILL_BUNDLE/agentparty-claw-evidence.json"
if grep -q 'E_EVIDENCE_FILL_NOOP' "$TMP_ROOT/agentparty_claw_evidence_fill_rejects_noop.out"; then
  printf 'PASS: agentparty_claw_evidence_fill_noop_guard\n'
else
  printf 'FAIL: agentparty_claw_evidence_fill_noop_guard\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_claw_evidence_fill_rejects_noop.out" >&2
  FAILED=1
fi
printf 'Claw transcript: evidence-fill copied a real Feishu transcript with the returned document link.\n' > "$TMP_ROOT/evidence-fill-transcript.txt"
printf 'Operation summary: evidence-fill copied the Feishu operation summary with no unresolved blocker.\n' > "$TMP_ROOT/evidence-fill-summary.txt"
printf 'Claude review: evidence-fill copied Claude review and kept the run state partial before import.\n' > "$TMP_ROOT/evidence-fill-review.txt"
run_expect pass "agentparty_claw_evidence_fill_updates_bundle" "$AGENTPARTY" evidence-fill --pack claude-code-feishu-claw --bundle "$CLAW_FILL_BUNDLE/agentparty-claw-evidence.json" --feishu-link "https://example.feishu.cn/docx/fill" --claw-transcript "$TMP_ROOT/evidence-fill-transcript.txt" --operation-summary "$TMP_ROOT/evidence-fill-summary.txt" --claude-review "$TMP_ROOT/evidence-fill-review.txt" --json
if grep -q '"updated": true' "$TMP_ROOT/agentparty_claw_evidence_fill_updates_bundle.out" \
  && grep -q '"does_not_update_pack_state": true' "$CLAW_FILL_BUNDLE/agentparty-claw-evidence.json" \
  && grep -q 'https://example.feishu.cn/docx/fill' "$CLAW_FILL_BUNDLE/agentparty-claw-evidence.json" \
  && grep -q 'evidence-fill copied a real Feishu transcript' "$CLAW_FILL_BUNDLE/feishu-claw-transcript.txt" \
  && grep -q '"completion_label": "partial"' "$CLAW_RUN/state.json"; then
  printf 'PASS: agentparty_claw_evidence_fill_local_only_boundary\n'
else
  printf 'FAIL: agentparty_claw_evidence_fill_local_only_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_evidence_fill_updates_bundle.out" >&2
  sed -n '1,220p' "$CLAW_FILL_BUNDLE/agentparty-claw-evidence.json" >&2
  FAILED=1
fi
printf 'Claw transcript: native PowerShell prep copied a transcript but did not import evidence.\n' > "$TMP_ROOT/native-evidence-fill-transcript.txt"
printf 'Operation summary: native PowerShell prep copied summary text for later WSL2 import.\n' > "$TMP_ROOT/native-evidence-fill-summary.txt"
printf 'Claude review: native PowerShell prep copied review text for later WSL2 import.\n' > "$TMP_ROOT/native-evidence-fill-review.txt"
run_expect pass "agentparty_force_native_windows_allows_evidence_fill_prep" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" evidence-fill --pack claude-code-feishu-claw --bundle "$CLAW_NATIVE_BUNDLE/agentparty-claw-evidence.json" --feishu-link "https://example.feishu.cn/docx/native-fill" --claw-transcript "$TMP_ROOT/native-evidence-fill-transcript.txt" --operation-summary "$TMP_ROOT/native-evidence-fill-summary.txt" --claude-review "$TMP_ROOT/native-evidence-fill-review.txt" --json
if grep -q '"updated": true' "$TMP_ROOT/agentparty_force_native_windows_allows_evidence_fill_prep.out" \
  && grep -q 'local bundle update only' "$TMP_ROOT/agentparty_force_native_windows_allows_evidence_fill_prep.out" \
  && grep -q 'https://example.feishu.cn/docx/native-fill' "$CLAW_NATIVE_BUNDLE/agentparty-claw-evidence.json" \
  && grep -q '"completion_label": "partial"' "$CLAW_RUN/state.json"; then
  printf 'PASS: agentparty_force_native_windows_evidence_fill_prep_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_evidence_fill_prep_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_force_native_windows_allows_evidence_fill_prep.out" >&2
  sed -n '1,220p' "$CLAW_NATIVE_BUNDLE/agentparty-claw-evidence.json" >&2
  FAILED=1
fi
CLAW_KIT="$TMP_ROOT/claw-kit"
run_expect pass "agentparty_claw_kit_creates_portable_bundle" "$AGENTPARTY" kit --pack claude-code-feishu-claw --task "整理飞书 kit 证据" --out "$CLAW_KIT" --json
if [ -f "$CLAW_KIT/agentparty-claw-kit.json" ] \
  && [ -f "$CLAW_KIT/START_HERE.md" ] \
  && [ -f "$CLAW_KIT/state.json" ] \
  && [ -f "$CLAW_KIT/claude-code-prompt.txt" ] \
  && [ -f "$CLAW_KIT/feishu-claw-prompt.txt" ] \
  && [ -f "$CLAW_KIT/evidence/agentparty-claw-evidence.json" ] \
  && grep -q 'agentparty.claw-kit.v1' "$CLAW_KIT/agentparty-claw-kit.json" \
  && grep -q '"start_here":' "$CLAW_KIT/agentparty-claw-kit.json" \
  && grep -q 'copy order, evidence checklist, import commands, and boundaries' "$CLAW_KIT/README.md" \
  && grep -q '## Environment Check' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'claude-code-prompt.txt' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'feishu-claw-prompt.txt' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'evidence/agentparty-claw-evidence.json' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'evidence-fill --pack claude-code-feishu-claw' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'scripts/agentparty.sh evidence --pack claude-code-feishu-claw' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'scripts/agentparty.sh validate-run' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'WSL2/macOS/Linux' "$CLAW_KIT/START_HERE.md" \
  && grep -q 'keep `true_triparty_ready=false`' "$CLAW_KIT/START_HERE.md" \
  && grep -q '"completion_label": "partial"' "$CLAW_KIT/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_KIT/state.json"; then
  printf 'PASS: agentparty_claw_kit_files_present\n'
else
  printf 'FAIL: agentparty_claw_kit_files_present\n' >&2
  find "$CLAW_KIT" -maxdepth 2 -type f -print >&2
  sed -n '1,160p' "$CLAW_KIT/state.json" 2>/dev/null >&2 || true
  FAILED=1
fi
run_expect pass "agentparty_claw_kit_initial_state_valid" "$AGENTPARTY" validate-run --run-dir "$CLAW_KIT"
run_expect fail "agentparty_claw_kit_refuses_overwrite" "$AGENTPARTY" kit --pack claude-code-feishu-claw --task "整理飞书 kit 证据" --out "$CLAW_KIT"
CLAW_NATIVE_KIT="$TMP_ROOT/claw-native-kit"
run_expect pass "agentparty_force_native_windows_allows_claw_kit_prep" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" kit --pack claude-code-feishu-claw --task "整理飞书 native kit" --out "$CLAW_NATIVE_KIT" --json
if [ -f "$CLAW_NATIVE_KIT/agentparty-claw-kit.json" ] \
  && [ -f "$CLAW_NATIVE_KIT/START_HERE.md" ] \
  && grep -q '"native_powershell_kit_generation": "supported_local_scaffold"' "$CLAW_NATIVE_KIT/agentparty-claw-kit.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_NATIVE_KIT/state.json"; then
  printf 'PASS: agentparty_force_native_windows_claw_kit_prep_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_claw_kit_prep_boundary\n' >&2
  find "$CLAW_NATIVE_KIT" -maxdepth 2 -type f -print >&2
  FAILED=1
fi
CLAW_BRIDGE="$TMP_ROOT/claw-bridge"
run_expect pass "agentparty_claw_bridge_kit_creates_shared_state" "$AGENTPARTY" bridge-kit --pack claude-code-feishu-claw --task "飞书小龙虾总入口调起 Claude Code 并汇报" --out "$CLAW_BRIDGE" --json
if [ -f "$CLAW_BRIDGE/agentparty-claw-bridge.json" ] \
  && [ -f "$CLAW_BRIDGE/START_HERE.md" ] \
  && [ -f "$CLAW_BRIDGE/state.json" ] \
  && [ -f "$CLAW_BRIDGE/feishu-entry-message.md" ] \
  && [ -f "$CLAW_BRIDGE/claude-code-runner-prompt.txt" ] \
  && [ -f "$CLAW_BRIDGE/shared-resources/resource-manifest.json" ] \
  && [ -f "$CLAW_BRIDGE/shared-resources/skill-contract.md" ] \
  && [ -f "$CLAW_BRIDGE/shared-state/revision-log.md" ] \
  && grep -q 'agentparty.claw-bridge-kit.v1' "$CLAW_BRIDGE/agentparty-claw-bridge.json" \
  && grep -q 'agentparty.claw-bridge-state.v1' "$CLAW_BRIDGE/state.json" \
  && grep -q '"primary": "feishu_claw"' "$CLAW_BRIDGE/state.json" \
  && grep -q '"id": "claude-code"' "$CLAW_BRIDGE/state.json" \
  && grep -q '"one_active_writer": true' "$CLAW_BRIDGE/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_BRIDGE/state.json" \
  && grep -q 'Feishu Claw' "$CLAW_BRIDGE/START_HERE.md" \
  && grep -q 'controlled runner' "$CLAW_BRIDGE/START_HERE.md" \
  && grep -q 'not directly exposed as raw shell from Feishu' "$CLAW_BRIDGE/START_HERE.md"; then
  printf 'PASS: agentparty_claw_bridge_kit_files_present\n'
else
  printf 'FAIL: agentparty_claw_bridge_kit_files_present\n' >&2
  find "$CLAW_BRIDGE" -maxdepth 3 -type f -print >&2
  sed -n '1,220p' "$CLAW_BRIDGE/state.json" 2>/dev/null >&2 || true
  FAILED=1
fi
run_expect pass "agentparty_claw_bridge_validate_passes" "$AGENTPARTY" bridge-validate --bridge-dir "$CLAW_BRIDGE" --json
if grep -q '"valid": true' "$TMP_ROOT/agentparty_claw_bridge_validate_passes.out" \
  && grep -q '"entrypoint": "feishu_claw"' "$TMP_ROOT/agentparty_claw_bridge_validate_passes.out" \
  && grep -q '"runner": "claude-code"' "$TMP_ROOT/agentparty_claw_bridge_validate_passes.out" \
  && grep -q '"native_feishu_claw_connector": false' "$TMP_ROOT/agentparty_claw_bridge_validate_passes.out"; then
  printf 'PASS: agentparty_claw_bridge_validate_boundary\n'
else
  printf 'FAIL: agentparty_claw_bridge_validate_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_bridge_validate_passes.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_claw_bridge_refuses_overwrite" "$AGENTPARTY" bridge-kit --pack claude-code-feishu-claw --task "飞书小龙虾总入口调起 Claude Code 并汇报" --out "$CLAW_BRIDGE"
CLAW_NATIVE_BRIDGE="$TMP_ROOT/claw-native-bridge"
run_expect pass "agentparty_force_native_windows_allows_bridge_kit_prep" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" bridge-kit --pack claude-code-feishu-claw --task "native bridge prep" --out "$CLAW_NATIVE_BRIDGE" --json
if [ -f "$CLAW_NATIVE_BRIDGE/agentparty-claw-bridge.json" ] \
  && grep -q '"target_os": "windows_powershell"' "$CLAW_NATIVE_BRIDGE/state.json" \
  && grep -q '"direct_shell_from_feishu": false' "$CLAW_NATIVE_BRIDGE/state.json"; then
  printf 'PASS: agentparty_force_native_windows_bridge_kit_prep_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_bridge_kit_prep_boundary\n' >&2
  find "$CLAW_NATIVE_BRIDGE" -maxdepth 3 -type f -print >&2
  FAILED=1
fi
printf 'Claw transcript: completed the Feishu kit workflow and returned the document link.\n' > "$TMP_ROOT/kit-fill-transcript.txt"
printf 'Operation summary: kit workflow completed; no missing permission or unresolved blocker.\n' > "$TMP_ROOT/kit-fill-summary.txt"
printf 'Claude review: kit transcript satisfies the brief and evidence is sufficient for pack_ready.\n' > "$TMP_ROOT/kit-fill-review.txt"
run_expect pass "agentparty_claw_kit_evidence_fill_updates_bundle" "$AGENTPARTY" evidence-fill --pack claude-code-feishu-claw --bundle "$CLAW_KIT/evidence/agentparty-claw-evidence.json" --feishu-link "https://example.feishu.cn/docx/kit" --claw-transcript "$TMP_ROOT/kit-fill-transcript.txt" --operation-summary "$TMP_ROOT/kit-fill-summary.txt" --claude-review "$TMP_ROOT/kit-fill-review.txt" --json
if grep -q '"updated": true' "$TMP_ROOT/agentparty_claw_kit_evidence_fill_updates_bundle.out" \
  && grep -q 'https://example.feishu.cn/docx/kit' "$CLAW_KIT/evidence/agentparty-claw-evidence.json" \
  && grep -q 'completed the Feishu kit workflow' "$CLAW_KIT/evidence/feishu-claw-transcript.txt" \
  && grep -q '"completion_label": "partial"' "$CLAW_KIT/state.json"; then
  printf 'PASS: agentparty_claw_kit_evidence_fill_keeps_state_partial_before_import\n'
else
  printf 'FAIL: agentparty_claw_kit_evidence_fill_keeps_state_partial_before_import\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_kit_evidence_fill_updates_bundle.out" >&2
  sed -n '1,220p' "$CLAW_KIT/evidence/agentparty-claw-evidence.json" >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_kit_bundle_marks_pack_ready" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_KIT/evidence/agentparty-claw-evidence.json"
if grep -q '"completion_label": "pack_ready"' "$CLAW_KIT/state.json" \
  && grep -q '"pack_ready": true' "$CLAW_KIT/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_KIT/state.json" \
  && grep -q '"evidence_bundle"' "$CLAW_KIT/state.json"; then
  printf 'PASS: agentparty_claw_kit_ready_never_sets_true_triparty\n'
else
  printf 'FAIL: agentparty_claw_kit_ready_never_sets_true_triparty\n' >&2
  sed -n '1,220p' "$CLAW_KIT/state.json" >&2
  FAILED=1
fi
run_expect fail "agentparty_claw_evidence_template_refuses_overwrite" "$AGENTPARTY" evidence-template --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --out "$CLAW_BUNDLE"
run_expect fail "agentparty_force_native_windows_blocks_evidence_import" env AGENTPARTY_FORCE_NATIVE_WINDOWS=1 "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
if grep -q 'E_BLOCKED_OS' "$TMP_ROOT/agentparty_force_native_windows_blocks_evidence_import.out" \
  && grep -q 'Windows non-WSL AgentParty evidence import is roadmap' "$TMP_ROOT/agentparty_force_native_windows_blocks_evidence_import.out" \
  && grep -q 'wsl --install -d Ubuntu' "$TMP_ROOT/agentparty_force_native_windows_blocks_evidence_import.out"; then
  printf 'PASS: agentparty_force_native_windows_evidence_import_boundary\n'
else
  printf 'FAIL: agentparty_force_native_windows_evidence_import_boundary\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_force_native_windows_blocks_evidence_import.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_claw_evidence_rejects_unfilled_bundle" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
python3 - "$CLAW_BUNDLE/agentparty-claw-evidence.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["feishu_link"] = "not-a-url"
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
run_expect fail "agentparty_claw_evidence_rejects_invalid_link" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
python3 - "$CLAW_BUNDLE/agentparty-claw-evidence.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["feishu_link"] = "https://example.com/docx/not-feishu"
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
run_expect fail "agentparty_claw_evidence_rejects_non_feishu_link" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
run_expect fail "agentparty_claw_evidence_rejects_run_dir_mismatch" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --run-dir "$TMP_ROOT/mismatched-run-dir" --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
python3 - "$CLAW_BUNDLE/agentparty-claw-evidence.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["feishu_link"] = "https://example.feishu.cn/docx/checklist"
data["artifacts"]["feishu_claw_transcript"] = "../outside-transcript.txt"
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
printf 'Outside transcript should not be imported from outside the bundle directory.\n' > "$TMP_ROOT/outside-transcript.txt"
run_expect fail "agentparty_claw_evidence_rejects_bundle_path_traversal" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
python3 - "$CLAW_BUNDLE/agentparty-claw-evidence.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["artifacts"]["feishu_claw_transcript"] = "feishu-claw-transcript.txt"
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
printf 'x\n' > "$CLAW_BUNDLE/feishu-claw-transcript.txt"
printf 'x\n' > "$CLAW_BUNDLE/operation-summary.txt"
printf 'x\n' > "$CLAW_BUNDLE/claude-code-review.txt"
run_expect fail "agentparty_claw_evidence_rejects_tiny_bundle_files" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
printf 'Claw transcript: created a Feishu release checklist and returned the document link.\n' > "$CLAW_BUNDLE/feishu-claw-transcript.txt"
printf 'Operation summary: release checklist created; no missing permission.\n' > "$CLAW_BUNDLE/operation-summary.txt"
printf 'Claude review: transcript satisfies the task brief and evidence is sufficient.\n' > "$CLAW_BUNDLE/claude-code-review.txt"
run_expect pass "agentparty_claw_evidence_bundle_marks_pack_ready" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --bundle "$CLAW_BUNDLE/agentparty-claw-evidence.json"
if grep -q '"completion_label": "pack_ready"' "$CLAW_RUN/state.json" \
  && grep -q '"pack_ready": true' "$CLAW_RUN/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_RUN/state.json" \
  && grep -q '"evidence_bundle"' "$CLAW_RUN/state.json"; then
  printf 'PASS: agentparty_claw_bundle_ready_never_sets_true_triparty\n'
else
  printf 'FAIL: agentparty_claw_bundle_ready_never_sets_true_triparty\n' >&2
  sed -n '1,220p' "$CLAW_RUN/state.json" >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_guide_ready_next_steps" "$AGENTPARTY" guide --pack claude-code-feishu-claw --run-dir "$CLAW_RUN" --json
if grep -q '"next_label": "pack_ready_validate"' "$TMP_ROOT/agentparty_claw_guide_ready_next_steps.out" \
  && grep -q '"pack_ready": true' "$TMP_ROOT/agentparty_claw_guide_ready_next_steps.out" \
  && grep -q '"true_triparty_ready": false' "$TMP_ROOT/agentparty_claw_guide_ready_next_steps.out"; then
  printf 'PASS: agentparty_claw_guide_ready_boundary\n'
else
  printf 'FAIL: agentparty_claw_guide_ready_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_guide_ready_next_steps.out" >&2
  FAILED=1
fi

run_expect pass "agentparty_claw_run_for_direct_evidence" env AGENTPARTY_RUNS_DIR="$AGENTPARTY_RUNS" "$AGENTPARTY" run --pack claude-code-feishu-claw --task "整理飞书直接证据"
CLAW_DIRECT_RUN="$(sed -n 's/^AgentParty pack run created: //p' "$TMP_ROOT/agentparty_claw_run_for_direct_evidence.out")"
printf 'Claw transcript: created a Feishu direct-evidence checklist and returned the document link.\n' > "$TMP_ROOT/claw-transcript.txt"
printf 'Operation summary: direct evidence checklist created; no missing permission.\n' > "$TMP_ROOT/claw-summary.txt"
printf 'Claude review: direct evidence transcript satisfies the task brief.\n' > "$TMP_ROOT/claude-review.txt"
run_expect pass "agentparty_claw_direct_evidence_still_marks_pack_ready" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --run-dir "$CLAW_DIRECT_RUN" --feishu-link "https://example.feishu.cn/docx/direct" --claw-transcript "$TMP_ROOT/claw-transcript.txt" --operation-summary "$TMP_ROOT/claw-summary.txt" --claude-review "$TMP_ROOT/claude-review.txt"
if grep -q '"completion_label": "pack_ready"' "$CLAW_DIRECT_RUN/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_DIRECT_RUN/state.json"; then
  printf 'PASS: agentparty_claw_direct_ready_never_sets_true_triparty\n'
else
  printf 'FAIL: agentparty_claw_direct_ready_never_sets_true_triparty\n' >&2
  sed -n '1,220p' "$CLAW_DIRECT_RUN/state.json" >&2
  FAILED=1
fi

run_expect pass "agentparty_claw_run_for_blocked_state" env AGENTPARTY_RUNS_DIR="$AGENTPARTY_RUNS" "$AGENTPARTY" run --pack claude-code-feishu-claw --task "整理无权限飞书文档"
CLAW_BLOCKED_RUN="$(sed -n 's/^AgentParty pack run created: //p' "$TMP_ROOT/agentparty_claw_run_for_blocked_state.out")"
run_expect pass "agentparty_claw_evidence_marks_blocked" "$AGENTPARTY" evidence --pack claude-code-feishu-claw --run-dir "$CLAW_BLOCKED_RUN" --blocked-reason "Feishu permission missing; user confirmation required."
if grep -q '"completion_label": "blocked"' "$CLAW_BLOCKED_RUN/state.json" \
  && grep -q '"code": "E_CLAW_BLOCKED"' "$CLAW_BLOCKED_RUN/state.json" \
  && grep -q '"true_triparty_ready": false' "$CLAW_BLOCKED_RUN/state.json"; then
  printf 'PASS: agentparty_claw_blocked_never_sets_true_triparty\n'
else
  printf 'FAIL: agentparty_claw_blocked_never_sets_true_triparty\n' >&2
  sed -n '1,220p' "$CLAW_BLOCKED_RUN/state.json" >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_guide_blocked_next_steps" "$AGENTPARTY" guide --pack claude-code-feishu-claw --run-dir "$CLAW_BLOCKED_RUN" --json
if grep -q '"next_label": "resolve_blocker"' "$TMP_ROOT/agentparty_claw_guide_blocked_next_steps.out" \
  && grep -q '"status": "blocked"' "$TMP_ROOT/agentparty_claw_guide_blocked_next_steps.out" \
  && grep -q 'E_CLAW_BLOCKED' "$TMP_ROOT/agentparty_claw_guide_blocked_next_steps.out"; then
  printf 'PASS: agentparty_claw_guide_blocked_boundary\n'
else
  printf 'FAIL: agentparty_claw_guide_blocked_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_guide_blocked_next_steps.out" >&2
  FAILED=1
fi
run_expect pass "agentparty_claw_run_for_scoped_state" env AGENTPARTY_RUNS_DIR="$AGENTPARTY_RUNS" "$AGENTPARTY" run --pack claude-code-feishu-claw --task "整理范围限定结果"
CLAW_SCOPED_RUN="$(sed -n 's/^AgentParty pack run created: //p' "$TMP_ROOT/agentparty_claw_run_for_scoped_state.out")"
python3 - "$CLAW_SCOPED_RUN/state.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["pack_status"] = "scoped"
data["pack_ready"] = False
data["completion_label"] = "scoped"
data["true_triparty_ready"] = False
data["errors"] = []
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
run_expect pass "agentparty_claw_guide_scoped_next_steps" "$AGENTPARTY" guide --pack claude-code-feishu-claw --run-dir "$CLAW_SCOPED_RUN" --json
if grep -q '"next_label": "review_scope"' "$TMP_ROOT/agentparty_claw_guide_scoped_next_steps.out" \
  && grep -q '"status": "scoped"' "$TMP_ROOT/agentparty_claw_guide_scoped_next_steps.out" \
  && grep -q '"true_triparty_ready": false' "$TMP_ROOT/agentparty_claw_guide_scoped_next_steps.out"; then
  printf 'PASS: agentparty_claw_guide_scoped_boundary\n'
else
  printf 'FAIL: agentparty_claw_guide_scoped_boundary\n' >&2
  sed -n '1,220p' "$TMP_ROOT/agentparty_claw_guide_scoped_next_steps.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_write_state_blocks_non_triparty_true_ready" python3 -c 'import importlib.util, pathlib, sys; root=pathlib.Path(sys.argv[1]); run=pathlib.Path(sys.argv[2]); run.mkdir(parents=True, exist_ok=True); spec=importlib.util.spec_from_file_location("agentparty_write_guard", root / "scripts/agentparty.py"); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); module.write_state(run, {"schema_version":"agentparty.pack-state.v1","pack_id":"claude-code-feishu-claw","true_triparty_ready": True})' "$ROOT_DIR" "$TMP_ROOT/write-guard"
if grep -q 'E_TRUE_TRIPARTY_FORBIDDEN' "$TMP_ROOT/agentparty_write_state_blocks_non_triparty_true_ready.out"; then
  printf 'PASS: agentparty_write_state_true_triparty_guard\n'
else
  printf 'FAIL: agentparty_write_state_true_triparty_guard\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_write_state_blocks_non_triparty_true_ready.out" >&2
  FAILED=1
fi
run_expect fail "agentparty_write_state_rejects_unknown_pack_schema" python3 -c 'import importlib.util, pathlib, sys; root=pathlib.Path(sys.argv[1]); run=pathlib.Path(sys.argv[2]); run.mkdir(parents=True, exist_ok=True); spec=importlib.util.spec_from_file_location("agentparty_write_schema_guard", root / "scripts/agentparty.py"); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); module.write_state(run, {"schema_version":"agentparty.pack-state.v2","pack_id":"claude-code-feishu-claw","true_triparty_ready": True})' "$ROOT_DIR" "$TMP_ROOT/write-schema-guard"
if grep -q 'E_PACK_SCHEMA_UNKNOWN' "$TMP_ROOT/agentparty_write_state_rejects_unknown_pack_schema.out"; then
  printf 'PASS: agentparty_write_state_schema_guard\n'
else
  printf 'FAIL: agentparty_write_state_schema_guard\n' >&2
  sed -n '1,120p' "$TMP_ROOT/agentparty_write_state_rejects_unknown_pack_schema.out" >&2
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
run_expect pass "preflight_falls_back_when_default_runs_unwritable" env PATH="$FAKE_OK_BIN:$PATH" TRIPARTY_REPO_RUNS_DIR="$RUNS_FALLBACK_DEFAULT" TRIPARTY_RUNS_FALLBACK_DIR="$RUNS_FALLBACK_TARGET" TRIPARTY_PROBE_TIMEOUT=5 TRIPARTY_PROBE_RETRIES=0 TRIPARTY_GEMINI_AUTH_TIMEOUT=5 "$TRIPARTY" preflight
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

GEMINI_CAPACITY_FAKE_BIN="$TMP_ROOT/fake-capacity-bin"
mkdir -p "$GEMINI_CAPACITY_FAKE_BIN"
cat > "$GEMINI_CAPACITY_FAKE_BIN/gemini" <<'EOF'
#!/usr/bin/env bash
printf 'Attempt 1 failed: You have exhausted your capacity on this model. Retrying...\n' >&2
exit 1
EOF
chmod +x "$GEMINI_CAPACITY_FAKE_BIN/gemini"
run_expect pass "gemini_auth_doctor_capacity_is_authenticated" env PATH="$GEMINI_CAPACITY_FAKE_BIN:$PATH" TRIPARTY_GEMINI_AUTH_TIMEOUT=5 "$ROOT_DIR/scripts/triparty-gemini-auth-doctor.sh" "$GEMINI_FAKE_OUT"
if env PATH="$GEMINI_CAPACITY_FAKE_BIN:$PATH" TRIPARTY_GEMINI_AUTH_TIMEOUT=5 "$ROOT_DIR/scripts/triparty-gemini-auth-doctor.sh" "$GEMINI_FAKE_OUT" 2>/dev/null | grep -q 'status=authenticated'; then
  printf 'PASS: gemini_auth_doctor_status_capacity_authenticated\n'
else
  printf 'FAIL: gemini_auth_doctor_status_capacity_authenticated\n' >&2
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
