# Power Platform Pipelines — Quick Guide

This is the plain-English version. For full technical details see [README.md](./README.md).

---

## What do these pipelines do?

They move Power Platform solutions (apps, flows, etc.) from development environments into production in a controlled, repeatable way. Think of them as an automated moving truck that packages everything in Dev, checks it, and delivers it to Test, then Stage, then Prod — with a stop for your approval before anything goes to production.

---

## The pipelines at a glance

| Pipeline | Runs | What it does |
|---|---|---|
| **Daily Export** | Automatically every night ~10 PM | Saves the latest Dev work to source control and kicks off the Test and QA deployments |
| **Release to Test** | Automatically after Daily Export | Deploys to Test — no approval needed |
| **Release to QA** | Automatically after Daily Export | Deploys to QA — no approval needed |
| **Promote to Stage + Prod** | Manually, when you're ready | Takes a verified build and deploys it to Stage and Prod with approval gates |

---

## The normal day-to-day flow

Most days you don't need to do anything. Here's what happens automatically:

```
Every night ~10 PM
    ↓
Daily Export runs — saves Dev solutions to source control
    ↓
Release to Test and Release to QA pipelines start automatically (in parallel)
    ↓
Deploys to Test and QA — no action needed from you
```

When you're **ready to go to Stage and Prod**, you kick that off yourself:

```
You run the Promote pipeline manually
    ↓
Select the export run you want to promote
    ↓
⏸ Waits for your approval to deploy to Stage
    ↓
⏸ Waits for your approval to deploy to Prod
```

This split means Test and QA get updated on every nightly export, and Stage/Prod only get updated when you deliberately decide to promote.

---

## How to promote a build to Stage and Prod

When you're ready to promote a Test-verified release:

1. Go to **Pipelines** in Azure DevOps
2. Click on the **Promote to Stage and Prod** pipeline (`release-solutions-promote`)
3. Click **Run pipeline**
4. In the **Resources** panel, expand `export-solutions` and select the run you want to promote (usually the most recent one)
5. Click **Run**

Azure DevOps will notify approvers (email or Teams) when each environment is ready for approval.

## How to approve a deployment to Stage or Prod

When a deployment is waiting for your approval:

1. Go to **Pipelines** in Azure DevOps
2. Click on the **Promote to Stage and Prod** pipeline
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

## When something looks wrong

**The pipeline ran but nothing was deployed**
- Check if all solutions were already at the same version in the target environment — the pipeline skips those automatically to avoid unnecessary work. This is normal.

**The pipeline failed with a red ✗**
- Click into the failed run and look at the step that went red
- Common causes: a solution version mismatch (the version in the config doesn't match what's in Dev), or a connection issue to the Power Platform environment
- Reach out to your developer with a screenshot of the error step

**Approvals aren't showing up for the Promote pipeline**
- Check that you've been added as an approver on the `Power Platform Stage` or `Power Platform Prod` ADO environment (ask your ADO administrator)
- Check your ADO notification settings
- Note: approvals only appear in the **Promote to Stage and Prod** pipeline (`release-solutions-promote`), not in the Test or QA pipelines

**The daily export didn't run**
- The export looks for a branch named `export/{today's date}-{something}` in the repo — if no such branch exists, the pipeline marks itself as **Cancelled** (this is expected on nights with no planned release, and the release pipeline will not trigger). Ask your developer to create the export branch for that date when a release is needed.

---

## Glossary

| Term | What it means |
|---|---|
| **Solution** | A Power Platform "package" containing apps, flows, tables, etc. |
| **Managed** | A solution installed in a way that can't be directly edited — used for Test, Stage, Prod |
| **Unmanaged** | A solution installed in a way that can be edited — used for Dev environments |
| **Artifact** | The packaged files produced by an export pipeline, ready to be deployed |
| **Variable group** | A named set of passwords/URLs stored securely in ADO — edited by your ADO admin |
| **ADO Environment** | A named checkpoint in ADO where approval checks live |
| **build.json** | A configuration file telling the pipeline which solutions to export/deploy and at what versions |
| **Export branch** | A short-lived Git branch that holds a `build.json` for one export run. Uses naming pattern `export/yyyy-MM-dd-{token}` (e.g. `export/2026-02-15-sprint42`) |
