# Failure Recovery Example

The framework separates preflight, review, cross-audit, and merge. A healthy connection check does not mean the full tri-party workflow is complete.

## Partial Run

A partial run can look like this in `state.json`:

```json
{
  "phase": "merged_partial",
  "true_triparty_ready": false,
  "conclusion": "Partial review only",
  "errors": [
    {
      "stage": "cross_audit",
      "party": "gemini",
      "code": "E_CROSS_TIMEOUT",
      "message": "Gemini cross-audit status: TimedOut"
    }
  ]
}
```

Do not summarize this as a true tri-party conclusion. Report the missing or failed party input.

## Resume With More Time

If the failure is a timeout or temporary model-capacity issue, retry the same run with a larger timeout and retry budget:

```bash
TRIPARTY_CROSS_TIMEOUT=240 TRIPARTY_CROSS_RETRIES=2 \
  scripts/triparty.sh resume docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Then re-check status:

```bash
scripts/triparty.sh status docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Only proceed to final synthesis when:

```json
{
  "phase": "merged_ready",
  "true_triparty_ready": true,
  "conclusion": "Ready for true tri-party synthesis"
}
```

## Manual Recovery

If an external model output was collected manually, inject it instead of pretending the automated path completed:

```bash
scripts/triparty.sh inject cross-audit gemini docs/framework/runs/review-YYYYMMDD-HHMMSS gemini-cross-audit-output.md
scripts/triparty.sh resume docs/framework/runs/review-YYYYMMDD-HHMMSS
```

Injected artifacts are marked as `origin=user_supplied` and keep source provenance in `state.json`.
