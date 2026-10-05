$parent = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $parent 'explain.lib.ps1'
if (-not (Test-Path -LiteralPath $libPath)) { $libPath = Join-Path $parent 'scripts\explain.lib.ps1' }
if (Test-Path -LiteralPath $libPath) { . $libPath }

Describe 'New-LearnPromptBody' {
    It 'puts the raw selection as the only user message without tags' {
        $sel = "line one`nline ``two`` with 'quotes' and `"doubles`""
        $body = New-LearnPromptBody -SelectedText $sel
        $text = $body.parts[0].text
        $text | Should Be $sel
        $text.Contains('<selected_text>') | Should Be $false
        $text.Contains('</selected_text>') | Should Be $false
        $body.parts.Count | Should Be 1
    }

    It 'keeps agent explain and honors the noreply switch' {
        $body = New-LearnPromptBody -SelectedText 'x' -NoReply
        $body.agent | Should Be 'explain'
        $body.noReply | Should Be $true
        $body.ContainsKey('model') | Should Be $false
    }

    It 'embeds the background inside the system prompt' {
        $body = New-LearnPromptBody -SelectedText 'x' -Background "user: what is fork?`nassistant: fork copies history"
        $body.system.Contains('[background]') | Should Be $true
        $body.system.Contains('user: what is fork?') | Should Be $true
        $body.parts.Count | Should Be 1
    }

    It 'omits background markers when no background given' {
        $body = New-LearnPromptBody -SelectedText 'x'
        $body.system.Contains('[background]') | Should Be $false
    }

    It 'adds request-level model when a model override string is given' {
        $body = New-LearnPromptBody -SelectedText 'x' -Model 'deepseek/deepseek-v4-flash'
        $body.model.providerID | Should Be 'deepseek'
        $body.model.modelID | Should Be 'deepseek-v4-flash'
    }

    It 'splits nested model ids on the first slash' {
        $body = New-LearnPromptBody -SelectedText 'x' -Model 'zenmux/deepseek/deepseek-v4-flash'
        $body.model.providerID | Should Be 'zenmux'
        $body.model.modelID | Should Be 'deepseek/deepseek-v4-flash'
    }

    It 'omits model key without an override' {
        $body = New-LearnPromptBody -SelectedText 'x'
        $body.ContainsKey('model') | Should Be $false
    }
}

Describe 'Build-LearnBackground' {
    function New-BgMessage {
        param($Role, $Text)
        New-Object PSObject -Property @{ info = @{ role = $Role }; parts = @(@{ type = 'text'; text = $Text }) }
    }

    It 'extracts user and assistant text with speaker labels and skips others' {
        $msgs = @(
            (New-BgMessage 'user' 'hello'),
            (New-BgMessage 'assistant' 'world'),
            (New-Object PSObject -Property @{ info = @{ role = 'system' }; parts = @(@{ type = 'text'; text = 'skip me' }) }),
            (New-Object PSObject -Property @{ info = @{ role = 'user' }; parts = @(@{ type = 'tool' }, @{ type = 'text'; text = 'after tool' }) })
        )
        $bg = Build-LearnBackground -Messages $msgs
        $bg.Contains('user: hello') | Should Be $true
        $bg.Contains('assistant: world') | Should Be $true
        $bg.Contains('after tool') | Should Be $true
        $bg.Contains('skip me') | Should Be $false
    }

    It 'keeps complete messages under the budget without slicing older messages' {
        $msgs = @(
            (New-BgMessage 'user' ('x' * 100)),
            (New-BgMessage 'assistant' 'ZZZ-FINAL-MARKER')
        )
        $bg = Build-LearnBackground -Messages $msgs -MaxChars 40
        $bg | Should Be 'assistant: ZZZ-FINAL-MARKER'
        $bg.Contains('ZZZ-FINAL-MARKER') | Should Be $true
    }

    It 'returns empty string when nothing usable' {
        $msgs = @(New-Object PSObject -Property @{ info = @{ role = 'system' }; parts = @(@{ type = 'text'; text = 'only system' }) })
        $bg = Build-LearnBackground -Messages $msgs
        $bg | Should Be ''
    }
}

Describe 'Select-MainSession' {
    $dir = 'C:\proj\alpha'
    $marker = [char]::ConvertFromUtf32(0x1F4D8)

    function New-FakeSession {
        param($Id, $Title, $Directory, $Updated)
        New-Object PSObject -Property @{ id = $Id; title = $Title; directory = $Directory; time = @{ updated = $Updated } }
    }

    It 'requires an explicit id when several root sessions match' {
        $a = New-FakeSession 'ses_a' 'work a' $dir 1000
        $b = New-FakeSession 'ses_b' 'work b' $dir 2000
        $c = New-FakeSession 'ses_c' 'work c' $dir 1500
        $result = Select-MainSession -Sessions @($a, $b, $c) -Directory $dir -ExcludeIds @() -Marker 'XYZNOPE'
        $result | Should BeNullOrEmpty
    }

    It 'excludes learn sessions by title marker and by excluded ids' {
        $learn = New-FakeSession 'ses_l1' ($marker + ' old learn') $dir 9000
        $main = New-FakeSession 'ses_m' 'main work' $dir 500
        $result = Select-MainSession -Sessions @($learn, $main) -Directory $dir -ExcludeIds @() -Marker $marker
        $result.id | Should Be 'ses_m'

        $bracketLearn = New-FakeSession 'ses_lb' ('[LEARN] bracket marked') $dir 9500
        $resultB = Select-MainSession -Sessions @($bracketLearn, $main) -Directory $dir -ExcludeIds @() -Marker '[LEARN]'
        $resultB.id | Should Be 'ses_m'

        $stale = New-FakeSession 'ses_s' 'stale but recent' $dir 8000
        $result2 = Select-MainSession -Sessions @($stale, $main) -Directory $dir -ExcludeIds @('ses_s') -Marker 'XYZNOPE'
        $result2.id | Should Be 'ses_m'
    }

    It 'ignores sessions from other directories' {
        $other = New-FakeSession 'ses_o' 'other dir newest' 'C:\proj\beta' 9999
        $mine = New-FakeSession 'ses_i' 'in dir' $dir 100
        $result = Select-MainSession -Sessions @($other, $mine) -Directory $dir -ExcludeIds @() -Marker 'XYZNOPE'
        $result.id | Should Be 'ses_i'
    }

    It 'returns null when no candidate remains' {
        $learn = New-FakeSession 'ses_l' ($marker + ' only learn') $dir 100
        $result = Select-MainSession -Sessions @($learn) -Directory $dir -ExcludeIds @() -Marker $marker
        $result | Should BeNullOrEmpty

        $result2 = Select-MainSession -Sessions @() -Directory $dir -ExcludeIds @() -Marker 'XYZNOPE'
        $result2 | Should BeNullOrEmpty
    }
}

Describe 'Learn state file' {
    $tempRoot = Join-Path $env:TEMP 'opencode'
    if (-not (Test-Path -LiteralPath $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

    It 'roundtrips the main-to-learn line map' {
        $path = Join-Path $tempRoot ('state-test-' + [Guid]::NewGuid().ToString('N') + '.json')
        Write-LearnState -Path $path -Lines @{ 'ses_main1' = 'ses_learn1'; 'ses_main2' = 'ses_learn2' }
        $state = Read-LearnState -Path $path
        $state.lines['ses_main1'] | Should Be 'ses_learn1'
        $state.lines['ses_main2'] | Should Be 'ses_learn2'
        Remove-Item -LiteralPath $path -Force
    }

    It 'returns empty map when state file is missing' {
        $path = Join-Path $tempRoot ('state-missing-' + [Guid]::NewGuid().ToString('N') + '.json')
        $state = Read-LearnState -Path $path
        $state.lines | Should BeNullOrEmpty
    }

    It 'preserves and reports a corrupt state file' {
        $path = Join-Path $env:TEMP ('opencode\corrupt-' + [Guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, '{broken')
        { Read-LearnState -Path $path } | Should Throw
        { Write-LearnState -Path $path -Lines @{ x='y' } } | Should Throw
        [IO.File]::ReadAllText($path) | Should Be '{broken'
        Remove-Item -LiteralPath $path
    }
}

Describe 'Get-LearnConfig' {
    $tempRoot = Join-Path $env:TEMP 'opencode'
    if (-not (Test-Path -LiteralPath $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

    It 'reads port from config file' {
        $path = Join-Path $tempRoot ('cfg-' + [Guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $path -Value '{"port": 5050}' -Encoding UTF8
        $cfg = Get-LearnConfig -ConfigPath $path
        $cfg.port | Should Be 5050
        Remove-Item -LiteralPath $path -Force
    }

    It 'reads an optional model override' {
        $path = Join-Path $tempRoot ('cfg-model-' + [Guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $path -Value '{"port": 5050, "model": "deepseek/deepseek-v4-flash"}' -Encoding UTF8
        $cfg = Get-LearnConfig -ConfigPath $path
        $cfg.model | Should Be 'deepseek/deepseek-v4-flash'
        Remove-Item -LiteralPath $path -Force
    }

    It 'defaults model override to empty when absent' {
        $path = Join-Path $tempRoot ('cfg-nomodel-' + [Guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $path -Value '{"port": 5050}' -Encoding UTF8
        $cfg = Get-LearnConfig -ConfigPath $path
        $cfg.model | Should Be ''
        Remove-Item -LiteralPath $path -Force
    }

    It 'defaults to 4399 when config file is missing' {
        $missing = Get-LearnConfig -ConfigPath (Join-Path $tempRoot ('cfg-missing-' + [Guid]::NewGuid().ToString('N') + '.json'))
        $missing.port | Should Be 4399
    }

    It 'defaults to 4399 when config file is corrupt' {
        $bad = Join-Path $tempRoot ('cfg-bad-' + [Guid]::NewGuid().ToString('N') + '.json')
        Set-Content -LiteralPath $bad -Value '{oops'
        $cfg2 = Get-LearnConfig -ConfigPath $bad
        $cfg2.port | Should Be 4399
        Remove-Item -LiteralPath $bad -Force
    }
}

Describe 'Get-ServerKey' {
    It 'encodes a server url as base64url' {
        Get-ServerKey -ServerUrl 'http://127.0.0.1:4399' | Should Be 'aHR0cDovLzEyNy4wLjAuMTo0Mzk5'
    }
}

Describe 'Test-LearnConfigStale' {
    It 'detects config newer than the listening process' {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        try {
            $cfg = Join-Path $env:TEMP ('opencode\stale-newer-' + [Guid]::NewGuid().ToString('N') + '.json')
            Set-Content -LiteralPath $cfg -Value '{}' -Encoding UTF8
            (Get-Item -LiteralPath $cfg).LastWriteTime = (Get-Date).AddMinutes(1)
            Test-LearnConfigStale -BaseUrl ("http://127.0.0.1:$port") -ConfigPaths @($cfg) | Should Be $true
        } finally { $listener.Stop(); Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue }
    }

    It 'returns false when config is older than the listening process' {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        try {
            $cfg = Join-Path $env:TEMP ('opencode\stale-older-' + [Guid]::NewGuid().ToString('N') + '.json')
            Set-Content -LiteralPath $cfg -Value '{}' -Encoding UTF8
            (Get-Item -LiteralPath $cfg).LastWriteTime = (Get-Date).AddMinutes(-5)
            Test-LearnConfigStale -BaseUrl ("http://127.0.0.1:$port") -ConfigPaths @($cfg) | Should Be $false
        } finally { $listener.Stop(); Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-LearnLineNeedsRebuild' {
    function New-LineInfo {
        param($Id, $ParentId, $Directory)
        $obj = New-Object PSObject -Property @{ id = $Id; directory = $Directory }
        $obj | Add-Member -NotePropertyName parentID -NotePropertyValue $ParentId -Force
        return $obj
    }

    It 'rebuilds when the mapped line is missing' {
        Test-LearnLineNeedsRebuild -LineInfo $null -ExpectedDirectory 'C:\learn\lines' | Should Be $true
    }

    It 'rebuilds a legacy child line (parentID set)' {
        $info = New-LineInfo 'ses_x' 'ses_main' 'C:\learn\lines'
        Test-LearnLineNeedsRebuild -LineInfo $info -ExpectedDirectory 'C:\learn\lines' | Should Be $true
    }

    It 'rebuilds a line placed outside the dedicated directory' {
        $info = New-LineInfo 'ses_x' '' 'C:\proj\alpha'
        Test-LearnLineNeedsRebuild -LineInfo $info -ExpectedDirectory 'C:\learn\lines' | Should Be $true
    }

    It 'keeps a healthy standalone root line in the dedicated directory' {
        $info = New-LineInfo 'ses_x' '' 'C:\learn\lines\'
        Test-LearnLineNeedsRebuild -LineInfo $info -ExpectedDirectory 'C:\learn\lines' | Should Be $false
    }
}

Describe 'Write-LearnOpenRequest' {
    $tempRoot = Join-Path $env:TEMP 'opencode'
    if (-not (Test-Path -LiteralPath $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

    It 'writes a per-invocation url marker readable by the panel extension' {
        $dir = Join-Path $tempRoot ('oreq-' + [Guid]::NewGuid().ToString('N'))
        Write-LearnOpenRequest -Directory $dir -Invocation 'abc-123' -Url 'http://127.0.0.1:4399/server/x/session/ses_line'
        $path = Join-Path $dir 'open-request.abc-123.json'
        (Test-Path -LiteralPath $path) | Should Be $true
        $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $m.invocation | Should Be 'abc-123'
        $m.url | Should Be 'http://127.0.0.1:4399/server/x/session/ses_line'
        $m.error | Should BeNullOrEmpty
        Remove-Item -LiteralPath $dir -Recurse -Force
    }

    It 'writes an error marker without url' {
        $dir = Join-Path $tempRoot ('oreq-err-' + [Guid]::NewGuid().ToString('N'))
        Write-LearnOpenRequest -Directory $dir -Invocation 'err-1' -ErrorMessage 'boom reason'
        $path = Join-Path $dir 'open-request.err-1.json'
        (Test-Path -LiteralPath $path) | Should Be $true
        $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $m.error | Should Be 'boom reason'
        $m.url | Should BeNullOrEmpty
        Remove-Item -LiteralPath $dir -Recurse -Force
    }

    It 'skips writing when invocation is empty (manual runs)' {
        $dir = Join-Path $tempRoot ('oreq-manual-' + [Guid]::NewGuid().ToString('N'))
        Write-LearnOpenRequest -Directory $dir -Invocation '' -Url 'http://x'
        (Test-Path -LiteralPath $dir) | Should Be $false
    }

    It 'sanitizes hostile invocation ids into filename-safe text' {
        $dir = Join-Path $tempRoot ('oreq-bad-' + [Guid]::NewGuid().ToString('N'))
        Write-LearnOpenRequest -Directory $dir -Invocation 'a/../b!@#c' -Url 'http://x'
        $path = Join-Path $dir 'open-request.abc.json'
        (Test-Path -LiteralPath $path) | Should Be $true
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

Describe 'Update-LearnKeybindings' {
    It 'rewrites the simpleBrowser url inside runCommands' {
        $path = Join-Path $env:TEMP ('opencode\kb-' + [Guid]::NewGuid().ToString('N') + '.json')
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
'@ | Set-Content -LiteralPath $path -Encoding UTF8
        $ok = Update-LearnKeybindings -KeybindingsPath $path -Url 'http://127.0.0.1:4399/session/ses_new123'
        $ok | Should Be $true
        $kbRaw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $kbRaw.TrimStart()[0] | Should Be '['
        $kb = $kbRaw | ConvertFrom-Json
        $kb[0].args.commands[1].args[0] | Should Be 'http://127.0.0.1:4399/session/ses_new123'
        Remove-Item -LiteralPath $path -Force
    }

    It 'returns false when file missing' {
        $path = Join-Path $env:TEMP ('opencode\kb-missing-' + [Guid]::NewGuid().ToString('N') + '.json')
        Update-LearnKeybindings -KeybindingsPath $path -Url 'http://127.0.0.1:4399/session/x' | Should Be $false
    }
}
