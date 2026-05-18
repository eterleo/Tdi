/**
 * TradingView Desktop CDP connection via ngrok tunnel.
 *
 * ── REQUIRED SETUP ──────────────────────────────────────────────────────────
 * Chrome's CDP server only accepts requests with Host: localhost/127.0.0.1.
 * ngrok's edge layer validates incoming Host matches its own domain, so you
 * cannot satisfy both with a plain HTTP tunnel.
 *
 * Fix — restart your tunnel with the host-header rewrite flag:
 *
 *   ngrok http 9222 --host-header="localhost:9222"
 *
 * ngrok will then accept the ngrok-domain Host (for its own routing) and
 * silently rewrite it to localhost:9222 before forwarding to Chrome.
 *
 * ── USAGE ───────────────────────────────────────────────────────────────────
 *   node connect.js            # status + chart symbol/timeframe
 *   node connect.js --backtest # also run the SMC+TDI v4 backtest
 */

'use strict';

const CDP   = require('chrome-remote-interface');

const NGROK_HOST    = 'clump-stunned-stank.ngrok-free.dev';
const NGROK_HTTPS   = `https://${NGROK_HOST}`;
const BACKTEST_PATH = 'C:\\Users\\Dell\\tradingview-mcp\\scripts\\backtest_smc_tdi_v4.js';
const RUN_BACKTEST  = process.argv.includes('--backtest');

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------
async function connectCDP() {
  console.log(`Connecting to TradingView Desktop via CDP…`);
  console.log(`  Endpoint : ${NGROK_HTTPS}`);

  let client;
  try {
    client = await CDP({
      host:        NGROK_HOST,
      port:        443,
      secure:      true,
      useHostName: true,
      // Passed through to the WebSocket constructor (ws package).
      // Also causes CRI to include them in the initial HTTP GET /json request.
      headers: {
        'ngrok-skip-browser-warning': 'true',
        'User-Agent': 'tradingview-mcp/1.0',
      },
    });
  } catch (err) {
    if (/host not in allowlist/i.test(err.message)) {
      console.error(`
ERROR: Chrome CDP rejected the connection — Host not in allowlist.

  ngrok forwards the request with Host: ${NGROK_HOST}, but Chrome only
  allows localhost / 127.0.0.1.  Restart your ngrok tunnel with:

      ngrok http 9222 --host-header="localhost:9222"

  That makes ngrok rewrite the Host header before forwarding to Chrome.
`);
    } else {
      console.error(`\nCDP connection failed: ${err.message}`);
    }
    process.exit(1);
  }

  return client;
}

// ---------------------------------------------------------------------------
// Step 1 — connection status
// ---------------------------------------------------------------------------
async function checkConnection(client) {
  const { Runtime } = client;
  const target      = client._target;

  console.log('\n=== CONNECTION STATUS ===');
  console.log(`  Endpoint    : ${NGROK_HTTPS}`);
  if (target) {
    console.log(`  Target type : ${target.type}`);
    console.log(`  Target URL  : ${target.url}`);
    console.log(`  Target title: ${target.title}`);
  }

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
      // Primary: tvWidget API (TradingView Desktop)
      if (window.tvWidget && typeof window.tvWidget.activeChart === 'function')
        return window.tvWidget.activeChart().symbol();
      // Fallback: scan window for any chart widget
      const k = Object.keys(window).find(
        k => window[k] && typeof window[k].activeChart === 'function'
      );
      if (k) return window[k].activeChart().symbol();
      // DOM fallback: legend title element
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
  const client = await connectCDP();
  const { Runtime } = client;
  await Runtime.enable();

  try {
    await checkConnection(client);
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
