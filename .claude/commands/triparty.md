---
description: Invoke the installed Codex + Claude + Gemini tri-party framework.
argument-hint: "[status|preflight|run|release-gate] [task or run-dir]"
allowed-tools: Bash
---

Use the existing portable framework. Do not recreate the protocol by writing new ad hoc Markdown files.

Arguments:

```text
$ARGUMENTS
```

Resolve the command in this order:

1. `triparty` from PATH.
2. `$TRIPARTY_FRAMEWORK_HOME/scripts/triparty.sh` after reading `~/.triparty-framework/config`.
3. `scripts/triparty.sh` from the current repository.

Dispatch:

- Empty arguments or `status`: run `triparty status`.
- `preflight`: run `triparty preflight`.
- `run <task>`: run `triparty run "<task>"`; this portable core path performs preflight, independent reviews, mutual cross-audit, merge, and state validation.
- `release-gate <run-dir>`: run `triparty release-gate <run-dir>`.
- Otherwise treat `$ARGUMENTS` as the task and run `triparty run "$ARGUMENTS"`.

Report the run directory, source status, and true/partial result.

Do not call `claude`, `gemini`, or provider APIs directly from this slash layer. Do not provide a cross-audit or merge bypass. Read readiness from the portable core's `state.json` through `triparty status` or `triparty release-gate`.
