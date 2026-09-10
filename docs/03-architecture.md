# 03 · 架构

## 组件总览

| 组件 | 位置 | 职责 |
|---|---|---|
| `explain.ps1` | 入口（VS Code 任务调用） | 编排：剪贴板 → 服务保障 → 选主会话 → 学习线 → 背景注入 → 发送 |
| `explain.lib.ps1` | 函数库 | 全部可单测逻辑：HTTP 封装 / 状态 / 背景构建 / 配置 / 键位更新 / 深链 |
| 后台服务 | `opencode serve`（默认 4399） | 会话 API + Web UI 托管（opencode 自带） |
| 学习会话 | 服务端会话 | 全新空会话（**不 fork 主会话**），只承载“原文→讲解”问答 |
| Simple Browser | VS Code 内建 | 图形化展示 Web UI 深链 |
| `prewarm.ps1` | 登录计划任务 | 开机预热后台服务 |
| `doctor.ps1` | 诊断 | 8 项环境体检 |
| `state.json` | 运行时 | 主会话 → 学习线 id 映射 |
| `config.json` | 运行时 | 端口 / 背景长度 / 可选模型覆盖 |

## 一次触发的数据流

```
用户普通拖选（opencode copy-on-select 自动复制到系统剪贴板）
        │
        ▼ Alt+L (when: terminalFocus)
runCommands ──► ① 任务：powershell explain.ps1
        │            │
        │            ├─ Get-Clipboard -Raw
        │            │   空？→ beep×2 + exit 1（后台静默）
        │            ├─ Test-LearnServerReady(base://127.0.0.1:<cfg.port>)
        │            │   不通 → Start-LearnServer 自愈拉起（cmd /c 隐藏）
        │            ├─ Test-LearnConfigStale：opencode.json mtime > 服务进程启动时间？
        │            │   是 → kill 端口进程 → 同端口重启（日志按端口分文件）
        │            ├─ Get-LearnSessions（UTF-8 手动解码，全局列表）
        │            ├─ Select-MainSession：directory==当前目录 && 标题不含 [LEARN] && 最近更新
        │            ├─ 学习线：state.lines[mainId]
        │            │   存在且存活 → 复用
        │            │   否则 → 清扫同目录“未映射”孤儿线 → POST /session{title:📘[LEARN]…, directory:工作目录, parentID:主会话}
        │            │   （directory 必传——缺失会触发 opencode subagent 子会话写库 FK 崩溃，见 05；
         │            │    parentID 使学习线成为子会话 → TUI/Web 会话列表天然隐藏，见设计决策）
        │            ├─ 背景：Get-LearnMessages(mainId) → Build-LearnBackground
        │            │       提取 user/assistant 文本 → "user: …\n\nassistant: …" → 截断保留尾部 ≤6万字符
        │            ├─ New-LearnPromptBody：
        │            │   system = 讲解指令 + [background]…（界面不可见）
        │            │   parts  = [ {text: 你选中的原文} ]   ← 无任何包装/标签
        │            │   model  = 可选 config.json 覆盖（请求级）
        │            ├─ Send-LearnPrompt：prompt_async（失败降级同步 message）
        │            ├─ Update-LearnKeybindings：确保键位 URL = /server/<serverKey>/session/<learnId>
        │            │   （幂等：URL 已正确则跳过写盘）
        │            └─ 打印网页地址
        └─── ② simpleBrowser.api.open(键位内 URL)
                 │
                 ▼ Web UI 加载（SPA）
        /server/<base64url(serverUrl)>/session/<learnId>   ← 应用原生深链路由
        WebSocket 实时流式：新问答自动滚出，无需刷新
```

## 关键设计决策

| 决策 | 理由 |
|---|---|
| **空会话而非 fork** | 要求“讲解窗口不显示主会话历史”。fork 会把历史复制成可见消息；空会话 + 请求级 `system` 注入让背景对模型可见、对界面不可见 |
| **子会话而非根会话** | 学习线以 `parentID` 挂为主会话的子会话——TUI 列表（服务端 `roots=true` + 客户端 `parentID === undefined` 双重过滤）与 Web 首页（`parseHomeSessionIndex` 丢弃子会话）**双端天然隐藏**；删除主会话时服务端递归级联删除学习线。深链按会话 ID 访问不受影响（v1 `POST /session` 支持 parentID，v2 暂无） |
| **背景截断（默认 6 万字符）** | 超长会话（数万 token）拖慢首字、抬高成本；只取最近部分对“解释当前语境”足够；可配置 |
| **请求级 system 而非改 agent prompt** | 背景随每次触发动态变化，只能随请求携带；指令文本内联在 system 里，无论 opencode 对 `system` 字段是替换还是追加 agent prompt 都自洽 |
| **粘性学习线（state.lines 映射）** | 任何项目/实例即开即用：按主会话 id 记忆学习会话，天然多线并存、互不干扰；重建时只清“未映射孤儿”，绝不误删别的主会话的活线 |
| **键位 URL 幂等回写** | 学习线换新（丢失/切主会话）后由脚本自己改写 keybindings.json 的 URL——零用户操作；URL 相同则跳过写盘避免文件抖动 |
| **配置过期自愈** | opencode 配置是服务启动时加载的；比较 mtime 与进程启动时间，过期即自动重启——用户改模型/改任何配置后下次触发自动生效 |
| **深链格式 /server/<serverKey>** | Web UI 自身的会话路由（serverKey = base64url(服务地址)）；目录 slug 形态会被应用自动重定向成它，直接用原生形态省一次跳转 |
| **不依赖 VS Code 链内剪贴板命令** | VS Code 存在“runCommands 里剪贴板命令静默失败”bug 族；且 TUI 选区是 opencode 内部选区、VS Code 命令本就看不见——复制交给 opencode 原生 copy-on-select（拖选即复制） |

## 状态与配置

```jsonc
// state.json（运行时生成）
{ "lines": { "<主会话id>": "<学习会话id>" }, "updatedAt": 1788… }

// config.json（用户可改）
{ "port": 4399, "backgroundMaxChars": 60000, "model": "deepseek/deepseek-v4-flash" }
```

## 测试体系

- 框架：PowerShell 5.1 自带 **Pester 3.4**（零额外安装）
- 运行：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1`
- 前置：`opencode` 在 PATH（沙箱会拉起真实 `opencode serve`，随机端口、临时目录，测完自清理——会话与进程均零残留）
- 分层：
  - **单元**（explain.Tests.ps1）：状态映射、主会话挑选、背景构建/截断、请求体构造（含模型覆盖切分）、配置读取、过期判定、键位 URL 改写、深链编码
  - **集成/黑盒**（http.Tests.ps1）：真实服务上的建线（directory+标记标题）、消息往返、noReply 落库、删除幂等、入口脚本端到端（建线/追加/切主换线/配置过期自动重启）、服务保活
- **兼容探针**：升级 opencode 后跑一遍，I/B 用例覆盖全部依赖 API 面
- 沙箱自清理的实现注意：Pester 3.4 的 `AfterAll` 看不到 Describe 作用域变量，必须用 `$script:` 前缀（否则僵尸进程与孤儿会话）

## PowerShell 5.1 铁律（开发本项目时踩过的坑，写代码前必读）

见 `05-troubleshooting.md` 的「PS 5.1 陷阱」一节——函数返回数组会被管道拆散、`@(cmdlet)` 不展开、`-like` 的 `[X]` 是字符类、含中文文件必须 UTF-8 BOM 等，均有修复范式与对应回归测试。
