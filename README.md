# Power Platform CI/CD Pipelines

Azure DevOps pipelines for exporting, importing, and managing Power Platform solutions.

## Repository Structure

```
pp-ci-cd-pipelines/
├── pipelines/
│   └── export-solutions.yml        # Daily solution export pipeline
├── exports/
│   └── {yyyy-MM-dd-token}/
│       └── build.json               # Export configuration per run
├── solutions/
│   ├── unpacked/{SolutionName}/     # Unpacked solution source files
│   ├── unmanaged/{SolutionName}.zip # Unmanaged solution zips
│   └── managed/{SolutionName}.zip   # Managed solution zips
└── README.md
```

---

## Pipelines

### Export Solutions (`pipelines/export-solutions.yml`)

Exports solutions from the Power Platform **dev** environment, unpacks them into source control, and converts them to managed packages.

**What it does:**

1. Detects a Git branch matching `export/{today's date}-{token}` (e.g., `export/2026-02-15-sprint42`)
2. Reads `exports/{date-token}/build.json` on that branch for the list of solutions to export
3. For each solution:
   - Exports the **unmanaged** solution zip from Power Platform &rarr; `solutions/unmanaged/`
   - Performs a **clean unpack** (deletes existing folder, then unpacks fresh) &rarr; `solutions/unpacked/`
   - Packs the unpacked source as a **managed** solution &rarr; `solutions/managed/`
4. Commits the results and pushes to the export branch
5. Creates a Pull Request to `main`, sets it to auto-complete (squash merge), and deletes the source branch

**Schedule:** Runs daily at **10:00 PM Eastern Time** (3:00 AM UTC). See [Changing the Schedule](#changing-the-schedule) to adjust.

---

## ADO Setup

### Prerequisites

| Requirement | Details |
|---|---|
| **Azure DevOps Organization** | Any ADO org with Pipelines enabled |
| **Power Platform Build Tools** | Install the [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools) extension from the Visual Studio Marketplace into your ADO organization |
| **App Registration (Service Principal)** | An Entra ID app registration with client secret, granted **System Administrator** or **System Customizer** role in the target Power Platform environment |
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
5. In the [Power Platform Admin Center](https://admin.powerplatform.microsoft.com), register this app as an **Application User** in your dev environment with the **System Administrator** security role

### Step 3: Create a Power Platform Service Connection

1. In your ADO project, go to **Project settings** > **Service connections** > **New service connection**
2. Select **Power Platform**
3. Fill in:
   - **Server URL**: Your environment URL (e.g., `https://yourorg.crm.dynamics.com`)
   - **Tenant ID**: From Step 2
   - **Application (Client) ID**: From Step 2
   - **Client Secret**: From Step 2
4. Name the service connection `PowerPlatformDev` (or update the `PowerPlatformServiceConnection` variable in the pipeline YAML to match your chosen name)
5. Click **Save**

### Step 4: Create the Pipeline

1. In your ADO project, go to **Pipelines** > **New pipeline**
2. Select your repository and choose **Existing Azure Pipelines YAML file**
3. Select `pipelines/export-solutions.yml` from the branch
4. **Before saving/running**, configure the pipeline variables (see next step)
5. Click **Save** (not "Run") to register the pipeline first

### Step 5: Configure Secret Variables

The pipeline requires three secret variables for pac CLI authentication. These must match the same service principal used in the service connection.

1. Open the saved pipeline and click **Edit**
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

Edit `pipelines/export-solutions.yml` and update the following variables to match your environment:

```yaml
variables:
  - name: PowerPlatformServiceConnection
    value: "PowerPlatformDev"            # <-- your service connection name

  - name: EnvironmentUrl
    value: "https://yourorg.crm.dynamics.com"  # <-- your dev environment URL
```

### Step 7: Grant Repository Permissions

The pipeline's build service identity needs permissions to push commits and create PRs.

1. Go to **Project settings** > **Repositories** > select your repository
2. Click the **Security** tab
3. Find **{Project Name} Build Service ({Org Name})** in the users list
4. Set the following permissions to **Allow**:
   - **Contribute**
   - **Create branch**
   - **Create pull requests**
   - **Contribute to pull requests**

> If you want the pipeline to auto-complete PRs without manual approval, also ensure no branch policies on `main` require human reviewers, or configure the build service as an allowed auto-completer.

---

## How to Execute

### Automatic (Scheduled)

The pipeline runs automatically every day at **10:00 PM ET**. No action is needed beyond the initial setup. The pipeline will:
- Check if an export branch exists for today's date
- Skip gracefully (with a warning) if no matching branch is found
- Process all solutions and merge if a branch is found

### Manual Trigger

1. Go to **Pipelines** in your ADO project
2. Select the **Export Solutions** pipeline
3. Click **Run pipeline**
4. Optionally fill in the parameters:

   | Parameter | Purpose | Default |
   |---|---|---|
   | **Override export branch** | Specify an exact branch name (e.g., `export/2026-02-15-hotfix`) | Empty (auto-detect) |
   | **Override date** | Check for branches matching a different date (yyyy-MM-dd) | Empty (today in ET) |

5. Click **Run**

### Setting Up an Export Run

To trigger an export for a given day:

**1. Create the export branch:**

```bash
git checkout main
git pull
git checkout -b export/2026-02-15-sprint42
```

The branch name must follow the format `export/{yyyy-MM-dd}-{token}` where:
- `yyyy-MM-dd` is the date the pipeline should pick it up
- `{token}` is any identifier (sprint name, ticket number, etc.)

**2. Create the build configuration:**

```bash
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

The `solutions` array contains the **exact solution unique names** as they appear in Power Platform.

**3. Commit and push:**

```bash
git add exports/
git commit -m "configure export for 2026-02-15-sprint42"
git push -u origin export/2026-02-15-sprint42
```

**4. Wait for the scheduled run** (10 PM ET), or trigger the pipeline manually.

### Verifying Results

After a successful run:
- A PR will be created (or auto-completed) merging the export branch into `main`
- The `solutions/` directory on `main` will contain:

  | Path | Contents |
  |---|---|
  | `solutions/unpacked/{SolutionName}/` | Unpacked solution source files (XML, JSON, etc.) suitable for source control diffing and code review |
  | `solutions/unmanaged/{SolutionName}.zip` | Unmanaged solution zip as exported from Power Platform |
  | `solutions/managed/{SolutionName}.zip` | Managed solution zip ready for deployment to downstream environments |

---

## Changing the Schedule

The schedule is defined as a cron expression in UTC in the pipeline YAML:

```yaml
schedules:
  - cron: "0 3 * * *"    # 3:00 AM UTC = 10:00 PM EST
```

To change the time, edit the cron expression. Common examples:

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

| Symptom | Cause | Fix |
|---|---|---|
| Pipeline skips with "No export branch found" | No branch matching `export/{today}-*` exists | Create the export branch and push it before the scheduled run |
| "build.json not found" | The `exports/{subfolder}/build.json` file is missing on the export branch | Ensure the file path matches the branch name (minus the `export/` prefix) |
| "Failed to authenticate with Power Platform" | Secret variables are missing or incorrect | Verify `ClientId`, `ClientSecret`, and `TenantId` in pipeline variables |
| "Failed to export solution" | Solution name doesn't match, or SPN lacks permissions | Verify the solution unique name in Power Platform and the app user's security role |
| "Failed to create Pull Request" | Build service lacks repo permissions | Grant Contribute and Create PR permissions (see Step 7) |
| PR created but not auto-completing | Branch policies require human reviewers | Either add an exception for the build service or manually complete the PR |
