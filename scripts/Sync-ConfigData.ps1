# =============================================================================
# Script: Sync-ConfigData.ps1
# =============================================================================
# Reusable script for extracting and upserting configuration data defined in
# build.json's configData array. Used by both export and deploy pipelines.
#
# Modes:
#   -Mode Extract : Queries OData from a source environment and writes JSON
#                   data files to the repository (used during export).
#   -Mode Upsert  : Reads JSON data files and PATCHes each record into the
#                   target environment using stable GUIDs (used during deploy).
#
# Parameters:
#   -Mode           : "Extract" or "Upsert"
#   -ConfigData     : Array of configData objects from build.json
#   -EnvironmentUrl : Dataverse environment URL (e.g., https://org.crm.dynamics.com)
#   -ApiHeaders     : Hashtable with Authorization and OData headers
#   -SourceDir      : Base directory used to resolve dataFile paths
#                     (export folder during extract; artifact directory during upsert)
# =============================================================================

param(
    [Parameter(Mandatory)]
    [ValidateSet("Extract", "Upsert")]
    [string]$Mode,

    [Parameter(Mandatory)]
    [array]$ConfigData,

    [Parameter(Mandatory)]
    [string]$EnvironmentUrl,

    [Parameter(Mandatory)]
    [hashtable]$ApiHeaders,

    [Parameter(Mandatory)]
    [string]$SourceDir
)

$ErrorActionPreference = "Stop"
$envUrl = $EnvironmentUrl.TrimEnd("/")

$successCount = 0
$failedCount = 0
$failedDataSets = @()

Write-Host ""
Write-Host "============================================"
Write-Host "  Config Data $Mode"
Write-Host "============================================"
Write-Host "Data sets: $($ConfigData.Count)"
Write-Host "Environment: $envUrl"
Write-Host ""

foreach ($dataset in $ConfigData) {
    $name       = $dataset.name
    $entity     = $dataset.entity
    $primaryKey = $dataset.primaryKey
    $select     = $dataset.select
    $filter     = if ($dataset.PSObject.Properties["filter"] -and $dataset.filter) { $dataset.filter } else { $null }
    $dataFile   = $dataset.dataFile

    $dataFilePath = Join-Path $SourceDir $dataFile

    Write-Host "--------------------------------------------"
    Write-Host "  $name ($entity)"
    Write-Host "--------------------------------------------"

    if ($Mode -eq "Extract") {
        # ---------------------------------------------------------------
        # EXTRACT: Query OData and write to data file
        # ---------------------------------------------------------------
        $selectColumns = "$primaryKey,$select"
        $queryUrl = "$envUrl/api/data/v9.2/$entity`?`$select=$selectColumns"

        if ($filter) {
            $queryUrl += "&`$filter=$filter"
        }

        Write-Host "  Query: $queryUrl"

        try {
            $allRecords = @()
            $nextLink = $queryUrl

            # Handle OData pagination
            while ($nextLink) {
                $response = Invoke-RestMethod -Uri $nextLink -Headers $ApiHeaders
                $allRecords += @($response.value)

                if ($response.PSObject.Properties["@odata.nextLink"]) {
                    $nextLink = $response."@odata.nextLink"
                    Write-Host "  Fetching next page ($($allRecords.Count) records so far)..."
                } else {
                    $nextLink = $null
                }
            }

            Write-Host "  Records retrieved: $($allRecords.Count)"

            # Clean OData metadata from each record (remove @odata.* properties)
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

            # Ensure directory exists
            $dataFileDir = Split-Path $dataFilePath -Parent
            if (-not (Test-Path $dataFileDir)) {
                New-Item -ItemType Directory -Path $dataFileDir -Force | Out-Null
            }

            # Write as formatted JSON array
            $cleanRecords | ConvertTo-Json -Depth 10 | Set-Content -Path $dataFilePath -Encoding UTF8
            Write-Host "  Written to: $dataFilePath"
            $successCount++

        } catch {
            Write-Host "##vso[task.logissue type=error]Failed to extract config data '$name': $($_.Exception.Message)"
            $failedCount++
            $failedDataSets += $name
        }

    } elseif ($Mode -eq "Upsert") {
        # ---------------------------------------------------------------
        # UPSERT: Read data file and PATCH each record by GUID
        # ---------------------------------------------------------------
        if (-not (Test-Path $dataFilePath)) {
            Write-Host "##vso[task.logissue type=warning]Data file not found: $dataFilePath — skipping '$name'"
            continue
        }

        $records = @(Get-Content $dataFilePath -Raw | ConvertFrom-Json)
        Write-Host "  Records to upsert: $($records.Count)"

        $upsertedCount = 0
        $recordFailCount = 0

        foreach ($record in $records) {
            # Extract the primary key GUID
            $guid = $record.$primaryKey

            if (-not $guid) {
                Write-Host "##vso[task.logissue type=warning]Record missing primary key '$primaryKey' — skipping"
                $recordFailCount++
                continue
            }

            # Build the PATCH body (all columns except the primary key)
            $body = @{}
            foreach ($prop in $record.PSObject.Properties) {
                if ($prop.Name -ne $primaryKey) {
                    $body[$prop.Name] = $prop.Value
                }
            }

            $patchUrl = "$envUrl/api/data/v9.2/$entity($guid)"
            $patchBody = $body | ConvertTo-Json -Depth 5 -Compress

            try {
                # PATCH without If-Match performs a true upsert (create or update by GUID).
                # Some Dataverse environments return 404 for PATCH when the record doesn't
                # exist yet; in that case fall back to POST with the primary key in the body.
                try {
                    Invoke-RestMethod -Uri $patchUrl -Method Patch -Headers $ApiHeaders -Body $patchBody | Out-Null
                    $upsertedCount++
                } catch {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    if ($statusCode -eq 404) {
                        # Record does not exist — create it via POST with explicit GUID
                        $createBody = $body.Clone()
                        $createBody[$primaryKey] = $guid
                        $createBodyJson = $createBody | ConvertTo-Json -Depth 5 -Compress
                        $postUrl = "$envUrl/api/data/v9.2/$entity"
                        Invoke-RestMethod -Uri $postUrl -Method Post -Headers $ApiHeaders -Body $createBodyJson | Out-Null
                        $upsertedCount++
                    } else {
                        throw
                    }
                }
            } catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                Write-Host "##vso[task.logissue type=warning]Failed to upsert record $guid in '$name' (HTTP $statusCode): $($_.Exception.Message)"
                $recordFailCount++
            }
        }

        Write-Host "  Upserted: $upsertedCount / $($records.Count)"

        if ($recordFailCount -gt 0) {
            Write-Host "  Failed:   $recordFailCount"
            Write-Host "##vso[task.logissue type=warning]$recordFailCount record(s) failed to upsert for '$name'"
            $failedCount++
            $failedDataSets += $name
        } else {
            $successCount++
        }
    }
}

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
Write-Host ""
Write-Host "============================================"
Write-Host "  Config Data $Mode Summary"
Write-Host "============================================"
Write-Host "Total data sets: $($ConfigData.Count)"
Write-Host "Succeeded:       $successCount"
Write-Host "Failed:          $failedCount"

if ($failedDataSets.Count -gt 0) {
    Write-Host "Failed data sets: $($failedDataSets -join ', ')"
    if ($Mode -eq "Extract") {
        Write-Error "One or more config data extractions failed"
        exit 1
    } else {
        # Upsert failures are warnings — don't fail the deployment
        Write-Host "##vso[task.logissue type=warning]Config data upsert had failures. Review warnings above."
    }
}

Write-Host ""
Write-Host "Config data $($Mode.ToLower()) complete."
