/**
 * Local CDP proxy — run this on the Windows machine alongside TradingView.
 *
 * Sits between ngrok and Chrome's CDP port so it can rewrite the Host
 * header from the ngrok domain to localhost:9222 before Chrome sees it.
 *
 *   ngrok → proxy:3001 → Chrome CDP:9222
 *
 * Start ngrok to point at this proxy (NOT directly at 9222):
 *   ngrok http 3001
 *
 * Then run this file:
 *   node proxy.js
 */

'use strict';

const http      = require('http');
const httpProxy = require('http-proxy');

const CDP_PORT   = 9222;
const PROXY_PORT = 3001;
const CDP_TARGET = `http://localhost:${CDP_PORT}`;

const proxy = httpProxy.createProxyServer({ ws: true });

proxy.on('error', (err, req, res) => {
  console.error('Proxy error:', err.message);
  if (res && res.writeHead) {
    res.writeHead(502);
    res.end('Proxy error: ' + err.message);
  }
});

const server = http.createServer((req, res) => {
  // Rewrite Host so Chrome's CDP allowlist check passes
  req.headers['host'] = `localhost:${CDP_PORT}`;
  console.log(`HTTP  ${req.method} ${req.url}`);
  proxy.web(req, res, { target: CDP_TARGET });
});

// WebSocket support — required for the CDP debugger protocol
server.on('upgrade', (req, socket, head) => {
  req.headers['host'] = `localhost:${CDP_PORT}`;
  console.log(`WS    UPGRADE ${req.url}`);
  proxy.ws(req, socket, head, { target: CDP_TARGET });
});

server.listen(PROXY_PORT, '0.0.0.0', () => {
  console.log(`CDP proxy listening on port ${PROXY_PORT}`);
  console.log(`Forwarding → ${CDP_TARGET}  (Host rewritten to localhost:${CDP_PORT})`);
  console.log('');
  console.log('Point ngrok at this proxy:');
  console.log(`  ngrok http ${PROXY_PORT}`);
});
