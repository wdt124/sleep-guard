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
    $script:MockMode='pass'
    $script:MockCalls=@()
    function Invoke-QuizAgent {
        param($Role,$Prompt,$Schema)
        $script:MockCalls+=$Role
        if($script:MockMode -eq 'unavailable'){throw '模拟 API 不可用'}
        if($Role -eq 'author'){return [pscustomobject]@{questions=$script:MockQuestions}}
        if($Role -eq 'independent_answer_reviewer'){
            if($Prompt -match '"correctIndex"|"grammarPoint"'){throw '盲审泄露了预设答案或知识点标题'}
        }
        $reviews=@($script:MockQuestions|ForEach-Object {[pscustomobject]@{knowledgePointId=$_.knowledgePointId;passed=$true;solvedIndex=$_.correctIndex;explanation='独立求解';reason='审查通过'}})
        if($script:MockMode -eq 'scope-fail' -and $Role -eq 'n4_scope_reviewer'){$reviews[0].passed=$false}
        if($script:MockMode -eq 'answer-fail' -and $Role -eq 'independent_answer_reviewer'){$reviews[0].solvedIndex=($reviews[0].solvedIndex+1)%4}
        return [pscustomobject]@{reviews=$reviews}
    }
    try{
        $approved=@(Invoke-ReviewedQuestionRequest $points)
        Assert-LearningTest ($approved.Count -eq 10 -and ($script:MockCalls -join ',') -eq 'author,n4_scope_reviewer,independent_answer_reviewer') 'runtime pipeline performs three independent calls in order'
        $script:MockMode='scope-fail';$script:MockCalls=@();$rejected=$false
        try{[void](Invoke-ReviewedQuestionRequest $points)}catch{$rejected=$true}
        Assert-LearningTest ($rejected -and 'independent_answer_reviewer' -notin $script:MockCalls) 'failed scope review prevents release'
        $script:MockMode='answer-fail';$rejected=$false
        try{[void](Invoke-ReviewedQuestionRequest $points)}catch{$rejected=$true}
        Assert-LearningTest $rejected 'failed answer review prevents release'
        $script:MockMode='unavailable';$rejected=$false
        try{[void](Get-QuestionSet $points)}catch{$rejected=$true}
        Assert-LearningTest $rejected 'offline without approved cache never falls back to legacy unaudited items'
    }finally{${function:Invoke-QuizAgent}=$originalAgent}
    Write-Host 'Learning tests complete; real learning history unchanged.'
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
