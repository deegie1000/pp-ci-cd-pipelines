# Power Platform CI/CD Pipelines

Azure DevOps pipelines for exporting, versioning, and deploying Power Platform solutions across environments.

## Repository Structure

```
pp-ci-cd-pipelines/
├── pipelines/
│   ├── export-solutions.yml             # Daily scheduled export (Dev → repo)
│   ├── release-solutions.yml            # Release pipeline (QA → Stage → Prod)
│   ├── export-solution-predev.yml       # On-demand single solution export (Pre-Dev)
│   ├── deploy-solution.yml              # Multi-stage deploy (Dev → QA → Stage → Prod)
│   └── templates/
│       ├── deploy-environment.yml        # Reusable deploy template (used by release pipeline)
│       └── deploy-single-solution.yml    # Reusable deploy template (used by deploy pipeline)
├── configData/                           # Extracted configuration data (populated by export)
├── deploymentSettings/
│   ├── deploymentSettings_Dev.json      # Accumulated deployment settings for Dev
│   ├── deploymentSettings_QA.json       # Accumulated deployment settings for QA
│   ├── deploymentSettings_Stage.json    # Accumulated deployment settings for Stage
│   └── deploymentSettings_Prod.json     # Accumulated deployment settings for Prod
├── exports/
│   └── {yyyy-MM-dd-dv-requestid}/
│       └── build.json                   # Generated from Dataverse Export Request
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
| 1 | [Daily Export Solutions](#1-daily-export-solutions) | Scheduled (10 PM ET daily) | Query Dataverse for export request, export from Dev, pack managed, PR to main |
| 2 | [Release Solutions](#2-release-solutions) | Auto (on export completion) | Deploy managed solutions through QA → Stage → Prod, update Dataverse status |
| 3 | [Export from Pre-Dev](#3-export-solution-from-pre-dev) | Manual | Export single solution from Pre-Dev, commit, trigger Dev deploy |
| 4 | [Deploy Solution](#4-deploy-solution) | Auto (on Pre-Dev export) | Deploy managed solution through Dev &rarr; QA &rarr; Stage &rarr; Prod |

---

## Pipelines

### 1. Daily Export Solutions (`pipelines/export-solutions.yml`)

Exports solutions from the Power Platform **Dev** environment on a daily schedule using a **Dataverse-driven** approach. Instead of reading from a manually-created Git export branch, the pipeline queries custom Dataverse tables for a queued **Export Request** record, reads the solution list and configuration from related tables, validates versions, unpacks into source control, converts to managed packages, and creates a PR to merge into `main`. Status and pipeline links are written back to the Dataverse record so users can track progress from a model-driven app.

**Dataverse custom tables** (see [Dataverse Custom Tables](#dataverse-custom-tables) for full schema):

| Table | Purpose |
|---|---|
| **Export Request** (`cr_exportrequest`) | Defines an export run &mdash; status, post-export version, pipeline URLs, per-stage deploy status |
| **Export Request Solution** (`cr_exportrequestsolution`) | Child rows listing which solutions to export and their expected versions |
| **Config Data Definition** (`cr_configdatadefinition`) | Child rows defining configuration data sets to extract (optional) |

**What it does:**

1. Queries Dataverse for the next Export Request with status = **Queued** (ordered by creation date)
2. Updates the request status to **In Progress** and writes the pipeline run URL back to the record
3. Reads the related Export Request Solution and Config Data Definition records
4. Generates `build.json` from the Dataverse data (including `exportRequestId` for downstream tracking)
5. Creates a working branch (`export/{date}-dv-{short-id}`) from `main`
6. For each solution:
   - Checks if a managed zip already exists for this name + version (cache check &mdash; skips if so)
   - Exports the **unmanaged** solution zip from Power Platform &rarr; `solutions/unmanaged/`
   - Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/`
   - **Detects cloud flows**: checks for `.json` files in the unpacked `Workflows/` directory. If found, sets `includesCloudFlows: true` on the solution entry in `build.json`
   - **Validates the version**: reads the actual version from `Other/Solution.xml` and compares it to the Export Request Solution record. If they don't match, the pipeline **fails** with an error
   - **Detects patches**: reads `Other/Solution.xml` for a `<ParentSolution>` element. If found, sets `isPatch: true`, `parentSolution`, and `displayName` on the solution entry in `build.json`
   - Packs the unpacked source as a **managed** solution &rarr; `solutions/managed/`
7. Writes the updated `build.json` (with auto-detected flags) and publishes it along with managed zips, config data files, and `deploymentSettings_*.json` files from the root `deploymentSettings/` folder as pipeline artifacts
8. **Extracts configuration data** &mdash; if Config Data Definition records exist on the Export Request, queries each data set from Dev using OData, writes the results as JSON to `configData/`, and includes them in the artifact. See [Configuration Data](#configuration-data) for details.
9. **Post-export version management** &mdash; if `postExportVersion` is set on the Export Request, bumps all solution versions in Dev after export. Non-patch solutions get a direct version update; patch solutions have their display name prefixed and a new patch is cloned from the parent at the new version. See [Post-Export Version Management](#post-export-version-management) for details.
10. Commits solution files, config data, and generated `build.json`, then pushes to the working branch
11. Creates a Pull Request to `main`, sets auto-complete (squash merge), and deletes the source branch
12. **Updates the Export Request** in Dataverse &mdash; sets per-solution statuses (Completed/Failed), auto-detected flags (`includesCloudFlows`, `isPatch`), and marks the request as **Completed** or **Failed**

**Version validation:** During export, the Export Request Solution records are the source of truth for expected versions. If a solution's version in the Dev environment doesn't match the expected version, the pipeline fails immediately with a message like:

```
Version mismatch for 'MySolution': export request specifies v1.0.0.0 but dev environment has v1.1.0.0.
Update the Export Request Solution record to match.
```

If `postExportVersion` is set, the pipeline bumps versions in Dev **after** the export and artifact publishing are complete. This does not affect the exported artifacts &mdash; they retain the original versions.

**Failure handling:** If the pipeline fails at any step after the Export Request is picked up, a dedicated failure handler step marks the request as **Failed** with an error details message and timestamp. This ensures users always see the correct status in the model-driven app.

**Trigger:** Daily at **10:00 PM Eastern Time** (3:00 AM UTC). Also runnable manually with an optional override to process a specific Export Request by ID. Can be triggered on-demand from Dataverse by setting an Export Request status to **Run Now** (requires a cloud flow; see [Run Now: Ad-Hoc Export via Cloud Flow](#run-now-ad-hoc-export-via-cloud-flow)).

**Parameters (manual runs):**

| Parameter | Description |
|---|---|
| `exportRequestId` | Override &mdash; process a specific Export Request by GUID (skip queue lookup) |

**Auth:** Uses pac CLI with secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`). The same credentials are used for Dataverse API calls to the Export Request tables.

**Artifact published:** `ManagedSolutions` &mdash; contains `build.json` (with `exportRequestId`), `{SolutionName}_{version}.zip` files, and `deploymentSettings_*.json` files from the root `deploymentSettings/` folder.

---

### 2. Release Solutions (`pipelines/release-solutions.yml`)

Deploys managed solutions through three environments in sequence: **QA &rarr; Stage &rarr; Prod**. Triggers automatically when the daily export pipeline completes on `main`. When the artifact contains an `exportRequestId`, each stage updates the corresponding deploy status and release pipeline URL on the Dataverse Export Request record.

**What it does (per stage):**

1. Downloads the `ManagedSolutions` artifact from the export pipeline
2. **Updates Dataverse** &mdash; reads `exportRequestId` from `build.json`, sets the stage's deploy status to **In Progress**, and writes the release pipeline URL back to the Export Request record (skipped gracefully if no `exportRequestId` present)
3. **Validates all artifacts upfront** &mdash; checks that every `{name}_{version}.zip` (and required `deploymentSettings_{stage}.json`) exists before importing anything. Fails immediately if any are missing
4. Authenticates with the target environment using credentials from a per-environment variable group
5. Queries all installed solutions in the target environment using `pac solution list`
6. For each solution in `build.json` (in order):
   - **Skip** &mdash; if the solution is already installed at the target version
   - **Fresh install** &mdash; if the solution doesn't exist in the target environment
   - **Upgrade** &mdash; if the solution exists but at a different version
   - Imports as managed with `--stage-and-upgrade --skip-lower-version --activate-plugins`
   - If the solution has `includeDeploymentSettings: true` in `build.json`, applies the matching `deploymentSettings_{stage}.json` file via `--settings-file`
   - If the solution has `includesCloudFlows: true`, checks for inactive cloud flows after import and attempts to activate them. Activation failures are logged as **warnings** but do not fail the deployment
7. **Upserts configuration data** &mdash; if `configData` is defined in `build.json`, PATCHes each record into the target environment using stable GUIDs. Record-level failures are logged as **warnings** but do not fail the deployment. See [Configuration Data](#configuration-data)
8. **Updates Dataverse** &mdash; sets the stage's deploy status to **Completed** or **Failed** with a timestamp (skipped gracefully if no `exportRequestId`)
9. Fails the stage if any solution fails to deploy

**Stages:**

| Stage | Deploys To | Trigger | Approval Required |
|---|---|---|---|
| **QA** | QA environment | Automatic (on export completion) | No |
| **Stage** | Stage environment | After QA succeeds | **Yes** &mdash; manual approval |
| **Prod** | Prod environment | After Stage succeeds | **Yes** &mdash; manual approval |

Stage and Prod approvals are controlled by **ADO Environment approval checks** (not pipeline gates). See [Step 5: Create ADO Environments](#step-5-create-ado-environments-release-pipeline) for setup.

**Trigger:** Automatic &mdash; runs when the `export-solutions` pipeline completes on the `main` branch.

**Auth:** Uses pac CLI with credentials from variable groups (`PowerPlatform-QA`, `PowerPlatform-Stage`, `PowerPlatform-Prod`).

**Template:** Uses `pipelines/templates/deploy-environment.yml` for each stage to keep the logic DRY.

---

### 3. Export Solution from Pre-Dev (`pipelines/export-solution-predev.yml`)

On-demand pipeline that exports a **single solution** from the **Pre-Dev** environment and promotes it through the build process.

**What it does:**

1. Exports the specified solution as **unmanaged** from Pre-Dev &rarr; `solutions/unmanaged/{name}.zip`
2. Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/{name}/`
3. Packs the unpacked source as a **managed** solution &rarr; `solutions/managed/{name}.zip`
4. Commits the results and pushes to the repository
5. Publishes the managed zip and `deploymentSettings_Dev.json` (from root `deploymentSettings/`, if it exists) as a pipeline artifact
6. **Automatically triggers** the Deploy Solution pipeline (Dev &rarr; QA &rarr; Stage &rarr; Prod)

**Trigger:** Manual only (run on demand from the ADO UI).

**Auth:** Service connection only &mdash; no secret pipeline variables needed.

---

### 4. Deploy Solution (`pipelines/deploy-solution.yml`)

Multi-stage pipeline that deploys a single managed solution through all environments in sequence: **Dev &rarr; QA &rarr; Stage &rarr; Prod**. Runs automatically after the Pre-Dev export pipeline completes, or can be triggered manually.

**What it does (per stage):**

1. Downloads the managed solution artifact (Dev downloads from the export pipeline; QA/Stage/Prod download from the Dev stage's published artifact)
2. Authenticates with the target environment using credentials from a per-environment variable group
3. Checks for `deploymentSettings_{stage}.json` &mdash; in the artifact (Dev, auto-triggered) or in root `deploymentSettings/` folder (Dev manual, and all downstream stages)
4. Imports the managed solution, applying deployment settings if found
5. **Upserts configuration data** &mdash; if `build.json` is present in the artifact and contains `configData`, PATCHes each record into the target environment. See [Configuration Data](#configuration-data)

**Stages:**

| Stage | Deploys To | Trigger | Approval Required |
|---|---|---|---|
| **Dev** | Dev environment | Automatic (on Pre-Dev export completion) | No |
| **QA** | QA environment | After Dev succeeds | **Yes** &mdash; manual approval |
| **Stage** | Stage environment | After QA succeeds | **Yes** &mdash; manual approval |
| **Prod** | Prod environment | After Stage succeeds | **Yes** &mdash; manual approval |

QA, Stage, and Prod approvals are controlled by **ADO Environment approval checks**. See [Step 5: Create ADO Environments](#step-5-create-ado-environments-release-pipeline) for setup.

**Trigger:** Automatic (on completion of the Pre-Dev export pipeline) or manual with a `solutionName` parameter.

**Parameters (manual runs):**

| Parameter | Description |
|---|---|
| `solutionName` | The solution's unique name as it appears in Power Platform. Required for manual runs; ignored for auto-triggered runs. |

**Auth:** Uses pac CLI with credentials from variable groups (`PowerPlatform-Dev`, `PowerPlatform-QA`, `PowerPlatform-Stage`, `PowerPlatform-Prod`).

**Template:** Uses `pipelines/templates/deploy-single-solution.yml` for QA, Stage, and Prod stages to keep the logic DRY.

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
│  1. Query Dataverse for  │    │  ┌─────────┐  ┌─────────┐  ┌────────────┐ │
│     queued Export Request│    │  │   QA    │  │  Stage  │  │    Prod    │ │
│  2. Build config from DV │    │  │  (auto) │─►│(manual) │─►│  (manual)  │ │
│  3. Export from Dev      │───►│  │         │  │         │  │            │ │
│  4. Validate versions    │    │  └─────────┘  └─────────┘  └────────────┘ │
│  5. Unpack + pack managed│    │                                             │
│  6. Publish artifact     │    │  Each stage:                                │
│  7. Post-export versions │    │  - Updates Dataverse status (In Progress)   │
│  8. PR to main           │    │  - Validates all artifacts upfront          │
│  9. Update DV status     │    │  - Checks installed versions                │
│                          │    │  - Skips if already at target version       │
└──────────────────────────┘    │  - Imports managed + stage-and-upgrade      │
         │                      │  - Applies deployment settings if enabled   │
         ▼                      │  - Activates cloud flows (warn on failure)  │
┌──────────────────────────┐    │  - Updates Dataverse status (Completed)     │
│  Dataverse Export Request│    └─────────────────────────────────────────────┘
│  ● Export status         │                     │
│  ● Export pipeline URL   │                     ▼
│  ● QA/Stage/Prod status  │    ┌─────────────────────────────────────────────┐
│  ● Release pipeline URL  │◄───│  Dataverse Export Request updated per stage │
└──────────────────────────┘    └─────────────────────────────────────────────┘
```

### Pre-Dev Promotion (On-Demand: Dev &rarr; QA &rarr; Stage &rarr; Prod)

```
┌─────────────────────────────────┐       ┌──────────────────────────────────────────────────┐
│  Export Solution from Pre-Dev   │       │  Deploy Solution                                 │
│  (manual trigger)               │       │  (auto-triggered on export completion)            │
│                                 │       │                                                   │
│  1. Export unmanaged from       │       │  ┌───────┐     ┌───────┐     ┌───────┐  ┌──────┐│
│     Pre-Dev environment         │  ───► │  │  Dev  │────►│  QA   │────►│ Stage │─►│ Prod ││
│  2. Clean unpack                │       │  │ (auto)│     │(appv.)│     │(appv.)│  │(appv)││
│  3. Pack as managed             │       │  └───────┘     └───────┘     └───────┘  └──────┘│
│  4. Commit to repo              │       │                                                   │
│  5. Publish artifact + settings │       │  Each stage:                                      │
│                                 │       │  - Imports managed solution                        │
│                                 │       │  - Applies deployment settings if available        │
└─────────────────────────────────┘       └──────────────────────────────────────────────────┘
```

### Architecture Overview

```
                              Power Platform CI/CD Pipelines

  ON-DEMAND (single solution)                  SCHEDULED (multi-solution, Dataverse-driven)
  ───────────────────────────                  ────────────────────────────────────────────

                                               ┌─────────────────────────────┐
                                               │  Dataverse Export Request   │
                                               │  (model-driven app UI)     │
                                               └──────────────┬──────────────┘
                                                              │ queued
                                                              ▼
  ┌─────────────────────────────┐              ┌─────────────────────────────┐
  │  3. Export from Pre-Dev     │              │  1. Daily Export Solutions   │
  │     (manual trigger)        │              │     (10 PM ET / cron)       │
  └──────────────┬──────────────┘              └──────────────┬──────────────┘
                 │ triggers                                   │ triggers
                 ▼                                            ▼
  ┌─────────────────────────────┐              ┌─────────────────────────────┐
  │  4. Deploy Solution         │              │  2. Release Solutions       │
  │     Dev → QA → Stg → Prod  │              │     QA → Stage → Prod      │
  │     (single solution)       │              │     (multi-solution)        │
  └─────────────────────────────┘              └─────────────────────────────┘

  Approval gates:                              Approval gates:
  ┌─────┐  ┌─────┐  ┌─────┐  ┌──────┐        ┌─────┐  ┌─────┐  ┌──────┐
  │ Dev │─►│ QA  │─►│ Stg │─►│ Prod │        │ QA  │─►│ Stg │─►│ Prod │
  │auto │  │gate │  │gate │  │gate  │        │auto │  │gate │  │gate  │
  └─────┘  └─────┘  └─────┘  └──────┘        └─────┘  └─────┘  └──────┘

                                               Status updates written back
                                               to Dataverse Export Request
                                               at each stage boundary
```

---

## build.json Configuration

The `build.json` file defines which solutions to export and their **expected versions**. It is generated automatically by the export pipeline from the Dataverse Export Request records and written to `exports/{date-dv-requestid}/build.json`. It also carries the `exportRequestId` so the release pipeline can link back to the Dataverse record for status updates.

```json
{
  "exportRequestId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "postExportVersion": "2.0.0.0",
  "solutions": [
    { "name": "CoreComponents", "version": "1.2.0.0" },
    { "name": "CustomConnectors", "version": "1.0.3.0" },
    { "name": "MainApp", "version": "2.1.0.0", "includeDeploymentSettings": true }
  ],
  "configData": [
    {
      "name": "USStates",
      "entity": "cr123_states",
      "primaryKey": "cr123_stateid",
      "select": "cr123_name,cr123_abbreviation,cr123_fipscode",
      "filter": "statecode eq 0",
      "dataFile": "configData/USStates.json"
    }
  ]
}
```

### Solutions Fields

| Field | Description |
|---|---|
| `exportRequestId` | Auto-generated GUID linking this `build.json` to the Dataverse Export Request record. Used by the release pipeline to write deploy status and pipeline URLs back to Dataverse. Do not set this manually &mdash; it is written by the export pipeline. |
| `postExportVersion` | Optional root-level string (set on the Export Request record). If set, the export pipeline bumps all solutions in Dev to this version after export. Non-patch solutions get a direct version update; patch solutions are cloned from the parent at this version (see [Post-Export Version Management](#post-export-version-management)). |
| `solutions` | Ordered array of solutions to export. Order matters &mdash; the release pipeline deploys in this order (put dependencies first). |
| `solutions[].name` | The solution's **unique name** as it appears in Power Platform (not the display name). |
| `solutions[].version` | The **exact version** expected in the Dev environment. Must match the version in Dev's `Solution.xml`, or the export pipeline will fail. |
| `solutions[].includeDeploymentSettings` | Optional boolean (default: `false`). If `true`, the release pipeline will apply a deployment settings file (`deploymentSettings_{stage}.json`) when importing this solution. Only one solution should have this set to `true`. |
| `solutions[].includesCloudFlows` | **Auto-detected** boolean. Set to `true` by the export pipeline if the unpacked solution contains cloud flows (`.json` files in the `Workflows/` directory). Do not set this manually &mdash; it is written by the pipeline during export. |
| `solutions[].isPatch` | **Auto-detected** boolean. Set to `true` if the unpacked `Solution.xml` contains a `<ParentSolution>` element. Do not set this manually. |
| `solutions[].parentSolution` | **Auto-detected** string. The unique name of the parent solution (only set when `isPatch` is `true`). |
| `solutions[].displayName` | **Auto-detected** string. The solution's localized display name (only set when `isPatch` is `true`). |

### Config Data Fields

| Field | Description |
|---|---|
| `configData` | Optional array of configuration data sets to extract from Dev and upsert into target environments. See [Configuration Data](#configuration-data). |
| `configData[].name` | Friendly name for the data set (used in pipeline logs and summaries). |
| `configData[].entity` | Dataverse table logical name in **plural form** for OData (e.g., `cr123_states`). |
| `configData[].primaryKey` | Primary key column name. The GUID in this column must be **stable across all environments** &mdash; the same record has the same GUID everywhere. |
| `configData[].select` | Comma-separated list of columns to extract and upsert (OData `$select`). Do **not** include the primary key here &mdash; it is added automatically. |
| `configData[].filter` | Optional OData `$filter` expression to scope which rows are extracted (e.g., `statecode eq 0`). Omit to extract all rows. |
| `configData[].dataFile` | Path to the JSON data file relative to the repository root (e.g., `configData/USStates.json`). Created/updated by the export pipeline. |

**How versions work:**

- The version in the Export Request Solution record (which populates `build.json`) must match the version in the Dev environment exactly
- The export pipeline **reads** the version from Dev after unpack and **compares** it &mdash; it never writes or changes versions
- If you increment a solution version in Dev, update the Export Request Solution record to match before the next export run
- The release pipeline uses the same version from `build.json` to name artifact files and check target environments
- Solution zip files are named `{name}_{version}.zip` (e.g., `CoreComponents_1.2.0.0.zip`)

**Caching:** If a managed zip for the exact name + version already exists in `solutions/managed/`, the export pipeline skips re-exporting that solution and uses the cached file. This makes re-runs efficient when only some solutions have changed.

### Deployment Settings

Deployment settings allow you to configure environment-specific values (such as connection references and environment variables) that get applied when importing a solution into a target environment.

**How it works:**

1. Set `"includeDeploymentSettings": true` on **one** solution in the Export Request (or `build.json`)
2. Maintain deployment settings files in the root `deploymentSettings/` folder, named by environment:
   - `deploymentSettings_QA.json`
   - `deploymentSettings_Stage.json`
   - `deploymentSettings_Prod.json`
3. The export pipeline copies these files from the root folder into the `ManagedSolutions` artifact automatically (excluding `deploymentSettings_Dev.json`)
4. During deployment, the release pipeline passes the matching file to `pac solution import --settings-file`

**Root `deploymentSettings/` folder:**

The repository maintains a root `deploymentSettings/` folder that holds the canonical set of deployment settings for all environments. Update these files directly on `main` when connection references or environment variables change. The export pipeline reads from this folder &mdash; no per-export settings files are needed.

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
- If `includeDeploymentSettings` is `true` but the corresponding `deploymentSettings_{stage}.json` file is missing from the root `deploymentSettings/` folder (and therefore the artifact), the deployment **fails** with an error

### Post-Export Version Management

If `build.json` includes a root-level `postExportVersion` property, the export pipeline automatically bumps solution versions in the Dev environment **after** exporting and publishing artifacts. This prepares Dev for the next development cycle.

**How it works:**

| Solution Type | Action |
|---|---|
| **Non-patch** | Calls `pac solution online-version` to set the solution's version to `postExportVersion` directly |
| **Patch** | 1. Renames the current patch's display name to add a prefix (e.g., `(DO NOT USE) My Patch`). 2. Calls the Dataverse `CloneAsPatch` action to create a new patch from the parent solution at `postExportVersion`. The new patch inherits the original display name. |

**Patch detection:** The pipeline reads each solution's `Other/Solution.xml` after unpacking. If a `<ParentSolution>` element exists, the solution is identified as a patch. The parent solution's unique name and the patch's display name are stored on the `build.json` solution entry.

**Configuring the patch prefix:**

The `PatchDisplayNamePrefix` variable controls the text prepended to old patch display names. It defaults to `(DO NOT USE) ` and can be overridden in the ADO pipeline variables:

```yaml
variables:
  - name: PatchDisplayNamePrefix
    value: "(DO NOT USE) "      # Change this to customize the prefix
```

**Example:**

Given `build.json`:
```json
{
  "postExportVersion": "2.0.0.0",
  "solutions": [
    { "name": "CoreComponents", "version": "1.5.0.0" },
    { "name": "CorePatch", "version": "1.5.0.1" }
  ]
}
```

If `CorePatch` is detected as a patch of `CoreComponents`:
1. `CoreComponents` &rarr; version bumped to `2.0.0.0`
2. `CorePatch` &rarr; display name changed to `(DO NOT USE) CorePatch`, then a new patch of `CoreComponents` is cloned at `2.0.0.0`

If `postExportVersion` is omitted from `build.json`, this step is skipped entirely.

### Configuration Data

Configuration data allows you to move reference/lookup data (such as US States, Country Codes, or any Dataverse table rows) across environments automatically. Data is extracted from Dev during the export pipeline and upserted into each target environment during deployment.

**How it works:**

1. Define one or more data sets in the `configData` array of `build.json`
2. During the daily export, the pipeline queries each data set from Dev using OData (`$select` + optional `$filter`)
3. Results are written as JSON files to `configData/` in the repository and included in the pipeline artifact
4. During deployment, the pipeline reads each data file and PATCHes every record into the target environment using the record's primary key GUID

**Stable GUIDs:** This approach requires that the primary key GUID for each record is **the same across all environments**. When you create records in Dev, they get assigned GUIDs. Those exact GUIDs are used to create-or-update (upsert) records in QA, Stage, and Prod. The Dataverse Web API `PATCH /api/data/v9.2/{entity}({guid})` creates the record with that GUID if it doesn't exist, or updates it if it does.

**Data file format** (`configData/USStates.json`):

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
- Data files are committed to the working branch and included in the PR to `main`
- Config data is included in the `ManagedSolutions` artifact alongside solution zips and deployment settings
- The deploy-solution pipeline (pipeline 4) passes config data through the `DeploySolution` artifact chain from Dev to downstream stages

---

## Dataverse Custom Tables

The export pipeline queries three custom Dataverse tables to determine what to export. These tables should be deployed to the **Dev** environment (or a dedicated admin environment) as part of a managed or unmanaged solution.

> **Note:** The table/column names below use the `cr_` publisher prefix as a placeholder. Replace `cr_` with your actual publisher prefix.

### Export Request (`cr_exportrequest`)

| Column | Type | Description |
|---|---|---|
| `cr_name` | Text | Auto-generated or user-provided name (e.g., `2026-02-18-001`) |
| `cr_status` | Choice | `0` = Draft, `1` = Queued, `2` = In Progress, `3` = Completed, `4` = Failed, `5` = Run Now |
| `cr_postexportversion` | Text | Optional. If set, the pipeline bumps all Dev solution versions to this after export |
| `cr_pipelinerunurl` | URL | Set by the export pipeline &mdash; link to the ADO export build |
| `cr_releasepipelineurl` | URL | Set by the release pipeline &mdash; link to the ADO release build |
| `cr_qadeploystatus` | Choice | `0` = Pending, `2` = In Progress, `3` = Completed, `4` = Failed |
| `cr_qacompletedon` | DateTime | Set by the release pipeline when QA stage finishes |
| `cr_stagedeploystatus` | Choice | Same values as QA |
| `cr_stagecompletedon` | DateTime | Set by the release pipeline when Stage finishes |
| `cr_proddeploystatus` | Choice | Same values as QA |
| `cr_prodcompletedon` | DateTime | Set by the release pipeline when Prod finishes |
| `cr_completedon` | DateTime | Set by the export pipeline when export finishes |
| `cr_errordetails` | Multiline Text | Set on failure &mdash; pipeline error message |

### Export Request Solution (`cr_exportrequestsolution`)

| Column | Type | Description |
|---|---|---|
| `cr_exportrequest` | Lookup | Parent Export Request |
| `cr_solutionname` | Text | Solution unique name (e.g., `CoreComponents`) |
| `cr_expectedversion` | Text | Expected version in Dev (e.g., `1.2.0.0`) |
| `cr_includedeploymentsettings` | Yes/No | If `true`, deployment settings are applied during import |
| `cr_sortorder` | Whole Number | Optional. Controls export/deploy order (lower = first) |
| `cr_status` | Choice | `0` = Pending, `2` = Exported, `3` = Failed, `4` = Skipped |
| `cr_includescloudflows` | Yes/No | Auto-detected by the export pipeline |
| `cr_ispatch` | Yes/No | Auto-detected by the export pipeline |
| `cr_parentsolution` | Text | Auto-detected &mdash; parent solution unique name (patches only) |
| `cr_errordetails` | Multiline Text | Set on failure |

### Config Data Definition (`cr_configdatadefinition`)

| Column | Type | Description |
|---|---|---|
| `cr_exportrequest` | Lookup | Parent Export Request |
| `cr_name` | Text | Friendly name for the data set (e.g., `USStates`) |
| `cr_entity` | Text | OData plural entity set name (e.g., `cr123_states`) |
| `cr_primarykey` | Text | Primary key column name (must be stable GUID) |
| `cr_selectcolumns` | Text | Comma-separated columns to extract |
| `cr_filter` | Text | Optional OData `$filter` expression |
| `cr_datafile` | Text | Path to JSON data file (e.g., `configData/USStates.json`) |

### User Experience

Users interact with these tables through a model-driven app. The typical workflow is:

1. **Create** an Export Request (status = Draft)
2. **Add** solution rows with names, versions, and settings flags
3. **Add** config data definitions if needed
4. **Choose** when to run:
   - Set status to **Queued** &mdash; the next scheduled pipeline run (10 PM ET) picks it up
   - Set status to **Run Now** &mdash; a cloud flow immediately triggers the pipeline (see [Run Now: Ad-Hoc Export via Cloud Flow](#run-now-ad-hoc-export-via-cloud-flow))
5. **Monitor** status changes and click pipeline URLs to see ADO logs
6. **Track** deployment progress through QA, Stage, and Prod from the same record

```
┌──────────────────────────────────────────────────────────────┐
│  Export Request: 2026-02-18-001                              │
│  Requested By: Jane Smith         Requested On: Feb 18 3pm  │
│                                                              │
│  Export Status:   ● Completed     🔗 View Export Pipeline    │
│  Release Status:                  🔗 View Release Pipeline   │
│                                                              │
│  ┌─────────┬──────────────┬────────────┐                     │
│  │  QA     │  ● Completed │  Feb 18    │                     │
│  │  Stage  │  ● Completed │  Feb 19    │                     │
│  │  Prod   │  ○ Pending   │  —         │                     │
│  └─────────┴──────────────┴────────────┘                     │
│                                                              │
│  Solutions:                                                  │
│  ┌──────────────────┬─────────┬────────────┬──────────┐      │
│  │ CoreComponents   │ 1.2.0.0 │ ● Exported │          │      │
│  │ MainApp          │ 2.1.0.0 │ ● Exported │ Settings │      │
│  └──────────────────┴─────────┴────────────┴──────────┘      │
└──────────────────────────────────────────────────────────────┘
```

### Run Now: Ad-Hoc Export via Cloud Flow

Users can trigger the export pipeline immediately from the model-driven app by setting an Export Request status to **Run Now** (`5`). This requires a Power Automate cloud flow that watches for that status change and calls the Azure DevOps REST API to queue a pipeline run.

**How it works:**

```
User sets status ──► Cloud flow triggers ──► ADO API queues pipeline ──► Pipeline processes request
  to "Run Now"        (Dataverse trigger)     with exportRequestId        (same as scheduled run)
```

The pipeline receives the Export Request GUID as a parameter and processes it directly &mdash; it skips the queue lookup and behaves identically to a manual ADO run. The cloud flow does **not** fire for "Queued" status, so scheduled exports remain unaffected.

**One-time setup:**

#### Step 1: Create an Azure DevOps Personal Access Token (PAT)

1. In Azure DevOps, click your profile icon &rarr; **Personal access tokens**
2. Click **+ New Token**
3. Set a descriptive name (e.g., `Power Automate - Queue Export Pipeline`)
4. Set the **scope** to **Build** &rarr; **Read & execute**
5. Set an expiration (max 1 year &mdash; set a reminder to rotate)
6. Click **Create** and copy the token value

> **Security note:** The PAT only needs Build read/execute scope. Do not grant broader permissions. Store it securely and rotate it before expiration.

#### Step 2: Get Your Pipeline ID

1. In Azure DevOps, go to **Pipelines** and click on the `export-solutions` pipeline
2. Look at the URL &mdash; the pipeline ID is the number at the end: `https://dev.azure.com/{org}/{project}/_build?definitionId=42` &rarr; pipeline ID is `42`

#### Step 3: Create the Cloud Flow

1. Go to [make.powerautomate.com](https://make.powerautomate.com) and select your Dev environment
2. Click **+ Create** &rarr; **Automated cloud flow**
3. Name it `Export Request - Run Now` and select the trigger **When a row is added, modified or deleted (Microsoft Dataverse)**

**Configure the trigger:**

| Setting | Value |
|---|---|
| Change type | Modified |
| Table name | Export Requests (`cr_exportrequests`) |
| Scope | Organization |
| Select columns | `cr_status` |
| Filter rows | `cr_status eq 5` |

> The `Filter rows` condition ensures the flow only fires when status changes to Run Now (`5`), not on any other status change.

**Add actions:**

4. Add a **Condition** action:
   - `Status Value` **is equal to** `5` (Run Now)
   - This is a safety check in case the filter row expression is not supported in your environment

5. In the **If yes** branch, add an **HTTP** action:

| Setting | Value |
|---|---|
| Method | `POST` |
| URI | `https://dev.azure.com/{org}/{project}/_apis/pipelines/{pipelineId}/runs?api-version=7.1` |
| Headers | `Content-Type`: `application/json` |
| Authentication | Basic |
| Username | (leave empty) |
| Password | Your PAT from Step 1 |

**Body:**

```json
{
  "templateParameters": {
    "exportRequestId": "@{triggerOutputs()?['body/cr_exportrequestid']}"
  }
}
```

> Replace `{org}`, `{project}`, and `{pipelineId}` with your values. The `cr_exportrequestid` field is the primary key GUID of the Export Request row &mdash; adjust the column name for your publisher prefix.

6. After the HTTP action, add an **Update a row** action (Microsoft Dataverse):

| Setting | Value |
|---|---|
| Table name | Export Requests |
| Row ID | `Export Request` (from trigger) |
| Status | `2` (In Progress) |

> This immediately updates the status to In Progress so the user sees feedback in the app. The pipeline will also set In Progress when it starts, but this provides a faster visual response.

7. In the **If no** branch, leave it empty (do nothing).

8. **Save** the flow.

**Complete flow summary:**

```
┌────────────────────────────────────────────────────┐
│  Trigger: When Export Request is modified           │
│  Filter:  cr_status eq 5 (Run Now)                 │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  Condition: Status Value = 5                  │  │
│  │                                               │  │
│  │  Yes:                                         │  │
│  │    1. HTTP POST to ADO Pipelines API          │  │
│  │       → Queue export-solutions pipeline       │  │
│  │       → Pass exportRequestId as parameter     │  │
│  │                                               │  │
│  │    2. Update row in Dataverse                 │  │
│  │       → Set status to In Progress (2)         │  │
│  │                                               │  │
│  │  No:                                          │  │
│  │    (do nothing)                               │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

**Testing the flow:**

1. Create a test Export Request with at least one solution row
2. Set the status to **Run Now**
3. Verify:
   - The cloud flow run appears in **Flow run history** with a Succeeded status
   - The Export Request status changes to **In Progress** within seconds
   - A new pipeline run appears in ADO &rarr; **Pipelines** &rarr; `export-solutions`
   - The pipeline run has the `exportRequestId` parameter set to the record's GUID

**Troubleshooting:**

| Symptom | Cause | Fix |
|---|---|---|
| Flow doesn't trigger | Filter row expression not matching | Verify `cr_status eq 5` uses the correct column logical name for your publisher prefix. Test by removing the filter and using only the condition action |
| HTTP action returns 401 | PAT expired or invalid | Generate a new PAT with Build Read & execute scope |
| HTTP action returns 404 | Wrong org, project, or pipeline ID in the URI | Double-check the URI components against your ADO URL |
| Pipeline runs but skips the request | `exportRequestId` parameter name mismatch | Ensure the pipeline YAML parameter is named `exportRequestId` (case-sensitive) and the flow body uses the correct column name |
| Status doesn't update to In Progress | Update row action failed | Check that the flow's Dataverse connection has write access to the Export Request table |

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
| `Deploy-Dev-Settings.Tests.ps1` | Pre-Dev &rarr; Dev deployment settings: artifact staging includes settings file when present, deploy resolves settings from artifact (auto-triggered) or repo root (manual) |
| `Config-Data-Validation.Tests.ps1` | Config data validation: required fields (`name`, `entity`, `primaryKey`, `select`, `dataFile`), optional `filter`, multiple data sets, empty/missing `configData` array, data file round-trip serialization |

---

## ADO Setup

### Prerequisites

| Requirement | Details |
|---|---|
| **Azure DevOps Organization** | Any ADO org with Pipelines enabled |
| **Power Platform Build Tools** | Install the [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools) extension from the Visual Studio Marketplace into your ADO organization |
| **App Registration (Service Principal)** | An Entra ID app registration with client secret, granted **System Administrator** or **System Customizer** role in the target Power Platform environments |
| **Dataverse Custom Tables** | The Export Request, Export Request Solution, and Config Data Definition tables deployed to the Dev environment (see [Dataverse Custom Tables](#dataverse-custom-tables)). The service principal must have read/write access to these tables |
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

> **Note:** You can use the same app registration across all environments, or create separate ones per environment for tighter access control.

### Step 3: Create Power Platform Service Connections

Create a service connection for **each** environment that uses the ADO task-based approach.

1. In your ADO project, go to **Project settings** > **Service connections** > **New service connection**
2. Select **Power Platform**
3. Fill in:
   - **Server URL**: The environment URL (e.g., `https://yourorg-predev.crm.dynamics.com`)
   - **Tenant ID**: From Step 2
   - **Application (Client) ID**: From Step 2
   - **Client Secret**: From Step 2
4. Name and save the connection

| Service Connection Name | Environment | Used By |
|---|---|---|
| `PowerPlatformPreDev` | Pre-Dev environment URL | Export Solution from Pre-Dev |
| `PowerPlatformDev` | Dev environment URL | Daily Export Solutions |

> **Tip:** If you use different names, update the corresponding variable in each pipeline YAML file.

### Step 4: Create Variable Groups (Release &amp; Deploy Pipelines)

The release pipeline and deploy pipeline use **variable groups** to store per-environment credentials. Create one group for each target environment.

1. Go to **Pipelines** > **Library** > **+ Variable group**
2. Create four variable groups with the following names and variables:

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

Both the release pipeline and the deploy pipeline use **ADO Environments** to gate deployments. Environments with approval checks will pause the pipeline and require manual approval before proceeding.

1. Go to **Pipelines** > **Environments** > **New environment**
2. Create four environments:

| Environment Name | Used By | Approval Check |
|---|---|---|
| `Power Platform Dev` | Deploy pipeline only | None (deploys automatically) |
| `Power Platform QA` | Release pipeline + Deploy pipeline | **Deploy pipeline:** add approval check. **Release pipeline:** deploys automatically (see note) |
| `Power Platform Stage` | Release pipeline + Deploy pipeline | **Add approval check** &mdash; select approver(s) |
| `Power Platform Prod` | Release pipeline + Deploy pipeline | **Add approval check** &mdash; select approver(s) |

> **Note:** ADO environment approval checks apply to **all** pipelines that use the environment. If you add an approval gate to `Power Platform QA`, both the release pipeline and the deploy pipeline will require approval for QA. If you want the release pipeline to deploy to QA automatically (no approval) while still requiring approval for the deploy pipeline, create a separate environment (e.g., `Power Platform QA - Deploy`) and update `deploy-solution.yml` to reference it.

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
| 3 | `pipelines/export-solution-predev.yml` | `Export Solution from Pre-Dev` |
| 4 | `pipelines/deploy-solution.yml` | `deploy-solution` |

> **Important:** Pipeline names matter for cross-pipeline triggers:
> - The **release pipeline** references the export pipeline as `source: "export-solutions"`. The export pipeline's name in ADO must match this value.
> - The **deploy pipeline** references the pre-dev export as `source: "Export Solution from Pre-Dev"`. Update if your pipeline name differs.

### Step 7: Configure Secret Variables (Daily Export Pipeline Only)

The **Daily Export Solutions** pipeline (`export-solutions.yml`) requires secret variables for pac CLI authentication. The other pipelines use service connections or variable groups.

1. Open the `export-solutions` pipeline and click **Edit**
2. Click **Variables** (top-right) > **New variable**
3. Add each of the following, checking **Keep this value secret** for `ClientSecret`:

   | Variable Name | Value | Secret? |
   |---|---|---|
   | `ClientId` | Application (Client) ID from Step 2 | No |
   | `ClientSecret` | Client secret value from Step 2 | **Yes** |
   | `TenantId` | Directory (Tenant) ID from Step 2 | No |

4. Click **Save**

> **Tip:** For managing these across multiple pipelines, create a **Variable Group** under **Pipelines** > **Library** and link it to the pipeline instead.

### Step 8: Update Pipeline Variables

Edit each pipeline YAML and update the service connection names, environment URLs, and Dataverse table names if they differ from the defaults:

**`pipelines/export-solutions.yml`:**
```yaml
variables:
  - name: PowerPlatformServiceConnection
    value: "PowerPlatformDev"            # <-- your Dev service connection
  - name: EnvironmentUrl
    value: "https://yourorg.crm.dynamics.com"  # <-- your Dev environment URL

  # Dataverse custom table names (update publisher prefix)
  - name: TableExportRequest
    value: "cr_exportrequests"           # <-- your plural table name
  - name: TableExportRequestSolution
    value: "cr_exportrequestsolutions"   # <-- your plural table name
  - name: TableConfigDataDefinition
    value: "cr_configdatadefinitions"    # <-- your plural table name
```

**`pipelines/release-solutions.yml`:**
```yaml
variables:
  - name: AdminEnvironmentUrl
    value: "https://yourorg.crm.dynamics.com"  # <-- Dev env where Export Request tables live
  - name: AdminClientId
    value: "$(AdminClientId)"            # <-- set in pipeline UI or variable group
  - name: AdminTenantId
    value: "$(AdminTenantId)"            # <-- set in pipeline UI or variable group
```

Each environment variable group (`PowerPlatform-QA`, etc.) should also include `AdminClientSecret` for the Dev/admin environment, so the release pipeline can update Dataverse status during each stage.

**`pipelines/export-solution-predev.yml`:**
```yaml
variables:
  - name: PreDevServiceConnection
    value: "PowerPlatformPreDev"         # <-- your Pre-Dev service connection
```

**`pipelines/deploy-solution.yml`:**

The deploy pipeline uses variable groups (`PowerPlatform-Dev`, `PowerPlatform-QA`, `PowerPlatform-Stage`, `PowerPlatform-Prod`) instead of inline variables. Update the variable group names in the YAML if yours differ from the defaults.

### Step 9: Grant Repository Permissions

The pipeline's build service identity needs permissions to push commits and create PRs.

1. Go to **Project settings** > **Repositories** > select your repository
2. Click the **Security** tab
3. Find **{Project Name} Build Service ({Org Name})** in the users list
4. Set the following permissions to **Allow**:
   - **Contribute**
   - **Create branch**
   - **Create pull requests** (for the daily export pipeline)
   - **Contribute to pull requests** (for the daily export pipeline)

---

## How to Execute

### Daily Export Solutions (Scheduled)

The daily pipeline runs automatically every day at **10:00 PM ET**. No action is needed beyond the initial setup. The pipeline will:
- Query Dataverse for an Export Request with status = **Queued**
- Skip gracefully if no queued request is found
- Process the request, export solutions, and create a PR to `main`

**To set up an export run**, create an Export Request in the model-driven app:

1. Open the **Export Requests** model-driven app in your Dev environment
2. Click **+ New** to create a new Export Request
3. Add **Export Request Solution** rows for each solution to export:
   - **Solution Name**: The solution's unique name (e.g., `CoreComponents`)
   - **Expected Version**: The exact version in Dev (e.g., `1.2.0.0`)
   - **Include Deployment Settings**: Set to **Yes** on one solution if needed
4. Optionally add **Config Data Definition** rows (see [Configuration Data](#configuration-data))
5. Optionally set **Post Export Version** (e.g., `2.0.0.0`)
6. Choose when to run:
   - Set the request status to **Queued** &mdash; the next scheduled run (10 PM ET) picks it up
   - Set the request status to **Run Now** &mdash; a cloud flow immediately triggers the pipeline (requires one-time setup; see [Run Now: Ad-Hoc Export via Cloud Flow](#run-now-ad-hoc-export-via-cloud-flow))

Status and pipeline links will be visible on the record as it progresses.

**To run manually from ADO:** Go to **Pipelines** > select `export-solutions` > **Run pipeline**. Optionally enter an `exportRequestId` to process a specific request.

### Release Pipeline (Automatic + Manual Approval)

The release pipeline triggers automatically after the export pipeline completes. No manual action is needed for the QA stage.

**For Stage and Prod:**

1. After QA completes successfully, approvers will receive a notification
2. Go to **Pipelines** > select the running release pipeline
3. Click **Review** on the Stage or Prod stage
4. Click **Approve** to proceed

The pipeline will skip any solution already installed at the target version in the environment.

### Export from Pre-Dev + Deploy (On-Demand)

1. Go to **Pipelines** in your ADO project
2. Select the **Export Solution from Pre-Dev** pipeline
3. Click **Run pipeline**
4. Enter the **Solution unique name** (exactly as it appears in Power Platform)
5. Click **Run**

The pipeline will export from Pre-Dev, unpack, commit, pack as managed, and automatically trigger the deploy pipeline. The solution will deploy to Dev immediately, then pause at QA, Stage, and Prod for approval.

**For QA, Stage, and Prod:**

1. After Dev completes successfully, approvers will receive a notification
2. Go to **Pipelines** > select the running deploy pipeline
3. Click **Review** on the QA, Stage, or Prod stage
4. Click **Approve** to proceed

### Deploy Solution (Manual)

If you need to re-deploy a solution that's already been exported and committed:

1. Go to **Pipelines** > select **deploy-solution**
2. Click **Run pipeline**
3. Enter the **Solution name** (must have a corresponding `solutions/managed/{name}.zip` in the repo)
4. Click **Run**

The solution will deploy through all four stages (Dev &rarr; QA &rarr; Stage &rarr; Prod), pausing at QA, Stage, and Prod for approval.

### Verifying Results

**After a daily export:**

| Where | What to Check |
|---|---|
| **Dataverse Export Request** | Status updated to **Completed** (or **Failed** with error details) |
| **Dataverse Export Request** | Pipeline run URL is clickable and links to the ADO build |
| **Dataverse Export Request Solutions** | Each solution shows **Exported** status with auto-detected flags |
| **Pipeline logs** | Version validation passed for each solution |
| **Repository** | `solutions/unpacked/{name}/` has the latest source files |
| **Repository** | `solutions/managed/{name}_{version}.zip` has the versioned managed package |
| **Pull Requests** | A PR was created and auto-completed (or is awaiting policy checks) |

**After a release deployment (pipeline 2):**

| Where | What to Check |
|---|---|
| **Dataverse Export Request** | QA/Stage/Prod deploy status updated to **Completed** with timestamps |
| **Dataverse Export Request** | Release pipeline URL is clickable and links to the ADO release build |
| **Pipeline logs** | Each solution shows "Successfully deployed" or "Already installed — skipping" |
| **Pipeline logs** | Cloud flow activation: look for "activated successfully" or warning messages for flows that couldn't be turned on |
| **Target environment** | Solutions are visible in the Power Platform maker portal at the expected versions |
| **Target environment** | Cloud flows are turned on (check Power Automate portal &mdash; some may need manual activation if warnings appeared) |

**After a deploy solution run (pipeline 4):**

| Where | What to Check |
|---|---|
| **Pipeline logs (Dev stage)** | Solution shows "Deployment Complete" |
| **Pipeline stages** | QA/Stage/Prod stages are paused waiting for approval (or already approved) |
| **Target environment** | The solution is visible in the Power Platform maker portal in each deployed environment |

---

## Changing the Schedule

The daily export schedule is defined as a cron expression in UTC:

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
| Pipeline skips with "No queued export requests found" | No Export Request with status = Queued exists in Dataverse | Create an Export Request in the model-driven app and set its status to **Queued** before the scheduled run |
| "Export request has no solutions" | The Export Request has no related Export Request Solution records | Add at least one solution row to the Export Request before queuing |
| "Version mismatch for '...'" | The solution version in Dev doesn't match the version on the Export Request Solution record | Update the Export Request Solution record to match the current version in Dev, or update the version in Dev to match |
| "Failed to authenticate with Power Platform" | Secret variables are missing or incorrect | Verify `ClientId`, `ClientSecret`, and `TenantId` in pipeline variables |
| "Failed to export solution" | Solution name doesn't match, or SPN lacks permissions | Verify the solution unique name in Power Platform and the app user's security role |
| "Failed to create Pull Request" | Build service lacks repo permissions | Grant Contribute and Create PR permissions (see Step 9) |
| PR created but not auto-completing | Branch policies require human reviewers | Either add an exception for the build service or manually complete the PR |
| Export Request still shows "Queued" after pipeline ran | Pipeline failed before picking up the request, or the Dataverse query failed | Check the pipeline logs for authentication errors. Verify the service principal has read/write access to the custom tables |
| Export Request shows "In Progress" but pipeline finished | The final status update step failed | Check the pipeline logs for the "Update export request status" step. The request may need to be manually updated in Dataverse |
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
| "includeDeploymentSettings is true but deploymentSettings_{stage}.json was not found" | Deployment settings file missing from artifact | Ensure the file exists in the root `deploymentSettings/` folder (e.g., `deploymentSettings/deploymentSettings_QA.json`) |
| Dataverse deploy status not updating | Admin credentials not configured or export request has no `exportRequestId` | Verify `AdminClientSecret`, `AdminClientId`, `AdminTenantId`, and `AdminEnvironmentUrl` are set in the release pipeline. Check pipeline logs for "skipping Dataverse status update" messages |
| "Artifact validation failed" | One or more solution zips or deployment settings files missing from artifact | The pipeline validates all artifacts upfront before importing anything. Ensure all solutions in `build.json` were exported successfully and all required `deploymentSettings_*.json` files exist |
| "Failed to activate flow" warning | Cloud flow could not be turned on after import | Common causes: connection references not resolved, SPN lacks access to the underlying connections, or flow suspended by DLP policy. Manually activate the flow in the Power Automate portal or resolve the underlying issue |
| "Could not acquire Dataverse API token" warning | OAuth token request for flow activation failed | Verify `ClientId`, `ClientSecret`, and `TenantId` are correct. Solution imports are not affected &mdash; only flow activation is skipped |

### Export from Pre-Dev / Deploy Solution

| Symptom | Cause | Fix |
|---|---|---|
| Export fails with auth error | Service connection misconfigured | Verify the `PowerPlatformPreDev` service connection has the correct environment URL, tenant, app ID, and secret |
| Export fails with "solution not found" | Solution name doesn't match | Use the exact **unique name** from Power Platform (not the display name) |
| Deploy pipeline doesn't trigger | Pipeline name mismatch | Ensure the `source` value in `deploy-solution.yml` matches the exact name of the export pipeline in ADO |
| Deploy pipeline doesn't trigger | Trigger branch filter | The export pipeline must run against `main` branch to trigger the deploy |
| Deploy fails with auth error in Dev | Variable group misconfigured | Verify the `PowerPlatform-Dev` variable group has correct `EnvironmentUrl`, `ClientId`, `ClientSecret`, and `TenantId` |
| Deploy fails with auth error in QA/Stage/Prod | Variable group misconfigured | Verify the corresponding variable group (`PowerPlatform-QA`, `PowerPlatform-Stage`, or `PowerPlatform-Prod`) has correct credentials |
| Manual deploy says "solution not found" | Solution not in repo | Run the export pipeline first, or verify `solutions/managed/{name}.zip` exists in the repo |
| QA/Stage/Prod stuck waiting | No one has approved | Approvers need to go to the pipeline run and click **Approve** on the pending stage |
| "No solution zip found in artifact" in QA/Stage/Prod | Dev stage didn't publish artifact | Check the Dev stage logs &mdash; it may have failed before the publish step |
| "Failed to push changes" | Build service lacks Contribute permission | Grant the Build Service account **Contribute** permission on the repository (see Step 9) |
