# 03 · 架构（1.2）

## 组件与数据流

扩展捕获一次剪贴板 → 根据活动终端 cwd 确定项目（多根且不明确时选择）→ 隐藏运行 explain.ps1 → 后台列出根会话 → 单个候选自动绑定、多个候选选择 → 加锁取得或创建学习线 → 拼接背景、异步发送 → 原子写入本次 invocation 标记 → 本地 Webview 打开学习线。

| 组件 | 职责 |
|---|---|
| extension/ | 快捷键、来源绑定、剪贴板快照、进程结果、Webview。Node spawn 使用 windowsHide；脚本 stdin 传文本，不把原文放进命令行 |
| explain.ps1 | 编排服务检查、主会话协商、学习线与请求；显式 -MainSessionId 可供脚本调用 |
| explain.lib.ps1 | HTTP、跨进程互斥、状态原子替换、建线/续建事务、进度和结果标记 |
| context.ps1 | 分页读取、选区定位、相关性排序、按完整消息执行字符预算 |
| extension/api.js | 本机状态读取及经过会话身份复核的生成中止请求 |
| prewarm-launcher.exe | 安装时由 HiddenLauncher.cs 编译的 GUI 子系统入口，启动时没有控制台 |
| prewarm.ps1 | 与按需入口共用服务启动逻辑；端口锁避免同时启动多个服务 |
| jsonc.ps1 | JSONC 解析及局部修改，保留未修改字段/注释；写入前校验后原子替换 |
| install-state.json | 安装前配置与工具预期值，用于保护用户设置和卸载恢复 |

## 主会话绑定

只选择当前目录的根会话，排除子会话、归档会话和 [LEARN] 会话。多个候选不按更新时间猜测。服务返回 sessions 标记后，扩展显示选择框；选择后传 MainSessionId 重试，复用最初捕获的剪贴板。

绑定按活动终端保存在扩展内存中，不同终端互不影响；没有活动终端时按当前窗口/目录绑定。重载窗口后重新确认。相同终端切换主会话时，使用「重新选择主会话并讲解」。面板显示来源目录、标题和 ID。

## 状态与历史保护

- 以状态文件的规范绝对路径生成命名互斥锁，覆盖读取、查线、建线、合并映射、写入全过程；不在生成回复期间持锁。
- 更新写入同目录临时文件，以 File.Replace 原子替换，旧内容保存至 state.json.bak。不同主会话映射合并，避免覆盖别的窗口。
- 状态缺失可以创建；损坏、空内容、错误 schema 会停止请求，保留原文件，不自动重置。
- 学习线请求只有明确 404 才视为不存在；网络或鉴权失败不会触发重建。
- 旧子会话需要迁移时新建独立根线，保留旧线全部历史。无映射会话也不自动删除，延后由用户确认整理。

## 后台与面板

后台服务固定监听 127.0.0.1，按端口互斥启动。PowerShell 子进程使用 UseShellExecute=false / CreateNoWindow=true；计划任务走 GUI 启动器。配置过期只提示，不根据端口直接 taskkill；全局配置在空闲时手动重启后生效，请求级 model 无需重启。

Webview 开启必要脚本能力，关闭 command URI、本地资源；frame-src 仅包含配置的 loopback origin，结果 URL 必须匹配服务及 session 路径。iframe 运行 OpenCode 自带 Web UI。

请求结果文件带唯一 invocation，以原子替换发布。脚本退出但没有结果时立即报错，避免等满 120 秒。异步发送只在 404/405 时降级同步接口，网络超时不盲目重复提交。

## API 与上下文

学习线仍是独立目录的空根会话，不 fork、不向主会话写消息。GET/POST session 的 directory 使用 query 参数。消息请求带 limit；下一页使用响应 X-Next-Cursor 的原始值作为 before，而非消息 ID。无游标时停止，重复消息去重，默认扫描最多 200 条。接口依据 [OpenCode Server API](https://opencode.ai/docs/server/)，游标行为另有真实服务测试。

相关模式先定位选区，再选相邻消息、此前提问和少量近期消息；分页边界处继续补查此前提问，至多回看四条有效文本消息，并始终受总扫描上限限制。按优先级纳入预算后恢复时间顺序。文本部分按消息合并，整条超限时跳过；新安装默认背景 12000 字符，原选区不截断。预算与历史阈值是字符/消息计量，不声称精确 token 估算。

当前学习线达到消息数或文本字符阈值时，在状态锁内复核空闲状态并准备独立会话。入口持有同一状态锁，延迟映射写入，直到发送前最后一次取消检查通过才提交，随后释放锁并发出请求；进入提交边界后不再取消或回滚可能已发送的请求。创建途中取消会保留旧映射；已创建的空会话不会被自动删除。旧会话保留，结果提供 previousUrl。忙碌或状态获取失败时不会切线。此检查发生于 Alt+L 入口，不拦截内嵌 Web UI 的直接追问。

progress-request 发布阶段，cancel-request 协作取消准备，open-request 发布最终结果，三者都以 invocation 隔离。取消与提交存在竞态，最终结果必须区分已发送与未发送；发送错误保留已知学习会话地址。停止生成前复核 ID、学习目录、标题和根会话身份，仅请求该学习会话的 abort，不停止主会话或服务进程。状态轮询只更新宿主状态文字，不重载 iframe。

## 测试

`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` 运行 Node 扩展行为测试和 Pester 单元、并发、安装、真实服务集成测试。HTTP 写入使用 noReply，不生成模型回答。运行前应使用隔离的 XDG 配置/数据目录并配置测试 explain agent，避免依赖真实用户设置。

`tests/smoke/index.cjs` 可由 VS Code 的 --extensionTestsPath 启动。通过 TUTOR_SMOKE_ROOT 指定独立目录，使用独立 --user-data-dir / --extensions-dir；真实扩展宿主连接本地模拟服务，检查 iframe JavaScript、流式事件、追问表单，不调用模型。

PS 5.1 注意事项仍见 [排障文档](05-troubleshooting.md)：UTF-8 BOM、数组管道语义、通配符字符类和 Pester 作用域。
