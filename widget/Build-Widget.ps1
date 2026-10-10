<#
.SYNOPSIS
    Builds, packages and signs the widget provider: widget\dist\ClaudeLockWidget.msix (+ .cer, Install-Widget.ps1).

.DESCRIPTION
    1. dotnet publish (self-contained, so the target PC needs no .NET or Windows App SDK install)
    2. generate icons/screenshot, fill in AppxManifest.xml
    3. makeappx pack  (from the Windows SDK, or downloaded from the Microsoft.Windows.SDK.BuildTools NuGet package)
    4. sign with a self-signed code-signing certificate (created once, kept in your CurrentUser\My store)

    The certificate is only a sideloading convenience: users trust it once (Install-Widget.ps1 asks for one
    admin prompt). For the Microsoft Store you would sign with the Store's certificate instead.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File widget\Build-Widget.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    [string]$Publisher = 'CN=ClaudeLockWidget',
    [string]$PfxPath,                 # use this certificate instead of the CurrentUser\My one (CI)
    [string]$PfxPassword
)

$ErrorActionPreference = 'Stop'
$widgetRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $widgetRoot
$build = Join-Path $widgetRoot 'build'
$layout = Join-Path $build 'layout'
$dist = Join-Path $widgetRoot 'dist'
$msix = Join-Path $dist 'ClaudeLockWidget.msix'
$clsid = [regex]::Match((Get-Content (Join-Path $widgetRoot 'Provider\WidgetProvider.cs') -Raw), 'ClsIdText = "([0-9A-Fa-f-]{36})"').Groups[1].Value
if (-not $clsid) { throw 'Could not read the provider CLSID from WidgetProvider.cs' }
$ver = [regex]::Match((Get-Content (Join-Path $repoRoot 'src\lib\Common.ps1') -Raw), "ClwVersion = '(\d+\.\d+\.\d+)'").Groups[1].Value
if (-not $ver) { throw 'Could not read the version from src\lib\Common.ps1' }
$pkgVersion = "$ver.0"
$rid = "win-$Arch"

function Write-Step([string]$t) { Write-Host "==> $t" -ForegroundColor Cyan }

function Get-SdkTool {
    param([string]$Name)
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path $kits) {
        $hit = Get-ChildItem $kits -Recurse -Filter $Name -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $tools = Join-Path $build 'tools'
    $found = Get-ChildItem $tools -Recurse -Filter $Name -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    if ($found) { return $found.FullName }

    Write-Step 'Windows SDK not found - downloading build tools from nuget.org (Microsoft.Windows.SDK.BuildTools)'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $versions = (Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/index.json').versions | Where-Object { $_ -notmatch '-' }
    $latest = $versions | Select-Object -Last 1
    [void](New-Item -ItemType Directory -Path $tools -Force)
    $zip = Join-Path $tools 'buildtools.zip'
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/$latest/microsoft.windows.sdk.buildtools.$latest.nupkg" -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tools 'pkg') -Force
    $found = Get-ChildItem $tools -Recurse -Filter $Name | Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    if (-not $found) { throw "$Name not found in the build tools package." }
    $found.FullName
}

# ------------------------------------------------------------------ 1. publish
Write-Step "Publishing provider ($rid, self-contained)"
if (Test-Path $layout) { Remove-Item $layout -Recurse -Force }
[void](New-Item -ItemType Directory -Path $layout -Force)
& dotnet publish (Join-Path $widgetRoot 'Provider\ClaudeLockWidget.Provider.csproj') -c Release -r $rid --self-contained `
    -p:Version=$ver -p:DebugType=none -p:DebugSymbols=false -o $layout --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

# ------------------------------------------------------------------ 2. assets + manifest
Write-Step 'Generating icons and widget screenshot'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $widgetRoot 'New-WidgetAssets.ps1') -OutDir (Join-Path $layout 'Assets') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'asset generation failed' }

Write-Step "Writing AppxManifest.xml (v$pkgVersion, $Arch)"
$manifest = Get-Content (Join-Path $widgetRoot 'Package\AppxManifest.template.xml') -Raw
$manifest = $manifest.Replace('{{PUBLISHER}}', $Publisher).Replace('{{VERSION}}', $pkgVersion).Replace('{{ARCH}}', $Arch).Replace('{{CLSID}}', $clsid)
[void]([xml]$manifest)    # must be well-formed
[System.IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ 3. pack
Write-Step 'Packing MSIX'
[void](New-Item -ItemType Directory -Path $dist -Force)
if (Test-Path $msix) { Remove-Item $msix -Force }
$makeappx = Get-SdkTool 'makeappx.exe'
& $makeappx pack /d $layout /p $msix /o | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'makeappx failed' }

# ------------------------------------------------------------------ 4. sign
Write-Step 'Signing'
$signtool = Get-SdkTool 'signtool.exe'
$cer = Join-Path $dist 'ClaudeLockWidget.cer'
if ($PfxPath) {
    & $signtool sign /fd SHA256 /f $PfxPath /p $PfxPassword $msix | Out-Host
    $pfx = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfxPath, $PfxPassword)
    [System.IO.File]::WriteAllBytes($cer, $pfx.Export('Cert'))
}
else {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Publisher -and $_.NotAfter -gt (Get-Date).AddDays(30) -and $_.HasPrivateKey } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        Write-Step "Creating a self-signed code-signing certificate ($Publisher, 5 years) in Cert:\CurrentUser\My"
        $cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature -FriendlyName 'Claude Lock Widget (sideloading)' `
            -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(5) `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    }
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My $msix | Out-Host
    [System.IO.File]::WriteAllBytes($cer, $cert.Export('Cert'))
}
if ($LASTEXITCODE -ne 0) { throw 'signtool failed' }

Copy-Item (Join-Path $widgetRoot 'Install-Widget.ps1') $dist -Force
Write-Host ''
Write-Host ('Built {0} ({1:N1} MB)' -f $msix, ((Get-Item $msix).Length / 1MB)) -ForegroundColor Green
Write-Host "Install with: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $dist 'Install-Widget.ps1')`"" -ForegroundColor Green
