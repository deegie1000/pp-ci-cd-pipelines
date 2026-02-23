Describe "Deploy-to-Dev deployment settings resolution" {

  BeforeAll {
  # -----------------------------------------------------------------------
  # Helper: mirrors the logic from deploy-solution.yml Dev stage
  # that resolves whether a deployment settings file exists.
  # -----------------------------------------------------------------------
  function Resolve-DeploymentSettings {
    param(
      [string]$ArtifactDir,
      [string]$RepoRoot,
      [string]$BuildReason   # "ResourceTrigger" or "Manual"
    )

    if ($BuildReason -eq "ResourceTrigger") {
      $settingsPath = Join-Path $ArtifactDir "deploymentSettings_Dev.json"
    } else {
      $settingsPath = Join-Path $RepoRoot "deploymentSettings/deploymentSettings_Dev.json"
    }

    return @{
      HasDeploymentSettings = (Test-Path $settingsPath)
      SettingsPath          = $settingsPath
    }
  }
  } # end BeforeAll

  BeforeEach {
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "deploy_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
  }

  AfterEach {
    Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "auto-triggered run (ResourceTrigger)" {
    It "finds deployment settings in the artifact directory" {
      $artifactDir = Join-Path $script:tempDir "artifact"
      New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
      Set-Content -Path (Join-Path $artifactDir "deploymentSettings_Dev.json") -Value "{}"

      $result = Resolve-DeploymentSettings -ArtifactDir $artifactDir -RepoRoot $script:tempDir -BuildReason "ResourceTrigger"
      $result.HasDeploymentSettings | Should -Be $true
      $result.SettingsPath | Should -BeLike "*artifact*deploymentSettings_Dev.json"
    }

    It "returns false when settings file is not in artifact" {
      $artifactDir = Join-Path $script:tempDir "artifact"
      New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null

      $result = Resolve-DeploymentSettings -ArtifactDir $artifactDir -RepoRoot $script:tempDir -BuildReason "ResourceTrigger"
      $result.HasDeploymentSettings | Should -Be $false
    }
  }

  Context "manual run" {
    It "finds deployment settings in the repo root" {
      $settingsDir = Join-Path $script:tempDir "deploymentSettings"
      New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
      Set-Content -Path (Join-Path $settingsDir "deploymentSettings_Dev.json") -Value "{}"

      $result = Resolve-DeploymentSettings -ArtifactDir "" -RepoRoot $script:tempDir -BuildReason "Manual"
      $result.HasDeploymentSettings | Should -Be $true
      $result.SettingsPath | Should -BeLike "*deploymentSettings*deploymentSettings_Dev.json"
    }

    It "returns false when settings file is not in repo" {
      $result = Resolve-DeploymentSettings -ArtifactDir "" -RepoRoot $script:tempDir -BuildReason "Manual"
      $result.HasDeploymentSettings | Should -Be $false
    }
  }
}

Describe "Pre-Dev artifact staging" {

  BeforeAll {
  # -----------------------------------------------------------------------
  # Helper: mirrors the logic from export-solution-predev.yml Step 8
  # that stages the managed zip and deployment settings for the artifact.
  # -----------------------------------------------------------------------
  function Invoke-ArtifactStaging {
    param(
      [string]$ManagedZipPath,
      [string]$SolutionName,
      [string]$RepoRoot,
      [string]$StagingDir
    )

    $stagedFiles = @()

    # Copy managed zip
    Copy-Item -Path $ManagedZipPath -Destination (Join-Path $StagingDir "$SolutionName.zip")
    $stagedFiles += "$SolutionName.zip"

    # Copy deployment settings for Dev (if exists)
    $settingsFile = Join-Path $RepoRoot "deploymentSettings/deploymentSettings_Dev.json"
    if (Test-Path $settingsFile) {
      Copy-Item -Path $settingsFile -Destination (Join-Path $StagingDir "deploymentSettings_Dev.json")
      $stagedFiles += "deploymentSettings_Dev.json"
    }

    return $stagedFiles
  }
  } # end BeforeAll

  BeforeEach {
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "predev_$([guid]::NewGuid().ToString('N'))"
    $script:repoRoot = Join-Path $script:tempDir "repo"
    $script:stagingDir = Join-Path $script:tempDir "staging"
    $script:managedDir = Join-Path $script:tempDir "managed"

    New-Item -ItemType Directory -Path $script:repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:stagingDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:managedDir -Force | Out-Null

    # Create a fake managed zip
    Set-Content -Path (Join-Path $script:managedDir "TestSolution.zip") -Value "fake-zip"
  }

  AfterEach {
    Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "when deploymentSettings_Dev.json exists in repo root" {
    It "stages both the managed zip and deployment settings" {
      $settingsDir = Join-Path $script:repoRoot "deploymentSettings"
      New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
      Set-Content -Path (Join-Path $settingsDir "deploymentSettings_Dev.json") -Value '{"EnvironmentVariables":[],"ConnectionReferences":[]}'

      $staged = Invoke-ArtifactStaging `
        -ManagedZipPath (Join-Path $script:managedDir "TestSolution.zip") `
        -SolutionName "TestSolution" `
        -RepoRoot $script:repoRoot `
        -StagingDir $script:stagingDir

      $staged | Should -HaveCount 2
      $staged | Should -Contain "TestSolution.zip"
      $staged | Should -Contain "deploymentSettings_Dev.json"

      (Join-Path $script:stagingDir "TestSolution.zip") | Should -Exist
      (Join-Path $script:stagingDir "deploymentSettings_Dev.json") | Should -Exist
    }
  }

  Context "when deploymentSettings_Dev.json does not exist" {
    It "stages only the managed zip" {
      $staged = Invoke-ArtifactStaging `
        -ManagedZipPath (Join-Path $script:managedDir "TestSolution.zip") `
        -SolutionName "TestSolution" `
        -RepoRoot $script:repoRoot `
        -StagingDir $script:stagingDir

      $staged | Should -HaveCount 1
      $staged | Should -Contain "TestSolution.zip"
      (Join-Path $script:stagingDir "TestSolution.zip") | Should -Exist
      (Join-Path $script:stagingDir "deploymentSettings_Dev.json") | Should -Not -Exist
    }
  }
}
