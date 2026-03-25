# =============================================================================
# Local: Export Power Platform Solutions
# =============================================================================
# Mirrors the export-solutions.yml pipeline for local execution.
# Skips git operations, artifact publishing, and PR creation.
#
# Reads build.json from local/exports/{subfolder}/
# Writes solutions to:
#   local/solutions/unmanaged/  - unmanaged zips
#   local/solutions/unpacked/   - unpacked source
#   local/solutions/managed/    - managed zips (used by Deploy-Solutions.ps1)
#
# Prerequisites:
#   - pac CLI installed (dotnet tool install --global Microsoft.PowerApps.CLI.Tool)
#   - Az.Accounts PowerShell module (Install-Module Az.Accounts)
# =============================================================================

[CmdletBinding()]
param(
    [string]$EnvironmentUrl,

    # When provided by a caller (e.g. Run-Local.ps1), skips the interactive
    # subfolder prompt and uses this name directly.
    [string]$Subfolder
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
# Resolve repo root and local paths
# -----------------------------------------------------------------------------
$repoRoot      = Split-Path $PSScriptRoot -Parent
$localRoot     = $PSScriptRoot
$exportsRoot   = Join-Path $localRoot "exports"
$unmanagedDir  = Join-Path $localRoot "solutions/unmanaged"
$unpackedDir   = Join-Path $localRoot "solutions/unpacked"
$managedDir    = Join-Path $localRoot "solutions/managed"
$scriptsDir    = Join-Path $repoRoot "scripts"

New-Item -ItemType Directory -Path $unmanagedDir -Force | Out-Null
New-Item -ItemType Directory -Path $unpackedDir  -Force | Out-Null
New-Item -ItemType Directory -Path $managedDir   -Force | Out-Null

# -----------------------------------------------------------------------------
# Prompt for environment URL if not supplied
# -----------------------------------------------------------------------------
if (-not $EnvironmentUrl) {
    $EnvironmentUrl = Read-Host "Dev environment URL (e.g. https://org.crm.dynamics.com)"
}
$EnvironmentUrl = $EnvironmentUrl.TrimEnd("/")

# -----------------------------------------------------------------------------
# Select export subfolder (interactive if not passed by caller)
# -----------------------------------------------------------------------------
Write-Header "Select Export Subfolder"

$subfolders = Get-ChildItem -Path $exportsRoot -Directory | Sort-Object Name

if ($subfolders.Count -eq 0) {
    Write-Error "No subfolders found in: $exportsRoot`nCreate a subfolder with a build.json to continue."
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
    Write-Host "Solutions to export ($($solutions.Count)):"
    foreach ($s in $solutions) {
        Write-Host "  - $($s.name) (v$($s.version))"
    }
}

# Validate: isUnmanaged is not supported
$invalidSolutions = @($solutions | Where-Object {
    $_.PSObject.Properties["isUnmanaged"] -and [bool]$_.isUnmanaged
})
if ($invalidSolutions.Count -gt 0) {
    foreach ($s in $invalidSolutions) {
        Write-Host "  Invalid: '$($s.name)' has isUnmanaged=true"
    }
    Write-Error "build.json validation failed: isUnmanaged=true is not supported."
    exit 1
}

# -----------------------------------------------------------------------------
# Interactive pac auth
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
# Connect Azure account for REST API token (flow activation, config data, Power Pages)
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

# Acquire Dataverse token
try {
    $tokenObj  = Get-AzAccessToken -ResourceUrl $EnvironmentUrl
    $apiHeaders = @{
        "Authorization"    = "Bearer $($tokenObj.Token)"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        "Content-Type"     = "application/json"
        "Accept"           = "application/json"
    }
    Write-Host "Acquired Dataverse API token."
} catch {
    Write-Host "WARNING: Could not acquire Dataverse API token: $_"
    Write-Host "Power Pages site component population and cloud flow activation will be skipped."
    $apiHeaders = $null
}

# -----------------------------------------------------------------------------
# Step: Add Power Pages site components (if configured)
# -----------------------------------------------------------------------------
$ppSolutions = @($solutions | Where-Object {
    $_.PSObject.Properties["powerPagesConfiguration"] -and
    $_.powerPagesConfiguration -and
    $_.powerPagesConfiguration.PSObject.Properties["addAllExistingSiteComponentsForSites"] -and
    $_.powerPagesConfiguration.addAllExistingSiteComponentsForSites
})

if ($ppSolutions.Count -gt 0 -and $apiHeaders) {
    Write-Header "Add Power Pages Site Components"

    $addScript = Join-Path $scriptsDir "Add-PowerPagesSiteComponents.ps1"

    foreach ($solution in $ppSolutions) {
        $solutionName = $solution.name
        $sitesRaw     = $solution.powerPagesConfiguration.addAllExistingSiteComponentsForSites
        $siteNames    = @($sitesRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        Write-Host "Solution '$solutionName' — sites: $($siteNames -join ', ')"

        & $addScript `
            -SolutionUniqueName $solutionName `
            -SiteNames $siteNames `
            -EnvironmentUrl $EnvironmentUrl `
            -ApiHeaders $apiHeaders

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to add Power Pages site components for solution '$solutionName'."
            exit 1
        }
    }
} elseif ($ppSolutions.Count -gt 0 -and -not $apiHeaders) {
    Write-Host "WARNING: Power Pages solutions require a Dataverse API token — skipping site component population."
}

# -----------------------------------------------------------------------------
# Step: Export, unpack, and pack managed solutions
# -----------------------------------------------------------------------------
Write-Header "Export and Process Solutions"

$failedSolutions = @()
$cachedSolutions = @()

foreach ($solution in $solutions) {
    $name    = $solution.name
    $version = $solution.version

    Write-Host ""
    Write-Host "--------------------------------------------"
    Write-Host "  Solution: $name (v$version)"
    Write-Host "--------------------------------------------"

    # isExisting: use pre-existing managed zip, no export needed
    if ($solution.PSObject.Properties["isExisting"] -and $solution.isExisting -eq $true) {
        $existingZip = Join-Path $managedDir "${name}_${version}.zip"
        Write-Host "  isExisting = true — using pre-existing managed zip."
        if (-not (Test-Path $existingZip)) {
            Write-Host "  ERROR: managed zip not found at: $existingZip"
            $failedSolutions += $name
            continue
        }
        Write-Host "  Solution '$name' (v$version) — skipped export (isExisting=true)."
        continue
    }

    # Cached: managed zip already present for this name + version
    $existingManagedZip = Join-Path $managedDir "${name}_${version}.zip"
    if (Test-Path $existingManagedZip) {
        Write-Host "  Managed zip already exists — using cached version."

        # Detect cloud flows from cached unpacked source
        $cachedUnpackDir    = Join-Path $unpackedDir $name
        $cachedWorkflowsDir = Join-Path $cachedUnpackDir "Workflows"
        if (Test-Path $cachedWorkflowsDir) {
            $cachedFlowFiles = Get-ChildItem -Path $cachedWorkflowsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
            if ($cachedFlowFiles -and $cachedFlowFiles.Count -gt 0) {
                Write-Host "  Cloud flows detected (cached): $($cachedFlowFiles.Count) .json file(s)"
                $solution | Add-Member -NotePropertyName "includesCloudFlows" -NotePropertyValue $true -Force
            }
        }

        # Detect patch from cached Solution.xml
        $cachedSolutionXml = Join-Path $cachedUnpackDir "Other/Solution.xml"
        if (Test-Path $cachedSolutionXml) {
            [xml]$cachedXml = Get-Content $cachedSolutionXml
            $parentNode = $cachedXml.ImportExportXml.SolutionManifest.ParentSolution
            if ($parentNode -and $parentNode.UniqueName) {
                $localizedNames = $cachedXml.ImportExportXml.SolutionManifest.LocalizedNames.LocalizedName
                $displayName    = ($localizedNames | Where-Object { $_.languagecode -eq "1033" }).description
                if (-not $displayName) { $displayName = $name }
                Write-Host "  Patch solution (cached). Parent: $($parentNode.UniqueName)"
                $solution | Add-Member -NotePropertyName "isPatch"        -NotePropertyValue $true                 -Force
                $solution | Add-Member -NotePropertyName "parentSolution" -NotePropertyValue $parentNode.UniqueName -Force
                $solution | Add-Member -NotePropertyName "displayName"    -NotePropertyValue $displayName           -Force
            }
        }

        $cachedSolutions += $name
        Write-Host "  Solution '$name' (v$version) — cached, no re-export needed."
        continue
    }

    # Export unmanaged solution
    $unmanagedZip = Join-Path $unmanagedDir "$name.zip"
    Write-Host ""
    Write-Host "  Exporting unmanaged solution..."
    pac solution export --name $name --path $unmanagedZip --overwrite

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to export solution: $name"
        $failedSolutions += $name
        continue
    }
    Write-Host "  Export complete."

    # Clean unpack
    $solutionUnpackDir = Join-Path $unpackedDir $name
    Write-Host ""
    Write-Host "  Unpacking solution (clean)..."
    if (Test-Path $solutionUnpackDir) {
        Remove-Item -Path $solutionUnpackDir -Recurse -Force
    }

    pac solution unpack `
        --zipfile $unmanagedZip `
        --folder $solutionUnpackDir `
        --allowDelete true `
        --allowWrite true

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to unpack solution: $name"
        $failedSolutions += $name
        continue
    }
    Write-Host "  Unpack complete."

    # Detect cloud flows
    $workflowsDir = Join-Path $solutionUnpackDir "Workflows"
    if (Test-Path $workflowsDir) {
        $cloudFlowFiles = Get-ChildItem -Path $workflowsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        if ($cloudFlowFiles -and $cloudFlowFiles.Count -gt 0) {
            Write-Host "  Cloud flows detected: $($cloudFlowFiles.Count) .json file(s) in Workflows/"
            $solution | Add-Member -NotePropertyName "includesCloudFlows" -NotePropertyValue $true -Force
        } else {
            Write-Host "  No cloud flows in Workflows/"
        }
    } else {
        Write-Host "  No Workflows/ directory — no cloud flows"
    }

    # Validate version matches build.json
    $solutionXmlPath = Join-Path $solutionUnpackDir "Other/Solution.xml"
    if (-not (Test-Path $solutionXmlPath)) {
        Write-Host "  ERROR: Solution.xml not found at: $solutionXmlPath"
        $failedSolutions += $name
        continue
    }

    [xml]$solutionXml  = Get-Content $solutionXmlPath
    $actualVersion     = $solutionXml.ImportExportXml.SolutionManifest.Version
    Write-Host "  Version in environment: $actualVersion"
    Write-Host "  Version in build.json:  $version"

    if ($actualVersion -ne $version) {
        Write-Host "  ERROR: Version mismatch for '$name': build.json=$version, environment=$actualVersion."
        Write-Host "         Update build.json to match before re-running."
        $failedSolutions += $name
        continue
    }
    Write-Host "  Version check passed."

    # Detect patch
    $parentNode = $solutionXml.ImportExportXml.SolutionManifest.ParentSolution
    if ($parentNode -and $parentNode.UniqueName) {
        $parentName     = $parentNode.UniqueName
        $localizedNames = $solutionXml.ImportExportXml.SolutionManifest.LocalizedNames.LocalizedName
        $displayName    = ($localizedNames | Where-Object { $_.languagecode -eq "1033" }).description
        if (-not $displayName) { $displayName = $name }
        Write-Host "  Patch solution detected. Parent: $parentName | Display: $displayName"
        $solution | Add-Member -NotePropertyName "isPatch"        -NotePropertyValue $true        -Force
        $solution | Add-Member -NotePropertyName "parentSolution" -NotePropertyValue $parentName  -Force
        $solution | Add-Member -NotePropertyName "displayName"    -NotePropertyValue $displayName -Force
    }

    # Rename unmanaged zip to versioned name
    $versionedUnmanagedZip = Join-Path $unmanagedDir "${name}_${version}.zip"
    Move-Item -Path $unmanagedZip -Destination $versionedUnmanagedZip -Force
    Write-Host "  Renamed unmanaged zip: ${name}_${version}.zip"

    # Export managed solution
    $managedZip = Join-Path $managedDir "${name}_${version}.zip"
    Write-Host ""
    Write-Host "  Exporting managed solution..."
    pac solution export --name $name --path $managedZip --managed --overwrite

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to export managed solution: $name"
        $failedSolutions += $name
        continue
    }
    Write-Host "  Managed export complete: $managedZip"
    Write-Host "  Solution '$name' (v$version) processed successfully."
}

# -----------------------------------------------------------------------------
# Update build.json with cloud flow flags
# -----------------------------------------------------------------------------
$updatedConfig = @{ solutions = @($solutions) }
if ($buildConfig.PSObject.Properties["configData"] -and $buildConfig.configData) {
    $updatedConfig["configData"] = $buildConfig.configData
}
$updatedConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $buildJsonPath -Encoding UTF8
Write-Host ""
Write-Host "Updated build.json with detection results."

# -----------------------------------------------------------------------------
# Extract configuration data (if configData defined in build.json)
# -----------------------------------------------------------------------------
if ($buildConfig.PSObject.Properties["configData"] -and $buildConfig.configData.Count -gt 0) {
    Write-Header "Extract Config Data from Dev"

    if (-not $apiHeaders) {
        Write-Host "WARNING: No Dataverse API token — skipping config data extraction."
    } else {
        $configData = @($buildConfig.configData)
        $syncScript = Join-Path $scriptsDir "Sync-ConfigData.ps1"

        & $syncScript `
            -Mode Extract `
            -ConfigData $configData `
            -EnvironmentUrl $EnvironmentUrl `
            -ApiHeaders $apiHeaders `
            -SourceDir $exportDir

        Write-Host "Config data extraction complete."
    }
} else {
    Write-Host ""
    Write-Host "No configData in build.json — skipping extraction."
}

# -----------------------------------------------------------------------------
# Post-export version management (postExportVersion / createNewPatch)
# Mirrors pipeline step 15. Runs after export; failures warn but do not stop.
# Skipped entirely if no solutions have postExportVersion defined.
# Skipped per-solution if isExisting=true or isRollback=true.
# -----------------------------------------------------------------------------
$postManaged = @($solutions | Where-Object {
    $_.PSObject.Properties["postExportVersion"] -and $_.postExportVersion
})

if ($postManaged.Count -gt 0) {
    Write-Header "Post-Export Version Management"

    if (-not $apiHeaders) {
        Write-Host "WARNING: No Dataverse API token — skipping post-export version management."
    } else {
        $patchDisplayNamePrefix = "(DO NOT USE) "
        $postFailedUpdates      = @()

        foreach ($solution in $solutions) {
            $name = $solution.name

            if (-not $solution.PSObject.Properties["postExportVersion"] -or -not $solution.postExportVersion) {
                Write-Host "Skipping '$name' — no postExportVersion defined."
                continue
            }

            if ($solution.isExisting -eq $true -or $solution.isRollback -eq $true) {
                $reason = if ($solution.isExisting -eq $true) { "isExisting=true" } else { "isRollback=true" }
                Write-Host "Skipping '$name' — version management skipped ($reason)."
                continue
            }

            $postVersion    = $solution.postExportVersion
            $createNewPatch = $false
            if ($solution.PSObject.Properties["createNewPatch"]) {
                $createNewPatch = [bool]$solution.createNewPatch
            }

            Write-Host ""
            Write-Host "  $name -> v$postVersion  (createNewPatch: $createNewPatch)"

            # Query solution details (id, friendly name, parent)
            try {
                $solQuery  = "$EnvironmentUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$name'&`$select=solutionid,friendlyname&`$expand=parentsolutionid(`$select=uniquename,friendlyname)"
                $solResult = Invoke-RestMethod -Uri $solQuery -Headers $apiHeaders
                $solRecord       = $solResult.value[0]
                $friendlyName    = $solRecord.friendlyname
                $solutionId      = $solRecord.solutionid
                $isAPatch        = $solRecord.parentsolutionid -and $solRecord.parentsolutionid.uniquename

                if ($isAPatch) {
                    $parentUniqueName   = $solRecord.parentsolutionid.uniquename
                    $parentFriendlyName = $solRecord.parentsolutionid.friendlyname
                    Write-Host "  '$name' is a patch — parent: '$parentUniqueName'"
                } else {
                    $parentUniqueName   = $name
                    $parentFriendlyName = $friendlyName
                }
            } catch {
                Write-Host "  WARNING: Failed to query solution details for '$name': $($_.Exception.Message)"
                $postFailedUpdates += $name
                continue
            }

            if ($createNewPatch) {
                # CloneAsPatch — must target the parent (base) solution, not a patch
                try {
                    $patchDisplayName = "$parentFriendlyName (PATCH)"
                    Write-Host "  Creating new patch from '$parentUniqueName' as '$patchDisplayName' at v$postVersion..."
                    $cloneBody = @{
                        ParentSolutionUniqueName = $parentUniqueName
                        DisplayName              = $patchDisplayName
                        VersionNumber            = $postVersion
                    } | ConvertTo-Json

                    Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/CloneAsPatch" -Method Post -Headers $apiHeaders -Body $cloneBody
                    Write-Host "  New patch created at v$postVersion."

                    # Mark the superseded patch as obsolete if it was itself a patch
                    if ($isAPatch) {
                        if (-not $friendlyName.StartsWith($patchDisplayNamePrefix)) {
                            $newDisplayName = "$patchDisplayNamePrefix$friendlyName"
                            Write-Host "  Marking old patch '$name' as obsolete: '$newDisplayName'..."
                            $renameBody = @{ friendlyname = $newDisplayName } | ConvertTo-Json
                            Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/solutions($solutionId)" `
                                -Method Patch -Headers $apiHeaders -Body $renameBody | Out-Null
                            Write-Host "  Old patch renamed to: '$newDisplayName'"
                        } else {
                            Write-Host "  Old patch already has prefix — skipping rename."
                        }
                    }
                } catch {
                    Write-Host "  WARNING: Failed to create patch from '$name': $($_.Exception.Message)"
                    $postFailedUpdates += $name
                    continue
                }

            } else {
                # CloneAsSolution — if name is a patch, clone the parent instead
                $targetName         = $parentUniqueName
                $targetFriendlyName = $parentFriendlyName
                if ($isAPatch) {
                    Write-Host "  '$name' is a patch — cloning parent '$targetName' to v$postVersion..."
                } else {
                    Write-Host "  Cloning '$targetName' to v$postVersion..."
                }

                try {
                    $cloneBody = @{
                        ParentSolutionUniqueName = $targetName
                        DisplayName              = $targetFriendlyName
                        VersionNumber            = $postVersion
                    } | ConvertTo-Json

                    Invoke-RestMethod -Uri "$EnvironmentUrl/api/data/v9.2/CloneAsSolution" -Method Post -Headers $apiHeaders -Body $cloneBody
                    Write-Host "  Solution cloned to v$postVersion."
                } catch {
                    Write-Host "  WARNING: Failed to clone solution '$targetName': $($_.Exception.Message)"
                    $postFailedUpdates += $name
                    continue
                }
            }
        }

        if ($postFailedUpdates.Count -gt 0) {
            Write-Host ""
            Write-Host "WARNING: Post-export version management failed for: $($postFailedUpdates -join ', ')"
            Write-Host "         Solutions were exported successfully — only the Dev version bump failed."
        } else {
            Write-Host ""
            Write-Host "Post-export version management complete."
        }
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Header "Export Summary"

$exportedCount = $solutions.Count - $failedSolutions.Count - $cachedSolutions.Count
Write-Host "Subfolder:       $Subfolder"
Write-Host "Total solutions: $($solutions.Count)"
Write-Host "Exported:        $exportedCount"
Write-Host "Cached:          $($cachedSolutions.Count)"
Write-Host "Failed:          $($failedSolutions.Count)"

if ($cachedSolutions.Count -gt 0) {
    Write-Host "Cached (skipped re-export): $($cachedSolutions -join ', ')"
}

if ($failedSolutions.Count -gt 0) {
    Write-Host "Failed: $($failedSolutions -join ', ')"
    Write-Error "One or more solutions failed to process."
    exit 1
}

Write-Host ""
Write-Host "Managed zips are in: $managedDir"
Write-Host "Run Deploy-Solutions.ps1 to deploy to a target environment."
Write-Host ""
Write-Host "All solutions exported successfully."
