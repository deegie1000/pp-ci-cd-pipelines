Describe "configData validation in build.json" {

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
  function Test-ConfigData {
    param([string]$Path)
    $config = Get-Content $Path -Raw | ConvertFrom-Json

    $result = @{
      HasConfigData = $false
      ConfigDataCount = 0
      DataSets = @()
    }

    if (-not $config.PSObject.Properties["configData"] -or $config.configData.Count -eq 0) {
      return $result
    }

    $configData = @($config.configData)
    $result.HasConfigData = $true
    $result.ConfigDataCount = $configData.Count

    foreach ($ds in $configData) {
      if (-not $ds.name) { throw "Config data entry missing 'name' property" }
      if (-not $ds.entity) { throw "Config data entry '$($ds.name)' missing 'entity' property" }
      if (-not $ds.primaryKey) { throw "Config data entry '$($ds.name)' missing 'primaryKey' property" }
      if (-not $ds.select) { throw "Config data entry '$($ds.name)' missing 'select' property" }
      if (-not $ds.dataFile) { throw "Config data entry '$($ds.name)' missing 'dataFile' property" }

      $result.DataSets += @{
        Name = $ds.name
        Entity = $ds.entity
        PrimaryKey = $ds.primaryKey
        HasFilter = [bool]($ds.PSObject.Properties["filter"] -and $ds.filter)
      }
    }

    return $result
  }

  AfterEach {
    if ($script:buildJsonPath) {
      $dir = Split-Path $script:buildJsonPath
      Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Context "build.json without configData" {
    It "returns HasConfigData false when configData is absent" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" }
        )
      }

      $result = Test-ConfigData -Path $script:buildJsonPath
      $result.HasConfigData | Should -Be $false
      $result.ConfigDataCount | Should -Be 0
    }

    It "returns HasConfigData false when configData is an empty array" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" }
        )
        configData = @()
      }

      $result = Test-ConfigData -Path $script:buildJsonPath
      $result.HasConfigData | Should -Be $false
    }
  }

  Context "valid configData with all required fields" {
    It "accepts configData with required fields and optional filter" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" }
        )
        configData = @(
          @{
            name = "USStates"
            entity = "cr123_states"
            primaryKey = "cr123_stateid"
            select = "cr123_name,cr123_abbreviation"
            filter = "statecode eq 0"
            dataFile = "configdata/USStates.json"
          }
        )
      }

      $result = Test-ConfigData -Path $script:buildJsonPath
      $result.HasConfigData | Should -Be $true
      $result.ConfigDataCount | Should -Be 1
      $result.DataSets[0].Name | Should -Be "USStates"
      $result.DataSets[0].HasFilter | Should -Be $true
    }

    It "accepts configData without filter" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" }
        )
        configData = @(
          @{
            name = "CountryCodes"
            entity = "cr123_countries"
            primaryKey = "cr123_countryid"
            select = "cr123_name,cr123_isocode"
            dataFile = "configdata/CountryCodes.json"
          }
        )
      }

      $result = Test-ConfigData -Path $script:buildJsonPath
      $result.HasConfigData | Should -Be $true
      $result.DataSets[0].HasFilter | Should -Be $false
    }

    It "accepts multiple configData entries" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(
          @{ name = "Sol1"; version = "1.0.0.0" }
        )
        configData = @(
          @{
            name = "USStates"
            entity = "cr123_states"
            primaryKey = "cr123_stateid"
            select = "cr123_name"
            dataFile = "configdata/USStates.json"
          },
          @{
            name = "CountryCodes"
            entity = "cr123_countries"
            primaryKey = "cr123_countryid"
            select = "cr123_name"
            dataFile = "configdata/CountryCodes.json"
          }
        )
      }

      $result = Test-ConfigData -Path $script:buildJsonPath
      $result.ConfigDataCount | Should -Be 2
    }
  }

  Context "invalid configData: missing required fields" {
    It "throws when name is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(@{ name = "Sol1"; version = "1.0.0.0" })
        configData = @(
          @{
            entity = "cr123_states"
            primaryKey = "cr123_stateid"
            select = "cr123_name"
            dataFile = "configdata/USStates.json"
          }
        )
      }

      { Test-ConfigData -Path $script:buildJsonPath } | Should -Throw "*missing 'name'*"
    }

    It "throws when entity is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(@{ name = "Sol1"; version = "1.0.0.0" })
        configData = @(
          @{
            name = "USStates"
            primaryKey = "cr123_stateid"
            select = "cr123_name"
            dataFile = "configdata/USStates.json"
          }
        )
      }

      { Test-ConfigData -Path $script:buildJsonPath } | Should -Throw "*missing 'entity'*"
    }

    It "throws when primaryKey is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(@{ name = "Sol1"; version = "1.0.0.0" })
        configData = @(
          @{
            name = "USStates"
            entity = "cr123_states"
            select = "cr123_name"
            dataFile = "configdata/USStates.json"
          }
        )
      }

      { Test-ConfigData -Path $script:buildJsonPath } | Should -Throw "*missing 'primaryKey'*"
    }

    It "throws when select is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(@{ name = "Sol1"; version = "1.0.0.0" })
        configData = @(
          @{
            name = "USStates"
            entity = "cr123_states"
            primaryKey = "cr123_stateid"
            dataFile = "configdata/USStates.json"
          }
        )
      }

      { Test-ConfigData -Path $script:buildJsonPath } | Should -Throw "*missing 'select'*"
    }

    It "throws when dataFile is missing" {
      $script:buildJsonPath = New-BuildJson -Content @{
        solutions = @(@{ name = "Sol1"; version = "1.0.0.0" })
        configData = @(
          @{
            name = "USStates"
            entity = "cr123_states"
            primaryKey = "cr123_stateid"
            select = "cr123_name"
          }
        )
      }

      { Test-ConfigData -Path $script:buildJsonPath } | Should -Throw "*missing 'dataFile'*"
    }
  }
}

Describe "Sync-ConfigData data file format" {

  Context "data file round-trip serialization" {
    It "preserves GUIDs and all columns in JSON output" {
      $records = @(
        @{
          cr123_stateid = "a1b2c3d4-0000-0000-0000-000000000001"
          cr123_name = "Alabama"
          cr123_abbreviation = "AL"
        },
        @{
          cr123_stateid = "a1b2c3d4-0000-0000-0000-000000000002"
          cr123_name = "Alaska"
          cr123_abbreviation = "AK"
        }
      )

      $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "configdata_$([guid]::NewGuid().ToString('N')).json"
      $records | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding UTF8

      $loaded = @(Get-Content $tempFile -Raw | ConvertFrom-Json)
      $loaded.Count | Should -Be 2
      $loaded[0].cr123_stateid | Should -Be "a1b2c3d4-0000-0000-0000-000000000001"
      $loaded[0].cr123_name | Should -Be "Alabama"
      $loaded[1].cr123_abbreviation | Should -Be "AK"

      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }

    It "handles empty data file (no records)" {
      $records = @()
      $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "configdata_$([guid]::NewGuid().ToString('N')).json"
      # ConvertTo-Json with empty array produces "[]" only with explicit wrapping
      "[]" | Set-Content -Path $tempFile -Encoding UTF8

      $loaded = @(Get-Content $tempFile -Raw | ConvertFrom-Json)
      $loaded.Count | Should -Be 0

      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
  }
}
