# Manual Injection Example

Use this when Claude or Gemini output was collected outside the automated runner.

## 1. Create A Review Run

```bash
scripts/triparty.sh review "Review this repository for architecture and reliability risks."
```

Find the latest run:

```bash
scripts/triparty.sh runs 1
```

Assume the run directory is:

```text
docs/framework/runs/review-YYYYMMDD-HHMMSS
```

## 2. Inject Claude And Gemini Reviews

```bash
scripts/triparty.sh inject review claude docs/framework/runs/review-YYYYMMDD-HHMMSS claude-output.md
scripts/triparty.sh inject review gemini docs/framework/runs/review-YYYYMMDD-HHMMSS gemini-output.md
```

## 3. Resume The Workflow

```bash
scripts/triparty.sh resume docs/framework/runs/review-YYYYMMDD-HHMMSS
```

The runner records:

- `origin`
- `injected_at`
- `source_path`
- `source_sha256`
- copied artifact SHA256

## 4. Verify Readiness

```bash
scripts/triparty.sh status docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Only claim true tri-party synthesis when `state.json` contains:

```json
{
  "true_triparty_ready": true,
  "conclusion": "Ready for true tri-party synthesis"
}
```
