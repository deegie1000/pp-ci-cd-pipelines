# Power Platform Pipelines — Quick Guide

This is the plain-English version. For full technical details see [README.md](./README.md).

---

## What do these pipelines do?

They move Power Platform solutions (apps, flows, etc.) from development environments into production in a controlled, repeatable way. Think of them as an automated moving truck that packages everything in Dev, checks it, and delivers it to QA, then Stage, then Prod — with a stop for your approval before anything goes to production.

---

## The pipelines at a glance

| Pipeline | Runs | What it does |
|---|---|---|
| **Daily Export** | Automatically every night ~10 PM | Saves the latest Dev work to source control and kicks off the QA deployment |
| **Release** | Automatically after Daily Export | Deploys to QA (automatic), then waits for approval to go to Stage and Prod |
| **Export from Pre-Dev** | You run it manually | Pulls a single solution out of Pre-Dev and deploys it to Dev |
| **Deploy Solution** | Automatically after Pre-Dev Export | Deploys that single solution into Dev |
| **Export for New Dev** | You run it manually | Packages solutions from Dev to seed a brand-new Dev environment |
| **Deploy to New Dev** | You run it manually | Takes that package and installs it into the new Dev environment |

---

## The normal day-to-day flow

Most days you don't need to do anything. Here's what happens automatically:

```
Every night ~10 PM
    ↓
Daily Export runs — saves Dev solutions to source control
    ↓
Release pipeline starts automatically
    ↓
Deploys to QA — no action needed from you
    ↓
⏸ Waits for your approval to deploy to Stage
    ↓
⏸ Waits for your approval to deploy to Prod
```

You only need to step in to **approve the Stage and Prod deployments**.

---

## How to approve a deployment to Stage or Prod

When a deployment is waiting for your approval, Azure DevOps will notify you (email or Teams, depending on your notification settings).

1. Go to **Pipelines** in Azure DevOps
2. Click on the **Release Solutions** pipeline
3. Find the run that's waiting — it will show a yellow "Waiting" badge
4. Click into the run, then click the **Review** button next to the Stage or Prod deployment
5. Add an optional comment and click **Approve**

The deployment will continue automatically after approval.

> **Tip:** You can set up email or Teams notifications in ADO under your profile settings → Notifications so you don't have to check manually.

---

## How to run a pipeline manually

All pipelines can be triggered manually. The Daily Export also runs automatically on a schedule (10 PM ET), but you can run it on demand too — useful if you need to re-run or test outside of the normal schedule.

1. Go to **Pipelines** in Azure DevOps
2. Find the pipeline you want to run
3. Click **Run pipeline**
4. Fill in any parameters shown (the important ones are called out below)
5. Click **Run**

---

## Setting up a new Dev environment

Use this when someone needs a fresh Power Platform environment that mirrors Dev (for example, a new team member or a temporary sandbox).

**Step 1 — Export to New Dev**

1. Create an export branch in the repo following the naming format: `export/{token}`
   (e.g. `export/onboarding-alex`)
2. Add a `build.json` file in the `exports/onboarding-alex/` folder listing the solutions you want — ask your developer to set this up if needed
3. Go to **Pipelines** → **export-for-new-dev**
4. Click **Run pipeline**
5. In the **Export branch** field, enter the branch name you created (e.g. `export/onboarding-alex`)
6. Click **Run** — the pipeline will export the solutions and publish a package

**Step 2 — Deploy to New Dev**

1. Go to **Pipelines** → **deploy-to-newdev**
2. Click **Run pipeline**
3. ADO will ask you to select which **export-for-new-dev** run to deploy — pick the one you just ran
4. Click **Run**

The solutions will be installed into the New Dev environment. Solutions marked as "unmanaged" in the configuration will be installed as unmanaged (editable), which is typical for a Dev environment.

> **Note:** The `isUnmanaged` flag in `build.json` also controls how solutions are deployed through the standard release pipeline (QA → Stage → Prod). If a solution has `isUnmanaged: true`, the release pipeline will import it as an unmanaged solution instead of managed. This also works together with `isExisting: true` — if both are set, the pipeline reads the zip from `solutions/unmanaged/` instead of `solutions/managed/`.

---

## Single solution quick-deploy (Pre-Dev → Dev)

When a developer finishes work on a single solution in Pre-Dev and needs it deployed to Dev:

1. Go to **Pipelines** → **Export Solution from Pre-Dev**
2. Click **Run pipeline**
3. Enter the **solution name** (the unique technical name, e.g. `MyApp`)
4. Click **Run**

The pipeline will export from Pre-Dev and automatically deploy to Dev. To then promote to QA, Stage, or Prod, use the **Release Ad-Hoc** pipeline.

---

## When something looks wrong

**The pipeline ran but nothing was deployed**
- Check if all solutions were already at the same version in the target environment — the pipeline skips those automatically to avoid unnecessary work. This is normal.

**The pipeline failed with a red ✗**
- Click into the failed run and look at the step that went red
- Common causes: a solution version mismatch (the version in the config doesn't match what's in Dev), or a connection issue to the Power Platform environment
- Reach out to your developer with a screenshot of the error step

**Approvals aren't showing up**
- Check that you've been added as an approver on the relevant ADO environment (ask your ADO administrator)
- Check your ADO notification settings

**The daily export didn't run**
- The export looks for a branch named `export/{today's date}-{something}` in the repo — if no such branch exists, it skips. Ask your developer to create the export branch for that date.

---

## Glossary

| Term | What it means |
|---|---|
| **Solution** | A Power Platform "package" containing apps, flows, tables, etc. |
| **Managed** | A solution installed in a way that can't be directly edited — used for QA, Stage, Prod |
| **Unmanaged** | A solution installed in a way that can be edited — used for Dev environments |
| **Artifact** | The packaged files produced by an export pipeline, ready to be deployed |
| **Variable group** | A named set of passwords/URLs stored securely in ADO — edited by your ADO admin |
| **ADO Environment** | A named checkpoint in ADO where approval checks live |
| **build.json** | A configuration file telling the pipeline which solutions to export/deploy and at what versions |
| **Export branch** | A short-lived Git branch that holds a `build.json` for one export run. Daily export branches use `export/yyyy-MM-dd-{token}`; New Dev export branches use `export/{token}` (no date required) |
