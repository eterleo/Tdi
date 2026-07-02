# Strategy Design — Liquidity Sweep Mean Reversion

## Step 1 — Market & Structural Edge

| Parameter | Choice | Why |
|---|---|---|
| Asset Class | Crypto — BTC/USD (spot or major perp) | Deepest liquidity, 24/7 clean session structure, no exchange halts to model. |
| Timeframe | 4-Hour | Filters intraday noise/spoofing that dominates 1m–15m crypto books while still producing ~6 signals/day of raw data (2190 bars/yr) — enough for statistically meaningful sampling. |
| Language | Python 3.11+ (pandas/numpy, no black-box backtest framework) | Full transparency into every fill, every friction deduction, every risk calc — nothing hidden in a vendored engine. |

### Candidate structural inefficiencies (price/volume/session based, no lagging indicator stacks)

1. **Liquidity Sweep Reversion (chosen, implemented below)** — Retail/algo stop-loss clusters sit just beyond obvious swing highs/lows. Market makers and large directional flow routinely push price through that level just far enough to trigger the stops and absorb the liquidity, then let price revert into the prior range. This is a microstructure fact (liquidity provision, not "trend"), and it prints a distinct fingerprint: a wick beyond structure + a close back inside it, often on a volume spike.
2. **Session Range Breakout Continuation** — The Asian session (00:00–08:00 UTC) typically compresses into a tight range; genuine directional continuation tends to start at the London (08:00 UTC) or NY (13:00 UTC) open when that range breaks with volume. Momentum, not reversion.
3. **Volatility Contraction Expansion** — Multi-bar contraction in true range (a "squeeze") historically precedes an expansion move; entry is taken on the breakout of the contraction range with a volatility-scaled stop.

We build #1 in full below because it has the cleanest, most objective trigger and the most consistent R:R skew.

## Step 2 — Strategy Rules: Liquidity Sweep Mean Reversion

### Definitions
- `swing_low[i]` = min(low) over the `lookback` bars preceding bar `i` (structure level, excludes bar `i` itself).
- `swing_high[i]` = max(high) over the `lookback` bars preceding bar `i`.
- `ATR[i]` = 14-period Average True Range at bar `i` (used only to size the invalidation buffer, not as a signal).

### Long entry trigger (short is the mirror image at swing highs)
```
if bar.low < swing_low[i]                      # price pierces below the liquidity pool
   and bar.close > swing_low[i]                 # but closes back inside the range (rejection)
   and bar.volume > avg_volume(lookback) * volume_spike_multiplier   # stop-run absorption confirmation
   and no_open_position:
       entry_price = bar.close                  # enter on the close of the sweep bar
       stop_price  = bar.low - (ATR[i] * sweep_buffer_atr)   # below the actual wick, plus buffer
       target_price = swing_high[i]              # prior range high = first liquidity target

       risk_per_unit   = entry_price - stop_price
       reward_per_unit = target_price - entry_price
       if reward_per_unit / risk_per_unit < min_risk_reward:   # e.g. 2.0
           SKIP TRADE   # structure doesn't pay — do not force it
       else:
           OPEN LONG
```

### Exit trigger
- **Invalidation (stop-loss):** hard stop at `stop_price`. No averaging down, no mental stops — the order is placed at entry time.
- **Profit target:** limit at `target_price` (the opposing structure level). No trailing/discretionary exit — this keeps the backtest and live behavior identical.
- **Time stop (optional, on by default):** flat if neither level is touched within `max_holding_bars` (default 12 bars = 48h) — stale setups are closed at market to avoid capital lockup in a decaying edge.

### R-Expectancy
`min_risk_reward = 2.0` is enforced at the trade-filter stage (see pseudocode above) — any setup where the nearest opposing structure doesn't offer at least 2R is **rejected**, not taken with a tighter target. This means win-rate can be as low as ~35–40% and the system is still expected to be profitable:

```
Expectancy(R) = (WinRate * AvgWin_R) - (LossRate * 1)
             ≈ (0.38 * 2.2) - (0.62 * 1) = 0.836 - 0.62 = +0.216 R / trade  (illustrative, pre-friction)
```

The actual win rate / avg R must come from the backtest (`src/metrics.py`), not from this assumption — this is just why a sub-50% win rate is survivable.
