# Tri-party Framework Anti-patterns

## AP-001: Treating Codex Sub-agents As External Parties

- Failure: Codex sub-agent output is described as Claude or Gemini input.
- Risk: False tri-party consensus.
- Prevention: Source-status gate must list Claude and Gemini as direct CLI/tool/API/connector/user-transcript sources.

## AP-002: Checking Only Exposed Tools And Missing Local CLIs

- Failure: Claude or Gemini is declared unavailable because MCP/connectors do not expose them, while local CLIs exist.
- Risk: False degraded mode.
- Prevention: Run `scripts/triparty-preflight.sh` or check `type -a claude` and `type -a gemini`.

## AP-003: Treating Probe Success As Review Success

- Failure: `GEMINI_OK` or `CLAUDE_OK` succeeds, but the full review hangs or fails.
- Risk: A partial result is mislabeled as complete.
- Prevention: Require review status `Completed` for both Claude and Gemini before claiming a true tri-party conclusion.

## AP-004: Prompt Contamination From Protocol Text

- Failure: Claude or Gemini copies labels such as `Codex-only provisional` from the protocol text and mislabels its own output.
- Risk: Source records become self-contradictory.
- Prevention: Prompts must explicitly state the model's current source label and tell it not to rewrite that label.

## AP-005: Treating Partial Runs As Synthesizable

- Failure: A run with missing, timed-out, failed, or skipped party output is summarized as if it were a true tri-party conclusion.
- Risk: False consensus and loss of user trust.
- Prevention: Run `scripts/triparty-merge.sh <run-dir>` and only synthesize a true tri-party result when the merge gate says it is ready.

## AP-006: Hard-coding Model Versions Across Protocol Prose

- Failure: Concrete model names are repeated across `AGENTS.md`, `README.md`, protocol docs, and decision logs.
- Risk: Version drift after model upgrades.
- Prevention: Keep capability roles in prose and store current versions in `docs/framework/model-binding.yaml`.

## AP-007: Letting Disconnected MCP Servers Participate In Headless Gemini Calls

- Failure: Gemini CLI is authenticated and available, but headless calls hang because a configured local MCP server is disconnected.
- Risk: False Gemini instability and repeated partial reviews.
- Prevention: For framework automation, call Gemini with the intended model and an explicit MCP allowlist, currently `-m gemini-3.1-pro-preview --allowed-mcp-server-names __none__`.

## AP-008: Treating Division Of Labor As Sufficient Review

- Failure: Codex, Claude, and Gemini each produce or own separate work, but no party audits another party's output before the final conclusion.
- Risk: A single model's blind spot survives because role assignment is mistaken for mutual supervision.
- Prevention: Require cross-audit artifacts before merge: Claude audits Gemini, Gemini audits Claude, and Codex audits the combined evidence before synthesis.

## AP-009: Shipping A Codex-only Wrapper As The Framework Core

- Failure: The framework is packaged only as a Codex Skill even though users may operate from Claude, Gemini, CLI, MCP, or a front-end UI.
- Risk: The protocol becomes ecosystem-locked and fails outside Codex.
- Prevention: Keep the canonical framework as a portable core kit with thin adapters for each agent environment.

## AP-010: Over-broad Source-label Scanning

- Failure: A report is rejected because it mentions `Codex-only` or another failure label descriptively, even though the party did not claim that identity.
- Risk: False negatives block valid tri-party runs and encourage users to bypass the gate.
- Prevention: Source-label scans should target identity claims such as "I am Codex" or "source label: Codex", not ordinary references to known anti-patterns.

## AP-011: Unescaped Markdown Backticks In Shell Report Templates

- Failure: A shell here-doc writes Markdown containing backticks, or its terminator is indented while using `<<EOF`.
- Risk: Reports emit shell errors, execute unintended text, or swallow later shell branches as template content.
- Prevention: Avoid unescaped backticks inside evaluated here-docs, keep terminators at column 1, or use quoted here-docs when no interpolation is needed.

## AP-012: Stale Mutually Exclusive Gate Artifacts

- Failure: A run directory keeps an old `partial-report.md` after a later successful merge, or an old `merge-input.md` after a later failed merge.
- Risk: Humans and downstream tools read contradictory state from the same run.
- Prevention: Each gate rerun must remove artifacts that are invalid for the new gate outcome.

## AP-013: Party-authored Global Source Status

- Failure: Claude or Gemini writes a global source-status statement such as "Gemini was not called" inside its independent review.
- Risk: A single party contradicts the orchestrator's real source record and poisons the merge gate.
- Prevention: Prompts must state that source status is runner-owned, and merge must reject party-authored true/partial/source-status claims near the top of party artifacts.

## AP-014: Treating Feature Mentions As Source-status Claims

- Failure: The merge gate rejects a party artifact because it mentions "Source Status management" as a feature, not as a global source-status claim.
- Risk: False positives block valid runs and hide actual product feedback.
- Prevention: Source-status contamination scans should require explicit claim markers such as `来源状态：` or `Source status:` before blocking.

## AP-015: Adapter Redefines Core Truth

- Failure: An external adapter marks a run complete, partial, or true tri-party based on its own local interpretation instead of `state.json`.
- Risk: Different ecosystems show contradictory status for the same run.
- Prevention: Adapters must treat the portable core and merge-generated `state.json` as the only truth source for tri-party readiness.

## AP-016: Network Adapter Without Explicit Safety Boundary

- Failure: An adapter exposes commands such as run, lint, or regression beyond loopback without authentication and state validation.
- Risk: Unauthorized local command execution, forged state, or misleading UI status.
- Prevention: Default to loopback, require explicit opt-in and auth for non-loopback, and validate `state.json` against current artifact hashes before returning it as trusted.

## AP-017: UI Implements Core Recovery Logic

- Failure: A future UI directly patches files, invents resume behavior, or interprets partial states instead of calling core commands.
- Risk: UI and CLI drift, making the same run appear different across surfaces.
- Prevention: Implement offline injection, resume, errors, runs, stats, archive, and MCP access before UI; the UI must consume these surfaces rather than redefine them.

## AP-018: Ambiguous Tri-party Trigger Drift

- Failure: A user says "三方框架" or "三方协议", and the agent guesses a local three-part design/registry/runtime structure, a third-party library framework, or another governance model instead of the canonical Codex + Claude + Gemini model framework.
- Risk: The agent claims to use the framework without running preflight, independent reviews, mutual cross-audit, or the merge gate.
- Prevention: Treat "Codex + Claude + Gemini 三方模型协作框架" as the canonical strong trigger. Treat standalone "三方框架"/"三方协议" as weak triggers; when context is ambiguous, ask whether the user means the Codex + Claude + Gemini model framework or another three-part structure.

## AP-019: Tri-party Context Drop On Follow-up Execution

- Failure: After the user has established the current workstream as the Codex + Claude + Gemini tri-party model framework, the agent treats a follow-up such as "补齐", "继续", "发布", "外推", or "记录进去" as an ordinary Codex-only implementation task and completes repository or GitHub work without running the tri-party protocol first.
- Risk: The work is presented as part of the tri-party framework while lacking independent Claude/Gemini review, mutual cross-audit, and merge-gate evidence; public releases can ship without the supervision standard the framework itself requires.
- Prevention: Treat same-workstream follow-ups as inherited tri-party triggers unless the user explicitly requests Codex-only execution. Codex may own code/repo edits, but tri-party-backed delivery requires preflight, independent reviews, mutual cross-audit, merge gate, and source-status reporting before final claims.

## AP-020: Gemini Runtime Noise Counted As Clean Completion

- Failure: Gemini CLI eventually returns text after internal 429 retries, tool-read failures, disconnected MCP noise, or ignored-artifact errors, and the framework marks the artifact as clean `Completed`.
- Risk: Claude/Codex audit the runtime error log instead of Gemini's actual opinion, or a capacity-degraded run is reported as fully healthy.
- Prevention: Use the Gemini headless policy, disabled MCP allowlist, longer timeout/retry/backoff, policy-hash recording, sanitized artifacts, sanitizer-version diagnostics in `state.json`, release capacity thresholds, and merge-blocking runtime-noise scans that include terminal warnings as noise.

## AP-021: New Session Recreates The Framework

- Failure: A new agent session cannot discover the installed tri-party framework and creates fresh Markdown files to reconstruct a partial protocol.
- Risk: The user sees a different framework every session; triggers drift, old fixes disappear, and the agent makes unverifiable claims from improvised docs.
- Prevention: Install the global bootstrap with `scripts/install-triparty-global-bootstrap.sh`; new sessions must locate `TRIPARTY_FRAMEWORK_HOME`, `~/.triparty-framework/config`, or the installed path before acting. For Claude Code, provide `CLAUDE.md` because Claude Code does not read `AGENTS.md`. If discovery fails, report it and ask whether to clone/install instead of creating ad hoc framework docs.

## AP-022: Slash Trigger Exists Only In Prose

- Failure: Documentation tells users to type `/triparty`, but the runtime has no installed skill or command file behind that slash trigger.
- Risk: New sessions still fall back to weak natural-language triggers, and users cannot tell whether they invoked the real framework or a freshly improvised workflow.
- Prevention: Treat slash invocation as a thin adapter with files under `.claude/skills/triparty/` and `.claude/commands/`; install them globally with `scripts/install-triparty-global-bootstrap.sh`, lint for their presence, and keep the `triparty` CLI as the portable fallback.

## AP-023: Adapter Purity Text Misread As Source-status Contamination

- Failure: A party says "the slash adapter must not directly call claude or gemini", and the merge gate treats that as if Claude or Gemini were not called in the current run.
- Risk: Valid adapter reviews are rejected, encouraging weaker prompts that avoid naming the exact unsafe behavior.
- Prevention: Source-label scans must reject explicit source-status claims, not ordinary discussion of adapter purity or direct-model-call risks; regression must include a passing case for descriptive "do not call claude/gemini directly" text.

## AP-024: Release Gate Selects An Incomplete Latest Run

- Failure: `triparty-release-gate.sh` is called without a run directory and selects a newer `review-*` directory that only contains preflight artifacts.
- Risk: Pre-push and release workflows fail even though the latest complete tri-party review is ready, or humans bypass the gate because it appears flaky.
- Prevention: Default latest-run resolution for release gates must only consider review directories that contain `source-status.md`; incomplete preflight-only directories remain inspectable but are not eligible as release candidates.
