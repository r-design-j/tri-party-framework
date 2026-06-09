# TriParty Product Site QA And Package Evidence

Generated: 2026-06-09 16:15:43 CST

This file is the tracked release-evidence copy of the post-review QA/package addendum for the AgentParty / TriParty productization work. The raw review-run directory remains ignored by Git so generated run artifacts do not pollute normal commits.

## Scope

- Hardened website contrast behavior after full-site QA flagged lowContrast candidates.
- Verified the product-homepage structure after the AgentParty / TriParty homepage rewrite.
- Verified the TriParty package smoke output includes the new `onboard` first-use surface.
- Preserved platform boundaries: macOS, Linux, and Windows WSL2 are executable paths; native PowerShell remains preparation / roadmap only.

## Website QA

QA directory:

`/Users/mr.ren/Documents/Codex/2026-06-05/agentparty-triparty-site-continuation/work/website-qa-20260609-product-site-v4-full`

Summary hash:

`3784b7527df53822b89527d56a2170995f9d76d121708c7a2f513c728b1a4ea1  qa-summary.json`

Matrix:

- 12 browser states checked: desktop, tablet, mobile x light, dark x default, expanded.
- `overflow=false` for all 12 states.
- Improved leaf-text contrast scanner reported `lowContrast=0` for all 12 states.
- Command cards: 19 in all states.
- Command-card copy buttons: 19 in all states.
- Total copy buttons: 22 in all states, because the homepage/product proof has additional copy CTAs outside the command-card grid.
- Expanded mode opened 14 / 14 details in all expanded states.
- PowerShell command card carries `Windows PowerShell only` and `dry-run` tags in all states.
- Product-proof preview remains visible in first viewport on default states: desktop 136px, tablet 127px, mobile 91px.

Screenshots were captured for each state as `*-home.png` and `*-full.png` in the QA directory.

## Product Package Smoke

Command:

```bash
scripts/agentparty.sh package --out /tmp/agentparty-release-test --archive --force --json
```

Result:

- Package directory: `/tmp/agentparty-release-test`
- Archive: `/tmp/agentparty-release-test.tar.gz`
- Archive sha256: `e238d321d512ff0fb5b6b275aa6f930243fc8b5c61cb6c653bbb6e6cf146a336`
- Included files: 67
- Pack ids: `triparty`, `claude-code-feishu-claw`
- Manifest hash: `7e971570aba666a16e3a87c3de58d46262d3f728021989e70992f2f52047aa1b`
- INSTALL hash: `b4940b16fce66ab60740c195d0165acb272c1c537e50ad0fd677f82941445a08`

Package content checks:

- `INSTALL.md` includes `scripts/agentparty.sh onboard --pack triparty --target-os auto`.
- `INSTALL.md` includes `.\scripts\agentparty.ps1 onboard --pack triparty --target-os windows_powershell`.
- Manifest `native_powershell_preparation` includes `onboard`.
- Manifest `blocked_native_powershell_commands` still blocks `install --execute`, `run`, `doctor --deep`, `evidence`, and `claw-e2e`.
- Manifest keeps `probe_success_is_not_review_completion=true`.

## Gates

Passed after the post-review fixes:

- `python3 -m py_compile scripts/agentparty.py scripts/agentparty-pack-lint.py`
- `scripts/agentparty.sh release-check --full --json`
- `scripts/triparty.sh release-gate docs/framework/runs/review-20260609-153301`
- `git diff --check`

`release-check --full` passed python compile, AgentParty pack lint, triparty lint, git diff check, static web structure, AgentParty release workflow, and triparty regression.

## Boundary Statement

This evidence supports the current TriParty productization and website QA state. It does not claim native PowerShell execution is shipped. It does not upgrade the Claude Code + Feishu Claw pack to true tri-party. It keeps probe/preflight success separate from review, cross-audit, merge, and release completion.
