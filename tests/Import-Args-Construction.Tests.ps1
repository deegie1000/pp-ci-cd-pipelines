Describe "Import argument construction" {

  # -----------------------------------------------------------------------
  # Helper: mirrors the import-args logic from deploy-environment.yml.
  # Builds the pac CLI argument array for a given solution entry.
  # -----------------------------------------------------------------------
  function Build-ImportArgs {
    param(
      [string]$ZipPath,
      [object]$Solution,
      [string]$StageName,
      [string]$ArtifactDir
    )

    $importArgs = @(
      "solution", "import",
      "--path", $ZipPath,
      "--stage-and-upgrade",
      "--skip-lower-version",
      "--activate-plugins"
    )

    $includeSettings = $false
    if ($Solution.PSObject.Properties["includeDeploymentSettings"]) {
      $includeSettings = [bool]$Solution.includeDeploymentSettings
    }

    if ($includeSettings) {
      $settingsFile = Join-Path $ArtifactDir "deploymentSettings_${StageName}.json"
      if (Test-Path $settingsFile) {
        $importArgs += @("--settings-file", $settingsFile)
      }
    }

    return $importArgs
  }

  # -----------------------------------------------------------------------
  # Helper: mirrors the import-args logic from deploy-single-solution.yml.
  # Builds the pac CLI argument array for a single-solution deploy.
  # -----------------------------------------------------------------------
  function Build-SingleSolutionImportArgs {
    param(
      [string]$ZipPath,
      [string]$StageName,
      [string]$RepoRoot
    )

    $importArgs = @(
      "solution", "import",
      "--path", $ZipPath,
      "--stage-and-upgrade",
      "--skip-lower-version",
      "--activate-plugins"
    )

    $settingsPath = Join-Path $RepoRoot "deploymentSettings/deploymentSettings_${StageName}.json"
    if (Test-Path $settingsPath) {
      $importArgs += @("--settings-file", $settingsPath)
    }

    return $importArgs
  }

  BeforeEach {
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "importargs_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
  }

  AfterEach {
    Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "base flags are always present" {
    It "includes --stage-and-upgrade, --skip-lower-version, and --activate-plugins" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      $args = Build-ImportArgs -ZipPath "/fake/Sol1_1.0.0.0.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args | Should -Contain "--stage-and-upgrade"
      $args | Should -Contain "--skip-lower-version"
      $args | Should -Contain "--activate-plugins"
    }

    It "does NOT include --force-overwrite" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      $args = Build-ImportArgs -ZipPath "/fake/Sol1_1.0.0.0.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args | Should -Not -Contain "--force-overwrite"
    }

    It "starts with 'solution' and 'import'" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      $args = Build-ImportArgs -ZipPath "/fake/path.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args[0] | Should -Be "solution"
      $args[1] | Should -Be "import"
    }

    It "includes --path with the correct zip path" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      $zipPath = "/artifact/Sol1_1.0.0.0.zip"
      $args = Build-ImportArgs -ZipPath $zipPath -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $pathIndex = [array]::IndexOf($args, "--path")
      $pathIndex | Should -BeGreaterThan -1
      $args[$pathIndex + 1] | Should -Be $zipPath
    }
  }

  Context "deployment settings flag" {
    It "adds --settings-file when includeDeploymentSettings is true and file exists" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true }
      Set-Content -Path (Join-Path $script:tempDir "deploymentSettings_QA.json") -Value "{}"

      $args = Build-ImportArgs -ZipPath "/fake/path.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args | Should -Contain "--settings-file"
      $settingsIndex = [array]::IndexOf($args, "--settings-file")
      $args[$settingsIndex + 1] | Should -BeLike "*deploymentSettings_QA.json"
    }

    It "does NOT add --settings-file when includeDeploymentSettings is false" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $false }
      Set-Content -Path (Join-Path $script:tempDir "deploymentSettings_QA.json") -Value "{}"

      $args = Build-ImportArgs -ZipPath "/fake/path.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args | Should -Not -Contain "--settings-file"
    }

    It "does NOT add --settings-file when includeDeploymentSettings is omitted" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      Set-Content -Path (Join-Path $script:tempDir "deploymentSettings_QA.json") -Value "{}"

      $args = Build-ImportArgs -ZipPath "/fake/path.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args | Should -Not -Contain "--settings-file"
    }

    It "does NOT add --settings-file when file does not exist even if flag is true" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true }
      # No settings file created

      $args = Build-ImportArgs -ZipPath "/fake/path.zip" -Solution $solution -StageName "QA" -ArtifactDir $script:tempDir

      $args | Should -Not -Contain "--settings-file"
    }

    It "uses the correct stage name in the settings file path" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true }
      Set-Content -Path (Join-Path $script:tempDir "deploymentSettings_Prod.json") -Value "{}"

      $args = Build-ImportArgs -ZipPath "/fake/path.zip" -Solution $solution -StageName "Prod" -ArtifactDir $script:tempDir

      $settingsIndex = [array]::IndexOf($args, "--settings-file")
      $args[$settingsIndex + 1] | Should -BeLike "*deploymentSettings_Prod.json"
    }
  }

  Context "deploy-single-solution template args" {
    It "includes base flags for single-solution deploy" {
      $repoRoot = Join-Path $script:tempDir "repo"
      New-Item -ItemType Directory -Path (Join-Path $repoRoot "deploymentSettings") -Force | Out-Null

      $args = Build-SingleSolutionImportArgs -ZipPath "/fake/path.zip" -StageName "QA" -RepoRoot $repoRoot

      $args | Should -Contain "--stage-and-upgrade"
      $args | Should -Contain "--skip-lower-version"
      $args | Should -Contain "--activate-plugins"
      $args | Should -Not -Contain "--force-overwrite"
    }

    It "adds --settings-file when repo deployment settings exist" {
      $repoRoot = Join-Path $script:tempDir "repo"
      $settingsDir = Join-Path $repoRoot "deploymentSettings"
      New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
      Set-Content -Path (Join-Path $settingsDir "deploymentSettings_Stage.json") -Value "{}"

      $args = Build-SingleSolutionImportArgs -ZipPath "/fake/path.zip" -StageName "Stage" -RepoRoot $repoRoot

      $args | Should -Contain "--settings-file"
    }

    It "omits --settings-file when repo deployment settings do not exist" {
      $repoRoot = Join-Path $script:tempDir "repo"
      New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

      $args = Build-SingleSolutionImportArgs -ZipPath "/fake/path.zip" -StageName "Stage" -RepoRoot $repoRoot

      $args | Should -Not -Contain "--settings-file"
    }
  }
}
