<#
Installs XAU_SMC_SNIPER_AI into a local MetaTrader 5 terminal and sets up
the ai_engine Python environment. Run this from the root of a checked-out
copy of the repo, in PowerShell on Windows (where MT5/MetaEditor live).

Usage:
  .\scripts\install_windows.ps1
  .\scripts\install_windows.ps1 -MT5DataDir "C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\<hash>"
  .\scripts\install_windows.ps1 -SkipPython
#>

param(
    [string]$MT5DataDir,
    [switch]$SkipPython
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Find-MT5DataDir {
    $root = Join-Path $env:APPDATA "MetaQuotes\Terminal"
    if (-not (Test-Path $root)) { return $null }
    $candidates = Get-ChildItem $root -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName "MQL5")
    }
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }
    if ($candidates.Count -gt 1) {
        Write-Host "Multiple MT5 terminal data folders found:"
        $candidates | ForEach-Object { Write-Host "  $($_.FullName)" }
        Write-Host "Re-run with -MT5DataDir <path> to pick one."
    }
    return $null
}

if (-not $MT5DataDir) {
    $MT5DataDir = Find-MT5DataDir
    if (-not $MT5DataDir) {
        throw "Could not auto-detect the MT5 data folder. In MT5: File > Open Data Folder, then re-run with -MT5DataDir <that path>."
    }
}
if (-not (Test-Path (Join-Path $MT5DataDir "MQL5"))) {
    throw "'$MT5DataDir' does not contain an MQL5 folder - is this really the MT5 data folder?"
}

Write-Host "Installing into: $MT5DataDir"

$includeSrc = Join-Path $RepoRoot "MQL5\Include\XAU_SMC_SNIPER_AI"
$includeDst = Join-Path $MT5DataDir "MQL5\Include\XAU_SMC_SNIPER_AI"
$expertSrc  = Join-Path $RepoRoot "MQL5\Experts\XAU_SMC_SNIPER_AI"
$expertDst  = Join-Path $MT5DataDir "MQL5\Experts\XAU_SMC_SNIPER_AI"

New-Item -ItemType Directory -Force -Path $includeDst | Out-Null
New-Item -ItemType Directory -Force -Path $expertDst | Out-Null
Copy-Item -Path (Join-Path $includeSrc "*") -Destination $includeDst -Recurse -Force
Copy-Item -Path (Join-Path $expertSrc "*") -Destination $expertDst -Recurse -Force
Write-Host "Copied Include/ and Experts/ files."

$metaeditor = Get-ChildItem "C:\Program Files\MetaTrader 5\MetaEditor64.exe" -ErrorAction SilentlyContinue
if ($metaeditor) {
    Write-Host "Compiling via MetaEditor..."
    & $metaeditor.FullName "/compile:$(Join-Path $expertDst 'XAU_SMC_SNIPER_AI.mq5')" "/log"
    Write-Host "Compile log written next to the .mq5 file - check for errors before attaching the EA."
} else {
    Write-Host "MetaEditor64.exe not found at the default path - compile XAU_SMC_SNIPER_AI.mq5 manually (F7) in MetaEditor."
}

if (-not $SkipPython) {
    Write-Host "Setting up ai_engine Python environment..."
    $venv = Join-Path $RepoRoot ".venv"
    if (-not (Test-Path $venv)) {
        python -m venv $venv
    }
    & (Join-Path $venv "Scripts\python.exe") -m pip install --upgrade pip
    & (Join-Path $venv "Scripts\python.exe") -m pip install -r (Join-Path $RepoRoot "ai_engine\requirements.txt")
    Write-Host "ai_engine deps installed into $venv"
}

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  1. In MT5: attach XAU_SMC_SNIPER_AI to an XAUUSD chart, enable AlgoTrading."
Write-Host "  2. Set XSS_COMMON_FILES_DIR to '$MT5DataDir\..\..\Terminal\Common\Files\XAU_SMC_SNIPER_AI' (or wherever your Common\Files is - same for every terminal install on this PC)."
Write-Host "  3. Run the evolution engine: $venv\Scripts\python.exe -m ai_engine.run_cycle --watch"
