# =============================================================================
# Local-UI.ps1 -- Power Platform Local Runner (GUI)
# =============================================================================
# WinForms UI for Export-Solutions.ps1 and Deploy-Solutions.ps1.
# Streams script output in near real-time and writes a log file to local/logs/.
#
# Usage: .\local\Local-UI.ps1
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptDir  = $PSScriptRoot
$logsDir    = Join-Path $scriptDir "logs"
$configFile = Join-Path $scriptDir "local.config.json"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

# -----------------------------------------------------------------------------
# Shared state
# -----------------------------------------------------------------------------
$script:runProcess         = $null
$script:runningMode        = $null
$script:outputQueue        = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:errorQueue         = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:processExited      = $false
$script:exitCode           = 0
$script:pendingDeployFile  = $null
$script:pendingDeployArgs  = $null
$script:logWriter          = $null

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Read-LocalConfig {
    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($cfg.devEnvironmentUrl) { $txtDevUrl.Text = $cfg.devEnvironmentUrl }
        } catch { }
    }
}

function Save-LocalConfig {
    try {
        $cfg = [ordered]@{ devEnvironmentUrl = $txtDevUrl.Text.Trim() }
        $cfg | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
    } catch { }
}

function Get-Subfolders {
    $root = Join-Path $scriptDir "exports"
    if (Test-Path $root) {
        return @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name | ForEach-Object { $_.Name })
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
$form.Text          = "Power Platform Local Runner"
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
$grpConfig.Size     = New-Object System.Drawing.Size(822, 208)
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

$lblTargetUrl           = New-Object System.Windows.Forms.Label
$lblTargetUrl.Text      = "Target Environment URL:"
$lblTargetUrl.Location  = New-Object System.Drawing.Point($lx, 58)
$lblTargetUrl.Size      = New-Object System.Drawing.Size($lw, 22)
$lblTargetUrl.TextAlign = "MiddleRight"

$txtTargetUrl          = New-Object System.Windows.Forms.TextBox
$txtTargetUrl.Location = New-Object System.Drawing.Point($ix, 56)
$txtTargetUrl.Size     = New-Object System.Drawing.Size(608, 22)
$txtTargetUrl.Anchor   = "Top,Left,Right"

$lblSettingsKey           = New-Object System.Windows.Forms.Label
$lblSettingsKey.Text      = "Settings Key:"
$lblSettingsKey.Location  = New-Object System.Drawing.Point($lx, 90)
$lblSettingsKey.Size      = New-Object System.Drawing.Size($lw, 22)
$lblSettingsKey.TextAlign = "MiddleRight"

$txtSettingsKey          = New-Object System.Windows.Forms.TextBox
$txtSettingsKey.Location = New-Object System.Drawing.Point($ix, 88)
$txtSettingsKey.Size     = New-Object System.Drawing.Size(120, 22)
$txtSettingsKey.Text     = "Test"

$lblSubfolder           = New-Object System.Windows.Forms.Label
$lblSubfolder.Text      = "Export Subfolder:"
$lblSubfolder.Location  = New-Object System.Drawing.Point($lx, 122)
$lblSubfolder.Size      = New-Object System.Drawing.Size($lw, 22)
$lblSubfolder.TextAlign = "MiddleRight"

$cmbSubfolder               = New-Object System.Windows.Forms.ComboBox
$cmbSubfolder.Location      = New-Object System.Drawing.Point($ix, 120)
$cmbSubfolder.Size          = New-Object System.Drawing.Size(570, 22)
$cmbSubfolder.Anchor        = "Top,Left,Right"
$cmbSubfolder.DropDownStyle = "DropDownList"

$btnRefresh           = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = "Refresh"
$btnRefresh.Location  = New-Object System.Drawing.Point(774, 119)
$btnRefresh.Size      = New-Object System.Drawing.Size(32, 25)
$btnRefresh.Anchor    = "Top,Right"
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.Font      = New-Object System.Drawing.Font("Segoe UI", 7)

$chkDryRun          = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text     = "Dry Run - validate without deploying"
$chkDryRun.Location = New-Object System.Drawing.Point($ix, 158)
$chkDryRun.Size     = New-Object System.Drawing.Size(290, 22)

$grpConfig.Controls.AddRange(@(
    $lblDevUrl, $txtDevUrl, $lblTargetUrl, $txtTargetUrl,
    $lblSettingsKey, $txtSettingsKey, $lblSubfolder, $cmbSubfolder,
    $btnRefresh, $chkDryRun
))

# -----------------------------------------------------------------------------
# Actions panel
# -----------------------------------------------------------------------------
$pnlActions          = New-Object System.Windows.Forms.Panel
$pnlActions.Location = New-Object System.Drawing.Point(10, 288)
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
$tabControl.Location = New-Object System.Drawing.Point(10, 342)
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

$tabControl.TabPages.AddRange(@($tabOutput, $tabHistory))

$form.Controls.AddRange(@($grpMode, $grpConfig, $pnlActions, $tabControl))

# =============================================================================
# Poll timer
# =============================================================================
$pollTimer          = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 80

$pollTimer.add_Tick({
    $line = $null
    while ($script:outputQueue.TryDequeue([ref]$line)) {
        Append-Log $line (Get-LineColor $line)
    }
    while ($script:errorQueue.TryDequeue([ref]$line)) {
        Append-Log $line ([System.Drawing.Color]::Crimson)
    }
    if ($logBox.TextLength -gt 0) { $logBox.ScrollToCaret() }

    if ($script:processExited) {
        $script:processExited = $false
        $code = $script:exitCode

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

    $lblDevUrl.Visible      = $isExport -or $isBoth
    $txtDevUrl.Visible      = $isExport -or $isBoth
    $lblTargetUrl.Visible   = $isDeploy -or $isBoth
    $txtTargetUrl.Visible   = $isDeploy -or $isBoth
    $lblSettingsKey.Visible = $isDeploy -or $isBoth
    $txtSettingsKey.Visible = $isDeploy -or $isBoth
    $chkDryRun.Visible      = $isDeploy -or $isBoth
}

function Refresh-Subfolders {
    $current = $cmbSubfolder.SelectedItem
    $cmbSubfolder.Items.Clear()
    foreach ($f in (Get-Subfolders)) { [void]$cmbSubfolder.Items.Add($f) }
    if ($cmbSubfolder.Items.Count -gt 0) {
        if ($current -and $cmbSubfolder.Items.Contains($current)) {
            $cmbSubfolder.SelectedItem = $current
        } else {
            $cmbSubfolder.SelectedIndex = 0
        }
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
    $psExe  = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $argStr = "-File `"$scriptFile`" " + ($scriptArgs -join " ")

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

    $proc.add_OutputDataReceived({
        param($s, $e)
        if ($null -ne $e.Data) { $script:outputQueue.Enqueue($e.Data) }
    })
    $proc.add_ErrorDataReceived({
        param($s, $e)
        if ($null -ne $e.Data) { $script:errorQueue.Enqueue($e.Data) }
    })
    $proc.add_Exited({
        param($s, $e)
        Start-Sleep -Milliseconds 150
        $script:exitCode      = $s.ExitCode
        $script:processExited = $true
    })

    $proc.Start()            | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    return $proc
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

    if ($rdoExport.Checked) {
        $script:runningMode = "export"
        Append-Log "=== Export - $subfolder ===" ([System.Drawing.Color]::SteelBlue)
        Append-Log "Log file: $logFile" ([System.Drawing.Color]::DimGray)
        Append-Log "" ([System.Drawing.Color]::Black)
        $script:runProcess = Invoke-ScriptProcess $exportScript @(
            "-EnvironmentUrl", "`"$devUrl`"", "-Subfolder", "`"$subfolder`"", "-SkipPrompts"
        )

    } elseif ($rdoDeploy.Checked) {
        $script:runningMode = "deploy"
        Append-Log "=== Deploy - $subfolder -> $targetUrl ===" ([System.Drawing.Color]::SteelBlue)
        Append-Log "Log file: $logFile" ([System.Drawing.Color]::DimGray)
        Append-Log "" ([System.Drawing.Color]::Black)
        $deployArgs = @("-EnvironmentUrl", "`"$targetUrl`"", "-Subfolder", "`"$subfolder`"",
                        "-SettingsKey", "`"$key`"", "-SkipPrompts")
        if ($chkDryRun.Checked) { $deployArgs += "-DryRun" }
        $script:runProcess = Invoke-ScriptProcess $deployScript $deployArgs

    } else {
        $script:runningMode       = "both-export"
        $script:pendingDeployFile = $deployScript
        $script:pendingDeployArgs = @("-EnvironmentUrl", "`"$targetUrl`"", "-Subfolder", "`"$subfolder`"",
                                      "-SettingsKey", "`"$key`"", "-SkipPrompts")
        if ($chkDryRun.Checked) { $script:pendingDeployArgs += "-DryRun" }

        Append-Log "=== Export + Deploy - $subfolder ===" ([System.Drawing.Color]::SteelBlue)
        Append-Log "Log file: $logFile" ([System.Drawing.Color]::DimGray)
        Append-Log "" ([System.Drawing.Color]::Black)
        Append-Log "--- Export phase ---" ([System.Drawing.Color]::DimGray)
        Append-Log "" ([System.Drawing.Color]::Black)
        $script:runProcess = Invoke-ScriptProcess $exportScript @(
            "-EnvironmentUrl", "`"$devUrl`"", "-Subfolder", "`"$subfolder`"", "-SkipPrompts"
        )
    }
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
[void]$form.ShowDialog()
$pollTimer.Stop()
