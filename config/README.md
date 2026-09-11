# 示例配置说明

本目录是给 opencode-tutor 的 **VS Code / opencode 侧配置示例**。安装完整步骤见
`../docs/01-install.md`。四个文件的用途与合并位置：

| 文件 | 合并到 | 说明 |
|---|---|---|
| `opencode.agent.example.json` | `~/.config/opencode/opencode.json` | 把其中的 `agent.explain` 对象并入现有 `agent` 字段（勿整文件覆盖——你可能有自己的 provider 配置）。改模型改这里的 `model` |
| `keybindings.example.json` | `%APPDATA%\Code\User\keybindings.json` | 合并进 JSON **数组**（保留你已有的其他键位）。`PLACEHOLDER` 会在首次 Alt+L 触发后被脚本自动替换为真实学习会话 URL。若改过后台端口，把 URL 里的 `4399` 与 `serverKey`（`aHR0cDovLzEyNy4wLjAuMTo0Mzk5` = base64url 编码的 `http://127.0.0.1:4399`）同步改掉 |
| `tasks.example.json` | `%APPDATA%\Code\User\tasks.json` | 任务 `label` 必须与 keybindings 的 `runTask` 参数完全一致；`-File` 路径改成你的实际安装位置 |
| `settings.example.json` | `%APPDATA%\Code\User\settings.json` | 合并进对象，保留原有键 |

> 注意：JSON 文件不支持注释。上面的 `%APPDATA%` 在 Windows 上通常是
> `C:\Users\<你>\AppData\Roaming`。
