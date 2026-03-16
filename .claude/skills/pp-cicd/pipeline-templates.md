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

  # 4. Detect export branch (or use override)
  # Logic: convert UTC to Eastern Time, find branch matching export/{date}-*

  # 5. Read build.json from export branch

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
```

### Key Generation Rules

- Steps 8, 10-11 are conditional (only generate if respective features enabled)
- The export loop (step 6) is a single large PowerShell step
- Artifact staging copies files to `$(Build.ArtifactStagingDirectory)` before publish
- PR creation uses `az repos pr create` CLI

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

stages:
  # Generate one stage per environment using the template
  # First environment: dependsOn is empty (deploys automatically)
  # Subsequent environments: dependsOn is previous stage

  - template: templates/deploy-environment.yml
    parameters:
      stageName: "{env_1_short}"             # e.g., "Test"
      displayName: "Deploy to {env_1}"
      environmentName: "{ado_env_1}"         # e.g., "Power Platform Test"
      variableGroup: "{var_group_1}"         # e.g., "PowerPlatform-Test"
      dependsOn: ""                          # Empty = no dependency (first stage)

  - template: templates/deploy-environment.yml
    parameters:
      stageName: "{env_2_short}"             # e.g., "Stage"
      displayName: "Deploy to {env_2}"
      environmentName: "{ado_env_2}"
      variableGroup: "{var_group_2}"
      dependsOn: "{env_1_short}"             # e.g., "Test"

  # ... repeat for each environment
```

### Key Generation Rules

- The release pipeline itself contains NO deployment logic — it's all in the template
- One `template:` block per environment
- `dependsOn` chains stages sequentially
- Pipeline resource alias (`ExportPipeline`) used in the template's download steps
- The `source` value must match the exact ADO pipeline name

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
                #    - Read powerPagesConfiguration (if set, overrides import strategy)
                #    - Default managed upgrade: --stage-and-upgrade --skip-lower-version --activate-plugins
                #    - Power Pages deployMode=UPGRADE: --stage-and-upgrade --skip-lower-version
                #    - Power Pages deployMode=UPDATE: plain import (no staging flags)
                #    - Power Pages deployMode=STAGE_FOR_UPGRADE: --import-as-holding

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
```

### Key Generation Rules

- The template needs a `checkout: self` step to access the `scripts/Sync-ConfigData.ps1` script
- The template download step alias (`ExportPipeline`) must match the pipeline resource alias in the parent pipeline
- Deployment settings file naming: `deploymentSettings_${{ parameters.stageName }}.json`
- Cloud flow activation is optional — only generate that section if feature enabled
- Config data upsert is optional — only generate if config data migration enabled
- Power Pages import strategy: read `powerPagesConfiguration` per solution; `deployMode` (UPGRADE/UPDATE/STAGE_FOR_UPGRADE) overrides the default `--stage-and-upgrade` logic; has no effect when `isUnmanaged: true`
- The entire deploy loop is one PowerShell step (for variable sharing)

---

## 4. README Generation Template

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
   - Ad-hoc flow (release-adhoc → any environment) with stage boxes
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
│Test │─►│ Stg │─►│Prod │
│auto │  │gate │  │gate │
└─────┘  └─────┘  └─────┘
```
