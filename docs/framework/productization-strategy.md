# AgentParty / triparty Productization Strategy

## Decision

The canonical product shape is now:

1. `AgentParty`: the generic protocol layer for multi-agent work.
2. Product packs: concrete installable presets under AgentParty.
3. Thin adapters: runtime-specific surfaces that call or read pack truth.

This remains a portable core kit with thin adapters; the new AgentParty layer clarifies what the core must generalize beyond the current Python `agentparty` scaffold before native cross-platform productization is claimed.

`triparty` remains the first productized pack. A Codex Skill can exist, but it is only one adapter. It must not become the framework core.

## Why

- Users may start from Codex, Claude, Gemini, a local CLI, an MCP server, a browser UI, or a team workflow tool.
- The same skill can degrade across agents when context loading, tools, memory, auth, and output gates differ. AgentParty must make those differences explicit instead of assuming portability.
- The core value is the protocol: source verification, capability dispatch, independent review, mutual cross-audit, merge gating, evidence archives, and daily standard extraction.
- If the core is packaged only as a Codex Skill, non-Codex users lose the workflow or receive a weaker reimplementation.

## AgentParty Core

AgentParty owns the reusable object model:

- Agent registry and capability roles.
- Skill portability contracts.
- Product pack registry.
- OS support matrix.
- Evidence and artifact rules.
- Pack-specific completion semantics.
- Adapter boundaries.

Core files:

- `docs/framework/agentparty-protocol.md`: generic protocol layer.
- `docs/framework/agentparty-pack.schema.json`: product pack registry schema.
- `docs/framework/agentparty-packs.json`: current pack registry.
- `docs/framework/product-packs/`: one document per product pack.
- `docs/framework/agentparty-managed-install-lifecycle.md`: install/rollback manifest states and regression evidence.
- `scripts/agentparty-pack-lint.py`: registry consistency check.

## Portable Core

The current executable portable core is the `triparty` product pack and remains file and CLI based:

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
- `scripts/agentparty.py quickstart`: one-copy install/use path and delegation prompt for each product pack and OS target.
- `scripts/agentparty.py onboard`: productized TriParty first-use status surface with OS boundary, readiness checks, install/preflight/run/release-gate steps, and copy-to-agent prompt.
- `scripts/agentparty.py install`: safe-by-default product-pack install wrapper for managed global bootstrap artifacts.
- `scripts/agentparty.py guide`: product-pack next-step runbook for install, partial evidence, blocked, scoped, and pack-ready states.
- `scripts/agentparty.py release-check`: AgentParty-level productization gate for quick/full release-candidate checks before commit or public packaging.
- `scripts/agentparty.py package`: read-only release-bundle generator with `INSTALL.md`, `agentparty-package-manifest.json`, file hashes, pack boundaries, and optional tarball archive.
- `.claude/commands/agentparty-claw.md` / `.claude/commands/ap-claw.md`: Claude Code adapter for creating and inspecting Claude Code + Feishu Claw local handoff kits.
- `scripts/install-triparty-global-bootstrap.sh` / `scripts/uninstall-triparty-global-bootstrap.sh` / `scripts/uninstall-triparty-global-bootstrap.ps1`: global discovery lifecycle installer and managed cleanup paths, with `managed-install.env` hash tracking for installed managed files; see `docs/framework/agentparty-managed-install-lifecycle.md` for the manifest state table and regression evidence.
- `adapters/http/triparty_http_adapter.py`: First External Adapter for the productized triparty pack.
- `adapters/mcp/triparty_mcp_adapter.py`: first MCP adapter.
- `docs/framework/adapter-contract.md`: adapter rules and endpoint contract.
- `VERSION` and `CHANGELOG.md`: release identity and change history.
- `docs/framework/runs/`: audit trail and source evidence.

The first generic CLI scaffold now exists as `scripts/agentparty.py` / `scripts/agentparty.sh`; it supports product-pack discovery, doctor checks, one-copy quickstarts, safe-by-default managed install dry-runs/execution, OS-specific install planning, prompt generation, Claw kit generation, pack-scoped run scaffolding, state-aware pack guides, Claw evidence bundle templates/import, direct Claw evidence import flags, pack-state validation, AgentParty release checks, and read-only release bundle packaging. It does not replace the executable `triparty` core. Native Windows PowerShell install execution/run/evidence execution remains roadmap until tested on Windows.

## Current Product Packs

| Pack | Agents | Status | Completion semantics |
| --- | --- | --- | --- |
| `triparty` | Codex + Claude + Gemini | Productized | `true_triparty_ready=true` only after release gate |
| `claude-code-feishu-claw` | Claude Code + Feishu Claw | Scaffolded | `pack_ready` / `partial` / `blocked` / `scoped`, never true tri-party |

The pack registry in `docs/framework/agentparty-packs.json` is the source of truth for website cards, CLI pack selection, and adapter UX.

## Cross-platform Rule

Current bash/Python pack execution supports macOS, Linux, and Windows WSL2.
Native Windows PowerShell/CMD/Git Bash/MSYS/Cygwin support is a generic AgentParty CLI roadmap item and must not be presented as shipped. `scripts/agentparty.ps1` is only a compatibility scaffold for discovery, doctor, quickstart, install-plan, prompt, guide, validate-run, kit, and evidence-template preparation/read-only surfaces; Windows non-WSL shell `install --execute`, `run`, `doctor --deep`, and `evidence` are blocked until verified on Windows. Current PowerShell evidence is static/regression/package-boundary evidence only unless a separate real Windows host run is recorded.

`agentparty install-plan --pack <pack-id> --target-os <os>` is the user-facing boundary router:

- `macos`, `linux`, and `windows_wsl2` return executable commands for the selected product pack.
- `windows_powershell` returns preparation commands plus explicit blocked commands and WSL2 handoff.
- Non-triparty packs can return `pack_ready` plans only; they cannot expose a path to `true_triparty_ready`.
- Supported executable paths also return cleanup commands for `scripts/uninstall-triparty-global-bootstrap.sh --dry-run` and `--execute`.

`agentparty install --pack <pack-id> --target-os <os>` is the user-facing managed installer:

- Defaults to dry-run and reports the managed actions without writing files.
- Requires `--execute` before calling `scripts/install-triparty-global-bootstrap.sh`.
- Executes only on macOS, Linux, and Windows WSL2 target paths.
- Execute also requires the requested target OS to match the detected host OS; dry-run may inspect other targets, but `--execute` must be run inside the host that will receive the install.
- Blocks native PowerShell execute and points users to WSL2.
- For `claude-code-feishu-claw`, installs the shared AgentParty/triparty bootstrap only; Feishu Claw connector/auth automation remains roadmap.

Global lifecycle rule: uninstall must be explicit and evidence-safe. The uninstaller defaults to dry-run and only removes managed bootstrap blocks, wrappers/config containing the current repo root, the managed install manifest, and copied Claude slash files that still match the install manifest or repository source.
The PowerShell uninstaller is a cleanup scaffold for native Windows users; it mirrors dry-run/execute and modified-file skip semantics, but it does not ship native PowerShell run/evidence execution and must not be cited as native Windows host validation without a separate Windows evidence run.

Every product pack must declare `macos`, `linux`, `windows_wsl2`, and `windows_powershell` status.

`agentparty release-check` is the local release-candidate gate:

- Default quick mode runs Python compile, pack registry lint, triparty lint, `git diff --check`, static website anchor checks, and exact website command-card copy command checks.
- `--full` also runs `scripts/triparty-regression.sh`.
- `--triparty-run-dir <run-dir>` additionally runs `scripts/triparty.sh release-gate <run-dir>`.
- It is a packaging/readiness gate only; it does not claim native PowerShell execution or Feishu connector automation.

`agentparty package --out <dir> --archive` is the local distribution-bundle surface:

- Copies only release-facing framework files: protocol docs, pack schemas/registry, product-pack docs, entrypoint scripts, installer/uninstaller scripts, adapters, examples, website files, and Claude slash command/skill files required by the installer.
- Writes `INSTALL.md` and `agentparty-package-manifest.json` with sha256 hashes, pack IDs, OS boundaries, blocked native PowerShell commands, and Feishu Claw roadmap notes.
- Excludes run directories, AgentParty run artifacts, continuity state, caches, and other local evidence.
- Does not install global files, call models, run Feishu automation, or turn native PowerShell execution into shipped capability.

`.github/workflows/agentparty-release.yml` is the repeatable release-artifact workflow:

- Ubuntu and macOS jobs run `agentparty release-check --full --json`, then build and upload `agentparty package` bundles.
- The Windows job supports the read-only PowerShell package surface, then asserts native PowerShell `install --execute`, `run`, `doctor --deep`, and `evidence` are blocked with `E_BLOCKED_OS` and WSL2 handoff text.
- The workflow is not a model-run workflow and must not be used as evidence that native PowerShell execution is shipped.

Regression-only Windows simulation:

- `AGENTPARTY_FORCE_NATIVE_WINDOWS=1` forces the Python CLI to behave as a native Windows non-WSL host.
- This is a test hook for macOS/Linux CI and local regression only.
- It must only verify blocked execution and preparation surfaces; it must not be documented as a user install path or as native Windows support.
- Covered boundaries: `install --execute`, `run`, `doctor --deep`, and `evidence` are blocked; `guide`, `validate-run`, `kit`, and `evidence-template` remain preparation/read-only scaffolds.

## Thin Adapters

Each ecosystem should wrap the portable core, not fork it:

- Codex adapter: a Skill that teaches Codex when to run the core scripts and how to summarize results.
- Claude adapter: a Claude command or skill that can run or consume the same run directory and produce Claude-labeled output.
- Claude Code Claw adapter: `/agentparty-claw` and `/ap-claw` call `agentparty kit/guide/validate-run` for the `claude-code-feishu-claw` pack without calling Feishu or importing evidence.
- Gemini adapter: a Gemini CLI extension or prompt template that uses the same model binding and MCP allowlist.
- MCP adapter: a small server exposing preflight, review, cross-audit, merge, lint, and regression as tools.
- Front-end adapter: a UI for creating runs, watching party status, reading cross-audits, and exporting summaries.
- CI adapter: a repository check that runs lint and regression before protocol changes are accepted.
- Feishu Claw adapter path: for now, transcript, document links, operation summaries, and Claude review notes are pack artifacts standardized through `agentparty kit` or `agentparty evidence-template` and imported through `agentparty evidence --bundle`, with direct evidence flags kept for compatibility. A future connector may automate collection, but the protocol must still preserve source labels and completion semantics.

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

Every `triparty` run should expose `state.json` as the machine-readable status surface for adapters and UI. The state file must conform to `docs/framework/state.schema.json`.

Non-triparty AgentParty packs must use pack-specific readiness fields and must not set `true_triparty_ready`.

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
