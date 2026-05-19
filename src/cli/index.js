#!/usr/bin/env node
'use strict';

const CDP = require('chrome-remote-interface');

const HOST = process.env.CDP_HOST || 'localhost';
const PORT = parseInt(process.env.CDP_PORT || '9222', 10);
const [,, command = 'status', ...args] = process.argv;

// ---------------------------------------------------------------------------
// CDP helpers
// ---------------------------------------------------------------------------
async function connect() {
  try {
    const client = await CDP({ host: HOST, port: PORT });
    return client;
  } catch (err) {
    console.error(`Cannot connect to CDP at ${HOST}:${PORT}`);
    console.error(`  ${err.message}`);
    console.error(`\nMake sure TradingView Desktop is running with:`);
    console.error(`  --remote-debugging-port=${PORT}`);
    process.exit(1);
  }
}

async function run(Runtime, expression, awaitPromise = false) {
  const r = await Runtime.evaluate({ expression, awaitPromise, returnByValue: true, silent: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'eval error');
  return r.result?.value;
}

function getWidget(Runtime) {
  return run(Runtime, `
    (() => {
      const w = window.tvWidget
        || Object.values(window).find(v => v && typeof v.activeChart === 'function');
      return w ? 'found' : null;
    })()
  `);
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------
const COMMANDS = {

  // ── status ────────────────────────────────────────────────────────────────
  async status() {
    const client = await connect();
    const { Runtime, Browser } = client;
    await Runtime.enable();

    console.log(`\nCDP  ${HOST}:${PORT}  CONNECTED ✓\n`);

    // Browser version
    try {
      const ver = await Browser.getVersion();
      console.log(`Browser : ${ver.product}`);
      console.log(`UA      : ${ver.userAgent.split(' ').slice(-1)[0]}`);
    } catch (_) {}

    // Chart widget
    const widget = await getWidget(Runtime);
    if (!widget) {
      console.log('\nTradingView chart widget not found on page.');
      await client.close(); return;
    }

    const symbol = await run(Runtime, `
      (() => { try { return (window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function')).activeChart().symbol(); } catch(e) { return null; } })()
    `);
    const resolution = await run(Runtime, `
      (() => { try { return (window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function')).activeChart().resolution(); } catch(e) { return null; } })()
    `);
    const studies = await run(Runtime, `
      (() => { try {
        const c = (window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function')).activeChart();
        return c.getAllStudies ? c.getAllStudies().map(s => s.name).join(', ') : '(API unavailable)';
      } catch(e) { return null; } })()
    `);

    console.log(`\nChart`);
    console.log(`  Symbol    : ${symbol     ?? '(not found)'}`);
    console.log(`  Timeframe : ${resolution ?? '(not found)'}`);
    console.log(`  Studies   : ${studies    ?? '(none)'}`);

    await client.close();
    console.log('\nStatus: OK\n');
  },

  // ── symbol ────────────────────────────────────────────────────────────────
  async symbol() {
    const sym = args[0];
    if (!sym) { console.error('Usage: node src/cli/index.js symbol XAUUSD'); process.exit(1); }
    const client = await connect();
    await client.Runtime.enable();
    await run(client.Runtime, `
      (() => {
        const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
        w.activeChart().setSymbol(${JSON.stringify(sym.toUpperCase())});
      })()
    `);
    console.log(`Symbol set to ${sym.toUpperCase()}`);
    await client.close();
  },

  // ── timeframe ─────────────────────────────────────────────────────────────
  async timeframe() {
    const tf = args[0];
    if (!tf) { console.error('Usage: node src/cli/index.js timeframe 1D|240|60|15|5'); process.exit(1); }
    const client = await connect();
    await client.Runtime.enable();
    await run(client.Runtime, `
      (() => {
        const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
        w.activeChart().setResolution(${JSON.stringify(tf)});
      })()
    `);
    console.log(`Timeframe set to ${tf}`);
    await client.close();
  },

  // ── screenshot ────────────────────────────────────────────────────────────
  async screenshot() {
    const label = args[0] || `chart_${Date.now()}`;
    const client = await connect();
    await client.Page.enable();
    const { data } = await client.Page.captureScreenshot({ format: 'png' });
    const fs   = require('fs');
    const path = require('path');
    const dir  = path.join(__dirname, '..', '..', 'screenshots');
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `${label}.png`);
    fs.writeFileSync(file, Buffer.from(data, 'base64'));
    console.log(`Screenshot saved: ${file}`);
    await client.close();
  },

  // ── analyse ───────────────────────────────────────────────────────────────
  async analyse() {
    // Delegate to the full analysis script
    require('../../analyse.js');
  },

  // ── help ──────────────────────────────────────────────────────────────────
  async help() {
    console.log(`
TradingView CDP CLI  (CDP_HOST=${HOST}  CDP_PORT=${PORT})

Commands:
  status                  Check connection, show current symbol + timeframe
  symbol   <SYM>          Switch chart to symbol (e.g. XAUUSD)
  timeframe <TF>          Switch timeframe (1D, 240, 60, 15, 5, 1)
  screenshot [label]      Save a PNG of the current chart
  analyse                 Run full SMC+TDI morning analysis
  help                    Show this message

Environment variables:
  CDP_HOST   (default: localhost)
  CDP_PORT   (default: 9222)
    `);
  },
};

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------
const handler = COMMANDS[command];
if (!handler) {
  console.error(`Unknown command: ${command}`);
  console.error(`Run:  node src/cli/index.js help`);
  process.exit(1);
}
handler().catch(err => { console.error('\nError:', err.message); process.exit(1); });
