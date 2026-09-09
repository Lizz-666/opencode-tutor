function Test-LearnServerReady {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)
    try {
        $null = Invoke-RestMethod -Method Get -Uri "$BaseUrl/session" -TimeoutSec 3
        return $true
    } catch {
        return $false
    }
}

function Start-LearnServer {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$WorkDir,
        [string]$LogPath
    )
    if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
    if (-not $LogPath) {
        $logDir = Join-Path $env:TEMP 'opencode'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $LogPath = Join-Path $logDir 'learn-serve.log'
    }
    Start-Process cmd -ArgumentList "/c opencode serve --port $Port --print-logs > `"$LogPath`" 2>&1" -WindowStyle Hidden -WorkingDirectory $WorkDir | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-LearnServerReady -BaseUrl ('http://127.0.0.1:' + $Port)) { return $true }
    }
    return $false
}

function ConvertTo-JsonBytes {
    param($Value)
    return ,([System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 8)))
}

function Get-LearnMarker {
    return '[LEARN]'
}

function New-LearnTitle {
    param([Parameter(Mandatory = $true)][string]$BaseTitle)
    $emoji = [char]::ConvertFromUtf32(0x1F4D8)
    $trimmed = $BaseTitle
    if ($trimmed.Length -gt 40) { $trimmed = $trimmed.Substring(0, 40) }
    return $emoji + ' [LEARN] ' + $trimmed
}

function Get-LearnSessions {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)
    $resp = Invoke-WebRequest -Uri "$BaseUrl/session" -UseBasicParsing -TimeoutSec 20
    $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $parsed = ConvertFrom-Json -InputObject $json
    return @($parsed)
}

function Remove-LearnSession {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$SessionId
    )
    try {
        Invoke-RestMethod -Method Delete -Uri "$BaseUrl/session/$SessionId" -TimeoutSec 15 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Send-LearnPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)]$Body
    )
    $bytes = ConvertTo-JsonBytes -Value $Body
    try {
        return Invoke-RestMethod -Method Post -Uri "$BaseUrl/session/$SessionId/prompt_async" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 20
    } catch {
        return Invoke-RestMethod -Method Post -Uri "$BaseUrl/session/$SessionId/message" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 300
    }
}

function Build-LearnBackground {
    param(
        [Parameter(Mandatory = $true)]$Messages,
        [int]$MaxChars = 60000
    )
    $lines = @()
    foreach ($m in @($Messages)) {
        if ($m.info.role -ne 'user' -and $m.info.role -ne 'assistant') { continue }
        $speaker = if ($m.info.role -eq 'user') { 'user' } else { 'assistant' }
        foreach ($t in @($m.parts)) {
            if ($t.type -eq 'text' -and $t.text) {
                $lines += ($speaker + ': ' + $t.text)
            }
        }
    }
    $joined = $lines -join "`n`n"
    if ($MaxChars -gt 0 -and $joined.Length -gt $MaxChars) {
        $joined = $joined.Substring($joined.Length - $MaxChars)
    }
    return $joined
}

function New-LearnPromptBody {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SelectedText,
        [string]$Background = '',
        [string]$Agent = 'explain',
        [string]$Model = '',
        [switch]$NoReply
    )
    $system = '用户消息中的文字是用户在原对话中选中、要求你讲解的原文。请用中文直接讲解：先一句话结论，再展开关键术语，结合背景说明它在原对话语境中的作用；不要复述背景、不要引用标签、不要输出任何形式的包裹标记；若原文为空请提醒用户先拖选文字。'
    if (-not [string]::IsNullOrWhiteSpace($Background)) {
        $system = $system + "`n`n[background]`n" + $Background + "`n[/background]"
    }
    $body = @{ agent = $Agent; system = $system; parts = @(@{ type = 'text'; text = $SelectedText }) }
    if ($Model) {
        $slash = $Model.IndexOf('/')
        if ($slash -gt 0) {
            $body['model'] = @{ providerID = $Model.Substring(0, $slash); modelID = $Model.Substring($slash + 1) }
        }
    }
    if ($NoReply) { $body['noReply'] = $true }
    return $body
}

function Get-LearnMessages {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$SessionId
    )
    $resp = Invoke-WebRequest -Uri "$BaseUrl/session/$SessionId/message" -UseBasicParsing -TimeoutSec 20
    $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $parsed = ConvertFrom-Json -InputObject $json
    return @($parsed)
}

function Invoke-LearnCreate {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Directory
    )
    $createBody = @{ title = $Title }
    if ($Directory) { $createBody['directory'] = $Directory }
    $bytes = ConvertTo-JsonBytes -Value $createBody
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/session" -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 30
}

function Select-MainSession {
    param(
        [Parameter(Mandatory = $true)]$Sessions,
        [Parameter(Mandatory = $true)][string]$Directory,
        [string[]]$ExcludeIds = @(),
        [string]$Marker = ''
    )
    $target = $Directory.TrimEnd('\')
    $candidates = @($Sessions | Where-Object {
        ($_.directory -and ($_.directory.TrimEnd('\') -eq $target)) -and
        ($Marker -eq '' -or -not ($_.title -and $_.title.Contains($Marker))) -and
        ($ExcludeIds -notcontains $_.id)
    })
    if ($candidates.Count -eq 0) { return $null }
    $sorted = @($candidates | Sort-Object { $_.time.updated } -Descending)
    return $sorted[0]
}

function Read-LearnState {
    param([Parameter(Mandatory = $true)][string]$Path)
    $empty = New-Object PSObject -Property @{ lines = @{} }
    if (-not (Test-Path -LiteralPath $Path)) { return $empty }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $obj = $raw | ConvertFrom-Json
        $lines = @{}
        if ($obj.lines) {
            foreach ($prop in $obj.lines.PSObject.Properties) { $lines[$prop.Name] = [string]$prop.Value }
        }
        return New-Object PSObject -Property @{ lines = $lines }
    } catch { return $empty }
}

function Write-LearnState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Lines
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @{ lines = $Lines; updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ServerKey {
    param([Parameter(Mandatory = $true)][string]$ServerUrl)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ServerUrl)
    $b64 = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    return $b64
}

function Get-LearnConfig {
    param([string]$ConfigPath)
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
    $result = @{ port = 4399; backgroundMaxChars = 60000; model = '' }
    try {
        if (Test-Path -LiteralPath $ConfigPath) {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            if ($null -ne $obj.port) { $result['port'] = [int]$obj.port }
            if ($null -ne $obj.backgroundMaxChars) { $result['backgroundMaxChars'] = [int]$obj.backgroundMaxChars }
            if ($obj.model) { $result['model'] = [string]$obj.model }
        }
    } catch {}
    return $result
}

function Test-LearnConfigStale {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [string[]]$ConfigPaths = @()
    )
    $port = ([Uri]$BaseUrl).Port
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $conn) { return $false }
    $owner = ($conn | Select-Object -First 1).OwningProcess
    $proc = Get-Process -Id $owner -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    foreach ($path in $ConfigPaths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            if ((Get-Item -LiteralPath $path).LastWriteTime -gt $proc.StartTime) { return $true }
        }
    }
    return $false
}

function Update-LearnKeybindings {
    param(
        [Parameter(Mandatory = $true)][string]$KeybindingsPath,
        [Parameter(Mandatory = $true)][string]$Url
    )
    try {
        if (-not (Test-Path -LiteralPath $KeybindingsPath)) { return $false }
        $raw = Get-Content -LiteralPath $KeybindingsPath -Raw -Encoding UTF8
        $kb = $raw | ConvertFrom-Json
        $changed = $false
        foreach ($entry in @($kb)) {
            if ($entry.command -ne 'runCommands' -or -not $entry.args) { continue }
            foreach ($cmd in @($entry.args.commands)) {
                if ($cmd.command -eq 'simpleBrowser.api.open') {
                    if (@($cmd.args).Count -gt 0) {
                        if ($cmd.args[0] -ne $Url) { $cmd.args[0] = $Url; $changed = $true }
                    } else {
                        $cmd.args = @($Url)
                        $changed = $true
                    }
                }
            }
        }
        if (-not $changed) { return $true }
        [System.IO.File]::WriteAllText($KeybindingsPath, (ConvertTo-Json -InputObject @($kb) -Depth 10), (New-Object System.Text.UTF8Encoding $true))
        return $true
    } catch { return $false }
}
