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
- `Dev Test Stage Prod` (standard 4-stage)
- `Dev Test Prod` (no staging)
- `Dev Test Prod` (simplified)
- Custom names

**For each environment, ask:**
- Environment URL (e.g., `https://yourorg-dev.crm.dynamics.com`)
- Whether it requires approval before deployment (typically: first environment = no, others = yes)

**Features to include (ask as multi-select):**
1. **Scheduled daily export** — Nightly export from Dev, validate versions, PR to main
2. **Multi-solution release pipeline** — Deploy multiple solutions from build.json through environments
3. **Deployment settings** — Environment-specific connection references and environment variables
4. **Post-export version management** — Auto-bump solution versions in Dev after export
5. **Cloud flow activation** — Activate cloud flows after deployment (via Dataverse API)
6. **Patch solution support** — Detect and handle solution patches (CloneAsPatch)
7. **Configuration data migration** — Extract reference/lookup data from Dev (OData) and upsert into target environments using stable GUIDs

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
   - Branch detection pattern: `export/{date}-{token}`
   - Auth: secret pipeline variables (`ClientId`, `ClientSecret`, `TenantId`) + service connection for PP tasks
   - Publishes `ManagedSolutions` artifact (build.json + managed zips + deployment settings files + config data files)
   - Config data extraction (if enabled): runs Sync-ConfigData.ps1 in Extract mode after solution export
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
   - Config data upsert (if enabled): runs Sync-ConfigData.ps1 in Upsert mode after solution imports

### 3c. Templates

4. **`pipelines/templates/deploy-environment.yml`** (if multi-solution release enabled) — Reusable template for multi-solution deployment. Parameters: `stageName`, `displayName`, `environmentName`, `variableGroup`, `dependsOn`.

### 3d. Scripts

7. **`scripts/Merge-DeploymentSettings.ps1`** (if deployment settings enabled) — Merge deployment settings from export folder into root. Key algorithm:
   - EnvironmentVariables matched by `SchemaName` (export overwrites root)
   - ConnectionReferences matched by `LogicalName` (export overwrites root)
   - New items appended; existing items not in export preserved

8. **`scripts/Sync-ConfigData.ps1`** (if config data migration enabled) — Extract and upsert configuration data. Two modes:
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
- **Service connections**: Used only for ADO task-based operations (daily export PP tasks)
- **Variable groups**: Used for pac CLI auth in all deployment stages. One group per environment: `{Prefix}{Env}` with keys: `EnvironmentUrl`, `ClientId`, `ClientSecret` (secret), `TenantId`
- **Secret pipeline variables**: Used only for daily export pipeline's pac CLI auth (alternative to variable group)

### Artifact Flow
- Daily export publishes `ManagedSolutions` artifact → consumed by release pipeline
  - Contains: build.json, `{name}_{version}.zip` files, `deploymentSettings_*.json`, `configData/*.json`
- Artifact always contains solution zips named `{name}_{version}.zip`

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
- Always use: `--activate-plugins`, `--async`, `--max-async-wait-time 60`
- Default upgrade strategy (managed, non-rollback, non-unmanaged): `--stage-and-upgrade --skip-lower-version`
- Conditionally use: `--settings-file` (only when deployment settings enabled and file exists)
- Power Pages override: if `powerPagesConfiguration.deployMode` is set, it controls the import strategy:
  - `UPGRADE` → `--stage-and-upgrade --skip-lower-version`
  - `UPDATE` → no staging flags (plain import)
  - `STAGE_FOR_UPGRADE` → `--import-as-holding`
  - `powerPagesConfiguration.addAllExistingSiteComponentsForSites` → `--add-existing-website-components <value>`
- Solution import via `pac solution import` (pac CLI, not ADO tasks) for deployment stages

### PR Automation (Daily Export)
- Create PR from export branch to main
- Set auto-complete with squash merge
- Include descriptive title and body listing solutions
- Attempt auto-approve (may fail due to branch policies — that's OK)
