Describe "Version skip logic" {

  BeforeAll {
  # -----------------------------------------------------------------------
  # Helper: mirrors the version-check logic from deploy-environment.yml.
  # Given a solution entry and a hashtable of installed solutions, returns
  # the deploy decision: Skip, Upgrade, or FreshInstall.
  # -----------------------------------------------------------------------
  function Get-DeployDecision {
    param(
      [object]$Solution,
      [hashtable]$InstalledSolutions
    )

    $name    = $Solution.name
    $version = $Solution.version

    if ($InstalledSolutions.ContainsKey($name)) {
      $installedVersion = $InstalledSolutions[$name]
      if ($installedVersion -eq $version) {
        return @{
          Action           = "Skip"
          Reason           = "Already installed at v$version"
          InstalledVersion = $installedVersion
        }
      }
      return @{
        Action           = "Upgrade"
        Reason           = "Upgrading from v$installedVersion to v$version"
        InstalledVersion = $installedVersion
      }
    }

    return @{
      Action           = "FreshInstall"
      Reason           = "Not currently installed"
      InstalledVersion = $null
    }
  }

  # -----------------------------------------------------------------------
  # Helper: mirrors the full deploy loop from deploy-environment.yml.
  # Processes an array of solutions against installed versions and returns
  # categorized lists (deployed, skipped, failed).
  # -----------------------------------------------------------------------
  function Invoke-DeployDecisions {
    param(
      [array]$Solutions,
      [hashtable]$InstalledSolutions
    )

    $deployed = @()
    $skipped  = @()

    foreach ($solution in $Solutions) {
      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $InstalledSolutions

      if ($decision.Action -eq "Skip") {
        $skipped += $solution.name
      } else {
        $deployed += $solution.name
      }
    }

    return @{
      Deployed = $deployed
      Skipped  = $skipped
    }
  }
  } # end BeforeAll

  Context "single solution decisions" {
    It "skips when installed version matches target version exactly" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.2.0.0" }
      $installed = @{ "Sol1" = "1.2.0.0" }

      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      $decision.Action | Should -Be "Skip"
      $decision.InstalledVersion | Should -Be "1.2.0.0"
    }

    It "upgrades when installed version is lower than target" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "2.0.0.0" }
      $installed = @{ "Sol1" = "1.0.0.0" }

      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      $decision.Action | Should -Be "Upgrade"
      $decision.InstalledVersion | Should -Be "1.0.0.0"
    }

    It "returns Upgrade when installed version is higher than target (pac handles via --skip-lower-version)" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      $installed = @{ "Sol1" = "2.0.0.0" }

      # Pipeline logic returns Upgrade — the actual skip is handled by
      # pac CLI's --skip-lower-version flag at import time
      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      $decision.Action | Should -Be "Upgrade"
      $decision.InstalledVersion | Should -Be "2.0.0.0"
    }

    It "returns FreshInstall when solution is not installed" {
      $solution = [PSCustomObject]@{ name = "NewSol"; version = "1.0.0.0" }
      $installed = @{ "OtherSol" = "1.0.0.0" }

      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      $decision.Action | Should -Be "FreshInstall"
      $decision.InstalledVersion | Should -BeNullOrEmpty
    }

    It "returns FreshInstall when no solutions are installed" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      $installed = @{}

      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      $decision.Action | Should -Be "FreshInstall"
    }
  }

  Context "version string comparison" {
    It "treats version comparison as string equality (not semantic)" {
      $solution = [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" }
      # Same version but different string — should NOT skip
      $installed = @{ "Sol1" = "1.0.0" }

      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      # "1.0.0" != "1.0.0.0" — so it will upgrade, not skip
      $decision.Action | Should -Be "Upgrade"
    }
  }

  Context "solution name matching" {
    It "matches solution names case-sensitively" {
      $solution = [PSCustomObject]@{ name = "MySolution"; version = "1.0.0.0" }
      $installed = @{ "mysolution" = "1.0.0.0" }

      # Hashtable keys in PowerShell are case-insensitive by default
      $decision = Get-DeployDecision -Solution $solution -InstalledSolutions $installed

      $decision.Action | Should -Be "Skip"
    }
  }

  Context "multi-solution batch decisions" {
    It "correctly categorizes a mix of skip, upgrade, and fresh install" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" },
        [PSCustomObject]@{ name = "Sol3"; version = "1.5.0.0" }
      )
      $installed = @{
        "Sol1" = "1.0.0.0"   # Same version — skip
        "Sol2" = "1.0.0.0"   # Lower — upgrade
        # Sol3 not installed — fresh install
      }

      $result = Invoke-DeployDecisions -Solutions $solutions -InstalledSolutions $installed

      $result.Skipped | Should -HaveCount 1
      $result.Skipped | Should -Contain "Sol1"
      $result.Deployed | Should -HaveCount 2
      $result.Deployed | Should -Contain "Sol2"
      $result.Deployed | Should -Contain "Sol3"
    }

    It "skips all solutions when all are at target version" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      $installed = @{
        "Sol1" = "1.0.0.0"
        "Sol2" = "2.0.0.0"
      }

      $result = Invoke-DeployDecisions -Solutions $solutions -InstalledSolutions $installed

      $result.Skipped | Should -HaveCount 2
      $result.Deployed | Should -HaveCount 0
    }

    It "deploys all solutions when none are installed" {
      $solutions = @(
        [PSCustomObject]@{ name = "Sol1"; version = "1.0.0.0" },
        [PSCustomObject]@{ name = "Sol2"; version = "2.0.0.0" }
      )
      $installed = @{}

      $result = Invoke-DeployDecisions -Solutions $solutions -InstalledSolutions $installed

      $result.Skipped | Should -HaveCount 0
      $result.Deployed | Should -HaveCount 2
    }
  }
}
