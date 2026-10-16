function Update-AppealConversation {
    param([Windows.Forms.Form]$Dialog)
    $state=$Dialog.Tag
    $target=Get-AppealTarget (Get-LearningProfile) $state.AttemptId $state.Index
    $appeal=Get-PropertyValue $target.Result 'appeal' $null
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('评审：请告诉我，这道题的题干、选项或原判答案哪里让你觉得不合理？可以引用日语语法、词义、上下文或反例；我会重新审题。')
    foreach($turn in @(Get-PropertyValue $appeal 'messages' @())){
        if($turn.role -eq 'user'){$lines.Add("你：`r`n$($turn.content)")}
        elseif($turn.role -eq 'assistant'){
            try{$reply=$turn.content|ConvertFrom-Json;$lines.Add("评审：`r`n$($reply.reply)")}catch{}
        }
    }
    $state.Chat.Text=$lines -join "`r`n`r`n"
    $state.Chat.SelectionStart=$state.Chat.TextLength
    $state.Chat.ScrollToCaret()
    $status=[string](Get-PropertyValue $appeal 'status' '')
    $state.Accepted=($status -eq 'accepted')
    $state.Status.Text=switch($status){'accepted'{'申辩已通过，本题已按正确计分。'} 'rejected'{'本轮暂未通过，你可以继续补充依据。'} default{'围绕这道题说说你的疑问，评审会保留对话上下文。'}}
    $state.Send.Enabled=-not $state.Accepted
    $state.Input.Enabled=-not $state.Accepted
    $state.Send.Text=if($state.Accepted){'本题已通过'}else{'发送给 API 评审'}
    $state.Close.Text=if($state.Accepted){'返回试卷，查看更新后的成绩'}else{'返回试卷'}
    if($state.Accepted){[void]$state.Close.Focus()}
}

function Show-QuestionAppeal {
    param([Windows.Forms.Form]$Owner, $Exam, [int]$QuestionIndex)
    $attemptId=[string](Get-PropertyValue $Exam 'AttemptId' '')
    $target=Get-AppealTarget (Get-LearningProfile) $attemptId $QuestionIndex
    $q=$target.Result.question
    $chosen=[int]$target.Result.chosenIndex
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text="睡眠守卫 · 第 $($QuestionIndex+1) 题申辩"
    $dialog.Size=New-Object Drawing.Size(1060,800)
    $dialog.MinimumSize=New-Object Drawing.Size(920,680)
    $dialog.StartPosition='CenterParent'
    $dialog.TopMost=$true
    $dialog.Font=$script:UiFont
    $dialog.BackColor=$script:Colors.Background

    $heading=New-Object Windows.Forms.Label
    $heading.Text='把疑问说清楚，我们一起重新审这道题。申辩通过后，本题按正确计分。'
    $heading.Dock='Top'
    $heading.Height=46
    $heading.Padding=New-Object Windows.Forms.Padding(12)
    $heading.ForeColor=$script:Colors.Text
    $close=New-UiButton -Text '返回试卷' -Width 300 -Height 40 -BackColor $script:Colors.Muted
    $close.Dock='Bottom'
    $close.Add_Click({$this.FindForm().Close()})
    $split=New-Object Windows.Forms.SplitContainer
    $split.Size=New-Object Drawing.Size(1020,650)
    $split.Dock='Fill'
    $split.SplitterDistance=410
    $dialog.Controls.Add($split)
    $dialog.Controls.Add($heading)
    $dialog.Controls.Add($close)

    $reference=New-Object Windows.Forms.TextBox
    $reference.ReadOnly=$true
    $reference.Multiline=$true
    $reference.ScrollBars='Vertical'
    $reference.Dock='Fill'
    $reference.Font=$script:JapaneseFont
    $reference.BackColor=$script:Colors.Card
    $options=for($j=0;$j -lt 4;$j++){"$([char](65+$j)). $($q.options[$j])"}
    $reference.Text="$($q.stem)`r`n`r`n$($options -join "`r`n")`r`n`r`n你的原选择：$([char](65+$chosen)). $($q.options[$chosen])`r`n原判答案：$([char](65+[int]$q.correctIndex)). $($q.options[[int]$q.correctIndex])`r`n`r`n原判解析：$($q.explanation)`r`n`r`n来源：$($q.source)`r`n$($q.sourceUrl)"
    $transcript=New-Object Windows.Forms.TextBox
    $transcript.Multiline=$true
    $transcript.ScrollBars='Vertical'
    $transcript.Dock='Fill'
    $transcript.Font=$script:JapaneseFont
    $transcript.MaxLength=12000
    $existing=Get-PropertyValue $target.Result 'appeal' $null
    $transcript.Text=[string](Get-PropertyValue $existing 'transcript' '')
    if($q.imagePath){
        $reference.Dock='Top'
        $reference.Height=170
        $image=New-QuestionPicture $q -Width 400
        $image.Dock='Top'
        $image.Height=[Math]::Min(230,$image.Height)
        $prompt=New-Object Windows.Forms.Label
        $prompt.Dock='Top'
        $prompt.Height=53
        $prompt.Text="图片题：请在下方补充完整题干和四个选项。`r`n本次 API 按这些文字复核；上方保留原图供对照。"
        $split.Panel1.Controls.Add($transcript)
        $split.Panel1.Controls.Add($prompt)
        $split.Panel1.Controls.Add($reference)
        $split.Panel1.Controls.Add($image)
    }else{$split.Panel1.Controls.Add($reference)}

    $chat=New-Object Windows.Forms.TextBox
    $chat.Multiline=$true
    $chat.ReadOnly=$true
    $chat.ScrollBars='Vertical'
    $chat.Dock='Fill'
    $chat.BackColor=$script:Colors.Card
    $chat.Font=$script:JapaneseFont
    $compose=New-Object Windows.Forms.Panel
    $compose.Dock='Bottom'
    $compose.Height=150
    $messageInput=New-Object Windows.Forms.TextBox
    $messageInput.Multiline=$true
    $messageInput.ScrollBars='Vertical'
    $messageInput.Dock='Fill'
    $messageInput.MaxLength=6000
    $messageInput.Font=$script:JapaneseFont
    $send=New-UiButton -Text '发送给 API 评审' -Height 36
    $send.Dock='Bottom'
    $compose.Controls.Add($messageInput)
    $compose.Controls.Add($send)
    $status=New-Object Windows.Forms.Label
    $status.Dock='Bottom'
    $status.Height=48
    $status.ForeColor=$script:Colors.Lavender
    $split.Panel2.Controls.Add($chat)
    $split.Panel2.Controls.Add($compose)
    $split.Panel2.Controls.Add($status)
    $dialog.Tag=[pscustomobject]@{AttemptId=$attemptId;Index=$QuestionIndex;Chat=$chat;Input=$messageInput;Send=$send;Status=$status;Close=$close;Transcript=$transcript;Accepted=$false}
    $send.Add_Click({
        $view=$this.FindForm()
        $state=$view.Tag
        if([string]::IsNullOrWhiteSpace($state.Input.Text)){return}
        $this.Enabled=$false
        $state.Status.Text='评审正在重新审题并阅读你的理由，请稍等一下……'
        $state.Status.Refresh()
        try{
            [void](Send-QuestionAppeal -AttemptId $state.AttemptId -QuestionIndex $state.Index -Message $state.Input.Text -QuestionTranscript $state.Transcript.Text)
            $state.Input.Clear()
            Update-AppealConversation $view
        }catch{
            $state.Status.Text=$_.Exception.Message
            $this.Enabled=$true
        }
    })
    Update-AppealConversation $dialog
    $dialog.Add_Shown({$split.SplitterDistance=410;if($this.Tag.Accepted){[void]$this.Tag.Close.Focus()}else{[void]$this.Tag.Input.Focus()}})
    [void](Show-GuardianDialog $dialog $Owner 'appeal')
    $accepted=[bool]$dialog.Tag.Accepted
    $dialog.Dispose()
    return $accepted
}
