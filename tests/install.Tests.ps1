. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\jsonc.ps1')
$installScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
$script:extDirName = 'lizz666.opencode-tutor-panel-' + ((Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'extension\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)
$script:sandboxes = @()

function New-SandboxHome {
    $root = Join-Path $env:TEMP ('opencode\install-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'AppData\Roaming\Code\User') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root '.config\opencode') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'AppData\Roaming\Code\User\keybindings.json') -Value '[{"key":"ctrl+alt+k","command":"workbench.action.files.saveAll"}]' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'AppData\Roaming\Code\User\tasks.json') -Value '{"version":"2.0.0","tasks":[{"label":"user task","type":"shell","command":"echo hi"}]}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'AppData\Roaming\Code\User\settings.json') -Value '{"editor.fontSize":14}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root '.config\opencode\opencode.json') -Value '{"model":"some/model","agent":{"other":{"mode":"primary"}}}' -Encoding UTF8
    $script:sandboxes += $root
    return $root
}

function Invoke-Installer {
    param([string]$Root, [string[]]$Extra = @())
    $cmdArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installScript, '-SandboxRoot', $Root, '-SkipSystemLevel', '-Force') + $Extra
    $out = & powershell @cmdArgs 2>&1 | Out-String
    return @{ out = $out; code = $LASTEXITCODE }
}

function Get-FileHashHex {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return 'MISSING'
}

function Read-JsonObj {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $parsed = ConvertFrom-TutorJsonc -Text $raw
    return @($parsed)
}

function Get-BackupCount {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.bak-' }).Count
}

Describe 'install.ps1' {
    if (-not (Test-Path -LiteralPath $installScript)) {
        It 'skipped: install.ps1 not present (runtime layout)' { $true | Should Be $true }
    } else {
        AfterAll {
            foreach ($h in @($script:sandboxes)) {
                if ($h -and (Test-Path -LiteralPath $h)) { Remove-Item -LiteralPath $h -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'installs into a seeded sandbox preserving user content' {
            $sandbox = New-SandboxHome
            $r = Invoke-Installer -Root $sandbox
            $r.code | Should Be 0

            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            $kb = @(Read-JsonObj -Path $kbPath)
            @($kb | Where-Object { $_.key -eq 'ctrl+alt+k' }).Count | Should Be 1
            $ours = @($kb | Where-Object { $_.key -eq 'alt+l' })
            @($ours).Count | Should Be 1
            $ours[0].command | Should Be 'opencodeTutor.open'

            $tasksPath = Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json'
            $tasks = Read-JsonObj -Path $tasksPath
            @($tasks.tasks | Where-Object { $_.label -eq 'user task' }).Count | Should Be 1
            @($tasks.tasks | Where-Object { $_.label -eq 'opencode: 讲解选区' }).Count | Should Be 0

            $settingsPath = Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json'
            $settings = Read-JsonObj -Path $settingsPath
            $settings.'editor.fontSize' | Should Be 14
            $settings.'terminal.integrated.copyOnSelection' | Should Be $true

            $extPkg = Join-Path $sandbox ('.vscode\extensions\' + $script:extDirName + '\package.json')
            $extJs = Join-Path $sandbox ('.vscode\extensions\' + $script:extDirName + '\extension.js')
            (Test-Path -LiteralPath $extPkg) | Should Be $true
            (Test-Path -LiteralPath $extJs) | Should Be $true

            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            $oc = Read-JsonObj -Path $ocPath
            $oc.model | Should Be 'some/model'
            $oc.agent.other.mode | Should Be 'primary'
            $oc.agent.explain.mode | Should Be 'subagent'

            (Test-Path -LiteralPath (Join-Path $sandbox '.config\opencode\learn\explain.ps1')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $sandbox '.config\opencode\learn\config.json')) | Should Be $true
            (Get-BackupCount -Root $sandbox) -gt 0 | Should Be $true
        }

        It 'upgrades legacy runCommands keybinding, removes legacy task and old browser setting patch' {
            $sandbox = New-SandboxHome
            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            @'
[
  { "key": "ctrl+alt+k", "command": "workbench.action.files.saveAll" },
  {
    "key": "alt+l",
    "command": "runCommands",
    "when": "terminalFocus",
    "args": {
      "commands": [
        { "command": "workbench.action.tasks.runTask", "args": "opencode: 讲解选区" },
        { "command": "simpleBrowser.api.open", "args": [ "http://127.0.0.1:4399/server/k/session/ses_old", { "preserveFocus": true, "viewColumn": 2 } ] }
      ]
    }
  }
]
'@ | Set-Content -LiteralPath $kbPath -Encoding UTF8
            $tasksPath = Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json'
            Set-Content -LiteralPath $tasksPath -Value '{"version":"2.0.0","tasks":[{"label":"user task","type":"shell","command":"echo hi"},{"label":"opencode: 讲解选区","type":"shell","command":"powershell"}]}' -Encoding UTF8
            $settingsPath = Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json'
            Set-Content -LiteralPath $settingsPath -Value '{"editor.fontSize":14,"workbench.browser.newTabPlacement":"sideGroup"}' -Encoding UTF8

            $r = Invoke-Installer -Root $sandbox
            $r.code | Should Be 0

            $kb = @(Read-JsonObj -Path $kbPath)
            @($kb | Where-Object { $_.key -eq 'ctrl+alt+k' }).Count | Should Be 1
            $ours = @($kb | Where-Object { $_.key -eq 'alt+l' })
            @($ours).Count | Should Be 1
            $ours[0].command | Should Be 'opencodeTutor.open'

            $tasks = Read-JsonObj -Path $tasksPath
            @($tasks.tasks | Where-Object { $_.label -eq 'user task' }).Count | Should Be 1
            @($tasks.tasks | Where-Object { $_.label -eq 'opencode: 讲解选区' }).Count | Should Be 0

            $settings = Read-JsonObj -Path $settingsPath
            $settings.'editor.fontSize' | Should Be 14
            $settings.'workbench.browser.newTabPlacement' | Should BeNullOrEmpty
        }

        It 'is idempotent: second run changes nothing' {
            $sandbox = $script:sandboxes[-1]
            $files = @(
                (Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'),
                (Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json'),
                (Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json'),
                (Join-Path $sandbox '.config\opencode\opencode.json'),
                (Join-Path $sandbox ('.vscode\extensions\' + $script:extDirName + '\package.json')),
                (Join-Path $sandbox ('.vscode\extensions\' + $script:extDirName + '\extension.js'))
            )
            $before = @($files | ForEach-Object { Get-FileHashHex -Path $_ })
            $bakBefore = Get-BackupCount -Root $sandbox

            $r = Invoke-Installer -Root $sandbox
            $r.code | Should Be 0

            $after = @($files | ForEach-Object { Get-FileHashHex -Path $_ })
            ($after -join ',') | Should Be ($before -join ',')
            (Get-BackupCount -Root $sandbox) | Should Be $bakBefore
        }

        It 'uninstall removes our entries and preserves the rest' {
            $sandbox = $script:sandboxes[-1]
            $r = Invoke-Installer -Root $sandbox -Extra @('-Uninstall')
            $r.code | Should Be 0

            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            $kb = @(Read-JsonObj -Path $kbPath)
            @($kb | Where-Object { $_.key -eq 'alt+l' }).Count | Should Be 0
            @($kb | Where-Object { $_.key -eq 'ctrl+alt+k' }).Count | Should Be 1

            $tasks = Read-JsonObj -Path (Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json')
            @($tasks.tasks | Where-Object { $_.label -eq 'opencode: 讲解选区' }).Count | Should Be 0
            @($tasks.tasks | Where-Object { $_.label -eq 'user task' }).Count | Should Be 1

            $oc = Read-JsonObj -Path (Join-Path $sandbox '.config\opencode\opencode.json')
            $oc.model | Should Be 'some/model'
            $oc.agent.other.mode | Should Be 'primary'
            ($oc.agent.PSObject.Properties.Name -contains 'explain') | Should Be $false

            $settings = Read-JsonObj -Path (Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json')
            $settings.'editor.fontSize' | Should Be 14

            (Test-Path -LiteralPath (Join-Path $sandbox ('.vscode\extensions\' + $script:extDirName))) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $sandbox '.config\opencode\learn')) | Should Be $false
        }

        It 'creates keybindings when missing and uninstalls back to an empty array' {
            $sandbox = New-SandboxHome
            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            Remove-Item -LiteralPath $kbPath -Force

            $r = Invoke-Installer -Root $sandbox
            $r.code | Should Be 0
            (Test-Path -LiteralPath $kbPath) | Should Be $true
            $kb = @(Read-JsonObj -Path $kbPath)
            @($kb | Where-Object { $_.key -eq 'alt+l' }).Count | Should Be 1

            $r2 = Invoke-Installer -Root $sandbox -Extra @('-Uninstall')
            $r2.code | Should Be 0
            (Test-Path -LiteralPath $kbPath) | Should Be $true
            $raw2 = Get-Content -LiteralPath $kbPath -Raw -Encoding UTF8
            ([TutorJsonc]::Clean($raw2)) | Should Be '[]'
            $kb2 = @(Read-JsonObj -Path $kbPath)
            @($kb2 | Where-Object { $_ -and $_.key -eq 'alt+l' }).Count | Should Be 0
        }

        It 'edits JSONC while preserving comments and custom entries' {
            $sandbox = New-SandboxHome
            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            Set-Content -LiteralPath $kbPath -Value "// user comment`n[`n// custom shortcut`n{`"key`":`"ctrl+k`",`"command`":`"custom.command`"},`n]" -Encoding UTF8
            $r = Invoke-Installer -Root $sandbox
            $r.code | Should Be 0
            $text = Get-Content -LiteralPath $kbPath -Raw -Encoding UTF8
            $text.Contains('// user comment') | Should Be $true
            $text.Contains('// custom shortcut') | Should Be $true
            @((Read-JsonObj $kbPath) | Where-Object command -eq 'opencodeTutor.open').Count | Should Be 1
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            $text = Get-Content -LiteralPath $kbPath -Raw -Encoding UTF8
            $text.Contains('// custom shortcut') | Should Be $true
            @((Read-JsonObj $kbPath) | Where-Object command -eq 'custom.command').Count | Should Be 1
        }

        It 'keeps a later custom shortcut ahead in priority during legacy migration and reinstall' {
            $sandbox = New-SandboxHome
            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            @'
[
  // tool binding
  {"key":"alt+l","command":"runCommands","when":"terminalFocus","args":{"commands":[{"command":"workbench.action.tasks.runTask","args":"opencode: 讲解选区"}]}},
  // user override must remain last
  {"key":"alt+l","command":"user.custom","when":"terminalFocus"}
]
'@ | Set-Content -LiteralPath $kbPath -Encoding UTF8
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            $kb = @(Read-JsonObj $kbPath)
            ($kb.command -join ',') | Should Be 'opencodeTutor.open,user.custom'
            $before = [IO.File]::ReadAllText($kbPath)
            $bakBefore = Get-BackupCount -Root $sandbox
            $before.Contains('// user override must remain last') | Should Be $true
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            [IO.File]::ReadAllText($kbPath) | Should Be $before
            (Get-BackupCount -Root $sandbox) | Should Be $bakBefore
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            (@(Read-JsonObj $kbPath).command -join ',') | Should Be 'user.custom'
        }

        It 'restores fields removed by reset including nested objects arrays null and false' {
            $sandbox = New-SandboxHome
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            $original = '{"agent":{"explain":{"model":"custom/model","temperature":0.2,"permission":{"bash":"deny"},"disable":false,"top_p":null,"empty":[],"single":["one"],"tools":{"bash":true,"custom":false}}}}'
            Set-Content -LiteralPath $ocPath -Value $original -Encoding UTF8
            (Invoke-Installer -Root $sandbox -Extra @('-ResetAgent')).code | Should Be 0
            $agent = (Read-JsonObj $ocPath).agent.explain
            ($agent.PSObject.Properties.Name -contains 'temperature') | Should Be $false
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            $agent = (Read-JsonObj $ocPath).agent.explain
            $agent.model | Should Be 'custom/model'
            $agent.temperature | Should Be 0.2
            $agent.permission.bash | Should Be 'deny'
            $agent.disable | Should Be $false
            ($agent.PSObject.Properties.Name -contains 'top_p') | Should Be $true
            $agent.top_p | Should BeNullOrEmpty
            (ConvertTo-Json -InputObject $agent.empty -Compress) | Should Be '[]'
            (ConvertTo-Json -InputObject $agent.single -Compress) | Should Be '["one"]'
            $agent.tools.bash | Should Be $true
            $agent.tools.custom | Should Be $false
        }

        It 'preserves fields redefined after reset and does not recreate a parent removed by the user' {
            $sandbox = New-SandboxHome
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            Set-Content -LiteralPath $ocPath -Value '{"agent":{"explain":{"temperature":0.2,"permission":"deny","tools":{"custom":false}}}}' -Encoding UTF8
            (Invoke-Installer -Root $sandbox -Extra @('-ResetAgent')).code | Should Be 0
            $obj = @(Read-JsonObj $ocPath)[0]
            $obj.agent.explain | Add-Member -NotePropertyName temperature -NotePropertyValue 0.9
            $obj.agent.explain | Add-Member -NotePropertyName permission -NotePropertyValue $null
            $obj.agent.explain.PSObject.Properties.Remove('tools')
            Write-TutorJsonc -Path $ocPath -Value $obj
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            $agent = (Read-JsonObj $ocPath).agent.explain
            $agent.temperature | Should Be 0.9
            ($agent.PSObject.Properties.Name -contains 'permission') | Should Be $true
            $agent.permission | Should BeNullOrEmpty
            ($agent.PSObject.Properties.Name -contains 'tools') | Should Be $false
        }

        It 'does not restore fields the user had already deleted before resetting' {
            $sandbox = New-SandboxHome
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            Set-Content -LiteralPath $ocPath -Value '{"agent":{"explain":{"temperature":0.2}}}' -Encoding UTF8
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            $obj = @(Read-JsonObj $ocPath)[0]
            $obj.agent.explain.PSObject.Properties.Remove('temperature')
            Write-TutorJsonc -Path $ocPath -Value $obj
            (Invoke-Installer -Root $sandbox -Extra @('-ResetAgent')).code | Should Be 0
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            ((Read-JsonObj $ocPath).agent.explain.PSObject.Properties.Name -contains 'temperature') | Should Be $false
        }

        It 'recovers deleted fields from legacy install records without deletion tracking' {
            $sandbox = New-SandboxHome
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            Set-Content -LiteralPath $ocPath -Value '{"agent":{"explain":{"temperature":0.2,"permission":"deny"}}}' -Encoding UTF8
            (Invoke-Installer -Root $sandbox -Extra @('-ResetAgent')).code | Should Be 0
            $statePath = Join-Path $sandbox '.config\opencode\learn\install-state.json'
            $state = @(Read-JsonObj $statePath)[0]
            $state.PSObject.Properties.Remove('agentRemoved')
            Write-TutorJsonc -Path $statePath -Value $state
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            (Read-JsonObj $ocPath).agent.explain.temperature | Should Be 0.2
            (Read-JsonObj $ocPath).agent.explain.permission | Should Be 'deny'
        }

        It 'preserves customized agents across reinstall and uninstall' {
            $sandbox = New-SandboxHome
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            Set-Content -LiteralPath $ocPath -Value '{"agent":{"explain":{"model":"custom/model","prompt":"custom prompt"}}}' -Encoding UTF8
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            $obj = Read-JsonObj $ocPath
            $obj.agent.explain.model | Should Be 'custom/model'
            $obj.agent.explain.prompt | Should Be 'custom prompt'
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            $obj = Read-JsonObj $ocPath
            $obj.agent.explain.model | Should Be 'custom/model'
            $obj.agent.explain.prompt | Should Be 'custom prompt'
            $obj.agent.explain.mode | Should BeNullOrEmpty
        }

        It 'keeps edits made after installation and preserves learning data on uninstall' {
            $sandbox = New-SandboxHome
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            $obj = @(Read-JsonObj $ocPath)[0]
            $obj.agent.explain.model = 'changed/after-install'
            Write-TutorJsonc -Path $ocPath -Value $obj
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            $statePath = Join-Path $sandbox '.config\opencode\learn\state.json'
            [IO.File]::WriteAllText($statePath, '{"lines":{"main":"learn"}}')
            (Invoke-Installer -Root $sandbox -Extra @('-Uninstall')).code | Should Be 0
            (Read-JsonObj $ocPath).agent.explain.model | Should Be 'changed/after-install'
            [IO.File]::ReadAllText($statePath) | Should Be '{"lines":{"main":"learn"}}'
        }

        It 'supports opencode.jsonc and preserves unchanged nested comments' {
            $sandbox = New-SandboxHome
            $ocPath = Join-Path $sandbox '.config\opencode\opencode.jsonc'
            [IO.File]::WriteAllText($ocPath, "{`n// agents`n`"agent`":{`"explain`":{`n// selected model`n`"model`":`"custom/model`",}},}")
            (Invoke-Installer -Root $sandbox).code | Should Be 0
            $text = [IO.File]::ReadAllText($ocPath)
            $text.Contains('// selected model') | Should Be $true
            (Read-JsonObj $ocPath).agent.explain.model | Should Be 'custom/model'
        }

        It 'dry run changes nothing' {
            $sandbox = New-SandboxHome
            $files = @(
                (Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'),
                (Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json'),
                (Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json'),
                (Join-Path $sandbox '.config\opencode\opencode.json')
            )
            $before = @($files | ForEach-Object { Get-FileHashHex -Path $_ })

            $r = Invoke-Installer -Root $sandbox -Extra @('-DryRun')
            $r.code | Should Be 0
            $r.out.Contains('[DRYRUN]') | Should Be $true

            $after = @($files | ForEach-Object { Get-FileHashHex -Path $_ })
            ($after -join ',') | Should Be ($before -join ',')
            (Test-Path -LiteralPath (Join-Path $sandbox '.config\opencode\learn')) | Should Be $false
        }
    }
}
