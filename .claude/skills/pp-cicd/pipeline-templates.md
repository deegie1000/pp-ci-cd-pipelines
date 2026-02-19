# Pipeline YAML Generation Templates

This document provides the structural skeleton for each pipeline. When generating, fill in the placeholders (`{...}`) with user-provided values and expand the PowerShell logic using patterns from [patterns.md](patterns.md).

## 1. Daily Export Solutions (`export-solutions.yml`)

### Structure

```yaml
# Header comment block (see patterns.md)

trigger: none

schedules:
  - cron: "{cron_expression}"    # e.g., "0 3 * * *" for 10 PM EST
    displayName: "{schedule_description}"
    branches:
      include:
        - main
    always: true

parameters:
  - name: exportRequestId
    displayName: "Override export request ID (leave empty to pick next queued request)"
    type: string
    default: ""
  - name: exportBranch
    displayName: "Override export branch name (skip auto-detect)"
    type: string
    default: ""
  - name: dateOverride
    displayName: "Override date for branch detection (yyyy-MM-dd)"
    type: string
    default: ""

variables:
  - name: PowerPlatformServiceConnection
    value: "{dev_service_connection}"        # e.g., "PowerPlatformDev"
  - name: EnvironmentUrl
    value: "{dev_environment_url}"           # e.g., "https://yourorg.crm.dynamics.com"
  # PatchDisplayNamePrefix only if patch support enabled
  - name: PatchDisplayNamePrefix
    value: "(DO NOT USE) "
  # Dataverse table names (only if Export Request tables enabled)
  - name: TableExportRequest
    value: "{export_request_table}"          # e.g., "cr_exportrequests"
  - name: TableExportRequestSolution
    value: "{export_request_solution_table}" # e.g., "cr_exportrequestsolutions"
  - name: TableConfigDataDefinition
    value: "{config_data_def_table}"         # e.g., "cr_configdatadefinitions"
  - name: StatusDraft
    value: "0"
  - name: StatusQueued
    value: "1"
  - name: StatusInProgress
    value: "2"
  - name: StatusCompleted
    value: "3"
  - name: StatusFailed
    value: "4"

pool:
  vmImage: "windows-latest"

steps:
  # 1. Checkout with persist credentials (needed for push + PR)
  - checkout: self
    persistCredentials: true
    fetchDepth: 0

  # 2. Install Power Platform Build Tools
  - task: PowerPlatformToolInstaller@2

  # 3. Authenticate pac CLI (using secret pipeline variables)
  # See patterns.md: "Secret Pipeline Variables" pattern

  # 3b. (If Dataverse Export Request tables enabled) Acquire OAuth token + Query Dataverse
  #    - Acquire OAuth token for Dataverse API (same credentials as pac CLI)
  #    - Query for Export Request: use exportRequestId parameter if provided, else find Queued request
  #    - Exit gracefully if no queued request found
  #    - Update Export Request to In Progress + set cr_pipelinerunurl
  #    - Query Export Request Solutions (ordered by cr_sortorder asc, createdon asc)
  #    - Fail Export Request if no solutions found
  #    - Query Config Data Definitions (if config data enabled)
  #    - Build build.json from Dataverse data (includes exportRequestId)
  #    - Set pipeline variables: ExportRequestId, SolutionIdsJson (for later updates)
  #    See patterns.md: "Dataverse Export Request Patterns"

  # 4. Detect export branch (or use override)
  # Logic: convert UTC to Eastern Time, find branch matching export/{date}-*

  # 5. Read build.json from export branch
  #    (If Dataverse tables enabled: build.json was created in step 3b, not read from branch)

  # 6. For each solution in build.json:
  #    a. Check cache (skip if managed zip exists for name+version)
  #    b. Export unmanaged from Dev
  #       - task: PowerPlatformExportSolution@2
  #    c. Clean unpack
  #       - Delete existing unpacked folder
  #       - task: PowerPlatformUnpackSolution@2
  #    d. Detect cloud flows (scan Workflows/ for .json files)
  #    e. Validate version (compare Solution.xml vs build.json)
  #    f. Detect patches (check for ParentSolution in Solution.xml)
  #    g. Pack as managed
  #       - task: PowerPlatformPackSolution@2

  # 7. Write updated build.json (with auto-detected flags)

  # 8. Extract config data from Dev (if configData defined in build.json)
  #    - Run scripts/Sync-ConfigData.ps1 -Mode Extract
  #    - Writes JSON data files to configData/
  #    - Stages config data files for artifact

  # 9. Publish artifact: ManagedSolutions
  #    Contents: build.json, {name}_{version}.zip files, deploymentSettings_*.json, configData/*.json
  - task: PublishPipelineArtifact@1
    inputs:
      targetPath: $(Build.ArtifactStagingDirectory)
      artifact: ManagedSolutions

  # 10. Post-export version management (if postExportVersion set)
  #     - Non-patches: pac solution online-version
  #     - Patches: rename old + CloneAsPatch

  # 11. Merge deployment settings (if deploymentSettings_*.json exist)
  #     - Run scripts/Merge-DeploymentSettings.ps1

  # 12. Commit and push to export branch (solutions/, configData/, deploymentSettings/)

  # 13. Create PR to main (auto-complete, squash merge)

  # 14. (If Dataverse Export Request tables enabled) Update Dataverse completion status
  #     - Update each Export Request Solution record: cr_status=Completed, cr_includescloudflows, cr_ispatch, cr_parentsolution
  #     - Update Export Request: cr_status=Completed, cr_completedon=timestamp
  #     See patterns.md: "Update Per-Solution Status After Export", "Mark Export Request Completed"

  # 15. (If Dataverse Export Request tables enabled) Failure handler step
  #     - condition: and(failed(), ne(variables['ExportRequestId'], ''))
  #     - Acquires fresh OAuth token (previous may be in failed step's scope)
  #     - Updates Export Request: cr_status=Failed, cr_completedon=timestamp, cr_errordetails
  #     See patterns.md: "Export Pipeline Failure Handler"
```

### Key Generation Rules

- Steps 8, 10-11 are conditional (only generate if respective features enabled)
- Steps 3b, 14-15 are conditional (only generate if Dataverse Export Request tables enabled)
- Step 15 (failure handler) MUST be the last step and has `condition: and(failed(), ne(variables['ExportRequestId'], ''))`
- The export loop (step 6) is a single large PowerShell step
- Artifact staging copies files to `$(Build.ArtifactStagingDirectory)` before publish
- PR creation uses `az repos pr create` CLI
- When Dataverse tables are enabled, the `exportRequestId` pipeline parameter is always generated

---

## 2. Release Solutions (`release-solutions.yml`)

### Structure

```yaml
# Header comment block

trigger: none

resources:
  pipelines:
    - pipeline: ExportPipeline
      source: "{export_pipeline_name}"       # e.g., "export-solutions"
      trigger:
        branches:
          include:
            - main

pool:
  vmImage: "windows-latest"

# (If Dataverse Export Request tables enabled) Admin environment variables
variables:
  - name: AdminEnvironmentUrl
    value: "{admin_environment_url}"         # e.g., "https://yourorg-dev.crm.dynamics.com"
  - name: AdminClientId
    value: "$(AdminClientId)"                # Set in ADO pipeline variables
  - name: AdminTenantId
    value: "$(AdminTenantId)"                # Set in ADO pipeline variables
  # AdminClientSecret: configured as secret pipeline variable in ADO UI

stages:
  # Generate one stage per environment using the template
  # First environment: dependsOn is empty (deploys automatically)
  # Subsequent environments: dependsOn is previous stage

  - template: templates/deploy-environment.yml
    parameters:
      stageName: "{env_1_short}"             # e.g., "QA"
      displayName: "Deploy to {env_1}"
      environmentName: "{ado_env_1}"         # e.g., "Power Platform QA"
      variableGroup: "{var_group_1}"         # e.g., "PowerPlatform-QA"
      dependsOn: ""                          # Empty = no dependency (first stage)
      # (If Dataverse Export Request tables enabled) Dataverse tracking parameters:
      adminEnvironmentUrl: $(AdminEnvironmentUrl)
      adminClientId: $(AdminClientId)
      adminTenantId: $(AdminTenantId)
      dataverseStatusField: "{env_1_status_field}"      # e.g., "cr_qadeploystatus"
      dataverseCompletedField: "{env_1_completed_field}" # e.g., "cr_qacompletedon"

  - template: templates/deploy-environment.yml
    parameters:
      stageName: "{env_2_short}"             # e.g., "Stage"
      displayName: "Deploy to {env_2}"
      environmentName: "{ado_env_2}"
      variableGroup: "{var_group_2}"
      dependsOn: "{env_1_short}"             # e.g., "QA"
      adminEnvironmentUrl: $(AdminEnvironmentUrl)
      adminClientId: $(AdminClientId)
      adminTenantId: $(AdminTenantId)
      dataverseStatusField: "{env_2_status_field}"
      dataverseCompletedField: "{env_2_completed_field}"

  # ... repeat for each environment
```

### Key Generation Rules

- The release pipeline itself contains NO deployment logic — it's all in the template
- One `template:` block per environment
- `dependsOn` chains stages sequentially
- Pipeline resource alias (`ExportPipeline`) used in the template's download steps
- The `source` value must match the exact ADO pipeline name
- (If Dataverse tables enabled) Admin environment variables point to where Export Request tables live (typically the Dev environment)
- (If Dataverse tables enabled) Each stage gets its own `dataverseStatusField` and `dataverseCompletedField` values. Naming convention: `cr_{env}deploystatus` and `cr_{env}completedon` (lowercase env name, replace `cr_` with publisher prefix)
- `AdminClientSecret` is a secret pipeline variable configured in the ADO UI (not in YAML)

---

## 3. Deploy Environment Template (`templates/deploy-environment.yml`)

### Structure

```yaml
# Header comment block

parameters:
  - name: stageName
    type: string
  - name: displayName
    type: string
  - name: environmentName
    type: string
  - name: variableGroup
    type: string
  - name: dependsOn
    type: string
    default: ""
  # (If Dataverse Export Request tables enabled) Admin environment parameters:
  - name: adminEnvironmentUrl
    type: string
    default: ""
  - name: adminClientId
    type: string
    default: ""
  - name: adminTenantId
    type: string
    default: ""
  - name: dataverseStatusField
    type: string
    default: ""                              # e.g., "cr_qadeploystatus"
  - name: dataverseCompletedField
    type: string
    default: ""                              # e.g., "cr_qacompletedon"
  - name: dataverseExportRequestTable
    type: string
    default: "{export_request_table}"        # e.g., "cr_exportrequests"
  - name: statusInProgress
    type: string
    default: "2"
  - name: statusCompleted
    type: string
    default: "3"
  - name: statusFailed
    type: string
    default: "4"

stages:
  - stage: ${{ parameters.stageName }}
    displayName: ${{ parameters.displayName }}
    ${{ if eq(parameters.dependsOn, '') }}:
      dependsOn: []
    ${{ else }}:
      dependsOn: ${{ parameters.dependsOn }}
    variables:
      - group: ${{ parameters.variableGroup }}
    jobs:
      - deployment: Deploy
        displayName: "Deploy solutions to ${{ parameters.stageName }}"
        environment: ${{ parameters.environmentName }}
        strategy:
          runOnce:
            deploy:
              steps:
                # 1. Download ManagedSolutions artifact from export pipeline
                - download: ExportPipeline
                  artifact: ManagedSolutions

                # 1b. (If Dataverse tables enabled) Read exportRequestId from build.json
                #     + Update deploy status to In Progress + set cr_releasepipelineurl
                #     See patterns.md: "Release Template — Read exportRequestId + Update Deploy Status (Start)"

                # 2. Install Power Platform Build Tools
                - task: PowerPlatformToolInstaller@2

                # 3. Authenticate pac CLI
                # See patterns.md

                # 4. Read build.json from artifact
                # 5. Validate all artifacts exist (upfront)
                # 6. Query installed solutions (pac solution list)
                # 7. Acquire OAuth token (if cloud flow activation enabled)
                # 8. Deploy each solution in order:
                #    - Skip if already at target version
                #    - Import with --force-overwrite --activate-plugins
                #    - Apply --settings-file if includeDeploymentSettings
                #    - Activate cloud flows if includesCloudFlows
                # 9. Print summary (deployed/skipped/failed counts)
                #    - Fail if any solutions failed

                # Steps 4-9 are one large PowerShell block
                - pwsh: |
                    # ... (see patterns.md for each sub-pattern)
                  displayName: "Deploy solutions"
                  env:
                    ClientSecret: $(ClientSecret)

                # 10. Upsert config data (if configData defined in build.json)
                #     - Read build.json from artifact
                #     - Run scripts/Sync-ConfigData.ps1 -Mode Upsert
                #     - Resolve data files from artifact directory

                # 11. (If Dataverse tables enabled) Update deploy status to Completed/Failed
                #     condition: and(not(canceled()), ne(variables['ExportRequestId'], ''))
                #     See patterns.md: "Release Template — Update Deploy Status (End)"
```

### Key Generation Rules

- The template needs a `checkout: self` step to access the `scripts/Sync-ConfigData.ps1` script
- The template download step alias (`ExportPipeline`) must match the pipeline resource alias in the parent pipeline
- Deployment settings file naming: `deploymentSettings_${{ parameters.stageName }}.json`
- Cloud flow activation is optional — only generate that section if feature enabled
- Config data upsert is optional — only generate if config data migration enabled
- The entire deploy loop is one PowerShell step (for variable sharing)
- (If Dataverse tables enabled) Steps 1b and 11 are generated for Dataverse status tracking
- (If Dataverse tables enabled) Step 1b reads `exportRequestId` from build.json, sets `ExportRequestId` pipeline variable, and updates the per-stage status field to In Progress. If no `exportRequestId` found, it sets the variable to empty and skips all Dataverse updates gracefully.
- (If Dataverse tables enabled) Step 11 MUST be the last step with condition `and(not(canceled()), ne(variables['ExportRequestId'], ''))`. Uses `$env:AGENT_JOBSTATUS` to determine Completed vs Failed.
- (If Dataverse tables enabled) `AdminClientSecret` is passed via `env:` block from the release pipeline's secret variable: `env: AdminClientSecret: $(AdminClientSecret)`

---

## 4. Export Solution from Pre-Dev (`export-solution-predev.yml`)

### Structure

```yaml
# Header comment block

trigger: none

parameters:
  - name: solutionName
    displayName: "Solution unique name (as it appears in Power Platform)"
    type: string

variables:
  - name: PreDevServiceConnection
    value: "{predev_service_connection}"    # e.g., "PowerPlatformPreDev"

pool:
  vmImage: "windows-latest"

steps:
  # 1. Checkout with persistCredentials (needed for push)
  - checkout: self
    persistCredentials: true
    fetchDepth: 0

  # 2. Install Power Platform Build Tools
  - task: PowerPlatformToolInstaller@2

  # 3. Create output directories
  - pwsh: |
      # Ensure solutions/{unmanaged,unpacked,managed} exist

  # 4. Export unmanaged solution
  - task: PowerPlatformExportSolution@2
    inputs:
      authenticationType: PowerPlatformSPN
      PowerPlatformSPN: $(PreDevServiceConnection)
      SolutionName: ${{ parameters.solutionName }}
      SolutionOutputFile: $(Build.SourcesDirectory)/solutions/unmanaged/${{ parameters.solutionName }}.zip
      Managed: false
      AsyncOperation: true
      MaxAsyncWaitTime: 60

  # 5. Clean unpack
  - pwsh: |
      # Delete existing unpacked folder if present
  - task: PowerPlatformUnpackSolution@2
    inputs:
      SolutionInputFile: ...
      SolutionTargetFolder: ...
      SolutionType: Unmanaged
      ProcessCanvasApps: true

  # 6. Pack as managed
  - task: PowerPlatformPackSolution@2
    inputs:
      SolutionSourceFolder: ...
      SolutionTargetFolder: ...
      SolutionType: Managed
      ProcessCanvasApps: true

  # 7. Commit and push
  - pwsh: |
      git config user.email "pipeline@dev.azure.com"
      git config user.name "Azure DevOps Pipeline"
      git add solutions/
      # Check for changes, commit, push

  # 8. Stage artifacts (managed zip + deployment settings)
  - pwsh: |
      # Copy managed zip to staging
      # Copy deploymentSettings_{first_env}.json from root if exists

  # 9. Publish artifact
  - task: PublishPipelineArtifact@1
    inputs:
      targetPath: $(Build.ArtifactStagingDirectory)
      artifact: ManagedSolution
```

### Key Generation Rules

- Uses ADO tasks (not pac CLI) for export/unpack/pack
- Commits to the current branch (typically `main`)
- Artifact name is `ManagedSolution` (singular — single solution)
- Deployment settings for the first environment only (e.g., `deploymentSettings_Dev.json`)

---

## 5. Deploy Solution (`deploy-solution.yml`)

### Structure

```yaml
# Header comment block

trigger: none

resources:
  pipelines:
    - pipeline: exportSolution
      source: "{predev_export_pipeline_name}"   # e.g., "Export Solution from Pre-Dev"
      trigger:
        branches:
          include:
            - main

parameters:
  - name: solutionName
    displayName: "Solution name (required for manual runs, ignored for auto-triggered)"
    type: string
    default: ""

pool:
  vmImage: "windows-latest"

stages:
  # First stage: inline (handles auto-trigger + manual, publishes artifact)
  - stage: {first_env_short}                   # e.g., "Dev"
    displayName: "Deploy to {first_env}"
    variables:
      - group: {first_env_var_group}           # e.g., "PowerPlatform-Dev"
    jobs:
      - deployment: Deploy
        displayName: "Deploy solution to {first_env}"
        environment: "{first_env_ado_env}"     # e.g., "Power Platform Dev"
        strategy:
          runOnce:
            deploy:
              steps:
                # 1. Checkout (for manual runs + deployment settings)
                - checkout: self

                # 2. Download artifact (auto-triggered only)
                - download: exportSolution
                  artifact: ManagedSolution
                  condition: eq(variables['Build.Reason'], 'ResourceTrigger')

                # 3. Install PP Build Tools
                - task: PowerPlatformToolInstaller@2

                # 4. Authenticate pac CLI

                # 5. Resolve solution path
                #    Auto: find zip in artifact
                #    Manual: use repo (solutions/managed/{name}.zip)

                # 6. Check for deployment settings
                #    Auto: in artifact folder
                #    Manual: in deploymentSettings/ root

                # 7. Import solution (pac solution import)

                # 8. Upsert config data (if build.json has configData)
                #    - Read build.json from artifact (auto-triggered only)
                #    - Run scripts/Sync-ConfigData.ps1 -Mode Upsert

                # 9. Stage + publish artifact for downstream stages
                #    Include build.json and configData files if auto-triggered
                - task: PublishPipelineArtifact@1
                  inputs:
                    targetPath: $(Build.ArtifactStagingDirectory)/DeploySolution
                    artifact: DeploySolution

  # Subsequent stages: use template
  - template: templates/deploy-single-solution.yml
    parameters:
      stageName: "{env_2_short}"               # e.g., "QA"
      displayName: "Deploy to {env_2}"
      environmentName: "{env_2_ado_env}"
      variableGroup: "{env_2_var_group}"
      dependsOn: "{first_env_short}"

  # ... repeat for each subsequent environment
```

### Key Generation Rules

- First stage is always inline (not from template) because it handles the dual auto/manual trigger logic
- First stage publishes `DeploySolution` artifact for downstream stages
- Downstream stages use `deploy-single-solution.yml` template
- `dependsOn` chains stages: first → second → third → fourth

---

## 6. Deploy Single Solution Template (`templates/deploy-single-solution.yml`)

### Structure

```yaml
# Header comment block

parameters:
  - name: stageName
    type: string
  - name: displayName
    type: string
  - name: environmentName
    type: string
  - name: variableGroup
    type: string
  - name: dependsOn
    type: string
    default: ""

stages:
  - stage: ${{ parameters.stageName }}
    displayName: ${{ parameters.displayName }}
    ${{ if eq(parameters.dependsOn, '') }}:
      dependsOn: []
    ${{ else }}:
      dependsOn: ${{ parameters.dependsOn }}
    variables:
      - group: ${{ parameters.variableGroup }}
    jobs:
      - deployment: Deploy
        displayName: "Deploy solution to ${{ parameters.stageName }}"
        environment: ${{ parameters.environmentName }}
        strategy:
          runOnce:
            deploy:
              steps:
                # 1. Download solution from Dev stage
                - download: current
                  artifact: DeploySolution

                # 2. Checkout for deployment settings
                - checkout: self

                # 3. Install PP Build Tools
                - task: PowerPlatformToolInstaller@2

                # 4. Authenticate pac CLI

                # 5. Import solution
                #    - Find zip in DeploySolution artifact
                #    - Check for deploymentSettings_{stageName}.json in repo root
                #    - Import with --force-overwrite --activate-plugins
                #    - Apply --settings-file if found

                # 6. Upsert config data (if build.json has configData in artifact)
                #    - Read build.json from DeploySolution artifact
                #    - Run scripts/Sync-ConfigData.ps1 -Mode Upsert
```

### Key Generation Rules

- Downloads from `current` pipeline (not external pipeline resource)
- Artifact name is `DeploySolution` (published by first stage)
- Deployment settings come from the repo (`deploymentSettings/deploymentSettings_{stage}.json`)
- Config data files come from the `DeploySolution` artifact (passed through from Dev stage)
- Simpler than deploy-environment.yml (no build.json, no multi-solution loop, no version check)

---

## README Generation Template

### Sections to Generate

1. **Title**: `# Power Platform CI/CD Pipelines`
2. **Intro**: One-line description
3. **Repository Structure**: Tree diagram of all generated files
4. **Pipeline Overview**: Table with columns: #, Pipeline, Trigger, Purpose
5. **Per-Pipeline Sections** (### numbered): Each with:
   - File path in header
   - Description paragraph
   - "What it does" numbered list
   - Stages table (if multi-stage)
   - Trigger description
   - Parameters table (if any)
   - Auth description
   - Template reference (if applicable)
   - Artifact description (if applicable)
6. **Pipeline Flow Diagrams**: ASCII art diagrams:
   - Main flow (export → release) with stage boxes
   - On-demand flow (pre-dev → deploy) with stage boxes
   - Architecture overview (both tracks side-by-side with approval gates)
7. **build.json Configuration**: Schema example (with configData if enabled), solutions field reference table, config data field reference table, version rules, caching note
8. **Deployment Settings** (if enabled): How it works, merge behavior, example, rules
9. **Configuration Data** (if enabled): How it works, stable GUIDs, data file format, execution order, OData pagination, error handling, rules
10. **Post-Export Version Management** (if enabled): How it works, patch handling, example
11. **Testing**: How to run, test suite table
12. **ADO Setup**: Step-by-step numbered sections (see SKILL.md Step 3g for full list)
13. **How to Execute**: Per-workflow step-by-step instructions
14. **Changing the Schedule** (if daily export): Cron examples table
15. **Troubleshooting**: Per-pipeline symptom/cause/fix tables (include Config Data section if enabled)

### Diagram Style

Use box-drawing characters for ASCII diagrams:

```
┌─────────┐     ┌─────────┐
│  Box 1  │────►│  Box 2  │
└─────────┘     └─────────┘
```

Show approval gates as:
```
┌─────┐  ┌─────┐  ┌─────┐
│ QA  │─►│ Stg │─►│Prod │
│auto │  │gate │  │gate │
└─────┘  └─────┘  └─────┘
```
