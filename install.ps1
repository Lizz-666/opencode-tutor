param(
    [switch]$WithPrewarm,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipSystemLevel,
    [string]$SandboxRoot = '',
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Continue'
$script:changedCount = 0
$script:skipCount = 0
$script:warnCount = 0

function Say { param([string]$m) Write-Output $m }
function SayChange { param([string]$m) $script:changedCount++; Write-Output ('[CHANGE] ' + $m) }
function SaySkip { param([string]$m) $script:skipCount++; Write-Output ('[SKIP] ' + $m) }
function SayWarn { param([string]$m) $script:warnCount++; Write-Output ('[WARN] ' + $m) }
function SayDry { param([string]$m) Write-Output ('[DRYRUN] ' + $m) }

$userProfile = if ($SandboxRoot) { $SandboxRoot } else { $env:USERPROFILE }
if ($SandboxRoot -and $env:USERPROFILE -and ($SandboxRoot.TrimEnd('\') -eq $env:USERPROFILE.TrimEnd('\'))) {
    Say '[WARN] SandboxRoot 不能等于真实用户目录（防止误改真实配置），已中止'
    exit 1
}
$appData = if ($SandboxRoot) { Join-Path $SandboxRoot 'AppData\Roaming' } else { $env:APPDATA }
$opencodeDir = Join-Path $userProfile '.config\opencode'
if (-not $InstallDir) { $InstallDir = Join-Path $opencodeDir 'learn' }
$opencodeJsonPath = Join-Path $opencodeDir 'opencode.json'
$vscodeUserDir = Join-Path $appData 'Code\User'
$keybindingsPath = Join-Path $vscodeUserDir 'keybindings.json'
$tasksPath = Join-Path $vscodeUserDir 'tasks.json'
$settingsPath = Join-Path $vscodeUserDir 'settings.json'
$scriptsSrc = Join-Path $PSScriptRoot 'scripts'
$agentExamplePath = Join-Path $PSScriptRoot 'config\opencode.agent.example.json'

$taskLabel = 'opencode: 讲解选区'
$scheduledTaskName = 'OpencodeLearnServer'

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $true; exists = $false; obj = $null } }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{ ok = $true; exists = $true; obj = $null } }
        $obj = $raw | ConvertFrom-Json
        return @{ ok = $true; exists = $true; obj = $obj }
    } catch {
        return @{ ok = $false; exists = $true; obj = $null }
    }
}

function Backup-FileIfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        if ($DryRun) { SayDry ('备份 ' + $Path); return }
        $bak = $Path + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmss')
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        Say ('[BACKUP] ' + $bak)
    }
}

function Write-JsonFile {
    param([string]$Path, $Obj, [switch]$IsArray)
    if ($DryRun) { SayDry ('写入 ' + $Path); return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = if ($IsArray) { ConvertTo-Json -InputObject @($Obj) -Depth 20 } else { ConvertTo-Json -InputObject $Obj -Depth 20 }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $true))
    Say ('[WRITE] ' + $Path)
}

function To-Canonical {
    param($Obj, [switch]$IsArray)
    if ($null -eq $Obj) { return '' }
    if ($IsArray) { return (ConvertTo-Json -InputObject @($Obj) -Depth 20 -Compress) }
    return (ConvertTo-Json -InputObject $Obj -Depth 20 -Compress)
}

function New-OurKeybindingEntry {
    param([string]$Url)
    return @{
        key = 'alt+l'
        command = 'runCommands'
        when = 'terminalFocus'
        args = @{
            commands = @(
                @{ command = 'workbench.action.tasks.runTask'; args = $taskLabel },
                @{ command = 'simpleBrowser.api.open'; args = @($Url, @{ preserveFocus = $true; viewColumn = 2 }) }
            )
        }
    }
}

function New-OurTaskEntry {
    return @{
        label = $taskLabel
        type = 'shell'
        command = 'powershell'
        args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $InstallDir 'explain.ps1'))
        presentation = @{ echo = $false; reveal = 'never'; focus = $false; panel = 'dedicated'; group = 'learn-while-aicoding'; clear = $true }
        problemMatcher = @()
    }
}

function Test-EntryIsOurs {
    param($Entry)
    if ($Entry.key -ne 'alt+l' -or $Entry.command -ne 'runCommands' -or -not $Entry.args) { return $false }
    foreach ($c in @($Entry.args.commands)) {
        if ($c -isnot [string] -and $c.command -eq 'workbench.action.tasks.runTask' -and $c.args -eq $taskLabel) { return $true }
    }
    return $false
}

function Get-EntryUrl {
    param($Entry)
    if (-not $Entry.args) { return '' }
    foreach ($c in @($Entry.args.commands)) {
        if ($c -isnot [string] -and $c.command -eq 'simpleBrowser.api.open' -and @($c.args).Count -gt 0) { return [string]$c.args[0] }
    }
    return ''
}

function Install-All {
    Say '==== learn-while-aicoding 一键安装 ===='
    if ($DryRun) { Say '(DryRun：只显示计划，不修改任何文件)' }
    if ($SandboxRoot) { Say ('沙箱模式: ' + $SandboxRoot) }

    if (-not (Test-Path -LiteralPath $scriptsSrc)) {
        SayWarn ('找不到 scripts 目录: ' + $scriptsSrc + '（请在仓库根目录运行 install.ps1）')
        exit 1
    }

    Say '--- 1/8 复制脚本到安装目录 ---'
    if ($DryRun) {
        SayDry ('复制 explain.ps1 / explain.lib.ps1 / prewarm.ps1 / doctor.ps1 -> ' + $InstallDir)
    } else {
        if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        foreach ($n in @('explain.ps1', 'explain.lib.ps1', 'prewarm.ps1', 'doctor.ps1')) {
            $src = Join-Path $scriptsSrc $n
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $n) -Force }
        }
        SayChange ('脚本已就位: ' + $InstallDir)
    }
    $cfgPath = Join-Path $InstallDir 'config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        SaySkip 'config.json 已存在，保持不动'
    } else {
        Write-JsonFile -Path $cfgPath -Obj @{ port = 4399; backgroundMaxChars = 60000; model = '' }
        SayChange '已创建默认 config.json'
    }

    Say '--- 2/8 环境变量（拖选即复制）---'
    if ($SkipSystemLevel) {
        SaySkip '环境变量（SkipSystemLevel 已跳过）'
    } else {
        $cur = [Environment]::GetEnvironmentVariable('OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT', 'User')
        if ($cur -eq '0') {
            SaySkip '环境变量已是 0'
        } elseif ($DryRun) {
            SayDry 'setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0'
        } else {
            setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0 | Out-Null
            SayChange '环境变量已设置（需完全重启 VS Code 生效）'
        }
    }

    Say '--- 3/8 合并 explain agent 到 opencode.json ---'
    $agentBlock = $null
    $ag = Read-JsonFile -Path $agentExamplePath
    if ($ag.ok -and $ag.obj) { $agentBlock = $ag.obj.agent.explain }
    if ($null -eq $agentBlock) {
        SayWarn ('读不到 agent 模板: ' + $agentExamplePath + '（跳过）')
    } else {
        $cur = Read-JsonFile -Path $opencodeJsonPath
        if (-not $cur.ok) {
            SayWarn 'opencode.json 解析失败（可能含注释），跳过 agent 合并；请手动合并 config/opencode.agent.example.json'
        } else {
            if ($cur.exists -and $cur.obj) { $obj = $cur.obj } else { $obj = New-Object PSObject }
            $before = To-Canonical -Obj $obj
            if (-not $obj.PSObject.Properties['agent']) { $obj | Add-Member -NotePropertyName agent -NotePropertyValue (New-Object PSObject) -Force }
            $obj.agent | Add-Member -NotePropertyName explain -NotePropertyValue $agentBlock -Force
            $after = To-Canonical -Obj $obj
            if ($before -eq $after) {
                SaySkip 'agent.explain 已是最新'
            } else {
                Backup-FileIfExists -Path $opencodeJsonPath
                Write-JsonFile -Path $opencodeJsonPath -Obj $obj
                SayChange 'agent.explain 已合并'
            }
        }
    }

    Say '--- 4/8 合并 keybindings.json ---'
    $kb = Read-JsonFile -Path $keybindingsPath
    if (-not $kb.ok) {
        SayWarn 'keybindings.json 解析失败（可能含注释），跳过；请手动合并 config/keybindings.example.json'
    } else {
        $arr = @()
        if ($kb.exists -and $kb.obj) { $arr = @($kb.obj) }
        $oursIdx = -1
        $existingUrl = ''
        for ($i = 0; $i -lt $arr.Count; $i++) {
            if (Test-EntryIsOurs -Entry $arr[$i]) {
                $oursIdx = $i
                $existingUrl = Get-EntryUrl -Entry $arr[$i]
            }
        }
        $serverKey = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('http://127.0.0.1:4399')).Replace('+', '-').Replace('/', '_').TrimEnd('=')
        $url = 'http://127.0.0.1:4399/server/' + $serverKey + '/session/PLACEHOLDER'
        if ($existingUrl -and -not $existingUrl.Contains('PLACEHOLDER')) { $url = $existingUrl }
        $entry = New-OurKeybindingEntry -Url $url
        if ($oursIdx -ge 0) {
            if ((To-Canonical -Obj $arr[$oursIdx]) -eq (To-Canonical -Obj $entry)) {
                SaySkip 'alt+l 条目已是最新'
            } else {
                $arr[$oursIdx] = $entry
                Backup-FileIfExists -Path $keybindingsPath
                Write-JsonFile -Path $keybindingsPath -Obj $arr -IsArray
                SayChange 'alt+l 条目已更新'
            }
        } else {
            $arr += $entry
            Backup-FileIfExists -Path $keybindingsPath
            Write-JsonFile -Path $keybindingsPath -Obj $arr -IsArray
            SayChange 'alt+l 条目已添加'
        }
    }

    Say '--- 5/8 合并 tasks.json ---'
    $t = Read-JsonFile -Path $tasksPath
    if (-not $t.ok) {
        SayWarn 'tasks.json 解析失败，跳过；请手动合并 config/tasks.example.json'
    } else {
        if ($t.exists -and $t.obj) { $tobj = $t.obj } else { $tobj = New-Object PSObject }
        if (-not $tobj.PSObject.Properties['version']) { $tobj | Add-Member -NotePropertyName version -NotePropertyValue '2.0.0' -Force }
        if (-not $tobj.PSObject.Properties['tasks']) { $tobj | Add-Member -NotePropertyName tasks -NotePropertyValue @() -Force }
        $tasks = @($tobj.tasks)
        $idx = -1
        for ($i = 0; $i -lt $tasks.Count; $i++) {
            if ($tasks[$i].label -eq $taskLabel) { $idx = $i }
        }
        $entry = New-OurTaskEntry
        $before = To-Canonical -Obj $tobj
        if ($idx -ge 0) {
            $tasks[$idx] = $entry
        } else {
            $tasks += $entry
        }
        $tobj.tasks = $tasks
        $after = To-Canonical -Obj $tobj
        if ($before -eq $after) {
            SaySkip '任务条目已是最新'
        } else {
            Backup-FileIfExists -Path $tasksPath
            Write-JsonFile -Path $tasksPath -Obj $tobj
            SayChange '任务条目已写入'
        }
    }

    Say '--- 6/8 合并 settings.json（copyOnSelection）---'
    $s = Read-JsonFile -Path $settingsPath
    if (-not $s.ok) {
        SayWarn 'settings.json 解析失败（可能含注释），跳过；请手动加 "terminal.integrated.copyOnSelection": true'
    } else {
        if ($s.exists -and $s.obj) { $sobj = $s.obj } else { $sobj = New-Object PSObject }
        $before = To-Canonical -Obj $sobj
        $sobj | Add-Member -NotePropertyName 'terminal.integrated.copyOnSelection' -NotePropertyValue $true -Force
        $after = To-Canonical -Obj $sobj
        if ($before -eq $after) {
            SaySkip 'copyOnSelection 已是 true'
        } else {
            Backup-FileIfExists -Path $settingsPath
            Write-JsonFile -Path $settingsPath -Obj $sobj
            SayChange 'copyOnSelection 已写入'
        }
    }

    Say '--- 7/8 登录自启（可选）---'
    if (-not $WithPrewarm) {
        SaySkip '默认不注册登录自启（后台服务会在首次 Alt+L 时自动拉起；需要常驻可加 -WithPrewarm）'
    } elseif ($SkipSystemLevel) {
        SaySkip '计划任务（SkipSystemLevel 已跳过）'
    } elseif ($DryRun) {
        SayDry ('注册登录计划任务 ' + $scheduledTaskName)
    } else {
        try {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'prewarm.ps1') + '"')
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:USERNAME"
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $scheduledTaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
            SayChange '登录计划任务已注册'
        } catch {
            SayWarn ('计划任务注册失败: ' + $_.Exception.Message)
        }
    }

    Say '--- 8/8 体检 ---'
    if ($SandboxRoot) {
        SaySkip 'doctor 体检（沙箱模式跳过）'
    } elseif ($DryRun) {
        SayDry '运行 doctor.ps1'
    } else {
        $doctor = Join-Path $InstallDir 'doctor.ps1'
        if (Test-Path -LiteralPath $doctor) { & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor }
    }

    Say ''
    Say '==== 安装完成 ===='
    Say ('变更 ' + $script:changedCount + ' 项，跳过 ' + $script:skipCount + ' 项，警告 ' + $script:warnCount + ' 项')
    Say ''
    Say '接下来请完成两步（一次性）：'
    Say '  1. 完全关闭并重开 VS Code（环境变量与新配置生效）'
    Say '  2. Ctrl+Shift+P 执行 "Toggle Do Not Disturb Mode"（防止通知遮挡讲解窗口）'
    Say ''
    Say '使用：普通拖选不懂的内容 -> 按 Alt+L'
}

function Uninstall-All {
    Say '==== learn-while-aicoding 卸载 ===='
    if ($DryRun) { Say '(DryRun：只显示计划，不修改任何文件)' }

    if (-not $Force -and -not $DryRun) {
        $ans = Read-Host '确认卸载（移除键位/任务/agent 条目与脚本目录）？输入 y 继续'
        if ($ans -ne 'y') { Say '已取消'; exit 0 }
    }

    Say '--- 1/6 移除 keybindings 条目 ---'
    $kb = Read-JsonFile -Path $keybindingsPath
    if (-not $kb.ok) {
        SayWarn 'keybindings.json 解析失败，跳过（请手动删除 alt+l 条目）'
    } else {
        $arr = @()
        if ($kb.exists -and $kb.obj) { $arr = @($kb.obj) }
        $kept = @($arr | Where-Object { -not (Test-EntryIsOurs -Entry $_) })
        if ($kept.Count -eq $arr.Count) {
            SaySkip '未找到我们的 alt+l 条目'
        } else {
            Backup-FileIfExists -Path $keybindingsPath
            Write-JsonFile -Path $keybindingsPath -Obj $kept -IsArray
            SayChange 'alt+l 条目已移除'
        }
    }

    Say '--- 2/6 移除 tasks 条目 ---'
    $t = Read-JsonFile -Path $tasksPath
    if (-not $t.ok) {
        SayWarn 'tasks.json 解析失败，跳过（请手动删除任务 ' + $taskLabel + '）'
    } elseif ($t.exists -and $t.obj) {
        $tobj = $t.obj
        $tasks = @($tobj.tasks)
        $kept = @($tasks | Where-Object { $_.label -ne $taskLabel })
        if ($kept.Count -eq $tasks.Count) {
            SaySkip '未找到我们的任务条目'
        } else {
            $tobj.tasks = $kept
            Backup-FileIfExists -Path $tasksPath
            Write-JsonFile -Path $tasksPath -Obj $tobj
            SayChange '任务条目已移除'
        }
    } else {
        SaySkip 'tasks.json 不存在'
    }

    Say '--- 3/6 移除 opencode.json 的 explain agent ---'
    $cur = Read-JsonFile -Path $opencodeJsonPath
    if (-not $cur.ok) {
        SayWarn 'opencode.json 解析失败，跳过（请手动删除 agent.explain）'
    } elseif ($cur.exists -and $cur.obj -and $cur.obj.PSObject.Properties['agent'] -and $cur.obj.agent.PSObject.Properties['explain']) {
        $cur.obj.agent.PSObject.Properties.Remove('explain')
        Backup-FileIfExists -Path $opencodeJsonPath
        Write-JsonFile -Path $opencodeJsonPath -Obj $cur.obj
        SayChange 'agent.explain 已移除'
    } else {
        SaySkip '未找到 agent.explain'
    }

    Say '--- 4/6 移除登录计划任务 ---'
    if ($SkipSystemLevel) {
        SaySkip '计划任务（SkipSystemLevel 已跳过）'
    } else {
        $existing = Get-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue
        if (-not $existing) {
            SaySkip '计划任务不存在'
        } elseif ($DryRun) {
            SayDry ('删除计划任务 ' + $scheduledTaskName)
        } else {
            Unregister-ScheduledTask -TaskName $scheduledTaskName -Confirm:$false
            SayChange '计划任务已删除'
        }
    }

    Say '--- 5/6 删除安装目录 ---'
    if (Test-Path -LiteralPath $InstallDir) {
        if ($DryRun) {
            SayDry ('删除目录 ' + $InstallDir)
        } else {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            SayChange ('已删除 ' + $InstallDir + '（服务端学习会话保留）')
        }
    } else {
        SaySkip '安装目录不存在'
    }

    Say '--- 6/6 残留手动项（有意保留，避免破坏你已依赖的行为）---'
    Say '  - 环境变量: 如需删除执行  REG delete "HKCU\Environment" /F /V OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT'
    Say '  - settings.json: 如需删除手动去掉 "terminal.integrated.copyOnSelection"'
    Say ''
    Say '==== 卸载完成 ===='
}

if ($Uninstall) { Uninstall-All } else { Install-All }
