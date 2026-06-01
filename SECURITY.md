# Security

Tri-party Framework runs local tools and may archive model outputs that contain sensitive project context. Treat every run directory as potentially private.

## Supported Versions

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |

## Reporting Issues

Open a private report with the maintainer when possible. If private reporting is unavailable, open a GitHub issue with reproduction steps but do not include secrets, tokens, proprietary prompts, or private model outputs.

## Local Adapter Boundary

The HTTP adapter defaults to loopback:

```bash
python3 adapters/http/triparty_http_adapter.py --host 127.0.0.1 --port 8765
```

Non-loopback binding is intentionally blocked unless both conditions are true:

- `--allow-non-loopback` is passed.
- `--auth-token` or `TRIPARTY_ADAPTER_AUTH_TOKEN` is configured.

When authentication is enabled, clients must send either:

```text
Authorization: Bearer <token>
```

or:

```text
X-Triparty-Token: <token>
```

Do not expose the adapter to an untrusted network without deployment-specific request logging, rate limiting, token rotation, and access controls.

## Artifact Sensitivity

Run artifacts are written under:

```text
docs/framework/runs/
```

This path is intentionally ignored by git. Do not commit:

- `claude-review.md`
- `gemini-review.md`
- `claude-cross-audit.md`
- `gemini-cross-audit.md`
- `merge-input.md`
- `state.json` from private runs

## Source-Truth Safety

Security fixes must not weaken the framework source rules:

- Adapters must not mark a run as true tri-party unless `state.json` says `true_triparty_ready: true`.
- Codex sub-agents must not be relabeled as Claude or Gemini.
- Artifact metadata, completion markers, hashes, and source labels must remain merge-blocking.
- User-supplied artifacts must keep provenance fields: `origin`, `injected_at`, `source_path`, `source_sha256`, and copied artifact hash.
