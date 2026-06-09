param(
  [switch] $DryRun,
  [switch] $Execute
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$HomeDir = if ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath("UserProfile") }
$CodexHomeDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HomeDir ".codex" }
$CodexAgentsFile = Join-Path $CodexHomeDir "AGENTS.md"
$ClaudeHomeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HomeDir ".claude" }
$ClaudeMemoryFile = Join-Path $ClaudeHomeDir "CLAUDE.md"
$ClaudeSkillFile = Join-Path $ClaudeHomeDir "skills/triparty/SKILL.md"
$ClaudeTripartyCommandFile = Join-Path $ClaudeHomeDir "commands/triparty.md"
$ClaudeTpCommandFile = Join-Path $ClaudeHomeDir "commands/tp.md"
$ClaudeAgentPartyClawCommandFile = Join-Path $ClaudeHomeDir "commands/agentparty-claw.md"
$ClaudeApClawCommandFile = Join-Path $ClaudeHomeDir "commands/ap-claw.md"
$ConfigDir = if ($env:TRIPARTY_CONFIG_DIR) { $env:TRIPARTY_CONFIG_DIR } else { Join-Path $HomeDir ".triparty-framework" }
$ConfigFile = Join-Path $ConfigDir "config"
$ManagedInstallFile = Join-Path $ConfigDir "managed-install.env"

function Normalize-AgentPartyLockPath {
  param([string] $Value)
  $Trimmed = $Value.TrimEnd([char[]]"\/")
  if (-not $Trimmed) {
    return $Value
  }
  if ([System.IO.Path]::IsPathRooted($Trimmed)) {
    $FullPath = [System.IO.Path]::GetFullPath($Trimmed)
  } else {
    $FullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Trimmed))
  }
  if ($FullPath.Length -gt 1) {
    return $FullPath.TrimEnd([char[]]"\/")
  }
  return $FullPath
}

$ManagedInstallLockRoot = if ($env:AGENTPARTY_LOCK_DIR) { $env:AGENTPARTY_LOCK_DIR } elseif ($env:TEMP) { Join-Path $env:TEMP "agentparty-managed-install-locks" } else { Join-Path $HomeDir ".agentparty-managed-install-locks" }
$ManagedInstallLockRoot = Normalize-AgentPartyLockPath $ManagedInstallLockRoot
$ConfigLockSource = Normalize-AgentPartyLockPath $ConfigDir
$ConfigBytes = [System.Text.Encoding]::UTF8.GetBytes($ConfigLockSource)
$ConfigHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($ConfigBytes)).Replace("-", "").ToLowerInvariant()
$ManagedInstallLockDir = Join-Path $ManagedInstallLockRoot "$ConfigHash.lock"
if ($env:TRIPARTY_BIN_DIR) {
  $BinDir = $env:TRIPARTY_BIN_DIR
} elseif (Test-Path (Join-Path $HomeDir ".npm-global/bin")) {
  $BinDir = Join-Path $HomeDir ".npm-global/bin"
} else {
  $BinDir = Join-Path $HomeDir ".local/bin"
}
$TripartyBinFile = Join-Path $BinDir "triparty"
$AgentPartyBinFile = Join-Path $BinDir "agentparty"
$ExecuteMode = [bool]$Execute
$script:ManagedInstallLockAcquired = $false
$script:ManagedInstallLockOwnerId = ""

if ($DryRun -and $Execute) {
  Write-Error "Use either -DryRun or -Execute, not both."
}

Write-Warning "[UNVERIFIED] Native PowerShell cleanup scaffold only. AgentParty install --execute, run, doctor --deep, and evidence execution remain WSL2/macOS/Linux paths until a separate real Windows host run is recorded."

function Get-AgentPartyHostName {
  if ($env:COMPUTERNAME) {
    return $env:COMPUTERNAME
  }
  return [System.Net.Dns]::GetHostName()
}

function Get-AgentPartyBootId {
  try {
    $Os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return $Os.LastBootUpTime.ToUniversalTime().ToString("o")
  } catch {
    return $null
  }
}

function Get-ManagedLockOwnerValueFromDir {
  param([string] $OwnerDir, [string] $Key)
  $OwnerPath = Join-Path $OwnerDir "owner.env"
  if (-not (Test-Path $OwnerPath)) {
    return $null
  }
  foreach ($Line in Get-Content -Path $OwnerPath) {
    if ($Line.StartsWith("${Key}=")) {
      return $Line.Substring($Key.Length + 1)
    }
  }
  return $null
}

function Get-ManagedLockOwnerValue {
  param([string] $Key)
  return Get-ManagedLockOwnerValueFromDir -OwnerDir $ManagedInstallLockDir -Key $Key
}

function Get-ManagedLockOwnerFingerprint {
  param([string] $OwnerDir)
  $Schema = Get-ManagedLockOwnerValueFromDir -OwnerDir $OwnerDir -Key "SCHEMA"
  $OwnerId = Get-ManagedLockOwnerValueFromDir -OwnerDir $OwnerDir -Key "LOCK_OWNER_ID"
  $OwnerPid = Get-ManagedLockOwnerValueFromDir -OwnerDir $OwnerDir -Key "PID"
  $OwnerHost = Get-ManagedLockOwnerValueFromDir -OwnerDir $OwnerDir -Key "HOSTNAME"
  $OwnerSource = Get-ManagedLockOwnerValueFromDir -OwnerDir $OwnerDir -Key "LOCK_SOURCE"
  $OwnerBoot = Get-ManagedLockOwnerValueFromDir -OwnerDir $OwnerDir -Key "BOOT_ID"
  return "schema=$Schema|owner=$OwnerId|pid=$OwnerPid|host=$OwnerHost|source=$OwnerSource|boot=$OwnerBoot"
}

function Get-ProcessStartedAtUtc {
  param([int] $ProcessId)
  $Process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $Process) {
    return $null
  }
  try {
    return $Process.StartTime.ToUniversalTime().ToString("o")
  } catch {
    return $null
  }
}

function Test-AgentPartyProcessExists {
  param([int] $ProcessId)
  return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-AgentPartySameKnownHost {
  param([string] $OwnerHost)
  $CurrentHost = Get-AgentPartyHostName
  if (-not $OwnerHost -or -not $CurrentHost) {
    return $false
  }
  if ($OwnerHost -eq "unknown" -or $CurrentHost -eq "unknown") {
    return $false
  }
  return ($OwnerHost -eq $CurrentHost)
}

function Get-AgentPartyPathStorageKind {
  param([string] $Path)
  try {
    $FullPath = [System.IO.Path]::GetFullPath($Path)
    if ($FullPath.StartsWith("\\")) {
      return "unc"
    }
    $Root = [System.IO.Path]::GetPathRoot($FullPath)
    if (-not $Root) {
      return "unknown"
    }
    $Drive = New-Object System.IO.DriveInfo($Root)
    return $Drive.DriveType.ToString().ToLowerInvariant()
  } catch {
    return "unknown"
  }
}

function Block-UnverifiedLockFilesystem {
  $LockStorageKind = Get-AgentPartyPathStorageKind -Path $ManagedInstallLockRoot
  $ConfigStorageKind = Get-AgentPartyPathStorageKind -Path $ConfigDir
  foreach ($Kind in @($LockStorageKind, $ConfigStorageKind)) {
    if ($Kind -eq "network" -or $Kind -eq "unc") {
      Write-Error "E_UNVERIFIED_FS: AgentParty native PowerShell cleanup locking is not verified on $Kind paths. Use a local Windows path for cleanup preview, or use WSL2 on a local Linux filesystem for executable AgentParty workflows."
    }
  }
}

function Sync-ManagedLockMetadata {
  param([string] $OwnerPath)
  try {
    $Stream = [System.IO.File]::Open($OwnerPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
      $Stream.Flush($true)
    } finally {
      $Stream.Dispose()
    }
    return $true
  } catch {
    return $false
  }
}

function Write-ManagedLockMetadata {
  $script:ManagedInstallLockOwnerId = "$((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")).$PID.$([guid]::NewGuid().ToString("N"))"
  $OwnerPath = Join-Path $ManagedInstallLockDir "owner.env"
  $TmpOwnerPath = Join-Path $ManagedInstallLockDir "owner.env.tmp.$PID"
  $LockMetadata = @(
    "SCHEMA=agentparty.managed-install-lock.v1",
    "LOCK_OWNER_ID=$script:ManagedInstallLockOwnerId",
    "PID=$PID",
    "HOSTNAME=$(Get-AgentPartyHostName)",
    "CONFIG_DIR=$ConfigDir",
    "LOCK_SOURCE=$ConfigLockSource",
    "PROCESS_STARTED_AT=$(Get-ProcessStartedAtUtc -ProcessId $PID)",
    "PROCESS_IDENTITY=$(Get-AgentPartyBootId):$(Get-ProcessStartedAtUtc -ProcessId $PID)",
    "BOOT_ID=$(Get-AgentPartyBootId)",
    "CREATED_AT=$((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))"
  )
  Set-Content -Path $TmpOwnerPath -Value $LockMetadata
  Move-Item -Force -LiteralPath $TmpOwnerPath -Destination $OwnerPath
  if (-not (Sync-ManagedLockMetadata -OwnerPath $OwnerPath)) {
    return $false
  }
  return ((Get-ManagedLockOwnerValue -Key "LOCK_OWNER_ID") -eq $script:ManagedInstallLockOwnerId)
}

function Test-StaleManagedInstallLock {
  $OwnerSchema = Get-ManagedLockOwnerValue -Key "SCHEMA"
  $OwnerPidRaw = Get-ManagedLockOwnerValue -Key "PID"
  $OwnerHost = Get-ManagedLockOwnerValue -Key "HOSTNAME"
  $OwnerLockSource = Get-ManagedLockOwnerValue -Key "LOCK_SOURCE"
  $OwnerBootId = Get-ManagedLockOwnerValue -Key "BOOT_ID"
  if ($OwnerSchema -ne "agentparty.managed-install-lock.v1") {
    return $false
  }
  if (-not $OwnerPidRaw -or -not $OwnerLockSource) {
    return $false
  }
  $OwnerPid = 0
  if (-not [int]::TryParse($OwnerPidRaw, [ref]$OwnerPid)) {
    return $false
  }
  if (-not (Test-AgentPartySameKnownHost -OwnerHost $OwnerHost)) {
    return $false
  }
  if ($OwnerLockSource -ne $ConfigLockSource) {
    return $false
  }
  $CurrentBootId = Get-AgentPartyBootId
  if ($OwnerBootId -and $CurrentBootId -and ($OwnerBootId -ne $CurrentBootId)) {
    return $true
  }
  if (-not (Test-AgentPartyProcessExists -ProcessId $OwnerPid)) {
    return $true
  }
  return $false
}

function Try-RecoverStaleManagedInstallLock {
  $ExpectedFingerprint = Get-ManagedLockOwnerFingerprint -OwnerDir $ManagedInstallLockDir
  if (Test-StaleManagedInstallLock) {
    $RecoveryDir = "$ManagedInstallLockDir.reclaim.$PID"
    [Console]::Error.WriteLine("Recover stale AgentParty managed install lock: $ManagedInstallLockDir")
    try {
      Move-Item -LiteralPath $ManagedInstallLockDir -Destination $RecoveryDir -ErrorAction Stop
      $ActualFingerprint = Get-ManagedLockOwnerFingerprint -OwnerDir $RecoveryDir
      if ($ActualFingerprint -ne $ExpectedFingerprint) {
        [Console]::Error.WriteLine("E_LOCKED: stale lock reclaim race detected for $ManagedInstallLockDir")
        if (-not (Test-Path $ManagedInstallLockDir)) {
          Move-Item -LiteralPath $RecoveryDir -Destination $ManagedInstallLockDir -ErrorAction SilentlyContinue
        }
        return $false
      }
      Remove-Item -Recurse -Force -LiteralPath $RecoveryDir
      return $true
    } catch {
      return (-not (Test-Path $ManagedInstallLockDir))
    }
  }
  return $false
}

function Write-ManagedLockBlockedError {
  $OwnerPid = Get-ManagedLockOwnerValue -Key "PID"
  $OwnerHost = Get-ManagedLockOwnerValue -Key "HOSTNAME"
  $OwnerSource = Get-ManagedLockOwnerValue -Key "LOCK_SOURCE"
  Write-Error "E_LOCKED: AgentParty managed install lifecycle is already running or left a stale lock: $ManagedInstallLockDir. Lock owner pid=$OwnerPid host=$OwnerHost source=$OwnerSource. Inspect owner metadata before deleting: $(Join-Path $ManagedInstallLockDir "owner.env"). Only remove this lock after confirming no AgentParty installer or uninstaller is active. PowerShell cleanup command: Remove-Item -Recurse -Force -LiteralPath `"$ManagedInstallLockDir`". Bash cleanup command: rm -rf '$ManagedInstallLockDir'"
}

function Acquire-ManagedInstallLock {
  if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
  }
  if (-not (Test-Path $ManagedInstallLockRoot)) {
    New-Item -ItemType Directory -Force -Path $ManagedInstallLockRoot | Out-Null
  }
  Block-UnverifiedLockFilesystem
  try {
    New-Item -ItemType Directory -Path $ManagedInstallLockDir -ErrorAction Stop | Out-Null
    $script:ManagedInstallLockAcquired = $true
    if (-not (Write-ManagedLockMetadata)) {
      Write-Error "E_LOCKED: failed to write AgentParty managed install lock owner metadata: $(Join-Path $ManagedInstallLockDir "owner.env")"
    }
  } catch {
    if (-not (Try-RecoverStaleManagedInstallLock)) {
      Write-ManagedLockBlockedError
    }
    try {
      New-Item -ItemType Directory -Path $ManagedInstallLockDir -ErrorAction Stop | Out-Null
      $script:ManagedInstallLockAcquired = $true
      if (-not (Write-ManagedLockMetadata)) {
        Write-Error "E_LOCKED: failed to write AgentParty managed install lock owner metadata: $(Join-Path $ManagedInstallLockDir "owner.env")"
      }
    } catch {
      Write-ManagedLockBlockedError
    }
  }
}

function Release-ManagedInstallLock {
  if ($script:ManagedInstallLockAcquired -and (Test-Path $ManagedInstallLockDir)) {
    Remove-Item -Recurse -Force -Path $ManagedInstallLockDir
    $script:ManagedInstallLockAcquired = $false
  }
}

trap {
  Release-ManagedInstallLock
  throw
}

Acquire-ManagedInstallLock

function Write-ManagedAction {
  param([string] $Message)
  if ($ExecuteMode) {
    Write-Output $Message
  } else {
    Write-Output "DRY RUN: $Message"
  }
}

function Get-ManagedFileSha {
  param([string] $Path)
  return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Remove-ManagedBootstrapBlock {
  param([string] $Path, [string] $Label)
  if (-not (Test-Path $Path)) {
    Write-Output "No $Label file: $Path"
    return
  }
  $Content = Get-Content -Raw -Path $Path
  if ($Content -notmatch '<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->') {
    Write-Output "No managed bootstrap block in ${Label}: $Path"
    return
  }
  Write-ManagedAction "remove managed bootstrap block from $Path"
  if ($ExecuteMode) {
    $Updated = [regex]::Replace(
      $Content,
      '(?s)\r?\n?<!-- BEGIN TRI-PARTY FRAMEWORK BOOTSTRAP -->.*?<!-- END TRI-PARTY FRAMEWORK BOOTSTRAP -->\r?\n?',
      "`n"
    )
    Set-Content -Path $Path -Value $Updated -NoNewline
  }
}

function Remove-ManagedFileIfContainsRoot {
  param([string] $Path, [string] $Label)
  if (-not (Test-Path $Path)) {
    Write-Output "No $Label file: $Path"
    return
  }
  $Content = Get-Content -Raw -Path $Path
  $ForwardRoot = $RootDir -replace '\\', '/'
  if (($Content -notlike "*$RootDir*") -and ($Content -notlike "*$ForwardRoot*")) {
    Write-Output "Skip unmanaged $Label file: $Path"
    return
  }
  Write-ManagedAction "remove managed $Label file $Path"
  if ($ExecuteMode) {
    Remove-Item -Force -Path $Path
  }
}

function Remove-ManagedFileIfSameAsSource {
  param([string] $Dest, [string] $Source, [string] $Label)
  if (-not (Test-Path $Dest)) {
    Write-Output "No $Label file: $Dest"
    return
  }
  if (-not (Test-Path $Source)) {
    Write-Output "Skip $Label because source is missing: $Source"
    return
  }
  if ((Get-ManagedFileSha $Dest) -ne (Get-ManagedFileSha $Source)) {
    Write-Output "Skip modified $Label file: $Dest"
    return
  }
  Write-ManagedAction "remove managed $Label file $Dest"
  if ($ExecuteMode) {
    Remove-Item -Force -Path $Dest
  }
}

function Remove-ManagedFileIfManifestOrSameAsSource {
  param([string] $Dest, [string] $Source, [string] $Label, [string] $ManifestKey)
  if (-not (Test-Path $Dest)) {
    Write-Output "No $Label file: $Dest"
    return
  }
  $ManifestState = Get-ManagedManifestValue -Key "${ManifestKey}_STATE"
  $ManifestSha = Get-ManagedManifestValue -Key "${ManifestKey}_SHA256"
  if ($ManifestState -eq "absent") {
    Write-Output "Skip $Label because install manifest records it absent: $Dest"
    return
  }
  if (($ManifestState -eq "present") -and $ManifestSha -and ($ManifestSha -ne "ABSENT")) {
    if ((Get-ManagedFileSha $Dest) -eq $ManifestSha) {
      Write-ManagedAction "remove managed manifest-matched $Label file $Dest"
      if ($ExecuteMode) {
        Remove-Item -Force -Path $Dest
      }
      return
    }
    Write-Output "Skip modified $Label file: $Dest"
    return
  }
  Remove-ManagedFileIfSameAsSource -Dest $Dest -Source $Source -Label $Label
}

function Test-ManagedContentContainsAll {
  param([string] $Content, [string[]] $Needles)
  foreach ($Needle in $Needles) {
    if (-not $Content.Contains($Needle)) {
      return $false
    }
  }
  return $true
}

function Get-ManagedManifestValue {
  param([string] $Key)
  if (-not (Test-Path $ManagedInstallFile)) {
    return $null
  }
  foreach ($Line in Get-Content -Path $ManagedInstallFile) {
    if ($Line.StartsWith("$Key=")) {
      return $Line.Substring($Key.Length + 1)
    }
  }
  return $null
}

function Remove-ManagedClaudeCommand {
  param(
    [string] $Dest,
    [string] $Source,
    [string] $Label,
    [string] $Marker,
    [string] $ManifestKey,
    [string[]] $LegacyNeedles
  )
  if (-not (Test-Path $Dest)) {
    Write-Output "No $Label file: $Dest"
    return
  }
  $ManifestSha = Get-ManagedManifestValue -Key "${ManifestKey}_SHA256"
  $ManifestState = Get-ManagedManifestValue -Key "${ManifestKey}_STATE"
  if ($ManifestState -eq "absent") {
    Write-Output "Skip $Label because install manifest records it absent: $Dest"
    return
  }
  if (($ManifestState -eq "present") -and $ManifestSha -and ($ManifestSha -ne "ABSENT")) {
    if ((Get-ManagedFileSha $Dest) -eq $ManifestSha) {
      Write-ManagedAction "remove managed manifest-matched $Label file $Dest"
      if ($ExecuteMode) {
        Remove-Item -Force -Path $Dest
      }
      return
    }
    Write-Output "Skip modified $Label file: $Dest"
    return
  }
  if ((Test-Path $Source) -and ((Get-ManagedFileSha $Dest) -eq (Get-ManagedFileSha $Source))) {
    Write-ManagedAction "remove managed $Label file $Dest"
    if ($ExecuteMode) {
      Remove-Item -Force -Path $Dest
    }
    return
  }
  $Content = Get-Content -Raw -Path $Dest
  if ($Content.Contains($Marker) -or (Test-ManagedContentContainsAll -Content $Content -Needles $LegacyNeedles)) {
    Write-ManagedAction "remove managed historical $Label file $Dest"
    if ($ExecuteMode) {
      Remove-Item -Force -Path $Dest
    }
    return
  }
  Write-Output "Skip modified $Label file: $Dest"
}

Write-Warning "AgentParty PowerShell uninstall is a managed cleanup scaffold. It does not enable native PowerShell run/evidence execution."

Remove-ManagedClaudeCommand `
  -Dest $ClaudeAgentPartyClawCommandFile `
  -Source (Join-Path $RootDir ".claude/commands/agentparty-claw.md") `
  -Label "Claude AgentParty Claw command" `
  -Marker "AGENTPARTY_MANAGED_COMMAND: agentparty-claw" `
  -ManifestKey "CLAUDE_AGENTPARTY_CLAW_COMMAND" `
  -LegacyNeedles @(
    "description: Create or inspect a Claude Code + Feishu Claw AgentParty handoff kit.",
    "Use the existing AgentParty portable framework.",
    "true_triparty_ready=true"
  )
Remove-ManagedClaudeCommand `
  -Dest $ClaudeApClawCommandFile `
  -Source (Join-Path $RootDir ".claude/commands/ap-claw.md") `
  -Label "Claude ap-claw command" `
  -Marker "AGENTPARTY_MANAGED_COMMAND: ap-claw" `
  -ManifestKey "CLAUDE_AP_CLAW_COMMAND" `
  -LegacyNeedles @(
    "description: Short alias for /agentparty-claw.",
    "Run the same workflow as",
    "true_triparty_ready=true"
  )

function Remove-ManagedEmptyDir {
  param([string] $Path, [string] $Label)
  if (-not (Test-Path $Path)) {
    return
  }
  $Child = Get-ChildItem -Force -Path $Path -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($Child) {
    return
  }
  Write-ManagedAction "remove empty $Label directory $Path"
  if ($ExecuteMode) {
    Remove-Item -Force -Path $Path
  }
}

Remove-ManagedBootstrapBlock -Path $CodexAgentsFile -Label "Codex AGENTS"
Remove-ManagedBootstrapBlock -Path $ClaudeMemoryFile -Label "Claude memory"
Remove-ManagedFileIfContainsRoot -Path $TripartyBinFile -Label "triparty wrapper"
Remove-ManagedFileIfContainsRoot -Path $AgentPartyBinFile -Label "agentparty wrapper"
Remove-ManagedFileIfContainsRoot -Path $ConfigFile -Label "framework config"
Remove-ManagedFileIfManifestOrSameAsSource -Dest $ClaudeSkillFile -Source (Join-Path $RootDir ".claude/skills/triparty/SKILL.md") -Label "Claude triparty skill" -ManifestKey "CLAUDE_SKILL"
Remove-ManagedFileIfManifestOrSameAsSource -Dest $ClaudeTripartyCommandFile -Source (Join-Path $RootDir ".claude/commands/triparty.md") -Label "Claude triparty command" -ManifestKey "CLAUDE_TRIPARTY_COMMAND"
Remove-ManagedFileIfManifestOrSameAsSource -Dest $ClaudeTpCommandFile -Source (Join-Path $RootDir ".claude/commands/tp.md") -Label "Claude tp command" -ManifestKey "CLAUDE_TP_COMMAND"
Remove-ManagedFileIfContainsRoot -Path $ManagedInstallFile -Label "managed install manifest"
Remove-ManagedEmptyDir -Path (Join-Path $ClaudeHomeDir "skills/triparty") -Label "Claude triparty skill"
Remove-ManagedEmptyDir -Path $ConfigDir -Label "framework config"

if ($ExecuteMode) {
  Write-Output "Uninstalled managed tri-party global bootstrap artifacts."
} else {
  Write-Output "Dry run complete. Re-run with -Execute to remove managed artifacts."
}

Release-ManagedInstallLock
