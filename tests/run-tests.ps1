<#
.SYNOPSIS
    Dependency-free test runner for Claude Lock Widget (works on a stock Windows PowerShell 5.1).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $root 'src\lib'

# isolate all widget data in a throw-away folder
$testHome = Join-Path ([System.IO.Path]::GetTempPath()) ('clw-tests-' + [guid]::NewGuid().ToString('N'))
$env:CLW_HOME = $testHome
Remove-Item Env:\CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue

foreach ($f in 'Common', 'Usage', 'LocalStats', 'Render', 'Widget', 'LockScreen', 'Scheduler', 'Integration') { . (Join-Path $lib "$f.ps1") }
$script:ClwQuiet = $true

# ---------------------------------------------------------------- mini framework
$script:passed = 0
$script:failed = New-Object System.Collections.Generic.List[string]

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if ($Actual -ne $Expected) { throw "Expected <$Expected> but got <$Actual>. $Message" }
}
function Assert-True {
    param($Condition, [string]$Message = 'condition was false')
    if (-not $Condition) { throw $Message }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:failed.Add($Name); Write-Host "  FAIL  $Name`n        $($_.Exception.Message)" -ForegroundColor Red }
}
function New-TempDir {
    $d = Join-Path $testHome ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $d -Force)
    $d
}
function New-TestConfig {
    param([string]$ClaudeDir = (New-TempDir))
    $c = Get-ClwConfig -Path (Join-Path $testHome 'nope.json')
    $c.claudeConfigDir = $ClaudeDir
    $c
}
function Reset-LiveUsage {
    $p = (Get-ClwPaths).LiveUsage
    if (Test-Path -LiteralPath $p) { [System.IO.File]::Delete($p) }
}
function Read-Fixture([string]$Name) { Get-Content (Join-Path $PSScriptRoot "fixtures\$Name") -Raw -Encoding UTF8 }
$dot = [string][char]0x00B7

Write-Host "`nFormatting" -ForegroundColor Cyan
Test-Case 'compact numbers' {
    Assert-Equal (Format-ClwCompact 1159536252) '1.2B'
    Assert-Equal (Format-ClwCompact 345600000) '345.6M'
    Assert-Equal (Format-ClwCompact 12340) '12.3K'
    Assert-Equal (Format-ClwCompact 999) '999'
}
Test-Case 'thousands separator' { Assert-Equal (Format-ClwNumber 4019) '4,019' }
Test-Case 'hour labels' {
    Assert-Equal (Format-ClwHour 0) '12 AM'; Assert-Equal (Format-ClwHour 9) '9 AM'
    Assert-Equal (Format-ClwHour 12) '12 PM'; Assert-Equal (Format-ClwHour 23) '11 PM'
}
Test-Case 'model display names' {
    Assert-Equal (Format-ClwModelName 'claude-sonnet-5-5') 'Sonnet 5.5'
    Assert-Equal (Format-ClwModelName 'claude-opus-4-1-20250805') 'Opus 4.1'
    Assert-Equal (Format-ClwModelName 'claude-sonnet-4-20250514') 'Sonnet 4'
    Assert-Equal (Format-ClwModelName 'claude-3-5-sonnet-20241022') 'Sonnet 3.5'
    Assert-Equal (Format-ClwModelName $null) '-'
}
Test-Case 'plan names' {
    Assert-Equal (Format-ClwPlan 'max' 'default_claude_max_5x') 'Max 5x'
    Assert-Equal (Format-ClwPlan 'pro' '') 'Pro'
}
Test-Case 'reset text: within a day vs later, rounded to the minute like Claude' {
    $now = [datetimeoffset]::Now
    Assert-Equal (Format-ClwReset $now.AddMinutes(135) $now) 'Resets in 2 hr 15 min'
    Assert-Equal (Format-ClwReset $now.AddMinutes(20) $now) 'Resets in 20 min'
    Assert-Equal (Format-ClwReset $now.AddMinutes(60) $now) 'Resets in 1 hr 0 min'
    Assert-True ((Format-ClwReset $now.AddDays(3) $now) -match '^Resets \w{3} \d{1,2}:\d{2} (AM|PM)$') 'weekday format'
    Assert-Equal (Format-ClwReset $null $now) ''
    # an API timestamp of 04:59:59.9Z must read as 05:00, not 04:59
    $at = [datetimeoffset]::Parse('2099-01-05T04:59:59.903Z', [cultureinfo]::InvariantCulture)
    $expected = 'Resets ' + $at.AddSeconds(30).ToLocalTime().ToString('ddd h:mm tt', [cultureinfo]::GetCultureInfo('en-US'))
    Assert-Equal (Format-ClwReset $at $now) $expected
    Assert-True ($expected -match ':00 (AM|PM)$' -or $at.ToLocalTime().Minute -ne 59) 'rounded to a clean minute'
}

Write-Host "`nConfiguration" -ForegroundColor Cyan
Test-Case 'defaults load when no file exists' {
    $cfg = Get-ClwConfig -Path (Join-Path $testHome 'nope.json')
    Assert-Equal $cfg.refreshMinutes 10; Assert-Equal @($cfg.bars).Count 2; Assert-Equal $cfg.bars[0].key 'five_hour'
    Assert-Equal $cfg.widgetWeeks 30; Assert-True (-not $cfg.apiFallback) 'API fallback (reads the login file) is opt-in'
}
Test-Case 'user values override, bad values are clamped or ignored' {
    $p = Join-Path (New-TempDir) 'config.json'
    '{ "refreshMinutes": 9999, "scale": 0.01, "widgetWeeks": 3, "position": "sideways", "statsRange": "30d", "accent": "red", "apiFallback": false, "bars": [ { "key": "seven_day_sonnet", "label": "Sonnet" } ] }' | Set-Content $p
    $cfg = Get-ClwConfig -Path $p
    Assert-Equal $cfg.refreshMinutes 240; Assert-Equal $cfg.scale 0.4; Assert-Equal $cfg.widgetWeeks 8; Assert-Equal $cfg.position 'auto'
    Assert-Equal $cfg.statsRange '30d'; Assert-Equal $cfg.accent '#2A78D6'; Assert-True (-not $cfg.apiFallback) 'apiFallback false'
    Assert-Equal @($cfg.bars).Count 1; Assert-Equal $cfg.bars[0].label 'Sonnet'
}
Test-Case 'invalid JSON falls back to defaults' {
    $p = Join-Path (New-TempDir) 'config.json'
    '{ not json' | Set-Content $p
    Assert-Equal (Get-ClwConfig -Path $p).refreshMinutes 10
}
Test-Case 'default config file is written once' {
    $p = Join-Path (New-TempDir) 'config.json'
    Assert-True (Save-ClwDefaultConfig -Path $p) 'first write'
    Assert-True (-not (Save-ClwDefaultConfig -Path $p)) 'must not overwrite'
    Assert-Equal (Get-ClwConfig -Path $p).refreshMinutes 10
}

Write-Host "`nUsage parsing" -ForegroundColor Cyan
Test-Case 'classic API response shape' {
    $map = ConvertFrom-ClwUsageJson -Json (Read-Fixture 'usage-sample.json')
    Assert-Equal $map['five_hour'].Percent 37; Assert-Equal $map['seven_day'].Percent 23
    Assert-True ($null -ne $map['seven_day'].ResetsAt) 'reset parsed'
    Assert-True ($null -eq $map['seven_day_opus'].ResetsAt) 'null reset stays null'
    Assert-True (-not $map.ContainsKey('seven_day_oauth_apps')) 'null buckets are skipped'
}
Test-Case 'newer list shape: kinds are aliased, classic entries win' {
    $map = ConvertFrom-ClwUsageJson -Json (Read-Fixture 'usage-new-shape.json')
    Assert-Equal $map['seven_day'].Percent 2 'classic entry wins over limits[weekly_all]'
    Assert-Equal $map['seven_day_sonnet'].Percent 7 'weekly_sonnet -> seven_day_sonnet'
    Assert-Equal $map['five_hour'].Percent 0
}
Test-Case 'list shape alone and clamping' {
    $map = ConvertFrom-ClwUsageJson -Json '{ "limits": [ { "kind": "session", "percent": 140 }, { "id": "seven_day", "percent": -5 } ] }'
    Assert-Equal $map['five_hour'].Percent 100; Assert-Equal $map['seven_day'].Percent 0
}
Test-Case 'window labels from the desktop app map to the usual keys' {
    Assert-Equal (Get-ClwWindowKey '5-hour limit') 'five_hour'
    Assert-Equal (Get-ClwWindowKey "Weekly $dot all models") 'seven_day'
    Assert-Equal (Get-ClwWindowKey "Weekly $dot Sonnet only") 'seven_day_sonnet'
    Assert-Equal (Get-ClwWindowKey 'Weekly - Opus only') 'seven_day_opus'
    Assert-Equal (Get-ClwWindowKey 'Session limit') 'five_hour'
}
Test-Case 'push-usage argument parsing' {
    $arg = "5-hour limit|33|2026-10-10T09:49:59.903Z;Weekly $dot all models|28%|2026-10-12T04:59:59.903Z;;broken;x|notanumber"
    $m = ConvertFrom-ClwWindowsArg $arg
    Assert-Equal $m.Count 2
    Assert-Equal $m['five_hour'].Percent 33; Assert-Equal $m['seven_day'].Percent 28
    Assert-Equal $m['seven_day'].ResetsAt.UtcDateTime.ToString('yyyy-MM-dd HH:mm') '2026-10-12 04:59'
    Assert-Equal (ConvertFrom-ClwWindowsArg '').Count 0
}
Test-Case 'bars follow the configured order and unknown keys stay empty' {
    $cfg = Get-ClwConfig -Path (Join-Path $testHome 'nope.json')
    $cfg.bars = @([ordered]@{ key = 'seven_day'; label = 'W' }, [ordered]@{ key = 'missing'; label = 'M' })
    $map = ConvertFrom-ClwUsageJson -Json (Read-Fixture 'usage-sample.json')
    $r = New-ClwUsageResult $cfg 'ok' '' $map 'Pro' ([datetimeoffset]::Now) $false
    Assert-Equal $r.Bars[0].Percent 23; Assert-True ($null -eq $r.Bars[1].Percent) 'unknown key is null'
}
Test-Case 'status line input (Claude Code rate_limits)' {
    $json = '{ "model": { "display_name": "Sonnet" }, "rate_limits": { "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 }, "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 } } }'
    $r = ConvertFrom-ClwStatusLineJson $json
    Assert-Equal $r.Entries['five_hour'].Percent 23.5; Assert-Equal $r.Entries['seven_day'].Percent 41.2
    Assert-Equal $r.Entries['five_hour'].ResetsAt.ToUnixTimeSeconds() 1738425600
    Assert-Equal $r.Text '5h 24% | 7d 41%'
    Assert-Equal (ConvertFrom-ClwStatusLineJson '{ "model": {} }').Entries.Count 0
    Assert-Equal (ConvertFrom-ClwStatusLineJson 'garbage').Text ''
    Assert-Equal (ConvertFrom-ClwStatusLineJson '{ "rate_limits": { "seven_day": { "used_percentage": 5 } } }').Text '7d 5%'
}

Write-Host "`nUsage sources" -ForegroundColor Cyan
Test-Case 'live data: saved, read back, merged per key' {
    Reset-LiveUsage
    $future = [datetimeoffset]::Now.AddHours(3)
    Save-ClwLiveUsage -Source 'agent' -Plan 'Pro' -Entries @{ five_hour = [pscustomobject]@{ Percent = 33; ResetsAt = $future } }
    Save-ClwLiveUsage -Source 'agent' -Entries @{ seven_day = [pscustomobject]@{ Percent = 28; ResetsAt = $future.AddDays(2) } }
    $live = Read-ClwLiveUsage
    Assert-Equal $live.Map.Count 2; Assert-Equal $live.Plan 'Pro' 'plan kept across merges'; Assert-Equal $live.Source 'agent'
    Assert-Equal $live.Map['five_hour'].Percent 33; Assert-Equal $live.Map['seven_day'].Percent 28
}
Test-Case 'fresh live data wins and is reported ok' {
    Reset-LiveUsage
    $cfg = New-TestConfig
    Save-ClwLiveUsage -Source 'agent' -Plan 'Pro' -Entries @{ five_hour = [pscustomobject]@{ Percent = 33; ResetsAt = [datetimeoffset]::Now.AddHours(4) } }
    $u = Get-ClwUsage -Config $cfg
    Assert-Equal $u.Status 'ok'; Assert-Equal $u.Source 'agent'; Assert-Equal $u.Bars[0].Percent 33; Assert-Equal $u.Plan 'Pro'; Assert-True (-not $u.Stale) 'fresh'
}
Test-Case 'a window whose reset time has passed is shown as 0%' {
    Reset-LiveUsage
    $cfg = New-TestConfig
    Save-ClwLiveUsage -Source 'agent' -Entries @{ five_hour = [pscustomobject]@{ Percent = 80; ResetsAt = [datetimeoffset]::Now.AddMinutes(-5) }; seven_day = [pscustomobject]@{ Percent = 28; ResetsAt = [datetimeoffset]::Now.AddDays(1) } }
    $u = Get-ClwUsage -Config $cfg
    Assert-Equal $u.Bars[0].Percent 0; Assert-True ($null -eq $u.Bars[0].ResetsAt) 'no reset time while idle'; Assert-Equal $u.Bars[1].Percent 28
}

# fake Claude Code home with a credentials file (all values are made up)
$fakeClaude = New-TempDir
$expiryMs = [int64]([datetimeoffset]::UtcNow.AddHours(5).ToUnixTimeMilliseconds())
(@{ claudeAiOauth = @{ accessToken = 'test-token-not-real'; refreshToken = 'x'; expiresAt = $expiryMs; subscriptionType = 'max'; rateLimitTier = 'default_claude_max_5x' } } | ConvertTo-Json) |
    Set-Content (Join-Path $fakeClaude '.credentials.json')
$cfgFake = New-TestConfig $fakeClaude; $cfgFake.apiFallback = $true

# shadow the HTTP call so no test ever touches the network
$script:fakeResponse = $null
$script:httpCalls = 0
function Invoke-ClwUsageRequest { param([string]$Token) $script:httpCalls++; $script:fakeResponse }

Test-Case 'credentials are read from the Claude folder' {
    $c = Get-ClwCredentials -Config $cfgFake
    Assert-Equal $c.Token 'test-token-not-real'; Assert-Equal $c.Plan 'Max 5x'; Assert-True ($c.ExpiresAt -gt [datetimeoffset]::Now) 'not expired'
}
Test-Case 'no live data -> the API is asked, and its answer becomes live data' {
    Reset-LiveUsage; $script:httpCalls = 0
    $script:fakeResponse = [pscustomobject]@{ Status = 200; Body = (Read-Fixture 'usage-sample.json') }
    $u = Get-ClwUsage -Config $cfgFake
    Assert-Equal $u.Status 'ok'; Assert-Equal $u.Source 'api'; Assert-Equal $u.Bars[1].Percent 23; Assert-Equal $u.Plan 'Max 5x'
    Assert-Equal $script:httpCalls 1
    Assert-Equal (Read-ClwLiveUsage).Source 'api'
}
Test-Case 'fresh live data means no network call at all' {
    Reset-LiveUsage; $script:httpCalls = 0
    Save-ClwLiveUsage -Source 'agent' -Entries @{ five_hour = [pscustomobject]@{ Percent = 10; ResetsAt = [datetimeoffset]::Now.AddHours(2) } }
    [void](Get-ClwUsage -Config $cfgFake)
    Assert-Equal $script:httpCalls 0
}
foreach ($code in 401, 403, 429, 0, 500) {
    $c = $code
    Test-Case "HTTP $c with only stale live data -> stale values kept, flagged" {
        Reset-LiveUsage
        Save-ClwLiveUsage -Source 'agent' -Entries @{ five_hour = [pscustomobject]@{ Percent = 41; ResetsAt = [datetimeoffset]::Now.AddHours(2) } }
        $p = (Get-ClwPaths).LiveUsage
        $doc = Get-Content $p -Raw | ConvertFrom-Json
        $doc.capturedAt = [datetimeoffset]::Now.AddHours(-8).ToString('o')
        $doc | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding UTF8
        $script:fakeResponse = [pscustomobject]@{ Status = $c; Body = $null }
        $u = Get-ClwUsage -Config $cfgFake
        Assert-Equal $u.Status 'stale'; Assert-True $u.Stale 'stale flag'; Assert-Equal $u.Bars[0].Percent 41 'old value still shown'
    }
}
Test-Case 'nothing known at all -> status none, bars empty' {
    Reset-LiveUsage
    $script:fakeResponse = [pscustomobject]@{ Status = 401; Body = $null }
    $u = Get-ClwUsage -Config $cfgFake
    Assert-Equal $u.Status 'none'; Assert-True ($null -eq $u.Bars[0].Percent) 'no percent'; Assert-True ($u.Message.Length -gt 10) 'explains what to do'
}
Test-Case 'apiFallback=false never calls the API' {
    Reset-LiveUsage; $script:httpCalls = 0
    $cfg = New-TestConfig $fakeClaude; $cfg.apiFallback = $false
    Assert-Equal (Get-ClwUsage -Config $cfg).Status 'none'
    Assert-Equal $script:httpCalls 0
}
Test-Case 'garbage 200 body does not crash' {
    Reset-LiveUsage
    $script:fakeResponse = [pscustomobject]@{ Status = 200; Body = 'not json' }
    Assert-Equal (Get-ClwUsage -Config $cfgFake).Status 'none'
}
Test-Case 'expired login file skips the request' {
    Reset-LiveUsage; $script:httpCalls = 0
    $dir = New-TempDir
    (@{ claudeAiOauth = @{ accessToken = 'old'; expiresAt = [int64]([datetimeoffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()) } } | ConvertTo-Json) | Set-Content (Join-Path $dir '.credentials.json')
    $c = New-TestConfig $dir; $c.apiFallback = $true
    Assert-Equal (Get-ClwUsage -Config $c).Status 'none'
    Assert-Equal $script:httpCalls 0
}
Test-Case 'fixture shortcut' {
    $u = Get-ClwUsage -Config (New-TestConfig) -Fixture (Join-Path $PSScriptRoot 'fixtures\usage-sample.json')
    Assert-Equal $u.Status 'ok'; Assert-Equal $u.Bars[0].Percent 37
}

Write-Host "`nClaude Code integration" -ForegroundColor Cyan
function New-IntegrationConfig { param([string]$SettingsJson, [string]$ClaudeMd)
    $dir = New-TempDir
    if ($null -ne $SettingsJson) { [System.IO.File]::WriteAllText((Join-Path $dir 'settings.json'), $SettingsJson, (New-Object System.Text.UTF8Encoding($false))) }
    if ($null -ne $ClaudeMd) { [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), $ClaudeMd, (New-Object System.Text.UTF8Encoding($false))) }
    [pscustomobject]@{ Dir = $dir; Config = (New-TestConfig $dir); Settings = (Join-Path $dir 'settings.json'); Md = (Join-Path $dir 'CLAUDE.md') }
}
function ConvertTo-Canonical($json) { ($json | ConvertFrom-Json) | ConvertTo-Json -Depth 20 -Compress }

$mine = @'
{
  "model": "sonnet",
  "enabledPlugins": { "a@b": true },
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ],
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "check.sh" } ] } ]
  }
}
'@
Test-Case 'Stop hook is added next to existing hooks, async, idempotent, and backed up' {
    $t = New-IntegrationConfig $mine $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false)
    $s = Get-Content $t.Settings -Raw | ConvertFrom-Json
    Assert-Equal @($s.hooks.Stop).Count 2 'existing group kept, ours appended'
    Assert-Equal $s.hooks.Stop[0].hooks[0].command 'echo mine'
    $ours = $s.hooks.Stop[1].hooks[0]
    Assert-True ($ours.async -eq $true) 'async so Claude never waits'
    Assert-True ($ours.command -match 'ClaudeLockWidget\.ps1" hook$') 'command ends with the hook verb'
    Assert-True ($ours.command -notmatch '\\') 'forward slashes (Git Bash safe)'
    Assert-Equal $s.hooks.PreToolUse[0].hooks[0].command 'check.sh'; Assert-Equal $s.model 'sonnet'
    Assert-True (@(Get-ChildItem $t.Dir -Filter 'settings.json.clw-backup-*').Count -ge 1) 'backup written'
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false)
    Assert-Equal @((Get-Content $t.Settings -Raw | ConvertFrom-Json).hooks.Stop).Count 2 'second install changes nothing'
}
Test-Case 'uninstall restores the original settings exactly' {
    $t = New-IntegrationConfig $mine $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false)
    [void](Uninstall-ClwIntegration -Config $t.Config)
    Assert-Equal (ConvertTo-Canonical (Get-Content $t.Settings -Raw)) (ConvertTo-Canonical $mine)
}
Test-Case 'settings without a hooks section: created, then removed again' {
    $plain = '{ "model": "opus", "theme": "dark" }'
    $t = New-IntegrationConfig $plain $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false)
    Assert-True (Test-ClwHookInstalled (Read-ClwSettings $t.Settings)) 'installed'
    [void](Uninstall-ClwIntegration -Config $t.Config)
    Assert-Equal (ConvertTo-Canonical (Get-Content $t.Settings -Raw)) (ConvertTo-Canonical $plain)
}
Test-Case 'no settings.json yet: created' {
    $t = New-IntegrationConfig $null $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false)
    Assert-True (Test-ClwHookInstalled (Read-ClwSettings $t.Settings)) 'installed'
}
Test-Case 'unreadable settings.json is never overwritten' {
    $t = New-IntegrationConfig '{ this is not json' $null
    $threw = $false
    try { [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false) } catch { $threw = $true }
    Assert-True $threw 'refuses to continue'
    Assert-Equal ([System.IO.File]::ReadAllText($t.Settings)) '{ this is not json'
}
Test-Case 'an existing status line is left alone; ours is added only when free' {
    $t = New-IntegrationConfig '{ "statusLine": { "type": "command", "command": "my-line.sh" } }' $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false -StatusLine $true)
    Assert-Equal (Get-Content $t.Settings -Raw | ConvertFrom-Json).statusLine.command 'my-line.sh'
    $t2 = New-IntegrationConfig '{ "model": "sonnet" }' $null
    [void](Install-ClwIntegration -Config $t2.Config -ClaudeMd $false -StatusLine $true)
    Assert-True (Test-ClwStatusLineOurs (Read-ClwSettings $t2.Settings)) 'added'
    [void](Uninstall-ClwIntegration -Config $t2.Config)
    Assert-True ($null -eq (Get-Content $t2.Settings -Raw | ConvertFrom-Json).PSObject.Properties['statusLine']) 'removed again'
}
Test-Case 'special characters survive the JSON round trip readably' {
    $t = New-IntegrationConfig '{ "note": "a & b <c> it''s", "x": 1 }' $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $false)
    $text = [System.IO.File]::ReadAllText($t.Settings)
    Assert-True ($text.Contains('a & b <c> it''s')) 'no \u0026-style escapes'
}
Test-Case 'CLAUDE.md block: appended, replaced not duplicated, removed cleanly' {
    $original = "# My notes`n`nBe concise.`n"
    $t = New-IntegrationConfig $null $original
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $true)
    $text = [System.IO.File]::ReadAllText($t.Md)
    Assert-True ($text.StartsWith($original)) 'user content untouched and first'
    Assert-True ($text.Contains('get_usage') -and $text.Contains('push-usage')) 'instructions present'
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $true)
    Assert-Equal ([regex]::Matches([System.IO.File]::ReadAllText($t.Md), 'BEGIN ClaudeLockWidget').Count) 1 'no duplicate block'
    [void](Uninstall-ClwIntegration -Config $t.Config)
    Assert-Equal ([System.IO.File]::ReadAllText($t.Md)) $original
}
Test-Case 'CLAUDE.md that only held our block is deleted on uninstall' {
    $t = New-IntegrationConfig $null $null
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $true)
    Assert-True (Test-Path $t.Md) 'created'
    [void](Uninstall-ClwIntegration -Config $t.Config)
    Assert-True (-not (Test-Path $t.Md)) 'removed'
}
Test-Case 'integration status reflects what is installed' {
    $t = New-IntegrationConfig '{ "model": "x" }' $null
    $s0 = Get-ClwIntegrationStatus -Config $t.Config
    Assert-True (-not $s0.StopHook -and -not $s0.ClaudeMd) 'nothing yet'
    [void](Install-ClwIntegration -Config $t.Config -ClaudeMd $true)
    $s1 = Get-ClwIntegrationStatus -Config $t.Config
    Assert-True ($s1.StopHook -and $s1.ClaudeMd) 'both installed'
}

Write-Host "`nTranscript scanner" -ForegroundColor Cyan
$projects = New-TempDir
$sessionA = Join-Path $projects 'proj-a'; [void](New-Item -ItemType Directory -Path $sessionA)
function New-Line {
    param([string]$Type, [string]$Ts, [string]$Model = '', [int]$In = 0, [int]$Out = 0, [int]$CacheW = 0, [int]$CacheR = 0, [string]$Id = '')
    if ($Type -eq 'user') { return ('{{"type":"user","timestamp":"{0}","sessionId":"s","message":{{"role":"user","content":"hi"}}}}' -f $Ts) }
    '{{"type":"assistant","timestamp":"{0}","requestId":"r-{6}","message":{{"id":"{6}","model":"{1}","usage":{{"input_tokens":{2},"output_tokens":{3},"cache_creation_input_tokens":{4},"cache_read_input_tokens":{5}}}}}}}' -f $Ts, $Model, $In, $Out, $CacheW, $CacheR, $Id
}
$t1 = '2026-03-02T12:00:00.000Z'; $t2 = '2026-03-02T12:00:05.000Z'; $t3 = '2026-03-04T12:00:00.000Z'
$fileA = Join-Path $sessionA 'a.jsonl'
@(
    (New-Line user $t1),
    (New-Line assistant $t2 'claude-sonnet-5-5' 10 20 30 40 'm1'),
    (New-Line assistant $t2 'claude-sonnet-5-5' 10 20 30 40 'm1'),     # duplicate content block of the same API message
    '{"type":"summary","summary":"ignored"}',
    'not even json',
    (New-Line user $t3),
    (New-Line assistant $t3 'claude-opus-5-5' 1 2 3 4 'm2')
) | Set-Content $fileA -Encoding UTF8
$fileB = Join-Path $projects 'b.jsonl'
@((New-Line user '2026-03-04T13:00:00.000Z')) | Set-Content $fileB -Encoding UTF8

function Get-LocalDay { param([string]$Utc) [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::Parse($Utc, [cultureinfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal'), [TimeZoneInfo]::Local).ToString('yyyy-MM-dd') }
Initialize-ClwScanner
$indexPath = Join-Path $testHome 'idx.json'

Test-Case 'counts match Claude Code semantics (raw mode)' {
    $raw = [ClaudeLockWidget.TranscriptScanner]::Scan($projects, $indexPath, $false) | ConvertFrom-Json
    Assert-Equal $raw.files 2; Assert-Equal $raw.scanned 2; Assert-Equal @($raw.sessions).Count 2
    $stats = ConvertTo-ClwStats -Raw $raw
    Assert-Equal $stats.Messages 6 'user+assistant lines, duplicates included'
    Assert-Equal $stats.TotalTokens ((10 + 20 + 30 + 40) * 2 + (1 + 2 + 3 + 4)) 'all token kinds, duplicates included'
    Assert-Equal $stats.Sessions 2
    Assert-Equal $stats.FavoriteModel 'claude-sonnet-5-5'
    Assert-True ($stats.ActiveDays -ge 2) 'active days'
    Assert-Equal $stats.Daily[(Get-LocalDay $t1)] ([int64]($stats.Daily[(Get-LocalDay $t1)])) 'daily map filled'
}
Test-Case 'second scan is served from the cache' {
    $raw = [ClaudeLockWidget.TranscriptScanner]::Scan($projects, $indexPath, $false) | ConvertFrom-Json
    Assert-Equal $raw.scanned 0 'nothing changed'
}
Test-Case 'appending to a transcript rescans only that file' {
    Add-Content $fileA (New-Line user '2026-03-05T12:00:00.000Z') -Encoding UTF8
    $raw = [ClaudeLockWidget.TranscriptScanner]::Scan($projects, $indexPath, $false) | ConvertFrom-Json
    Assert-Equal $raw.scanned 1
    Assert-Equal (ConvertTo-ClwStats -Raw $raw).Messages 7
}
Test-Case 'deduplicated mode counts each API message once' {
    $raw = [ClaudeLockWidget.TranscriptScanner]::Scan($projects, $indexPath, $true) | ConvertFrom-Json
    Assert-Equal $raw.scanned 2 'switching mode invalidates the cache'
    $stats = ConvertTo-ClwStats -Raw $raw
    Assert-Equal $stats.Messages 6 'one duplicate removed (7 lines - 1)'
    Assert-Equal $stats.TotalTokens ((10 + 20 + 30 + 40) + (1 + 2 + 3 + 4))
}
Test-Case 'range filters (30d / 7d) use local calendar days' {
    $raw = [ClaudeLockWidget.TranscriptScanner]::Scan($projects, $indexPath, $true) | ConvertFrom-Json
    $today = [datetime]'2026-03-05'
    Assert-Equal (ConvertTo-ClwStats -Raw $raw -Range 'all' -Today $today).Messages 6
    Assert-Equal (ConvertTo-ClwStats -Raw $raw -Range '7d' -Today $today).Messages 6
    Assert-Equal (ConvertTo-ClwStats -Raw $raw -Range '7d' -Today ([datetime]'2026-03-20')).Messages 0 'everything is older than 7 days'
    Assert-Equal (ConvertTo-ClwStats -Raw $raw -Range '30d' -Today ([datetime]'2026-03-20')).Messages 6
}
Test-Case 'missing or empty folders are fine' {
    $raw = [ClaudeLockWidget.TranscriptScanner]::Scan((Join-Path $testHome 'does-not-exist'), (Join-Path $testHome 'idx2.json'), $false) | ConvertFrom-Json
    Assert-Equal $raw.files 0
    $stats = ConvertTo-ClwStats -Raw $raw
    Assert-Equal $stats.Messages 0; Assert-True ($null -eq $stats.PeakHour) 'no peak hour'
}

Write-Host "`nCalendar heatmap" -ForegroundColor Cyan
Test-Case 'grid ends with the current week and has no future days' {
    $today = [datetime]'2026-10-10'   # a Saturday
    $cells = Get-ClwHeatCells -Daily @{ '2026-10-10' = 5; '2026-10-08' = 20 } -Cols 26 -Today $today
    $last = $cells | Where-Object { $_.Col -eq 25 }
    Assert-Equal @($last).Count 7 'Saturday is the last row, so the final week is complete'
    Assert-Equal ($cells | Where-Object { $_.Col -eq 25 -and $_.Row -eq 4 }).Level 3 'Thursday 8th is the busiest day'
    Assert-Equal ($cells | Where-Object { $_.Col -eq 25 -and $_.Row -eq 6 }).Level 1 'today, light activity'
    $wed = [datetime]'2026-10-07'
    $cells2 = Get-ClwHeatCells -Daily @{} -Cols 26 -Today $wed
    Assert-Equal @($cells2 | Where-Object { $_.Col -eq 25 }).Count 4 'Sun..Wed only'
}

Write-Host "`nWidget image and state" -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
function Read-Pixel { param([string]$Path, [int]$X, [int]$Y) $b = New-Object System.Drawing.Bitmap $Path; try { $b.GetPixel($X, $Y) } finally { $b.Dispose() } }
$cfgR = Get-ClwConfig -Path (Join-Path $testHome 'nope.json')
$usageDemo = New-ClwUsageResult $cfgR 'ok' '' (ConvertFrom-ClwUsageJson -Json (Read-Fixture 'usage-sample.json')) 'Pro' ([datetimeoffset]::Now) $false 'agent'

Test-Case 'glass tile: fills a ~2.1:1 lock screen tile with a transparent background and light text' {
    $out = Join-Path (New-TempDir) 'tile.png'
    [void](New-ClwWidgetImage -Config $cfgR -Stats (Get-ClwDemoStats) -Usage $usageDemo -OutPath $out -Style glass)
    $bmp = New-Object System.Drawing.Bitmap $out
    try {
        Assert-Equal $bmp.Width 640
        $aspect = $bmp.Width / $bmp.Height
        Assert-True ($aspect -ge 2.0 -and $aspect -le 2.3) "aspect $aspect (the lock screen tile is about 2.1:1)"
        Assert-Equal $bmp.GetPixel(0, 0).A 0 'corner is transparent'
        Assert-Equal $bmp.GetPixel(8, [int]($bmp.Height / 2)).A 0 'no inner card: the margin is transparent'
        # something light must have been drawn (text / empty calendar cells are white with alpha)
        $light = 0
        for ($x = 16; $x -lt 120; $x += 2) { for ($y = 10; $y -lt 44; $y += 2) { $px = $bmp.GetPixel($x, $y); if ($px.A -gt 120 -and $px.R -gt 200 -and $px.G -gt 200) { $light++ } } }
        Assert-True ($light -gt 20) "header text is light ($light light pixels)"
    }
    finally { $bmp.Dispose() }
}
Test-Case 'card tile: opaque dark rounded card for light-theme hosts' {
    $out = Join-Path (New-TempDir) 'card.png'
    [void](New-ClwWidgetImage -Config $cfgR -Stats (Get-ClwDemoStats) -Usage $usageDemo -OutPath $out -Style card)
    $bmp = New-Object System.Drawing.Bitmap $out
    try {
        Assert-Equal $bmp.GetPixel(0, 0).A 0 'rounded corner is transparent'
        $card = $bmp.GetPixel(6, [int]($bmp.Height / 2))
        Assert-True ($card.A -eq 255 -and $card.R -lt 60 -and $card.G -lt 60) 'card is dark and opaque'
    }
    finally { $bmp.Dispose() }
}
Test-Case 'tile header status text is short and flags problems' {
    $ok = Get-ClwTileCaption $cfgR $usageDemo
    Assert-True ($ok.Text -match '^Updated \d{1,2}:\d{2} (AM|PM)$' -and -not $ok.Warn) 'ok state'
    $stale = New-ClwUsageResult $cfgR 'stale' 'x' $null 'Pro' ([datetimeoffset]::Now.AddHours(-9)) $true 'agent'
    Assert-True ((Get-ClwTileCaption $cfgR $stale).Warn) 'stale warns'
    $none = New-ClwUsageResult $cfgR 'none' 'x' $null '' $null $true ''
    Assert-Equal (Get-ClwTileCaption $cfgR $none).Text 'No usage reported yet'
}
Test-Case 'widget tile grows with more bars and survives missing data' {
    $cfg = Get-ClwConfig -Path (Join-Path $testHome 'nope.json')
    $cfg.bars = @(1..4 | ForEach-Object { [ordered]@{ key = 'five_hour'; label = "Bar $_" } })
    $u = New-ClwUsageResult $cfg 'ok' '' (ConvertFrom-ClwUsageJson -Json (Read-Fixture 'usage-sample.json')) 'Pro' ([datetimeoffset]::Now) $false 'agent'
    $a = Join-Path (New-TempDir) 'a.png'; $b = Join-Path (New-TempDir) 'b.png'
    [void](New-ClwWidgetImage -Config $cfgR -Stats (Get-ClwDemoStats) -Usage $usageDemo -OutPath $a)
    [void](New-ClwWidgetImage -Config $cfg -Stats (Get-ClwDemoStats) -Usage $u -OutPath $b)
    $ha = (New-Object System.Drawing.Bitmap $a); $hb = (New-Object System.Drawing.Bitmap $b)
    try { Assert-True ($hb.Height -gt $ha.Height) 'taller with 4 bars' } finally { $ha.Dispose(); $hb.Dispose() }
    $none = New-ClwUsageResult $cfgR 'none' 'No usage yet' $null '' $null $true ''
    $c = Join-Path (New-TempDir) 'c.png'
    [void](New-ClwWidgetImage -Config $cfgR -Stats $null -Usage $none -OutPath $c)
    Assert-True ((Get-Item $c).Length -gt 3000) 'rendered without stats and without usage'
}
Test-Case 'widget state: image + state file, atomic names, pruning, alt text' {
    $img1 = Update-ClwWidgetState -Config $cfgR -Stats (Get-ClwDemoStats) -Usage $usageDemo
    $paths = Get-ClwPaths
    Assert-True (Test-Path $img1) 'image written'
    $state = Get-Content $paths.State -Raw | ConvertFrom-Json
    Assert-Equal $state.image (Split-Path -Leaf $img1)
    Assert-True (Test-Path (Join-Path $paths.Widget $state.imageCard)) 'opaque card variant written too'
    Assert-True ($state.imageCard -ne $state.image) 'two different pictures'
    Assert-True ($state.alt -match 'Session limit: 37 percent used') 'alt text has the numbers'
    Assert-True ($state.alt -notmatch [string][char]0x00B7) 'alt text is plain'
    Assert-Equal @($state.bars).Count 2
    1..6 | ForEach-Object { [void](Update-ClwWidgetState -Config $cfgR -Stats (Get-ClwDemoStats) -Usage $usageDemo); Start-Sleep -Milliseconds 20 }
    Assert-True (@(Get-ChildItem $paths.Widget -Filter 'widget-*.png').Count -le 8) 'old tiles pruned (newest 4 updates, 2 pictures each)'
    Assert-True (@(Get-ChildItem $paths.Widget -Filter '*.tmp').Count -eq 0) 'no temp files left behind'
    $latest = Get-Content $paths.State -Raw | ConvertFrom-Json
    Assert-True (Test-Path (Join-Path $paths.Widget $latest.image)) 'state always points at an existing image'
    Assert-True (Test-Path (Join-Path $paths.Widget $latest.imageCard)) 'and at an existing card image'
}

Write-Host "`nLegacy full-screen picture" -ForegroundColor Cyan
Test-Case 'renders a PNG of the requested size with the panel on the left' {
    $out = Join-Path (New-TempDir) 'a.png'
    [void](New-ClwImage -Config $cfgR -Stats (Get-ClwDemoStats) -Usage $usageDemo -Width 1280 -Height 720 -OutPath $out)
    $bmp = New-Object System.Drawing.Bitmap $out
    try {
        Assert-Equal $bmp.Width 1280; Assert-Equal $bmp.Height 720
        $left = $bmp.GetPixel(120, 360); $right = $bmp.GetPixel(1100, 360)
        Assert-True ($left.R -ne $right.R -or $left.G -ne $right.G) 'panel differs from the background'
    }
    finally { $bmp.Dispose() }
}
Test-Case 'works without stats and with a missing-usage state' {
    $none = New-ClwUsageResult $cfgR 'none' 'No usage yet' $null '' $null $true ''
    $out = Join-Path (New-TempDir) 's.png'
    [void](New-ClwImage -Config $cfgR -Stats $null -Usage $none -Width 1024 -Height 600 -OutPath $out)
    Assert-True ((Get-Item $out).Length -gt 5000) 'file written'
}

Write-Host "`nScheduler and lock screen helpers" -ForegroundColor Cyan
Test-Case 'task XML is valid and escapes special characters' {
    $xml = [xml](Get-ClwTaskXml -ScriptPath 'C:\Users\a & b\<x>\ClaudeLockWidget.ps1' -IntervalMinutes 7)
    Assert-Equal $xml.Task.Triggers.TimeTrigger.Repetition.Interval 'PT7M'
    Assert-Equal @($xml.Task.Triggers.SessionStateChangeTrigger).Count 2
    Assert-Equal $xml.Task.Principals.Principal.RunLevel 'LeastPrivilege'
    Assert-True ($xml.Task.Actions.Exec.Arguments -like '*a & b*<x>*refresh -Quiet') 'path survives round trip'
}
Test-Case 'task XML without session triggers / without conhost' {
    $xml = [xml](Get-ClwTaskXml -ScriptPath 'C:\x.ps1' -IntervalMinutes 5 -IncludeSessionTriggers $false -Headless $false)
    Assert-True ($null -eq $xml.Task.Triggers.SessionStateChangeTrigger) 'no session triggers'
    Assert-Equal $xml.Task.Actions.Exec.Command 'powershell.exe'
}
Test-Case 'screen size is detected' { $s = Get-ClwScreenSize; Assert-True ($s.Width -ge 640 -and $s.Height -ge 480) 'sane size' }
Test-Case 'old images are pruned, newest kept' {
    $d = New-TempDir
    1..6 | ForEach-Object { $f = Join-Path $d "lockscreen-$_.png"; Set-Content $f 'x'; (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-10 + $_) }
    Remove-ClwOldImages -Directory $d -Keep 3
    Assert-Equal @(Get-ChildItem $d).Count 3
    Assert-True (Test-Path (Join-Path $d 'lockscreen-6.png')) 'newest kept'
}

Write-Host "`nRepository hygiene" -ForegroundColor Cyan
$sources = Get-ChildItem -Path (Join-Path $root 'src'), (Join-Path $root 'tests'), (Join-Path $root 'widget') -Recurse -File -Include *.ps1, *.cs, *.csproj, *.xml |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|build|dist)\\' }
Test-Case 'source files are ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
    foreach ($f in $sources) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
        Assert-True ($bad -eq 0) "$($f.Name) contains $bad non-ASCII byte(s)"
    }
}
Test-Case 'every PowerShell file parses' {
    foreach ($f in ($sources | Where-Object { $_.Extension -eq '.ps1' })) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        Assert-True (@($errors).Count -eq 0) "$($f.Name): $(@($errors)[0])"
    }
}
Test-Case 'script version matches the newest CHANGELOG entry and the provider project' {
    $m = [regex]::Match((Get-Content (Join-Path $root 'CHANGELOG.md') -Raw), '##\s*\[(\d+\.\d+\.\d+)\]')
    Assert-Equal $script:ClwVersion $m.Groups[1].Value
    $v = [regex]::Match((Get-Content (Join-Path $root 'widget\Provider\ClaudeLockWidget.Provider.csproj') -Raw), '<Version>(\d+\.\d+\.\d+)</Version>')
    Assert-Equal $v.Groups[1].Value $script:ClwVersion 'csproj version'
}
Test-Case 'example config matches the built-in defaults' {
    $ex = Get-Content (Join-Path $root 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $def = Get-ClwDefaultConfig
    foreach ($k in $def.Keys) { Assert-True ($null -ne $ex.PSObject.Properties[$k]) "config.example.json is missing '$k'" }
    Assert-Equal $ex.refreshMinutes $def.refreshMinutes
    Assert-Equal @($ex.bars).Count @($def.bars).Count
}
Test-Case 'package manifest template is well-formed once filled in' {
    $t = Get-Content (Join-Path $root 'widget\Package\AppxManifest.template.xml') -Raw
    $clsid = [regex]::Match((Get-Content (Join-Path $root 'widget\Provider\WidgetProvider.cs') -Raw), 'ClsIdText = "([0-9A-Fa-f-]{36})"').Groups[1].Value
    Assert-True ($clsid.Length -eq 36) 'CLSID in provider source'
    $x = [xml]($t.Replace('{{PUBLISHER}}', 'CN=Test').Replace('{{VERSION}}', '1.2.3.0').Replace('{{ARCH}}', 'x64').Replace('{{CLSID}}', $clsid))
    Assert-Equal $x.Package.Identity.Version '1.2.3.0'
    Assert-True ($x.OuterXml -match 'com.microsoft.windows.widgets') 'widget extension present'
    Assert-True ($x.OuterXml -match '<Size Name="small"') 'small size (required for the lock screen)'
}

# ------------------------------------------------------------------ summary
Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:failed.Count -eq 0) { Write-Host "All $script:passed tests passed." -ForegroundColor Green; exit 0 }
Write-Host "$($script:failed.Count) failed, $script:passed passed:" -ForegroundColor Red
$script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
