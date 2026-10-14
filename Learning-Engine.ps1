# Learning records stay in LocalAppData; no API keys or personal results enter Git.
$script:LearningPath = Join-Path $DataRoot 'learning-history.json'
$script:OfficialBankPath = Join-Path $DataRoot 'official-questions.json'
$script:ReviewedCachePath = Join-Path $DataRoot 'reviewed-questions.json'

function Get-KnowledgeDirectory {
    param($Point)
    $title = [string]$Point.title
    switch ([string]$Point.category) {
        '生词' {
            if ($title -match '予定|約束|準備|必要|連絡') { return '01 生词 / 计划与事务' }
            if ($title -match '間に合う|続ける|決める|選ぶ|届く') { return '02 生词 / 行动与变化' }
            return '03 生词 / 状态与时间'
        }
        '活用' { return '04 活用 / 能力、意志与禁止' }
        '授受' { return '05 语法 / 授受与帮助' }
    }
    if ($title -match 'つもり|予定|ほうが|なくても|なければ|にする') { return '06 语法 / 意图、义务与建议' }
    if ($title -match 'そう|かもしれ|でしょう|と思う|と言う') { return '07 语法 / 推测与引用' }
    if ($title -match 'ので|たら|なら|ても|より') { return '08 语法 / 原因、条件与比较' }
    if ($title -match 'ながら|たり|前に|時|もう|に行く') { return '09 句型 / 时间与动作关系' }
    return '10 语法 / 动作状态与程度'
}

function Get-LearningProfile {
    if (Test-Path -LiteralPath $script:LearningPath) {
        # Preserve corrupt files for diagnosis; never silently reset earned history.
        $saved = Get-Content -LiteralPath $script:LearningPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $saved = $null }
    $points = @{}
    foreach ($p in @(Get-PropertyValue $saved 'points' @())) {
        if ($null -ne $p) { $points[[string]$p.id] = $p }
    }
    return [pscustomobject]@{
        points = $points
        pending = @((Get-PropertyValue $saved 'pending' @()))
        history = @((Get-PropertyValue $saved 'history' @()))
        seen = @((Get-PropertyValue $saved 'seen' @()))
        revision = [int](Get-PropertyValue $saved 'revision' 0)
    }
}

function Save-LearningProfile {
    param($Profile)
    Write-JsonFile $script:LearningPath ([ordered]@{
        schemaVersion = 1
        revision = $Profile.revision
        points = @($Profile.points.Values | Sort-Object id)
        pending = @($Profile.pending)
        history = @($Profile.history | Select-Object -Last 200)
        seen = @($Profile.seen | Select-Object -Last 1000)
    })
}

function Get-PointWeight {
    param($Point, $Profile)
    $stat = $Profile.points[[string]$Point.id]
    if ($null -eq $stat) { return 8.0 }
    $attempts = [int](Get-PropertyValue $stat 'attempts' 0)
    $errors = [int](Get-PropertyValue $stat 'errors' 0)
    $streak = [int](Get-PropertyValue $stat 'streak' 0)
    $weight = 5.0
    if ($attempts -gt 0 -and $errors -eq 0) { $weight = 0.15 }
    elseif ($streak -ge 2) { $weight = 0.6 }
    elseif ($errors -gt 0) { $weight = 7.0 }
    $lastShown = [string](Get-PropertyValue $stat 'lastShown' '')
    if ($lastShown) {
        $days = ((Get-Date).Date - [datetime]::Parse($lastShown).Date).TotalDays
        if ($days -lt 3) { $weight *= 0.15 }
        elseif ($days -ge 14) { $weight *= 2.0 }
    }
    return [Math]::Max(0.01, $weight)
}

function Select-DistributedKnowledge {
    param($Candidates, [int]$Count, $Profile, [string[]]$RequiredIds = @())
    $chosen = [System.Collections.Generic.List[object]]::new()
    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($p in @($Candidates)) { $remaining.Add($p) }
    foreach ($id in $RequiredIds) {
        $p = @($remaining | Where-Object id -eq $id | Select-Object -First 1)
        if ($p.Count -and $chosen.Count -lt $Count) { $chosen.Add($p[0]); [void]$remaining.Remove($p[0]) }
    }
    while ($chosen.Count -lt $Count -and $remaining.Count -gt 0) {
        # Fill the least represented directory first, then weighted-sample within it.
        $groups = @($remaining | Group-Object { Get-KnowledgeDirectory $_ })
        $ranked = @($groups | ForEach-Object {
            $directory = $_.Name
            [pscustomobject]@{ Group = $_; Count = @($chosen | Where-Object { (Get-KnowledgeDirectory $_) -eq $directory }).Count; Tie = Get-Random }
        } | Sort-Object Count,Tie)
        $eligible = @($ranked[0].Group.Group)
        $weighted = @($eligible | ForEach-Object {
            $u = ((Get-Random -Minimum 1 -Maximum 1000000) / 1000000.0)
            [pscustomobject]@{ Point = $_; Key = -[Math]::Log($u) / (Get-PointWeight $_ $Profile) }
        } | Sort-Object Key)
        $winner = $weighted[0].Point
        $chosen.Add($winner)
        [void]$remaining.Remove($winner)
    }
    if ($chosen.Count -ne $Count) { throw '知识点数量不足，无法组成完整试卷。' }
    return @($chosen | Sort-Object { Get-KnowledgeDirectory $_ },id)
}

function Get-DailyKnowledgeSet {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $profile = Get-LearningProfile
    $selected = @()
    if (Test-Path -LiteralPath $DailyStudyPath) {
        $cached = Get-Content -LiteralPath $DailyStudyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$cached.date -eq $today -and [int](Get-PropertyValue $cached 'selectionVersion' 0) -eq 2) {
            # Resolve IDs against current knowledge, not stale copies of corrected explanations.
            $selected = @($script:KnowledgeBank | Where-Object { $_.id -in @($cached.ids) })
        }
    }
    if ($selected.Count -ne $script:DailyKnowledgeCount) {
        $selected = @(Select-DistributedKnowledge $script:KnowledgeBank $script:DailyKnowledgeCount $profile $profile.pending)
    } else {
        foreach ($id in @($profile.pending)) {
            if ($id -notin @($selected.id)) {
                $missing = @($script:KnowledgeBank | Where-Object id -eq $id)
                if ($missing.Count) {
                    $removable = @($selected | Where-Object { $_.id -notin @($profile.pending) } | Sort-Object { Get-PointWeight $_ $profile })
                    $selected = @($selected | Where-Object id -ne $removable[0].id) + @($missing[0])
                }
            }
        }
    }
    Write-JsonFile $DailyStudyPath ([ordered]@{ date=$today; selectionVersion=2; level='N4'; ids=@($selected.id) })
    return @($selected | Sort-Object { Get-KnowledgeDirectory $_ },id)
}

function Register-StudyExposure {
    param($KnowledgePoints)
    $profile = Get-LearningProfile
    foreach ($p in @($KnowledgePoints)) {
        $id = [string]$p.id
        if (-not $profile.points.ContainsKey($id)) {
            $profile.points[$id] = [pscustomobject]@{ id=$id; attempts=0; correct=0; errors=0; streak=0; exposures=0; lastShown=''; lastResult='' }
        }
        $stat = $profile.points[$id]
        if ($stat.lastShown -ne (Get-Date -Format 'yyyy-MM-dd')) { $stat.exposures++; $stat.lastShown=Get-Date -Format 'yyyy-MM-dd' }
    }
    Save-LearningProfile $profile
}

function Get-ExamKnowledgePoints {
    param($DailyPoints)
    $profile = Get-LearningProfile
    # Last submitted mistakes always override the anti-repeat filter.
    $available = @($DailyPoints | Where-Object { $_.id -in @($profile.pending) -or -not $script:UsedKnowledgeIds.Contains([string]$_.id) })
    if ($available.Count -lt $script:ExamQuestionCount) { $script:UsedKnowledgeIds.Clear(); $available = @($DailyPoints) }
    $selected = @(Select-DistributedKnowledge $available $script:ExamQuestionCount $profile $profile.pending)
    foreach ($p in $selected) { $script:UsedKnowledgeIds.Add([string]$p.id) }
    return $selected
}

function Get-QuestionFingerprint {
    param([string]$Stem)
    return ($Stem -replace '[\s\p{P}\p{S}]','').ToLowerInvariant()
}

function Save-ExamResult {
    param($Exam, [int[]]$Answers)
    if ($Answers.Count -ne $Exam.Questions.Count -or $Answers -contains -1) { throw '不能保存未完成的试卷。' }
    $profile = Get-LearningProfile
    $pending = @()
    $results = @()
    foreach ($i in 0..($Answers.Count-1)) {
        $q = $Exam.Questions[$i]
        $id = [string]$q.knowledgePointId
        if (-not $profile.points.ContainsKey($id)) {
            $profile.points[$id]=[pscustomobject]@{id=$id;attempts=0;correct=0;errors=0;streak=0;exposures=0;lastShown='';lastResult=''}
        }
        $stat = $profile.points[$id]
        $right = $Answers[$i] -eq [int]$q.correctIndex
        $stat.attempts++
        $stat.lastResult = if ($right) {'correct'} else {'wrong'}
        if ($right) { $stat.correct++; $stat.streak++ } else { $stat.errors++; $stat.streak=0; $pending += $id }
        $results += [pscustomobject]@{ question=$q; chosenIndex=$Answers[$i]; correct=$right }
    }
    $profile.pending = @($pending | Select-Object -Unique)
    $profile.history += [pscustomobject]@{ id=[guid]::NewGuid().ToString(); time=[DateTimeOffset]::Now.ToString('o'); source=$Exam.Source; results=@($results) }
    $profile.revision++
    Save-LearningProfile $profile
}

function Invoke-QuizAgent {
    param([string]$Role, [string]$Prompt, $Schema)
    $settings = Get-LlmSettings
    if (-not ($settings.enabled -and $settings.apiKey -and $settings.baseUrl -and $settings.model)) { throw 'LLM 未配置完整。' }
    $timeout = [Math]::Max(45, [int](Get-PropertyValue $script:Config.llm 'quizRequestTimeoutSeconds' 60))
    $schemaName = 'sleep_guard_' + $Role
    $headers = @{Authorization="Bearer $($settings.apiKey)"; 'Content-Type'='application/json; charset=utf-8'}
    if ($settings.apiMode -eq 'responses') {
        $body = @{model=$settings.model; input=$Prompt; text=@{format=@{type='json_schema';name=$schemaName;strict=$true;schema=$Schema}}}
        $endpoint = Get-ApiEndpoint $settings.baseUrl 'responses'
    } else {
        $limit=if($Role -eq 'author'){6500}else{4000}
        $body = @{model=$settings.model;messages=@(@{role='system';content="你是独立的 $Role agent。严谨执行当前任务，最终只返回 JSON 对象。"},@{role='user';content=$Prompt});max_tokens=$limit;response_format=@{type='json_object'}}
        if(([uri]$settings.baseUrl).Host -match '(^|\.)deepseek\.com$'){$body.thinking=@{type='disabled'}}
        $endpoint = Get-ApiEndpoint $settings.baseUrl 'chat/completions'
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 40 -Compress))
    $started = Get-Date
    Write-QuizLog "agent=$Role started"
    if($script:PreparationLabel){
        $stage=switch($Role){'author'{'1 / 3 · 正在生成新题'} 'n4_scope_reviewer'{'2 / 3 · 正在审查 N4 范围'} default{'3 / 3 · 正在独立解题与核对答案'}}
        $script:PreparationLabel.Text="$stage`r`n审查未通过的题目不会进入试卷，请稍等一下。"
        $script:PreparationLabel.Refresh()
    }
    try {
        # Explicit UTF-8 decoding avoids PS5.1 response charset guesses.
        $http = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $headers -Body $payload -TimeoutSec $timeout
        $stream = $http.RawContentStream
        $stream.Position=0
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
        try { $response = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        $text = if ($settings.apiMode -eq 'responses') { Get-ResponsesText $response } else { [string]$response.choices[0].message.content }
        $document = ConvertFrom-ModelJson $text
        Write-QuizLog "agent=$Role success model=$($settings.model) seconds=$([int]((Get-Date)-$started).TotalSeconds)"
        return $document
    } catch {
        # Do not persist HTTP bodies, credentials, or provider request dumps.
        Write-QuizLog "agent=$Role failed type=$($_.Exception.GetType().Name)"
        throw "${Role} 调用失败或返回格式无效。"
    }
}

function Get-ReviewSchema {
    param([switch]$AnswerReview)
    $properties = [ordered]@{knowledgePointId=@{type='string'};passed=@{type='boolean'};reason=@{type='string'}}
    if ($AnswerReview) { $properties.solvedIndex=@{type='integer';minimum=0;maximum=3}; $properties.explanation=@{type='string'} }
    return @{type='object';additionalProperties=$false;required=@('reviews');properties=@{reviews=@{type='array';items=@{type='object';additionalProperties=$false;required=@($properties.Keys);properties=$properties}}}}
}

function Assert-AgentReview {
    param($Document, $Questions, [switch]$AnswerReview)
    $reviews = @($Document.reviews)
    if ($reviews.Count -ne @($Questions).Count) { throw "审查未覆盖全部题目（应审 $(@($Questions).Count) 题，返回 $($reviews.Count) 题）。" }
    $seen=[Collections.Generic.HashSet[string]]::new()
    foreach ($r in $reviews) {
        $id=[string]$r.knowledgePointId
        $q=@($Questions | Where-Object knowledgePointId -eq $id)
        if ($q.Count -ne 1 -or -not $seen.Add($id) -or $r.passed -isnot [bool] -or -not $r.passed) {
            throw "审查未通过：$id $([string]$r.reason)"
        }
        if ($AnswerReview) {
            $index=0
            if (-not [int]::TryParse([string]$r.solvedIndex,[ref]$index) -or $index -ne [int]$q[0].correctIndex -or [string]::IsNullOrWhiteSpace([string]$r.explanation)) {
                throw "独立解题与预设答案不一致：$id"
            }
            $q[0].explanation=[string]$r.explanation
        }
    }
}

function Invoke-ReviewedQuestionRequest {
    param($KnowledgePoints, [string[]]$ExcludedStems = @())
    $profile = Get-LearningProfile
    $past = @($profile.seen | Select-Object -Last 150 | ForEach-Object stem) + @($ExcludedStems)
    $study = @($KnowledgePoints | Select-Object id,category,title,content,example,translation) | ConvertTo-Json -Depth 8 -Compress
    $prompt = @"
为下面知识点各原创一道日语四选一填空题，共 $(@($KnowledgePoints).Count) 题。难度为 JLPT N4，允许 N5 基础，不得用 N3以上语法。每题只有一个全角空格括号（　），4个不同选项，唯一正确答案。题干须完整自然，上下文能排除其他选项，不要用常识猜测代替语法，也不能泄露知识点标题。不要复制例句或过去题干，变化场景和问法。不要声称原创题是真题。每个知识点id仅一次。
返回 {"questions":[{"id":"1","knowledgePointId":"原id","stem":"题干（　）。","options":["一","二","三","四"],"correctIndex":0,"explanation":"中文解析","grammarPoint":"原标题"}]}。
知识点：$study
过去题干：$($past | ConvertTo-Json -Compress)
"@
    $document = Invoke-QuizAgent 'author' $prompt (Get-QuestionJsonSchema -Count @($KnowledgePoints).Count)
    $questions = @(ConvertTo-ValidatedQuestionSet $document $KnowledgePoints $past)
    $seenFingerprints = @($profile.seen | ForEach-Object {Get-QuestionFingerprint $_.stem}) + @($ExcludedStems | ForEach-Object {Get-QuestionFingerprint $_})
    foreach ($q in $questions) { if ((Get-QuestionFingerprint $q.stem) -in $seenFingerprints) {throw '生成题复用了历史题干。'} }
    $rangeInput = @($questions | Select-Object knowledgePointId,stem,options,grammarPoint) | ConvertTo-Json -Depth 8 -Compress
    $scope = Invoke-QuizAgent 'n4_scope_reviewer' @"
独立审查以下 $($questions.Count) 道题的词汇、语法、句型是否适合JLPT N4（允许N5基础），并确认实际考查内容对应提供的知识点。官方没有逐词逐语法清单，请按基础日语能力和官方公开样题校准；难度不确定或超纲则passed=false。不得为了凑题通过。逐题返回 {"reviews":[{"knowledgePointId":"id","passed":true,"reason":"40字内依据"}]}。reviews数组必须正好有 $($questions.Count) 项，每个试题id一次，包含全部：$($questions.knowledgePointId -join ',')。
知识点：$study
试题：$rangeInput
"@ (Get-ReviewSchema)
    Assert-AgentReview $scope $questions
    # The solver never receives the author's answer or explanation.
    $blind = @($questions | Select-Object knowledgePointId,stem,options) | ConvertTo-Json -Depth 8 -Compress
    $answer = Invoke-QuizAgent 'independent_answer_reviewer' @"
你是独立日语审题者，请从零解答以下 $($questions.Count) 道四选一试题。将每个选项代入整句，检查语法、语义、搭配、上下文和自然程度。题干错误、答案多解、没有答案或缺少排除其他选项的语境时passed=false。只有唯一无歧义正确答案才通过。solvedIndex为0..3；explanation用120字内中文说明正确理由和容易混淆的错误选项。不要猜测出题者意图。逐题返回 {"reviews":[{"knowledgePointId":"id","passed":true,"solvedIndex":0,"explanation":"中文解析","reason":"40字内审查依据"}]}。reviews数组必须正好有 $($questions.Count) 项，每个试题id一次，包含全部：$($questions.knowledgePointId -join ',')。
试题：$blind
"@ (Get-ReviewSchema -AnswerReview)
    Assert-AgentReview $answer $questions -AnswerReview
    foreach($q in $questions){$q.source='API 原创练习 · N4 范围审查与独立答案复核通过'}
    return $questions
}

function Get-OfficialQuestions {
    if (-not (Test-Path -LiteralPath $script:OfficialBankPath)) { return @() }
    $bank=Get-Content -LiteralPath $script:OfficialBankPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $index=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'official-index.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $valid=@()
    foreach($q in @($bank.questions)){
        $meta=@($index.items|Where-Object {("official-$($_.year)-G-$($_.number)") -eq $q.id})
        if($meta.Count -eq 1 -and $q.knowledgePointId -eq $meta[0].knowledgePointId -and [int]$q.correctIndex -eq ([int]$meta[0].answer-1) -and (Test-Path -LiteralPath $q.imagePath)){$valid+=$q}
    }
    return $valid
}

function Get-QuestionSet {
    param($KnowledgePoints, [string[]]$ExcludedStems = @())
    $profile = Get-LearningProfile
    $official = @(Get-OfficialQuestions)
    $questions = @()
    $missing = @()
    foreach ($p in @($KnowledgePoints)) {
        $candidates=@($official | Where-Object knowledgePointId -eq $p.id)
        # Prefer unseen real questions; stale real questions yield to fresh generation.
        $candidate=@($candidates | Where-Object { (Get-QuestionFingerprint $_.stem) -notin @($profile.seen | ForEach-Object {Get-QuestionFingerprint $_.stem}) -and $_.stem -notin $ExcludedStems } | Get-Random -Count 1)
        if ($candidate.Count) { $questions += $candidate[0] } else { $missing += $p }
    }
    $officialCount=$questions.Count
    $failure=''
    $generatedCount=0
    $cachedCount=0
    if ($missing.Count) {
        for ($attempt=1;$attempt -le 2;$attempt++) {
            try {
                $generated=@(Invoke-ReviewedQuestionRequest $missing $ExcludedStems)
                $questions += $generated
                $generatedCount=$generated.Count
                $cache=@()
                if(Test-Path -LiteralPath $script:ReviewedCachePath){$cache=@((Get-Content -LiteralPath $script:ReviewedCachePath -Raw -Encoding UTF8|ConvertFrom-Json).questions)}
                $cache+=@($generated|ForEach-Object{[pscustomobject]@{question=$_;pipelineVersion=1;reviewedAt=[DateTimeOffset]::Now.ToString('o')}})
                Write-JsonFile $script:ReviewedCachePath ([ordered]@{questions=@($cache|Select-Object -Last 300)})
                break
            } catch { $failure=$_.Exception.Message; Write-QuizLog "审查流水线 attempt=$attempt rejected: $failure" }
        }
        if (-not $generatedCount) {
            $cache=@()
            if(Test-Path -LiteralPath $script:ReviewedCachePath){$cache=@((Get-Content -LiteralPath $script:ReviewedCachePath -Raw -Encoding UTF8|ConvertFrom-Json).questions)}
            foreach($p in $missing){
                $approved=@($cache|Where-Object {$_.pipelineVersion -eq 1 -and $_.question.knowledgePointId -eq $p.id -and $_.question.stem -notin $ExcludedStems}|Select-Object -Last 1)
                $knownReal=@($official|Where-Object {$_.knowledgePointId -eq $p.id -and $_.stem -notin $ExcludedStems}|Get-Random -Count 1)
                if($knownReal.Count){$questions+=$knownReal[0];$officialCount++}
                elseif($approved.Count){$questions+=$approved[0].question;$cachedCount++}
                else {throw "本次未能准备完整的合格试卷：$failure 没有可用真题或双审缓存，请稍后重试。"}
            }
        }
    }
    $questions=@(ConvertTo-ValidatedQuestionSet ([pscustomobject]@{questions=$questions}) $KnowledgePoints)
    # Remove answer-position bias in the old bank without changing answer meaning.
    foreach ($q in $questions) {
        if(-not $q.imagePath){
            $answerText=[string]$q.options[$q.correctIndex]
            $q.options=@($q.options | Sort-Object {Get-Random})
            $q.correctIndex=[array]::IndexOf($q.options,$answerText)
        }
    }
    $questions=@($questions | Sort-Object {Get-Random})
    $source="官方真题 $officialCount 题 / API 即时生成并双审 $generatedCount 题 / 双审缓存 $cachedCount 题"
    $description=$source
    if ($generatedCount) { $description+="`r`n生成题已通过 N4 范围审查与隐藏预设答案的独立解题复核。" }
    if ($cachedCount) { $description+="`r`nAPI 未成功，缓存题是此前通过两道审查的旧题。原因：$failure" }
    if ($officialCount) { $description+="`r`n官方题来自 JLPT 公开真题选编，答案采用官方正答表；详细出处在交卷后显示。" }
    foreach ($q in $questions) { $profile.seen += [pscustomobject]@{stem=$q.stem;time=[DateTimeOffset]::Now.ToString('o')} }
    Save-LearningProfile $profile
    return [pscustomobject]@{Source=$source;Description=$description;Questions=$questions}
}
