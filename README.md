# opencode-learn · 哪里不会点哪里

在 opencode 里选中一段看不懂的 AI 输出，一键让独立讲解会话结合上下文给你讲清楚——**不污染主会话、不打断当前工作、不改任何文件**。

## 它是怎么做到的

```
┌─────────────────────────────────────────────────────────────┐
│ VS Code（编辑器区）                                          │
│                                                             │
│  opencode TUI（插件终端）        讲解窗口（Simple Browser）   │
│  ┌────────────────────────┐     ┌────────────────────────┐  │
│  │ 普通拖选 AI 输出        │     │ 📘 学习会话（图形聊天）   │  │
│  │ （松手即自动复制）       │     │   只显示：你的原文 → 讲解  │  │
│  │          ↓ Alt+L       │     │   追问：直接在窗口里聊     │  │
│  └────────────────────────┘     └────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
        │ Alt+L = runCommands
        ├── ① 运行后台任务 explain.ps1
        │      ├─ 读取剪贴板（=你拖选的内容）
        │      ├─ 确保讲解后台服务（4399，opencode serve）
        │      ├─ 配置比服务新？→ 自动重启后台加载新配置
        │      ├─ 找到当前项目最活跃的主会话
        │      ├─ 找到/创建该主会话的「学习线」（空会话，带目录）
        │      ├─ 取主会话最近对话文本（≤6万字符）经 system 隐式注入
        │      ├─ 用户消息 = 你选中的原文（无任何包装）
        │      └─ prompt_async 发送（不阻塞）
        └── ② 打开 Simple Browser → 学习会话的 Web UI 深链
```

**关键设计**：学习会话是**全新空会话**（不 fork 主会话），对话历史对模型可见、对界面不可见（经请求级 `system` 字段注入，封顶 6 万字符）。讲解由专用 `explain` agent 完成——**只读，禁用全部写类工具**。

## 特性

- **零打扰**：讲解在独立会话并行生成，主会话/主工作流完全不受影响（包括 AI 正在输出时）
- **干净对话**：讲解窗口只显示「你选的原文 → 讲解」，不显示主会话历史
- **多实例/多项目**：按「主会话」各建一条持久学习线，任何 opencode 实例、任何项目即开即用
- **纯图形窗口**：讲解在 VS Code 编辑器区的网页窗口流式输出，可连续追问
- **不弹终端**：后台任务静默执行（reveal: never）
- **一键复制**：快捷键自动抓取当前终端选区（不占用也不影响系统 Ctrl+C）
- **模型可配**：双层配置（见 docs/01-install），改完下次触发自动生效
- **自愈**：后台服务掉了自动拉起；opencode 配置改了自动重启后台；学习线丢了自动重建并清扫孤儿
- **诊断**：`scripts/doctor.ps1` 一键体检 8 项环境

## 快速开始

1. 完整安装步骤见 **[docs/01-install.md](docs/01-install.md)**（约 5 分钟，含模型配置与 VS Code 三件套）
2. 装完跑一次 `powershell -File <安装目录>\doctor.ps1` 自检
3. **完全重启 VS Code**（环境变量与新键位生效的必要条件）
4. 使用：**普通拖选**不懂的文字（松手自动复制）→ **Alt+L** → 右侧讲解窗口弹出

> ⚠️ Windows-first：本项目面向 **Windows + PowerShell 5.1**。macOS/Linux 需要移植（见 README 下方「兼容性与移植」）。

## 使用流程（日常）

1. 在 opencode 聊天界面里看到不懂的术语/报错/代码片段
2. **鼠标普通拖选**它（松开即自动复制，无需 Alt、无需 Ctrl+C）
3. 按 **Alt+L**
4. 编辑器区右侧出现讲解窗口：先一句话结论、再展开、结合你的项目语境说明作用
5. 不懂继续在窗口里打字追问；弄懂了继续干活

## 目录结构

```
├── scripts/
│   ├── explain.ps1          # 入口：一键讲解（被 VS Code 任务调用）
│   ├── explain.lib.ps1      # 函数库（全部业务逻辑，可单测）
│   ├── prewarm.ps1          # 登录自启后台服务（可选）
│   ├── doctor.ps1           # 环境诊断
│   └── config.example.json  # 端口/背景长度/模型覆盖 示例
├── config/                  # VS Code 与 opencode 配置示例（含说明）
├── docs/                    # 安装/使用/架构/安全/排障
└── tests/                   # Pester 3.4 测试（37 例，需 opencode 在 PATH）
```

## 兼容性与版本

| 依赖 | 最低要求 | 已验证 | 说明 |
|---|---|---|---|
| 操作系统 | **Windows 10/11** | Win11 | 脚本使用 PowerShell/计划任务/剪贴板等 Windows 机制 |
| PowerShell | **5.1**（系统自带） | 5.1.22621 | 全库刻意规避 5.1 陷阱（数组展开/BOM/-like 字符类等，见 05 排障） |
| opencode | **≥ 1.18.29** | 1.18.29 / 1.18.30 | 依赖：`POST /session`（含 directory 字段）、`/session/:id/prompt_async`、消息 `{info,parts}` 结构、agent tools 配置、Web UI `/server/<key>/session/:id` 深链路由 |
| VS Code | runCommands（≥1.77）、Simple Browser、用户级 Tasks | 当前稳定版 | 链内剪贴板类命令存在已知 bug 家族——本设计**不依赖**链内复制，规避之 |
| opencode VS Code 扩展 | 0.0.13 | 0.0.13 | 插件以编辑器区集成终端形态运行 TUI 并注入环境变量；若未来扩展改渲染形态，拖选复制需重验 |
| 讲解模型 | 任意已登录 provider 的模型 | deepseek-v4-flash | 双层配置（opencode.json agent.model 或 config.json model 覆盖） |

**升级 opencode 后请跑一次测试**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1`（I/B 用例覆盖了全部依赖的 API 面，即“兼容探针”）。Web UI 深链路由若随版本变化，`doctor.ps1` 的「键位 URL」检查可辅助发现（页面层面需人工确认一次）。

### 移植到 macOS/Linux 的差异点（欢迎 PR）

| 环节 | Windows | macOS/Linux 对应 |
|---|---|---|
| 拖选即复制 | opencode 环境变量 + 重启 | opencode copy-on-select 在 mac/linux **默认开启**，无需环境变量 |
| 剪贴板读取 | `Get-Clipboard -Raw` | `pbpaste` / `xclip -o` |
| 后台服务启动 | `cmd /c` 隐藏窗口 | `nohup ... &` |
| 登录自启 | 计划任务 `schtasks` | launchd / systemd user unit |
| 环境变量持久化 | `setx` | `launchctl setenv` / shell profile |

## 安全与隐私

- 讲解 agent **只读**：禁用 write / edit / patch / bash / todowrite，只会解释不会操作
- 每次触发会把「选区 + 主会话最近 ≤6 万字符文本」发送给你**配置的模型服务商**（默认 DeepSeek）——详见 [docs/04-security-privacy.md](docs/04-security-privacy.md)
- 讲解后台服务仅监听 127.0.0.1，无鉴权（本地单机设计）；请勿暴露到局域网

## 文档

- [01-install.md](docs/01-install.md) — 安装与配置（模型双层配置 / VS Code 三件套 / 计划任务 / 验收清单）
- [02-usage.md](docs/02-usage.md) — 使用指南（含学习线生命周期、改模型/改端口、常见操作）
- [03-architecture.md](docs/03-architecture.md) — 架构与数据流
- [04-security-privacy.md](docs/04-security-privacy.md) — 安全与隐私边界
- [05-troubleshooting.md](docs/05-troubleshooting.md) — 排障全集与已知问题

## License

MIT
