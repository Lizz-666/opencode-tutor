function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function New-Sandbox {
    param([string]$Name = 'learn-test')
    $root = Join-Path $env:TEMP 'opencode'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $dir = Join-Path $root ($Name + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $port = Get-FreePort
    $log = Join-Path $dir 'serve.log'
    Start-Process cmd -ArgumentList "/c opencode serve --port $port --print-logs > `"$log`" 2>&1" -WindowStyle Hidden -WorkingDirectory $dir | Out-Null
    $base = 'http://127.0.0.1:' + $port
    $ready = $false
    for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
        Start-Sleep -Milliseconds 500
        try { $null = Invoke-RestMethod -Uri "$base/session" -TimeoutSec 2; $ready = $true } catch {}
    }
    if (-not $ready) {
        $tail = ''
        if (Test-Path -LiteralPath $log) { $tail = Get-Content -LiteralPath $log -Raw }
        throw "sandbox server failed to start on $base. log tail: $tail"
    }
    return New-Object PSObject -Property @{ BaseUrl = $base; Port = $port; Directory = $dir; Log = $log }
}

function Clear-SandboxSessions {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Directory
    )
    $target = $Directory.TrimEnd('\')
    $resp = Invoke-WebRequest -Uri "$BaseUrl/session" -UseBasicParsing -TimeoutSec 20
    $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $parsed = ConvertFrom-Json -InputObject $json
    $sessions = @($parsed)
    foreach ($s in $sessions) {
        if ($s.directory -and $s.directory.TrimEnd('\') -eq $target) {
            try { Invoke-RestMethod -Method Delete -Uri "$BaseUrl/session/$($s.id)" -TimeoutSec 15 | Out-Null } catch {}
        }
    }
}

function Remove-Sandbox {
    param([Parameter(Mandatory = $true)]$Sandbox)
    try { Clear-SandboxSessions -BaseUrl $Sandbox.BaseUrl -Directory $Sandbox.Directory } catch {}
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $conn = Get-NetTCPConnection -LocalPort $Sandbox.Port -State Listen -ErrorAction SilentlyContinue
        if (-not $conn) { break }
        $owners = @($conn | Select-Object -ExpandProperty OwningProcess -Unique)
        foreach ($owner in $owners) {
            taskkill /PID $owner /T /F 2>&1 | Out-Null
            Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $Sandbox.Directory -Recurse -Force -ErrorAction SilentlyContinue
}

function New-SandboxSession {
    param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Title)
    $body = @{ title = $Title } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/session" -ContentType 'application/json' -Body $body -TimeoutSec 15
}

function Add-SandboxMessage {
    param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$SessionId, [Parameter(Mandatory = $true)][string]$Text)
    $body = @{ noReply = $true; parts = @(@{ type = 'text'; text = $Text }) } | ConvertTo-Json -Depth 6
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/session/$SessionId/message" -ContentType 'application/json' -Body $body -TimeoutSec 30
}
