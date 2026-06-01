# Tri-party Collaboration Protocol

## Definition

The tri-party framework means collaboration among exactly three model parties:

- Codex
- Claude
- Gemini

Codex sub-agents are useful for parallel Codex work, but they are not Claude or Gemini and must never be reported as their opinions.

## Capability Roles

Use the three parties according to their default strengths:

| Party | Default Role | Best Used For |
| --- | --- | --- |
| Codex | Implementation owner | Real project code, repository edits, tests, debugging, and in-worktree execution |
| Claude | Reasoning and autonomy owner | Complex reasoning, architecture tradeoffs, long-chain agent planning, autonomous multi-step strategy |
| Gemini | Multimodal and Google-context owner | PDFs, video, audio, images, Google Search/Maps/URL context, and Google ecosystem synthesis |

This is a dispatch rule, not a replacement for source verification. A model only counts as a party when its source is valid under the source rules below.

Current model bindings live in `docs/framework/model-binding.yaml`.

## Dispatch Pattern

For each task, assign:

- Primary owner: the party whose default role best matches the task.
- Support reviewer: the party most likely to catch missing reasoning, implementation, or context gaps.
- Challenge reviewer: the party asked to find failure modes, blind spots, or invalid assumptions.

Default mapping:

- Code/repository work: Codex primary, Claude architecture reviewer, Gemini context/multimodal reviewer when external assets are involved.
- Complex planning/reasoning: Claude primary, Codex feasibility reviewer, Gemini external-context reviewer.
- Multimodal/Google-context work: Gemini primary, Claude reasoning reviewer, Codex implementation reviewer if code changes are needed.
- Framework governance: Claude primary for logic, Codex primary for executable process, Gemini primary for external/multimodal expansion.

## Preflight Source Check

Before starting any tri-party review, fill this status mentally or explicitly when reporting:

| Party | Valid Source | Current Status | Evidence |
| --- | --- | --- | --- |
| Codex | Local Codex reasoning, file edits, tool output | Available / Unavailable | Message, file path, or command result |
| Claude | Direct Claude CLI/tool/API, connector, or user-provided transcript | Available / User-provided / Unavailable | CLI path, tool result, or pasted transcript |
| Gemini | Direct Gemini CLI/tool/API, connector, or user-provided transcript | Available / User-provided / Unavailable | CLI path, tool result, or pasted transcript |

If either Claude or Gemini is unavailable, the output is not a true tri-party result.

When shell access is available, source checks must include:

- `type -a claude`
- `type -a gemini`
- A minimal non-interactive connectivity test when the command exists and the task requires real model input.

Prefer the executable preflight script:

```bash
scripts/triparty-preflight.sh
```

The script records source status under `docs/framework/runs/` and exits non-zero when Claude or Gemini is unavailable, timed out, or failed.

## Valid And Invalid Substitutions

Valid Claude/Gemini inputs:

- Direct callable model tool or API result.
- Local CLI result from the actual `claude` or `gemini` command.
- Connector result explicitly identified as Claude or Gemini.
- User-pasted Claude or Gemini answer, clearly labeled by the user.

Invalid substitutions:

- Codex sub-agents.
- Explorer or worker agents spawned from Codex.
- Roleplay or simulated "Claude-style" or "Gemini-style" opinions.
- Unlabeled summaries where the source model cannot be verified.

## Required Output Labeling

Any tri-party report must include:

- Source status: whether Codex, Claude, and Gemini were called, user-supplied, or unavailable.
- Separate opinions: each party's position must be labeled by source.
- Consolidated result: distinguish consensus, majority view, and unresolved conflict.
- Missing inputs: if any party is unavailable, list what is needed to complete the real tri-party review.

## Workflow

1. Define the shared task, decision boundary, and expected deliverable.
2. Perform the preflight source check, preferably with `scripts/triparty-preflight.sh`.
3. Collect independent opinions from Codex, Claude, and Gemini.
4. Run mutual cross-audit before synthesis: Claude audits Gemini, Gemini audits Claude, and Codex audits the combined evidence.
5. Compare agreements, disagreements, risks, and evidence gaps after the cross-audit.
6. Run the source-status and cross-audit merge gate before synthesis.
7. Produce one consolidated recommendation with source labels preserved.
8. Convert repeated issues into daily standard candidates.
9. Solidify only stable, reusable, and verified rules into `AGENTS.md`.

For repeatable reviews, prefer:

```bash
scripts/triparty.sh run "<question>"
```

The unified command creates a timestamped run directory, collects Claude/Gemini reviews, runs cross-audit, runs the merge gate, and writes `state.json`.
For manual stage control, use `scripts/triparty.sh review`, `scripts/triparty.sh cross-audit`, `scripts/triparty.sh merge`, and `scripts/triparty.sh status`.

## Mutual Cross-audit Gate

Before synthesis, run:

```bash
scripts/triparty-cross-audit.sh docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Default audit pairing:

- Claude audits Gemini's review.
- Gemini audits Claude's review.
- Codex audits the source status, both reviews, both cross-audits, and the user's latest request before final response.

Cross-audit artifacts must be non-empty, hash-verifiable, and archived in the run directory. Missing, timed-out, failed, empty, mislabeled, or hash-mismatched cross-audits force partial labeling.

## Source-status And Merge Gate

Before calling any result a true tri-party conclusion, verify:

- Claude review status is `Completed`.
- Gemini review status is `Completed`.
- Claude cross-audit status is `Completed`.
- Gemini cross-audit status is `Completed`.
- Codex has synthesized the results in the current session.
- Each party's source label is preserved.

If any party is `Unavailable`, `TimedOut`, `Failed`, `Skipped`, missing a cross-audit, or has an invalid self-label, the final report must be labeled as partial and must list the missing or invalid input.

Use the executable merge gate:

```bash
scripts/triparty.sh merge docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Use `scripts/triparty.sh status [run-dir]` to generate or refresh the machine-readable `state.json` view.

## Connectivity Probe

Default probe behavior:

- Probe timeout: 20 seconds per CLI.
- Probe retries: 1 retry after the first failed attempt.
- Expected Claude probe output: `CLAUDE_OK`.
- Expected Gemini probe output: `GEMINI_OK`.
- Valid states: `Available`, `Unavailable`, `TimedOut`, `Failed`.

Default review behavior:

- Review timeout: 90 seconds per CLI.
- Review retries: 1 retry after the first failed attempt.
- Prompt max characters before slimming: 6000.
- Default Gemini review model: `gemini-3.1-pro-preview`.
- Default Gemini MCP allowlist: `__none__`, to avoid headless hangs from disconnected local MCP servers.
- Valid states: `Completed`, `TimedOut`, `Failed`, `Skipped`.
- A successful connectivity probe is not enough to prove a full review is stable; the review status must also be `Completed`.
- If full context is too large, the review script creates `model-context.md` with a slimmed or ultra-slimmed context.
- If a party is unavailable, timed out, failed, or skipped, the review script writes a party-specific handoff prompt such as `gemini-handoff.md`.

## Degraded Mode

When Claude or Gemini cannot be called:

- State the limitation before presenting conclusions.
- Use the label `Codex-only provisional` or `Codex plus Codex sub-agents`.
- Do not use the phrase "tri-party conclusion".
- Provide a handoff prompt that the user can send to Claude or Gemini.
- Reconcile the missing opinions later if the user provides them.

## Local CLI Invocation

For analysis-only tri-party reviews, prefer non-interactive read-only prompts:

- Claude direct call: `claude -p "<prompt>" --output-format text --tools "" --no-session-persistence --bare`
- Gemini direct call: `gemini -p "<prompt>" --output-format text --skip-trust`

If a CLI cannot read project files directly in the chosen permission mode, pass the relevant file contents or excerpts in the prompt and record that the opinion was based on provided context.

Every Claude/Gemini prompt must explicitly state that the model's source label is the corresponding CLI. This prevents the model from copying degraded-mode labels such as `Codex-only provisional` from the protocol text.

## Conflict Resolution

When the three parties disagree:

1. Prefer verifiable evidence over model preference.
2. Prefer the user's latest stated goal over older assumptions.
3. Prefer lower operational risk when evidence is incomplete.
4. If the conflict remains unresolved, present the disagreement and ask the user to decide.

## Current Known Source Status

As of this framework update, Codex may not have Claude or Gemini exposed as MCP/model tools, but local shell CLIs can be used when available:

- Claude CLI: `claude` on `PATH`
- Gemini CLI: `gemini` on `PATH`
