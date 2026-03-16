BeforeAll {
  $scriptPath = Join-Path $PSScriptRoot "../scripts/Merge-DeploymentSettings.ps1"
}

Describe "Merge-DeploymentSettings" {

  BeforeEach {
    # Create temp directories for each test
    $script:exportDir = Join-Path ([System.IO.Path]::GetTempPath()) "export_$([guid]::NewGuid().ToString('N'))"
    $script:rootDir   = Join-Path ([System.IO.Path]::GetTempPath()) "root_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:exportDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:rootDir   -Force | Out-Null
  }

  AfterEach {
    Remove-Item -Path $script:exportDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $script:rootDir   -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "when no export settings files exist" {
    It "exits without error and does not create root files" {
      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      $rootFiles = Get-ChildItem -Path $script:rootDir -Filter "deploymentSettings_*.json" -ErrorAction SilentlyContinue
      $rootFiles | Should -BeNullOrEmpty
    }
  }

  Context "when root file does not exist" {
    It "creates a new root file from export items" {
      $exportContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_Var1"; Value = "value1" }
        )
        ConnectionReferences = @(
          @{ LogicalName = "cr5a4_Conn1"; ConnectionId = "conn-1"; ConnectorId = "/apis/shared_test" }
        )
      } | ConvertTo-Json -Depth 10

      Set-Content -Path (Join-Path $script:exportDir "deploymentSettings_Test.json") -Value $exportContent

      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      $rootFile = Join-Path $script:rootDir "deploymentSettings_Test.json"
      $rootFile | Should -Exist

      $result = Get-Content $rootFile -Raw | ConvertFrom-Json
      $result.EnvironmentVariables.Count | Should -Be 1
      $result.EnvironmentVariables[0].SchemaName | Should -Be "cr5a4_Var1"
      $result.EnvironmentVariables[0].Value | Should -Be "value1"
      $result.ConnectionReferences.Count | Should -Be 1
      $result.ConnectionReferences[0].LogicalName | Should -Be "cr5a4_Conn1"
    }
  }

  Context "when merging new items into existing root" {
    It "appends items that do not exist in root" {
      # Root has one variable
      $rootContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_Existing"; Value = "original" }
        )
        ConnectionReferences = @()
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:rootDir "deploymentSettings_Test.json") -Value $rootContent

      # Export adds a new variable
      $exportContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_NewVar"; Value = "new-value" }
        )
        ConnectionReferences = @(
          @{ LogicalName = "cr5a4_NewConn"; ConnectionId = "conn-new"; ConnectorId = "/apis/shared_new" }
        )
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:exportDir "deploymentSettings_Test.json") -Value $exportContent

      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      $result = Get-Content (Join-Path $script:rootDir "deploymentSettings_Test.json") -Raw | ConvertFrom-Json
      $result.EnvironmentVariables.Count | Should -Be 2
      $result.EnvironmentVariables[0].SchemaName | Should -Be "cr5a4_Existing"
      $result.EnvironmentVariables[0].Value | Should -Be "original"
      $result.EnvironmentVariables[1].SchemaName | Should -Be "cr5a4_NewVar"
      $result.EnvironmentVariables[1].Value | Should -Be "new-value"
      $result.ConnectionReferences.Count | Should -Be 1
      $result.ConnectionReferences[0].LogicalName | Should -Be "cr5a4_NewConn"
    }
  }

  Context "when export item matches an existing root item" {
    It "overwrites the root item with the export item" {
      # Root has a variable
      $rootContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_Shared"; Value = "old-value" }
        )
        ConnectionReferences = @(
          @{ LogicalName = "cr5a4_SharedConn"; ConnectionId = "old-conn"; ConnectorId = "/apis/shared_old" }
        )
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:rootDir "deploymentSettings_Stage.json") -Value $rootContent

      # Export has the same keys with new values
      $exportContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_Shared"; Value = "new-value" }
        )
        ConnectionReferences = @(
          @{ LogicalName = "cr5a4_SharedConn"; ConnectionId = "new-conn"; ConnectorId = "/apis/shared_new" }
        )
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:exportDir "deploymentSettings_Stage.json") -Value $exportContent

      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      $result = Get-Content (Join-Path $script:rootDir "deploymentSettings_Stage.json") -Raw | ConvertFrom-Json
      $result.EnvironmentVariables.Count | Should -Be 1
      $result.EnvironmentVariables[0].Value | Should -Be "new-value"
      $result.ConnectionReferences.Count | Should -Be 1
      $result.ConnectionReferences[0].ConnectionId | Should -Be "new-conn"
      $result.ConnectionReferences[0].ConnectorId | Should -Be "/apis/shared_new"
    }
  }

  Context "when export has a mix of new and existing items" {
    It "overwrites matching items and appends new ones preserving order" {
      $rootContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_A"; Value = "a-old" },
          @{ SchemaName = "cr5a4_B"; Value = "b-old" },
          @{ SchemaName = "cr5a4_C"; Value = "c-old" }
        )
        ConnectionReferences = @()
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:rootDir "deploymentSettings_Prod.json") -Value $rootContent

      $exportContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_B"; Value = "b-new" },
          @{ SchemaName = "cr5a4_D"; Value = "d-new" }
        )
        ConnectionReferences = @()
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:exportDir "deploymentSettings_Prod.json") -Value $exportContent

      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      $result = Get-Content (Join-Path $script:rootDir "deploymentSettings_Prod.json") -Raw | ConvertFrom-Json
      $result.EnvironmentVariables.Count | Should -Be 4
      # Order: A (root), B (overwritten), C (root), D (new)
      $result.EnvironmentVariables[0].SchemaName | Should -Be "cr5a4_A"
      $result.EnvironmentVariables[0].Value | Should -Be "a-old"
      $result.EnvironmentVariables[1].SchemaName | Should -Be "cr5a4_B"
      $result.EnvironmentVariables[1].Value | Should -Be "b-new"
      $result.EnvironmentVariables[2].SchemaName | Should -Be "cr5a4_C"
      $result.EnvironmentVariables[2].Value | Should -Be "c-old"
      $result.EnvironmentVariables[3].SchemaName | Should -Be "cr5a4_D"
      $result.EnvironmentVariables[3].Value | Should -Be "d-new"
    }
  }

  Context "when multiple environment files exist" {
    It "merges each environment file independently" {
      # Create root files
      foreach ($env in @("Test", "Stage")) {
        $rootContent = @{
          EnvironmentVariables = @(
            @{ SchemaName = "cr5a4_Root_$env"; Value = "root-$env" }
          )
          ConnectionReferences = @()
        } | ConvertTo-Json -Depth 10
        Set-Content -Path (Join-Path $script:rootDir "deploymentSettings_$env.json") -Value $rootContent
      }

      # Create export files
      foreach ($env in @("Test", "Stage")) {
        $exportContent = @{
          EnvironmentVariables = @(
            @{ SchemaName = "cr5a4_Export_$env"; Value = "export-$env" }
          )
          ConnectionReferences = @()
        } | ConvertTo-Json -Depth 10
        Set-Content -Path (Join-Path $script:exportDir "deploymentSettings_$env.json") -Value $exportContent
      }

      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      foreach ($env in @("Test", "Stage")) {
        $result = Get-Content (Join-Path $script:rootDir "deploymentSettings_$env.json") -Raw | ConvertFrom-Json
        $result.EnvironmentVariables.Count | Should -Be 2
        $result.EnvironmentVariables[0].SchemaName | Should -Be "cr5a4_Root_$env"
        $result.EnvironmentVariables[1].SchemaName | Should -Be "cr5a4_Export_$env"
      }
    }
  }

  Context "when export has empty arrays" {
    It "preserves existing root items without changes" {
      $rootContent = @{
        EnvironmentVariables = @(
          @{ SchemaName = "cr5a4_Keep"; Value = "keep-me" }
        )
        ConnectionReferences = @(
          @{ LogicalName = "cr5a4_KeepConn"; ConnectionId = "keep-conn"; ConnectorId = "/apis/shared_keep" }
        )
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:rootDir "deploymentSettings_Test.json") -Value $rootContent

      $exportContent = @{
        EnvironmentVariables = @()
        ConnectionReferences = @()
      } | ConvertTo-Json -Depth 10
      Set-Content -Path (Join-Path $script:exportDir "deploymentSettings_Test.json") -Value $exportContent

      & $scriptPath -ExportFolder $script:exportDir -RootFolder $script:rootDir

      $result = Get-Content (Join-Path $script:rootDir "deploymentSettings_Test.json") -Raw | ConvertFrom-Json
      $result.EnvironmentVariables.Count | Should -Be 1
      $result.EnvironmentVariables[0].Value | Should -Be "keep-me"
      $result.ConnectionReferences.Count | Should -Be 1
      $result.ConnectionReferences[0].ConnectionId | Should -Be "keep-conn"
    }
  }
}
