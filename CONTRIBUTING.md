# Contributing

Thanks for considering a contribution to Tri-party Framework.

The project is small by design: the portable shell/Python core is the source of truth, and adapters must not redefine tri-party status.

## Ground Rules

- Do not claim true tri-party output unless `state.json` says `true_triparty_ready: true`.
- Do not treat Codex sub-agents as Claude or Gemini.
- Preserve source status, artifact hashes, metadata headers, and completion markers.
- Keep adapters thin. They should call `scripts/triparty.sh` or read artifacts produced by it.
- Default network behavior must remain local and safe.

## Local Checks

Run these before opening a pull request:

```bash
scripts/triparty-lint.sh
scripts/triparty-regression.sh
scripts/triparty-adapter-smoke.sh
scripts/triparty-mcp-smoke.sh
```

If your change only touches docs, `scripts/triparty-lint.sh` is the minimum required check.

## Useful First Contributions

- Improve examples and screenshots.
- Add platform-specific install notes.
- Improve shell portability without adding heavy dependencies.
- Add schema examples for `state.json`.
- Add adapter client examples for HTTP or MCP.

## Pull Request Checklist

- [ ] The change preserves the source-of-truth rules.
- [ ] The change does not bypass the merge gate.
- [ ] New behavior is documented in README or `docs/framework/`.
- [ ] Relevant scripts pass locally.
- [ ] User-facing wording distinguishes true tri-party, partial, and missing-party states.

## Issue Labels

- `good first issue`: scoped, low-risk contribution.
- `help wanted`: useful but not required for the next release.
- `docs`: documentation and examples.
- `adapter`: HTTP, MCP, UI, or external integration work.
- `core`: portable CLI, state, merge, lint, or regression logic.
