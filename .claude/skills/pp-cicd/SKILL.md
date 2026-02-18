---
name: pp-cicd
description: Generate Power Platform CI/CD pipelines for Azure DevOps from scratch. Creates export, release, and deploy pipelines with multi-stage approvals, deployment settings, version management, and cloud flow activation. Use when setting up a new Power Platform project or migrating to ADO pipelines.
disable-model-invocation: true
argument-hint: [environment-list e.g. "Dev QA Stage Prod"]
---

# Power Platform CI/CD Pipeline Generator

Generate a complete Azure DevOps CI/CD pipeline infrastructure for Power Platform solutions. This skill creates all pipeline YAML files, templates, scripts, tests, sample configuration, and documentation.

## Step 1: Gather Configuration

Before generating anything, ask the user the following questions. Use the AskUserQuestion tool to collect answers interactively. If the user provided arguments (`$ARGUMENTS`), use those as the environment list and ask the remaining questions.

### Required Information

**Environments:** Which Power Platform environments will you deploy to? The arguments `$ARGUMENTS` may already specify these (e.g., `Dev QA Stage Prod`). If not provided, ask. Common patterns:
- `Dev QA Stage Prod` (standard 4-stage)
- `Dev QA Prod` (no staging)
- `Dev Test Prod` (simplified)
- Custom names

**For each environment, ask:**
- Environment URL (e.g., `https://yourorg-dev.crm.dynamics.com`)
- Whether it requires approval before deployment (typically: first environment = no, others = yes)

**Features to include (ask as multi-select):**
1. **Scheduled daily export** — Nightly export from Dev, validate versions, PR to main
2. **Multi-solution release pipeline** — Deploy multiple solutions from build.json through environments
3. **On-demand single-solution export** — Export from a "Pre-Dev" or sandbox environment
4. **Multi-stage single-solution deploy** — Deploy a single solution through all environments with approvals
5. **Deployment settings** — Environment-specific connection references and environment variables
6. **Post-export version management** — Auto-bump solution versions in Dev after export
7. **Cloud flow activation** — Activate cloud flows after deployment (via Dataverse API)
8. **Patch solution support** — Detect and handle solution patches (CloneAsPatch)

**Naming conventions (offer defaults, let user override):**
- Service connection prefix: `PowerPlatform` (e.g., `PowerPlatformDev`)
- Variable group prefix: `PowerPlatform-` (e.g., `PowerPlatform-Dev`)
- ADO environment prefix: `Power Platform ` (e.g., `Power Platform Dev`)
- Pipeline names: `export-solutions`, `release-solutions`, `deploy-solution`, etc.

**Schedule (if daily export enabled):**
- What time should the daily export run? (default: 10:00 PM Eastern / `0 3 * * *` UTC)
- Weekdays only or every day?

## Step 2: Generate Directory Structure

Create the following directory structure at the repository root:

```
{repo-root}/
├── pipelines/
│   └── templates/
├── deploymentSettings/          # Only if deployment settings feature enabled
├── exports/
│   └── sample/
├── scripts/                     # Only if deployment settings feature enabled
├── tests/
└── solutions/
    ├── unmanaged/
    ├── unpacked/
    └── managed/
```

## Step 3: Generate Files

Read [patterns.md](patterns.md) for detailed code patterns and conventions. Read [pipeline-templates.md](pipeline-templates.md) for the YAML structure of each pipeline.

Generate files in this order (skip any that correspond to disabled features):

### 3a. Core Configuration

1. **`exports/sample/build.json`** — Sample build.json with the user's environment structure. Include `postExportVersion` only if version management is enabled.

### 3b. Pipelines

Generate each pipeline YAML file following the patterns in [pipeline-templates.md](pipeline-templates.md).

2. **`pipelines/export-solutions.yml`** (if daily export enabled) — Scheduled export from Dev. Key decisions:
   - Branch detection pattern: `export/{date}-{token}`
   - Auth: secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`) + service connection for PP tasks
   - Publishes `ManagedSolutions` artifact (build.json + managed zips + deployment settings files)
   - Post-export version bumping (if enabled): `pac solution online-version` for non-patches, `CloneAsPatch` for patches
   - Deployment settings merge (if enabled): runs Merge-DeploymentSettings.ps1
   - Creates PR to main with auto-complete (squash merge)

3. **`pipelines/release-solutions.yml`** (if multi-solution release enabled) — Multi-stage release. Key decisions:
   - Triggered by export pipeline completion on `main`
   - Uses `deploy-environment.yml` template for each stage
   - First environment deploys automatically; others require approval (per user config)
   - Validates all artifacts upfront before any imports
   - Skips solutions already at target version
   - Cloud flow activation (if enabled): acquires OAuth token, activates via Dataverse API, warns on failure

4. **`pipelines/export-solution-predev.yml`** (if on-demand export enabled) — Single solution export. Key decisions:
   - Manual trigger with `solutionName` parameter
   - Auth: service connection (no secrets in YAML)
   - Uses ADO tasks (`PowerPlatformExportSolution@2`, etc.)
   - Commits to repo, publishes artifact, triggers deploy pipeline

5. **`pipelines/deploy-solution.yml`** (if multi-stage deploy enabled) — Multi-stage single-solution deploy. Key decisions:
   - Triggered by pre-dev export pipeline completion
   - First stage (Dev): inline, handles auto-trigger + manual, publishes `DeploySolution` artifact
   - Subsequent stages: use `deploy-single-solution.yml` template, download from Dev stage
   - Auth: variable groups for all stages
   - Approval gates on environments (per user config)

### 3c. Templates

6. **`pipelines/templates/deploy-environment.yml`** (if multi-solution release enabled) — Reusable template for multi-solution deployment. Parameters: `stageName`, `displayName`, `environmentName`, `variableGroup`, `dependsOn`.

7. **`pipelines/templates/deploy-single-solution.yml`** (if multi-stage deploy enabled) — Reusable template for single-solution deployment. Same parameter pattern as deploy-environment.

### 3d. Scripts

8. **`scripts/Merge-DeploymentSettings.ps1`** (if deployment settings enabled) — Merge deployment settings from export folder into root. Key algorithm:
   - EnvironmentVariables matched by `SchemaName` (export overwrites root)
   - ConnectionReferences matched by `LogicalName` (export overwrites root)
   - New items appended; existing items not in export preserved

### 3e. Deployment Settings

9. **`deploymentSettings/deploymentSettings_{Env}.json`** (if deployment settings enabled) — One file per environment with empty arrays as starting point:
   ```json
   {
     "EnvironmentVariables": [],
     "ConnectionReferences": []
   }
   ```

### 3f. Tests

10. **Pester test files** — Generate tests for each feature that has testable logic:
    - `tests/Build-Json-Validation.Tests.ps1` — Validates build.json schema (required fields, defaults, constraints)
    - `tests/Merge-DeploymentSettings.Tests.ps1` (if deployment settings enabled) — Tests merge algorithm
    - `tests/Cloud-Flow-Detection.Tests.ps1` (if cloud flows enabled) — Tests flow detection logic
    - `tests/Deploy-Dev-Settings.Tests.ps1` (if both deploy + deployment settings enabled) — Tests settings resolution

### 3g. Documentation

11. **`README.md`** — Comprehensive documentation following this structure:
    - Repository structure (tree diagram)
    - Pipeline overview table (number, name, trigger, purpose)
    - Detailed section per pipeline (what it does, stages table, trigger, auth, parameters)
    - Pipeline flow diagrams (ASCII art):
      - Daily export + release flow diagram
      - On-demand promotion flow diagram (if applicable)
      - Architecture overview diagram (showing both pipeline tracks side-by-side)
    - build.json configuration (schema, field reference table, version rules, caching)
    - Deployment settings (if enabled): how it works, merge behavior, example, rules
    - Post-export version management (if enabled): how it works, patch handling, example
    - Testing section (how to run, test suite table)
    - ADO Setup guide (step-by-step with exact UI instructions):
      1. Install Power Platform Build Tools extension
      2. Register app in Entra ID
      3. Create service connections (table with names, environments, used-by)
      4. Create variable groups (one section per environment with variable table)
      5. Create ADO environments (table with names, approval checks, shared-environment note)
      6. Create pipelines (table with YAML file, recommended name)
      7. Configure secret variables (if daily export)
      8. Update pipeline variables (code blocks showing what to customize)
      9. Grant repository permissions
    - How to execute (step-by-step for each workflow)
    - Changing the schedule (cron examples table)
    - Troubleshooting (table per pipeline: symptom, cause, fix)

## Step 4: Summarize

After generating all files, provide:
1. List of files created
2. ADO setup checklist (what the user needs to configure in Azure DevOps)
3. First-run instructions (how to test the pipeline)

## Architecture Decisions (follow these exactly)

These are the **hardened design decisions** from production use. Do not deviate unless the user explicitly requests changes.

### Authentication Model
- **Service connections**: Used only for ADO task-based operations (Pre-Dev export, daily export PP tasks)
- **Variable groups**: Used for pac CLI auth in all deployment stages. One group per environment: `{Prefix}{Env}` with keys: `EnvironmentUrl`, `ClientId`, `ClientSecret` (secret), `TenantId`
- **Secret pipeline variables**: Used only for daily export pipeline's pac CLI auth (alternative to variable group)

### Artifact Flow
- Daily export publishes `ManagedSolutions` artifact → consumed by release pipeline
- Pre-dev export publishes `ManagedSolution` artifact → consumed by deploy pipeline Dev stage
- Deploy pipeline Dev stage re-publishes as `DeploySolution` artifact → consumed by downstream stages
- Artifact always contains solution zips named `{name}_{version}.zip` (daily) or `{name}.zip` (pre-dev)

### Deployment Settings Strategy
- Root `deploymentSettings/` folder = accumulated source of truth
- Export folders contain per-run overrides
- Merge script combines them (export wins on key match, new items appended)
- Only ONE solution in build.json should have `includeDeploymentSettings: true`

### Version Validation
- build.json version MUST match Dev environment's Solution.xml version
- Pipeline reads and compares — never writes during export
- Post-export version bump happens AFTER artifact publishing (doesn't affect exported artifacts)

### Error Handling Philosophy
- **Validate upfront**: Check all artifacts exist before importing anything
- **Fail fast on critical errors**: Version mismatch, missing artifacts, auth failure
- **Warn on non-critical**: Cloud flow activation failures logged as warnings, don't fail deployment
- **Accumulate and summarize**: Track deployed/skipped/failed counts, report at end

### Cloud Flow Activation
- Acquire OAuth token once per stage (graceful failure if token unavailable)
- Query solution components (type 29 = workflow), filter for cloud flows (category 5)
- Only activate inactive flows (statecode != 1)
- Individual flow failures = warning (not error)

### Multi-Stage Pipeline Pattern
- Use ADO `deployment` jobs with `environment` parameter for approval gates
- Use `strategy: runOnce: deploy: steps:` pattern
- Templates take standard parameters: `stageName`, `displayName`, `environmentName`, `variableGroup`, `dependsOn`
- Conditional `dependsOn`: empty array for first stage, previous stage name for others

### Import Options
- Always use: `--force-overwrite`, `--activate-plugins`
- Conditionally use: `--settings-file` (only when deployment settings enabled and file exists)
- Solution import via `pac solution import` (pac CLI, not ADO tasks) for deployment stages

### PR Automation (Daily Export)
- Create PR from export branch to main
- Set auto-complete with squash merge
- Include descriptive title and body listing solutions
- Attempt auto-approve (may fail due to branch policies — that's OK)
