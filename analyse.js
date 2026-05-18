/**
 * SMC + TDI Morning Analysis
 *
 * For XAUUSD, USDJPY, EURUSD:
 *   • Daily  — SMC bias, supply/demand zones, liquidity levels
 *   • 4H     — SMC bias, supply/demand zones, liquidity levels
 *   • 5M     — TDI indicator added, screenshot
 *   • 15M    — TDI indicator added, screenshot
 *
 * Saves 12 screenshots (2 timeframes × 3 pairs × 2 SMC+TDI groups)
 * then prints a scalping briefing with entry zone, SL and TP per pair.
 *
 * Usage:
 *   node analyse.js
 *
 * Prerequisites:
 *   proxy.js running on port 3001
 *   ngrok tunnelling https://clump-stunned-stank.ngrok-free.dev → port 3001
 */

'use strict';

const CDP  = require('chrome-remote-interface');
const https = require('https');
const fs   = require('fs');
const path = require('path');

const NGROK_HOST = 'clump-stunned-stank.ngrok-free.dev';
const NGROK_WSS  = `wss://${NGROK_HOST}`;
const HEADERS    = { 'ngrok-skip-browser-warning': 'true', 'User-Agent': 'tradingview-mcp/1.0' };
const OUT_DIR    = path.join(__dirname, 'screenshots');

const PAIRS = ['XAUUSD', 'USDJPY', 'EURUSD'];

// TDI = Traders Dynamic Index (RSI-based, 3 lines: GreenLine, RedLine, YellowLine)
const TDI_INDICATOR = {
  name: 'Traders Dynamic Index',
  shortName: 'TDI',
  // Pine script ID used by TradingView for the built-in / community TDI
  scriptIdPart: 'PUB;TDI',
};

// ---------------------------------------------------------------------------
// CDP bootstrap (same pattern as connect.js)
// ---------------------------------------------------------------------------
function fetchJson(urlPath) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      { hostname: NGROK_HOST, port: 443, path: urlPath, method: 'GET', headers: HEADERS },
      res => {
        let body = '';
        res.on('data', c => (body += c));
        res.on('end', () => {
          if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}: ${body.trim()}`));
          try { resolve(JSON.parse(body)); } catch (e) { reject(new Error('JSON parse: ' + body.slice(0, 120))); }
        });
      }
    );
    req.on('error', reject);
    req.end();
  });
}

async function connectCDP() {
  const targets = await fetchJson('/json');
  if (!targets?.length) throw new Error('No CDP targets — is TradingView running?');
  const target = targets.find(t => t.type === 'page' && /tradingview/i.test(`${t.url}${t.title}`))
               || targets.find(t => t.type === 'page')
               || targets[0];
  const wsUrl = NGROK_WSS + new URL(target.webSocketDebuggerUrl).pathname;
  const client = await CDP({ target: wsUrl, headers: HEADERS });
  await Promise.all([
    client.Runtime.enable(),
    client.Page.enable(),
    client.DOM.enable(),
  ]);
  return client;
}

// ---------------------------------------------------------------------------
// CDP helpers
// ---------------------------------------------------------------------------
async function run(Runtime, expression, awaitPromise = false) {
  const r = await Runtime.evaluate({ expression, awaitPromise, returnByValue: true, silent: false });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || JSON.stringify(r.exceptionDetails));
  return r.result?.value;
}

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function waitForChartReady(Runtime, timeoutMs = 12000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ready = await run(Runtime, `
      (function(){
        try {
          const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
          return !!(w && w.activeChart && w.activeChart().symbol());
        } catch(_) { return false; }
      })()
    `);
    if (ready) return;
    await sleep(600);
  }
  throw new Error('Chart did not become ready within timeout');
}

function getChart(Runtime) {
  return run(Runtime, `
    (function(){
      const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
      return w ? 'ok' : null;
    })()
  `);
}

async function setSymbol(Runtime, symbol) {
  await run(Runtime, `
    (function(){
      const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
      w.activeChart().setSymbol(${JSON.stringify(symbol)});
    })()
  `);
  await sleep(2500);
  await waitForChartReady(Runtime);
}

async function setTimeframe(Runtime, resolution) {
  // resolution: '1D', '240', '15', '5', etc.
  await run(Runtime, `
    (function(){
      const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
      w.activeChart().setResolution(${JSON.stringify(resolution)});
    })()
  `);
  await sleep(2000);
}

async function screenshot(Page, label) {
  if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
  const { data } = await Page.captureScreenshot({ format: 'png', captureBeyondViewport: false });
  const file = path.join(OUT_DIR, `${label}.png`);
  fs.writeFileSync(file, Buffer.from(data, 'base64'));
  console.log(`    📸 Saved: screenshots/${label}.png`);
  return file;
}

// ---------------------------------------------------------------------------
// TradingView drawing helpers (SMC)
// ---------------------------------------------------------------------------

/** Fetch OHLC data from TradingView's internal series for the active chart. */
async function getOHLC(Runtime, bars = 200) {
  return run(Runtime, `
    (function(){
      try {
        const chart = (window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function')).activeChart();
        const series = chart.getAllStudies ? null : null; // price series via datafeed
        // Use the chart's visible range bars
        const priceSeries = chart.getSeries ? chart.getSeries() : null;
        if (!priceSeries) return null;
        const data = priceSeries.data().bars();
        if (!data || !data.length) return null;
        const last = Math.min(data.length, ${bars});
        return data.slice(data.length - last).map(b => ({
          t: b.time, o: b.open, h: b.high, l: b.low, c: b.close
        }));
      } catch(e) { return 'ERROR:' + e.message; }
    })()
  `, false);
}

/**
 * Draw a horizontal line (supply/demand zone boundary or liquidity level).
 * TradingView widget API: createShape with 'horizontal_line'
 */
async function drawHLine(Runtime, price, color, text) {
  await run(Runtime, `
    (function(){
      const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
      const chart = w.activeChart();
      chart.createShape(
        { price: ${price} },
        {
          shape: 'horizontal_line',
          lock: false,
          disableSelection: false,
          overrides: {
            linecolor: ${JSON.stringify(color)},
            linewidth: 2,
            linestyle: 0,
            showLabel: true,
            text: ${JSON.stringify(text)},
            textcolor: ${JSON.stringify(color)},
            fontsize: 11,
          }
        }
      );
    })()
  `);
}

/**
 * Draw a filled rectangle between two prices over a time range
 * to represent a supply or demand zone.
 */
async function drawZone(Runtime, priceTop, priceBot, color, label) {
  // Use a price range shape (rectangle anchored to most recent bars)
  await run(Runtime, `
    (function(){
      const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
      const chart = w.activeChart();
      // Draw two boundary lines for the zone
      chart.createShape({ price: ${priceTop} }, {
        shape: 'horizontal_line',
        overrides: { linecolor: ${JSON.stringify(color)}, linewidth: 1, linestyle: 2,
                     showLabel: true, text: ${JSON.stringify(label + ' top')}, textcolor: ${JSON.stringify(color)}, fontsize: 10 }
      });
      chart.createShape({ price: ${priceBot} }, {
        shape: 'horizontal_line',
        overrides: { linecolor: ${JSON.stringify(color)}, linewidth: 1, linestyle: 2,
                     showLabel: true, text: ${JSON.stringify(label + ' bot')}, textcolor: ${JSON.stringify(color)}, fontsize: 10 }
      });
    })()
  `);
}

// ---------------------------------------------------------------------------
// Add TDI indicator via TradingView's addStudy API
// ---------------------------------------------------------------------------
async function addTDI(Runtime) {
  const result = await run(Runtime, `
    (function(){
      try {
        const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
        const chart = w.activeChart();
        // Try by name first (built-in or already-favourited)
        const studies = chart.getAllStudies ? chart.getAllStudies() : [];
        const hasTDI = studies.some(s => /tdi|traders.dynamic/i.test(s.name));
        if (hasTDI) return 'already_present';
        chart.createStudy('Traders Dynamic Index', false, false);
        return 'added';
      } catch(e) {
        // Fallback: try short name variants
        try {
          const w = window.tvWidget || Object.values(window).find(v => v && typeof v.activeChart === 'function');
          w.activeChart().createStudy('TDI', false, false);
          return 'added_short';
        } catch(e2) { return 'ERROR:' + e2.message; }
      }
    })()
  `);
  await sleep(1500);
  return result;
}

// ---------------------------------------------------------------------------
// SMC analysis: identify swing highs/lows, supply/demand zones, liquidity
// ---------------------------------------------------------------------------
function analyseOHLC(bars) {
  if (!bars || bars.length < 20) return null;

  // Find swing highs and lows (simple: local max/min over N bars)
  const swingN = 5;
  const swingHighs = [];
  const swingLows  = [];
  for (let i = swingN; i < bars.length - swingN; i++) {
    const slice = bars.slice(i - swingN, i + swingN + 1);
    const h = bars[i].h;
    const l = bars[i].l;
    if (h === Math.max(...slice.map(b => b.h))) swingHighs.push({ idx: i, price: h });
    if (l === Math.min(...slice.map(b => b.l))) swingLows.push({ idx: i, price: l });
  }

  // Recent high/low (last 50 bars)
  const recent = bars.slice(-50);
  const recentHigh = Math.max(...recent.map(b => b.h));
  const recentLow  = Math.min(...recent.map(b => b.l));
  const close      = bars[bars.length - 1].c;
  const bias       = close > (recentHigh + recentLow) / 2 ? 'BULLISH' : 'BEARISH';

  // Supply zone: last significant swing high area
  const lastSwingHigh = swingHighs.slice(-3).sort((a, b) => b.price - a.price)[0];
  // Demand zone: last significant swing low area
  const lastSwingLow  = swingLows.slice(-3).sort((a, b) => a.price - b.price)[0];

  // Liquidity levels: equal highs/lows (within 0.1% of each other)
  const eqHighs = [];
  const eqLows  = [];
  for (let i = 0; i < swingHighs.length - 1; i++) {
    const diff = Math.abs(swingHighs[i].price - swingHighs[i + 1].price) / swingHighs[i].price;
    if (diff < 0.001) eqHighs.push((swingHighs[i].price + swingHighs[i + 1].price) / 2);
  }
  for (let i = 0; i < swingLows.length - 1; i++) {
    const diff = Math.abs(swingLows[i].price - swingLows[i + 1].price) / swingLows[i].price;
    if (diff < 0.001) eqLows.push((swingLows[i].price + swingLows[i + 1].price) / 2);
  }

  // BOS / CHoCH detection (simplified)
  let structure = 'RANGING';
  const highs = swingHighs.slice(-5).map(s => s.price);
  const lows  = swingLows.slice(-5).map(s => s.price);
  const higherHighs = highs.every((h, i) => i === 0 || h > highs[i - 1]);
  const higherLows  = lows.every((l, i) => i === 0 || l > lows[i - 1]);
  const lowerHighs  = highs.every((h, i) => i === 0 || h < highs[i - 1]);
  const lowerLows   = lows.every((l, i) => i === 0 || l < lows[i - 1]);
  if (higherHighs && higherLows) structure = 'UPTREND (BOS ↑)';
  else if (lowerHighs && lowerLows) structure = 'DOWNTREND (BOS ↓)';
  else if (bias === 'BULLISH' && lowerHighs) structure = 'CHoCH → potential reversal up';
  else if (bias === 'BEARISH' && higherLows) structure = 'CHoCH → potential reversal down';

  return {
    bias,
    structure,
    close,
    recentHigh,
    recentLow,
    supplyZone:  lastSwingHigh ? { top: lastSwingHigh.price * 1.001, bot: lastSwingHigh.price * 0.999 } : null,
    demandZone:  lastSwingLow  ? { top: lastSwingLow.price  * 1.001, bot: lastSwingLow.price  * 0.999 } : null,
    equalHighs:  eqHighs,
    equalLows:   eqLows,
    swingHighs:  swingHighs.slice(-3),
    swingLows:   swingLows.slice(-3),
  };
}

function scalpSetup(symbol, daily, h4) {
  if (!daily || !h4) return null;

  const dp = 4; // decimal places
  const pip = symbol === 'XAUUSD' ? 0.1 : symbol === 'USDJPY' ? 0.01 : 0.0001;
  const slPips = symbol === 'XAUUSD' ? 3 : symbol === 'USDJPY' ? 8 : 8;
  const tp1Pips = slPips * 1.5;
  const tp2Pips = slPips * 3;

  const alignedBullish = daily.bias === 'BULLISH' && h4.bias === 'BULLISH';
  const alignedBearish = daily.bias === 'BEARISH' && h4.bias === 'BEARISH';

  let direction, entry, sl, tp1, tp2, rationale;

  if (alignedBullish && h4.demandZone) {
    direction = 'BUY';
    entry     = h4.demandZone.top;
    sl        = entry - slPips * pip;
    tp1       = entry + tp1Pips * pip;
    tp2       = entry + tp2Pips * pip;
    rationale = `Daily + 4H bullish. Price entering 4H demand zone. Target: ${h4.recentHigh.toFixed(dp)}`;
  } else if (alignedBearish && h4.supplyZone) {
    direction = 'SELL';
    entry     = h4.supplyZone.bot;
    sl        = entry + slPips * pip;
    tp1       = entry - tp1Pips * pip;
    tp2       = entry - tp2Pips * pip;
    rationale = `Daily + 4H bearish. Price entering 4H supply zone. Target: ${h4.recentLow.toFixed(dp)}`;
  } else if (h4.bias === 'BULLISH' && h4.demandZone) {
    direction = 'BUY (countertrend — reduce size)';
    entry     = h4.demandZone.top;
    sl        = entry - slPips * pip;
    tp1       = entry + tp1Pips * pip;
    tp2       = entry + tp2Pips * pip;
    rationale = `4H bullish but Daily ${daily.bias} — wait for Daily confirmation`;
  } else {
    direction = 'WAIT — no clean setup';
    entry     = h4.close;
    sl        = null;
    tp1       = null;
    tp2       = null;
    rationale = `Daily: ${daily.bias}, 4H: ${h4.bias} — structure unclear, no zone alignment`;
  }

  return { symbol, direction, entry, sl, tp1, tp2, rationale, dailyBias: daily.bias, h4Bias: h4.bias, dailyStructure: daily.structure, h4Structure: h4.structure };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log('═══════════════════════════════════════════════════════');
  console.log('  SMC + TDI MORNING ANALYSIS');
  console.log(`  ${new Date().toUTCString()}`);
  console.log('═══════════════════════════════════════════════════════\n');

  let client;
  try {
    process.stdout.write('Connecting to TradingView… ');
    client = await connectCDP();
    console.log('CONNECTED ✓\n');
  } catch (err) {
    console.error('Connection failed:', err.message);
    console.error('\nMake sure:');
    console.error('  1. proxy.js is running  (node proxy.js)');
    console.error('  2. ngrok is tunnelling to port 3001  (ngrok http 3001)');
    console.error('  3. TradingView Desktop is open with --remote-debugging-port=9222');
    process.exit(1);
  }

  const { Runtime, Page } = client;
  const results = {};

  for (const symbol of PAIRS) {
    console.log(`\n┌─── ${symbol} ${'─'.repeat(40 - symbol.length)}`);
    results[symbol] = {};

    // ── Daily ────────────────────────────────────────────────────────────
    process.stdout.write(`│  [1/4] Daily — switching chart… `);
    await setSymbol(Runtime, symbol);
    await setTimeframe(Runtime, '1D');
    console.log('done');

    const dailyBars = await getOHLC(Runtime, 200);
    const daily     = typeof dailyBars === 'string' ? null : analyseOHLC(dailyBars);

    if (daily) {
      console.log(`│        Bias: ${daily.bias}  |  Structure: ${daily.structure}`);
      console.log(`│        Range: ${daily.recentLow.toFixed(4)} – ${daily.recentHigh.toFixed(4)}`);
      if (daily.supplyZone) {
        await drawZone(Runtime, daily.supplyZone.top, daily.supplyZone.bot, '#ef5350', 'D Supply');
        console.log(`│        Supply zone drawn: ${daily.supplyZone.bot.toFixed(4)}–${daily.supplyZone.top.toFixed(4)}`);
      }
      if (daily.demandZone) {
        await drawZone(Runtime, daily.demandZone.top, daily.demandZone.bot, '#26a69a', 'D Demand');
        console.log(`│        Demand zone drawn: ${daily.demandZone.bot.toFixed(4)}–${daily.demandZone.top.toFixed(4)}`);
      }
      for (const liq of daily.equalHighs.slice(0, 2)) {
        await drawHLine(Runtime, liq, '#ffeb3b', 'EQH liq');
      }
      for (const liq of daily.equalLows.slice(0, 2)) {
        await drawHLine(Runtime, liq, '#ff9800', 'EQL liq');
      }
    }
    await sleep(500);
    const dailyFile = await screenshot(Page, `${symbol}_Daily`);
    results[symbol].daily = daily;

    // ── 4H ──────────────────────────────────────────────────────────────
    process.stdout.write(`│  [2/4] 4H   — switching chart… `);
    await setTimeframe(Runtime, '240');
    console.log('done');

    const h4Bars = await getOHLC(Runtime, 200);
    const h4     = typeof h4Bars === 'string' ? null : analyseOHLC(h4Bars);

    if (h4) {
      console.log(`│        Bias: ${h4.bias}  |  Structure: ${h4.structure}`);
      if (h4.supplyZone) {
        await drawZone(Runtime, h4.supplyZone.top, h4.supplyZone.bot, '#e53935', '4H Supply');
      }
      if (h4.demandZone) {
        await drawZone(Runtime, h4.demandZone.top, h4.demandZone.bot, '#00897b', '4H Demand');
      }
      for (const liq of h4.equalHighs.slice(0, 2)) {
        await drawHLine(Runtime, liq, '#ffe082', '4H EQH');
      }
      for (const liq of h4.equalLows.slice(0, 2)) {
        await drawHLine(Runtime, liq, '#ffb74d', '4H EQL');
      }
    }
    await sleep(500);
    await screenshot(Page, `${symbol}_4H`);
    results[symbol].h4 = h4;

    // ── 15M + TDI ────────────────────────────────────────────────────────
    process.stdout.write(`│  [3/4] 15M  — adding TDI… `);
    await setTimeframe(Runtime, '15');
    const tdi15 = await addTDI(Runtime);
    console.log(tdi15);
    await screenshot(Page, `${symbol}_15M_TDI`);

    // ── 5M + TDI ─────────────────────────────────────────────────────────
    process.stdout.write(`│  [4/4] 5M   — adding TDI… `);
    await setTimeframe(Runtime, '5');
    const tdi5 = await addTDI(Runtime);
    console.log(tdi5);
    await screenshot(Page, `${symbol}_5M_TDI`);

    console.log(`└${'─'.repeat(46)}`);
  }

  // ── Build scalping briefing ─────────────────────────────────────────────
  console.log('\n\n═══════════════════════════════════════════════════════');
  console.log('  SCALPING BRIEFING');
  console.log('═══════════════════════════════════════════════════════\n');

  const setups = PAIRS.map(sym => scalpSetup(sym, results[sym].daily, results[sym].h4));

  for (const s of setups) {
    if (!s) { console.log(`  ${s?.symbol ?? '?'}: insufficient data\n`); continue; }

    const f = (n, dec) => n != null ? Number(n).toFixed(dec ?? 4) : '—';
    const dp = s.symbol === 'XAUUSD' ? 2 : s.symbol === 'USDJPY' ? 3 : 4;

    console.log(`  ┌── ${s.symbol}`);
    console.log(`  │  Daily : ${s.dailyBias.padEnd(8)}  ${s.dailyStructure}`);
    console.log(`  │  4H    : ${s.h4Bias.padEnd(8)}  ${s.h4Structure}`);
    console.log(`  │`);
    console.log(`  │  Direction : ${s.direction}`);
    if (s.sl != null) {
      console.log(`  │  Entry     : ${f(s.entry, dp)}`);
      console.log(`  │  Stop Loss : ${f(s.sl,    dp)}`);
      console.log(`  │  TP1       : ${f(s.tp1,   dp)}`);
      console.log(`  │  TP2       : ${f(s.tp2,   dp)}`);
    }
    console.log(`  │  Note      : ${s.rationale}`);
    console.log(`  └${'─'.repeat(50)}\n`);
  }

  // Best setup
  const best = setups.find(s => s && !s.direction.includes('WAIT'));
  if (best) {
    console.log(`  ★  PRIORITY SETUP: ${best.symbol} — ${best.direction}`);
    console.log(`     Entry ${best.entry?.toFixed(4)} | SL ${best.sl?.toFixed(4)} | TP1 ${best.tp1?.toFixed(4)}\n`);
  } else {
    console.log('  ★  No clean setup this session — stay on the sidelines.\n');
  }

  const files = fs.readdirSync(OUT_DIR).filter(f => f.endsWith('.png'));
  console.log(`  Screenshots saved (${files.length}): ${OUT_DIR}\n`);

  await client.close();
}

main().catch(err => { console.error('\nFatal:', err.message); process.exit(1); });
