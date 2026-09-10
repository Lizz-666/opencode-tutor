$installScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
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
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
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
            @($kb | Where-Object { $_.key -eq 'alt+l' }).Count | Should Be 1

            $tasksPath = Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json'
            $tasks = Read-JsonObj -Path $tasksPath
            @($tasks.tasks | Where-Object { $_.label -eq 'user task' }).Count | Should Be 1
            @($tasks.tasks | Where-Object { $_.label -eq 'opencode: 讲解选区' }).Count | Should Be 1

            $settingsPath = Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json'
            $settings = Read-JsonObj -Path $settingsPath
            $settings.'editor.fontSize' | Should Be 14
            $settings.'terminal.integrated.copyOnSelection' | Should Be $true

            $ocPath = Join-Path $sandbox '.config\opencode\opencode.json'
            $oc = Read-JsonObj -Path $ocPath
            $oc.model | Should Be 'some/model'
            $oc.agent.other.mode | Should Be 'primary'
            $oc.agent.explain.mode | Should Be 'subagent'

            (Test-Path -LiteralPath (Join-Path $sandbox '.config\opencode\learn\explain.ps1')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $sandbox '.config\opencode\learn\config.json')) | Should Be $true
            (Get-BackupCount -Root $sandbox) -gt 0 | Should Be $true
        }

        It 'is idempotent: second run changes nothing' {
            $sandbox = $script:sandboxes[-1]
            $files = @(
                (Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'),
                (Join-Path $sandbox 'AppData\Roaming\Code\User\tasks.json'),
                (Join-Path $sandbox 'AppData\Roaming\Code\User\settings.json'),
                (Join-Path $sandbox '.config\opencode\opencode.json')
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
            ($raw2.Trim() -match '^\[\s*\]$') | Should Be $true
            $kb2 = @(Read-JsonObj -Path $kbPath)
            @($kb2 | Where-Object { $_ -and $_.key -eq 'alt+l' }).Count | Should Be 0
        }

        It 'skips files with comments (JSONC) without touching them' {
            $sandbox = New-SandboxHome
            $kbPath = Join-Path $sandbox 'AppData\Roaming\Code\User\keybindings.json'
            Set-Content -LiteralPath $kbPath -Value "// user comment`n[]" -Encoding UTF8
            $hashBefore = Get-FileHashHex -Path $kbPath

            $r = Invoke-Installer -Root $sandbox
            $r.code | Should Be 0
            $r.out.Contains('keybindings') | Should Be $true
            (Get-FileHashHex -Path $kbPath) | Should Be $hashBefore

            $r2 = Invoke-Installer -Root $sandbox -Extra @('-Uninstall')
            $r2.code | Should Be 0
            (Get-FileHashHex -Path $kbPath) | Should Be $hashBefore
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
