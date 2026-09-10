param(
    [string]$ClipboardText = '',
    [string]$ServerUrl = '',
    [int]$ServerPort = 0,
    [string]$StateFile = '',
    [string]$WorkDir = '',
    [switch]$NoReply,
    [string]$KeybindingsPath = '',
    [string]$ConfigPath = '',
    [string[]]$OpencodeConfigPaths = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'explain.lib.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$cfg = Get-LearnConfig -ConfigPath $ConfigPath
if ($ServerPort -le 0) { $ServerPort = $cfg.port }
if (-not $ServerUrl) { $ServerUrl = 'http://127.0.0.1:' + $ServerPort }
if (-not $StateFile) { $StateFile = Join-Path $PSScriptRoot 'state.json' }
if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
if (-not $KeybindingsPath -and $env:APPDATA) { $KeybindingsPath = Join-Path $env:APPDATA 'Code\User\keybindings.json' }

$selectedText = $ClipboardText
if ([string]::IsNullOrWhiteSpace($selectedText)) {
    try { $selectedText = Get-Clipboard -Raw -ErrorAction Stop } catch { $selectedText = '' }
}
if ([string]::IsNullOrWhiteSpace($selectedText)) {
    [Console]::Beep(900, 220)
    Start-Sleep -Milliseconds 150
    [Console]::Beep(600, 220)
    Write-Output '剪贴板为空：请先在 opencode 聊天界面按住 Alt 拖选不懂的文字，再按 Alt+L。'
    exit 1
}

if (-not (Test-LearnServerReady -BaseUrl $ServerUrl)) {
    if ($ServerUrl -eq ('http://127.0.0.1:' + $ServerPort)) {
        $started = Start-LearnServer -Port $ServerPort -WorkDir $WorkDir
        if (-not $started) {
            Write-Output ('讲解后台服务启动失败，请查看日志：' + (Join-Path $env:TEMP 'opencode\learn-serve.log'))
            exit 1
        }
    } else {
        Write-Output ('无法连接讲解服务：' + $ServerUrl)
        exit 1
    }
}

try {
    $serverPortForRestart = ([Uri]$ServerUrl).Port
    $globalCfg = @(
        (Join-Path $env:USERPROFILE '.config\opencode\opencode.json'),
        (Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'),
        (Join-Path $env:USERPROFILE '.config\opencode\config.json')
    )
    if ($OpencodeConfigPaths -and $OpencodeConfigPaths.Count -gt 0) { $globalCfg = $OpencodeConfigPaths }
    if (Test-LearnConfigStale -BaseUrl $ServerUrl -ConfigPaths $globalCfg) {
        Write-Output '检测到 opencode 配置比后台服务新，正在重启讲解后台服务...'
        $conn = Get-NetTCPConnection -LocalPort $serverPortForRestart -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            $conn | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
                taskkill /PID $_ /T /F 2>&1 | Out-Null
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 800
        $restartLog = Join-Path $env:TEMP ('opencode\learn-restart-' + $serverPortForRestart + '.log')
        $null = Start-LearnServer -Port $serverPortForRestart -WorkDir $WorkDir -LogPath $restartLog
    }

    $sessions = @(Get-LearnSessions -BaseUrl $ServerUrl)
    $state = Read-LearnState -Path $StateFile
    $marker = Get-LearnMarker
    $main = Select-MainSession -Sessions $sessions -Directory $WorkDir -ExcludeIds @() -Marker $marker
    if (-not $main) {
        Write-Output ('在 ' + $WorkDir + ' 下没有找到可用的主会话：请先打开 opencode 并开始对话，再使用讲解功能。')
        exit 1
    }

    $learnId = $null
    if ($state.lines -and $state.lines.ContainsKey($main.id)) { $learnId = [string]$state.lines[$main.id] }
    $learnAlive = $false
    if ($learnId) {
        try {
            $null = Invoke-RestMethod -Uri ($ServerUrl + '/session/' + $learnId) -TimeoutSec 10
            $learnAlive = $true
        } catch {
            $learnAlive = $false
        }
    }

    if (-not $learnId -or -not $learnAlive) {
        $liveLineIds = @()
        if ($state.lines) { foreach ($k in @($state.lines.Keys)) { $liveLineIds += [string]$state.lines[$k] } }
        foreach ($s in @($sessions | Where-Object {
            $_.title.Contains($marker) -and
            $_.directory -and $_.directory.TrimEnd('\') -eq ($WorkDir.TrimEnd('\')) -and
            ($liveLineIds -notcontains $_.id)
        })) {
            $null = Remove-LearnSession -BaseUrl $ServerUrl -SessionId $s.id
        }
        $learn = Invoke-LearnCreate -BaseUrl $ServerUrl -Title (New-LearnTitle -BaseTitle $main.title) -Directory $WorkDir -ParentId $main.id
        $learnId = $learn.id
        $lines = @{}
        if ($state.lines) { foreach ($k in @($state.lines.Keys)) { $lines[$k] = [string]$state.lines[$k] } }
        $lines[$main.id] = $learnId
        Write-LearnState -Path $StateFile -Lines $lines
    }

    $learnUrl = '{0}/server/{1}/session/{2}' -f $ServerUrl, (Get-ServerKey -ServerUrl $ServerUrl), $learnId
    if ($KeybindingsPath) {
        $null = Update-LearnKeybindings -KeybindingsPath $KeybindingsPath -Url $learnUrl
    }

    $bgCap = 60000
    if ($cfg.ContainsKey('backgroundMaxChars')) { $bgCap = [int]$cfg['backgroundMaxChars'] }
    $modelOverride = ''
    if ($cfg.ContainsKey('model')) { $modelOverride = [string]$cfg['model'] }
    $mainMessages = @(Get-LearnMessages -BaseUrl $ServerUrl -SessionId $main.id)
    $background = Build-LearnBackground -Messages $mainMessages -MaxChars $bgCap

    $body = New-LearnPromptBody -SelectedText $selectedText -Background $background -Model $modelOverride -NoReply:$NoReply
    $null = Send-LearnPrompt -BaseUrl $ServerUrl -SessionId $learnId -Body $body

    Write-Output ('讲解已发送，网页窗口地址：' + $learnUrl)
    exit 0
} catch {
    Write-Output ('讲解流程出错：' + $_.Exception.Message)
    exit 1
}
