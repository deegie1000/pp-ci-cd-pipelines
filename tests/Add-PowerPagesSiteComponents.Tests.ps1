BeforeAll {
  $scriptPath = Join-Path $PSScriptRoot "../scripts/Add-PowerPagesSiteComponents.ps1"
}

Describe "Add-PowerPagesSiteComponents" {

  BeforeEach {
    $script:envUrl     = "https://test.crm.dynamics.com"
    $script:solution   = "TestSolution"
    $script:headers    = @{ Authorization = "Bearer test-token" }
    $script:solutionId = "aaaaaaaa-0000-0000-0000-000000000001"
    $script:siteId     = "bbbbbbbb-0000-0000-0000-000000000001"
  }

  # ---------------------------------------------------------------------------
  Context "resolving component type codes" {

    It "exits with error when powerpagesite definition is missing" {
      Mock Invoke-RestMethod {
        return @{ value = @(@{ name = "powerpagecomponent"; solutioncomponenttype = 10002 }) }
      }
      { & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("S1") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers } | Should -Throw
    }

    It "exits with error when powerpagecomponent definition is missing" {
      Mock Invoke-RestMethod {
        return @{ value = @(@{ name = "powerpagesite"; solutioncomponenttype = 10001 }) }
      }
      { & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("S1") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers } | Should -Throw
    }
  }

  # ---------------------------------------------------------------------------
  Context "resolving the target solution" {

    BeforeEach {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponentdefinitions*" } {
        return @{ value = @(
          @{ name = "powerpagesite";      solutioncomponenttype = 10001 },
          @{ name = "powerpagecomponent"; solutioncomponenttype = 10002 }
        )}
      }
    }

    It "exits with error when the target solution is not found" {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/solutions*" } {
        return @{ value = @() }
      }
      { & $scriptPath -SolutionUniqueName "NoSuchSolution" -SiteNames @("S1") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers } | Should -Throw
    }
  }

  # ---------------------------------------------------------------------------
  Context "processing sites" {

    BeforeEach {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponentdefinitions*" } {
        return @{ value = @(
          @{ name = "powerpagesite";      solutioncomponenttype = 10001 },
          @{ name = "powerpagecomponent"; solutioncomponenttype = 10002 }
        )}
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/solutions*" } {
        return @{ value = @(
          @{ solutionid = $script:solutionId; uniquename = "TestSolution"; friendlyname = "Test Solution" }
        )}
      }
      # Table snapshot + post-run check (empty — no inadvertent tables)
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 1" } {
        return @{ value = @() }
      }
    }

    It "exits with error when the site is not found" {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @() }
      }
      { & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("GhostSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers } | Should -Throw
    }

    It "skips adding the site when it is already in solution" {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "TestSite" }) }
      }
      # Site already in solution
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @(@{ objectid = $script:siteId }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } { }

      & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers

      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } -Times 0 -Exactly
    }

    It "adds the site when it is not yet in solution" {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "TestSite" }) }
      }
      # Site not in solution
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } { }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @() }
      }

      & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers

      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } -Times 1 -Exactly
    }

    It "adds only components not already in solution" {
      $compId1 = "cccccccc-0000-0000-0000-000000000001"
      $compId2 = "cccccccc-0000-0000-0000-000000000002"
      $compId3 = "cccccccc-0000-0000-0000-000000000003"

      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "TestSite" }) }
      }
      # Site already in solution — no site add call
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @(@{ objectid = $script:siteId }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @(
          @{ powerpagecomponentid = $compId1; name = "Comp1" },
          @{ powerpagecomponentid = $compId2; name = "Comp2" },
          @{ powerpagecomponentid = $compId3; name = "Comp3" }
        )}
      }
      # compId1 already in solution; compId2 and compId3 are new
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10002*" } {
        return @{ value = @(@{ objectid = $compId1 }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } { }

      & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers

      # Site was skipped (already in solution); only 2 new components added
      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } -Times 2 -Exactly
    }

    It "continues gracefully when site has no components" {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "TestSite" }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } { }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @() }
      }

      { & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers } | Should -Not -Throw
    }
  }

  # ---------------------------------------------------------------------------
  Context "table component cleanup" {

    BeforeEach {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponentdefinitions*" } {
        return @{ value = @(
          @{ name = "powerpagesite";      solutioncomponenttype = 10001 },
          @{ name = "powerpagecomponent"; solutioncomponenttype = 10002 }
        )}
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/solutions*" } {
        return @{ value = @(
          @{ solutionid = $script:solutionId; uniquename = "TestSolution"; friendlyname = "Test Solution" }
        )}
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "TestSite" }) }
      }
      # Site already in solution
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @(@{ objectid = $script:siteId }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @() }
      }
    }

    It "removes table components that were inadvertently added during the run" {
      $newTableId = "dddddddd-0000-0000-0000-000000000001"
      $script:tableCallCount = 0
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 1" } {
        $script:tableCallCount++
        if ($script:tableCallCount -eq 1) {
          return @{ value = @() }                              # Before: no tables
        } else {
          return @{ value = @(@{ objectid = $newTableId }) }  # After: new table appeared
        }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*RemoveSolutionComponent*" } { }

      & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers

      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*RemoveSolutionComponent*" } -Times 1 -Exactly
    }

    It "skips cleanup when no table components were inadvertently added" {
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 1" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*RemoveSolutionComponent*" } { }

      & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers

      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*RemoveSolutionComponent*" } -Times 0 -Exactly
    }
  }

  # ---------------------------------------------------------------------------
  Context "OData pagination" {

    It "follows @odata.nextLink to retrieve all pages of results" {
      $script:pageCallCount = 0
      # First call returns a nextLink; second call returns the rest
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponentdefinitions*" } {
        $script:pageCallCount++
        if ($script:pageCallCount -eq 1) {
          return [PSCustomObject]@{
            value             = @(@{ name = "powerpagesite"; solutioncomponenttype = 10001 })
            "@odata.nextLink" = "https://test.crm.dynamics.com/api/data/v9.2/solutioncomponentdefinitions?page=2"
          }
        } else {
          return @{ value = @(@{ name = "powerpagecomponent"; solutioncomponenttype = 10002 }) }
        }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/solutions*" } {
        return @{ value = @(@{ solutionid = $script:solutionId; uniquename = "TestSolution"; friendlyname = "Test" }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 1" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "TestSite" }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @(@{ objectid = $script:siteId }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @() }
      }

      # Both type codes resolved across two pages — script should not throw
      { & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("TestSite") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers } | Should -Not -Throw

      # The type definition query was made twice: initial page + nextLink page
      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponentdefinitions*" } -Times 2 -Exactly
    }
  }

  # ---------------------------------------------------------------------------
  Context "multiple sites" {

    It "processes each site independently and adds both when neither is in solution" {
      $siteId2 = "bbbbbbbb-0000-0000-0000-000000000002"

      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponentdefinitions*" } {
        return @{ value = @(
          @{ name = "powerpagesite";      solutioncomponenttype = 10001 },
          @{ name = "powerpagecomponent"; solutioncomponenttype = 10002 }
        )}
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/solutions*" } {
        return @{ value = @(@{ solutionid = $script:solutionId; uniquename = "TestSolution"; friendlyname = "Test" }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 1" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" -and $Uri -like "*name eq 'Site1'*" } {
        return @{ value = @(@{ powerpagesiteid = $script:siteId; name = "Site1" }) }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagesites*" -and $Uri -like "*name eq 'Site2'*" } {
        return @{ value = @(@{ powerpagesiteid = $siteId2; name = "Site2" }) }
      }
      # Neither site in solution
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*solutioncomponents*" -and $Uri -like "*componenttype eq 10001*" } {
        return @{ value = @() }
      }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } { }
      Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*powerpagecomponents*" } {
        return @{ value = @() }
      }

      & $scriptPath -SolutionUniqueName $script:solution -SiteNames @("Site1", "Site2") `
          -EnvironmentUrl $script:envUrl -ApiHeaders $script:headers

      # One AddSolutionComponent call per site
      Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like "*AddSolutionComponent*" } -Times 2 -Exactly
    }
  }
}
