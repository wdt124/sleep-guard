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
    [void](Show-ReviewForm $previewOwner $exam $answers)
    $savedLearningPath=$script:LearningPath
    $script:LearningPath=Join-Path $script:UiTestRoot 'isolated-history.json'
    try{
        Save-ExamResult $exam $answers
        Show-LearningLibrary $previewOwner
        $knowledgeCapture=Join-Path $script:UiTestRoot 'library.png'
        [IO.File]::Copy($knowledgeCapture,(Join-Path $script:UiTestRoot 'knowledge-library.png'),$true)
        Show-LearningLibrary $previewOwner -Mistakes
    }finally{$script:LearningPath=$savedLearningPath}
    [pscustomobject]@{UiCheck='Passed';Screenshots=$script:UiTestRoot;GuardianStateChanged=$false}|Format-List
}finally{$previewOwner.Close();$previewOwner.Dispose();$script:UiTestRoot=$null}
