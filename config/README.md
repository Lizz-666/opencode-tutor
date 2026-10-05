# 示例配置说明

本目录是给 opencode-tutor 的 **VS Code / opencode 侧配置示例**。安装完整步骤见
`../docs/01-install.md`。三个文件的用途与合并位置：

| 文件 | 合并到 | 说明 |
|---|---|---|
| `opencode.agent.example.json` | `~/.config/opencode/opencode.json` | 把其中的 `agent.explain` 对象并入现有 `agent` 字段（勿整文件覆盖——你可能有自己的 provider 配置）。改模型改这里的 `model` |
| `keybindings.example.json` | `%APPDATA%\Code\User\keybindings.json` | 合并进 JSON **数组**（保留你已有的其他键位）。键位调用讲解面板扩展的命令 `opencodeTutor.open`（扩展由 install.ps1 安装到 `~\.vscode\extensions\`）；不再依赖任务系统与内建 Simple Browser，也不携带会话 URL |
| `settings.example.json` | `%APPDATA%\Code\User\settings.json` | 合并进对象，保留原有键。`copyOnSelection` 可选（VS Code 侧拖选复制） |

> 注意：JSON 文件不支持注释。上面的 `%APPDATA%` 在 Windows 上通常是
> `C:\Users\<你>\AppData\Roaming`。
> 旧版本的 `tasks.example.json` 已移除：任务系统路径（runTask + 隐藏终端）在
> VS Code 1.138 上暴露出"扩展激活超时即静默失效"的脆弱性，现由扩展直接执行脚本取代。
