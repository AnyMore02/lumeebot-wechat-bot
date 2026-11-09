param([string]$CommonPath,[string]$SessionJson,$Queue,[Threading.CancellationToken]$CancelToken)
$ErrorActionPreference='Stop'
. $CommonPath
$session=$SessionJson|ConvertFrom-Json
$script:BotUiTick={if($CancelToken.IsCancellationRequested){$script:BotCancel=$true}}
$scan=$null
$groups=@()
function Publish-GroupView([string]$Note,[bool]$Finished){
    $Queue.Enqueue([pscustomobject]@{accountId=$session.accountId;sessionId=$session.id;groups=@($groups);note=$Note;finished=$Finished})
}
try{
    $groups=@(Get-BotGroups $session -CachedOnly)
    Publish-GroupView '已显示保存的群，正在后台补充最新资料…' $false
    $scan=New-BotGroupScan $session
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    do{
        if($CancelToken.IsCancellationRequested){break}
        $groups=@(Get-BotGroups $session)
        $note=if($script:BotGroupReadState.partial){'最新群资料暂未返回，已保留保存的群，可直接搜索选择。'}else{$scan.note}
        Publish-GroupView $note $false
        if($CancelToken.IsCancellationRequested){break}
        Update-BotGroupScan $session $scan $groups
        Publish-GroupView $scan.note $scan.finished
        if($scan.finished){break}
        for($i=0;$i -lt 10 -and -not $CancelToken.IsCancellationRequested;$i++){Start-Sleep -Milliseconds 100}
    }while([DateTime]::UtcNow -lt $deadline)
    Publish-GroupView '本轮同步已结束；已保存的群仍可搜索，未同步到的群可能遗漏。' $true
}catch{
    if(-not $CancelToken.IsCancellationRequested){Publish-GroupView '部分群资料读取失败，已保留已有结果，可重新同步。' $true}
}finally{
    $script:BotUiTick=$null;$script:BotCancel=$false
    if($scan -and -not $scan.finished){try{Stop-BotGroupScan $session $scan}catch{}}
    if($script:BotHttpClient){$script:BotHttpClient.Dispose();$script:BotHttpClient=$null}
}
