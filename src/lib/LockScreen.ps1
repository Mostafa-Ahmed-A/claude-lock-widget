# LockScreen.ps1 - sets the Windows lock screen picture and queries the display.
#
# Windows has no public API for third-party apps to draw arbitrary widgets on the lock screen.
# The supported route is the per-user WinRT call Windows.System.UserProfile.LockScreen
# .SetImageFileAsync, which needs no administrator rights and works for unpackaged apps.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0

function Initialize-ClwWinRt {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    [void][Windows.Foundation.IAsyncAction, Windows.Foundation, ContentType = WindowsRuntime]
}

function Wait-ClwWinRt {
    # Blocks on a WinRT IAsyncAction / IAsyncOperation<T> (PowerShell 5.1 cannot 'await' natively).
    param([Parameter(Mandatory)]$Operation, [Type]$ResultType, [int]$TimeoutMs = 20000)

    $extensions = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1
    }
    if ($ResultType) {
        $method = $extensions | Where-Object { $_.IsGenericMethod -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    }
    else {
        $method = $extensions | Where-Object { -not $_.IsGenericMethod -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
        $task = $method.Invoke($null, @($Operation))
    }
    if (-not $task.Wait($TimeoutMs)) { throw 'The Windows lock screen call timed out.' }
    if ($task.IsFaulted) { throw $task.Exception.InnerException }
    if ($ResultType) { return $task.Result }
}

function Test-ClwLockScreenApi {
    # Read-only probe: can this process talk to the lock screen API at all?
    try {
        Initialize-ClwWinRt
        $stream = [Windows.System.UserProfile.LockScreen]::GetImageStream()
        return $true
    }
    catch { return $false }
}

function Set-ClwLockScreenImage {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Image not found: $Path" }
    Initialize-ClwWinRt
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $file = Wait-ClwWinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
    Wait-ClwWinRt ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file))
}

function Get-ClwScreenSize {
    # Physical pixel size of the primary display (not DPI-scaled).
    if (-not ('ClwNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class ClwNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
'@
    }
    [void][ClwNative]::SetProcessDPIAware()
    $w = [ClwNative]::GetSystemMetrics(0)   # SM_CXSCREEN
    $h = [ClwNative]::GetSystemMetrics(1)   # SM_CYSCREEN
    if ($w -lt 640 -or $h -lt 480) { $w = 1920; $h = 1080 }
    [pscustomobject]@{ Width = $w; Height = $h }
}

function Get-ClwLockScreenPolicyWarnings {
    # Group Policy / MDM can force a lock screen image or forbid changes.
    $warnings = @()
    $keys = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    )
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $props = Get-ItemProperty -LiteralPath $k
        if ($props.PSObject.Properties['LockScreenImage'] -and $props.LockScreenImage) { $warnings += "Policy forces a lock screen image ($k)." }
        if ($props.PSObject.Properties['NoChangingLockScreen'] -and $props.NoChangingLockScreen -eq 1) { $warnings += "Policy blocks changing the lock screen ($k)." }
        if ($props.PSObject.Properties['NoLockScreen'] -and $props.NoLockScreen -eq 1) { $warnings += "Policy disables the lock screen ($k)." }
    }
    $warnings
}

function Get-ClwLockScreenMode {
    # 'spotlight' when "Windows spotlight" rotates the lock screen picture, otherwise 'picture'.
    try {
        $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name RotatingLockScreenEnabled -ErrorAction Stop).RotatingLockScreenEnabled
        if ($v -eq 1) { return 'spotlight' }
    }
    catch { }
    'picture'
}

function Remove-ClwOldImages {
    # Each refresh writes a fresh file (Windows can cache by path); keep only the newest few.
    param([string]$Directory, [int]$Keep = 3)
    Get-ChildItem -LiteralPath $Directory -Filter 'lockscreen-*.png' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
