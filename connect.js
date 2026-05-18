/**
 * TradingView Desktop CDP connection via ngrok tunnel.
 *
 * Chrome rejects CDP requests whose Host header doesn't match localhost.
 * ngrok rewrites the Host to its own domain, so we override it back to
 * "localhost:9222" on every HTTP and WebSocket request.
 *
 * Usage:
 *   node connect.js            # status + chart info
 *   node connect.js --backtest # also run SMC+TDI v4 backtest
 */

'use strict';

const fetch = require('node-fetch');
const WebSocket = require('ws');

const NGROK_URL      = 'https://clump-stunned-stank.ngrok-free.dev';
const NGROK_WSS      = NGROK_URL.replace(/^https?:\/\//, 'wss://');
const BACKTEST_PATH  = 'C:\\Users\\Dell\\tradingview-mcp\\scripts\\backtest_smc_tdi_v4.js';
const RUN_BACKTEST   = process.argv.includes('--backtest');

// Both headers are required:
//   Host                       → tricks Chrome's CDP allowlist check
//   ngrok-skip-browser-warning → bypasses the ngrok interstitial page
const COMMON_HEADERS = {
  'Host': 'localhost:9222',
  'ngrok-skip-browser-warning': 'true',
  'User-Agent': 'tradingview-mcp/1.0',
};

// ---------------------------------------------------------------------------
// Minimal CDP client built on raw `ws` so we can pass custom headers.
// ---------------------------------------------------------------------------
class CdpClient {
  constructor(wsUrl) {
    this._wsUrl  = wsUrl;
    this._msgId  = 0;
    this._pending = new Map();   // id → { resolve, reject }
    this._ws     = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this._wsUrl, { headers: COMMON_HEADERS });
      ws.on('open',    () => { this._ws = ws; resolve(); });
      ws.on('error',   (err) => reject(err));
      ws.on('message', (data) => this._onMessage(data));
      ws.on('close',   () => {
        for (const [, p] of this._pending) p.reject(new Error('WebSocket closed'));
        this._pending.clear();
      });
    });
  }

  send(method, params = {}) {
    const id = ++this._msgId;
    return new Promise((resolve, reject) => {
      this._pending.set(id, { resolve, reject });
      this._ws.send(JSON.stringify({ id, method, params }));
    });
  }

  _onMessage(data) {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    const pending = this._pending.get(msg.id);
    if (!pending) return;
    this._pending.delete(msg.id);
    if (msg.error) pending.reject(new Error(`CDP error ${msg.error.code}: ${msg.error.message}`));
    else pending.resolve(msg.result);
  }

  close() {
    if (this._ws) this._ws.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** GET /json through the tunnel with the spoofed Host header. */
async function fetchTargets() {
  const res = await fetch(`${NGROK_URL}/json`, { headers: COMMON_HEADERS });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`/json returned HTTP ${res.status}: ${body}`);
  }
  return res.json();
}

/** Pick the best CDP target — prefer TradingView page, fall back to first page. */
function selectTarget(targets) {
  return (
    targets.find((t) => t.type === 'page' && /tradingview/i.test(`${t.url}${t.title}`)) ||
    targets.find((t) => t.type === 'page') ||
    targets[0]
  );
}

/**
 * Rewrite the webSocketDebuggerUrl (which contains "127.0.0.1:9222" or
 * "localhost:9222") to use the ngrok host so the connection goes through
 * the tunnel.  The Host header override makes Chrome accept it.
 */
function rewriteWsUrl(localUrl) {
  const u = new URL(localUrl);
  return `${NGROK_WSS}${u.pathname}`;
}

/** Evaluate JS in the page; return the primitive result value. */
async function evaluate(client, expression, awaitPromise = false) {
  const result = await client.send('Runtime.evaluate', {
    expression,
    awaitPromise,
    returnByValue: true,
    silent: false,
  });
  if (result.exceptionDetails) {
    const msg =
      result.exceptionDetails.exception?.description ||
      JSON.stringify(result.exceptionDetails);
    throw new Error(`JS evaluation failed: ${msg}`);
  }
  return result.result?.value;
}

// ---------------------------------------------------------------------------
// Step 1 — connection status
// ---------------------------------------------------------------------------
async function checkConnection(client, target) {
  console.log('\n=== CONNECTION STATUS ===');
  console.log(`  Ngrok URL   : ${NGROK_URL}`);
  console.log(`  Target type : ${target.type}`);
  console.log(`  Target URL  : ${target.url}`);
  console.log(`  Target title: ${target.title}`);

  const ua = await evaluate(client, 'navigator.userAgent');
  console.log(`  User-Agent  : ${ua}`);
  console.log('  Status      : CONNECTED ✓');
}

// ---------------------------------------------------------------------------
// Step 2 — current chart symbol & timeframe
// ---------------------------------------------------------------------------
async function getChartInfo(client) {
  console.log('\n=== CHART INFO ===');

  // Try tvWidget API first, then DOM fallbacks.
  const symbolScript = `(function() {
    try {
      if (window.tvWidget && typeof window.tvWidget.activeChart === 'function')
        return window.tvWidget.activeChart().symbol();
      const k = Object.keys(window).find(k => window[k] && typeof window[k].activeChart === 'function');
      if (k) return window[k].activeChart().symbol();
      const el = document.querySelector('[data-name="legend-source-title"]');
      if (el) return el.textContent.trim();
      return null;
    } catch(e) { return 'ERROR: ' + e.message; }
  })()`;

  const resolutionScript = `(function() {
    try {
      if (window.tvWidget && typeof window.tvWidget.activeChart === 'function')
        return window.tvWidget.activeChart().resolution();
      const k = Object.keys(window).find(k => window[k] && typeof window[k].activeChart === 'function');
      if (k) return window[k].activeChart().resolution();
      const el = document.querySelector('[data-active-chart-time-zone]') ||
                 document.querySelector('.chart-toolbar [class*="interval"]');
      if (el) return el.textContent.trim();
      return null;
    } catch(e) { return 'ERROR: ' + e.message; }
  })()`;

  const symbol     = await evaluate(client, symbolScript);
  const resolution = await evaluate(client, resolutionScript);

  console.log(`  Symbol    : ${symbol     ?? '(not found)'}`);
  console.log(`  Timeframe : ${resolution ?? '(not found)'}`);
  return { symbol, resolution };
}

// ---------------------------------------------------------------------------
// Step 3 — read backtest script from disk (Electron FS) and execute it
// ---------------------------------------------------------------------------
async function runBacktest(client) {
  console.log('\n=== BACKTEST: SMC+TDI v4 ===');
  console.log(`  Script path: ${BACKTEST_PATH}`);

  // TradingView Desktop is an Electron app; the renderer process can access
  // the Node.js `fs` module when nodeIntegration is enabled.
  const readScript = `(function() {
    try {
      const fs = require('fs');
      return fs.readFileSync(${JSON.stringify(BACKTEST_PATH)}, 'utf8');
    } catch(e1) {
      try {
        if (window.electronAPI && window.electronAPI.readFile)
          return window.electronAPI.readFile(${JSON.stringify(BACKTEST_PATH)});
      } catch(e2) {}
      return 'READ_ERROR: ' + e1.message;
    }
  })()`;

  const scriptSource = await evaluate(client, readScript);
  if (!scriptSource || scriptSource.startsWith('READ_ERROR:')) {
    throw new Error(`Could not read backtest script: ${scriptSource}`);
  }

  console.log(`  Script size : ${scriptSource.length} bytes`);
  console.log('  Executing…');

  // Wrap in async IIFE so the backtest can use await at the top level.
  const result = await evaluate(
    client,
    `(async function() {\n${scriptSource}\n})()`,
    true /* awaitPromise */
  );

  console.log('  Result :', result ?? '(completed — no return value)');
  console.log('  Status : DONE ✓');
  return result;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('Connecting to TradingView Desktop via CDP over ngrok…');
  console.log(`  Endpoint: ${NGROK_URL}`);

  let targets;
  try {
    targets = await fetchTargets();
  } catch (err) {
    console.error(`\nFailed to fetch CDP targets: ${err.message}`);
    console.error('Ensure the ngrok tunnel is active and TradingView Desktop is open.');
    process.exit(1);
  }

  if (!targets?.length) {
    console.error('\nNo CDP targets found. Is TradingView Desktop running?');
    process.exit(1);
  }

  console.log(`\nFound ${targets.length} CDP target(s):`);
  targets.forEach((t, i) => console.log(`  [${i}] ${t.type} — ${t.title || t.url}`));

  const target = selectTarget(targets);
  const wsUrl  = rewriteWsUrl(target.webSocketDebuggerUrl);

  console.log(`\nSelected: ${target.title || target.url}`);
  console.log(`  WebSocket: ${wsUrl}`);

  const client = new CdpClient(wsUrl);
  try {
    await client.connect();
    await client.send('Runtime.enable');
  } catch (err) {
    console.error(`\nCDP connection failed: ${err.message}`);
    process.exit(1);
  }

  try {
    await checkConnection(client, target);
    await getChartInfo(client);
    if (RUN_BACKTEST) {
      await runBacktest(client);
    } else {
      console.log('\n(Add --backtest flag to also run the SMC+TDI v4 backtest)');
    }
  } catch (err) {
    console.error(`\nError: ${err.message}`);
  } finally {
    client.close();
    console.log('\nCDP connection closed.');
  }
}

main();
