# =============================================================================
# Local-UI.ps1 -- Power Platform Local Pipelines (GUI)
# =============================================================================
# WinForms UI for Export-Solutions.ps1 and Deploy-Solutions.ps1.
# Streams script output in near real-time and writes a log file to local/logs/.
#
# Usage: .\local\Local-UI.ps1
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Compile a pure-.NET helper for process output capture.
# PS script block event handlers don't execute while WinForms owns the thread (runspace is "busy").
# C# lambdas run directly on the threadpool with no runspace involvement.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ProcCapture {
    public static void Wire(Process proc,
                            ConcurrentQueue<string> outQ,
                            ConcurrentQueue<string> errQ) {
        proc.OutputDataReceived += (s, e) => { if (e.Data != null) outQ.Enqueue(e.Data); };
        proc.ErrorDataReceived  += (s, e) => { if (e.Data != null) errQ.Enqueue(e.Data); };
    }
}
public static class Win32 {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    public static void SetRedraw(IntPtr hWnd, bool redraw) {
        SendMessage(hWnd, 0x000B, new IntPtr(redraw ? 1 : 0), IntPtr.Zero);
    }
}
"@

$scriptDir  = $PSScriptRoot
$logsDir    = Join-Path $scriptDir "logs"
$configFile = Join-Path $scriptDir "local.config.json"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

# -----------------------------------------------------------------------------
# Shared state
# -----------------------------------------------------------------------------
$script:runProcess              = $null
$script:runningMode             = $null
$script:outputQueue             = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:errorQueue              = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:pendingDeployFile       = $null
$script:pendingDeployArgs       = $null
$script:logWriter               = $null
$script:notificationWebhookUrl  = $null
$script:configTargets           = @{}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Reload-Targets {
    $selected = if ($cmbTarget.SelectedItem) { $cmbTarget.SelectedItem.ToString() } else { "" }
    $cmbTarget.Items.Clear()
    [void]$cmbTarget.Items.Add("")   # blank = manual entry

    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            $script:configTargets = @{}
            if ($cfg.targets) {
                foreach ($t in $cfg.targets) {
                    [void]$cmbTarget.Items.Add($t.name)
                    $script:configTargets[$t.name] = $t
                }
            }
        } catch { }
    }

    if ($selected -and $cmbTarget.Items.Contains($selected)) {
        $cmbTarget.SelectedItem = $selected
    } else {
        $cmbTarget.SelectedIndex = 0
    }
}

function Read-LocalConfig {
    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($cfg.devEnvironmentUrl)         { $txtDevUrl.Text = $cfg.devEnvironmentUrl }
            if ($cfg.notificationWebhookUrl)    { $script:notificationWebhookUrl = $cfg.notificationWebhookUrl }

            # Reload targets first so we can restore the last selection
            Reload-Targets

            if ($cfg.lastTargetName -and $cmbTarget.Items.Contains($cfg.lastTargetName)) {
                $cmbTarget.SelectedItem = $cfg.lastTargetName
                # SelectedIndexChanged will fill URL + settings key
            } elseif ($cfg.lastTargetUrl) {
                $txtTargetUrl.Text  = $cfg.lastTargetUrl
                $txtSettingsKey.Text = if ($cfg.lastSettingsKey) { $cfg.lastSettingsKey } else { "" }
            }
        } catch { }
    } else {
        Reload-Targets
    }
}

function Save-LocalConfig {
    try {
        $targetName = if ($cmbTarget.SelectedItem) { $cmbTarget.SelectedItem.ToString() } else { "" }
        $cfg = [ordered]@{
            devEnvironmentUrl = $txtDevUrl.Text.Trim()
            lastTargetName    = $targetName
            lastTargetUrl     = $txtTargetUrl.Text.Trim()
            lastSettingsKey   = $txtSettingsKey.Text.Trim()
        }
        # Preserve existing targets array so we don't overwrite it
        if (Test-Path $configFile) {
            $existing = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($existing.targets)                  { $cfg["targets"]                 = $existing.targets }
            if ($existing.notificationWebhookUrl)   { $cfg["notificationWebhookUrl"]  = $existing.notificationWebhookUrl }
        }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $configFile -Encoding UTF8
    } catch { }
}

function Get-Subfolders {
    $root = Join-Path $scriptDir "exports"
    if (Test-Path $root) {
        return @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne 'sample' } |
                 Sort-Object Name -Descending | ForEach-Object { $_.Name })
    }
    return @()
}

function Get-LineColor([string]$line) {
    if ($line -match '(?i)\bERROR\b|MISSING|\bexception\b') { return [System.Drawing.Color]::Crimson            }
    if ($line -match '(?i)\bWARNING\b')                     { return [System.Drawing.Color]::DarkOrange         }
    if ($line -match '(?i)success|complete|deployed|activated|passed|skipped') {
                                                              return [System.Drawing.Color]::FromArgb(0, 140, 0) }
    if ($line -match '(?i)DRY RUN')                         { return [System.Drawing.Color]::SteelBlue          }
    if ($line -match '^[=]{3,}|^[-]{3,}')                   { return [System.Drawing.Color]::DimGray            }
    return [System.Drawing.Color]::Black
}

function Append-Log([string]$text, [System.Drawing.Color]$color) {
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $color
    $logBox.AppendText($text + "`n")
    if ($script:logWriter) { $script:logWriter.WriteLine($text) }
}

# Reads the last N lines of a file efficiently without loading the whole file
function Get-LogStatus([string]$path) {
    try {
        $lines = [System.IO.File]::ReadAllLines($path)
        for ($i = $lines.Length - 1; $i -ge [Math]::Max(0, $lines.Length - 5); $i--) {
            if ($lines[$i] -match 'exit:\s*(\w+)') { return $Matches[1] }
        }
        return "Running"
    } catch {
        return "?"
    }
}

# =============================================================================
# Form
# =============================================================================
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Power Platform Local Pipelines"
$form.Size          = New-Object System.Drawing.Size(860, 800)
$form.MinimumSize   = New-Object System.Drawing.Size(660, 640)
$form.StartPosition = "CenterScreen"
$form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)

# -----------------------------------------------------------------------------
# Mode group
# -----------------------------------------------------------------------------
$grpMode          = New-Object System.Windows.Forms.GroupBox
$grpMode.Text     = "Mode"
$grpMode.Location = New-Object System.Drawing.Point(10, 8)
$grpMode.Size     = New-Object System.Drawing.Size(822, 55)
$grpMode.Anchor   = "Top,Left,Right"

$rdoExport          = New-Object System.Windows.Forms.RadioButton
$rdoExport.Text     = "Export only"
$rdoExport.Location = New-Object System.Drawing.Point(12, 22)
$rdoExport.Size     = New-Object System.Drawing.Size(140, 22)
$rdoExport.Checked  = $true

$rdoDeploy          = New-Object System.Windows.Forms.RadioButton
$rdoDeploy.Text     = "Deploy only"
$rdoDeploy.Location = New-Object System.Drawing.Point(168, 22)
$rdoDeploy.Size     = New-Object System.Drawing.Size(140, 22)

$rdoBoth            = New-Object System.Windows.Forms.RadioButton
$rdoBoth.Text       = "Export + Deploy"
$rdoBoth.Location   = New-Object System.Drawing.Point(324, 22)
$rdoBoth.Size       = New-Object System.Drawing.Size(160, 22)

$grpMode.Controls.AddRange(@($rdoExport, $rdoDeploy, $rdoBoth))

# -----------------------------------------------------------------------------
# Configuration group
# -----------------------------------------------------------------------------
$grpConfig          = New-Object System.Windows.Forms.GroupBox
$grpConfig.Text     = "Configuration"
$grpConfig.Location = New-Object System.Drawing.Point(10, 72)
$grpConfig.Size     = New-Object System.Drawing.Size(822, 242)
$grpConfig.Anchor   = "Top,Left,Right"

$lx = 12 ; $lw = 178 ; $ix = 196

$lblDevUrl           = New-Object System.Windows.Forms.Label
$lblDevUrl.Text      = "Dev Environment URL:"
$lblDevUrl.Location  = New-Object System.Drawing.Point($lx, 26)
$lblDevUrl.Size      = New-Object System.Drawing.Size($lw, 22)
$lblDevUrl.TextAlign = "MiddleRight"

$txtDevUrl           = New-Object System.Windows.Forms.TextBox
$txtDevUrl.Location  = New-Object System.Drawing.Point($ix, 24)
$txtDevUrl.Size      = New-Object System.Drawing.Size(608, 22)
$txtDevUrl.Anchor    = "Top,Left,Right"

$lblTarget           = New-Object System.Windows.Forms.Label
$lblTarget.Text      = "Target:"
$lblTarget.Location  = New-Object System.Drawing.Point($lx, 60)
$lblTarget.Size      = New-Object System.Drawing.Size($lw, 22)
$lblTarget.TextAlign = "MiddleRight"

$cmbTarget               = New-Object System.Windows.Forms.ComboBox
$cmbTarget.Location      = New-Object System.Drawing.Point($ix, 58)
$cmbTarget.Size          = New-Object System.Drawing.Size(570, 22)
$cmbTarget.Anchor        = "Top,Left,Right"
$cmbTarget.DropDownStyle = "DropDownList"

$btnRefreshTargets           = New-Object System.Windows.Forms.Button
$btnRefreshTargets.Text      = "Reload"
$btnRefreshTargets.Location  = New-Object System.Drawing.Point(774, 57)
$btnRefreshTargets.Size      = New-Object System.Drawing.Size(32, 25)
$btnRefreshTargets.Anchor    = "Top,Right"
$btnRefreshTargets.FlatStyle = "Flat"
$btnRefreshTargets.Font      = New-Object System.Drawing.Font("Segoe UI", 7)

$lblTargetUrl           = New-Object System.Windows.Forms.Label
$lblTargetUrl.Text      = "Target Environment URL:"
$lblTargetUrl.Location  = New-Object System.Drawing.Point($lx, 94)
$lblTargetUrl.Size      = New-Object System.Drawing.Size($lw, 22)
$lblTargetUrl.TextAlign = "MiddleRight"

$txtTargetUrl          = New-Object System.Windows.Forms.TextBox
$txtTargetUrl.Location = New-Object System.Drawing.Point($ix, 92)
$txtTargetUrl.Size     = New-Object System.Drawing.Size(608, 22)
$txtTargetUrl.Anchor   = "Top,Left,Right"

$lblSettingsKey           = New-Object System.Windows.Forms.Label
$lblSettingsKey.Text      = "Settings Key:"
$lblSettingsKey.Location  = New-Object System.Drawing.Point($lx, 126)
$lblSettingsKey.Size      = New-Object System.Drawing.Size($lw, 22)
$lblSettingsKey.TextAlign = "MiddleRight"

$txtSettingsKey          = New-Object System.Windows.Forms.TextBox
$txtSettingsKey.Location = New-Object System.Drawing.Point($ix, 124)
$txtSettingsKey.Size     = New-Object System.Drawing.Size(120, 22)
$txtSettingsKey.Text     = ""

$lblSubfolder           = New-Object System.Windows.Forms.Label
$lblSubfolder.Text      = "Export Subfolder:"
$lblSubfolder.Location  = New-Object System.Drawing.Point($lx, 160)
$lblSubfolder.Size      = New-Object System.Drawing.Size($lw, 22)
$lblSubfolder.TextAlign = "MiddleRight"

$cmbSubfolder               = New-Object System.Windows.Forms.ComboBox
$cmbSubfolder.Location      = New-Object System.Drawing.Point($ix, 158)
$cmbSubfolder.Size          = New-Object System.Drawing.Size(570, 22)
$cmbSubfolder.Anchor        = "Top,Left,Right"
$cmbSubfolder.DropDownStyle = "DropDownList"

$btnRefresh           = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = "Refresh"
$btnRefresh.Location  = New-Object System.Drawing.Point(774, 157)
$btnRefresh.Size      = New-Object System.Drawing.Size(32, 25)
$btnRefresh.Anchor    = "Top,Right"
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.Font      = New-Object System.Drawing.Font("Segoe UI", 7)

$chkDryRun          = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text     = "Dry Run - validate without deploying"
$chkDryRun.Location = New-Object System.Drawing.Point($ix, 196)
$chkDryRun.Size     = New-Object System.Drawing.Size(290, 22)

$chkTeamsNotify          = New-Object System.Windows.Forms.CheckBox
$chkTeamsNotify.Text     = "Send Teams Notifications"
$chkTeamsNotify.Location = New-Object System.Drawing.Point(500, 196)
$chkTeamsNotify.Size     = New-Object System.Drawing.Size(210, 22)
$chkTeamsNotify.Checked  = $true

$grpConfig.Controls.AddRange(@(
    $lblDevUrl, $txtDevUrl,
    $lblTarget, $cmbTarget, $btnRefreshTargets,
    $lblTargetUrl, $txtTargetUrl,
    $lblSettingsKey, $txtSettingsKey,
    $lblSubfolder, $cmbSubfolder, $btnRefresh,
    $chkDryRun, $chkTeamsNotify
))

# -----------------------------------------------------------------------------
# Actions panel
# -----------------------------------------------------------------------------
$pnlActions          = New-Object System.Windows.Forms.Panel
$pnlActions.Location = New-Object System.Drawing.Point(10, 322)
$pnlActions.Size     = New-Object System.Drawing.Size(822, 46)
$pnlActions.Anchor   = "Top,Left,Right"

$btnRun                           = New-Object System.Windows.Forms.Button
$btnRun.Text                      = "Run"
$btnRun.Location                  = New-Object System.Drawing.Point(0, 7)
$btnRun.Size                      = New-Object System.Drawing.Size(88, 30)
$btnRun.BackColor                 = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnRun.ForeColor                 = [System.Drawing.Color]::White
$btnRun.FlatStyle                 = "Flat"
$btnRun.FlatAppearance.BorderSize = 0

$btnStop           = New-Object System.Windows.Forms.Button
$btnStop.Text      = "Stop"
$btnStop.Location  = New-Object System.Drawing.Point(93, 7)
$btnStop.Size      = New-Object System.Drawing.Size(88, 30)
$btnStop.Enabled   = $false
$btnStop.FlatStyle = "Flat"

$btnClear           = New-Object System.Windows.Forms.Button
$btnClear.Text      = "Clear"
$btnClear.Location  = New-Object System.Drawing.Point(186, 7)
$btnClear.Size      = New-Object System.Drawing.Size(65, 30)
$btnClear.FlatStyle = "Flat"

$progress                       = New-Object System.Windows.Forms.ProgressBar
$progress.Location              = New-Object System.Drawing.Point(264, 12)
$progress.Size                  = New-Object System.Drawing.Size(555, 20)
$progress.Anchor                = "Top,Left,Right"
$progress.Style                 = "Marquee"
$progress.MarqueeAnimationSpeed = 25
$progress.Visible               = $false

$pnlActions.Controls.AddRange(@($btnRun, $btnStop, $btnClear, $progress))

# -----------------------------------------------------------------------------
# Tab control (Output + History)
# -----------------------------------------------------------------------------
$tabControl          = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 376)
$tabControl.Size     = New-Object System.Drawing.Size(822, 416)
$tabControl.Anchor   = "Top,Left,Right,Bottom"

# ---- Output tab ----
$tabOutput      = New-Object System.Windows.Forms.TabPage
$tabOutput.Text = "Output"
$tabOutput.Padding = New-Object System.Windows.Forms.Padding(0)

$logBox            = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock       = "Fill"
$logBox.ReadOnly   = $true
$logBox.BackColor  = [System.Drawing.Color]::FromArgb(252, 252, 252)
$logBox.ScrollBars = "Both"
$logBox.WordWrap   = $false

$installedFamilies = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
foreach ($fontName in @("Cascadia Mono", "Consolas", "Courier New")) {
    if ($installedFamilies -contains $fontName) {
        $logBox.Font = New-Object System.Drawing.Font($fontName, 9)
        break
    }
}

$tabOutput.Controls.Add($logBox)

# ---- History tab ----
$tabHistory      = New-Object System.Windows.Forms.TabPage
$tabHistory.Text = "History"

# Toolbar panel inside history tab
$pnlHistoryBar          = New-Object System.Windows.Forms.Panel
$pnlHistoryBar.Dock     = "Top"
$pnlHistoryBar.Height   = 36
$pnlHistoryBar.Padding  = New-Object System.Windows.Forms.Padding(4, 4, 4, 0)

$btnHistoryRefresh           = New-Object System.Windows.Forms.Button
$btnHistoryRefresh.Text      = "Refresh"
$btnHistoryRefresh.Location  = New-Object System.Drawing.Point(4, 4)
$btnHistoryRefresh.Size      = New-Object System.Drawing.Size(72, 26)
$btnHistoryRefresh.FlatStyle = "Flat"

$btnOpenExternal           = New-Object System.Windows.Forms.Button
$btnOpenExternal.Text      = "Open in Notepad"
$btnOpenExternal.Location  = New-Object System.Drawing.Point(81, 4)
$btnOpenExternal.Size      = New-Object System.Drawing.Size(110, 26)
$btnOpenExternal.FlatStyle = "Flat"
$btnOpenExternal.Enabled   = $false

$btnDeleteLog           = New-Object System.Windows.Forms.Button
$btnDeleteLog.Text      = "Delete"
$btnDeleteLog.Location  = New-Object System.Drawing.Point(196, 4)
$btnDeleteLog.Size      = New-Object System.Drawing.Size(65, 26)
$btnDeleteLog.FlatStyle = "Flat"
$btnDeleteLog.Enabled   = $false

$pnlHistoryBar.Controls.AddRange(@($btnHistoryRefresh, $btnOpenExternal, $btnDeleteLog))

# ListView
$lstHistory                   = New-Object System.Windows.Forms.ListView
$lstHistory.Dock               = "Top"
$lstHistory.Height             = 160
$lstHistory.View               = "Details"
$lstHistory.FullRowSelect      = $true
$lstHistory.GridLines          = $true
$lstHistory.MultiSelect        = $false
$lstHistory.HideSelection      = $false

[void]$lstHistory.Columns.Add("Date / Time",  145)
[void]$lstHistory.Columns.Add("Mode",          90)
[void]$lstHistory.Columns.Add("Subfolder",     280)
[void]$lstHistory.Columns.Add("Status",         80)

# Splitter
$splitterHistory        = New-Object System.Windows.Forms.Splitter
$splitterHistory.Dock   = "Top"
$splitterHistory.Height = 4

# Log viewer inside history tab
$txtHistoryView            = New-Object System.Windows.Forms.RichTextBox
$txtHistoryView.Dock       = "Fill"
$txtHistoryView.ReadOnly   = $true
$txtHistoryView.BackColor  = [System.Drawing.Color]::FromArgb(252, 252, 252)
$txtHistoryView.ScrollBars = "Both"
$txtHistoryView.WordWrap   = $false
foreach ($fontName in @("Cascadia Mono", "Consolas", "Courier New")) {
    if ($installedFamilies -contains $fontName) {
        $txtHistoryView.Font = New-Object System.Drawing.Font($fontName, 9)
        break
    }
}

$tabHistory.Controls.Add($txtHistoryView)
$tabHistory.Controls.Add($splitterHistory)
$tabHistory.Controls.Add($lstHistory)
$tabHistory.Controls.Add($pnlHistoryBar)

# ---- build.json tab ----
$tabBuildJson      = New-Object System.Windows.Forms.TabPage
$tabBuildJson.Text = "build.json"

$txtBuildJson            = New-Object System.Windows.Forms.RichTextBox
$txtBuildJson.Dock       = "Fill"
$txtBuildJson.ReadOnly   = $true
$txtBuildJson.BackColor  = [System.Drawing.Color]::FromArgb(252, 252, 252)
$txtBuildJson.ScrollBars = "Both"
$txtBuildJson.WordWrap   = $false
foreach ($fontName in @("Cascadia Mono", "Consolas", "Courier New")) {
    if ($installedFamilies -contains $fontName) {
        $txtBuildJson.Font = New-Object System.Drawing.Font($fontName, 9)
        break
    }
}

$tabBuildJson.Controls.Add($txtBuildJson)

$tabControl.TabPages.AddRange(@($tabOutput, $tabHistory, $tabBuildJson))

$form.Controls.AddRange(@($grpMode, $grpConfig, $pnlActions, $tabControl))

# =============================================================================
# Poll timer
# =============================================================================
$pollTimer          = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 80

$pollTimer.add_Tick({
    $line    = $null
    $hasNew  = $false

    [Win32]::SetRedraw($logBox.Handle, $false)
    try {
        while ($script:outputQueue.TryDequeue([ref]$line)) {
            Append-Log $line (Get-LineColor $line)
            $hasNew = $true
        }
        while ($script:errorQueue.TryDequeue([ref]$line)) {
            Append-Log $line ([System.Drawing.Color]::Crimson)
            $hasNew = $true
        }
    } finally {
        [Win32]::SetRedraw($logBox.Handle, $true)
    }
    if ($hasNew) {
        $logBox.Invalidate()
        $logBox.ScrollToCaret()
    }

    # Check for process exit on the UI thread (avoids threading issues with PS5.1 event handlers)
    if ($script:runProcess -ne $null -and $script:runProcess.HasExited) {
        $code              = $script:runProcess.ExitCode
        $script:runProcess = $null   # clear before any branching so we don't re-enter

        # Final drain — async reads may have queued a few last lines
        [Win32]::SetRedraw($logBox.Handle, $false)
        try {
            while ($script:outputQueue.TryDequeue([ref]$line)) {
                Append-Log $line (Get-LineColor $line)
            }
            while ($script:errorQueue.TryDequeue([ref]$line)) {
                Append-Log $line ([System.Drawing.Color]::Crimson)
            }
        } finally {
            [Win32]::SetRedraw($logBox.Handle, $true)
        }
        $logBox.Invalidate()
        $logBox.ScrollToCaret()

        if ($script:runningMode -eq "both-export") {
            if ($code -eq 0) {
                Append-Log "" ([System.Drawing.Color]::Black)
                Append-Log "=== Export complete - starting Deploy phase ===" ([System.Drawing.Color]::SteelBlue)
                Append-Log "" ([System.Drawing.Color]::Black)
                $script:runningMode = "both-deploy"
                $script:runProcess  = Invoke-ScriptProcess $script:pendingDeployFile $script:pendingDeployArgs
            } else {
                Append-Log "" ([System.Drawing.Color]::Black)
                Append-Log "Export failed (exit $code) - deploy phase skipped." ([System.Drawing.Color]::Crimson)
                Complete-Run -Failed
            }
        } else {
            if ($code -eq 0) { Complete-Run } else { Complete-Run -Failed }
        }
    }
})

$pollTimer.Start()

# =============================================================================
# Functions
# =============================================================================
function Update-Visibility {
    $isExport = $rdoExport.Checked
    $isDeploy = $rdoDeploy.Checked
    $isBoth   = $rdoBoth.Checked

    $lblDevUrl.Visible           = $isExport -or $isBoth
    $txtDevUrl.Visible           = $isExport -or $isBoth
    $lblTarget.Visible           = $isDeploy -or $isBoth
    $cmbTarget.Visible           = $isDeploy -or $isBoth
    $btnRefreshTargets.Visible   = $isDeploy -or $isBoth
    $lblTargetUrl.Visible        = $isDeploy -or $isBoth
    $txtTargetUrl.Visible        = $isDeploy -or $isBoth
    $lblSettingsKey.Visible      = $isDeploy -or $isBoth
    $txtSettingsKey.Visible      = $isDeploy -or $isBoth
    $chkDryRun.Visible           = $isDeploy -or $isBoth
}

function Refresh-Subfolders {
    $current = $cmbSubfolder.SelectedItem
    $cmbSubfolder.Items.Clear()
    foreach ($f in (Get-Subfolders)) { [void]$cmbSubfolder.Items.Add($f) }
    if ($current -and $cmbSubfolder.Items.Contains($current)) {
        $cmbSubfolder.SelectedItem = $current
    }
    # No default selection — user must choose explicitly
}

function Load-BuildJson {
    $txtBuildJson.Clear()
    $subfolder = $cmbSubfolder.SelectedItem
    if (-not $subfolder) { return }

    $buildPath = Join-Path $scriptDir "exports\$subfolder\build.json"
    if (-not (Test-Path $buildPath)) {
        $txtBuildJson.ForeColor = [System.Drawing.Color]::DimGray
        $txtBuildJson.Text = "(no build.json found at exports\$subfolder\build.json)"
        return
    }

    try {
        $raw = Get-Content $buildPath -Raw -Encoding UTF8
        # Re-format for consistent indentation
        $pretty = $raw | ConvertFrom-Json | ConvertTo-Json -Depth 20

        # Simple JSON syntax coloring: tokenize line by line
        $colorKey     = [System.Drawing.Color]::FromArgb(0, 100, 180)   # blue  - keys
        $colorString  = [System.Drawing.Color]::FromArgb(160, 60,  0)   # brown - string values
        $colorNumber  = [System.Drawing.Color]::FromArgb(9,  134,  88)  # green - numbers/booleans
        $colorDefault = [System.Drawing.Color]::FromArgb(50,  50,  50)  # dark gray - punctuation

        foreach ($line in ($pretty -split "`r?`n")) {
            # Key: "someKey":
            if ($line -match '^(\s*)("[\w\s]+")\s*:(.*)$') {
                $indent  = $Matches[1]
                $key     = $Matches[2] + ":"
                $rest    = $Matches[3]

                $txtBuildJson.SelectionStart  = $txtBuildJson.TextLength
                $txtBuildJson.SelectionColor  = $colorDefault
                $txtBuildJson.AppendText($indent)

                $txtBuildJson.SelectionStart  = $txtBuildJson.TextLength
                $txtBuildJson.SelectionColor  = $colorKey
                $txtBuildJson.AppendText($key)

                # Value portion
                $restTrim = $rest.Trim()
                if ($restTrim -match '^"') {
                    $txtBuildJson.SelectionStart = $txtBuildJson.TextLength
                    $txtBuildJson.SelectionColor = $colorString
                    $txtBuildJson.AppendText($rest)
                } elseif ($restTrim -match '^[\d\-]|^true|^false|^null') {
                    $txtBuildJson.SelectionStart = $txtBuildJson.TextLength
                    $txtBuildJson.SelectionColor = $colorNumber
                    $txtBuildJson.AppendText($rest)
                } else {
                    $txtBuildJson.SelectionStart = $txtBuildJson.TextLength
                    $txtBuildJson.SelectionColor = $colorDefault
                    $txtBuildJson.AppendText($rest)
                }
                $txtBuildJson.AppendText("`n")
            } else {
                # Value-only lines (array items, closing braces)
                $trimmed = $line.Trim()
                if ($trimmed -match '^"') {
                    $txtBuildJson.SelectionStart = $txtBuildJson.TextLength
                    $txtBuildJson.SelectionColor = $colorString
                } elseif ($trimmed -match '^[\d\-]|^true|^false|^null') {
                    $txtBuildJson.SelectionStart = $txtBuildJson.TextLength
                    $txtBuildJson.SelectionColor = $colorNumber
                } else {
                    $txtBuildJson.SelectionStart = $txtBuildJson.TextLength
                    $txtBuildJson.SelectionColor = $colorDefault
                }
                $txtBuildJson.AppendText($line + "`n")
            }
        }
        $txtBuildJson.SelectionStart = 0
        $txtBuildJson.ScrollToCaret()
    } catch {
        $txtBuildJson.ForeColor = [System.Drawing.Color]::Crimson
        $txtBuildJson.Text = "Error reading build.json: $_"
    }
}

function Load-History {
    $lstHistory.Items.Clear()
    $txtHistoryView.Clear()
    $btnOpenExternal.Enabled = $false
    $btnDeleteLog.Enabled    = $false

    $logFiles = Get-ChildItem -Path $logsDir -Filter "*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending

    foreach ($f in $logFiles) {
        # Filename: yyyy-MM-dd_HH-mm-ss_mode_subfolder.log
        $parsed   = $f.BaseName -match '^(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})_([^_]+)_(.+)$'
        if ($parsed) {
            $dateStr   = $Matches[1]
            $timeStr   = $Matches[2] -replace '-', ':'
            $modeStr   = $Matches[3]
            $subStr    = $Matches[4]
        } else {
            $dateStr   = $f.LastWriteTime.ToString("yyyy-MM-dd")
            $timeStr   = $f.LastWriteTime.ToString("HH:mm:ss")
            $modeStr   = "-"
            $subStr    = $f.BaseName
        }

        $status    = Get-LogStatus $f.FullName
        $item      = New-Object System.Windows.Forms.ListViewItem("$dateStr  $timeStr")
        [void]$item.SubItems.Add($modeStr)
        [void]$item.SubItems.Add($subStr)
        [void]$item.SubItems.Add($status)
        $item.Tag  = $f.FullName

        if ($status -eq "FAILED") {
            $item.ForeColor = [System.Drawing.Color]::Crimson
        } elseif ($status -eq "OK") {
            $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 0)
        } else {
            $item.ForeColor = [System.Drawing.Color]::DarkOrange
        }

        [void]$lstHistory.Items.Add($item)
    }
}

function View-SelectedLog {
    if ($lstHistory.SelectedItems.Count -eq 0) { return }
    $path = $lstHistory.SelectedItems[0].Tag

    $txtHistoryView.Clear()
    try {
        $lines = [System.IO.File]::ReadAllLines($path)
        foreach ($line in $lines) {
            $txtHistoryView.SelectionStart  = $txtHistoryView.TextLength
            $txtHistoryView.SelectionLength = 0
            $txtHistoryView.SelectionColor  = Get-LineColor $line
            $txtHistoryView.AppendText($line + "`n")
        }
        $txtHistoryView.SelectionStart = 0
        $txtHistoryView.ScrollToCaret()
    } catch {
        $txtHistoryView.Text = "Could not read log file: $_"
    }
}

function Invoke-ScriptProcess([string]$scriptFile, [string[]]$scriptArgs) {
    $psExe = if ($PSVersionTable.PSVersion.Major -ge 6) {
        Join-Path $PSHOME "pwsh.exe"
    } else {
        Join-Path $PSHOME "powershell.exe"
    }

    $argStr = "-ExecutionPolicy Bypass -File `"$scriptFile`" " + ($scriptArgs -join " ")

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $psExe
    $psi.Arguments              = $argStr
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc                     = New-Object System.Diagnostics.Process
    $proc.StartInfo           = $psi
    $proc.EnableRaisingEvents = $true

    # Use compiled C# lambdas — PS script block event handlers don't fire while
    # WinForms owns the main thread (runspace is busy).
    [ProcCapture]::Wire($proc, $script:outputQueue, $script:errorQueue)

    $proc.Start()            | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    return $proc
}

function Send-TeamsNotification([object]$card) {
    $url = $script:notificationWebhookUrl
    if (-not $url) { return $false }
    try {
        $payload = [ordered]@{
            type        = "message"
            attachments = @([ordered]@{
                contentType = "application/vnd.microsoft.card.adaptive"
                contentUrl  = $null
                content     = $card
            })
        } | ConvertTo-Json -Depth 20
        $payload = [System.Text.RegularExpressions.Regex]::Replace($payload, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value[0] })
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json; charset=utf-8" -Body $bodyBytes -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $errMsg = $null
        try { $errMsg = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
        if (-not $errMsg) { $errMsg = $_.Exception.Message }
        Append-Log "Teams error: $errMsg" ([System.Drawing.Color]::OrangeRed)
        return $false
    }
}

function Invoke-Run {  # starts the actual subprocess(es) after any countdown delay
    param(
        [string]$exportScript, [string]$deployScript,
        [string]$subfolder,    [string]$devUrl,
        [string]$targetUrl,    [string]$key,
        [bool]$dryRun,         [bool]$skipTeams
    )
    if ($rdoExport.Checked) {
        $script:runningMode = "export"
        $exportArgs = @("-EnvironmentUrl", $devUrl, "-Subfolder", $subfolder, "-SkipPrompts")
        if ($skipTeams) { $exportArgs += "-SkipTeamsNotifications" }
        $script:runProcess  = Invoke-ScriptProcess $exportScript $exportArgs
    } elseif ($rdoDeploy.Checked) {
        $script:runningMode = "deploy"
        $deployArgs = @("-EnvironmentUrl", $targetUrl, "-Subfolder", $subfolder, "-SettingsKey", $key, "-SkipPrompts")
        if ($dryRun)     { $deployArgs += "-DryRun" }
        if ($skipTeams)  { $deployArgs += "-SkipTeamsNotifications" }
        $script:runProcess  = Invoke-ScriptProcess $deployScript $deployArgs
    } else {
        $script:runningMode       = "both-export"
        $script:pendingDeployFile = $deployScript
        $script:pendingDeployArgs = @("-EnvironmentUrl", $targetUrl, "-Subfolder", $subfolder, "-SettingsKey", $key, "-SkipPrompts")
        if ($dryRun)    { $script:pendingDeployArgs += "-DryRun" }
        if ($skipTeams) { $script:pendingDeployArgs += "-SkipTeamsNotifications" }
        Append-Log "--- Export phase ---" ([System.Drawing.Color]::DimGray)
        Append-Log "" ([System.Drawing.Color]::Black)
        $exportArgs = @("-EnvironmentUrl", $devUrl, "-Subfolder", $subfolder, "-SkipPrompts")
        if ($skipTeams) { $exportArgs += "-SkipTeamsNotifications" }
        $script:runProcess  = Invoke-ScriptProcess $exportScript $exportArgs
    }
}

function Start-Run {
    $subfolder = $cmbSubfolder.SelectedItem
    if (-not $subfolder) {
        [System.Windows.Forms.MessageBox]::Show("Please select an export subfolder.", "Missing Input",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if (($rdoExport.Checked -or $rdoBoth.Checked) -and -not $txtDevUrl.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("Dev Environment URL is required for export.", "Missing Input",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if (($rdoDeploy.Checked -or $rdoBoth.Checked) -and -not $txtTargetUrl.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("Target Environment URL is required for deploy.", "Missing Input",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Save-LocalConfig

    $modeLabel = if ($rdoExport.Checked) { "export" } elseif ($rdoDeploy.Checked) { "deploy" } else { "export-deploy" }
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logFile   = Join-Path $logsDir "${timestamp}_${modeLabel}_${subfolder}.log"
    $script:logWriter = [System.IO.StreamWriter]::new($logFile, $false, [System.Text.Encoding]::UTF8)
    $script:logWriter.AutoFlush = $true

    $logBox.Clear()
    $tabControl.SelectedTab = $tabOutput
    $btnRun.Enabled         = $false
    $btnStop.Enabled        = $true
    $grpMode.Enabled        = $false
    $grpConfig.Enabled      = $false
    $progress.Visible       = $true

    $exportScript = Join-Path $scriptDir "Export-Solutions.ps1"
    $deployScript = Join-Path $scriptDir "Deploy-Solutions.ps1"
    $devUrl       = $txtDevUrl.Text.Trim()
    $targetUrl    = $txtTargetUrl.Text.Trim()
    $key          = if ($txtSettingsKey.Text.Trim()) { $txtSettingsKey.Text.Trim() } else { "Test" }
    $dryRun       = $chkDryRun.Checked
    $skipTeams    = -not $chkTeamsNotify.Checked

    # Write the mode header now so it's visible during any countdown
    if ($rdoExport.Checked) {
        Append-Log "=== Export - $subfolder ===" ([System.Drawing.Color]::SteelBlue)
    } elseif ($rdoDeploy.Checked) {
        Append-Log "=== Deploy - $subfolder -> $targetUrl ===" ([System.Drawing.Color]::SteelBlue)
    } else {
        Append-Log "=== Export + Deploy - $subfolder ===" ([System.Drawing.Color]::SteelBlue)
    }
    Append-Log "Log file: $logFile" ([System.Drawing.Color]::DimGray)
    Append-Log "" ([System.Drawing.Color]::Black)

    Invoke-Run $exportScript $deployScript $subfolder $devUrl $targetUrl $key $dryRun $skipTeams
}

function Complete-Run {
    param([switch]$Failed)

    if ($script:logWriter) {
        $script:logWriter.WriteLine("")
        $status = if ($Failed) { "FAILED" } else { "OK" }
        $script:logWriter.WriteLine("Run completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - exit: $status")
        $script:logWriter.Close()
        $script:logWriter = $null
    }

    $script:runProcess        = $null
    $script:runningMode       = $null
    $script:pendingDeployFile = $null
    $script:pendingDeployArgs = $null

    $btnRun.Enabled    = $true
    $btnStop.Enabled   = $false
    $grpMode.Enabled   = $true
    $grpConfig.Enabled = $true
    $progress.Visible  = $false

    Append-Log "" ([System.Drawing.Color]::Black)
    if ($Failed) {
        Append-Log "Finished with errors." ([System.Drawing.Color]::Crimson)
    } else {
        Append-Log "Done." ([System.Drawing.Color]::FromArgb(0, 140, 0))
    }
    $logBox.ScrollToCaret()

    # Refresh history list in the background so it's ready when the user switches tabs
    Load-History
}

# =============================================================================
# Event wiring
# =============================================================================
$rdoExport.add_CheckedChanged({ Update-Visibility })
$rdoDeploy.add_CheckedChanged({ Update-Visibility })
$rdoBoth.add_CheckedChanged({ Update-Visibility })

$cmbTarget.add_SelectedIndexChanged({
    $name = if ($cmbTarget.SelectedItem) { $cmbTarget.SelectedItem.ToString() } else { "" }
    if ($name -and $script:configTargets -and $script:configTargets.ContainsKey($name)) {
        $t = $script:configTargets[$name]
        $txtTargetUrl.Text   = if ($t.url)         { $t.url }         else { "" }
        $txtSettingsKey.Text = if ($t.settingsKey)  { $t.settingsKey }  else { "" }
    }
})

$btnRefreshTargets.add_Click({ Reload-Targets })
$cmbSubfolder.add_SelectedIndexChanged({ Load-BuildJson })
$btnRefresh.add_Click({ Refresh-Subfolders })
$btnRun.add_Click({ Start-Run })
$btnClear.add_Click({ $logBox.Clear() })

$btnStop.add_Click({
    if ($script:runProcess -and -not $script:runProcess.HasExited) {
        try {
            $procId = $script:runProcess.Id
            $script:runProcess.Kill()
            Get-CimInstance Win32_Process -Filter "ParentProcessId = $procId" -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    $script:processExited = $false
    $script:runningMode   = $null
    Append-Log "" ([System.Drawing.Color]::Black)
    Append-Log "Stopped by user." ([System.Drawing.Color]::DarkOrange)
    Complete-Run -Failed
})

# History tab events
$tabControl.add_SelectedIndexChanged({
    if ($tabControl.SelectedTab -eq $tabHistory) { Load-History }
})

$lstHistory.add_SelectedIndexChanged({
    $hasSelection = $lstHistory.SelectedItems.Count -gt 0
    $btnOpenExternal.Enabled = $hasSelection
    $btnDeleteLog.Enabled    = $hasSelection
    if ($hasSelection) { View-SelectedLog }
})

$btnHistoryRefresh.add_Click({ Load-History })

$btnOpenExternal.add_Click({
    if ($lstHistory.SelectedItems.Count -gt 0) {
        $path = $lstHistory.SelectedItems[0].Tag
        Start-Process notepad.exe -ArgumentList "`"$path`""
    }
})

$btnDeleteLog.add_Click({
    if ($lstHistory.SelectedItems.Count -eq 0) { return }
    $item = $lstHistory.SelectedItems[0]
    $path = $item.Tag
    $name = [System.IO.Path]::GetFileName($path)
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Delete log file?`n`n$name", "Confirm Delete",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($result -eq "Yes") {
        try {
            Remove-Item $path -Force
            $lstHistory.Items.Remove($item)
            $txtHistoryView.Clear()
            $btnOpenExternal.Enabled = $false
            $btnDeleteLog.Enabled    = $false
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not delete file: $_", "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
})

$form.add_FormClosing({
    param($s, $e)
    if ($script:runProcess -and -not $script:runProcess.HasExited) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "A script is currently running. Stop it and close?", "Confirm Close",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($result -eq "Yes") {
            try { $script:runProcess.Kill() } catch { }
            if ($script:logWriter) { $script:logWriter.Close(); $script:logWriter = $null }
        } else {
            $e.Cancel = $true
        }
    }
})

# =============================================================================
# Init and show
# =============================================================================
Update-Visibility
Refresh-Subfolders
Read-LocalConfig
Load-BuildJson
[void]$form.ShowDialog()
$pollTimer.Stop()
