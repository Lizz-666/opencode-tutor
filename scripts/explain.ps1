param(
    [string]$ClipboardText = '',
    [string]$ServerUrl = '',
    [int]$ServerPort = 0,
    [string]$StateFile = '',
    [string]$WorkDir = '',
    [string]$LineDir = '',
    [switch]$NoReply,
    [string]$KeybindingsPath = '',
    [string]$ConfigPath = '',
    [string[]]$OpencodeConfigPaths = @(),
    [string]$OpenRequestDir = '',
    [string]$MainSessionId = '',
    [ValidateSet('brief','detailed','example')][string]$Style = 'brief',
    [ValidateSet('relevant','recent','none')][string]$ContextMode = 'relevant',
    [switch]$NewLine
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'explain.lib.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$cfg = Get-LearnConfig -ConfigPath $ConfigPath
if ($ServerPort -le 0) { $ServerPort = $cfg.port }
if (-not $ServerUrl) { $ServerUrl = 'http://127.0.0.1:' + $ServerPort }
if (-not $StateFile) { $StateFile = Join-Path $PSScriptRoot 'state.json' }
if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
if (-not $LineDir) { $LineDir = Join-Path $PSScriptRoot 'lines' }
if (-not $OpenRequestDir) { $OpenRequestDir = $PSScriptRoot }
if (-not $KeybindingsPath -and $env:APPDATA) { $KeybindingsPath = Join-Path $env:APPDATA 'Code\User\keybindings.json' }
$invocation = ''
if ($env:OPENCODE_TUTOR_INVOCATION) { $invocation = ([string]$env:OPENCODE_TUTOR_INVOCATION -replace '[^A-Za-z0-9-]', '') }

$selectedText = $ClipboardText
if ($env:OPENCODE_TUTOR_STDIN -eq '1') { $selectedText = [Console]::In.ReadToEnd() }
if ([string]::IsNullOrWhiteSpace($selectedText) -and -not $PSBoundParameters.ContainsKey('ClipboardText') -and $env:OPENCODE_TUTOR_STDIN -ne '1') {
    try { $selectedText = Get-Clipboard -Raw -ErrorAction Stop } catch { $selectedText = '' }
}
if ([string]::IsNullOrWhiteSpace($selectedText)) {
    $msg = '剪贴板为空：请先在 opencode 聊天界面拖选不懂的文字，再按 Alt+L。'
    Write-LearnOpenRequest -Directory $OpenRequestDir -Invocation $invocation -ErrorMessage $msg
    [Console]::Beep(900, 220)
    Start-Sleep -Milliseconds 150
    [Console]::Beep(600, 220)
    Write-Output $msg
    exit 1
}

try {
    $details = @{}
    Assert-LearnNotCancelled $OpenRequestDir $invocation
    if ($selectedText.Length -gt $cfg.selectionMaxChars) { throw ('选区过长，请缩小到 '+$cfg.selectionMaxChars+' 字符以内；原文不会被静默截断。') }
    Write-LearnProgress $OpenRequestDir $invocation 'connecting'
if (-not (Test-LearnServerReady -BaseUrl $ServerUrl)) {
    if ($ServerUrl -eq ('http://127.0.0.1:' + $ServerPort)) {
        Write-LearnProgress $OpenRequestDir $invocation 'starting'
        $started = Start-LearnServer -Port $ServerPort -WorkDir $WorkDir
        if (-not $started) {
            $msg = '讲解后台服务启动失败，请查看日志：' + (Join-Path $env:TEMP ('opencode\learn-serve-'+$ServerPort+'.log'))
            Write-LearnOpenRequest -Directory $OpenRequestDir -Invocation $invocation -ErrorMessage $msg
            Write-Output $msg
            exit 1
        }
    } else {
        $msg = '无法连接讲解服务：' + $ServerUrl
        Write-LearnOpenRequest -Directory $OpenRequestDir -Invocation $invocation -ErrorMessage $msg
        Write-Output $msg
        exit 1
    }
}

    $globalCfg = @(
        (Join-Path $env:USERPROFILE '.config\opencode\opencode.json'),
        (Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'),
        (Join-Path $env:USERPROFILE '.config\opencode\config.json')
    )
    if ($OpencodeConfigPaths -and $OpencodeConfigPaths.Count -gt 0) { $globalCfg = $OpencodeConfigPaths }
    if (Test-LearnConfigStale -BaseUrl $ServerUrl -ConfigPaths $globalCfg) {
        Write-Output '配置有更新；当前服务继续运行，重启后台服务后生效。'
        $details['notice'] = '全局配置有更新，服务空闲后重启才能生效。'
    }
    Assert-LearnNotCancelled $OpenRequestDir $invocation
    Write-LearnProgress $OpenRequestDir $invocation 'selecting'
    $sessions = @(Get-LearnSessions -BaseUrl $ServerUrl -Directory $WorkDir)
    $candidates = @(Get-LearnMainCandidates -Sessions $sessions -Directory $WorkDir)
    $main = Select-MainSession -Sessions $sessions -Directory $WorkDir -MainSessionId $MainSessionId
    if (-not $main) {
        if ($candidates.Count -gt 0 -and $invocation) {
            $choices = @($candidates | ForEach-Object { @{ id = $_.id; title = $_.title; directory = $_.directory; updated = $_.time.updated } })
            Write-LearnOpenRequest -Directory $OpenRequestDir -Invocation $invocation -Sessions $choices
            exit 0
        }
        throw ('请明确选择主会话（-MainSessionId）；当前目录可用根会话数：' + $candidates.Count)
    }
    Write-LearnProgress $OpenRequestDir $invocation 'context'
    $checkpoint = { Assert-LearnNotCancelled $OpenRequestDir $invocation }
    $mainMessages = @(Get-LearnContextMessages -BaseUrl $ServerUrl -SessionId $main.id -Directory $WorkDir -SelectedText $selectedText -Mode $ContextMode -PageSize $cfg.contextPageSize -MaxMessages $cfg.contextMaxMessages -Checkpoint $checkpoint)
    $context = New-LearnContext -Messages $mainMessages -SelectedText $selectedText -Mode $ContextMode -MaxChars $cfg.backgroundMaxChars
    Assert-LearnNotCancelled $OpenRequestDir $invocation
    Write-LearnProgress $OpenRequestDir $invocation 'session'
    $previousId = ''
    $lineGuard = Enter-LearnLock -Key ([IO.Path]::GetFullPath($StateFile))
    try {
        $learnId = Get-OrCreateLearnLine -BaseUrl $ServerUrl -StateFile $StateFile -LineDir $LineDir -Main $main -MaxMessages $cfg.learningMaxMessages -MaxChars $cfg.learningMaxChars -NewLine:$NewLine -PreviousId ([ref]$previousId) -Checkpoint $checkpoint -DeferStateWrite

        $learnUrl = '{0}/server/{1}/session/{2}' -f $ServerUrl, (Get-ServerKey -ServerUrl $ServerUrl), $learnId
        $details['learnSession'] = @{ id=$learnId; directory=$LineDir }
        $details['context'] = @{ chars=$context.chars; messages=$context.messages; omitted=$context.omitted; oversized=$context.oversized; match=$context.match; mode=$context.mode; scanned=$mainMessages.Count; budget=$context.budget }
        $details['style'] = $Style
        if ($previousId) { $details['previousUrl'] = '{0}/server/{1}/session/{2}' -f $ServerUrl,(Get-ServerKey $ServerUrl),$previousId }
        $modelOverride = ''
        if ($cfg.ContainsKey('model')) { $modelOverride = [string]$cfg['model'] }
        $body = New-LearnPromptBody -SelectedText $selectedText -Background $context.text -Style $Style -Model $modelOverride -NoReply:$NoReply
        Assert-LearnNotCancelled $OpenRequestDir $invocation
        Write-LearnProgress $OpenRequestDir $invocation 'sending' @{ url=$learnUrl; learnSession=$details.learnSession; mainSession=@{ id=$main.id; title=$main.title; directory=$WorkDir } }
        # Commit only after preparation is accepted. No cancellation checks after this send boundary.
        Write-LearnState -Path $StateFile -Lines @{ ([string]$main.id) = [string]$learnId }
        $sending = $true
    } finally { Exit-LearnLock $lineGuard }
    $null = Send-LearnPrompt -BaseUrl $ServerUrl -SessionId $learnId -Body $body
    if ($KeybindingsPath) {
        $null = Update-LearnKeybindings -KeybindingsPath $KeybindingsPath -Url $learnUrl
    }

    Write-LearnOpenRequest -Directory $OpenRequestDir -Invocation $invocation -Url $learnUrl -MainSession @{ id = $main.id; title = $main.title; directory = $WorkDir } -Details $details
    Write-Output ('讲解已发送，网页窗口地址：' + $learnUrl)
    exit 0
} catch {
    $msg = '讲解流程出错：' + $_.Exception.Message
    if ($sending) { $msg += ' 请求可能已被接收，请先查看学习会话，避免重复发送。'; $details['url']=$learnUrl; $details['mainSession']=@{ id=$main.id; title=$main.title; directory=$WorkDir } }
    elseif ($previousId) {
        # Keep the busy or retained line accessible when rollover cannot finish.
        $details['url'] = '{0}/server/{1}/session/{2}' -f $ServerUrl,(Get-ServerKey $ServerUrl),$previousId
        $details['learnSession'] = @{ id=$previousId; directory=$LineDir }
        $details['mainSession'] = @{ id=$main.id; title=$main.title; directory=$WorkDir }
    }
    Write-LearnOpenRequest -Directory $OpenRequestDir -Invocation $invocation -ErrorMessage $msg -Details $details
    Write-Output $msg
    exit 1
}
