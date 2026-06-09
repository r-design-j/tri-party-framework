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
CLAUDE_AGENTPARTY_CLAW_COMMAND_FILE="$CLAUDE_COMMANDS_DIR/agentparty-claw.md"
CLAUDE_AP_CLAW_COMMAND_FILE="$CLAUDE_COMMANDS_DIR/ap-claw.md"
CONFIG_DIR="${TRIPARTY_CONFIG_DIR:-"$HOME/.triparty-framework"}"
CONFIG_FILE="$CONFIG_DIR/config"
MANAGED_INSTALL_FILE="$CONFIG_DIR/managed-install.env"
MANAGED_INSTALL_LOCK_ROOT="${AGENTPARTY_LOCK_DIR:-"${TMPDIR:-/tmp}/agentparty-managed-install-locks"}"
MANAGED_INSTALL_LOCK_DIR=""
MANAGED_INSTALL_LOCK_SOURCE=""
MANAGED_INSTALL_LOCK_OWNER_ID=""
LOCK_FILESYSTEM_UNVERIFIED="nfs nfs4 smbfs cifs afpfs fuse fuseblk fuse.sshfs sshfs 9p drvfs autofs"
LOCK_FILESYSTEM_VERIFIED_LOCAL="apfs hfs hfsplus hfs+ ufs ext2 ext3 ext4 ext2/ext3 xfs btrfs zfs tmpfs devtmpfs overlay overlayfs f2fs jfs"
LOCK_FILESYSTEM_CANDIDATES="$LOCK_FILESYSTEM_UNVERIFIED $LOCK_FILESYSTEM_VERIFIED_LOCAL"
if [ -n "${TRIPARTY_BIN_DIR:-}" ]; then
  BIN_DIR="$TRIPARTY_BIN_DIR"
elif [ -d "$HOME/.npm-global/bin" ]; then
  BIN_DIR="$HOME/.npm-global/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi
BIN_FILE="$BIN_DIR/triparty"
AGENTPARTY_BIN_FILE="$BIN_DIR/agentparty"
REPO_URL="https://github.com/r-design-j/tri-party-framework.git"

block_native_windows_shell() {
  local os_name
  os_name="$(uname -s 2>/dev/null || printf 'unknown')"
  case "$os_name" in
    MINGW*|MSYS*|CYGWIN*)
      printf 'E_BLOCKED_OS: Windows non-WSL AgentParty Bash installer is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for managed install execution. Start with: wsl --install -d Ubuntu\n' >&2
      exit 1
      ;;
  esac
  if [ "${AGENTPARTY_FORCE_NATIVE_WINDOWS:-0}" = "1" ]; then
    printf 'E_BLOCKED_OS: Windows non-WSL AgentParty Bash installer is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for managed install execution. Start with: wsl --install -d Ubuntu\n' >&2
    exit 1
  fi
}

normalize_lock_path() {
  local path="$1"
  local parent
  local base
  local physical_parent
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  case "$path" in
    /*)
      ;;
    *)
      path="$(pwd -P)/$path"
      ;;
  esac
  if [ -d "$path" ]; then
    (cd -P "$path" 2>/dev/null && pwd -P) && return 0
  fi
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$parent" ]; then
    physical_parent="$(cd -P "$parent" 2>/dev/null && pwd -P)" || physical_parent="$parent"
    printf '%s/%s\n' "$physical_parent" "$base"
    return 0
  fi
  printf '%s\n' "$path"
}

current_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    tr -d '\r\n' < /proc/sys/kernel/random/boot_id
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/darwin-boot-\1/p'
  fi
}

process_started_at() {
  local pid="$1"
  ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

process_identity() {
  local pid="$1"
  local boot_id
  local proc_start
  boot_id="$(current_boot_id)"
  if [ -r "/proc/$pid/stat" ]; then
    proc_start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)"
    if [ -n "$proc_start" ]; then
      printf '%s:%s\n' "${boot_id:-unknown-boot}" "$proc_start"
      return 0
    fi
  fi
  proc_start="$(process_started_at "$pid")"
  if [ -n "$proc_start" ]; then
    printf '%s:%s\n' "${boot_id:-unknown-boot}" "$proc_start"
  fi
}

same_known_host() {
  local owner_host="$1"
  local current_host="$2"
  if [ -z "$owner_host" ] || [ -z "$current_host" ]; then
    return 1
  fi
  if [ "$owner_host" = "unknown" ] || [ "$current_host" = "unknown" ]; then
    return 1
  fi
  [ "$owner_host" = "$current_host" ]
}

lock_filesystem_type() {
  local path="$1"
  local fs_type
  if fs_type="$(stat -f -c %T "$path" 2>/dev/null)" && [ -n "$fs_type" ]; then
    printf '%s\n' "$fs_type"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    AGENTPARTY_LOCK_FS_CANDIDATES="$LOCK_FILESYSTEM_CANDIDATES" python3 - "$path" <<'PY'
import os
import subprocess
import sys
import time

path = sys.argv[1]
env = dict(os.environ)
env["LC_ALL"] = "C"
env["LANG"] = "C"
candidates = os.environ.get("AGENTPARTY_LOCK_FS_CANDIDATES", "").split()
deadline = time.monotonic() + 15.0
for candidate in candidates:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    try:
        result = subprocess.run(
            ["df", "-T", candidate, path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=min(5.0, remaining),
            env=env,
        )
    except Exception:
        continue
    if result.returncode == 0 and result.stdout.strip():
        print(candidate)
        sys.exit(0)
PY
  fi
}

lock_filesystem_type_in_list() {
  local needle="$1"
  local candidate
  for candidate in $2; do
    [ "$needle" = "$candidate" ] && return 0
  done
  return 1
}

is_verified_local_lock_filesystem() {
  lock_filesystem_type_in_list "$1" "$LOCK_FILESYSTEM_VERIFIED_LOCAL"
}

is_unverified_lock_filesystem() {
  lock_filesystem_type_in_list "$1" "$LOCK_FILESYSTEM_UNVERIFIED"
}

block_unverified_lock_filesystem() {
  local fs_type
  fs_type="$(lock_filesystem_type "$MANAGED_INSTALL_LOCK_ROOT" | tr '[:upper:]' '[:lower:]')"
  if is_unverified_lock_filesystem "$fs_type"; then
    printf 'E_UNVERIFIED_FS: AgentParty managed install locking is not verified on %s filesystems. Use a local macOS/Linux/WSL2 filesystem for AGENTPARTY_LOCK_DIR and TRIPARTY_CONFIG_DIR.\n' "$fs_type" >&2
    exit 1
  fi
  if ! is_verified_local_lock_filesystem "$fs_type"; then
    printf 'E_UNVERIFIED_FS: AgentParty managed install locking cannot verify filesystem type "%s". Use a verified local macOS/Linux/WSL2 filesystem for AGENTPARTY_LOCK_DIR and TRIPARTY_CONFIG_DIR.\n' "${fs_type:-unknown}" >&2
    exit 1
  fi
}

fsync_lock_metadata() {
  local owner_file="$1"
  local owner_dir="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$owner_file" "$owner_dir" <<'PY'
import os
import sys

owner_file, owner_dir = sys.argv[1], sys.argv[2]
file_fd = os.open(owner_file, os.O_RDONLY)
try:
    os.fsync(file_fd)
finally:
    os.close(file_fd)
try:
    dir_fd = os.open(owner_dir, os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
    return $?
  fi
  sync 2>/dev/null || true
  return 0
}

write_lock_owner_metadata() {
  local owner_file="$MANAGED_INSTALL_LOCK_DIR/owner.env"
  local owner_tmp="$MANAGED_INSTALL_LOCK_DIR/owner.env.tmp.$$"
  MANAGED_INSTALL_LOCK_OWNER_ID="$(date -u '+%Y%m%dT%H%M%SZ').$$.${RANDOM:-0}"
  if {
    printf 'SCHEMA=agentparty.managed-install-lock.v1\n'
    printf 'LOCK_OWNER_ID=%s\n' "$MANAGED_INSTALL_LOCK_OWNER_ID"
    printf 'PID=%s\n' "$$"
    printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf 'CONFIG_DIR=%s\n' "$CONFIG_DIR"
    printf 'LOCK_SOURCE=%s\n' "$MANAGED_INSTALL_LOCK_SOURCE"
    printf 'PROCESS_STARTED_AT=%s\n' "$(process_started_at "$$")"
    printf 'PROCESS_IDENTITY=%s\n' "$(process_identity "$$")"
    printf 'BOOT_ID=%s\n' "$(current_boot_id)"
    printf 'CREATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$owner_tmp" && mv "$owner_tmp" "$owner_file" && fsync_lock_metadata "$owner_file" "$MANAGED_INSTALL_LOCK_DIR"; then
    [ "$(lock_owner_value "LOCK_OWNER_ID")" = "$MANAGED_INSTALL_LOCK_OWNER_ID" ] && return 0
  fi
  rm -f "$owner_tmp"
  return 1
}

lock_owner_value_from_dir() {
  local owner_dir="$1"
  local key="$2"
  local owner_file="$owner_dir/owner.env"
  if [ ! -f "$owner_file" ]; then
    return 0
  fi
  awk -F= -v key="$key" '$1 == key { print substr($0, length($1) + 2); exit }' "$owner_file"
}

lock_owner_value() {
  lock_owner_value_from_dir "$MANAGED_INSTALL_LOCK_DIR" "$1"
}

lock_owner_fingerprint_from_dir() {
  local owner_dir="$1"
  printf 'schema=%s|owner=%s|pid=%s|host=%s|source=%s|boot=%s\n' \
    "$(lock_owner_value_from_dir "$owner_dir" "SCHEMA")" \
    "$(lock_owner_value_from_dir "$owner_dir" "LOCK_OWNER_ID")" \
    "$(lock_owner_value_from_dir "$owner_dir" "PID")" \
    "$(lock_owner_value_from_dir "$owner_dir" "HOSTNAME")" \
    "$(lock_owner_value_from_dir "$owner_dir" "LOCK_SOURCE")" \
    "$(lock_owner_value_from_dir "$owner_dir" "BOOT_ID")"
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

stale_lock_recoverable() {
  local owner_schema
  local owner_pid
  local owner_host
  local owner_source
  local owner_boot_id
  local current_host
  local current_boot
  owner_schema="$(lock_owner_value "SCHEMA")"
  owner_pid="$(lock_owner_value "PID")"
  owner_host="$(lock_owner_value "HOSTNAME")"
  owner_source="$(lock_owner_value "LOCK_SOURCE")"
  owner_boot_id="$(lock_owner_value "BOOT_ID")"
  current_host="$(hostname 2>/dev/null || printf 'unknown')"
  current_boot="$(current_boot_id)"
  if [ "$owner_schema" != "agentparty.managed-install-lock.v1" ]; then
    return 1
  fi
  if [ -z "$owner_pid" ] || [ -z "$owner_source" ]; then
    return 1
  fi
  case "$owner_pid" in
    *[!0-9]*)
      return 1
      ;;
  esac
  if ! same_known_host "$owner_host" "$current_host"; then
    return 1
  fi
  if [ "$owner_source" != "$MANAGED_INSTALL_LOCK_SOURCE" ]; then
    return 1
  fi
  if [ -n "$owner_boot_id" ] && [ -n "$current_boot" ] && [ "$owner_boot_id" != "$current_boot" ]; then
    return 0
  fi
  if ! kill -0 "$owner_pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

try_reclaim_stale_lock() {
  local reclaim_dir
  local expected_fingerprint
  local actual_fingerprint
  reclaim_dir="$MANAGED_INSTALL_LOCK_DIR.reclaim.$$"
  if [ ! -d "$MANAGED_INSTALL_LOCK_DIR" ]; then
    return 0
  fi
  expected_fingerprint="$(lock_owner_fingerprint_from_dir "$MANAGED_INSTALL_LOCK_DIR")"
  if stale_lock_recoverable; then
    printf 'Recover stale AgentParty managed install lock: %s\n' "$MANAGED_INSTALL_LOCK_DIR" >&2
    if mv "$MANAGED_INSTALL_LOCK_DIR" "$reclaim_dir" 2>/dev/null; then
      actual_fingerprint="$(lock_owner_fingerprint_from_dir "$reclaim_dir")"
      if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
        printf 'E_LOCKED: stale lock reclaim race detected for %s\n' "$MANAGED_INSTALL_LOCK_DIR" >&2
        if [ ! -d "$MANAGED_INSTALL_LOCK_DIR" ]; then
          mv "$reclaim_dir" "$MANAGED_INSTALL_LOCK_DIR" 2>/dev/null || true
        fi
        return 1
      fi
      rm -rf "$reclaim_dir"
      return 0
    fi
    [ ! -d "$MANAGED_INSTALL_LOCK_DIR" ] && return 0
  fi
  return 1
}

print_lock_blocked_message() {
  printf 'E_LOCKED: AgentParty managed install lifecycle is already running or left a stale lock: %s\n' "$MANAGED_INSTALL_LOCK_DIR" >&2
  printf 'Lock owner pid=%s host=%s source=%s\n' "$(lock_owner_value "PID")" "$(lock_owner_value "HOSTNAME")" "$(lock_owner_value "LOCK_SOURCE")" >&2
  printf 'Inspect owner metadata before deleting: %s\n' "$MANAGED_INSTALL_LOCK_DIR/owner.env" >&2
  printf 'Only remove this lock after confirming no AgentParty installer or uninstaller is active.\n' >&2
  printf 'Bash cleanup command: rm -rf %q\n' "$MANAGED_INSTALL_LOCK_DIR" >&2
  printf 'PowerShell cleanup command: Remove-Item -Recurse -Force -LiteralPath "%s"\n' "$MANAGED_INSTALL_LOCK_DIR" >&2
}

acquire_managed_install_lock() {
  local lock_id
  mkdir -p "$CONFIG_DIR"
  mkdir -p "$MANAGED_INSTALL_LOCK_ROOT"
  MANAGED_INSTALL_LOCK_ROOT="$(normalize_lock_path "$MANAGED_INSTALL_LOCK_ROOT")"
  MANAGED_INSTALL_LOCK_SOURCE="$(normalize_lock_path "$CONFIG_DIR")"
  lock_id="$(hash_text "$MANAGED_INSTALL_LOCK_SOURCE")"
  MANAGED_INSTALL_LOCK_DIR="$MANAGED_INSTALL_LOCK_ROOT/$lock_id.lock"
  mkdir -p "$MANAGED_INSTALL_LOCK_ROOT"
  chmod 700 "$MANAGED_INSTALL_LOCK_ROOT" 2>/dev/null || true
  block_unverified_lock_filesystem
  if ! mkdir "$MANAGED_INSTALL_LOCK_DIR" 2>/dev/null; then
    if ! try_reclaim_stale_lock || ! mkdir "$MANAGED_INSTALL_LOCK_DIR" 2>/dev/null; then
      print_lock_blocked_message
      exit 1
    fi
  fi
  trap 'rm -rf "$MANAGED_INSTALL_LOCK_DIR"' EXIT
  if ! write_lock_owner_metadata; then
    rm -rf "$MANAGED_INSTALL_LOCK_DIR"
    printf 'E_LOCKED: failed to write AgentParty managed install lock owner metadata: %s\n' "$MANAGED_INSTALL_LOCK_DIR/owner.env" >&2
    exit 1
  fi
}

file_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

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

write_manifest_entry() {
  local key="$1"
  local path="$2"
  printf '%s_PATH=%s\n' "$key" "$path"
  if [ -f "$path" ]; then
    printf '%s_STATE=present\n' "$key"
    printf '%s_SHA256=%s\n' "$key" "$(file_sha "$path")"
  else
    printf '%s_STATE=absent\n' "$key"
    printf '%s_SHA256=ABSENT\n' "$key"
  fi
}

write_managed_install_manifest() {
  local tmp="$MANAGED_INSTALL_FILE.tmp.$$"
  {
    printf 'SCHEMA=agentparty.managed-install.v1\n'
    printf 'GENERATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'ROOT_DIR=%s\n' "$ROOT_DIR"
    write_manifest_entry "CODEX_AGENTS" "$CODEX_AGENTS_FILE"
    write_manifest_entry "CLAUDE_MEMORY" "$CLAUDE_MEMORY_FILE"
    write_manifest_entry "CLAUDE_SKILL" "$CLAUDE_SKILL_FILE"
    write_manifest_entry "CLAUDE_TRIPARTY_COMMAND" "$CLAUDE_TRIPARTY_COMMAND_FILE"
    write_manifest_entry "CLAUDE_TP_COMMAND" "$CLAUDE_TP_COMMAND_FILE"
    write_manifest_entry "CLAUDE_AGENTPARTY_CLAW_COMMAND" "$CLAUDE_AGENTPARTY_CLAW_COMMAND_FILE"
    write_manifest_entry "CLAUDE_AP_CLAW_COMMAND" "$CLAUDE_AP_CLAW_COMMAND_FILE"
    write_manifest_entry "TRIPARTY_WRAPPER" "$BIN_FILE"
    write_manifest_entry "AGENTPARTY_WRAPPER" "$AGENTPARTY_BIN_FILE"
    write_manifest_entry "CONFIG" "$CONFIG_FILE"
  } > "$tmp"
  mv "$tmp" "$MANAGED_INSTALL_FILE"
}

block_native_windows_shell
acquire_managed_install_lock
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
AGENTPARTY_FRAMEWORK_HOME=$ROOT_DIR
AGENTPARTY_PACK_REGISTRY=$ROOT_DIR/docs/framework/agentparty-packs.json
TRIPARTY_REPO_URL=$REPO_URL
TRIPARTY_CANONICAL_TRIGGER=Codex + Claude + Gemini 三方模型协作框架
TRIPARTY_SLASH_TRIGGER=/triparty
TRIPARTY_SLASH_ALIAS=/tp
AGENTPARTY_CLAW_SLASH_TRIGGER=/agentparty-claw
AGENTPARTY_CLAW_SLASH_ALIAS=/ap-claw
EOF
mv "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"

cat > "$BIN_FILE.tmp.$$" <<EOF
#!/usr/bin/env bash
exec "$ROOT_DIR/scripts/triparty.sh" "\$@"
EOF
chmod +x "$BIN_FILE.tmp.$$"
mv "$BIN_FILE.tmp.$$" "$BIN_FILE"

cat > "$AGENTPARTY_BIN_FILE.tmp.$$" <<EOF
#!/usr/bin/env bash
exec "$ROOT_DIR/scripts/agentparty.sh" "\$@"
EOF
chmod +x "$AGENTPARTY_BIN_FILE.tmp.$$"
mv "$AGENTPARTY_BIN_FILE.tmp.$$" "$AGENTPARTY_BIN_FILE"

install_required_file "$ROOT_DIR/.claude/skills/triparty/SKILL.md" "$CLAUDE_SKILL_FILE"
install_required_file "$ROOT_DIR/.claude/commands/triparty.md" "$CLAUDE_TRIPARTY_COMMAND_FILE"
install_required_file "$ROOT_DIR/.claude/commands/tp.md" "$CLAUDE_TP_COMMAND_FILE"
install_required_file "$ROOT_DIR/.claude/commands/agentparty-claw.md" "$CLAUDE_AGENTPARTY_CLAW_COMMAND_FILE"
install_required_file "$ROOT_DIR/.claude/commands/ap-claw.md" "$CLAUDE_AP_CLAW_COMMAND_FILE"

BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/triparty-bootstrap-block.XXXXXX")"
cat > "$BLOCK_FILE" <<EOF
<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->

## Tri-party Framework Bootstrap

- Canonical framework: Codex + Claude + Gemini 三方模型协作框架.
- Installed framework home: \`$ROOT_DIR\`.
- Framework config: \`$CONFIG_FILE\`.
- Portable CLI wrapper: \`$BIN_FILE\`.
- AgentParty CLI wrapper: \`$AGENTPARTY_BIN_FILE\`.
- Claude Code slash trigger: \`/triparty\` with alias \`/tp\`.
- Claude Code Claw pack trigger: \`/agentparty-claw\` with alias \`/ap-claw\`.
- Repository: $REPO_URL.
- In any new Codex session, if the user asks for "Codex + Claude + Gemini", "三方模型协作框架", "三方模型协议", or a same-workstream follow-up to this framework:
  - In Claude Code, this same rule must be loaded from \`$CLAUDE_MEMORY_FILE\` or the repository \`CLAUDE.md\`; Claude Code reads \`CLAUDE.md\`, not \`AGENTS.md\`.
  - In Claude Code, prefer \`/triparty status\`, \`/triparty preflight\`, \`/triparty run "<task>"\`, or the short alias \`/tp\` when slash commands are available.
  - Do not recreate the framework by inventing new Markdown files.
  - Do not treat standalone "三方框架/三方协议" as a design/registry/runtime audit unless the user explicitly says so.
  - First locate the existing framework via \`TRIPARTY_FRAMEWORK_HOME\`, then \`$CONFIG_FILE\`, then the installed home above.
  - If located, use the existing scripts: \`scripts/triparty.sh preflight\`, \`scripts/triparty.sh run "<task>"\`, \`scripts/triparty.sh status\`, and \`scripts/triparty.sh release-gate <run-dir>\`.
  - For generic AgentParty product-pack discovery and setup guidance, use \`agentparty packs\`, \`agentparty doctor\`, \`agentparty install-plan --pack <pack-id>\`, or \`agentparty prompt --pack <pack-id>\`.
  - For Claude Code + Feishu Claw work, prefer \`/agentparty-claw kit "<task>"\`, \`/agentparty-claw guide <kit-dir>\`, or \`/ap-claw\`; this creates local handoff kits only and must not claim Feishu connector/auth automation or \`true_triparty_ready=true\`.
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
- AgentParty CLI wrapper: \`$AGENTPARTY_BIN_FILE\`.
- Slash trigger: \`/triparty\`; short alias: \`/tp\`.
- Claw pack slash trigger: \`/agentparty-claw\`; short alias: \`/ap-claw\`.
- Repository: $REPO_URL.
- Claude Code reads \`CLAUDE.md\`, not \`AGENTS.md\`; this global memory exists so Claude Code sessions can discover the same installed framework.
- If the user asks for "Codex + Claude + Gemini", "三方模型协作框架", "三方模型协议", or a same-workstream follow-up to this framework:
  - Prefer the Claude Code slash trigger \`/triparty status\`, \`/triparty preflight\`, \`/triparty run "<task>"\`, or \`/tp\` when slash commands are available.
  - Do not recreate the framework by inventing new Markdown files.
  - Do not treat standalone "三方框架/三方协议" as a design/registry/runtime audit unless the user explicitly says so.
  - First locate the existing framework via \`TRIPARTY_FRAMEWORK_HOME\`, then \`$CONFIG_FILE\`, then the installed home above.
  - If located, use the existing CLI: \`triparty preflight\`, \`triparty run "<task>"\`, \`triparty status\`, and \`triparty release-gate <run-dir>\`.
  - For generic AgentParty product-pack discovery and setup guidance, use \`agentparty packs\`, \`agentparty doctor\`, \`agentparty install-plan --pack <pack-id>\`, or \`agentparty prompt --pack <pack-id>\`.
  - For Claude Code + Feishu Claw work, prefer \`/agentparty-claw kit "<task>"\`, \`/agentparty-claw guide <kit-dir>\`, or \`/ap-claw\`; this creates local handoff kits only and must not claim Feishu connector/auth automation or \`true_triparty_ready=true\`.
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

write_managed_install_manifest

printf 'Installed tri-party global bootstrap.\n'
printf 'Codex AGENTS: %s\n' "$CODEX_AGENTS_FILE"
printf 'Claude Code CLAUDE: %s\n' "$CLAUDE_MEMORY_FILE"
printf 'Claude Code slash skill: %s\n' "$CLAUDE_SKILL_FILE"
printf 'Claude Code slash command: %s\n' "$CLAUDE_TRIPARTY_COMMAND_FILE"
printf 'Claude Code slash alias: %s\n' "$CLAUDE_TP_COMMAND_FILE"
printf 'Claude Code Claw slash command: %s\n' "$CLAUDE_AGENTPARTY_CLAW_COMMAND_FILE"
printf 'Claude Code Claw slash alias: %s\n' "$CLAUDE_AP_CLAW_COMMAND_FILE"
printf 'Config: %s\n' "$CONFIG_FILE"
printf 'Managed install manifest: %s\n' "$MANAGED_INSTALL_FILE"
printf 'CLI wrapper: %s\n' "$BIN_FILE"
printf 'AgentParty CLI wrapper: %s\n' "$AGENTPARTY_BIN_FILE"
