@AGENTS.md

## Claude Code

- This repository's canonical agent instructions live in `AGENTS.md`; Claude Code must import and follow them instead of creating a separate protocol.
- When asked for the Codex + Claude + Gemini tri-party framework, use the existing `scripts/triparty.sh` workflow and do not reconstruct the framework with new ad hoc Markdown files.
- In Claude Code, prefer `/triparty` for direct slash invocation and `/tp` as the short alias when slash skills or slash commands are available.
- For Claude Code + Feishu Claw work, prefer `/agentparty-claw` and `/ap-claw` when available. These slash entries create or inspect local AgentParty Claw kits only; they must not call Feishu, import evidence, or claim `true_triparty_ready=true`.
