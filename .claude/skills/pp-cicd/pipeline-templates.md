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

  # 8. Publish artifact: ManagedSolutions
  #    Contents: build.json, {name}_{version}.zip files, deploymentSettings_*.json
  - task: PublishPipelineArtifact@1
    inputs:
      targetPath: $(Build.ArtifactStagingDirectory)
      artifact: ManagedSolutions

  # 9. Post-export version management (if postExportVersion set)
  #    - Non-patches: pac solution online-version
  #    - Patches: rename old + CloneAsPatch

  # 10. Merge deployment settings (if deploymentSettings_*.json exist)
  #     - Run scripts/Merge-DeploymentSettings.ps1

  # 11. Commit and push to export branch

  # 12. Create PR to main (auto-complete, squash merge)
```

### Key Generation Rules

- Steps 9-10 are conditional (only generate if features enabled)
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
      stageName: "{env_1_short}"             # e.g., "QA"
      displayName: "Deploy to {env_1}"
      environmentName: "{ado_env_1}"         # e.g., "Power Platform QA"
      variableGroup: "{var_group_1}"         # e.g., "PowerPlatform-QA"
      dependsOn: ""                          # Empty = no dependency (first stage)

  - template: templates/deploy-environment.yml
    parameters:
      stageName: "{env_2_short}"             # e.g., "Stage"
      displayName: "Deploy to {env_2}"
      environmentName: "{ado_env_2}"
      variableGroup: "{var_group_2}"
      dependsOn: "{env_1_short}"             # e.g., "QA"

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
```

### Key Generation Rules

- The template download step alias (`ExportPipeline`) must match the pipeline resource alias in the parent pipeline
- Deployment settings file naming: `deploymentSettings_${{ parameters.stageName }}.json`
- Cloud flow activation is optional — only generate that section if feature enabled
- The entire deploy loop is one PowerShell step (for variable sharing)

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

                # 8. Stage + publish artifact for downstream stages
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
```

### Key Generation Rules

- Downloads from `current` pipeline (not external pipeline resource)
- Artifact name is `DeploySolution` (published by first stage)
- Deployment settings come from the repo (`deploymentSettings/deploymentSettings_{stage}.json`)
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
7. **build.json Configuration**: Schema example, field reference table, version rules, caching note
8. **Deployment Settings** (if enabled): How it works, merge behavior, example, rules
9. **Post-Export Version Management** (if enabled): How it works, patch handling, example
10. **Testing**: How to run, test suite table
11. **ADO Setup**: Step-by-step numbered sections (see SKILL.md Step 3g for full list)
12. **How to Execute**: Per-workflow step-by-step instructions
13. **Changing the Schedule** (if daily export): Cron examples table
14. **Troubleshooting**: Per-pipeline symptom/cause/fix tables

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
