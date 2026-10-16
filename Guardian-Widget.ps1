[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$TestQuestionGeneration,
    [switch]$PreviewQuiz,
    [switch]$PreviewReview,
    [switch]$PreviewStudy,
    [switch]$TestScheduleUpdate,
    [switch]$PreviewLibrary,
    [switch]$TestLearning,
    [switch]$TestUi,
    [switch]$TestAppeals,
    [switch]$TestAppealApi
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$KnowledgeBankPath = Join-Path $PSScriptRoot 'knowledge-bank.json'
$DataRoot = Join-Path $env:LOCALAPPDATA 'SleepGuardian'
$StatePath = Join-Path $DataRoot 'state.json'
$AllowancePath = Join-Path $DataRoot 'allowance.json'
$AllowanceRegistryPath = 'HKCU:\Software\SleepGuardian'
$WidgetStatePath = Join-Path $DataRoot 'widget-state.json'
$QuizLogPath = Join-Path $DataRoot 'quiz.log'
$DailyStudyPath = Join-Path $DataRoot 'daily-study.json'
$MutexName = 'Local\SleepGuardianWidget_v1'
$ShowEventName = 'Local\SleepGuardianWidgetShow_v1'

[System.IO.Directory]::CreateDirectory($DataRoot) | Out-Null
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "缺少配置文件：$ConfigPath" }
if (-not (Test-Path -LiteralPath $KnowledgeBankPath)) { throw "缺少 N4 知识库：$KnowledgeBankPath" }

$script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:KnowledgeBank = Get-Content -LiteralPath $KnowledgeBankPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:UsedStems = [System.Collections.Generic.List[string]]::new()
$script:UsedKnowledgeIds = [System.Collections.Generic.List[string]]::new()
$script:DailyKnowledgeCount = 30
$script:ExamQuestionCount = 10
$script:AllowExit = $false
$script:DragStart = $null
$script:StartLocation = $null

function Write-QuizLog {
    param([string]$Message)
    $line = '[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($QuizLogPath, $line, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 30
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)} }
}

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-IsRestrictedTime {
    param([datetime]$Now = (Get-Date))
    $start = [TimeSpan]::Parse([string]$script:Config.windowStart)
    $end = [TimeSpan]::Parse([string]$script:Config.windowEnd)
    if ($start -lt $end) { return ($Now.TimeOfDay -ge $start -and $Now.TimeOfDay -lt $end) }
    return ($Now.TimeOfDay -ge $start -or $Now.TimeOfDay -lt $end)
}

function Get-NextWindowEnd {
    $now = Get-Date
    $end = [TimeSpan]::Parse([string]$script:Config.windowEnd)
    $until = $now.Date.Add($end)
    if ($until -le $now) { $until = $until.AddDays(1) }
    return [DateTimeOffset]$until
}

function Get-GuardianState {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $until = [DateTimeOffset]::Parse([string]$state.disabledUntil)
        if ($until -gt [DateTimeOffset]::Now) { return $state }
        [System.IO.File]::Delete($StatePath)
    }
    catch {
        Write-QuizLog "忽略无效停用状态：$($_.Exception.Message)"
    }
    return $null
}

function Disable-GuardianTonight {
    param([ValidateSet('QuizPassed','MonthlyAllowance')] [string]$Mode)
    $until = Get-NextWindowEnd
    $state = [ordered]@{
        disabledUntil = $until.ToString('o')
        mode = $Mode
        createdAt = [DateTimeOffset]::Now.ToString('o')
        reasonHash = ''
    }
    Write-JsonFile -Path $StatePath -Value $state
    Stop-ScheduledTask -TaskName ([string]$script:Config.taskName) -ErrorAction SilentlyContinue
    return $until
}

function Enable-Guardian {
    if (Test-Path -LiteralPath $StatePath) { [System.IO.File]::Delete($StatePath) }
    if (Test-IsRestrictedTime) {
        Start-ScheduledTask -TaskName ([string]$script:Config.taskName) -ErrorAction SilentlyContinue
    }
}

function Get-AllowanceState {
    $month = Get-Date -Format 'yyyy-MM'
    $state = $null
    if (Test-Path -LiteralPath $AllowancePath) {
        try { $state = Get-Content -LiteralPath $AllowancePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    $fileUsed = 0
    $events = @()
    if ($null -ne $state -and [string](Get-PropertyValue $state 'month' '') -eq $month) {
        $fileUsed = [int](Get-PropertyValue $state 'used' 0)
        foreach ($eventValue in @($state.events)) { $events += $eventValue }
    }
    $registryUsed = 0
    try {
        $registry = Get-ItemProperty -LiteralPath $AllowanceRegistryPath -ErrorAction Stop
        if ([string]$registry.AllowanceMonth -eq $month) { $registryUsed = [int]$registry.AllowanceUsed }
    } catch {}
    $used = [Math]::Max(0, [Math]::Min(3, [Math]::Max($fileUsed, $registryUsed)))
    return [pscustomobject]@{
        month = $month
        used = $used
        remaining = 3 - $used
        events = @($events)
    }
}

function Use-MonthlyAllowance {
    $state = Get-AllowanceState
    if ($state.remaining -le 0) { return $false }
    $events = [System.Collections.Generic.List[string]]::new()
    foreach ($event in @($state.events)) { $events.Add([string]$event) }
    $events.Add([DateTimeOffset]::Now.ToString('o'))
    Write-JsonFile -Path $AllowancePath -Value ([ordered]@{
        month = $state.month
        used = $state.used + 1
        events = @($events)
    })
    if (-not (Test-Path -LiteralPath $AllowanceRegistryPath)) { New-Item -Path $AllowanceRegistryPath -Force | Out-Null }
    New-ItemProperty -LiteralPath $AllowanceRegistryPath -Name 'AllowanceMonth' -Value $state.month -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $AllowanceRegistryPath -Name 'AllowanceUsed' -Value ($state.used + 1) -PropertyType DWord -Force | Out-Null
    return $true
}

function Test-QuestionObject {
    param(
        $Question,
        [System.Collections.Generic.HashSet[string]]$SeenStems,
        [System.Collections.Generic.HashSet[string]]$AllowedKnowledgeIds
    )
    if ($null -eq $Question) { return $false }
    $knowledgePointId = [string](Get-PropertyValue $Question 'knowledgePointId' '')
    $stem = [string](Get-PropertyValue $Question 'stem' '')
    $grammarPoint = [string](Get-PropertyValue $Question 'grammarPoint' '')
    $explanation = [string](Get-PropertyValue $Question 'explanation' '')
    $optionsValue = $Question.options
    if ($optionsValue -is [Array] -and $optionsValue.Count -eq 1 -and $optionsValue[0] -is [Array]) { $optionsValue = $optionsValue[0] }
    $options = @()
    foreach ($optionValue in $optionsValue) { $options += $optionValue }
    $correctIndexRaw = Get-PropertyValue $Question 'correctIndex' $null
    if ([string]::IsNullOrWhiteSpace($knowledgePointId) -or -not $AllowedKnowledgeIds.Contains($knowledgePointId)) { return $false }
    if ([string]::IsNullOrWhiteSpace($stem) -or ([regex]::Matches($stem,'（\s*）|_{2,}').Count -ne 1)) { return $false }
    if ([string]::IsNullOrWhiteSpace($grammarPoint) -or [string]::IsNullOrWhiteSpace($explanation)) { return $false }
    if ($options.Count -ne 4) { return $false }
    $optionSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($option in $options) {
        if ([string]::IsNullOrWhiteSpace([string]$option) -or -not $optionSet.Add(([string]$option).Trim())) { return $false }
    }
    $index = 0
    if (-not [int]::TryParse([string]$correctIndexRaw, [ref]$index) -or $index -lt 0 -or $index -gt 3) { return $false }
    if (-not $SeenStems.Add($stem.Trim())) { return $false }
    return $true
}

function ConvertTo-ValidatedQuestionSet {
    param($Document, $KnowledgePoints, [string[]]$ExcludedStems = @())
    $sourceValue = $Document.questions
    if ($sourceValue -is [Array] -and $sourceValue.Count -eq 1 -and $sourceValue[0] -is [Array]) { $sourceValue = $sourceValue[0] }
    $source = @()
    foreach ($sourceItem in $sourceValue) { $source += $sourceItem }
    $expectedCount = @($KnowledgePoints).Count
    if ($expectedCount -lt 1 -or $expectedCount -gt $script:ExamQuestionCount -or $source.Count -ne $expectedCount) { throw "题目数量不匹配知识点数量（实际为 $($source.Count)）。" }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allowedKnowledgeIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($point in @($KnowledgePoints)) { [void]$allowedKnowledgeIds.Add([string]$point.id) }
    if ($allowedKnowledgeIds.Count -ne $expectedCount) { throw '本次抽取的知识点数量不正确。' }
    $usedKnowledgeIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $excluded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($stem in @($ExcludedStems)) { [void]$excluded.Add([string]$stem) }
    $validated = @()
    for ($i = 0; $i -lt $source.Count; $i++) {
        $question = $source[$i]
        if (-not (Test-QuestionObject -Question $question -SeenStems $seen -AllowedKnowledgeIds $allowedKnowledgeIds)) { throw "第 $($i + 1) 题字段不符合约束。" }
        $stem = [string]$question.stem
        if ($excluded.Contains($stem)) { throw '新试卷复用了刚才的题目。' }
        $knowledgePointId = [string]$question.knowledgePointId
        if (-not $usedKnowledgeIds.Add($knowledgePointId)) { throw "知识点 $knowledgePointId 被重复出题。" }
        $validated += [pscustomobject]@{
            id = "exam-$($i + 1)"
            knowledgePointId = $knowledgePointId
            stem = $stem.Trim()
            options = @($question.options | ForEach-Object { ([string]$_).Trim() })
            correctIndex = [int]$question.correctIndex
            explanation = ([string]$question.explanation).Trim()
            grammarPoint = ([string]$question.grammarPoint).Trim()
            source = [string](Get-PropertyValue $question 'source' '原创练习题')
            sourceUrl = [string](Get-PropertyValue $question 'sourceUrl' '')
            imagePath = [string](Get-PropertyValue $question 'imagePath' '')
        }
    }
    return $validated
}

function Get-QuestionJsonSchema {
    param([int]$Count = 10)
    return [ordered]@{
        type = 'object'
        additionalProperties = $false
        required = @('questions')
        properties = [ordered]@{
            questions = [ordered]@{
                type = 'array'
                minItems = $Count
                maxItems = $Count
                items = [ordered]@{
                    type = 'object'
                    additionalProperties = $false
                    required = @('id','knowledgePointId','stem','options','correctIndex','explanation','grammarPoint')
                    properties = [ordered]@{
                        id = @{ type = 'string' }
                        knowledgePointId = @{ type = 'string' }
                        stem = @{ type = 'string' }
                        options = @{ type = 'array'; minItems = 4; maxItems = 4; items = @{ type = 'string' } }
                        correctIndex = @{ type = 'integer'; minimum = 0; maximum = 3 }
                        explanation = @{ type = 'string' }
                        grammarPoint = @{ type = 'string' }
                    }
                }
            }
        }
    }
}

function Get-LlmSettings {
    $llm = $script:Config.llm
    $keyEnvName = [string](Get-PropertyValue $llm 'apiKeyEnvironmentVariable' 'SLEEP_GUARDIAN_API_KEY')
    $baseEnvName = [string](Get-PropertyValue $llm 'baseUrlEnvironmentVariable' 'SLEEP_GUARDIAN_BASE_URL')
    $modelEnvName = [string](Get-PropertyValue $llm 'modelEnvironmentVariable' 'SLEEP_GUARDIAN_MODEL')
    $apiKey = if (-not [string]::IsNullOrWhiteSpace($keyEnvName)) { [Environment]::GetEnvironmentVariable($keyEnvName, 'User') } else { '' }
    if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = [string](Get-PropertyValue $llm 'apiKey' '') }
    $baseUrl = if (-not [string]::IsNullOrWhiteSpace($baseEnvName)) { [Environment]::GetEnvironmentVariable($baseEnvName, 'User') } else { '' }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = [string](Get-PropertyValue $llm 'baseUrl' '') }
    $model = if (-not [string]::IsNullOrWhiteSpace($modelEnvName)) { [Environment]::GetEnvironmentVariable($modelEnvName, 'User') } else { '' }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = [string](Get-PropertyValue $llm 'model' '') }
    return [pscustomobject]@{
        enabled = [bool](Get-PropertyValue $llm 'enabled' $false)
        apiMode = [string](Get-PropertyValue $llm 'apiMode' 'responses')
        apiKey = $apiKey
        baseUrl = $baseUrl.TrimEnd('/')
        model = $model
        timeout = [Math]::Max(5, [int](Get-PropertyValue $llm 'requestTimeoutSeconds' 15))
    }
}

function Get-ApiEndpoint {
    param([string]$BaseUrl, [string]$Resource)
    return ($BaseUrl.TrimEnd('/') + '/' + $Resource.TrimStart('/'))
}

function Get-ResponsesText {
    param($Response)
    $direct = Get-PropertyValue $Response 'output_text' ''
    if (-not [string]::IsNullOrWhiteSpace([string]$direct)) { return [string]$direct }
    foreach ($item in @($Response.output)) {
        foreach ($content in @($item.content)) {
            if ([string](Get-PropertyValue $content 'type' '') -eq 'output_text') {
                $text = [string](Get-PropertyValue $content 'text' '')
                if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
            }
        }
    }
    throw 'Responses API 没有返回 output_text。'
}

function ConvertFrom-ModelJson {
    param([string]$Text)
    $clean = $Text.Trim()
    if ($clean -match '[ãäåæçèé]') {
        try {
            $latin1 = [Text.Encoding]::GetEncoding(28591)
            $repaired = [Text.Encoding]::UTF8.GetString($latin1.GetBytes($clean))
            if ($repaired -notmatch [char]0xFFFD) { $clean = $repaired }
        } catch {}
    }
    if ($clean.StartsWith('```')) {
        $clean = $clean -replace '^```(?:json)?\s*', ''
        $clean = $clean -replace '\s*```$', ''
    }
    return $clean | ConvertFrom-Json
}

function Get-HttpErrorDetail {
    param($ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
        return "$message | $([string]$ErrorRecord.ErrorDetails.Message)"
    }
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            if (-not [string]::IsNullOrWhiteSpace($body)) { return "$message | $body" }
        }
    } catch {}
    return $message
}

function Get-LocalQuestionSet {
    param($KnowledgePoints)
    $questions = @()
    foreach ($point in @($KnowledgePoints)) {
        $questions += [pscustomobject]@{
            id = "local-$($point.id)"
            knowledgePointId = [string]$point.id
            stem = [string]$point.quiz.stem
            options = @($point.quiz.options)
            correctIndex = [int]$point.quiz.correctIndex
            explanation = [string]$point.quiz.explanation
            grammarPoint = [string]$point.title
        }
    }
    return ConvertTo-ValidatedQuestionSet -Document ([pscustomobject]@{ questions = $questions }) -KnowledgePoints $KnowledgePoints
}

function Test-KnowledgePoint {
    param($Point)
    if ($null -eq $Point -or [string]::IsNullOrWhiteSpace([string]$Point.id) -or
        [string]::IsNullOrWhiteSpace([string]$Point.category) -or [string]::IsNullOrWhiteSpace([string]$Point.title) -or
        [string]::IsNullOrWhiteSpace([string]$Point.content) -or [string]::IsNullOrWhiteSpace([string]$Point.example) -or
        [string]::IsNullOrWhiteSpace([string]$Point.translation) -or $null -eq $Point.quiz) { return $false }
    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$allowed.Add([string]$Point.id)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $question = [pscustomobject]@{
        knowledgePointId = [string]$Point.id
        stem = [string]$Point.quiz.stem
        options = @($Point.quiz.options)
        correctIndex = [int]$Point.quiz.correctIndex
        explanation = [string]$Point.quiz.explanation
        grammarPoint = [string]$Point.title
    }
    return Test-QuestionObject -Question $question -SeenStems $seen -AllowedKnowledgeIds $allowed
}

function Assert-KnowledgeBank {
    if (@($script:KnowledgeBank).Count -lt 40) { throw "本地 N4 知识库少于 40 条（当前 $(@($script:KnowledgeBank).Count) 条）。" }
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($point in @($script:KnowledgeBank)) {
        if (-not $ids.Add([string]$point.id)) { throw "知识点 ID 重复：$($point.id)" }
        if (-not (Test-KnowledgePoint $point)) { throw "知识点无效：$($point.id)" }
    }
}

. (Join-Path $PSScriptRoot 'Learning-Engine.ps1')
. (Join-Path $PSScriptRoot 'Appeal-Engine.ps1')

if($TestAppeals -or $TestAppealApi){
    . (Join-Path $PSScriptRoot 'Test-Appeals.ps1')
    exit 0
}

if ($TestLearning) {
    . (Join-Path $PSScriptRoot 'Test-Learning.ps1')
    exit 0
}

if ($SelfTest) {
    Assert-KnowledgeBank
    $daily = Get-DailyKnowledgeSet
    $selectedPoints = @($daily | Select-Object -First $script:ExamQuestionCount)
    $sample = Get-LocalQuestionSet -KnowledgePoints $selectedPoints
    $allowance = Get-AllowanceState
    $llm = Get-LlmSettings
    [pscustomobject]@{
        KnowledgeBank = @($script:KnowledgeBank).Count
        DailyKnowledge = @($daily).Count
        SampleQuestions = @($sample).Count
        Level = 'N4'
        LlmConfigured = ($llm.enabled -and $llm.apiKey -and $llm.baseUrl -and $llm.model)
        AllowanceMonth = $allowance.month
        AllowanceRemaining = $allowance.remaining
        GuardianDisabled = ($null -ne (Get-GuardianState))
    } | Format-List
    exit 0
}

if ($TestQuestionGeneration) {
    Assert-KnowledgeBank
    $daily = Get-DailyKnowledgeSet
    $selectedPoints = @(Get-ExamKnowledgePoints -DailyPoints $daily)
    $exam = Get-QuestionSet -KnowledgePoints $selectedPoints
    [pscustomobject]@{
        Source = $exam.Source
        Count = @($exam.Questions).Count
        GrammarPoints = (@($exam.Questions) | ForEach-Object { $_.grammarPoint }) -join '、'
    } | Format-List
    exit 0
}

Assert-KnowledgeBank
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('SleepGuardian.WidgetNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SleepGuardian {
    public static class WidgetNative {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
'@
}
[void][SleepGuardian.WidgetNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:UiFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:TitleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
$script:JapaneseFont = New-Object System.Drawing.Font('Yu Gothic UI', 10)
$script:Colors = @{
    Background = [Drawing.Color]::FromArgb(247, 242, 250)
    Card = [Drawing.Color]::White
    Lavender = [Drawing.Color]::FromArgb(116, 91, 143)
    LavenderLight = [Drawing.Color]::FromArgb(226, 214, 239)
    Rose = [Drawing.Color]::FromArgb(194, 103, 126)
    Green = [Drawing.Color]::FromArgb(64, 130, 104)
    Text = [Drawing.Color]::FromArgb(58, 49, 67)
    Muted = [Drawing.Color]::FromArgb(111, 100, 121)
    Wrong = [Drawing.Color]::FromArgb(245, 218, 224)
    Right = [Drawing.Color]::FromArgb(218, 239, 229)
}

function New-UiButton {
    param([string]$Text, [int]$Width = 160, [int]$Height = 36, [Drawing.Color]$BackColor = $script:Colors.Lavender)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = $Height
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $BackColor
    $button.ForeColor = [Drawing.Color]::White
    $button.Font = $script:UiFont
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    return $button
}

function Show-GuardianDialog {
    param([Windows.Forms.Form]$Dialog, [Windows.Forms.Form]$Owner, [string]$Name)
    if($script:UiTestRoot){
        $capturePath=Join-Path $script:UiTestRoot ($Name+'.png')
        $beforeCapture=$script:UiBeforeCapture
        $Dialog.Add_Shown({
            if($beforeCapture){& $beforeCapture $this}
            $this.Refresh()
            $bitmap=New-Object Drawing.Bitmap($this.Width,$this.Height)
            try{$this.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$this.Width,$this.Height)));$bitmap.Save($capturePath)}finally{$bitmap.Dispose()}
            $this.DialogResult=[Windows.Forms.DialogResult]::Cancel
            $this.Close()
        }.GetNewClosure())
    }
    return $Dialog.ShowDialog($Owner)
}

function Show-DailyKnowledgeForm {
    param([Windows.Forms.Form]$Owner, $KnowledgePoints)
    $form = New-Object Windows.Forms.Form
    $form.Text = '睡眠守卫 · 今日 N4 知识点'
    $form.Size = New-Object Drawing.Size(900, 790)
    $form.MinimumSize = New-Object Drawing.Size(760, 650)
    $form.StartPosition = 'CenterParent'
    $form.TopMost = $true
    $form.BackColor = $script:Colors.Background
    $form.Font = $script:UiFont

    $heading = New-Object Windows.Forms.Label
    $heading.Text = '今天的 30 个 N4 知识点'
    $heading.Font = $script:TitleFont
    $heading.ForeColor = $script:Colors.Text
    $heading.AutoSize = $true
    $heading.Location = New-Object Drawing.Point(24, 16)
    $form.Controls.Add($heading)

    $intro = New-Object Windows.Forms.Label
    $intro.Text = "先按自己的节奏读完这些内容。考试只会从今天展示的知识点中抽取 10 个出题。`r`n滚动到最下面后，进入考试按钮才会解锁。"
    $intro.ForeColor = $script:Colors.Muted
    $intro.Location = New-Object Drawing.Point(26, 46)
    $intro.Size = New-Object Drawing.Size(820, 42)
    $form.Controls.Add($intro)

    $panel = New-Object Windows.Forms.Panel
    $panel.Location = New-Object Drawing.Point(16, 92)
    $panel.Size = New-Object Drawing.Size(850, 590)
    $panel.Anchor = 'Top,Bottom,Left,Right'
    $panel.AutoScroll = $true
    $panel.BackColor = $script:Colors.Background
    $form.Controls.Add($panel)

    $y = 4
    for ($i = 0; $i -lt @($KnowledgePoints).Count; $i++) {
        $point = $KnowledgePoints[$i]
        $card = New-Object Windows.Forms.Panel
        $card.Location = New-Object Drawing.Point(6, $y)
        $card.Size = New-Object Drawing.Size(810, 142)
        $card.Anchor = 'Top,Left,Right'
        $card.BackColor = $script:Colors.Card

        $titleLabel = New-Object Windows.Forms.Label
        $titleLabel.Text = "{0:D2}　[{1}]　{2}" -f ($i + 1), [string]$point.category, [string]$point.title
        $titleLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
        $titleLabel.ForeColor = $script:Colors.Lavender
        $titleLabel.Location = New-Object Drawing.Point(14, 10)
        $titleLabel.Size = New-Object Drawing.Size(780, 26)
        $card.Controls.Add($titleLabel)

        $contentLabel = New-Object Windows.Forms.Label
        $contentLabel.Text = [string]$point.content
        $contentLabel.ForeColor = $script:Colors.Text
        $contentLabel.Location = New-Object Drawing.Point(16, 40)
        $contentLabel.Size = New-Object Drawing.Size(776, 34)
        $card.Controls.Add($contentLabel)

        $exampleLabel = New-Object Windows.Forms.Label
        $exampleLabel.Text = "例：$($point.example)"
        $exampleLabel.Font = $script:JapaneseFont
        $exampleLabel.ForeColor = $script:Colors.Text
        $exampleLabel.Location = New-Object Drawing.Point(16, 78)
        $exampleLabel.Size = New-Object Drawing.Size(776, 27)
        $card.Controls.Add($exampleLabel)

        $translationLabel = New-Object Windows.Forms.Label
        $translationLabel.Text = "译：$($point.translation)"
        $translationLabel.ForeColor = $script:Colors.Muted
        $translationLabel.Location = New-Object Drawing.Point(16, 108)
        $translationLabel.Size = New-Object Drawing.Size(776, 24)
        $card.Controls.Add($translationLabel)

        $panel.Controls.Add($card)
        $y += 150
    }
    $panel.AutoScrollMinSize = New-Object Drawing.Size(0, ($y + 8))

    $progress = New-Object Windows.Forms.Label
    $progress.Text = '请继续向下阅读今日知识点……'
    $progress.ForeColor = $script:Colors.Muted
    $progress.Anchor = 'Bottom,Left'
    $progress.Location = New-Object Drawing.Point(24, 704)
    $progress.Size = New-Object Drawing.Size(330, 30)
    $form.Controls.Add($progress)

    $cancel = New-UiButton -Text '先放弃，去休息' -Width 150 -BackColor $script:Colors.Green
    $cancel.Anchor = 'Bottom,Right'
    $cancel.Location = New-Object Drawing.Point(548, 704)
    $cancel.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::Cancel; $this.FindForm().Close() })
    $form.Controls.Add($cancel)

    $continue = New-UiButton -Text '读完了，进入考试' -Width 170
    $continue.Anchor = 'Bottom,Right'
    $continue.Location = New-Object Drawing.Point(710, 704)
    $continue.Enabled = $false
    $continue.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::OK; $this.FindForm().Close() })
    $form.Controls.Add($continue)
    $form.CancelButton = $cancel

    $completedColor = $script:Colors.Green
    $checkReadToEnd = {
        $bottom = (-$panel.AutoScrollPosition.Y) + $panel.ClientSize.Height
        if ($bottom -ge ($panel.AutoScrollMinSize.Height - 24)) {
            $continue.Enabled = $true
            $progress.Text = '今日知识点已浏览完成，可以进入考试。'
            $progress.ForeColor = $completedColor
        }
    }.GetNewClosure()
    $panel.Add_Scroll($checkReadToEnd)
    $panel.Add_MouseWheel($checkReadToEnd)
    $panel.Add_Resize($checkReadToEnd)

    $result = Show-GuardianDialog $form $Owner 'study'
    $form.Dispose()
    return $result
}

function Show-LoadingForm {
    param([Windows.Forms.Form]$Owner)
    $form = New-Object Windows.Forms.Form
    $form.Text = '睡眠守卫正在准备试卷'
    $form.Size = New-Object Drawing.Size(420, 150)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.BackColor = $script:Colors.Background
    $label = New-Object Windows.Forms.Label
    $label.Text = "正在准备 10 道题……`r`n优先公开真题；生成题依次经过出题、N4 范围审查、独立解题复核。"
    $label.Font = $script:UiFont
    $label.ForeColor = $script:Colors.Text
    $label.TextAlign = 'MiddleCenter'
    $label.Dock = 'Fill'
    $form.Controls.Add($label)
    $script:PreparationLabel=$label
    $form.Show($Owner)
    $form.Refresh()
    [Windows.Forms.Application]::DoEvents()
    return $form
}

function New-QuestionPicture {
    param($Question, [int]$Width = 770)
    $path = [string](Get-PropertyValue $Question 'imagePath' '')
    if (-not $path) { return $null }
    $picture=New-Object Windows.Forms.PictureBox
    $original=[Drawing.Image]::FromFile($path)
    try { $picture.Image=New-Object Drawing.Bitmap($original) } finally { $original.Dispose() }
    $height=[int][Math]::Ceiling($picture.Image.Height * ($Width / [double]$picture.Image.Width))
    $picture.Size=New-Object Drawing.Size($Width,$height)
    $picture.SizeMode='Zoom'
    $picture.Add_Disposed({if($this.Image){$this.Image.Dispose()}})
    return $picture
}

function Show-QuizForm {
    param([Windows.Forms.Form]$Owner, $Exam)
    $form = New-Object Windows.Forms.Form
    $form.Text = '睡眠守卫 · JLPT N4 每日知识考试'
    $form.Size = New-Object Drawing.Size(900, 790)
    $form.MinimumSize = New-Object Drawing.Size(760, 650)
    $form.StartPosition = 'CenterParent'
    $form.TopMost = $true
    $form.BackColor = $script:Colors.Background
    $form.Font = $script:UiFont

    $heading = New-Object Windows.Forms.Label
    $heading.Text = '全部 10 题都答对，才会出现今晚停用按钮'
    $heading.Font = $script:TitleFont
    $heading.ForeColor = $script:Colors.Text
    $heading.AutoSize = $true
    $heading.Location = New-Object Drawing.Point(24, 18)
    $form.Controls.Add($heading)

    $source = New-Object Windows.Forms.Label
    $source.Text = "本卷来源：$($Exam.Source)　｜　请选择每题唯一正确答案"
    $source.ForeColor = $script:Colors.Muted
    $source.AutoSize = $true
    $source.Location = New-Object Drawing.Point(26, 48)
    $form.Controls.Add($source)

    $panel = New-Object Windows.Forms.Panel
    $panel.Location = New-Object Drawing.Point(16, 76)
    $panel.Anchor = 'Top,Bottom,Left,Right'
    $panel.Size = New-Object Drawing.Size(850, 615)
    $panel.AutoScroll = $true
    $panel.BackColor = $script:Colors.Background
    $form.Controls.Add($panel)

    $answerGroups = @()
    $y = 4
    for ($i = 0; $i -lt $Exam.Questions.Count; $i++) {
        $q = $Exam.Questions[$i]
        $group = New-Object Windows.Forms.GroupBox
        $group.Text = "第 $($i + 1) 题"
        $group.Font = $script:UiFont
        $group.ForeColor = $script:Colors.Text
        $group.BackColor = $script:Colors.Card
        $group.Location = New-Object Drawing.Point(6, $y)
        $group.Size = New-Object Drawing.Size(810, 230)
        $group.Anchor = 'Top,Left,Right'

        $picture=New-QuestionPicture $q
        if($null -ne $picture){
            $picture.Location=New-Object Drawing.Point(18,27)
            $group.Controls.Add($picture)
            $optionsTop=37+$picture.Height
            $group.Height=$optionsTop+80
        } else {
            $stem = New-Object Windows.Forms.Label
            $stem.Text = [string]$q.stem
            $stem.Font = $script:JapaneseFont
            $stem.Location = New-Object Drawing.Point(18, 27)
            $stem.Size = New-Object Drawing.Size(770, 66)
            $group.Controls.Add($stem)
            $optionsTop=99
        }

        $buttons = @()
        for ($j = 0; $j -lt 4; $j++) {
            $radio = New-Object Windows.Forms.RadioButton
            $radio.Text = if($picture){"选择原题第 $($j+1) 项"}else{"{0}. {1}" -f ([char](65 + $j)), [string]$q.options[$j]}
            $radio.Font = $script:JapaneseFont
            $rowHeight=if($picture){35}else{60}
            $radio.Location = New-Object Drawing.Point((18 + (($j % 2) * 390)), ($optionsTop + ([Math]::Floor($j / 2) * $rowHeight)))
            $radio.Size = New-Object Drawing.Size(370, ($rowHeight-4))
            $radio.Tag = $j
            $group.Controls.Add($radio)
            $buttons += $radio
        }
        $panel.Controls.Add($group)
        $answerGroups += [pscustomobject]@{ Question = $q; Buttons = $buttons }
        $y += $group.Height+10
    }
    $panel.AutoScrollMinSize = New-Object Drawing.Size(0, ($y + 4))

    $cancel = New-UiButton -Text '先放弃，去休息' -Width 150 -BackColor $script:Colors.Muted
    $cancel.Anchor = 'Bottom,Right'
    $cancel.Location = New-Object Drawing.Point(548, 706)
    $cancel.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::Cancel; $this.FindForm().Close() })
    $form.Controls.Add($cancel)

    $submit = New-UiButton -Text '交卷并查看解析' -Width 170
    $submit.Anchor = 'Bottom,Right'
    $submit.Location = New-Object Drawing.Point(710, 706)
    $form.Controls.Add($submit)
    $form.AcceptButton = $submit
    $form.CancelButton = $cancel
    $form.Tag = [pscustomobject]@{ Groups = $answerGroups; Answers = $null }

    $submit.Add_Click({
        $quizForm = $this.FindForm()
        $answers = @()
        foreach ($entry in @($quizForm.Tag.Groups)) {
            $selected = -1
            foreach ($radio in @($entry.Buttons)) { if ($radio.Checked) { $selected = [int]$radio.Tag; break } }
            $answers += $selected
        }
        if ($answers -contains -1) {
            [Windows.Forms.MessageBox]::Show($quizForm, '还有题目没有选择答案哦。要交卷，需要先完成全部 10 题。', '睡眠守卫', 'OK', 'Information') | Out-Null
            return
        }
        $quizForm.Tag.Answers = $answers
        $quizForm.DialogResult = [Windows.Forms.DialogResult]::OK
        $quizForm.Close()
    })

    if($script:UiTestRoot){
        foreach($group in $panel.Controls){if($group.Text -notmatch '^第 \d+ 题$'){throw '答题页泄露了知识点提示。'}}
    }
    $result = Show-GuardianDialog $form $Owner 'quiz'
    $answersResult = $form.Tag.Answers
    $form.Dispose()
    if ($result -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return ,$answersResult
}

function Show-ReviewForm {
    param([Windows.Forms.Form]$Owner, $Exam, [int[]]$Answers)
    do{$result=Show-ReviewPage -Owner $Owner -Exam $Exam -Answers $Answers}while($result -eq [Windows.Forms.DialogResult]::Ignore)
    return $result
}

function Show-ReviewPage {
    param([Windows.Forms.Form]$Owner, $Exam, [int[]]$Answers)
    $marking=@(Get-ExamMarking $Exam $Answers)
    $score=@($marking|Where-Object Correct).Count
    $allCorrect=($score -eq $Exam.Questions.Count)

    $form = New-Object Windows.Forms.Form
    $form.Text = '睡眠守卫 · 答案与解析'
    $form.Size = New-Object Drawing.Size(900, 790)
    $form.MinimumSize = New-Object Drawing.Size(760, 650)
    $form.StartPosition = 'CenterParent'
    $form.TopMost = $true
    $form.BackColor = $script:Colors.Background
    $form.Font = $script:UiFont

    $title = New-Object Windows.Forms.Label
    $title.Text = if ($allCorrect) { '10 / 10，全部通过。你已经完成今晚的解锁条件。' } else { "$score / 10。对错题有疑问，可以点题目下方的「申辩」。" }
    $title.Font = $script:TitleFont
    $title.ForeColor = if ($allCorrect) { $script:Colors.Green } else { $script:Colors.Rose }
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(24, 18)
    $form.Controls.Add($title)

    $panel = New-Object Windows.Forms.Panel
    $panel.Location = New-Object Drawing.Point(16, 60)
    $panel.Size = New-Object Drawing.Size(850, 625)
    $panel.Anchor = 'Top,Bottom,Left,Right'
    $panel.AutoScroll = $true
    $panel.BackColor = $script:Colors.Background
    $form.Controls.Add($panel)

    $y = 4
    for ($i = 0; $i -lt 10; $i++) {
        $q = $Exam.Questions[$i]
        $correct = [int]$q.correctIndex
        $chosen = [int]$Answers[$i]
        $isRight = $marking[$i].Correct
        $card = New-Object Windows.Forms.Panel
        $card.Location = New-Object Drawing.Point(6, $y)
        $card.Size = New-Object Drawing.Size(810, 262)
        $card.Anchor = 'Top,Left,Right'
        $card.BackColor = if ($isRight) { $script:Colors.Right } else { $script:Colors.Wrong }

        $qLabel = New-Object Windows.Forms.Label
        $qLabel.Text = "第 $($i + 1) 题　$($q.stem)"
        $qLabel.Font = $script:JapaneseFont
        $qLabel.Location = New-Object Drawing.Point(14, 12)
        $qLabel.Size = New-Object Drawing.Size(775, 64)
        $card.Controls.Add($qLabel)

        $picture=New-QuestionPicture $q -Width 775
        $answerTop=80
        if($picture){
            $qLabel.Text="第 $($i+1) 题 · 官方原题"
            $qLabel.Height=26
            $picture.Location=New-Object Drawing.Point(14,44)
            $card.Controls.Add($picture)
            $answerTop=52+$picture.Height
            $card.Height=$answerTop+174
        }

        $answerLabel = New-Object Windows.Forms.Label
        $answerLabel.Text = "你的答案：$([char](65 + $chosen)). $($q.options[$chosen])　　正确答案：$([char](65 + $correct)). $($q.options[$correct])"
        if($marking[$i].AppealAccepted){$answerLabel.Text="申辩已通过，本题按正确计分。你的原选择：$([char](65+$chosen)). $($q.options[$chosen])"}
        $answerLabel.Font = $script:UiFont
        $answerLabel.ForeColor = if ($isRight) { $script:Colors.Green } else { $script:Colors.Rose }
        $answerLabel.Location = New-Object Drawing.Point(14, $answerTop)
        $answerLabel.Size = New-Object Drawing.Size(775, 27)
        $card.Controls.Add($answerLabel)

        $explain = New-Object Windows.Forms.Label
        $explain.Text = "知识点：$($q.grammarPoint)`r`n解析：$($q.explanation)`r`n出处：$($q.source) $($q.sourceUrl)"
        $explain.Font = $script:UiFont
        $explain.ForeColor = $script:Colors.Text
        $explain.Location = New-Object Drawing.Point(14, ($answerTop+35))
        $explain.Size = New-Object Drawing.Size(775, 135)
        $card.Controls.Add($explain)

        if($marking[$i].AppealAccepted){
            $explain.Text="申辩结论：$($marking[$i].Reason)`r`n原判解析（保留供追溯）：$($q.explanation)"
        }
        if(-not $isRight){
            $appealButton=New-UiButton -Text '对本题有疑问，申辩' -Width 195 -Height 32
            $appealButton.Location=New-Object Drawing.Point(14,($card.Height+4))
            $appealButton.Tag=[pscustomobject]@{Exam=$Exam;Index=$i}
            $card.Height+=46
            $appealButton.Add_Click({
                $page=$this.FindForm()
                $item=$this.Tag
                try{
                    $accepted=Show-QuestionAppeal -Owner $page -Exam $item.Exam -QuestionIndex $item.Index
                    if($accepted){$page.DialogResult=[Windows.Forms.DialogResult]::Ignore;$page.Close()}
                }catch{[void][Windows.Forms.MessageBox]::Show($page,$_.Exception.Message,'申辩暂未完成','OK','Information')}
            })
            $card.Controls.Add($appealButton)
        }

        $panel.Controls.Add($card)
        $y += $card.Height+10
    }
    $panel.AutoScrollMinSize = New-Object Drawing.Size(0, ($y + 4))

    if ($allCorrect) {
        $rest = New-UiButton -Text '算了，还是去睡觉' -Width 160 -BackColor $script:Colors.Muted
        $rest.Anchor = 'Bottom,Right'
        $rest.Location = New-Object Drawing.Point(520, 704)
        $rest.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::Cancel; $this.FindForm().Close() })
        $form.Controls.Add($rest)
        $unlock = New-UiButton -Text "我完成了，停用到 $($script:Config.windowEnd)" -Width 205 -BackColor $script:Colors.Rose
        $unlock.Anchor = 'Bottom,Right'
        $unlock.Location = New-Object Drawing.Point(676, 704)
        $unlock.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::OK; $this.FindForm().Close() })
        $form.Controls.Add($unlock)
        $form.AcceptButton = $unlock
        $form.CancelButton = $rest
    }
    else {
        $giveUp = New-UiButton -Text '放弃，去睡觉' -Width 160 -BackColor $script:Colors.Green
        $giveUp.Anchor = 'Bottom,Right'
        $giveUp.Location = New-Object Drawing.Point(548, 704)
        $giveUp.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::Cancel; $this.FindForm().Close() })
        $form.Controls.Add($giveUp)
        $retry = New-UiButton -Text '重新开始新试卷' -Width 170
        $retry.Anchor = 'Bottom,Right'
        $retry.Location = New-Object Drawing.Point(710, 704)
        $retry.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::Retry; $this.FindForm().Close() })
        $form.Controls.Add($retry)
        $form.AcceptButton = $retry
        $form.CancelButton = $giveUp
    }
    $result = Show-GuardianDialog $form $Owner 'review'
    $form.Dispose()
    return $result
}

function Invoke-QuizUnlock {
    param([Windows.Forms.Form]$Owner)
    $confirm = [Windows.Forms.MessageBox]::Show(
        $Owner,
        "真的要让睡眠守卫休息到监管结束时间 $($script:Config.windowEnd) 吗？`r`n`r`n继续后会先展示今天的 30 个 JLPT N4 知识点；阅读完毕后，需要完成 10 道对应试题并且全部答对。",
        '请再想一下',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($confirm -ne [Windows.Forms.DialogResult]::Yes) { return }

    $dailyPoints = @(Get-DailyKnowledgeSet)
    $studyResult = Show-DailyKnowledgeForm -Owner $Owner -KnowledgePoints $dailyPoints
    if ($studyResult -ne [Windows.Forms.DialogResult]::OK) { return }
    Register-StudyExposure $dailyPoints
    $script:UsedKnowledgeIds.Clear()
    $script:UsedStems.Clear()

    while ($true) {
        $examKnowledge = @(Get-ExamKnowledgePoints -DailyPoints $dailyPoints)
        $loading = Show-LoadingForm -Owner $Owner
        try { $exam = Get-QuestionSet -KnowledgePoints $examKnowledge -ExcludedStems @($script:UsedStems) }
        catch {
            $loading.Close()
            [void][Windows.Forms.MessageBox]::Show($Owner, $_.Exception.Message, '暂时没有准备好合格试卷', 'OK', 'Information')
            return
        }
        finally { $script:PreparationLabel=$null; $loading.Close(); $loading.Dispose() }
        [void][Windows.Forms.MessageBox]::Show($Owner, $exam.Description, '本次试卷来源与审查结果', 'OK', 'Information')
        foreach ($question in $exam.Questions) { $script:UsedStems.Add([string]$question.stem) }
        $answers = Show-QuizForm -Owner $Owner -Exam $exam
        if ($null -eq $answers) { return }
        Save-ExamResult -Exam $exam -Answers $answers
        $review = Show-ReviewForm -Owner $Owner -Exam $exam -Answers $answers
        if ($review -eq [Windows.Forms.DialogResult]::OK) {
            $until = Disable-GuardianTonight -Mode QuizPassed
            [Windows.Forms.MessageBox]::Show($Owner, "好吧，今晚已经停用到 $($until.ToString('MM-dd HH:mm'))。`r`n如果你改变主意，小窗里可以立刻重新开启。", '睡眠守卫已停用', 'OK', 'Information') | Out-Null
            return
        }
        if ($review -ne [Windows.Forms.DialogResult]::Retry) { return }
    }
}

function Save-WidgetLocation {
    param([Windows.Forms.Form]$Form)
    Write-JsonFile -Path $WidgetStatePath -Value ([ordered]@{ x = $Form.Left; y = $Form.Top })
}

function Set-InitialWidgetLocation {
    param([Windows.Forms.Form]$Form)
    $working = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $working.Right - $Form.Width - 18
    $y = $working.Bottom - $Form.Height - 18
    if (Test-Path -LiteralPath $WidgetStatePath) {
        try {
            $saved = Get-Content -LiteralPath $WidgetStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $candidate = New-Object Drawing.Rectangle([int]$saved.x, [int]$saved.y, $Form.Width, $Form.Height)
            foreach ($screen in [Windows.Forms.Screen]::AllScreens) {
                if ($screen.WorkingArea.IntersectsWith($candidate)) { $x = [int]$saved.x; $y = [int]$saved.y; break }
            }
        } catch {}
    }
    $Form.Location = New-Object Drawing.Point($x, $y)
}

function Show-Widget {
    param([Windows.Forms.Form]$Form)
    if (-not $Form.Visible) { $Form.Show() }
    $Form.WindowState = 'Normal'
    $Form.TopMost = $true
    $Form.Activate()
}

function Update-MonitorTaskSchedule {
    $taskName = [string]$script:Config.taskName
    if ($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw "监控任务 $taskName 尚未安装。"
    }
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $start = [TimeSpan]::Parse([string]$script:Config.windowStart)
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add($start))
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 24) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -Hidden
    Set-ScheduledTask -TaskName $taskName -Trigger @($dailyTrigger, $logonTrigger) -Settings $settings | Out-Null
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (Test-IsRestrictedTime) { Start-ScheduledTask -TaskName $taskName }
}

function Set-GuardianSchedule {
    param([string]$StartTime, [string]$EndTime)
    [void][TimeSpan]::ParseExact($StartTime, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    [void][TimeSpan]::ParseExact($EndTime, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    if ($StartTime -eq $EndTime) { throw '开始和结束时间不能相同。' }
    $oldStart = [string]$script:Config.windowStart
    $oldEnd = [string]$script:Config.windowEnd
    try {
        $script:Config.windowStart = $StartTime
        $script:Config.windowEnd = $EndTime
        Write-JsonFile -Path $ConfigPath -Value $script:Config
        Update-MonitorTaskSchedule
    }
    catch {
        $script:Config.windowStart = $oldStart
        $script:Config.windowEnd = $oldEnd
        Write-JsonFile -Path $ConfigPath -Value $script:Config
        throw
    }
}

function Show-ScheduleEditor {
    param([Windows.Forms.Form]$Owner)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = '编辑睡眠守卫监管时间'
    $dialog.Size = New-Object Drawing.Size(440, 250)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.TopMost = $true
    $dialog.BackColor = $script:Colors.Background
    $dialog.Font = $script:UiFont

    $intro = New-Object Windows.Forms.Label
    $intro.Text = "每天在这个时段监管浏览器和游戏平台。`r`n可以跨过午夜，例如 23:30–06:30。"
    $intro.ForeColor = $script:Colors.Text
    $intro.Location = New-Object Drawing.Point(24, 18)
    $intro.Size = New-Object Drawing.Size(380, 46)
    $dialog.Controls.Add($intro)

    $startLabel = New-Object Windows.Forms.Label
    $startLabel.Text = '开始时间'
    $startLabel.Location = New-Object Drawing.Point(28, 82)
    $startLabel.Size = New-Object Drawing.Size(80, 26)
    $dialog.Controls.Add($startLabel)
    $startPicker = New-Object Windows.Forms.DateTimePicker
    $startPicker.Format = [Windows.Forms.DateTimePickerFormat]::Custom
    $startPicker.CustomFormat = 'HH:mm'
    $startPicker.ShowUpDown = $true
    $startPicker.Value = [datetime]::Today.Add([TimeSpan]::Parse([string]$script:Config.windowStart))
    $startPicker.Location = New-Object Drawing.Point(112, 78)
    $startPicker.Size = New-Object Drawing.Size(92, 30)
    $dialog.Controls.Add($startPicker)

    $endLabel = New-Object Windows.Forms.Label
    $endLabel.Text = '结束时间'
    $endLabel.Location = New-Object Drawing.Point(226, 82)
    $endLabel.Size = New-Object Drawing.Size(80, 26)
    $dialog.Controls.Add($endLabel)
    $endPicker = New-Object Windows.Forms.DateTimePicker
    $endPicker.Format = [Windows.Forms.DateTimePickerFormat]::Custom
    $endPicker.CustomFormat = 'HH:mm'
    $endPicker.ShowUpDown = $true
    $endPicker.Value = [datetime]::Today.Add([TimeSpan]::Parse([string]$script:Config.windowEnd))
    $endPicker.Location = New-Object Drawing.Point(310, 78)
    $endPicker.Size = New-Object Drawing.Size(92, 30)
    $dialog.Controls.Add($endPicker)

    $note = New-Object Windows.Forms.Label
    $note.Text = '保存后会立即同步计划任务；不会关闭或重启 VPN。'
    $note.ForeColor = $script:Colors.Muted
    $note.Location = New-Object Drawing.Point(28, 126)
    $note.Size = New-Object Drawing.Size(370, 24)
    $dialog.Controls.Add($note)

    $cancel = New-UiButton -Text '取消' -Width 110 -BackColor $script:Colors.Muted
    $cancel.Location = New-Object Drawing.Point(178, 164)
    $cancel.Add_Click({ $this.FindForm().DialogResult = [Windows.Forms.DialogResult]::Cancel; $this.FindForm().Close() })
    $dialog.Controls.Add($cancel)
    $save = New-UiButton -Text '保存时间' -Width 120
    $save.Location = New-Object Drawing.Point(298, 164)
    $dialog.Controls.Add($save)
    $dialog.AcceptButton = $save
    $dialog.CancelButton = $cancel
    $dialog.Tag = $null
    $save.Add_Click({
        $editor = $this.FindForm()
        $startText = $startPicker.Value.ToString('HH:mm')
        $endText = $endPicker.Value.ToString('HH:mm')
        if ($startText -eq $endText) {
            [Windows.Forms.MessageBox]::Show($editor, '开始和结束时间不能相同哦。', '时间还需要调整', 'OK', 'Information') | Out-Null
            return
        }
        $editor.Tag = [pscustomobject]@{ Start = $startText; End = $endText }
        $editor.DialogResult = [Windows.Forms.DialogResult]::OK
        $editor.Close()
    })
    $result = $dialog.ShowDialog($Owner)
    $selection = $dialog.Tag
    $dialog.Dispose()
    if ($result -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return $selection
}

if ($TestScheduleUpdate) {
    Set-GuardianSchedule -StartTime ([string]$script:Config.windowStart) -EndTime ([string]$script:Config.windowEnd)
    $taskInfo = Get-ScheduledTaskInfo -TaskName ([string]$script:Config.taskName)
    [pscustomobject]@{
        Window = "$($script:Config.windowStart)-$($script:Config.windowEnd)"
        NextRunTime = $taskInfo.NextRunTime
        TaskState = (Get-ScheduledTask -TaskName ([string]$script:Config.taskName)).State
    } | Format-List
    exit 0
}

. (Join-Path $PSScriptRoot 'Learning-Library.ps1')
. (Join-Path $PSScriptRoot 'Appeal-Dialog.ps1')

if($TestUi){
    [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
    . (Join-Path $PSScriptRoot 'Test-UI.ps1')
    exit 0
}

if ($PreviewLibrary) {
    $previewOwner = New-Object Windows.Forms.Form
    $previewOwner.Opacity = 0
    $previewOwner.ShowInTaskbar = $false
    $previewOwner.Show()
    Show-LearningLibrary -Owner $previewOwner
    $previewOwner.Dispose()
    exit 0
}

if ($PreviewStudy) {
    $previewOwner = New-Object Windows.Forms.Form
    $previewOwner.Opacity = 0
    $previewOwner.ShowInTaskbar = $false
    $previewOwner.StartPosition = 'CenterScreen'
    $previewOwner.Show()
    [void](Show-DailyKnowledgeForm -Owner $previewOwner -KnowledgePoints @(Get-DailyKnowledgeSet))
    $previewOwner.Close()
    $previewOwner.Dispose()
    exit 0
}

if ($PreviewQuiz) {
    $previewOwner = New-Object Windows.Forms.Form
    $previewOwner.Opacity = 0
    $previewOwner.ShowInTaskbar = $false
    $previewOwner.StartPosition = 'CenterScreen'
    $previewOwner.Show()
    $previewPoints = @(Get-DailyKnowledgeSet | Select-Object -First $script:ExamQuestionCount)
    $previewExam = [pscustomobject]@{ Source = '界面预览 · 今日 N4 知识点'; Questions = @(Get-LocalQuestionSet -KnowledgePoints $previewPoints) }
    [void](Show-QuizForm -Owner $previewOwner -Exam $previewExam)
    $previewOwner.Close()
    $previewOwner.Dispose()
    exit 0
}

if ($PreviewReview) {
    $previewOwner = New-Object Windows.Forms.Form
    $previewOwner.Opacity = 0
    $previewOwner.ShowInTaskbar = $false
    $previewOwner.StartPosition = 'CenterScreen'
    $previewOwner.Show()
    $previewPoints = @(Get-DailyKnowledgeSet | Select-Object -First $script:ExamQuestionCount)
    $previewExam = [pscustomobject]@{ Source = '界面预览 · 今日 N4 知识点'; Questions = @(Get-LocalQuestionSet -KnowledgePoints $previewPoints) }
    $previewAnswers = @($previewExam.Questions | ForEach-Object { [int]$_.correctIndex })
    $previewAnswers[0] = ($previewAnswers[0] + 1) % 4
    [void](Show-ReviewForm -Owner $previewOwner -Exam $previewExam -Answers $previewAnswers)
    $previewOwner.Close()
    $previewOwner.Dispose()
    exit 0
}

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, $MutexName, [ref]$createdNew)
if (-not $createdNew) {
    try { $event = [Threading.EventWaitHandle]::OpenExisting($ShowEventName); [void]$event.Set(); $event.Dispose() } catch {}
    $mutex.Dispose()
    exit 0
}
$createdEvent = $false
$showEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, $ShowEventName, [ref]$createdEvent)

$form = New-Object Windows.Forms.Form
$form.Text = '睡眠守卫'
$form.Size = New-Object Drawing.Size(318, 218)
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = $script:Colors.Background
$form.Font = $script:UiFont
$form.Padding = New-Object Windows.Forms.Padding(1)

$title = New-Object Windows.Forms.Label
$title.Text = '睡眠守卫'
$title.Font = $script:TitleFont
$title.ForeColor = $script:Colors.Text
$title.Location = New-Object Drawing.Point(16, 12)
$title.Size = New-Object Drawing.Size(210, 28)
$form.Controls.Add($title)

$hide = New-Object Windows.Forms.Label
$hide.Text = '—'
$hide.Font = New-Object Drawing.Font('Microsoft YaHei UI', 13, [Drawing.FontStyle]::Bold)
$hide.ForeColor = $script:Colors.Muted
$hide.TextAlign = 'MiddleCenter'
$hide.Cursor = [Windows.Forms.Cursors]::Hand
$hide.Location = New-Object Drawing.Point(272, 6)
$hide.Size = New-Object Drawing.Size(36, 32)
$hide.Add_Click({ $this.FindForm().Hide() })
$form.Controls.Add($hide)

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(18, 42)
$status.Size = New-Object Drawing.Size(282, 20)
$status.ForeColor = $script:Colors.Green
$form.Controls.Add($status)

$scheduleLabel = New-Object Windows.Forms.Label
$scheduleLabel.Location = New-Object Drawing.Point(18, 62)
$scheduleLabel.Size = New-Object Drawing.Size(282, 22)
$scheduleLabel.ForeColor = $script:Colors.Lavender
$scheduleLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8.5, [Drawing.FontStyle]::Underline)
$scheduleLabel.Cursor = [Windows.Forms.Cursors]::Hand
$form.Controls.Add($scheduleLabel)

$normalButton = New-UiButton -Text '今晚关闭（N4 学习关）' -Width 190 -Height 38
$normalButton.Location = New-Object Drawing.Point(16, 88)
$form.Controls.Add($normalButton)

$allowButton = New-UiButton -Text '本月纵容 3/3' -Width 94 -Height 38 -BackColor $script:Colors.Rose
$allowButton.Location = New-Object Drawing.Point(212, 88)
$form.Controls.Add($allowButton)

$hint = New-Object Windows.Forms.Label
$hint.Text = '拖动空白处移动 · “—”隐藏 · 双击托盘再次唤起'
$hint.ForeColor = $script:Colors.Muted
$hint.Font = New-Object Drawing.Font('Microsoft YaHei UI', 7.8)
$hint.Location = New-Object Drawing.Point(17, 182)
$hint.Size = New-Object Drawing.Size(285, 22)
$form.Controls.Add($hint)

$libraryButton = New-UiButton -Text '知识库' -Width 140 -Height 32
$libraryButton.Location = New-Object Drawing.Point(16, 136)
$libraryButton.Add_Click({ Show-LearningLibrary -Owner $form })
$form.Controls.Add($libraryButton)
$mistakeButton = New-UiButton -Text '错题本' -Width 144 -Height 32 -BackColor $script:Colors.Muted
$mistakeButton.Location = New-Object Drawing.Point(162, 136)
$mistakeButton.Add_Click({ Show-LearningLibrary -Owner $form -Mistakes })
$form.Controls.Add($mistakeButton)

function Update-WidgetStatus {
    $state = Get-GuardianState
    $allowance = Get-AllowanceState
    if ($null -ne $state) {
        $until = [DateTimeOffset]::Parse([string]$state.disabledUntil)
        $status.Text = "今晚已停用，$($until.ToString('MM-dd HH:mm')) 自动恢复"
        $status.ForeColor = $script:Colors.Rose
        $normalButton.Text = '现在重新开启守卫'
        $normalButton.BackColor = $script:Colors.Green
        $allowButton.Enabled = $false
    }
    else {
        $status.Text = '守卫已开启'
        $status.ForeColor = $script:Colors.Green
        $normalButton.Text = '今晚关闭（N4 学习关）'
        $normalButton.BackColor = $script:Colors.Lavender
        $allowButton.Enabled = ($allowance.remaining -gt 0)
    }
    $scheduleLabel.Text = "监管时间：$($script:Config.windowStart)–$($script:Config.windowEnd)（双击编辑）"
    $allowButton.Text = "纵容 $($allowance.remaining)/3"
    if ($allowance.remaining -le 0) { $allowButton.BackColor = $script:Colors.Muted } else { $allowButton.BackColor = $script:Colors.Rose }
}

$normalButton.Add_Click({
    if ($null -ne (Get-GuardianState)) {
        Enable-Guardian
        [Windows.Forms.MessageBox]::Show($form, '睡眠守卫已经重新开启。今晚如果到了监测时段，它会继续照看你。', '已经重新开启', 'OK', 'Information') | Out-Null
    }
    else { Invoke-QuizUnlock -Owner $form }
    Update-WidgetStatus
})

$allowButton.Add_Click({
    $allowance = Get-AllowanceState
    if ($allowance.remaining -le 0) {
        [Windows.Forms.MessageBox]::Show($form, '这个月的 3 次纵容已经用完啦。下一自然月会自动恢复。', '本月额度已用完', 'OK', 'Information') | Out-Null
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show(
        $form,
        "这会消耗本月 1 次纵容，并把守卫停用到 $($script:Config.windowEnd)。`r`n本月目前还剩 $($allowance.remaining) 次，真的要用吗？",
        '温柔放行一次',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($answer -eq [Windows.Forms.DialogResult]::Yes -and (Use-MonthlyAllowance)) {
        $until = Disable-GuardianTonight -Mode MonthlyAllowance
        [Windows.Forms.MessageBox]::Show($form, "好，今晚放你一次，已经停用到 $($until.ToString('MM-dd HH:mm'))。`r`n不过如果只是累得不想动，去睡觉其实会更舒服一点。", '本次已放行', 'OK', 'Information') | Out-Null
        Update-WidgetStatus
    }
})

$scheduleLabel.Add_DoubleClick({
    $selection = Show-ScheduleEditor -Owner $form
    if ($null -eq $selection) { return }
    try {
        Set-GuardianSchedule -StartTime $selection.Start -EndTime $selection.End
        Update-WidgetStatus
        [Windows.Forms.MessageBox]::Show($form, "监管时间已经改为 $($selection.Start)–$($selection.End)。`r`n计划任务也同步好啦。", '时间已更新', 'OK', 'Information') | Out-Null
    }
    catch {
        [Windows.Forms.MessageBox]::Show($form, "时间没有修改成功：$($_.Exception.Message)", '修改失败', 'OK', 'Error') | Out-Null
    }
})

$dragControls = @($form, $title, $status, $hint)
foreach ($control in $dragControls) {
    $control.Add_MouseDown({
        if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) {
            $script:DragStart = [Windows.Forms.Cursor]::Position
            $script:StartLocation = $form.Location
        }
    })
    $control.Add_MouseMove({
        if ($null -ne $script:DragStart -and $_.Button -eq [Windows.Forms.MouseButtons]::Left) {
            $now = [Windows.Forms.Cursor]::Position
            $form.Location = New-Object Drawing.Point(($script:StartLocation.X + $now.X - $script:DragStart.X), ($script:StartLocation.Y + $now.Y - $script:DragStart.Y))
        }
    })
    $control.Add_MouseUp({
        if ($null -ne $script:DragStart) { Save-WidgetLocation -Form $form }
        $script:DragStart = $null
        $script:StartLocation = $null
    })
}

$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$showItem = $trayMenu.Items.Add('显示睡眠守卫')
$enableItem = $trayMenu.Items.Add('立即重新开启')
$libraryItem = $trayMenu.Items.Add('打开知识库')
$mistakeItem = $trayMenu.Items.Add('打开错题本')
$exitItem = $trayMenu.Items.Add('退出小窗（不关闭守卫）')
$showItem.Add_Click({ Show-Widget -Form $form })
$enableItem.Add_Click({ Enable-Guardian; Update-WidgetStatus; Show-Widget -Form $form })
$libraryItem.Add_Click({ Show-LearningLibrary -Owner $form })
$mistakeItem.Add_Click({ Show-LearningLibrary -Owner $form -Mistakes })
$exitItem.Add_Click({ $script:AllowExit = $true; $form.Close() })

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Text = '睡眠守卫（双击显示）'
$tray.Icon = [Drawing.SystemIcons]::Information
$tray.Visible = $true
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ Show-Widget -Form $form })

$form.Add_FormClosing({
    if (-not $script:AllowExit) { $_.Cancel = $true; $form.Hide() }
})
$form.Add_FormClosed({ $tray.Visible = $false; $tray.Dispose() })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1200
$timer.Add_Tick({
    if ($showEvent.WaitOne(0)) { Show-Widget -Form $form }
    Update-WidgetStatus
})

Set-InitialWidgetLocation -Form $form
Update-WidgetStatus
$timer.Start()
try { [Windows.Forms.Application]::Run($form) }
finally {
    $timer.Stop(); $timer.Dispose()
    $showEvent.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
