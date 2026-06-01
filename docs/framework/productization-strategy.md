# Tri-party Productization Strategy

## Decision

The canonical product shape is a portable core kit with thin adapters. A Codex Skill can exist, but it is only one adapter. It must not become the framework core.

## Why

- Users may start from Codex, Claude, Gemini, a local CLI, an MCP server, a browser UI, or a team workflow tool.
- The core value is the protocol: source verification, capability dispatch, independent review, mutual cross-audit, merge gating, evidence archives, and daily standard extraction.
- If the core is packaged only as a Codex Skill, non-Codex users lose the workflow or receive a weaker reimplementation.

## Portable Core

The core should remain file and CLI based:

- `AGENTS.md`: durable working agreements.
- `docs/framework/tri-party-protocol.md`: protocol and gates.
- `docs/framework/model-binding.yaml`: current role-to-model binding.
- `docs/framework/model-binding.schema.json`: expected binding shape.
- `docs/framework/state.schema.json`: machine-readable run state contract.
- `scripts/triparty-preflight.sh`: source availability check.
- `scripts/triparty-review.sh`: independent Claude/Gemini review runner.
- `scripts/triparty-cross-audit.sh`: mutual review audit runner.
- `scripts/triparty-merge.sh`: final merge gate.
- `scripts/triparty.sh`: unified product entrypoint and state generator.
- `scripts/triparty-lint.sh`: framework consistency check.
- `scripts/triparty-regression.sh`: failure-mode regression tests.
- `adapters/http/triparty_http_adapter.py`: first external adapter.
- `adapters/mcp/triparty_mcp_adapter.py`: first MCP adapter.
- `docs/framework/adapter-contract.md`: adapter rules and endpoint contract.
- `VERSION` and `CHANGELOG.md`: release identity and change history.
- `docs/framework/runs/`: audit trail and source evidence.

## Thin Adapters

Each ecosystem should wrap the portable core, not fork it:

- Codex adapter: a Skill that teaches Codex when to run the core scripts and how to summarize results.
- Claude adapter: a Claude command or skill that can run or consume the same run directory and produce Claude-labeled output.
- Gemini adapter: a Gemini CLI extension or prompt template that uses the same model binding and MCP allowlist.
- MCP adapter: a small server exposing preflight, review, cross-audit, merge, lint, and regression as tools.
- Front-end adapter: a UI for creating runs, watching party status, reading cross-audits, and exporting summaries.
- CI adapter: a repository check that runs lint and regression before protocol changes are accepted.

## User-facing Commands

The default user path should be:

```bash
scripts/triparty.sh run "<question>" [context-files...]
scripts/triparty.sh status [run-dir]
```

Advanced users may still run individual stages:

```bash
scripts/triparty.sh preflight
scripts/triparty.sh review "<question>" [context-files...]
scripts/triparty.sh cross-audit [run-dir]
scripts/triparty.sh merge [run-dir]
scripts/triparty.sh inject [review|cross-audit] <party> <run-dir> <artifact-file>
scripts/triparty.sh resume [run-dir]
scripts/triparty.sh runs [limit]
scripts/triparty.sh stats
scripts/triparty.sh archive [--keep N] [--dry-run]
```

Every run should expose `state.json` as the machine-readable status surface for adapters and UI. The state file must conform to `docs/framework/state.schema.json`.

## First External Adapter

The first external adapter is a local HTTP adapter:

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

It exposes health, runs, status/state, run, review, cross-audit, merge, preflight, lint, and regression endpoints. This adapter is intentionally local-first and dependency-free so it can become the bridge for a browser UI, CI job, MCP wrapper, or another agent runtime.

Security boundary:

- Default bind is loopback-only.
- Non-loopback binding requires `--allow-non-loopback` and an auth token.
- Returned state includes runtime validation against current artifact hashes.

## MCP Adapter

The MCP adapter is:

```bash
python3 adapters/mcp/triparty_mcp_adapter.py
```

It exposes the same core operations as MCP tools, including offline injection, resume, runs, stats, archive, lint, and regression. This validates that the portable core can be called by agent tooling before a UI exists.

## Packaging Rule

The portable core owns truth. Adapters own convenience.

Adapter outputs must write back to the same run structure and preserve:

- Source labels.
- Review status.
- Cross-audit status.
- Artifact hashes.
- Error codes.
- Handoff prompts for missing parties.

## Versioning Rule

Use semantic versions for the portable core once the scripts stabilize:

- Patch: docs, wording, prompt copy, or non-breaking checks.
- Minor: new adapter, new report field, new optional gate.
- Major: run directory schema change or merge-gate compatibility break.
