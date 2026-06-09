# AgentParty Protocol

## Purpose

AgentParty is the generic multi-agent protocol layer under the current `triparty` product pack.
It exists to reduce a common user-facing failure mode: the same skill or workflow produces different quality when copied across agent runtimes because each runtime has different context loading, tool access, memory rules, UI affordances, and review gates.

AgentParty makes those differences explicit. A product pack must declare:

- Which agents participate.
- Which capabilities each agent owns.
- How shared skills are normalized before use.
- What artifacts and evidence must be produced.
- Which audit topology is required.
- Which completion label is allowed.
- Which operating systems and runtime adapters are supported.

## Layers

| Layer | Owns | Examples |
| --- | --- | --- |
| Protocol | Common object model, evidence rules, audit topology, completion semantics | AgentParty |
| Product pack | Concrete agent roster, install path, state semantics, user prompts | `triparty`, `claude-code-feishu-claw` |
| Adapter | Runtime-specific invocation surface | CLI, Claude Code slash, Feishu Claw transcript, HTTP, MCP |
| Run | One execution with artifacts, state, and review evidence | `review-YYYYMMDD-HHMMSS`, transcript bundle |

The protocol owns truth. Product packs own defaults. Adapters own convenience.

## Core Objects

| Object | Meaning |
| --- | --- |
| `agent` | A real callable runtime or a user-supplied transcript source. |
| `capability` | What the agent is trusted to do in the pack. |
| `role` | The job assigned to the agent in a run, such as implementation, reasoning, context, operation, or review. |
| `skill_contract` | The normalized way a shared skill is loaded, scoped, executed, and reviewed across runtimes. |
| `artifact` | A file, transcript, state object, screenshot, report, or command output that can be inspected later. |
| `audit_topology` | Who reviews whose output and whether cross-audit is required. |
| `gate` | The release or completion rule that converts artifacts into a status label. |
| `run_state` | Machine-readable state for UI, adapters, handoff, and release gates. |

## Skill Portability Contract

A product pack that reuses the same skill across multiple agents must define these fields before claiming product readiness:

- `skill_name`: stable skill or workflow name.
- `runtime_entrypoints`: how each agent loads or invokes it.
- `context_required`: files, docs, links, memories, or product facts that must be loaded.
- `tool_boundary`: which tools are available, unavailable, or forbidden in each runtime.
- `expected_output`: artifact shape, summary shape, or state fields.
- `quality_gate`: tests, release gate, source check, visual QA, or human acceptance rule.
- `loss_controls`: where output may degrade across agents and how the pack detects or mitigates it.

This is the product answer to "same skill, different agent, different quality": do not assume parity; declare the differences and verify the shared result.

## Completion Semantics

AgentParty packs must not reuse `true_triparty_ready` unless the pack is exactly the Codex + Claude + Gemini `triparty` pack and its release gate has passed.

Allowed pack-level labels:

| Label | Meaning |
| --- | --- |
| `ready` | The pack-specific completion gate passed. |
| `partial` | At least one required agent, artifact, audit, or handoff is missing. |
| `blocked` | Execution cannot proceed without user action, credentials, OS support, or external state. |
| `scoped` | The pack produced a narrow artifact but did not satisfy its full workflow. |
| `roadmap` | The capability is documented as a future productization route only. |

For `triparty`, `ready` additionally requires `state.json.true_triparty_ready = true`.
For 2-agent packs, `ready` must use a pack-specific state field such as `pack_ready`; it must not be translated into true tri-party readiness.

## Operating System Policy

Current executable support:

- macOS: supported for current bash/Python-based product packs.
- Linux: supported for current bash/Python-based product packs.
- Windows WSL2: supported by entering Ubuntu or another Linux distribution and using the Linux path.
- Windows native PowerShell/CMD: a Python-based `scripts/agentparty.ps1` wrapper exists as a compatibility scaffold, but verified native Windows support remains roadmap until it is tested on Windows. Do not run bash scripts directly in native PowerShell.

Every product pack must include an `os_support` matrix and must state whether PowerShell-native support is `supported`, `blocked`, or `roadmap`.

## CLI Surface

The current generic AgentParty CLI is Python-based:

```bash
scripts/agentparty.sh packs
scripts/agentparty.sh doctor
scripts/agentparty.sh quickstart --pack triparty --target-os auto
scripts/agentparty.sh quickstart --pack claude-code-feishu-claw --target-os auto
scripts/agentparty.sh package --out dist/agentparty-release --archive
scripts/agentparty.sh prompt --pack claude-code-feishu-claw --task "<task>"
scripts/agentparty.sh kit --pack claude-code-feishu-claw --task "<task>" --out claw-kit
scripts/agentparty.sh bridge-kit --pack claude-code-feishu-claw --task "<task>" --out claw-bridge
scripts/agentparty.sh bridge-validate --bridge-dir claw-bridge
scripts/agentparty.sh run --pack claude-code-feishu-claw --task "<task>"
scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir "<run-dir>"
scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir "<run-dir>" --out "<bundle-dir>"
scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle "<bundle-dir>/agentparty-claw-evidence.json"
scripts/agentparty.sh validate-run --run-dir "<run-dir>"
scripts/agentparty.sh run --pack triparty --task "<task>"
```

Claude Code adapter commands for the Claw pack:

```text
/agentparty-claw kit "<task>"
/agentparty-claw guide claw-kit
/agentparty-claw validate claw-kit
/ap-claw "<task>"
```

`triparty` pack runs delegate to `scripts/triparty.sh`.
`claude-code-feishu-claw` runs create a pack-scoped prompt/state bundle and remain `partial` until a Feishu Claw evidence bundle or equivalent direct evidence is supplied.
`quickstart` is the user-facing one-copy entrypoint; it prints pack-specific install commands and a copy-to-agent prompt without executing model or Feishu actions.
`kit` is the Claw pack handoff entrypoint; it creates a local directory containing prompts, task brief, state, evidence bundle, and allowed completion boundaries without calling Feishu, importing evidence, or modifying external systems.
`bridge-kit` is the Claw pack target-shape scaffold. It creates a Feishu-entry / Claude-runner bridge directory with shared resources, bridge `state.json`, revision log, mutual-supervision rules, and report templates. Feishu Claw is the intake/report surface, Claude Code is a controlled runner, one active writer owns each revision, and both sides must review the other side's output. It must not expose local shell directly to Feishu or claim native callback support.
`/agentparty-claw` and `/ap-claw` are Claude Code adapter commands for the same `kit`, `guide`, and `validate-run` surfaces; they must not claim `pack_ready` or `true_triparty_ready` by themselves.
`package` is the read-only distribution entrypoint. It creates `INSTALL.md`, `agentparty-package-manifest.json`, file hashes, and an optional archive for release-facing framework files. It does not install global files, execute models, automate Feishu Claw auth, or claim native PowerShell execution.

## Current Product Packs

The pack registry is `docs/framework/agentparty-packs.json`.

| Pack | Agents | Status | Completion claim |
| --- | --- | --- | --- |
| `triparty` | Codex + Claude + Gemini | productized | May claim true tri-party only after release gate |
| `claude-code-feishu-claw` | Claude Code + Feishu Claw | scaffolded | May claim pack-ready or partial, never true tri-party |

## Productization Baseline

A pack is not product-ready until it has:

- Registry entry.
- Product-pack document.
- Quickstart install/use entrypoint.
- Install or handoff prompt.
- OS support matrix.
- Runtime boundary notes.
- State or transcript contract.
- Evidence and audit requirements.
- Failure recovery notes.
- Website placement under AgentParty.
- A validation path, even if the first version is document-level validation.
