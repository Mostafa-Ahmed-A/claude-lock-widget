<#
.SYNOPSIS
    One-time maintainer setup: creates a release signing certificate with an EXPORTABLE key and stores it
    as the GitHub Actions secrets CLW_PFX_BASE64 / CLW_PFX_PASSWORD that .github\workflows\release.yml uses.

.DESCRIPTION
    Why: Build-Widget.ps1 creates its local certificate non-exportable (the safe default). A release workflow
    needs the key in a secret, and signing every release with the SAME certificate means users trust it once.

    What it does:
      1. creates (or, with -ReuseExisting, finds) an exportable code-signing certificate in Cert:\CurrentUser\My
      2. exports it to a temporary .pfx protected by a random 32-character password (never shown or saved)
      3. uploads the .pfx (base64) and the password as repository secrets with the GitHub CLI
      4. overwrites and deletes the temporary file

    The private key stays in your certificate store (exportable, so you can repeat this). Requires `gh auth login`.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File widget\Set-ReleaseSigning.ps1 -Repo Mostafa-Ahmed-A/claude-lock-widget
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,                  # owner/name
    [string]$Subject = 'CN=ClaudeLockWidget',             # must equal Build-Widget.ps1's -Publisher
    [switch]$ReuseExisting                                # use an existing exportable certificate instead of creating one
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required: https://cli.github.com' }
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'Run "gh auth login" first.' }

function New-RandomPassword([int]$Length = 32) {
    $chars = ([char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789')
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Set-GhSecretFromFile([string]$Name, [string]$File) {
    # stdin redirection from a file keeps the value exact (piping from PowerShell would append a newline)
    $out = & cmd.exe /c ('gh secret set {0} --repo {1} < "{2}"' -f $Name, $Repo, $File) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not set secret ${Name}: $out" }
}

# ---- 1. certificate
$cert = $null
if ($ReuseExisting) {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date).AddDays(30) -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
}
if (-not $cert) {
    Write-Host "Creating an exportable code-signing certificate ($Subject, 5 years) ..." -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature -KeyExportPolicy Exportable `
        -FriendlyName 'Claude Lock Widget (release signing)' -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}
Write-Host ("Certificate {0} (expires {1:yyyy-MM-dd})" -f $cert.Thumbprint, $cert.NotAfter) -ForegroundColor Green

# ---- 2. export to a temp .pfx and 3. upload
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('clw-sign-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$pfx = Join-Path $work 'sign.pfx'; $b64File = Join-Path $work 'pfx.b64'; $pwFile = Join-Path $work 'pw.txt'
try {
    $password = New-RandomPassword
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString $password -AsPlainText -Force) | Out-Null
    [System.IO.File]::WriteAllText($b64File, [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfx)))
    [System.IO.File]::WriteAllText($pwFile, $password)
    Set-GhSecretFromFile 'CLW_PFX_BASE64' $b64File
    Set-GhSecretFromFile 'CLW_PFX_PASSWORD' $pwFile
    $password = $null
}
finally {
    # ---- 4. overwrite and remove the temporary files
    foreach ($f in $pfx, $b64File, $pwFile) {
        if (Test-Path -LiteralPath $f) {
            try { $len = (Get-Item -LiteralPath $f).Length; [System.IO.File]::WriteAllBytes($f, (New-Object byte[] $len)) } catch { }
            [System.IO.File]::Delete($f)
        }
    }
    [System.IO.Directory]::Delete($work, $true)
}

Write-Host ''
Write-Host "Secrets stored on $Repo :" -ForegroundColor Green
& gh secret list --repo $Repo
Write-Host ''
Write-Host 'Next: tag a release (git tag v2.0.1; git push origin v2.0.1). Releases are now signed with this certificate.' -ForegroundColor Cyan
Write-Host 'Your own PC trusts the older local certificate; the first release you install will ask once (admin prompt) to trust this one.' -ForegroundColor Gray
