<#
.SYNOPSIS
    Claude Lock Widget - shows your Claude Code usage in a Windows lock screen widget.

.DESCRIPTION
    Data commands (run automatically; you rarely need them yourself):
      refresh             Recompute stats + usage and publish them to the widget (default).
      hook                Same as refresh; called by Claude Code's Stop hook after every task.
      push-usage          Store fresh plan-usage numbers (called by Claude after a task), then refresh.
      capture-statusline  Claude Code status line feed (reads JSON on stdin).

    Setup commands:
      install             Install the app, the background task and (optionally) the Claude Code integration.
      uninstall           Remove the task, integration and installed app (-Purge also deletes all data).
      integrate           -Action install | uninstall | status  for the Claude Code hook + CLAUDE.md note.
      preview             Render the widget tile to a PNG and open it (add -Demo for sample data).
      status / doctor     Show state / check everything and explain problems.
      lockscreen-image    LEGACY: render a full-screen picture and set it as the lock screen picture.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File ClaudeLockWidget.ps1 preview -Demo

.NOTES
    Requires Windows 10/11 and the built-in Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('refresh', 'hook', 'push-usage', 'capture-statusline', 'preview', 'install', 'uninstall',
        'integrate', 'status', 'doctor', 'lockscreen-image', 'help')]
    [string]$Command = 'refresh',

    [switch]$Quiet,          # no console output (used by background runs)
    [switch]$Demo,           # use built-in sample data instead of your real stats/usage
    [switch]$NoOpen,         # preview: do not open the PNG afterwards
    [switch]$NoTask,         # install: do not register the background task
    [switch]$NoWidget,       # install: do not install the widget package (no admin prompt)
    [switch]$Purge,          # uninstall: also delete config, cache and logs
    [switch]$Integrate,      # install: add the Claude Code hook + CLAUDE.md note without asking
    [switch]$NoIntegrate,    # install: never touch Claude Code settings
    [switch]$StatusLine,     # integrate: also feed usage from Claude Code's status line (terminal / IDE)
    [switch]$Full,           # preview: render the legacy full-screen picture instead of the widget tile
    [switch]$NoApply,        # lockscreen-image: render only
    [ValidateSet('install', 'uninstall', 'status')][string]$Action = 'status',   # integrate
    [string]$Windows,        # push-usage: "label|percentUsed|resetsAt;label|percentUsed|resetsAt"
    [string]$Plan = '',      # push-usage: plan name, e.g. Pro
    [string]$UsageFixture,   # read usage from a JSON file instead of live sources (testing)
    [string]$Out,            # preview: write the PNG here
    [int]$Width = 0,
    [int]$Height = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$lib = Join-Path $PSScriptRoot 'lib'
foreach ($f in 'Common', 'Usage', 'LocalStats', 'Render', 'Widget', 'LockScreen', 'Scheduler', 'Integration') {
    . (Join-Path $lib "$f.ps1")
}
$script:ClwQuiet = [bool]$Quiet
$script:ClwRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath

# ---------------------------------------------------------------- helpers

function Write-ClwStep {
    param([string]$Text, [string]$Color = 'Cyan')
    if (-not $script:ClwQuiet) { Write-Host $Text -ForegroundColor $Color }
}

function Get-ClwUsageAndStats {
    param($Config, [bool]$UseDemo, [string]$Fixture)
    $usage = if ($UseDemo) { Get-ClwDemoUsage $Config } else { Get-ClwUsage -Config $Config -Fixture $Fixture }
    if ($usage.Status -notin 'ok') { Write-ClwLog "Usage: $($usage.Status) - $($usage.Message)" 'WARN' }
    $stats = $null
    if ($UseDemo) { $stats = Get-ClwDemoStats }
    else {
        try { $stats = Get-ClwStats -Config $Config }
        catch { Write-ClwLog "Local stats unavailable: $($_.Exception.Message)" 'WARN' }
    }
    [pscustomobject]@{ Usage = $usage; Stats = $stats }
}

function Invoke-ClwRefresh {
    # Publish = write the live widget state; otherwise render only to -TilePath (previews).
    param($Config, [bool]$Publish, [bool]$UseDemo, [string]$Fixture, [string]$TilePath)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Initialize-ClwDirectories
    $data = Get-ClwUsageAndStats -Config $Config -UseDemo $UseDemo -Fixture $Fixture
    $tile = if ($Publish) { Update-ClwWidgetState -Config $Config -Stats $data.Stats -Usage $data.Usage }
    else { New-ClwWidgetImage -Config $Config -Stats $data.Stats -Usage $data.Usage -OutPath $TilePath -Style card }   # previews use the opaque card so they are readable on any background
    Write-ClwLog ('Widget {0} in {1:N1}s (usage: {2} via {3}, stats: {4})' -f $(if ($Publish) { 'updated' } else { 'rendered' }), $clock.Elapsed.TotalSeconds, $data.Usage.Status, $(if ($data.Usage.Source) { $data.Usage.Source } else { 'none' }), $(if ($data.Stats) { 'ok' } else { 'n/a' }))
    [pscustomobject]@{ Tile = $tile; Usage = $data.Usage; Stats = $data.Stats }
}

function Invoke-ClwFullImage {
    # LEGACY full-screen lock screen picture.
    param($Config, [bool]$Apply, [bool]$UseDemo, [string]$Fixture, [string]$OutPath, [int]$W, [int]$H)
    $paths = Get-ClwPaths
    Initialize-ClwDirectories
    $data = Get-ClwUsageAndStats -Config $Config -UseDemo $UseDemo -Fixture $Fixture
    if ($W -le 0) { $W = [int]$Config.width }
    if ($H -le 0) { $H = [int]$Config.height }
    if ($W -le 0 -or $H -le 0) { $s = Get-ClwScreenSize; $W = $s.Width; $H = $s.Height }
    $file = $OutPath
    if (-not $file) { $file = Join-Path $paths.Output ('lockscreen-{0}.png' -f (Get-Date -Format 'yyyyMMddHHmmssfff')) }
    [void](New-ClwImage -Config $Config -Stats $data.Stats -Usage $data.Usage -Width $W -Height $H -OutPath $file)
    if ($Apply) { Set-ClwLockScreenImage -Path $file; Remove-ClwOldImages -Directory $paths.Output }
    $file
}

# --------------------------------------------------------------- commands

function Invoke-ClwCmdRefresh {
    $paths = Get-ClwPaths
    Initialize-ClwDirectories
    $mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeLockWidget.Refresh')
    if (-not $mutex.WaitOne(0)) {
        # a refresh is already running: ask it to go around once more so our newer data is included
        Set-Content -LiteralPath $paths.Pending -Value (Get-Date -Format o)
        Write-ClwLog 'Another refresh is running; queued one more pass.'
        return 0
    }
    try {
        $cfg = Get-ClwConfig
        for ($pass = 0; $pass -lt 3; $pass++) {
            if (Test-Path -LiteralPath $paths.Pending) { Remove-Item -LiteralPath $paths.Pending -Force -ErrorAction SilentlyContinue }
            [void](Invoke-ClwRefresh -Config $cfg -Publish $true -UseDemo $Demo.IsPresent -Fixture $UsageFixture -TilePath '')
            if (-not (Test-Path -LiteralPath $paths.Pending)) { break }
        }
        Write-ClwStep 'Widget data updated.' 'Green'
        return 0
    }
    catch {
        Write-ClwLog "Refresh failed: $($_.Exception.Message)" 'ERROR'
        return 1
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Invoke-ClwCmdPushUsage {
    $entries = ConvertFrom-ClwWindowsArg $Windows
    if ($entries.Count -eq 0) {
        Write-ClwLog 'push-usage: no usable windows in -Windows (expected "label|percentUsed|resetsAt;...").' 'WARN'
        Write-ClwStep 'No usable usage windows were given.' 'Yellow'
        return 2
    }
    Save-ClwLiveUsage -Entries $entries -Source 'agent' -Plan $Plan
    Write-ClwLog ('push-usage: {0}' -f (($entries.Keys | Sort-Object | ForEach-Object { '{0}={1}%' -f $_, [math]::Round($entries[$_].Percent) }) -join ', '))
    return (Invoke-ClwCmdRefresh)
}

function Invoke-ClwCmdPreview {
    try {
        $cfg = Get-ClwConfig
        $paths = Get-ClwPaths
        if ($Full) {
            $target = if ($Out) { $Out } else { Join-Path $paths.Output 'preview-fullscreen.png' }
            $file = Invoke-ClwFullImage -Config $cfg -Apply $false -UseDemo $Demo.IsPresent -Fixture $UsageFixture -OutPath $target -W $Width -H $Height
        }
        else {
            $target = if ($Out) { $Out } else { Join-Path $paths.Output 'preview-widget.png' }
            Initialize-ClwDirectories
            $file = (Invoke-ClwRefresh -Config $cfg -Publish $false -UseDemo $Demo.IsPresent -Fixture $UsageFixture -TilePath $target).Tile
        }
        Write-ClwStep "Preview written to $file" 'Green'
        if (-not $NoOpen -and -not $script:ClwQuiet) { Start-Process -FilePath $file }
        return 0
    }
    catch {
        Write-ClwLog "Preview failed: $($_.Exception.Message)" 'ERROR'
        return 1
    }
}

function Invoke-ClwCmdLockImage {
    try {
        $cfg = Get-ClwConfig
        $file = Invoke-ClwFullImage -Config $cfg -Apply (-not $NoApply) -UseDemo $Demo.IsPresent -Fixture $UsageFixture -OutPath $Out -W $Width -H $Height
        Write-ClwStep $(if ($NoApply) { "Rendered (not applied): $file" } else { 'Lock screen picture updated.' }) 'Green'
        return 0
    }
    catch { Write-ClwLog "lockscreen-image failed: $($_.Exception.Message)" 'ERROR'; return 1 }
}

function Invoke-ClwCmdIntegrate {
    $cfg = Get-ClwConfig
    switch ($Action) {
        'install' { (Install-ClwIntegration -Config $cfg -ClaudeMd $true -StatusLine $StatusLine.IsPresent) | ForEach-Object { Write-ClwStep "  $_" 'Gray' } }
        'uninstall' { (Uninstall-ClwIntegration -Config $cfg) | ForEach-Object { Write-ClwStep "  $_" 'Gray' } }
        default {
            $s = Get-ClwIntegrationStatus -Config $cfg
            Write-Host ("Stop hook (updates stats after every task) : {0}" -f $(if ($s.StopHook) { 'installed' } else { 'not installed' }))
            Write-Host ("CLAUDE.md note (Claude pushes usage)       : {0}" -f $(if ($s.ClaudeMd) { 'installed' } else { 'not installed' }))
            Write-Host ("Status line feed (terminal / IDE)          : {0}" -f $(if ($s.StatusLine) { 'installed' } else { 'not installed' }))
        }
    }
    0
}

function Find-ClwWidgetInstaller {
    $dist = Join-Path $script:ClwRoot 'widget\dist'
    $msix = Join-Path $dist 'ClaudeLockWidget.msix'
    $installer = Join-Path $script:ClwRoot 'widget\Install-Widget.ps1'
    if ((Test-Path -LiteralPath $msix) -and (Test-Path -LiteralPath $installer)) { return $installer }
    $null
}

function Invoke-ClwCmdInstall {
    $paths = Get-ClwPaths
    Write-ClwStep 'Installing Claude Lock Widget ...'
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or newer is required.' }
    Initialize-ClwDirectories

    # 1. copy the app so the downloaded folder can be moved or deleted afterwards
    $source = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath
    $target = $paths.App
    if ($source.TrimEnd('\') -ne $target.TrimEnd('\')) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $target -Force)
        Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
        Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        Write-ClwStep "  App copied to $target"
    }
    if (Save-ClwDefaultConfig) { Write-ClwStep "  Settings file created: $($paths.Config)" }
    else { Write-ClwStep "  Keeping existing settings: $($paths.Config)" }
    $cfg = Get-ClwConfig

    # 2. background task (keeps reset countdowns fresh and recovers after sign-in)
    if (-not $NoTask) {
        $reg = Register-ClwTask -ScriptPath (Join-Path $target 'ClaudeLockWidget.ps1') -IntervalMinutes $cfg.refreshMinutes
        Write-ClwStep ("  Background task registered (every {0} min, on sign-in{1})" -f $cfg.refreshMinutes, $(if ($reg.SessionTriggers) { ', on lock and unlock' } else { '' }))
    }

    # 3. Claude Code integration (hook + usage note)
    $doIntegrate = $Integrate.IsPresent
    if (-not $doIntegrate -and -not $NoIntegrate -and -not $script:ClwQuiet -and -not [Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host 'Update the widget after every Claude task?' -ForegroundColor Cyan
        Write-Host '  This adds (1) an async "Stop" hook to ~/.claude/settings.json and' -ForegroundColor Gray
        Write-Host '  (2) a short, clearly marked note to ~/.claude/CLAUDE.md asking Claude to report your plan usage.' -ForegroundColor Gray
        Write-Host '  Both are reversible with: integrate -Action uninstall   (settings.json is backed up first).' -ForegroundColor Gray
        $answer = Read-Host '  Enable it? [Y/n]'
        $doIntegrate = ($answer -eq '' -or $answer -match '^(y|yes)$')
    }
    if ($doIntegrate -and -not $NoIntegrate) {
        foreach ($line in (Install-ClwIntegration -Config $cfg -ClaudeMd $true -StatusLine $StatusLine.IsPresent)) { Write-ClwStep "  $line" }
    }
    else { Write-ClwStep '  Claude Code integration skipped (enable later with: integrate -Action install).' 'Yellow' }

    # 4. first publish
    Write-ClwStep '  Publishing the first widget image ...'
    try {
        $r = Invoke-ClwRefresh -Config $cfg -Publish $true -UseDemo $Demo.IsPresent -Fixture $UsageFixture -TilePath ''
        if ($r.Usage.Status -ne 'ok') { Write-ClwStep "  Note: $($r.Usage.Message)" 'Yellow' }
    }
    catch {
        Write-ClwLog "First refresh failed: $($_.Exception.Message)" 'ERROR'
        Write-ClwStep "  The first refresh failed ($($_.Exception.Message)). Run doctor.cmd for details." 'Yellow'
    }

    # 5. the Windows widget itself (a signed package; needs one admin prompt to trust its certificate)
    $widgetInstaller = if ($NoWidget) { $null } else { Find-ClwWidgetInstaller }
    if ($NoWidget) { Write-ClwStep '  Widget package skipped (-NoWidget).' 'Yellow' }
    elseif ($widgetInstaller) {
        Write-ClwStep '  Installing the lock screen widget package ...'
        $dist = Join-Path $script:ClwRoot 'widget\dist'
        try { & $widgetInstaller -Msix (Join-Path $dist 'ClaudeLockWidget.msix') -Cert (Join-Path $dist 'ClaudeLockWidget.cer') -NoOpenSettings:$Quiet.IsPresent }
        catch { Write-ClwStep "  Widget package install failed: $($_.Exception.Message)" 'Yellow' }
    }
    else {
        Write-ClwStep '  Widget package not found (widget\dist\ClaudeLockWidget.msix). Download a release, or build it with widget\Build-Widget.ps1.' 'Yellow'
    }

    Write-ClwStep ''
    Write-ClwStep 'Next: Settings > Personalization > Lock screen > Widgets > Add widget > "Claude usage".' 'Green'
    0
}

function Invoke-ClwCmdUninstall {
    $paths = Get-ClwPaths
    if (Unregister-ClwTask) { Write-ClwStep 'Background task removed.' 'Green' } else { Write-ClwStep 'No background task found.' 'Yellow' }

    try {
        $cfg = Get-ClwConfig
        foreach ($line in (Uninstall-ClwIntegration -Config $cfg)) { Write-ClwStep "  $line" 'Gray' }
    }
    catch { Write-ClwStep "  Could not update Claude Code settings: $($_.Exception.Message)" 'Yellow' }

    $pkg = Get-AppxPackage -Name 'ClaudeLockWidget.Provider' -ErrorAction SilentlyContinue
    if ($pkg) { $pkg | Remove-AppxPackage; Write-ClwStep 'Widget package removed.' 'Green' }

    if ($Purge) {
        # safety net: never recursively delete a folder that is not obviously ours (e.g. a bad CLW_HOME)
        if ((Split-Path -Leaf $paths.Home.TrimEnd('\')) -notmatch '^(ClaudeLockWidget|clw-.+)$') {
            throw "Refusing to delete '$($paths.Home)': the folder name is not 'ClaudeLockWidget'."
        }
        $running = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath
        if ($running.StartsWith($paths.Home, [StringComparison]::OrdinalIgnoreCase)) {
            # we are running from the folder we are about to delete: hand over to a detached cleanup
            $cmd = "Start-Sleep 2; Remove-Item -LiteralPath '$($paths.Home.Replace("'", "''"))' -Recurse -Force"
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd
        }
        elseif (Test-Path -LiteralPath $paths.Home) { Remove-Item -LiteralPath $paths.Home -Recurse -Force }
        Write-ClwStep "Removed $($paths.Home)." 'Green'
    }
    elseif (Test-Path -LiteralPath $paths.App) {
        $running = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath
        if (-not $running.StartsWith($paths.App, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $paths.App -Recurse -Force
            Write-ClwStep 'Installed app removed (settings kept; use -Purge to delete them too).' 'Green'
        }
        else { Write-ClwStep "Installed app left in place because it is running ($($paths.App))." 'Yellow' }
    }
    Write-ClwStep 'The widget trust certificate is left in place; remove it in certlm.msc (Trusted People) if you want.' 'Gray'
    0
}

function Invoke-ClwCmdStatus {
    $paths = Get-ClwPaths
    $task = Get-ClwTaskStatus
    if ($task) { Write-Host ("Task      : {0} (last run {1}, result 0x{2:X}, next {3})" -f $task.State, $task.LastRunTime, $task.LastTaskResult, $task.NextRunTime) }
    else { Write-Host 'Task      : not installed' -ForegroundColor Yellow }
    $pkg = Get-AppxPackage -Name 'ClaudeLockWidget.Provider' -ErrorAction SilentlyContinue
    Write-Host ("Widget    : {0}" -f $(if ($pkg) { "installed (v$($pkg.Version))" } else { 'package not installed' }))
    $live = Read-ClwLiveUsage
    if ($live) { Write-Host ("Usage     : from {0}, captured {1:N0} min ago" -f $live.Source, (([datetimeoffset]::Now - $live.CapturedAt).TotalMinutes)) }
    else { Write-Host 'Usage     : no live data yet' -ForegroundColor Yellow }
    Write-Host "Home      : $($paths.Home)"
    if (Test-Path -LiteralPath $paths.Log) {
        Write-Host 'Recent log:'
        Get-Content -LiteralPath $paths.Log -Tail 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
    0
}

function Invoke-ClwCmdDoctor {
    $failed = 0
    $report = {
        param([string]$Level, [string]$Text)
        $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'INFO' { 'Gray' } default { 'Red' } }
        Write-Host ('[{0,-4}] {1}' -f $Level, $Text) -ForegroundColor $color
    }

    $os = Get-CimInstance Win32_OperatingSystem
    & $report 'INFO' "$($os.Caption) (build $([Environment]::OSVersion.Version.Build)), PowerShell $($PSVersionTable.PSVersion)"
    if ($PSVersionTable.PSVersion.Major -lt 5) { & $report 'FAIL' 'Windows PowerShell 5.1 is required.'; $failed++ }
    if ([Environment]::OSVersion.Version.Build -lt 22621) { & $report 'WARN' 'Lock screen widgets need a recent Windows 11 (24H2 or later recommended).' }

    $cfg = Get-ClwConfig
    $claude = Get-ClwClaudeDir $cfg
    if (Test-Path -LiteralPath $claude) { & $report 'OK' "Claude Code folder: $claude" }
    else { & $report 'FAIL' "Claude Code folder not found: $claude"; $failed++ }

    try {
        $stats = Get-ClwStats -Config $cfg
        & $report 'OK' ('Local stats: {0} sessions, {1} messages, {2} tokens' -f (Format-ClwNumber $stats.Sessions), (Format-ClwNumber $stats.Messages), (Format-ClwCompact $stats.TotalTokens))
    }
    catch { & $report 'WARN' "Local stats unavailable: $($_.Exception.Message)" }

    $live = Read-ClwLiveUsage
    if ($live) {
        $age = ([datetimeoffset]::Now - $live.CapturedAt).TotalMinutes
        $parts = @($live.Map.Keys | Sort-Object | ForEach-Object { '{0} {1}%' -f $_, [math]::Round($live.Map[$_].Percent) })
        & $report $(if ($age -gt $cfg.staleAfterMinutes) { 'WARN' } else { 'OK' }) ('Usage from "{0}", {1:N0} min old: {2}' -f $live.Source, $age, ($parts -join ', '))
    }
    else { & $report 'WARN' 'No usage data yet. Finish a task in Claude Code (with the integration installed) or use the status line feed.' }

    $int = Get-ClwIntegrationStatus -Config $cfg
    & $report $(if ($int.StopHook) { 'OK' } else { 'WARN' }) ('Stop hook (refresh after every task): ' + $(if ($int.StopHook) { 'installed' } else { 'not installed - run install.cmd or: integrate -Action install' }))
    & $report $(if ($int.ClaudeMd) { 'OK' } else { 'WARN' }) ('CLAUDE.md usage note (Claude reports plan usage): ' + $(if ($int.ClaudeMd) { 'installed' } else { 'not installed' }))

    $pkg = Get-AppxPackage -Name 'ClaudeLockWidget.Provider' -ErrorAction SilentlyContinue
    if ($pkg) { & $report 'OK' "Widget package installed (v$($pkg.Version))" }
    else { & $report 'FAIL' 'Widget package not installed (see SETUP_GUIDE.md, "Install the widget").'; $failed++ }

    if (Test-Path -LiteralPath (Get-ClwPaths).State) {
        $st = Get-Content -LiteralPath (Get-ClwPaths).State -Raw | ConvertFrom-Json
        & $report 'OK' ("Widget data last published {0}" -f $st.updatedAt)
    }
    else { & $report 'WARN' 'Widget data has not been published yet (run refresh-now.cmd).' }

    $task = Get-ClwTaskStatus
    if ($task) { & $report 'OK' "Background task: $($task.State), last run $($task.LastRunTime)" }
    else { & $report 'WARN' 'Background task not installed (run install.cmd).' }

    if ($failed -gt 0) { Write-Host "`n$failed problem(s) found." -ForegroundColor Red; return 1 }
    Write-Host "`nNo blocking problems found." -ForegroundColor Green
    0
}

# ------------------------------------------------------------------ main

try {
    $code = switch ($Command) {
        'refresh' { Invoke-ClwCmdRefresh }
        'hook' { $script:ClwQuiet = $true; Invoke-ClwCmdRefresh }
        'push-usage' { Invoke-ClwCmdPushUsage }
        'capture-statusline' { $script:ClwQuiet = $true; [Console]::Out.Write((Invoke-ClwStatusLineCapture)); 0 }
        'preview' { Invoke-ClwCmdPreview }
        'install' { Invoke-ClwCmdInstall }
        'uninstall' { Invoke-ClwCmdUninstall }
        'integrate' { Invoke-ClwCmdIntegrate }
        'status' { Invoke-ClwCmdStatus }
        'doctor' { Invoke-ClwCmdDoctor }
        'lockscreen-image' { Invoke-ClwCmdLockImage }
        default { Get-Help $PSCommandPath -Full | Out-Host; 0 }
    }
}
catch {
    Write-ClwLog "$Command failed: $($_.Exception.Message)" 'ERROR'
    $code = 1
}
exit ([int](@($code)[-1]))
