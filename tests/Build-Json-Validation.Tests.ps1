Describe "build.json validation" {

  BeforeAll {
    # Helper: writes a build.json and returns the path
    function New-BuildJson {
      param([object]$Content)
      $dir = Join-Path ([System.IO.Path]::GetTempPath()) "build_$([guid]::NewGuid().ToString('N'))"
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      $path = Join-Path $dir "build.json"
      $Content | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
      return $path
    }

    # Validation function under test — mirrors what the pipeline should enforce
    function Test-BuildJson {
      param([string]$Path)
      $config = Get-Content $Path -Raw | ConvertFrom-Json
      $solutions = @($config.solutions)

      if (-not $solutions -or $solutions.Count -eq 0) {
        throw "No solutions specified in build.json"
      }

      $settingsCount = 0
      foreach ($s in $solutions) {
        if (-not $s.name) { throw "Solution missing 'name' property" }
        if (-not $s.version) { throw "Solution missing 'version' property" }

        $hasSettings = $false
        if ($s.PSObject.Properties["includeDeploymentSettings"]) {
          $hasSettings = [bool]$s.includeDeploymentSettings
        }
        if ($hasSettings) { $settingsCount++ }
      }

      if ($settingsCount -gt 1) {
        throw "Only one solution may have includeDeploymentSettings set to true, but $settingsCount were found"
      }

      return @{
        Solutions = $solutions
        HasDeploymentSettings = ($settingsCount -eq 1)
        SettingsCount = $settingsCount
      }
    }
  }

  AfterEach {
    if ($script:buildJsonPath) {
      $dir = Split-Path $script:buildJsonPath
      Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Context "valid build.json without deployment settings" {
    It "accepts solutions without includeDeploymentSettings" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" },
          @{ name = "Sol2"; version = "2.0.0.0" }
        )
      }

      $result = Test-BuildJson -Path $script:buildJsonPath
      $result.Solutions.Count | Should -Be 2
      $result.HasDeploymentSettings | Should -Be $false
      $result.SettingsCount | Should -Be 0
    }
  }

  Context "valid build.json with one deployment settings solution" {
    It "accepts exactly one solution with includeDeploymentSettings true" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" },
          @{ name = "Sol2"; version = "2.0.0.0"; includeDeploymentSettings = $true }
        )
      }

      $result = Test-BuildJson -Path $script:buildJsonPath
      $result.HasDeploymentSettings | Should -Be $true
      $result.SettingsCount | Should -Be 1
    }
  }

  Context "valid build.json with explicit false" {
    It "treats includeDeploymentSettings false the same as omitted" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $false },
          @{ name = "Sol2"; version = "2.0.0.0" }
        )
      }

      $result = Test-BuildJson -Path $script:buildJsonPath
      $result.HasDeploymentSettings | Should -Be $false
      $result.SettingsCount | Should -Be 0
    }
  }

  Context "invalid: multiple solutions with includeDeploymentSettings true" {
    It "throws an error when more than one solution has includeDeploymentSettings true" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0"; includeDeploymentSettings = $true },
          @{ name = "Sol2"; version = "2.0.0.0"; includeDeploymentSettings = $true }
        )
      }

      { Test-BuildJson -Path $script:buildJsonPath } | Should -Throw "*Only one solution*"
    }
  }

  Context "invalid: empty solutions array" {
    It "throws an error for empty solutions" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @()
      }

      { Test-BuildJson -Path $script:buildJsonPath } | Should -Throw "*No solutions*"
    }
  }

  Context "invalid: missing name" {
    It "throws an error when name is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ version = "1.0.0.0" }
        )
      }

      { Test-BuildJson -Path $script:buildJsonPath } | Should -Throw "*missing 'name'*"
    }
  }

  Context "invalid: missing version" {
    It "throws an error when version is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1" }
        )
      }

      { Test-BuildJson -Path $script:buildJsonPath } | Should -Throw "*missing 'version'*"
    }
  }
}
