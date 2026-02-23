Describe "Artifact validation" {

  BeforeAll {
  # -----------------------------------------------------------------------
  # Helper: mirrors the upfront artifact validation logic from
  # deploy-environment.yml. Validates that all required zip files and
  # deployment settings files exist before any imports begin.
  # Returns a result object with pass/fail and list of missing artifacts.
  # -----------------------------------------------------------------------
  function Test-ArtifactValidation {
    param(
      [array]$Solutions,
      [string]$ArtifactDir,
      [string]$StageName
    )

    $missingArtifacts = @()

    foreach ($solution in $Solutions) {
      $name    = $solution.name
      $version = $solution.version
      $zipPath = Join-Path $ArtifactDir "${name}_${version}.zip"

      if (-not (Test-Path $zipPath)) {
        $missingArtifacts += "${name}_${version}.zip"
      }

      $includeSettings = $false
      if ($solution.PSObject.Properties["includeDeploymentSettings"]) {
        $includeSettings = [bool]$solution.includeDeploymentSettings
      }

      if ($includeSettings) {
        $settingsFile = Join-Path $ArtifactDir "deploymentSettings_${StageName}.json"
        if (-not (Test-Path $settingsFile)) {
          $missingArtifacts += "deploymentSettings_${StageName}.json"
        }
      }
    }

    return @{
      IsValid          = ($missingArtifacts.Count -eq 0)
      MissingArtifacts = $missingArtifacts
      MissingCount     = $missingArtifacts.Count
    }
  }
  } # end BeforeAll

  BeforeEach {
    $script:artifactDir = Join-Path ([System.IO.Path]::GetTempPath()) "artifact_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:artifactDir -Force | Out-Null
  }

  AfterEach {
    Remove-Item -Path $script:artifactDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "all artifacts present" {
    It "passes when all solution zips exist" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"
      Set-Content -Path (Join-Path $script:artifactDir "Sol2_2.0.0.0.zip") -Value "fake"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $true
      $result.MissingCount | Should -Be 0
    }

    It "passes when solution zips and deployment settings both exist" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0"; includeDeploymentSettings = $true }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"
      Set-Content -Path (Join-Path $script:artifactDir "Sol2_2.0.0.0.zip") -Value "fake"
      Set-Content -Path (Join-Path $script:artifactDir "deploymentSettings_QA.json") -Value "{}"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $true
    }
  }

  Context "missing solution zips" {
    It "fails when a solution zip is missing" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"
      # Sol2 zip missing

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $false
      $result.MissingCount | Should -Be 1
      $result.MissingArtifacts | Should -Contain "Sol2_2.0.0.0.zip"
    }

    It "fails and reports all missing zips when multiple are absent" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" },
        [PSCustomObject]@{ name = "Sol3"; version = "3.0.0.0" }
      )
      # No zips at all

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $false
      $result.MissingCount | Should -Be 3
    }
  }

  Context "missing deployment settings" {
    It "fails when deployment settings file is missing but required" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"
      # No deployment settings file

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $false
      $result.MissingArtifacts | Should -Contain "deploymentSettings_QA.json"
    }

    It "passes when deployment settings are not required even if file is absent" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $false }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $true
    }

    It "passes when includeDeploymentSettings is omitted" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $true
    }
  }

  Context "stage-specific deployment settings" {
    It "checks for the correct stage-specific settings file" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"
      # Create QA settings but check for Prod
      Set-Content -Path (Join-Path $script:artifactDir "deploymentSettings_QA.json") -Value "{}"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "Prod"

      $result.IsValid | Should -Be $false
      $result.MissingArtifacts | Should -Contain "deploymentSettings_Prod.json"
    }

    It "does not duplicate missing deployment settings when multiple solutions reference it" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"
      Set-Content -Path (Join-Path $script:artifactDir "Sol2_2.0.0.0.zip") -Value "fake"
      # No settings file — only Sol1 requires it

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $false
      $result.MissingCount | Should -Be 1
    }
  }

  Context "combined failures" {
    It "reports both missing zips and missing settings in one result" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0"; includeDeploymentSettings = $true }
      )
      # Sol1 zip present, Sol2 zip missing, settings missing
      Set-Content -Path (Join-Path $script:artifactDir "Sol1_1.0.0.0.zip") -Value "fake"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "Stage"

      $result.IsValid | Should -Be $false
      $result.MissingCount | Should -Be 2
      $result.MissingArtifacts | Should -Contain "Sol2_2.0.0.0.zip"
      $result.MissingArtifacts | Should -Contain "deploymentSettings_Stage.json"
    }
  }

  Context "zip naming convention" {
    It "expects zip name format: {name}_{version}.zip" {
      $solutions = @(
        [PSCustomObject]@{ name = "MyApp"; version = "3.1.0.5" }
      )
      # Wrong name format — missing version
      Set-Content -Path (Join-Path $script:artifactDir "MyApp.zip") -Value "fake"

      $result = Test-ArtifactValidation -Solutions $solutions -ArtifactDir $script:artifactDir -StageName "QA"

      $result.IsValid | Should -Be $false
      $result.MissingArtifacts | Should -Contain "MyApp_3.1.0.5.zip"
    }
  }
}
