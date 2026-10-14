function Show-LearningLibrary {
    param([Windows.Forms.Form]$Owner, [switch]$Mistakes)
    $profile=Get-LearningProfile
    $library=New-Object Windows.Forms.Form
    $library.Text='睡眠守卫 · 知识库与错题本'
    $library.Size=New-Object Drawing.Size(1000,760)
    $library.MinimumSize=New-Object Drawing.Size(820,620)
    $library.StartPosition='CenterParent'
    $library.BackColor=$script:Colors.Background
    $library.Font=$script:UiFont
    $library.TopMost=$true
    $tabs=New-Object Windows.Forms.TabControl
    $tabs.Dock='Fill'
    $library.Controls.Add($tabs)
    $knowledgeTab=New-Object Windows.Forms.TabPage('知识库')
    $wrongTab=New-Object Windows.Forms.TabPage('错题本')
    $tabs.TabPages.AddRange(@($knowledgeTab,$wrongTab))

    $search=New-Object Windows.Forms.TextBox
    $search.Dock='Top'
    $search.Font=$script:UiFont
    $searchHint=New-Object Windows.Forms.Label
    $searchHint.Text='按标题、日语、中文解释或 ID 搜索；左侧为目录。学习记录从本次更新开始积累。'
    $searchHint.Dock='Top'
    $searchHint.Height=32
    $split=New-Object Windows.Forms.SplitContainer
    $split.Size=New-Object Drawing.Size(960,640)
    $split.Dock='Fill'
    $split.SplitterDistance=310
    $tree=New-Object Windows.Forms.TreeView
    $tree.Dock='Fill'
    $tree.HideSelection=$false
    $split.Panel1.Controls.Add($tree)
    $detail=New-Object Windows.Forms.TextBox
    $detail.Dock='Fill'
    $detail.ReadOnly=$true
    $detail.Multiline=$true
    $detail.ScrollBars='Vertical'
    $detail.BackColor=$script:Colors.Card
    $detail.Font=$script:JapaneseFont
    $split.Panel2.Controls.Add($detail)
    $knowledgeTab.Controls.Add($split)
    $knowledgeTab.Controls.Add($search)
    $knowledgeTab.Controls.Add($searchHint)

    $rebuild={
        $tree.BeginUpdate()
        $tree.Nodes.Clear()
        $query=$search.Text.Trim()
        $roots=@{}
        foreach($point in @($script:KnowledgeBank | Sort-Object {Get-KnowledgeDirectory $_},id)) {
            if($query -and ("$($point.id) $($point.title) $($point.content) $($point.example)".IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0)){continue}
            $directory=Get-KnowledgeDirectory $point
            if(-not $roots.ContainsKey($directory)){$roots[$directory]=$tree.Nodes.Add($directory)}
            $stat=$profile.points[[string]$point.id]
            $mark=if($point.id -in @($profile.pending)){'待复习'}elseif($stat -and $stat.attempts -gt 0 -and $stat.errors -eq 0){'熟悉'}elseif($stat -and $stat.errors -gt 0){'曾错'}else{'未测'}
            $node=$roots[$directory].Nodes.Add("[$mark] $($point.title)")
            $node.Tag=$point
        }
        $tree.ExpandAll()
        $tree.EndUpdate()
    }
    $search.Add_TextChanged($rebuild)
    $tree.Add_AfterSelect({
        $point=$_.Node.Tag
        if($null -eq $point){return}
        $stat=$profile.points[[string]$point.id]
        $record=if($stat){"答题 $($stat.attempts) 次 · 答对 $($stat.correct) · 答错 $($stat.errors) · 连续正确 $($stat.streak)"}else{'还没有答题记录'}
        $detail.Text="$($point.title)   [$($point.id)]`r`n$(Get-KnowledgeDirectory $point)`r`n`r`n$($point.content)`r`n`r`n例：$($point.example)`r`n译：$($point.translation)`r`n`r`n$record`r`n`r`n抽取规则：上次错题优先复习；从未答错的知识点降低权重；每次尽量覆盖不同目录。"
    })
    & $rebuild
    $detail.Text="这里收录全部 $(@($script:KnowledgeBank).Count) 个知识点，可随时查阅。`r`n`r`n官方 JLPT 公开真题选编（个人学习）：`r`nhttps://www.jlpt.jp/e/samples/sampleindex.html`r`n`r`n官方题只保存在本机，不随开源项目上传。"

    $wrongSplit=New-Object Windows.Forms.SplitContainer
    $wrongSplit.Size=New-Object Drawing.Size(960,640)
    $wrongSplit.Dock='Fill'
    $wrongSplit.SplitterDistance=320
    $wrongTab.Controls.Add($wrongSplit)
    $wrongList=New-Object Windows.Forms.ListBox
    $wrongList.Dock='Fill'
    $wrongList.HorizontalScrollbar=$true
    $wrongList.DisplayMember='Label'
    $wrongSplit.Panel1.Controls.Add($wrongList)
    $wrongDetail=New-Object Windows.Forms.TextBox
    $wrongDetail.Dock='Fill'
    $wrongDetail.ReadOnly=$true
    $wrongDetail.Multiline=$true
    $wrongDetail.ScrollBars='Vertical'
    $wrongDetail.BackColor=$script:Colors.Card
    $wrongDetail.Font=$script:JapaneseFont
    $wrongSplit.Panel2.Controls.Add($wrongDetail)
    $wrongPicture=New-Object Windows.Forms.PictureBox
    $wrongPicture.Dock='Top'
    $wrongPicture.SizeMode='Zoom'
    $wrongPicture.Height=260
    $wrongPicture.Visible=$false
    $wrongSplit.Panel2.Controls.Add($wrongPicture)
    $allWrong=@()
    foreach($exam in @($profile.history | Sort-Object time -Descending)) {
        foreach($result in @($exam.results | Where-Object {-not $_.correct})) {
            $q=$result.question
            $stamp=([DateTimeOffset]::Parse($exam.time)).ToLocalTime().ToString('MM-dd HH:mm')
            $label="$stamp · $($q.grammarPoint)"
            $allWrong += [pscustomobject]@{Label=$label;Question=$q;Chosen=[int]$result.chosenIndex;Time=$exam.time;Source=$exam.source}
        }
    }
    foreach($entry in $allWrong){[void]$wrongList.Items.Add($entry)}
    $wrongDetail.Text="目前保存 $($allWrong.Count) 道错题。`r`n`r`n左侧点击即可查看题干、所有选项、自己的答案、正确答案、解析与来源。`r`n`r`n以后答对会更新知识点状态，历史错题仍会保留。"
    $wrongList.Add_SelectedIndexChanged({
        $entry=$wrongList.SelectedItem
        if($null -eq $entry){return}
        $q=$entry.Question
        if($wrongPicture.Image){$wrongPicture.Image.Dispose();$wrongPicture.Image=$null}
        if($q.imagePath -and (Test-Path -LiteralPath $q.imagePath)){
            $original=[Drawing.Image]::FromFile($q.imagePath)
            try{$wrongPicture.Image=New-Object Drawing.Bitmap($original)}finally{$original.Dispose()}
            $wrongPicture.Visible=$true
        }else{$wrongPicture.Visible=$false}
        $options=for($j=0;$j -lt 4;$j++){"$([char](65+$j)). $($q.options[$j])"}
        $status=if($q.knowledgePointId -in @($profile.pending)){'下次优先复习'}else{'历史错题'}
        $wrongDetail.Text="$($q.grammarPoint) · $status`r`n$($entry.Time)`r`n`r`n$($q.stem)`r`n`r`n$($options -join "`r`n")`r`n`r`n你的答案：$([char](65+$entry.Chosen)). $($q.options[$entry.Chosen])`r`n正确答案：$([char](65+[int]$q.correctIndex)). $($q.options[[int]$q.correctIndex])`r`n`r`n解析：$($q.explanation)`r`n`r`n本卷来源：$($entry.Source)`r`n题目出处：$($q.source)`r`n$($q.sourceUrl)"
    })
    if($Mistakes){$tabs.SelectedTab=$wrongTab}
    if($script:UiTestRoot){
        if($Mistakes){
            if($wrongList.Items.Count -lt 1){throw 'UI 自检错题列表为空。'}
            $wrongList.SelectedIndex=0
            if($wrongDetail.Text -notmatch '正确答案'){throw '错题本选中条目没有展示答案。'}
        }else{
            $search.Text='連絡'
            if($tree.Nodes.Count -ne 1 -or $tree.Nodes[0].Nodes.Count -ne 1){throw '知识库搜索没有正确过滤目录。'}
            [void]$tree.Handle
            $tree.SelectedNode=$tree.Nodes[0].Nodes[0]
            if($detail.Text -notmatch '連絡'){throw '知识点点击后没有展示详情。'}
        }
    }
    $library.Add_Shown({$split.SplitterDistance=320;$wrongSplit.SplitterDistance=320})
    [void](Show-GuardianDialog $library $Owner 'library')
    if($wrongPicture.Image){$wrongPicture.Image.Dispose();$wrongPicture.Image=$null}
    $library.Dispose()
}
