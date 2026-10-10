# Common.ps1 - paths, logging, configuration and formatting helpers.
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less files as ANSI.

Set-StrictMode -Version 1.0

$script:ClwVersion = '2.0.1'
$script:ClwQuiet = $false
$script:ClwCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')

# ------------------------------------------------------------------ paths

function Get-ClwHome {
    if ($env:CLW_HOME) { return $env:CLW_HOME }
    return (Join-Path $env:LOCALAPPDATA 'ClaudeLockWidget')
}

function Get-ClwPaths {
    $root = Get-ClwHome
    [pscustomobject]@{
        Home       = $root
        App        = Join-Path $root 'app'
        Config     = Join-Path $root 'config.json'
        Cache      = Join-Path $root 'cache'
        Output     = Join-Path $root 'output'
        Logs       = Join-Path $root 'logs'
        Widget     = Join-Path $root 'widget'
        Log        = Join-Path $root 'logs\widget.log'
        UsageCache = Join-Path $root 'cache\usage.json'
        LiveUsage  = Join-Path $root 'cache\usage-live.json'
        StatsIndex = Join-Path $root 'cache\stats-index.json'
        Pending    = Join-Path $root 'cache\refresh.pending'
        State      = Join-Path $root 'widget\widget-state.json'
    }
}

function Initialize-ClwDirectories {
    $p = Get-ClwPaths
    foreach ($d in @($p.Home, $p.Cache, $p.Output, $p.Logs, $p.Widget)) {
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    }
}

# ---------------------------------------------------------------- logging

function Write-ClwLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $p = Get-ClwPaths
        if (-not (Test-Path -LiteralPath $p.Logs)) { [void](New-Item -ItemType Directory -Path $p.Logs -Force) }
        if ((Test-Path -LiteralPath $p.Log) -and ((Get-Item -LiteralPath $p.Log).Length -gt 256KB)) {
            Move-Item -LiteralPath $p.Log -Destination ($p.Log + '.old') -Force
        }
        Add-Content -LiteralPath $p.Log -Value $line -Encoding UTF8
    }
    catch { }   # logging must never break a refresh

    if (-not $script:ClwQuiet) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
}

# ----------------------------------------------------------------- config

function Get-ClwDefaultConfig {
    $dot = [string][char]0x00B7
    [ordered]@{
        refreshMinutes  = 10
        widgetWeeks     = 30              # weeks shown in the widget's activity calendar (8-52)
        staleAfterMinutes = 360           # usage older than this is flagged as stale
        apiFallback     = $false          # opt-in: read ~/.claude/.credentials.json and ask Anthropic's usage endpoint when no live data exists
        position        = 'auto'          # (legacy full-screen image) auto | left | center | right
        verticalAlign   = 'center'        # top | center | bottom
        offsetXPercent  = 0
        offsetYPercent  = 0
        scale           = 1.0
        statsRange      = 'all'           # all | 30d | 7d
        background      = 'gradient'      # gradient | wallpaper | <path to an image>
        backgroundDim   = 0.45
        cardOpacity     = 0.92
        accent          = '#2A78D6'
        colorizeBars    = $true
        showUpdatedAt   = $true
        funFactBook     = 'Pride and Prejudice'   # or "off"
        countMode       = 'claude-code'   # claude-code | deduplicated
        fontFamily      = 'Segoe UI'
        claudeConfigDir = ''
        width           = 0               # 0 = detect primary display
        height          = 0
        bars            = @(
            [ordered]@{ key = 'five_hour'; label = 'Session limit' },
            [ordered]@{ key = 'seven_day'; label = ('Weekly {0} all models' -f $dot) }
        )
    }
}

function Get-ClwConfig {
    param([string]$Path)
    $p = Get-ClwPaths
    if (-not $Path) { $Path = $p.Config }

    $cfg = Get-ClwDefaultConfig
    $user = $null
    if (Test-Path -LiteralPath $Path) {
        try { $user = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-ClwLog "config.json is not valid JSON ($($_.Exception.Message)); using defaults." 'WARN' }
    }

    if ($user) {
        foreach ($key in @($cfg.Keys)) {
            $prop = $user.PSObject.Properties[$key]
            if ($null -eq $prop -or $null -eq $prop.Value) { continue }
            if ($key -eq 'bars') {
                $bars = @()
                foreach ($b in @($prop.Value)) {
                    if ($b.key) {
                        $label = if ($b.label) { [string]$b.label } else { [string]$b.key }
                        $bars += [ordered]@{ key = [string]$b.key; label = $label }
                    }
                }
                if ($bars.Count -gt 0) { $cfg.bars = $bars }
                continue
            }
            $default = $cfg[$key]
            try {
                if ($default -is [bool]) { $cfg[$key] = [bool]$prop.Value }
                elseif ($default -is [int]) { $cfg[$key] = [int]$prop.Value }
                elseif ($default -is [double]) { $cfg[$key] = [double]$prop.Value }
                else { $cfg[$key] = [string]$prop.Value }
            }
            catch { Write-ClwLog "Ignoring invalid value for '$key' in config.json." 'WARN' }
        }
    }

    # clamp / normalise
    $cfg.refreshMinutes = [math]::Min(240, [math]::Max(1, [int]$cfg.refreshMinutes))
    $cfg.widgetWeeks = [math]::Min(52, [math]::Max(8, [int]$cfg.widgetWeeks))
    $cfg.staleAfterMinutes = [math]::Min(10080, [math]::Max(5, [int]$cfg.staleAfterMinutes))
    $cfg.scale = [math]::Min(3.0, [math]::Max(0.4, [double]$cfg.scale))
    $cfg.backgroundDim = [math]::Min(0.95, [math]::Max(0.0, [double]$cfg.backgroundDim))
    $cfg.cardOpacity = [math]::Min(1.0, [math]::Max(0.3, [double]$cfg.cardOpacity))
    $cfg.offsetXPercent = [math]::Min(50, [math]::Max(-50, [double]$cfg.offsetXPercent))
    $cfg.offsetYPercent = [math]::Min(50, [math]::Max(-50, [double]$cfg.offsetYPercent))
    if ($cfg.position -notin 'auto', 'left', 'center', 'right') { $cfg.position = 'auto' }
    if ($cfg.verticalAlign -notin 'top', 'center', 'bottom') { $cfg.verticalAlign = 'center' }
    if ($cfg.statsRange -notin 'all', '30d', '7d') { $cfg.statsRange = 'all' }
    if ($cfg.countMode -notin 'claude-code', 'deduplicated') { $cfg.countMode = 'claude-code' }
    if ($cfg.accent -notmatch '^#[0-9A-Fa-f]{6}$') { $cfg.accent = '#2A78D6' }
    $cfg
}

function Save-ClwDefaultConfig {
    param([string]$Path)
    if (-not $Path) { $Path = (Get-ClwPaths).Config }
    if (Test-Path -LiteralPath $Path) { return $false }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = (Get-ClwDefaultConfig) | ConvertTo-Json -Depth 5
    # ConvertTo-Json escapes non-ASCII as \uXXXX in 5.1, keeping the file ASCII-safe.
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    $true
}

function Get-ClwClaudeDir {
    param($Config)
    if ($Config -and $Config.claudeConfigDir) { return [string]$Config.claudeConfigDir }
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

# ------------------------------------------------------------- formatting

function Format-ClwNumber {
    param([double]$Value)
    $Value.ToString('N0', $script:ClwCulture)
}

function Format-ClwCompact {
    param([double]$Value)
    if ($Value -ge 1e9) { return ('{0}B' -f ([math]::Round($Value / 1e9, 1)).ToString('0.#', $script:ClwCulture)) }
    if ($Value -ge 1e6) { return ('{0}M' -f ([math]::Round($Value / 1e6, 1)).ToString('0.#', $script:ClwCulture)) }
    if ($Value -ge 1e3) { return ('{0}K' -f ([math]::Round($Value / 1e3, 1)).ToString('0.#', $script:ClwCulture)) }
    return ([math]::Round($Value)).ToString('0', $script:ClwCulture)
}

function Format-ClwHour {
    param([int]$Hour)
    $suffix = if ($Hour -lt 12) { 'AM' } else { 'PM' }
    $h = $Hour % 12
    if ($h -eq 0) { $h = 12 }
    '{0} {1}' -f $h, $suffix
}

function Format-ClwModelName {
    param([string]$Id)
    if (-not $Id) { return '-' }
    $m = [regex]::Match($Id, '^claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(?:\[.*\])?$')
    if ($m.Success) {
        $name = (Get-Culture).TextInfo.ToTitleCase($m.Groups[1].Value)
        $ver = $m.Groups[2].Value
        if ($m.Groups[3].Success) { $ver += '.' + $m.Groups[3].Value }
        return "$name $ver"
    }
    $m = [regex]::Match($Id, '^claude-(\d+)(?:-(\d{1,2}))?-(opus|sonnet|haiku)(?:-\d{8})?$')
    if ($m.Success) {
        $name = (Get-Culture).TextInfo.ToTitleCase($m.Groups[3].Value)
        $ver = $m.Groups[1].Value
        if ($m.Groups[2].Success) { $ver += '.' + $m.Groups[2].Value }
        return "$name $ver"
    }
    return (Get-Culture).TextInfo.ToTitleCase(($Id -replace '^claude-', '') -replace '-', ' ')
}

function Format-ClwReset {
    # Mirrors Claude's wording: "Resets in 2 hr 15 min" within a day, "Resets Mon 8:00 AM" beyond.
    param($ResetsAt, [datetimeoffset]$Now = [datetimeoffset]::Now)
    if ($null -eq $ResetsAt) { return '' }
    # Reset times arrive as e.g. 04:59:59.9Z; Claude shows them rounded to the minute (8:00 AM).
    $at = ([datetimeoffset]$ResetsAt).AddSeconds(30)
    $delta = $at - $Now
    if ($delta.TotalSeconds -le 0) { return 'Resets soon' }
    if ($delta.TotalHours -lt 24) {
        $total = [int][math]::Floor($delta.TotalMinutes)
        $h = [int][math]::Floor($total / 60)
        $mins = $total % 60
        if ($h -gt 0) { return "Resets in $h hr $mins min" }
        return "Resets in $([math]::Max(1, $mins)) min"
    }
    return 'Resets ' + $at.ToLocalTime().ToString('ddd h:mm tt', $script:ClwCulture)
}

function Format-ClwPlan {
    param([string]$SubscriptionType, [string]$RateLimitTier)
    $tier = if ($RateLimitTier) { $RateLimitTier.ToLowerInvariant() } else { '' }
    $m = [regex]::Match($tier, 'max_(\d+)x')
    if ($m.Success) { return 'Max ' + $m.Groups[1].Value + 'x' }
    if ($SubscriptionType) { return (Get-Culture).TextInfo.ToTitleCase($SubscriptionType.ToLowerInvariant()) }
    return ''
}

# Approximate token counts of well-known books, used for the "You've used ~Nx more tokens
# than <book>" line. Pride and Prejudice matches what Claude Code displays.
function Get-ClwBookTokens {
    @{
        'The Great Gatsby'      = 62000
        'Pride and Prejudice'   = 156000
        'Moby Dick'             = 280000
        'The Lord of the Rings' = 630000
        'War and Peace'         = 780000
        'The Bible'             = 1000000
        'Harry Potter (series)' = 1400000
    }
}
