[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$WidgetPath = Join-Path $PSScriptRoot 'Guardian-Widget.ps1'
$LauncherPath = Join-Path $PSScriptRoot 'Launch-Guardian-Widget.vbs'
$TaskName = 'SleepGuardian_Widget'
if (-not (Test-Path -LiteralPath $WidgetPath)) { throw "缺少桌面小窗脚本：$WidgetPath" }
if (-not (Test-Path -LiteralPath $LauncherPath)) { throw "缺少静默启动器：$LauncherPath" }
foreach($name in @('Learning-Engine.ps1','Learning-Library.ps1','knowledge-bank.json','official-index.json')){
    if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))){throw "缺少学习功能文件：$name"}
}

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$arguments = "//B //Nologo `"$LauncherPath`""
$action = New-ScheduledTaskAction -Execute $wscript -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -Hidden

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description '睡眠守卫桌面开关：可拖动、可隐藏，提供 N4 每日学习答题停用和每月三次纵容。'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop '睡眠守卫.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $wscript
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = '显示睡眠守卫桌面开关（Ctrl+Alt+S）'
$shortcut.Hotkey = 'CTRL+ALT+S'
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
$shortcut.Save()

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Milliseconds 800

[pscustomobject]@{
    TaskName = $TaskName
    TaskState = (Get-ScheduledTask -TaskName $TaskName).State
    DesktopShortcut = $shortcutPath
    Hotkey = 'Ctrl+Alt+S'
    Launcher = $LauncherPath
} | Format-List
