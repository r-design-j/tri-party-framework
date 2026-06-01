# Global Codex Working Agreements

## Output Review Standard

- Before sending any user-visible Codex window output, final response, document content, Figma/design change summary, or generated artifact for review, perform at least 3 self-review passes.
- The 3 passes must check:
  - Alignment with the user's latest request and wording.
  - Completeness and correctness of the actual result, not just the intended result.
  - Visible quality issues such as overlap, overflow, missing content, wrong labels, wrong hierarchy, or unclear placement when the work involves UI, Figma, documents, slides, or screenshots.
- Do not say the work is done until the review passes. If a check fails, fix it first and review again.
- When the user asks to "固化" a working agreement, prefer adding it here so future Codex sessions inherit it.

## Daily Work Standard Extraction

- At the end of each working day, summarize that day's completed work items and decisions.
- From the daily work summary, extract reusable, abstract, and implementable standards rather than only recording events.
- Present the extracted standards as a clear list, with each item written so it can be applied to future tri-party framework optimization.
- Treat these standards as real operational data and source material for continuously improving the existing tri-party framework system.
- When summarizing, explicitly look for optimization opportunities, missing capabilities, reusable patterns, and feature ideas that could enrich the framework.
- The Codex, Claude, and Gemini model parties should cross-check each other's reasoning where relevant, identify reusable lessons, and use the results as input for ongoing self-iteration.

## Tri-party Framework Definition

- "Tri-party framework" and "three-party protocol" mean collaboration among exactly these three model parties: Codex, Claude, and Gemini.
- Default capability roles:
  - Codex: primary owner for real project code, repository edits, implementation, tests, and in-worktree execution.
  - Claude: primary owner for complex reasoning, long-chain agent planning, architecture tradeoff analysis, and autonomous multi-step strategy.
  - Gemini: primary owner for multimodal work involving PDFs, video, audio, images, Google Search/Maps/URL context, and Google ecosystem synthesis.
- Current model bindings live in `docs/framework/model-binding.yaml`.
- The executable protocol and source-check template live in `docs/framework/tri-party-protocol.md`.
- Prefer the executable scripts `scripts/triparty-preflight.sh` and `scripts/triparty-review.sh` for source checks and repeatable tri-party reviews before relying on manual CLI calls.
- Codex sub-agents, local explorer agents, worker agents, or other Codex-internal delegations do not count as Claude or Gemini.
- Before claiming that a result is a tri-party conclusion, verify and state the source of each party's input:
  - Codex: local Codex reasoning or execution result.
  - Claude: direct Claude CLI/tool/API result, connector result, or user-provided Claude transcript.
  - Gemini: direct Gemini CLI/tool/API result, connector result, or user-provided Gemini transcript.
- Source availability checks must include both exposed tools/connectors and local shell CLI availability, including `type -a claude` and `type -a gemini` when shell access is available.
- If Claude or Gemini is not actually available in the current environment, do not simulate or substitute them with Codex sub-agents. Label the result as "Codex-only provisional" or "Codex plus Codex sub-agents" instead.
- Any summary that mentions Codex, Claude, and Gemini must include a source-status line showing whether each party was directly called, supplied by the user, or unavailable.
- When one or more parties are unavailable, proceed only with clearly marked partial analysis and list the missing party inputs needed for a true tri-party review.
- If a previous response incorrectly described Codex sub-agent output as tri-party output, correct the record immediately and add the failure mode to the daily standard extraction candidates.

## Tri-party Trigger Contract

- Canonical activation phrase: "Codex + Claude + Gemini tri-party model collaboration framework" / "Codex + Claude + Gemini 三方模型协作框架".
- Strong triggers include:
  - The user explicitly says "Codex + Claude + Gemini".
  - The user says "三方模型协作框架" or "三方模型协议".
  - The user invokes `/triparty` or `/tp` in an agent runtime that supports slash skills or slash commands.
  - The user asks to run `scripts/triparty.sh`, `triparty_run`, or the "true_triparty_ready" gate.
  - The user asks for source status, independent review, mutual cross-audit, and merge gate in one request.
- Weak triggers include standalone phrases such as "三方框架", "三方协议", or "tri-party framework" without naming Codex, Claude, and Gemini. For weak triggers, first inspect local `AGENTS.md`/`README.md` if available. If the active context could also mean a design-component/registry/runtime audit, a third-party library, or another three-part structure, ask a concise disambiguation question before proceeding.
- Disambiguation question: "你指的是 Codex + Claude + Gemini 三方模型协作框架，还是另一个三方结构？"
- Do not reinterpret the canonical tri-party model framework as a Figma/component-registry/runtime audit, an external third-party framework, or a generic three-part analysis unless the user explicitly says so.
- Once a workstream is confirmed as the Codex + Claude + Gemini tri-party model framework, follow-up instructions such as "继续", "补齐", "优化", "发布", "外推", or "记录进去" inherit the tri-party protocol unless the user explicitly says to run Codex-only. Codex may still own implementation work, but public delivery, release, or framework claims must pass preflight, independent reviews, mutual cross-audit, and merge gate before being reported as tri-party-backed.
- Once the canonical trigger is confirmed, execute the normal workflow: preflight, independent reviews, mutual cross-audit, merge gate, and source-status reporting.

## New-session Bootstrap Contract

- The framework must be installed into the agent's global startup context before it can be reliably triggered outside this repository.
- Use `scripts/install-triparty-global-bootstrap.sh` to install:
  - a global Codex `AGENTS.md` bootstrap block;
  - a global Claude Code `~/.claude/CLAUDE.md` bootstrap block;
  - a Claude Code `/triparty` slash skill plus `/triparty` and `/tp` slash command files;
  - `~/.triparty-framework/config` with the framework home and repo URL;
  - a portable `triparty` CLI wrapper in a user bin directory already on PATH when possible.
- The repository should also keep `CLAUDE.md` importing `AGENTS.md`, because Claude Code reads `CLAUDE.md` rather than `AGENTS.md`.
- In a new session, the agent must first locate the existing framework through `TRIPARTY_FRAMEWORK_HOME`, `~/.triparty-framework/config`, or the installed bootstrap path.
- The agent must not reconstruct the framework by creating new ad hoc Markdown files when the installed framework cannot be found.
- If the framework cannot be located, the agent must say it is not installed or not discoverable in the current environment and ask whether to clone or install it.
- New-session activation should use existing commands (`/triparty`, `/tp`, `triparty preflight`, `triparty run`, `triparty status`, or the repository's `scripts/triparty.sh`) rather than inventing a new workflow.

## Tri-party Collaboration Workflow

- Step 1: Define the shared question, expected deliverable, and decision boundary.
- Step 2: Run a source availability check for Codex, Claude, and Gemini before starting the review.
- Step 3: Collect each party's independent opinion with preserved source labels.
- Step 4: Run mutual cross-audit: Claude reviews Gemini's result, Gemini reviews Claude's result, and Codex reviews the combined evidence before synthesis.
- Step 5: Compare agreements, disagreements, risks, and missing evidence after the cross-audit, not before it.
- Step 6: Before synthesis, verify that the source-status table marks Claude and Gemini as completed and that cross-audit status is completed, or explicitly label the result as partial.
- Step 7: Produce a consolidated recommendation that distinguishes consensus, majority view, unresolved conflict, and missing inputs.
- Step 8: Feed repeated failures, useful patterns, and protocol gaps into the daily standard extraction process.

## Tri-party Mutual Audit Gate

- Division of labor does not remove mutual supervision: each party's major output must be checked by at least one other party before it can support a true tri-party conclusion.
- Default audit pairing: Claude audits Gemini's review, Gemini audits Claude's review, and Codex performs the final synthesis audit against source status, artifacts, and the user's latest request.
- A result is not eligible for "true tri-party synthesis" unless both independent reviews and both cross-audits are completed and archived.
- If any review or cross-audit is missing, timed out, failed, empty, mislabeled, or hash-mismatched, report the result as partial and list the missing or invalid input.
- Prefer `scripts/triparty-cross-audit.sh <run-dir>` after `scripts/triparty-review.sh` and before `scripts/triparty-merge.sh`.
