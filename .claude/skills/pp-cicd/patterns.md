# Code Patterns & Conventions Reference

This document contains the detailed code patterns, naming conventions, and implementation specifics that the skill should follow when generating pipelines.

## Naming Conventions

### File Naming

| Pattern | Example | Used For |
|---------|---------|----------|
| `{SolutionName}_{version}.zip` | `CoreComponents_1.2.0.0.zip` | Versioned solution artifacts (daily export) |
| `deploymentSettings_{Env}.json` | `deploymentSettings_Test.json` | Per-environment deployment settings |
| `build.json` | `build.json` | Export/release configuration |
| `export/{yyyy-MM-dd}-{token}` | `export/2026-02-15-sprint42` | Export branch names |
| `exports/{yyyy-MM-dd-token}/` | `exports/2026-02-15-sprint42/` | Export configuration folder |
| `configData/{Name}.json` | `configData/USStates.json` | Extracted configuration data files |

### ADO Resource Naming

| Resource Type | Pattern | Example |
|--------------|---------|---------|
| Service connection | `PowerPlatform{Env}` | `PowerPlatformDev`, `PowerPlatformTest` |
| Variable group | `PowerPlatform-{Env}` | `PowerPlatform-Test`, `PowerPlatform-Prod` |
| ADO environment | `Power Platform {Env}` | `Power Platform Test`, `Power Platform Prod` |
| Pipeline name | lowercase with hyphens | `export-solutions`, `release-solutions` |

## Authentication Patterns

### Pattern: pac CLI with Variable Group

Used by release and deploy pipelines for all deployment stages.

```yaml
stages:
  - stage: Test
    variables:
      - group: PowerPlatform-Test
    jobs:
      - deployment: Deploy
        environment: "Power Platform Test"
        strategy:
          runOnce:
            deploy:
              steps:
                - pwsh: |
                    $ErrorActionPreference = "Stop"
                    Write-Host "Authenticating with: $(EnvironmentUrl)"
                    pac auth create `
                      --environment "$(EnvironmentUrl)" `
                      --applicationId "$(ClientId)" `
                      --clientSecret "$(ClientSecret)" `
                      --tenant "$(TenantId)"
                    if ($LASTEXITCODE -ne 0) {
                      Write-Error "Failed to authenticate with Power Platform"
                      exit 1
                    }
                    Write-Host "Successfully authenticated."
                    pac auth list
                  displayName: "Authenticate with Power Platform"
                  env:
                    ClientSecret: $(ClientSecret)
```

**Important:** Always pass `ClientSecret` via the `env:` block (not inline in the script) for security.

### Pattern: Service Connection (ADO Tasks)

Used by the daily export pipeline for Power Platform Build Tools tasks.

```yaml
variables:
  - name: PowerPlatformServiceConnection
    value: "PowerPlatformDev"

steps:
  - task: PowerPlatformExportSolution@2
    inputs:
      authenticationType: PowerPlatformSPN
      PowerPlatformSPN: $(PowerPlatformServiceConnection)
      SolutionName: MySolution
      SolutionOutputFile: $(Build.SourcesDirectory)/solutions/unmanaged/MySolution.zip
      Managed: false
      AsyncOperation: true
      MaxAsyncWaitTime: 60
```

### Pattern: Secret Pipeline Variables (pac CLI)

Used by daily export pipeline when not using a variable group.

```yaml
# Variables configured in ADO UI (not in YAML):
# - ClientId (plain)
# - ClientSecret (secret)
# - TenantId (plain)

steps:
  - pwsh: |
      pac auth create `
        --environment "$(EnvironmentUrl)" `
        --applicationId "$(ClientId)" `
        --clientSecret "$(ClientSecret)" `
        --tenant "$(TenantId)"
    displayName: "Authenticate with Power Platform"
```

## Artifact Flow Patterns

### Pattern: Pipeline Resource Trigger

```yaml
trigger: none

resources:
  pipelines:
    - pipeline: ExportPipeline          # alias used in download steps
      source: "export-solutions"        # must match ADO pipeline name exactly
      trigger:
        branches:
          include:
            - main
```

### Pattern: Conditional Artifact Download

```yaml
# Auto-triggered: download from pipeline resource
- download: exportSolution
  artifact: ManagedSolution
  displayName: "Download managed solution from export pipeline"
  condition: eq(variables['Build.Reason'], 'ResourceTrigger')

# Manual: use repo source (no download needed)
```

### Pattern: Stage-to-Stage Artifact Passing

Dev stage publishes an artifact that downstream stages consume:

```yaml
# Dev stage: publish after import
- pwsh: |
    $stagingDir = "$(Build.ArtifactStagingDirectory)/DeploySolution"
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    Copy-Item -Path "$(SolutionZipPath)" -Destination $stagingDir
  displayName: "Stage solution for downstream stages"

- task: PublishPipelineArtifact@1
  displayName: "Publish solution for downstream stages"
  inputs:
    targetPath: $(Build.ArtifactStagingDirectory)/DeploySolution
    artifact: DeploySolution

# Downstream stage: download from current pipeline
- download: current
  artifact: DeploySolution
  displayName: "Download solution artifact"
```

## Solution Export Patterns

### Pattern: Clean Unpack

Always delete existing unpacked folder before unpacking to prevent stale files:

```powershell
$unpackDir = "$(Build.SourcesDirectory)/solutions/unpacked/$solutionName"
if (Test-Path $unpackDir) {
  Write-Host "Removing existing unpacked folder: $unpackDir"
  Remove-Item -Path $unpackDir -Recurse -Force
}
```

### Pattern: Version Validation

```powershell
$solutionXmlPath = Join-Path $unpackDir "Other/Solution.xml"
[xml]$solutionXml = Get-Content $solutionXmlPath
$actualVersion = $solutionXml.ImportExportXml.SolutionManifest.Version

if ($actualVersion -ne $expectedVersion) {
  Write-Error ("Version mismatch for '$solutionName': " +
    "build.json specifies v$expectedVersion but dev environment has v$actualVersion. " +
    "Update build.json to match the dev environment before re-running.")
  exit 1
}
```

### Pattern: Patch Detection

```powershell
$parentNode = $solutionXml.ImportExportXml.SolutionManifest.ParentSolution
if ($parentNode) {
  $solution.isPatch = $true
  $solution.parentSolution = $parentNode.UniqueName
  $solution.displayName = $solutionXml.ImportExportXml.SolutionManifest.LocalizedNames.LocalizedName |
    Where-Object { $_.languagecode -eq "1033" } |
    Select-Object -ExpandProperty description
}
```

### Pattern: Cloud Flow Detection

```powershell
$workflowsDir = Join-Path $unpackDir "Workflows"
$hasCloudFlows = $false
if (Test-Path $workflowsDir) {
  $jsonFiles = Get-ChildItem -Path $workflowsDir -Filter "*.json" -ErrorAction SilentlyContinue
  if ($jsonFiles -and $jsonFiles.Count -gt 0) {
    $hasCloudFlows = $true
  }
}
$solution.includesCloudFlows = $hasCloudFlows
```

### Pattern: Artifact Caching (Skip Re-export)

```powershell
$managedZip = "$(Build.SourcesDirectory)/solutions/managed/${name}_${version}.zip"
if (Test-Path $managedZip) {
  Write-Host "Managed zip already exists for $name v$version — skipping export."
  continue
}
```

## Deployment Patterns

### Pattern: Upfront Artifact Validation

Validate everything exists before importing anything:

```powershell
$missingArtifacts = @()
foreach ($solution in $solutions) {
  $zipPath = Join-Path $artifactDir "$($solution.name)_$($solution.version).zip"
  if (-not (Test-Path $zipPath)) {
    $missingArtifacts += "$($solution.name)_$($solution.version).zip"
  }
  # Also check deployment settings if required
  if ($solution.includeDeploymentSettings) {
    $settingsFile = Join-Path $artifactDir "deploymentSettings_${stageName}.json"
    if (-not (Test-Path $settingsFile)) {
      $missingArtifacts += "deploymentSettings_${stageName}.json"
    }
  }
}
if ($missingArtifacts.Count -gt 0) {
  Write-Error "Artifact validation failed — $($missingArtifacts.Count) file(s) missing."
  exit 1
}
```

### Pattern: Version-Based Skip Logic

```powershell
$listJson = pac solution list --output json 2>&1 | Out-String
$installedList = @($listJson | ConvertFrom-Json)
$installed = @{}
foreach ($s in $installedList) {
  $installed[$s.uniqueName] = $s.version
}

foreach ($solution in $solutions) {
  if ($installed.ContainsKey($solution.name)) {
    if ($installed[$solution.name] -eq $solution.version) {
      Write-Host "Already installed at v$($solution.version) — skipping."
      $skippedSolutions += $solution.name
      continue
    }
  }
  # Import...
}
```

### Pattern: Solution Import with Conditional Settings

```powershell
$importArgs = @(
  "solution", "import",
  "--path", $zipPath,
  "--activate-plugins",
  "--async",
  "--max-async-wait-time", "60"
)

# Power Pages deployMode overrides the default upgrade strategy for managed solutions.
# isRollback skips staged upgrade entirely.
if ($ppConfig -and $ppDeployMode) {
  switch ($ppDeployMode) {
    "UPGRADE"         { $importArgs += "--stage-and-upgrade"; $importArgs += "--skip-lower-version" }
    "UPDATE"          { } # plain import — no staging flags
    "STAGE_FOR_UPGRADE" { $importArgs += "--import-as-holding" }
  }
} elseif ($isUpgrade -and -not $isRollback) {
  $importArgs += "--stage-and-upgrade"
  $importArgs += "--skip-lower-version"
}

if ($includeSettings -and (Test-Path $settingsFile)) {
  $importArgs += @("--settings-file", $settingsFile)
}

& pac @importArgs

if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to import solution: $name"
  $failedSolutions += $name
  continue
}
```

### Pattern: Deployment Summary

```powershell
Write-Host ""
Write-Host "============================================"
Write-Host "  Deployment Summary — $stageName"
Write-Host "============================================"
Write-Host "Total solutions: $($solutions.Count)"
Write-Host "Deployed:        $($deployedSolutions.Count)"
Write-Host "Skipped:         $($skippedSolutions.Count)"
Write-Host "Failed:          $($failedSolutions.Count)"

if ($failedSolutions.Count -gt 0) {
  Write-Error "One or more solutions failed to deploy"
  exit 1
}
```

## Cloud Flow Activation Pattern

### OAuth Token Acquisition

```powershell
$tokenUrl = "https://login.microsoftonline.com/$(TenantId)/oauth2/v2.0/token"
$tokenBody = @{
  grant_type    = "client_credentials"
  client_id     = "$(ClientId)"
  client_secret = $env:ClientSecret
  scope         = "$(EnvironmentUrl)/.default"
}

try {
  $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody
  $apiHeaders = @{
    "Authorization"    = "Bearer $($tokenResponse.access_token)"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    "Content-Type"     = "application/json"
    "Accept"           = "application/json"
  }
  $hasApiToken = $true
} catch {
  $hasApiToken = $false
  Write-Host "##vso[task.logissue type=warning]Could not acquire Dataverse API token: $_"
}
```

### Flow Query and Activation

```powershell
$envUrl = "$(EnvironmentUrl)".TrimEnd("/")

# Find solution ID
$solQuery = "$envUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$name'&`$select=solutionid"
$solResult = Invoke-RestMethod -Uri $solQuery -Headers $apiHeaders
$solutionId = $solResult.value[0].solutionid

# Get workflow components (type 29)
$compQuery = "$envUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $solutionId and componenttype eq 29&`$select=objectid"
$compResult = Invoke-RestMethod -Uri $compQuery -Headers $apiHeaders

foreach ($wfId in $compResult.value.objectid) {
  $wf = Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/workflows($wfId)?`$select=name,category,statecode" -Headers $apiHeaders

  # Only cloud flows (category 5) that are inactive (statecode != 1)
  if ($wf.category -ne 5 -or $wf.statecode -eq 1) { continue }

  try {
    Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/workflows($wfId)" -Method Patch -Headers $apiHeaders -Body '{"statecode": 1}'
    Write-Host "Activated flow: $($wf.name)"
  } catch {
    Write-Host "##vso[task.logissue type=warning]Failed to activate flow '$($wf.name)': $_"
  }
}
```

## Post-Export Version Management Pattern

### Non-Patch Solutions

```powershell
pac solution online-version `
  --solution-name $solutionName `
  --solution-version $postExportVersion
```

### Patch Solutions (CloneAsPatch)

```powershell
# 1. Rename old patch (add prefix)
$patchPrefix = if ($env:PatchDisplayNamePrefix) { $env:PatchDisplayNamePrefix } else { "(DO NOT USE) " }
$renameBody = @{ friendlyname = "${patchPrefix}${displayName}" } | ConvertTo-Json
Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/solutions($patchSolutionId)" -Method Patch -Headers $apiHeaders -Body $renameBody

# 2. Clone new patch from parent at new version
$cloneBody = @{
  ParentSolutionUniqueName = $parentSolution
  DisplayName             = $displayName
  VersionNumber           = $postExportVersion
} | ConvertTo-Json
Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/CloneAsPatch" -Method Post -Headers $apiHeaders -Body $cloneBody
```

## Deployment Settings Merge Pattern

### Merge Algorithm (Merge-DeploymentSettings.ps1)

```powershell
function Merge-SettingsArray {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][array]$RootItems,
    [Parameter(Mandatory)][AllowEmptyCollection()][array]$ExportItems,
    [Parameter(Mandatory)][string]$KeyProperty
  )

  $merged = [System.Collections.ArrayList]::new()
  $indexMap = @{}

  # Seed with root items (preserves order)
  for ($i = 0; $i -lt $RootItems.Count; $i++) {
    $key = $RootItems[$i].$KeyProperty
    [void]$merged.Add($RootItems[$i])
    $indexMap[$key] = $i
  }

  # Overlay export items (overwrite on match, append if new)
  foreach ($exportItem in $ExportItems) {
    $key = $exportItem.$KeyProperty
    if ($indexMap.ContainsKey($key)) {
      $merged[$indexMap[$key]] = $exportItem
    } else {
      $indexMap[$key] = $merged.Count
      [void]$merged.Add($exportItem)
    }
  }

  return @($merged)
}
```

**Key properties:**
- `EnvironmentVariables` → matched by `SchemaName`
- `ConnectionReferences` → matched by `LogicalName`

## Template Parameter Pattern

All reusable templates follow this parameter convention:

```yaml
parameters:
  - name: stageName         # Short name: "Test", "Stage", "Prod"
    type: string
  - name: displayName       # Human-readable: "Deploy to Test"
    type: string
  - name: environmentName   # ADO environment: "Power Platform Test"
    type: string
  - name: variableGroup     # Credential group: "PowerPlatform-Test"
    type: string
  - name: dependsOn         # Previous stage: "Dev", "Test", etc.
    type: string
    default: ""

stages:
  - stage: ${{ parameters.stageName }}
    displayName: ${{ parameters.displayName }}
    ${{ if eq(parameters.dependsOn, '') }}:
      dependsOn: []
    ${{ else }}:
      dependsOn: ${{ parameters.dependsOn }}
    variables:
      - group: ${{ parameters.variableGroup }}
    jobs:
      - deployment: Deploy
        displayName: "Deploy solutions to ${{ parameters.stageName }}"
        environment: ${{ parameters.environmentName }}
        strategy:
          runOnce:
            deploy:
              steps:
                # ... deployment logic
```

## PR Automation Pattern (Daily Export)

```powershell
# Create PR
$prTitle = "Export Power Platform Solutions - $exportSubfolder"
$prBody = "Automated export of Power Platform solutions.`n`nSolutions:`n"
foreach ($s in $solutions) {
  $prBody += "- $($s.name) v$($s.version)`n"
}

az repos pr create `
  --repository "$(Build.Repository.Name)" `
  --source-branch "$exportBranch" `
  --target-branch "main" `
  --title "$prTitle" `
  --description "$prBody" `
  --auto-complete `
  --merge-strategy squash `
  --delete-source-branch
```

## YAML Header Convention

Every pipeline YAML starts with a descriptive header comment block:

```yaml
# =============================================================================
# Pipeline: {Pipeline Display Name}
# =============================================================================
# {One-line description of what this pipeline does.}
#
# {Additional context: trigger behavior, auto vs manual, etc.}
#
# Prerequisites:
#   1. {First prerequisite}
#   2. {Second prerequisite}
#   ...
#
# {Notes about authentication, variables, etc.}
# =============================================================================
```

## ADO Task Versions

Always use these task versions:
- `PowerPlatformToolInstaller@2`
- `PowerPlatformExportSolution@2`
- `PowerPlatformUnpackSolution@2`
- `PowerPlatformPackSolution@2`
- `PowerPlatformImportSolution@2`
- `PublishPipelineArtifact@1`

## Configuration Data Patterns

### Pattern: Config Data Extract (OData Query)

```powershell
$selectColumns = "$primaryKey,$select"
$queryUrl = "$envUrl/api/data/v9.2/$entity`?`$select=$selectColumns"

if ($filter) {
  $queryUrl += "&`$filter=$filter"
}

$allRecords = @()
$nextLink = $queryUrl

# Handle OData pagination
while ($nextLink) {
  $response = Invoke-RestMethod -Uri $nextLink -Headers $apiHeaders
  $allRecords += @($response.value)

  if ($response.PSObject.Properties["@odata.nextLink"]) {
    $nextLink = $response."@odata.nextLink"
  } else {
    $nextLink = $null
  }
}

# Clean OData metadata from each record
$cleanRecords = @()
foreach ($record in $allRecords) {
  $clean = @{}
  foreach ($prop in $record.PSObject.Properties) {
    if (-not $prop.Name.StartsWith("@odata.") -and -not $prop.Name.StartsWith("_") -and $prop.Name -ne "versionnumber") {
      $clean[$prop.Name] = $prop.Value
    }
  }
  $cleanRecords += $clean
}

$cleanRecords | ConvertTo-Json -Depth 10 | Set-Content -Path $dataFilePath -Encoding UTF8
```

### Pattern: Config Data Upsert (PATCH by GUID)

```powershell
foreach ($record in $records) {
  $guid = $record.$primaryKey

  # Build body (all columns except primary key)
  $body = @{}
  foreach ($prop in $record.PSObject.Properties) {
    if ($prop.Name -ne $primaryKey) {
      $body[$prop.Name] = $prop.Value
    }
  }

  $patchUrl = "$envUrl/api/data/v9.2/$entity($guid)"
  $patchBody = $body | ConvertTo-Json -Depth 5 -Compress

  try {
    # PATCH without If-Match header = upsert (creates if not exists, updates if exists)
    Invoke-RestMethod -Uri $patchUrl -Method Patch -Headers $apiHeaders -Body $patchBody | Out-Null
  } catch {
    Write-Host "##vso[task.logissue type=warning]Failed to upsert record $guid: $_"
  }
}
```

**Key rules:**
- `PATCH /api/data/v9.2/{entity}({guid})` without `If-Match` header = upsert
- Primary key GUID must be stable across all environments
- Entity name must be the OData plural form (e.g., `cr123_states`)
- Extract cleans OData metadata (`@odata.*`, `_*_value`, `versionnumber`)
- Upsert record failures are warnings (don't fail the deployment)

### Pattern: Config Data in Pipeline Steps

```yaml
# In export pipeline — extract after solution export, before artifact publish
- pwsh: |
    $configData = @("$(ConfigDataList)" | ConvertFrom-Json)
    $syncScript = Join-Path $sourceDir "scripts/Sync-ConfigData.ps1"
    & $syncScript -Mode Extract -ConfigData $configData -EnvironmentUrl $envUrl -ApiHeaders $apiHeaders -SourceDir $sourceDir
  displayName: "Extract config data from Dev"
  env:
    ClientSecret: $(ClientSecret)

# In deploy pipelines — upsert after solution import
- pwsh: |
    $buildConfig = Get-Content $buildJsonPath -Raw | ConvertFrom-Json
    $configData = @($buildConfig.configData)
    $syncScript = "$(Build.SourcesDirectory)/scripts/Sync-ConfigData.ps1"
    & $syncScript -Mode Upsert -ConfigData $configData -EnvironmentUrl $envUrl -ApiHeaders $apiHeaders -SourceDir $artifactDir
  displayName: "Upsert config data"
  env:
    ClientSecret: $(ClientSecret)
```

## Pool Configuration

All pipelines use Microsoft-hosted Windows agents:

```yaml
pool:
  vmImage: "windows-latest"
```

## PowerShell Conventions

- Always start scripts with `$ErrorActionPreference = "Stop"`
- Use `pwsh` (not `powershell`) for cross-platform compatibility
- Use backtick (`` ` ``) for line continuation in pac CLI calls
- Use `Write-Host "##vso[task.setvariable variable=Name]Value"` for cross-step variables
- Use `Write-Host "##vso[task.logissue type=warning]Message"` for ADO warnings
- Use `Write-Error` + `exit 1` for failures
- Always check `$LASTEXITCODE` after pac CLI calls
