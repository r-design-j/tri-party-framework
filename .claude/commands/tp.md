---
description: Short alias for /triparty.
argument-hint: "[status|preflight|run|release-gate] [task or run-dir]"
allowed-tools: Bash
---

Run the same workflow as `/triparty` with these arguments:

```text
$ARGUMENTS
```

Use the installed `triparty` CLI when available. If it is not on PATH, read `~/.triparty-framework/config` and use `$TRIPARTY_FRAMEWORK_HOME/scripts/triparty.sh`. Do not recreate the framework with new ad hoc Markdown files. Do not call `claude`, `gemini`, or provider APIs directly from this alias.
