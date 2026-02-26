<#
.SYNOPSIS
  Merges deployment settings from an export folder into the root
  deploymentSettings folder.

.DESCRIPTION
  For each deploymentSettings_{env}.json file found in the export folder,
  merges its EnvironmentVariables and ConnectionReferences into the
  corresponding root file. Items from the export overwrite matching items
  in the root (matched by SchemaName for variables, LogicalName for
  connection references). New items are appended.

.PARAMETER ExportFolder
  Path to the export folder containing deploymentSettings_*.json files.

.PARAMETER RootFolder
  Path to the root deploymentSettings folder.
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$ExportFolder,

  [Parameter(Mandatory = $true)]
  [string]$RootFolder
)

$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------
# Merge function: takes root array and export array, returns merged result.
# Items are matched by a key property. Export items overwrite root matches.
# -------------------------------------------------------------------------
function Merge-SettingsArray {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [array]$RootItems,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [array]$ExportItems,

    [Parameter(Mandatory = $true)]
    [string]$KeyProperty
  )

  # Build an ordered list: start with root items, overwrite or append from export
  $merged = [System.Collections.ArrayList]::new()
  $indexMap = @{}

  for ($i = 0; $i -lt $RootItems.Count; $i++) {
    $key = $RootItems[$i].$KeyProperty
    [void]$merged.Add($RootItems[$i])
    $indexMap[$key] = $i
  }

  foreach ($exportItem in $ExportItems) {
    $key = $exportItem.$KeyProperty
    if ($indexMap.ContainsKey($key)) {
      # Overwrite existing item
      $merged[$indexMap[$key]] = $exportItem
    } else {
      # Append new item
      $indexMap[$key] = $merged.Count
      [void]$merged.Add($exportItem)
    }
  }

  return @($merged)
}

# -------------------------------------------------------------------------
# Main: find export settings files and merge each into the root
# -------------------------------------------------------------------------
$exportFiles = Get-ChildItem -Path $ExportFolder -Filter "deploymentSettings_*.json" -ErrorAction SilentlyContinue

if (-not $exportFiles -or $exportFiles.Count -eq 0) {
  Write-Host "No deployment settings files found in export folder. Nothing to merge."
  exit 0
}

$mergedCount = 0

foreach ($exportFile in $exportFiles) {
  $envName = $exportFile.BaseName -replace "^deploymentSettings_", ""
  $rootFile = Join-Path $RootFolder $exportFile.Name

  Write-Host "Processing: $($exportFile.Name) (environment: $envName)"

  # Load export settings
  $exportSettings = Get-Content $exportFile.FullName -Raw | ConvertFrom-Json

  # Load or initialize root settings
  if (Test-Path $rootFile) {
    $rootSettings = Get-Content $rootFile -Raw | ConvertFrom-Json
  } else {
    Write-Host "  Root file does not exist — creating new: $($exportFile.Name)"
    $rootSettings = [PSCustomObject]@{
      EnvironmentVariables = @()
      ConnectionReferences = @()
    }
  }

  # Ensure arrays exist (guard against $null from ConvertFrom-Json when a property
  # is missing or explicitly null — @($null) is unreliable across PS versions)
  $rootEnvVars   = if ($rootSettings.EnvironmentVariables)   { @($rootSettings.EnvironmentVariables)   } else { @() }
  $rootConnRefs  = if ($rootSettings.ConnectionReferences)   { @($rootSettings.ConnectionReferences)   } else { @() }
  $exportEnvVars = if ($exportSettings.EnvironmentVariables) { @($exportSettings.EnvironmentVariables) } else { @() }
  $exportConnRefs= if ($exportSettings.ConnectionReferences) { @($exportSettings.ConnectionReferences) } else { @() }

  # Merge
  $mergedEnvVars = Merge-SettingsArray -RootItems $rootEnvVars -ExportItems $exportEnvVars -KeyProperty "SchemaName"
  $mergedConnRefs = Merge-SettingsArray -RootItems $rootConnRefs -ExportItems $exportConnRefs -KeyProperty "LogicalName"

  # Build output
  $output = [PSCustomObject]@{
    EnvironmentVariables = $mergedEnvVars
    ConnectionReferences = $mergedConnRefs
  }

  # Write back
  $output | ConvertTo-Json -Depth 10 | Set-Content -Path $rootFile -Encoding UTF8
  Write-Host "  Merged into: $rootFile"
  Write-Host "    EnvironmentVariables: $($mergedEnvVars.Count) items"
  Write-Host "    ConnectionReferences: $($mergedConnRefs.Count) items"
  $mergedCount++
}

Write-Host "`nMerge complete. Processed $mergedCount file(s)."
