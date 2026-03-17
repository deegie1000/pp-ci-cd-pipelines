# Power Platform CI/CD Pipelines

Azure DevOps pipelines for exporting, versioning, and deploying Power Platform solutions across environments.

> **New to this repo?** See [TLDR.md](./TLDR.md) for a plain-English guide on how to use the pipelines.

## Contents

- [Repository Structure](#repository-structure)
- [Pipeline Overview](#pipeline-overview)
- [Pipelines](#pipelines)
  - [1. Daily Export Solutions](#1-daily-export-solutions-pipelinesexport-solutionsyml)
  - [2. Release Solutions to Test](#2-release-solutions-to-test-pipelinesrelease-solutions-testyml)
  - [3. Release Solutions to QA](#3-release-solutions-to-qa-pipelinesrelease-solutions-qayml)
  - [4. Promote to Stage and Prod](#4-promote-to-stage-and-prod-pipelinesrelease-solutions-promoteyml)
  - [5. Release Ad-Hoc](#5-release-ad-hoc-pipelinesrelease-adhocyml)
- [Pipeline Flow](#pipeline-flow)
  - [Daily Export + Release to Test](#daily-export--release-to-test-dev--test)
  - [Promote to Stage and Prod](#promote-to-stage-and-prod)
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
  - [Release to Test](#release-to-test-automatic)
  - [Promote to Stage and Prod](#promote-to-stage-and-prod-manual)
  - [Release Ad-Hoc](#release-ad-hoc-manual)
  - [Verifying Results](#verifying-results)
- [Changing the Schedule](#changing-the-schedule)
- [Troubleshooting](#troubleshooting)

---

## Repository Structure

```
pp-ci-cd-pipelines/
├── pipelines/
│   ├── export-solutions.yml             # Daily scheduled export (Dev → repo)
│   ├── release-solutions-test.yml       # Release pipeline (Test only — auto-triggered)
│   ├── release-solutions-qa.yml         # Release pipeline (QA only — auto-triggered)
│   ├── release-solutions-promote.yml    # Promotion pipeline (Stage → Prod — manual)
│   ├── release-adhoc.yml                # Ad-hoc release to any environment
│   └── templates/
│       └── deploy-environment.yml        # Reusable deploy template (used by release pipelines)
├── deploymentSettings/
│   ├── deploymentSettings_Dev.json          # Accumulated deployment settings for Dev (daily export)
│   ├── deploymentSettings_Test.json           # Accumulated deployment settings for Test (daily export)
│   ├── deploymentSettings_Stage.json        # Accumulated deployment settings for Stage (daily export)
│   └── deploymentSettings_Prod.json         # Accumulated deployment settings for Prod (daily export)
├── exports/
│   └── {yyyy-MM-dd-token}/              # Daily export (export/yyyy-MM-dd-{token} branches)
│       ├── build.json                   # Export configuration for that run
│       ├── configdata/                  # Extracted configuration data (populated by export)
│       │   └── {DataSetName}.json       #   One file per configData entry in build.json
│       ├── deploymentSettings_Test.json   # Deployment settings for Test (optional)
│       ├── deploymentSettings_Stage.json # Deployment settings for Stage (optional)
│       └── deploymentSettings_Prod.json  # Deployment settings for Prod (optional)
├── scripts/
│   ├── Merge-DeploymentSettings.ps1     # Merges export settings into root folder
│   └── Sync-ConfigData.ps1             # Extracts/upserts configuration data via Dataverse API
├── tests/
│   ├── Merge-DeploymentSettings.Tests.ps1  # Pester tests for merge logic
│   ├── Build-Json-Validation.Tests.ps1     # Pester tests for build.json validation
│   ├── Cloud-Flow-Detection.Tests.ps1      # Pester tests for cloud flow detection
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
| 2 | [Release Solutions to Test](#2-release-solutions-to-test) | Auto (on export completion) | Deploy managed solutions to Test — no approval required |
| 3 | [Release Solutions to QA](#3-release-solutions-to-qa) | Auto (on export completion) | Deploy managed solutions to QA — no approval required |
| 4 | [Promote to Stage and Prod](#4-promote-to-stage-and-prod) | Manual | Promote a selected export run to Stage and Prod with approval gates |
| 5 | [Release Ad-Hoc](#5-release-ad-hoc) | Manual | Deploy any export run to a named environment and variable group |

---

## Pipelines

### 1. Daily Export Solutions (`pipelines/export-solutions.yml`)

Exports solutions from the Power Platform **Dev** environment on a daily schedule, validates their versions against `build.json`, unpacks them into source control, exports managed solutions directly from Power Platform, and creates a PR to merge into `main`. Optionally bumps solution versions in Dev after export to prepare for the next development cycle.

**What it does:**

1. Detects a Git branch matching `export/{today's date}-{token}` (e.g., `export/2026-02-15-sprint42`)
2. Reads `exports/{date-token}/build.json` on that branch for the list of solutions and their expected versions
3. **Adds Power Pages site components** &mdash; for each solution that has `powerPagesConfiguration.addAllExistingSiteComponentsForSites` set, queries the Dev environment's Dataverse API and adds all `powerpagesite` and `powerpagecomponent` records connected to the named site(s) into the solution before export. This ensures the components are captured in the exported zip. See [`addAllExistingSiteComponentsForSites`](#solutionspowerpagesconfigurationaddallexistingsitecomponentsforsite) for details.
4. For each solution:
   - If `isExisting: true`, skips all export/unpack steps and uses a pre-existing managed zip already in the repo from `solutions/managed/{name}_{version}.zip`. Fails if the expected zip is not found.
   - Checks if a managed zip already exists for this name + version (cache check &mdash; skips if so)
   - Exports the **unmanaged** solution zip from Power Platform &rarr; `solutions/unmanaged/`
   - Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/`
   - **Detects [cloud flows](https://learn.microsoft.com/en-us/power-automate/overview-cloud)**: checks for `.json` files in the unpacked `Workflows/` directory. If found, sets `includesCloudFlows: true` on the solution entry in `build.json`
   - **Validates the version**: reads the actual version from `Other/Solution.xml` and compares it to `build.json`. If they don't match, the pipeline **fails** with an error
   - Exports the **managed** solution directly from Power Platform &rarr; `solutions/managed/`
5. Writes the updated `build.json` (with the auto-detected `includesCloudFlows` flag) and publishes it along with managed zips, config data files, and any `deploymentSettings_*.json` files as pipeline artifacts (consumed by the release pipeline)
6. **Extracts configuration data** &mdash; if `configData` is defined in `build.json`, queries each data set from Dev using OData `$select`/`$filter`, writes the results as JSON to `configdata/` inside the export folder (alongside `build.json`), and includes them in the artifact. See [Configuration Data](#configuration-data) for details.
7. **Post-export version management** &mdash; for each solution that has a `postExportVersion` defined in `build.json`, bumps that solution's version in the Dev environment after export. Solutions with `createNewPatch: true` have a new patch cloned from themselves at the new version via the Dataverse `CloneAsPatch` action; solutions with `createNewPatch: false` (or unset) get a direct version update via `pac solution online-version`. See [Post-Export Version Management](#post-export-version-management) for details.
8. **Merges deployment settings** &mdash; if `deploymentSettings_*.json` files exist in the export folder, merges them into the root `deploymentSettings/` folder. Items from the export overwrite matching items in root (matched by `SchemaName` for environment variables, `LogicalName` for connection references); new items are appended. See [Deployment Settings](#deployment-settings) for details.
9. Commits solution files, config data (in the export folder), and merged deployment settings, then pushes to the export branch
10. Creates a Pull Request to `main`, sets auto-complete (squash merge), and deletes the source branch

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

### 2. Release Solutions to Test (`pipelines/release-solutions-test.yml`)

Deploys managed solutions to the **Test** environment only. Triggers automatically when the daily export pipeline completes on `main`. No approval is required — Test deployments are fully continuous.

**What it does:**

1. Tags the pipeline run with the export branch name for traceability
2. Downloads the `ManagedSolutions` artifact from the export pipeline
3. **Validates all artifacts upfront** &mdash; checks that every `{name}_{version}.zip` (and required `deploymentSettings_Test.json`) exists before importing anything
4. Authenticates with Test using credentials from the `PowerPlatform-Test` variable group
5. Queries installed solutions in Test and for each solution in `build.json` (in order):
   - **Skip** &mdash; if already installed at the target version
   - **Fresh install** or **upgrade** &mdash; imports with the appropriate flags (see below)
   - Applies `deploymentSettings_Test.json` if `includeDeploymentSettings: true`
   - Activates cloud flows if `includesCloudFlows: true` (warnings on failure, does not fail the stage)
6. **Upserts configuration data** &mdash; if `configData` is defined in `build.json`
7. Fails the stage if any solution fails to deploy

**Trigger:** Automatic &mdash; runs when `export-solutions` completes on the `main` branch.

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `dryRun` | `false` | Validate without deploying. Logs what would be imported but makes no changes. |

**Auth:** Uses pac CLI with credentials from `PowerPlatform-Test`.

**Template:** Uses `pipelines/templates/deploy-environment.yml`.

---

### 3. Release Solutions to QA (`pipelines/release-solutions-qa.yml`)

Deploys managed solutions to the **QA** environment only. Triggers automatically when the daily export pipeline completes on `main`. No approval is required — QA deployments are fully continuous.

**What it does:**

1. Tags the pipeline run with the export branch name for traceability
2. Downloads the `ManagedSolutions` artifact from the export pipeline
3. **Validates all artifacts upfront** &mdash; checks that every `{name}_{version}.zip` (and required `deploymentSettings_QA.json`) exists before importing anything
4. Authenticates with QA using credentials from the `PowerPlatform-QA` variable group
5. Queries installed solutions in QA and for each solution in `build.json` (in order):
   - **Skip** &mdash; if already installed at the target version
   - **Fresh install** or **upgrade** &mdash; imports with the appropriate flags (see below)
   - Applies `deploymentSettings_QA.json` if `includeDeploymentSettings: true`
   - Activates cloud flows if `includesCloudFlows: true` (warnings on failure, does not fail the stage)
6. **Upserts configuration data** &mdash; if `configData` is defined in `build.json`
7. Fails the stage if any solution fails to deploy

**Trigger:** Automatic &mdash; runs when `export-solutions` completes on the `main` branch.

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `dryRun` | `false` | Validate without deploying. Logs what would be imported but makes no changes. |

**Auth:** Uses pac CLI with credentials from `PowerPlatform-QA`.

**Template:** Uses `pipelines/templates/deploy-environment.yml`.

---

### 4. Promote to Stage and Prod (`pipelines/release-solutions-promote.yml`)

Manually triggered pipeline that promotes a selected export artifact to **Stage** and then **Prod**. Run this when you are ready to promote a Test-verified build. Both environments require manual approval.

**What it does (per stage):**

1. Tags the pipeline run with the export branch name for traceability
2. Downloads the `ManagedSolutions` artifact from the selected export run
3. **Validates all artifacts upfront** &mdash; checks that every `{name}_{version}.zip` (and required `deploymentSettings_{stage}.json`) exists before importing anything. Fails immediately if any are missing
4. Authenticates with the target environment using credentials from a per-environment variable group
5. Queries all installed solutions in the target environment using `pac solution list`
6. For each solution in `build.json` (in order):
   - **Skip** &mdash; if the solution is already installed at the target version
   - **Fresh install** &mdash; if the solution doesn't exist in the target environment: imports with `--activate-plugins`
   - **Upgrade (managed)** &mdash; if the solution exists at a different version: imports with `--stage-and-upgrade --skip-lower-version --activate-plugins`
   - **Power Pages import** &mdash; if `powerPagesConfiguration` is set, the `deployMode` field overrides the default import strategy
   - If the solution has `includeDeploymentSettings: true`, applies the matching `deploymentSettings_{stage}.json` file via `--settings-file`
   - If the solution has `includesCloudFlows: true`, checks for inactive cloud flows after import and attempts to activate them. Activation failures are logged as **warnings** but do not fail the deployment
7. **Upserts configuration data** &mdash; if `configData` is defined in `build.json`, PATCHes each record into the target environment using stable GUIDs
8. Fails the stage if any solution fails to deploy

**Stages:**

| Stage | Deploys To | Trigger | Approval Required |
|---|---|---|---|
| **Stage** | Stage environment | First stage (after SetBuildName) | **Yes** &mdash; manual approval |
| **Prod** | Prod environment | After Stage succeeds | **Yes** &mdash; manual approval |

Approvals are controlled by **ADO Environment approval checks**. See [Step 5: Create ADO Environments](#step-5-create-ado-environments-release--deploy-pipelines) for setup.

**Trigger:** Manual only &mdash; no auto-trigger. When run, select the `export-solutions` run you want to promote in the **Resources** panel of the Run Pipeline dialog.

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `dryRun` | `false` | Validate without deploying. Safe to run at any time against any environment. |

**Auth:** Uses pac CLI with credentials from variable groups (`PowerPlatform-Stage`, `PowerPlatform-Prod`).

**Template:** Uses `pipelines/templates/deploy-environment.yml` for each stage.

---

### 5. Release Ad-Hoc (`pipelines/release-adhoc.yml`)

Manually triggered pipeline that deploys solutions from **any completed `export-solutions` run** into a **named environment and variable group**. Use this for environments outside the standard Test → Stage → Prod chain — such as sandboxes, UAT, or hotfix environments.

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

## Pipeline Flow

### Daily Export + Release to Test (Dev &rarr; Test)

The continuous flow. Solutions export from Dev nightly and deploy automatically to Test — no human action needed.

```
 EXPORT                                RELEASE TO TEST
 ──────                                ───────────────

┌──────────────────────────┐    ┌──────────────────────────────────────────┐
│  Daily Export Solutions   │    │  Release Solutions to Test               │
│  (scheduled / manual)    │    │  (auto-triggered on export completion)   │
│                          │    │                                          │
│  1. Detect export branch │    │  ┌──────────────────────────────────────┐│
│  2. Read build.json      │    │  │  Test (auto — no approval)           ││
│  3. Export from Dev      │───►│  │  - Validates artifacts upfront       ││
│  4. Validate versions    │    │  │  - Checks installed versions         ││
│  5. Unpack + export managed│  │  │  - Skips if already at target ver.  ││
│  6. Publish artifact     │    │  │  - Managed upgrade: stage-and-upgrade││
│  7. Post-export versions │    │  │  - Applies deployment settings       ││
│  8. Merge deploy settings│    │  │  - Activates cloud flows (warn only) ││
│  9. PR to main           │    │  └──────────────────────────────────────┘│
└──────────────────────────┘    └──────────────────────────────────────────┘
```

### Promote to Stage and Prod

A deliberate promotion step. Run manually when a Test-verified build is ready for production.

```
 PROMOTE (manual — select export run)
 ────────────────────────────────────

┌─────────────────────────────────────────────────────────────────────┐
│  Promote to Stage and Prod                                          │
│                                                                     │
│  ┌───────────────────┐  ┌───────────────────┐                      │
│  │  Stage            │  │  Prod             │                      │
│  │  (manual approval)│─►│  (manual approval)│                      │
│  │  - Same deploy    │  │  - Same deploy    │                      │
│  │    logic as Test  │  │    logic as Test  │                      │
│  └───────────────────┘  └───────────────────┘                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Architecture Overview

```
                              Power Platform CI/CD Pipelines

  ┌─────────────────────────────┐
  │  1. Daily Export Solutions   │
  │     (10 PM ET / cron)       │
  └──────────────┬──────────────┘
                 │ triggers automatically
                 ▼
  ┌─────────────────────────────┐         ┌───────┐
  │  2. Release to Test         │────────►│ Test  │
  │     (auto, no approval)     │         │ auto  │
  └─────────────────────────────┘         └───────┘

  ┌─────────────────────────────┐         ┌───────┐
  │  3. Release to QA           │────────►│  QA   │
  │     (auto, no approval)     │         │ auto  │
  └─────────────────────────────┘         └───────┘

  ┌─────────────────────────────┐         ┌───────┐  ┌───────┐
  │  4. Promote to Stage + Prod │────────►│  Stg  │─►│ Prod  │
  │     (manual, select run)    │         │ gate  │  │ gate  │
  └─────────────────────────────┘         └───────┘  └───────┘

  ┌─────────────────────────────┐
  │  5. Release Ad-Hoc          │  ← manual, targets any environment
  │     (any export artifact)   │
  └─────────────────────────────┘
```

---

## build.json Configuration

The `build.json` file defines which solutions to export and their **expected versions**. It lives on the export branch at `exports/{date-token}/build.json`.

```json
{
  "solutions": [
    { "name": "CoreComponents", "version": "1.2.0.0", "postExportVersion": "1.3.0.0", "createNewPatch": true },
    { "name": "CustomConnectors", "version": "1.0.3.0", "postExportVersion": "1.0.4.0", "createNewPatch": false },
    { "name": "MainApp", "version": "2.1.0.0", "includeDeploymentSettings": true },
    { "name": "ThirdPartyBase", "version": "3.5.0.0", "isExisting": true },
    { "name": "PowerPagesPortal", "version": "1.0.0.0", "powerPagesConfiguration": { "deployMode": "UPGRADE" } }
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
| `solutions[].isExisting` | Optional boolean (default: `false`). If `true`, the export pipeline skips exporting this solution from Power Platform and uses a pre-existing managed zip already committed to the repo from `solutions/managed/{name}_{version}.zip`. The pipeline fails if the expected zip is not found. |
| `solutions[].isRollback` | Optional boolean (default: `false`). If `true`, the deploy pipelines omit `--skip-lower-version` when importing this solution, allowing a lower (rollback) version to be installed over a higher one. Applies to all stages (Dev, Test, Stage, Prod). |
| `solutions[].powerPagesConfiguration` | Optional object. When set, overrides the default import strategy for this solution to use Power Pages-specific deployment behavior. See sub-fields below. |
| `solutions[].powerPagesConfiguration.deployMode` | Required when `powerPagesConfiguration` is set. Controls the `pac solution import` strategy: `UPGRADE` — uses `--stage-and-upgrade --skip-lower-version` (regardless of whether the solution is already installed); `UPDATE` — plain import with no staging flags; `STAGE_FOR_UPGRADE` — uses `--import-as-holding` to stage the solution without applying the upgrade. |
| `solutions[].powerPagesConfiguration.addAllExistingSiteComponentsForSites` | Optional string. Comma-separated list of Power Pages site names (as they appear in the Dev environment). When set, the export pipeline queries the Dev environment's Dataverse API and adds all `powerpagesite` and `powerpagecomponent` records connected to each named site into the solution **before** export, so they are captured in the exported zip. Only site component types are added — tables, flows, and other component types are excluded (`AddRequiredComponents = false`). The pipeline **fails** if a named site is not found in the environment. Example: `"my-portal"` or `"customer-portal, partner-portal"`. Has no effect during deployment. |

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
   - `deploymentSettings_Test.json`
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

Suppose the root `deploymentSettings/deploymentSettings_Test.json` currently contains:

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

And an export run includes `exports/2026-02-15-sprint42/deploymentSettings_Test.json` with:

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

**Example deployment settings file** (`deploymentSettings_Test.json`):

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

**Stable GUIDs:** This approach requires that the primary key GUID for each record is **the same across all environments**. When you create records in Dev, they get assigned GUIDs. Those exact GUIDs are used to create-or-update (upsert) records in Test, Stage, and Prod. The [Dataverse Web API](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/overview) `PATCH /api/data/v9.2/{entity}({guid})` creates the record with that GUID if it doesn't exist, or updates it if it does.

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
- Config data is upserted into each environment by the release pipeline after solution imports

---

## Testing

The repository includes [Pester](https://pester.dev) unit tests. Tests are in the `tests/` folder.

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
| `Add-PowerPagesSiteComponents.Tests.ps1` | Power Pages component sync: component type resolution, solution lookup, site-already-in-solution skip, site add, component diffing (new only), inadvertent table component cleanup, OData pagination, multiple sites |
| `Merge-DeploymentSettings.Tests.ps1` | Merge logic: new items appended, existing items overwritten by export, multiple environment files processed independently, empty arrays preserved |
| `Build-Json-Validation.Tests.ps1` | `build.json` validation: required fields, `includeDeploymentSettings` defaults to false, only one solution may have it set to true |
| `Cloud-Flow-Detection.Tests.ps1` | Cloud flow detection: `.json` files in `Workflows/` detected, `.xaml`-only and empty directories return false, `includesCloudFlows` flag round-trip through `build.json` serialization |
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
5. In the [Power Platform Admin Center](https://admin.powerplatform.microsoft.com), register this app as an **Application User** in **all** environments (Dev, Test, Stage, Prod) with the **System Administrator** security role

> **Note:** You can use the same app registration across all environments, or create separate ones per environment for tighter access control. See [Register an application in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app) and [Manage application users](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users) on Microsoft Learn.

### Step 3: Create Power Platform Service Connections

> **No service connections are required.** All pipelines authenticate via pac CLI using credentials from variable groups (created in Step 4). The `PowerPlatformToolInstaller@2` task is used only where Power Platform Build Tools ADO tasks are needed (daily export pipeline) &mdash; it does not require a service connection.
>
> You can skip this step entirely.

### Step 4: Create Variable Groups (Release &amp; Deploy Pipelines)

The release pipeline uses **[variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)** to store per-environment credentials. Create one group for each environment.

1. Go to **Pipelines** > **Library** > **+ Variable group**
2. Create variable groups with the following names and variables:

**`PowerPlatform-Dev`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-dev.crm.dynamics.com` | No |
| `ClientId` | Application (Client) ID | No |
| `ClientSecret` | Client secret value | **Yes** |
| `TenantId` | Directory (Tenant) ID | No |

**`PowerPlatform-Test`**

| Variable | Value | Secret? |
|---|---|---|
| `EnvironmentUrl` | `https://yourorg-test.crm.dynamics.com` | No |
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
| `Power Platform Test` | Release Solutions to Test | Deploys automatically (see note) |
| `Power Platform QA` | Release Solutions to QA | Deploys automatically (see note) |
| `Power Platform Stage` | Promote to Stage and Prod | **Add approval check** &mdash; select approver(s) |
| `Power Platform Prod` | Promote to Stage and Prod | **Add approval check** &mdash; select approver(s) |

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
| 2 | `pipelines/release-solutions-test.yml` | `release-solutions-test` |
| 3 | `pipelines/release-solutions-qa.yml` | `release-solutions-qa` |
| 4 | `pipelines/release-solutions-promote.yml` | `release-solutions-promote` |
| 5 | `pipelines/release-adhoc.yml` | `release-adhoc` |

> **Important:** All release pipelines reference the export pipeline as `source: "export-solutions"`. The export pipeline's name in ADO must match this value exactly.

### Step 7: Link Variable Groups to Pipelines

Each pipeline must be authorized to use its variable group(s). After creating the variable groups in Step 4:

1. Open each variable group in **Pipelines** > **Library**
2. Click **Pipeline permissions**
3. Click **+** and add the pipeline(s) that use that group:

| Variable Group | Used By |
|---|---|
| `PowerPlatform-Dev` | Daily Export Solutions |
| `PowerPlatform-Test` | Release Solutions to Test |
| `PowerPlatform-QA` | Release Solutions to QA |
| `PowerPlatform-Stage` | Promote to Stage and Prod |
| `PowerPlatform-Prod` | Promote to Stage and Prod |
| *(your group)* | Release Ad-Hoc (specified at runtime — no pre-authorization needed if the pipeline is set to allow all variable groups) |

### Step 8: Update Pipeline Variables

All pipelines use variable groups for configuration &mdash; there are no inline service connection names to update. If you named your variable groups differently from the defaults, update the `group:` references in each pipeline YAML.

**`pipelines/export-solutions.yml`:**

Uses the `PowerPlatform-Dev` variable group. No inline variables to configure &mdash; all credentials and the environment URL come from the variable group.

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
- Mark the pipeline as **Cancelled** (not failed) if no matching branch is found — this prevents the release pipeline from triggering on nights with no export
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

If using deployment settings, create a settings file for each target environment in the same folder (e.g., `exports/2026-02-15-sprint42/deploymentSettings_Test.json`, `deploymentSettings_Stage.json`, `deploymentSettings_Prod.json`). See [Deployment Settings](#deployment-settings) for the file format.

```bash
git add exports/
git commit -m "configure export for 2026-02-15-sprint42"
git push -u origin export/2026-02-15-sprint42
```

**To run manually:** Go to **Pipelines** > select `export-solutions` > **Run pipeline**. Optionally supply an export branch to skip auto-detect.

### Release to Test (Automatic)

The `release-solutions-test` pipeline triggers automatically after the export pipeline completes. No manual action is needed — Test deploys continuously.

**Dry run:**

To validate what *would* be deployed to Test without making any changes:

1. Go to **Pipelines** > select `release-solutions-test` > **Run pipeline**
2. Set `dryRun` to `true`
3. Click **Run**

### Promote to Stage and Prod (Manual)

When you are ready to promote a Test-verified build to production environments:

1. Go to **Pipelines** > select `release-solutions-promote` > **Run pipeline**
2. In the **Resources** panel, expand `export-solutions` and select the specific run you want to promote
3. Click **Run**
4. After the Stage stage starts, approvers will receive a notification &mdash; go to the running pipeline and click **Review** > **Approve**
5. Repeat approval for Prod after Stage completes

The pipeline will skip any solution already installed at the target version in each environment.

**Dry run:**

To validate what *would* be promoted without making any changes:

1. Go to **Pipelines** > select `release-solutions-promote` > **Run pipeline**
2. Select the export run in **Resources** and set `dryRun` to `true`
3. Click **Run**

The pipeline authenticates with each environment, validates all artifacts, queries currently installed solution versions, and logs the exact `pac solution import` command that *would* be run &mdash; but no imports are executed and no config data is upserted.

### Release Ad-Hoc (Manual)

To deploy any export run to an environment outside the standard Test → Stage → Prod chain:

1. Go to **Pipelines** > select `release-adhoc` > **Run pipeline**
2. Fill in the parameters:
   - **ADO Environment name** — the environment to deploy into (e.g., `Power Platform Sandbox`)
   - **Variable group name** — the library variable group with credentials for that environment (e.g., `PowerPlatform-Sandbox`)
3. In the **Resources** panel, select the `export-solutions` run whose artifact you want to deploy
4. Click **Run**

The pipeline deploys all solutions from the selected export run using the same version-skip and upgrade logic as the standard release pipeline. If a `deploymentSettings_{variableGroup}.json` file is present in the artifact, it will be applied automatically.

> **Note:** The variable group named in step 2 must be authorized for the `release-adhoc` pipeline. Open the variable group in **Pipelines > Library > Pipeline permissions** and add `release-adhoc` if it is not already listed.

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
| Pipeline shows as **Cancelled** with "No export branch found" | No branch matching `export/{today}-*` exists | This is expected on nights with no planned release — create the export branch and push it before the scheduled run when a release is needed. The release pipeline will not trigger on cancelled runs. |
| "build.json not found" | The `exports/{subfolder}/build.json` file is missing on the export branch | Ensure the file path matches the branch name (minus the `export/` prefix) |
| "build.json validation failed: isUnmanaged=true is not supported" | A solution has `isUnmanaged: true` | Deploying unmanaged solutions is not supported. Remove the `isUnmanaged` field from the solution entry. |
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

### Release Solutions to Test / Promote to Stage and Prod

| Symptom | Cause | Fix |
|---|---|---|
| Release to Test / QA pipeline doesn't trigger | Export pipeline name mismatch | Ensure the export pipeline is named `export-solutions` in ADO (must match `source` in `release-solutions-test.yml` and `release-solutions-qa.yml`) |
| Release to Test / QA pipeline doesn't trigger | Export didn't run on `main` | The release only triggers when the export pipeline runs against the `main` branch |
| "build.json not found in artifact" | Export pipeline didn't publish artifacts | Check the export pipeline logs &mdash; it may have been cancelled (no export branch found, which should not trigger the release) or failed before artifact publishing |
| "Failed to authenticate" in a stage | Variable group misconfigured | Verify the variable group for that stage has correct `EnvironmentUrl`, `ClientId`, `ClientSecret`, and `TenantId` |
| "Failed to list solutions" | SPN lacks read access to target environment | Ensure the app user has System Administrator or System Customizer role in the target environment |
| "Failed to import solution" | Missing dependencies, invalid solution, or insufficient permissions | Check the pipeline logs for the detailed Dataverse error. Common causes: a dependent solution is missing, version downgrade attempted, or SPN lacks import permissions |
| Stage/Prod stuck waiting | No one has approved | Approvers need to go to the `release-solutions-promote` run and click **Approve** on the pending stage |
| "Managed zip not found in artifact" | Artifact filename doesn't match build.json | Ensure solution names and versions in `build.json` match exactly (filenames are `{name}_{version}.zip`) |
| Solutions always skipped | Already deployed at target version | This is expected behavior &mdash; the pipeline only deploys when the version changes |
| "includeDeploymentSettings is true but deploymentSettings_{stage}.json was not found" | Deployment settings file missing from artifact | Ensure the file exists in the same folder as `build.json` on the export branch (e.g., `exports/{date-token}/deploymentSettings_Test.json`) |
| "Artifact validation failed" | One or more solution zips or deployment settings files missing from artifact | The pipeline validates all artifacts upfront before importing anything. Ensure all solutions in `build.json` were exported successfully and all required `deploymentSettings_*.json` files exist |
| "Failed to activate flow" warning | Cloud flow could not be turned on after import | Common causes: connection references not resolved, SPN lacks access to the underlying connections, or flow suspended by DLP policy. Manually activate the flow in the Power Automate portal or resolve the underlying issue |
| "Could not acquire Dataverse API token" warning | OAuth token request for flow activation failed | Verify `ClientId`, `ClientSecret`, and `TenantId` are correct. Solution imports are not affected &mdash; only flow activation is skipped |

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
