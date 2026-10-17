# This suite uses isolated temporary records; it never changes real learning or allowances.
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('SleepGuard-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$savedLearning=$script:LearningPath
$savedDaily=$DailyStudyPath
$savedOfficial=$script:OfficialBankPath
$savedReviewed=$script:ReviewedCachePath
$savedLog=$QuizLogPath
$script:LearningPath=Join-Path $testRoot 'history.json'
$DailyStudyPath=Join-Path $testRoot 'daily.json'
$script:OfficialBankPath=Join-Path $testRoot 'official.json'
$script:ReviewedCachePath=Join-Path $testRoot 'reviewed.json'
$QuizLogPath=Join-Path $testRoot 'quiz.log'
function Assert-LearningTest {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw "TEST FAILED: $Message"}
    Write-Host "PASS $Message"
}
try {
    Assert-KnowledgeBank
    $daily=@(Get-DailyKnowledgeSet)
    Assert-LearningTest ($daily.Count -eq 30 -and @($daily.id|Select-Object -Unique).Count -eq 30) '30 unique daily points'
    Assert-LearningTest (@($daily|Group-Object {Get-KnowledgeDirectory $_}).Count -eq 10) 'daily set covers all ten directories'
    $cached=@(Get-DailyKnowledgeSet)
    Assert-LearningTest ((($daily.id|Sort-Object)-join ',') -eq (($cached.id|Sort-Object)-join ',')) 'daily pool is stable before new mistakes'
    Register-StudyExposure $daily
    $points=@(Get-ExamKnowledgePoints $daily)
    Assert-LearningTest (@($points|Group-Object {Get-KnowledgeDirectory $_}).Count -eq 10) 'first exam spans all ten directories'
    $questions=@(Get-LocalQuestionSet $points)
    $exam=[pscustomobject]@{Source='test';Questions=$questions}
    $answers=@($questions|ForEach-Object {[int]$_.correctIndex})
    $answers[0]=($answers[0]+1)%4
    Save-ExamResult $exam $answers
    $profile=Get-LearningProfile
    Assert-LearningTest ($profile.history.Count -eq 1 -and $profile.pending.Count -eq 1) 'submitted wrong answer persists'
    $mastered=$points[1]
    $fresh=@($script:KnowledgeBank|Where-Object {$_.id -notin $points.id}|Select-Object -First 1)[0]
    Assert-LearningTest ((Get-PointWeight $mastered $profile) -lt (Get-PointWeight $fresh $profile)*0.05) 'never-wrong point gets under 5 percent of fresh weight'
    $again=@(Get-ExamKnowledgePoints $daily)
    Assert-LearningTest ($questions[0].knowledgePointId -in @($again.id)) 'last error is forced into next exam despite repeat filter'
    # A mistake outside today's pool must be added to the study page before exam selection.
    $outside=@($script:KnowledgeBank|Where-Object {$_.id -notin $daily.id}|Select-Object -First 1)[0]
    $profile.pending=@($outside.id)
    Save-LearningProfile $profile
    $updated=@(Get-DailyKnowledgeSet)
    Assert-LearningTest ($updated.Count -eq 30 -and $outside.id -in $updated.id) 'outside mistake enters current daily pool'
    $goodReviews=[pscustomobject]@{reviews=@($questions|ForEach-Object {[pscustomobject]@{knowledgePointId=$_.knowledgePointId;passed=$true;solvedIndex=$_.correctIndex;explanation='独立解析';reason='通过'}})}
    Assert-AgentReview $goodReviews $questions -AnswerReview
    $goodReviews.reviews[0].solvedIndex=($goodReviews.reviews[0].solvedIndex+1)%4
    $rejected=$false
    try{Assert-AgentReview $goodReviews $questions -AnswerReview}catch{$rejected=$true}
    Assert-LearningTest $rejected 'independent answer disagreement is rejected'
    $goodReviews.reviews[0].solvedIndex=$questions[0].correctIndex
    $goodReviews.reviews[0].passed='true'
    $rejected=$false
    try{Assert-AgentReview $goodReviews $questions}catch{$rejected=$true}
    Assert-LearningTest $rejected 'string true cannot masquerade as boolean review pass'
    $goodReviews.reviews[0].passed=$false
    $rejected=$false
    try{Assert-AgentReview $goodReviews $questions}catch{$rejected=$true}
    Assert-LearningTest $rejected 'scope rejection blocks paper'
    $goodReviews.reviews[0].passed=$true
    $goodReviews.reviews[1].knowledgePointId=$goodReviews.reviews[0].knowledgePointId
    $rejected=$false
    try{Assert-AgentReview $goodReviews $questions}catch{$rejected=$true}
    Assert-LearningTest $rejected 'duplicate or incomplete coverage is rejected'
    $originalAgent=${function:Invoke-QuizAgent}
    $script:MockQuestions=@(Get-LocalQuestionSet $points)
    $script:MockCase=0
    function Reset-QuestionMock {
        param([string]$Mode)
        $script:MockMode=$Mode
        $script:MockCase++
        $script:MockRound=0
        $script:MockCalls=@()
        $script:MockRequests=@()
        $script:MockIssued=@{}
        $script:MockFirstStems=@{}
    }
    function Invoke-QuizAgent {
        param($Role,$Prompt,$Schema)
        $script:MockCalls+=$Role
        if($script:MockMode -eq 'unavailable' -or ($script:MockMode -eq 'review-unavailable' -and $Role -eq 'n4_scope_reviewer')){throw '模拟 API 不可用'}
        if($Role -eq 'author'){
            try{
            $script:MockRound++
            $studyText=[regex]::Match($Prompt,'(?s)知识点：(.*?)\r?\n过去题干：').Groups[1].Value
            $requested=@($studyText|ConvertFrom-Json|ForEach-Object {$_})
            $script:MockRequests+=[pscustomobject]@{Role=$Role;Ids=@($requested.id);Prompt=$Prompt}
            $drafts=@(foreach($point in $requested){
                $draft=@($script:MockQuestions|Where-Object knowledgePointId -eq $point.id)[0]|ConvertTo-Json -Depth 8|ConvertFrom-Json
                $draft.stem+=" 测试批$($script:MockCase)轮$($script:MockRound)"
                if($script:MockRound -eq 1){$script:MockFirstStems[[string]$point.id]=$draft.stem}
                if($script:MockMode -eq 'repeated-repair' -and $script:MockRound -eq 2){$draft.stem=$script:MockFirstStems[[string]$point.id]}
                $script:MockIssued[[string]$point.id]=$draft
                $draft
            })
            if($script:MockRound -eq 1){
                switch($script:MockMode){
                    'fields-once'{$drafts[0].options=@('一','二','三')}
                    'missing-question-once'{$drafts=@($drafts|Select-Object -Skip 1)}
                    'duplicate-question-once'{$drafts+=@($drafts[0])}
                }
            }
            return [pscustomobject]@{questions=$drafts}
            }catch{Write-Host $_.Exception.Message;Write-Host $_.ScriptStackTrace;throw}
        }
        if($Role -eq 'independent_answer_reviewer'){
            if($Prompt -match '"correctIndex"|"grammarPoint"'){throw '盲审泄露了预设答案或知识点标题'}
        }
        $examText=[regex]::Match($Prompt,'(?s)试题：(.*)$').Groups[1].Value
        $requested=@($examText|ConvertFrom-Json|ForEach-Object {$_})
        $script:MockRequests+=[pscustomobject]@{Role=$Role;Ids=@($requested.knowledgePointId);Prompt=$Prompt}
        $reviews=@($requested|ForEach-Object {[pscustomobject]@{knowledgePointId=$_.knowledgePointId;passed=$true;solvedIndex=$script:MockIssued[[string]$_.knowledgePointId].correctIndex;explanation='独立求解';reason='审查通过'}})
        $target=@($reviews|Where-Object knowledgePointId -eq $script:MockQuestions[0].knowledgePointId)
        if($target.Count){
            if($Role -eq 'n4_scope_reviewer'){
                if($script:MockMode -eq 'scope-fail' -or ($script:MockRound -eq 1 -and $script:MockMode -in @('scope-once','repeated-repair'))){$target[0].passed=$false;$target[0].reason='模拟超出N4范围'}
                if($script:MockRound -eq 1){
                    switch($script:MockMode){
                        'review-type-once'{$target[0].passed='true'}
                        'review-missing-once'{$reviews=@($reviews|Where-Object knowledgePointId -ne $target[0].knowledgePointId)}
                        'review-duplicate-once'{$reviews+=@($target[0])}
                    }
                }
            }
            if($Role -eq 'independent_answer_reviewer' -and ($script:MockMode -eq 'answer-fail' -or ($script:MockMode -eq 'answer-once' -and $script:MockRound -eq 1))){$target[0].solvedIndex=($target[0].solvedIndex+1)%4}
        }
        return [pscustomobject]@{reviews=$reviews}
    }
    try{
        Reset-QuestionMock 'pass'
        $approved=@(Invoke-ReviewedQuestionRequest $points)
        Assert-LearningTest ($approved.Count -eq 10 -and ($script:MockCalls -join ',') -eq 'author,n4_scope_reviewer,independent_answer_reviewer') 'runtime pipeline performs three independent calls in order'
        foreach($mode in @('scope-once','answer-once','fields-once','missing-question-once','duplicate-question-once','review-type-once','review-missing-once','review-duplicate-once')){
            Reset-QuestionMock $mode
            $approved=@(Invoke-ReviewedQuestionRequest $points)
            $authors=@($script:MockRequests|Where-Object Role -eq 'author')
            Assert-LearningTest ($approved.Count -eq 10 -and $authors.Count -eq 2 -and $authors[0].Ids.Count -eq 10 -and $authors[1].Ids.Count -eq 1 -and $authors[1].Ids[0] -eq $points[0].id) "$mode replaces only the faulty item automatically"
            $unchanged=@($approved|Where-Object {$_.knowledgePointId -ne $points[0].id -and $_.stem -eq $script:MockFirstStems[[string]$_.knowledgePointId]})
            Assert-LearningTest ($unchanged.Count -eq 9) "$mode preserves nine approved questions"
            $lastRoles=@($script:MockCalls|Select-Object -Last 3)
            Assert-LearningTest (($lastRoles -join ',') -eq 'author,n4_scope_reviewer,independent_answer_reviewer') "$mode replacement receives both independent reviews"
        }
        Reset-QuestionMock 'scope-once'
        [void](Invoke-ReviewedQuestionRequest $points)
        $repairPrompt=@($script:MockRequests|Where-Object Role -eq 'author')[1].Prompt
        Assert-LearningTest ($repairPrompt.Contains('模拟超出N4范围') -and $repairPrompt.Contains($script:MockFirstStems[[string]$points[0].id])) 'repair author receives rejected stem and review feedback'
        Reset-QuestionMock 'repeated-repair'
        $approved=@(Invoke-ReviewedQuestionRequest $points)
        Assert-LearningTest ($approved.Count -eq 10 -and $script:MockRound -eq 3 -and @($script:MockRequests|Where-Object Role -eq 'n4_scope_reviewer').Count -eq 2) 'repeated rejected draft is blocked locally before another review'
        foreach($mode in @('scope-fail','answer-fail')){
            Reset-QuestionMock $mode
            $partial=@(Invoke-ReviewedQuestionRequest $points -AllowPartial)
            Assert-LearningTest ($partial.Count -eq 9 -and $points[0].id -notin @($partial.knowledgePointId) -and $script:MockRound -eq 3) "$mode never releases the bad item and stops after three rounds"
        }
        Reset-QuestionMock 'unavailable';$rejected=$false
        try{[void](Get-QuestionSet $points)}catch{$rejected=$true}
        Assert-LearningTest ($rejected -and $script:MockCalls.Count -eq 1) 'API outage does not waste time repeating unavailable requests'
        # Only the unresolved point needs a backup; the nine good generated items survive.
        $backup=@(Get-LocalQuestionSet @($points[0]))[0]
        Write-JsonFile $script:ReviewedCachePath ([ordered]@{questions=@([pscustomobject]@{question=$backup;pipelineVersion=1;reviewedAt=[DateTimeOffset]::Now.ToString('o')})})
        Reset-QuestionMock 'answer-fail'
        $completed=Get-QuestionSet $points
        Assert-LearningTest ($completed.Questions.Count -eq 10 -and $completed.Source -match '即时生成并双审 9 题 / 双审缓存 1 题') 'permanent review failure silently fills only the gap with approved cache'
        Assert-LearningTest ($completed.Description -notmatch '模拟|不一致|未通过|原因：' -and $completed.Description -notmatch [regex]::Escape([string]$points[0].id)) 'source notice contains no internal rejection details'
        $cache=@((Get-Content -LiteralPath $script:ReviewedCachePath -Raw -Encoding UTF8|ConvertFrom-Json).questions)
        Assert-LearningTest ($cache.Count -eq 10 -and @($cache|Where-Object {$_.question.stem -match "测试批$($script:MockCase)轮" -and $_.question.knowledgePointId -eq $points[0].id}).Count -eq 0) 'cache stores all passing items and no rejected drafts'
        Reset-QuestionMock 'unavailable'
        $completed=Get-QuestionSet $points
        Assert-LearningTest ($completed.Questions.Count -eq 10 -and $completed.Source -match '双审缓存 10 题') 'API outage uses approved backups without exposing raw errors'
        Reset-QuestionMock 'review-unavailable'
        $completed=Get-QuestionSet $points
        Assert-LearningTest ($completed.Questions.Count -eq 10 -and $script:MockCalls.Count -eq 2 -and 'independent_answer_reviewer' -notin $script:MockCalls) 'review API outage goes straight to safe backups instead of repeated generation'
        $malformed=$backup|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $malformed.options=@('一','二','三')
        $cache+=@([pscustomobject]@{question=$malformed;pipelineVersion=1;reviewedAt=[DateTimeOffset]::Now.ToString('o')})
        Write-JsonFile $script:ReviewedCachePath ([ordered]@{questions=$cache})
        Reset-QuestionMock 'unavailable'
        $completed=Get-QuestionSet $points
        Assert-LearningTest ($completed.Questions.Count -eq 10) 'malformed latest cache is skipped automatically in favor of an earlier valid backup'
        $profile=Get-LearningProfile
        $profile.quarantined+=@(Get-QuestionFingerprint $backup.stem)
        Save-LearningProfile $profile
        Reset-QuestionMock 'unavailable';$failureMessage=''
        try{[void](Get-QuestionSet $points)}catch{$failureMessage=$_.Exception.Message}
        Assert-LearningTest ($failureMessage -match '没有足够的合格备用题' -and $failureMessage -notmatch '模拟|审查|独立解题') 'unsafe quarantined backup is never used and terminal notice stays generic'
        Reset-QuestionMock 'scope-once'
        $completed=Get-QuestionSet $points
        Assert-LearningTest ($completed.Questions.Count -eq 10 -and $completed.Source -match '即时生成并双审 10 题 / 双审缓存 0 题' -and $script:MockRound -eq 2) 'full exam assembly continues after automatic replacement without falling back or interrupting'
        # Isolated official-bank fixture exercises both unseen selection and later backup use.
        $meta=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'official-index.json') -Raw -Encoding UTF8|ConvertFrom-Json).items[0]
        $officialPoint=@($script:KnowledgeBank|Where-Object id -eq $meta.knowledgePointId)[0]
        $officialQuestion=@(Get-LocalQuestionSet @($officialPoint))[0]
        $officialQuestion.id="official-$($meta.year)-G-$($meta.number)"
        $officialQuestion.correctIndex=[int]$meta.answer-1
        $officialQuestion.stem+=' 官方题选择测试'
        $officialQuestion.imagePath=$script:LearningPath # Existence-only fixture, never rendered.
        Write-JsonFile $script:OfficialBankPath ([ordered]@{questions=@($officialQuestion)})
        Reset-QuestionMock 'unavailable'
        $completed=Get-QuestionSet @($officialPoint)
        Assert-LearningTest ($completed.Questions.Count -eq 1 -and $completed.Source -match '官方真题 1 题' -and $script:MockCalls.Count -eq 0) 'unseen validated official question needs no generation calls'
        Reset-QuestionMock 'unavailable'
        $completed=Get-QuestionSet @($officialPoint)
        Assert-LearningTest ($completed.Questions.Count -eq 1 -and $completed.Source -match '官方真题 1 题' -and $script:MockCalls.Count -eq 1) 'known official question fills the gap when generation is unavailable'
    }finally{${function:Invoke-QuizAgent}=$originalAgent}
    Write-Host 'Learning tests complete; real learning history unchanged.'
} catch {
    if(Test-Path -LiteralPath $QuizLogPath){Get-Content -LiteralPath $QuizLogPath -Tail 30|Write-Host}
    throw
} finally {
    $script:LearningPath=$savedLearning
    $DailyStudyPath=$savedDaily
    $script:OfficialBankPath=$savedOfficial
    $script:ReviewedCachePath=$savedReviewed
    $QuizLogPath=$savedLog
    # Exact fresh directory, not a workspace or user-data directory.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'SleepGuard-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
