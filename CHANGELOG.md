# Changelog

## 0.1.0 - 2026-06-01

- Established the portable tri-party core: preflight, review, cross-audit, merge, state, lint, and regression.
- Added public launch materials: product README, MIT license, contribution guide, examples, and GitHub issue templates.
- Added release checklist, security notes, and failure-recovery example for partial tri-party runs.
- Added release gate scripts and Gemini CLI stability hardening: headless policy, policy-hash recording, retry/backoff, runtime-noise sanitization, capacity thresholds, sanitizer-version diagnostics in `state.json`, and release-level state validation.
- Added a global new-session bootstrap installer so fresh Codex and Claude Code sessions can discover the installed framework instead of recreating Markdown protocols.
- Added Claude Code slash entrypoints `/triparty` and `/tp`, installed as thin adapters over the existing portable core.
- Refined merge source-label scanning so adapter-purity text about not directly calling `claude` or `gemini` is not misread as missing-party source status.
- Refined release-gate latest-run resolution so preflight-only `review-*` directories do not block valid pre-push gates.
- Added `scripts/triparty.sh` as the unified user-facing CLI.
- Added `state.json`, `docs/framework/state.schema.json`, and `scripts/triparty-validate-state.py` as the machine-readable run state contract and validator.
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
- Added writable runs-directory fallback through `scripts/triparty-runs-dir.sh`; core CLI, preflight, review, release gate, and HTTP adapter now record/read the actual runs directory instead of assuming `docs/framework/runs`.
- Added `scripts/triparty-gemini-auth-doctor.sh` and preflight/state integration so Gemini browser-auth waits are classified before long review calls.
- Added continuity checkpoint/bootstrap commands with manifest hash verification for file-backed session handoff.
- Tightened release-gate/state validation so true release claims require authenticated Gemini auth-doctor status and complete review plus cross-audit evidence.
