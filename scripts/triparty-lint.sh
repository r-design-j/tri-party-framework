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

require_file "AGENTS.md"
require_file "README.md"
require_file "VERSION"
require_file "CHANGELOG.md"
require_file "docs/framework/tri-party-protocol.md"
require_file "docs/framework/adapter-contract.md"
require_file "docs/framework/model-binding.yaml"
require_file "docs/framework/model-binding.schema.json"
require_file "docs/framework/state.schema.json"
require_file "docs/framework/productization-strategy.md"
require_file "adapters/http/triparty_http_adapter.py"
require_file "adapters/mcp/triparty_mcp_adapter.py"

require_exec "scripts/triparty-preflight.sh"
require_exec "scripts/triparty-review.sh"
require_exec "scripts/triparty-cross-audit.sh"
require_exec "scripts/triparty-merge.sh"
require_exec "scripts/triparty.sh"
require_exec "scripts/triparty-lint.sh"
require_exec "scripts/triparty-regression.sh"
require_exec "scripts/triparty-adapter-smoke.sh"
require_exec "scripts/triparty-mcp-smoke.sh"
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
require_text "AGENTS.md" 'Codex.*Claude.*Gemini.*三方模型协作框架' "AGENTS records canonical trigger phrase"
require_text "AGENTS.md" 'follow-up instructions.*inherit the tri-party protocol' "AGENTS records inherited follow-up trigger"
require_text "README.md" 'triparty-cross-audit\.sh' "README documents cross-audit step"
require_text "README.md" 'triparty\.sh' "README documents unified CLI"
require_text "README.md" 'triparty_http_adapter\.py' "README documents HTTP adapter"
require_text "README.md" 'triparty_mcp_adapter\.py' "README documents MCP adapter"
require_text "README.md" 'Standalone phrases such as `三方框架`' "README documents weak trigger ambiguity"
require_text "README.md" 'follow-up requests.*inherit the tri-party protocol' "README documents inherited workstream trigger"
require_text "docs/framework/adapter-contract.md" 'true_triparty_ready' "adapter contract preserves core truth"
require_text "docs/framework/adapter-contract.md" 'triparty_resume' "adapter contract documents resume"
require_text "docs/framework/adapter-contract.md" 'completion_marker' "adapter contract documents artifact completion markers"
require_text "docs/framework/adapter-contract.md" 'temp-file-and-rename' "adapter contract documents atomic status publication"
require_text "docs/framework/tri-party-protocol.md" 'Mutual Cross-audit Gate' "protocol documents mutual cross-audit gate"
require_text "docs/framework/tri-party-protocol.md" 'Claude audits Gemini' "protocol records Claude auditing Gemini"
require_text "docs/framework/tri-party-protocol.md" 'Gemini audits Claude' "protocol records Gemini auditing Claude"
require_text "docs/framework/tri-party-protocol.md" 'Activation And Ambiguity Rules' "protocol documents activation ambiguity rules"
require_text "docs/framework/tri-party-protocol.md" 'Inherited Workstream Rule' "protocol documents inherited workstream rule"
require_text "docs/framework/anti-patterns.md" 'Ambiguous Tri-party Trigger Drift' "anti-patterns document trigger drift"
require_text "docs/framework/anti-patterns.md" 'Tri-party Context Drop On Follow-up Execution' "anti-patterns document context drop failure"
require_text "docs/framework/model-binding.yaml" 'required_for_true_tri_party: true' "model binding requires cross-audit"
require_text "docs/framework/model-binding.yaml" 'cli_model_name: gemini-3\.1-pro-preview' "model binding pins Gemini CLI model"
require_text "docs/framework/model-binding.yaml" '--allowed-mcp-server-names' "model binding records Gemini MCP allowlist"
require_text "docs/framework/model-binding.yaml" '__none__' "model binding disables default Gemini MCP servers"
require_text "docs/framework/productization-strategy.md" 'portable core kit with thin adapters' "product strategy avoids Codex-only core"
require_text "docs/framework/productization-strategy.md" 'First External Adapter' "product strategy documents first adapter"
require_text "docs/framework/productization-strategy.md" 'MCP adapter' "product strategy documents MCP adapter"
require_text "docs/framework/state.schema.json" 'triparty.state.v1' "state schema documents state.json"
require_text "scripts/triparty-merge.sh" 'artifact_metadata_status' "merge gate validates artifact metadata"
require_text "scripts/triparty-merge.sh" 'TRIPARTY_REVIEW_COMPLETE' "merge gate validates review completion marker"
require_text "scripts/triparty-preflight.sh" 'MODEL_BINDING_SHA256' "preflight records model binding hash"
require_text "scripts/triparty.sh" 'state.json.tmp' "unified status writes state atomically"

if [ "$FAILED" -eq 0 ]; then
  printf 'triparty lint passed\n'
  exit 0
fi

printf 'triparty lint failed\n' >&2
exit 1
