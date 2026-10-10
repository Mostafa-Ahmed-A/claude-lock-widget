# Widget.ps1 - publishes what the Windows widget shows.
#
# The packaged widget provider (src\widget) watches %LOCALAPPDATA%\ClaudeLockWidget\widget and
# pushes widget-state.json + the tile PNG it points to into the lock screen widget.
# Files are written under a unique name and the state file is swapped in last, so the provider
# never reads a half-written image.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0

function Get-ClwSpokenSummary {
    # Plain-language description for screen readers and the widget's alt text.
    param($Stats, $Usage)
    $parts = @('Claude Code usage.')
    foreach ($b in @($Usage.Bars)) {
        if ($null -eq $b.Percent) { $parts += ('{0}: unknown.' -f $b.Label); continue }
        $reset = Format-ClwReset $b.ResetsAt
        $text = '{0}: {1} percent used' -f $b.Label, [math]::Round($b.Percent)
        if ($reset) { $text += ', ' + $reset.Substring(0, 1).ToLowerInvariant() + $reset.Substring(1) }
        $parts += ($text + '.')
    }
    if ($Stats) {
        $parts += ('{0} messages and {1} tokens in {2} sessions.' -f (Format-ClwNumber $Stats.Messages), (Format-ClwCompact $Stats.TotalTokens), (Format-ClwNumber $Stats.Sessions))
    }
    ($parts -join ' ') -replace [string][char]0x00B7, '-'
}

function Update-ClwWidgetState {
    param([Parameter(Mandatory)]$Config, $Stats, [Parameter(Mandatory)]$Usage)

    Initialize-ClwDirectories
    $paths = Get-ClwPaths
    $stamp = (Get-Date).ToString('yyyyMMddHHmmssfff', [System.Globalization.CultureInfo]::InvariantCulture)
    # "glass" = transparent, light text (lock screen, dark theme); "card" = opaque, for a light-theme Widgets board
    $imageName = "widget-$stamp.png"
    $cardName = "widget-$stamp-card.png"
    $imagePath = Join-Path $paths.Widget $imageName
    [void](New-ClwWidgetImage -Config $Config -Stats $Stats -Usage $Usage -OutPath $imagePath -Style glass)
    [void](New-ClwWidgetImage -Config $Config -Stats $Stats -Usage $Usage -OutPath (Join-Path $paths.Widget $cardName) -Style card)

    $caption = Get-ClwCaption $Config $Usage
    $state = [ordered]@{
        version   = 1
        updatedAt = [datetimeoffset]::Now.ToString('o')
        image     = $imageName
        imageCard = $cardName
        status    = $Usage.Status
        source    = $Usage.Source
        caption   = $caption.Text
        alt       = (Get-ClwSpokenSummary $Stats $Usage)
        bars      = @($Usage.Bars | ForEach-Object {
                [ordered]@{ label = $_.Label; percent = $_.Percent; resets = (Format-ClwReset $_.ResetsAt) }
            })
    }
    $tmp = $paths.State + '.tmp'
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $paths.State -Force

    # keep the newest few tiles only (the provider may still be reading the previous one)
    Get-ChildItem -LiteralPath $paths.Widget -Filter 'widget-*.png' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 8 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $imagePath
}
