# 01 · 安装与配置

## 一键安装（推荐）

```powershell
git clone https://github.com/Lizz-666/learn-while-aicoding.git
cd learn-while-aicoding
powershell -ExecutionPolicy Bypass -File install.ps1
```

安装器会自动完成本文第 1–7 节的全部步骤（复制脚本、环境变量、agent、VS Code 三件套、
可选计划任务、体检），并遵守以下安全设计：

- **幂等**：重复运行安全，已是最新的项自动跳过
- **备份**：每次修改配置文件前生成 `.bak-时间戳` 备份
- **不写坏**：任何配置文件解析失败（如含注释的 JSONC）会跳过该项并给出手动指引
- **可预览**：`-DryRun` 只显示计划不改动
- **可卸载**：`-Uninstall` 精确移除我们加入的条目（保留你的其他配置），残留手动项会明确列出

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只显示将要修改什么，不落盘 |
| `-WithPrewarm` | 注册登录自启计划任务（默认不注册） |
| `-Uninstall [-Force]` | 卸载 |
| `-SandboxRoot <路径>` / `-SkipSystemLevel` | 测试/沙箱用（重定向路径、跳过系统级操作） |

装完做两步：**完全重启 VS Code** + `Ctrl+Shift+P` → **Toggle Do Not Disturb Mode**。

以下为手动安装（分步/自定义）的完整说明。

---

> 面向 Windows + PowerShell 5.1。安装路径约定：把 `scripts/` 目录内容复制到
> `C:\Users\<你的用户名>\.config\opencode\learn\`（或 clone 仓库后把 scripts 目录整体复制过去）。
> 下文以 `%LEARN%` 代指该目录（例：`C:\Users\<你的用户名>\.config\opencode\learn`）。

## 0. 前置条件

- 已安装 opencode（`opencode --version` ≥ 1.18.29）且 `opencode` 在 PATH
- 已登录至少一个模型 provider（`opencode auth login`）
- 已安装 VS Code，opencode 官方扩展（插件终端形态）可选但推荐
- 全程共需 **一次 VS Code 完全重启**（最后一步）

## 1. 复制脚本

```powershell
# 把本仓库 scripts/ 复制到 opencode 的用户配置目录
Copy-Item scripts\* -Destination "$env:USERPROFILE\.config\opencode\learn\" -Recurse
# 初始化运行时配置（config.json 不存在时脚本会用它默认值，也可手动复制）
Copy-Item scripts\config.example.json "$env:USERPROFILE\.config\opencode\learn\config.json"
```

## 2. 配置讲解后台端口（可选，默认 4399）

编辑 `%LEARN%\config.json`：

```json
{
  "port": 4399,
  "backgroundMaxChars": 60000,
  "model": ""
}
```

| 键 | 含义 | 默认 |
|---|---|---|
| `port` | 讲解后台服务端口（可改，脚本与预热均读这里） | 4399 |
| `backgroundMaxChars` | 注入模型的主会话背景文本最大字符数（取最近部分） | 60000 |
| `model` | **可选模型覆盖**：如 `"deepseek/deepseek-v4-flash"`。设置了就以请求级 model 发送（优先级最高）；留空则走 explain agent 的 model | 空 |

## 3. 配置讲解 agent（模型的第一层）

把 `config/opencode.agent.example.json` 中的 `agent.explain` 块合并进
`~/.config/opencode/opencode.json` 的 `agent` 字段（合并到现有文件，勿整体覆盖）。

核心字段：

```jsonc
"agent": {
  "explain": {
    "mode": "subagent",                    // 不出现在你的 agent 切换列表
    "model": "deepseek/deepseek-v4-flash", // ← 想换模型改这一行
    "prompt": "……中文讲解员人设（示例内含全文）……",
    "tools": { "write": false, "edit": false, "patch": false, "bash": false, "todowrite": false }
  }
}
```

> **模型配置的两种方式**（满足不同熟练度用户）：
> 1. **改这里**的 `model` → 下次触发讲解时后台会自动重启并加载新配置（已验证）
> 2. 或在 `%LEARN%\config.json` 设 `model` 键 → 请求级覆盖，不依赖 agent 配置

## 4. 开启 opencode 原生“拖选即复制”

Windows 上 opencode 的 copy-on-select 默认关闭，用一个用户环境变量开启：

```powershell
setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0
```

> `0` = 开启拖选即复制（`1`/`true` = 关闭）。**必须完全重启 VS Code 后生效**
> （环境变量只传递给新启动的进程）。若你不想用拖选自动复制，可跳过本步，
> 改用「拖选 → 右键」或任何你习惯的复制方式——Alt+L 只需剪贴板里有内容。

## 5. VS Code 三件套（示例见 config/ 目录）

**keybindings.json**（`%APPDATA%\Code\User\keybindings.json`，用户级，合并进数组）：

```jsonc
[
  {
    "key": "alt+l",
    "command": "runCommands",
    "when": "terminalFocus",
    "args": {
      "commands": [
        { "command": "workbench.action.tasks.runTask", "args": "opencode: 讲解选区" },
        { "command": "simpleBrowser.api.open",
          "args": [ "http://127.0.0.1:4399/server/<SERVERKEY>/session/PLACEHOLDER", { "preserveFocus": true, "viewColumn": 2 } ] }
      ]
    }
  }
]
```

> `SERVERKEY` = `base64url("http://127.0.0.1:4399")` = `aHR0cDovLzEyNy4wLjAuMTo0Mzk5`。
> `PLACEHOLDER` 会在**首次真实触发**时被 explain.ps1 自动替换为你的学习会话 URL。
> 端口如改过（config.json），把 URL 里的 4399 与 SERVERKEY 同步改掉（首次触发后脚本会自动回写正确 URL，无需手工精确）。

**tasks.json**（`%APPDATA%\Code\User\tasks.json`，用户级）：

```jsonc
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "opencode: 讲解选区",          // ← 必须与 keybindings 的 runTask 参数一致
      "type": "shell",
      "command": "powershell",
      "args": ["-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", "C:\\Users\\<你>\\.config\\opencode\\learn\\explain.ps1"],  // ← 改你的路径
      "presentation": { "echo": false, "reveal": "never", "focus": false, "panel": "dedicated" },
      "problemMatcher": []
    }
  ]
}
```

**settings.json**（`%APPDATA%\Code\User\settings.json`，合并进对象）：

```jsonc
{ "terminal.integrated.copyOnSelection": true }   // 可选：拖选即自动复制（VS Code 侧）
```

## 6. 登录自启后台服务（可选但推荐）

后台服务（4399 讲解服务）会在每次 Alt+L 时自动拉起（自愈），无需常驻。
若想开机即热，注册一个登录计划任务：

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Users\<你>\.config\opencode\learn\prewarm.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'OpencodeLearnServer' -Action $action -Trigger $trigger -Settings $settings -Force
```

## 7. 打开勿扰模式（强烈推荐，一次性）

`Ctrl+Shift+P` → **Toggle Do Not Disturb Mode**

VS Code 的通知 toast 若与编辑器区网页窗口重叠，会触发“因通知而暂停”遮罩（VS Code 原生行为，见 05 排障）。勿扰模式让通知只进铃铛中心、不弹 toast，从此不再打扰讲解窗口。

## 8. 验收清单

1. **完全关闭并重开 VS Code**（环境变量/键位/settings 全部生效的关键）
2. 在 opencode 聊天里说几句话
3. **普通拖选**一段话 → 松手 → 去任意输入框 Ctrl+V：应能粘出选中文本（copy-on-select 生效）
4. 回到终端，拖选后直接按 **Alt+L** → 右侧出现讲解窗口（图形聊天），内容即你选中的原文 + DeepSeek 讲解
5. 再次拖选另一段 → Alt+L → 同一窗口追加新问答（学习线复用）
6. 有问题先跑 `doctor.ps1` 自检
