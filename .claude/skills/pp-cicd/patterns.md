# Code Patterns & Conventions Reference

This document contains the detailed code patterns, naming conventions, and implementation specifics that the skill should follow when generating pipelines.

## Naming Conventions

### File Naming

| Pattern | Example | Used For |
|---------|---------|----------|
| `{SolutionName}_{version}.zip` | `CoreComponents_1.2.0.0.zip` | Versioned solution artifacts (daily export) |
| `{SolutionName}.zip` | `MainApp.zip` | Unversioned solution artifacts (pre-dev export) |
| `deploymentSettings_{Env}.json` | `deploymentSettings_QA.json` | Per-environment deployment settings |
| `build.json` | `build.json` | Export/release configuration |
| `export/{yyyy-MM-dd}-{token}` | `export/2026-02-15-sprint42` | Export branch names |
| `exports/{yyyy-MM-dd-token}/` | `exports/2026-02-15-sprint42/` | Export configuration folder |
| `configData/{Name}.json` | `configData/USStates.json` | Extracted configuration data files |

### ADO Resource Naming

| Resource Type | Pattern | Example |
|--------------|---------|---------|
| Service connection | `PowerPlatform{Env}` | `PowerPlatformPreDev`, `PowerPlatformDev` |
| Variable group | `PowerPlatform-{Env}` | `PowerPlatform-QA`, `PowerPlatform-Prod` |
| ADO environment | `Power Platform {Env}` | `Power Platform QA`, `Power Platform Prod` |
| Pipeline name | lowercase with hyphens | `export-solutions`, `release-solutions` |

## Authentication Patterns

### Pattern: pac CLI with Variable Group

Used by release and deploy pipelines for all deployment stages.

```yaml
stages:
  - stage: QA
    variables:
      - group: PowerPlatform-QA
    jobs:
      - deployment: Deploy
        environment: "Power Platform QA"
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

Used by export pipelines for Power Platform Build Tools tasks.

```yaml
variables:
  - name: PreDevServiceConnection
    value: "PowerPlatformPreDev"

steps:
  - task: PowerPlatformExportSolution@2
    inputs:
      authenticationType: PowerPlatformSPN
      PowerPlatformSPN: $(PreDevServiceConnection)
      SolutionName: ${{ parameters.solutionName }}
      SolutionOutputFile: $(Build.SourcesDirectory)/solutions/unmanaged/${{ parameters.solutionName }}.zip
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

## Dataverse Export Request Patterns

These patterns are used when the **Dataverse Export Request tables** feature is enabled.

### Pattern: Dataverse Table Variables

```yaml
variables:
  - name: TableExportRequest
    value: "cr_exportrequests"
  - name: TableExportRequestSolution
    value: "cr_exportrequestsolutions"
  - name: TableConfigDataDefinition
    value: "cr_configdatadefinitions"
  - name: StatusDraft
    value: "0"
  - name: StatusQueued
    value: "1"
  - name: StatusInProgress
    value: "2"
  - name: StatusCompleted
    value: "3"
  - name: StatusFailed
    value: "4"
```

Replace `cr_` with the user's publisher prefix. Status values are choice (option set) integer values.

### Pattern: Query Export Request (Queue Lookup)

```powershell
$baseUrl = "$envUrl/api/data/v9.2"

if ($overrideId) {
  # Direct lookup by ID (manual run or Run Now cloud flow)
  $requestUrl = "$baseUrl/$(TableExportRequest)($overrideId)"
  $request = Invoke-RestMethod -Uri $requestUrl -Headers $apiHeaders
} else {
  # Queue lookup: oldest Queued request
  $filter = "cr_status eq $(StatusQueued)"
  $requestUrl = "$baseUrl/$(TableExportRequest)?`$filter=$filter&`$orderby=createdon asc&`$top=1"
  $result = Invoke-RestMethod -Uri $requestUrl -Headers $apiHeaders

  if ($result.value.Count -eq 0) {
    Write-Host "No queued export requests found. Exiting gracefully."
    Write-Host "##vso[task.setvariable variable=ExportRequestId]"
    exit 0
  }
  $request = $result.value[0]
}

$requestId = $request.cr_exportrequestid
$requestName = $request.cr_name
$postExportVersion = $request.cr_postexportversion
```

**Key points:**
- `$overrideId` comes from the `exportRequestId` pipeline parameter
- Queue filter: `cr_status eq 1` (Queued), ordered oldest first, top 1
- Graceful exit if no queued request found (not an error)

### Pattern: Update Export Request Status

```powershell
# Set to In Progress with pipeline URL
$pipelineUrl = "$(System.TeamFoundationCollectionUri)$(System.TeamProject)/_build/results?buildId=$(Build.BuildId)"

$updateBody = @{
  cr_status         = [int]$(StatusInProgress)
  cr_pipelinerunurl = $pipelineUrl
} | ConvertTo-Json

Invoke-RestMethod -Uri "$baseUrl/$(TableExportRequest)($requestId)" `
  -Method Patch -Headers $apiHeaders -Body $updateBody
```

### Pattern: Query Export Request Solutions

```powershell
$solFilter = "_cr_exportrequest_value eq '$requestId'"
$solUrl = "$baseUrl/$(TableExportRequestSolution)?`$filter=$solFilter&`$orderby=cr_sortorder asc,createdon asc"
$solResult = Invoke-RestMethod -Uri $solUrl -Headers $apiHeaders
$solutions = @($solResult.value)

if ($solutions.Count -eq 0) {
  $failBody = @{
    cr_status       = [int]$(StatusFailed)
    cr_errordetails = "No solutions found on the export request."
  } | ConvertTo-Json
  Invoke-RestMethod -Uri "$baseUrl/$(TableExportRequest)($requestId)" `
    -Method Patch -Headers $apiHeaders -Body $failBody
  Write-Error "Export request has no solutions."
  exit 1
}
```

**Key points:**
- Lookup relationship filter: `_cr_exportrequest_value eq 'GUID'` (note the underscore prefix and `_value` suffix for lookup columns)
- Ordered by `cr_sortorder asc, createdon asc`
- Fail the Export Request if no solutions found

### Pattern: Query Config Data Definitions

```powershell
$cdFilter = "_cr_exportrequest_value eq '$requestId'"
$cdUrl = "$baseUrl/$(TableConfigDataDefinition)?`$filter=$cdFilter"
$cdResult = Invoke-RestMethod -Uri $cdUrl -Headers $apiHeaders
$configDefs = @($cdResult.value)
```

### Pattern: Build build.json from Dataverse

```powershell
$buildConfig = @{
  exportRequestId = $requestId
}

if ($postExportVersion) {
  $buildConfig["postExportVersion"] = $postExportVersion
}

$buildConfig["solutions"] = @($solutions | ForEach-Object {
  $sol = @{
    name    = $_.cr_solutionname
    version = $_.cr_expectedversion
  }
  if ($_.cr_includedeploymentsettings) {
    $sol["includeDeploymentSettings"] = $true
  }
  $sol
})

if ($configDefs.Count -gt 0) {
  $buildConfig["configData"] = @($configDefs | ForEach-Object {
    $cd = @{
      name       = $_.cr_name
      entity     = $_.cr_entity
      primaryKey = $_.cr_primarykey
      select     = $_.cr_selectcolumns
      dataFile   = $_.cr_datafile
    }
    if ($_.cr_filter) {
      $cd["filter"] = $_.cr_filter
    }
    $cd
  })
}

$buildConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $buildJsonPath -Encoding UTF8
```

**Key points:**
- `exportRequestId` is always included in build.json — the release pipeline reads it for Dataverse status tracking
- Maps Dataverse column names (`cr_solutionname`) to build.json field names (`name`)
- Config data definitions are optional

### Pattern: Update Per-Solution Status After Export

```powershell
foreach ($sol in $solutions) {
  $name = $sol.name
  $solRecordId = $solutionIds.$name   # Stored earlier from cr_exportrequestsolutionid

  $solBody = @{
    cr_status = [int]$(StatusCompleted)
  }

  if ($sol.PSObject.Properties["includesCloudFlows"] -and $sol.includesCloudFlows) {
    $solBody["cr_includescloudflows"] = $true
  }
  if ($sol.PSObject.Properties["isPatch"] -and $sol.isPatch) {
    $solBody["cr_ispatch"] = $true
    if ($sol.parentSolution) {
      $solBody["cr_parentsolution"] = $sol.parentSolution
    }
  }

  Invoke-RestMethod -Uri "$baseUrl/$(TableExportRequestSolution)($solRecordId)" `
    -Method Patch -Headers $apiHeaders -Body ($solBody | ConvertTo-Json)
}
```

### Pattern: Mark Export Request Completed

```powershell
$requestBody = @{
  cr_status      = [int]$(StatusCompleted)
  cr_completedon = (Get-Date -Format "o")
} | ConvertTo-Json

Invoke-RestMethod -Uri "$baseUrl/$(TableExportRequest)($requestId)" `
  -Method Patch -Headers $apiHeaders -Body $requestBody
```

### Pattern: Export Pipeline Failure Handler

This step runs only when the pipeline fails AND an Export Request was being processed.

```powershell
# condition: and(failed(), ne(variables['ExportRequestId'], ''))
$requestId = "$(ExportRequestId)"

$failBody = @{
  cr_status       = [int]$(StatusFailed)
  cr_completedon  = (Get-Date -Format "o")
  cr_errordetails = "Pipeline failed. See pipeline run for details."
} | ConvertTo-Json

Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/$(TableExportRequest)($requestId)" `
  -Method Patch -Headers $apiHeaders -Body $failBody
```

### Pattern: Release Template — Read exportRequestId + Update Deploy Status (Start)

Used by `deploy-environment.yml` at the beginning of each stage.

```powershell
$artifactDir = "$(Pipeline.Workspace)/ExportPipeline/ManagedSolutions"
$buildJsonPath = Join-Path $artifactDir "build.json"

if (-not (Test-Path $buildJsonPath)) {
  Write-Host "No build.json found — skipping Dataverse status update."
  Write-Host "##vso[task.setvariable variable=ExportRequestId]"
  exit 0
}

$buildConfig = Get-Content $buildJsonPath -Raw | ConvertFrom-Json

if (-not $buildConfig.PSObject.Properties["exportRequestId"] -or -not $buildConfig.exportRequestId) {
  Write-Host "No exportRequestId in build.json — Dataverse status tracking disabled."
  Write-Host "##vso[task.setvariable variable=ExportRequestId]"
  exit 0
}

$requestId = $buildConfig.exportRequestId
Write-Host "##vso[task.setvariable variable=ExportRequestId]$requestId"

# Acquire OAuth token for admin environment
$tokenUrl = "https://login.microsoftonline.com/${{ parameters.adminTenantId }}/oauth2/v2.0/token"
$tokenBody = @{
  grant_type    = "client_credentials"
  client_id     = "${{ parameters.adminClientId }}"
  client_secret = $env:AdminClientSecret
  scope         = "$adminUrl/.default"
}

$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody
$apiHeaders = @{ ... }  # Same as standard Dataverse headers

$pipelineUrl = "$(System.TeamFoundationCollectionUri)$(System.TeamProject)/_build/results?buildId=$(Build.BuildId)"
$statusField = "${{ parameters.dataverseStatusField }}"

$updateBody = @{
  $statusField = [int]${{ parameters.statusInProgress }}
  cr_releasepipelineurl = $pipelineUrl
} | ConvertTo-Json

try {
  Invoke-RestMethod -Uri "$adminUrl/api/data/v9.2/${{ parameters.dataverseExportRequestTable }}($requestId)" `
    -Method Patch -Headers $apiHeaders -Body $updateBody
} catch {
  Write-Host "##vso[task.logissue type=warning]Failed to update Dataverse status: $($_.Exception.Message)"
}
```

### Pattern: Release Template — Update Deploy Status (End)

Runs at the end of each stage regardless of success/failure (condition: `and(not(canceled()), ne(variables['ExportRequestId'], ''))`).

```powershell
$requestId = "$(ExportRequestId)"
$statusField = "${{ parameters.dataverseStatusField }}"
$completedField = "${{ parameters.dataverseCompletedField }}"

# Acquire OAuth token (same pattern)
# ...

$succeeded = "$env:AGENT_JOBSTATUS" -eq "Succeeded"
$statusValue = if ($succeeded) { [int]${{ parameters.statusCompleted }} } else { [int]${{ parameters.statusFailed }} }

$updateBody = @{
  $statusField = $statusValue
}

if ($completedField) {
  $updateBody[$completedField] = (Get-Date -Format "o")
}

Invoke-RestMethod -Uri "$adminUrl/api/data/v9.2/${{ parameters.dataverseExportRequestTable }}($requestId)" `
  -Method Patch -Headers $apiHeaders -Body ($updateBody | ConvertTo-Json)
```

**Key points:**
- Uses `$env:AGENT_JOBSTATUS` to determine success/failure
- Dataverse update failures are warnings (don't mask the real error)
- `cr_releasepipelineurl` is set only on the start step (same URL for all stages)
- Each stage updates its own field (e.g., `cr_qadeploystatus`, `cr_stagecompletedon`)

### Pattern: Release Pipeline Admin Environment Variables

```yaml
# In release-solutions.yml
variables:
  - name: AdminEnvironmentUrl
    value: "https://yourorg-dev.crm.dynamics.com"     # Where Export Request tables live
  - name: AdminClientId
    value: "$(AdminClientId)"                          # Set in pipeline variables
  - name: AdminTenantId
    value: "$(AdminTenantId)"                          # Set in pipeline variables
  # AdminClientSecret: configured as secret pipeline variable in ADO UI

# Passed to each stage template:
- template: templates/deploy-environment.yml
  parameters:
    stageName: QA
    displayName: "Deploy to QA"
    environmentName: "Power Platform QA"
    variableGroup: "PowerPlatform-QA"
    adminEnvironmentUrl: $(AdminEnvironmentUrl)
    adminClientId: $(AdminClientId)
    adminTenantId: $(AdminTenantId)
    dataverseStatusField: "cr_qadeploystatus"
    dataverseCompletedField: "cr_qacompletedon"
```

**Key points:**
- Admin credentials are separate from deployment credentials (may be same app registration but different variable source)
- `AdminClientSecret` is a secret pipeline variable, passed via `env:` block to PowerShell
- `dataverseStatusField` and `dataverseCompletedField` are different for each stage
- Field names use the publisher prefix (replace `cr_` with actual prefix)

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
  "--stage-and-upgrade",
  "--skip-lower-version",
  "--activate-plugins"
)

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
  - name: stageName         # Short name: "QA", "Stage", "Prod"
    type: string
  - name: displayName       # Human-readable: "Deploy to QA"
    type: string
  - name: environmentName   # ADO environment: "Power Platform QA"
    type: string
  - name: variableGroup     # Credential group: "PowerPlatform-QA"
    type: string
  - name: dependsOn         # Previous stage: "Dev", "QA", etc.
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
