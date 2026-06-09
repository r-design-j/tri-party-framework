# AgentParty / triparty Adapter Contract

## Purpose

Adapters connect external environments to AgentParty product packs without changing core truth. An adapter may improve access, UI, auth, transcript capture, or deployment, but it must not redefine pack status or synthesize conclusions outside the pack gate.

The current executable adapter contract is for the `triparty` pack. Generic AgentParty and other product packs must preserve the same truth rules while using their own completion semantics.

The generic CLI surface is `scripts/agentparty.py` / `scripts/agentparty.sh`. It may discover packs and scaffold pack-specific runs, but it must delegate `triparty` execution to `scripts/triparty.sh` and must not redefine true tri-party readiness.

## Required Invariants

- The portable core or product pack gate remains the source of truth.
- Adapters must call `scripts/triparty.sh` or read artifacts created by it.
- Adapters must preserve run directories, source labels, review artifacts, cross-audit artifacts, hashes, and error codes.
- Adapters must read the actual `runs_dir` / `run_dir` from core output or `state.json`; the repo-local `docs/framework/runs` path is only the preferred default and may fall back to `${TMPDIR:-/tmp}/triparty-runs`.
- Adapters must preserve provenance details for user-supplied artifacts: origin, injected timestamp, source path, source hash, and copied artifact hash.
- Adapters must preserve runner-written artifact metadata and completion markers. Missing metadata, party/stage mismatch, marker mismatch, hash drift, or source-label contamination must remain merge-blocking.
- Core status writers should publish state/status files through temp-file-and-rename atomic writes so adapters never trust partially written JSON or env files.
- Adapters must not mark a run as true tri-party unless `state.json` says `true_triparty_ready: true`.
- Adapters for non-triparty packs must not write or imply `true_triparty_ready`.
- Adapters for 2-agent packs must label results as pack-ready, partial, blocked, or scoped according to that pack's contract.
- Adapters must validate `state.json` against the current artifact hashes before returning it as trusted state.
- Adapters must expose partial states honestly and keep handoff prompts available when a party is missing.
- Adapters must treat `state.json` as the machine-readable status contract.
- Network adapters must default to loopback-only. Non-loopback binding requires explicit opt-in and authentication.

## Canonical State

Every adapter should read:

- `state.json`
- `source-status.md`
- `cross-audit-status.md`
- `merge-status.md`
- `merge-input.md` when `true_triparty_ready` is true
- `partial-report.md` when the merge gate fails

`state.json` must conform to `docs/framework/state.schema.json`.

For AgentParty product-pack discovery, adapters should read `docs/framework/agentparty-packs.json`. The registry tells the UI, the current `agentparty` CLI scaffold, and future native surfaces which packs exist, which OS paths are supported, and which claims are forbidden.
Adapters that need user installation should call or mirror `scripts/agentparty.sh install --pack <pack-id> --target-os <os>` first. It defaults to dry-run and requires explicit `--execute` before writing managed bootstrap artifacts. Execute must run on the detected target host; adapters must not spoof `--target-os` to force writes on a different platform. Adapters that only need guidance should call or mirror `scripts/agentparty.sh install-plan --pack <pack-id> --target-os <os>`. The install plan is the boundary-safe source for macOS/Linux/WSL2 executable commands, Windows native preparation commands, blocked commands, and whether a pack can ever claim `true_triparty_ready`.
For cleanup UX, adapters should expose `scripts/uninstall-triparty-global-bootstrap.sh --dry-run` before `--execute`, or `scripts/uninstall-triparty-global-bootstrap.ps1 -DryRun` before `-Execute` on native PowerShell. Adapters should not delete user-modified files outside the uninstaller's managed-artifact checks.

For injected artifacts, adapters must read the relevant `review_provenance_detail` or `cross_audit_provenance_detail` object instead of inferring source from filenames. `origin=user_supplied` means the artifact was provided through `inject`; `source_sha256` records the original file hash, and `artifact_sha256` records the copied run artifact hash.

The merge gate also validates artifact-level metadata written at the top of every accepted review and cross-audit file:

- `triparty_artifact: v1`
- `party: Claude|Gemini`
- `stage: review|cross-audit`
- `completion_marker: TRIPARTY_REVIEW_COMPLETE|TRIPARTY_CROSS_AUDIT_COMPLETE`

Preflight records the active `model-binding.yaml` SHA256 so later review, merge, and adapter layers can detect binding drift.

## Recommended Command Surface

Adapters should expose these operations:

| Operation | Core Command | Notes |
| --- | --- | --- |
| health | n/a | Adapter liveness and version. |
| runs | filesystem read | List recent review runs. |
| status | `scripts/triparty.sh status [run-dir]` | Refresh and return `state.json`. |
| run | `scripts/triparty.sh run "<question>" [context-files...]` | Full review -> cross-audit -> merge flow. |
| review | `scripts/triparty.sh review "<question>" [context-files...]` | Stage-only call for advanced workflows. |
| cross-audit | `scripts/triparty.sh cross-audit [run-dir]` | Stage-only call. |
| merge | `scripts/triparty.sh merge [run-dir]` | Stage-only call. |
| inject | `scripts/triparty.sh inject [review\|cross-audit] <party> <run-dir> <artifact-file>` | Offline transcript/artifact injection. |
| resume | `scripts/triparty.sh resume [run-dir]` | Continue from the latest safe stage. |
| runs | `scripts/triparty.sh runs [limit]` | List recent run states. |
| stats | `scripts/triparty.sh stats` | Aggregate run health. |
| archive | `scripts/triparty.sh archive [--keep N] [--dry-run]` | Manage run history. |
| lint | `scripts/triparty-lint.sh` through `triparty.sh` | Local framework consistency check. |
| regression | `scripts/triparty-regression.sh` through `triparty.sh` | Historical failure-mode tests. |

## Local HTTP Adapter

The first external adapter is `adapters/http/triparty_http_adapter.py`.

Default local start:

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

Endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Adapter liveness, version, root path. |
| GET | `/runs?limit=20` | Recent run list with available state. |
| GET | `/status?run_dir=...` | Refresh and return status for a run. |
| GET | `/state?run_dir=...` | Same as status; convenient machine endpoint. |
| POST | `/run` | Body: `{"question":"...", "context_files":[]}`. |
| POST | `/review` | Body: `{"question":"...", "context_files":[]}`. |
| POST | `/cross-audit` | Body: `{"run_dir":"..."}`. |
| POST | `/merge` | Body: `{"run_dir":"..."}`. |
| POST | `/inject` | Body: `{"stage":"review","party":"claude","run_dir":"...","artifact_file":"..."}`. |
| POST | `/resume` | Body: `{"run_dir":"..."}`. |
| GET | `/stats` | Aggregate run health. |
| POST | `/archive` | Body: `{"keep":20,"dry_run":true}`. |
| POST | `/preflight` | Optional body: `{"out_dir":"docs/framework/runs/preflight-..."}`. |
| POST | `/lint` | Run local lint. |
| POST | `/regression` | Run local regression suite. |

## MCP Adapter

The stdio MCP adapter is `adapters/mcp/triparty_mcp_adapter.py`.

It exposes these tools:

- `triparty_status`
- `triparty_run`
- `triparty_review`
- `triparty_cross_audit`
- `triparty_merge`
- `triparty_inject`
- `triparty_resume`
- `triparty_runs`
- `triparty_stats`
- `triparty_archive`
- `triparty_lint`
- `triparty_regression`

The MCP adapter is a thin wrapper around `scripts/triparty.sh`; it must not synthesize its own true/partial status.

## Feishu Claw Pack Boundary

The `claude-code-feishu-claw` product pack is currently transcript-based:

- Claude Code output is an artifact.
- Feishu Claw output is a transcript, Feishu document link, or user-supplied operation summary.
- Standard manual evidence bundles are created through `scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir <run-dir> --out <dir>`.
- Pack evidence is imported through `scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle <dir>/agentparty-claw-evidence.json`, with direct `--run-dir ... --feishu-link ...` flags kept for compatibility.
- Pack state is validated through `scripts/agentparty.sh validate-run --run-dir <run-dir>`.
- The adapter or user must preserve source labels and timestamps.
- Placeholder template files containing `TODO_AGENTPARTY_REPLACE` must not be accepted as real evidence.
- Evidence files below the CLI's minimum content threshold and Feishu links that are not `http://` or `https://` URLs must not be accepted as pack-ready evidence.
- Bundle artifact paths must stay inside the evidence bundle directory, and an explicit `--run-dir` must match the bundle's recorded `run_dir`.
- Missing Feishu permissions, missing transcript, or missing document evidence must produce partial or blocked status.
- This 2-agent pack must never be surfaced as true tri-party.

The target bridge scaffold for the same pack is created through:

```bash
scripts/agentparty.sh bridge-kit --pack claude-code-feishu-claw --task "<task>" --out "<bridge-dir>"
scripts/agentparty.sh bridge-validate --bridge-dir "<bridge-dir>"
```

This bridge state treats Feishu Claw as the user-facing intake/report surface and Claude Code as a controlled runner. Adapters must preserve these bridge rules:

- `state.json` must use `schema_version=agentparty.claw-bridge-state.v1`.
- Feishu may enqueue or report tasks, but it must not directly execute arbitrary local shell.
- Claude Code execution must go through a controlled runner with an allowlist, audit log, and explicit user/auth boundary.
- Shared resources are prompts, skill contracts, manifests, evidence files, and state files; private runtime folders such as `~/.claude/skills` and `~/.codex/skills` are not shared directly.
- The bridge must keep one active writer, revision tracking, and read-only reviewers.
- Claw reviews Claude output and Claude reviews Claw output; if either side is missing or lacks evidence, the bridge remains partial or blocked.
- Native Feishu Claw callback support is not implied by a valid bridge scaffold.

## Resume and Archive Semantics

`archive` moves old runs from `docs/framework/runs/review-*` to `docs/framework/runs/archive/review-*`. Archived runs are excluded from default `runs`, `stats`, and latest-run resolution. They can still be resumed only when the archived run directory is passed explicitly, preserving the same merge gate and hash checks.

## Safety Boundary

The HTTP adapter defaults to `127.0.0.1`. It restricts run directories to `docs/framework/runs/` and context files to this workspace root.

Non-loopback binding is refused unless both are true:

- `--allow-non-loopback` is passed.
- `--auth-token` or `TRIPARTY_ADAPTER_AUTH_TOKEN` is set.

When an auth token is configured, clients must send either:

- `Authorization: Bearer <token>`
- `X-Triparty-Token: <token>`

Do not expose the adapter to an untrusted network without request logging, rate limiting, and a deployment-specific auth policy.
