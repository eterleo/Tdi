/**
 * TradingView Desktop CDP connection via ngrok tunnel.
 *
 * Requires proxy.js running on the Windows machine:
 *   node proxy.js          # starts on port 3001, rewrites Host → localhost:9222
 *   ngrok http 3001        # tunnel ngrok to the proxy, NOT directly to 9222
 *
 * The proxy handles the Host rewrite so Chrome's CDP allowlist check passes.
 * No --host-header or --remote-allow-origins flags needed.
 *
 * Usage:
 *   node connect.js            # status + chart symbol/timeframe
 *   node connect.js --backtest # also run the SMC+TDI v4 backtest
 */

'use strict';

const CDP   = require('chrome-remote-interface');
const https = require('https');

const NGROK_HOST    = 'clump-stunned-stank.ngrok-free.dev';
const NGROK_URL     = `https://${NGROK_HOST}`;
const NGROK_WSS     = `wss://${NGROK_HOST}`;
const BACKTEST_PATH = 'C:\\Users\\Dell\\tradingview-mcp\\scripts\\backtest_smc_tdi_v4.js';
const RUN_BACKTEST  = process.argv.includes('--backtest');

// Only the ngrok interstitial header is needed — proxy.js handles Host rewriting.
const HEADERS = {
  'ngrok-skip-browser-warning': 'true',
  'User-Agent':                 'tradingview-mcp/1.0',
};

// ---------------------------------------------------------------------------
// Fetch /json using Node's native https module
// ---------------------------------------------------------------------------
function fetchJson(path) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      { hostname: NGROK_HOST, port: 443, path, method: 'GET', headers: HEADERS },
      (res) => {
        let body = '';
        res.on('data', (chunk) => (body += chunk));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            return reject(new Error(`HTTP ${res.statusCode}: ${body.trim()}`));
          }
          try { resolve(JSON.parse(body)); }
          catch (e) { reject(new Error(`JSON parse error: ${body.slice(0, 200)}`)); }
        });
      }
    );
    req.on('error', reject);
    req.end();
  });
}

/** Rewrite ws://127.0.0.1:9222/… → wss://<ngrok-host>/… */
function rewriteWsUrl(localUrl) {
  const u = new URL(localUrl);
  return `${NGROK_WSS}${u.pathname}`;
}

/** Prefer a TradingView page; fall back to any page target. */
function selectTarget(targets) {
  return (
    targets.find(t => t.type === 'page' && /tradingview/i.test(`${t.url}${t.title}`)) ||
    targets.find(t => t.type === 'page') ||
    targets[0]
  );
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------
async function connectCDP() {
  console.log('Connecting to TradingView Desktop via CDP…');
  console.log(`  Endpoint: ${NGROK_URL}  →  proxy:3001  →  Chrome:9222`);

  let targets;
  try {
    targets = await fetchJson('/json');
  } catch (err) {
    console.error(`\nFailed to fetch CDP targets: ${err.message}`);
    console.error('Make sure proxy.js is running on the Windows machine and');
    console.error('ngrok is tunnelling to port 3001 (not 9222 directly).');
    process.exit(1);
  }

  if (!targets?.length) {
    console.error('\nNo CDP targets found — is TradingView Desktop running?');
    process.exit(1);
  }

  console.log(`\nFound ${targets.length} CDP target(s):`);
  targets.forEach((t, i) => console.log(`  [${i}] ${t.type} — ${t.title || t.url}`));

  const target = selectTarget(targets);
  const wsUrl  = rewriteWsUrl(target.webSocketDebuggerUrl);
  console.log(`\nConnecting to: ${target.title || target.url}`);
  console.log(`  WebSocket: ${wsUrl}`);

  let client;
  try {
    client = await CDP({ target: wsUrl, headers: HEADERS });
  } catch (err) {
    console.error(`\nCDP WebSocket connection failed: ${err.message}`);
    process.exit(1);
  }

  return { client, target };
}

// ---------------------------------------------------------------------------
// Step 1 — connection status
// ---------------------------------------------------------------------------
async function checkConnection(client, target) {
  const { Runtime } = client;
  console.log('\n=== CONNECTION STATUS ===');
  console.log(`  Endpoint    : ${NGROK_URL}`);
  console.log(`  Target type : ${target.type}`);
  console.log(`  Target URL  : ${target.url}`);
  console.log(`  Target title: ${target.title}`);
  const ua = await evaluate(Runtime, 'navigator.userAgent');
  console.log(`  User-Agent  : ${ua}`);
  console.log('  Status      : CONNECTED ✓');
}

// ---------------------------------------------------------------------------
// Step 2 — current chart symbol & timeframe
// ---------------------------------------------------------------------------
async function getChartInfo(Runtime) {
  console.log('\n=== CHART INFO ===');

  const symbolScript = `(function() {
    try {
      if (window.tvWidget && typeof window.tvWidget.activeChart === 'function')
        return window.tvWidget.activeChart().symbol();
      const k = Object.keys(window).find(
        k => window[k] && typeof window[k].activeChart === 'function'
      );
      if (k) return window[k].activeChart().symbol();
      const el = document.querySelector('[data-name="legend-source-title"]');
      return el ? el.textContent.trim() : null;
    } catch(e) { return 'ERROR: ' + e.message; }
  })()`;

  const resolutionScript = `(function() {
    try {
      if (window.tvWidget && typeof window.tvWidget.activeChart === 'function')
        return window.tvWidget.activeChart().resolution();
      const k = Object.keys(window).find(
        k => window[k] && typeof window[k].activeChart === 'function'
      );
      if (k) return window[k].activeChart().resolution();
      const el = document.querySelector('[data-active-chart-time-zone]') ||
                 document.querySelector('.chart-toolbar [class*="interval"]');
      return el ? el.textContent.trim() : null;
    } catch(e) { return 'ERROR: ' + e.message; }
  })()`;

  const symbol     = await evaluate(Runtime, symbolScript);
  const resolution = await evaluate(Runtime, resolutionScript);

  console.log(`  Symbol    : ${symbol     ?? '(not found)'}`);
  console.log(`  Timeframe : ${resolution ?? '(not found)'}`);
  return { symbol, resolution };
}

// ---------------------------------------------------------------------------
// Step 3 — read backtest script from Electron FS and execute it
// ---------------------------------------------------------------------------
async function runBacktest(Runtime) {
  console.log('\n=== BACKTEST: SMC+TDI v4 ===');
  console.log(`  Script path: ${BACKTEST_PATH}`);

  const readScript = `(function() {
    try {
      const fs = require('fs');
      return fs.readFileSync(${JSON.stringify(BACKTEST_PATH)}, 'utf8');
    } catch(e1) {
      try {
        if (window.electronAPI && window.electronAPI.readFile)
          return window.electronAPI.readFile(${JSON.stringify(BACKTEST_PATH)});
      } catch(_) {}
      return 'READ_ERROR: ' + e1.message;
    }
  })()`;

  const scriptSource = await evaluate(Runtime, readScript);
  if (!scriptSource || scriptSource.startsWith('READ_ERROR:')) {
    throw new Error(`Could not read backtest script: ${scriptSource}`);
  }

  console.log(`  Script size: ${scriptSource.length} bytes`);
  console.log('  Executing…');

  const result = await evaluate(
    Runtime,
    `(async function() {\n${scriptSource}\n})()`,
    true
  );

  console.log('  Result :', result ?? '(completed — no return value)');
  console.log('  Status : DONE ✓');
  return result;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function evaluate(Runtime, expression, awaitPromise = false) {
  const result = await Runtime.evaluate({
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
// Main
// ---------------------------------------------------------------------------
async function main() {
  const { client, target } = await connectCDP();
  const { Runtime } = client;
  await Runtime.enable();

  try {
    await checkConnection(client, target);
    await getChartInfo(Runtime);
    if (RUN_BACKTEST) {
      await runBacktest(Runtime);
    } else {
      console.log('\n(Run with --backtest to also execute the SMC+TDI v4 backtest)');
    }
  } catch (err) {
    console.error(`\nError: ${err.message}`);
  } finally {
    await client.close();
    console.log('\nCDP connection closed.');
  }
}

main();
