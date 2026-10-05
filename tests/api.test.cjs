const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { request } = require('../extension/api');

test('local API parses JSON and sends a single explicit abort', async () => {
  const calls = [];
  const server = http.createServer((req,res) => {
    calls.push({url:req.url,method:req.method});
    if(req.url==='/bad-status'){res.writeHead(500);res.end('failure');return;}
    if(req.url==='/bad-json'){res.end('not json');return;}
    res.setHeader('Content-Type','application/json');res.end('{"ok":true}');
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`;
  try {
    assert.deepEqual(await request(origin,'/session/status'),{ok:true});
    await request(origin,'/session/ses_learning/abort','POST');
    assert.equal(calls.filter(c=>c.method==='POST').length,1);
    await assert.rejects(request(origin,'/bad-status'),/HTTP 500/);
    await assert.rejects(request(origin,'/bad-json'),/JSON/);
    await assert.rejects(request(origin,'http://example.com/session/status'),/本机/);
    assert.equal(calls.length,4);
  } finally {await new Promise(resolve=>server.close(resolve));}
});
