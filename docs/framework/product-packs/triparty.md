# Product Pack: triparty

## Positioning

`triparty` is the first productized AgentParty pack.
It binds the generic AgentParty protocol to exactly three parties:

- Codex: implementation owner and final synthesis.
- Claude Code: reasoning, architecture, and long-chain review.
- Gemini CLI: multimodal, Google-context, and broad-context review.

This pack is the only current pack allowed to claim `true_triparty_ready`, and only after the release gate passes.

## Install Path

macOS / Linux / Windows WSL2:

```bash
git clone https://github.com/r-design-j/tri-party-framework.git
cd tri-party-framework
chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py
scripts/triparty-lint.sh
scripts/agentparty.sh install --pack triparty --target-os auto
scripts/agentparty.sh install --pack triparty --target-os auto --execute
triparty preflight
```

Windows native PowerShell/CMD is not a shipped path for this bash-based pack. Use WSL2 or wait for the generic AgentParty CLI route.

AgentParty can also delegate into this pack:

```bash
scripts/agentparty.sh run --pack triparty --task "<task>"
```

This calls the existing `scripts/triparty.sh run` core; it does not redefine tri-party readiness.

To print the OS-specific installation plan:

```bash
scripts/agentparty.sh onboard --pack triparty --target-os auto
scripts/agentparty.sh install --pack triparty --target-os auto
scripts/agentparty.sh install --pack triparty --target-os auto --execute
scripts/agentparty.sh install-plan --pack triparty --target-os auto
scripts/agentparty.sh install-plan --pack triparty --target-os windows_powershell
scripts/agentparty.sh quickstart --pack triparty --target-os auto
scripts/agentparty.sh guide --pack triparty --target-os auto
```

`agentparty onboard --pack triparty` is the recommended first-use surface for productized TriParty. It returns a readiness checklist, OS-specific next step, install dry-run/execute sequence, preflight command, first `triparty run`, release-gate command, and a copy-to-agent prompt. It is read-only: it does not run models, install global files, or claim completion from probe success.

`agentparty install` defaults to dry-run. `--execute` installs only managed bootstrap artifacts: discovery config, `triparty`/`agentparty` wrappers, Codex/Claude bootstrap blocks, and Claude Code slash files.

`agentparty quickstart --pack triparty` prints a one-copy install path and agent delegation prompt for the requested OS target. On native PowerShell it prints WSL2 handoff commands and does not expose direct triparty execution.

`agentparty guide --pack triparty` prints the next install/run/release-gate command for the requested OS target. On `windows_powershell`, it points to WSL2 and does not claim native triparty execution.

On native Windows, `packs`, `doctor`, `install` dry-run, `install-plan`, `prompt`, `guide`, and read-only validation surfaces are allowed compatibility surfaces; `install --execute`, `run`, and `doctor --deep` remain blocked until native execution is productized.

To inspect or remove global bootstrap artifacts:

```bash
scripts/uninstall-triparty-global-bootstrap.sh --dry-run
scripts/uninstall-triparty-global-bootstrap.sh --execute
```

The uninstaller removes only managed bootstrap blocks, current-root wrappers/config, and unmodified copied Claude slash files.

Native PowerShell cleanup uses the matching scaffold:

```powershell
.\scripts\uninstall-triparty-global-bootstrap.ps1 -DryRun
.\scripts\uninstall-triparty-global-bootstrap.ps1 -Execute
```

This is cleanup-only and does not ship native PowerShell tri-party execution.

## Completion Gate

The pack is complete only when:

- Claude preflight is available.
- Gemini preflight is available and Gemini auth doctor reports `authenticated`.
- Claude review artifact is completed.
- Gemini review artifact is completed.
- Claude audits Gemini.
- Gemini audits Claude.
- Merge gate passes.
- Release gate validates `state.json`.
- `state.json.true_triparty_ready` is `true`.

Probe success alone is not completion.

## Runtime Boundaries

- Claude Code slash entrypoints `/triparty` and `/tp` are Claude Code adapter surfaces.
- Codex uses the portable `triparty` CLI or repository scripts.
- HTTP and MCP adapters must read or call the same portable core and must not synthesize status.

## User Promise

The user can copy one install prompt to an AI agent. The agent installs the pack, runs preflight, and reports the install path and readiness. Missing Claude, Gemini, auth, permissions, or release evidence must be reported as partial or blocked.
