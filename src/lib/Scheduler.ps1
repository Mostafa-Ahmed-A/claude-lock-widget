# Scheduler.ps1 - per-user Scheduled Task that keeps the lock screen fresh. No admin rights needed.
#
# Triggers: at sign-in, on workstation unlock, on workstation lock, and every N minutes.
# NOTE: keep this file ASCII-only.

Set-StrictMode -Version 1.0

$script:ClwTaskName = 'ClaudeLockWidget'

function Get-ClwTaskXml {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$IntervalMinutes,
        [bool]$IncludeSessionTriggers = $true,
        [bool]$Headless = $true
    )

    $user = [System.Security.SecurityElement]::Escape([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $start = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" refresh -Quiet' -f $ScriptPath

    if ($Headless) {
        # conhost --headless runs PowerShell without flashing a console window.
        $command = Join-Path $env:windir 'System32\conhost.exe'
        $arguments = '--headless powershell.exe ' + $psArgs
    }
    else {
        $command = 'powershell.exe'
        $arguments = '-WindowStyle Hidden ' + $psArgs
    }
    $command = [System.Security.SecurityElement]::Escape($command)
    $arguments = [System.Security.SecurityElement]::Escape($arguments)

    $sessionTriggers = ''
    if ($IncludeSessionTriggers) {
        $sessionTriggers = @"

    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
      <UserId>$user</UserId>
    </SessionStateChangeTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionLock</StateChange>
      <UserId>$user</UserId>
    </SessionStateChangeTrigger>
"@
    }

    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>ClaudeLockWidget: keeps the Windows lock screen showing your Claude Code usage.</Description>
    <Author>ClaudeLockWidget</Author>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT${IntervalMinutes}M</Interval>
      </Repetition>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>$sessionTriggers
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-ClwTask {
    # Registers (or replaces) the task. Falls back to simpler variants if the first attempt is rejected.
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][int]$IntervalMinutes, [string]$TaskName = $script:ClwTaskName)

    $variants = @(
        @{ Session = $true; Headless = $true },
        @{ Session = $false; Headless = $true },
        @{ Session = $false; Headless = $false }
    )
    $lastError = $null
    foreach ($v in $variants) {
        try {
            $xml = Get-ClwTaskXml -ScriptPath $ScriptPath -IntervalMinutes $IntervalMinutes -IncludeSessionTriggers $v.Session -Headless $v.Headless
            [void](Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force -ErrorAction Stop)
            return [pscustomobject]@{ Registered = $true; SessionTriggers = $v.Session; Headless = $v.Headless }
        }
        catch { $lastError = $_.Exception.Message }
    }
    throw "Could not register the scheduled task: $lastError"
}

function Unregister-ClwTask {
    param([string]$TaskName = $script:ClwTaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $false }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    $true
}

function Get-ClwTaskStatus {
    param([string]$TaskName = $script:ClwTaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{
        State          = [string]$task.State
        LastRunTime    = if ($info) { $info.LastRunTime } else { $null }
        LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
        NextRunTime    = if ($info) { $info.NextRunTime } else { $null }
        Triggers       = @($task.Triggers).Count
    }
}
