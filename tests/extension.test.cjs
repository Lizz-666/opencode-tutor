const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const source = fs.readFileSync(path.join(__dirname, '../extension/extension.js'), 'utf8');
function host(respond) {
  const commands = new Map(), files = new Map(), calls = [], picks = [];
  let webOptions, disposePanel, receive;
  const statuses=[], apiCalls=[];
  const panel = { webview:{html:'',onDidReceiveMessage(fn){receive=fn;},postMessage(m){statuses.push(m);}}, reveal(){}, onDidDispose(fn){disposePanel=fn;} };
  const fakeApi={request:async(origin,route,method)=>{apiCalls.push({origin,route,method});return {};}};
  const vscode = {
    env: {clipboard:{readText:async()=> '选中的原文'}},
    ViewColumn: {Beside:2},
    workspace: {getConfiguration:()=>({get:()=>''}),workspaceFolders:[{name:'A',uri:{scheme:'file',fsPath:'C:\\A'}}]},
    window: {
      activeTerminal:{},
      createWebviewPanel(a,b,c,opts){webOptions=opts;return panel;},
      createOutputChannel(){return {appendLine(){},dispose(){}};},
      showQuickPick: async items => {picks.push(items);return items[items.length-1];}
    },
    commands:{registerCommand(id,fn){commands.set(id,fn);return {dispose(){}};}}
  };
  const fakeFs = {
    existsSync:()=>true,readdirSync:()=>[],unlinkSync:p=>files.delete(p),writeFileSync:(p,v)=>files.set(p,v),
    readFileSync(p){if(p.endsWith('config.json'))return '{"port":4399}';if(files.has(p))return files.get(p);throw Error('missing');}
  };
  const spawn = (cmd,args,options) => {
    const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.stdin=new EventEmitter();child.kill=()=>{child.killed=true;};
    child.stdin.end=text=>{
      const call={cmd,args,options,text,child};calls.push(call);
      queueMicrotask(()=>{
        if(child.killed)return;
        const result=respond(call,calls.length,files);
        if(result?.pending)return;
        if(result){const id=options.env.OPENCODE_TUTOR_INVOCATION;files.set(path.join('C:\\fakehome','.config','opencode','learn',`open-request.${id}.json`),JSON.stringify({invocation:id,...result}));}
        child.emit('close',result?0:1);
      });
    };
    return child;
  };
  const context={module:{exports:{}},process:{env:{}},URL,Date,setInterval,clearInterval,setTimeout,clearTimeout,
    require(name){if(name==='./api')return fakeApi;if(name==='vscode')return vscode;if(name==='fs')return fakeFs;if(name==='os')return {homedir:()=> 'C:\\fakehome'};if(name==='child_process')return {spawn};return require(name);}};
  vm.runInNewContext(source,context);
  context.module.exports.activate({subscriptions:[]});
  return {vscode,calls,picks,panel,commands,files,statuses,api:fakeApi,apiCalls,receive:m=>receive(m),validate:context.module.exports.validateUrl,get options(){return webOptions;},dispose:()=>disposePanel?.()};
}
const ready={url:'http://127.0.0.1:4399/server/aHR0cA/session/ses_learning',mainSession:{id:'ses_main',title:'主对话',directory:'C:\\A'}};
const choices={sessions:[{id:'ses_one',title:'One',directory:'C:\\A'},{id:'ses_main',title:'Two',directory:'C:\\A'}]};

test('hidden launch, script-enabled webview, local CSP and visible source',async()=>{
  const h=host(()=>ready);await h.commands.get('opencodeTutor.open')();
  assert.equal(h.calls[0].options.windowsHide,true);
  assert.equal(h.calls[0].options.windowsHidden,undefined);
  assert.equal(h.options.enableScripts,true);
  assert.equal(h.options.enableCommandUris,false);
  assert.ok(h.panel.webview.html.includes('frame-src http://127.0.0.1:4399'));
  assert.ok(!h.panel.webview.html.includes('frame-src *'));
  assert.ok(h.panel.webview.html.includes('主对话'));
  assert.equal(h.calls[0].text,'选中的原文');
  assert.ok(!h.calls[0].args.includes('选中的原文'));
});
test('ambiguity picker binds per terminal and manual selection resets binding',async()=>{
  const h=host(call=>call.args.includes('-MainSessionId')?ready:choices);
  await h.commands.get('opencodeTutor.open')();
  assert.equal(h.picks.length,1);
  assert.equal(h.calls[1].args.at(-1),'ses_main');
  await h.commands.get('opencodeTutor.open')();assert.equal(h.picks.length,1);
  h.vscode.window.activeTerminal={};
  await h.commands.get('opencodeTutor.open')();assert.equal(h.picks.length,2);
  await h.commands.get('opencodeTutor.chooseSession')();assert.equal(h.picks.length,3);
});
test('multi-root prompts instead of silently choosing first folder',async()=>{
  const h=host(()=>ready);
  h.vscode.workspace.workspaceFolders.push({name:'B',uri:{scheme:'file',fsPath:'C:\\B'}});
  await h.commands.get('opencodeTutor.open')();assert.equal(h.calls[0].options.cwd,'C:\\B');
});
test('terminal shell integration cwd takes precedence',async()=>{
  const h=host(()=>ready);h.vscode.window.activeTerminal.shellIntegration={cwd:{scheme:'file',fsPath:'C:\\A\\subdir'}};
  await h.commands.get('opencodeTutor.open')();assert.equal(h.calls[0].options.cwd,'C:\\A\\subdir');
});
test('cancelled selection never sends a second request',async()=>{
  const h=host(()=>choices);h.vscode.window.showQuickPick=async()=>undefined;
  await h.commands.get('opencodeTutor.open')();assert.equal(h.calls.length,1);assert.ok(h.panel.webview.html.includes('未发送'));
});
test('unexpected process exit fails immediately without waiting 120 seconds',async()=>{
  const h=host(()=>null);await h.commands.get('opencodeTutor.open')();assert.ok(h.panel.webview.html.includes('已退出'));
});
test('rejects foreign URLs and unexpected local routes',()=>{
  const h=host(()=>ready);
  for(const url of ['https://example.com/server/x/session/y','http://127.0.0.1:4400/server/x/session/y','http://127.0.0.1:4399/settings','http://user@127.0.0.1:4399/server/x/session/y'])
    assert.throws(()=>h.validate(url,'http://127.0.0.1:4399'));
});

test('options snapshot clipboard before pickers and propagate style and context',async()=>{
  const h=host(()=>ready);
  h.vscode.window.showQuickPick=async items=>{h.vscode.env.clipboard.readText=async()=> 'changed clipboard';return items.at(-1);};
  await h.commands.get('opencodeTutor.openWithOptions')();
  assert.equal(h.calls[0].text,'选中的原文');
  assert.ok(h.calls[0].args.includes('example'));assert.ok(h.calls[0].args.includes('none'));
  assert.ok(h.panel.webview.html.includes('本次原文'));
});
test('cancelling options sends nothing',async()=>{
  const h=host(()=>ready);h.vscode.window.showQuickPick=async()=>undefined;
  await h.commands.get('opencodeTutor.openWithOptions')();assert.equal(h.calls.length,0);
});
test('new-line action inherits selection-only mode and explanation style',async()=>{
  const h=host(()=>ready);
  try {
    await h.commands.get('opencodeTutor.openWithOptions')();
    const nonce=h.panel.webview.html.match(/<script nonce="([^"]+)"/)[1];
    h.vscode.env.clipboard.readText=async()=> 'changed clipboard';
    h.receive({action:'newLine',nonce});await new Promise(r=>setImmediate(r));
    assert.equal(h.calls.length,2);
    const call=h.calls[1];
    assert.equal(call.text,'选中的原文');
    assert.equal(call.args[call.args.indexOf('-Style')+1],'example');
    assert.equal(call.args[call.args.indexOf('-ContextMode')+1],'none');
    assert.ok(call.args.includes('-NewLine'));
    // A fresh keyboard invocation still uses the configured defaults.
    await h.commands.get('opencodeTutor.open')();
    assert.equal(h.calls[2].args[h.calls[2].args.indexOf('-ContextMode')+1],'relevant');
  } finally {h.dispose();}
});
for (const cancelledPicker of [1,2]) {
  test(`cancelling option picker ${cancelledPicker} preserves the iframe and abort controls`,async()=>{
    const result={...ready,learnSession:{id:'ses_learning',directory:'C:\\fakehome\\.config\\opencode\\learn\\lines'}};
    const h=host(()=>result);
    h.api.request=async(origin,route,method)=>{h.apiCalls.push({route,method});return {id:'ses_learning',title:'[LEARN] test',directory:result.learnSession.directory};};
    try {
      await h.commands.get('opencodeTutor.open')();
      const original=h.panel.webview.html;
      let picks=0;
      h.vscode.window.showQuickPick=async items=>++picks===cancelledPicker?undefined:items[0];
      const nonce=original.match(/<script nonce="([^"]+)"/)[1];
      h.receive({action:'options',nonce});await new Promise(r=>setImmediate(r));
      assert.equal(h.panel.webview.html,original);
      assert.equal(h.calls.length,1);
      await h.commands.get('opencodeTutor.abortGeneration')();
      assert.equal(h.apiCalls.filter(c=>c.method==='POST').length,1);
      assert.ok(h.apiCalls.at(-1).route.startsWith('/session/ses_learning/abort'));
    } finally {h.dispose();}
  });
}
test('cancel command invalidates a pending picker without losing the current view',async()=>{
  const h=host(()=>ready);
  try {
    await h.commands.get('opencodeTutor.open')();
    const original=h.panel.webview.html;
    let resolvePicker;
    h.vscode.window.showQuickPick=()=>new Promise(resolve=>{resolvePicker=resolve;});
    const pending=h.commands.get('opencodeTutor.openWithOptions')();
    await new Promise(r=>setImmediate(r));
    h.commands.get('opencodeTutor.cancelPreparation')();
    resolvePicker({value:'example'});await pending;
    assert.equal(h.calls.length,1);
    assert.equal(h.panel.webview.html,original);
  } finally {h.dispose();}
});
test('cooperative cancellation marks the request without killing the process',async()=>{
  const h=host(()=>({pending:true}));const opened=h.commands.get('opencodeTutor.open')();
  await new Promise(r=>setImmediate(r));
  h.commands.get('opencodeTutor.cancelPreparation')();
  assert.ok([...h.files.keys()].some(p=>p.includes('cancel-request.')));
  assert.ok(!h.calls[0].child.killed);
  h.calls[0].child.emit('close',1);await opened;
});
test('sent request remains inspectable after a transport error without retrying',async()=>{
  const h=host(()=>({...ready,error:'请求可能已被接收'}));
  await h.commands.get('opencodeTutor.open')();
  assert.equal(h.calls.length,1);assert.ok(h.panel.webview.html.includes('<iframe'));
  assert.ok(h.panel.webview.html.includes('请求可能已被接收'));
});
test('abort verifies learning identity and never targets the main session',async()=>{
  const result={...ready,learnSession:{id:'ses_learning',directory:'C:\\fakehome\\.config\\opencode\\learn\\lines'}};
  const h=host(()=>result);
  h.api.request=async(origin,route,method)=>{h.apiCalls.push({route,method});if(method==='POST')return true;return {id:'ses_learning',title:'[LEARN] test',directory:result.learnSession.directory};};
  try {
    await h.commands.get('opencodeTutor.open')();await h.commands.get('opencodeTutor.abortGeneration')();
    assert.equal(h.apiCalls.filter(c=>c.method==='POST').length,1);
    assert.ok(h.apiCalls.at(-1).route.startsWith('/session/ses_learning/abort'));
    h.api.request=async()=>({id:'ses_main',title:'Main',directory:'C:\\A'});
    await h.commands.get('opencodeTutor.abortGeneration')();
    assert.ok(h.statuses.at(-1).text.includes('校验失败'));
  } finally {h.dispose();}
});
test('untrusted webview messages cannot invoke actions',async()=>{
  const h=host(()=>ready);await h.commands.get('opencodeTutor.open')();
  h.receive({action:'newLine',nonce:'incorrect'});await new Promise(r=>setImmediate(r));
  assert.equal(h.calls.length,1);
});
test('progress markers update the panel and late cancellation admits the send',async()=>{
  const h=host(()=>({pending:true}));const opened=h.commands.get('opencodeTutor.open')();
  await new Promise(r=>setImmediate(r));
  const call=h.calls[0],id=call.options.env.OPENCODE_TUTOR_INVOCATION;
  const root=path.join('C:\\fakehome','.config','opencode','learn');
  h.files.set(path.join(root,`progress-request.${id}.json`),JSON.stringify({invocation:id,stage:'context'}));
  await new Promise(r=>setTimeout(r,230));
  assert.ok(h.panel.webview.html.includes('正在选取相关上下文'));
  h.commands.get('opencodeTutor.cancelPreparation')();
  h.files.set(path.join(root,`open-request.${id}.json`),JSON.stringify({invocation:id,...ready}));
  call.child.emit('close',0);await opened;
  assert.ok(h.panel.webview.html.includes('取消到达时请求已发送'));
  assert.ok(h.panel.webview.html.includes('<iframe'));
});
test('cancellation while discovering sessions never opens a picker or sends another request',async()=>{
  const h=host(()=>({pending:true}));const opened=h.commands.get('opencodeTutor.open')();
  await new Promise(r=>setImmediate(r));
  const call=h.calls[0],id=call.options.env.OPENCODE_TUTOR_INVOCATION;
  h.commands.get('opencodeTutor.cancelPreparation')();
  h.files.set(path.join('C:\\fakehome','.config','opencode','learn',`open-request.${id}.json`),JSON.stringify({invocation:id,...choices}));
  call.child.emit('close',0);await opened;
  assert.equal(h.picks.length,0);assert.equal(h.calls.length,1);
  assert.ok(h.panel.webview.html.includes('未发送'));
});
