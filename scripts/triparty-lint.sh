#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILED=1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

require_file() {
  local file="$1"
  if [ -f "$ROOT_DIR/$file" ]; then
    pass "file exists: $file"
  else
    fail "missing file: $file"
  fi
}

require_exec() {
  local file="$1"
  if [ -x "$ROOT_DIR/$file" ]; then
    pass "executable: $file"
  else
    fail "not executable: $file"
  fi
}

require_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Eq -- "$pattern" "$ROOT_DIR/$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Eq -- "$pattern" "$ROOT_DIR/$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

require_file "AGENTS.md"
require_file "CLAUDE.md"
require_file ".claude/skills/triparty/SKILL.md"
require_file ".claude/commands/triparty.md"
require_file ".claude/commands/tp.md"
require_file "README.md"
require_file "VERSION"
require_file "CHANGELOG.md"
require_file "docs/framework/tri-party-protocol.md"
require_file "docs/framework/adapter-contract.md"
require_file "docs/framework/model-binding.yaml"
require_file "docs/framework/model-binding.schema.json"
require_file "docs/framework/state.schema.json"
require_file "docs/framework/productization-strategy.md"
require_file "docs/framework/gemini-headless-policy.toml"
require_file "adapters/http/triparty_http_adapter.py"
require_file "adapters/mcp/triparty_mcp_adapter.py"
require_file "scripts/triparty-validate-state.py"
require_file "scripts/triparty-runs-dir.sh"
require_file "scripts/triparty-gemini-auth-doctor.sh"
require_file "scripts/triparty-continuity-checkpoint.sh"
require_file "scripts/triparty-continuity-bootstrap.sh"

require_exec "scripts/triparty-preflight.sh"
require_exec "scripts/triparty-review.sh"
require_exec "scripts/triparty-cross-audit.sh"
require_exec "scripts/triparty-merge.sh"
require_exec "scripts/triparty.sh"
require_exec "scripts/triparty-lint.sh"
require_exec "scripts/triparty-regression.sh"
require_exec "scripts/triparty-adapter-smoke.sh"
require_exec "scripts/triparty-mcp-smoke.sh"
require_exec "scripts/triparty-release-gate.sh"
require_exec "scripts/triparty-runs-dir.sh"
require_exec "scripts/triparty-gemini-auth-doctor.sh"
require_exec "scripts/triparty-continuity-checkpoint.sh"
require_exec "scripts/triparty-continuity-bootstrap.sh"
require_exec "scripts/install-triparty-git-hooks.sh"
require_exec "scripts/install-triparty-global-bootstrap.sh"
require_exec "scripts/triparty-validate-state.py"
require_exec "adapters/http/triparty_http_adapter.py"
require_exec "adapters/mcp/triparty_mcp_adapter.py"

if bash -n "$ROOT_DIR"/scripts/*.sh; then
  pass "all shell scripts parse"
else
  fail "one or more shell scripts do not parse"
fi

require_text "AGENTS.md" 'Tri-party Mutual Audit Gate' "AGENTS records mutual audit gate"
require_text "AGENTS.md" 'Codex, Claude, and Gemini' "AGENTS names the three parties"
require_text "AGENTS.md" 'Tri-party Trigger Contract' "AGENTS records trigger contract"
require_text "AGENTS.md" 'New-session Bootstrap Contract' "AGENTS records new-session bootstrap contract"
require_text "AGENTS.md" 'Codex.*Claude.*Gemini.*三方模型协作框架' "AGENTS records canonical trigger phrase"
require_text "AGENTS.md" '/triparty' "AGENTS records slash trigger"
require_text "AGENTS.md" '/tp' "AGENTS records slash alias"
require_text "AGENTS.md" 'follow-up instructions.*inherit the tri-party protocol' "AGENTS records inherited follow-up trigger"
require_text "CLAUDE.md" '@AGENTS.md' "CLAUDE imports AGENTS"
require_text "CLAUDE.md" 'Claude Code' "CLAUDE documents Claude Code entrypoint"
require_text "CLAUDE.md" '/triparty' "CLAUDE documents slash trigger"
require_text ".claude/skills/triparty/SKILL.md" 'description:.*Codex \+ Claude \+ Gemini' "Claude skill describes canonical framework"
require_text ".claude/skills/triparty/SKILL.md" '/triparty' "Claude skill records slash trigger"
require_text ".claude/skills/triparty/SKILL.md" 'Do not recreate' "Claude skill forbids framework recreation"
require_text ".claude/skills/triparty/SKILL.md" 'Adapter Boundaries' "Claude skill records adapter boundaries"
require_text ".claude/skills/triparty/SKILL.md" 'state validation' "Claude skill records state validation"
require_text ".claude/commands/triparty.md" 'description:' "Claude triparty slash command has description"
require_text ".claude/commands/triparty.md" 'Do not recreate' "Claude triparty slash command forbids framework recreation"
require_text ".claude/commands/triparty.md" 'state validation' "Claude triparty slash command records state validation"
require_text ".claude/commands/tp.md" '/triparty' "Claude tp slash alias points to triparty"
forbid_text ".claude/skills/triparty/SKILL.md" 'scripts/triparty-(preflight|review|cross-audit|merge)\.sh' "Claude skill does not bypass unified CLI with stage scripts"
forbid_text ".claude/commands/triparty.md" 'scripts/triparty-(preflight|review|cross-audit|merge)\.sh' "Claude slash command does not bypass unified CLI with stage scripts"
forbid_text ".claude/commands/tp.md" 'scripts/triparty-(preflight|review|cross-audit|merge)\.sh' "Claude slash alias does not bypass unified CLI with stage scripts"
forbid_text ".claude/skills/triparty/SKILL.md" '(^|[[:space:]`])(claude|gemini)[[:space:]]+(-|--|run|chat|api)' "Claude skill does not directly invoke model CLIs"
forbid_text ".claude/commands/triparty.md" '(^|[[:space:]`])(claude|gemini)[[:space:]]+(-|--|run|chat|api)' "Claude slash command does not directly invoke model CLIs"
forbid_text ".claude/commands/tp.md" '(^|[[:space:]`])(claude|gemini)[[:space:]]+(-|--|run|chat|api)' "Claude slash alias does not directly invoke model CLIs"
require_text "README.md" 'triparty-cross-audit\.sh' "README documents cross-audit step"
require_text "README.md" 'triparty\.sh' "README documents unified CLI"
require_text "README.md" 'triparty_http_adapter\.py' "README documents HTTP adapter"
require_text "README.md" 'triparty_mcp_adapter\.py' "README documents MCP adapter"
require_text "README.md" 'triparty-release-gate\.sh' "README documents release gate"
require_text "README.md" 'Standalone phrases such as `三方框架`' "README documents weak trigger ambiguity"
require_text "README.md" 'follow-up requests.*inherit the tri-party protocol' "README documents inherited workstream trigger"
require_text "README.md" 'install-triparty-global-bootstrap\.sh' "README documents global bootstrap installer"
require_text "README.md" 'Claude Code reads `CLAUDE.md`' "README documents Claude Code bootstrap"
require_text "README.md" '/triparty status' "README documents slash trigger"
require_text "README.md" '/tp status' "README documents slash alias"
require_text "docs/framework/adapter-contract.md" 'true_triparty_ready' "adapter contract preserves core truth"
require_text "docs/framework/adapter-contract.md" 'triparty_resume' "adapter contract documents resume"
require_text "docs/framework/adapter-contract.md" 'completion_marker' "adapter contract documents artifact completion markers"
require_text "docs/framework/adapter-contract.md" 'temp-file-and-rename' "adapter contract documents atomic status publication"
require_text "docs/framework/tri-party-protocol.md" 'Mutual Cross-audit Gate' "protocol documents mutual cross-audit gate"
require_text "docs/framework/tri-party-protocol.md" 'Claude audits Gemini' "protocol records Claude auditing Gemini"
require_text "docs/framework/tri-party-protocol.md" 'Gemini audits Claude' "protocol records Gemini auditing Claude"
require_text "docs/framework/tri-party-protocol.md" 'Activation And Ambiguity Rules' "protocol documents activation ambiguity rules"
require_text "docs/framework/tri-party-protocol.md" 'Inherited Workstream Rule' "protocol documents inherited workstream rule"
require_text "docs/framework/tri-party-protocol.md" 'New-session Discovery' "protocol documents new-session discovery"
require_text "docs/framework/tri-party-protocol.md" 'Claude Code reads `CLAUDE.md`' "protocol documents Claude Code discovery"
require_text "docs/framework/tri-party-protocol.md" 'Slash Invocation' "protocol documents slash invocation"
require_text "docs/framework/tri-party-protocol.md" '/triparty' "protocol records slash trigger"
require_text "docs/framework/tri-party-protocol.md" '/tp' "protocol records slash alias"
require_text "docs/framework/tri-party-protocol.md" 'Gemini CLI Reliability Rules' "protocol documents Gemini CLI reliability rules"
require_text "docs/framework/tri-party-protocol.md" 'release-gate' "protocol documents release gate"
require_text "docs/framework/anti-patterns.md" 'Ambiguous Tri-party Trigger Drift' "anti-patterns document trigger drift"
require_text "docs/framework/anti-patterns.md" 'Tri-party Context Drop On Follow-up Execution' "anti-patterns document context drop failure"
require_text "docs/framework/anti-patterns.md" 'Gemini Runtime Noise Counted As Clean Completion' "anti-patterns document Gemini runtime noise"
require_text "docs/framework/anti-patterns.md" 'New Session Recreates The Framework' "anti-patterns document new-session reconstruction failure"
require_text "docs/framework/anti-patterns.md" 'Slash Trigger Exists Only In Prose' "anti-patterns document slash trigger failure"
require_text "docs/framework/anti-patterns.md" 'Adapter Purity Text Misread As Source-status Contamination' "anti-patterns document adapter purity false positive"
require_text "docs/framework/anti-patterns.md" 'Release Gate Selects An Incomplete Latest Run' "anti-patterns document release-gate latest-run failure"
require_text "docs/framework/model-binding.yaml" 'required_for_true_tri_party: true' "model binding requires cross-audit"
require_text "docs/framework/model-binding.yaml" 'cli_model_name: gemini-3\.1-pro-preview' "model binding pins Gemini CLI model"
require_text "docs/framework/model-binding.yaml" '--allowed-mcp-server-names' "model binding records Gemini MCP allowlist"
require_text "docs/framework/model-binding.yaml" '__none__' "model binding disables default Gemini MCP servers"
require_text "docs/framework/model-binding.yaml" 'gemini-headless-policy\.toml' "model binding records Gemini headless policy"
require_text "docs/framework/model-binding.yaml" 'runtime_noise_is_merge_blocking: true' "model binding records runtime noise gate"
require_text "docs/framework/model-binding.yaml" 'auth_doctor_statuses' "model binding records Gemini auth doctor"
require_text "docs/framework/model-binding.yaml" 'runs_dir_fallback' "model binding records runs dir fallback"
require_text "docs/framework/model-binding.yaml" 'release_max_capacity_events: 3' "model binding records Gemini capacity threshold"
require_text "docs/framework/productization-strategy.md" 'portable core kit with thin adapters' "product strategy avoids Codex-only core"
require_text "docs/framework/productization-strategy.md" 'First External Adapter' "product strategy documents first adapter"
require_text "docs/framework/productization-strategy.md" 'MCP adapter' "product strategy documents MCP adapter"
require_text "docs/framework/state.schema.json" 'triparty.state.v1' "state schema documents state.json"
require_text "docs/framework/state.schema.json" 'preflight_binary_sha256' "state schema requires preflight binary evidence"
require_text "docs/framework/state.schema.json" 'preflight_policy_sha256' "state schema requires Gemini policy evidence"
require_text "docs/framework/state.schema.json" 'auth_doctor' "state schema documents Gemini auth doctor"
require_text "docs/framework/state.schema.json" 'gemini_diagnostics' "state schema requires Gemini diagnostics"
require_text "scripts/triparty-runs-dir.sh" 'triparty-runs' "runs-dir helper records temp fallback"
require_text "scripts/triparty-gemini-auth-doctor.sh" 'interactive-auth-required' "Gemini auth doctor reports interactive auth"
require_text "scripts/triparty-merge.sh" 'artifact_metadata_status' "merge gate validates artifact metadata"
require_text "scripts/triparty-merge.sh" 'TRIPARTY_REVIEW_COMPLETE' "merge gate validates review completion marker"
require_text "scripts/triparty-merge.sh" 'artifact_runtime_noise_status' "merge gate validates runtime noise"
require_text "scripts/triparty-merge.sh" 'Warning: True color' "merge gate treats terminal warnings as runtime noise"
require_text "scripts/triparty-preflight.sh" 'MODEL_BINDING_SHA256' "preflight records model binding hash"
require_text "scripts/triparty-preflight.sh" 'GEMINI_POLICY_SHA256' "preflight records Gemini policy hash"
require_text "scripts/triparty-preflight.sh" 'GEMINI_AUTH_STATUS' "preflight records Gemini auth status"
require_text "scripts/triparty-review.sh" 'gemini-sanitize-v2' "review records sanitizer version"
require_text "scripts/triparty.sh" 'state.json.tmp' "unified status writes state atomically"
require_text "scripts/triparty.sh" '"runs_dir"' "unified status records actual runs dir"
require_text "scripts/triparty.sh" 'release-gate' "unified CLI exposes release gate"
require_text "scripts/triparty.sh" 'continuity' "unified CLI exposes continuity handoff"
require_text "scripts/triparty.sh" 'triparty-validate-state.py' "unified run validates release state"
require_text "scripts/triparty-release-gate.sh" 'triparty-validate-state.py' "release gate validates state schema"
require_text "scripts/triparty-release-gate.sh" 'source-status\.md' "release gate filters latest run candidates by source status"
require_text "scripts/triparty-validate-state.py" 'TRIPARTY_RELEASE_MAX_GEMINI_CAPACITY_EVENTS' "state validator enforces Gemini capacity threshold"
require_text "scripts/triparty-validate-state.py" 'auth_doctor.status must be authenticated' "state validator requires Gemini auth for release"
require_text "scripts/triparty-continuity-checkpoint.sh" 'triparty-continuity/v1' "continuity checkpoint writes current.yml schema"
require_text "scripts/triparty-continuity-checkpoint.sh" 'manifest.json' "continuity checkpoint writes manifest"
require_text "scripts/triparty-continuity-bootstrap.sh" 'Hash mismatch' "continuity bootstrap verifies hashes"
require_text "scripts/install-triparty-global-bootstrap.sh" '\.triparty-framework' "global bootstrap writes discovery config"
require_text "scripts/install-triparty-global-bootstrap.sh" '\.claude.*/CLAUDE\.md|CLAUDE_MEMORY_FILE' "global bootstrap writes Claude Code memory"
require_text "scripts/install-triparty-global-bootstrap.sh" 'skills/triparty' "global bootstrap installs Claude slash skill"
require_text "scripts/install-triparty-global-bootstrap.sh" 'commands/tp\.md' "global bootstrap installs Claude slash alias"

if [ "$FAILED" -eq 0 ]; then
  printf 'triparty lint passed\n'
  exit 0
fi

printf 'triparty lint failed\n' >&2
exit 1
