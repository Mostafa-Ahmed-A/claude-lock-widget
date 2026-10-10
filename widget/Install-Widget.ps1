<#
.SYNOPSIS
    Installs (or removes) the Claude Lock Widget package so it appears under
    Settings > Personalization > Lock screen > Widgets > Add widget.

.DESCRIPTION
    The package is signed with a self-signed certificate. Windows only installs packages whose signer it
    trusts, so the certificate is added to "Trusted People" for this PC - that is the one step that needs
    an administrator prompt (UAC). The package itself installs without admin rights.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Install-Widget.ps1
    powershell -ExecutionPolicy Bypass -File Install-Widget.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Msix,              # default: ClaudeLockWidget.msix next to this script, or in .\dist
    [string]$Cert,              # default: ClaudeLockWidget.cer next to the package
    [switch]$Uninstall,
    [switch]$TrustCertOnly,     # internal: runs elevated to import the certificate
    [switch]$NoOpenSettings
)

$ErrorActionPreference = 'Stop'
$packageName = 'ClaudeLockWidget.Provider'
$packageDir = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ClaudeLockWidget.msix')) { $PSScriptRoot } else { Join-Path $PSScriptRoot 'dist' }
if (-not $Msix) { $Msix = Join-Path $packageDir 'ClaudeLockWidget.msix' }
if (-not $Cert) { $Cert = Join-Path (Split-Path -Parent $Msix) 'ClaudeLockWidget.cer' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CertTrusted([string]$CerPath) {
    $thumb = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)).Thumbprint
    [bool](Get-ChildItem Cert:\LocalMachine\TrustedPeople -ErrorAction SilentlyContinue | Where-Object Thumbprint -eq $thumb)
}

if ($TrustCertOnly) {
    # elevated child process: only imports the (public) certificate
    Import-Certificate -FilePath $Cert -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    exit 0
}

if ($Uninstall) {
    $pkg = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue
    if ($pkg) { $pkg | Remove-AppxPackage; Write-Host 'Widget package removed.' -ForegroundColor Green }
    else { Write-Host 'Widget package is not installed.' -ForegroundColor Yellow }
    exit 0
}

if (-not (Test-Path -LiteralPath $Msix)) { throw "Package not found: $Msix (build it with widget\Build-Widget.ps1 or download a release)." }
if (-not (Test-Path -LiteralPath $Cert)) { throw "Certificate not found: $Cert" }

if (-not (Test-CertTrusted $Cert)) {
    Write-Host 'The widget is signed with its own certificate. Windows needs to trust it once (admin prompt) ...' -ForegroundColor Cyan
    if (Test-Admin) { Import-Certificate -FilePath $Cert -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null }
    else {
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-TrustCertOnly', '-Cert', ('"{0}"' -f $Cert))
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -WindowStyle Hidden
        }
        catch { Write-Host "  The admin prompt was cancelled or blocked: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if (-not (Test-CertTrusted $Cert)) {
        throw ("The certificate is not trusted yet. Do it by hand: right-click '$Cert' > Install Certificate > Local Machine > " +
            "Place all certificates in the following store > Trusted People. Then run this script again.")
    }
    Write-Host '  Certificate trusted.' -ForegroundColor Green
}

Write-Host 'Installing the widget package ...' -ForegroundColor Cyan
# -ForceApplicationShutdown: when updating, Windows stops the running provider (it is running while a widget is
# pinned) and starts it again by itself when the widget is next shown.
Add-AppxPackage -Path $Msix -ForceUpdateFromAnyVersion -ForceApplicationShutdown
$pkg = Get-AppxPackage -Name $packageName
Write-Host ("Installed {0} v{1}" -f $pkg.Name, $pkg.Version) -ForegroundColor Green
Write-Host ''
Write-Host 'Now add it: Settings > Personalization > Lock screen > Widgets > Add widget > "Claude usage".' -ForegroundColor Green
if (-not $NoOpenSettings) { try { Start-Process 'ms-settings:lockscreen' } catch { } }
