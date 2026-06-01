# Examples

This directory gives new users a small path from "what is this?" to "I can run it."

## 1. Review This Repository

Use the prompt in [review-framework-task.md](review-framework-task.md):

```bash
scripts/triparty.sh run "$(cat examples/review-framework-task.md)"
```

Expected run artifacts are written to:

```text
docs/framework/runs/review-YYYYMMDD-HHMMSS/
```

## 2. Manual Artifact Injection

If Claude or Gemini output was collected outside the automated CLI path, use [manual-injection.md](manual-injection.md). The injected artifact is copied, hashed, wrapped with metadata, and recorded in `state.json`.

## 3. State Shape

[state-sample.json](state-sample.json) shows the machine-readable status contract exposed to HTTP, MCP, UI, and CI adapters.

The key field is:

```json
"true_triparty_ready": true
```

If this is false, the result must be described as partial.

## 4. Failure Recovery

Use [failure-recovery.md](failure-recovery.md) when a model times out, the provider reports capacity limits, or the merge gate returns `Partial review only`.
