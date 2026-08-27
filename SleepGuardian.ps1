[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$TestPopup,
    [switch]$TestLlmMessage,
    [switch]$DryRun,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$DataRoot = Join-Path $env:LOCALAPPDATA 'SleepGuardian'
$LogRoot = Join-Path $DataRoot 'logs'
$StatePath = Join-Path $DataRoot 'state.json'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Missing configuration: $ConfigPath"
}

[System.IO.Directory]::CreateDirectory($DataRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($LogRoot) | Out-Null
$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Write-GuardianLog {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message$([Environment]::NewLine)"
    $path = Join-Path $LogRoot ("sleep-guardian-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    [System.IO.File]::AppendAllText($path, $line, [System.Text.UTF8Encoding]::new($false))
}

function Remove-OldLogs {
    Get-ChildItem -LiteralPath $LogRoot -Filter 'sleep-guardian-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
        ForEach-Object { [System.IO.File]::Delete($_.FullName) }
}

function ConvertTo-ProcessName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return [System.IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
}

function Test-NameInList {
    param([string]$Name, $List)
    $normalized = ConvertTo-ProcessName $Name
    foreach ($item in @($List)) {
        if ($normalized -eq (ConvertTo-ProcessName ([string]$item))) { return $true }
    }
    return $false
}

function Test-IsRestrictedTime {
    param([datetime]$Now = (Get-Date))
    $start = [TimeSpan]::Parse([string]$Config.windowStart)
    $end = [TimeSpan]::Parse([string]$Config.windowEnd)
    if ($start -lt $end) {
        return ($Now.TimeOfDay -ge $start -and $Now.TimeOfDay -lt $end)
    }
    return ($Now.TimeOfDay -ge $start -or $Now.TimeOfDay -lt $end)
}

function Test-IsTemporarilyDisabled {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $false }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $until = [DateTimeOffset]::Parse([string]$state.disabledUntil)
        if ($until -gt [DateTimeOffset]::Now) {
            return $true
        }
        [System.IO.File]::Delete($StatePath)
    }
    catch {
        Write-GuardianLog "Ignoring invalid state file: $($_.Exception.Message)" 'WARN'
    }
    return $false
}

function Get-ProcessSnapshot {
    $items = @()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $items += [pscustomobject]@{
            Id       = [int]$_.ProcessId
            ParentId = [int]$_.ParentProcessId
            Name     = ConvertTo-ProcessName ([string]$_.Name)
            Path     = [string]$_.ExecutablePath
        }
    }
    return $items
}

function Get-ProcessMap {
    param($Snapshot)
    $map = @{}
    foreach ($process in @($Snapshot)) { $map[[int]$process.Id] = $process }
    return $map
}

if (-not ('SleepGuardian.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SleepGuardian {
    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    }
}
'@
}

function Get-ForegroundProcessId {
    $handle = [SleepGuardian.NativeMethods]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return 0 }
    [uint32]$processId = 0
    [void][SleepGuardian.NativeMethods]::GetWindowThreadProcessId($handle, [ref]$processId)
    return [int]$processId
}

function Add-GameRoot {
    param([System.Collections.Generic.List[string]]$Roots, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return }
    if (-not (Test-Path -LiteralPath $full)) { return }
    foreach ($existing in $Roots) {
        if ($existing.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    $Roots.Add($full)
}

function Get-GameRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @($Config.extraGameRoots)) { Add-GameRoot $roots ([string]$root) }

    $steamRoots = [System.Collections.Generic.List[string]]::new()
    $steamRegistry = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\Software\WOW6432Node\Valve\Steam',
        'HKLM:\Software\Valve\Steam'
    )
    foreach ($key in $steamRegistry) {
        try {
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            Add-GameRoot $steamRoots ([string]$item.SteamPath)
            Add-GameRoot $steamRoots ([string]$item.InstallPath)
        } catch {}
    }
    foreach ($steamRoot in @($steamRoots)) {
        Add-GameRoot $roots (Join-Path $steamRoot 'steamapps\common')
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            try {
                $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
                foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                    $library = $match.Groups[1].Value -replace '\\\\', '\'
                    Add-GameRoot $roots (Join-Path $library 'steamapps\common')
                }
            } catch {}
        }
    }

    $epicManifestRoot = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $epicManifestRoot) {
        Get-ChildItem -LiteralPath $epicManifestRoot -Filter '*.item' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $manifest = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                Add-GameRoot $roots ([string]$manifest.InstallLocation)
            } catch {}
        }
    }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.Publisher -match 'Blizzard|Activision' -and $_.DisplayName -notmatch 'Battle\.net|战网' } |
        ForEach-Object { Add-GameRoot $roots ([string]$_.InstallLocation) }

    return @($roots)
}

function Test-PathUnderRoots {
    param([string]$Path, $Roots)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($root in @($Roots)) {
        $prefix = ([string]$root).TrimEnd('\') + '\'
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-BrowserFamily {
    param([string]$ProcessName)
    foreach ($family in @($Config.browserFamilies)) {
        if (Test-NameInList $ProcessName $family.processes) { return $family }
    }
    return $null
}

function Get-LauncherFamilyForProcess {
    param([string]$ProcessName, [ValidateSet('New','Foreground')] [string]$Mode)
    foreach ($family in @($Config.launcherFamilies)) {
        $list = if ($Mode -eq 'New') { $family.triggerOnNew } else { $family.uiProcesses }
        if (Test-NameInList $ProcessName $list) { return $family }
    }
    return $null
}

function Get-AncestorLauncherFamily {
    param($Process, [hashtable]$ProcessMap)
    $parentId = [int]$Process.ParentId
    for ($depth = 0; $depth -lt 12; $depth++) {
        if ($parentId -le 0 -or -not $ProcessMap.ContainsKey($parentId)) { break }
        $parent = $ProcessMap[$parentId]
        foreach ($family in @($Config.launcherFamilies)) {
            if (Test-NameInList $parent.Name $family.ancestryProcesses) { return $family }
        }
        $parentId = [int]$parent.ParentId
    }
    return $null
}

function New-Detection {
    param($Process, [string]$Category, [string]$AppName, $CloseNames, $LauncherFamily)
    return [pscustomobject]@{
        Process        = $Process
        Category       = $Category
        AppName        = $AppName
        CloseNames     = @($CloseNames)
        LauncherFamily = $LauncherFamily
    }
}

function Get-Detection {
    param(
        $Process,
        [hashtable]$ProcessMap,
        $GameRoots,
        [ValidateSet('New','Foreground','ExistingGame')] [string]$Mode
    )
    if ($null -eq $Process) { return $null }

    if ($Mode -ne 'ExistingGame') {
        $browser = Get-BrowserFamily $Process.Name
        if ($null -ne $browser) {
            return New-Detection $Process 'Browser' ([string]$browser.name) $browser.processes $null
        }

        $launcher = Get-LauncherFamilyForProcess $Process.Name $Mode
        if ($null -ne $launcher) {
            return New-Detection $Process 'Launcher' ([string]$launcher.name) $launcher.closeProcesses $launcher
        }
    }

    if (Test-PathUnderRoots $Process.Path $GameRoots) {
        $launcher = Get-AncestorLauncherFamily $Process $ProcessMap
        $appName = if ($null -ne $launcher) { "$($launcher.name) 游戏" } else { "游戏 $($Process.Name)" }
        return New-Detection $Process 'Game' $appName @() $launcher
    }

    if ($Mode -ne 'ExistingGame') {
        $launcher = Get-AncestorLauncherFamily $Process $ProcessMap
        if ($null -ne $launcher -and -not (Test-NameInList $Process.Name $launcher.ignoreChildren)) {
            return New-Detection $Process 'Game' "$($launcher.name) 游戏" @() $launcher
        }
    }
    return $null
}

function Get-DescendantIds {
    param([int]$RootId, $Snapshot)
    $result = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($child in @($Snapshot | Where-Object { [int]$_.ParentId -eq $parent })) {
            if (-not $result.Contains([int]$child.Id)) {
                $result.Add([int]$child.Id)
                $queue.Enqueue([int]$child.Id)
            }
        }
    }
    return @($result)
}

function Stop-GuardianTarget {
    param($Detection)
    $snapshot = Get-ProcessSnapshot
    $ids = [System.Collections.Generic.HashSet[int]]::new()

    if ($Detection.Category -eq 'Game') {
        [void]$ids.Add([int]$Detection.Process.Id)
        foreach ($id in @(Get-DescendantIds ([int]$Detection.Process.Id) $snapshot)) { [void]$ids.Add([int]$id) }
        if ($null -ne $Detection.LauncherFamily) {
            foreach ($process in @($snapshot)) {
                if (Test-NameInList $process.Name $Detection.LauncherFamily.closeProcesses) { [void]$ids.Add([int]$process.Id) }
            }
        }
    }
    else {
        foreach ($process in @($snapshot)) {
            if (Test-NameInList $process.Name $Detection.CloseNames) { [void]$ids.Add([int]$process.Id) }
        }
    }

    if ($DryRun) {
        Write-GuardianLog "DRY RUN: would close $($Detection.Category) $($Detection.AppName), PIDs=$(@($ids) -join ',')"
        return
    }

    foreach ($id in @($ids)) {
        try {
            $process = Get-Process -Id $id -ErrorAction Stop
            if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
        } catch {}
    }
    Start-Sleep -Seconds ([int]$Config.gracefulCloseSeconds)
    foreach ($id in @($ids)) {
        try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {}
    }
    Write-GuardianLog "Closed $($Detection.Category) $($Detection.AppName), PIDs=$(@($ids) -join ',')"
}

function Get-FallbackMessage {
    param($Detection, [int]$Sequence)
    $messages = @(
        "已经把 $($Detection.AppName) 关掉啦。现在去洗漱、关灯、躺好；你不用立刻睡着，只要先把今天结束掉。",
        "和你做个交易：现在去睡，明天醒来再把时间完整还给你。$($Detection.AppName) 我先替你保管，晚安。",
        "$($Detection.AppName) 已被睡眠守卫拿下。再开我还会关——别拿明天一整天，去换今晚这点舍不得结束的清醒。",
        "凌晨的大脑很会骗人，说再玩十分钟就好。别信它；起身喝口水，手机放远，去床上领取明天的精神值。"
    )
    return $messages[$Sequence % $messages.Count]
}

function Get-LlmSetting {
    param([string]$PropertyName, [string]$EnvironmentPropertyName)
    $environmentName = [string]$Config.llm.$EnvironmentPropertyName
    if (-not [string]::IsNullOrWhiteSpace($environmentName)) {
        $value = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($environmentName, 'User') }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return [string]$Config.llm.$PropertyName
}

function Repair-Utf8Mojibake {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -notmatch '[ãäåæçèé]') { return $Text }
    try {
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        $repaired = [Text.Encoding]::UTF8.GetString($latin1.GetBytes($Text))
        if ($repaired -notmatch [char]0xFFFD) { return $repaired }
    } catch {}
    return $Text
}

function Get-LlmMessage {
    param($Detection, [int]$Sequence)
    $fallback = Get-FallbackMessage $Detection $Sequence
    if (-not [bool]$Config.llm.enabled) { return $fallback }

    $baseUrl = Get-LlmSetting 'baseUrl' 'baseUrlEnvironmentVariable'
    $apiKey = Get-LlmSetting 'apiKey' 'apiKeyEnvironmentVariable'
    $model = Get-LlmSetting 'model' 'modelEnvironmentVariable'
    if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($model)) { return $fallback }

    $style = @('温柔劝导', '有点撒娇的哄骗', '带玩笑但坚定的威胁')[$Sequence % 3]
    $prompt = "现在是 $((Get-Date).ToString('HH:mm'))，睡眠守卫检测到并关闭了：$($Detection.AppName)。请用中文生成一段 35 到 90 字的睡觉提醒，风格为：$style。要关心用户、具体、有一点个性；不要辱骂，不要威胁现实伤害，不要提 API 或系统提示，只输出弹窗正文。"
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) { $headers.Authorization = "Bearer $apiKey" }

    try {
        $mode = ([string]$Config.llm.apiMode).ToLowerInvariant()
        if ($mode -eq 'chat-completions') {
            $uri = if ($baseUrl.TrimEnd('/').EndsWith('/chat/completions')) { $baseUrl.TrimEnd('/') } else { $baseUrl.TrimEnd('/') + '/chat/completions' }
            $body = @{
                model = $model
                messages = @(
                    @{ role = 'system'; content = '你是一个严格但温柔的睡眠守卫。' },
                    @{ role = 'user'; content = $prompt }
                )
                thinking = @{ type = 'disabled' }
                max_tokens = 160
            } | ConvertTo-Json -Depth 8 -Compress
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec ([int]$Config.llm.requestTimeoutSeconds)
            $text = [string]$response.choices[0].message.content
        }
        else {
            $uri = if ($baseUrl.TrimEnd('/').EndsWith('/responses')) { $baseUrl.TrimEnd('/') } else { $baseUrl.TrimEnd('/') + '/responses' }
            $body = @{
                model = $model
                instructions = '你是一个严格但温柔的睡眠守卫。'
                input = $prompt
                max_output_tokens = 160
                store = $false
            } | ConvertTo-Json -Depth 8 -Compress
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec ([int]$Config.llm.requestTimeoutSeconds)
            $text = [string]$response.output_text
            if ([string]::IsNullOrWhiteSpace($text)) {
                $parts = @()
                foreach ($item in @($response.output)) {
                    foreach ($content in @($item.content)) {
                        if ($content.type -eq 'output_text' -and -not [string]::IsNullOrWhiteSpace([string]$content.text)) { $parts += [string]$content.text }
                    }
                }
                $text = $parts -join ' '
            }
        }
        $text = Repair-Utf8Mojibake $text
        $text = ($text -replace '[\r\n]+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $fallback }
        if ($text.Length -gt 240) { $text = $text.Substring(0, 240) }
        return $text
    }
    catch {
        Write-GuardianLog "LLM request failed; using fallback: $($_.Exception.Message)" 'WARN'
        return $fallback
    }
}

function Show-GuardianPopup {
    param([string]$Message, [string]$AppName)
    $messageBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message))
    $titleBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("睡眠守卫 · 已关闭 $AppName"))
    $childCode = @"
Add-Type -AssemblyName PresentationFramework
`$message = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$messageBase64'))
`$title = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$titleBase64'))
[void][System.Windows.MessageBox]::Show(`$message, `$title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Exclamation)
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) -WindowStyle Hidden | Out-Null
}

Remove-OldLogs
$gameRoots = Get-GameRoots

if ($TestLlmMessage) {
    $detection = [pscustomobject]@{ AppName = '测试浏览器' }
    $fallback = Get-FallbackMessage $detection 0
    $message = Get-LlmMessage $detection 0
    [pscustomobject]@{ LlmGenerated = ($message -ne $fallback); Message = $message } | Format-List
    exit 0
}

if ($SelfTest) {
    $llmBase = Get-LlmSetting 'baseUrl' 'baseUrlEnvironmentVariable'
    $llmModel = Get-LlmSetting 'model' 'modelEnvironmentVariable'
    $task = Get-ScheduledTask -TaskName ([string]$Config.taskName) -ErrorAction SilentlyContinue
    $syntheticBrowser = [pscustomobject]@{ Id = 900001; ParentId = 0; Name = 'msedge'; Path = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }
    $syntheticBrowserMap = @{ 900001 = $syntheticBrowser }
    $browserRule = Get-Detection $syntheticBrowser $syntheticBrowserMap $gameRoots 'New'
    $syntheticGamePath = if (@($gameRoots).Count -gt 0) { Join-Path $gameRoots[0] 'SyntheticGame.exe' } else { 'G:\SyntheticGame.exe' }
    $syntheticGame = [pscustomobject]@{ Id = 900002; ParentId = 0; Name = 'syntheticgame'; Path = $syntheticGamePath }
    $syntheticGameMap = @{ 900002 = $syntheticGame }
    $gameRule = Get-Detection $syntheticGame $syntheticGameMap $gameRoots 'New'
    [pscustomobject]@{
        ConfigPath       = $ConfigPath
        RestrictedWindow = "$($Config.windowStart)-$($Config.windowEnd)"
        BrowserFamilies = (@($Config.browserFamilies).name -join ', ')
        LauncherFamilies = (@($Config.launcherFamilies).name -join ', ')
        GameRoots        = ($gameRoots -join '; ')
        LlmConfigured    = (-not [string]::IsNullOrWhiteSpace($llmBase) -and -not [string]::IsNullOrWhiteSpace($llmModel))
        TemporarilyDisabled = Test-IsTemporarilyDisabled
        ScheduledTask    = if ($null -ne $task) { $task.State } else { 'Not installed' }
        BrowserRuleTest  = if ($null -ne $browserRule) { "$($browserRule.Category):$($browserRule.AppName)" } else { 'FAILED' }
        GameRuleTest     = if ($null -ne $gameRule) { "$($gameRule.Category):$($gameRule.AppName)" } else { 'FAILED' }
    } | Format-List
    if ($TestPopup) {
        $sample = [pscustomobject]@{ AppName = '自检程序' }
        Show-GuardianPopup (Get-FallbackMessage $sample 1) '自检程序'
    }
    exit 0
}

if (Test-IsTemporarilyDisabled) {
    Write-GuardianLog 'Guardian is disabled by the safety switch.'
    exit 0
}

if (-not (Test-IsRestrictedTime) -and -not $Once -and -not $DryRun) {
    Write-GuardianLog 'Started outside the restricted window; exiting.'
    exit 0
}

$mutex = [Threading.Mutex]::new($false, 'Local\SleepGuardianMonitor')
if (-not $mutex.WaitOne(0)) {
    Write-GuardianLog 'Another monitor instance is already running.'
    exit 0
}

try {
    Write-GuardianLog "Monitor started. Game roots: $($gameRoots -join '; ')"
    $snapshot = Get-ProcessSnapshot
    $knownPids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($process in @($snapshot)) { [void]$knownPids.Add([int]$process.Id) }
    $sequence = 0
    $lastPopup = [datetime]::MinValue

    while ($true) {
        if (Test-IsTemporarilyDisabled) {
            Write-GuardianLog 'Safety switch activated; monitor exiting.'
            break
        }
        if (-not (Test-IsRestrictedTime) -and -not $Once -and -not $DryRun) {
            Write-GuardianLog 'Restricted window ended; monitor exiting.'
            break
        }

        $snapshot = Get-ProcessSnapshot
        $processMap = Get-ProcessMap $snapshot
        $detection = $null

        $foregroundId = Get-ForegroundProcessId
        if ($foregroundId -gt 0 -and $processMap.ContainsKey($foregroundId)) {
            $detection = Get-Detection $processMap[$foregroundId] $processMap $gameRoots 'Foreground'
        }

        if ($null -eq $detection) {
            foreach ($process in @($snapshot)) {
                if (-not $knownPids.Contains([int]$process.Id)) {
                    $detection = Get-Detection $process $processMap $gameRoots 'New'
                    if ($null -ne $detection) { break }
                }
            }
        }

        if ($null -eq $detection -and $sequence -eq 0) {
            foreach ($process in @($snapshot)) {
                $detection = Get-Detection $process $processMap $gameRoots 'ExistingGame'
                if ($null -ne $detection) { break }
            }
        }

        if ($null -ne $detection) {
            Stop-GuardianTarget $detection
            $sequence++
            if (((Get-Date) - $lastPopup).TotalSeconds -ge [int]$Config.notificationCooldownSeconds) {
                $message = Get-LlmMessage $detection $sequence
                Show-GuardianPopup $message $detection.AppName
                $lastPopup = Get-Date
            }
            Start-Sleep -Seconds 1
            $snapshot = Get-ProcessSnapshot
        }

        $knownPids = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($process in @($snapshot)) { [void]$knownPids.Add([int]$process.Id) }
        if ($Once -or $DryRun) { break }
        Start-Sleep -Seconds ([int]$Config.pollSeconds)
    }
}
catch {
    Write-GuardianLog $_.Exception.ToString() 'ERROR'
    throw
}
finally {
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
