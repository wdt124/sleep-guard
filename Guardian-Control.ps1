[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Status', 'Enable', 'DisableTonight', 'DisableIndefinitely')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$DataRoot = Join-Path $env:LOCALAPPDATA 'SleepGuardian'
$StatePath = Join-Path $DataRoot 'state.json'
[System.IO.Directory]::CreateDirectory($DataRoot) | Out-Null

function Get-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try { return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Test-IsRestrictedTime {
    $start = [TimeSpan]::Parse([string]$Config.windowStart)
    $end = [TimeSpan]::Parse([string]$Config.windowEnd)
    $now = (Get-Date).TimeOfDay
    if ($start -lt $end) { return ($now -ge $start -and $now -lt $end) }
    return ($now -ge $start -or $now -lt $end)
}

function Get-ReasonHash {
    param([string]$Reason)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Reason)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Invoke-FrictionChallenge {
    param([int]$Seconds, [switch]$Indefinite)
    $minimum = if ($Indefinite) { 30 } else { 20 }
    $reason = Read-Host "请写下停用理由（至少 $minimum 个字符；理由不会明文保存）"
    if ([string]::IsNullOrWhiteSpace($reason) -or $reason.Trim().Length -lt $minimum) {
        throw '理由太短，未关闭守卫。'
    }

    $code = Get-Random -Minimum 100000 -Maximum 999999
    Write-Host "冷静期开始：$Seconds 秒。关闭终端即可取消。" -ForegroundColor Yellow
    for ($remaining = $Seconds; $remaining -gt 0; $remaining -= 10) {
        Write-Host ("还剩 {0} 秒……" -f $remaining)
        Start-Sleep -Seconds ([Math]::Min(10, $remaining))
    }

    $phrase = if ($Indefinite) {
        "我确认长期停用睡眠守卫，并愿意重新手动开启它。验证码 $code"
    } else {
        "我知道继续用电脑会透支之后的状态，并确认只停用到监管结束时间 $($Config.windowEnd)。验证码 $code"
    }
    Write-Host '请完整输入下面这句话：' -ForegroundColor Yellow
    Write-Host $phrase -ForegroundColor Cyan
    $typed = Read-Host
    if ($typed -cne $phrase) { throw '确认句不完全一致，未关闭守卫。' }
    if ($Indefinite) {
        $codeCharacters = [char[]]([string]$code)
        [array]::Reverse($codeCharacters)
        $reverseCode = -join $codeCharacters
        $second = Read-Host "最后确认：请输入倒序验证码 $reverseCode"
        if ($second -cne $reverseCode) { throw '第二次确认失败，未关闭守卫。' }
    }
    return $reason
}

function Write-DisabledState {
    param([DateTimeOffset]$Until, [string]$Mode, [string]$Reason)
    $state = [ordered]@{
        disabledUntil = $Until.ToString('o')
        mode = $Mode
        createdAt = [DateTimeOffset]::Now.ToString('o')
        reasonHash = Get-ReasonHash $Reason
    }
    $json = $state | ConvertTo-Json
    [System.IO.File]::WriteAllText($StatePath, $json, [System.Text.UTF8Encoding]::new($false))
}

switch ($Action) {
    'Status' {
        $task = Get-ScheduledTask -TaskName ([string]$Config.taskName) -ErrorAction SilentlyContinue
        $state = Get-State
        $disabledUntil = $null
        if ($null -ne $state) { try { $disabledUntil = [DateTimeOffset]::Parse([string]$state.disabledUntil) } catch {} }
        [pscustomobject]@{
            TaskName = [string]$Config.taskName
            TaskState = if ($null -ne $task) { $task.State } else { 'Not installed' }
            Window = "$($Config.windowStart)-$($Config.windowEnd)"
            GuardianEnabled = ($null -eq $disabledUntil -or $disabledUntil -le [DateTimeOffset]::Now)
            DisabledUntil = $disabledUntil
        } | Format-List
    }
    'Enable' {
        if (Test-Path -LiteralPath $StatePath) { [System.IO.File]::Delete($StatePath) }
        if (Test-IsRestrictedTime) {
            Start-ScheduledTask -TaskName ([string]$Config.taskName) -ErrorAction SilentlyContinue
        }
        Write-Host '睡眠守卫已开启。' -ForegroundColor Green
    }
    'DisableTonight' {
        $reason = Invoke-FrictionChallenge -Seconds 90
        $now = Get-Date
        $until = Get-Date -Hour 6 -Minute 0 -Second 0
        if ($until -le $now) { $until = $until.AddDays(1) }
        Write-DisabledState ([DateTimeOffset]$until) 'Tonight' $reason
        Stop-ScheduledTask -TaskName ([string]$Config.taskName) -ErrorAction SilentlyContinue
        Write-Host "已停用到 $($until.ToString('yyyy-MM-dd HH:mm'))。" -ForegroundColor Yellow
    }
    'DisableIndefinitely' {
        $reason = Invoke-FrictionChallenge -Seconds 180 -Indefinite
        Write-DisabledState ([DateTimeOffset]::Parse('2099-12-31T23:59:59+08:00')) 'Indefinite' $reason
        Stop-ScheduledTask -TaskName ([string]$Config.taskName) -ErrorAction SilentlyContinue
        Write-Host '已长期停用；重新开启需要运行 Guardian-Control.ps1 -Action Enable。' -ForegroundColor Yellow
    }
}
