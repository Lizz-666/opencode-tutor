# 05 · 排障

## 快速自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <learn目录>\doctor.ps1
```

8 项检查：opencode 版本 / copy-on-select 环境变量 / 后台服务可达 / 键位与 URL / 任务配置 /
copyOnSelection / explain agent / state 幽灵会话。每项失败都带修复指引。

## 症状 → 原因 → 修复

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
- 键位没加载？外部工具改过 keybindings.json 后 VS Code 偶尔不热加载 → 完全重启
- 剪贴板为空？会响两声提示音（beep）
- 后台任务在静默终端里报错了？看任务终端：终端面板下拉里选「opencode: 讲解选区」查看输出

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
排查：看任务终端输出 / `%TEMP%\opencode\learn-serve.log` 尾部。
已知诱因：**用 API 创建会话时缺 `directory` 字段**会触发 subagent 子会话写库外键失败——
本项目建线恒带 directory（见 03 架构）；若你手动用别的方式建会话请同样带上。

### 7. 剪贴板读取到的是乱码

脚本读剪贴板用 `Get-Clipboard -Raw`（PS 5.1 自带）。若用第三方剪贴板管理器干扰，先禁用以排除。

## 版本兼容矩阵

见 README「兼容性与版本」。要点：
- opencode **≥1.18.29**；升级后跑 `tests\run.ps1`（37 例，即兼容探针）
- VS Code 需支持 runCommands 与 Simple Browser（近两年版本均可）
- **Windows-only**；macOS/Linux 移植点见 README

## PowerShell 5.1 陷阱（贡献者必读）

本项目开发中踩过的坑，均有修复范式与回归测试守护：

| 陷阱 | 现象 | 正确写法 |
|---|---|---|
| 函数返回数组被管道拆散 | HTTP body 变“散装字节”→ 服务端 JSON 解析失败（500） | `return ,($array)` |
| `@(cmdlet)` 一步式不展开 | 计数为 1、属性访问变成员枚举拼接、删除打到 `System.Object[]` | `$x = cmdlet; @($x)` 两步式；JSON 用 `ConvertFrom-Json -InputObject` |
| `-like` 把 `[LEARN]` 当字符类 | 主会话被误杀/排除逻辑全错 | 匹配固定标记用 `.Contains()` |
| `ConvertTo-Json` 单元素数组 | 写回 JSON 根变成 `{}`（VS Code 不认） | `ConvertTo-Json -InputObject @($arr)` |
| 无 BOM 的中文 .ps1 | PS 5.1 按 GBK 解析 → 乱码/语法错 | 含中文文件保存为 UTF-8 **带 BOM** |
| `Invoke-RestMethod` 响应中文 | 按 Latin-1 解码 → emoji/中文乱码 → 匹配失效 | 手动 `RawContentStream` + UTF-8 解码 |
| Pester 3.4 `AfterAll` 作用域 | AfterAll 看不到 Describe 变量 → 清理没跑 → 僵尸进程/孤儿会话 | 沙箱变量用 `$script:` 前缀 |
| 服务日志被独占 | prewarm 用 `*>>` 写日志导致只读失败 | 用 `Get-Content -Tail` 读；自愈重启日志按端口分文件 |
| 内联脚本中文编码 | bash 内联 PowerShell 命令串中文时解析错 | 复杂逻辑写成 `.ps1` 文件再 `-File` 执行 |

## 已知限制（设计取舍）

- 切换主会话后的**第一次** Alt+L，讲解窗口可能还显示上一条学习线（键位 URL 由脚本在下一次触发时回写；第二次即正确）
- 学习线问答历史随使用累积，输入成本缓增（背景已封顶；建议周期性重置，见 02-usage）
- 同目录多个 TUI **几乎同时**触发可能竞争写 state.json（最后写者胜；低概率，不致命——丢失的线会在下次触发自愈重建）
- Web UI 深链路由随 opencode 版本演进可能变化（doctor 可查键位 URL，页面级需人工确认一次）
