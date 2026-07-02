# Tdi — Liquidity Sweep Mean Reversion (BTC/USD, 4H)

An institutional-style systematic strategy built around one clean,
objective market-structure edge rather than a stack of lagging indicators —
designed to survive real execution friction and to shut itself off before
a real drawdown becomes a real blowup.

See **[STRATEGY.md](STRATEGY.md)** for the full market-structure rationale
and entry/exit rules (Steps 1–2), and **[VALIDATION_PLAN.md](VALIDATION_PLAN.md)**
for the 60-day walk-forward / out-of-sample protocol to run before any real
capital is at risk (Step 5).

## Layout

```
config.py                  All tunable parameters (Steps 1-4) in one place
STRATEGY.md                 Market inefficiency + entry/exit rules (Steps 1-2)
VALIDATION_PLAN.md          60-day walk-forward / OOS / paper-trading gate (Step 5)
src/
  strategy.py                Signal generation: swing structure, sweep detection, R:R filter
  friction.py                Slippage + commission model (Step 3)
  risk.py                    Position sizing + circuit breaker (Step 4)
  backtest.py                Event-driven engine wiring it all together
  metrics.py                 Win rate / expectancy / profit factor / drawdown / Sharpe
data/generate_sample_data.py Synthetic OHLCV generator (pipeline testing only — NOT real data)
run_backtest.py              CLI entry point
tests/                       Unit tests for friction, risk, and signal logic
```

## Quickstart

```bash
pip install -r requirements.txt
python run_backtest.py                      # uses/generates synthetic sample data
python run_backtest.py path/to/real_4h.csv  # CSV columns: timestamp,open,high,low,close,volume
pytest tests/ -q
```

`run_backtest.py` runs two passes:
1. **Baseline** — circuit breaker disabled, establishes the historical max
   drawdown that Step 4's breaker is measured against.
2. **Guarded** — re-runs with the circuit breaker armed at
   `1.5x` that baseline (`config.StrategyConfig.circuit_breaker_multiplier`),
   exactly as it would run in paper/live trading.

The printed `PerformanceReport` includes a `Verdict:` line — if friction
alone turns a positive-R-expectancy edge into a net loss, it prints
**"FAIL — FRICTION KILLS THE EDGE"** rather than a misleadingly clean equity
curve. Note: the bundled sample data is a synthetic random walk used only
to prove the pipeline runs end-to-end; it has no real edge and is expected
to fail. Point `run_backtest.py` at real OHLCV before drawing any
conclusion about the strategy itself.

## Step 4 risk controls at a glance

- **Position sizing** (`src/risk.py::position_size`): every trade risks
  exactly `risk_per_trade_pct` (default 1%) of *current* equity, sized
  dynamically off the distance to that trade's stop.
- **Circuit breaker** (`src/risk.py::CircuitBreaker`): tracks running
  drawdown against a pre-recorded historical baseline; the instant live
  drawdown reaches `1.5x` that baseline it raises `CircuitBreakerTripped`
  and prints `CRITICAL FAILSAFE TRIPPED: HALT ALL TRADING.` It stays
  halted until a human explicitly calls `.reset()` — it will never
  silently resume on its own.

## Next steps

1. Feed it real BTC/USD 4H OHLCV and run Stage 0 of `VALIDATION_PLAN.md`.
2. Only after clearing all 60 days of validation should this be pointed at
   a funded account — and even then, start at a fraction of intended size.
