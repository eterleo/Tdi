# XAU_SMC_SNIPER_AI

Self-evolving, locally-AI-assisted Smart Money Concepts sniper EA for
**XAUUSD only**, MetaTrader 5, M1/M5 execution with H1/M15 bias and context.

- **Bias (H1):** EMA20/50 + BOS/CHOCH via `TrendEngine.mqh`
- **Setup (M5):** liquidity sweep (`Liquidity.mqh`) + FVG/Supply-Demand zone
  (`FairValueGap.mqh` / `SupplyDemand.mqh`)
- **Execution (M1):** CHOCH → BOS sequence (`MarketStructure.mqh`), limit
  entry at the 50% FVG/zone midpoint
- **Filters:** Qatar-session London/NY windows (`SessionFilter.mqh`), ATR(14)
  volatility floor, spread cap, CPI/NFP/FOMC/PCE blackout (`NewsFilter.mqh`)
- **Confluence score** 0–100, default entry threshold 90 (`Defines.mqh`)
- **Risk:** 0.5–1% per trade, 3-loss / -3%/-6% daily/weekly circuit breaker
  (`RiskManager.mqh`), BE@1R + 50% partial@2R, 3–5R targets (`TradeManager.mqh`)
- **Alerts:** Telegram (`Telegram.mqh`)
- **Memory:** every trade, market snapshot, and strategy version logged to
  `Common\Files\XAU_SMC_SNIPER_AI\` (`MarketMemory.mqh`)

## Self-evolving AI loop

A locally-hosted model (Ollama / LM Studio / vLLM — never a cloud endpoint)
periodically reviews trade history and proposes:

- **Parameter tweaks** — applied live, hot-reloaded, hard-clamped to safe
  bounds regardless of what the model suggests.
- **Structural rewrites** of one whitelisted detection module at a time —
  isolated, interface-checked, compiled, and backtested before ever
  reaching the live EA; deployed only once the account is flat.

The AI **never places a trade**. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
for the full design, and [`ai_engine/README.md`](ai_engine/README.md) for
how to run the Python side.

## Layout

```
MQL5/Experts/XAU_SMC_SNIPER_AI/XAU_SMC_SNIPER_AI.mq5   main EA
MQL5/Include/XAU_SMC_SNIPER_AI/*.mqh                    detection/risk/execution modules
ai_engine/                                              local Python evolution engine
docs/ARCHITECTURE.md                                    full design writeup
```

## Disclaimer

This is a trading system template, not financial advice. Backtest and
forward-test on a demo account before risking real capital, and review
every AI-proposed change before it reaches a live account.
