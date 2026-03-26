# Local Power Platform Scripts

Run the export and deploy pipelines locally without ADO. No service principal credentials required — authentication is done interactively via browser.

## Prerequisites

- [pac CLI](https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction) — `dotnet tool install --global Microsoft.PowerApps.CLI.Tool`
- [Az.Accounts PowerShell module](https://learn.microsoft.com/en-us/powershell/module/az.accounts) — `Install-Module Az.Accounts -Scope CurrentUser`

## Quick Start

**GUI (recommended):**
```powershell
.\local\Local-UI.ps1
```

**Command line:**
```powershell
.\local\Run-Local.ps1
```

## Folder Structure

```
local/
  logs/                           # Log files written by Local-UI.ps1 (auto-created)
    {timestamp}_{mode}_{subfolder}.log
  exports/                        # Your export configs — one subfolder per build
    sample/                       # Reference example (do not use directly)
      build.json
      configdata/
    {your-subfolder}/             # Copy of sample, renamed for your build
      build.json
      deploymentSettings_Test.json
      deploymentSettings_Stage.json
      deploymentSettings_Prod.json
      configdata/
  solutions/                      # Generated output — do not edit manually
    unmanaged/                    # Unmanaged zips exported from Dev
    unpacked/                     # Unpacked solution source
    managed/                      # Managed zips — input to Deploy-Solutions.ps1
  deploymentSettings/             # Sample deployment settings files
    deploymentSettings_sample.json
  Export-Solutions.ps1
  Deploy-Solutions.ps1
  Run-Local.ps1
  Local-UI.ps1
  README.md
```

> `solutions/` is generated output from `Export-Solutions.ps1`. You only need to create and manage the `exports/{subfolder}/` folders.

## Scripts

### `Local-UI.ps1` — GUI entry point

WinForms GUI. Select mode, fill in URLs, pick a subfolder, and hit Run. Output streams in near real-time with color coding (errors in red, warnings in orange, successes in green). Each run writes a log file to `local/logs/` named `{timestamp}_{mode}_{subfolder}.log`.

```powershell
.\local\Local-UI.ps1
```

### `Run-Local.ps1` — command-line entry point

Prompts for a mode and coordinates the other scripts. When running Export + Deploy, the subfolder is selected once and shared between both.

```powershell
.\local\Run-Local.ps1           # interactive
.\local\Run-Local.ps1 -DryRun   # validate deploy without importing anything
```

**Modes:**

| # | Mode | What it does |
|---|------|---|
| 1 | Export only | Exports solutions from Dev into `local/solutions/` |
| 2 | Deploy only | Deploys managed zips from `local/solutions/managed/` to a target environment |
| 3 | Export + Deploy | Runs export then deploy in sequence |

### `Export-Solutions.ps1` — mirrors `export-solutions.yml`

Exports solutions from a Power Platform Dev environment into `local/solutions/`. Skips git, PR, and artifact publishing steps.

```powershell
.\local\Export-Solutions.ps1
.\local\Export-Solutions.ps1 -EnvironmentUrl https://yourorg.crm.dynamics.com
```

**What it does:**
- Authenticates to Dev interactively via `pac auth create`
- For each solution in `build.json`: exports unmanaged, unpacks, exports managed
- Detects cloud flows and patch solutions; updates `build.json` accordingly
- Skips re-export if a managed zip for the same name + version already exists (caching)
- Extracts config data from Dev if `configData` is defined in `build.json`
- Runs post-export version management: bumps solution versions in Dev via `CloneAsSolution` or `CloneAsPatch` for any solution with `postExportVersion` set (failures warn but do not stop the script)

### `Deploy-Solutions.ps1` — mirrors `release-solutions-test.yml` + `deploy-environment.yml`

Deploys managed solutions from `local/solutions/managed/` to any target environment.

```powershell
.\local\Deploy-Solutions.ps1
.\local\Deploy-Solutions.ps1 -EnvironmentUrl https://yourtest.crm.dynamics.com
.\local\Deploy-Solutions.ps1 -EnvironmentUrl https://yourtest.crm.dynamics.com -SettingsKey Prod
.\local\Deploy-Solutions.ps1 -EnvironmentUrl https://yourtest.crm.dynamics.com -DryRun
```

| Parameter | Default | Description |
|---|---|---|
| `-EnvironmentUrl` | _(prompted)_ | Target environment URL |
| `-SettingsKey` | `Test` | Which `deploymentSettings_{key}.json` to use |
| `-DryRun` | `false` | Validates and logs what would happen without importing |

**What it does:**
- Validates all managed zips and deployment settings files exist before starting
- Authenticates to the target environment interactively via `pac auth create`
- Skips solutions already installed at the target version
- Respects `deployMode` per solution (see `build.json` reference below)
- Activates cloud flows after import
- Upserts config data if `configData` is defined in `build.json`

## Setting Up an Export Subfolder

1. Create a subfolder under `local/exports/` named for your build (e.g. `2025-03-25-myfeature`)
2. Add a `build.json` — see `local/exports/sample/build.json` for a full annotated example
3. If any solution has `"includeDeploymentSettings": true`, add a `deploymentSettings_{SettingsKey}.json` in the same subfolder — see `local/deploymentSettings/deploymentSettings_sample.json` for the format

Minimal `build.json`:

```json
{
  "solutions": [
    {
      "name": "MySolution",
      "version": "1.2.0.0"
    }
  ]
}
```

## build.json Reference

### Solution fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Solution unique name |
| `version` | string | Version to export/deploy (must match the Dev environment) |
| `deployMode` | `"upgrade"` \| `"update"` | Controls import strategy (see below). Default: `"upgrade"` |
| `includeDeploymentSettings` | bool | If `true`, passes `deploymentSettings_{SettingsKey}.json` to the import |
| `postExportVersion` | string | After export, bumps the solution in Dev to this version. Uses `CloneAsSolution` unless `createNewPatch` is `true` |
| `createNewPatch` | bool | If `true`, creates a new patch in Dev at `postExportVersion` via `CloneAsPatch` instead of cloning the solution. Ignored if `postExportVersion` is not set |
| `isExisting` | bool | If `true`, skips export and uses a pre-built zip already in `local/solutions/managed/`. Also skips post-export version management |
| `isRollback` | bool | If `true`, disables the version guard to allow importing a lower version. Also skips post-export version management |
| `powerPagesConfiguration` | object | Power Pages-specific options (see below). Its `deployMode` takes precedence over the top-level one |

### `deployMode` values

| Value | Behavior |
|---|---|
| `"upgrade"` _(default)_ | Uses `--stage-and-upgrade --skip-lower-version` when installing over an existing version |
| `"update"` | Standard import — no staged upgrade. Use when the solution does not support staged upgrades |

`isRollback: true` overrides `deployMode` and always skips staged upgrade regardless of the value set.

### `powerPagesConfiguration` fields

| Field | Description |
|---|---|
| `deployMode` | `UPGRADE`, `UPDATE`, or `STAGE_FOR_UPGRADE` — maps directly to pac import flags |
| `addAllExistingSiteComponentsForSites` | Comma-separated site names to add all existing site components to the solution before export |

### `configData` fields

| Field | Description |
|---|---|
| `name` | Friendly label for logging |
| `entity` | Dataverse entity logical name |
| `primaryKey` | Primary key column logical name (used for upsert matching) |
| `select` | Comma-separated columns to extract |
| `filter` | OData `$filter` expression (optional) |
| `dataFile` | Path to the JSON data file, relative to the export subfolder |

## Authentication

Both scripts authenticate twice — once for `pac` (solution import/export) and once for the Dataverse REST API (cloud flow activation, config data, Power Pages site components):

| Auth | Used for | How |
|---|---|---|
| `pac auth create` | Solution export/import, `pac solution list` | Interactive browser login |
| `Connect-AzAccount` + `Get-AzAccessToken` | Dataverse REST API calls | Interactive browser login via Az module |

If you're already signed into Azure (`Get-AzContext`), the scripts will ask if you want to reuse the existing session.
