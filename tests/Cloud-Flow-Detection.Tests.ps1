Describe "Cloud flow detection" {

  # -----------------------------------------------------------------------
  # Helper: mirrors the detection logic used by the export pipeline.
  # Given an unpacked solution root folder, returns $true if cloud flows
  # (.json files in Workflows/) are found.
  # -----------------------------------------------------------------------
  function Test-HasCloudFlows {
    param([string]$UnpackedDir)
    $workflowsDir = Join-Path $UnpackedDir "Workflows"
    if (-not (Test-Path $workflowsDir)) { return $false }
    $jsonFiles = Get-ChildItem -Path $workflowsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    return ($null -ne $jsonFiles -and $jsonFiles.Count -gt 0)
  }

  # -----------------------------------------------------------------------
  # Helper: creates a temp unpacked solution structure and returns the path.
  # -----------------------------------------------------------------------
  function New-UnpackedSolution {
    param(
      [string]$Name,
      [switch]$WithWorkflowsDir,
      [string[]]$CloudFlowFiles,
      [string[]]$ClassicWorkflowFiles
    )
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "solution_$([guid]::NewGuid().ToString('N'))"
    $solutionDir = Join-Path $dir $Name
    New-Item -ItemType Directory -Path $solutionDir -Force | Out-Null

    if ($WithWorkflowsDir -or $CloudFlowFiles -or $ClassicWorkflowFiles) {
      $wfDir = Join-Path $solutionDir "Workflows"
      New-Item -ItemType Directory -Path $wfDir -Force | Out-Null

      foreach ($f in $CloudFlowFiles) {
        # Cloud flows are .json files with Logic Apps schema content
        $content = @{
          definition = @{
            triggers = @{}
            actions = @{}
          }
        } | ConvertTo-Json -Depth 5
        Set-Content -Path (Join-Path $wfDir $f) -Value $content -Encoding UTF8
      }

      foreach ($f in $ClassicWorkflowFiles) {
        # Classic workflows are .xaml files
        Set-Content -Path (Join-Path $wfDir $f) -Value "<Activity />" -Encoding UTF8
      }
    }

    return $solutionDir
  }

  AfterEach {
    if ($script:solutionDir) {
      $parent = Split-Path (Split-Path $script:solutionDir)
      Remove-Item -Path $parent -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Context "when solution has no Workflows directory" {
    It "returns false" {
      $script:solutionDir = New-UnpackedSolution -Name "NoWorkflows"
      Test-HasCloudFlows -UnpackedDir $script:solutionDir | Should -Be $false
    }
  }

  Context "when Workflows directory is empty" {
    It "returns false" {
      $script:solutionDir = New-UnpackedSolution -Name "EmptyWorkflows" -WithWorkflowsDir
      Test-HasCloudFlows -UnpackedDir $script:solutionDir | Should -Be $false
    }
  }

  Context "when Workflows has only classic workflow (.xaml) files" {
    It "returns false" {
      $script:solutionDir = New-UnpackedSolution -Name "ClassicOnly" `
        -ClassicWorkflowFiles @("MyWorkflow.xaml", "AnotherWorkflow.xaml")
      Test-HasCloudFlows -UnpackedDir $script:solutionDir | Should -Be $false
    }
  }

  Context "when Workflows has cloud flow (.json) files" {
    It "returns true for a single cloud flow" {
      $script:solutionDir = New-UnpackedSolution -Name "OneFlow" `
        -CloudFlowFiles @("Send-Approval-Flow.json")
      Test-HasCloudFlows -UnpackedDir $script:solutionDir | Should -Be $true
    }

    It "returns true for multiple cloud flows" {
      $script:solutionDir = New-UnpackedSolution -Name "MultiFlow" `
        -CloudFlowFiles @("Flow1.json", "Flow2.json", "Flow3.json")
      Test-HasCloudFlows -UnpackedDir $script:solutionDir | Should -Be $true
    }
  }

  Context "when Workflows has a mix of cloud flows and classic workflows" {
    It "returns true (cloud flows are present)" {
      $script:solutionDir = New-UnpackedSolution -Name "MixedFlows" `
        -CloudFlowFiles @("CloudFlow.json") `
        -ClassicWorkflowFiles @("ClassicWorkflow.xaml")
      Test-HasCloudFlows -UnpackedDir $script:solutionDir | Should -Be $true
    }
  }
}

Describe "build.json cloud flow flag round-trip" {

  BeforeEach {
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "buildrt_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
  }

  AfterEach {
    Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "when includesCloudFlows is added and build.json is re-serialized" {
    It "preserves the flag alongside existing properties" {
      $original = @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" },
          @{ name = "Sol2"; version = "2.0.0.0"; includeDeploymentSettings = $true }
        )
      }

      $path = Join-Path $script:tempDir "build.json"
      $original | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

      # Simulate pipeline: read, add flag, write back
      $config = Get-Content $path -Raw | ConvertFrom-Json
      $solutions = @($config.solutions)
      $solutions[0] | Add-Member -NotePropertyName "includesCloudFlows" -NotePropertyValue $true -Force

      $updated = @{ solutions = @($solutions) } | ConvertTo-Json -Depth 10
      Set-Content -Path $path -Value $updated -Encoding UTF8

      # Read back and verify
      $result = Get-Content $path -Raw | ConvertFrom-Json
      $result.solutions[0].name | Should -Be "Sol1"
      $result.solutions[0].version | Should -Be "1.0.0.0"
      $result.solutions[0].includesCloudFlows | Should -Be $true
      $result.solutions[1].name | Should -Be "Sol2"
      $result.solutions[1].version | Should -Be "2.0.0.0"
      $result.solutions[1].includeDeploymentSettings | Should -Be $true
      # Sol2 should NOT have includesCloudFlows
      $result.solutions[1].PSObject.Properties["includesCloudFlows"] | Should -BeNullOrEmpty
    }
  }

  Context "when no solutions have cloud flows" {
    It "does not add includesCloudFlows to any solution" {
      $original = @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" }
        )
      }

      $path = Join-Path $script:tempDir "build.json"
      $original | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

      # Simulate pipeline: read, don't add flag, write back
      $config = Get-Content $path -Raw | ConvertFrom-Json
      $solutions = @($config.solutions)
      $updated = @{ solutions = @($solutions) } | ConvertTo-Json -Depth 10
      Set-Content -Path $path -Value $updated -Encoding UTF8

      $result = Get-Content $path -Raw | ConvertFrom-Json
      $result.solutions[0].name | Should -Be "Sol1"
      $result.solutions[0].PSObject.Properties["includesCloudFlows"] | Should -BeNullOrEmpty
    }
  }
}
