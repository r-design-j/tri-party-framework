---
name: triparty
description: Invoke the installed Codex + Claude + Gemini tri-party framework. Use when the user types /triparty, asks for the Codex + Claude + Gemini tri-party model collaboration framework, says 三方模型协作框架 or 三方模型协议, or gives a same-workstream follow-up such as 继续, 补齐, 优化, 发布, 外推, or 记录进去.
argument-hint: "[status|preflight|run|release-gate] [task or run-dir]"
allowed-tools: Bash
---

# Triparty

Use the existing portable framework. Do not recreate the protocol by writing new ad hoc Markdown files.

Arguments from the slash command:

```text
$ARGUMENTS
```

## Resolution

1. Prefer `triparty` from PATH when `command -v triparty` succeeds.
2. Otherwise read `~/.triparty-framework/config` and use `$TRIPARTY_FRAMEWORK_HOME/scripts/triparty.sh`.
3. Otherwise, if the current repository has `scripts/triparty.sh`, use that script.
4. If none are available, report that the framework is not installed or not discoverable, and ask whether to clone `https://github.com/r-design-j/tri-party-framework`.

## Dispatch

- No arguments or `status`: run `triparty status`.
- `preflight`: run `triparty preflight`.
- `run <task>`: run `triparty run "<task>"`; this portable core path performs preflight, independent reviews, mutual cross-audit, merge, and state validation.
- `release-gate <run-dir>`: run `triparty release-gate <run-dir>`.
- Any other non-empty arguments: treat the full argument string as the task and run `triparty run "$ARGUMENTS"`.

## Reporting

Report the run directory, source status, and whether the result is `true_triparty_ready` or partial. Do not call a result tri-party-backed unless the merge gate and state validation pass. For public release or publishing claims, also run `triparty release-gate <run-dir>`.

## Adapter Boundaries

- Do not call `claude`, `gemini`, or provider APIs directly from this slash layer.
- Do not provide or emulate `--skip-cross-audit`, `--skip-merge`, or any other bypass.
- Do not assert readiness in the slash layer; read readiness from the portable core's `state.json` through `triparty status` or `triparty release-gate`.
