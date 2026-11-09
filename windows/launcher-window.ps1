param([ValidateSet('Start','Pause')][string]$Mode='Start',[string]$PreviewPath,[string]$PreviewQr)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'launcher-common.ps1')
$script:BotUiTick={ [Windows.Forms.Application]::DoEvents() }
$script:Session=$null
$script:Phase='preparing'
$script:Busy=$false
$script:Started=$false
$script:Committing=$false
$script:AllGroups=@()
$script:SelectedGroups=@{}
$script:SelectionContext=$null
$script:UpdatingGroups=$false
$script:ShownGeneration=$null
$script:LoginDeadline=[DateTime]::UtcNow.AddSeconds(340)
$script:PollBusy=$false
$script:OwnsLoginFlow=$false
$script:Discovery=$null
$script:GroupScan=$null
$script:GroupWorker=$null
$script:RetryAction=$null
$script:LoginRetryAt=[DateTime]::MinValue
$script:LastRefresh=[DateTime]::MinValue
$script:LoginStartedAt=[DateTime]::UtcNow
$taskHasher=[Security.Cryptography.SHA256]::Create()
try{
    $taskLockBytes=$taskHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))
    $taskLockName='Local\LumeebotLauncher-'+[BitConverter]::ToString($taskLockBytes,0,12).Replace('-','')
}finally{$taskHasher.Dispose()}
$taskLock=New-Object Threading.Mutex($false,$taskLockName)
$taskOwnsLock=$false
if (-not $PreviewPath) {
    $taskOwnsLock=$taskLock.WaitOne(0)
    if (-not $taskOwnsLock) {
        [void][Windows.Forms.MessageBox]::Show('机器人操作窗口已经打开，请先完成或关闭它。','微信群机器人','OK','Information')
        $taskLock.Dispose()
        exit 0
    }
}
$taskGreen=[Drawing.ColorTranslator]::FromHtml('#078F66')
$taskInk=[Drawing.ColorTranslator]::FromHtml('#163E36')
$taskMuted=[Drawing.ColorTranslator]::FromHtml('#6F827B')
$taskBackground=[Drawing.ColorTranslator]::FromHtml('#F3F7F5')
$form=New-Object Windows.Forms.Form
$form.Text=if($Mode -eq 'Start'){'启动微信群机器人'}else{'暂停微信群机器人'}
$form.ClientSize=[Drawing.Size]::new(640,742)
$form.StartPosition='CenterScreen'
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false
$form.BackColor=$taskBackground
$form.Font=[Drawing.Font]::new('Microsoft YaHei UI',10)
$form.AutoScaleMode='Dpi'
$form.Icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot ('icons\wechat-'+$(if($Mode -eq 'Start'){'start'}else{'pause'})+'.ico')))
function New-BotLabel([Windows.Forms.Control]$Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height,[single]$Size=10,[switch]$Bold) {
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text;$label.Location=[Drawing.Point]::new($X,$Y);$label.Size=[Drawing.Size]::new($Width,$Height)
    $style=if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
    $label.Font=[Drawing.Font]::new('Microsoft YaHei UI',$Size,$style)
    $label.ForeColor=$taskInk
    $Parent.Controls.Add($label)
    return $label
}
$brand=New-Object Windows.Forms.PictureBox
$brand.Location=[Drawing.Point]::new(24,22);$brand.Size=[Drawing.Size]::new(76,76);$brand.SizeMode='Zoom'
$brand.Image=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot ('icons\wechat-'+$(if($Mode -eq 'Start'){'start'}else{'pause'})+'.png')))
$form.Controls.Add($brand)
$title=New-BotLabel $form '微信群机器人' 112 27 470 40 22 -Bold
$subtitle=New-BotLabel $form '先选微信，再选群聊。' 114 74 470 28 10
$subtitle.ForeColor=$taskMuted
$steps=New-Object Windows.Forms.Panel
$steps.Location=[Drawing.Point]::new(32,122);$steps.Size=[Drawing.Size]::new(576,46);$steps.BackColor=[Drawing.Color]::White
$form.Controls.Add($steps)
$stepOne=New-BotLabel $steps '① 扫码选微信' 22 11 220 28 11 -Bold
$stepOne.ForeColor=$taskGreen
$stepTwo=New-BotLabel $steps '② 选择群聊并启动' 296 11 260 28 11
$stepTwo.ForeColor=$taskMuted
$card=New-Object Windows.Forms.Panel
$card.Location=[Drawing.Point]::new(32,184);$card.Size=[Drawing.Size]::new(576,388);$card.BackColor=[Drawing.Color]::White
$form.Controls.Add($card)
$scanTitle=New-BotLabel $card '用想当机器人的微信扫码' 24 18 528 34 15 -Bold
$scanTitle.TextAlign='MiddleCenter'
$qr=New-Object Windows.Forms.PictureBox
$qr.Location=[Drawing.Point]::new(164,64);$qr.Size=[Drawing.Size]::new(248,248);$qr.SizeMode='Zoom';$qr.BackColor=[Drawing.Color]::White
$card.Controls.Add($qr)
$qrPlaceholder=New-BotLabel $qr '正在准备二维码…' 12 100 224 44 11
$qrPlaceholder.TextAlign='MiddleCenter';$qrPlaceholder.ForeColor=$taskMuted
$scanHint=New-BotLabel $card "扫码的是哪个微信，就用哪个微信当机器人。`n换微信时重新扫码，登录后再选择群聊。" 24 326 528 50 10
$scanHint.TextAlign='MiddleCenter';$scanHint.ForeColor=$taskMuted
$groupPanel=New-Object Windows.Forms.Panel
$groupPanel.Dock='Fill';$groupPanel.BackColor=[Drawing.Color]::White;$groupPanel.Visible=$false
$card.Controls.Add($groupPanel)
$accountPanel=New-Object Windows.Forms.Panel
$accountPanel.Dock='Fill';$accountPanel.BackColor=[Drawing.Color]::White;$accountPanel.Visible=$false
$card.Controls.Add($accountPanel)
$accountChoiceTitle=New-BotLabel $accountPanel '选择这次使用的微信' 24 66 528 40 17 -Bold
$accountChoiceTitle.TextAlign='MiddleCenter'
$accountChoiceHint=New-BotLabel $accountPanel "可以继续上次扫码的微信，保留已同步群资料。`n也可以换一个微信重新扫码。" 30 126 516 70 11
$accountChoiceHint.TextAlign='MiddleCenter';$accountChoiceHint.ForeColor=$taskMuted
$changeAccount=New-Object Windows.Forms.Button
$changeAccount.Text='换微信 / 重新扫码';$changeAccount.Location=[Drawing.Point]::new(144,232);$changeAccount.Size=[Drawing.Size]::new(288,50)
$changeAccount.FlatStyle='Flat';$changeAccount.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#D4E0D9');$changeAccount.ForeColor=$taskGreen
$accountPanel.Controls.Add($changeAccount)
$accountLabel=New-BotLabel $groupPanel '微信已登录' 24 18 528 30 14 -Bold
$groupHint=New-BotLabel $groupPanel '可勾选多个群；继续搜索其他群，已选项会保留。' 24 55 528 30 10
$groupHint.ForeColor=$taskMuted
$filter=New-Object Windows.Forms.TextBox
$filter.Location=[Drawing.Point]::new(24,94);$filter.Size=[Drawing.Size]::new(318,30)
$groupPanel.Controls.Add($filter)
$refresh=New-Object Windows.Forms.Button
$refresh.Text='搜索';$refresh.Location=[Drawing.Point]::new(354,91);$refresh.Size=[Drawing.Size]::new(90,34)
$refresh.FlatStyle='Flat';$refresh.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#DBE6E0')
$groupPanel.Controls.Add($refresh)
$sync=New-Object Windows.Forms.Button
$sync.Text='同步群列表';$sync.Location=[Drawing.Point]::new(456,91);$sync.Size=[Drawing.Size]::new(96,34)
$sync.FlatStyle='Flat';$sync.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#D4E0D9');$sync.ForeColor=$taskGreen
$groupPanel.Controls.Add($sync)
$locate=New-Object Windows.Forms.LinkLabel
$locate.Text='仍找不到？辅助定位';$locate.Location=[Drawing.Point]::new(24,305);$locate.Size=[Drawing.Size]::new(220,24)
$locate.LinkColor=$taskMuted;$locate.Visible=$false
$groupPanel.Controls.Add($locate)
$selectionCount=New-BotLabel $groupPanel '已选 0 个群' 24 132 300 24 10 -Bold
$selectionCount.ForeColor=$taskGreen
$selectedOnly=New-Object Windows.Forms.CheckBox
$selectedOnly.Text='只看已选';$selectedOnly.Location=[Drawing.Point]::new(428,130);$selectedOnly.Size=[Drawing.Size]::new(124,28)
$groupPanel.Controls.Add($selectedOnly)
$list=New-Object Windows.Forms.CheckedListBox
$list.CheckOnClick=$true
$list.Location=[Drawing.Point]::new(24,162);$list.Size=[Drawing.Size]::new(528,140);$list.BorderStyle='FixedSingle';$list.DisplayMember='Label';$list.IntegralHeight=$false
$list.ItemHeight=28
$groupPanel.Controls.Add($list)
$groupFoot=New-BotLabel $groupPanel "登录后自动同步群资料，搜索结果持续更新。`n仅在选中群回复，无需 @；部分未同步的群可能暂不显示。" 24 334 528 48 9
$groupFoot.ForeColor=$taskMuted
$status=New-BotLabel $form '正在准备…' 32 588 576 40 10
$status.ForeColor=$taskMuted
$script:BotStatus={param($Text) $status.Text=$Text;[Windows.Forms.Application]::DoEvents()}
$progress=New-Object Windows.Forms.ProgressBar
$progress.Location=[Drawing.Point]::new(32,632);$progress.Size=[Drawing.Size]::new(576,4);$progress.Style='Marquee';$progress.MarqueeAnimationSpeed=26
$form.Controls.Add($progress)
$primary=New-Object Windows.Forms.Button
$primary.Text='等待扫码…';$primary.Location=[Drawing.Point]::new(32,652);$primary.Size=[Drawing.Size]::new(432,48)
$primary.BackColor=$taskGreen;$primary.ForeColor=[Drawing.Color]::White;$primary.FlatStyle='Flat';$primary.FlatAppearance.BorderSize=0;$primary.Font=[Drawing.Font]::new('Microsoft YaHei UI',12,[Drawing.FontStyle]::Bold)
$primary.Enabled=$false
$form.Controls.Add($primary)
$cancel=New-Object Windows.Forms.Button
$cancel.Text='取消';$cancel.Location=[Drawing.Point]::new(480,652);$cancel.Size=[Drawing.Size]::new(128,48)
$cancel.FlatStyle='Flat';$cancel.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#D4E0D9');$cancel.ForeColor=$taskMuted
$form.Controls.Add($cancel)
$footer=New-BotLabel $form '关闭扫码窗口会取消本次登录；启动成功后可关闭窗口。' 32 714 576 24 8
$footer.ForeColor=$taskMuted
$timer=New-Object Windows.Forms.Timer
$timer.Interval=1000
function Show-BotQr([string]$Path) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    $stream=[IO.MemoryStream]::new($bytes)
    $image=[Drawing.Image]::FromStream($stream)
    $copy=[Drawing.Bitmap]::new($image)
    $image.Dispose();$stream.Dispose()
    if($qr.Image){$qr.Image.Dispose()}
    $qr.Image=$copy;$qrPlaceholder.Visible=$false
}
function Get-BotSelectedGroups {
    return @($script:SelectedGroups.Values | Sort-Object displayName,id)
}
function Update-BotSelectionSummary {
    $selectionCount.Text='已选 '+$script:SelectedGroups.Count+' 个群'
    if($script:Phase -eq 'groups' -or ($script:Phase -eq 'retry' -and $script:RetryAction -eq 'start')){
        $primary.Enabled=($script:SelectedGroups.Count -gt 0 -and -not $script:Busy)
    }
}
function Restore-BotGroupSelection {
    $context=([string]$script:Session.id)+'|'+([string]$script:Session.accountId)+'|'+([string]$script:Session.ownUsername)
    if($script:SelectionContext -eq $context){return}
    $script:SelectedGroups=@{};$script:SelectionContext=$context
    $saved=@()
    if($script:Session.groups){$saved=@($script:Session.groups)}
    elseif($script:Session.groupIds){$saved=@($script:Session.groupIds | ForEach-Object {[pscustomobject]@{id=[string]$_;displayName=[string]$_}})}
    elseif($script:Session.groupId){$saved=@([pscustomobject]@{id=[string]$script:Session.groupId;displayName=[string]$script:Session.groupName})}
    foreach($group in $saved){
        if($group.id -and [string]$group.id -like '*@chatroom'){$script:SelectedGroups[[string]$group.id]=$group}
    }
}
function Update-BotGroupList {
    $previous=$null
    if($list.SelectedItem){$previous=$list.SelectedItem.Group.id}
    foreach($group in $script:AllGroups){
        if($script:SelectedGroups.ContainsKey([string]$group.id)){$script:SelectedGroups[[string]$group.id]=$group}
    }
    $query=$filter.Text.Trim()
    $visibleGroups=if($selectedOnly.Checked){@(Get-BotSelectedGroups)}else{@(Search-BotGroups $script:AllGroups $query)}
    $script:UpdatingGroups=$true;$list.BeginUpdate()
    try{
        $list.Items.Clear()
        foreach($group in $visibleGroups) {
            $name=if($group.displayName){[string]$group.displayName}elseif($group.name){[string]$group.name}else{[string]$group.id}
            $label=if(-not(Test-BotGroupName $name $group.id)){'群名待同步 · '+$group.id}elseif($group.source -eq 'saved-directory'){$name+'  · 历史资料'}else{$name}
            if(@($script:AllGroups | Where-Object displayName -eq $name).Count -gt 1){$label+='  · '+$group.id}
            $item=[pscustomobject]@{Label=$label;Group=$group}
            $index=$list.Items.Add($item)
            $list.SetItemChecked($index,$script:SelectedGroups.ContainsKey([string]$group.id))
            if($previous -eq $group.id){$list.SelectedIndex=$index}
        }
    }finally{$list.EndUpdate();$script:UpdatingGroups=$false}
    $locate.Visible=(-not $selectedOnly.Checked -and [bool]$query -and $list.Items.Count -eq 0 -and (-not $script:GroupScan -or $script:GroupScan.finished))
    Update-BotSelectionSummary
    if(-not $script:Discovery){
        $countText=if($selectedOnly.Checked){'正在显示已选的 '+$list.Items.Count+' 个群。'}else{'已载入 '+$script:AllGroups.Count+' 个群；匹配 '+$list.Items.Count+' 个。'}
        $status.Text=if($script:GroupScan -and -not $script:GroupScan.finished){$countText+' '+$script:GroupScan.note}elseif(-not $selectedOnly.Checked -and $query -and $list.Items.Count -eq 0){$countText+' 未找到，可点同步重试或辅助定位。'}else{$countText}
    }
}
function Begin-BotGroupSearch {
    if($script:Phase -eq 'retry' -and $script:RetryAction -eq 'start'){$script:Phase='groups';$primary.Text='在选中群启动机器人'}
    if($script:Busy -or $script:Phase -ne 'groups'){return}
    try{
        Update-BotGroupList
        if(-not $script:GroupWorker -or $script:GroupWorker.disposed){
            $script:GroupWorker=Start-BotGroupWorker $script:Session
            $script:GroupScan=[pscustomobject]@{finished=$false;note='正在后台同步群资料，已有结果可直接选择。'}
        }
        Update-BotGroupList
        $timer.Start()
    }catch{if($script:BotCancel){$script:Busy=$false;$form.Close()}else{$status.Text='群资料暂未返回，请稍后搜索；无需重新扫码。'}}
}
function Read-BotGroupList {
    param([switch]$Quiet)
    $script:Busy=$true;$refresh.Enabled=$false;$sync.Enabled=$false
    try{
        if(-not $Quiet){Set-BotStatus '正在读取群列表…'}
        $script:AllGroups=@(Get-BotGroups $script:Session -CachedOnly | Sort-Object displayName,id)
    } finally{$script:Busy=$false;$refresh.Enabled=$true;$sync.Enabled=$true}
    $script:LastRefresh=[DateTime]::UtcNow
    Update-BotGroupList
}
function Show-BotGroupStage($Account){
    Confirm-BotIdentity $script:Session $Account
    Restore-BotGroupSelection
    $accountLabel.Text='已登录：'+$Account.ownUsername
    $script:Phase='groups';$accountPanel.Visible=$false;$scanTitle.Visible=$false;$qr.Visible=$false;$scanHint.Visible=$false
    $groupPanel.Visible=$true;$groupPanel.BringToFront();$stepOne.ForeColor=$taskMuted;$stepTwo.ForeColor=$taskGreen
    $primary.Text='在选中群启动机器人';$progress.Visible=$false;$script:Busy=$false
    $footer.Text='确认选中的群后，点击启动才会开启自动回复。'
    $script:GroupScan=[pscustomobject]@{finished=$false;note='已显示保存的群，正在后台同步最新资料…'}
    try{Read-BotGroupList}catch{
        if($script:BotCancel){throw}
        $status.Text='微信已登录，群资料暂未返回；正在继续读取，无需重新扫码。'
    }
    $script:LastRefresh=[DateTime]::MinValue
    Update-BotGroupList
    $script:GroupWorker=Start-BotGroupWorker $script:Session
    $timer.Start()
}
function Begin-BotContinue {
    try{Stop-BotGroupWorker $script:GroupWorker}catch{Show-BotFailure $_.Exception.Message -RetryAction 'continue';return}
    $script:GroupWorker=$null
    $script:OwnsLoginFlow=$true;$script:Busy=$true;$script:BotCancel=$false;$script:Discovery=$null;$script:GroupScan=$null
    $script:Session=Get-BotReusableSession;$accountPanel.Visible=$false;$scanTitle.Visible=$true;$qr.Visible=$true;$scanHint.Visible=$true
    $primary.Enabled=$false;$primary.Text='正在连接…';$progress.Visible=$true
    try{
        if(Continue-BotLogin $script:Session){Show-BotGroupStage (Get-BotAccount $script:Session)}else{
            $script:Phase='scan';$script:ShownGeneration=$null;$script:LoginStartedAt=[DateTime]::UtcNow
            $script:LoginDeadline=[DateTime]::UtcNow.AddSeconds(340);$timer.Start()
        }
    }catch{if($script:BotCancel){$script:Busy=$false;$form.Close()}else{Show-BotFailure $_.Exception.Message -RetryAction 'continue'}}finally{$script:Busy=$false}
}
function Show-BotFailure([string]$Message,[ValidateSet('','start','continue')][string]$RetryAction='') {
    $script:RetryAction=$RetryAction
    $script:Phase=if($RetryAction){'retry'}else{'failed'}
    $timer.Stop();$script:Busy=$false;$script:Committing=$false
    $progress.Visible=$false;$status.ForeColor=[Drawing.ColorTranslator]::FromHtml('#B3442A');$status.Text=$Message
    $primary.Text=if($RetryAction -eq 'start'){'重试启动所选群'}elseif($RetryAction -eq 'continue'){'重试连接已扫码的微信'}else{'重新扫码'}
    $primary.Enabled=($Mode -eq 'Start');$cancel.Text='关闭';$cancel.Enabled=$true
    $refresh.Enabled=$true;$sync.Enabled=$true;$filter.Enabled=$true;$list.Enabled=$true;$selectedOnly.Enabled=$true
    if($RetryAction -eq 'start'){Update-BotSelectionSummary}
}
function Begin-BotScan {
    try{Stop-BotGroupWorker $script:GroupWorker}catch{Show-BotFailure $_.Exception.Message;return}
    $script:GroupWorker=$null
    $script:OwnsLoginFlow=$true;$script:Busy=$true;$script:Phase='preparing';$script:BotCancel=$false;$script:Discovery=$null;$script:GroupScan=$null
    $script:SelectedGroups=@{};$script:SelectionContext=$null;$script:AllGroups=@();$selectedOnly.Checked=$false
    Update-BotSelectionSummary
    $script:ShownGeneration=$null;$groupPanel.Visible=$false;$accountPanel.Visible=$false;$scanTitle.Visible=$true;$qr.Visible=$true;$scanHint.Visible=$true
    $filter.Text='';$stepOne.Text='① 扫码选微信';$stepOne.ForeColor=$taskGreen;$stepTwo.ForeColor=$taskMuted
    $progress.Visible=$true;$primary.Text='等待扫码…';$primary.Enabled=$false;$cancel.Text='取消'
    $status.ForeColor=$taskMuted;$qrPlaceholder.Visible=$true
    if($qr.Image){$qr.Image.Dispose();$qr.Image=$null}
    try{
        $script:Session=New-BotLogin
        $script:Phase='scan';$script:LoginDeadline=[DateTime]::UtcNow.AddSeconds(340);$script:LoginStartedAt=[DateTime]::UtcNow
        Set-BotStatus '请用希望当机器人的微信扫一扫，并在手机上确认。'
        $timer.Start()
    }catch{
        if($script:BotCancel){$script:Busy=$false;$form.Close();return}
        Show-BotFailure $_.Exception.Message
    }finally{$script:Busy=$false}
}
$timer.Add_Tick({
    if($script:Busy -or $script:PollBusy -or $script:Phase -notin @('scan','groups')){return}
    if($script:Phase -eq 'groups'){
        $script:PollBusy=$true;$script:Busy=$true
        try{
            $view=Read-BotGroupWorker $script:GroupWorker
            if($view -and $view.accountId -eq $script:Session.accountId -and $view.sessionId -eq $script:Session.id){
                if($null -ne $view.groups){$script:AllGroups=@($view.groups)}
                $script:GroupScan=[pscustomobject]@{finished=[bool]$view.finished;note=[string]$view.note}
            }
            if($script:Discovery){
                $found=Find-BotGroupByLocator $script:Session $script:Discovery
                if($found){
                    $script:AllGroups=@($script:AllGroups | Where-Object {$_.id -ne $found.id})+@($found)
                    $selectedOnly.Checked=$false
                    $filter.Text=$found.displayName;$script:Discovery=$null
                    $groupFoot.Text="已通过定位消息确认群身份。`n勾选该群后点击启动；之前勾选的其他群会保留。"
                }
            }
            $script:Busy=$false
            Update-BotGroupList
        }catch{if($script:BotCancel){$script:Busy=$false;$form.Close()}else{$status.Text='群资料暂未返回，可点刷新重试；已登录的微信会保留。'}}finally{$script:PollBusy=$false;$script:Busy=$false;$script:LastRefresh=[DateTime]::UtcNow}
        return
    }
    if([DateTime]::UtcNow -lt $script:LoginRetryAt){return}
    $script:PollBusy=$true;$script:Busy=$true
    try{
        $operation=Get-BotLoginOperation $script:Session
        if($operation.state -eq 'succeeded'){
            Show-BotGroupStage (Get-BotAccount $script:Session)
        }elseif($operation.state -in @('failed','cancelled','expired','needs_review')){
            throw '本次登录未完成。请点击“重新扫码”再试一次。'
        }else{
            $seconds=[int]([DateTime]::UtcNow-$script:LoginStartedAt).TotalSeconds
            $status.Text=if($operation.state -in @('scanned','awaiting_approval')){'已扫描，请在手机确认。正在等待微信返回登录结果（'+$seconds+' 秒）'}elseif($operation.result.qrAvailable){'请扫码并在手机确认（已等待 '+$seconds+' 秒）'}else{'正在连接微信服务器并申请二维码（'+$seconds+' 秒）'}
            if($operation.result.qrAvailable -and $operation.result.qrGeneration -ne $script:ShownGeneration){
                Show-BotQr (Save-BotQr $script:Session $operation)
                $script:ShownGeneration=$operation.result.qrGeneration
                $progress.Visible=$false
            }
            if([DateTime]::UtcNow -gt $script:LoginDeadline){throw '二维码登录超时，请点击“重新扫码”。'}
        }
    }catch{
        if($script:BotCancel){$script:Busy=$false;$form.Close()}elseif((Test-BotTransientError $_) -and [DateTime]::UtcNow -lt $script:LoginDeadline){
            $status.Text='微信服务暂未响应，扫码状态已保留，正在继续等待…'
            $script:LoginRetryAt=[DateTime]::UtcNow.AddSeconds(2)
        }else{Show-BotFailure $_.Exception.Message}
    }finally{$script:PollBusy=$false;$script:Busy=$false}
})
$filter.Add_TextChanged({if(-not $script:Busy){Update-BotGroupList}})
$list.Add_ItemCheck({param($sender,$eventArgs)
    if($script:UpdatingGroups -or $script:Busy){return}
    $group=$list.Items[$eventArgs.Index].Group
    if($eventArgs.NewValue -eq [Windows.Forms.CheckState]::Checked){$script:SelectedGroups[[string]$group.id]=$group}
    else{$script:SelectedGroups.Remove([string]$group.id)}
    Update-BotSelectionSummary
    if($selectedOnly.Checked){[void]$form.BeginInvoke([Action]{if(-not $script:Busy -and -not $form.IsDisposed){Update-BotGroupList}})}
})
$selectedOnly.Add_CheckedChanged({if(-not $script:Busy){Update-BotGroupList}})
$refresh.Add_Click({Begin-BotGroupSearch})
$sync.Add_Click({Begin-BotGroupSearch})
$filter.Add_KeyDown({param($sender,$eventArgs) if($eventArgs.KeyCode -eq 'Enter'){$eventArgs.SuppressKeyPress=$true;Begin-BotGroupSearch}})
$locate.Add_Click({
    $name=$filter.Text.Trim()
    if(-not $name){$status.Text='请先在搜索框输入目标群的完整群名。';return}
    $code='机器人定位 '+[guid]::NewGuid().ToString('N').Substring(0,8)
    $script:Discovery=[pscustomobject]@{name=$name;code=$code;startedAt=[DateTime]::UtcNow}
    $groupFoot.Text="请让群成员发送：$code`n收到后会自动识别这个群；此时不会自动回复。"
    $status.Text='正在等待目标群的定位消息。';$script:LastRefresh=[DateTime]::MinValue
    try{[Windows.Forms.Clipboard]::SetText($code);$status.Text='定位码已复制。请在目标群发送这条定位码。'}catch{}
    $timer.Start()
})
$changeAccount.Add_Click({Begin-BotScan})
$primary.Add_Click({
    if($script:Busy){return}
    if($script:Started -or $Mode -eq 'Pause'){$form.Close();return}
    if($script:Phase -eq 'retry'){
        if($script:RetryAction -eq 'continue'){Begin-BotContinue;return}
        $script:Phase='groups';$status.ForeColor=$taskMuted;$primary.Text='在选中群启动机器人'
    }
    if($script:Phase -eq 'failed'){Begin-BotScan;return}
    if($script:Phase -eq 'choose'){Begin-BotContinue;return}
    if($script:Phase -ne 'groups' -or $script:SelectedGroups.Count -eq 0){return}
    $selectedGroups=@(Get-BotSelectedGroups)
    $script:Busy=$true;$script:Committing=$true;$primary.Enabled=$false;$cancel.Enabled=$false;$refresh.Enabled=$false;$sync.Enabled=$false;$filter.Enabled=$false;$list.Enabled=$false;$selectedOnly.Enabled=$false
    $progress.Visible=$true;$primary.Text='正在启动…'
    try{
        Stop-BotGroupWorker $script:GroupWorker
        Start-BotForGroups $script:Session $selectedGroups
        $script:Started=$true;$script:Phase='running';$primary.Text='完成';$primary.Enabled=$true;$cancel.Visible=$false
        $status.Text='已在 '+$selectedGroups.Count+' 个选中群启动。现在这些群内发言即可触发回复。';$status.ForeColor=$taskGreen
        $progress.Visible=$false;$footer.Text='请保持网关运行。重新以 -Mode Pause 打开本界面即可暂停。'
    }catch{
        $message=$_.Exception.Message
        try{Disable-BotChannel}catch{$message+=' 自动回复关闭未确认，请以 -Mode Pause 打开本界面。'}
        $script:Session.status='select-group';Write-BotSession $script:Session
        Show-BotFailure $message -RetryAction 'start'
    }finally{$script:Busy=$false;$script:Committing=$false}
})
$cancel.Add_Click({
    if($script:Busy){if(-not $script:Committing){$script:BotCancel=$true;Set-BotStatus '正在取消本次登录…'}}else{$form.Close()}
})
$form.Add_FormClosing({param($sender,$eventArgs)
    if($script:Busy){$eventArgs.Cancel=$true;if(-not $script:Committing){$script:BotCancel=$true;Set-BotStatus '正在取消本次登录…'}}
})
try{
    if($PreviewPath){
        $qrPlaceholder.Text='扫码二维码显示在这里'
        if($PreviewQr){Show-BotQr $PreviewQr}
        $status.Text='请用希望当机器人的微信扫一扫，并在手机上确认。';$progress.Visible=$false
        $form.Show();[Windows.Forms.Application]::DoEvents()
        $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
        $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose();$form.Close()
    }else{
        $form.Add_Shown({
            try{
                Initialize-BotLauncher
                if($Mode -eq 'Start'){
                    $cached=Get-BotReusableSession
                    if($cached -and $cached.ownUsername -and $cached.identityValidatedAt){
                        $script:Phase='choose';$qr.Visible=$false;$scanTitle.Visible=$false;$scanHint.Visible=$false
                        $accountPanel.Visible=$true;$accountPanel.BringToFront();$stepOne.Text='① 选择微信'
                        $accountChoiceHint.Text="上次扫码账号：$($cached.ownUsername)`n点击继续可保留已同步资料；也可以换微信扫码。"
                        $primary.Text='继续上次扫码的微信';$primary.Enabled=$true;$progress.Visible=$false
                        $status.Text='请选择账号，不会自动登录你的个人微信。'
                        $footer.Text='只有点击继续或重新扫码后，才会连接对应微信。'
                    }else{Begin-BotScan}
                }else{
                    $script:Busy=$true;$steps.Visible=$false;$qr.Visible=$false;$scanHint.Visible=$false
                    $subtitle.Text='停止自动回复，保留账号资料与聊天记录。';$scanTitle.Text='正在暂停机器人…';$scanTitle.Location=[Drawing.Point]::new(24,128)
                    Stop-BotLauncher
                    $script:Busy=$false;$scanTitle.Text='机器人已暂停';$status.Text='自动回复已关闭，微信连接服务已停止。下次可选择继续使用保存的登录账号。'
                    $status.ForeColor=$taskGreen;$primary.Text='完成';$primary.Enabled=$true;$cancel.Visible=$false;$progress.Visible=$false
                    $footer.Text='OpenClaw 的其他功能保持可用。'
                }
            }catch{Show-BotFailure $_.Exception.Message;$primary.Enabled=$false}
        })
        [Windows.Forms.Application]::Run($form)
    }
}finally{
    $timer.Stop();$timer.Dispose()
    try{Stop-BotGroupWorker $script:GroupWorker}catch{}
    $script:BotUiTick=$null;$script:BotStatus=$null
    if(-not $PreviewPath -and $Mode -eq 'Start' -and $script:OwnsLoginFlow -and -not $script:Started){
        $script:BotCancel=$true
        try{Stop-BotLauncher}catch{
            $_.Exception.Message|Set-Content -LiteralPath (Join-Path $script:BotRoot 'launcher-cleanup-error.log') -Encoding UTF8
            [void][Windows.Forms.MessageBox]::Show('取消时未能完成暂停，请重新以 -Mode Pause 打开本界面。','微信群机器人','OK','Warning')
        }
    }
    if($qr.Image){$qr.Image.Dispose()};$brand.Image.Dispose();$form.Dispose()
    if($taskOwnsLock){$taskLock.ReleaseMutex()};$taskLock.Dispose()
}
