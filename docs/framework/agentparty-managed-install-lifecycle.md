# AgentParty Managed Install Lifecycle

This document is the compact evidence map for installing and rolling back
AgentParty-managed global files. It exists so release reviews can verify the
user safety boundary without reading the full installer and uninstaller scripts.

## Purpose

AgentParty installs global discovery files so a new Codex or Claude Code session
can find the existing framework instead of recreating it from ad hoc Markdown.
Rollback must be equally productized: an ordinary user should be able to preview
cleanup, execute it explicitly, and keep any slash command or skill file they
have modified.

The Bash installer writes only user-space paths: `CODEX_HOME`,
`CLAUDE_CONFIG_DIR`, `TRIPARTY_CONFIG_DIR`, and `TRIPARTY_BIN_DIR`, defaulting to
directories under `HOME`. It does not invoke `sudo` or write privileged system
directories by default.

The Bash installer and uninstaller block native Windows POSIX shells (`MSYS`, `MINGW`, and `CYGWIN`). Windows users should use WSL2 for executable Bash install/uninstall paths; the PowerShell uninstaller remains a native cleanup preview/execute scaffold only and does not enable native AgentParty run or evidence execution.

## Capability Matrix

| Surface | Status | Boundary |
| --- | --- | --- |
| Bash install/uninstall on local macOS, Linux, and Windows WSL2 filesystems | Verified by release-check/regression | Current executable path. |
| Native PowerShell cleanup scaffold | [UNVERIFIED] static/package-boundary only | No native PowerShell AgentParty `install --execute`, `run`, `doctor --deep`, or `evidence` execution claim without a separate real Windows host run; UNC/network cleanup lock paths are hard-blocked with `E_UNVERIFIED_FS`. |
| NFS/SMB/shared filesystems, WSL2 bridge mounts such as `/mnt/c`/`drvfs`, and unknown/empty filesystem types | [UNVERIFIED] blocked for managed install locking | Use a verified local filesystem for `AGENTPARTY_LOCK_DIR` and `TRIPARTY_CONFIG_DIR`; WSL2 C: path equivalence remains validation work. |
| Claude Code + Feishu Claw pack | 2-agent product pack | `true_triparty_ready=false`; Feishu connector/auth automation remains roadmap. |

The lifecycle manifest is:

```text
~/.triparty-framework/managed-install.env
```

`scripts/install-triparty-global-bootstrap.sh` writes this file after copying
managed artifacts. The manifest schema is `agentparty.managed-install.v1`.

## Manifest States

Each managed artifact records a path, state, and SHA-256 value. Modified-file
preservation is based on content SHA-256, never on timestamps.

| State | SHA-256 value | Meaning |
| --- | --- | --- |
| `STATE=present` | real file hash | Installer wrote the file and uninstall may remove it only if the current file still matches the recorded hash. |
| `STATE=absent` | `ABSENT` | Installer did not write that artifact; uninstall must skip it and must not fall back to marker or legacy deletion. |
| Missing manifest/key | n/a | Compatibility path only; uninstall may compare the current file with the repository source hash or use historical managed markers. |

Current manifest keys include:

- `CLAUDE_TRIPARTY_COMMAND`
- `CLAUDE_TP_COMMAND`
- `CLAUDE_AGENTPARTY_CLAW_COMMAND`
- `CLAUDE_AP_CLAW_COMMAND`
- `CLAUDE_SKILL`
- `TRIPARTY_WRAPPER`
- `AGENTPARTY_WRAPPER`
- `CONFIG_FILE`
- `CODEX_MEMORY`
- `CLAUDE_MEMORY`

## Uninstall Rules

Both `scripts/uninstall-triparty-global-bootstrap.sh` and
`scripts/uninstall-triparty-global-bootstrap.ps1` follow the same policy.

| Case | Result |
| --- | --- |
| Manifest says `present` and current hash matches | Remove the file and report manifest-matched cleanup. |
| Manifest says `present` and current hash differs | Skip the file as user-modified. |
| Manifest says `absent` | Skip the file; do not use marker or legacy fallback. |
| Manifest/key missing but file matches repository source | Remove it as source-matched managed content. |
| Manifest/key missing and historical managed marker matches | Remove it as legacy managed content. |
| None of the above | Skip the file. |

The uninstaller requires explicit execution (`--execute` on Bash, `-Execute` on
PowerShell). Dry-run remains the default preview path.

## Concurrency

The managed lifecycle uses an external user-scoped lock directory under
`${TMPDIR:-/tmp}/agentparty-managed-install-locks` by default, or
`AGENTPARTY_LOCK_DIR` in tests and controlled environments. The lock name is
derived from the normalized full target `TRIPARTY_CONFIG_DIR` hash, and the lock
is acquired with atomic `mkdir` before changing managed files. Scripts normalize the lock root trailing slash, existing physical directories, `..` parent
segments, and symlinked config directories before path composition; case folding
remains host filesystem behavior and is not a cross-filesystem guarantee. The
lock root is set to user-only permissions when the platform allows it.

After acquiring the lock directory, scripts write `owner.env` through
temp-file-and-rename, flush/fsync the metadata when the platform helper is
available, and verify the recorded `LOCK_OWNER_ID` by reading the file back.
Owner metadata includes PID, host, config path, `LOCK_SOURCE`,
`PROCESS_STARTED_AT`, `PROCESS_IDENTITY`, `BOOT_ID`, and creation time for
stale-lock diagnosis. Scripts keep the lock until all managed cleanup work,
including empty config-directory cleanup, has finished.

Before reporting `E_LOCKED`, scripts attempt one conservative stale-lock recovery path. Automatic recovery is allowed only when `owner.env` has the
expected schema, records the same known host, records the same normalized
`LOCK_SOURCE`, and either the recorded PID no longer exists or the recorded
`BOOT_ID` proves the lock came from an earlier boot of the same host. A live PID always remains fail-safe `E_LOCKED`, even if `PROCESS_STARTED_AT` differs; this
avoids deleting a lock after PID reuse or low-precision process-start reporting.
Locks with missing/corrupt owner metadata, foreign-host metadata, source
mismatch, unknown host metadata, or a still-live process are not auto-recovered.

When a lock is recoverable, the script records the current owner fingerprint,
then moves the stale lock directory to a same-filesystem reclaim path. It reads
the moved `owner.env` again and deletes the reclaim path only if the fingerprint
still matches. If the fingerprint differs, the script treats it as a stale lock reclaim race, attempts to restore the moved directory, and returns `E_LOCKED`
instead of deleting another process's new lock. After successful reclaim it
retries atomic `mkdir`. This keeps concurrent self-healing attempts from
deleting the same lock directory at the same time. The `E_LOCKED` error prints
the exact lock directory, owner pid/host/source, and Bash and PowerShell cleanup commands, including PowerShell cleanup commands; users should run those only after inspecting `owner.env` and
confirming no AgentParty installer or uninstaller is active.

This is a local user-space locking contract. Network/sync filesystem behavior
and real Windows host behavior remain validation work; the Bash scripts emit
`E_UNVERIFIED_FS` for known unverified shared or bridge filesystem types and
fail closed for unknown or empty filesystem-type detection. The PowerShell
uninstaller emits `E_UNVERIFIED_FS` for UNC/network lock or config paths.
PowerShell remains a cleanup scaffold, not proof of native PowerShell AgentParty
execution.

Bash filesystem detection first trusts GNU `stat -f -c %T` only when the command
succeeds with a non-empty value. BSD/macOS fallback uses `LC_ALL=C` and bounded
`df -T <candidate> <path>` probes against the explicit local/unverified type
lists, with one shared candidate list and a 15 second total fallback budget. If
no candidate matches, the lock is blocked as unverified.
On Darwin, regression `global_bootstrap_darwin_df_candidate_fallback_installs`
forces the GNU `stat` path to fail and verifies the real `df -T apfs <path>`
fallback can still install and uninstall on the local APFS filesystem.
Regression `global_bootstrap_nfs_df_candidate_fallback_fails_closed` covers the
opposite path: if fallback detection matches `nfs`, the installer emits
`E_UNVERIFIED_FS` before writing managed-install state.

## Regression Evidence

`scripts/triparty-regression.sh` covers the lifecycle with these checks:

- `global_bootstrap_installs_temp_artifacts`: installer creates wrappers,
  config, Claude commands, and `managed-install.env` with Claw command hashes.
- `global_uninstall_execute_removes_managed_artifacts`: explicit uninstall
  removes wrappers, config, manifest, bootstrap memory blocks, and managed slash
  commands.
- `global_uninstall_execute_is_idempotent`: repeated cleanup is safe.
- `global_bootstrap_lock_blocks_concurrent_install`: installer refuses to run
  while another managed lifecycle operation holds the lock.
- `global_uninstall_lock_blocks_concurrent_cleanup`: uninstaller refuses to run
  while another managed lifecycle operation holds the lock.
- `global_bootstrap_recovers_stale_lock`: installer recovers a same-host lock
  whose recorded PID no longer exists.
- `global_bootstrap_live_pid_lock_fails_safe`: installer refuses to recover a
  same-host lock whose PID is still live, even if process-start metadata differs.
- `global_bootstrap_foreign_host_lock_fails_safe`: installer refuses to recover
  a foreign-host lock even when the recorded PID is not live locally.
- `global_bootstrap_config_trailing_slash_lock_equivalence`: config paths with
  and without a trailing slash derive the same lock.
- `global_bootstrap_relative_parent_lock_equivalence`: config paths containing
  `..` parent segments derive the same lock as the normalized physical target.
- `global_bootstrap_symlink_config_lock_equivalence`: symlinked config paths
  derive the same lock as the physical config directory.
- `global_bootstrap_lock_root_trailing_slash_equivalence`: lock roots with and
  without a trailing slash address the same lock.
- `global_uninstall_resumes_after_interrupted_cleanup`: if an earlier cleanup
  already removed some managed files while the manifest remains, rerunning
  explicit uninstall removes the remaining managed files, memory blocks, and
  manifest.
- `global_bootstrap_blocks_forced_native_windows_shell`: Bash installer blocks
  native Windows POSIX-shell execution.
- `global_uninstall_blocks_forced_native_windows_shell`: Bash uninstaller blocks
  native Windows POSIX-shell execution.
- `global_uninstall_cleans_legacy_claw_commands`: pre-manifest Claw slash files
  with historical managed content are cleaned.
- `global_uninstall_respects_absent_manifest_state`: a manifest `absent` entry
  preserves a matching historical-looking file instead of deleting it.
- `global_uninstall_skips_modified_claude_command`: user-edited `/triparty` and
  `/agentparty-claw` slash files are preserved.
- `global_uninstall_modified_user_file_preserved`: preserved files still contain
  the user customization after uninstall.
- `global_uninstall_partial_cleanup_verified`: partial managed installs can be
  cleaned without requiring every artifact to exist.

`scripts/triparty-lint.sh` also checks that the installer writes the manifest,
that Bash and PowerShell uninstallers read manifest hashes, that `STATE=absent`
is honored, and that the regression labels above remain present.

## Boundaries

This lifecycle improves productized installation and rollback only. It does not claim native PowerShell execution for AgentParty workflows. Windows users still use WSL2 for executable `install --execute`, `run`, `doctor --deep`, and `evidence` paths until native PowerShell execution is verified on a real Windows host.
