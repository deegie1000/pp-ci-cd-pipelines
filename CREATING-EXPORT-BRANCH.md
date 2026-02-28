# How to Create an Export Branch (VS Code + Git Beginner Guide)

This guide walks you through the **Daily Export + Release** workflow from scratch — creating the export branch, adding the required files, and pushing so the pipeline can pick it up. No prior Git or VS Code experience needed.

**What this covers:** The [Daily Export Solutions](./README.md#1-daily-export-solutions-pipelinesexport-solutionsyml) pipeline exports your solutions from Dev, then the [Release Solutions](./README.md#2-release-solutions-pipelinesrelease-solutionsyml) pipeline automatically deploys them through QA → Stage → Prod. Your job is to create the branch and files — the pipelines handle the rest.

> **Already know Git?** Skip ahead to [Step 3: Create the Branch](#step-3-create-the-branch).

---

## What You'll Need Before Starting

- **Git** installed on your machine — [download here](https://git-scm.com/downloads)
- **Visual Studio Code** installed — [download here](https://code.visualstudio.com/)
- **Access to the repository** in Azure DevOps (someone on your team needs to give you access)

### Recommended VS Code Extensions

Open VS Code, click the **Extensions** icon on the left sidebar (it looks like four squares), and install:

- **GitLens** — adds extra Git info directly in the editor (optional but helpful)

---

## Step 1: Clone the Repository (First Time Only)

If you already have the repo folder on your computer, skip to [Step 2](#step-2-open-the-repo-in-vs-code).

1. In Azure DevOps, open the repository and click **Clone** (top right).
2. Copy the **HTTPS** clone URL.
3. Open VS Code.
4. Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on Mac) to open the Command Palette.
5. Type **Git: Clone** and press Enter.
6. Paste the URL and press Enter.
7. Choose a folder on your computer where the repo will be saved, then click **Select Repository Location**.
8. When prompted, click **Open** to open the cloned folder.

---

## Step 2: Open the Repo in VS Code

If you've already cloned it before:

1. Open VS Code.
2. Go to **File → Open Folder...** and select the repo folder.

---

## Step 3: Get the Latest Code from Main

Before creating a branch, always pull the latest code so you're starting from an up-to-date copy.

1. Open the **Source Control** panel by clicking the branching icon on the left sidebar (or press `Ctrl+Shift+G`).
2. At the bottom-left of VS Code, you'll see the current branch name (e.g., `main`). Click it.
3. A menu appears at the top — click **main** to switch to the main branch.
4. Back in the Source Control panel, click the `...` menu (three dots) → **Pull**.

You now have the latest version of `main`.

---

## Step 4: Create the Branch

Export branches follow a specific naming convention. The format is:

```
export/yyyy-MM-dd-{short-description}
```

**Examples:**
- `export/2026-02-28-quarterly-release`
- `export/2026-02-28-hotfix-connectors`
- `export/2026-02-28-sprint-14`

> The date must be today's date in `yyyy-MM-dd` format (year-month-day). The part after the date is a short label — use lowercase letters and hyphens, no spaces.

### How to create the branch in VS Code:

1. Click the **branch name** at the bottom-left of VS Code (currently shows `main`).
2. In the menu that appears, choose **Create new branch...**.
3. Type your branch name — for example: `export/2026-02-28-quarterly-release`
4. Press Enter. VS Code automatically switches you to the new branch.

---

## Step 5: Create the Export Folder

Inside the repo there is an `exports/` folder. You need to create a **subfolder** inside it using the same date-and-label you used in your branch name.

**Example:** If your branch is `export/2026-02-28-quarterly-release`, your folder should be:

```
exports/2026-02-28-quarterly-release/
```

### How to create the folder in VS Code:

1. In the **Explorer** panel (left sidebar, top icon), find the `exports/` folder.
2. Right-click on `exports/` and choose **New Folder...**.
3. Type the folder name (e.g., `2026-02-28-quarterly-release`) and press Enter.

> See [Repository Structure](./README.md#repository-structure) in the README for a full picture of where this fits.

---

## Step 6: Create `build.json`

`build.json` is the main configuration file that tells the pipeline which solutions to export and how to version them.

### How to create it:

1. Right-click the new folder you just created (e.g., `exports/2026-02-28-quarterly-release/`) and choose **New File...**.
2. Name it `build.json` and press Enter.
3. The file opens. Copy and paste the template below, then edit it for your solutions.

### Minimal template (one solution, no config data):

```json
{
  "solutions": [
    {
      "name": "YourSolutionName",
      "version": "1.0.0.0",
      "postExportVersion": "1.0.1.0",
      "createNewPatch": false
    }
  ]
}
```

### Full template (multiple solutions + config data):

```json
{
  "solutions": [
    {
      "name": "CoreComponents",
      "version": "1.2.0.0",
      "postExportVersion": "1.3.0.0",
      "createNewPatch": true,
      "isUnmanaged": false
    },
    {
      "name": "MainApp",
      "version": "2.1.0.0",
      "postExportVersion": "2.2.0.0",
      "includeDeploymentSettings": true,
      "createNewPatch": false
    }
  ],
  "configData": [
    {
      "name": "USStates",
      "entity": "cr123_states",
      "primaryKey": "cr123_stateid",
      "select": "cr123_name,cr123_abbreviation",
      "filter": "statecode eq 0",
      "dataFile": "configdata/USStates.json"
    }
  ]
}
```

### Key fields explained:

| Field | What it does |
|-------|-------------|
| `name` | The exact internal name of the solution in Power Platform |
| `version` | The current version to export |
| `postExportVersion` | The version the solution gets bumped to *after* exporting |
| `createNewPatch` | `true` = create a patch during export; `false` = skip |
| `isUnmanaged` | `true` = export as unmanaged only; omit or `false` = managed |
| `includeDeploymentSettings` | `true` = include deployment settings during deploy |
| `configData` | List of reference data tables to export alongside the solution |

> For the full field reference, see [build.json Configuration](./README.md#buildjson-configuration) in the README.

---

## Step 7: Create Deployment Settings Files (Optional)

Deployment settings files let you configure environment variables and connection references differently per environment (QA, Stage, Prod). You only need these if your solution uses connection references or environment variables that differ between environments.

If you need them, create one or more of these files inside your export folder:

- `deploymentSettings_QA.json`
- `deploymentSettings_Stage.json`
- `deploymentSettings_Prod.json`

### Minimal empty template (safe starting point):

```json
{
  "EnvironmentVariables": [],
  "ConnectionReferences": []
}
```

You can fill in the values later. See [`exports/sample/deploymentSettings_QA.json`](./exports/sample/deploymentSettings_QA.json) for the full format, and [Deployment Settings](./README.md#deployment-settings) in the README for documentation.

> You must also set `"includeDeploymentSettings": true` on the relevant solution in `build.json` for these files to be used during deployment.

---

## Step 8: Commit Your Changes

Once your files are created and edited:

1. Open the **Source Control** panel (`Ctrl+Shift+G`).
2. You'll see your new files listed under **Changes**.
3. Hover over each file and click the **+** icon to **stage** it (or click **Stage All Changes** to stage everything at once).
4. In the **Message** box at the top, type a short description of what you're adding — for example:

   ```
   Add export branch for 2026-02-28 quarterly release
   ```

5. Press `Ctrl+Enter` (or click the checkmark **Commit** button) to commit.

---

## Step 9: Push the Branch to Azure DevOps

Committing only saves changes locally. You need to **push** to share the branch with the team and trigger the pipeline.

1. In the Source Control panel, click the `...` menu → **Push**.
2. VS Code will prompt you: **"The branch 'export/2026-02-28-...' has no upstream branch. Would you like to publish it?"** — click **OK** (or **Publish Branch**).

Your branch is now visible in Azure DevOps.

---

## Step 10: What Happens Next — The Pipeline Flow

Once you push your branch, the pipeline can run. Here's the full sequence:

### Option A: Wait for the Automatic Run
The **Daily Export Solutions** pipeline runs automatically at **10 PM ET** every night. It will detect your branch, export the solutions from Dev, and then automatically trigger the **Release Solutions** pipeline to deploy QA → Stage → Prod.

### Option B: Trigger Manually (Don't Want to Wait)

1. Go to your Azure DevOps project.
2. Navigate to **Pipelines** and find the **Daily Export Solutions** pipeline.
3. Click **Run pipeline**.
4. Under **exportBranch**, either leave it blank (auto-detects today's branch) or paste your full branch name (e.g., `export/2026-02-28-quarterly-release`).
5. Click **Run**.

> For full details on both pipelines and the deployment flow, see [Daily Export Solutions](./README.md#1-daily-export-solutions-pipelinesexport-solutionsyml) and [Release Solutions](./README.md#2-release-solutions-pipelinesrelease-solutionsyml) in the README, or the [Pipeline Flow](./README.md#pipeline-flow) diagram.

---

## Your Finished Export Folder Structure

When done, your folder should look like this:

```
exports/
└── 2026-02-28-quarterly-release/
    ├── build.json                      ← required
    ├── deploymentSettings_QA.json      ← optional
    ├── deploymentSettings_Stage.json   ← optional
    └── deploymentSettings_Prod.json    ← optional
```

And the `exports/sample/` folder is there as a reference — you can look at it any time to see a complete example.

---

## Quick Reference: Branch Naming

| Component | Example | Notes |
|-----------|---------|-------|
| Prefix | `export/` | Always exactly this |
| Date | `2026-02-28` | Today's date, `yyyy-MM-dd` format |
| Label | `quarterly-release` | Lowercase, hyphens, no spaces |
| Full name | `export/2026-02-28-quarterly-release` | Matches your folder name |

---

## Troubleshooting

**VS Code says "Make sure you configure your user.name and user.email in git"**
Open a terminal in VS Code (`Ctrl+`` `) and run:
```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

**Push fails with "Permission denied" or 403**
You may not have write access to the repo. Ask your team lead to add you as a contributor in Azure DevOps.

**The pipeline didn't pick up my branch**
Make sure the folder name inside `exports/` matches the date portion of your branch name, and that `build.json` exists inside that folder.

**Not sure what solution names to use?**
In Power Platform, go to **Solutions**, find your solution, and use the **Name** column (not the Display Name). It usually looks like `MySolutionName` with no spaces.
