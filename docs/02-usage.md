# 02 · 使用指南

## 日常流程

1. 在 opencode 聊天里看到不懂的内容，**鼠标普通拖选**（松开即自动复制；若未开 copy-on-select，则拖选后右键一次）
2. 按 **Alt+L**（终端聚焦时生效）
3. 编辑器区右侧弹出讲解窗口：`你的原文 → DeepSeek 讲解`，流式输出
4. 可在窗口里直接打字追问；讲解会话与主会话完全隔离

**失败信号**：剪贴板为空时响两声提示音（后台终端静默，不打扰）。

## 学习会话生命周期

| 问题 | 答案 |
|---|---|
| 一个学习会话活多久？ | **持久**。每个主会话对应一条「学习线」，首次触发创建、之后反复复用追加 |
| 什么时候消失？ | ① 你在 opencode 会话列表手动删除；② state.json 丢失/重置后，同目录再建新线时自动清扫未映射的旧孤儿线；③ 永不自动删除（尊重你的数据） |
| 会无限膨胀吗？ | 背景注入已封顶（默认 6 万字符，取主会话最近部分）；但**学习线自身的问答历史会累积**，每次触发模型需重读，成本随月缓增。建议每几周重置一次（见下） |
| 怎么重置？ | 删除 `%LEARN%\state.json` 并删除对应 📘 学习会话（opencode TUI 会话列表里删，或删 state 后下次触发自动清理孤儿并重建）。想彻底干净：两个都删，下次 Alt+L 全新开始 |
| 换主会话了会怎样？ | 新主会话自动获得自己的新学习线，互不干扰；讲解窗口切到新线的 URL 是在下一次触发时由脚本自动更新（**切换后的第一次 Alt+L 打开的可能还是上一条线**，再按一次即正确） |

## 多实例 / 多项目

- 每个**项目目录 + 主会话**一条独立学习线（state.json 记录映射）
- 后台服务与会话存储是全局的：任何 opencode 实例/终端触发都能用
- 4399 端口被占用时：改 `%LEARN%\config.json` 的 `port` 后首次触发会自动拉起新端口服务；**旧端口的常驻服务不会自动停止**，请手动结束或重启一次

## 更换讲解模型

**方式一（推荐）**：编辑 `~/.config/opencode/opencode.json` 中 `agent.explain.model` → 保存 → 下次 Alt+L 触发时后台自动检测到配置变新、自动重启加载 → 新模型生效。

**方式二（傻瓜旋钮）**：编辑 `%LEARN%\config.json` 加一行 `"model": "<provider>/<model>"` → 立即生效（请求级覆盖，无需重启任何东西）。

> 模型串格式：`providerID/modelID`；若 modelID 本身含 `/`（如 zenmux 的 `deepseek/deepseek-v4-flash`），写 `zenmux/deepseek/deepseek-v4-flash`——脚本按第一个 `/` 切分，支持嵌套 id。

## 幽灵“Session not found”角落通知（一次性清理）

场景：讲解窗口正常显示，但角落弹「Session not found: ses_xxx」（一个从未出现在地址栏的 id）。

原因：Web UI 在 localStorage 里记忆“上次当前会话”，若该会话早已被清理/从未持久化，每次加载都会顺手 fetch 一次而 404。

解决（一次性）：
1. 打开 `http://127.0.0.1:4399/` 首页
2. 在会话列表里**点进你的 📘 学习线**
3. 此后应用的当前会话指针更新为真实 id，通知不再出现

## 换电脑 / 重装

迁移三个位置即可：
- `~/.config/opencode/opencode.json`（agent 配置）
- `~/.config/opencode/learn/`（脚本 + config.json；state.json 可丢，会自动重建）
- VS Code 三件套（keybindings/tasks/settings 的对应片段）
- 环境变量（`setx OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT 0`）
- 可选：注册登录计划任务
