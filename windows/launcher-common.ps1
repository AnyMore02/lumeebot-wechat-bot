$ErrorActionPreference = 'Stop'
$script:BotBase = $PSScriptRoot
$script:BotRuntime = Join-Path (Split-Path -Parent $script:BotBase) '.runtime'
$script:BotOpenClawState = Join-Path $script:BotRuntime 'openclaw'
$script:BotRoot = Join-Path $script:BotRuntime 'windows-launcher'
$script:BotSessions = Join-Path $script:BotRoot 'sessions'
$script:BotStatePath = Join-Path $script:BotRoot 'current-session.json'
$script:BotConfigPath = Join-Path $script:BotOpenClawState 'openclaw.json'
$script:BotWx = Join-Path $script:BotRuntime 'bin\wx.exe'
$script:BotNode = (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$script:BotOpenClaw = Join-Path (Split-Path -Parent $script:BotBase) 'node_modules\openclaw\openclaw.mjs'
# Separate the desktop daemon from the headless CLI daemon on port 6275.
$script:BotPort = 6276
$script:BotCancel = $false
$script:BotUiTick = $null
$script:BotStatus = $null
$script:BotVerifiedGroups = Join-Path $script:BotRoot 'verified-groups.json'
$script:BotGroupDirectory = Join-Path $script:BotRoot 'group-directory.json'

function Set-BotSessionField($Session,[string]$Name,$Value) {
    $Session | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}
function Test-BotTransientError($ErrorRecord){
    $exception=if($ErrorRecord -is [Exception]){$ErrorRecord}else{$ErrorRecord.Exception}
    while($exception){
        if($exception.Data.Contains('BotTransient')){return [bool]$exception.Data['BotTransient']}
        if($exception -is [TimeoutException] -or $exception -is [OperationCanceledException] -or $exception -is [Net.Sockets.SocketException]){return $true}
        $exception=$exception.InnerException
    }
    return $false
}
function Invoke-BotHttp {
    param($Session,[string]$Path,[string]$Method='GET',$Body,[switch]$Bytes,[int]$TimeoutSeconds=8)
    if($Session.port -ne $script:BotPort){throw '微信服务端口不正确。'}
    $token=(Get-Content -LiteralPath (Join-Path $Session.root 'api-token') -Raw -Encoding UTF8).Trim()
    if(-not $script:BotHttpClient){
        Add-Type -AssemblyName System.Net.Http
        $handler=New-Object Net.Http.HttpClientHandler
        $handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
        $script:BotHttpClient=[Net.Http.HttpClient]::new($handler)
        $script:BotHttpClient.Timeout=[TimeSpan]::FromSeconds(15)
        $script:BotHttpClient.MaxResponseContentBufferSize=8388608
    }
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),('http://127.0.0.1:'+$Session.port+'/'+$Path.TrimStart('/')))
    $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)
    $cancellation=[Threading.CancellationTokenSource]::new($TimeoutSeconds*1000)
    $response=$null
    try{
        if($null -ne $Body){
            $request.Content=[Net.Http.StringContent]::new(($Body|ConvertTo-Json -Depth 15 -Compress),[Text.Encoding]::UTF8,'application/json')
        }
        $pending=$script:BotHttpClient.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token)
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while(-not $pending.IsCompleted){
            Invoke-BotTick
            if($script:BotCancel){$cancellation.Cancel();throw '操作已取消。'}
            if([DateTime]::UtcNow -gt $deadline){$cancellation.Cancel();throw '微信本地接口暂时未响应，请稍后刷新。'}
            Start-Sleep -Milliseconds 20
        }
        $response=$pending.GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        if($Bytes){
            if($response.Content.Headers.ContentType.MediaType -ne 'image/png' -or $response.Content.Headers.ContentLength -gt 4194304){throw '二维码响应格式不正确。'}
            $contentTask=$response.Content.ReadAsByteArrayAsync()
        }else{$contentTask=$response.Content.ReadAsStringAsync()}
        while(-not $contentTask.IsCompleted){
            Invoke-BotTick
            if($script:BotCancel -or [DateTime]::UtcNow -gt $deadline){$cancellation.Cancel();throw '操作已取消或响应超时。'}
            Start-Sleep -Milliseconds 20
        }
        if($Bytes){return ,($contentTask.GetAwaiter().GetResult())}
        $text=$contentTask.GetAwaiter().GetResult()
        return ($text|ConvertFrom-Json)
    }catch{
        if($script:BotCancel){throw '操作已取消。'}
        $errorRecord=$_
        if($response -and [int]$response.StatusCode -in @(401,403,404)){
            $friendly=[InvalidOperationException]::new('微信登录资料暂不可用，请返回账号选择并重新连接。',$_.Exception)
            $friendly.Data['BotTransient']=$false
            throw $friendly
        }
        if((Test-BotTransientError $errorRecord) -or $cancellation.IsCancellationRequested){
            $friendly=[TimeoutException]::new('微信服务响应超时，扫码状态已保留，正在等待重试。',$_.Exception)
            $friendly.Data['BotTransient']=$true
            throw $friendly
        }
        $inner=$_.Exception
        while($inner.InnerException){$inner=$inner.InnerException}
        if($inner -is [Net.Http.HttpRequestException] -or $inner -is [IO.IOException]){
            $friendly=[IO.IOException]::new('微信连接暂时中断，扫码状态已保留，请重试连接。',$_.Exception)
            $friendly.Data['BotTransient']=$true
            throw $friendly
        }
        throw
    }finally{if($response){$response.Dispose()};$request.Dispose();$cancellation.Dispose()}
}
function Get-BotAccount($Session){
    return Invoke-BotHttp -Session $Session -Path ('v1/accounts/'+[Uri]::EscapeDataString($Session.accountId))
}
function Confirm-BotIdentity($Session,$Account){
    if(-not $Account.authenticated -or -not $Account.ownUsername){throw '微信登录尚未建立完成。'}
    if($Session.ownUsername -and $Session.ownUsername -cne $Account.ownUsername){
        Set-BotSessionField $Session 'groups' @()
        Set-BotSessionField $Session 'groupIds' @()
        Set-BotSessionField $Session 'groupId' $null
        Set-BotSessionField $Session 'groupName' $null
    }
    Set-BotSessionField $Session 'ownUsername' $Account.ownUsername
    Set-BotSessionField $Session 'identityValidatedAt' ([DateTime]::UtcNow.ToString('o'))
    $Session.status='select-group';Write-BotSession $Session
}
function Get-BotVerifiedGroups($Session){
    if(-not $Session.ownUsername -or -not(Test-Path -LiteralPath $script:BotVerifiedGroups)){return @()}
    $saved=Get-Content -LiteralPath $script:BotVerifiedGroups -Raw -Encoding UTF8|ConvertFrom-Json
    return @($saved.entries|Where-Object {$_.accountUsername -eq $Session.ownUsername})
}
function Save-BotVerifiedGroup($Session,[string]$Name,$Message){
    if(-not $Session.ownUsername -or $Message.threadId -notmatch '^\d+@chatroom$' -or -not $Message.id){throw '群消息身份不完整，不能确认目标群。'}
    $entries=@()
    if(Test-Path -LiteralPath $script:BotVerifiedGroups){$entries=@((Get-Content -LiteralPath $script:BotVerifiedGroups -Raw -Encoding UTF8|ConvertFrom-Json).entries)}
    $entries=@($entries|Where-Object {-not($_.accountUsername -eq $Session.ownUsername -and $_.id -eq $Message.threadId)})
    $entry=[pscustomobject]@{accountUsername=$Session.ownUsername;id=$Message.threadId;displayName=$Name;source='locator-message';messageId=$Message.id;serverId=$Message.serverId;verifiedAt=[DateTime]::UtcNow.ToString('o')}
    $entries+=$entry
    $temp=$script:BotVerifiedGroups+'.tmp'
    [IO.File]::WriteAllText($temp,(@{schemaVersion=1;entries=$entries}|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $script:BotVerifiedGroups -Force
    return $entry
}
function Get-BotNativePage($Session,[string]$Kind,[string]$Cursor){
    $path='v1/accounts/'+[Uri]::EscapeDataString($Session.accountId)+'/'+$Kind+'?limit=200'
    if($Cursor){$path+='&cursor='+[Uri]::EscapeDataString($Cursor)}
    return Invoke-BotHttp -Session $Session -Path $path
}
function Get-BotRecentGroups($Session){
    return @(Get-BotNativeItems $Session 'threads' | Where-Object {$_.kind -eq 'group' -and $_.peerId -like '*@chatroom' -and -not $_.deleted -and -not $_.tombstone})
}
function Get-BotNativeItems($Session,[string]$Kind){
    $cursor=$null
    $seen=New-Object 'Collections.Generic.HashSet[string]'
    do{
        $page=Get-BotNativePage $Session $Kind $cursor
        foreach($item in @($page.items)){if($null -ne $item){$item}}
        $next=$page.nextCursor
        if(-not $next){$next=$page.next_cursor}
        if(-not $next){break}
        if(-not $seen.Add([string]$next)){throw '群资料分页游标重复，请重新搜索。'}
        $cursor=$next
        Invoke-BotTick
        if($script:BotCancel){throw '操作已取消。'}
    }while($true)
}
function Test-BotGroupName([string]$Name,[string]$Id){
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -ne $Id -and $Name -notlike '*@chatroom')
}
function Get-BotSavedDirectory($Session){
    if(-not $Session.ownUsername -or -not(Test-Path -LiteralPath $script:BotGroupDirectory)){return @()}
    $saved=Get-Content -LiteralPath $script:BotGroupDirectory -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($saved.entries | Where-Object {$_.accountUsername -eq $Session.ownUsername})
}
function Save-BotGroupDirectory($Session,$Groups){
    if(-not $Session.ownUsername){return}
    $entries=@()
    if(Test-Path -LiteralPath $script:BotGroupDirectory){
        $entries=@((Get-Content -LiteralPath $script:BotGroupDirectory -Raw -Encoding UTF8 | ConvertFrom-Json).entries | Where-Object {$_.accountUsername -ne $Session.ownUsername})
    }
    foreach($group in @($Groups)){
        if($group.id -and (Test-BotGroupName $group.displayName $group.id)){
            $entries+=[pscustomobject]@{accountUsername=$Session.ownUsername;id=$group.id;displayName=$group.displayName;source=$group.source;verified=[bool]$group.verified;updatedAt=[DateTime]::UtcNow.ToString('o')}
        }
    }
    $content=@{schemaVersion=1;entries=$entries}|ConvertTo-Json -Depth 8
    if(Test-Path -LiteralPath $script:BotGroupDirectory){
        $old=Get-Content -LiteralPath $script:BotGroupDirectory -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldNames=@($old.entries | Select-Object accountUsername,id,displayName,source,verified | Sort-Object accountUsername,id) | ConvertTo-Json -Depth 6 -Compress
        $newNames=@($entries | Select-Object accountUsername,id,displayName,source,verified | Sort-Object accountUsername,id) | ConvertTo-Json -Depth 6 -Compress
        if($oldNames -eq $newNames){return}
    }
    $temp=$script:BotGroupDirectory+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,$content,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $script:BotGroupDirectory -Force
}
function New-BotGroupScan($Session){
    $queue=New-Object 'Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{path='group-sync';label='同步群目录';groupId=$null;fallback=$false})
    $queue.Enqueue([pscustomobject]@{path='contact-sync';label='同步联系人目录';groupId=$null;fallback=$false})
    return [pscustomobject]@{accountId=$Session.accountId;queue=$queue;attempted=(New-Object 'Collections.Generic.HashSet[string]');active=$null;operationId=$null;startedAt=[DateTime]::UtcNow;finished=$false;failed=0;succeeded=0;note='正在同步群目录…';results=(New-Object 'Collections.Generic.List[object]')}
}
function Update-BotGroupScan($Session,$Scan,$Groups){
    if($Scan.accountId -ne $Session.accountId){throw '群同步账号不匹配。'}
    if($Scan.finished){return}
    $base='v1/accounts/'+[Uri]::EscapeDataString($Session.accountId)+'/'
    if($Scan.operationId){
        $operation=Invoke-BotHttp $Session ($base+'operations/'+[Uri]::EscapeDataString($Scan.operationId))
        if($operation.state -notin @('succeeded','failed','cancelled','expired','needs_review')){
            $Scan.note=$Scan.active.label+'…（'+[int]([DateTime]::UtcNow-$Scan.startedAt).TotalSeconds+' 秒）'
            return
        }
        $Scan.results.Add([pscustomobject]@{path=$Scan.active.path;state=$operation.state;result=$operation.result})
        if($operation.state -eq 'succeeded'){$Scan.succeeded++}else{$Scan.failed++}
        # Contact lookup can hydrate a name when the group-detail projection fails.
        if($Scan.active.groupId -and -not $Scan.active.fallback){
            $Scan.queue.Enqueue([pscustomobject]@{path=('contacts/'+[Uri]::EscapeDataString($Scan.active.groupId)+'/refresh');label='补充群名称';groupId=$Scan.active.groupId;fallback=$true})
        }
        $Scan.active=$null;$Scan.operationId=$null
        # Re-read after each completed operation before scheduling more lookups.
        $Scan.note='正在更新搜索结果…'
        return
    }
    if(([DateTime]::UtcNow-$Scan.startedAt).TotalSeconds -gt 180){
        $Scan.finished=$true;$Scan.note='本轮同步已结束，部分群资料尚未返回；可再点同步。';return
    }
    foreach($group in @($Groups)){
        if(-not(Test-BotGroupName $group.displayName $group.id) -and $Scan.attempted.Count -lt 60 -and $Scan.attempted.Add([string]$group.id)){
            $Scan.queue.Enqueue([pscustomobject]@{path=('groups/'+[Uri]::EscapeDataString($group.id)+'/refresh');label='补充群名称';groupId=$group.id;fallback=$false})
        }
    }
    while($Scan.queue.Count -gt 0){
        $action=$Scan.queue.Dequeue()
        if($action.groupId){
            $current=@($Groups | Where-Object id -eq $action.groupId | Select-Object -First 1)
            if($current.Count -and (Test-BotGroupName $current[0].displayName $action.groupId)){continue}
        }
        try{
            $operation=Invoke-BotHttp $Session ($base+$action.path) -Method POST -Body @{}
            if(-not $operation.id){throw '未返回群同步操作编号。'}
            $Scan.active=$action;$Scan.operationId=$operation.id;$Scan.note=$action.label+'…'
        }catch{
            if($script:BotCancel){throw}
            $Scan.failed++;$Scan.note='部分资料暂时未返回，正在保留已有搜索结果。'
        }
        return
    }
    $Scan.finished=$true
    $Scan.note=if($Scan.failed){'本轮同步已结束，部分资料未能读取。'}else{'本轮同步已完成，底层接口仍可能遗漏部分群。'}
}
function Stop-BotGroupScan($Session,$Scan){
    if(-not $Scan -or $Scan.finished){return}
    if($Scan.accountId -ne $Session.accountId){throw '群同步账号不匹配。'}
    if($Scan.operationId){
        $path='v1/accounts/'+[Uri]::EscapeDataString($Session.accountId)+'/operations/'+[Uri]::EscapeDataString($Scan.operationId)
        $null=Invoke-BotHttp $Session $path -Method DELETE
    }
    $Scan.finished=$true;$Scan.note='已停止资料同步，准备在选中群启动。'
}
function Find-BotGroupByLocator($Session,$Discovery){
    $matches=New-Object Collections.Generic.List[object]
    foreach($thread in @(Get-BotRecentGroups $Session|Select-Object -First 20)){
        $path='v1/accounts/'+[Uri]::EscapeDataString($Session.accountId)+'/threads/'+[Uri]::EscapeDataString($thread.peerId)+'/messages?limit=5'
        $page=Invoke-BotHttp -Session $Session -Path $path
        foreach($message in @($page.items)){
            if($message.body -eq $Discovery.code -and $message.direction -eq 'incoming' -and [DateTimeOffset]::Parse($message.createdAt).UtcDateTime -ge $Discovery.startedAt.AddSeconds(-5)){$matches.Add($message)}
        }
    }
    $ids=@($matches|Select-Object -ExpandProperty threadId -Unique)
    if($ids.Count -gt 1){throw '多个群收到了相同定位码，请重新生成定位码，仅在目标群发送。'}
    if($ids.Count -eq 1){return Save-BotVerifiedGroup $Session $Discovery.name $matches[0]}
    return $null
}
function Continue-BotLogin($Session){
    Disable-BotChannel
    $previous=Get-BotSession
    if($previous -and $previous.root -ne $Session.root){Stop-BotNative $previous}
    Write-BotSession $Session
    $state=Invoke-BotWx -Root $Session.root -Arguments @('daemon','status')
    if($state.state -ne 'ready'){$null=Invoke-BotWx -Root $Session.root -Arguments @('daemon','start')}
    $account=Get-BotAccount $Session
    if($account.authenticated -and $account.connection -eq 'online'){
        Confirm-BotIdentity $Session $account
        return $true
    }
    Set-BotStatus '正在连接上次扫码的微信；需要手机确认时会显示提示…'
    try {
        $login=Invoke-BotWx -Root $Session.root -Arguments @('--account',$Session.accountId,'auth','login','--strategy','auto','--detach','--timeout','300')
    }catch{
        # A restored daemon can finish auto-connect before the CLI receipt arrives.
        # Reconcile only the same account; never repeat an uncertain login request.
        $loginError=$_
        try{
            $recovered=Get-BotAccount $Session
            if($recovered.authenticated -and $recovered.connection -eq 'online' -and $recovered.ownUsername -and (-not $Session.ownUsername -or $recovered.ownUsername -eq $Session.ownUsername)){
                Confirm-BotIdentity $Session $recovered
                return $true
            }
        }catch{}
        throw $loginError
    }
    $Session.operationId=$login.id;$Session.status='awaiting-scan';Write-BotSession $Session
    return $false
}

function Set-BotStatus([string]$Text) {
    if ($script:BotStatus) { & $script:BotStatus $Text }
}
function Invoke-BotTick {
    if ($script:BotUiTick) { & $script:BotUiTick }
}
function New-BotPrivateDirectory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '私密目录不能是符号链接。' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($principal in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $item.SetAccessControl($acl) }
    else { [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl) }
}
function Initialize-BotLauncher {
    $modePath=Join-Path $script:BotRuntime 'mode'
    if (-not (Test-Path -LiteralPath $modePath -PathType Leaf) -or (Get-Content -LiteralPath $modePath -Raw -Encoding UTF8).Trim() -cne 'desktop') {
        throw '请先在仓库目录运行 node bin/bot.mjs setup --desktop。'
    }
    if (-not $script:BotNode) { throw '找不到 Node.js，请先按仓库 README 安装。' }
    foreach ($file in @($script:BotWx,$script:BotNode,$script:BotOpenClaw,$script:BotConfigPath)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw ('请先完成 README 的安装和初始化。缺少文件：'+$file) }
    }
    New-BotPrivateDirectory $script:BotRoot
    New-BotPrivateDirectory $script:BotSessions
    $null=Invoke-BotGateway -Mode status
}
function ConvertTo-BotArgument([string]$Value) {
    if ($Value.Contains([char]0)) { throw '启动参数包含无效字符。' }
    $quoted = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $quoted = [regex]::Replace($quoted,'(\\+)$','$1$1')
    return '"'+$quoted+'"'
}
function Invoke-BotProcess {
    param([string]$File,[string[]]$Arguments,[int]$TimeoutSeconds=60,[switch]$AllowFailure,[switch]$IgnoreCancel,[string]$ProgressPath)
    $captureId=[guid]::NewGuid().ToString('N')
    $outPath=Join-Path $script:BotRoot ($captureId+'.stdout.tmp')
    $errPath=Join-Path $script:BotRoot ($captureId+'.stderr.tmp')
    $argLine=(($Arguments | ForEach-Object { ConvertTo-BotArgument ([string]$_) }) -join ' ')
    $previousState=$env:OPENCLAW_STATE_DIR
    $previousConfig=$env:OPENCLAW_CONFIG_PATH
    $previousPath=$env:Path
    $process=$null
    try {
        $env:OPENCLAW_STATE_DIR=$script:BotOpenClawState
        $env:OPENCLAW_CONFIG_PATH=$script:BotConfigPath
        $env:Path=(Split-Path $script:BotNode)+';'+$previousPath
        # File capture avoids waiting for inherited pipe handles held by the background daemon.
        $process=Start-Process -FilePath $File -ArgumentList $argLine -WorkingDirectory $script:BotBase -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        [void]$process.Handle
    } finally {
        $env:OPENCLAW_STATE_DIR=$previousState;$env:OPENCLAW_CONFIG_PATH=$previousConfig;$env:Path=$previousPath
    }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $lastProgress=[DateTime]::MinValue
        while (-not $process.HasExited) {
            Invoke-BotTick
            if($ProgressPath -and ([DateTime]::UtcNow-$lastProgress).TotalMilliseconds -gt 500){
                try{
                    $progress=Get-Content -LiteralPath $ProgressPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                    if($progress.message){Set-BotStatus ($progress.message+'（'+[int]($progress.elapsedMs/1000)+' 秒）')}
                }catch{}
                $lastProgress=[DateTime]::UtcNow
            }
            if ((-not $IgnoreCancel -and $script:BotCancel) -or [DateTime]::UtcNow -gt $deadline) {
                $process.Kill()
                if ($script:BotCancel) { throw '操作已取消。' }
                throw '本地服务响应超时，请稍后重试。'
            }
            Start-Sleep -Milliseconds 80
            $process.Refresh()
        }
        $process.WaitForExit()
        Start-Sleep -Milliseconds 80
        $output=Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
        $errorText=Get-Content -LiteralPath $errPath -Raw -Encoding UTF8
        if($null -eq $output){$output=''};if($null -eq $errorText){$errorText=''}
        $result = [pscustomobject]@{ ExitCode=$process.ExitCode; Out=$output; Err=$errorText }
        if (-not $AllowFailure -and $result.ExitCode -ne 0) {
            $detail = ($errorText+' '+$output).Trim()
            if ($detail.Length -gt 1000) { $detail=$detail.Substring(0,1000) }
            throw ('操作失败：'+$detail)
        }
        return $result
    } finally {
        if($process){$process.Dispose()}
        foreach($capture in @($outPath,$errPath)){Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue}
    }
}
function Invoke-BotWx {
    param([string]$Root,[string[]]$Arguments,[int]$Port=$script:BotPort,[switch]$AllowFailure,[switch]$IgnoreCancel)
    $argsList = @('--json','--data-dir',$Root,'--listen',('127.0.0.1:'+$Port))+$Arguments
    $result = Invoke-BotProcess -File $script:BotWx -Arguments $argsList -TimeoutSeconds 75 -AllowFailure -IgnoreCancel:$IgnoreCancel
    $parsed=$null
    if($result.Out.Trim()){try{$parsed=$result.Out|ConvertFrom-Json}catch{}}
    # The native CLI also uses a nonzero exit for correctly reported terminal operations.
    if($result.ExitCode -ne 0 -and -not ($parsed.id -and $parsed.kind -and $parsed.state)) {
        if($AllowFailure){return $null}
        $detail=($result.Err+' '+$result.Out).Trim()
        if($detail.Length -gt 1000){$detail=$detail.Substring(0,1000)}
        throw ('微信服务操作失败：'+$detail)
    }
    return $parsed
}
function Get-BotConfig { return (Get-Content -LiteralPath $script:BotConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
function Invoke-BotGateway {
    param([ValidateSet('start','pause','status')][string]$Mode,[string]$PatchFile,[string]$SessionFile,[string]$ProgressPath,[int]$TimeoutSeconds=25)
    $arguments=@('--stack-size=8192',(Join-Path $script:BotBase 'gateway-wechat.mjs'),$Mode)
    if($Mode -eq 'start'){$arguments+=@($PatchFile,$SessionFile)}
    $result=Invoke-BotProcess -File $script:BotNode -Arguments $arguments -TimeoutSeconds $TimeoutSeconds -AllowFailure -IgnoreCancel -ProgressPath $ProgressPath
    try{$parsed=$result.Out|ConvertFrom-Json}catch{throw '网关未返回有效连接结果，扫码账号已保留，请重试。'}
    if($result.ExitCode -ne 0 -or -not $parsed.ok){
        if($parsed.message){throw ([string]$parsed.message)}
        throw '网关连接暂未完成，扫码账号已保留，请重试。'
    }
    return $parsed
}
function Write-BotSession($Session) {
    $temp = $script:BotStatePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Session | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $script:BotStatePath -Force
    if(Test-Path -LiteralPath $Session.root -PathType Container){
        [IO.File]::WriteAllText((Join-Path $Session.root 'session.json'),($Session|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    }
}
function Get-BotSession {
    if (-not (Test-Path -LiteralPath $script:BotStatePath)) { return $null }
    $state = Get-Content -LiteralPath $script:BotStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $expected = [IO.Path]::GetFullPath($script:BotSessions).TrimEnd('\')+'\'
    $actual = [IO.Path]::GetFullPath([string]$state.root)
    if (-not $actual.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $actual -Parent) -ne $expected.TrimEnd('\')) { throw '扫码登录资料路径不正确，已停止操作。' }
    if ($state.port -ne $script:BotPort) { throw '扫码服务端口不匹配。' }
    return $state
}
function Get-BotReusableSession {
    $current=Get-BotSession
    if($current -and $current.ownUsername -and $current.identityValidatedAt){return $current}
    foreach($directory in @(Get-ChildItem -LiteralPath $script:BotSessions -Directory|Sort-Object LastWriteTime -Descending)){
        $path=Join-Path $directory.FullName 'session.json'
        if(-not(Test-Path -LiteralPath $path)){continue}
        $candidate=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($candidate.root -eq $directory.FullName -and $candidate.port -eq $script:BotPort -and $candidate.ownUsername -and $candidate.identityValidatedAt){return $candidate}
    }
    return $null
}
function Disable-BotChannel {
    Set-BotStatus '正在检查并暂停自动回复…'
    $null=Invoke-BotGateway -Mode pause
}
function Stop-BotNative($Session) {
    if ($null -eq $Session) { return }
    if ($Session.operationId -and $Session.status -eq 'awaiting-scan') {
        $null=Invoke-BotWx -Root $Session.root -Arguments @('--account',$Session.accountId,'auth','cancel',$Session.operationId) -AllowFailure -IgnoreCancel
    }
    $null=Invoke-BotWx -Root $Session.root -Arguments @('daemon','stop') -AllowFailure -IgnoreCancel
    $state=Invoke-BotWx -Root $Session.root -Arguments @('daemon','status') -IgnoreCancel
    if($state.state -ne 'stopped'){throw '微信连接服务还没有停止，请再次点击暂停。'}
    $Session.status='paused'
    Write-BotSession $Session
}
function Stop-BotLauncher {
    Disable-BotChannel
    $state=Get-BotSession
    Stop-BotNative $state
}
function New-BotLogin {
    Stop-BotLauncher
    if ($script:BotCancel) { throw '操作已取消。' }
    $sessionId='scan-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,10)
    $session=[pscustomobject]@{
        schemaVersion=1; id=$sessionId; root=(Join-Path $script:BotSessions $sessionId); port=$script:BotPort
        accountId=$null; operationId=$null; status='preparing'; groupId=$null; groupName=$null; groupIds=@(); groups=@()
        createdAt=[DateTime]::UtcNow.ToString('o')
    }
    New-BotPrivateDirectory $session.root
    Write-BotSession $session
    Set-BotStatus '正在生成本次登录二维码…'
    $null=Invoke-BotWx -Root $session.root -Arguments @('daemon','start')
    $created=Invoke-BotWx -Root $session.root -Arguments @('accounts','create','--alias',$sessionId)
    $accounts=Invoke-BotWx -Root $session.root -Arguments @('accounts','list')
    if (@($accounts.items).Count -ne 1) { throw '本次扫码环境不为空，已停止登录。' }
    $session.accountId=$accounts.items[0].id
    if (-not $session.accountId -or $accounts.items[0].authenticated) { throw '本次扫码环境不是全新账号，已停止登录。' }
    $login=Invoke-BotWx -Root $session.root -Arguments @('--account',$session.accountId,'auth','login','--strategy','qr','--force-qr','--detach','--timeout','300')
    if (-not $login.id) { throw '未能创建扫码操作。' }
    $session.operationId=$login.id
    $session.status='awaiting-scan'
    Write-BotSession $session
    return $session
}
function Get-BotLoginOperation($Session) {
    return Invoke-BotHttp -Session $Session -Path ('v1/accounts/'+[Uri]::EscapeDataString($Session.accountId)+'/operations/'+[Uri]::EscapeDataString($Session.operationId))
}
function Save-BotQr($Session,$Operation) {
    $path=Join-Path $Session.root ('qr-'+$Operation.result.qrGeneration+'.png')
    $route='v1/accounts/'+[Uri]::EscapeDataString($Session.accountId)+'/operations/'+[Uri]::EscapeDataString($Session.operationId)+'/qr?generation='+$Operation.result.qrGeneration
    $bytes=Invoke-BotHttp -Session $Session -Path $route -Bytes
    [IO.File]::WriteAllBytes($path,$bytes)
    return $path
}
function Get-BotGroups {
    param($Session,[switch]$CachedOnly)
    $all=@{}
    $removed=New-Object 'Collections.Generic.HashSet[string]'
    $warnings=New-Object 'Collections.Generic.List[string]'
    foreach($saved in @(Get-BotSavedDirectory $Session)){
        $all[$saved.id]=[pscustomobject]@{id=$saved.id;displayName=$saved.displayName;verified=[bool]$saved.verified;source='saved-directory'}
    }
    foreach($verified in @(Get-BotVerifiedGroups $Session)){
        if(-not $all.ContainsKey([string]$verified.id)){
            $all[$verified.id]=[pscustomobject]@{id=$verified.id;displayName=$verified.displayName;verified=$true;source='locator-message'}
        }
    }
    if($CachedOnly){return @($all.Values)}
    $nativeGroups=@()
    try{$nativeGroups=@(Get-BotNativeItems $Session 'groups')}catch{if($script:BotCancel){throw};$warnings.Add('群目录暂未返回')}
    foreach($item in $nativeGroups) {
        if(-not $item.id -or $item.id -notlike '*@chatroom'){continue}
        if($item.deleted -or $item.tombstone){
            [void]$removed.Add([string]$item.id);$all.Remove([string]$item.id);continue
        }
        if((Test-BotGroupName $item.displayName $item.id) -or -not $all.ContainsKey([string]$item.id)){
            $all[$item.id]=[pscustomobject]@{id=$item.id;displayName=$item.displayName;verified=$false;source='cached-group'}
        }
    }
    $recentGroups=@()
    try{$recentGroups=@(Get-BotRecentGroups $Session)}catch{if($script:BotCancel){throw};$warnings.Add('最近会话暂未返回')}
    foreach($thread in $recentGroups){
        if($removed.Contains([string]$thread.peerId)){continue}
        if(-not $all.ContainsKey([string]$thread.peerId) -or ((Test-BotGroupName $thread.displayName $thread.peerId) -and -not(Test-BotGroupName $all[$thread.peerId].displayName $thread.peerId))){
            $all[$thread.peerId]=[pscustomobject]@{id=$thread.peerId;displayName=$thread.displayName;verified=$false;source='recent-thread'}
        }
    }
    foreach($verified in @(Get-BotVerifiedGroups $Session)){
        if($removed.Contains([string]$verified.id)){continue}
        if(-not $all.ContainsKey([string]$verified.id) -or -not(Test-BotGroupName $all[$verified.id].displayName $verified.id)){
            $all[$verified.id]=[pscustomobject]@{id=$verified.id;displayName=$verified.displayName;verified=$true;source='locator-message'}
        }
    }
    try{Save-BotGroupDirectory $Session @($all.Values)}catch{$warnings.Add('群目录保存未完成')}
    $script:BotGroupReadState=[pscustomobject]@{partial=($warnings.Count -gt 0);warnings=@($warnings.ToArray())}
    return @($all.Values)
}
function Start-BotGroupWorker($Session){
    $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
    $cancel=[Threading.CancellationTokenSource]::new()
    $powershell=[PowerShell]::Create()
    [void]$powershell.AddCommand((Join-Path $script:BotBase 'group-discovery-worker.ps1')).AddParameter('CommonPath',(Join-Path $script:BotBase 'launcher-common.ps1')).AddParameter('SessionJson',($Session|ConvertTo-Json -Depth 20 -Compress)).AddParameter('Queue',$queue).AddParameter('CancelToken',$cancel.Token)
    $handle=$powershell.BeginInvoke()
    return [pscustomobject]@{powershell=$powershell;handle=$handle;queue=$queue;cancel=$cancel;accountId=$Session.accountId;sessionId=$Session.id;disposed=$false;error=$null}
}
function Read-BotGroupWorker($Worker){
    if(-not $Worker -or $Worker.disposed){return $null}
    $latest=$null;$item=$null
    while($Worker.queue.TryDequeue([ref]$item)){$latest=$item;$item=$null}
    if($Worker.handle.IsCompleted -and -not $Worker.disposed){
        try{$null=$Worker.powershell.EndInvoke($Worker.handle)}catch{$Worker.error=$_.Exception.Message}
        if($Worker.powershell.Streams.Error.Count -gt 0){$Worker.error='后台同步未完成'}
        if($Worker.error -and -not $latest){$latest=[pscustomobject]@{accountId=$Worker.accountId;sessionId=$Worker.sessionId;groups=$null;finished=$true;note='后台同步未完成，已保留保存的群，可点同步重试。'}}
        $Worker.powershell.Dispose();$Worker.cancel.Dispose();$Worker.disposed=$true
    }
    return $latest
}
function Stop-BotGroupWorker($Worker){
    if(-not $Worker -or $Worker.disposed){return}
    $Worker.cancel.Cancel()
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not $Worker.handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline){Invoke-BotTick;Start-Sleep -Milliseconds 30}
    if(-not $Worker.handle.IsCompleted){throw '群资料同步尚未结束，请稍后重试；当前扫码账号会保留。'}
    $null=Read-BotGroupWorker $Worker
}
function Search-BotGroups($Groups,[string]$Query){
    $queryText=$Query.Trim()
    return @($Groups | Where-Object {
        -not $queryText -or ([string]$_.displayName).IndexOf($queryText,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.id).IndexOf($queryText,[StringComparison]::OrdinalIgnoreCase) -ge 0
    } | Sort-Object @{Expression={if([string]$_.displayName -eq $queryText){0}elseif(Test-BotGroupName $_.displayName $_.id){1}else{2}}},displayName,id)
}
function Get-BotSelection($Groups) {
    $selected=New-Object 'Collections.Generic.List[object]'
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($group in @($Groups)){
        $id=[string]$group.id
        if([string]::IsNullOrWhiteSpace($id) -or $id -cnotmatch '^[^\s@*]+@chatroom$'){throw '请选择有效微信群。'}
        if($seen.Add($id)){
            $name=if([string]::IsNullOrWhiteSpace([string]$group.displayName)){$id}else{[string]$group.displayName}
            $selected.Add([pscustomobject]@{id=$id;displayName=$name})
        }
    }
    if($selected.Count -eq 0){throw '请至少选择一个微信群。'}
    return $selected.ToArray()
}
function New-BotActivationPatch($Session,$Groups,$Config) {
    if (-not $Session.accountId -or $Session.status -notin @('select-group','running')) { throw '请先完成扫码登录。' }
    $selected=@(Get-BotSelection $Groups)
    $groups=@{'*'=@{enabled=$false}}
    $bindings=@($Config.bindings | Where-Object {$_.match.channel -ne 'agent-wechat'})
    foreach($group in $selected){
        $groups[$group.id]=@{enabled=$true;requireMention=$false}
        $bindings+=@{agentId='wechat-trial';match=@{channel='agent-wechat';peer=@{kind='group';id=$group.id}}}
    }
    return @{
        secrets=@{providers=@{'wechat-launcher'=@{source='file';path=(Join-Path $Session.root 'api-token');mode='singleValue'}}}
        agents=@{entries=@{'wechat-trial'=@{name='微信群机器人';skills=@();tools=@{deny=@('*')}}}}
        bindings=$bindings
        channels=@{'agent-wechat'=@{
            enabled=$true;dmPolicy='disabled';groupPolicy='open';groups=$groups
            native=@{mode='external';accountId=$Session.accountId;endpoint=('http://127.0.0.1:'+$Session.port)
                token=@{source='file';provider='wechat-launcher';id='value'}
                consumerStateDir=(Join-Path $script:BotOpenClawState ('agent-wechat-launcher\'+$Session.id)).Replace('\','/');readPolicy='on_inbound'}
        }}
    }
}
function Start-BotForGroups($Session,$Groups) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $selected=@(Get-BotSelection $Groups)
    Set-BotStatus ('正在连接选中的 '+$selected.Count+' 个微信群…')
    $config=Get-BotConfig
    $patch=New-BotActivationPatch $Session $selected $config
    $patchPath=Join-Path $Session.root 'activation.patch.json'
    [IO.File]::WriteAllText($patchPath,($patch|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
    Set-BotSessionField $Session 'groups' $selected
    Set-BotSessionField $Session 'groupIds' @($selected | ForEach-Object {$_.id})
    # Keep the first group for old diagnostic scripts; activation uses the full collection.
    Set-BotSessionField $Session 'groupId' $selected[0].id
    Set-BotSessionField $Session 'groupName' $selected[0].displayName
    $Session.status='activating'
    Write-BotSession $Session
    $progressPath=Join-Path $Session.root 'activation-progress.json'
    Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
    $proof=Invoke-BotGateway -Mode start -PatchFile $patchPath -SessionFile (Join-Path $Session.root 'session.json') -ProgressPath $progressPath -TimeoutSeconds 150
    $proof|Add-Member -MemberType NoteProperty -Name totalMs -Value $clock.ElapsedMilliseconds -Force
    [IO.File]::WriteAllText((Join-Path $Session.root 'activation-result.json'),($proof|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $Session.status='running'
    Write-BotSession $Session
}
function Start-BotForGroup($Session,$Group) {
    Start-BotForGroups $Session @($Group)
}
