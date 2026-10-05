$parent = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $parent 'explain.lib.ps1'
if (-not (Test-Path -LiteralPath $libPath)) { $libPath = Join-Path $parent 'scripts\explain.lib.ps1' }
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
    if (-not (Test-Path -LiteralPath $entry)) { $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\explain.ps1' }
    $statePath = Join-Path $script:sb.Directory ('state-' + [Guid]::NewGuid().ToString('N') + '.json')
    $kbPath = Join-Path $script:sb.Directory ('kb-' + [Guid]::NewGuid().ToString('N') + '.json')
    $script:lineDir = Join-Path $script:sb.Directory 'lines'
    $script:markerDir = Join-Path $script:sb.Directory 'markers'
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
        $env:OPENCODE_TUTOR_INVOCATION = 'e1'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText ' ' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -OpenRequestDir $script:markerDir -NoReply 2>&1
        if ($LASTEXITCODE -ne 1) { Write-Output $out }
        $LASTEXITCODE | Should Be 1
        Remove-Item Env:\OPENCODE_TUTOR_INVOCATION -ErrorAction SilentlyContinue
        $raw2 = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session" -TimeoutSec 15
        $after = @($raw2).Count
        $after | Should Be $before
        (Test-Path -LiteralPath $statePath) | Should Be $false

        $markerPath = Join-Path $script:markerDir 'open-request.e1.json'
        (Test-Path -LiteralPath $markerPath) | Should Be $true
        $m = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $m.invocation | Should Be 'e1'
        $m.url | Should BeNullOrEmpty
        $m.error | Should Not BeNullOrEmpty
    }

    It 'first trigger creates one sticky learn line with the selection' {
        $main = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'main work'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $main.id -Text 'main context message' | Out-Null
        $env:OPENCODE_TUTOR_INVOCATION = 's1'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'what is mount' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -OpenRequestDir $script:markerDir -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0
        Remove-Item Env:\OPENCODE_TUTOR_INVOCATION -ErrorAction SilentlyContinue

        (Test-Path -LiteralPath $script:lineDir) | Should Be $true
        $escLineDir = [Uri]::EscapeDataString($script:lineDir)
        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session?directory=$escLineDir" -TimeoutSec 15
        $sessions = @($raw)
        $marked = @($sessions | Where-Object { $_.title.Contains((Get-LearnMarker)) })
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

        $lineInfo = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$($marked[0].id)" -TimeoutSec 15
        $lineInfo.parentID | Should BeNullOrEmpty
        $lineInfo.directory.TrimEnd('\') | Should Be $script:lineDir.TrimEnd('\')

        $markerPath = Join-Path $script:markerDir 'open-request.s1.json'
        (Test-Path -LiteralPath $markerPath) | Should Be $true
        $m = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $m.invocation | Should Be 's1'
        $m.error | Should BeNullOrEmpty
        $m.url.Contains($marked[0].id) | Should Be $true
    }

    It 'honors a cancellation marker before creating a line or sending a prompt' {
        $env:OPENCODE_TUTOR_INVOCATION = 'cancel-before-send'
        $cancel = Join-Path $script:markerDir 'cancel-request.cancel-before-send.json'
        [IO.File]::WriteAllText($cancel,'{}')
        $isolatedState = Join-Path $script:sb.Directory 'cancelled-state.json'
        try {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'cancel this selection' -ServerUrl $script:sb.BaseUrl -StateFile $isolatedState -WorkDir $script:sb.Directory -OpenRequestDir $script:markerDir -NoReply 2>&1
            $LASTEXITCODE | Should Be 1
            (Test-Path -LiteralPath $isolatedState) | Should Be $false
            $result = Get-Content -LiteralPath (Join-Path $script:markerDir 'open-request.cancel-before-send.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.error.Contains('未发送') | Should Be $true
        } finally { Remove-Item Env:\OPENCODE_TUTOR_INVOCATION -ErrorAction SilentlyContinue }
    }

    It 'learn line stays invisible in the project session listings' {
        $state = Read-LearnState -Path $statePath
        $learnId = @($state.lines.Values)[-1]

        $escDir = [Uri]::EscapeDataString($script:sb.Directory)
        $projRoots = @(Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session?directory=$escDir&roots=true" -TimeoutSec 15)
        @($projRoots | Where-Object { $_.id -eq $learnId }).Count | Should Be 0

        $projRaw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session?directory=$escDir" -TimeoutSec 15
        $proj = @($projRaw)
        @($proj | Where-Object { $_.id -eq $learnId }).Count | Should Be 0
    }

    It 'second trigger appends to the same sticky line without creating a new one' {
        $state = Read-LearnState -Path $statePath
        $firstId = @($state.lines.Values)[0]
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -ClipboardText 'second selection' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $escLineDir = [Uri]::EscapeDataString($script:lineDir)
        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session?directory=$escLineDir" -TimeoutSec 15
        $sessions = @($raw)
        $marked = @($sessions | Where-Object { $_.title.Contains((Get-LearnMarker)) })
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
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -MainSessionId $second.id -ClipboardText 'third selection' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $state = Read-LearnState -Path $statePath
        $state.lines[$second.id] | Should Not Be $oldId

        $newLineInfo = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$($state.lines[$second.id])" -TimeoutSec 15
        $newLineInfo.id | Should Be $state.lines[$second.id]
        $newLineInfo.parentID | Should BeNullOrEmpty
        $kbRaw = Get-Content -LiteralPath $kbPath -Raw -Encoding UTF8
        $kbRaw.Contains($state.lines[$second.id]) | Should Be $true
    }

    It 'migrates a legacy child line into a standalone root line' {
        $legacyMain = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'legacy main'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $legacyMain.id -Text 'legacy ctx' | Out-Null
        $otherMain = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'legacy other main'
        $emoji = [char]::ConvertFromUtf32(0x1F4D8)
        $childBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ title = ($emoji + ' [LEARN] legacy child'); directory = $script:sb.Directory; parentID = $legacyMain.id } | ConvertTo-Json))
        $child = Invoke-RestMethod -Method Post -Uri "$($script:sb.BaseUrl)/session" -ContentType 'application/json; charset=utf-8' -Body $childBytes -TimeoutSec 30
        $otherChildBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ title = ($emoji + ' [LEARN] legacy other child'); directory = $script:sb.Directory; parentID = $otherMain.id } | ConvertTo-Json))
        $otherChild = Invoke-RestMethod -Method Post -Uri "$($script:sb.BaseUrl)/session" -ContentType 'application/json; charset=utf-8' -Body $otherChildBytes -TimeoutSec 30

        $st = Read-LearnState -Path $statePath
        $lines = @{}
        foreach ($k in @($st.lines.Keys)) { $lines[$k] = [string]$st.lines[$k] }
        $lines[$legacyMain.id] = [string]$child.id
        $lines[$otherMain.id] = [string]$otherChild.id
        Write-LearnState -Path $statePath -Lines $lines

        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $legacyMain.id -Text 'legacy ctx 2' | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -MainSessionId $legacyMain.id -ClipboardText 'migration selection' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        $state = Read-LearnState -Path $statePath
        $newId = [string]$state.lines[$legacyMain.id]
        $newId | Should Not Be $child.id

        foreach ($dead in @($child.id, $otherChild.id)) {
            $gone = $false
            try { $null = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$dead" -TimeoutSec 10 } catch { $gone = $true }
            $gone | Should Be $false
        }

        $newInfo = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$newId" -TimeoutSec 15
        $newInfo.parentID | Should BeNullOrEmpty
        $newInfo.directory.TrimEnd('\') | Should Be $script:lineDir.TrimEnd('\')
    }

    It 'preserves unmapped learn lines during rebuild' {
        if (-not (Test-Path -LiteralPath $script:lineDir)) { New-Item -ItemType Directory -Path $script:lineDir -Force | Out-Null }
        $emoji = [char]::ConvertFromUtf32(0x1F4D8)
        $orphanLineBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ title = ($emoji + ' [LEARN] orphan line'); directory = $script:lineDir } | ConvertTo-Json))
        $orphanLine = Invoke-RestMethod -Method Post -Uri "$($script:sb.BaseUrl)/session" -ContentType 'application/json; charset=utf-8' -Body $orphanLineBytes -TimeoutSec 30
        $orphanProjBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ title = ($emoji + ' [LEARN] orphan proj'); directory = $script:sb.Directory } | ConvertTo-Json))
        $orphanProj = Invoke-RestMethod -Method Post -Uri "$($script:sb.BaseUrl)/session" -ContentType 'application/json; charset=utf-8' -Body $orphanProjBytes -TimeoutSec 30

        $freshMain = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'fresh main'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $freshMain.id -Text 'fresh ctx' | Out-Null

        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -MainSessionId $freshMain.id -ClipboardText 'cleanup selection' -ServerUrl $script:sb.BaseUrl -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -NoReply 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Output $out }
        $LASTEXITCODE | Should Be 0

        foreach ($dead in @($orphanLine.id, $orphanProj.id)) {
            $gone = $false
            try { $null = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session/$dead" -TimeoutSec 10 } catch { $gone = $true }
            $gone | Should Be $false
        }

        $escLineDir = [Uri]::EscapeDataString($script:lineDir)
        $raw = Invoke-RestMethod -Uri "$($script:sb.BaseUrl)/session?directory=$escLineDir" -TimeoutSec 15
        $marked = @($raw | Where-Object { $_.title.Contains((Get-LearnMarker)) })
        $marked.Count | Should BeGreaterThan 0
        $state = Read-LearnState -Path $statePath
        $state.lines[$freshMain.id] | Should Not BeNullOrEmpty
    }

    It 'keeps a running backend when config changes instead of killing its owner' {
        $fakeCfg = Join-Path $script:sb.Directory 'fake-opencode.json'
        Set-Content -LiteralPath $fakeCfg -Value '{}' -Encoding UTF8
        (Get-Item -LiteralPath $fakeCfg).LastWriteTime = (Get-Date).AddMinutes(5)
        $main = New-SandboxSession -BaseUrl $script:sb.BaseUrl -Title 'stale main'
        Add-SandboxMessage -BaseUrl $script:sb.BaseUrl -SessionId $main.id -Text 'ctx' | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $entry -MainSessionId $main.id -ClipboardText 'stale check' -ServerUrl $script:sb.BaseUrl -OpencodeConfigPaths @($fakeCfg) -StateFile $statePath -WorkDir $script:sb.Directory -KeybindingsPath $kbPath -LineDir $script:lineDir -NoReply 2>&1
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

    It 'pages older context using the supported limit and before parameters' {
        $s = New-SandboxSession -BaseUrl $sb.BaseUrl -Title 'pagination fixture'
        foreach ($text in @('older selected phrase','middle context','latest context')) {
            Add-SandboxMessage -BaseUrl $sb.BaseUrl -SessionId $s.id -Text $text | Out-Null
        }
        $cursor = ''
        $recent = @(Get-LearnMessages -BaseUrl $sb.BaseUrl -SessionId $s.id -Limit 2 -NextCursor ([ref]$cursor))
        $recent.Count | Should Be 2
        (Get-LearnMessageText $recent[0]) | Should Be 'middle context'
        $cursor | Should Not BeNullOrEmpty
        $older = @(Get-LearnMessages -BaseUrl $sb.BaseUrl -SessionId $s.id -Limit 2 -Before $cursor)
        $older.Count | Should Be 1
        (Get-LearnMessageText $older[0]) | Should Be 'older selected phrase'
        $context = @(Get-LearnContextMessages -BaseUrl $sb.BaseUrl -SessionId $s.id -SelectedText 'older selected phrase' -PageSize 2 -MaxMessages 6)
        $context.Count | Should Be 3
    }

    It 'rolls over a full learning session without deleting the previous one' {
        $main = New-SandboxSession -BaseUrl $sb.BaseUrl -Title 'rollover fixture'
        $state = Join-Path $sb.Directory 'rollover.json'
        $lineDir = Join-Path $sb.Directory 'lines'
        $old = Get-OrCreateLearnLine $sb.BaseUrl $state $lineDir $main -MaxMessages 2
        Add-SandboxMessage -BaseUrl $sb.BaseUrl -SessionId $old -Text 'first question' | Out-Null
        Add-SandboxMessage -BaseUrl $sb.BaseUrl -SessionId $old -Text 'second question' | Out-Null
        $previous = ''
        $next = Get-OrCreateLearnLine $sb.BaseUrl $state $lineDir $main -MaxMessages 2 -PreviousId ([ref]$previous)
        $next | Should Not Be $old
        $previous | Should Be $old
        (Read-LearnState $state).lines[$main.id] | Should Be $next
        @(Get-LearnMessages -BaseUrl $sb.BaseUrl -SessionId $old).Count | Should Be 2
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
