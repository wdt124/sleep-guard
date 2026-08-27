[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$MonitorPath = Join-Path $PSScriptRoot 'SleepGuardian.ps1'
if (-not (Test-Path -LiteralPath $ConfigPath) -or -not (Test-Path -LiteralPath $MonitorPath)) {
    throw 'Sleep Guardian files are incomplete.'
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskName = [string]$config.taskName
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MonitorPath`""

$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $PSScriptRoot
$windowStart = [TimeSpan]::Parse([string]$config.windowStart)
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add($windowStart))
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 24) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -Hidden

$task = New-ScheduledTask `
    -Action $action `
    -Trigger @($dailyTrigger, $logonTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description "每天 $($config.windowStart)-$($config.windowEnd) 监测浏览器和游戏平台，关闭夜间娱乐程序并弹出睡眠提醒。"

Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

$start = [TimeSpan]::Parse([string]$config.windowStart)
$end = [TimeSpan]::Parse([string]$config.windowEnd)
$now = (Get-Date).TimeOfDay
$inWindow = if ($start -lt $end) { $now -ge $start -and $now -lt $end } else { $now -ge $start -or $now -lt $end }
if ($inWindow) { Start-ScheduledTask -TaskName $taskName }

& $MonitorPath -SelfTest
& (Join-Path $PSScriptRoot 'Install-Guardian-Widget.ps1')
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State, Author, Description | Format-List
