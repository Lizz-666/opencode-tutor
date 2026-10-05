param(
    [switch]$WithPrewarm,
    [switch]$DisablePrewarm,
    [switch]$ResetAgent,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipSystemLevel,
    [string]$SandboxRoot = '',
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\jsonc.ps1')
$script:changedCount = 0
$script:skipCount = 0
$script:warnCount = 0

function Say { param([string]$m) Write-Output $m }
function SayChange { param([string]$m) $script:changedCount++; Write-Output ('[CHANGE] ' + $m) }
function SaySkip { param([string]$m) $script:skipCount++; Write-Output ('[SKIP] ' + $m) }
function SayWarn { param([string]$m) $script:warnCount++; Write-Output ('[WARN] ' + $m) }
function SayDry { param([string]$m) Write-Output ('[DRYRUN] ' + $m) }

if ($SandboxRoot) { $SkipSystemLevel = $true }
$userProfile = if ($SandboxRoot) { $SandboxRoot } else { $env:USERPROFILE }
if ($SandboxRoot -and $env:USERPROFILE -and ([IO.Path]::GetFullPath($SandboxRoot).TrimEnd('\') -eq [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\'))) {
    Say '[WARN] SandboxRoot 不能等于真实用户目录（防止误改真实配置），已中止'
    exit 1
}
$appData = if ($SandboxRoot) { Join-Path $SandboxRoot 'AppData\Roaming' } else { $env:APPDATA }
$opencodeDir = Join-Path $userProfile '.config\opencode'
if (-not $InstallDir) { $InstallDir = Join-Path $opencodeDir 'learn' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if ($InstallDir.TrimEnd('\') -eq [IO.Path]::GetPathRoot($InstallDir).TrimEnd('\') -or $InstallDir.TrimEnd('\') -eq [IO.Path]::GetFullPath($userProfile).TrimEnd('\')) { throw 'InstallDir 不能是磁盘根目录或用户目录' }
$opencodeJsonPath = Join-Path $opencodeDir 'opencode.json'
if (Test-Path -LiteralPath (Join-Path $opencodeDir 'opencode.jsonc')) { $opencodeJsonPath = Join-Path $opencodeDir 'opencode.jsonc' }
$vscodeUserDir = Join-Path $appData 'Code\User'
$keybindingsPath = Join-Path $vscodeUserDir 'keybindings.json'
$tasksPath = Join-Path $vscodeUserDir 'tasks.json'
$settingsPath = Join-Path $vscodeUserDir 'settings.json'
$scriptsSrc = Join-Path $PSScriptRoot 'scripts'
$agentExamplePath = Join-Path $PSScriptRoot 'config\opencode.agent.example.json'
$extensionSrc = Join-Path $PSScriptRoot 'extension'
$extensionVersion = ''
try {
    $extManifest = Get-Content -LiteralPath (Join-Path $extensionSrc 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($extManifest.version) { $extensionVersion = [string]$extManifest.version }
} catch {}
$extensionDir = Join-Path $userProfile '.vscode\extensions'
$extensionDest = if ($extensionVersion) { Join-Path $extensionDir ('lizz666.opencode-tutor-panel-' + $extensionVersion) } else { '' }

$taskLabel = 'opencode: 讲解选区'
$scheduledTaskName = 'OpencodeLearnServer'

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $true; exists = $false; obj = $null } }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{ ok = $true; exists = $true; obj = $null } }
        $obj = ConvertFrom-TutorJsonc -Text $raw
        return @{ ok = $true; exists = $true; obj = $obj }
    } catch {
        return @{ ok = $false; exists = $true; obj = $null }
    }
}

function Backup-FileIfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        if ($DryRun) { SayDry ('备份 ' + $Path); return }
        $bak = $Path + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
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
    $value = if ($IsArray) { ,@($Obj) } else { $Obj }
    Write-TutorJsonc -Path $Path -Value $value
    Say ('[WRITE] ' + $Path)
}

function To-Canonical {
    param($Obj, [switch]$IsArray)
    if ($null -eq $Obj) { return '' }
    if ($IsArray) { return (ConvertTo-Json -InputObject @($Obj) -Depth 20 -Compress) }
    return (ConvertTo-Json -InputObject $Obj -Depth 20 -Compress)
}

function New-OurKeybindingEntry {
    return @{
        key = 'alt+l'
        command = 'opencodeTutor.open'
        when = 'terminalFocus'
    }
}

function Test-EntryIsOurs {
    param($Entry)
    if ($Entry.key -ne 'alt+l') { return $false }
    if ($Entry.command -eq 'opencodeTutor.open') { return $true }
    if ($Entry.command -eq 'runCommands' -and $Entry.args) {
        foreach ($c in @($Entry.args.commands)) {
            if ($c -isnot [string] -and $c.command -eq 'workbench.action.tasks.runTask' -and $c.args -eq $taskLabel) { return $true }
        }
    }
    return $false
}

function Test-ExtensionCurrent {
    if (-not (Test-Path -LiteralPath $extensionDest)) { return $false }
    foreach ($n in @('package.json', 'extension.js', 'api.js')) {
        $src = Join-Path $extensionSrc $n
        $dst = Join-Path $extensionDest $n
        if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $dst)) { return $false }
        if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash) { return $false }
    }
    return $true
}

function Copy-ObjectValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    # A wrapper preserves empty and single-element arrays through the PS pipeline.
    $copy = ConvertFrom-Json -InputObject ('{"value":' + (ConvertTo-Json -InputObject $Value -Depth 30) + '}')
    return ,$copy.value
}

function Merge-MissingFields {
    param($Target, $Defaults)
    foreach ($prop in $Defaults.PSObject.Properties) {
        if (-not $Target.PSObject.Properties[$prop.Name]) {
            $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue (Copy-ObjectValue $prop.Value)
        } elseif ($Target.($prop.Name) -is [pscustomobject] -and $prop.Value -is [pscustomobject]) {
            Merge-MissingFields -Target $Target.($prop.Name) -Defaults $prop.Value
        }
    }
}

function Remember-NewManagedFields {
    param($Expected, $BeforeUpgrade, $AfterUpgrade)
    foreach ($prop in $AfterUpgrade.PSObject.Properties) {
        $prior = $null
        if ($BeforeUpgrade) { $prior = $BeforeUpgrade.PSObject.Properties[$prop.Name] }
        if (-not $prior) {
            $Expected | Add-Member -NotePropertyName $prop.Name -NotePropertyValue (Copy-ObjectValue $prop.Value) -Force
        } elseif ($prop.Value -is [pscustomobject] -and $prior.Value -is [pscustomobject]) {
            if (-not $Expected.PSObject.Properties[$prop.Name]) { $Expected | Add-Member -NotePropertyName $prop.Name -NotePropertyValue ([pscustomobject]@{}) }
            Remember-NewManagedFields $Expected.($prop.Name) $prior.Value $prop.Value
        }
    }
}

function Get-RemovedFieldRecords {
    param($Before, $After, [string[]]$Path = @())
    if ($Before -isnot [pscustomobject] -or $After -isnot [pscustomobject]) { return }
    foreach ($prop in $Before.PSObject.Properties) {
        $next = $After.PSObject.Properties[$prop.Name]
        $fieldPath = @($Path) + @($prop.Name)
        if (-not $next) {
            [pscustomobject]@{ path = $fieldPath; value = (Copy-ObjectValue $prop.Value) }
        } elseif ($prop.Value -is [pscustomobject] -and $next.Value -is [pscustomobject]) {
            Get-RemovedFieldRecords -Before $prop.Value -After $next.Value -Path $fieldPath
        }
    }
}

function Restore-RemovedFields {
    param($Current, $Records)
    foreach ($record in @($Records)) {
        if (-not $record -or -not $record.path) { continue }
        $path = @($record.path)
        $parent = $Current
        for ($i = 0; $i -lt $path.Count - 1; $i++) {
            $prop = $parent.PSObject.Properties[$path[$i]]
            # A removed or replaced parent is a later user edit; leave it alone.
            if (-not $prop -or $prop.Value -isnot [pscustomobject]) { $parent = $null; break }
            $parent = $prop.Value
        }
        if ($parent -is [pscustomobject] -and -not $parent.PSObject.Properties[$path[-1]]) {
            $parent | Add-Member -NotePropertyName $path[-1] -NotePropertyValue (Copy-ObjectValue $record.value)
        }
    }
}

function Restore-ManagedFields {
    param($Current, $Before, $Installed)
    foreach ($prop in @($Installed.PSObject.Properties)) {
        $name = $prop.Name
        if (-not $Current.PSObject.Properties[$name]) { continue }
        $prior = $null
        if ($Before) { $prior = $Before.PSObject.Properties[$name] }
        if ($prop.Value -is [pscustomobject] -and $Current.$name -is [pscustomobject]) {
            $old = $null; if ($prior) { $old = $prior.Value }
            Restore-ManagedFields -Current $Current.$name -Before $old -Installed $prop.Value
            if (-not $prior -and @($Current.$name.PSObject.Properties).Count -eq 0) { $Current.PSObject.Properties.Remove($name) }
        } elseif ((To-Canonical $Current.$name) -eq (To-Canonical $prop.Value)) {
            if ($prior) { $Current.$name = Copy-ObjectValue $prior.Value }
            else { $Current.PSObject.Properties.Remove($name) }
        }
    }
}

function Remove-OwnedDirectory {
    param([string]$Path, [string]$Parent)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw ('Unsafe removal path: ' + $full) }
    if ((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to remove a linked directory' }
    Remove-Item -LiteralPath $full -Recurse -Force
}

function Save-InstallState {
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        Write-TutorJsonc -Path $script:installStatePath -Value $script:installState
    }
}

function Build-HiddenLauncher {
    $source = Join-Path $InstallDir 'HiddenLauncher.cs'
    $exe = Join-Path $InstallDir 'prewarm-launcher.exe'
    $hashFile = $exe + '.sha256'
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $hashFile) -and ([IO.File]::ReadAllText($hashFile).Trim() -eq $hash)) { return $exe }
    $tmpExe = Join-Path $InstallDir ('launcher-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
        Add-Type -Path $source -OutputAssembly $tmpExe -OutputType WindowsApplication
        Copy-Item -LiteralPath $tmpExe -Destination $exe -Force
        [IO.File]::WriteAllText($hashFile, $hash)
    } finally { if (Test-Path -LiteralPath $tmpExe) { Remove-Item -LiteralPath $tmpExe -Force } }
    return $exe
}

$script:installStatePath = Join-Path $InstallDir 'install-state.json'
$saved = Read-JsonFile $script:installStatePath
if (-not $saved.ok) { throw 'install-state.json 损坏，已停止安装，避免覆盖配置记录。' }
$script:installState = if ($saved.obj) { $saved.obj } else { [pscustomobject]@{ version = 1 } }
function Remember-Value {
    param([string]$Name, $Value)
    if (-not $script:installState.PSObject.Properties[$Name]) {
        $script:installState | Add-Member -NotePropertyName $Name -NotePropertyValue (Copy-ObjectValue $Value)
    }
}

function Install-All {
    Say '==== opencode-tutor 一键安装 ===='
    if ($DryRun) { Say '(DryRun：只显示计划，不修改任何文件)' }
    if ($SandboxRoot) { Say ('沙箱模式: ' + $SandboxRoot) }

    if (-not (Test-Path -LiteralPath $scriptsSrc)) {
        SayWarn ('找不到 scripts 目录: ' + $scriptsSrc + '（请在仓库根目录运行 install.ps1）')
        exit 1
    }

    Say '--- 1/9 复制脚本到安装目录 ---'
    if ($DryRun) {
        SayDry ('复制 explain.ps1 / explain.lib.ps1 / prewarm.ps1 / doctor.ps1 -> ' + $InstallDir)
    } else {
        if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        foreach ($n in @('explain.ps1', 'explain.lib.ps1', 'context.ps1', 'prewarm.ps1', 'doctor.ps1', 'jsonc.ps1', 'HiddenLauncher.cs')) {
            $src = Join-Path $scriptsSrc $n
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $n) -Force }
        }
        SayChange ('脚本已就位: ' + $InstallDir)
    }
    $cfgPath = Join-Path $InstallDir 'config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        SaySkip 'config.json 已存在，保持不动'
    } else {
        Write-JsonFile -Path $cfgPath -Obj @{ port = 4399; backgroundMaxChars = 12000; model = '' }
        SayChange '已创建默认 config.json'
    }

    Say '--- 2/9 环境变量（拖选即复制）---'
    if ($SkipSystemLevel) {
        SaySkip '环境变量（SkipSystemLevel 已跳过）'
    } else {
        $cur = [Environment]::GetEnvironmentVariable('OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT', 'User')
        Remember-Value 'copyOnSelectEnvironmentBefore' $cur
        Save-InstallState
        if ($cur -eq '0') {
            SaySkip '环境变量已是 0'
        } elseif ($DryRun) {
            SayDry 'setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0'
        } else {
            setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0 | Out-Null
            SayChange '环境变量已设置（需完全重启 VS Code 生效）'
        }
    }

    Say '--- 3/9 合并 explain agent 到 opencode.json ---'
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
            Remember-Value 'agentBefore' $obj.agent.explain
            Save-InstallState
            $beforeUpgrade = Copy-ObjectValue $obj.agent.explain
            if (-not $script:installState.PSObject.Properties['agentRemoved']) {
                # Older install records stored only snapshots; retain their deleted fields.
                $removed = @(Get-RemovedFieldRecords $script:installState.agentBefore $script:installState.agentInstalled)
                $script:installState | Add-Member -NotePropertyName agentRemoved -NotePropertyValue $removed
            }
            if ($ResetAgent) {
                $removed = @($script:installState.agentRemoved)
                foreach ($record in @(Get-RemovedFieldRecords $beforeUpgrade $agentBlock)) {
                    $key = To-Canonical $record.path -IsArray
                    $removed = @($removed | Where-Object { (To-Canonical $_.path -IsArray) -ne $key }) + @($record)
                }
                $script:installState.agentRemoved = $removed
            }
            if ($ResetAgent -or -not $obj.agent.PSObject.Properties['explain']) {
                $obj.agent | Add-Member -NotePropertyName explain -NotePropertyValue $agentBlock -Force
            } elseif ($obj.agent.explain -is [pscustomobject]) {
                Merge-MissingFields -Target $obj.agent.explain -Defaults $agentBlock
            } else { throw 'agent.explain 必须是对象，未修改现有配置。' }
            if ($ResetAgent -or -not $script:installState.PSObject.Properties['agentInstalled']) {
                $script:installState | Add-Member -NotePropertyName agentInstalled -NotePropertyValue (Copy-ObjectValue $obj.agent.explain) -Force
            } else { Remember-NewManagedFields $script:installState.agentInstalled $beforeUpgrade $obj.agent.explain }
            Save-InstallState
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

    Say '--- 4/9 合并 keybindings.json（单命令形态）---'
    $kb = Read-JsonFile -Path $keybindingsPath
    if (-not $kb.ok) {
        SayWarn 'keybindings.json 解析失败（可能含注释），跳过；请手动加 { "key": "alt+l", "command": "opencodeTutor.open", "when": "terminalFocus" }'
    } else {
        $arr = @()
        if ($kb.exists -and $kb.obj) { $arr = @($kb.obj) }
        $kept = @()
        $found = $false
        for ($i = 0; $i -lt $arr.Count; $i++) {
            if (Test-EntryIsOurs -Entry $arr[$i]) {
                if (-not $found) { $kept += (New-OurKeybindingEntry); $found = $true }
            } else {
                $kept += $arr[$i]
            }
        }
        if (-not $found) { $kept += (New-OurKeybindingEntry) }
        if ([TutorJsonc]::Equivalent((To-Canonical -Obj $arr -IsArray), (To-Canonical -Obj $kept -IsArray))) {
            SaySkip 'alt+l 条目已是最新'
        } else {
            Backup-FileIfExists -Path $keybindingsPath
            Write-JsonFile -Path $keybindingsPath -Obj $kept -IsArray
            SayChange 'alt+l 条目已写入（opencodeTutor.open；旧 runCommands 形态自动迁移）'
        }
    }

    Say '--- 5/9 清理遗留任务条目（升级迁移）---'
    $t = Read-JsonFile -Path $tasksPath
    if (-not $t.ok) {
        SayWarn ('tasks.json 解析失败，跳过（如有旧任务条目请手动删除 label 为 "' + $taskLabel + '" 的条目）')
    } elseif ($t.exists -and $t.obj -and $t.obj.PSObject.Properties['tasks']) {
        $tobj = $t.obj
        $tasks = @($tobj.tasks)
        $keptTasks = @($tasks | Where-Object { $_.label -ne $taskLabel })
        if ($keptTasks.Count -eq $tasks.Count) {
            SaySkip '无遗留任务条目'
        } else {
            $tobj.tasks = $keptTasks
            Backup-FileIfExists -Path $tasksPath
            Write-JsonFile -Path $tasksPath -Obj $tobj
            SayChange '遗留任务条目已移除（现由扩展直接执行脚本，不再依赖任务系统）'
        }
    } else {
        SaySkip '无遗留任务条目'
    }

    Say '--- 6/9 合并 settings.json（copyOnSelection）---'
    $s = Read-JsonFile -Path $settingsPath
    if (-not $s.ok) {
        SayWarn 'settings.json 解析失败（可能含注释），跳过；请手动加 "terminal.integrated.copyOnSelection": true'
    } else {
        if ($s.exists -and $s.obj) { $sobj = $s.obj } else { $sobj = New-Object PSObject }
        Remember-Value 'copyOnSelectionBefore' $sobj.'terminal.integrated.copyOnSelection'
        Remember-Value 'copyOnSelectionExisted' ([bool]$sobj.PSObject.Properties['terminal.integrated.copyOnSelection'])
        Save-InstallState
        $before = To-Canonical -Obj $sobj
        $sobj | Add-Member -NotePropertyName 'terminal.integrated.copyOnSelection' -NotePropertyValue $true -Force
        $patchRemoved = $false
        if ($sobj.PSObject.Properties['workbench.browser.newTabPlacement'] -and $sobj.'workbench.browser.newTabPlacement' -eq 'sideGroup') {
            $sobj.PSObject.Properties.Remove('workbench.browser.newTabPlacement')
            $patchRemoved = $true
        }
        $after = To-Canonical -Obj $sobj
        if ($before -eq $after) {
            SaySkip 'copyOnSelection 已是 true'
        } else {
            Backup-FileIfExists -Path $settingsPath
            Write-JsonFile -Path $settingsPath -Obj $sobj
            SayChange 'copyOnSelection 已写入'
            if ($patchRemoved) { Say '（已移除旧的 workbench.browser.newTabPlacement 补丁：面板现由扩展自带，不再需要）' }
        }
    }

    Say '--- 7/9 安装 VS Code 扩展（讲解面板）---'
    if (-not (Test-Path -LiteralPath (Join-Path $extensionSrc 'extension.js'))) {
        SayWarn ('找不到 extension 目录: ' + $extensionSrc + '（跳过；Alt+L 将不可用）')
    } elseif (-not $extensionVersion) {
        SayWarn ('读取扩展版本失败: ' + (Join-Path $extensionSrc 'package.json') + '（跳过扩展安装）')
    } elseif ($DryRun) {
        SayDry ('复制扩展 -> ' + $extensionDest)
    } elseif (Test-ExtensionCurrent) {
        SaySkip '扩展已是最新'
    } else {
        if (-not (Test-Path -LiteralPath $extensionDir)) { New-Item -ItemType Directory -Path $extensionDir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $extensionDest)) { New-Item -ItemType Directory -Path $extensionDest -Force | Out-Null }
        foreach ($n in @('package.json', 'extension.js', 'api.js')) {
            Copy-Item -LiteralPath (Join-Path $extensionSrc $n) -Destination (Join-Path $extensionDest $n) -Force
        }
        foreach ($old in @(Get-ChildItem -LiteralPath $extensionDir -Directory -Filter 'lizz666.opencode-tutor-panel-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne (Split-Path -Leaf $extensionDest) })) {
            Remove-OwnedDirectory -Path $old.FullName -Parent $extensionDir
            Say ('[CLEAN] 已移除旧版本扩展目录: ' + $old.Name)
        }
        SayChange ('扩展已安装: ' + $extensionDest + '（需 Reload Window 生效）')
    }

    Say '--- 8/9 登录自启（保留已有偏好，迁移无控制台入口）---'
    if ($SkipSystemLevel) {
        SaySkip '计划任务（SkipSystemLevel 已跳过）'
    } else {
        if ($WithPrewarm -and $DisablePrewarm) { throw 'WithPrewarm 和 DisablePrewarm 不能同时使用' }
        $existing = Get-ScheduledTask -TaskName $scheduledTaskName -ErrorAction SilentlyContinue
        if ($existing) {
            $owned = @($existing.Actions | Where-Object { $_.Arguments -like '*prewarm.ps1*' -or $_.Execute -eq (Join-Path $InstallDir 'prewarm-launcher.exe') })
            if ($owned.Count -eq 0) { throw '同名计划任务不属于本项目，未修改。' }
        }
        if ($DisablePrewarm) {
            if ($existing -and -not $DryRun) { $existing | Disable-ScheduledTask | Out-Null }
            Say '预热任务已禁用（DryRun 时仅预览）；快捷键仍可按需启动服务。'
        } elseif ($existing -or $WithPrewarm) {
            if ($DryRun) { SayDry '将预热任务迁移到 prewarm-launcher.exe，保留已有触发器与启停状态' }
            else {
                $launcher = Build-HiddenLauncher
                $action = New-ScheduledTaskAction -Execute $launcher -WorkingDirectory $InstallDir
                if ($existing) {
                    if ($existing.Actions.Execute -ne $launcher) {
                        Export-ScheduledTask -TaskName $scheduledTaskName | Set-Content -LiteralPath (Join-Path $InstallDir ('task-before-migration-' + (Get-Date -Format yyyyMMddHHmmssfff) + '.xml')) -Encoding Unicode
                        Set-ScheduledTask -TaskName $scheduledTaskName -Action $action | Out-Null
                        SayChange '旧任务已迁移到无控制台启动器'
                    } else { SaySkip '计划任务已使用无控制台启动器' }
                    if ($WithPrewarm) { Enable-ScheduledTask -TaskName $scheduledTaskName | Out-Null }
                } else {
                    $triggers = @((New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:USERNAME"),
                        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)))
                    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
                    Register-ScheduledTask -TaskName $scheduledTaskName -Action $action -Trigger $triggers -Settings $settings -Force | Out-Null
                    SayChange '无控制台预热任务已注册'
                }
            }
        } else { SaySkip '使用按需启动，不新建预热任务' }
    }

    Say '--- 9/9 体检 ---'
    if ($SandboxRoot) {
        SaySkip 'doctor 体检（沙箱模式跳过）'
    } elseif ($DryRun) {
        SayDry '运行 doctor.ps1'
    } else {
        $doctor = Join-Path $InstallDir 'doctor.ps1'
        if (Test-Path -LiteralPath $doctor) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor
            if ($LASTEXITCODE -ne 0) { SayWarn '程序已安装，体检仍有未通过项；请按体检提示处理。' }
        }
    }

    Say ''
    Say '==== 安装完成 ===='
    Say ('变更 ' + $script:changedCount + ' 项，跳过 ' + $script:skipCount + ' 项，警告 ' + $script:warnCount + ' 项')
    Say ''
    Say '接下来请完成两步（一次性）：'
    Say '  1. 让扩展生效：Ctrl+Shift+P -> "Developer: Reload Window"（首次安装建议完全重启 VS Code：环境变量也需重启生效）'
    Say '  2. Ctrl+Shift+P 执行 "Toggle Do Not Disturb Mode"（防止通知遮挡讲解窗口）'
    Say ''
    Say '使用：普通拖选不懂的内容 -> 按 Alt+L（讲解面板在编辑器右侧弹出）'
}

function Uninstall-All {
    Say '==== opencode-tutor 卸载 ===='
    if ($DryRun) { Say '(DryRun：只显示计划，不修改任何文件)' }

    if (-not $Force -and -not $DryRun) {
        $ans = Read-Host '确认卸载（移除键位/扩展/agent 条目与脚本目录）？输入 y 继续'
        if ($ans -ne 'y') { Say '已取消'; exit 0 }
    }

    Say '--- 1/7 移除 keybindings 条目 ---'
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

    Say '--- 2/7 移除遗留任务条目 ---'
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

    Say '--- 3/7 移除 opencode.json 的 explain agent ---'
    $cur = Read-JsonFile -Path $opencodeJsonPath
    if (-not $cur.ok) {
        SayWarn 'opencode.json 解析失败，跳过（请手动删除 agent.explain）'
    } elseif ($cur.exists -and $cur.obj -and $cur.obj.PSObject.Properties['agent'] -and $cur.obj.agent.PSObject.Properties['explain']) {
        if ($script:installState.PSObject.Properties['agentInstalled']) {
            $removed = if ($script:installState.PSObject.Properties['agentRemoved']) { @($script:installState.agentRemoved) }
                else { @(Get-RemovedFieldRecords $script:installState.agentBefore $script:installState.agentInstalled) }
            Restore-RemovedFields -Current $cur.obj.agent.explain -Records $removed
            Restore-ManagedFields -Current $cur.obj.agent.explain -Before $script:installState.agentBefore -Installed $script:installState.agentInstalled
            if (-not $script:installState.agentBefore -and @($cur.obj.agent.explain.PSObject.Properties).Count -eq 0) { $cur.obj.agent.PSObject.Properties.Remove('explain') }
            Backup-FileIfExists -Path $opencodeJsonPath
            Write-JsonFile -Path $opencodeJsonPath -Obj $cur.obj
            SayChange '已恢复本次安装管理的 agent 字段，保留用户修改'
        } else { SayWarn '缺少安装记录，保留现有 explain agent，请按需手动移除' }
    } else {
        SaySkip '未找到 agent.explain'
    }

    Say '--- 4/7 移除登录计划任务 ---'
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

    Say '--- 5/7 移除 VS Code 扩展 ---'
    if (Test-Path -LiteralPath $extensionDest) {
        if ($DryRun) {
            SayDry ('删除扩展目录 ' + $extensionDest)
        } else {
            Remove-OwnedDirectory -Path $extensionDest -Parent $extensionDir
            SayChange ('扩展已移除: ' + $extensionDest + '（重开窗口后生效）')
        }
    } else {
        SaySkip '扩展目录不存在'
    }

    Say '--- 6/7 恢复本工具修改的设置 ---'
    $s = Read-JsonFile -Path $settingsPath
    if ($s.ok -and $s.obj -and $script:installState.PSObject.Properties['copyOnSelectionExisted'] -and $s.obj.'terminal.integrated.copyOnSelection' -eq $true) {
        if ($script:installState.copyOnSelectionExisted) { $s.obj.'terminal.integrated.copyOnSelection' = $script:installState.copyOnSelectionBefore }
        else { $s.obj.PSObject.Properties.Remove('terminal.integrated.copyOnSelection') }
        Backup-FileIfExists $settingsPath
        Write-JsonFile -Path $settingsPath -Obj $s.obj
    }
    if (-not $SkipSystemLevel -and -not $DryRun -and $script:installState.PSObject.Properties['copyOnSelectEnvironmentBefore']) {
        if ([Environment]::GetEnvironmentVariable('OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT','User') -eq '0') {
            [Environment]::SetEnvironmentVariable('OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT', $script:installState.copyOnSelectEnvironmentBefore, 'User')
        }
    }
    Say '--- 7/7 移除程序文件，保留学习数据和备份 ---'
    if ($DryRun) { SayDry ('移除已安装程序文件: ' + $InstallDir) }
    elseif (Test-Path -LiteralPath $InstallDir) {
        foreach ($name in @('explain.ps1','explain.lib.ps1','context.ps1','prewarm.ps1','doctor.ps1','jsonc.ps1','HiddenLauncher.cs','prewarm-launcher.exe','prewarm-launcher.exe.sha256','install-state.json')) {
            $file = Join-Path $InstallDir $name
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
        $cfg = Join-Path $InstallDir 'config.json'
        if ((Test-Path -LiteralPath $cfg) -and -not (Test-Path -LiteralPath (Join-Path $InstallDir 'state.json'))) {
            $value = Read-JsonFile $cfg
            if ($value.ok -and $value.obj.port -eq 4399 -and $value.obj.backgroundMaxChars -in @(12000,60000) -and -not $value.obj.model -and @($value.obj.PSObject.Properties).Count -eq 3) { Remove-Item -LiteralPath $cfg }
        }
        if (@(Get-ChildItem -LiteralPath $InstallDir -Force).Count -eq 0) { Remove-Item -LiteralPath $InstallDir }
        else { Say ('保留数据目录：' + $InstallDir) }
    }
    Say ''
    Say '==== 卸载完成 ===='
}

try {
    if ($Uninstall) { Uninstall-All } else { Install-All }
    if ($script:warnCount -gt 0) { Say '部分步骤未完成，请处理上面的警告。'; exit 2 }
} catch { Write-Error ('安装/卸载失败，已保留配置备份：' + $_.Exception.Message); exit 1 }
