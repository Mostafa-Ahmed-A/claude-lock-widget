# LocalStats.ps1 - the "Overview" numbers (sessions, messages, tokens, active days, peak hour,
# favourite model, activity heatmap) computed from Claude Code's local transcripts.
# Metric definitions match Claude Code's /stats screen; see TranscriptScanner.cs.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0

function Initialize-ClwScanner {
    if ('ClaudeLockWidget.TranscriptScanner' -as [type]) { return }
    $source = Join-Path $PSScriptRoot 'TranscriptScanner.cs'
    Add-Type -Path $source -ReferencedAssemblies 'System.Web.Extensions'
}

function Get-ClwRawStats {
    param($Config)
    Initialize-ClwScanner
    $paths = Get-ClwPaths
    Initialize-ClwDirectories
    $projects = Join-Path (Get-ClwClaudeDir $Config) 'projects'
    $dedupe = ($Config.countMode -eq 'deduplicated')
    $json = [ClaudeLockWidget.TranscriptScanner]::Scan($projects, $paths.StatsIndex, $dedupe)
    $json | ConvertFrom-Json
}

function ConvertTo-ClwStats {
    # Pure function: raw scanner output -> the numbers shown in the UI. Easy to unit test.
    param(
        [Parameter(Mandatory)]$Raw,
        [ValidateSet('all', '30d', '7d')][string]$Range = 'all',
        [datetime]$Today = (Get-Date).Date
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $minDay = $null
    if ($Range -eq '30d') { $minDay = $Today.AddDays(-29).ToString('yyyy-MM-dd', $invariant) }
    if ($Range -eq '7d') { $minDay = $Today.AddDays(-6).ToString('yyyy-MM-dd', $invariant) }

    $messages = [int64]0
    $tokens = [int64]0
    $activeDays = 0
    $modelTokens = @{}
    $daily = @{}

    foreach ($p in $Raw.days.PSObject.Properties) {
        $day = $p.Name
        $d = $p.Value
        $daily[$day] = [int64]$d.m          # the heatmap always shows every day it has room for
        if ($minDay -and [string]::CompareOrdinal($day, $minDay) -lt 0) { continue }
        $messages += [int64]$d.m
        $tokens += [int64]$d.t
        if ([int64]$d.m -gt 0) { $activeDays++ }
        foreach ($m in $d.models.PSObject.Properties) {
            $modelTokens[$m.Name] = [int64]$modelTokens[$m.Name] + [int64]$m.Value
        }
    }

    $sessions = 0
    $startHours = @(0) * 24
    foreach ($s in @($Raw.sessions)) {
        if ($null -eq $s) { continue }
        if ($minDay -and [string]::CompareOrdinal([string]$s.d, $minDay) -lt 0) { continue }
        $sessions++
        $startHours[[int]$s.h]++
    }

    $peakHour = $null
    $best = 0
    for ($h = 0; $h -lt 24; $h++) {
        if ($startHours[$h] -gt $best) { $best = $startHours[$h]; $peakHour = $h }
    }

    $favorite = $null
    $bestTokens = [int64]0
    foreach ($k in $modelTokens.Keys) {
        if ($modelTokens[$k] -gt $bestTokens) { $bestTokens = $modelTokens[$k]; $favorite = $k }
    }

    [pscustomobject]@{
        Range         = $Range
        Sessions      = $sessions
        Messages      = $messages
        TotalTokens   = $tokens
        ActiveDays    = $activeDays
        PeakHour      = $peakHour
        FavoriteModel = $favorite
        Daily         = $daily
    }
}

function Get-ClwStats {
    param($Config)
    $raw = Get-ClwRawStats -Config $Config
    ConvertTo-ClwStats -Raw $raw -Range $Config.statsRange
}

function Get-ClwDemoStats {
    # Deterministic sample data for README screenshots and "-Demo" previews.
    param([datetime]$Today = (Get-Date).Date)
    $rnd = New-Object System.Random 42
    $daily = @{}
    for ($i = 0; $i -lt 180; $i++) {
        $date = $Today.AddDays(-$i)
        $roll = $rnd.NextDouble()
        if ($roll -lt 0.38) { continue }
        $weekend = $date.DayOfWeek -in 'Saturday', 'Sunday'
        $base = if ($weekend) { 30 } else { 120 }
        $key = $date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $daily[$key] = [int64]($base * (0.2 + $rnd.NextDouble() * 2.2))
    }
    [pscustomobject]@{
        Range         = 'all'
        Sessions      = 128
        Messages      = 24861
        TotalTokens   = [int64]3400000000
        ActiveDays    = $daily.Count
        PeakHour      = 14
        FavoriteModel = 'claude-sonnet-5-5'
        Daily         = $daily
    }
}
