# Power Platform CI/CD Pipelines

Azure DevOps pipelines for exporting, importing, and managing Power Platform solutions.

## Repository Structure

```
pp-ci-cd-pipelines/
├── pipelines/
│   ├── export-solutions.yml         # Daily scheduled solution export (Dev)
│   ├── export-solution-predev.yml   # On-demand single solution export (Pre-Dev)
│   └── deploy-solution-dev.yml      # Auto-triggered deploy to Dev
├── exports/
│   └── {yyyy-MM-dd-token}/
│       └── build.json               # Export configuration per scheduled run
├── solutions/
│   ├── unpacked/{SolutionName}/     # Unpacked solution source files
│   ├── unmanaged/{SolutionName}.zip # Unmanaged solution zips
│   └── managed/{SolutionName}.zip   # Managed solution zips
└── README.md
```

---

## Pipelines

### 1. Daily Export Solutions (`pipelines/export-solutions.yml`)

Exports solutions from the Power Platform **Dev** environment on a daily schedule, unpacks them into source control, and converts them to managed packages.

**What it does:**

1. Detects a Git branch matching `export/{today's date}-{token}` (e.g., `export/2026-02-15-sprint42`)
2. Reads `exports/{date-token}/build.json` on that branch for the list of solutions to export
3. For each solution:
   - Exports the **unmanaged** solution zip from Power Platform &rarr; `solutions/unmanaged/`
   - Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/`
   - Packs the unpacked source as a **managed** solution &rarr; `solutions/managed/`
4. Commits the results and pushes to the export branch
5. Creates a Pull Request to `main`, sets it to auto-complete (squash merge), and deletes the source branch

**Trigger:** Daily at **10:00 PM Eastern Time** (3:00 AM UTC). Also runnable manually.

**Auth:** Uses pac CLI with secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`).

---

### 2. Export Solution from Pre-Dev (`pipelines/export-solution-predev.yml`)

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

### 3. Deploy Solution to Dev (`pipelines/deploy-solution-dev.yml`)

Imports a managed solution into the **Dev** environment. Runs automatically after the Pre-Dev export pipeline completes, or can be triggered manually.

**What it does:**

1. Downloads the managed solution artifact from the triggering export pipeline (or uses the repo for manual runs)
2. Imports the managed solution into the Dev environment

**Trigger:** Automatic (on completion of the Pre-Dev export pipeline) or manual.

**Auth:** Service connection only &mdash; no secret pipeline variables needed.

---

### Pipeline Flow: Pre-Dev to Dev Promotion

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
5. In the [Power Platform Admin Center](https://admin.powerplatform.microsoft.com), register this app as an **Application User** in **both** your Pre-Dev and Dev environments with the **System Administrator** security role

### Step 3: Create Power Platform Service Connections

Create a service connection for **each** environment used by the pipelines.

1. In your ADO project, go to **Project settings** > **Service connections** > **New service connection**
2. Select **Power Platform**
3. Fill in:
   - **Server URL**: The environment URL (e.g., `https://yourorg-predev.crm.dynamics.com`)
   - **Tenant ID**: From Step 2
   - **Application (Client) ID**: From Step 2
   - **Client Secret**: From Step 2
4. Name and save the connection

Create the following service connections:

| Service Connection Name | Environment | Used By |
|---|---|---|
| `PowerPlatformPreDev` | Pre-Dev environment URL | Export Solution from Pre-Dev |
| `PowerPlatformDev` | Dev environment URL | Daily Export Solutions, Deploy Solution to Dev |

> **Tip:** If you use different names, update the corresponding variable in each pipeline YAML file.

### Step 4: Create the Pipelines

Register each pipeline in ADO:

1. Go to **Pipelines** > **New pipeline**
2. Select your repository and choose **Existing Azure Pipelines YAML file**
3. Select the YAML file and click **Save**

Create pipelines in this order:

| # | YAML File | Recommended Pipeline Name |
|---|---|---|
| 1 | `pipelines/export-solutions.yml` | Daily Export Solutions |
| 2 | `pipelines/export-solution-predev.yml` | Export Solution from Pre-Dev |
| 3 | `pipelines/deploy-solution-dev.yml` | Deploy Solution to Dev |

> **Important:** The deploy pipeline references the export pipeline by name. The `source` value in `deploy-solution-dev.yml` must match the name you give to the `export-solution-predev.yml` pipeline in ADO. The default is `"Export Solution from Pre-Dev"`.

### Step 5: Configure Secret Variables (Daily Export Pipeline Only)

The **Daily Export Solutions** pipeline (`export-solutions.yml`) requires secret variables for pac CLI authentication. The other two pipelines use service connections exclusively and do **not** need secret variables.

1. Open the **Daily Export Solutions** pipeline and click **Edit**
2. Click **Variables** (top-right) > **New variable**
3. Add each of the following, checking **Keep this value secret** for `ClientSecret`:

   | Variable Name | Value | Secret? |
   |---|---|---|
   | `ClientId` | Application (Client) ID from Step 2 | No |
   | `ClientSecret` | Client secret value from Step 2 | **Yes** |
   | `TenantId` | Directory (Tenant) ID from Step 2 | No |

4. Click **Save**

> **Tip:** For managing these across multiple pipelines, create a **Variable Group** under **Pipelines** > **Library** and link it to the pipeline instead.

### Step 6: Update Pipeline Variables

Edit each pipeline YAML and update the service connection names if they differ from the defaults:

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

### Step 7: Grant Repository Permissions

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

To set up an export run, create a branch and build.json:

```bash
git checkout main && git pull
git checkout -b export/2026-02-15-sprint42
mkdir -p exports/2026-02-15-sprint42
```

Create `exports/2026-02-15-sprint42/build.json`:

```json
{
  "solutions": [
    "MySolution",
    "MyOtherSolution"
  ]
}
```

```bash
git add exports/
git commit -m "configure export for 2026-02-15-sprint42"
git push -u origin export/2026-02-15-sprint42
```

### Export from Pre-Dev + Deploy to Dev (On-Demand)

This is the simplest way to promote a solution from Pre-Dev to Dev:

1. Go to **Pipelines** in your ADO project
2. Select the **Export Solution from Pre-Dev** pipeline
3. Click **Run pipeline**
4. Enter the **Solution unique name** (exactly as it appears in Power Platform)
5. Click **Run**

That's it. The pipeline will:
1. Export the solution from Pre-Dev
2. Unpack, commit, and pack it as managed
3. Automatically trigger the **Deploy Solution to Dev** pipeline
4. The deploy pipeline imports the managed solution into Dev

No need to run the deploy pipeline manually &mdash; it triggers automatically when the export completes.

### Deploy to Dev (Manual)

If you need to re-deploy a solution that's already been exported and committed:

1. Go to **Pipelines** > select **Deploy Solution to Dev**
2. Click **Run pipeline**
3. Enter the **Solution name** (must have a corresponding `solutions/managed/{name}.zip` in the repo)
4. Click **Run**

### Verifying Results

After a successful export + deploy:

| Where | What to Check |
|---|---|
| **Repository** | `solutions/unpacked/{name}/` has the latest source files |
| **Repository** | `solutions/unmanaged/{name}.zip` has the unmanaged export |
| **Repository** | `solutions/managed/{name}.zip` has the managed package |
| **Dev environment** | Solution is imported and visible in the maker portal |

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
| "Failed to authenticate with Power Platform" | Secret variables are missing or incorrect | Verify `ClientId`, `ClientSecret`, and `TenantId` in pipeline variables |
| "Failed to export solution" | Solution name doesn't match, or SPN lacks permissions | Verify the solution unique name in Power Platform and the app user's security role |
| "Failed to create Pull Request" | Build service lacks repo permissions | Grant Contribute and Create PR permissions (see Step 7) |
| PR created but not auto-completing | Branch policies require human reviewers | Either add an exception for the build service or manually complete the PR |

### Export from Pre-Dev / Deploy to Dev

| Symptom | Cause | Fix |
|---|---|---|
| Export fails with auth error | Service connection misconfigured | Verify the `PowerPlatformPreDev` service connection has the correct environment URL, tenant, app ID, and secret |
| Export fails with "solution not found" | Solution name doesn't match | Use the exact **unique name** from Power Platform (not the display name) |
| Deploy pipeline doesn't trigger | Pipeline name mismatch | Ensure the `source` value in `deploy-solution-dev.yml` matches the exact name of the export pipeline in ADO |
| Deploy pipeline doesn't trigger | Trigger branch filter | The export pipeline must run against `main` branch to trigger the deploy |
| Deploy fails with auth error | Service connection misconfigured | Verify the `PowerPlatformDev` service connection has the correct Dev environment URL, tenant, app ID, and secret |
| Manual deploy says "solution not found" | Solution not in repo | Run the export pipeline first, or verify `solutions/managed/{name}.zip` exists in the repo |
| "Failed to push changes" | Build service lacks Contribute permission | Grant the Build Service account **Contribute** permission on the repository (see Step 7) |
