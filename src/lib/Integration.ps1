# Integration.ps1 - hooks the widget into Claude Code so it updates after every task.
#
#   * Stop hook (async)   ~/.claude/settings.json -> runs `ClaudeLockWidget.ps1 hook` when Claude finishes
#                         responding. Refreshes the stats and re-renders; never blocks Claude.
#   * Agent push          a clearly marked block in ~/.claude/CLAUDE.md asks Claude to call the desktop
#                         app's get_usage tool after each task and pass the numbers to `push-usage`.
#   * Status line (opt.)  Claude Code's status line gets rate_limits on every update (terminal / IDE).
#
# Every change is reversible with `integrate -Action uninstall`; settings.json is backed up first.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0

$script:ClwMdBegin = '<!-- BEGIN ClaudeLockWidget (managed block - remove with: ClaudeLockWidget.ps1 integrate -Action uninstall) -->'
$script:ClwMdEnd = '<!-- END ClaudeLockWidget -->'

function Get-ClwEntryScript {
    # Prefer the installed copy so the downloaded folder can be deleted afterwards.
    $installed = Join-Path (Get-ClwPaths).App 'ClaudeLockWidget.ps1'
    $path = if (Test-Path -LiteralPath $installed) { $installed } else { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\ClaudeLockWidget.ps1')).ProviderPath }
    $path -replace '\\', '/'
}

function Get-ClwCommandLine {
    param([string]$Verb)
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f (Get-ClwEntryScript), $Verb
}

# ------------------------------------------------------- settings.json

function Get-ClwSettingsPath {
    param($Config)
    Join-Path (Get-ClwClaudeDir $Config) 'settings.json'
}

function Read-ClwSettings {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    $raw = [System.IO.File]::ReadAllText($Path)
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    $raw | ConvertFrom-Json
}

function Write-ClwSettings {
    param([string]$Path, $Settings)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    if (Test-Path -LiteralPath $Path) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Path -Destination "$Path.clw-backup-$stamp" -Force
        Get-ChildItem -LiteralPath $dir -Filter 'settings.json.clw-backup-*' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $json = $Settings | ConvertTo-Json -Depth 20
    # Windows PowerShell escapes these characters needlessly; undo it so the file stays readable.
    $backslash = [string][char]92
    foreach ($pair in @(@('u0026', '&'), @('u003c', '<'), @('u003e', '>'), @('u0027', "'"))) {
        $json = $json.Replace($backslash + $pair[0], $pair[1])
    }
    [void]($json | ConvertFrom-Json)   # never write something we cannot read back
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Test-ClwOurCommand {
    param([string]$Command, [string]$Verb)
    $Command -match 'ClaudeLockWidget\.ps1' -and $Command -match ('\s{0}\s*$' -f [regex]::Escape($Verb))
}

function Get-ClwStopEntries {
    param($Settings)
    $hooks = $Settings.PSObject.Properties['hooks']
    if (-not $hooks -or -not $hooks.Value) { return @() }
    $stop = $hooks.Value.PSObject.Properties['Stop']
    if (-not $stop -or -not $stop.Value) { return @() }
    @($stop.Value)
}

function Test-ClwHookInstalled {
    param($Settings)
    foreach ($group in (Get-ClwStopEntries $Settings)) {
        foreach ($h in @($group.hooks)) { if (Test-ClwOurCommand ([string]$h.command) 'hook') { return $true } }
    }
    $false
}

function Add-ClwStopHook {
    param($Settings, [string]$Command)
    if (Test-ClwHookInstalled $Settings) { return $false }
    $entry = [pscustomobject]@{
        hooks = @([pscustomobject]@{ type = 'command'; command = $Command; async = $true; timeout = 120 })
    }
    if (-not $Settings.PSObject.Properties['hooks'] -or -not $Settings.hooks) {
        $Settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $groups = @(@(Get-ClwStopEntries $Settings) + @($entry))
    if ($Settings.hooks.PSObject.Properties['Stop']) { $Settings.hooks.Stop = $groups }   # assign in place: keeps the user's key order
    else { $Settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue $groups }
    $true
}

function Remove-ClwStopHook {
    param($Settings)
    if (-not (Test-ClwHookInstalled $Settings)) { return $false }
    $kept = @()
    foreach ($group in (Get-ClwStopEntries $Settings)) {
        $hooks = @(@($group.hooks) | Where-Object { -not (Test-ClwOurCommand ([string]$_.command) 'hook') })
        if ($hooks.Count -gt 0) {
            $group.hooks = $hooks
            $kept += $group
        }
    }
    if ($kept.Count -gt 0) { $Settings.hooks.Stop = $kept }
    else {
        $Settings.hooks.PSObject.Properties.Remove('Stop')
        if (-not @($Settings.hooks.PSObject.Properties).Count) { $Settings.PSObject.Properties.Remove('hooks') }
    }
    $true
}

function Test-ClwStatusLineOurs {
    param($Settings)
    $sl = $Settings.PSObject.Properties['statusLine']
    [bool]($sl -and $sl.Value -and (Test-ClwOurCommand ([string]$sl.Value.command) 'capture-statusline'))
}

# ------------------------------------------------------------ CLAUDE.md

function Get-ClwClaudeMdBlock {
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" push-usage -Plan "<plan.plan>" -Windows "<label>|<percentUsed>|<resetsAt>;<label>|<percentUsed>|<resetsAt>"' -f (Get-ClwEntryScript)
    @(
        $script:ClwMdBegin
        '## Lock screen usage widget'
        'The user keeps a Windows lock screen widget that shows their Claude plan usage. After you finish a task in which you used tools or changed anything - right before your final reply, and not for plain conversational answers - silently do both steps and do not mention them:'
        ''
        '1. Call the `get_usage` tool (the desktop app session-management tool, for example `mcp__ccd_session_mgmt__get_usage`). If it is not available in this session, or `plan.status` is not `ok`, skip step 2.'
        '2. Run one shell command. Write each entry of `plan.windows` as `label|percentUsed|resetsAt` and join the entries with `;`:'
        ''
        ('   `{0}`' -f $cmd)
        ''
        'If either step fails, ignore the failure and carry on. Never retry more than once and never let this delay your answer.'
        $script:ClwMdEnd
    ) -join "`n"
}

function Get-ClwClaudeMdPath {
    param($Config)
    Join-Path (Get-ClwClaudeDir $Config) 'CLAUDE.md'
}

function Test-ClwClaudeMdInstalled {
    param([string]$Path)
    (Test-Path -LiteralPath $Path) -and ([System.IO.File]::ReadAllText($Path).Contains($script:ClwMdBegin))
}

function Set-ClwClaudeMdBlock {
    param([string]$Path)
    $block = Get-ClwClaudeMdBlock
    $text = if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) } else { '' }
    $pattern = '(?s)' + [regex]::Escape($script:ClwMdBegin) + '.*?' + [regex]::Escape($script:ClwMdEnd)
    if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, { param($m) $block }) }
    else {
        if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
        if ($text) { $text += "`n" }
        $text += $block + "`n"
    }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-ClwClaudeMdBlock {
    param([string]$Path)
    if (-not (Test-ClwClaudeMdInstalled $Path)) { return $false }
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?s)\r?\n?' + [regex]::Escape($script:ClwMdBegin) + '.*?' + [regex]::Escape($script:ClwMdEnd) + '\r?\n?'
    $text = [regex]::Replace($text, $pattern, '')
    if ($text.Trim()) { [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false))) }
    else { Remove-Item -LiteralPath $Path -Force }
    $true
}

# ------------------------------------------------------------- commands

function Install-ClwIntegration {
    param($Config, [bool]$ClaudeMd = $true, [bool]$StatusLine = $false)
    $log = New-Object System.Collections.Generic.List[string]
    $path = Get-ClwSettingsPath $Config
    $settings = Read-ClwSettings $path
    $changed = $false

    if (Add-ClwStopHook $settings (Get-ClwCommandLine 'hook')) { $changed = $true; $log.Add('Added the Stop hook (async) to settings.json.') }
    else { $log.Add('Stop hook already present.') }

    if ($StatusLine) {
        $sl = $settings.PSObject.Properties['statusLine']
        if ($sl -and $sl.Value -and -not (Test-ClwStatusLineOurs $settings)) {
            $log.Add('Left your existing status line untouched (it can call "capture-statusline" itself; see the setup guide).')
        }
        elseif (-not (Test-ClwStatusLineOurs $settings)) {
            $entry = [pscustomobject]@{ type = 'command'; command = (Get-ClwCommandLine 'capture-statusline') }
            $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $entry -Force
            $changed = $true; $log.Add('Added the status line feed to settings.json.')
        }
    }
    if ($changed) { Write-ClwSettings $path $settings; $log.Add("settings.json saved (backup next to it: settings.json.clw-backup-*).") }

    if ($ClaudeMd) {
        $md = Get-ClwClaudeMdPath $Config
        Set-ClwClaudeMdBlock $md
        $log.Add("Added the usage-sync note to $md.")
    }
    $log
}

function Uninstall-ClwIntegration {
    param($Config)
    $log = New-Object System.Collections.Generic.List[string]
    $path = Get-ClwSettingsPath $Config
    if (Test-Path -LiteralPath $path) {
        $settings = Read-ClwSettings $path
        $changed = $false
        if (Remove-ClwStopHook $settings) { $changed = $true; $log.Add('Removed the Stop hook.') }
        if (Test-ClwStatusLineOurs $settings) { $settings.PSObject.Properties.Remove('statusLine'); $changed = $true; $log.Add('Removed the status line feed.') }
        if ($changed) { Write-ClwSettings $path $settings }
    }
    if (Remove-ClwClaudeMdBlock (Get-ClwClaudeMdPath $Config)) { $log.Add('Removed the usage-sync note from CLAUDE.md.') }
    if ($log.Count -eq 0) { $log.Add('Nothing to remove.') }
    $log
}

function Get-ClwIntegrationStatus {
    param($Config)
    $settings = Read-ClwSettings (Get-ClwSettingsPath $Config)
    [pscustomobject]@{
        StopHook   = (Test-ClwHookInstalled $settings)
        StatusLine = (Test-ClwStatusLineOurs $settings)
        ClaudeMd   = (Test-ClwClaudeMdInstalled (Get-ClwClaudeMdPath $Config))
    }
}

function ConvertFrom-ClwStatusLineJson {
    # Claude Code status line input -> @{ Entries = @{ five_hour = ...; seven_day = ... }; Text = "5h 23% | 7d 41%" }
    # (rate_limits only exists for claude.ai Pro/Max subscribers after the first API response.)
    param([string]$Json)
    $result = [pscustomobject]@{ Entries = @{}; Text = '' }
    try { $o = $Json | ConvertFrom-Json } catch { return $result }
    if ($null -eq $o) { return $result }
    $rl = $o.PSObject.Properties['rate_limits']
    if (-not $rl -or -not $rl.Value) { return $result }

    $text = @()
    foreach ($pair in @(@('five_hour', '5h'), @('seven_day', '7d'))) {
        $w = $rl.Value.PSObject.Properties[$pair[0]]
        if (-not $w -or -not $w.Value) { continue }
        $pct = $w.Value.PSObject.Properties['used_percentage']
        if (-not $pct -or $null -eq $pct.Value) { continue }
        $reset = $null
        if ($w.Value.PSObject.Properties['resets_at']) { $reset = ConvertTo-ClwResetTime $w.Value.resets_at }
        $result.Entries[$pair[0]] = [pscustomobject]@{ Percent = [math]::Min(100.0, [math]::Max(0.0, [double]$pct.Value)); ResetsAt = $reset }
        $text += ('{0} {1}%' -f $pair[1], [math]::Round([double]$pct.Value))
    }
    $result.Text = $text -join ' | '
    $result
}

function Invoke-ClwStatusLineCapture {
    # Called by Claude Code's status line: JSON on stdin, one line of text on stdout.
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $parsed = ConvertFrom-ClwStatusLineJson ([Console]::In.ReadToEnd())
    $entries = $parsed.Entries
    $text = $parsed.Text
    if ($entries.Count -eq 0) { return '' }

    $previous = Read-ClwLiveUsage
    $changed = $true
    if ($previous -and $previous.Source -eq 'statusline' -and (([datetimeoffset]::Now - $previous.CapturedAt).TotalMinutes -lt 10)) {
        $changed = $false
        foreach ($k in $entries.Keys) {
            if (-not $previous.Map.ContainsKey($k) -or [math]::Abs($previous.Map[$k].Percent - $entries[$k].Percent) -ge 0.5) { $changed = $true }
        }
    }
    if ($changed) {
        Save-ClwLiveUsage -Entries $entries -Source 'statusline'
        # re-render in the background so the status line itself stays instant
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Get-ClwEntryScript)), 'refresh', '-Quiet') | Out-Null
    }
    $text
}
