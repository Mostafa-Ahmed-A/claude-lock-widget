# Render.ps1 - draws the lock screen image with System.Drawing (GDI+, built into Windows).
#
# Layout (top to bottom): "Overview" card (stats tiles + activity calendar) and, below it, the
# "Plan usage limits" card with the usage bars. Colours/proportions follow Claude Code's UI.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0
Add-Type -AssemblyName System.Drawing

# Design-space metrics (1 unit = 1 px at 1080p and scale 1.0, multiplied by $Ctx.U).
$script:ClwDesign = @{
    CardW      = 550
    Pad        = 16
    Radius     = 14
    Gap        = 12      # between the two cards
    OverviewH  = 346
    HeatCols   = 26
}

$script:ClwPalette = @{
    Card   = '#212121'; Tile = '#383838'; Pill = '#323232'; Cell = '#383838'
    Level1 = '#86ACEA'; Level2 = '#6394E3'; Level3 = '#2566D0'
    Text   = '#F2F1EC'; Muted = '#A3A19A'; Dim = '#8B8982'; Track = '#2B2B2A'
    Warn   = '#F5A524'; Danger = '#E5484D'
}

# ------------------------------------------------------------ primitives

function ConvertFrom-ClwHex {
    param([Parameter(Mandatory)][string]$Hex, [int]$Alpha = 255)
    $h = $Hex.TrimStart('#')
    [System.Drawing.Color]::FromArgb($Alpha,
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function Get-ClwBrush {
    param($Ctx, [string]$Hex, [int]$Alpha = 255)
    $key = "$Hex/$Alpha"
    if (-not $Ctx.Brushes.ContainsKey($key)) {
        $Ctx.Brushes[$key] = New-Object System.Drawing.SolidBrush (ConvertFrom-ClwHex $Hex $Alpha)
    }
    $Ctx.Brushes[$key]
}

function New-ClwRoundPath {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [math]::Min($R * 2, [math]::Min($W, $H))
    if ($d -le 0.5) { $path.AddRectangle((New-Object System.Drawing.RectangleF($X, $Y, $W, $H))); return $path }
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function Add-ClwRoundRect {
    param($Ctx, [string]$Hex, [double]$X, [double]$Y, [double]$W, [double]$H, [double]$R, [int]$Alpha = 255)
    if ($W -le 0 -or $H -le 0) { return }
    $path = New-ClwRoundPath $X $Y $W $H $R
    $Ctx.G.FillPath((Get-ClwBrush $Ctx $Hex $Alpha), $path)
    $path.Dispose()
}

function Measure-ClwText {
    param($Ctx, [string]$Text, $Font)
    $Ctx.G.MeasureString($Text, $Font, 100000, $Ctx.MeasureFormat).Width
}

function Add-ClwText {
    param(
        $Ctx, [string]$Text, $Font, [string]$Hex,
        [double]$X, [double]$Y, [double]$W, [double]$H,
        [ValidateSet('Near', 'Center', 'Far')][string]$Align = 'Near',
        [ValidateSet('Near', 'Center', 'Far')][string]$VAlign = 'Center',
        [int]$Alpha = 255
    )
    if ([string]::IsNullOrEmpty($Text)) { return }
    $fmt = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
    $fmt.Alignment = [System.Drawing.StringAlignment]$Align
    $fmt.LineAlignment = [System.Drawing.StringAlignment]$VAlign
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $rect = New-Object System.Drawing.RectangleF($X, $Y, $W, $H)
    $Ctx.G.DrawString($Text, $Font, (Get-ClwBrush $Ctx $Hex $Alpha), $rect, $fmt)
    $fmt.Dispose()
}

function New-ClwFont {
    param([string]$Family, [double]$Px, [bool]$Bold = $false)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font($Family, [single]$Px, $style, [System.Drawing.GraphicsUnit]::Pixel)
}

function Add-ClwFonts {
    # Creates the font set used by every drawing routine, scaled by $U.
    param($Ctx, $Config, [double]$U)
    $families = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    $family = if ($families -contains $Config.fontFamily) { [string]$Config.fontFamily } else { 'Segoe UI' }
    $semibold = "$family Semibold"
    $useSemi = $families -contains $semibold
    $bold = {
        param($px)
        if ($useSemi) { New-ClwFont $semibold ($px * $U) } else { New-ClwFont $family ($px * $U) $true }
    }
    $Ctx.FontHeader = New-ClwFont $family (14 * $U)
    $Ctx.FontHeaderBold = & $bold 14
    $Ctx.FontSmall = New-ClwFont $family (13.5 * $U)
    $Ctx.FontValue = & $bold 18
    $Ctx.FontTitle = New-ClwFont $family (14.5 * $U)
    $Ctx.FontBar = New-ClwFont $family (15 * $U)
    $Ctx.FontBarBold = & $bold 15.5
    $Ctx.FontCaption = New-ClwFont $family (13 * $U)
}

# ------------------------------------------------------------ background

function Add-ClwGlow {
    param($G, [double]$Cx, [double]$Cy, [double]$Rx, [double]$Ry, [string]$Hex, [int]$Alpha)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse([single]($Cx - $Rx), [single]($Cy - $Ry), [single]($Rx * 2), [single]($Ry * 2))
    $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush $path
    $brush.CenterColor = ConvertFrom-ClwHex $Hex $Alpha
    $brush.SurroundColors = [System.Drawing.Color[]]@(ConvertFrom-ClwHex $Hex 0)
    $G.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
}

function Get-ClwBackgroundImagePath {
    param([string]$Setting)
    if ($Setting -eq 'wallpaper') {
        try {
            $wp = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction Stop).WallPaper
            if ($wp -and (Test-Path -LiteralPath $wp)) { return $wp }
        }
        catch { }
        $transcoded = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
        if (Test-Path -LiteralPath $transcoded) { return $transcoded }
        return $null
    }
    if ($Setting -and $Setting -ne 'gradient' -and (Test-Path -LiteralPath $Setting)) { return $Setting }
    $null
}

function Add-ClwBackground {
    param($Ctx, $Config)
    $g = $Ctx.G; $w = $Ctx.W; $h = $Ctx.H
    $image = $null
    $imagePath = Get-ClwBackgroundImagePath ([string]$Config.background)
    if ($imagePath) {
        try {
            # Read via a memory stream so the source file is not left locked.
            $ms = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($imagePath))
            $image = [System.Drawing.Image]::FromStream($ms)
        }
        catch { Write-ClwLog "Could not load background '$imagePath': $($_.Exception.Message)" 'WARN'; $image = $null }
    }

    if ($image) {
        # "cover" fit: scale to fill, centre-crop
        $scale = [math]::Max($w / $image.Width, $h / $image.Height)
        $sw = $w / $scale; $sh = $h / $scale
        $src = New-Object System.Drawing.RectangleF(([single](($image.Width - $sw) / 2)), ([single](($image.Height - $sh) / 2)), [single]$sw, [single]$sh)
        $dst = New-Object System.Drawing.RectangleF(0, 0, [single]$w, [single]$h)
        $g.DrawImage($image, $dst, $src, [System.Drawing.GraphicsUnit]::Pixel)
        $image.Dispose()
        $dim = [int](255 * [double]$Config.backgroundDim)
        $g.FillRectangle((Get-ClwBrush $Ctx '#000000' $dim), 0, 0, $w, $h)
        return
    }

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (ConvertFrom-ClwHex '#0B0D12'), (ConvertFrom-ClwHex '#1A1F2B'), 40.0)
    $g.FillRectangle($lg, $rect)
    $lg.Dispose()
    Add-ClwGlow $g ($w * 0.88) ($h * 0.10) ($w * 0.55) ($h * 0.75) $Config.accent 80
    Add-ClwGlow $g ($w * 0.06) ($h * 1.00) ($w * 0.50) ($h * 0.65) '#D97757' 55
}

function Add-ClwBackdropBlur {
    # Frosted-glass effect: blur the background under a card by down- and up-scaling it.
    param($Ctx, [double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
    $sw = [math]::Max(2, [int]($W / 14)); $sh = [math]::Max(2, [int]($H / 14))
    $small = New-Object System.Drawing.Bitmap($sw, $sh)
    $gs = [System.Drawing.Graphics]::FromImage($small)
    $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $gs.DrawImage($Ctx.Bmp, (New-Object System.Drawing.RectangleF(0, 0, $sw, $sh)),
        (New-Object System.Drawing.RectangleF([single]$X, [single]$Y, [single]$W, [single]$H)), [System.Drawing.GraphicsUnit]::Pixel)
    $gs.Dispose()

    $path = New-ClwRoundPath $X $Y $W $H $R
    $Ctx.G.SetClip($path)
    $Ctx.G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $Ctx.G.DrawImage($small, (New-Object System.Drawing.RectangleF([single]$X, [single]$Y, [single]$W, [single]$H)),
        (New-Object System.Drawing.RectangleF(0, 0, $sw, $sh)), [System.Drawing.GraphicsUnit]::Pixel)
    $Ctx.G.ResetClip()
    $path.Dispose(); $small.Dispose()
}

function Add-ClwCard {
    param($Ctx, [double]$X, [double]$Y, [double]$W, [double]$H)
    $u = $Ctx.U
    $r = $script:ClwDesign.Radius * $u
    Add-ClwBackdropBlur $Ctx $X $Y $W $H $r
    Add-ClwRoundRect $Ctx $script:ClwPalette.Card $X $Y $W $H $r ([int](255 * $Ctx.CardOpacity))
    $path = New-ClwRoundPath ($X + 0.5) ($Y + 0.5) ($W - 1) ($H - 1) $r
    $pen = New-Object System.Drawing.Pen ((ConvertFrom-ClwHex '#FFFFFF' 26)), 1
    $Ctx.G.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
}

# --------------------------------------------------------------- heatmap

function Get-ClwHeatCells {
    # 7 rows (Sunday..Saturday) x $Cols week-columns; the last column is the current week.
    # Future days are omitted. Level 0 = no activity, 1..3 = increasing activity.
    param($Daily, [int]$Cols, [datetime]$Today)
    $today = $Today.Date
    $lastWeekStart = $today.AddDays(-([int]$today.DayOfWeek))
    $cells = New-Object System.Collections.Generic.List[object]
    for ($c = 0; $c -lt $Cols; $c++) {
        $weekStart = $lastWeekStart.AddDays(-7 * ($Cols - 1 - $c))
        for ($r = 0; $r -lt 7; $r++) {
            $date = $weekStart.AddDays($r)
            if ($date -gt $today) { continue }
            $count = 0
            if ($Daily) {
                $key = $date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                if ($Daily.ContainsKey($key)) { $count = [int64]$Daily[$key] }
            }
            $cells.Add([pscustomobject]@{ Col = $c; Row = $r; Count = $count; Level = 0 })
        }
    }
    $max = 0
    foreach ($cell in $cells) { if ($cell.Count -gt $max) { $max = $cell.Count } }
    foreach ($cell in $cells) {
        if ($cell.Count -le 0 -or $max -le 0) { continue }
        $ratio = $cell.Count / $max
        $cell.Level = if ($ratio -le 0.33) { 1 } elseif ($ratio -le 0.66) { 2 } else { 3 }
    }
    , $cells
}

# ----------------------------------------------------------- Overview card

function Get-ClwFunFact {
    param($Stats, [string]$Book)
    if (-not $Book -or $Book -eq 'off' -or -not $Stats -or $Stats.TotalTokens -le 0) { return '' }
    $books = Get-ClwBookTokens
    if (-not $books.ContainsKey($Book)) { return '' }
    $times = [math]::Floor($Stats.TotalTokens / $books[$Book])
    if ($times -lt 1) { return '' }
    "You've used ~{0}{1} more tokens than {2}." -f $times, [char]0x00D7, $Book
}

function Add-ClwOverviewCard {
    param($Ctx, $Config, $Stats, [double]$X, [double]$Y)
    $d = $script:ClwDesign; $u = $Ctx.U; $p = $script:ClwPalette
    $w = $d.CardW * $u; $h = $d.OverviewH * $u; $pad = $d.Pad * $u
    Add-ClwCard $Ctx $X $Y $w $h

    # header: "Overview" pill on the left, range chips on the right
    $hy = $Y + 11 * $u; $hh = 24 * $u
    $pillW = (Measure-ClwText $Ctx 'Overview' $Ctx.FontHeader) + 22 * $u
    Add-ClwRoundRect $Ctx $p.Pill ($X + $pad) $hy $pillW $hh (8 * $u)
    Add-ClwText $Ctx 'Overview' $Ctx.FontHeaderBold $p.Text ($X + $pad) $hy $pillW $hh 'Center'

    $cx = $X + $w - $pad
    foreach ($range in @('7d', '30d', 'All')) {
        $chipW = (Measure-ClwText $Ctx $range $Ctx.FontHeader) + 18 * $u
        $cx -= $chipW
        $selected = ($range.ToLowerInvariant() -eq $Config.statsRange)
        if ($selected) { Add-ClwRoundRect $Ctx $p.Pill $cx $hy $chipW $hh (8 * $u) }
        $font = if ($selected) { $Ctx.FontHeaderBold } else { $Ctx.FontHeader }
        $hex = if ($selected) { $p.Text } else { $p.Muted }
        Add-ClwText $Ctx $range $font $hex $cx $hy $chipW $hh 'Center'
        $cx -= 4 * $u
    }

    # stat tiles (3 x 2)
    $dash = '-'
    $tiles = @(
        @('Sessions', $(if ($Stats) { Format-ClwNumber $Stats.Sessions } else { $dash })),
        @('Messages', $(if ($Stats) { Format-ClwNumber $Stats.Messages } else { $dash })),
        @('Total tokens', $(if ($Stats) { Format-ClwCompact $Stats.TotalTokens } else { $dash })),
        @('Active days', $(if ($Stats) { Format-ClwNumber $Stats.ActiveDays } else { $dash })),
        @('Peak hour', $(if ($Stats -and $null -ne $Stats.PeakHour) { Format-ClwHour $Stats.PeakHour } else { $dash })),
        @('Favorite model', $(if ($Stats -and $Stats.FavoriteModel) { Format-ClwModelName $Stats.FavoriteModel } else { $dash }))
    )
    $gap = 5 * $u
    $tileW = ($w - 2 * $pad - 2 * $gap) / 3
    $tileH = 51 * $u
    $ty0 = $Y + 57 * $u
    for ($i = 0; $i -lt 6; $i++) {
        $col = $i % 3; $row = [math]::Floor($i / 3)
        $tx = $X + $pad + $col * ($tileW + $gap)
        $ty = $ty0 + $row * ($tileH + $gap)
        Add-ClwRoundRect $Ctx $p.Tile $tx $ty $tileW $tileH (7 * $u)
        Add-ClwText $Ctx $tiles[$i][0] $Ctx.FontSmall $p.Muted ($tx + 11 * $u) ($ty + 6 * $u) ($tileW - 16 * $u) (20 * $u)
        Add-ClwText $Ctx $tiles[$i][1] $Ctx.FontValue $p.Text ($tx + 11 * $u) ($ty + 26 * $u) ($tileW - 16 * $u) (22 * $u)
    }

    # activity calendar
    $cols = $d.HeatCols
    $heatY = $Y + 171 * $u
    $cell = 16 * $u
    $pitch = ($w - 2 * $pad - $cell) / ($cols - 1)
    $daily = if ($Stats) { $Stats.Daily } else { $null }
    $cells = Get-ClwHeatCells -Daily $daily -Cols $cols -Today $Ctx.Today
    foreach ($c in $cells) {
        $hex = switch ($c.Level) { 1 { $p.Level1 } 2 { $p.Level2 } 3 { $p.Level3 } default { $p.Cell } }
        Add-ClwRoundRect $Ctx $hex ($X + $pad + $c.Col * $pitch) ($heatY + $c.Row * $pitch) $cell $cell (3.2 * $u)
    }

    # fun fact
    $fact = Get-ClwFunFact $Stats $Config.funFactBook
    Add-ClwText $Ctx $fact $Ctx.FontSmall $p.Dim ($X + $pad) ($Y + 318 * $u) ($w - 2 * $pad) (20 * $u)
}

# -------------------------------------------------------------- Usage card

function Get-ClwUsageCardHeight {
    param([int]$BarCount)
    $last = 73 + ([math]::Max(1, $BarCount) - 1) * 42 + 4
    $last + 18
}

function Add-ClwUsageCard {
    param($Ctx, $Config, $Usage, [double]$X, [double]$Y)
    $d = $script:ClwDesign; $u = $Ctx.U; $p = $script:ClwPalette
    $w = $d.CardW * $u; $pad = $d.Pad * $u
    $bars = @($Usage.Bars)
    $h = (Get-ClwUsageCardHeight $bars.Count) * $u
    Add-ClwCard $Ctx $X $Y $w $h

    $title = 'Plan usage limits'
    if ($Usage.Plan) { $title += ' {0} {1}' -f [char]0x00B7, $Usage.Plan }
    Add-ClwText $Ctx $title $Ctx.FontTitle $p.Dim ($X + $pad) ($Y + 14 * $u) ($w - 2 * $pad) (24 * $u)

    $trackW = $w - 2 * $pad
    $barH = 4 * $u
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $bar = $bars[$i]
        $rowY = $Y + (58 + $i * 42) * $u          # vertical centre of the label row
        $pctText = if ($null -ne $bar.Percent) { '{0}%' -f [math]::Round($bar.Percent) } else { '--' }
        $pctW = (Measure-ClwText $Ctx $pctText $Ctx.FontBar)
        Add-ClwText $Ctx $bar.Label $Ctx.FontBarBold $p.Text ($X + $pad) ($rowY - 12 * $u) ($trackW * 0.6) (24 * $u)
        Add-ClwText $Ctx $pctText $Ctx.FontBar $p.Muted ($X + $w - $pad - $pctW - 4 * $u) ($rowY - 12 * $u) ($pctW + 4 * $u) (24 * $u) 'Far'
        $reset = Format-ClwReset $bar.ResetsAt
        if ($reset) {
            $rw = $trackW - $pctW - 18 * $u
            Add-ClwText $Ctx $reset $Ctx.FontBar $p.Dim ($X + $pad) ($rowY - 12 * $u) $rw (24 * $u) 'Far'
        }

        $barY = $rowY + 15 * $u
        Add-ClwRoundRect $Ctx $p.Track ($X + $pad) $barY $trackW $barH ($barH / 2)
        if ($null -ne $bar.Percent -and $bar.Percent -gt 0) {
            $fill = $Config.accent
            if ($Config.colorizeBars) {
                if ($bar.Percent -ge 90) { $fill = $p.Danger } elseif ($bar.Percent -ge 75) { $fill = $p.Warn }
            }
            $fw = [math]::Max($barH, $trackW * ($bar.Percent / 100.0))
            Add-ClwRoundRect $Ctx $fill ($X + $pad) $barY $fw $barH ($barH / 2)
        }
    }
    $h
}

# ------------------------------------------------------------ entry point

function Get-ClwCaption {
    param($Config, $Usage)
    $time = { param($t) if ($t) { ([datetimeoffset]$t).ToLocalTime().ToString('h:mm tt', $script:ClwCulture) } else { 'never' } }
    $dot = [string][char]0x00B7
    if (-not $Usage) { return @{ Text = ''; Warn = $false } }
    if ($Usage.Status -eq 'ok') {
        if (-not $Config.showUpdatedAt) { return @{ Text = ''; Warn = $false } }
        return @{ Text = ('Updated {0}' -f (& $time $Usage.FetchedAt)); Warn = $false }
    }
    $msg = if ($Usage.FetchedAt) { 'Usage as of {0} {1} {2}' -f (& $time $Usage.FetchedAt), $dot, $Usage.Message } else { [string]$Usage.Message }
    @{ Text = $msg; Warn = $true }
}

# ------------------------------------------------------------ widget tile

function Get-ClwTileCaption {
    # Short status text for the widget header: @{ Text; Warn }
    param($Config, $Usage)
    $time = { param($t) if ($t) { ([datetimeoffset]$t).ToLocalTime().ToString('h:mm tt', $script:ClwCulture) } else { '' } }
    if (-not $Usage) { return @{ Text = ''; Warn = $false } }
    switch ($Usage.Status) {
        'ok' {
            if (-not $Config.showUpdatedAt -or -not $Usage.FetchedAt) { return @{ Text = ''; Warn = $false } }
            return @{ Text = ('Updated {0}' -f (& $time $Usage.FetchedAt)); Warn = $false }
        }
        'stale' { return @{ Text = ('Stale since {0}' -f (& $time $Usage.FetchedAt)); Warn = $true } }
        'none' { return @{ Text = 'No usage reported yet'; Warn = $true } }
        default { return @{ Text = [string]$Usage.Message; Warn = $true } }
    }
}

function New-ClwWidgetImage {
    <#
    .SYNOPSIS
        Renders the picture shown inside the Windows widget: a compact header, the activity calendar on
        top and the usage bars below.
        -Style glass : transparent background, light text - sits directly on the (dark) lock screen tile.
        -Style card  : opaque dark rounded card - used when the host theme is light.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        $Stats,
        [Parameter(Mandatory)]$Usage,
        [Parameter(Mandatory)][string]$OutPath,
        [datetime]$Today = (Get-Date).Date,
        [int]$Width = 640,
        [ValidateSet('glass', 'card')][string]$Style = 'glass'
    )

    $p = $script:ClwPalette
    $glass = ($Style -eq 'glass')
    # role -> @(hex, alpha)
    $c = if ($glass) {
        @{ Text = @('#FFFFFF', 245); Muted = @('#FFFFFF', 175); Dim = @('#FFFFFF', 130); Chip = @('#FFFFFF', 36); Cell = @('#FFFFFF', 40); Track = @('#FFFFFF', 46) }
    }
    else {
        @{ Text = @($p.Text, 255); Muted = @($p.Muted, 255); Dim = @($p.Dim, 255); Chip = @($p.Pill, 255); Cell = @($p.Cell, 255); Track = @($p.Track, 255) }
    }

    $bars = @($Usage.Bars)
    $cols = [int]$Config.widgetWeeks
    $pad = 16.0
    $headerTop = 10.0; $headerH = 34.0
    $ratio = 0.82                                  # cell size as a share of the pitch
    $pitch = ($Width - 2 * $pad) / (($cols - 1) + $ratio)
    $cell = $pitch * $ratio
    $heatTop = $headerTop + $headerH + 4
    $heatH = 6 * $pitch + $cell
    $barsTop = $heatTop + $heatH + 12
    $rowH = 50.0
    $height = [int][math]::Ceiling($barsTop + $bars.Count * $rowH + 4)

    $bmp = New-Object System.Drawing.Bitmap($Width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias     # alpha-correct on a transparent canvas
    $g.Clear([System.Drawing.Color]::Transparent)
    $ctx = $null
    try {
        $ctx = @{
            Bmp = $bmp; G = $g; W = $Width; H = $height; U = 1.0; Today = $Today
            CardOpacity = 1.0; Brushes = @{}
            MeasureFormat = [System.Drawing.StringFormat]::GenericTypographic
        }
        Add-ClwFonts $ctx $Config 1.0
        # Windows shows this picture at roughly half its pixel width, so the type is large.
        $families = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
        $family = if ($families -contains $Config.fontFamily) { [string]$Config.fontFamily } else { 'Segoe UI' }
        $semi = if ($families -contains "$family Semibold") { "$family Semibold" } else { $null }
        $mkBold = { param($px) if ($semi) { New-ClwFont $semi $px } else { New-ClwFont $family $px $true } }
        $fName = & $mkBold 26
        $fLabel = & $mkBold 24
        $fText = New-ClwFont $family 22
        $fSmall = New-ClwFont $family 20

        if (-not $glass) {
            Add-ClwRoundRect $ctx $p.Card 0 0 $Width $height 22
            $path = New-ClwRoundPath 0.5 0.5 ($Width - 1) ($height - 1) 22
            $pen = New-Object System.Drawing.Pen ((ConvertFrom-ClwHex '#FFFFFF' 28)), 1
            $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
        }

        # header: "Claude" + plan chip + status on the left, headline numbers on the right
        Add-ClwText $ctx 'Claude' $fName $c.Text[0] $pad $headerTop 120 $headerH 'Near' -Alpha $c.Text[1]
        $x = $pad + (Measure-ClwText $ctx 'Claude' $fName) + 10
        if ($Usage.Plan) {
            $chipW = (Measure-ClwText $ctx $Usage.Plan $fSmall) + 22
            Add-ClwRoundRect $ctx $c.Chip[0] $x ($headerTop + 3) $chipW ($headerH - 6) 9 $c.Chip[1]
            Add-ClwText $ctx $Usage.Plan $fSmall $c.Muted[0] $x ($headerTop + 3) $chipW ($headerH - 6) 'Center' -Alpha $c.Muted[1]
            $x += $chipW + 12
        }
        $caption = Get-ClwTileCaption $Config $Usage
        $right = $Width - $pad
        if ($Stats -and -not $caption.Warn) {
            $headline = '{0} msgs {1} {2} tokens' -f (Format-ClwNumber $Stats.Messages), [char]0x00B7, (Format-ClwCompact $Stats.TotalTokens)
            $hw = (Measure-ClwText $ctx $headline $fSmall)
            Add-ClwText $ctx $headline $fSmall $c.Muted[0] ($right - $hw - 4) $headerTop ($hw + 8) $headerH 'Far' -Alpha $c.Muted[1]
            $right -= ($hw + 16)
        }
        if ($caption.Text) {
            $room = $right - $x
            if ($caption.Warn) {
                $warnW = [math]::Min($Width - $pad - $x, 420)
                Add-ClwText $ctx $caption.Text $fSmall $p.Warn ($Width - $pad - $warnW) $headerTop $warnW $headerH 'Far'
            }
            elseif ($room -gt 120) {
                Add-ClwText $ctx $caption.Text $fSmall $c.Dim[0] $x $headerTop $room $headerH 'Near' -Alpha $c.Dim[1]
            }
        }

        # activity calendar
        $daily = if ($Stats) { $Stats.Daily } else { $null }
        $cells = Get-ClwHeatCells -Daily $daily -Cols $cols -Today $Today
        foreach ($cc in $cells) {
            $x0 = $pad + $cc.Col * $pitch; $y0 = $heatTop + $cc.Row * $pitch
            if ($cc.Level -eq 0) { Add-ClwRoundRect $ctx $c.Cell[0] $x0 $y0 $cell $cell ($cell * 0.22) $c.Cell[1] }
            else {
                $hex = switch ($cc.Level) { 1 { $p.Level1 } 2 { $p.Level2 } default { $p.Level3 } }
                Add-ClwRoundRect $ctx $hex $x0 $y0 $cell $cell ($cell * 0.22)
            }
        }

        # usage bars
        $trackW = $Width - 2 * $pad
        $barH = 8.0
        for ($i = 0; $i -lt $bars.Count; $i++) {
            $bar = $bars[$i]
            $y = $barsTop + $i * $rowH
            $pctText = if ($null -ne $bar.Percent) { '{0}%' -f [math]::Round($bar.Percent) } else { '--' }
            $pctW = (Measure-ClwText $ctx $pctText $fText)
            Add-ClwText $ctx $bar.Label $fLabel $c.Text[0] $pad $y ($trackW * 0.58) 30 'Near' -Alpha $c.Text[1]
            Add-ClwText $ctx $pctText $fText $c.Muted[0] ($Width - $pad - $pctW - 4) $y ($pctW + 4) 30 'Far' -Alpha $c.Muted[1]
            $reset = Format-ClwReset $bar.ResetsAt
            if ($reset) { Add-ClwText $ctx $reset $fSmall $c.Dim[0] $pad $y ($trackW - $pctW - 16) 30 'Far' -Alpha $c.Dim[1] }

            $by = $y + 34
            Add-ClwRoundRect $ctx $c.Track[0] $pad $by $trackW $barH ($barH / 2) $c.Track[1]
            if ($null -ne $bar.Percent -and $bar.Percent -gt 0) {
                $fill = $Config.accent
                if ($Config.colorizeBars) {
                    if ($bar.Percent -ge 90) { $fill = $p.Danger } elseif ($bar.Percent -ge 75) { $fill = $p.Warn }
                }
                Add-ClwRoundRect $ctx $fill $pad $by ([math]::Max($barH, $trackW * ($bar.Percent / 100.0))) $barH ($barH / 2)
            }
        }

        $dir = Split-Path -Parent $OutPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($ctx) { foreach ($b in $ctx.Brushes.Values) { $b.Dispose() } }
        $g.Dispose(); $bmp.Dispose()
    }
    $OutPath
}

function New-ClwImage {
    <#
    .SYNOPSIS
        Renders the lock screen image and returns the path of the written PNG.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        $Stats,
        [Parameter(Mandatory)]$Usage,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][string]$OutPath,
        [datetime]$Today = (Get-Date).Date
    )

    $d = $script:ClwDesign
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $ctx = $null

    try {
        # scale: 1 design unit == 1px at 1080p; shrink if the panel would not fit the screen
        $barCount = @($Usage.Bars).Count
        $designH = $d.OverviewH + $d.Gap + (Get-ClwUsageCardHeight $barCount) + 34
        $u = ($Height / 1080.0) * [double]$Config.scale * 1.15
        $u = [math]::Min($u, ($Height * 0.94) / $designH)
        $u = [math]::Min($u, ($Width * 0.94) / $d.CardW)

        $ctx = @{
            Bmp = $bmp; G = $g; W = $Width; H = $Height; U = $u; Today = $Today
            CardOpacity = [double]$Config.cardOpacity
            Brushes = @{}
            MeasureFormat = [System.Drawing.StringFormat]::GenericTypographic
        }
        Add-ClwFonts $ctx $Config $u

        Add-ClwBackground $ctx $Config

        # panel placement
        $panelW = $d.CardW * $u
        $panelH = $designH * $u
        $position = [string]$Config.position
        if ($position -eq 'auto') {
            # Windows 11 puts the clock top-centre, Windows 10 bottom-left.
            $position = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'left' } else { 'right' }
        }
        $margin = [math]::Max(24, $Width * 0.06)
        $px = switch ($position) { 'left' { $margin } 'center' { ($Width - $panelW) / 2 } default { $Width - $margin - $panelW } }
        $py = switch ([string]$Config.verticalAlign) { 'top' { $Height * 0.06 } 'bottom' { $Height * 0.94 - $panelH } default { ($Height - $panelH) / 2 } }
        $px += $Width * ([double]$Config.offsetXPercent / 100.0)
        $py += $Height * ([double]$Config.offsetYPercent / 100.0)
        $px = [math]::Min([math]::Max(0.0, [double]$px), [double]($Width - $panelW))
        $py = [math]::Min([math]::Max(0.0, [double]$py), [double]($Height - $panelH))

        Add-ClwOverviewCard $ctx $Config $Stats $px $py
        $usageY = $py + ($d.OverviewH + $d.Gap) * $u
        $usageH = @(Add-ClwUsageCard $ctx $Config $Usage $px $usageY)[-1]

        $caption = Get-ClwCaption $Config $Usage
        if ($caption.Text) {
            $cy = $usageY + $usageH + 8 * $u
            $hex = if ($caption.Warn) { $script:ClwPalette.Warn } else { '#FFFFFF' }
            $alpha = if ($caption.Warn) { 255 } else { 150 }
            Add-ClwText $ctx $caption.Text $ctx.FontCaption '#000000' ($px + $u) ($cy + $u) $panelW (22 * $u) 'Near' 'Center' 120
            Add-ClwText $ctx $caption.Text $ctx.FontCaption $hex $px $cy $panelW (22 * $u) 'Near' 'Center' $alpha
        }

        $dir = Split-Path -Parent $OutPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($ctx) { foreach ($b in $ctx.Brushes.Values) { $b.Dispose() } }
        $g.Dispose(); $bmp.Dispose()
    }
    $OutPath
}
