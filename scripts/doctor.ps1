param(
    [string]$ServerUrl = '',
    [string]$KeybindingsPath = '',
    [string]$TasksPath = '',
    [string]$SettingsPath = '',
    [string]$OpencodeJsonPath = ''
)

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
if (Test-Path (Join-Path $scriptDir 'explain.lib.ps1')) {
    . (Join-Path $scriptDir 'explain.lib.ps1')
} else {
    Write-Output '[FAIL] 找不到 explain.lib.ps1（doctor 需与 lib 同目录）'
    exit 1
}

$global:failedCount = 0

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Hint)
    if ($Ok) { Write-Output ("[PASS] " + $Name) }
    else {
        $script:failedCount++
        Write-Output ("[FAIL] " + $Name)
        if ($Hint) { Write-Output ("        指引: " + $Hint) }
    }
}

Write-Output '==== opencode-tutor 环境诊断 ===='

Write-Output '--- 1. opencode 可执行与版本 ---'
$oc = Get-Command opencode -ErrorAction SilentlyContinue
if ($oc) {
    Write-Output ("opencode 位于: " + $oc.Source)
    $verRaw = & opencode --version 2>&1
    $ver = ($verRaw | Select-Object -First 1)
    Write-Output ("版本: " + $ver)
    $majorMinor = [regex]::Match([string]$ver, '(\d+)\.(\d+)\.(\d+)')
    if ($majorMinor.Success) {
        $v = [version]($majorMinor.Value)
        Write-Check 'opencode 版本 >= 1.18.29' ($v -ge [version]'1.18.29') '请升级 opencode 至 1.18.29+'
    } else {
        Write-Check 'opencode 版本可解析' $false '无法解析版本号'
    }
} else {
    Write-Check 'opencode 在 PATH 中' $false '请安装 opencode 并加入 PATH'
}

Write-Output '--- 2. 拖选即复制环境变量 ---'
$envVal = [Environment]::GetEnvironmentVariable('OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT', 'User')
Write-Check "OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=0 (当前: '$envVal')" ($envVal -eq '0') 'setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0，然后完全重启 VS Code'

Write-Output '--- 3. 讲解后台服务 ---'
$cfg = Get-LearnConfig
if (-not $ServerUrl) { $ServerUrl = 'http://127.0.0.1:' + $cfg.port }
$ready = Test-LearnServerReady -BaseUrl $ServerUrl
Write-Check "后台服务 $ServerUrl 可访问" $ready ('服务未启动：按一次 Alt+L 会自动拉起，或运行计划任务/执行 prewarm.ps1；或检查端口是否被占用')

Write-Output '--- 4. keybindings.json ---'
if (-not $KeybindingsPath) { $KeybindingsPath = Join-Path $env:APPDATA 'Code\User\keybindings.json' }
$kbOk = $false
$kbUrl = ''
if (Test-Path -LiteralPath $KeybindingsPath) {
    try {
        $kbRaw = Get-Content -LiteralPath $KeybindingsPath -Raw -Encoding UTF8
        $kb = $kbRaw | ConvertFrom-Json
        $entry = @($kb) | Where-Object { $_.key -eq 'alt+l' -and $_.command -eq 'runCommands' }
        if ($entry) {
            $sbCmd = @($entry.args.commands) | Where-Object { $_ -isnot [string] -and $_.command -eq 'simpleBrowser.api.open' }
            if ($sbCmd) { $kbUrl = [string]$sbCmd[0].args[0] }
            $kbOk = $kbUrl -ne ''
        }
    } catch {}
}
Write-Check 'keybindings 含 alt+l runCommands+simpleBrowser' $kbOk 'keybindings.json 需含示例中的 alt+l 绑定（含 simpleBrowser.api.open 条目）'
Write-Check '键位 URL 非占位符' ($kbOk -and -not $kbUrl.Contains('PLACEHOLDER')) '学习线 URL 会在首次 Alt+L 触发后自动回填；若持续为 PLACEHOLDER，请检查 explain.ps1 是否成功执行'

Write-Output '--- 5. tasks.json ---'
if (-not $TasksPath) { $TasksPath = Join-Path $env:APPDATA 'Code\User\tasks.json' }
$taskOk = $false
if (Test-Path -LiteralPath $TasksPath) {
    try {
        $t = (Get-Content -LiteralPath $TasksPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $task = @($t.tasks) | Where-Object { $_.label -eq 'opencode: 讲解选区' }
        if ($task) { $taskOk = $true }
    } catch {}
}
Write-Check 'tasks 含任务 opencode: 讲解选区' $taskOk 'tasks.json 需含示例任务（label 必须与 keybindings 的 runTask 参数一致）'

Write-Output '--- 6. settings.json copyOnSelection ---'
if (-not $SettingsPath) { $SettingsPath = Join-Path $env:APPDATA 'Code\User\settings.json' }
$copyOk = $false
if (Test-Path -LiteralPath $SettingsPath) {
    try {
        $s = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json
        $copyOk = $s.'terminal.integrated.copyOnSelection' -eq $true
    } catch {}
}
Write-Check 'terminal.integrated.copyOnSelection=true' $copyOk '在 settings.json 加入该键（opencode 自身拖选即复制依赖此设置可选；Alt+L 链不依赖它）'

Write-Output '--- 7. explain agent ---'
if (-not $OpencodeJsonPath) { $OpencodeJsonPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json' }
$agentOk = $false
$agentModel = ''
if (Test-Path -LiteralPath $OpencodeJsonPath) {
    try {
        $o = (Get-Content -LiteralPath $OpencodeJsonPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($o.agent.explain) {
            $agentOk = $true
            $agentModel = [string]$o.agent.explain.model
        }
    } catch {}
}
Write-Check 'explain agent 已配置' $agentOk '将示例 config/opencode.agent.example.json 并入 opencode.json 的 agent 字段'
Write-Check "agent 模型已指定 (当前: '$agentModel')" ($agentModel -ne '') '建议在 explain agent 配置 model（或用 learn config.json 的 model 键覆盖）'

Write-Output '--- 8. state 幽灵检测 ---'
$statePath = Join-Path $scriptDir 'state.json'
$ghostOk = $true
if (Test-Path -LiteralPath $statePath) {
    $state = Read-LearnState -Path $statePath
    if ($ready -and $state.lines) {
        foreach ($k in @($state.lines.Keys)) {
            $learnId = [string]$state.lines[$k]
            $exists = $true
            try { $null = Invoke-RestMethod -Uri ($ServerUrl + '/session/' + $learnId) -TimeoutSec 10 } catch { $exists = $false }
            if (-not $exists) {
                $ghostOk = $false
                Write-Output ("        幽灵: 主会话 $k 映射的学习会话 $learnId 已不存在（可删除该 state.json 行或整文件，下次触发自动重建）")
            }
        }
    }
} else {
    Write-Output '        state.json 不存在：首次触发会自动创建，非问题'
}
Write-Check 'state 映射无幽灵会话' $ghostOk ''

Write-Output '==== 诊断结束 ===='
if ($global:failedCount -gt 0) {
    Write-Output ("结论: $($global:failedCount) 项未通过，按上方指引修复；修复后完全重启 VS Code 再试。")
    exit 1
} else {
    Write-Output '结论: 全部通过，可以正常使用（拖选 -> Alt+L）。'
    exit 0
}
