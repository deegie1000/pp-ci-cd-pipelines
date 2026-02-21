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
9. **Configuration data migration** — Extract reference/lookup data from Dev (OData) and upsert into target environments using stable GUIDs
10. **Dataverse Export Request tables** — Manage export requests through custom Dataverse tables and a model-driven app instead of manually editing build.json (recommended for daily export)

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
├── configData/                  # Only if config data migration enabled
├── deploymentSettings/          # Only if deployment settings feature enabled
├── exports/
│   └── sample/
├── scripts/                     # If deployment settings or config data enabled
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

1. **`exports/sample/build.json`** — Sample build.json with the user's environment structure. Include `postExportVersion` only if version management is enabled. Include `configData` array only if config data migration is enabled.

### 3b. Pipelines

Generate each pipeline YAML file following the patterns in [pipeline-templates.md](pipeline-templates.md).

2. **`pipelines/export-solutions.yml`** (if daily export enabled) — Scheduled export from Dev. Key decisions:
   - **Dataverse-driven** (if Export Request tables enabled): Queries Dataverse for a Queued Export Request, reads Export Request Solution rows, builds build.json from Dataverse data. Updates Export Request status throughout (Queued → In Progress → Completed/Failed). Sets pipeline URL on the record. Has a failure handler step that marks the request as Failed with error details.
   - **`exportRequestId` parameter**: Optional override to process a specific Export Request by GUID (skips queue lookup)
   - Branch detection pattern: `export/{date}-{token}`
   - Auth: secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`) + service connection for PP tasks. Same credentials used for Dataverse API calls.
   - Publishes `ManagedSolutions` artifact (build.json + managed zips + deployment settings files + config data files)
   - Config data extraction (if enabled): reads Config Data Definition rows from Dataverse (if Export Request tables enabled), runs Sync-ConfigData.ps1 in Extract mode after solution export
   - Post-export version bumping (if enabled): `pac solution online-version` for non-patches, `CloneAsPatch` for patches
   - Deployment settings merge (if enabled): runs Merge-DeploymentSettings.ps1
   - Creates PR to main with auto-complete (squash merge)
   - Updates per-solution status on Export Request Solution records (auto-detected fields: `includesCloudFlows`, `isPatch`, `parentSolution`)

3. **`pipelines/release-solutions.yml`** (if multi-solution release enabled) — Multi-stage release. Key decisions:
   - Triggered by export pipeline completion on `main`
   - Uses `deploy-environment.yml` template for each stage
   - First environment deploys automatically; others require approval (per user config)
   - Validates all artifacts upfront before any imports
   - Skips solutions already at target version
   - Cloud flow activation (if enabled): acquires OAuth token, activates via Dataverse API, warns on failure
   - Config data upsert (if enabled): runs Sync-ConfigData.ps1 in Upsert mode after solution imports
   - **Dataverse status tracking** (if Export Request tables enabled): Passes admin environment credentials and per-stage Dataverse field names to the template. Each stage updates its deploy status field (e.g., `cr_qadeploystatus`) and completed timestamp on the Export Request. Sets `cr_releasepipelineurl` on first stage. Variables: `AdminEnvironmentUrl`, `AdminClientId`, `AdminTenantId`, `AdminClientSecret` (secret)

4. **`pipelines/export-solution-predev.yml`** (if on-demand export enabled) — Single solution export. Key decisions:
   - Manual trigger with `solutionName` parameter
   - Auth: service connection (no secrets in YAML)
   - Uses ADO tasks (`PowerPlatformExportSolution@2`, etc.)
   - Commits to repo, publishes artifact, triggers deploy pipeline

5. **`pipelines/deploy-solution.yml`** (if multi-stage deploy enabled) — Multi-stage single-solution deploy. Key decisions:
   - Triggered by pre-dev export pipeline completion
   - First stage (Dev): inline, handles auto-trigger + manual, publishes `DeploySolution` artifact (including build.json and config data files)
   - Subsequent stages: use `deploy-single-solution.yml` template, download from Dev stage
   - Config data upsert (if enabled): runs after solution import in each stage
   - Auth: variable groups for all stages
   - Approval gates on environments (per user config)

### 3c. Templates

6. **`pipelines/templates/deploy-environment.yml`** (if multi-solution release enabled) — Reusable template for multi-solution deployment. Parameters: `stageName`, `displayName`, `environmentName`, `variableGroup`, `dependsOn`. If Dataverse Export Request tables enabled, also accepts: `adminEnvironmentUrl`, `adminClientId`, `adminTenantId`, `dataverseStatusField`, `dataverseCompletedField`, `dataverseExportRequestTable`, `statusInProgress`, `statusCompleted`, `statusFailed`. Reads `exportRequestId` from build.json artifact. Updates per-stage deploy status and timestamp on Export Request at start (In Progress) and end (Completed/Failed) of each stage.

7. **`pipelines/templates/deploy-single-solution.yml`** (if multi-stage deploy enabled) — Reusable template for single-solution deployment. Same parameter pattern as deploy-environment.

### 3d. Scripts

8. **`scripts/Merge-DeploymentSettings.ps1`** (if deployment settings enabled) — Merge deployment settings from export folder into root. Key algorithm:
   - EnvironmentVariables matched by `SchemaName` (export overwrites root)
   - ConnectionReferences matched by `LogicalName` (export overwrites root)
   - New items appended; existing items not in export preserved

9. **`scripts/Sync-ConfigData.ps1`** (if config data migration enabled) — Extract and upsert configuration data. Two modes:
   - `-Mode Extract`: Queries OData from Dev, writes JSON data files to `configData/`
   - `-Mode Upsert`: Reads JSON data files and PATCHes each record by stable GUID into target environment
   - Handles OData pagination (`@odata.nextLink`)
   - Cleans OData metadata from extracted records
   - Extract failures fail the pipeline; upsert record failures are warnings

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
    - `tests/Config-Data-Validation.Tests.ps1` (if config data migration enabled) — Tests configData schema validation and data file serialization

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
    - Configuration data (if enabled): how it works, stable GUIDs, execution order
    - Dataverse Custom Tables (if Export Request tables enabled):
      - Export Request table: all columns with types and descriptions (status choices: 0=Draft, 1=Queued, 2=In Progress, 3=Completed, 4=Failed, 5=Run Now)
      - Export Request Solution table: all columns
      - Config Data Definition table: all columns (if config data enabled)
      - User Experience section: workflow steps with ASCII art mockup of model-driven app form, mention both Queued and Run Now options
      - Run Now: Ad-Hoc Export via Cloud Flow section (if Export Request tables enabled): full setup guide with PAT creation, pipeline ID lookup, cloud flow trigger/action configuration (Dataverse trigger → HTTP POST to ADO Pipelines API with exportRequestId → Update status to In Progress), testing steps, and troubleshooting table
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
    - How to execute (step-by-step for each workflow, include Queued vs Run Now if Export Request tables enabled)
    - Changing the schedule (cron examples table)
    - Troubleshooting (table per pipeline: symptom, cause, fix)

## Step 4: Summarize

After generating all files, provide:
1. List of files created
2. ADO setup checklist (what the user needs to configure in Azure DevOps)
3. First-run instructions (how to test the pipeline)

## Architecture Decisions (follow these exactly)

These are the **hardened design decisions** from production use. Do not deviate unless the user explicitly requests changes.

### Dataverse Export Request Tables (if enabled)
- **Three custom tables**: Export Request (`cr_exportrequests`), Export Request Solution (`cr_exportrequestsolutions`), Config Data Definition (`cr_configdatadefinitions`). Replace `cr_` with the user's publisher prefix.
- **Export pipeline** queries Dataverse for a Queued (`cr_status eq 1`) Export Request, reads its child Export Request Solution rows, and builds `build.json` from that data. The pipeline does NOT read from a pre-existing build.json — it creates one from Dataverse.
- **`exportRequestId` parameter**: When provided, the pipeline fetches that specific Export Request by GUID (skip queue lookup). This is how the "Run Now" cloud flow and manual ADO runs work.
- **Status lifecycle**: Draft (0) → Queued (1) or Run Now (5) → In Progress (2) → Completed (3) or Failed (4). The pipeline updates status at each transition.
- **Pipeline URL tracking**: Export pipeline sets `cr_pipelinerunurl`. Release pipeline sets `cr_releasepipelineurl`.
- **Per-stage deploy status**: Release pipeline template updates per-stage fields on the Export Request (e.g., `cr_qadeploystatus`, `cr_qacompletedon`). Status values: 0=Pending, 2=In Progress, 3=Completed, 4=Failed.
- **Failure handler**: Export pipeline has a dedicated failure handler step (`condition: and(failed(), ne(variables['ExportRequestId'], ''))`) that marks the Export Request as Failed with `cr_errordetails` and `cr_completedon`.
- **Per-solution updates**: After export, pipeline updates each Export Request Solution record with auto-detected fields: `cr_status` (Completed), `cr_includescloudflows`, `cr_ispatch`, `cr_parentsolution`.
- **Config Data Definitions**: Queried from Dataverse (same relationship filter as solutions), used to populate `build.json` configData array.
- **Admin environment credentials** (release pipeline): The Dataverse tables live in the Dev/admin environment. The release pipeline needs separate credentials (`AdminEnvironmentUrl`, `AdminClientId`, `AdminTenantId`, `AdminClientSecret`) to update the Export Request during deployment to downstream environments.
- **Run Now (status 5)**: Not handled by the pipeline. A Power Automate cloud flow watches for this status and queues the pipeline via ADO REST API with `exportRequestId`.
- **Graceful degradation**: If `exportRequestId` is not in build.json, the release template skips all Dataverse status updates. This supports manual/ad-hoc runs without Export Request tables.

### Authentication Model
- **Service connections**: Used only for ADO task-based operations (Pre-Dev export, daily export PP tasks)
- **Variable groups**: Used for pac CLI auth in all deployment stages. One group per environment: `{Prefix}{Env}` with keys: `EnvironmentUrl`, `ClientId`, `ClientSecret` (secret), `TenantId`
- **Secret pipeline variables**: Used only for daily export pipeline's pac CLI auth (alternative to variable group)

### Artifact Flow
- Daily export publishes `ManagedSolutions` artifact → consumed by release pipeline
  - Contains: build.json (with `exportRequestId` if Dataverse tables enabled), `{name}_{version}.zip` files, `deploymentSettings_*.json`, `configData/*.json`
- Pre-dev export publishes `ManagedSolution` artifact → consumed by deploy pipeline Dev stage
- Deploy pipeline Dev stage re-publishes as `DeploySolution` artifact → consumed by downstream stages
  - If auto-triggered: includes build.json and configData files from upstream artifact
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

### Configuration Data Strategy
- Defined in `build.json` under `configData` array (alongside `solutions`)
- Extract via OData `$select`/`$filter` (not FetchXML)
- Upsert via `PATCH /api/data/v9.2/{entity}({guid})` — creates if not exists, updates if exists
- Requires **stable GUIDs** across all environments (same record = same primary key GUID everywhere)
- Data files stored in `configData/` directory, committed to repo
- Runs after solution imports (tables must exist before data can be written)
- Extract failures fail the pipeline; upsert record-level failures are warnings
- Uses shared `scripts/Sync-ConfigData.ps1` for both Extract and Upsert modes

### Error Handling Philosophy
- **Validate upfront**: Check all artifacts exist before importing anything
- **Fail fast on critical errors**: Version mismatch, missing artifacts, auth failure
- **Warn on non-critical**: Cloud flow activation failures and config data upsert record failures logged as warnings, don't fail deployment
- **Accumulate and summarize**: Track deployed/skipped/failed counts, report at end
- **Dataverse failure handler** (if Export Request tables enabled): Export pipeline has a dedicated final step with condition `and(failed(), ne(variables['ExportRequestId'], ''))` that updates the Export Request to Failed with error details and timestamp. Release template uses `and(not(canceled()), ne(variables['ExportRequestId'], ''))` to update per-stage status. Dataverse update failures themselves are warnings (don't mask the real error)

### Cloud Flow Activation
- Acquire OAuth token once per stage (graceful failure if token unavailable)
- Query solution components (type 29 = workflow), filter for cloud flows (category 5)
- Only activate inactive flows (statecode != 1)
- Individual flow failures = warning (not error)

### Multi-Stage Pipeline Pattern
- Use ADO `deployment` jobs with `environment` parameter for approval gates
- Use `strategy: runOnce: deploy: steps:` pattern
- Templates take standard parameters: `stageName`, `displayName`, `environmentName`, `variableGroup`, `dependsOn`
- If Dataverse Export Request tables enabled, templates also take: `adminEnvironmentUrl`, `adminClientId`, `adminTenantId`, `dataverseStatusField`, `dataverseCompletedField`, `dataverseExportRequestTable` (default: `cr_exportrequests`), `statusInProgress` (default: `2`), `statusCompleted` (default: `3`), `statusFailed` (default: `4`)
- Conditional `dependsOn`: empty array for first stage, previous stage name for others
- If Dataverse tracking enabled, each stage has two extra steps: (1) read `exportRequestId` from build.json + update status to In Progress at start, (2) update status to Completed/Failed + set timestamp at end (runs even on failure, condition: `and(not(canceled()), ne(variables['ExportRequestId'], ''))`)

### Import Options
- Always use: `--stage-and-upgrade`, `--skip-lower-version`, `--activate-plugins`
- Conditionally use: `--settings-file` (only when deployment settings enabled and file exists)
- Solution import via `pac solution import` (pac CLI, not ADO tasks) for deployment stages

### PR Automation (Daily Export)
- Create PR from export branch to main
- Set auto-complete with squash merge
- Include descriptive title and body listing solutions
- Attempt auto-approve (may fail due to branch policies — that's OK)
