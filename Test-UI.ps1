$script:UiTestRoot=Join-Path $DataRoot 'ui-check'
[void][IO.Directory]::CreateDirectory($script:UiTestRoot)
$previewOwner=New-Object Windows.Forms.Form
$previewOwner.Opacity=0
$previewOwner.ShowInTaskbar=$false
$previewOwner.Show()
try{
    # Actual official image controls and reviewed generated text are tested together.
    $official=@(Get-OfficialQuestions|Select-Object -First 5)
    $cache=@((Get-Content -LiteralPath $script:ReviewedCachePath -Raw -Encoding UTF8|ConvertFrom-Json).questions|Select-Object -Last 5|ForEach-Object question)
    $exam=[pscustomobject]@{Source='UI 自检：官方原题与双审生成题';Questions=@($official)+@($cache)}
    if($exam.Questions.Count -ne 10){throw 'UI 自检需要导入官方题与至少5道双审缓存题。'}
    [void](Show-QuizForm $previewOwner $exam)
    $answers=@($exam.Questions|ForEach-Object {([int]$_.correctIndex+1)%4})
    $savedLearningPath=$script:LearningPath
    $script:LearningPath=Join-Path $script:UiTestRoot 'isolated-history.json'
    try{
        Save-ExamResult $exam $answers
        [void](Show-ReviewForm $previewOwner $exam $answers)
        Show-LearningLibrary $previewOwner
        $knowledgeCapture=Join-Path $script:UiTestRoot 'library.png'
        [IO.File]::Copy($knowledgeCapture,(Join-Path $script:UiTestRoot 'knowledge-library.png'),$true)
        Show-LearningLibrary $previewOwner -Mistakes
        # Drive the real send-button event with an isolated API stub, not live records.
        $originalAgent=${function:Invoke-QuizAgent}
        function Invoke-QuizAgent{
            param($Role,$Prompt,$Schema,$Messages)
            $context=([string]$Messages[1].content -replace '^.*?：','')|ConvertFrom-Json
            return [pscustomobject]@{caseId=$context.caseId;questionNumber=$context.questionNumber;decision='accept';reply='你指出的搭配问题成立，原题上下文不足，存在歧义。本题申辩通过，按正确计分。';reason='题干上下文不足，不能唯一排除你的选项。';questionFlawed=$true}
        }
        try{
            $appealExam=[pscustomobject]@{Source='UI 申辩测试';Questions=$exam.Questions}
            $appealAnswers=@($appealExam.Questions|ForEach-Object {[int]$_.correctIndex})
            $appealAnswers[5]=($appealAnswers[5]+1)%4
            Save-ExamResult $appealExam $appealAnswers
            $script:UiBeforeCapture={param($window)
                if($window.Text -match '题申辩'){
                    $window.Tag.Input.Text='这里的上下文不足，我选择的选项也能自然成立，请重新审题。'
                    $window.Tag.Send.PerformClick()
                    if(-not $window.Tag.Accepted){throw 'UI 申辩发送按钮没有更新成绩。'}
                }
            }
            if(-not (Show-QuestionAppeal $previewOwner $appealExam 5)){throw 'UI 申辩没有返回通过状态。'}
            $script:UiBeforeCapture={param($window)
                if($window.Text -eq '睡眠守卫 · 答案与解析'){
                    $unlock=@($window.Controls|Where-Object {$_.Text -match '^我完成了，停用到'})
                    if($unlock.Count -ne 1){throw '申辩后全卷通过仍未显示停用按钮。'}
                }
            }
            [void](Show-ReviewForm $previewOwner $appealExam $appealAnswers)
            Show-LearningLibrary $previewOwner -Mistakes
        }finally{${function:Invoke-QuizAgent}=$originalAgent;$script:UiBeforeCapture=$null}
    }finally{$script:LearningPath=$savedLearningPath}
    [pscustomobject]@{UiCheck='Passed';Screenshots=$script:UiTestRoot;GuardianStateChanged=$false}|Format-List
}finally{$previewOwner.Close();$previewOwner.Dispose();$script:UiTestRoot=$null}
