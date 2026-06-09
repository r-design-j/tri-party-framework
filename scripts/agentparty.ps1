param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $AgentPartyArgs
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$Cli = Join-Path $RootDir "scripts/agentparty.py"

Write-Warning "AgentParty PowerShell wrapper is a compatibility scaffold for packs, doctor, quickstart, onboard, install-plan, install dry-run, prompt, guide, validate-run, bridge-kit, bridge-validate, kit, evidence-template, evidence-fill, and package. Native PowerShell install execute/run/deep/evidence/claw-e2e execution is roadmap; use WSL2 for current executable workflows."

if ($AgentPartyArgs.Count -gt 0) {
  $Command = $null
  $KnownCommands = @(
    "packs",
    "info",
    "quickstart",
    "onboard",
    "prompt",
    "kit",
    "bridge-kit",
    "bridge-validate",
    "install-plan",
    "install",
    "run",
    "claw-e2e",
    "evidence-template",
    "evidence-fill",
    "evidence",
    "validate-run",
    "guide",
    "doctor",
    "release-check",
    "package"
  )
  foreach ($Arg in $AgentPartyArgs) {
    if ((-not $Arg.StartsWith("-")) -and ($KnownCommands -contains $Arg)) {
      $Command = $Arg
      break
    }
  }
  if ($Command -eq "run") {
    [Console]::Error.WriteLine("E_BLOCKED_OS: PowerShell native AgentParty run is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for run execution. Start with: wsl --install -d Ubuntu")
    exit 2
  }
  if ($Command -eq "claw-e2e") {
    [Console]::Error.WriteLine("E_BLOCKED_OS: PowerShell native AgentParty claw-e2e is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for Claude Code + Feishu CLI E2E execution. Start with: wsl --install -d Ubuntu")
    exit 2
  }
  if (($Command -eq "doctor") -and ($AgentPartyArgs -contains "--deep")) {
    [Console]::Error.WriteLine("E_BLOCKED_OS: PowerShell native AgentParty deep doctor is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for executable checks. Start with: wsl --install -d Ubuntu")
    exit 2
  }
  if ($Command -eq "evidence") {
    [Console]::Error.WriteLine("E_BLOCKED_OS: PowerShell native AgentParty evidence import is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for evidence import. Start with: wsl --install -d Ubuntu")
    exit 2
  }
  if (($Command -eq "install") -and ($AgentPartyArgs -contains "--execute")) {
    [Console]::Error.WriteLine("E_BLOCKED_OS: PowerShell native AgentParty install execute is roadmap and is not verified. Use Windows WSL2, macOS, or Linux for managed install execution. Start with: wsl --install -d Ubuntu")
    exit 2
  }
}

$Python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $Python) {
  $Python = Get-Command python -ErrorAction SilentlyContinue
}
if (-not $Python) {
  $Python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $Python) {
  Write-Error "Python 3 is required. Install Python first, or use Windows WSL2 for the current supported path."
  exit 1
}

& $Python.Source $Cli @AgentPartyArgs
exit $LASTEXITCODE
