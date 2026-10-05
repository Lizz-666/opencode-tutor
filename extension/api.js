const http = require('node:http');

function request(origin, route, method = 'GET') {
  const url = new URL(route, origin);
  if (url.origin !== origin || url.hostname !== '127.0.0.1' || url.protocol !== 'http:') {
    return Promise.reject(new Error('服务地址必须是配置的本机服务。'));
  }
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method, timeout: 8000 }, res => {
      let body = '', size = 0;
      res.setEncoding('utf8');
      res.on('data', chunk => {
        size += Buffer.byteLength(chunk);
        if (size > 1024 * 1024) { req.destroy(new Error('服务状态响应过大。')); return; }
        body += chunk;
      });
      res.on('error', reject);
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) return reject(new Error(`服务返回 HTTP ${res.statusCode}`));
        try { resolve(body ? JSON.parse(body) : null); } catch { reject(new Error('服务返回了无效 JSON。')); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('服务状态请求超时。')));
    req.on('error', reject);
    req.end();
  });
}
module.exports = { request };
