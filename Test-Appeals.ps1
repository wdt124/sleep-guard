$appealTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('SleepGuard-appeals-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($appealTestRoot)
$originalLearningPath=$script:LearningPath
$originalQuizLog=$QuizLogPath
$originalAgent=${function:Invoke-QuizAgent}
$script:LearningPath=Join-Path $appealTestRoot 'history.json'
$QuizLogPath=Join-Path $appealTestRoot 'quiz.log'
function Assert-AppealTest {
    param([bool]$Condition,[string]$Label)
    if(-not $Condition){throw "TEST FAILED: $Label"}
    Write-Host "PASS $Label"
}
try{
    $points=@($script:KnowledgeBank|Select-Object -First 10)
    $questions=@(Get-LocalQuestionSet $points)
    $questions[0].stem='私は昨日学校に（　）。'
    $questions[0].options=@('行きました','食べました','読みました','寝ました')
    $questions[0].correctIndex=1
    $questions[0].explanation='故意设置的错误答案，仅用于申辩测试。'
    $exam=[pscustomobject]@{Source='申辩隔离测试';Questions=$questions}
    $answers=@($questions|ForEach-Object {[int]$_.correctIndex})
    $answers[0]=0
    Save-ExamResult $exam $answers
    Assert-AppealTest ((@(Get-ExamMarking $exam $answers)|Where-Object Correct).Count -eq 9) 'initial paper is 9 of 10'
    Save-ExamResult $exam $answers
    Assert-AppealTest ((Get-LearningProfile).history.Count -eq 1) 'saving same submitted paper is idempotent'
    if($TestAppealApi){
        $verdict=Send-QuestionAppeal -AttemptId $exam.AttemptId -QuestionIndex 0 -Message '学校に行きました才是自然的日语。原判把食べました设为正确答案，但学校に食べました不符合这里的句法和语义。我选的是行きました，请重新检查。'
        Assert-AppealTest ($verdict.status -eq 'accepted') 'real configured API accepts clear answer-key error'
        Assert-AppealTest ((@(Get-ExamMarking $exam $answers)|Where-Object Correct).Count -eq 10) 'real API verdict changes only the challenged item to correct'
        Write-Host ('API reply: '+$verdict.reply)
    }else{
        $script:AppealMockMode='continue'
        $script:AppealMockCalls=0
        $script:AppealMockLastMessages=@()
        function Invoke-QuizAgent {
            param($Role,$Prompt,$Schema,$Messages)
            if($Role -ne 'appeal_adjudicator'){throw 'Unexpected API role'}
            $script:AppealMockCalls++
            $script:AppealMockLastMessages=@($Messages)
            if($script:AppealMockMode -eq 'network-error'){throw '模拟网络错误'}
            $context=([string]$Messages[1].content -replace '^.*?：','')|ConvertFrom-Json
            $document=[pscustomobject]@{caseId=$context.caseId;questionNumber=$context.questionNumber;decision=$script:AppealMockMode;reply='请结合学校に行く的搭配继续说明。';reason='独立重新审题';questionFlawed=$false}
            switch($script:AppealMockMode){
                'accept'{$document.questionFlawed=$true;$document.reply='原答案有误，行きました符合题意。申辩通过。'}
                'wrong-case'{$document.decision='accept';$document.caseId='other-case'}
                'wrong-question'{$document.decision='accept';$document.questionNumber=2}
                'bad-type'{$document.decision='accept';$document.questionFlawed='true'}
                'bad-decision'{$document.decision='accepted'}
                'contradictory'{$document.decision='reject';$document.questionFlawed=$true}
            }
            return $document
        }
        $before=(Get-FileHash -LiteralPath $script:LearningPath).Hash
        foreach($mode in @('network-error','wrong-case','wrong-question','bad-type','bad-decision','contradictory')){
            $script:AppealMockMode=$mode
            $failed=$false
            try{[void](Send-QuestionAppeal $exam.AttemptId 0 '请复核原答案。')}catch{$failed=$true}
            Assert-AppealTest ($failed -and (Get-FileHash -LiteralPath $script:LearningPath).Hash -eq $before) "$mode cannot alter a score or stored history"
        }
        $script:AppealMockMode='continue'
        $verdict=Send-QuestionAppeal $exam.AttemptId 0 '我认为这里应该用行きました。'
        Assert-AppealTest ($verdict.status -eq 'continue' -and (@(Get-ExamMarking $exam $answers)|Where-Object Correct).Count -eq 9) 'discussion alone does not award credit'
        $script:AppealMockMode='reject'
        $verdict=Send-QuestionAppeal $exam.AttemptId 0 '请检查に和行く的搭配。'
        Assert-AppealTest ($verdict.status -eq 'rejected' -and $script:AppealMockLastMessages.Count -eq 5) 'second API call retains earlier user and assistant turns'
        $script:AppealMockMode='accept'
        $verdict=Send-QuestionAppeal $exam.AttemptId 0 '昨日学校に行きました是完整的过去时句子。'
        $profile=Get-LearningProfile
        Assert-AppealTest ($verdict.status -eq 'accepted' -and (@(Get-ExamMarking $exam $answers)|Where-Object Correct).Count -eq 10) 'successful appeal produces a fully passed exam'
        Assert-AppealTest ($profile.history.Count -eq 1 -and $profile.history[0].results[0].question.correctIndex -eq 1 -and $profile.history[0].results[0].chosenIndex -eq 0) 'original key and chosen answer are retained'
        $stat=$profile.points[$questions[0].knowledgePointId]
        Assert-AppealTest ($stat.attempts -eq 1 -and $stat.correct -eq 1 -and $stat.errors -eq 0 -and $profile.pending.Count -eq 0) 'acceptance corrects counters and next-exam mistake queue'
        Assert-AppealTest ((Get-QuestionFingerprint $questions[0].stem) -in $profile.quarantined) 'confirmed faulty question is quarantined'
        $calls=$script:AppealMockCalls
        [void](Send-QuestionAppeal $exam.AttemptId 0 '再次打开同一申辩。')
        Assert-AppealTest ($script:AppealMockCalls -eq $calls -and (Get-LearningProfile).points[$questions[0].knowledgePointId].correct -eq 1) 'accepted appeal cannot award credit twice'
        # Older paper credits must not erase a later mistake on the same knowledge point.
        $older=[pscustomobject]@{Source='older';Questions=$questions}
        $newer=[pscustomobject]@{Source='newer';Questions=$questions}
        Save-ExamResult $older $answers
        Save-ExamResult $newer $answers
        [void](Send-QuestionAppeal $older.AttemptId 0 '原答案有误。')
        Assert-AppealTest ($questions[0].knowledgePointId -in (Get-LearningProfile).pending) 'older appeal preserves unresolved mistake in latest paper'
        $imageExam=[pscustomobject]@{Source='image';Questions=@($questions|ForEach-Object {$_|ConvertTo-Json -Depth 8|ConvertFrom-Json})}
        $imageExam.Questions[0].imagePath='personal-official.png'
        Save-ExamResult $imageExam $answers
        $calls=$script:AppealMockCalls;$failed=$false
        try{[void](Send-QuestionAppeal $imageExam.AttemptId 0 '这题有问题。')}catch{$failed=$true}
        Assert-AppealTest ($failed -and $script:AppealMockCalls -eq $calls) 'image question cannot be judged without actual question text'
    }
    Write-Host 'Appeal tests complete; live history and guardian state unchanged.'
}finally{
    ${function:Invoke-QuizAgent}=$originalAgent
    $script:LearningPath=$originalLearningPath
    $QuizLogPath=$originalQuizLog
    $resolved=[IO.Path]::GetFullPath($appealTestRoot)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'SleepGuard-appeals-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
