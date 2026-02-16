# Power Platform CI/CD Pipelines

Azure DevOps pipelines for exporting, versioning, and deploying Power Platform solutions across environments.

## Repository Structure

```
pp-ci-cd-pipelines/
├── pipelines/
│   ├── export-solutions.yml             # Daily scheduled export (Dev → repo)
│   ├── release-solutions.yml            # Release pipeline (QA → Stage → Prod)
│   ├── export-solution-predev.yml       # On-demand single solution export (Pre-Dev)
│   ├── deploy-solution-dev.yml          # Auto-triggered deploy to Dev
│   └── templates/
│       └── deploy-environment.yml        # Reusable deploy template (used by release pipeline)
├── exports/
│   └── {yyyy-MM-dd-token}/
│       ├── build.json                   # Export configuration per scheduled run
│       ├── deploymentSettings_QA.json   # Deployment settings for QA (optional)
│       ├── deploymentSettings_Stage.json # Deployment settings for Stage (optional)
│       └── deploymentSettings_Prod.json  # Deployment settings for Prod (optional)
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
| 1 | [Daily Export Solutions](#1-daily-export-solutions) | Scheduled (10 PM ET daily) | Export from Dev, validate versions, pack managed, PR to main |
| 2 | [Release Solutions](#2-release-solutions) | Auto (on export completion) | Deploy managed solutions through QA → Stage → Prod |
| 3 | [Export from Pre-Dev](#3-export-solution-from-pre-dev) | Manual | Export single solution from Pre-Dev, commit, trigger Dev deploy |
| 4 | [Deploy to Dev](#4-deploy-solution-to-dev) | Auto (on Pre-Dev export) | Import managed solution into Dev |

---

## Pipelines

### 1. Daily Export Solutions (`pipelines/export-solutions.yml`)

Exports solutions from the Power Platform **Dev** environment on a daily schedule, validates their versions against `build.json`, unpacks them into source control, converts them to managed packages, and creates a PR to merge into `main`.

**What it does:**

1. Detects a Git branch matching `export/{today's date}-{token}` (e.g., `export/2026-02-15-sprint42`)
2. Reads `exports/{date-token}/build.json` on that branch for the list of solutions and their expected versions
3. For each solution:
   - Checks if a managed zip already exists for this name + version (cache check &mdash; skips if so)
   - Exports the **unmanaged** solution zip from Power Platform &rarr; `solutions/unmanaged/`
   - Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/`
   - **Validates the version**: reads the actual version from `Other/Solution.xml` and compares it to `build.json`. If they don't match, the pipeline **fails** with an error
   - Packs the unpacked source as a **managed** solution &rarr; `solutions/managed/`
4. Publishes managed zips, `build.json`, and any `deploymentSettings_*.json` files as pipeline artifacts (consumed by the release pipeline)
5. Commits solution files and pushes to the export branch
6. Creates a Pull Request to `main`, sets auto-complete (squash merge), and deletes the source branch

**Version validation:** The pipeline does **not** modify solution versions in Dev or update `build.json`. The `build.json` file is the source of truth for expected versions. If a solution's version in the Dev environment doesn't match what's in `build.json`, the pipeline fails immediately with a message like:

```
Version mismatch for 'MySolution': build.json specifies v1.0.0.0 but dev environment has v1.1.0.0.
Update build.json to match the dev environment before re-running.
```

**Trigger:** Daily at **10:00 PM Eastern Time** (3:00 AM UTC). Also runnable manually with optional overrides for branch name and date.

**Parameters (manual runs):**

| Parameter | Description |
|---|---|
| `exportBranch` | Override export branch name (skip auto-detect) |
| `dateOverride` | Override date for branch detection (yyyy-MM-dd) |

**Auth:** Uses pac CLI with secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`).

**Artifact published:** `ManagedSolutions` &mdash; contains `build.json`, `{SolutionName}_{version}.zip` files, and any `deploymentSettings_*.json` files present in the export folder.

---

### 2. Release Solutions (`pipelines/release-solutions.yml`)

Deploys managed solutions through three environments in sequence: **QA &rarr; Stage &rarr; Prod**. Triggers automatically when the daily export pipeline completes on `main`.

**What it does (per stage):**

1. Downloads the `ManagedSolutions` artifact from the export pipeline
2. Authenticates with the target environment using credentials from a per-environment variable group
3. Queries all installed solutions in the target environment using `pac solution list`
4. For each solution in `build.json` (in order):
   - **Skip** &mdash; if the solution is already installed at the target version
   - **Fresh install** &mdash; if the solution doesn't exist in the target environment
   - **Upgrade** &mdash; if the solution exists but at a different version
   - Imports as managed with `--force-overwrite --activate-plugins`
   - If the solution has `includeDeploymentSettings: true` in `build.json`, applies the matching `deploymentSettings_{stage}.json` file via `--settings-file`
5. Fails the stage if any solution fails to deploy

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
5. Publishes the managed zip as a pipeline artifact
6. **Automatically triggers** the Deploy Solution to Dev pipeline

**Trigger:** Manual only (run on demand from the ADO UI).

**Auth:** Service connection only &mdash; no secret pipeline variables needed.

---

### 4. Deploy Solution to Dev (`pipelines/deploy-solution-dev.yml`)

Imports a managed solution into the **Dev** environment. Runs automatically after the Pre-Dev export pipeline completes, or can be triggered manually.

**What it does:**

1. Downloads the managed solution artifact from the triggering export pipeline (or uses the repo for manual runs)
2. Imports the managed solution into the Dev environment

**Trigger:** Automatic (on completion of the Pre-Dev export pipeline) or manual.

**Auth:** Service connection only &mdash; no secret pipeline variables needed.

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
│  5. Unpack + pack managed│    │  └─────────┘  └─────────┘  └────────────┘ │
│  6. Publish artifact     │    │                                             │
│  7. PR to main           │    │  Each stage:                                │
│                          │    │  - Checks installed versions                │
└──────────────────────────┘    │  - Skips if already at target version       │
                                │  - Imports managed + force-overwrite        │
                                │  - Applies deployment settings if enabled   │
                                └─────────────────────────────────────────────┘
```

### Pre-Dev to Dev Promotion (On-Demand)

```
┌─────────────────────────────────┐       ┌──────────────────────────────┐
│  Export Solution from Pre-Dev   │       │   Deploy Solution to Dev     │
│  (manual trigger)               │       │   (auto-triggered)           │
│                                 │       │                              │
│  1. Export unmanaged from       │       │  1. Download managed         │
│     Pre-Dev environment         │  ───► │     solution artifact        │
│  2. Clean unpack                │       │  2. Import managed solution  │
│  3. Pack as managed             │       │     into Dev environment     │
│  4. Commit to repo              │       │                              │
│  5. Publish artifact            │       │                              │
└─────────────────────────────────┘       └──────────────────────────────┘
```

---

## build.json Configuration

The `build.json` file defines which solutions to export and their **expected versions**. It lives on the export branch at `exports/{date-token}/build.json`.

```json
{
  "solutions": [
    { "name": "CoreComponents", "version": "1.2.0.0" },
    { "name": "CustomConnectors", "version": "1.0.3.0" },
    { "name": "MainApp", "version": "2.1.0.0", "includeDeploymentSettings": true }
  ]
}
```

| Field | Description |
|---|---|
| `solutions` | Ordered array of solutions to export. Order matters &mdash; the release pipeline deploys in this order (put dependencies first). |
| `solutions[].name` | The solution's **unique name** as it appears in Power Platform (not the display name). |
| `solutions[].version` | The **exact version** expected in the Dev environment. Must match the version in Dev's `Solution.xml`, or the export pipeline will fail. |
| `solutions[].includeDeploymentSettings` | Optional boolean (default: `false`). If `true`, the release pipeline will apply a deployment settings file (`deploymentSettings_{stage}.json`) when importing this solution. Only one solution should have this set to `true`. |

**How versions work:**

- The version in `build.json` must match the version in the Dev environment exactly
- The export pipeline **reads** the version from Dev after unpack and **compares** it &mdash; it never writes or changes versions
- If you increment a solution version in Dev, update `build.json` to match before the next export run
- The release pipeline uses the same version from `build.json` to name artifact files and check target environments
- Solution zip files are named `{name}_{version}.zip` (e.g., `CoreComponents_1.2.0.0.zip`)

**Caching:** If a managed zip for the exact name + version already exists in `solutions/managed/`, the export pipeline skips re-exporting that solution and uses the cached file. This makes re-runs efficient when only some solutions have changed.

### Deployment Settings

Deployment settings allow you to configure environment-specific values (such as connection references and environment variables) that get applied when importing a solution into a target environment.

**How it works:**

1. Set `"includeDeploymentSettings": true` on **one** solution in `build.json`
2. Create deployment settings files in the **same folder** as `build.json`, named by environment:
   - `deploymentSettings_QA.json`
   - `deploymentSettings_Stage.json`
   - `deploymentSettings_Prod.json`
3. The export pipeline includes these files in the `ManagedSolutions` artifact automatically
4. During deployment, the release pipeline passes the matching file to `pac solution import --settings-file`

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

---

## ADO Setup

### Prerequisites

| Requirement | Details |
|---|---|
| **Azure DevOps Organization** | Any ADO org with Pipelines enabled |
| **Power Platform Build Tools** | Install the [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools) extension from the Visual Studio Marketplace into your ADO organization |
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

> **Note:** You can use the same app registration across all environments, or create separate ones per environment for tighter access control.

### Step 3: Create Power Platform Service Connections

Create a service connection for **each** environment that uses the ADO task-based approach (Pre-Dev and Dev).

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
| `PowerPlatformDev` | Dev environment URL | Daily Export Solutions, Deploy Solution to Dev |

> **Tip:** If you use different names, update the corresponding variable in each pipeline YAML file.

### Step 4: Create Variable Groups (Release Pipeline)

The release pipeline uses **variable groups** to store per-environment credentials. Create one group for each target environment.

1. Go to **Pipelines** > **Library** > **+ Variable group**
2. Create three variable groups with the following names and variables:

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

3. On each variable group, click **Pipeline permissions** and authorize the release pipeline to use it

### Step 5: Create ADO Environments (Release Pipeline)

The release pipeline uses **ADO Environments** to gate deployments. Stage and Prod require manual approval checks.

1. Go to **Pipelines** > **Environments** > **New environment**
2. Create three environments:

| Environment Name | Approval Check |
|---|---|
| `Power Platform QA` | None (deploys automatically) |
| `Power Platform Stage` | **Add approval check** &mdash; select approver(s) |
| `Power Platform Prod` | **Add approval check** &mdash; select approver(s) |

**To add an approval check:**

1. Click on the environment (e.g., `Power Platform Stage`)
2. Click the **&vellip;** menu (top-right) > **Approvals and checks**
3. Click **+ Add check** > **Approvals**
4. Add one or more approvers (users or groups)
5. Optionally set a timeout and instructions
6. Click **Create**

When the release pipeline reaches Stage or Prod, it will pause and notify the approvers. The stage only proceeds after approval.

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
| 4 | `pipelines/deploy-solution-dev.yml` | `Deploy Solution to Dev` |

> **Important:** Pipeline names matter for cross-pipeline triggers:
> - The **release pipeline** references the export pipeline as `source: "export-solutions"`. The export pipeline's name in ADO must match this value.
> - The **deploy-to-dev pipeline** references the pre-dev export as `source: "Export Solution from Pre-Dev"`. Update if your pipeline name differs.

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

Edit each pipeline YAML and update the service connection names and environment URLs if they differ from the defaults:

**`pipelines/export-solutions.yml`:**
```yaml
variables:
  - name: PowerPlatformServiceConnection
    value: "PowerPlatformDev"            # <-- your Dev service connection
  - name: EnvironmentUrl
    value: "https://yourorg.crm.dynamics.com"  # <-- your Dev environment URL
```

**`pipelines/export-solution-predev.yml`:**
```yaml
variables:
  - name: PreDevServiceConnection
    value: "PowerPlatformPreDev"         # <-- your Pre-Dev service connection
```

**`pipelines/deploy-solution-dev.yml`:**
```yaml
variables:
  - name: DevServiceConnection
    value: "PowerPlatformDev"            # <-- your Dev service connection
```

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

**To run manually:** Go to **Pipelines** > select `export-solutions` > **Run pipeline**. Optionally override the export branch or date.

### Release Pipeline (Automatic + Manual Approval)

The release pipeline triggers automatically after the export pipeline completes. No manual action is needed for the QA stage.

**For Stage and Prod:**

1. After QA completes successfully, approvers will receive a notification
2. Go to **Pipelines** > select the running release pipeline
3. Click **Review** on the Stage or Prod stage
4. Click **Approve** to proceed

The pipeline will skip any solution already installed at the target version in the environment.

### Export from Pre-Dev + Deploy to Dev (On-Demand)

1. Go to **Pipelines** in your ADO project
2. Select the **Export Solution from Pre-Dev** pipeline
3. Click **Run pipeline**
4. Enter the **Solution unique name** (exactly as it appears in Power Platform)
5. Click **Run**

The pipeline will export from Pre-Dev, unpack, commit, pack as managed, and automatically trigger deployment to Dev.

### Deploy to Dev (Manual)

If you need to re-deploy a solution that's already been exported and committed:

1. Go to **Pipelines** > select **Deploy Solution to Dev**
2. Click **Run pipeline**
3. Enter the **Solution name** (must have a corresponding `solutions/managed/{name}.zip` in the repo)
4. Click **Run**

### Verifying Results

**After a daily export:**

| Where | What to Check |
|---|---|
| **Pipeline logs** | Version validation passed for each solution |
| **Repository** | `solutions/unpacked/{name}/` has the latest source files |
| **Repository** | `solutions/unmanaged/{name}_{version}.zip` has the versioned unmanaged export |
| **Repository** | `solutions/managed/{name}_{version}.zip` has the versioned managed package |
| **Pull Requests** | A PR was created and auto-completed (or is awaiting policy checks) |

**After a release deployment:**

| Where | What to Check |
|---|---|
| **Pipeline logs** | Each solution shows "Successfully deployed" or "Already installed — skipping" |
| **Target environment** | Solutions are visible in the Power Platform maker portal at the expected versions |

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
| Pipeline skips with "No export branch found" | No branch matching `export/{today}-*` exists | Create the export branch and push it before the scheduled run |
| "build.json not found" | The `exports/{subfolder}/build.json` file is missing on the export branch | Ensure the file path matches the branch name (minus the `export/` prefix) |
| "Version mismatch for '...'" | The solution version in Dev doesn't match the version in `build.json` | Update `build.json` to match the current version in Dev, or update the version in Dev to match `build.json` |
| "Failed to authenticate with Power Platform" | Secret variables are missing or incorrect | Verify `ClientId`, `ClientSecret`, and `TenantId` in pipeline variables |
| "Failed to export solution" | Solution name doesn't match, or SPN lacks permissions | Verify the solution unique name in Power Platform and the app user's security role |
| "Failed to create Pull Request" | Build service lacks repo permissions | Grant Contribute and Create PR permissions (see Step 9) |
| PR created but not auto-completing | Branch policies require human reviewers | Either add an exception for the build service or manually complete the PR |

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

### Export from Pre-Dev / Deploy to Dev

| Symptom | Cause | Fix |
|---|---|---|
| Export fails with auth error | Service connection misconfigured | Verify the `PowerPlatformPreDev` service connection has the correct environment URL, tenant, app ID, and secret |
| Export fails with "solution not found" | Solution name doesn't match | Use the exact **unique name** from Power Platform (not the display name) |
| Deploy pipeline doesn't trigger | Pipeline name mismatch | Ensure the `source` value in `deploy-solution-dev.yml` matches the exact name of the export pipeline in ADO |
| Deploy pipeline doesn't trigger | Trigger branch filter | The export pipeline must run against `main` branch to trigger the deploy |
| Deploy fails with auth error | Service connection misconfigured | Verify the `PowerPlatformDev` service connection has the correct Dev environment URL, tenant, app ID, and secret |
| Manual deploy says "solution not found" | Solution not in repo | Run the export pipeline first, or verify `solutions/managed/{name}.zip` exists in the repo |
| "Failed to push changes" | Build service lacks Contribute permission | Grant the Build Service account **Contribute** permission on the repository (see Step 9) |
