# 05 · 排障

## 快速自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <learn目录>\doctor.ps1
```

10 项检查：opencode 版本 / copy-on-select 环境变量 / 后台服务可达 / 键位指向扩展命令 / 讲解面板扩展已安装 /
无遗留旧版任务 / copyOnSelection / explain agent（2 项）/ state 幽灵会话。每项失败都带修复指引。

## 症状 → 原因 → 修复

### 0. 按 Alt+L 报"命令 opencodeTutor.open 未找到"或毫无反应

| 可能原因 | 判定 | 修复 |
|---|---|---|
| 扩展未生效 | doctor 第 5 项 FAIL，或键位存在但命令不存在 | 安装后需 **Reload Window** 一次（`Ctrl+Shift+P` → `Developer: Reload Window`）；确认 `~\.vscode\extensions\lizz666.opencode-tutor-panel-<版本>\` 存在 |
| VS Code 用了自定义 `--extensions-dir` / 便携模式 | 扩展装到了默认目录而 VS Code 不读 | 把 `extension\` 复制到你的扩展目录后 Reload |
| 终端没聚焦 | 键位带 `when: terminalFocus` | 焦点放回 opencode 终端再按 |

> 历史背景（≤0.3 版本的任务系统路径，已弃用）：Alt+L 曾依赖 `runTask` + 内建 Simple Browser，
> 在 VS Code 1.137/1.138 上先后踩坑（simple-browser 委托集成浏览器丢 `viewColumn` 参数、
> 冷启动面板 ERR_CONNECTION_REFUSED、1.138 "Timed out activating extensions for task providers"
> 导致任务系统整体静默失效）。自有扩展一次性根治了这四类问题；升级到 ≥0.4 由安装器自动迁移。

### 0b. 面板显示"等待讲解脚本超时"或错误信息

面板自带诊断：脚本失败/超时会直接把原因显示在面板上（如"剪贴板为空"），并提示查看输出通道。
`Ctrl+Shift+P` → `Output: Show Output Channel` → 选 **opencode-tutor**，可见每次触发的脚本完整输出。

### 1. 拖选后不能自动复制（要右键才行）

| 可能原因 | 判定 | 修复 |
|---|---|---|
| `OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT` 未送达 | 环境变量设了但没**完全重启 VS Code** | 完全关闭 VS Code 再开（Reload Window 不够） |
| opencode 未捕获鼠标 | 普通拖选无高亮 | 默认即捕获；若被 `OPENCODE_DISABLE_MOUSE=1` 关闭则普通拖选=VS Code 选区，copy-on-select 反而依赖 VS Code 侧 copyOnSelection 设置 |

> 背景知识：opencode 捕获鼠标后，**普通拖选的选区是 opencode 内部选区**，VS Code 的
> `copySelection` 命令与 `copyOnSelection` 设置对它无效——这是本项目**不依赖** VS Code
> 链内复制命令的原因。右键复制是 opencode TUI 自己的功能（直接写系统剪贴板）。

### 2. 按 Alt+L 没反应

- 终端没聚焦？键位带 `when: terminalFocus`
- 扩展没生效？见症状 0（Reload Window / 扩展目录检查）
- 剪贴板为空？面板会显示提示（旧版本是响两声）
- 脚本输出异常？看输出通道「opencode-tutor」（每次触发的完整日志）

### 3. 讲解窗口弹了但显示 “Session not found”

- **角落通知 + 页面正常**：Web UI 的陈旧“当前会话”指针（幽灵 id）。一次性解决：打开
  `http://127.0.0.1:4399/` 首页点进学习线（详见 02-usage）
- **整个页面报错**：键位 URL 指向的会话不存在（曾手动删过？）→ 直接再按一次 Alt+L，脚本会自愈重建学习线并回写键位

### 4. 讲解窗口被灰色遮罩挡住：“因通知而暂停”

这是 **VS Code 自身行为**（browserView 编辑器被工作台通知 toast 覆盖时的暂停 UI），与 opencode
无关。任何通知（如扩展提醒）压在窗口上就会触发。

修复：`Ctrl+Shift+P` → **Toggle Do Not Disturb Mode**（通知只进铃铛中心，不弹 toast）。

### 5. 换模型/改配置后不生效

opencode 配置在**服务启动时**加载。改 `opencode.json` 后，下一次 Alt+L 会自动检测并重启后台
（默认开启）。若没生效：`doctor.ps1` 确认服务已重启；或手动杀掉 4399 进程再触发一次。
改 `config.json` 的端口后：旧端口常驻服务不会自动停止——手动结束（`taskkill /PID <pid> /T /F`）。

### 6. 异步“静默失败”（exit 0 但窗口没新回复）

`prompt_async` 先回 200、异步处理失败时**不会**报给入口（曾遇到 opencode 内部 SQLite FK 崩溃）。
现象：网页只有你的原文、没有讲解回复。
排查：看输出通道 opencode-tutor / `%TEMP%\opencode\learn-serve-端口号.log` 尾部。
API 陷阱提醒：v1 `POST /session` 的 **body `directory` 字段会被忽略**（会话落到服务进程 cwd），
必须用 query 参数 `POST /session?directory=<urlencoded路径>`；`GET /session` 裸调用返回**全局**
会话且带上限（~100），按项目取会话必须显式 `?directory=`。本项目已按此实现（见 03 架构）。

### 7. 剪贴板读取到的是乱码

脚本读剪贴板用 `Get-Clipboard -Raw`（PS 5.1 自带）。若用第三方剪贴板管理器干扰，先禁用以排除。

## 版本兼容矩阵

见 README「兼容性与版本」。要点：
- opencode **≥1.18.29**；升级后跑 `tests\run.ps1`（含扩展行为、并发状态和真实服务检查）
- VS Code **≥1.80**（扩展 `engines` 要求）；1.137/1.138 已验证——讲解面板由自带扩展渲染，不受内建 Simple Browser/集成浏览器演进影响
- **Windows-only**；macOS/Linux 移植点见 README

## PowerShell 5.1 陷阱（贡献者必读）

本项目开发中踩过的坑，均有修复范式与回归测试守护：

| 陷阱 | 现象 | 正确写法 |
|---|---|---|
| 函数返回数组被管道拆散 | HTTP body 变“散装字节”→ 服务端 JSON 解析失败（500） | `return ,($array)` |
| `@(cmdlet)` 一步式不展开 | 计数为 1、属性访问变成员枚举拼接、删除打到 `System.Object[]` | `$x = cmdlet; @($x)` 两步式；JSON 用 `ConvertFrom-Json -InputObject` |
| `-like` 把 `[LEARN]` 当字符类 | 主会话被误杀/排除逻辑全错 | 匹配固定标记用 `.Contains()` |
| `Mandatory` 参数拒收空字符串 | 显式传 `''` 也抛绑定异常，整条链退出 | 需要"空值合法"的参数加 `[AllowEmptyString()]` |
| `ConvertTo-Json` 单元素数组 | 写回 JSON 根变成 `{}`（VS Code 不认） | `ConvertTo-Json -InputObject @($arr)` |
| 无 BOM 的中文 .ps1 | PS 5.1 按 GBK 解析 → 乱码/语法错 | 含中文文件保存为 UTF-8 **带 BOM** |
| `Invoke-RestMethod` 响应中文 | 按 Latin-1 解码 → emoji/中文乱码 → 匹配失效 | 手动 `RawContentStream` + UTF-8 解码 |
| Pester 3.4 `AfterAll` 作用域 | AfterAll 看不到 Describe 变量 → 清理没跑 → 僵尸进程/孤儿会话 | 沙箱变量用 `$script:` 前缀 |
| 服务日志被独占 | prewarm 用 `*>>` 写日志导致只读失败 | 用 `Get-Content -Tail` 读；服务日志按端口分文件 |
| 内联脚本中文编码 | bash 内联 PowerShell 命令串中文时解析错 | 复杂逻辑写成 `.ps1` 文件再 `-File` 执行 |

## 已知限制（设计取舍）

- 后台服务冷启动（开机后首次触发、或手动重启后台）时面板会等待十几秒（显示 spinner），脚本就绪后自动加载——不再报错页；推荐 `-WithPrewarm` 安装让服务常热
- 讲解面板扩展安装/升级后需 Reload Window 一次生效
- 学习历史在下次 Alt+L 时按阈值检查并续建；内嵌 Web UI 的直接追问不经过此检查，可用面板按钮主动新开会话（见 02-usage）
- 旧版（≤0.2 子会话机制）学习线在首次触发时自动迁移，**历史不保留**
- 同目录多个 TUI **几乎同时**触发可能竞争写 state.json（最后写者胜；低概率，不致命——丢失的线会在下次触发自愈重建）
- Web UI 深链路由随 opencode 版本演进可能变化（doctor 可查服务可达性，页面级需人工确认一次）


## 1.1 稳定性更新

- **定时弹出终端**：重新运行安装器，确认 OpencodeLearnServer 的入口是 prewarm-launcher.exe。已有任务会备份后迁移；不需要预热可加 `-DisablePrewarm`。
- **面板空白**：确认已加载当前扩展 1.2.1 并 Reload Window；新版本允许内嵌页面脚本，且仅允许配置的本地 origin。
- **讲解来源不对**：使用「opencode-tutor: 重新选择主会话并讲解」；不会再将子会话或最近更新的任意会话作为默认来源。
- **state.json 损坏**：停止触发讲解，保留原文件，对照 state.json.bak 恢复。程序不会将损坏文件当空状态，更不会据此删除学习记录。
- **改模型未生效**：learn/config.json 的 model 下次请求立即生效；修改 OpenCode 全局 agent 配置需要在后台空闲时重启服务。
