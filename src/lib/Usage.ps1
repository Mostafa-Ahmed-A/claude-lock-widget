# Usage.ps1 - plan usage limits ("Session limit", "Weekly - all models", ...).
#
# Where the numbers come from (freshest wins):
#   1. "agent"      Claude pushes them after finishing a task: it calls the desktop app's get_usage
#                   tool and runs `ClaudeLockWidget.ps1 push-usage` (see Integration.ps1).
#   2. "statusline" Claude Code's status line receives rate_limits on every update (terminal / IDE).
#   3. "api"        Anthropic's usage endpoint with the login in ~/.claude/.credentials.json.
#                   Only used when there is no fresh live data. The Claude desktop app keeps its own
#                   login in memory, so this file is often stale; the widget never refreshes or
#                   rewrites it and never logs the token.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0

$script:ClwUsageUrl = 'https://api.anthropic.com/api/oauth/usage'
$script:ClwFreshMinutes = 60

# ------------------------------------------------------------ credentials

function Get-ClwCredentials {
    # Returns @{ Token; ExpiresAt; Plan; Source } or $null when no Claude Code login is found.
    param($Config)

    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return [pscustomobject]@{ Token = $env:CLAUDE_CODE_OAUTH_TOKEN; ExpiresAt = $null; Plan = ''; Source = 'CLAUDE_CODE_OAUTH_TOKEN' }
    }

    $file = Join-Path (Get-ClwClaudeDir $Config) '.credentials.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }

    try { $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }

    $oauth = $json.claudeAiOauth
    if ($null -eq $oauth -or -not $oauth.accessToken) { return $null }

    $expires = $null
    if ($oauth.expiresAt) {
        try { $expires = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$oauth.expiresAt) } catch { }
    }
    [pscustomobject]@{
        Token     = [string]$oauth.accessToken
        ExpiresAt = $expires
        Plan      = (Format-ClwPlan -SubscriptionType ([string]$oauth.subscriptionType) -RateLimitTier ([string]$oauth.rateLimitTier))
        Source    = $file
    }
}

# ------------------------------------------------------------- HTTP call

function Invoke-ClwUsageRequest {
    # Returns @{ Status = <http status or 0>; Body = <string or $null> }. Never throws.
    param([Parameter(Mandatory)][string]$Token)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }

    $headers = @{
        'Authorization'     = "Bearer $Token"
        'anthropic-beta'    = 'oauth-2025-04-20'
        'anthropic-version' = '2023-06-01'
        'Accept'            = 'application/json'
    }
    try {
        $r = Invoke-WebRequest -Uri $script:ClwUsageUrl -Headers $headers -UseBasicParsing -TimeoutSec 20 `
            -UserAgent "ClaudeLockWidget/$script:ClwVersion"
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
    }
    catch {
        $status = 0
        $resp = $null
        try { $resp = $_.Exception.Response } catch { }
        if ($resp) { try { $status = [int]$resp.StatusCode } catch { } }
        return [pscustomobject]@{ Status = $status; Body = $null }
    }
}

# --------------------------------------------------------------- parsing

function ConvertTo-ClwResetTime {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try {
        if ($Value -is [datetime]) { return [datetimeoffset]$Value }
        if ($Value -is [datetimeoffset]) { return $Value }
        if ($Value -is [double] -or $Value -is [int] -or $Value -is [long]) {
            # unix seconds (or milliseconds)
            $n = [double]$Value
            if ($n -gt 1e11) { return [datetimeoffset]::FromUnixTimeMilliseconds([int64]$n) }
            return [datetimeoffset]::FromUnixTimeSeconds([int64]$n)
        }
        return [datetimeoffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }
    catch { return $null }
}

function Get-ClwFirstProp {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value) { return $p.Value }
    }
    $null
}

function ConvertFrom-ClwUsageJson {
    # Turns the API response into @{ <key> = @{ Percent; ResetsAt } }. Understands the classic shape
    #   { "five_hour": { "utilization": 23.0, "resets_at": "..." }, "seven_day": {...} }
    # and the list shape: { "limits": [ { "kind"|"key"|"id": "...", "percent": 23, ... } ] }
    param([Parameter(Mandatory)][string]$Json)

    $root = $Json | ConvertFrom-Json
    $map = @{}

    foreach ($prop in $root.PSObject.Properties) {
        $v = $prop.Value
        if ($null -eq $v -or $v -isnot [pscustomobject]) { continue }
        $pct = Get-ClwFirstProp $v @('utilization', 'percent', 'used_percent')
        if ($null -eq $pct) { continue }
        $map[$prop.Name] = [pscustomobject]@{
            Percent  = [math]::Min(100.0, [math]::Max(0.0, [double]$pct))
            ResetsAt = ConvertTo-ClwResetTime (Get-ClwFirstProp $v @('resets_at', 'reset_at', 'resetsAt'))
        }
    }

    # newer shape: list entries are named by "kind" (session, weekly_all, ...); map them to the classic keys
    $aliases = @{ session = 'five_hour'; weekly_all = 'seven_day'; weekly_sonnet = 'seven_day_sonnet'; weekly_opus = 'seven_day_opus' }
    $limits = $root.PSObject.Properties['limits']
    if ($limits -and $limits.Value) {
        foreach ($item in @($limits.Value)) {
            $id = Get-ClwFirstProp $item @('key', 'id', 'name', 'type', 'window', 'kind')
            $pct = Get-ClwFirstProp $item @('percent', 'utilization', 'used_percent')
            if ($null -eq $id -or $null -eq $pct) { continue }
            $key = [string]$id
            if ($aliases.ContainsKey($key)) { $key = $aliases[$key] }
            if ($map.ContainsKey($key) -and $key -ne [string]$id) { continue }   # classic entry wins over its alias
            $map[$key] = [pscustomobject]@{
                Percent  = [math]::Min(100.0, [math]::Max(0.0, [double]$pct))
                ResetsAt = ConvertTo-ClwResetTime (Get-ClwFirstProp $item @('resets_at', 'reset_at', 'resetsAt'))
            }
        }
    }
    $map
}

function Get-ClwWindowKey {
    # Maps a human label from the desktop app's get_usage ("5-hour limit", "Weekly . all models",
    # "Weekly . Sonnet only") to the API-style keys the settings use.
    param([string]$Label)
    $l = $Label.ToLowerInvariant()
    if ($l -match 'sonnet') { return 'seven_day_sonnet' }
    if ($l -match 'opus') { return 'seven_day_opus' }
    if ($l -match '5.?hour|five.?hour|session') { return 'five_hour' }
    if ($l -match 'week') { return 'seven_day' }
    ($l -replace '[^a-z0-9]+', '_').Trim('_')
}

function ConvertFrom-ClwWindowsArg {
    # "label|percent|resetsAt;label|percent|resetsAt"  ->  @{ key = @{ Percent; ResetsAt } }
    param([string]$Windows)
    $map = @{}
    foreach ($part in ($Windows -split ';')) {
        if (-not $part.Trim()) { continue }
        $f = $part -split '\|'
        if ($f.Count -lt 2) { continue }
        $pct = 0.0
        if (-not [double]::TryParse(($f[1] -replace '%', '').Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pct)) { continue }
        $reset = $null
        if ($f.Count -ge 3) { $reset = ConvertTo-ClwResetTime ($f[2].Trim()) }
        $map[(Get-ClwWindowKey $f[0])] = [pscustomobject]@{
            Percent  = [math]::Min(100.0, [math]::Max(0.0, $pct))
            ResetsAt = $reset
        }
    }
    $map
}

# ------------------------------------------------------ live usage store

function Save-ClwLiveUsage {
    # Merges fresh values into cache\usage-live.json. -Source: agent | statusline | api
    param([hashtable]$Entries, [string]$Source, [string]$Plan = '')
    Initialize-ClwDirectories
    $paths = Get-ClwPaths
    $existing = Read-ClwLiveUsage
    $merged = @{}
    if ($existing) { foreach ($k in $existing.Map.Keys) { $merged[$k] = $existing.Map[$k] } }
    foreach ($k in $Entries.Keys) { $merged[$k] = $Entries[$k] }
    if (-not $Plan -and $existing) { $Plan = $existing.Plan }

    $out = @{}
    foreach ($k in $merged.Keys) {
        $out[$k] = @{
            percent  = $merged[$k].Percent
            resetsAt = if ($merged[$k].ResetsAt) { ([datetimeoffset]$merged[$k].ResetsAt).ToString('o') } else { $null }
        }
    }
    $doc = @{ source = $Source; capturedAt = [datetimeoffset]::Now.ToString('o'); plan = $Plan; entries = $out }
    $tmp = $paths.LiveUsage + '.tmp'
    $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $paths.LiveUsage -Force
}

function Read-ClwLiveUsage {
    $paths = Get-ClwPaths
    if (-not (Test-Path -LiteralPath $paths.LiveUsage)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $paths.LiveUsage -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($p in $doc.entries.PSObject.Properties) {
            $map[$p.Name] = [pscustomobject]@{
                Percent  = [double]$p.Value.percent
                ResetsAt = ConvertTo-ClwResetTime $p.Value.resetsAt
            }
        }
        [pscustomobject]@{
            Map        = $map
            Plan       = [string]$doc.plan
            Source     = [string]$doc.source
            CapturedAt = [datetimeoffset]::Parse([string]$doc.capturedAt, [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch { $null }
}

function Update-ClwForElapsedResets {
    # A usage window whose reset time has passed is back to 0% (until the next message starts a new one).
    param($Map, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $out = @{}
    foreach ($k in $Map.Keys) {
        $e = $Map[$k]
        if ($e.ResetsAt -and ([datetimeoffset]$e.ResetsAt) -lt $Now) {
            $out[$k] = [pscustomobject]@{ Percent = 0.0; ResetsAt = $null }
        }
        else { $out[$k] = $e }
    }
    $out
}

# --------------------------------------------------------- result object

function New-ClwUsageResult {
    param($Config, [string]$Status, [string]$Message, $Map, [string]$Plan, $FetchedAt, [bool]$Stale, [string]$Source = '')

    $bars = @()
    foreach ($b in @($Config.bars)) {
        $entry = $null
        if ($Map -and $Map.ContainsKey([string]$b.key)) { $entry = $Map[[string]$b.key] }
        $bars += [pscustomobject]@{
            Key      = [string]$b.key
            Label    = [string]$b.label
            Percent  = if ($entry) { $entry.Percent } else { $null }
            ResetsAt = if ($entry) { $entry.ResetsAt } else { $null }
        }
    }
    [pscustomobject]@{
        Status    = $Status      # ok | stale | none | login-expired | no-login | no-scope | rate-limited | offline | error
        Message   = $Message
        Plan      = $Plan
        FetchedAt = $FetchedAt
        Stale     = $Stale
        Source    = $Source
        Bars      = $bars
    }
}

function Get-ClwDemoUsage {
    # Sample numbers for README images, widget assets and "-Demo" previews.
    param($Config)
    $now = [datetimeoffset]::Now
    $daysToMonday = (8 - [int]$now.DayOfWeek) % 7
    if ($daysToMonday -eq 0) { $daysToMonday = 7 }
    $monday = [datetimeoffset]::new($now.Date.AddDays($daysToMonday).AddHours(8), $now.Offset)
    $map = @{
        'five_hour'        = [pscustomobject]@{ Percent = 37; ResetsAt = $now.AddMinutes(134) }
        'seven_day'        = [pscustomobject]@{ Percent = 62; ResetsAt = $monday }
        'seven_day_sonnet' = [pscustomobject]@{ Percent = 41; ResetsAt = $monday }
        'seven_day_opus'   = [pscustomobject]@{ Percent = 18; ResetsAt = $monday }
    }
    New-ClwUsageResult $Config 'ok' 'demo' $map 'Pro' $now $false 'demo'
}

# --------------------------------------------------------------- API path

function Invoke-ClwApiUsage {
    # Returns @{ Status; Message; Map; Plan }. Saves successful results as live usage (source "api").
    param($Config)

    $creds = Get-ClwCredentials -Config $Config
    if (-not $creds) { return [pscustomobject]@{ Status = 'no-login'; Message = 'No Claude Code login file found.'; Map = $null; Plan = '' } }
    if ($creds.ExpiresAt -and $creds.ExpiresAt -lt [datetimeoffset]::Now) {
        return [pscustomobject]@{ Status = 'login-expired'; Message = 'Claude Code login file has expired.'; Map = $null; Plan = $creds.Plan }
    }

    $resp = Invoke-ClwUsageRequest -Token $creds.Token
    switch ($resp.Status) {
        200 {
            try {
                $map = ConvertFrom-ClwUsageJson -Json $resp.Body
                if ($map.Count -eq 0) { return [pscustomobject]@{ Status = 'error'; Message = 'Usage response had an unexpected shape.'; Map = $null; Plan = $creds.Plan } }
                Save-ClwLiveUsage -Entries $map -Source 'api' -Plan $creds.Plan
                return [pscustomobject]@{ Status = 'ok'; Message = ''; Map = $map; Plan = $creds.Plan }
            }
            catch { return [pscustomobject]@{ Status = 'error'; Message = "Could not parse usage response: $($_.Exception.Message)"; Map = $null; Plan = $creds.Plan } }
        }
        401 { return [pscustomobject]@{ Status = 'login-expired'; Message = 'Claude Code login was rejected.'; Map = $null; Plan = $creds.Plan } }
        403 { return [pscustomobject]@{ Status = 'no-scope'; Message = 'This login cannot read usage.'; Map = $null; Plan = $creds.Plan } }
        429 { return [pscustomobject]@{ Status = 'rate-limited'; Message = 'Usage endpoint is rate limited.'; Map = $null; Plan = $creds.Plan } }
        0 { return [pscustomobject]@{ Status = 'offline'; Message = 'Could not reach api.anthropic.com.'; Map = $null; Plan = $creds.Plan } }
        default { return [pscustomobject]@{ Status = 'error'; Message = "Usage request failed (HTTP $($resp.Status))."; Map = $null; Plan = $creds.Plan } }
    }
}

function Get-ClwUsage {
    # -Fixture reads a local JSON file instead (demo, tests).
    param($Config, [string]$Fixture)

    $now = [datetimeoffset]::Now
    if ($Fixture) {
        $map = ConvertFrom-ClwUsageJson -Json (Get-Content -LiteralPath $Fixture -Raw -Encoding UTF8)
        return (New-ClwUsageResult $Config 'ok' 'fixture' $map 'Pro' $now $false 'fixture')
    }

    $live = Read-ClwLiveUsage
    $ageMin = if ($live) { ($now - $live.CapturedAt).TotalMinutes } else { [double]::MaxValue }

    # 1. fresh live data (agent push / status line / earlier API call)
    if ($live -and $ageMin -lt $script:ClwFreshMinutes) {
        $map = Update-ClwForElapsedResets $live.Map $now
        return (New-ClwUsageResult $Config 'ok' '' $map $live.Plan $live.CapturedAt $false $live.Source)
    }

    # 2. ask the API (works for CLI users whose login file is current)
    $apiNote = ''
    if ($Config.apiFallback) {
        $api = Invoke-ClwApiUsage -Config $Config
        if ($api.Status -eq 'ok') {
            return (New-ClwUsageResult $Config 'ok' '' (Update-ClwForElapsedResets $api.Map $now) $api.Plan $now $false 'api')
        }
        $apiNote = $api.Status
    }

    # 3. stale live data is still the best we have
    if ($live) {
        $map = Update-ClwForElapsedResets $live.Map $now
        $stale = ($ageMin -ge [double]$Config.staleAfterMinutes)
        $status = if ($stale) { 'stale' } else { 'ok' }
        $msg = if ($stale) { 'finish a Claude task to refresh' } else { '' }
        return (New-ClwUsageResult $Config $status $msg $map $live.Plan $live.CapturedAt $stale $live.Source)
    }

    # 4. nothing yet
    $msg = 'No usage yet - finish a Claude task (see setup guide)'
    if ($apiNote -eq 'no-login' -or $apiNote -eq 'login-expired') { $msg = 'No usage yet - finish a Claude task so it can report limits' }
    New-ClwUsageResult $Config 'none' $msg $null '' $null $true ''
}
