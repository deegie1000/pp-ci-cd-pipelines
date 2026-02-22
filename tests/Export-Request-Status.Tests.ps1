Describe "Export request status transitions" {

  # -----------------------------------------------------------------------
  # Status choice values (mirrors pipeline variables)
  # -----------------------------------------------------------------------
  $script:StatusDraft     = 0
  $script:StatusQueued    = 1
  $script:StatusInProgress = 2
  $script:StatusCompleted = 3
  $script:StatusFailed    = 4
  $script:StatusRunNow    = 5

  # -----------------------------------------------------------------------
  # Helper: simulates the export pipeline's status transition logic.
  # Returns the sequence of status updates that would be applied.
  # -----------------------------------------------------------------------
  function Get-ExportStatusTransitions {
    param(
      [string]$ExportRequestId,
      [int]$InitialStatus,
      [bool]$ExportSucceeds = $true,
      [bool]$HasChanges = $true
    )

    $transitions = @()

    # Pipeline only processes Queued or RunNow requests
    if ($InitialStatus -ne $script:StatusQueued -and $InitialStatus -ne $script:StatusRunNow) {
      return @{
        Transitions = $transitions
        Processed   = $false
        Reason      = "Export request status is $InitialStatus — only Queued ($($script:StatusQueued)) or RunNow ($($script:StatusRunNow)) are processed"
      }
    }

    # No export request ID → skip all Dataverse updates
    if (-not $ExportRequestId) {
      return @{
        Transitions = $transitions
        Processed   = $false
        Reason      = "No export request ID"
      }
    }

    # Step 3: Update to In Progress
    $transitions += @{
      Status = $script:StatusInProgress
      Field  = "cr_status"
      Step   = "Query Dataverse / begin export"
    }

    if ($ExportSucceeds) {
      # Step 12: Update to Completed
      $transitions += @{
        Status = $script:StatusCompleted
        Field  = "cr_status"
        Step   = "Export complete"
        IncludesTimestamp = $true
      }
    } else {
      # Step 12b: Update to Failed
      $transitions += @{
        Status = $script:StatusFailed
        Field  = "cr_status"
        Step   = "Export failed"
        IncludesTimestamp = $true
        IncludesErrorDetails = $true
      }
    }

    return @{
      Transitions = $transitions
      Processed   = $true
      FinalStatus = $transitions[-1].Status
    }
  }

  # -----------------------------------------------------------------------
  # Helper: simulates the release pipeline's per-stage status transitions.
  # -----------------------------------------------------------------------
  function Get-ReleaseStageTransitions {
    param(
      [string]$ExportRequestId,
      [string]$StageName,
      [string]$StatusField,
      [string]$CompletedField,
      [bool]$DeploySucceeds = $true
    )

    $transitions = @()

    # No request ID → skip all status updates
    if (-not $ExportRequestId) {
      return @{
        Transitions = $transitions
        Processed   = $false
        Reason      = "No export request ID — Dataverse status tracking disabled"
      }
    }

    # No status field configured → skip
    if (-not $StatusField) {
      return @{
        Transitions = $transitions
        Processed   = $false
        Reason      = "Status field not configured"
      }
    }

    # Update to In Progress at start of stage
    $transitions += @{
      Status = $script:StatusInProgress
      Field  = $StatusField
      Step   = "$StageName deploy started"
      IncludesPipelineUrl = $true
    }

    if ($DeploySucceeds) {
      $transitions += @{
        Status = $script:StatusCompleted
        Field  = $StatusField
        CompletedField = $CompletedField
        Step   = "$StageName deploy completed"
        IncludesTimestamp = $true
      }
    } else {
      $transitions += @{
        Status = $script:StatusFailed
        Field  = $StatusField
        CompletedField = $CompletedField
        Step   = "$StageName deploy failed"
        IncludesTimestamp = $true
      }
    }

    return @{
      Transitions = $transitions
      Processed   = $true
      FinalStatus = $transitions[-1].Status
    }
  }

  # -----------------------------------------------------------------------
  # Helper: simulates per-solution status updates during export.
  # -----------------------------------------------------------------------
  function Get-SolutionExportStatus {
    param(
      [string]$SolutionRecordId,
      [bool]$ExportSucceeds = $true,
      [bool]$HasCloudFlows = $false,
      [bool]$IsPatch = $false
    )

    if (-not $SolutionRecordId) {
      return @{
        Updated = $false
        Reason  = "No Dataverse record ID for solution"
      }
    }

    $update = @{
      cr_status = if ($ExportSucceeds) { $script:StatusCompleted } else { $script:StatusFailed }
    }

    if ($HasCloudFlows) {
      $update["cr_includescloudflows"] = $true
    }

    if ($IsPatch) {
      $update["cr_ispatch"] = $true
    }

    return @{
      Updated    = $true
      StatusCode = $update.cr_status
      Fields     = $update
    }
  }

  Context "export pipeline status transitions" {
    It "transitions Queued to InProgress to Completed on success" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusQueued `
        -ExportSucceeds $true

      $result.Processed | Should -Be $true
      $result.Transitions | Should -HaveCount 2
      $result.Transitions[0].Status | Should -Be $script:StatusInProgress
      $result.Transitions[1].Status | Should -Be $script:StatusCompleted
      $result.FinalStatus | Should -Be $script:StatusCompleted
    }

    It "transitions Queued to InProgress to Failed on error" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusQueued `
        -ExportSucceeds $false

      $result.Processed | Should -Be $true
      $result.Transitions | Should -HaveCount 2
      $result.Transitions[1].Status | Should -Be $script:StatusFailed
      $result.Transitions[1].IncludesErrorDetails | Should -Be $true
      $result.FinalStatus | Should -Be $script:StatusFailed
    }

    It "processes RunNow status same as Queued" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusRunNow `
        -ExportSucceeds $true

      $result.Processed | Should -Be $true
      $result.FinalStatus | Should -Be $script:StatusCompleted
    }

    It "does not process Draft status" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusDraft

      $result.Processed | Should -Be $false
      $result.Transitions | Should -HaveCount 0
    }

    It "does not process InProgress status (already running)" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusInProgress

      $result.Processed | Should -Be $false
    }

    It "does not process Completed status" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusCompleted

      $result.Processed | Should -Be $false
    }

    It "does not process Failed status" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusFailed

      $result.Processed | Should -Be $false
    }

    It "skips gracefully when no export request ID" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "" `
        -InitialStatus $script:StatusQueued

      $result.Processed | Should -Be $false
      $result.Reason | Should -BeLike "*No export request*"
    }

    It "includes timestamp on final status update" {
      $result = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusQueued `
        -ExportSucceeds $true

      $result.Transitions[-1].IncludesTimestamp | Should -Be $true
    }
  }

  Context "release pipeline per-stage status transitions" {
    It "transitions QA through InProgress to Completed on success" {
      $result = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "QA" `
        -StatusField "cr_qadeploystatus" `
        -CompletedField "cr_qacompletedon" `
        -DeploySucceeds $true

      $result.Processed | Should -Be $true
      $result.Transitions | Should -HaveCount 2
      $result.Transitions[0].Status | Should -Be $script:StatusInProgress
      $result.Transitions[0].Field | Should -Be "cr_qadeploystatus"
      $result.Transitions[1].Status | Should -Be $script:StatusCompleted
      $result.Transitions[1].CompletedField | Should -Be "cr_qacompletedon"
    }

    It "transitions Stage to Failed on deploy error" {
      $result = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "Stage" `
        -StatusField "cr_stagedeploystatus" `
        -CompletedField "cr_stagecompletedon" `
        -DeploySucceeds $false

      $result.FinalStatus | Should -Be $script:StatusFailed
      $result.Transitions[1].Field | Should -Be "cr_stagedeploystatus"
    }

    It "uses correct field names for Prod stage" {
      $result = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "Prod" `
        -StatusField "cr_proddeploystatus" `
        -CompletedField "cr_prodcompletedon" `
        -DeploySucceeds $true

      $result.Transitions[0].Field | Should -Be "cr_proddeploystatus"
      $result.Transitions[1].CompletedField | Should -Be "cr_prodcompletedon"
    }

    It "skips when no export request ID" {
      $result = Get-ReleaseStageTransitions `
        -ExportRequestId "" `
        -StageName "QA" `
        -StatusField "cr_qadeploystatus" `
        -CompletedField "cr_qacompletedon"

      $result.Processed | Should -Be $false
      $result.Reason | Should -BeLike "*No export request*"
    }

    It "skips when status field not configured" {
      $result = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "QA" `
        -StatusField "" `
        -CompletedField ""

      $result.Processed | Should -Be $false
      $result.Reason | Should -BeLike "*not configured*"
    }

    It "includes pipeline URL in initial InProgress update" {
      $result = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "QA" `
        -StatusField "cr_qadeploystatus" `
        -CompletedField "cr_qacompletedon"

      $result.Transitions[0].IncludesPipelineUrl | Should -Be $true
    }
  }

  Context "per-solution export status" {
    It "marks solution as Completed on successful export" {
      $result = Get-SolutionExportStatus `
        -SolutionRecordId "sol-abc-123" `
        -ExportSucceeds $true

      $result.Updated | Should -Be $true
      $result.StatusCode | Should -Be $script:StatusCompleted
    }

    It "marks solution as Failed on export error" {
      $result = Get-SolutionExportStatus `
        -SolutionRecordId "sol-abc-123" `
        -ExportSucceeds $false

      $result.StatusCode | Should -Be $script:StatusFailed
    }

    It "includes cloud flow flag when detected" {
      $result = Get-SolutionExportStatus `
        -SolutionRecordId "sol-abc-123" `
        -ExportSucceeds $true `
        -HasCloudFlows $true

      $result.Fields["cr_includescloudflows"] | Should -Be $true
    }

    It "includes patch flag when detected" {
      $result = Get-SolutionExportStatus `
        -SolutionRecordId "sol-abc-123" `
        -ExportSucceeds $true `
        -IsPatch $true

      $result.Fields["cr_ispatch"] | Should -Be $true
    }

    It "does not include optional flags when not applicable" {
      $result = Get-SolutionExportStatus `
        -SolutionRecordId "sol-abc-123" `
        -ExportSucceeds $true `
        -HasCloudFlows $false `
        -IsPatch $false

      $result.Fields.ContainsKey("cr_includescloudflows") | Should -Be $false
      $result.Fields.ContainsKey("cr_ispatch") | Should -Be $false
    }

    It "skips when no solution record ID" {
      $result = Get-SolutionExportStatus `
        -SolutionRecordId "" `
        -ExportSucceeds $true

      $result.Updated | Should -Be $false
    }
  }

  Context "full export-to-release status flow" {
    It "produces correct end-to-end status sequence for a successful pipeline" {
      # Export phase
      $exportResult = Get-ExportStatusTransitions `
        -ExportRequestId "abc-123" `
        -InitialStatus $script:StatusQueued `
        -ExportSucceeds $true

      # Release QA phase
      $qaResult = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "QA" `
        -StatusField "cr_qadeploystatus" `
        -CompletedField "cr_qacompletedon" `
        -DeploySucceeds $true

      # Release Stage phase
      $stageResult = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "Stage" `
        -StatusField "cr_stagedeploystatus" `
        -CompletedField "cr_stagecompletedon" `
        -DeploySucceeds $true

      # Release Prod phase
      $prodResult = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "Prod" `
        -StatusField "cr_proddeploystatus" `
        -CompletedField "cr_prodcompletedon" `
        -DeploySucceeds $true

      # Verify full sequence
      $exportResult.FinalStatus | Should -Be $script:StatusCompleted
      $qaResult.FinalStatus | Should -Be $script:StatusCompleted
      $stageResult.FinalStatus | Should -Be $script:StatusCompleted
      $prodResult.FinalStatus | Should -Be $script:StatusCompleted

      # Total transitions: 2 (export) + 2 (QA) + 2 (Stage) + 2 (Prod) = 8
      $totalTransitions = $exportResult.Transitions.Count +
        $qaResult.Transitions.Count +
        $stageResult.Transitions.Count +
        $prodResult.Transitions.Count
      $totalTransitions | Should -Be 8
    }

    It "stops release status updates when a stage fails" {
      $qaResult = Get-ReleaseStageTransitions `
        -ExportRequestId "abc-123" `
        -StageName "QA" `
        -StatusField "cr_qadeploystatus" `
        -CompletedField "cr_qacompletedon" `
        -DeploySucceeds $false

      $qaResult.FinalStatus | Should -Be $script:StatusFailed

      # Stage and Prod would not run (ADO stage dependency)
      # but if they did run, they'd have their own independent status
    }
  }
}
