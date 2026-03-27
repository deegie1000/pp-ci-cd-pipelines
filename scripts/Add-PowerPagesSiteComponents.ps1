# =============================================================================
# Script: Add-PowerPagesSiteComponents.ps1
# =============================================================================
# Adds all existing Power Pages site components from the dev environment that
# are connected to specified site(s) into a target solution.
#
# Only powerpagesite and powerpagecomponent records are added — tables, flows,
# and other component types are excluded. AddRequiredComponents is set to false
# to prevent dependency cascades. Any table components inadvertently added are
# removed as a safeguard.
#
# Parameters:
#   -SolutionUniqueName : Unique name of the target solution
#   -SiteNames          : Array of Power Pages site names to process
#   -EnvironmentUrl     : Dataverse environment URL (e.g., https://org.crm.dynamics.com)
#   -ApiHeaders         : Hashtable with Authorization and OData headers
# =============================================================================

param(
    [Parameter(Mandatory)]
    [string]$SolutionUniqueName,

    [Parameter(Mandatory)]
    [string[]]$SiteNames,

    [Parameter(Mandatory)]
    [string]$EnvironmentUrl,

    [Parameter(Mandatory)]
    [hashtable]$ApiHeaders
)

$ErrorActionPreference = "Stop"
$envUrl = $EnvironmentUrl.TrimEnd("/")

# Helper: executes a paginated OData GET and returns all records across pages
function Invoke-ODataPagedQuery {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )
    $results = @()
    $next = $Uri
    while ($next) {
        $response = Invoke-RestMethod -Uri $next -Headers $Headers
        $results += @($response.value)
        $next = if ($response.PSObject.Properties["@odata.nextLink"]) { $response."@odata.nextLink" } else { $null }
    }
    return $results
}

Write-Host ""
Write-Host "============================================"
Write-Host "  Add Power Pages Site Components"
Write-Host "============================================"
Write-Host "Solution:    $SolutionUniqueName"
Write-Host "Sites:       $($SiteNames -join ', ')"
Write-Host "Environment: $envUrl"
Write-Host ""

# ---------------------------------------------------------------
# 1. Resolve component type integers for powerpagesite and
#    powerpagecomponent via solutioncomponentdefinitions
# ---------------------------------------------------------------
Write-Host "--------------------------------------------"
Write-Host "  Resolving component type codes"
Write-Host "--------------------------------------------"

$typeUrl = "$envUrl/api/data/v9.2/solutioncomponentdefinitions" +
           "?`$select=name,solutioncomponenttype" +
           "&`$filter=name eq 'powerpagesite' or name eq 'powerpagecomponent'"

$typeDefs = Invoke-ODataPagedQuery -Uri $typeUrl -Headers $ApiHeaders

$siteTypeDef = $typeDefs | Where-Object { $_.name -eq "powerpagesite" }  | Select-Object -First 1
$compTypeDef = $typeDefs | Where-Object { $_.name -eq "powerpagecomponent" } | Select-Object -First 1

if (-not $siteTypeDef) {
    Write-Host "##vso[task.logissue type=error]Could not resolve component type for 'powerpagesite'."
    Write-Error "Could not resolve component type for 'powerpagesite'."
    exit 1
}
if (-not $compTypeDef) {
    Write-Host "##vso[task.logissue type=error]Could not resolve component type for 'powerpagecomponent'."
    Write-Error "Could not resolve component type for 'powerpagecomponent'."
    exit 1
}

$siteComponentType = [int]$siteTypeDef.solutioncomponenttype
$ppComponentType   = [int]$compTypeDef.solutioncomponenttype

Write-Host "  powerpagesite type:      $siteComponentType"
Write-Host "  powerpagecomponent type: $ppComponentType"

# ---------------------------------------------------------------
# 2. Resolve target solution ID
# ---------------------------------------------------------------
Write-Host ""
Write-Host "--------------------------------------------"
Write-Host "  Resolving target solution"
Write-Host "--------------------------------------------"

$escapedUniqueName = $SolutionUniqueName.Replace("'", "''")
$solUrl = "$envUrl/api/data/v9.2/solutions" +
          "?`$select=solutionid,uniquename,friendlyname" +
          "&`$filter=uniquename eq '$escapedUniqueName'"

$solResults = Invoke-ODataPagedQuery -Uri $solUrl -Headers $ApiHeaders
$targetSolution = $solResults | Select-Object -First 1

if (-not $targetSolution) {
    Write-Host "##vso[task.logissue type=error]Target solution '$SolutionUniqueName' not found in environment."
    Write-Error "Target solution '$SolutionUniqueName' not found in environment."
    exit 1
}

$targetSolutionId = $targetSolution.solutionid
Write-Host "  Found: $($targetSolution.friendlyname) [$SolutionUniqueName] ($targetSolutionId)"

# ---------------------------------------------------------------
# 3. Snapshot existing table components (Entity type 1) before
#    any changes — used to identify inadvertently added tables
# ---------------------------------------------------------------
$tableComponentType = 1
$tableSnapshotUrl = "$envUrl/api/data/v9.2/solutioncomponents" +
                    "?`$select=objectid" +
                    "&`$filter=_solutionid_value eq $targetSolutionId and componenttype eq $tableComponentType"

$existingTableIds = @(Invoke-ODataPagedQuery -Uri $tableSnapshotUrl -Headers $ApiHeaders |
                      ForEach-Object { $_.objectid })
$existingTableSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$existingTableIds,
    [System.StringComparer]::OrdinalIgnoreCase
)
Write-Host ""
Write-Host "  Pre-existing table components in solution: $($existingTableSet.Count)"

# ---------------------------------------------------------------
# 4. Process each site
# ---------------------------------------------------------------
$totalAdded   = 0
$totalSkipped = 0
$totalFailed  = 0

foreach ($siteName in $SiteNames) {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "  Processing site: $siteName"
    Write-Host "============================================"

    # -- Find site by name --
    $escapedSiteName = $siteName.Replace("'", "''")
    $siteUrl = "$envUrl/api/data/v9.2/powerpagesites" +
               "?`$select=powerpagesiteid,name" +
               "&`$filter=name eq '$escapedSiteName'"

    $siteResults = Invoke-ODataPagedQuery -Uri $siteUrl -Headers $ApiHeaders
    $site = $siteResults | Select-Object -First 1

    if (-not $site) {
        Write-Host "##vso[task.logissue type=error]Power Pages site '$siteName' not found in environment."
        Write-Error "Power Pages site '$siteName' not found in environment."
        exit 1
    }

    $siteId = $site.powerpagesiteid
    Write-Host "  Site ID: $siteId"

    # -- Add the site record itself to the solution (idempotent pre-check) --
    $siteMemberUrl = "$envUrl/api/data/v9.2/solutioncomponents" +
                     "?`$select=objectid" +
                     "&`$filter=_solutionid_value eq $targetSolutionId and componenttype eq $siteComponentType and objectid eq $siteId"
    $siteMembership = Invoke-ODataPagedQuery -Uri $siteMemberUrl -Headers $ApiHeaders

    if ($siteMembership.Count -gt 0) {
        Write-Host "  Site already in solution - skipping."
        $totalSkipped++
    } else {
        $addSiteBody = @{
            ComponentId           = $siteId
            ComponentType         = $siteComponentType
            SolutionUniqueName    = $SolutionUniqueName
            AddRequiredComponents = $false
        } | ConvertTo-Json -Compress

        try {
            Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/AddSolutionComponent" -Method Post -Headers $ApiHeaders -Body $addSiteBody | Out-Null
            Write-Host "  Added site to solution: $siteName ($siteId)"
            $totalAdded++
        } catch {
            Write-Host "##vso[task.logissue type=error]Failed to add site '$siteName' ($siteId) to solution: $($_.Exception.Message)"
            Write-Error "Failed to add site '$siteName' to solution."
            exit 1
        }
    }

    # -- Get all powerpagecomponent records for the site --
    $compUrl = "$envUrl/api/data/v9.2/powerpagecomponents" +
               "?`$select=powerpagecomponentid,name" +
               "&`$filter=_powerpagesiteid_value eq $siteId"
    $allComponents = @(Invoke-ODataPagedQuery -Uri $compUrl -Headers $ApiHeaders)
    Write-Host "  Site components in environment: $($allComponents.Count)"

    if ($allComponents.Count -eq 0) {
        Write-Host "  No site components to add for '$siteName'."
        continue
    }

    # -- Get existing solution membership for powerpagecomponent type --
    $memberUrl = "$envUrl/api/data/v9.2/solutioncomponents" +
                 "?`$select=objectid" +
                 "&`$filter=_solutionid_value eq $targetSolutionId and componenttype eq $ppComponentType"
    $existingMembers = @(Invoke-ODataPagedQuery -Uri $memberUrl -Headers $ApiHeaders |
                         ForEach-Object { $_.objectid })
    $existingMemberSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$existingMembers,
        [System.StringComparer]::OrdinalIgnoreCase
    )
    Write-Host "  Components already in solution: $($existingMemberSet.Count)"

    # -- Diff: only add components not already present --
    $toAdd = @($allComponents | Where-Object { -not $existingMemberSet.Contains($_.powerpagecomponentid) })
    Write-Host "  Components to add: $($toAdd.Count)"

    $siteAdded  = 0
    $siteFailed = 0

    foreach ($comp in $toAdd) {
        $compId   = $comp.powerpagecomponentid
        $compName = if ($comp.name) { $comp.name } else { "(unnamed)" }

        $addBody = @{
            ComponentId           = $compId
            ComponentType         = $ppComponentType
            SolutionUniqueName    = $SolutionUniqueName
            AddRequiredComponents = $false
        } | ConvertTo-Json -Compress

        try {
            Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/AddSolutionComponent" -Method Post -Headers $ApiHeaders -Body $addBody | Out-Null
            Write-Host "  Added: $compName ($compId)"
            $siteAdded++
            $totalAdded++
        } catch {
            Write-Host "##vso[task.logissue type=error]Failed to add component '$compName' ($compId): $($_.Exception.Message)"
            $siteFailed++
            $totalFailed++
        }
    }

    Write-Host ""
    Write-Host "  Site summary [$siteName]: Added=$siteAdded, Skipped=0, Failed=$siteFailed"

    if ($siteFailed -gt 0) {
        Write-Error "One or more site components failed to add for site '$siteName'."
        exit 1
    }
}

# ---------------------------------------------------------------
# 5. Cleanup: remove any table components added inadvertently
#    (i.e., present now but not in the pre-run snapshot)
# ---------------------------------------------------------------
Write-Host ""
Write-Host "--------------------------------------------"
Write-Host "  Cleanup: checking for inadvertently added table components"
Write-Host "--------------------------------------------"

$currentTableUrl = "$envUrl/api/data/v9.2/solutioncomponents" +
                   "?`$select=objectid" +
                   "&`$filter=_solutionid_value eq $targetSolutionId and componenttype eq $tableComponentType"
$currentTableIds = @(Invoke-ODataPagedQuery -Uri $currentTableUrl -Headers $ApiHeaders |
                     ForEach-Object { $_.objectid })
$newTableIds = @($currentTableIds | Where-Object { -not $existingTableSet.Contains($_) })

if ($newTableIds.Count -eq 0) {
    Write-Host "  No new table components found - no cleanup needed."
} else {
    Write-Host "  Removing $($newTableIds.Count) inadvertently added table component(s)..."
    foreach ($tableId in $newTableIds) {
        $removeBody = @{
            ComponentId        = $tableId
            ComponentType      = $tableComponentType
            SolutionUniqueName = $SolutionUniqueName
        } | ConvertTo-Json -Compress

        try {
            Invoke-RestMethod -Uri "$envUrl/api/data/v9.2/RemoveSolutionComponent" -Method Post -Headers $ApiHeaders -Body $removeBody | Out-Null
            Write-Host "  Removed table component: $tableId"
        } catch {
            $errDetail = $null
            try { $errDetail = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
            $errMsg = if ($errDetail) { $errDetail } else { $_.Exception.Message }
            Write-Host "  WARNING: Could not remove table component $tableId from solution: $errMsg"
        }
    }
}

# ---------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------
Write-Host ""
Write-Host "============================================"
Write-Host "  Add Power Pages Site Components Summary"
Write-Host "============================================"
Write-Host "Sites processed:    $($SiteNames.Count)"
Write-Host "Components added:   $totalAdded"
Write-Host "Components skipped: $totalSkipped"
Write-Host "Components failed:  $totalFailed"
Write-Host ""
Write-Host "Power Pages site component population complete."
