# Tri-party Adapter Contract

## Purpose

Adapters connect external environments to the portable core without changing core truth. An adapter may improve access, UI, auth, or deployment, but it must not redefine tri-party status or synthesize conclusions outside the merge gate.

## Required Invariants

- The portable core remains the source of truth.
- Adapters must call `scripts/triparty.sh` or read artifacts created by it.
- Adapters must preserve run directories, source labels, review artifacts, cross-audit artifacts, hashes, and error codes.
- Adapters must read the actual `runs_dir` / `run_dir` from core output or `state.json`; the repo-local `docs/framework/runs` path is only the preferred default and may fall back to `${TMPDIR:-/tmp}/triparty-runs`.
- Adapters must preserve provenance details for user-supplied artifacts: origin, injected timestamp, source path, source hash, and copied artifact hash.
- Adapters must preserve runner-written artifact metadata and completion markers. Missing metadata, party/stage mismatch, marker mismatch, hash drift, or source-label contamination must remain merge-blocking.
- Core status writers should publish state/status files through temp-file-and-rename atomic writes so adapters never trust partially written JSON or env files.
- Adapters must not mark a run as true tri-party unless `state.json` says `true_triparty_ready: true`.
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
