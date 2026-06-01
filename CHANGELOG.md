# Changelog

## 0.1.0 - 2026-06-01

- Established the portable tri-party core: preflight, review, cross-audit, merge, state, lint, and regression.
- Added public launch materials: product README, MIT license, contribution guide, examples, and GitHub issue templates.
- Added release checklist, security notes, and failure-recovery example for partial tri-party runs.
- Added `scripts/triparty.sh` as the unified user-facing CLI.
- Added `state.json` and `docs/framework/state.schema.json` as the machine-readable run state contract.
- Added mutual audit gating: Claude audits Gemini, Gemini audits Claude, Codex performs final synthesis.
- Added `docs/framework/adapter-contract.md` for external adapters.
- Added the first external adapter: local HTTP adapter at `adapters/http/triparty_http_adapter.py`.
- Added adapter smoke testing with `scripts/triparty-adapter-smoke.sh`.
- Added loopback-first adapter safety, optional bearer/token auth, and runtime `state.json` hash validation.
- Added offline artifact injection through `scripts/triparty.sh inject`.
- Added `resume`, `runs`, `stats`, and `archive` CLI operations.
- Added structured state errors, detailed provenance fields, core version, and model-binding hash in `state.json`.
- Added the stdio MCP adapter at `adapters/mcp/triparty_mcp_adapter.py` and smoke test `scripts/triparty-mcp-smoke.sh`.
- Added regression coverage for invalid injection inputs and injected artifact hash mismatch.
- Added runner-written artifact metadata and completion-marker checks to the merge gate.
- Added atomic status/state file publication and preflight model-binding SHA256 recording.
