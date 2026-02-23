Describe "Deploy ordering and failure isolation" {

  BeforeAll {
  # -----------------------------------------------------------------------
  # Helper: simulates the deploy loop from deploy-environment.yml.
  # Takes solutions, installed versions, and a set of solutions that will
  # "fail" import. Returns the deploy summary with order tracking.
  # -----------------------------------------------------------------------
  function Invoke-SimulatedDeploy {
    param(
      [array]$Solutions,
      [hashtable]$InstalledSolutions,
      [string[]]$FailingSolutions = @()
    )

    $failedSolutions  = @()
    $skippedSolutions = @()
    $deployedSolutions = @()
    $deployOrder = @()

    foreach ($solution in $Solutions) {
      $name    = $solution.name
      $version = $solution.version

      # Check if already installed at this version
      if ($InstalledSolutions.ContainsKey($name)) {
        $installedVersion = $InstalledSolutions[$name]
        if ($installedVersion -eq $version) {
          $skippedSolutions += $name
          continue
        }
      }

      # Track that we attempted this solution (in order)
      $deployOrder += $name

      # Simulate import — check if this solution is in the "failing" set
      if ($name -in $FailingSolutions) {
        $failedSolutions += $name
        continue
      }

      $deployedSolutions += $name
    }

    return @{
      Deployed    = $deployedSolutions
      Skipped     = $skippedSolutions
      Failed      = $failedSolutions
      DeployOrder = $deployOrder
      Total       = $Solutions.Count
      HasFailures = ($failedSolutions.Count -gt 0)
    }
  }
  } # end BeforeAll

  Context "deploy order matches build.json order" {
    It "deploys solutions in the exact order specified in build.json" {
      $solutions = @(
        [PSCustomObject]@{ name = "CoreComponents"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "CustomConnectors"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "MainApp"; version = "1.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed

      $result.DeployOrder | Should -HaveCount 3
      $result.DeployOrder[0] | Should -Be "CoreComponents"
      $result.DeployOrder[1] | Should -Be "CustomConnectors"
      $result.DeployOrder[2] | Should -Be "MainApp"
    }

    It "skipped solutions do not appear in deploy order" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" },
        [PSCustomObject]@{ name = "Sol3"; version = "3.0.0.0" }
      )
      $installed = @{ "Sol2" = "2.0.0.0" }  # Sol2 already at target

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed

      $result.DeployOrder | Should -HaveCount 2
      $result.DeployOrder[0] | Should -Be "Sol1"
      $result.DeployOrder[1] | Should -Be "Sol3"
      $result.Skipped | Should -Contain "Sol2"
    }
  }

  Context "failure isolation" {
    It "continues deploying remaining solutions after a failure" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" },
        [PSCustomObject]@{ name = "Sol3"; version = "3.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed -FailingSolutions @("Sol2")

      $result.Deployed | Should -HaveCount 2
      $result.Deployed | Should -Contain "Sol1"
      $result.Deployed | Should -Contain "Sol3"
      $result.Failed | Should -HaveCount 1
      $result.Failed | Should -Contain "Sol2"
    }

    It "reports failure even when first solution fails" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed -FailingSolutions @("Sol1")

      $result.Deployed | Should -Contain "Sol2"
      $result.Failed | Should -Contain "Sol1"
      $result.HasFailures | Should -Be $true
    }

    It "reports failure even when last solution fails" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed -FailingSolutions @("Sol2")

      $result.Deployed | Should -Contain "Sol1"
      $result.Failed | Should -Contain "Sol2"
      $result.HasFailures | Should -Be $true
    }

    It "handles multiple failures" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" },
        [PSCustomObject]@{ name = "Sol3"; version = "3.0.0.0" },
        [PSCustomObject]@{ name = "Sol4"; version = "4.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed -FailingSolutions @("Sol1", "Sol3")

      $result.Failed | Should -HaveCount 2
      $result.Deployed | Should -HaveCount 2
      $result.Deployed | Should -Contain "Sol2"
      $result.Deployed | Should -Contain "Sol4"
    }
  }

  Context "summary counts" {
    It "correctly counts deployed, skipped, and failed" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },  # Will deploy
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" },  # Will skip (installed)
        [PSCustomObject]@{ name = "Sol3"; version = "3.0.0.0" },  # Will fail
        [PSCustomObject]@{ name = "Sol4"; version = "4.0.0.0" }   # Will deploy
      )
      $installed = @{ "Sol2" = "2.0.0.0" }

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed -FailingSolutions @("Sol3")

      $result.Total | Should -Be 4
      $result.Deployed | Should -HaveCount 2
      $result.Skipped | Should -HaveCount 1
      $result.Failed | Should -HaveCount 1
      # Verify: deployed + skipped + failed = total
      ($result.Deployed.Count + $result.Skipped.Count + $result.Failed.Count) | Should -Be $result.Total
    }

    It "reports HasFailures as false when no failures occur" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed

      $result.HasFailures | Should -Be $false
    }

    It "all skipped produces zero deployed and zero failed" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      $installed = @{
        "Sol1" = "1.0.0.0"
        "Sol2" = "2.0.0.0"
      }

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed

      $result.Deployed | Should -HaveCount 0
      $result.Skipped | Should -HaveCount 2
      $result.Failed | Should -HaveCount 0
      $result.HasFailures | Should -Be $false
    }
  }

  Context "mixed skip and failure" {
    It "a skipped solution is never counted as failed" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      )
      # Sol1 is at target version — should skip, not fail
      $installed = @{ "Sol1" = "1.0.0.0" }

      $result = Invoke-SimulatedDeploy -Solutions $solutions -InstalledSolutions $installed -FailingSolutions @("Sol1")

      $result.Skipped | Should -Contain "Sol1"
      $result.Failed | Should -Not -Contain "Sol1"
    }
  }
}
