# opencode-learn

**在 opencode 里"哪里不会点哪里"：拖选一段看不懂的 AI 输出，一键让独立讲解会话结合你的对话上下文讲清楚——不污染主会话、不打断当前工作、绝不碰你的文件。**

![概念图](https://img.shields.io/badge/Windows-ready-0078d4) ![依赖](https://img.shields.io/badge/opencode-%E2%89%A51.18.29-000000) ![许可证](https://img.shields.io/badge/License-MIT-green)

---

## 目录

- [为什么用它](#为什么用它)
- [快速开始](#快速开始)
- [日常使用](#日常使用)
- [工作原理](#工作原理)
- [安装文档](#安装文档)
- [兼容性](#兼容性)
- [安全与隐私](#安全与隐私)
- [开发与测试](#开发与测试)
- [许可证](#许可证)

---

## 为什么用它

| 痛点 | opencode-learn 的做法 |
|---|---|
| AI 输出里有看不懂的术语/报错/片段，复制粘贴去提问很割裂 | 鼠标**普通拖选** → 按 **Alt+L**，全程不离开键盘工作流 |
| 提问会污染主会话上下文 / 打断正在进行的生成 | 讲解在**独立会话**并行进行，主会话零改动（AI 输出中也能触发） |
| 新会话没有上下文，解释常答非所问 | 主会话最近对话经 `system` 字段**隐式注入**（界面不可见、封顶 6 万字符） |
| 想自己换讲解模型 | **双层模型配置**，改一处、下次触发自动生效 |
| 多项目、多实例环境不好维护 | 学习线按「主会话」自动记忆，任何项目即开即用，配置全局一份 |

## 快速开始

```powershell
# 1. 复制脚本到 opencode 用户目录
Copy-Item scripts\* -Destination "$env:USERPROFILE\.config\opencode\learn\" -Recurse

# 2. 开启 opencode 原生"拖选即复制"（Windows 默认关闭）
setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0
```

3. 把 `agent.explain` 并入 `~/.config/opencode/opencode.json`（示例见 [config/opencode.agent.example.json](config/opencode.agent.example.json)）
4. 配置 VS Code 三件套：`keybindings.json` / `tasks.json` / `settings.json`（示例见 [config/](config/)，完整步骤见 [01-install.md](docs/01-install.md)）
5. **完全重启 VS Code** → 跑一次体检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.config\opencode\learn\doctor.ps1"
```

## 日常使用

```
opencode 聊天界面里看到不懂的内容
        │
        ▼ ① 鼠标普通拖选（松手即自动复制，无需 Ctrl+C）
        ▼ ② 按 Alt+L
        │
        ▼ ③ 编辑器区右侧弹出图形讲解窗口
   "你的原文 → 中文讲解（一句话结论→展开→结合你的项目语境）"
        │
        ▼ ④ 不懂就继续在窗口里打字追问
```

**失败信号**：剪贴板为空时响两声提示音（后台静默执行，不弹终端）。

**学习会话说明**：每个主会话对应一条持久「学习线」，反复复用、互不干扰；换主会话自动换线。
生命周期、重置方法与常见操作见 [02-usage.md](docs/02-usage.md)。

## 工作原理

讲解由 opencode 自己的 **Web UI** 呈现：`Alt+L` = `runCommands` → ① 后台静默运行
`explain.ps1`（取剪贴板 → 保障后台服务 → 选主会话 → 复用/重建学习线 → 注入背景 → 异步发送）
→ ② 在 VS Code **Simple Browser**（编辑器区）打开学习会话深链，WebSocket 实时流式。

关键设计：

- **空会话而非 fork** —— 讲解窗口只显示「原文 → 讲解」，主会话历史对模型可见、对界面不可见
- **只读讲解 agent** —— 禁用 write/edit/patch/bash/todowrite 全部写类工具
- **自愈** —— 后台服务掉线自动拉起；改配置后自动重启加载；学习线丢失自动重建并清扫孤儿
- **不依赖 VS Code 链内剪贴板命令** —— 复制交给 opencode 原生 copy-on-select（规避 VS Code 已知 bug 族）

详见 [03-architecture.md](docs/03-architecture.md)。

## 安装文档

| 文档 | 内容 |
|---|---|
| [01-install.md](docs/01-install.md) | 完整安装：模型双层配置、VS Code 三件套、登录自启、勿扰模式、验收清单 |
| [02-usage.md](docs/02-usage.md) | 使用指南：学习线生命周期、换模型/换端口、多实例、幽灵通知清理、重装迁移 |
| [03-architecture.md](docs/03-architecture.md) | 架构与数据流、设计决策、测试体系、PS 5.1 开发铁律 |
| [04-security-privacy.md](docs/04-security-privacy.md) | 数据流向、边界清单、推荐做法 |
| [05-troubleshooting.md](docs/05-troubleshooting.md) | 症状→原因→修复 排障表、版本矩阵、已知限制 |

## 兼容性

| 依赖 | 要求 | 已验证 |
|---|---|---|
| 操作系统 | **Windows 10/11**（macOS/Linux 移植点见 [05](docs/05-troubleshooting.md)） | Win11 |
| PowerShell | 5.1（系统自带，零额外安装） | 5.1.22621 |
| opencode | ≥ 1.18.29 | 1.18.29 / 1.18.30 |
| VS Code | runCommands + Simple Browser + 用户级 Tasks | 当前稳定版 |
| opencode VS Code 扩展 | ≥ 0.0.13 | 0.0.13 |

> **升级 opencode 后请跑一次测试**（测试覆盖全部依赖的 API 面，即兼容探针）：
> `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1`

## 安全与隐私

- 讲解 agent **只读**，实测回复不含任何工具调用
- 每次触发会把「选区 + 主会话最近 ≤6 万字符文本」发给**你配置的模型服务商**
- 后台服务仅监听 `127.0.0.1`，请勿暴露到局域网
- 详见 [04-security-privacy.md](docs/04-security-privacy.md)

## 开发与测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1   # 37 例，需 opencode 在 PATH
```

测试用真实 `opencode serve`（随机端口 + 临时目录），测完自清理、零残留。
仓库测试可在**本仓库目录直接运行**（兼容扁平与 scripts/ 两种布局）。

## 许可证

[MIT](LICENSE)
