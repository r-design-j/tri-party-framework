# Release Checklist

Use this checklist before creating a GitHub release or promoting the project publicly.

## Source-Truth Gate

- [ ] `scripts/triparty-lint.sh` passes.
- [ ] `scripts/triparty-regression.sh` passes.
- [ ] `scripts/triparty-adapter-smoke.sh` passes.
- [ ] `scripts/triparty-mcp-smoke.sh` passes.
- [ ] A current tri-party review run has `true_triparty_ready: true`.
- [ ] The release notes do not claim true tri-party output without a run directory and source status.

## Public Documentation Gate

- [ ] README explains that Codex sub-agents do not count as Claude or Gemini.
- [ ] README explains that preflight success is not the same as review completion.
- [ ] README explains partial state and `true_triparty_ready`.
- [ ] CONTRIBUTING preserves source labels, artifact hashes, metadata headers, and completion markers.
- [ ] Examples include both normal operation and failure recovery.
- [ ] SECURITY explains adapter binding, authentication, artifact sensitivity, and report handling.

## Adapter Safety Gate

- [ ] HTTP adapter still defaults to `127.0.0.1`.
- [ ] Non-loopback binding still requires explicit opt-in and authentication.
- [ ] MCP adapter remains a thin wrapper around the portable core.
- [ ] Adapters do not synthesize their own readiness labels.
- [ ] `state.json` remains the machine-readable source of truth.

## GitHub Launch Gate

- [ ] Repository description is clear and not over-claimed.
- [ ] Topics include Codex, Claude, Gemini, MCP, multi-agent, source verification, and developer tools.
- [ ] Issues and Discussions are enabled.
- [ ] Initial `good first issue` items are scoped and useful.
- [ ] The release tag matches `VERSION`.
