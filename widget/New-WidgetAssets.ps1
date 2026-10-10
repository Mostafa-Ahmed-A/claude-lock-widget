<#
.SYNOPSIS
    Generates the package icons and the widget-picker screenshot with GDI+ (no image files in git).
#>
param([Parameter(Mandatory)][string]$OutDir)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
foreach ($f in 'Common', 'Usage', 'LocalStats', 'Render', 'Widget') { . (Join-Path $root "src\lib\$f.ps1") }
$script:ClwQuiet = $true
[void](New-Item -ItemType Directory -Path $OutDir -Force)

function Save-Icon {
    param([int]$Size, [string]$Path)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $bg = New-ClwRoundPath 0 0 $Size $Size ($Size * 0.22)
    $brush = New-Object System.Drawing.SolidBrush (ConvertFrom-ClwHex '#212121')
    $g.FillPath($brush, $bg)
    $levels = @(@(0, 1, 0), @(1, 2, 3), @(2, 3, 1))                  # a tiny activity calendar
    $colors = @('#3A3A3A', '#86ACEA', '#6394E3', '#2566D0')
    $margin = $Size * 0.2
    $pitch = ($Size - 2 * $margin) / 3
    $cell = $pitch * 0.78
    for ($r = 0; $r -lt 3; $r++) {
        for ($c = 0; $c -lt 3; $c++) {
            $b = New-Object System.Drawing.SolidBrush (ConvertFrom-ClwHex $colors[$levels[$r][$c]])
            $p = New-ClwRoundPath ($margin + $c * $pitch + ($pitch - $cell) / 2) ($margin + $r * $pitch + ($pitch - $cell) / 2) $cell $cell ($cell * 0.22)
            $g.FillPath($b, $p); $p.Dispose(); $b.Dispose()
        }
    }
    $bg.Dispose(); $brush.Dispose(); $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

Save-Icon 50 (Join-Path $OutDir 'StoreLogo.png')
Save-Icon 44 (Join-Path $OutDir 'Square44x44Logo.png')
Save-Icon 150 (Join-Path $OutDir 'Square150x150Logo.png')
Save-Icon 64 (Join-Path $OutDir 'ProviderIcon.png')
Save-Icon 64 (Join-Path $OutDir 'WidgetIcon.png')

# Widget picker screenshot: 300 x 304, transparent rounded corners, shows the (demo) widget.
$cfg = Get-ClwDefaultConfig
$tile = New-ClwWidgetImage -Config $cfg -Stats (Get-ClwDemoStats) -Usage (Get-ClwDemoUsage $cfg) `
    -OutPath (Join-Path ([System.IO.Path]::GetTempPath()) 'clw-asset-tile.png')
$src = [System.Drawing.Image]::FromFile($tile)
try {
    $bmp = New-Object System.Drawing.Bitmap(300, 304, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    $bg = New-ClwRoundPath 0 0 300 304 18
    $g.FillPath((New-Object System.Drawing.SolidBrush (ConvertFrom-ClwHex '#202020')), $bg)
    $w = 276.0; $h = $src.Height * ($w / $src.Width)
    $g.DrawImage($src, 12.0, (304 - $h) / 2, $w, $h)
    $g.Dispose()
    $bmp.Save((Join-Path $OutDir 'WidgetScreenshot.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
finally { $src.Dispose() }

Get-ChildItem $OutDir -File | ForEach-Object { '{0,-26} {1,6} bytes' -f $_.Name, $_.Length }
