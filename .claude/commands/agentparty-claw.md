---
description: Create or inspect a Claude Code + Feishu Claw AgentParty handoff kit.
argument-hint: "[kit|prompt|guide|validate] [task or kit-dir]"
allowed-tools: Bash
---

<!-- AGENTPARTY_MANAGED_COMMAND: agentparty-claw v1 -->

Use the existing AgentParty portable framework. Do not recreate the protocol by writing new ad hoc Markdown files.

Arguments:

```text
$ARGUMENTS
```

Resolve the command in this order:

1. `agentparty` from PATH.
2. `$AGENTPARTY_FRAMEWORK_HOME/scripts/agentparty.sh` after reading `~/.triparty-framework/config`.
3. `scripts/agentparty.sh` from the current repository.

Run this resolver before dispatch:

```bash
AGENTPARTY_CMD="$(command -v agentparty 2>/dev/null || true)"
if [ -z "$AGENTPARTY_CMD" ] && [ -f "$HOME/.triparty-framework/config" ]; then
  . "$HOME/.triparty-framework/config"
  if [ -n "${AGENTPARTY_FRAMEWORK_HOME:-}" ] && [ -x "$AGENTPARTY_FRAMEWORK_HOME/scripts/agentparty.sh" ]; then
    AGENTPARTY_CMD="$AGENTPARTY_FRAMEWORK_HOME/scripts/agentparty.sh"
  fi
fi
if [ -z "$AGENTPARTY_CMD" ] && [ -x "scripts/agentparty.sh" ]; then
  AGENTPARTY_CMD="scripts/agentparty.sh"
fi
if [ -z "$AGENTPARTY_CMD" ]; then
  printf '%s\n' "AgentParty is not installed or not discoverable in this environment." >&2
  printf '%s\n' "After installation, run: agentparty doctor" >&2
  printf '%s\n' "Install or clone: https://github.com/r-design-j/tri-party-framework.git" >&2
  exit 1
fi
```

If all three resolution paths fail, stop with the resolver's non-zero exit. Report that AgentParty is not installed or not discoverable in the current environment, suggest running `agentparty doctor` after installation, and ask whether to clone or install `https://github.com/r-design-j/tri-party-framework.git`. Do not create replacement protocol files, placeholder Markdown, or local ad hoc workflows.

Dispatch:

- Empty arguments: run `"$AGENTPARTY_CMD" guide --pack claude-code-feishu-claw`.
- `prompt <task>`: run `"$AGENTPARTY_CMD" prompt --pack claude-code-feishu-claw --task "<task>"`.
- `kit <task>`: run `"$AGENTPARTY_CMD" kit --pack claude-code-feishu-claw --task "<task>" --out "agentparty-claw-kit-$(date +%Y%m%d-%H%M%S)"`.
- `guide <kit-dir-or-run-dir>`: run `"$AGENTPARTY_CMD" guide --pack claude-code-feishu-claw --run-dir "<kit-dir-or-run-dir>"`.
- `validate <kit-dir-or-run-dir>`: run `"$AGENTPARTY_CMD" validate-run --run-dir "<kit-dir-or-run-dir>"`.
- Otherwise treat `$ARGUMENTS` as the task and create a new local handoff kit with `"$AGENTPARTY_CMD" kit --pack claude-code-feishu-claw --task "$ARGUMENTS" --out "agentparty-claw-kit-$(date +%Y%m%d-%H%M%S)"`.

Report the kit directory, `state.json`, evidence bundle path, next command, and boundaries.

Boundaries:

- This is a 2-agent AgentParty product pack, not Codex + Claude + Gemini true tri-party.
- This pack does not participate in Codex + Claude + Gemini cross-audit unless a separate `triparty` run is explicitly started.
- Do not set or claim `true_triparty_ready=true`.
- The slash layer must not call Feishu, configure Claw auth, import evidence, or claim `pack_ready` by itself.
- Evidence import remains a WSL2/macOS/Linux executable path; native PowerShell is preparation-only.
