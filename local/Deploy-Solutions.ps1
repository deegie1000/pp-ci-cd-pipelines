# =============================================================================
# Local: Deploy Power Platform Solutions
# =============================================================================
# Mirrors the release-solutions-test.yml pipeline + deploy-environment.yml
# template for local execution.
#
# Reads build.json from local/exports/{subfolder}/
# Reads managed zips from local/solutions/managed/
# Reads deployment settings from local/exports/{subfolder}/deploymentSettings_*.json
#
# Prerequisites:
#   - pac CLI installed (dotnet tool install --global Microsoft.PowerApps.CLI.Tool)
#   - Az.Accounts PowerShell module (Install-Module Az.Accounts)
# =============================================================================

[CmdletBinding()]
param(
    [string]$EnvironmentUrl,

    # Maps to the settingsKey / stageName in the template. Used to resolve
    # deploymentSettings_{SettingsKey}.json. Defaults to "Test".
    [string]$SettingsKey = "Test",

    # When provided by a caller (e.g. Run-Local.ps1), skips the interactive
    # subfolder prompt and uses this name directly.
    [string]$Subfolder,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Write-Header([string]$text) {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "  $text"
    Write-Host "============================================"
}

function Assert-Command([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Error "'$name' not found. Please install it and re-run."
        exit 1
    }
}

# -----------------------------------------------------------------------------
# Prereq checks
# -----------------------------------------------------------------------------
Assert-Command "pac"

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az.Accounts module not found. Run: Install-Module Az.Accounts -Scope CurrentUser"
    exit 1
}

# -----------------------------------------------------------------------------
# Dry run notice
# -----------------------------------------------------------------------------
if ($DryRun) {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "  DRY RUN MODE — no changes will be made"
    Write-Host "============================================"
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Resolve paths
# -----------------------------------------------------------------------------
$repoRoot    = Split-Path $PSScriptRoot -Parent
$localRoot   = $PSScriptRoot
$exportsRoot = Join-Path $localRoot "exports"
$managedDir  = Join-Path $localRoot "solutions/managed"
$scriptsDir  = Join-Path $repoRoot "scripts"

# -----------------------------------------------------------------------------
# Prompt for environment URL if not supplied
# -----------------------------------------------------------------------------
if (-not $EnvironmentUrl) {
    $EnvironmentUrl = Read-Host "Target environment URL (e.g. https://org.crm.dynamics.com)"
}
$EnvironmentUrl = $EnvironmentUrl.TrimEnd("/")

# -----------------------------------------------------------------------------
# Prompt for SettingsKey if default "Test" may not apply
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "Deployment settings key: '$SettingsKey'"
Write-Host "(Controls which deploymentSettings_{key}.json is used. Pass -SettingsKey to override.)"

# -----------------------------------------------------------------------------
# Select export subfolder (interactive if not passed by caller)
# -----------------------------------------------------------------------------
Write-Header "Select Export Subfolder"

$subfolders = Get-ChildItem -Path $exportsRoot -Directory | Sort-Object Name

if ($subfolders.Count -eq 0) {
    Write-Error "No subfolders found in: $exportsRoot`nRun Export-Solutions.ps1 first."
    exit 1
}

if ($Subfolder) {
    if (-not ($subfolders | Where-Object { $_.Name -eq $Subfolder })) {
        Write-Error "Subfolder '$Subfolder' not found in: $exportsRoot"
        exit 1
    }
    Write-Host "Using subfolder (passed by caller): $Subfolder"
} else {
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

    $Subfolder = $subfolders[$choiceInt].Name
}

$exportDir     = Join-Path $exportsRoot $Subfolder
$buildJsonPath = Join-Path $exportDir "build.json"

Write-Host "Using subfolder: $Subfolder"

# -----------------------------------------------------------------------------
# Read build.json
# -----------------------------------------------------------------------------
Write-Header "Read build.json"

if (-not (Test-Path $buildJsonPath)) {
    Write-Error "build.json not found at: $buildJsonPath"
    exit 1
}

$buildConfig = Get-Content $buildJsonPath -Raw | ConvertFrom-Json
$solutions   = if ($buildConfig.solutions) { @($buildConfig.solutions) } else { @() }

if ($solutions.Count -eq 0) {
    Write-Host "No solutions in build.json — config data only run."
} else {
    Write-Host "Solutions to deploy ($($solutions.Count)):"
    foreach ($s in $solutions) {
        Write-Host "  - $($s.name) (v$($s.version))"
    }
}

# -----------------------------------------------------------------------------
# Validate all managed zip artifacts exist before doing anything
# -----------------------------------------------------------------------------
Write-Header "Validate Artifacts"

$missingArtifacts = @()

foreach ($solution in $solutions) {
    $name    = $solution.name
    $version = $solution.version
    $zipPath = Join-Path $managedDir "${name}_${version}.zip"

    if (-not (Test-Path $zipPath)) {
        Write-Host "  MISSING: ${name}_${version}.zip"
        $missingArtifacts += "${name}_${version}.zip"
    } else {
        Write-Host "  OK:      ${name}_${version}.zip"
    }

    # Check deployment settings if required by this solution
    $includeSettings = $false
    if ($solution.PSObject.Properties["includeDeploymentSettings"]) {
        $includeSettings = [bool]$solution.includeDeploymentSettings
    }

    if ($includeSettings) {
        $settingsFile = Join-Path $exportDir "deploymentSettings_${SettingsKey}.json"
        if (-not (Test-Path $settingsFile)) {
            Write-Host "  MISSING: deploymentSettings_${SettingsKey}.json (required by $name)"
            $missingArtifacts += "deploymentSettings_${SettingsKey}.json"
        } else {
            Write-Host "  OK:      deploymentSettings_${SettingsKey}.json"
        }
    }
}

if ($missingArtifacts.Count -gt 0) {
    Write-Host ""
    Write-Error "Artifact validation failed — $($missingArtifacts.Count) file(s) missing. Run Export-Solutions.ps1 first."
    exit 1
}

Write-Host "All artifacts validated."

# -----------------------------------------------------------------------------
# Interactive pac auth for target environment
# -----------------------------------------------------------------------------
Write-Header "Authenticate pac CLI (interactive browser)"

Write-Host "Authenticating with: $EnvironmentUrl"
pac auth create --environment $EnvironmentUrl

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to authenticate with Power Platform"
    exit 1
}

Write-Host "pac auth list:"
pac auth list

# -----------------------------------------------------------------------------
# Connect Azure account for REST API token (flow activation, config data)
# -----------------------------------------------------------------------------
Write-Header "Authenticate Azure (for Dataverse REST API)"

$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    Write-Host "No Azure context found — launching interactive login..."
    Connect-AzAccount
} else {
    Write-Host "Already signed in as: $($azContext.Account.Id)"
    $confirm = Read-Host "Use this account? [Y/n]"
    if ($confirm -eq "n" -or $confirm -eq "N") {
        Connect-AzAccount
    }
}

$hasApiToken = $false
try {
    $tokenObj = Get-AzAccessToken -ResourceUrl $EnvironmentUrl
    $apiHeaders = @{
        "Authorization"    = "Bearer $($tokenObj.Token)"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        "Content-Type"     = "application/json"
        "Accept"           = "application/json"
    }
    $hasApiToken = $true
    Write-Host "Acquired Dataverse API token for flow activation."
} catch {
    Write-Host "WARNING: Could not acquire Dataverse API token: $_"
    Write-Host "Cloud flow activation will be skipped."
    $apiHeaders = $null
}

# -----------------------------------------------------------------------------
# Query installed solutions in the target environment
# -----------------------------------------------------------------------------
Write-Header "Query Installed Solutions"

$listJson = (pac solution list --json) | Out-String

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to list solutions in target environment"
    exit 1
}

$installedList = @($listJson | ConvertFrom-Json)
$installed     = @{}
foreach ($s in $installedList) {
    $key = if ($s.PSObject.Properties['solutionUniqueName']) { $s.solutionUniqueName } else { $s.uniqueName }
    $ver = if ($s.PSObject.Properties['version'])            { $s.version }            else { $s.versionNumber }
    if ($key) { $installed[$key] = $ver }
}

Write-Host "Found $($installed.Count) solutions in target environment."
foreach ($key in $installed.Keys) {
    Write-Host "  $key = v$($installed[$key])"
}

# -----------------------------------------------------------------------------
# Deploy each solution in build.json order
# -----------------------------------------------------------------------------
Write-Header "Deploy Solutions"

$failedSolutions   = @()
$skippedSolutions  = @()
$deployedSolutions = @()
$flowWarnings      = @()

foreach ($solution in $solutions) {
    $name    = $solution.name
    $version = $solution.version
    $zipPath = Join-Path $managedDir "${name}_${version}.zip"

    Write-Host ""
    Write-Host "--------------------------------------------"
    Write-Host "  Solution: $name (v$version)"
    Write-Host "--------------------------------------------"

    # isRollback flag
    $isRollback = $false
    if ($solution.PSObject.Properties['isRollback']) {
        $isRollback = [bool]$solution.isRollback
    }
    if ($isRollback) {
        Write-Host "  isRollback = true — staged upgrade will NOT be used."
    }

    # Solution-level deployMode. Supported values: "upgrade" (default), "update"
    # "upgrade" uses --stage-and-upgrade when installing over an existing version.
    # "update"  uses a standard import (no staged upgrade).
    # powerPagesConfiguration.deployMode takes precedence for Power Pages solutions.
    $solutionDeployMode = ""
    if ($solution.PSObject.Properties['deployMode'] -and $solution.deployMode) {
        $solutionDeployMode = $solution.deployMode.ToLower()
        Write-Host "  deployMode = $solutionDeployMode"
    }

    # powerPagesConfiguration
    $ppConfig     = $null
    $ppDeployMode = ""
    if ($solution.PSObject.Properties['powerPagesConfiguration']) {
        $ppConfig = $solution.powerPagesConfiguration
        if ($ppConfig.PSObject.Properties['deployMode'] -and $ppConfig.deployMode) {
            $ppDeployMode = $ppConfig.deployMode.ToUpper()
        }
        Write-Host "  powerPagesConfiguration: deployMode = $ppDeployMode"
    }

    # Skip check
    $isUpgrade = $false
    if ($installed.ContainsKey($name)) {
        $installedVersion = $installed[$name]
        if ($installedVersion -eq $version) {
            Write-Host "  Already installed at v$version — skipping."
            $skippedSolutions += $name
            continue
        }

        try {
            if (([Version]$installedVersion) -gt ([Version]$version) -and -not $isRollback) {
                Write-Host "  Installed v$installedVersion is higher than target v$version — skipping (not a rollback)."
                $skippedSolutions += $name
                continue
            }
        } catch {
            Write-Host "  WARNING: Could not compare versions '$installedVersion' and '$version' — proceeding."
        }

        if ($isRollback) {
            Write-Host "  Rolling back: v$installedVersion → v$version"
        } else {
            Write-Host "  Upgrading: v$installedVersion → v$version"
        }
        $isUpgrade = $true
    } else {
        Write-Host "  Not currently installed — fresh install."
    }

    # Build pac import arguments
    $importArgs = @(
        "solution", "import",
        "--path", $zipPath,
        "--activate-plugins",
        "--async",
        "--max-async-wait-time", "60"
    )

    if ($ppConfig -and $ppDeployMode) {
        switch ($ppDeployMode) {
            "UPGRADE" {
                Write-Host "  Power Pages deployMode=UPGRADE — using --stage-and-upgrade"
                $importArgs += "--stage-and-upgrade"
                $importArgs += "--skip-lower-version"
            }
            "UPDATE" {
                Write-Host "  Power Pages deployMode=UPDATE — standard import"
            }
            "STAGE_FOR_UPGRADE" {
                Write-Host "  Power Pages deployMode=STAGE_FOR_UPGRADE — using --import-as-holding"
                $importArgs += "--import-as-holding"
            }
            default {
                Write-Host "  WARNING: Unknown powerPagesConfiguration.deployMode '$ppDeployMode' — falling back to default strategy."
                if ($isUpgrade -and -not $isRollback) {
                    $importArgs += "--stage-and-upgrade"
                    $importArgs += "--skip-lower-version"
                }
            }
        }
    } elseif ($solutionDeployMode -eq "update") {
        Write-Host "  deployMode=update — standard import (no staged upgrade)"
    } elseif ($isUpgrade -and -not $isRollback) {
        # deployMode="upgrade" or unset — default to staged upgrade
        if ($solutionDeployMode -eq "upgrade") {
            Write-Host "  deployMode=upgrade — using --stage-and-upgrade"
        }
        $importArgs += "--stage-and-upgrade"
        $importArgs += "--skip-lower-version"
    }

    # Deployment settings
    $includeSettings = $false
    if ($solution.PSObject.Properties["includeDeploymentSettings"]) {
        $includeSettings = [bool]$solution.includeDeploymentSettings
    }

    if ($includeSettings) {
        $settingsFile = Join-Path $exportDir "deploymentSettings_${SettingsKey}.json"
        Write-Host "  Using deployment settings: deploymentSettings_${SettingsKey}.json"
        $importArgs += @("--settings-file", $settingsFile)
    }

    # Execute import (or dry run)
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would execute: pac $($importArgs -join ' ')"
        $deployedSolutions += $name
    } else {
        Write-Host "  Importing managed solution..."
        & pac @importArgs

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR: Failed to import solution: $name"
            $failedSolutions += $name
            continue
        }

        Write-Host "  Successfully deployed."
        $deployedSolutions += $name
    }

    # -------------------------------------------------------------------------
    # Activate cloud flows (if applicable)
    # -------------------------------------------------------------------------
    $hasCloudFlows = $false
    if ($solution.PSObject.Properties["includesCloudFlows"]) {
        $hasCloudFlows = [bool]$solution.includesCloudFlows
    }

    if ($hasCloudFlows -and $hasApiToken -and -not $DryRun) {
        Write-Host "  Checking cloud flow statuses..."

        try {
            # Find solution ID by unique name
            $solQuery  = "$EnvironmentUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$name'&`$select=solutionid"
            $solResult = Invoke-RestMethod -Uri $solQuery -Headers $apiHeaders
            $solutionId = $solResult.value[0].solutionid

            # Get workflow component IDs (componenttype 29 = Workflow/Process)
            $compQuery  = "$EnvironmentUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $solutionId and componenttype eq 29&`$select=objectid"
            $compResult = Invoke-RestMethod -Uri $compQuery -Headers $apiHeaders
            $workflowIds = @($compResult.value | ForEach-Object { $_.objectid })

            if ($workflowIds.Count -eq 0) {
                Write-Host "    No workflow components found in solution."
            } else {
                Write-Host "    Found $($workflowIds.Count) workflow component(s). Checking for inactive cloud flows..."
                $activatedCount = 0

                foreach ($wfId in $workflowIds) {
                    try {
                        $wfQuery = "$EnvironmentUrl/api/data/v9.2/workflows($wfId)?`$select=name,category,statecode"
                        $wf      = Invoke-RestMethod -Uri $wfQuery -Headers $apiHeaders

                        # Only cloud flows (category 5) that are inactive
                        if ($wf.category -ne 5) { continue }
                        if ($wf.statecode -eq 1) {
                            Write-Host "    Flow '$($wf.name)' is already on."
                            continue
                        }

                        Write-Host "    Flow '$($wf.name)' is off — activating..."
                        Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/workflows($wfId)" `
                            -Method Patch -Headers $apiHeaders -Body '{"statecode": 1}'
                        Write-Host "    Flow '$($wf.name)' activated."
                        $activatedCount++
                    } catch {
                        $flowDisplayName = if ($wf -and $wf.name) { $wf.name } else { $wfId }
                        $errorMsg = $_.Exception.Message
                        Write-Host "    WARNING: Failed to activate flow '$flowDisplayName': $errorMsg"
                        $flowWarnings += @{ Solution = $name; Flow = $flowDisplayName; Error = $errorMsg }
                    }
                }

                if ($activatedCount -gt 0) {
                    Write-Host "    Activated $activatedCount cloud flow(s)."
                }
            }
        } catch {
            Write-Host "    WARNING: Failed to check/activate cloud flows for '$name': $($_.Exception.Message)"
            $flowWarnings += @{ Solution = $name; Flow = "(all)"; Error = $_.Exception.Message }
        }
    }
}

# -----------------------------------------------------------------------------
# Upsert configuration data (if configData defined in build.json)
# -----------------------------------------------------------------------------
if (-not $DryRun -and $buildConfig.PSObject.Properties["configData"] -and $buildConfig.configData.Count -gt 0) {
    Write-Header "Upsert Config Data"

    if (-not $hasApiToken) {
        Write-Host "WARNING: No Dataverse API token — skipping config data upsert."
    } else {
        $configData = @($buildConfig.configData)
        $syncScript = Join-Path $scriptsDir "Sync-ConfigData.ps1"

        & $syncScript `
            -Mode Upsert `
            -ConfigData $configData `
            -EnvironmentUrl $EnvironmentUrl `
            -ApiHeaders $apiHeaders `
            -SourceDir $exportDir

        Write-Host "Config data upsert complete."
    }
} elseif ($DryRun) {
    Write-Host ""
    Write-Host "[DRY RUN] Skipping config data upsert."
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Header "Deployment Summary"

if ($DryRun) { Write-Host "  Mode: DRY RUN — no imports were performed" }
Write-Host "Environment:     $EnvironmentUrl"
Write-Host "Subfolder:       $Subfolder"
Write-Host "Settings key:    $SettingsKey"
Write-Host "Total solutions: $($solutions.Count)"

if ($DryRun) {
    Write-Host "Would deploy:    $($deployedSolutions.Count)"
} else {
    Write-Host "Deployed:        $($deployedSolutions.Count)"
}
Write-Host "Skipped:         $($skippedSolutions.Count)"
Write-Host "Failed:          $($failedSolutions.Count)"

if ($skippedSolutions.Count -gt 0) {
    Write-Host "Skipped (already at target version): $($skippedSolutions -join ', ')"
}

if ($flowWarnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Cloud flow activation warnings: $($flowWarnings.Count)"
    foreach ($fw in $flowWarnings) {
        Write-Host "  - [$($fw.Solution)] Flow '$($fw.Flow)': $($fw.Error)"
    }
}

if ($failedSolutions.Count -gt 0) {
    Write-Host "Failed: $($failedSolutions -join ', ')"
    Write-Error "One or more solutions failed to deploy."
    exit 1
}

Write-Host ""
Write-Host "All solutions deployed successfully to: $EnvironmentUrl"
