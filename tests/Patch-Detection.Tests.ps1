Describe "Patch solution detection" {

  BeforeAll {
  # -----------------------------------------------------------------------
  # Helper: mirrors the patch detection logic from export-solutions.yml.
  # Reads Solution.xml and determines if the solution is a patch.
  # Returns patch metadata if it is.
  # -----------------------------------------------------------------------
  function Test-PatchSolution {
    param([string]$SolutionXmlPath)

    if (-not (Test-Path $SolutionXmlPath)) {
      throw "Solution.xml not found at: $SolutionXmlPath"
    }

    [xml]$solutionXml = Get-Content $SolutionXmlPath
    $parentNode = $solutionXml.ImportExportXml.SolutionManifest.ParentSolution

    $result = @{
      IsPatch        = $false
      ParentSolution = $null
      DisplayName    = $null
      Version        = $solutionXml.ImportExportXml.SolutionManifest.Version
    }

    if ($parentNode -and $parentNode.UniqueName) {
      $result.IsPatch = $true
      $result.ParentSolution = $parentNode.UniqueName

      $localizedNames = $solutionXml.ImportExportXml.SolutionManifest.LocalizedNames.LocalizedName
      $displayName = ($localizedNames | Where-Object { $_.languagecode -eq "1033" }).description
      $result.DisplayName = $displayName
    }

    return $result
  }

  # -----------------------------------------------------------------------
  # Helper: mirrors how the export pipeline adds patch metadata to the
  # solution object in build.json.
  # -----------------------------------------------------------------------
  function Add-PatchMetadata {
    param(
      [object]$Solution,
      [hashtable]$PatchInfo
    )

    if ($PatchInfo.IsPatch) {
      $Solution | Add-Member -NotePropertyName "isPatch" -NotePropertyValue $true -Force
      $Solution | Add-Member -NotePropertyName "parentSolution" -NotePropertyValue $PatchInfo.ParentSolution -Force
      $displayName = if ($PatchInfo.DisplayName) { $PatchInfo.DisplayName } else { $Solution.name }
      $Solution | Add-Member -NotePropertyName "displayName" -NotePropertyValue $displayName -Force
    }

    return $Solution
  }

  # -----------------------------------------------------------------------
  # Helper: creates a Solution.xml file with optional parent solution.
  # -----------------------------------------------------------------------
  function New-SolutionXml {
    param(
      [string]$OutputDir,
      [string]$UniqueName,
      [string]$Version,
      [string]$DisplayName = "My Solution",
      [string]$ParentUniqueName = $null,
      [string]$ParentVersion = $null
    )

    $otherDir = Join-Path $OutputDir "Other"
    New-Item -ItemType Directory -Path $otherDir -Force | Out-Null

    $parentXml = ""
    if ($ParentUniqueName) {
      $parentXml = @"

      <ParentSolution>
        <UniqueName>$ParentUniqueName</UniqueName>
        <Version>$ParentVersion</Version>
      </ParentSolution>
"@
    }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<ImportExportXml version="9.2.24052.102" SolutionPackageVersion="9.2" languagecode="1033" generatedBy="CrmLive" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <SolutionManifest>
    <UniqueName>$UniqueName</UniqueName>
    <LocalizedNames>
      <LocalizedName description="$DisplayName" languagecode="1033" />
    </LocalizedNames>
    <Version>$Version</Version>$parentXml
    <Managed>0</Managed>
  </SolutionManifest>
</ImportExportXml>
"@

    $xmlPath = Join-Path $otherDir "Solution.xml"
    Set-Content -Path $xmlPath -Value $xml -Encoding UTF8
    return $xmlPath
  }
  } # end BeforeAll

  BeforeEach {
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "patch_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
  }

  AfterEach {
    Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context "non-patch solutions" {
    It "returns IsPatch false when no ParentSolution element exists" {
      $xmlPath = New-SolutionXml `
        -OutputDir $script:tempDir `
        -UniqueName "CoreComponents" `
        -Version "1.0.0.0" `
        -DisplayName "Core Components"

      $result = Test-PatchSolution -SolutionXmlPath $xmlPath

      $result.IsPatch | Should -Be $false
      $result.ParentSolution | Should -BeNullOrEmpty
      $result.Version | Should -Be "1.0.0.0"
    }
  }

  Context "patch solutions" {
    It "detects a patch solution with parent" {
      $xmlPath = New-SolutionXml `
        -OutputDir $script:tempDir `
        -UniqueName "CoreComponentsPatch1" `
        -Version "1.0.0.1" `
        -DisplayName "Core Components Patch 1" `
        -ParentUniqueName "CoreComponents" `
        -ParentVersion "1.0.0.0"

      $result = Test-PatchSolution -SolutionXmlPath $xmlPath

      $result.IsPatch | Should -Be $true
      $result.ParentSolution | Should -Be "CoreComponents"
      $result.DisplayName | Should -Be "Core Components Patch 1"
      $result.Version | Should -Be "1.0.0.1"
    }
  }

  Context "build.json metadata enrichment" {
    It "adds isPatch, parentSolution, and displayName to solution object" {
      $solution = [PSCustomObject]@{ name = "MyPatch"; version = "1.0.0.1" }
      $patchInfo = @{
        IsPatch        = $true
        ParentSolution = "MyParent"
        DisplayName    = "My Patch Display Name"
      }

      $enriched = Add-PatchMetadata -Solution $solution -PatchInfo $patchInfo

      $enriched.isPatch | Should -Be $true
      $enriched.parentSolution | Should -Be "MyParent"
      $enriched.displayName | Should -Be "My Patch Display Name"
      # Original properties preserved
      $enriched.name | Should -Be "MyPatch"
      $enriched.version | Should -Be "1.0.0.1"
    }

    It "does not add patch properties to non-patch solutions" {
      $solution = [PSCustomObject]@{ name = "RegularSol"; version = "2.0.0.0" }
      $patchInfo = @{
        IsPatch        = $false
        ParentSolution = $null
        DisplayName    = $null
      }

      $enriched = Add-PatchMetadata -Solution $solution -PatchInfo $patchInfo

      $enriched.PSObject.Properties["isPatch"] | Should -BeNullOrEmpty
      $enriched.PSObject.Properties["parentSolution"] | Should -BeNullOrEmpty
      $enriched.PSObject.Properties["displayName"] | Should -BeNullOrEmpty
    }

    It "uses solution name as displayName when XML has no localized name" {
      $solution = [PSCustomObject]@{ name = "MyPatch"; version = "1.0.0.1" }
      $patchInfo = @{
        IsPatch        = $true
        ParentSolution = "MyParent"
        DisplayName    = $null  # No localized name found
      }

      $enriched = Add-PatchMetadata -Solution $solution -PatchInfo $patchInfo

      $enriched.displayName | Should -Be "MyPatch"
    }
  }

  Context "build.json round-trip with patch metadata" {
    It "preserves patch metadata through JSON serialization" {
      $buildConfig = @{
        solutions = @(
          @{ name = "Parent"; version = "1.0.0.0" },
          @{ name = "ParentPatch1"; version = "1.0.0.1"; isPatch = $true; parentSolution = "Parent"; displayName = "Parent Patch 1" }
        )
      }

      $path = Join-Path $script:tempDir "build.json"
      $buildConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

      $loaded = Get-Content $path -Raw | ConvertFrom-Json
      $patchSol = $loaded.solutions | Where-Object { $_.name -eq "ParentPatch1" }

      $patchSol.isPatch | Should -Be $true
      $patchSol.parentSolution | Should -Be "Parent"
      $patchSol.displayName | Should -Be "Parent Patch 1"
    }

    It "non-patch solutions have no patch properties after round-trip" {
      $buildConfig = @{
        solutions = @(
          @{ name = "RegularSol"; version = "1.0.0.0" }
        )
      }

      $path = Join-Path $script:tempDir "build.json"
      $buildConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

      $loaded = Get-Content $path -Raw | ConvertFrom-Json
      $sol = $loaded.solutions[0]

      $sol.PSObject.Properties["isPatch"] | Should -BeNullOrEmpty
      $sol.PSObject.Properties["parentSolution"] | Should -BeNullOrEmpty
    }
  }

  Context "post-export version management decision" {
    BeforeAll {
    # -----------------------------------------------------------------------
    # Helper: mirrors the post-export version management decision from
    # export-solutions.yml. Determines whether to bump version directly
    # or clone a new patch.
    # -----------------------------------------------------------------------
    function Get-VersionAction {
      param(
        [object]$Solution,
        [string]$PostExportVersion,
        [string]$PatchPrefix = "(DO NOT USE) "
      )

      $isPatch = $false
      if ($Solution.PSObject.Properties["isPatch"]) {
        $isPatch = [bool]$Solution.isPatch
      }

      if ($isPatch) {
        return @{
          Action     = "ClonePatch"
          OldName    = $Solution.name
          Parent     = $Solution.parentSolution
          NewVersion = $PostExportVersion
          RenamePrefix = $PatchPrefix
        }
      } else {
        return @{
          Action     = "BumpVersion"
          Name       = $Solution.name
          NewVersion = $PostExportVersion
        }
      }
    }
    } # end BeforeAll

    It "returns BumpVersion for non-patch solutions" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }

      $action = Get-VersionAction -Solution $solution -PostExportVersion "2.0.0.0"

      $action.Action | Should -Be "BumpVersion"
      $action.Name | Should -Be "Sol1"
      $action.NewVersion | Should -Be "2.0.0.0"
    }

    It "returns ClonePatch for patch solutions" {
      $solution = [PSCustomObject]@{
        name = "MyPatch"
        version = "1.0.0.1"
        isPatch = $true
        parentSolution = "MyParent"
        displayName = "My Patch"
      }

      $action = Get-VersionAction -Solution $solution -PostExportVersion "2.0.0.0"

      $action.Action | Should -Be "ClonePatch"
      $action.Parent | Should -Be "MyParent"
      $action.NewVersion | Should -Be "2.0.0.0"
      $action.RenamePrefix | Should -Be "(DO NOT USE) "
    }

    It "treats isPatch false same as omitted" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0"; isPatch = $false }

      $action = Get-VersionAction -Solution $solution -PostExportVersion "2.0.0.0"

      $action.Action | Should -Be "BumpVersion"
    }
  }
}
