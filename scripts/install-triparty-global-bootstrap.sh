#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-"$HOME/.codex"}"
CODEX_AGENTS_FILE="$CODEX_HOME_DIR/AGENTS.md"
CLAUDE_HOME_DIR="${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}"
CLAUDE_MEMORY_FILE="$CLAUDE_HOME_DIR/CLAUDE.md"
CLAUDE_SKILL_DIR="$CLAUDE_HOME_DIR/skills/triparty"
CLAUDE_COMMANDS_DIR="$CLAUDE_HOME_DIR/commands"
CLAUDE_SKILL_FILE="$CLAUDE_SKILL_DIR/SKILL.md"
CLAUDE_TRIPARTY_COMMAND_FILE="$CLAUDE_COMMANDS_DIR/triparty.md"
CLAUDE_TP_COMMAND_FILE="$CLAUDE_COMMANDS_DIR/tp.md"
CONFIG_DIR="${TRIPARTY_CONFIG_DIR:-"$HOME/.triparty-framework"}"
CONFIG_FILE="$CONFIG_DIR/config"
if [ -n "${TRIPARTY_BIN_DIR:-}" ]; then
  BIN_DIR="$TRIPARTY_BIN_DIR"
elif [ -d "$HOME/.npm-global/bin" ]; then
  BIN_DIR="$HOME/.npm-global/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi
BIN_FILE="$BIN_DIR/triparty"
REPO_URL="https://github.com/r-design-j/tri-party-framework.git"

install_required_file() {
  local src="$1"
  local dest="$2"
  if [ ! -f "$src" ]; then
    printf 'Missing required installer source: %s\n' "$src" >&2
    exit 1
  fi
  cp "$src" "$dest.tmp.$$"
  mv "$dest.tmp.$$" "$dest"
}

mkdir -p "$CODEX_HOME_DIR" "$CLAUDE_HOME_DIR" "$CLAUDE_SKILL_DIR" "$CLAUDE_COMMANDS_DIR" "$CONFIG_DIR" "$BIN_DIR"

if [ ! -f "$CODEX_AGENTS_FILE" ]; then
  cat > "$CODEX_AGENTS_FILE" <<'EOF'
# Global Codex Working Agreements
EOF
fi

if [ ! -f "$CLAUDE_MEMORY_FILE" ]; then
  cat > "$CLAUDE_MEMORY_FILE" <<'EOF'
# Global Claude Code Instructions
EOF
fi

cat > "$CONFIG_FILE.tmp.$$" <<EOF
TRIPARTY_FRAMEWORK_HOME=$ROOT_DIR
TRIPARTY_REPO_URL=$REPO_URL
TRIPARTY_CANONICAL_TRIGGER=Codex + Claude + Gemini 三方模型协作框架
TRIPARTY_SLASH_TRIGGER=/triparty
TRIPARTY_SLASH_ALIAS=/tp
EOF
mv "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"

cat > "$BIN_FILE.tmp.$$" <<EOF
#!/usr/bin/env bash
exec "$ROOT_DIR/scripts/triparty.sh" "\$@"
EOF
chmod +x "$BIN_FILE.tmp.$$"
mv "$BIN_FILE.tmp.$$" "$BIN_FILE"

install_required_file "$ROOT_DIR/.claude/skills/triparty/SKILL.md" "$CLAUDE_SKILL_FILE"
install_required_file "$ROOT_DIR/.claude/commands/triparty.md" "$CLAUDE_TRIPARTY_COMMAND_FILE"
install_required_file "$ROOT_DIR/.claude/commands/tp.md" "$CLAUDE_TP_COMMAND_FILE"

BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/triparty-bootstrap-block.XXXXXX")"
cat > "$BLOCK_FILE" <<EOF
<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->

## Tri-party Framework Bootstrap

- Canonical framework: Codex + Claude + Gemini 三方模型协作框架.
- Installed framework home: \`$ROOT_DIR\`.
- Framework config: \`$CONFIG_FILE\`.
- Portable CLI wrapper: \`$BIN_FILE\`.
- Claude Code slash trigger: \`/triparty\` with alias \`/tp\`.
- Repository: $REPO_URL.
- In any new Codex session, if the user asks for "Codex + Claude + Gemini", "三方模型协作框架", "三方模型协议", or a same-workstream follow-up to this framework:
  - In Claude Code, this same rule must be loaded from \`$CLAUDE_MEMORY_FILE\` or the repository \`CLAUDE.md\`; Claude Code reads \`CLAUDE.md\`, not \`AGENTS.md\`.
  - In Claude Code, prefer \`/triparty status\`, \`/triparty preflight\`, \`/triparty run "<task>"\`, or the short alias \`/tp\` when slash commands are available.
  - Do not recreate the framework by inventing new Markdown files.
  - Do not treat standalone "三方框架/三方协议" as a design/registry/runtime audit unless the user explicitly says so.
  - First locate the existing framework via \`TRIPARTY_FRAMEWORK_HOME\`, then \`$CONFIG_FILE\`, then the installed home above.
  - If located, use the existing scripts: \`scripts/triparty.sh preflight\`, \`scripts/triparty.sh run "<task>"\`, \`scripts/triparty.sh status\`, and \`scripts/triparty.sh release-gate <run-dir>\`.
  - If not located, state that the framework is not installed in the current environment and ask whether to clone $REPO_URL.
  - If the user only says "三方框架" and the target is ambiguous, ask: "你指的是 Codex + Claude + Gemini 三方模型协作框架，还是另一个三方结构？"
- Same-workstream follow-ups such as "继续", "补齐", "优化", "发布", "外推", or "记录进去" inherit this tri-party framework unless the user explicitly requests Codex-only work.

<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->
EOF

AGENTS_TMP="$CODEX_AGENTS_FILE.tmp.$$"
awk '
  /<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->/ { skip = 1; next }
  /<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->/ { skip = 0; next }
  skip != 1 { print }
' "$CODEX_AGENTS_FILE" > "$AGENTS_TMP"
{
  cat "$AGENTS_TMP"
  printf '\n'
  cat "$BLOCK_FILE"
  printf '\n'
} > "$CODEX_AGENTS_FILE.tmp2.$$"
mv "$CODEX_AGENTS_FILE.tmp2.$$" "$CODEX_AGENTS_FILE"
rm -f "$AGENTS_TMP" "$BLOCK_FILE"

CLAUDE_BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/triparty-claude-bootstrap-block.XXXXXX")"
cat > "$CLAUDE_BLOCK_FILE" <<EOF
<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->

## Tri-party Framework Bootstrap

- Canonical framework: Codex + Claude + Gemini 三方模型协作框架.
- Installed framework home: \`$ROOT_DIR\`.
- Framework config: \`$CONFIG_FILE\`.
- Portable CLI wrapper: \`$BIN_FILE\`.
- Slash trigger: \`/triparty\`; short alias: \`/tp\`.
- Repository: $REPO_URL.
- Claude Code reads \`CLAUDE.md\`, not \`AGENTS.md\`; this global memory exists so Claude Code sessions can discover the same installed framework.
- If the user asks for "Codex + Claude + Gemini", "三方模型协作框架", "三方模型协议", or a same-workstream follow-up to this framework:
  - Prefer the Claude Code slash trigger \`/triparty status\`, \`/triparty preflight\`, \`/triparty run "<task>"\`, or \`/tp\` when slash commands are available.
  - Do not recreate the framework by inventing new Markdown files.
  - Do not treat standalone "三方框架/三方协议" as a design/registry/runtime audit unless the user explicitly says so.
  - First locate the existing framework via \`TRIPARTY_FRAMEWORK_HOME\`, then \`$CONFIG_FILE\`, then the installed home above.
  - If located, use the existing CLI: \`triparty preflight\`, \`triparty run "<task>"\`, \`triparty status\`, and \`triparty release-gate <run-dir>\`.
  - If not located, state that the framework is not installed in the current environment and ask whether to clone $REPO_URL.
  - If the user only says "三方框架" and the target is ambiguous, ask: "你指的是 Codex + Claude + Gemini 三方模型协作框架，还是另一个三方结构？"
- Same-workstream follow-ups such as "继续", "补齐", "优化", "发布", "外推", or "记录进去" inherit this tri-party framework unless the user explicitly requests single-agent work.

<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->
EOF

CLAUDE_TMP="$CLAUDE_MEMORY_FILE.tmp.$$"
awk '
  /<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->/ { skip = 1; next }
  /<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->/ { skip = 0; next }
  skip != 1 { print }
' "$CLAUDE_MEMORY_FILE" > "$CLAUDE_TMP"
{
  cat "$CLAUDE_TMP"
  printf '\n'
  cat "$CLAUDE_BLOCK_FILE"
  printf '\n'
} > "$CLAUDE_MEMORY_FILE.tmp2.$$"
mv "$CLAUDE_MEMORY_FILE.tmp2.$$" "$CLAUDE_MEMORY_FILE"
rm -f "$CLAUDE_TMP" "$CLAUDE_BLOCK_FILE"

printf 'Installed tri-party global bootstrap.\n'
printf 'Codex AGENTS: %s\n' "$CODEX_AGENTS_FILE"
printf 'Claude Code CLAUDE: %s\n' "$CLAUDE_MEMORY_FILE"
printf 'Claude Code slash skill: %s\n' "$CLAUDE_SKILL_FILE"
printf 'Claude Code slash command: %s\n' "$CLAUDE_TRIPARTY_COMMAND_FILE"
printf 'Claude Code slash alias: %s\n' "$CLAUDE_TP_COMMAND_FILE"
printf 'Config: %s\n' "$CONFIG_FILE"
printf 'CLI wrapper: %s\n' "$BIN_FILE"
