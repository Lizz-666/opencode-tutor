$libPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'explain.lib.ps1'
if (Test-Path -LiteralPath $libPath) { . $libPath }
Import-Module (Join-Path $PSScriptRoot 'sandbox.psm1') -Force

Describe 'Server keep-alive' {
    It 'starts server on demand and becomes ready' {
        $port = Get-FreePort
        $base = 'http://127.0.0.1:' + $port
        $log = Join-Path $env:TEMP ('opencode\keepalive-' + [Guid]::NewGuid().ToString('N') + '.log')
        try {
            Test-LearnServerReady -BaseUrl $base | Should Be $false
            $ok = Start-LearnServer -Port $port -WorkDir $env:TEMP -LogPath $log
            $ok | Should Be $true
            Test-LearnServerReady -BaseUrl $base | Should Be $true
        } finally {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
                if (-not $conn) { break }
                $conn | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
                    taskkill /PID $_ /T /F 2>&1 | Out-Null
                    Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 400
            }
            if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Entry script black box' {
    $script:sb = New-Sandbox
    $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'explain.ps1'
    $statePath = Join-Path $script:sb.Directory ('state-' + [Guid]::NewGuid().ToString('N') + '.json')
    $kbPath = Join-Path $script:sb.Directory ('kb-' + [Guid]::NewGuid().ToString('N') + '.json')
    @'
[
  {
    "key": "ctrl+alt+l",
    "command": "runCommands",
    "args": {
      "commands": [
        { "command": "workbench.action.tasks.runTask", "args": "opencode: 讲解选区" },
        { "command": "simpleBrowser.api.open", "args": [ "http://127.0.0.1:4399/session/PLACEHOLDER", { "preserveFocus": true, "viewColumn": 2 } ] }
      ]
    }
  }
]
'@ | Set-Content -LiteralPath $kbPath -Encoding UTF8

    AfterAll {
        if ($script:sb) { Remove-Sandbox -Sandbox $script:sb }
    }

    It 'exits with error and no side effects when clipboard is empty' {
        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session" -TimeoutSec 15
        $before = @($raw).Count
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText ' ' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -NoReply 2>&1
        if ($LASTEXITCODE -ne 1) { Write-Output $out }
        $LASTEXITCODE | Should Be 1
        $raw2 = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session" -TimeoutSec 15
        $after = @($raw2).Count
        $after | Should Be $before
        (Test-Path -LiteralPath $statePath) | Should Be $false
    }

    It 'first trigger creates one sticky learn line with the selection' {
        $main = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'main work'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $main.id -Text 'main context message' | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'what is mount' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session" -TimeoutSec 15
        $sessions = @($raw)
        $marked = @($sessions | Where-Object { $_.title.Contains((Get-LearnMarker)) -and $_.directory -eq $script:sb.Directory })
        $marked.Count | Should Be 1

        $state = Read-LearnState -Path $statePath
        $state.lines[$main.id] | Should Be $marked[0].id

        $kbRaw = Get-Content -LiteralPath $kbPath -Raw -Encoding UTF8
        $kbRaw.Contains($marked[0].id) | Should Be $true

        $found = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Milliseconds 400
            $rawM = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$($marked[0].id)/message" -TimeoutSec 15
            $msgs = @($rawM)
            $texts = ($msgs | ForEach-Object { $_.parts | ForEach-Object { $_.text } }) -join ' '
            if ($texts.Contains('what is mount')) { $found = $true; break }
        }
        $found | Should Be $true
        $texts.Contains('<selected_text>') | Should Be $false
        $texts.Contains('main context message') | Should Be $false
    }

    It 'second trigger appends to the same sticky line without creating a new one' {
        $state = Read-LearnState -Path $statePath
        $firstId = @($state.lines.Values)[0]
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'second selection' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session" -TimeoutSec 15
        $sessions = @($raw)
        $marked = @($sessions | Where-Object { $_.title.Contains((Get-LearnMarker)) -and $_.directory -eq $script:sb.Directory })
        $marked.Count | Should Be 1
        $marked[0].id | Should Be $firstId

        $rawM = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$firstId/message" -TimeoutSec 15
        $texts = (@($rawM) | ForEach-Object { $_.parts | ForEach-Object { $_.text } }) -join ' '
        $texts.Contains('second selection') | Should Be $true
        $texts.Contains('what is mount') | Should Be $true
    }

    It 'switching main session starts a new line and repoints keybindings' {
        $second = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'second main'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $second.id -Text 'new main context' | Out-Null
        $oldState = Read-LearnState -Path $statePath
        $oldId = @($oldState.lines.Values)[0]
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'third selection' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $state = Read-LearnState -Path $statePath
        $state.lines[$second.id] | Should Not Be $oldId

        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session" -TimeoutSec 15
        $sessions = @($raw)
        $newLine = @($sessions | Where-Object { $_.id -eq $state.lines[$second.id] })
        $newLine.Count | Should Be 1
        $kbRaw = Get-Content -LiteralPath $kbPath -Raw -Encoding UTF8
        $kbRaw.Contains($state.lines[$second.id]) | Should Be $true
    }

    It 'auto-restarts the backend when opencode config is newer than the server' {
        $fakeCfg = Join-Path $script:sb.Directory 'fake-opencode.json'
        Set-Content -LiteralPath $fakeCfg -Value '{}' -Encoding UTF8
        (Get-Item -LiteralPath $fakeCfg).LastWriteTime = (Get-Date).AddMinutes(5)
        $main = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'stale main'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $main.id -Text 'ctx' | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'stale check' -ServerUrl $script:sb.BaseUrl -OpencodeConfigPaths @($fakeCfg) -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $state = Read-LearnState -Path $statePath
        $state.lines[$main.id] | Should Not BeNullOrEmpty
    }
}

Describe 'HTTP wrappers against sandbox server' {
    $script:sb = New-Sandbox
    $marker = [char]::ConvertFromUtf32(0x1F4D8)

    AfterAll {
        if ($script:sb) { Remove-Sandbox -Sandbox $script:sb }
    }

    It 'creates a learn session with directory and marker title' {
        $learn = Invoke-LearnCreate -BaseUrl $script:sb.BaseUrl -Title (New-LearnTitle -BaseTitle 'i1 base') -Directory $script:sb.Directory
        $learn.id | Should Not BeNullOrEmpty

        $one = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$($learn.id)" -TimeoutSec 15
        $one.title.Contains((Get-LearnMarker)) | Should Be $true
        $one.directory.TrimEnd('\') | Should Be $script:sb.Directory.TrimEnd('\')
    }

    It 'roundtrips messages written into a created session' {
        $learn = Invoke-LearnCreate -BaseUrl $script:sb.BaseUrl -Title 'i2 base' -Directory $script:sb.Directory
        $body = @{ noReply = $true; parts = @(@{ type = 'text'; text = 'roundtrip marker text' }) }
        Send-LearnPrompt -BaseUrl $script:sb.BaseUrl -SessionId $learn.id -Body $body | Out-Null

        $roundtripped = $false
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 300
            $rawM = Invoke-WebRequest -Uri "$($script:sb.BaseUrl)/session/$($learn.id)/message" -UseBasicParsing -TimeoutSec 15
            $parsed = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($rawM.RawContentStream.ToArray()))
            $msgs = @($parsed)
            $texts = ($msgs | ForEach-Object { $_.parts | ForEach-Object { $_.text } }) -join ' '
            if ($texts.Contains('roundtrip marker text')) { $roundtripped = $true; break }
        }
        $roundtripped | Should Be $true
    }

    It 'sends prompt that lands as user message without assistant reply' {
        $s = New-SandboxSession -BaseUrl $sb.BaseUrl -Title 'i3 send'
        $body = @{ noReply = $true; parts = @(@{ type = 'text'; text = 'hello learn' }) }
        Send-LearnPrompt -BaseUrl $sb.BaseUrl -SessionId $s.id -Body $body | Out-Null

        $userCount = 0
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 300
            $msgs = @(Invoke-RestMethod -Uri "$($sb.BaseUrl)/session/$($s.id)/message" -TimeoutSec 15)
            $userCount = @($msgs | Where-Object { $_.info.role -eq 'user' }).Count
            if ($userCount -ge 1) { break }
        }
        $userCount | Should Be 1
        @($msgs | Where-Object { $_.info.role -eq 'assistant' }).Count | Should Be 0
    }

    It 'deletes session and tolerates repeated deletion' {
        $s = New-SandboxSession -BaseUrl $sb.BaseUrl -Title 'i4 delete'
        $first = Remove-LearnSession -BaseUrl $sb.BaseUrl -SessionId $s.id
        $first | Should Be $true

        $list = @(Invoke-RestMethod -Uri "$($sb.BaseUrl)/session" -TimeoutSec 15)
        @($list | Where-Object { $_.id -eq $s.id }).Count | Should Be 0

        $second = Remove-LearnSession -BaseUrl $sb.BaseUrl -SessionId $s.id
        $second | Should Be $false
    }
}
