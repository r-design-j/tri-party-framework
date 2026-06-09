# Product Pack: Claude Code + Feishu Claw

## Positioning

`claude-code-feishu-claw` is the second AgentParty product pack scaffold.
It targets the user's common workflow: Claude Code collaborates with Feishu Claw ("小龙虾") around documents, workflows, and operational execution.

This is a 2-agent AgentParty pack, not a tri-party pack. It must never claim `true_triparty_ready`, `true tri-party`, or Codex + Claude + Gemini completion.

## Why This Pack Exists

The pain point is skill portability. A workflow may work well in Claude Code but degrade in Feishu Claw, or vice versa, because each runtime has different context, tool access, document permissions, and output conventions.

This pack reduces that loss by forcing both sides to share:

- A single task brief.
- A shared skill contract.
- Explicit tool and permission boundaries.
- Transcript or artifact evidence.
- A pack-specific completion label.
- A handoff rule for unresolved work.

## Agents And Roles

| Agent | Role | Evidence |
| --- | --- | --- |
| Claude Code | Reasoning, plan, code/workflow critique, cross-checking Feishu outputs | Claude Code transcript, changed files, review notes |
| Feishu Claw | Feishu document/workflow operation, cloud context, task execution inside Feishu | Feishu document link, Claw transcript, operation summary |

If Claw is not directly callable from the current runtime, use user-supplied transcript injection. Label the source as transcript/manual and keep the result partial until the required evidence is present.

## Current Install / Use Path

This first product scaffold is prompt-and-transcript based. The AgentParty CLI can create the prompt/state bundle:

```bash
scripts/agentparty.sh install --pack claude-code-feishu-claw --target-os auto
scripts/agentparty.sh install --pack claude-code-feishu-claw --target-os auto --execute
scripts/agentparty.sh quickstart --pack claude-code-feishu-claw --target-os auto
scripts/agentparty.sh kit --pack claude-code-feishu-claw --task "<任务>" --out claw-kit
scripts/agentparty.sh bridge-kit --pack claude-code-feishu-claw --task "<任务>" --out claw-bridge
scripts/agentparty.sh bridge-validate --bridge-dir claw-bridge
scripts/agentparty.sh run --pack claude-code-feishu-claw --task "<任务>"
scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir "<run-dir>"
scripts/agentparty.sh claw-e2e --pack claude-code-feishu-claw --task "<任务>" --out claw-e2e-run
```

`agentparty install` defaults to dry-run. `--execute` installs the shared AgentParty/triparty bootstrap and CLI discovery surfaces. It does not install a Feishu Claw connector, does not configure Feishu auth, and does not make this pack a true tri-party workflow.

`agentparty claw-e2e` is a scoped local adapter for the current executable environment. It calls Claude Code for planning/review, uses the authenticated `feishu` CLI to create and fetch a Feishu docx document, writes transcript/summary/review evidence, imports that evidence, and runs `validate-run`. It proves the end-to-end local evidence loop, but it is not native Feishu Claw connector automation.

`agentparty bridge-kit` is the first scaffold for the target native shape: Feishu Claw is the user-facing intake and report surface, Claude Code is a controlled runner, and both sides share file-backed resources plus a bridge `state.json`. It creates the shared resource manifest, skill contract, Feishu entry message, Claude runner prompt, revision log, report templates, and mutual-supervision state. It still does not expose local shell directly to Feishu and does not claim native Feishu Claw callback support.

For the simplest productized handoff, generate a Claw kit:

```bash
scripts/agentparty.sh kit --pack claude-code-feishu-claw --task "<任务>" --out claw-kit
```

In Claude Code, the installed slash command surface provides the same pack adapter:

```text
/agentparty-claw kit "<任务>"
/agentparty-claw guide claw-kit
/agentparty-claw validate claw-kit
/ap-claw "<任务>"
```

These slash entries locate the existing `agentparty` CLI and create or inspect local kits. They do not call Feishu, import evidence, configure Claw auth, or claim `true_triparty_ready=true`.
If `agentparty`, `AGENTPARTY_FRAMEWORK_HOME`, and the current repository fallback are all unavailable, the slash command must stop, report that AgentParty is not installed or discoverable, and ask whether to install or clone the framework. It must not reconstruct the protocol with new Markdown files.

This writes a reusable directory with:

- `START_HERE.md`
- `claude-code-prompt.txt`
- `feishu-claw-prompt.txt`
- `claw-action-request.md`
- `task-brief.md`
- `state.json`
- `evidence/agentparty-claw-evidence.json`
- `evidence/feishu-claw-transcript.txt`
- `evidence/operation-summary.txt`
- `evidence/claude-code-review.txt`
- `agentparty-claw-kit.json`

The kit is a local handoff scaffold. It writes local files, but it does not call Feishu, configure Claw auth, import evidence, modify external systems, or claim completion. Native PowerShell may generate this kit and fill the local evidence bundle for preparation, but evidence import remains a WSL2/macOS/Linux execution path.
`START_HERE.md` is the kit's first page for ordinary users. It preserves the copy order, evidence checklist, `evidence-fill` shortcut, import commands, guide command, and pack boundaries so users do not have to infer the flow from separate files.

The lower-level run command creates:

- `claude-code-prompt.txt`
- `feishu-claw-prompt.txt`
- `state.json` with `schema_version=agentparty.pack-state.v1`

`agentparty quickstart --pack claude-code-feishu-claw` prints a one-copy install/use path and a delegation prompt for the current OS target. The initial run status is `partial` until Feishu Claw transcript evidence is provided and reviewed. Use `agentparty guide --pack claude-code-feishu-claw --run-dir "<run-dir>"` any time the run is unclear; it reads `state.json` and prints the next safe command for `partial`, `blocked`, `scoped`, or `pack_ready`.

Create a standard evidence bundle before handing the task between Claude Code and Feishu Claw:

```bash
scripts/agentparty.sh evidence-template \
  --pack claude-code-feishu-claw \
  --run-dir "<run-dir>" \
  --out "<claw-evidence-dir>"
```

This writes:

- `agentparty-claw-evidence.json`
- `feishu-claw-transcript.txt`
- `operation-summary.txt`
- `claude-code-review.txt`
- `README.md`

The generated files include `TODO_AGENTPARTY_REPLACE` markers. `agentparty evidence-fill` can set `feishu_link` and copy real transcript/summary/review files into the bundle without importing state. `agentparty evidence` rejects unchanged template files, evidence files shorter than the minimum content threshold, non-http(s) Feishu links, bundle artifact paths outside the bundle directory, and `--run-dir` values that conflict with the bundle's recorded `run_dir` so placeholder or cross-run evidence cannot become `pack_ready`.

To print the OS-specific installation and usage plan:

```bash
scripts/agentparty.sh install-plan --pack claude-code-feishu-claw --target-os auto
scripts/agentparty.sh install-plan --pack claude-code-feishu-claw --target-os windows_powershell
```

On native Windows, `install` dry-run, `install-plan`, `doctor`, `prompt`, `guide`, `validate-run`, `bridge-kit`, `bridge-validate`, `kit`, `evidence-template`, and `evidence-fill` can be used as preparation or read-only/local scaffolds. `install --execute`, `run`, `doctor --deep`, `evidence`, and `claw-e2e` remain blocked until native Windows execution and evidence import are tested.

If the global bootstrap needs to be removed, inspect first:

```bash
scripts/uninstall-triparty-global-bootstrap.sh --dry-run
scripts/uninstall-triparty-global-bootstrap.sh --execute
```

Native PowerShell cleanup uses:

```powershell
.\scripts\uninstall-triparty-global-bootstrap.ps1 -DryRun
.\scripts\uninstall-triparty-global-bootstrap.ps1 -Execute
```

After Claw returns evidence, fill the bundle locally, then import it into the run:

```bash
scripts/agentparty.sh evidence-fill \
  --pack claude-code-feishu-claw \
  --bundle "<claw-evidence-dir>/agentparty-claw-evidence.json" \
  --feishu-link "<飞书链接>" \
  --claw-transcript "<claw-transcript.txt>" \
  --operation-summary "<operation-summary.txt>" \
  --claude-review "<claude-review.txt>"
```

`evidence-fill` is a prep-only surface: it writes the local bundle and evidence text files, but it does not call Feishu, import evidence, or update `state.json`.

```bash
scripts/agentparty.sh evidence \
  --pack claude-code-feishu-claw \
  --bundle "<claw-evidence-dir>/agentparty-claw-evidence.json"
```

The bundle contains `run_dir`, so `--run-dir` is optional when importing from the bundle. For backwards compatibility, direct flags still work:

```bash
scripts/agentparty.sh evidence \
  --pack claude-code-feishu-claw \
  --run-dir "<run-dir>" \
  --feishu-link "<飞书链接>" \
  --claw-transcript "<claw-transcript.txt>" \
  --operation-summary "<operation-summary.txt>" \
  --claude-review "<claude-review.txt>"
```

Then validate the state:

```bash
scripts/agentparty.sh validate-run --run-dir "<run-dir>"
```

If all required evidence is present, the run becomes `completion_label=pack_ready`, `pack_ready=true`, and `true_triparty_ready=false`.
If evidence is missing, it remains `partial`.
If permission or user-confirmation work blocks execution, import the blocked status:

```bash
scripts/agentparty.sh evidence \
  --pack claude-code-feishu-claw \
  --run-dir "<run-dir>" \
  --blocked-reason "Feishu permission missing; user confirmation required."
```

```text
请按 AgentParty 的 Claude Code + Feishu Claw 产品包处理这个任务。
目标：<任务>
要求：
1. Claude Code 先输出任务拆解、风险、需要 Claw 执行的 Feishu 动作。
2. 把 Claw 要执行的动作写成可复制指令。
3. Claw 执行后，把 Feishu 链接、操作摘要和 transcript 填入 AgentParty evidence bundle；可以用 `evidence-fill` 减少手工改 JSON。
4. Claude Code 读取 transcript，检查是否满足任务 brief。
5. 如果缺权限、缺链接、缺 transcript 或结果不一致，标记 partial，不要声称完整完成。
6. 这是 2-agent AgentParty pack，不要声称 true tri-party，不要写 true_triparty_ready=true。
7. 最终只允许输出 pack_ready、partial、blocked 或 scoped。
```

macOS / Linux / Windows WSL2 can use the same prompt and transcript workflow.
Native PowerShell/CMD/Git Bash/MSYS/Cygwin do not change the pack semantics. `scripts/agentparty.ps1` is included as a discovery / doctor / quickstart / install dry-run / install-plan / prompt / guide / validate-run / bridge-kit / bridge-validate / kit / evidence-template / evidence-fill compatibility scaffold, but Windows non-WSL shell `install --execute`, `run`, `doctor --deep`, `evidence`, and `claw-e2e` are blocked until tested on Windows.

## Completion Gate

Pack-ready requires:

- Claude Code side plan or review artifact.
- Feishu Claw action transcript or Feishu document evidence.
- Explicit comparison against the original task brief.
- Missing-permission and missing-transcript checks.
- Final label is `pack_ready`, `partial`, `blocked`, or `scoped`.

Pack-ready does not imply true tri-party readiness.

## Implemented Scaffold

- `agentparty.pack-state.v1` defines generic product-pack run state.
- `agentparty.claw-bridge-state.v1` defines the bridge scaffold state for Feishu-as-entry and Claude Code-as-runner workflows.
- `scripts/agentparty.sh prompt --pack claude-code-feishu-claw --task "<任务>"` generates the copy-to-agent prompt.
- `scripts/agentparty.sh quickstart --pack claude-code-feishu-claw --target-os auto` generates one-copy install/use instructions and a delegation prompt.
- `scripts/agentparty.sh kit --pack claude-code-feishu-claw --task "<任务>" --out "<dir>"` creates a reusable Claw kit with `START_HERE.md`, prompts, action request, state, evidence bundle, and boundaries.
- `scripts/agentparty.sh bridge-kit --pack claude-code-feishu-claw --task "<任务>" --out "<dir>"` creates a Feishu-entry bridge scaffold with shared resources, shared state, one-active-writer policy, and mutual-supervision rules.
- `scripts/agentparty.sh bridge-validate --bridge-dir "<dir>"` validates the bridge scaffold without turning it into a native Claw connector claim.
- `.claude/commands/agentparty-claw.md` and `.claude/commands/ap-claw.md` expose the same kit/guide/validate path inside Claude Code.
- `scripts/agentparty.sh run --pack claude-code-feishu-claw --task "<任务>"` creates the prompt/state bundle and starts as `partial`.
- `scripts/agentparty.sh guide --pack claude-code-feishu-claw --run-dir "<run-dir>"` prints state-aware next steps for evidence collection, blockers, or final validation.
- `scripts/agentparty.sh evidence-template --pack claude-code-feishu-claw --run-dir "<run-dir>" --out "<dir>"` creates a fill-in bundle for Claw transcript, operation summary, and Claude review evidence.
- `scripts/agentparty.sh evidence-fill --pack claude-code-feishu-claw --bundle "<dir>/agentparty-claw-evidence.json" ...` fills the local bundle without importing state.
- `scripts/agentparty.sh evidence --pack claude-code-feishu-claw --bundle "<dir>/agentparty-claw-evidence.json"` imports bundle evidence.
- `scripts/agentparty.sh evidence --pack claude-code-feishu-claw --run-dir "<run-dir>" ...` still imports direct transcript, link, operation summary, and Claude review flags.
- `scripts/agentparty.sh validate-run --run-dir "<run-dir>"` validates pack state without converting it into true tri-party readiness.
- `scripts/agentparty.sh claw-e2e --pack claude-code-feishu-claw --task "<任务>" --out "<run-dir>"` runs the scoped Claude Code + Feishu CLI E2E adapter and can produce `pack_ready` without manual transcript copy/paste when both local CLIs are authenticated.

## Roadmap

- Add native Feishu Claw connector event intake that can feed `bridge-kit` state instead of relying on manual copy/paste.
- Add controlled Claude Code runner execution behind the bridge, with auth, queueing, allowlisted tools, audit logs, and user-visible Feishu reports.
- Add Feishu document content checks beyond user-supplied links and transcripts.
- Add broader pack-level regression fixtures for malformed evidence and recovery edge cases.
