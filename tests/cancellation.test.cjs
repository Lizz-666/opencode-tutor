const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');

async function fixture(t, cancelAt = '', sendStatus = 204) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tutor-cancellation-'));
  const lines = path.join(root, 'lines'), state = path.join(root, 'state.json');
  const invocation = 'cancellation-test', calls = [];
  const marker = name => path.join(root, `${name}-request.${invocation}.json`);
  const cancel = () => fs.writeFileSync(marker('cancel'), '{}');
  fs.mkdirSync(lines);
  fs.writeFileSync(state, JSON.stringify({ lines: { main: 'learn_old', other: 'learn_other' } }));
  fs.writeFileSync(path.join(root, 'config.json'), '{}');
  fs.writeFileSync(path.join(root, 'keybindings.json'), '[]');
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    calls.push(`${req.method} ${url.pathname}`);
    for await (const chunk of req) { /* drain the request */ }
    const json = value => { res.writeHead(200, {'Content-Type':'application/json; charset=utf-8'}); res.end(JSON.stringify(value)); };
    if (url.pathname === '/session' && req.method === 'GET') return json([{id:'main', title:'Main', directory:root, time:{updated:1}}]);
    if (url.pathname === '/session/status') { if (cancelAt === 'before-create') cancel(); return json({}); }
    if (url.pathname === '/session' && req.method === 'POST') {
      if (cancelAt === 'during-create') cancel();
      return json({id:'learn_new', title:'[LEARN] new', directory:lines});
    }
    if (/^\/session\/learn_(old|new)$/.test(url.pathname)) return json({id:url.pathname.split('/').at(-1), title:'[LEARN] line', directory:lines});
    if (url.pathname.endsWith('/message')) return json([]);
    if (url.pathname.endsWith('/prompt_async')) {
      if (cancelAt === 'during-send') cancel();
      res.writeHead(sendStatus, {'Content-Type':'application/json'}); return res.end(sendStatus === 204 ? undefined : '{}');
    }
    res.writeHead(404); res.end('{}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise(resolve => server.close(resolve));
    const target = path.resolve(root);
    assert.equal(path.dirname(target), path.resolve(os.tmpdir()));
    assert.ok(path.basename(target).startsWith('tutor-cancellation-'));
    fs.rmSync(target, {recursive:true, force:true});
  });
  const run = (newLine = false) => new Promise((resolve, reject) => {
    const args = ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'../scripts/explain.ps1'),
      '-ClipboardText','selected phrase','-ServerUrl',`http://127.0.0.1:${server.address().port}`,
      '-StateFile',state,'-LineDir',lines,'-WorkDir',root,'-OpenRequestDir',root,
      '-KeybindingsPath',path.join(root,'keybindings.json'),'-ConfigPath',path.join(root,'config.json'),
      '-OpencodeConfigPaths',path.join(root,'absent.json'),'-MainSessionId','main','-ContextMode','none'];
    if (newLine) args.push('-NewLine');
    const child = spawn('powershell.exe',args,{windowsHide:true,env:{...process.env,OPENCODE_TUTOR_INVOCATION:invocation,OPENCODE_TUTOR_STDIN:''}});
    let output = '';
    child.stdout.on('data', b => output += b.toString('utf8'));
    child.stderr.on('data', b => output += b.toString('utf8'));
    child.on('error',reject);
    child.on('close',code=>resolve({code,output,result:JSON.parse(fs.readFileSync(marker('open'),'utf8'))}));
  });
  return {run,calls,state:()=>JSON.parse(fs.readFileSync(state,'utf8')),clearCancellation:()=>fs.unlinkSync(marker('cancel'))};
}

for (const stage of ['before-create','during-create']) {
  test(`PowerShell entrypoint cancellation ${stage} preserves the current learning line`, {skip:process.platform!=='win32'}, async t => {
    const f = await fixture(t,stage);
    const cancelled = await f.run(true);
    assert.equal(cancelled.code,1,cancelled.output);
    assert.match(cancelled.result.error,/已取消准备/);
    assert.equal(cancelled.result.learnSession.id,'learn_old');
    assert.equal(f.state().lines.main,'learn_old');
    assert.equal(f.state().lines.other,'learn_other');
    assert.equal(f.calls.filter(c=>c.endsWith('/prompt_async')).length,0);
    assert.equal(f.calls.filter(c=>c==='POST /session').length,stage==='during-create'?1:0);
    f.clearCancellation();
    const next = await f.run();
    assert.equal(next.code,0,next.output);
    assert.equal(next.result.learnSession.id,'learn_old');
    assert.equal(f.calls.filter(c=>c==='POST /session/learn_old/prompt_async').length,1);
  });
}
test('an uncertain send keeps the new mapping and does not retry', {skip:process.platform!=='win32'}, async t => {
  const f = await fixture(t,'',500);
  const sent = await f.run(true);
  assert.equal(sent.code,1,sent.output);
  assert.match(sent.result.error,/请求可能已被接收/);
  assert.equal(sent.result.learnSession.id,'learn_new');
  assert.equal(f.state().lines.main,'learn_new');
  assert.equal(f.calls.filter(c=>c.endsWith('/prompt_async')).length,1);
});
test('cancellation after the send boundary retains the submitted learning session', {skip:process.platform!=='win32'}, async t => {
  const f = await fixture(t,'during-send');
  const sent = await f.run(true);
  assert.equal(sent.code,0,sent.output);
  assert.equal(sent.result.learnSession.id,'learn_new');
  assert.equal(f.state().lines.main,'learn_new');
  assert.equal(f.calls.filter(c=>c.endsWith('/prompt_async')).length,1);
});
