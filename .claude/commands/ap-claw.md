---
description: Short alias for /agentparty-claw.
argument-hint: "[kit|prompt|guide|validate] [task or kit-dir]"
allowed-tools: Bash
---

<!-- AGENTPARTY_MANAGED_COMMAND: ap-claw v1 -->

Run the same workflow as `/agentparty-claw` with these arguments:

```text
$ARGUMENTS
```

Use the installed `agentparty` CLI when available. If it is not on PATH, read `~/.triparty-framework/config` and use `$AGENTPARTY_FRAMEWORK_HOME/scripts/agentparty.sh`; otherwise fall back to `scripts/agentparty.sh` in the current repository.

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

If no AgentParty CLI path can be resolved, stop with the resolver's non-zero exit. Report that AgentParty is not installed or not discoverable, suggest running `agentparty doctor` after installation, and ask whether to clone or install `https://github.com/r-design-j/tri-party-framework.git`. Do not recreate the framework with new ad hoc Markdown files.

This alias supports the same `kit`, `prompt`, `guide`, and `validate` dispatch as `/agentparty-claw`. It is preparation and handoff only. Do not call Feishu, configure Claw auth, import evidence, claim `pack_ready` by itself, participate in Codex + Claude + Gemini cross-audit, or claim `true_triparty_ready=true`.
