# 01 · 安装与配置

## 一键安装（推荐）

```powershell
git clone https://github.com/Lizz-666/opencode-tutor.git
cd opencode-tutor
powershell -ExecutionPolicy Bypass -File install.ps1
```

安装器会自动完成本文第 1–7 节的全部步骤（复制脚本、环境变量、agent、VS Code 侧配置（键位/设置/扩展）、
可选计划任务、体检），并遵守以下安全设计：

- **幂等**：重复运行安全，已是最新的项自动跳过
- **备份**：每次修改配置文件前生成 `.bak-时间戳` 备份
- **不写坏**：支持 JSONC 注释和尾逗号，保留未改字段及其注释；格式损坏时保留原文件并报告部分失败
- **可预览**：`-DryRun` 只显示计划不改动
- **可卸载**：`-Uninstall` 精确移除我们加入的条目（保留你的其他配置），残留手动项会明确列出

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只显示将要修改什么，不落盘 |
| `-WithPrewarm` | 注册后台服务预热计划任务（登录自启 + 30 分钟保活；默认不注册） |
| `-Uninstall [-Force]` | 卸载 |
| `-SandboxRoot <路径>` / `-SkipSystemLevel` | 测试/沙箱用（重定向路径、跳过系统级操作） |

装完做两步：**Reload Window**（加载讲解面板扩展）+ `Ctrl+Shift+P` → **Toggle Do Not Disturb Mode**。

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
> 1. **改这里**的 `model` → 在后台空闲时手动重启后生效；按需立即换模型请使用 learn/config.json 的 model
> 2. 或在 `%LEARN%\config.json` 设 `model` 键 → 请求级覆盖，不依赖 agent 配置

## 4. 开启 opencode 原生“拖选即复制”

Windows 上 opencode 的 copy-on-select 默认关闭，用一个用户环境变量开启：

```powershell
setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0
```

> `0` = 开启拖选即复制（`1`/`true` = 关闭）。**必须完全重启 VS Code 后生效**
> （环境变量只传递给新启动的进程）。若你不想用拖选自动复制，可跳过本步，
> 改用「拖选 → 右键」或任何你习惯的复制方式——Alt+L 只需剪贴板里有内容。

## 5. VS Code 侧配置（键位 + 设置 + 扩展）

**keybindings.json**（`%APPDATA%\Code\User\keybindings.json`，用户级，合并进数组）：

```jsonc
[
  {
    "key": "alt+l",
    "command": "opencodeTutor.open",   // 讲解面板扩展命令（见下）
    "when": "terminalFocus"
  }
]
```

**settings.json**（`%APPDATA%\Code\User\settings.json`，合并进对象）：

```jsonc
{ "terminal.integrated.copyOnSelection": true }   // 可选：拖选即自动复制（VS Code 侧）
```

**讲解面板扩展**（Alt+L 的执行者与面板宿主）：

- 安装位置：`~\.vscode\extensions\lizz666.opencode-tutor-panel-<版本>\`（install.ps1 自动复制）
- 职责：按 Alt+L 后隐身运行 explain.ps1（**不经过任务系统**）、等待脚本就绪、在编辑器右侧打开讲解面板；
  脚本日志进输出通道「opencode-tutor」
- **安装/升级后需 Reload Window 一次生效**（`Ctrl+Shift+P` → `Developer: Reload Window`）
- 手动安装：把仓库 `extension\` 目录复制到上述位置（保持目录名不变）

> 旧版本（≤0.3）通过 用户级 tasks.json + 内建 Simple Browser 实现，已在 VS Code 1.137/1.138
> 上先后失效（详见 05 排障「症状 0」历史背景）；升级安装会自动迁移键位并移除遗留任务条目。

## 6. 登录自启后台服务（可选但推荐）

后台服务（4399 讲解服务）会在每次 Alt+L 时自动拉起（自愈），无需常驻。
但**冷启动期间**面板并行加载可能报连接错误（见 05 排障）；推荐注册计划任务让服务常热。
`install.ps1 -WithPrewarm` 会注册「登录自启 + 30 分钟保活」触发器（prewarm 幂等：
服务在线则秒退）。手动注册等价命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -WithPrewarm
# 关闭预热（保留快捷键按需启动）
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DisablePrewarm
```

安装器编译 Windows GUI 子系统的 `prewarm-launcher.exe`，由它以 `CreateNoWindow` 启动脚本。不要再把计划任务入口设为 powershell.exe。已有预热任务在普通升级时自动迁移，保留原触发器和启停状态，并备份原任务 XML。

> 注意：登录触发器必须带 `-User`（限定本人账户），否则注册"任意用户登录"触发器需要管理员权限。
> 解锁触达场景由 30 分钟保活覆盖。

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


## 配置保护与退出码（1.1）

- 已有 `opencode.jsonc` 时优先编辑它；否则编辑 `opencode.json`。自定义模型和提示词默认保留；`-ResetAgent` 才覆盖。
- `install-state.json` 记录安装前值、工具写入值，以及 `-ResetAgent` 实际删除的字段。卸载会恢复仍未重新设置的删除项；用户重新设置的值（包括 null）或主动删除的父对象保持不动。旧安装记录也支持从前后快照恢复删除项。
- 更新快捷键时保留数组顺序、注释和用户覆盖项的优先级；仅对象属性顺序不同不会触发重复写入或额外备份。
- 自定义 `-InstallDir` 时，在 VS Code 设置 `opencodeTutor.learnDirectory` 为相同路径。
- 退出码：0 完成，2 部分完成（检查警告/体检），1 失败。`-DryRun` 不落盘；`-SandboxRoot` 自动跳过系统级操作。
- 卸载保留 state、学习历史、自定义运行配置及迁移备份；确认不需要时再手动整理。
