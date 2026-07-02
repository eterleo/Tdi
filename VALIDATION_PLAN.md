# 60-Day Walk-Forward & Out-of-Sample Validation Plan

Do not fund this strategy with real capital until it has passed every stage
below. Each stage exists to catch a specific way retail systems fail
(overfitting, regime dependence, execution assumptions that don't hold live).

## Stage 0 — Data & In-Sample Fit (before Day 1)
1. Source at least 3 years of real BTC/USD 4H OHLCV from your execution venue (not a third-party proxy — basis differences change your fills).
2. Split chronologically: 60% in-sample (IS) fit window, 40% held out and **not looked at** until Stage 2.
3. On the IS window only, tune the handful of parameters in `config.py` (`lookback`, `sweep_buffer_atr`, `volume_spike_multiplier`, `min_risk_reward`). Cap yourself at **no more than 3 parameter sweeps** — each additional sweep on the same data is a curve-fit, not a discovery. Record every parameter set tried and its result, not just the winner.
4. Reject the strategy at this stage if `report.survives_friction` is `False` on the IS window. If friction alone kills the edge, no amount of live discipline fixes it.

## Stage 1 — Walk-Forward Analysis (Days 1–20)
1. Use rolling walk-forward windows: fit on a trailing N-month block, test on the next unseen month, then roll forward (anchored or rolling, pick one and keep it fixed).
2. Run `run_backtest.py` per fold; log `PerformanceReport` for each out-of-fold segment.
3. Pass criteria for this stage:
   - Expectancy_R > 0 in at least 70% of out-of-fold segments (not every single one — that's overfit).
   - No single fold's max drawdown exceeds 2x the Stage 0 IS max drawdown.
   - Parameter values stay reasonably stable fold-to-fold (if the "best" `lookback` swings from 10 to 60 between folds, the edge isn't real).
4. Record `final_historical_max_dd_pct` from the full walk-forward run — this is the number that seeds the circuit breaker (`CircuitBreaker(historical_max_dd_pct=...)`) for every later stage.

## Stage 2 — True Out-of-Sample Test (Days 21–35)
1. Run the fixed, already-tuned config (zero further changes) against the 40% held-out block from Stage 0 that has never been touched.
2. If OOS expectancy or max drawdown diverges sharply from the walk-forward numbers, stop — the walk-forward result was itself overfit to the fold structure, and you go back to Stage 0 with a different sweep budget, not a tweaked parameter.
3. Confirm the R:R distribution matches the design intent (`min_risk_reward=2.0` should show up as an avg win noticeably larger than avg loss in R terms — see STRATEGY.md Step 2).

## Stage 3 — Paper / Demo Execution (Days 36–60)
1. Deploy to a broker/exchange **demo or paper account** — same venue you intend to trade live, so fees and typical slippage are realistic, not simulated.
2. Run the strategy live-forward, tick-for-tick, with the `CircuitBreaker` from `src/risk.py` wired to the `historical_max_dd_pct` recorded in Stage 1 — this is not optional, it is the point of the exercise. Confirm you can trigger and observe the `"CRITICAL FAILSAFE TRIPPED: HALT ALL TRADING."` message under a synthetic forced-drawdown test before relying on it.
3. Log every live fill next to the price the strategy's logic expected. Compare actual slippage to the `slippage_bps` assumption in `config.py` — if real slippage consistently exceeds the assumption, the backtest was optimistic and the config needs correcting (then you must re-run Stages 1–2 with the corrected friction, you cannot just patch it going forward).
4. Track paper-trading expectancy weekly. Require at least 15–20 closed trades in the 25-day window before drawing any conclusion — fewer than that is not a sample, it's noise.

## Go/No-Go Gate (Day 60)
Advance to risking real capital only if **all** of the following hold:
- [ ] Stage 0: `survives_friction == True` on IS data.
- [ ] Stage 1: walk-forward expectancy positive in ≥70% of folds; parameters stable.
- [ ] Stage 2: OOS results consistent with walk-forward (no material divergence).
- [ ] Stage 3: paper-traded expectancy positive after real fills/fees; circuit breaker verified to trip correctly on a forced test.
- [ ] Max live-observed drawdown during paper trading stayed below the 1.5x circuit-breaker threshold (if it tripped, you understand exactly why before resetting it).

If any box is unchecked, the answer is to repeat the relevant stage with a
tighter sweep budget or a smaller position size — never to lower the bar.
