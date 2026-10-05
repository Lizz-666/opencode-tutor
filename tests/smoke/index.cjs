const vscode = require('vscode');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

exports.run = async () => {
  const root = process.env.TUTOR_SMOKE_ROOT;
  if (!root) throw new Error('TUTOR_SMOKE_ROOT must point to an isolated test directory');
  const runtime = path.join(root, 'runtime');
  fs.mkdirSync(runtime, { recursive: true });
  const repo = path.resolve(__dirname, '../..');
  for (const name of ['explain.ps1', 'explain.lib.ps1', 'context.ps1']) fs.copyFileSync(path.join(repo, 'scripts', name), path.join(runtime, name));
  const project = vscode.workspace.workspaceFolders[0].uri.fsPath;
  let posted, loaded = false, streamed = false, followed = false, aborted = false;
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const json = data => {res.setHeader('Content-Type','application/json');res.end(JSON.stringify(data));};
    if (url.pathname === '/loaded') { loaded=true; return res.end('ok'); }
    if (url.pathname === '/streamed') { streamed=true; return res.end('ok'); }
    if (url.pathname === '/followup') { followed=true; return res.end('ok'); }
    if (url.pathname === '/events') {
      res.writeHead(200, {'Content-Type':'text/event-stream','Cache-Control':'no-cache'});
      res.end('data: reply-chunk\n\n');return;
    }
    if (url.pathname.startsWith('/server/')) {
      res.setHeader('Content-Type','text/html');
      return res.end(`<!doctype html><html><body><form id="follow"><input value="followup"><button>send</button></form>
      <script>fetch('/loaded');const es=new EventSource('/events');es.onmessage=()=>{fetch('/streamed');es.close();document.getElementById('follow').requestSubmit();};document.getElementById('follow').onsubmit=e=>{e.preventDefault();fetch('/followup',{method:'POST',body:'followup'});};</script></body></html>`);
    }
    if (url.pathname === '/session' && req.method === 'GET') return json([{id:'ses_main',title:'Smoke main',directory:project,time:{updated:1}}]);
    if (url.pathname === '/session/status') return json({ses_learn:{type:'idle'}});
    if (url.pathname === '/session/ses_learn') return json({id:'ses_learn',title:'[LEARN] smoke',directory:path.join(runtime,'lines')});
    if (url.pathname === '/session/ses_learn/abort') {aborted=true;return json(true);}
    if (url.pathname === '/session' && req.method === 'POST') return json({id:'ses_learn',title:'[LEARN] smoke',directory:url.searchParams.get('directory')});
    if (url.pathname === '/session/ses_main/message') return json([]);
    if (url.pathname === '/session/ses_learn/prompt_async') {
      let body='';req.on('data',d=>body+=d);req.on('end',()=>{posted=JSON.parse(body);res.writeHead(204);res.end();});return;
    }
    res.writeHead(404);res.end();
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  fs.writeFileSync(path.join(runtime,'config.json'),JSON.stringify({port:server.address().port}));
  const selection = 'opencode-tutor isolated smoke selection';
  const original = await vscode.env.clipboard.readText();
  try {
    await vscode.workspace.getConfiguration('opencodeTutor').update('learnDirectory',runtime,vscode.ConfigurationTarget.Global);
    await vscode.env.clipboard.writeText(selection);
    const extension = vscode.extensions.getExtension('lizz666.opencode-tutor-panel');
    assert.ok(extension,'Development extension discovered');
    await extension.activate();
    await vscode.commands.executeCommand('opencodeTutor.open');
    const deadline=Date.now()+25000;
    while(Date.now()<deadline && !(loaded&&streamed&&followed)) await new Promise(r=>setTimeout(r,200));
    assert.equal(posted?.parts[0].text,selection,'Selection reached mock backend');
    assert.ok(loaded,'Nested iframe JavaScript ran');
    assert.ok(streamed,'Nested iframe received a streamed event');
    assert.ok(followed,'Follow-up form submitted');
    assert.ok(posted.system.includes('简短解释'),'Selected explanation style reached backend');
    await vscode.commands.executeCommand('opencodeTutor.abortGeneration');
    assert.ok(aborted,'Only the learning session received abort');
    fs.writeFileSync(path.join(root,'result.json'),JSON.stringify({passed:true,loaded,streamed,followed,aborted}));
  } catch(error) {
    fs.writeFileSync(path.join(root,'result.json'),JSON.stringify({passed:false,error:String(error),posted:!!posted,loaded,streamed,followed}));
    throw error;
  } finally {
    if(await vscode.env.clipboard.readText()===selection) await vscode.env.clipboard.writeText(original);
    server.closeAllConnections();server.close();
  }
};
