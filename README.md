# Power Platform CI/CD Pipelines

Azure DevOps pipelines for exporting, versioning, and deploying Power Platform solutions across environments.

> **New to this repo?** See [TLDR.md](./TLDR.md) for a plain-English guide on how to use the pipelines.

## Contents

- [Repository Structure](#repository-structure)
- [Pipeline Overview](#pipeline-overview)
- [Pipelines](#pipelines)
  - [1. Daily Export Solutions](#1-daily-export-solutions-pipelinesexport-solutionsyml)
  - [2. Release Solutions](#2-release-solutions-pipelinesrelease-solutionsyml)
  - [3. Release Ad-Hoc](#3-release-ad-hoc-pipelinesrelease-adhocyml)
  - [4. Export Solution from Pre-Dev](#4-export-solution-from-pre-dev-pipelinesexport-solution-predevyml)
  - [5. Deploy Solution (Dev)](#5-deploy-solution-pipelinesdeploy-solutionyml)
  - [6. Export for New Dev](#6-export-for-new-dev-pipelinesexport-to-newdevyml)
  - [7. Deploy to New Dev](#7-deploy-to-new-dev-pipelinesdeploy-to-newdevyml)
- [Pipeline Flow](#pipeline-flow)
  - [Daily Export + Release](#daily-export--release-dev--qa--stage--prod)
  - [Pre-Dev Promotion](#pre-dev-promotion-on-demand)
  - [Architecture Overview](#architecture-overview)
- [build.json Configuration](#buildjson-configuration)
  - [Solutions Fields](#solutions-fields)
  - [Config Data Fields](#config-data-fields)
  - [Deployment Settings](#deployment-settings)
  - [Post-Export Version Management](#post-export-version-management)
  - [Configuration Data](#configuration-data)
- [Testing](#testing)
- [ADO Setup](#ado-setup)
  - [Prerequisites](#prerequisites)
  - [Step 1: Install Power Platform Build Tools](#step-1-install-the-power-platform-build-tools-extension)
  - [Step 2: Register an App in Entra ID](#step-2-register-an-app-in-entra-id-azure-ad)
  - [Step 3: Create Service Connections](#step-3-create-power-platform-service-connections)
  - [Step 4: Create Variable Groups](#step-4-create-variable-groups-release--deploy-pipelines)
  - [Step 5: Create ADO Environments](#step-5-create-ado-environments-release--deploy-pipelines)
  - [Step 6: Create the Pipelines](#step-6-create-the-pipelines)
  - [Step 7: Link Variable Groups to Pipelines](#step-7-link-variable-groups-to-pipelines)
  - [Step 8: Update Pipeline Variables](#step-8-update-pipeline-variables)
  - [Step 9: Grant Repository Permissions](#step-9-grant-repository-permissions)
- [How to Execute](#how-to-execute)
  - [Daily Export Solutions](#daily-export-solutions-scheduled)
  - [Release Pipeline](#release-pipeline-automatic--manual-approval)
  - [Release Ad-Hoc](#release-ad-hoc-manual)
  - [Export from Pre-Dev + Deploy](#export-from-pre-dev--deploy-on-demand)
  - [Deploy Solution](#deploy-solution-manual)
  - [Verifying Results](#verifying-results)
- [Changing the Schedule](#changing-the-schedule)
- [Troubleshooting](#troubleshooting)

---

## Repository Structure

```
pp-ci-cd-pipelines/
├── pipelines/
│   ├── export-solutions.yml             # Daily scheduled export (Dev → repo)
│   ├── release-solutions.yml            # Release pipeline (QA → Stage → Prod)
│   ├── release-adhoc.yml                # Ad-hoc release to any environment
│   ├── export-solution-predev.yml       # On-demand single solution export (Pre-Dev)
│   ├── deploy-solution.yml              # Deploy single solution to Dev (triggered by pre-dev export)
│   ├── export-to-newdev.yml             # Manual export from Dev to seed a New Dev environment
│   ├── deploy-to-newdev.yml             # Manual deploy to a New Dev environment
│   └── templates/
│       └── deploy-environment.yml        # Reusable deploy template (used by release pipelines)
├── deploymentSettings/
│   ├── preDev/                              # Deployment settings for Pre-Dev exports
│   │   ├── deploymentSettings_Dev.json      #   Applied when deploying to Dev
│   │   └── deploymentSettings_PreDev.json   #   Settings for the Pre-Dev environment itself
│   ├── deploymentSettings_Dev.json          # Accumulated deployment settings for Dev (daily export)
│   ├── deploymentSettings_QA.json           # Accumulated deployment settings for QA (daily export)
│   ├── deploymentSettings_Stage.json        # Accumulated deployment settings for Stage (daily export)
│   └── deploymentSettings_Prod.json         # Accumulated deployment settings for Prod (daily export)
├── exports/
│   ├── {yyyy-MM-dd-token}/              # Daily export (export/yyyy-MM-dd-{token} branches)
│   └── {token}/                         # New Dev export (export/{token} branches)
│       ├── build.json                   # Export configuration for that run
│       ├── configdata/                  # Extracted configuration data (populated by export)
│       │   └── {DataSetName}.json       #   One file per configData entry in build.json
│       ├── deploymentSettings_QA.json   # Deployment settings for QA (optional)
│       ├── deploymentSettings_Stage.json # Deployment settings for Stage (optional)
│       └── deploymentSettings_Prod.json  # Deployment settings for Prod (optional)
├── scripts/
│   ├── Merge-DeploymentSettings.ps1     # Merges export settings into root folder
│   └── Sync-ConfigData.ps1             # Extracts/upserts configuration data via Dataverse API
├── tests/
│   ├── Merge-DeploymentSettings.Tests.ps1  # Pester tests for merge logic
│   ├── Build-Json-Validation.Tests.ps1     # Pester tests for build.json validation
│   ├── Cloud-Flow-Detection.Tests.ps1      # Pester tests for cloud flow detection
│   ├── Deploy-Dev-Settings.Tests.ps1       # Pester tests for Pre-Dev → Dev settings
│   └── Config-Data-Validation.Tests.ps1   # Pester tests for config data schema + serialization
├── solutions/
│   ├── unpacked/{SolutionName}/         # Unpacked solution source files
│   ├── unmanaged/{SolutionName}_v.zip   # Versioned unmanaged solution zips
│   └── managed/{SolutionName}_v.zip     # Versioned managed solution zips
└── README.md
```

---

## Pipeline Overview

| # | Pipeline | Trigger | Purpose |
|---|----------|---------|---------|
| 1 | [Daily Export Solutions](#1-daily-export-solutions) | Scheduled (10 PM ET) or manual | Export from Dev, validate versions, export managed, PR to main |
| 2 | [Release Solutions](#2-release-solutions) | Auto (on export completion) | Deploy managed solutions through QA → Stage → Prod |
| 3 | [Release Ad-Hoc](#3-release-ad-hoc) | Manual | Deploy any export run to a named environment and variable group |
| 4 | [Export from Pre-Dev](#4-export-solution-from-pre-dev) | Manual | Export single solution from Pre-Dev, commit, trigger Dev deploy |
| 5 | [Deploy Solution (Dev)](#5-deploy-solution) | Auto (on Pre-Dev export) | Deploy managed solution into Dev |
| 6 | [Export for New Dev](#6-export-for-new-dev) | Manual | Export solutions from Dev to seed a new Dev environment (supports `isUnmanaged`) |
| 7 | [Deploy to New Dev](#7-deploy-to-new-dev) | Manual | Deploy the New Dev artifact into a fresh New Dev environment |

---

## Pipelines

### 1. Daily Export Solutions (`pipelines/export-solutions.yml`)

Exports solutions from the Power Platform **Dev** environment on a daily schedule, validates their versions against `build.json`, unpacks them into source control, exports managed solutions directly from Power Platform, and creates a PR to merge into `main`. Optionally bumps solution versions in Dev after export to prepare for the next development cycle.

**What it does:**

1. Detects a Git branch matching `export/{today's date}-{token}` (e.g., `export/2026-02-15-sprint42`)
2. Reads `exports/{date-token}/build.json` on that branch for the list of solutions and their expected versions
3. For each solution:
   - If `isExisting: true`, skips all export/unpack steps and uses a pre-existing zip already in the repo. If `isUnmanaged: true`, reads from `solutions/unmanaged/{name}_{version}.zip`; otherwise reads from `solutions/managed/{name}_{version}.zip`. Fails if the expected zip is not found.
   - Checks if a managed zip already exists for this name + version (cache check &mdash; skips if so)
   - Exports the **unmanaged** solution zip from Power Platform &rarr; `solutions/unmanaged/`
   - Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/`
   - **Detects [cloud flows](https://learn.microsoft.com/en-us/power-automate/overview-cloud)**: checks for `.json` files in the unpacked `Workflows/` directory. If found, sets `includesCloudFlows: true` on the solution entry in `build.json`
   - **Validates the version**: reads the actual version from `Other/Solution.xml` and compares it to `build.json`. If they don't match, the pipeline **fails** with an error
   - Exports the **managed** solution directly from Power Platform &rarr; `solutions/managed/`
4. Writes the updated `build.json` (with the auto-detected `includesCloudFlows` flag) and publishes it along with managed zips, config data files, and any `deploymentSettings_*.json` files as pipeline artifacts (consumed by the release pipeline)
5. **Extracts configuration data** &mdash; if `configData` is defined in `build.json`, queries each data set from Dev using OData `$select`/`$filter`, writes the results as JSON to `configdata/` inside the export folder (alongside `build.json`), and includes them in the artifact. See [Configuration Data](#configuration-data) for details.
6. **Post-export version management** &mdash; for each solution that has a `postExportVersion` defined in `build.json`, bumps that solution's version in the Dev environment after export. Solutions with `createNewPatch: true` have a new patch cloned from themselves at the new version via the Dataverse `CloneAsPatch` action; solutions with `createNewPatch: false` (or unset) get a direct version update via `pac solution online-version`. See [Post-Export Version Management](#post-export-version-management) for details.
7. **Merges deployment settings** &mdash; if `deploymentSettings_*.json` files exist in the export folder, merges them into the root `deploymentSettings/` folder. Items from the export overwrite matching items in root (matched by `SchemaName` for environment variables, `LogicalName` for connection references); new items are appended. See [Deployment Settings](#deployment-settings) for details.
8. Commits solution files, config data (in the export folder), and merged deployment settings, then pushes to the export branch
9. Creates a Pull Request to `main`, sets auto-complete (squash merge), and deletes the source branch

**Version validation:** During export, the `build.json` file is the source of truth for expected versions. If a solution's version in the Dev environment doesn't match what's in `build.json`, the pipeline fails immediately with a message like:

```
Version mismatch for 'MySolution': build.json specifies v1.0.0.0 but dev environment has v1.1.0.0.
Update build.json to match the dev environment before re-running.
```

If `postExportVersion` is set, the pipeline bumps versions in Dev **after** the export and artifact publishing are complete. This does not affect the exported artifacts &mdash; they retain the original versions from `build.json`.

**Trigger:** Daily at **10:00 PM Eastern Time** (3:00 AM UTC). Also runnable manually with an optional branch override.

**Parameters (manual runs):**

| Parameter | Description |
|---|---|
| `exportBranch` | Override export branch name (skip auto-detect). Leave blank or type `default` to auto-detect from today's date. |

**Auth:** Uses pac CLI with secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`).

**Artifact published:** `ManagedSolutions` &mdash; contains `build.json`, `{SolutionName}_{version}.zip` files, and any `deploymentSettings_*.json` files present in the export folder.

---

### 2. Release Solutions (`pipelines/release-solutions.yml`)

Deploys managed solutions through three environments in sequence: **QA &rarr; Stage &rarr; Prod**. Triggers automatically when the daily export pipeline completes on `main`.

**What it does (per stage):**

1. Downloads the `ManagedSolutions` artifact from the export pipeline
2. **Validates all artifacts upfront** &mdash; checks that every `{name}_{version}.zip` (and required `deploymentSettings_{stage}.json`) exists before importing anything. Fails immediately if any are missing
3. Authenticates with the target environment using credentials from a per-environment variable group
4. Queries all installed solutions in the target environment using `pac solution list`
5. For each solution in `build.json` (in order):
   - **Skip** &mdash; if the solution is already installed at the target version
   - **Fresh install** &mdash; if the solution doesn't exist in the target environment: imports with `--activate-plugins`
   - **Upgrade (managed)** &mdash; if the solution exists at a different version and `isUnmanaged` is not set: imports with `--stage-and-upgrade --skip-lower-version --activate-plugins`
   - **Unmanaged import** &mdash; if `isUnmanaged: true`: imports directly without `--stage-and-upgrade`, regardless of whether the solution is already installed. Use this when the artifact zip is an unmanaged solution.
   - If the solution has `includeDeploymentSettings: true` in `build.json`, applies the matching `deploymentSettings_{stage}.json` file via `--settings-file`
   - If the solution has `includesCloudFlows: true`, checks for inactive cloud flows after import and attempts to activate them. Activation failures are logged as **warnings** but do not fail the deployment
6. **Upserts configuration data** &mdash; if `configData` is defined in `build.json`, PATCHes each record into the target environment using stable GUIDs. Record-level failures are logged as **warnings** but do not fail the deployment. See [Configuration Data](#configuration-data)
7. Fails the stage if any solution fails to deploy

**Stages:**

| Stage | Deploys To | Trigger | Approval Required |
|---|---|---|---|
| **QA** | QA environment | Automatic (on export completion) | No |
| **Stage** | Stage environment | After QA succeeds | **Yes** &mdash; manual approval |
| **Prod** | Prod environment | After Stage succeeds | **Yes** &mdash; manual approval |

Stage and Prod approvals are controlled by **ADO Environment approval checks** (not pipeline gates). See [Step 5: Create ADO Environments](#step-5-create-ado-environments-release-pipeline) for setup.

**Trigger:** Automatic &mdash; runs when the `export-solutions` pipeline completes on the `main` branch. See [pipeline completion triggers](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/pipeline-triggers) on Microsoft Learn.

**Variables (manual runs):**

| Variable | Default | Description |
|---|---|---|
| `dryRun` | `"false"` | Set to `"true"` in the Variables section of the Run pipeline dialog to validate without importing any solutions or upserting config data. Safe to run at any time against any environment. |

**Auth:** Uses pac CLI with credentials from variable groups (`PowerPlatform-QA`, `PowerPlatform-Stage`, `PowerPlatform-Prod`).

**Template:** Uses `pipelines/templates/deploy-environment.yml` for each stage to keep the logic DRY.

---

### 3. Release Ad-Hoc (`pipelines/release-adhoc.yml`)

Manually triggered pipeline that deploys solutions from **any completed `export-solutions` run** into a **named environment and variable group**. Use this for environments outside the standard QA → Stage → Prod chain — such as sandboxes, UAT, or hotfix environments.

**What it does:**

1. Downloads the `ManagedSolutions` artifact from the selected export run
2. Validates all artifacts, authenticates, queries installed solutions, and deploys using the same logic as [Release Solutions](#2-release-solutions)
3. Applies `deploymentSettings_{variableGroup}.json` from the artifact if present (e.g., `deploymentSettings_PowerPlatform-Sandbox.json`)

**Parameters:**

| Parameter | Description |
|---|---|
| `environmentName` | The ADO Environment name to deploy into (e.g., `Power Platform Sandbox`). Must exist in your ADO project. |
| `variableGroup` | The library variable group containing credentials for the target environment (e.g., `PowerPlatform-Sandbox`). Also used as the deployment settings file key. |

**Trigger:** Manual only &mdash; no auto-trigger.

**Auth:** Uses credentials from the variable group specified at runtime.

**Template:** Uses `pipelines/templates/deploy-environment.yml`.

---

### 4. Export Solution from Pre-Dev (`pipelines/export-solution-predev.yml`)

On-demand pipeline that exports a **single solution** from the **Pre-Dev** environment and promotes it through the build process.

**What it does:**

1. Authenticates pac CLI with the Pre-Dev environment using credentials from the `PowerPlatform-PreDev` variable group
2. Exports the specified solution as **unmanaged** from Pre-Dev using `pac solution export` &rarr; `solutions/unmanaged/{name}.zip`
3. Performs a **clean unpack** using `pac solution unpack` (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/{name}/`; reads the version from `Other/Solution.xml` and renames the unmanaged zip to `{name}_{version}.zip`
4. Exports the **managed** solution directly from Pre-Dev using `pac solution export --managed` &rarr; `solutions/managed/{name}_{version}.zip`
5. Creates a timestamped branch `export/predev/{yyyy-MM-dd-HHmmss}`, commits the solution files, and pushes to that branch
6. Creates a Pull Request from the export branch to `main`, sets auto-complete (squash merge), and deletes the source branch
7. Publishes the managed zip and `deploymentSettings_Dev.json` from `deploymentSettings/preDev/` as a pipeline artifact
8. **Automatically triggers** the Deploy Solution pipeline (Dev only)

**Trigger:** Manual only (run on demand from the ADO UI).

**Auth:** Uses pac CLI with credentials from the `PowerPlatform-PreDev` variable group. Does not require Power Platform Build Tools — all operations use pac CLI directly.

---

### 5. Deploy Solution (`pipelines/deploy-solution.yml`)

Deploys a single managed solution into the **Dev** environment. Runs automatically after the Pre-Dev export pipeline completes, or can be triggered manually. For promotion to QA, Stage, and Prod, use the [Release Ad-Hoc](#3-release-ad-hoc-pipelinesrelease-adhocyml) pipeline against an `export-solutions` artifact.

**What it does:**

1. Downloads the managed solution artifact from the Pre-Dev export pipeline (auto-triggered) or uses `solutions/managed/{name}.zip` from the repo (manual)
2. Authenticates with Dev using credentials from the `PowerPlatform-Dev` variable group
3. Checks for `deploymentSettings_Dev.json` &mdash; in the artifact (auto-triggered) or in `deploymentSettings/preDev/` (manual)
4. Imports the managed solution into Dev, applying deployment settings if found. If `build.json` is present in the artifact and the solution has `isRollback: true`, `--skip-lower-version` is omitted so a lower version can overwrite a higher one
5. **Upserts configuration data** &mdash; if `build.json` is present in the artifact and contains `configData`, PATCHes each record into Dev. See [Configuration Data](#configuration-data)

**Trigger:** Automatic (on completion of the Pre-Dev export pipeline) or manual with a `solutionName` parameter.

**Parameters (manual runs):**

| Parameter | Default | Description |
|---|---|---|
| `solutionName` | `""` | The solution's unique name as it appears in Power Platform. Required for manual runs; ignored for auto-triggered runs. |
| `dryRun` | `false` | When `true`, authenticates, queries the installed solution version, and logs exactly what *would* be imported — but performs no imports and no config data upserts. |

**Auth:** Uses pac CLI with credentials from the `PowerPlatform-Dev` variable group.

---

### 6. Export for New Dev (`pipelines/export-to-newdev.yml`)

Manual pipeline used to **seed or refresh a New Dev environment**. Checks out a specified export branch, exports solutions from Dev (respecting the `isUnmanaged` flag per solution), extracts config data, commits back to the export branch, opens a PR to `main`, and publishes a `NewDevSolutions` artifact consumed by **Deploy to New Dev**.

**What it does:**

1. Checks out the branch specified by the `exportBranch` parameter and reads `exports/{subfolder}/build.json`
2. For each solution:
   - If `isUnmanaged: true` — exports unmanaged + managed zips as usual, but **stages the unmanaged zip** in the artifact
   - If `isUnmanaged: false` (or omitted) — exports and stages the managed zip (same as daily export)
   - `isExisting: true` — uses the pre-existing zip already in `solutions/` (unmanaged if `isUnmanaged: true`, otherwise managed)
3. Extracts configuration data from Dev (if `configData` is defined in `build.json`) into `exports/{subfolder}/configdata/`
4. Publishes a `NewDevSolutions` artifact (solution zips, `build.json`, config data)
5. Commits the unpacked source, config data, and updated `build.json` back to the export branch and opens a PR to `main`

**Trigger:** Manual only.

**Parameters:**

| Parameter | Description |
|---|---|
| `exportBranch` | **Required.** The export branch containing `build.json` (e.g. `export/sprint42`). The subfolder is derived automatically by stripping the `export/` prefix. |

**Auth:** Uses pac CLI with credentials from the `PowerPlatform-Dev` variable group.

---

### 7. Deploy to New Dev (`pipelines/deploy-to-newdev.yml`)

Manual pipeline that downloads the `NewDevSolutions` artifact from a chosen **Export for New Dev** run and imports every solution into a **New Dev** environment. When running this pipeline, ADO prompts you to select which export run to deploy from.

**What it does:**

1. Downloads the `NewDevSolutions` artifact from the selected export run
2. Validates all artifact zips are present before importing anything
3. Queries the current solution versions in New Dev
4. For each solution (in `build.json` order):
   - Skips if already installed at the target version
   - If `isUnmanaged: true` — imports the unmanaged zip directly (no staged upgrade)
   - If `isUnmanaged: false` — imports the managed zip; uses staged upgrade when upgrading an existing install
   - Applies `deploymentSettings/deploymentSettings_Dev.json` from the repo if `includeDeploymentSettings: true`
   - Activates cloud flows after import
5. Upserts configuration data into New Dev (if `configData` defined in `build.json`)

**Trigger:** Manual only.

**dryRun:** Set the `dryRun` pipeline variable to `true` in the Run dialog to validate without importing.

**Auth:** Uses pac CLI with credentials from the `PowerPlatform-NewDev` variable group.

---

## Pipeline Flow

### Daily Export + Release (Dev &rarr; QA &rarr; Stage &rarr; Prod)

This is the primary CI/CD flow. Solutions are exported from Dev nightly, and the release pipeline promotes them through all downstream environments.

```
 EXPORT                                RELEASE
 ──────                                ───────

┌──────────────────────────┐    ┌─────────────────────────────────────────────┐
│  Daily Export Solutions   │    │  Release Solutions                          │
│  (scheduled / manual)    │    │  (auto-triggered on export completion)      │
│                          │    │                                             │
│  1. Detect export branch │    │  ┌─────────┐  ┌─────────┐  ┌────────────┐ │
│  2. Read build.json      │    │  │   QA    │  │  Stage  │  │    Prod    │ │
│  3. Export from Dev      │    │  │  (auto) │─►│(manual) │─►│  (manual)  │ │
│  4. Validate versions    │───►│  │         │  │         │  │            │ │
│  5. Unpack + export managed│  │  └─────────┘  └─────────┘  └────────────┘ │
│  6. Publish artifact     │    │                                             │
│  7. Post-export versions │    │  Each stage:                                │
│  8. Merge deploy settings│    │  - Validates all artifacts upfront           │
│  9. PR to main           │                                                │
│                          │    │  - Checks installed versions                │
└──────────────────────────┘    │  - Skips if already at target version       │
                                │  - Managed upgrade: stage-and-upgrade      │
                                │  - Unmanaged (isUnmanaged=true): direct     │
                                │  - Applies deployment settings if enabled   │
                                │  - Activates cloud flows (warn on failure)  │
                                └─────────────────────────────────────────────┘
```

### Pre-Dev Promotion (On-Demand)

```
┌─────────────────────────────────┐       ┌──────────────────────────────────┐
│  Export Solution from Pre-Dev   │       │  Deploy Solution                 │
│  (manual trigger)               │       │  (auto-triggered on export)      │
│                                 │       │                                  │
│  1. Export unmanaged from       │       │  ┌───────┐                       │
│     Pre-Dev environment         │  ───► │  │  Dev  │                       │
│  2. Clean unpack (pac CLI)      │       │  │ (auto)│                       │
│  3. Export managed directly     │       │  └───────┘                       │
│  4. Create export/predev/       │       │                                  │
│     {timestamp} branch + commit │       │  - Imports managed solution       │
│  5. PR to main → squash merge   │       │  - Applies deploymentSettings_   │
│  6. Publish artifact +          │       │    Dev.json if present           │
│     deploymentSettings_Dev.json │       │                                  │
└─────────────────────────────────┘       └──────────────────────────────────┘

To promote to QA/Stage/Prod, use the Release Ad-Hoc pipeline with an export-solutions artifact.
```

### Architecture Overview

```
                              Power Platform CI/CD Pipelines

  ON-DEMAND (single solution)                  SCHEDULED (multi-solution)
  ───────────────────────────                  ─────────────────────────

  ┌─────────────────────────────┐              ┌─────────────────────────────┐
  │  3. Export from Pre-Dev     │              │  1. Daily Export Solutions   │
  │     (manual trigger)        │              │     (10 PM ET / cron)       │
  └──────────────┬──────────────┘              └──────────────┬──────────────┘
                 │ triggers                                   │ triggers
                 ▼                                            ▼
  ┌─────────────────────────────┐              ┌─────────────────────────────┐
  │  4. Deploy Solution         │              │  2. Release Solutions       │
  │     Dev only                │              │     QA → Stage → Prod      │
  │     (single solution)       │              │     (multi-solution)        │
  └─────────────────────────────┘              └─────────────────────────────┘
                 │
                 │ for QA/Stage/Prod, run:
                 ▼
  ┌─────────────────────────────┐              Approval gates:
  │  3. Release Ad-Hoc          │              ┌─────┐  ┌─────┐  ┌──────┐
  │     (manual, any env)       │              │ QA  │─►│ Stg │─►│ Prod │
  └─────────────────────────────┘              │auto │  │gate │  │gate  │
                                               └─────┘  └─────┘  └──────┘
```

---

## build.json Configuration

The `build.json` file defines which solutions to export and their **expected versions**. It lives on the export branch at `exports/{date-token}/build.json`.

```json
{
  "solutions": [
    { "name": "CoreComponents", "version": "1.2.0.0", "postExportVersion": "1.3.0.0", "createNewPatch": true },
    { "name": "CustomConnectors", "version": "1.0.3.0", "postExportVersion": "1.0.4.0", "createNewPatch": false },
    { "name": "MainApp", "version": "2.1.0.0", "includeDeploymentSettings": true }
  ],
  "configData": [
    {
      "name": "USStates",
      "entity": "cr123_states",
      "primaryKey": "cr123_stateid",
      "select": "cr123_name,cr123_abbreviation,cr123_fipscode",
      "filter": "statecode eq 0",
      "dataFile": "configdata/USStates.json"
    }
  ]
}
```

### Solutions Fields

| Field | Description |
|---|---|
| `solutions` | Ordered array of solutions to export. Order matters &mdash; the release pipeline deploys in this order (put dependencies first). |
| `solutions[].name` | The solution's **[unique name](https://learn.microsoft.com/en-us/power-platform/alm/solution-concepts-alm)** as it appears in Power Platform (not the display name). |
| `solutions[].version` | The **exact version** expected in the Dev environment. Must match the version in Dev's `Solution.xml`, or the export pipeline will fail. |
| `solutions[].includeDeploymentSettings` | Optional boolean (default: `false`). If `true`, the release pipeline will apply a deployment settings file (`deploymentSettings_{stage}.json`) when importing this solution. Only one solution should have this set to `true`. |
| `solutions[].postExportVersion` | Optional string. If set, the export pipeline bumps this solution's version in Dev to the specified version after export. See [Post-Export Version Management](#post-export-version-management). |
| `solutions[].createNewPatch` | Optional boolean (default: `false`). Only used when `postExportVersion` is set. If `true`, a new patch is cloned from this solution at `postExportVersion` via the Dataverse [`CloneAsPatch`](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/reference/cloneaspatch) action. If `false`, the solution's version is updated directly via [`pac solution online-version`](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/solution). |
| `solutions[].includesCloudFlows` | **Auto-detected** boolean. Set to `true` by the export pipeline if the unpacked solution contains cloud flows (`.json` files in the `Workflows/` directory). Do not set this manually &mdash; it is written by the pipeline during export. |
| `solutions[].isExisting` | Optional boolean (default: `false`). If `true`, the export pipeline skips exporting this solution from Power Platform and uses a pre-existing zip already committed to the repo. The source directory depends on `isUnmanaged`: if `isUnmanaged: true`, the zip is read from `solutions/unmanaged/{name}_{version}.zip`; otherwise it is read from `solutions/managed/{name}_{version}.zip`. The pipeline fails if the expected zip is not found. |
| `solutions[].isRollback` | Optional boolean (default: `false`). If `true`, the deploy pipelines omit `--skip-lower-version` when importing this solution, allowing a lower (rollback) version to be installed over a higher one. Applies to all stages (Dev, QA, Stage, Prod). |
| `solutions[].isUnmanaged` | Optional boolean (default: `false`). When `true`: (1) **`isExisting` source** — the export pipeline reads the pre-existing zip from `solutions/unmanaged/` instead of `solutions/managed/`. (2) **Daily export release** — the release pipeline (`deploy-environment.yml`) imports the solution as unmanaged (direct import, no staged upgrade). (3) **New Dev pipelines** — `export-for-new-dev` stages the unmanaged zip in the artifact and `deploy-to-newdev` imports it as unmanaged. |

### Config Data Fields

| Field | Description |
|---|---|
| `configData` | Optional array of configuration data sets to extract from Dev and upsert into target environments. See [Configuration Data](#configuration-data). |
| `configData[].name` | Friendly name for the data set (used in pipeline logs and summaries). |
| `configData[].entity` | Dataverse table logical name in **plural form** for OData (e.g., `cr123_states`). |
| `configData[].primaryKey` | Primary key column name. The GUID in this column must be **stable across all environments** &mdash; the same record has the same GUID everywhere. |
| `configData[].select` | Comma-separated list of columns to extract and upsert (OData `$select`). Do **not** include the primary key here &mdash; it is added automatically. |
| `configData[].filter` | Optional OData `$filter` expression to scope which rows are extracted (e.g., `statecode eq 0`). Omit to extract all rows. |
| `configData[].dataFile` | Path to the JSON data file relative to the export folder (e.g., `configdata/USStates.json`). Created/updated by the export pipeline inside the same folder as `build.json`. |

**How versions work:**

- The version in `build.json` must match the version in the Dev environment exactly
- The export pipeline **reads** the version from Dev after unpack and **compares** it &mdash; it never writes or changes versions
- If you increment a solution version in Dev, update `build.json` to match before the next export run
- The release pipeline uses the same version from `build.json` to name artifact files and check target environments
- Solution zip files are named `{name}_{version}.zip` (e.g., `CoreComponents_1.2.0.0.zip`)

**Caching:** If a managed zip for the exact name + version already exists in `solutions/managed/`, the export pipeline skips re-exporting that solution and uses the cached file. This makes re-runs efficient when only some solutions have changed.

### Deployment Settings

Deployment settings allow you to configure environment-specific values (such as [connection references](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference) and [environment variables](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/environmentvariables)) that get applied when importing a solution into a target environment.

**How it works:**

1. Set `"includeDeploymentSettings": true` on **one** solution in `build.json`
2. Create deployment settings files in the **same folder** as `build.json`, named by environment:
   - `deploymentSettings_QA.json`
   - `deploymentSettings_Stage.json`
   - `deploymentSettings_Prod.json`
3. The export pipeline includes these files in the `ManagedSolutions` artifact automatically
4. During deployment, the release pipeline passes the matching file to `pac solution import --settings-file` (see [connection references and environment variables with build tools](https://learn.microsoft.com/en-us/power-platform/alm/conn-ref-env-variables-build-tools) for the file schema)

**Root `deploymentSettings/` folder:**

The repository maintains a root `deploymentSettings/` folder that holds the accumulated set of deployment settings across all export runs. During the export pipeline, before the PR is created:

1. The pipeline runs `scripts/Merge-DeploymentSettings.ps1`
2. For each `deploymentSettings_{env}.json` in the export folder, items are merged into the corresponding root file
3. **Matching items are overwritten** &mdash; `EnvironmentVariables` are matched by `SchemaName`, `ConnectionReferences` by `LogicalName`
4. **New items are appended** to the root file
5. The updated root files are committed to the export branch and included in the PR to `main`

This ensures the root `deploymentSettings/` folder always reflects the latest configuration from every export run.

**Merge example:**

Suppose the root `deploymentSettings/deploymentSettings_QA.json` currently contains:

```json
{
  "EnvironmentVariables": [
    { "SchemaName": "cr5a4_ApiUrl", "Value": "https://old-api.example.com" },
    { "SchemaName": "cr5a4_FeatureFlag", "Value": "false" }
  ],
  "ConnectionReferences": [
    { "LogicalName": "cr5a4_DataverseConn", "ConnectionId": "aaa-111", "ConnectorId": "/apis/shared_cds" }
  ]
}
```

And an export run includes `exports/2026-02-15-sprint42/deploymentSettings_QA.json` with:

```json
{
  "EnvironmentVariables": [
    { "SchemaName": "cr5a4_ApiUrl", "Value": "https://new-api.example.com" },
    { "SchemaName": "cr5a4_Timeout", "Value": "30" }
  ],
  "ConnectionReferences": []
}
```

After the merge, the root file becomes:

```json
{
  "EnvironmentVariables": [
    { "SchemaName": "cr5a4_ApiUrl", "Value": "https://new-api.example.com" },
    { "SchemaName": "cr5a4_FeatureFlag", "Value": "false" },
    { "SchemaName": "cr5a4_Timeout", "Value": "30" }
  ],
  "ConnectionReferences": [
    { "LogicalName": "cr5a4_DataverseConn", "ConnectionId": "aaa-111", "ConnectorId": "/apis/shared_cds" }
  ]
}
```

- `cr5a4_ApiUrl` was **overwritten** (matched by `SchemaName`, export value wins)
- `cr5a4_FeatureFlag` was **preserved** (exists in root but not in export)
- `cr5a4_Timeout` was **appended** (new item from export)
- `cr5a4_DataverseConn` was **preserved** (export had an empty `ConnectionReferences` array)

**Example deployment settings file** (`deploymentSettings_QA.json`):

```json
{
  "EnvironmentVariables": [
    {
      "SchemaName": "cr5a4_SharedVariableName",
      "Value": "qa-value"
    }
  ],
  "ConnectionReferences": [
    {
      "LogicalName": "cr5a4_SharedConnectionRef",
      "ConnectionId": "00000000-0000-0000-0000-000000000000",
      "ConnectorId": "/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps"
    }
  ]
}
```

**Rules:**

- Only **one** solution in `build.json` should have `includeDeploymentSettings: true`
- If `includeDeploymentSettings` is omitted or `false`, no deployment settings are applied for that solution
- If `includeDeploymentSettings` is `true` but the corresponding `deploymentSettings_{stage}.json` file is missing from the artifact, the deployment **fails** with an error

### Post-Export Version Management

If a solution entry in `build.json` includes a `postExportVersion` property, the export pipeline automatically bumps that solution's version in the Dev environment **after** exporting and publishing artifacts. This prepares Dev for the next development cycle. Solutions without `postExportVersion` are left untouched.

**How it works:**

| `createNewPatch` | Action |
|---|---|
| `false` (or omitted) | Calls [`pac solution online-version`](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/solution) to set the solution's version to `postExportVersion` directly |
| `true` | Calls the Dataverse [`CloneAsPatch`](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/reference/cloneaspatch) action to create a new patch at `postExportVersion`. If the solution is itself a patch, the new patch is cloned from its **parent** (base) solution — Dataverse does not allow creating a patch from a patch. See [Create patches to simplify solution updates](https://learn.microsoft.com/en-us/power-platform/alm/create-patches-simplify-solution-updates) on Microsoft Learn. |

**Example:**

Given `build.json`:
```json
{
  "solutions": [
    { "name": "CoreComponents", "version": "1.2.0.0", "postExportVersion": "1.3.0.0", "createNewPatch": true },
    { "name": "CustomConnectors", "version": "1.0.3.0", "postExportVersion": "1.0.4.0", "createNewPatch": false },
    { "name": "MainApp", "version": "2.1.0.0" }
  ]
}
```

After export:
1. `CoreComponents` &rarr; a new patch is cloned from `CoreComponents` at version `1.3.0.0`
2. `CustomConnectors` &rarr; version updated directly to `1.0.4.0`
3. `MainApp` &rarr; no change (no `postExportVersion`)

If no solutions in `build.json` have `postExportVersion`, this step is skipped entirely.

### Configuration Data

Configuration data allows you to move reference/lookup data (such as US States, Country Codes, or any Dataverse table rows) across environments automatically. Data is extracted from Dev during the export pipeline and upserted into each target environment during deployment.

**How it works:**

1. Define one or more data sets in the `configData` array of `build.json`
2. During the daily export, the pipeline queries each data set from Dev using [OData](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/query-data-web-api) (`$select` + optional `$filter`)
3. Results are written as JSON files to `configdata/` inside the export folder (the same folder as `build.json`, e.g., `exports/2026-02-15-sprint42/configdata/`) and included in the pipeline artifact
4. During deployment, the pipeline reads each data file and PATCHes every record into the target environment using the record's primary key GUID

**Stable GUIDs:** This approach requires that the primary key GUID for each record is **the same across all environments**. When you create records in Dev, they get assigned GUIDs. Those exact GUIDs are used to create-or-update (upsert) records in QA, Stage, and Prod. The [Dataverse Web API](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/overview) `PATCH /api/data/v9.2/{entity}({guid})` creates the record with that GUID if it doesn't exist, or updates it if it does.

**Data file format** (`configdata/USStates.json`):

```json
[
  {
    "cr123_stateid": "a1b2c3d4-0000-0000-0000-000000000001",
    "cr123_name": "Alabama",
    "cr123_abbreviation": "AL",
    "cr123_fipscode": "01"
  },
  {
    "cr123_stateid": "a1b2c3d4-0000-0000-0000-000000000002",
    "cr123_name": "Alaska",
    "cr123_abbreviation": "AK",
    "cr123_fipscode": "02"
  }
]
```

**Execution order in deploy pipelines:**

```
1. Import solutions (creates tables if they don't exist)
2. Activate cloud flows (if enabled)
3. Upsert config data (tables must exist before data can be written)
```

Config data upsert runs **after** solution imports because the target tables must exist in the environment before records can be written.

**OData pagination:** The extract step automatically handles Dataverse OData pagination (`@odata.nextLink`). Data sets with more than 5,000 rows are fetched in batches.

**Error handling:**

| Phase | Behavior |
|---|---|
| **Extract** (export pipeline) | Failures **fail the pipeline**. If a data set can't be queried, the export stops. |
| **Upsert** (deploy pipelines) | Record-level failures are logged as **warnings** but do not fail the deployment. A summary shows how many records succeeded/failed per data set. |

**Script:** Both extract and upsert operations are handled by `scripts/Sync-ConfigData.ps1`, which takes a `-Mode Extract` or `-Mode Upsert` parameter.

**Rules:**

- The `entity` value must be the **plural** OData entity set name (e.g., `cr123_states`, not `cr123_state`)
- The `primaryKey` column must contain a stable GUID that is identical across all environments
- The `select` columns should not include the primary key &mdash; it is added automatically during extraction
- Data files are committed to the export branch (inside the export folder) and included in the PR to `main`
- Config data is included in the `ManagedSolutions` artifact alongside solution zips and deployment settings
- The deploy-solution pipeline (pipeline 5) upserts config data into Dev if `build.json` contains a `configData` array in the artifact

---

## Testing

The repository includes [Pester](https://pester.dev) unit tests for the deployment settings logic. Tests are in the `tests/` folder.

**Running the tests:**

```powershell
# Install Pester (if not already available)
Install-Module -Name Pester -Force -Scope CurrentUser

# Run all tests
Invoke-Pester tests/ -Output Detailed
```

**Test suites:**

| File | What it tests |
|---|---|
| `Merge-DeploymentSettings.Tests.ps1` | Merge logic: new items appended, existing items overwritten by export, multiple environment files processed independently, empty arrays preserved |
| `Build-Json-Validation.Tests.ps1` | `build.json` validation: required fields, `includeDeploymentSettings` defaults to false, only one solution may have it set to true |
| `Cloud-Flow-Detection.Tests.ps1` | Cloud flow detection: `.json` files in `Workflows/` detected, `.xaml`-only and empty directories return false, `includesCloudFlows` flag round-trip through `build.json` serialization |
| `Deploy-Dev-Settings.Tests.ps1` | Pre-Dev &rarr; Dev deployment settings: settings file resolution from artifact (auto-triggered) or `deploymentSettings/preDev/` (manual) |
| `Config-Data-Validation.Tests.ps1` | Config data validation: required fields (`name`, `entity`, `primaryKey`, `select`, `dataFile`), optional `filter`, multiple data sets, empty/missing `configData` array, data file round-trip serialization |

---

## ADO Setup

### Prerequisites

| Requirement | Details |
|---|---|
| **Azure DevOps Organization** | Any ADO org with Pipelines enabled |
| **Power Platform Build Tools** | Install the [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools) extension from the Visual Studio Marketplace into your ADO organization. Docs: [Power Platform Build Tools for Azure DevOps](https://learn.microsoft.com/en-us/power-platform/alm/devops-build-tools). |
| **pac CLI (Power Platform CLI)** | Installed automatically at runtime via `dotnet tool install --global Microsoft.PowerApps.CLI.Tool`. No pre-installation required; Microsoft-hosted agents include the .NET SDK. Docs: [Power Platform CLI](https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction). |
| **App Registration (Service Principal)** | An Entra ID app registration with client secret, granted **System Administrator** or **System Customizer** role in the target Power Platform environments |
| **Agent Pool** | Uses `windows-latest` Microsoft-hosted agents (no self-hosted agent required) |

### Step 1: Install the Power Platform Build Tools Extension

1. Go to your Azure DevOps organization (`https://dev.azure.com/{your-org}`)
2. Click **Organization settings** > **Extensions** > **Browse marketplace**
3. Search for **Power Platform Build Tools**
4. Click **Get it free** and install it into your organization

### Step 2: Register an App in Entra ID (Azure AD)

1. Go to the [Azure Portal](https://portal.azure.com) > **Entra ID** > **App registrations** > **New registration**
2. Name it (e.g., `PowerPlatform-ADO-Pipeline`)
3. Under **Certificates & secrets**, create a new **Client secret** and save the value
4. Note down:
   - **Application (client) ID**
   - **Directory (tenant) ID**
   - **Client secret value**
5. In the [Power Platform Admin Center](https://admin.powerplatform.microsoft.com), register this app as an **Application User** in **all** environments (Pre-Dev, Dev, QA, Stage, Prod) with the **System Administrator** security role

> **Note:** You can use the same app registration across all environments, or create separate ones per environment for tighter access control. See [Register an application in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app) and [Manage application users](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users) on Microsoft Learn.

### Step 3: Create Power Platform Service Connections

> **No service connections are required.** All pipelines authenticate via pac CLI using credentials from variable groups (created in Step 4). The `PowerPlatformToolInstaller@2` task is used only where Power Platform Build Tools ADO tasks are needed (daily export and new dev pipelines) &mdash; it does not require a service connection.
>
> You can skip this step entirely.

### Step 4: Create Variable Groups (Release &amp; Deploy Pipelines)

The release pipeline, deploy pipeline, and pre-dev export pipeline use **[variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)** to store per-environment credentials. Create one group for each environment.

1. Go to **Pipelines** > **Library** > **+ Variable group**
2. Create five variable groups with the following names and variables:

**`PowerPlatform-PreDev`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-predev.crm.dynamics.com` | No |
| `ClientId` | Application (Client) ID | No |
| `ClientSecret` | Client secret value | **Yes** |
| `TenantId` | Directory (Tenant) ID | No |


**`PowerPlatform-Dev`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-dev.crm.dynamics.com` | No |
| `ClientId` | Application (Client) ID | No |
| `ClientSecret` | Client secret value | **Yes** |
| `TenantId` | Directory (Tenant) ID | No |

**`PowerPlatform-QA`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-qa.crm.dynamics.com` | No |
| `ClientId` | Application (Client) ID | No |
| `ClientSecret` | Client secret value | **Yes** |
| `TenantId` | Directory (Tenant) ID | No |

**`PowerPlatform-Stage`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-stage.crm.dynamics.com` | No |
| `ClientId` | Application (Client) ID | No |
| `ClientSecret` | Client secret value | **Yes** |
| `TenantId` | Directory (Tenant) ID | No |

**`PowerPlatform-Prod`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-prod.crm.dynamics.com` | No |
| `ClientId` | Application (Client) ID | No |
| `ClientSecret` | Client secret value | **Yes** |
| `TenantId` | Directory (Tenant) ID | No |

3. On each variable group, click **Pipeline permissions** and authorize the pipelines that use it (release pipeline and/or deploy pipeline)

### Step 5: Create ADO Environments (Release &amp; Deploy Pipelines)

Both the release pipeline and the deploy pipeline use **[ADO Environments](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/environments)** to gate deployments. Environments with approval checks will pause the pipeline and require manual approval before proceeding.

1. Go to **Pipelines** > **Environments** > **New environment**
2. Create five environments:

| Environment Name | Used By | Approval Check |
|---|---|---|
| `Power Platform Dev` | Deploy pipeline only | None (deploys automatically) |
| `Power Platform QA` | Release pipeline | Deploys automatically (see note) |
| `Power Platform Stage` | Release pipeline | **Add approval check** &mdash; select approver(s) |
| `Power Platform Prod` | Release pipeline | **Add approval check** &mdash; select approver(s) |
| `Power Platform NewDev` | Deploy to New Dev pipeline | None (or add an approval check if desired) |

> **Note:** ADO environment approval checks apply to **all** pipelines that use the environment. If you use `release-adhoc` against a named environment that already has an approval check, the ad-hoc run will also require approval.

**To add an approval check:**

1. Click on the environment (e.g., `Power Platform Stage`)
2. Click the **&vellip;** menu (top-right) > **Approvals and checks**
3. Click **+ Add check** > **Approvals**
4. Add one or more approvers (users or groups)
5. Optionally set a timeout and instructions
6. Click **Create**

When a pipeline reaches a stage with an approval gate, it will pause and notify the approvers. The stage only proceeds after approval.

### Step 6: Create the Pipelines

Register each pipeline in ADO:

1. Go to **Pipelines** > **New pipeline**
2. Select your repository and choose **Existing Azure Pipelines YAML file**
3. Select the YAML file and click **Save**

Create pipelines in this order:

| # | YAML File | Recommended Pipeline Name |
|---|---|---|
| 1 | `pipelines/export-solutions.yml` | `export-solutions` |
| 2 | `pipelines/release-solutions.yml` | `release-solutions` |
| 3 | `pipelines/release-adhoc.yml` | `release-adhoc` |
| 4 | `pipelines/export-solution-predev.yml` | `Export Solution from Pre-Dev` |
| 5 | `pipelines/deploy-solution.yml` | `deploy-solution` (Dev only) |
| 6 | `pipelines/export-to-newdev.yml` | `export-for-new-dev` |
| 7 | `pipelines/deploy-to-newdev.yml` | `deploy-to-newdev` |

> **Important:** Pipeline names matter for cross-pipeline triggers and artifact downloads:
> - The **release pipeline** and **release-adhoc pipeline** reference the export pipeline as `source: "export-solutions"`. The export pipeline's name in ADO must match this value.
> - The **deploy pipeline** references the pre-dev export as `source: "Export Solution from Pre-Dev"`. Update if your pipeline name differs.
> - The **deploy-to-newdev pipeline** references the export-for-new-dev pipeline as `source: "export-for-new-dev"`. The export pipeline's name in ADO must match this value.

### Step 7: Link Variable Groups to Pipelines

Each pipeline must be authorized to use its variable group(s). After creating the variable groups in Step 4:

1. Open each variable group in **Pipelines** > **Library**
2. Click **Pipeline permissions**
3. Click **+** and add the pipeline(s) that use that group:

| Variable Group | Used By |
|---|---|
| `PowerPlatform-PreDev` | Export Solution from Pre-Dev |
| `PowerPlatform-Dev` | Daily Export Solutions, Deploy Solution, Export for New Dev |
| `PowerPlatform-QA` | Release Solutions |
| `PowerPlatform-Stage` | Release Solutions |
| `PowerPlatform-Prod` | Release Solutions |
| `PowerPlatform-NewDev` | Deploy to New Dev |
| *(your group)* | Release Ad-Hoc (specified at runtime — no pre-authorization needed if the pipeline is set to allow all variable groups) |

### Step 8: Update Pipeline Variables

All pipelines use variable groups for configuration &mdash; there are no inline service connection names to update. If you named your variable groups differently from the defaults, update the `group:` references in each pipeline YAML.

**`pipelines/export-solutions.yml`:**

Uses the `PowerPlatform-Dev` variable group. No inline variables to configure &mdash; all credentials and the environment URL come from the variable group.

**`pipelines/export-solution-predev.yml`:**

Uses the `PowerPlatform-PreDev` variable group. No inline variables to configure &mdash; all credentials come from the variable group.

**`pipelines/deploy-solution.yml`:**

The deploy pipeline uses the `PowerPlatform-Dev` variable group. Update the variable group name in the YAML if yours differs from the default.

### Step 9: Grant Repository Permissions

The pipeline's build service identity needs permissions to push commits and create PRs.

1. Go to **Project settings** > **Repositories** > select your repository
2. Click the **Security** tab
3. Find **{Project Name} Build Service ({Org Name})** in the users list
4. Set the following permissions to **Allow**:
   - **Contribute**
   - **Create branch**
   - **Force push (rewrite history, delete branches)** (required to delete the export branch after merge — used by both export pipelines)
   - **Create pull requests** (used by both export pipelines)
   - **Contribute to pull requests** (used by both export pipelines)

---

## How to Execute

### Daily Export Solutions (Scheduled)

The pipeline runs automatically every day at **10:00 PM ET**, but can also be triggered manually on demand from the ADO UI. The pipeline will:
- Check if an export branch exists for today's date
- Skip gracefully (with a warning) if no matching branch is found
- Process all solutions and merge if a branch is found

**To set up an export run**, create a branch and `build.json`:

```bash
git checkout main && git pull
git checkout -b export/2026-02-15-sprint42
mkdir -p exports/2026-02-15-sprint42
```

Create `exports/2026-02-15-sprint42/build.json`:

```json
{
  "solutions": [
    { "name": "CoreComponents", "version": "1.2.0.0" },
    { "name": "MainApp", "version": "2.1.0.0", "includeDeploymentSettings": true }
  ]
}
```

If using deployment settings, create a settings file for each target environment in the same folder (e.g., `exports/2026-02-15-sprint42/deploymentSettings_QA.json`, `deploymentSettings_Stage.json`, `deploymentSettings_Prod.json`). See [Deployment Settings](#deployment-settings) for the file format.

```bash
git add exports/
git commit -m "configure export for 2026-02-15-sprint42"
git push -u origin export/2026-02-15-sprint42
```

**To run manually:** Go to **Pipelines** > select `export-solutions` > **Run pipeline**. Optionally supply an export branch to skip auto-detect.

### Release Pipeline (Automatic + Manual Approval)

The release pipeline triggers automatically after the export pipeline completes. No manual action is needed for the QA stage.

**For Stage and Prod:**

1. After QA completes successfully, approvers will receive a notification
2. Go to **Pipelines** > select the running release pipeline
3. Click **Review** on the Stage or Prod stage
4. Click **Approve** to proceed

The pipeline will skip any solution already installed at the target version in the environment.

**Dry run:**

To validate what *would* be deployed without making any changes:

1. Go to **Pipelines** > select `release-solutions` > **Run pipeline**
2. Expand **Variables** and set `dryRun` to `true`
3. Click **Run**

The pipeline authenticates with each environment, validates all artifacts, queries currently installed solution versions, and logs the exact `pac solution import` command that *would* be run for each solution — but no imports are executed and no config data is upserted.

### Release Ad-Hoc (Manual)

To deploy any export run to an environment outside the standard QA → Stage → Prod chain:

1. Go to **Pipelines** > select `release-adhoc` > **Run pipeline**
2. Fill in the parameters:
   - **ADO Environment name** — the environment to deploy into (e.g., `Power Platform Sandbox`)
   - **Variable group name** — the library variable group with credentials for that environment (e.g., `PowerPlatform-Sandbox`)
3. In the **Resources** panel, select the `export-solutions` run whose artifact you want to deploy
4. Click **Run**

The pipeline deploys all solutions from the selected export run using the same version-skip and upgrade logic as the standard release pipeline. If a `deploymentSettings_{variableGroup}.json` file is present in the artifact, it will be applied automatically.

> **Note:** The variable group named in step 2 must be authorized for the `release-adhoc` pipeline. Open the variable group in **Pipelines > Library > Pipeline permissions** and add `release-adhoc` if it is not already listed.

### Export from Pre-Dev + Deploy (On-Demand)

1. Go to **Pipelines** in your ADO project
2. Select the **Export Solution from Pre-Dev** pipeline
3. Click **Run pipeline**
4. Enter the **Solution unique name** (exactly as it appears in Power Platform)
5. Click **Run**

The pipeline will export from Pre-Dev (unmanaged + managed directly via pac CLI), unpack, create an `export/predev/{timestamp}` branch, commit the solution files, create a PR to `main` (squash merge), and automatically trigger the deploy pipeline. The solution will deploy to Dev immediately.

To promote to QA, Stage, and Prod, run the **Release Ad-Hoc** pipeline using an `export-solutions` artifact for those environments.

### Deploy Solution (Manual)

If you need to re-deploy a solution that's already been exported and committed to Dev:

1. Go to **Pipelines** > select **deploy-solution**
2. Click **Run pipeline**
3. Enter the **Solution name** (must have a corresponding `solutions/managed/{name}.zip` in the repo)
4. Click **Run**

The solution will deploy to Dev only.

**Dry run:** Check the **Dry run** checkbox when running the pipeline manually to validate version checks and import arguments without making any changes.

### Verifying Results

**After a daily export:**

| Where | What to Check |
|---|---|
| **Pipeline logs** | Version validation passed for each solution |
| **Repository** | `solutions/unpacked/{name}/` has the latest source files |
| **Repository** | `solutions/unmanaged/{name}_{version}.zip` has the versioned unmanaged export |
| **Repository** | `solutions/managed/{name}_{version}.zip` has the versioned managed package |
| **Pull Requests** | A PR was created and auto-completed (or is awaiting policy checks) |

**After a release deployment (pipeline 2):**

| Where | What to Check |
|---|---|
| **Pipeline logs** | Each solution shows "Successfully deployed" or "Already installed — skipping" |
| **Pipeline logs** | Cloud flow activation: look for "activated successfully" or warning messages for flows that couldn't be turned on |
| **Target environment** | Solutions are visible in the Power Platform maker portal at the expected versions |
| **Target environment** | Cloud flows are turned on (check Power Automate portal &mdash; some may need manual activation if warnings appeared) |

**After a deploy solution run (pipeline 5):**

| Where | What to Check |
|---|---|
| **Pipeline logs** | Solution shows "Deployment Complete" |
| **Dev environment** | The solution is visible in the Power Platform maker portal at the expected version |

---

## Changing the Schedule

The daily export schedule is defined as a [cron expression](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/scheduled-triggers) in UTC:

```yaml
schedules:
  - cron: "0 3 * * *"    # 3:00 AM UTC = 10:00 PM EST
```

Common examples:

| Desired Time (ET) | Cron (UTC) | Notes |
|---|---|---|
| 10:00 PM EST | `0 3 * * *` | November - March |
| 10:00 PM EDT | `0 2 * * *` | March - November |
| 8:00 PM ET | `0 1 * * *` | Approximate for EDT |
| Weekdays only at 10 PM EST | `0 3 * * 1-5` | Monday through Friday |
| Disable schedule | Remove the `schedules:` block | Manual-only |

> **Note:** ADO cron schedules use UTC. The pipeline calculates the current Eastern Time date at runtime regardless of the cron time, so the date detection is always correct even if the UTC/ET offset shifts with daylight saving time.

---

## Troubleshooting

### Daily Export Solutions

| Symptom | Cause | Fix |
|---|---|---|
| Pipeline skips with "No export branch found" | No branch matching `export/{today}-*` exists | Create the export branch and push it before the scheduled run |
| "build.json not found" | The `exports/{subfolder}/build.json` file is missing on the export branch | Ensure the file path matches the branch name (minus the `export/` prefix) |
| "Version mismatch for '...'" | The solution version in Dev doesn't match the version in `build.json` | Update `build.json` to match the current version in Dev, or update the version in Dev to match `build.json` |
| "Failed to authenticate with Power Platform" | Secret variables are missing or incorrect | Verify `ClientId`, `ClientSecret`, and `TenantId` in pipeline variables |
| "Failed to export solution" | Solution name doesn't match, or SPN lacks permissions | Verify the solution unique name in Power Platform and the app user's security role |
| "Failed to create Pull Request" | Build service lacks repo permissions | Grant Contribute and Create PR permissions (see Step 9) |
| "Could not delete source branch" warning after PR merge | Build service lacks Force push permission | Grant **Force push (rewrite history, delete branches)** to the Build Service account on the repository (see Step 9) |
| PR created but not auto-completing | Branch policies require human reviewers | Either add an exception for the build service or manually complete the PR |
| Root `deploymentSettings/` not updated | No `deploymentSettings_*.json` files in the export folder | The merge step only runs when settings files exist in `exports/{date-token}/`. If you need deployment settings, add them to the export folder before the pipeline runs |
| Export overwrote a value I didn't expect | Export items overwrite matching root items by key | The merge uses `SchemaName` (env variables) and `LogicalName` (connection references) to match. If an export file contains an item with the same key as the root, the export value wins. Review the diff in the PR before merging to `main` |
| "Failed to set version" after export | `pac solution online-version` failed | Ensure the SPN has permissions to update solutions in Dev. Verify the `postExportVersion` value is a valid version string (e.g., `2.0.0.0`) |
| "Failed to clone patch" after export | Dataverse `CloneAsPatch` action failed | Common causes: parent solution doesn't exist in Dev, version format is invalid, or SPN lacks permissions. Check the pipeline logs for the detailed API error |
| "Failed to rename patch" after export | Dataverse API couldn't update the display name | Verify the SPN has write access to the solution entity in Dev. The patch's unique name may also not match what's in `build.json` |

### Config Data (All Pipelines)

| Symptom | Cause | Fix |
|---|---|---|
| "Failed to extract config data" during export | OData query failed | Verify the `entity` name is the correct plural OData entity set name (e.g., `cr123_states`). Check that the SPN has read access to the table in Dev |
| Config data file is empty (`[]`) | No records match the `filter` expression | Verify the `filter` value in `build.json` returns records. Test the OData query manually: `GET {envUrl}/api/data/v9.2/{entity}?$select=...&$filter=...` |
| "Failed to upsert record" warnings during deploy | Record PATCH failed | Common causes: table doesn't exist yet (ensure the solution creating the table is imported first), column name mismatch, or SPN lacks write access |
| Records created with wrong GUIDs | GUIDs are not stable across environments | The primary key GUID in the data file must match the GUID you want in the target environment. Create records in Dev with deterministic GUIDs, or manually set GUIDs in the data file |
| "Data file not found" warning during deploy | Config data was not extracted or not included in artifact | Ensure the export pipeline ran successfully and the data file path in `build.json` matches the actual file location in the artifact |
| OData pagination issues | Data set has more than 5,000 rows | The extract script handles `@odata.nextLink` automatically. If timeouts occur, consider narrowing the `filter` to reduce the data set size |

### Release Solutions

| Symptom | Cause | Fix |
|---|---|---|
| Release pipeline doesn't trigger | Export pipeline name mismatch | Ensure the export pipeline is named `export-solutions` in ADO (must match `source` in `release-solutions.yml`) |
| Release pipeline doesn't trigger | Export didn't run on `main` | The release only triggers when the export pipeline runs against the `main` branch |
| "build.json not found in artifact" | Export pipeline didn't publish artifacts | Check the export pipeline logs &mdash; it may have skipped (no export branch found) or failed before artifact publishing |
| "Failed to authenticate" in a stage | Variable group misconfigured | Verify the variable group for that stage has correct `EnvironmentUrl`, `ClientId`, `ClientSecret`, and `TenantId` |
| "Failed to list solutions" | SPN lacks read access to target environment | Ensure the app user has System Administrator or System Customizer role in the target environment |
| "Failed to import solution" | Missing dependencies, invalid solution, or insufficient permissions | Check the pipeline logs for the detailed Dataverse error. Common causes: a dependent solution is missing, version downgrade attempted, or SPN lacks import permissions |
| Stage/Prod stuck waiting | No one has approved | Approvers need to go to the pipeline run and click **Approve** on the pending stage |
| "Managed zip not found in artifact" | Artifact filename doesn't match build.json | Ensure solution names and versions in `build.json` match exactly (filenames are `{name}_{version}.zip`) |
| Solutions always skipped | Already deployed at target version | This is expected behavior &mdash; the pipeline only deploys when the version changes |
| "includeDeploymentSettings is true but deploymentSettings_{stage}.json was not found" | Deployment settings file missing from artifact | Ensure the file exists in the same folder as `build.json` on the export branch (e.g., `exports/{date-token}/deploymentSettings_QA.json`) |
| "Artifact validation failed" | One or more solution zips or deployment settings files missing from artifact | The pipeline validates all artifacts upfront before importing anything. Ensure all solutions in `build.json` were exported successfully and all required `deploymentSettings_*.json` files exist |
| "Failed to activate flow" warning | Cloud flow could not be turned on after import | Common causes: connection references not resolved, SPN lacks access to the underlying connections, or flow suspended by DLP policy. Manually activate the flow in the Power Automate portal or resolve the underlying issue |
| "Could not acquire Dataverse API token" warning | OAuth token request for flow activation failed | Verify `ClientId`, `ClientSecret`, and `TenantId` are correct. Solution imports are not affected &mdash; only flow activation is skipped |

### Export from Pre-Dev / Deploy Solution

| Symptom | Cause | Fix |
|---|---|---|
| Export fails with auth error | Variable group misconfigured | Verify the `PowerPlatform-PreDev` variable group has correct `EnvironmentUrl`, `ClientId`, `ClientSecret`, and `TenantId` |
| Export fails with "solution not found" | Solution name doesn't match | Use the exact **unique name** from Power Platform (not the display name) |
| Deploy pipeline doesn't trigger | Pipeline name mismatch | Ensure the `source` value in `deploy-solution.yml` matches the exact name of the export pipeline in ADO |
| Deploy pipeline doesn't trigger | Trigger branch filter | The export pipeline must run against `main` branch to trigger the deploy |
| Deploy fails with auth error in Dev | Variable group misconfigured | Verify the `PowerPlatform-Dev` variable group has correct `EnvironmentUrl`, `ClientId`, `ClientSecret`, and `TenantId` |
| Manual deploy says "solution not found" | Solution not in repo | Run the export pipeline first, or verify `solutions/managed/{name}.zip` exists in the repo |
| "Failed to push branch" | Build service lacks Contribute or Create branch permission | Grant the Build Service account **Contribute** and **Create branch** permissions on the repository (see Step 9) |
| "Failed to create Pull Request" | Build service lacks Create pull request permission | Grant the Build Service account **Create pull requests** and **Contribute to pull requests** permissions on the repository (see Step 9) |
| "Could not delete source branch" warning after PR merge | Build service lacks Force push permission | Grant **Force push (rewrite history, delete branches)** to the Build Service account on the repository (see Step 9) |

---

## Resources

Microsoft Learn documentation referenced in this README:

**Power Platform & ALM**
- [Solution concepts for ALM](https://learn.microsoft.com/en-us/power-platform/alm/solution-concepts-alm)
- [Power Platform Build Tools for Azure DevOps](https://learn.microsoft.com/en-us/power-platform/alm/devops-build-tools)
- [Create patches to simplify solution updates](https://learn.microsoft.com/en-us/power-platform/alm/create-patches-simplify-solution-updates)
- [Connection references and environment variables with build tools](https://learn.microsoft.com/en-us/power-platform/alm/conn-ref-env-variables-build-tools)

**Power Platform CLI (pac)**
- [Power Platform CLI overview](https://learn.microsoft.com/en-us/power-platform/developer/cli/introduction)
- [pac solution command reference](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/solution)

**Dataverse**
- [Connection references in Power Apps](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference)
- [Environment variables in solutions](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/environmentvariables)
- [Dataverse Web API overview](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/overview)
- [Query data using OData](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/query-data-web-api)
- [CloneAsPatch Web API action](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/reference/cloneaspatch)

**Power Automate**
- [Overview of cloud flows](https://learn.microsoft.com/en-us/power-automate/overview-cloud)

**Power Platform Administration**
- [Manage application users](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)

**Microsoft Entra ID**
- [Register an application in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)

**Azure DevOps Pipelines**
- [Pipeline completion triggers](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/pipeline-triggers)
- [Scheduled triggers (cron)](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/scheduled-triggers)
- [Variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)
- [Environments and approval checks](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/environments)
