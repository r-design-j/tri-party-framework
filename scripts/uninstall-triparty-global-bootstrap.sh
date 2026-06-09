#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME_DIR="${CODEX_HOME:-"$HOME/.codex"}"
CODEX_AGENTS_FILE="$CODEX_HOME_DIR/AGENTS.md"
CLAUDE_HOME_DIR="${CLAUDE_CONFIG_DIR:-"$HOME/.claude"}"
CLAUDE_MEMORY_FILE="$CLAUDE_HOME_DIR/CLAUDE.md"
CLAUDE_SKILL_FILE="$CLAUDE_HOME_DIR/skills/triparty/SKILL.md"
CLAUDE_TRIPARTY_COMMAND_FILE="$CLAUDE_HOME_DIR/commands/triparty.md"
CLAUDE_TP_COMMAND_FILE="$CLAUDE_HOME_DIR/commands/tp.md"
CLAUDE_AGENTPARTY_CLAW_COMMAND_FILE="$CLAUDE_HOME_DIR/commands/agentparty-claw.md"
CLAUDE_AP_CLAW_COMMAND_FILE="$CLAUDE_HOME_DIR/commands/ap-claw.md"
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
EXECUTE=0

usage() {
  cat <<'EOF'
Usage:
  scripts/uninstall-triparty-global-bootstrap.sh [--dry-run]
  scripts/uninstall-triparty-global-bootstrap.sh --execute

Removes only bootstrap artifacts that can be attributed to this repository:
Codex/Claude bootstrap blocks, CLI wrappers, config, and copied Claude slash files.
Default mode is dry-run.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      EXECUTE=0
      ;;
    --execute)
      EXECUTE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

block_native_windows_shell() {
  local os_name
  os_name="$(uname -s 2>/dev/null || printf 'unknown')"
  case "$os_name" in
    MINGW*|MSYS*|CYGWIN*)
      printf 'E_BLOCKED_OS: Windows non-WSL AgentParty Bash uninstaller is roadmap and is not verified. Use .\\scripts\\uninstall-triparty-global-bootstrap.ps1 for native PowerShell cleanup preview, or use WSL2 for executable Bash cleanup. Start with: wsl --install -d Ubuntu\n' >&2
      exit 1
      ;;
  esac
  if [ "${AGENTPARTY_FORCE_NATIVE_WINDOWS:-0}" = "1" ]; then
    printf 'E_BLOCKED_OS: Windows non-WSL AgentParty Bash uninstaller is roadmap and is not verified. Use .\\scripts\\uninstall-triparty-global-bootstrap.ps1 for native PowerShell cleanup preview, or use WSL2 for executable Bash cleanup. Start with: wsl --install -d Ubuntu\n' >&2
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

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
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

release_managed_install_lock() {
  rm -rf "$MANAGED_INSTALL_LOCK_DIR"
  trap - EXIT
}

block_native_windows_shell
acquire_managed_install_lock

say_action() {
  if [ "$EXECUTE" -eq 1 ]; then
    printf '%s\n' "$1"
  else
    printf 'DRY RUN: %s\n' "$1"
  fi
}

remove_bootstrap_block() {
  local file="$1"
  local label="$2"
  if [ ! -f "$file" ]; then
    printf 'No %s file: %s\n' "$label" "$file"
    return
  fi
  if ! grep -q '<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->' "$file"; then
    printf 'No managed bootstrap block in %s: %s\n' "$label" "$file"
    return
  fi
  say_action "remove managed bootstrap block from $file"
  if [ "$EXECUTE" -eq 1 ]; then
    local tmp
    tmp="$file.tmp.$$"
    awk '
      /<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->/ { skip = 1; next }
      /<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->/ { skip = 0; next }
      skip != 1 { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}

file_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

remove_file_if_same_as_source() {
  local dest="$1"
  local src="$2"
  local label="$3"
  if [ ! -f "$dest" ]; then
    printf 'No %s file: %s\n' "$label" "$dest"
    return
  fi
  if [ ! -f "$src" ]; then
    printf 'Skip %s because source is missing: %s\n' "$label" "$src"
    return
  fi
  if [ "$(file_sha "$dest")" != "$(file_sha "$src")" ]; then
    printf 'Skip modified %s file: %s\n' "$label" "$dest"
    return
  fi
  say_action "remove managed $label file $dest"
  if [ "$EXECUTE" -eq 1 ]; then
    rm -f "$dest"
  fi
}

remove_file_if_manifest_or_same_as_source() {
  local dest="$1"
  local src="$2"
  local label="$3"
  local manifest_key="$4"
  if [ ! -f "$dest" ]; then
    printf 'No %s file: %s\n' "$label" "$dest"
    return
  fi
  local manifest_state
  local manifest_sha
  manifest_state="$(managed_manifest_value "${manifest_key}_STATE")"
  manifest_sha="$(managed_manifest_value "${manifest_key}_SHA256")"
  if [ "$manifest_state" = "absent" ]; then
    printf 'Skip %s because install manifest records it absent: %s\n' "$label" "$dest"
    return
  fi
  if [ "$manifest_state" = "present" ] && [ -n "$manifest_sha" ] && [ "$manifest_sha" != "ABSENT" ]; then
    if [ "$(file_sha "$dest")" = "$manifest_sha" ]; then
      say_action "remove managed manifest-matched $label file $dest"
      if [ "$EXECUTE" -eq 1 ]; then
        rm -f "$dest"
      fi
      return
    fi
    printf 'Skip modified %s file: %s\n' "$label" "$dest"
    return
  fi
  remove_file_if_same_as_source "$dest" "$src" "$label"
}

file_contains_all() {
  local file="$1"
  shift
  local needle
  for needle in "$@"; do
    if ! grep -Fq "$needle" "$file"; then
      return 1
    fi
  done
  return 0
}

managed_manifest_value() {
  local key="$1"
  if [ ! -f "$MANAGED_INSTALL_FILE" ]; then
    return 0
  fi
  awk -F= -v key="$key" '$1 == key { print substr($0, length($1) + 2); exit }' "$MANAGED_INSTALL_FILE"
}

remove_claude_command_if_managed() {
  local dest="$1"
  local src="$2"
  local label="$3"
  local marker="$4"
  local manifest_key="$5"
  shift 5
  if [ ! -f "$dest" ]; then
    printf 'No %s file: %s\n' "$label" "$dest"
    return
  fi
  local manifest_sha
  local manifest_state
  manifest_state="$(managed_manifest_value "${manifest_key}_STATE")"
  manifest_sha="$(managed_manifest_value "${manifest_key}_SHA256")"
  if [ "$manifest_state" = "absent" ]; then
    printf 'Skip %s because install manifest records it absent: %s\n' "$label" "$dest"
    return
  fi
  if [ "$manifest_state" = "present" ] && [ -n "$manifest_sha" ] && [ "$manifest_sha" != "ABSENT" ]; then
    if [ "$(file_sha "$dest")" = "$manifest_sha" ]; then
      say_action "remove managed manifest-matched $label file $dest"
      if [ "$EXECUTE" -eq 1 ]; then
        rm -f "$dest"
      fi
      return
    fi
    printf 'Skip modified %s file: %s\n' "$label" "$dest"
    return
  fi
  if [ -f "$src" ] && [ "$(file_sha "$dest")" = "$(file_sha "$src")" ]; then
    say_action "remove managed $label file $dest"
    if [ "$EXECUTE" -eq 1 ]; then
      rm -f "$dest"
    fi
    return
  fi
  if grep -Fq "$marker" "$dest" || file_contains_all "$dest" "$@"; then
    say_action "remove managed historical $label file $dest"
    if [ "$EXECUTE" -eq 1 ]; then
      rm -f "$dest"
    fi
    return
  fi
  printf 'Skip modified %s file: %s\n' "$label" "$dest"
}

remove_file_if_contains_root() {
  local file="$1"
  local label="$2"
  if [ ! -f "$file" ]; then
    printf 'No %s file: %s\n' "$label" "$file"
    return
  fi
  if ! grep -Fq "$ROOT_DIR" "$file"; then
    printf 'Skip unmanaged %s file: %s\n' "$label" "$file"
    return
  fi
  say_action "remove managed $label file $file"
  if [ "$EXECUTE" -eq 1 ]; then
    rm -f "$file"
  fi
}

remove_empty_dir() {
  local dir="$1"
  local label="$2"
  if [ ! -d "$dir" ]; then
    return
  fi
  if find "$dir" -mindepth 1 -maxdepth 1 | grep -q .; then
    return
  fi
  say_action "remove empty $label directory $dir"
  if [ "$EXECUTE" -eq 1 ]; then
    rmdir "$dir"
  fi
}

remove_bootstrap_block "$CODEX_AGENTS_FILE" "Codex AGENTS"
remove_bootstrap_block "$CLAUDE_MEMORY_FILE" "Claude memory"
remove_file_if_contains_root "$BIN_FILE" "triparty wrapper"
remove_file_if_contains_root "$AGENTPARTY_BIN_FILE" "agentparty wrapper"
remove_file_if_contains_root "$CONFIG_FILE" "framework config"
remove_file_if_manifest_or_same_as_source "$CLAUDE_SKILL_FILE" "$ROOT_DIR/.claude/skills/triparty/SKILL.md" "Claude triparty skill" "CLAUDE_SKILL"
remove_file_if_manifest_or_same_as_source "$CLAUDE_TRIPARTY_COMMAND_FILE" "$ROOT_DIR/.claude/commands/triparty.md" "Claude triparty command" "CLAUDE_TRIPARTY_COMMAND"
remove_file_if_manifest_or_same_as_source "$CLAUDE_TP_COMMAND_FILE" "$ROOT_DIR/.claude/commands/tp.md" "Claude tp command" "CLAUDE_TP_COMMAND"
remove_claude_command_if_managed \
  "$CLAUDE_AGENTPARTY_CLAW_COMMAND_FILE" \
  "$ROOT_DIR/.claude/commands/agentparty-claw.md" \
  "Claude AgentParty Claw command" \
  "AGENTPARTY_MANAGED_COMMAND: agentparty-claw" \
  "CLAUDE_AGENTPARTY_CLAW_COMMAND" \
  "description: Create or inspect a Claude Code + Feishu Claw AgentParty handoff kit." \
  "Use the existing AgentParty portable framework." \
  "true_triparty_ready=true"
remove_claude_command_if_managed \
  "$CLAUDE_AP_CLAW_COMMAND_FILE" \
  "$ROOT_DIR/.claude/commands/ap-claw.md" \
  "Claude ap-claw command" \
  "AGENTPARTY_MANAGED_COMMAND: ap-claw" \
  "CLAUDE_AP_CLAW_COMMAND" \
  "description: Short alias for /agentparty-claw." \
  "Run the same workflow as" \
  "true_triparty_ready=true"
remove_file_if_contains_root "$MANAGED_INSTALL_FILE" "managed install manifest"
remove_empty_dir "$CLAUDE_HOME_DIR/skills/triparty" "Claude triparty skill"
remove_empty_dir "$CONFIG_DIR" "framework config"
release_managed_install_lock

if [ "$EXECUTE" -eq 1 ]; then
  printf 'Uninstalled managed tri-party global bootstrap artifacts.\n'
else
  printf 'Dry run complete. Re-run with --execute to remove managed artifacts.\n'
fi
