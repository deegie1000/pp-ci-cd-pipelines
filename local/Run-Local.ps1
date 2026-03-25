# =============================================================================
# Local: Run Export, Deploy, or Both
# =============================================================================
# Entry-point wrapper. Prompts for a mode, then calls Export-Solutions.ps1,
# Deploy-Solutions.ps1, or both — passing the shared subfolder selection so
# you're only prompted to pick it once.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Header([string]$text) {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "  $text"
    Write-Host "============================================"
}

# -----------------------------------------------------------------------------
# Mode selection
# -----------------------------------------------------------------------------
Write-Header "Power Platform Local Runner"

Write-Host "What would you like to do?"
Write-Host "  [1] Export only    (Dev → local/solutions/)"
Write-Host "  [2] Deploy only    (local/solutions/ → target environment)"
Write-Host "  [3] Export + Deploy"
Write-Host ""

$modeInput = Read-Host "Enter number"

switch ($modeInput) {
    "1" { $mode = "export" }
    "2" { $mode = "deploy" }
    "3" { $mode = "both"   }
    default {
        Write-Error "Invalid selection. Enter 1, 2, or 3."
        exit 1
    }
}

# -----------------------------------------------------------------------------
# Collect environment URLs based on mode
# -----------------------------------------------------------------------------
Write-Host ""

if ($mode -eq "export" -or $mode -eq "both") {
    $devUrl = Read-Host "Dev environment URL (e.g. https://yourorg.crm.dynamics.com)"
}

if ($mode -eq "deploy" -or $mode -eq "both") {
    $targetUrl = Read-Host "Target environment URL (e.g. https://yourtest.crm.dynamics.com)"

    Write-Host ""
    Write-Host "Deployment settings key (press Enter to use 'Test'):"
    Write-Host "  Controls which deploymentSettings_{key}.json is used."
    $settingsKeyInput = Read-Host "Settings key"
    if (-not $settingsKeyInput) { $settingsKeyInput = "Test" }
}

# -----------------------------------------------------------------------------
# Select subfolder once (shared for both scripts when mode = "both")
# -----------------------------------------------------------------------------
$localRoot   = $PSScriptRoot
$exportsRoot = Join-Path $localRoot "exports"

$subfolders = Get-ChildItem -Path $exportsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name

if (-not $subfolders -or $subfolders.Count -eq 0) {
    Write-Error "No subfolders found in: $exportsRoot`nCreate a subfolder with a build.json to continue."
    exit 1
}

Write-Header "Select Export Subfolder"

Write-Host "Available export subfolders:"
for ($i = 0; $i -lt $subfolders.Count; $i++) {
    Write-Host "  [$($i + 1)] $($subfolders[$i].Name)"
}

$choice    = Read-Host "Enter number"
$choiceInt = [int]$choice - 1

if ($choiceInt -lt 0 -or $choiceInt -ge $subfolders.Count) {
    Write-Error "Invalid selection."
    exit 1
}

$selectedSubfolder = $subfolders[$choiceInt].Name
Write-Host "Using subfolder: $selectedSubfolder"

# -----------------------------------------------------------------------------
# Run selected scripts
# -----------------------------------------------------------------------------
$exportScript = Join-Path $PSScriptRoot "Export-Solutions.ps1"
$deployScript = Join-Path $PSScriptRoot "Deploy-Solutions.ps1"

if ($mode -eq "export" -or $mode -eq "both") {
    Write-Header "Running Export"
    & $exportScript -EnvironmentUrl $devUrl -Subfolder $selectedSubfolder
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Export failed — stopping."
        exit 1
    }
}

if ($mode -eq "deploy" -or $mode -eq "both") {
    Write-Header "Running Deploy"
    $deployParams = @{
        EnvironmentUrl = $targetUrl
        SettingsKey    = $settingsKeyInput
        Subfolder      = $selectedSubfolder
    }
    if ($DryRun) { $deployParams["DryRun"] = $true }

    & $deployScript @deployParams
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Deploy failed."
        exit 1
    }
}

Write-Host ""
Write-Host "Done."
