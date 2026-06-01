# Tri-party Framework Workspace

This workspace defines and operates the Codex + Claude + Gemini collaboration framework.

## Install From GitHub

Repository:

```text
https://github.com/r-design-j/tri-party-framework
```

Clone:

```bash
git clone https://github.com/r-design-j/tri-party-framework.git
cd tri-party-framework
chmod +x scripts/*.sh adapters/http/triparty_http_adapter.py adapters/mcp/triparty_mcp_adapter.py
scripts/triparty-lint.sh
```

Download ZIP:

```text
https://github.com/r-design-j/tri-party-framework/archive/refs/heads/main.zip
```

## Quick Start

Use the unified product entrypoint for a full run:

```bash
scripts/triparty.sh run "Review the framework architecture, logic, and user experience."
```

Check the latest run status:

```bash
scripts/triparty.sh status
```

The unified command writes `state.json` into the run directory.

Start the first external adapter:

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

Then read the latest state through HTTP:

```bash
curl http://127.0.0.1:8765/status
```

Use offline injection when a party response was collected manually:

```bash
scripts/triparty.sh inject review claude docs/framework/runs/review-YYYYMMDD-HHMMSS claude-output.md
scripts/triparty.sh resume docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Injected artifacts are copied into the run directory, size-checked, hashed, and recorded in `state.json` with detailed provenance (`origin`, `injected_at`, `source_path`, `source_sha256`, and copied artifact hash).

Every accepted review and cross-audit artifact also carries a runner-written metadata header and a completion marker. The merge gate rejects artifacts with missing metadata, party/stage mismatch, missing completion marker, hash drift, or source-label contamination.

Inspect run history before building a UI:

```bash
scripts/triparty.sh runs
scripts/triparty.sh stats
scripts/triparty.sh archive --keep 20 --dry-run
```

Run a source check before any tri-party claim:

```bash
scripts/triparty.sh preflight
```

Run a review and archive the raw Claude/Gemini outputs:

```bash
scripts/triparty.sh review "Review the framework architecture, logic, and user experience."
```

Run mutual cross-audit before synthesis:

```bash
scripts/triparty.sh cross-audit docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Run the merge gate before presenting a synthesized tri-party result:

```bash
scripts/triparty.sh merge docs/framework/runs/review-YYYYMMDD-HHMMSS
```

The run output is written under `docs/framework/runs/`.

## Source Rule

A result is a true tri-party result only when:

- Codex source is the current Codex session.
- Claude source is a direct Claude CLI/tool/API result, connector result, or user-provided Claude transcript.
- Gemini source is a direct Gemini CLI/tool/API result, connector result, or user-provided Gemini transcript.
- Claude and Gemini cross-audits are completed and archived.
- The final response includes source status for all three parties.

Codex sub-agents do not count as Claude or Gemini.

## Capability Roles

Use this default dispatch pattern:

- Codex: real project code, repository work, tests, implementation.
- Claude: complex reasoning, architecture, long-chain agent work, autonomous planning.
- Gemini: multimodal inputs, PDFs, video, audio, images, Google Search/Maps/URL context.

Assign one primary owner per task, then use the other parties for review, challenge, or context expansion.
Current concrete model bindings are in `docs/framework/model-binding.yaml`.

## Asset Map

- `AGENTS.md`: stable working agreements inherited by future Codex sessions.
- `VERSION` and `CHANGELOG.md`: product-core version and release notes.
- `docs/framework/tri-party-protocol.md`: executable protocol and source rules.
- `docs/framework/adapter-contract.md`: rules every external adapter must obey.
- `scripts/triparty-preflight.sh`: source availability and connectivity probe.
- `scripts/triparty-review.sh`: Claude/Gemini review runner with retry, prompt slimming, timeout, handoff prompts, and archival.
- `scripts/triparty-cross-audit.sh`: mutual Claude/Gemini review audit runner.
- `scripts/triparty-merge.sh`: source-status and cross-audit gate before any synthesized tri-party result.
- `scripts/triparty.sh`: unified CLI for full runs, individual stages, latest-run status, and `state.json` generation.
- `scripts/triparty-lint.sh`: local framework consistency checks.
- `scripts/triparty-regression.sh`: merge-gate regression tests for historical failure modes.
- `scripts/triparty-adapter-smoke.sh`: local HTTP adapter smoke test.
- `scripts/triparty-mcp-smoke.sh`: MCP adapter smoke test.
- `adapters/http/triparty_http_adapter.py`: local HTTP adapter for external tools, UI, CI, or future MCP wrappers.
- `adapters/mcp/triparty_mcp_adapter.py`: stdio MCP adapter exposing the portable core as MCP tools.
- `docs/framework/model-binding.yaml`: current model-version binding for each capability role.
- `docs/framework/model-binding.schema.json`: expected shape for model binding records.
- `docs/framework/state.schema.json`: expected shape for run-level `state.json`.
- `docs/framework/productization-strategy.md`: portable-core and thin-adapter packaging strategy.
- `docs/framework/standard-candidates.md`: candidate standards and implementation status.
- `docs/framework/anti-patterns.md`: known failure modes and prevention rules.
- `docs/framework/decision-log.md`: accepted framework decisions.
- `docs/daily/`: daily summaries and reusable standard extraction.
