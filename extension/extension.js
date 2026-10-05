// @ts-check
const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');
const api = require('./api');
let panel, channel, active, view, pollTimer, pageNonce;
let generation = 0;
const terminalBindings = new WeakMap();
const windowBindings = new Map();
const learnDir = () => vscode.workspace.getConfiguration('opencodeTutor').get('learnDirectory') || path.join(os.homedir(), '.config', 'opencode', 'learn');
const markerPath = id => path.join(learnDir(), `open-request.${id}.json`);
const normalizeDir = dir => path.resolve(dir).toLowerCase();

function escapeHtml(value) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function html(content, origin) {
  const frames = origin ? escapeHtml(origin) : "'none'";
  pageNonce = crypto.randomBytes(16).toString('hex');
  return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${pageNonce}'; frame-src ${frames};">
    <style>html,body{margin:0;height:100%;color:var(--vscode-editor-foreground);background:var(--vscode-editor-background);font:13px system-ui}
    body{display:flex;flex-direction:column}.notice{padding:16px;white-space:pre-wrap;line-height:1.6}
    .source{padding:8px 12px;border-bottom:1px solid var(--vscode-panel-border)}iframe{width:100%;flex:1;min-height:180px;border:0}
    button{margin:6px 6px 0 0;padding:4px 8px;color:var(--vscode-button-foreground);background:var(--vscode-button-background);border:0;cursor:pointer}
    pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:160px;overflow:auto}details{margin-top:6px}.meta{opacity:.8;margin-top:4px}#status{margin-top:6px}</style>
    </head><body>${content}<script nonce="${pageNonce}">
    const host=acquireVsCodeApi();document.addEventListener('click',e=>{const button=e.target.closest('button[data-action]');if(button)host.postMessage({action:button.dataset.action,nonce:'${pageNonce}'});});
    window.addEventListener('message',e=>{if(e.data?.type==='status'){const status=document.getElementById('status');if(status)status.textContent=e.data.text;}});
    </script></body></html>`;
}
function show(message) {
  if (panel) panel.webview.html = html(`<div class="notice"><div id="status">${escapeHtml(message)}</div><button data-action="cancel">取消准备</button></div>`);
}
function ensurePanel() {
  if (panel) { panel.reveal(vscode.ViewColumn.Beside, true); return; }
  panel = vscode.window.createWebviewPanel('opencodeTutorPanel', '讲解',
    { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
    { enableScripts: true, enableCommandUris: false, localResourceRoots: [] });
  panel.webview.onDidReceiveMessage(message => {
    if (message?.nonce !== pageNonce) return;
    if (message.action === 'cancel') cancelPreparation();
    else if (message.action === 'abort') void abortGeneration();
    else if (message.action === 'options') void onOpen(false, { ...view, withOptions: true });
    else if (message.action === 'newLine') void onOpen(false, { ...view, newLine: true });
    else if (message.action === 'previous' && view?.result.previousUrl) {
      void vscode.env.openExternal(vscode.Uri.parse(validateUrl(view.result.previousUrl, view.origin)));
    }
  });
  panel.onDidDispose(() => { panel = undefined; view = undefined; clearTimeout(pollTimer); cancel(); });
}
function log(text) {
  if (!channel) channel = vscode.window.createOutputChannel('opencode-tutor');
  channel.appendLine(text);
}
function serverOrigin() {
  let port = 4399;
  const cfgPath = path.join(learnDir(), 'config.json');
  if (fs.existsSync(cfgPath)) {
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, ''));
    port = cfg.port ?? port;
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('config.json 中的 port 必须是 1–65535 的整数。');
  return `http://127.0.0.1:${port}`;
}
function validateUrl(value, origin) {
  const url = new URL(value);
  if (url.origin !== origin || url.username || url.password || url.hash || url.search ||
      !/^\/server\/[A-Za-z0-9_-]+\/session\/[A-Za-z0-9_-]+$/.test(url.pathname)) {
    throw new Error('讲解地址与配置的本地服务不匹配。');
  }
  return url.href;
}
async function workspaceDir(terminal) {
  const cwd = terminal?.shellIntegration?.cwd;
  if (cwd?.scheme === 'file') return cwd.fsPath;
  const folders = (vscode.workspace.workspaceFolders || []).filter(f => f.uri.scheme === 'file');
  if (folders.length === 1) return folders[0].uri.fsPath;
  if (!folders.length) throw new Error('请先打开本地项目文件夹。');
  const selected = await vscode.window.showQuickPick(folders.map(f => ({
    label: f.name, description: f.uri.fsPath, directory: f.uri.fsPath
  })), { placeHolder: '选择当前终端对应的项目目录' });
  return selected?.directory;
}
function cancel(keepPolling = false) {
  generation++;
  if (!keepPolling) clearTimeout(pollTimer);
  if (active) active.cancel();
  active = undefined;
}
function cancelPreparation() {
  if (active) { active.cancel(); show('正在取消准备…若请求已发送，生成会继续；返回会话后可点击“停止生成”。'); }
  else {
    generation++;
    if (view) setStatus('已取消本次准备，当前学习会话保留。');
    else show('已取消准备，未发送讲解请求。');
  }
}
function setStatus(text, current = view) {
  if (panel && current === view) void panel.webview.postMessage({ type: 'status', text });
}
async function abortGeneration() {
  const current = view;
  if (!current?.result.learnSession?.id || current.stopping) return;
  current.stopping = true;
  const id = current.result.learnSession.id;
  try {
    const info = await api.request(current.origin, `/session/${encodeURIComponent(id)}`);
    if (id === current.result.mainSession?.id || info.id !== id || info.parentID ||
        !info.title?.includes('[LEARN]') || !info.directory || normalizeDir(info.directory) !== normalizeDir(path.join(learnDir(), 'lines'))) {
      throw new Error('会话身份校验失败，未停止任何生成。');
    }
    await api.request(current.origin, `/session/${encodeURIComponent(id)}/abort?directory=${encodeURIComponent(info.directory)}`, 'POST');
    setStatus('已请求停止当前学习会话的生成。', current);
  } catch (error) { setStatus(`停止失败：${error.message}`, current); }
  finally { current.stopping = false; }
}
function watchStatus(current) {
  let checks = 0, busy = false;
  const poll = async () => {
    if (current !== view || !panel) return;
    try {
      const states = await api.request(current.origin, `/session/status?directory=${encodeURIComponent(current.result.learnSession.directory)}`);
      if (current !== view) return;
      const state = states?.[current.result.learnSession.id];
      busy ||= state?.type === 'busy' || state?.type === 'retry';
      setStatus(state?.type === 'busy' ? '正在生成讲解…' : state?.type === 'retry' ? '服务正在重试，请稍候…' : '学习会话当前空闲，回复或错误详情见下方。', current);
      if (busy && (!state || state.type === 'idle')) return;
    } catch { setStatus('暂时无法读取生成状态，请查看下方会话。', current); }
    if (++checks < 150 && current === view) pollTimer = setTimeout(poll, 2000);
    else if (current === view) setStatus('请以下方会话中的实时状态为准。', current);
  };
  pollTimer = setTimeout(poll, 500);
}
function showResult(result, options, origin, cwd, terminal, warning = '') {
  const url = validateUrl(result.url, origin);
  const main = result.mainSession;
  if (!main?.id) throw new Error('后台未返回主会话信息，请更新安装。');
  if (result.learnSession && result.learnSession.id !== new URL(url).pathname.split('/').at(-1)) throw new Error('学习会话与返回地址不一致。');
  view = { result, selection: options.selection, style: options.style, contextMode: options.contextMode, origin, cwd, terminal, mainId: main.id };
  panel.title = `讲解 · ${main.title || main.id}`;
  const context = result.context;
  const labels = { brief: '简短解释', detailed: '深入解释', example: '举例说明', relevant: '相关背景', recent: '近期对话', none: '仅选区', exact: '已定位选区', related: '采用相关消息', recentMatch: '未定位选区，采用近期消息' };
  const stats = context ? `${labels[result.style] || ''} · ${labels[context.mode]} · 扫描 ${context.scanned} 条，采用 ${context.messages} 条完整消息 / ${context.chars} 字符（预算 ${context.budget}）` : '';
  const match = context && context.mode === 'relevant' ? (!context.messages ? '没有纳入背景，仅发送选区' : context.match === 'recent' ? labels.recentMatch : labels[context.match]) : '';
  panel.webview.html = html(`<div class="source">来源：${escapeHtml(main.title || main.id)}<br>${escapeHtml(main.directory)} · ${escapeHtml(main.id)}
    <div class="meta">${escapeHtml(stats)} ${escapeHtml(match)}${context?.oversized ? '；已跳过超出预算的完整消息' : ''}</div>
    <details><summary>本次原文（${options.selection.length} 字符）</summary><pre>${escapeHtml(options.selection)}</pre></details>
    ${result.notice ? `<div class="meta">${escapeHtml(result.notice)}</div>` : ''}
    <div id="status" role="status">${escapeHtml(warning || '已发送，等待生成…')}</div>
    <button data-action="abort">停止生成</button><button data-action="options">换种方式讲解</button><button data-action="newLine">新会话讲解此选区</button>
    ${result.previousUrl ? '<button data-action="previous">查看上一学习会话</button><div class="meta">已新建学习会话，原记录保留。</div>' : ''}
    </div><iframe title="讲解会话" sandbox="allow-scripts allow-forms allow-same-origin" src="${escapeHtml(url)}"></iframe>`, origin);
  if (result.learnSession && !warning) watchStatus(view);
}
function cleanupMarkers() {
  try {
    for (const name of fs.readdirSync(learnDir())) {
      if (!/^(open|progress|cancel)-request\.[a-zA-Z0-9-]+\.json$/.test(name)) continue;
      const file = path.join(learnDir(), name);
      if (Date.now() - fs.statSync(file).mtimeMs > 3600000) fs.unlinkSync(file);
    }
  } catch { /* Best-effort cleanup does not affect requests. */ }
}
function runScript(cwd, selection, mainId, origin, options, token) {
  const invocation = crypto.randomUUID();
  const marker = markerPath(invocation);
    const progressFile = path.join(learnDir(), `progress-request.${invocation}.json`);
    const cancelFile = path.join(learnDir(), `cancel-request.${invocation}.json`);
  return new Promise((resolve, reject) => {
    let done = false, timer, timeout, child;
    let tail = '';
    let progress, cancelled = false;
    const request = { cancel: () => { cancelled = true; try { fs.writeFileSync(cancelFile, '{}'); } catch (error) { log(`取消准备失败：${error.message}`); } } };
    const finish = (error, value) => {
      if (done) return;
      done = true;
      clearInterval(timer); clearTimeout(timeout);
      if (active === request) active = undefined;
      if (error && child) child.kill();
      try { fs.unlinkSync(marker); } catch { /* already absent */ }
      try { fs.unlinkSync(progressFile); } catch { /* already absent */ }
      child?.once('close', () => { try { fs.unlinkSync(cancelFile); } catch {} });
      if (error && !error.result && progress?.url) error.result = progress;
      error ? reject(error) : resolve(value);
    };
    const checkMarker = () => {
      try {
        const update = JSON.parse(fs.readFileSync(progressFile, 'utf8'));
        if (update.invocation === invocation && update.stage !== progress?.stage) {
          progress = update;
          const stages = { connecting: '正在连接服务…', starting: '正在启动后台服务…', selecting: '正在定位主会话…', context: '正在选取相关上下文…', session: '正在准备学习会话…', sending: '正在发送，请勿重复提交…' };
          if (token === generation && !cancelled) show(stages[update.stage] || '正在准备讲解…');
        }
      } catch { /* atomic progress may not exist yet */ }
      let result;
      try { result = JSON.parse(fs.readFileSync(marker, 'utf8')); } catch { return false; }
      if (result.invocation !== invocation) return false;
      const error = result.error ? Object.assign(new Error(result.error), { result }) : null;
      finish(error, { ...result, cancelled });
      return true;
    };
    const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
      path.join(learnDir(), 'explain.ps1'), '-WorkDir', cwd, '-ServerUrl', origin];
    args.push('-Style', options.style, '-ContextMode', options.contextMode);
    if (options.newLine) args.push('-NewLine');
    if (mainId) args.push('-MainSessionId', mainId);
    try {
      child = spawn('powershell.exe', args, {
        cwd, windowsHide: true,
        env: { ...process.env, OPENCODE_TUTOR_INVOCATION: invocation, OPENCODE_TUTOR_STDIN: '1' },
        stdio: ['pipe', 'pipe', 'pipe']
      });
      active = request;
      const capture = data => { const text = data.toString('utf8'); tail = (tail + text).slice(-2000); log(text.trimEnd()); };
      child.stdout.on('data', capture); child.stderr.on('data', capture);
      child.on('error', error => finish(new Error(`讲解脚本启动失败：${error.message}`)));
      child.on('close', code => {
        if (!done && !checkMarker()) finish(new Error(`讲解脚本已退出（${code}），未返回结果。\n${tail}`));
        try { fs.unlinkSync(cancelFile); } catch { /* already absent */ }
      });
      child.stdin.on('error', error => finish(error));
      timer = setInterval(checkMarker, 200);
      timeout = setTimeout(() => finish(new Error(`准备讲解超时。\n${tail}`)), 120000);
      child.stdin.end(selection, 'utf8');
    } catch (error) { finish(error); }
  });
}
async function onOpen(forceChoose = false, options = {}) {
  // Keep the current iframe and its controls alive until a new request is confirmed.
  cancel(Boolean(view));
  const token = generation;
  const terminal = options.terminal || vscode.window.activeTerminal;
  const selectionNotice = message => view ? setStatus(message) : show(message);
  let origin, cwd;
  try {
    const selection = options.selection ?? await vscode.env.clipboard.readText();
    options = { ...options, selection };
    if (generation !== token) return;
    ensurePanel();
    if (!selection.trim()) throw new Error('剪贴板为空：先拖选不懂的文字，再按 Alt+L。');
    if (!fs.existsSync(path.join(learnDir(), 'explain.ps1'))) throw new Error('找不到讲解脚本，请运行 install.ps1。');
    cwd = options.cwd || await workspaceDir(terminal);
    if (generation !== token || !cwd) { if (generation === token) selectionNotice('已取消项目选择。'); return; }
    origin = serverOrigin();
    const cfg = vscode.workspace.getConfiguration('opencodeTutor');
    options.style ||= cfg.get('explanationStyle') || 'brief';
    options.contextMode ||= cfg.get('contextMode') || 'relevant';
    if (options.withOptions) {
      const style = await vscode.window.showQuickPick([{ label: '简短解释', value: 'brief' }, { label: '深入解释', value: 'detailed' }, { label: '举例说明', value: 'example' }], { placeHolder: '选择本次讲解方式' });
      if (generation !== token || !style) { if (generation === token) selectionNotice('已取消本次选择，未发送新讲解请求。'); return; }
      const background = await vscode.window.showQuickPick([{ label: '相关背景', value: 'relevant' }, { label: '近期对话', value: 'recent' }, { label: '仅选区', value: 'none' }], { placeHolder: '选择本次背景范围' });
      if (generation !== token || !background) { if (generation === token) selectionNotice('已取消本次选择，未发送新讲解请求。'); return; }
      options.style = style.value; options.contextMode = background.value;
    }
    const key = `${origin}|${normalizeDir(cwd)}`;
    const remembered = terminal ? terminalBindings.get(terminal) : windowBindings.get(key);
    let mainId = options.mainId || (!forceChoose && remembered?.key === key ? remembered.id : '');
    clearTimeout(pollTimer);
    view = undefined;
    cleanupMarkers();
    for (let attempt = 0; attempt < 3; attempt++) {
      show('正在准备讲解…');
      const result = await runScript(cwd, selection, mainId, origin, options, token);
      if (generation !== token) return;
      if (Array.isArray(result.sessions)) {
        if (result.cancelled) { show('已取消会话选择，未发送讲解请求。'); return; }
        if (!result.sessions.length) throw new Error('当前项目没有可用主会话。');
        const chosen = await vscode.window.showQuickPick(result.sessions.map(s => ({
          label: s.title || s.id, description: s.id, detail: s.directory, session: s
        })), { placeHolder: '选择你正在阅读的主会话（当前终端会记住此选择）', ignoreFocusOut: true });
        if (generation !== token) return;
        if (!chosen) { show('已取消会话选择，未发送讲解请求。'); return; }
        mainId = chosen.session.id;
        continue;
      }
      const main = result.mainSession;
      if (!main?.id) throw new Error('后台未返回主会话信息，请更新安装。');
      const binding = { key, id: main.id };
      if (terminal) terminalBindings.set(terminal, binding); else windowBindings.set(key, binding);
      if (panel) showResult(result, options, origin, cwd, terminal, result.cancelled ? '取消到达时请求已发送；如需中止，请点击“停止生成”。' : '');
      return;
    }
    throw new Error('主会话连续变化，请重新选择后重试。');
  } catch (error) {
    if (generation === token) {
      if (panel && error.result?.url && error.result?.mainSession) {
        try { showResult(error.result, options, origin, cwd, terminal, error.message); } catch { show(error.message); }
      } else selectionNotice(`讲解未能完成\n${error.message}\n\n详情见输出通道 opencode-tutor。`);
    }
  }
}
function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('opencodeTutor.open', () => onOpen()),
    vscode.commands.registerCommand('opencodeTutor.chooseSession', () => onOpen(true)),
    vscode.commands.registerCommand('opencodeTutor.openWithOptions', () => onOpen(false, { withOptions: true })),
    vscode.commands.registerCommand('opencodeTutor.newLine', () => onOpen(false, { newLine: true })),
    vscode.commands.registerCommand('opencodeTutor.cancelPreparation', cancelPreparation),
    vscode.commands.registerCommand('opencodeTutor.abortGeneration', abortGeneration),
    { dispose() { cancel(); view = undefined; channel?.dispose(); } }
  );
}
module.exports = { activate, validateUrl };
