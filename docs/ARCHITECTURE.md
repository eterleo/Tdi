# XAU_SMC_SNIPER_AI — Architecture

Gold-only (XAUUSD) M1/M5 Smart Money Concepts sniper EA with a locally-hosted
AI evolution loop. Two halves, two languages, one shared on-disk contract.

```
MQL5/Experts/XAU_SMC_SNIPER_AI/XAU_SMC_SNIPER_AI.mq5   <- runs in the terminal, places trades
MQL5/Include/XAU_SMC_SNIPER_AI/*.mqh                    <- detection/risk/execution modules
ai_engine/                                              <- local Python process, NEVER trades
```

They talk to each other only through files under MT5's `Common\Files\`
folder (`FILE_COMMON`), so the EA and the Python process never need IPC,
sockets, or to even run on the same machine clock tick.

## Trading logic (MQL5 side)

| Timeframe | Role | Module |
|---|---|---|
| H1 | Bias | `TrendEngine.mqh` — EMA20/50 + BOS/CHOCH via an internal `MarketStructure` |
| M15 | Context | confluence scoring inputs |
| M5 | Setup | `Liquidity.mqh` (sweep), `FairValueGap.mqh` / `SupplyDemand.mqh` (zone) |
| M1 | Execution | `MarketStructure.mqh` — CHOCH → BOS sequence gate |

Entries are limit orders at the 50% midpoint of the triggering FVG/zone.
`SessionFilter.mqh` converts broker time to Qatar (GMT+3) and only allows
London (13–16) / NY (18–22) windows. `NewsFilter.mqh` blacks out ±30 min
around CPI/NFP/FOMC/PCE via the MT5 Calendar API with a CSV fallback.

`ConfluenceScore` (see `Defines.mqh`) sums H1 bias (20) + sweep (25) +
CHOCH (15) + BOS (15) + FVG/zone (15) + session (5) + ATR (5) = 100; a
trade requires `score_threshold` (default 90, AI-tunable, clamped to
[80,100]). `RiskManager.mqh` sizes positions at 0.5–1% risk, halts after 3
consecutive losses or -3%/-6% daily/weekly drawdown. `TradeManager.mqh`
moves to break-even at 1R and takes 50% partial profit at 2R, targeting
3–5R. `Telegram.mqh` reports every open/close/error/evolution event.

## Why "self-modifying code" is two tiers, not one

MQL5 **cannot** recompile or hot-swap its own running `.ex5` — there is no
API for an EA to rewrite and reload itself mid-session. Any design that
promises true single-process self-modification for MQL5 is not honest
about the platform. So evolution is split:

### Tier 1 — live parameter hot-reload (no restart, every cycle)

`ai_engine/param_evolution.py` proposes new values for the already-
parameterized numeric knobs in `AIStrategyParams` (`AIGateway.mqh`):
`atr_threshold`, `score_threshold`, `risk_percent_default`,
`max_bars_between_choch_bos`, the news blackout windows,
`liquidity_lookback_bars`, `impulse_atr_multiplier`. The AI's suggestion is
**never trusted directly**: every value is hard-clamped to a fixed
`(min, max)` range and to a max 20%-per-cycle step in
`param_evolution.BOUNDS` / `_clamp_step`, regardless of what the model
returned or whether the model was reachable at all (a deterministic
heuristic fallback covers the AI-unavailable case). `CAIGateway` polls
`strategy_params.json` and applies a newer version on its next timer tick
— no restart, no compile, no risk of the AI ever directly setting a
risk-critical value outside the safety envelope.

### Tier 2 — structural module rewrite (validated, then restart-on-flat)

Every other evolution cycle, `ai_engine/module_evolution.py` asks the local
AI to rewrite the *internal detection logic* of one whitelisted `.mqh`
(`Liquidity`, `MarketStructure`, `FairValueGap`, `SupplyDemand` — never
`RiskManager`/`TradeManager`/the main `.mq5`). The candidate:

1. Is written into an **isolated** `versions/vN/Include/XAU_SMC_SNIPER_AI/`
   workspace, seeded with a full copy of the current live include set —
   it never touches the checked-in source tree directly.
2. Is rejected before ever reaching a compiler if it changed the class name
   or dropped any public method the rest of the system calls by name
   (`module_evolution._preserves_public_interface`).
3. Must compile cleanly via MetaEditor's CLI (`ai_engine/compiler.py`).
4. Must clear backtest gates via the Strategy Tester
   (`ai_engine/backtest_validator.py`): `min_profit_factor`,
   `max_drawdown_pct`, `min_win_rate_pct`, `min_trades_in_backtest`.

Only if **both** pass does `ai_engine/version_manager.py` promote the
module into the live tree and write `version_status.json` with
`structural_change: true`. `CCodeEvolutionEngine::PollVersionStatus`
(`CodeEvolutionEngine.mqh`) reads that file, applies the new live params
immediately, and sets `pending_restart` — it keeps trading on its current
binary. `ai_engine/deploy_watchdog.py` polls that flag and only swaps the
compiled `.ex5` into the live `Experts/` folder once this EA's magic
number has **zero open positions** — it never touches a position to force
a swap.

Every promoted version's full source snapshot stays under `versions/vN/`,
so rollback is just `version_manager.rollback_to_version()` re-promoting an
older version's module file through the same path — never a destructive
git operation, always reversible at runtime.

## Shared on-disk contract (`Common\Files\XAU_SMC_SNIPER_AI\`)

| File | Writer | Reader | Purpose |
|---|---|---|---|
| `trades.csv` | EA (`MarketMemory`) | `ai_engine.data_loader` | one row per closed trade |
| `market_states.json` (JSONL) | EA | `ai_engine.data_loader` | per-bar snapshot log |
| `performance.csv` | EA | `ai_engine.data_loader` | rolling day/week stats |
| `strategy_history.json` (JSONL) | EA | `ai_engine.version_manager.search_history` | append-only, searchable version-transition log |
| `evolution_trigger.json` | EA | `ai_engine.evolution_engine` | "run a cycle now" signal, every N closed trades |
| `strategy_params.json` | `ai_engine.version_manager` | EA (`AIGateway`) | live numeric params, version-gated |
| `version_status.json` | `ai_engine.version_manager` | EA (`CodeEvolutionEngine`) | approve/reject verdict for one version |
| `evolution_state.json` | EA | `ai_engine.deploy_watchdog` | current version + `pending_restart` flag |
| `module_flags.json` | `ai_engine` (future) | EA (`CodeEvolutionEngine`) | module on/off toggles |
| `market_memory.sqlite` | EA (`MarketMemory`) | `ai_engine.data_loader` / `pattern_clustering` | structured mirror of `trades`, `rejected_setups`, `feature_snapshots` tables |
| `rejected_setups.csv` + table | EA (`MarketMemory`) | `ai_engine.data_loader` | setups that scored/were considered but not traded — learning from near-misses |
| `feature_snapshots.json` (JSONL) + table | EA (`FeatureEngine` via `MarketMemory`) | `ai_engine.data_loader` | engineered-feature vector per scan (`FeatureSnapshot`) |
| `adaptive_weights.json` | `ai_engine.adaptive_weight_evolution` | EA (`AdaptiveConfluence`) | live, version-gated weights for the adaptive confluence score |

No file in this directory is ever read by more than one side without going
through this table — the contract is the entire integration surface.

## v2.0 additions

Everything below is **additive**: every v1.0 struct, method signature, and
file is unchanged, and the legacy static `ConfluenceScore`/`BuildScore` gate
still runs exactly as before. v2.0 adds a parallel market-memory, analytics,
and adaptive-scoring layer on top.

- **`MarketRegime.mqh`** — classifies every bar into one of
  `ENUM_XSS_REGIME` (Strong/Weak Trend, Range, Expansion, Compression,
  High/Low Volatility, News Driven), independent of the legacy
  `CStatistics::ClassifyRegime` vol+session string still stored in
  `TradeRecord.regime` for backward compatibility. The new classification
  feeds `CStatistics::RegisterTrade`'s optional `regime` parameter for
  regime-segmented stats, and `TradeRecord.clusterKey`.
- **`FeatureEngine.mqh`** — computes a `FeatureSnapshot` (time since last
  sweep, distance to HTF liquidity, FVG size/fill %, zone age/touch count,
  BOS/CHOCH strength, trend slope, body/wick ratio, relative ATR, session
  progression, tick volume, swing distance, liquidity density, time between
  BOS events) on every scan — logged via `MarketMemory.LogFeatureSnapshot`
  for trades, rejections, and plain scans alike.
- **`AdaptiveConfluence.mqh`** — a second, weighted confluence score computed
  *alongside* the legacy score, with weights hot-reloaded from
  `adaptive_weights.json` the same version-gated way `AIGateway` reloads
  `strategy_params.json`. When `InpUseAdaptiveConfluence` is enabled it adds
  an extra `NormalizedPct(score) >= threshold` requirement on top of — never
  instead of — the legacy gate, so it can only make entries more
  conservative.
- **`ExecutionOptimizer.mqh`** — aggregates the slippage/latency/requote/
  missed-fill samples `TradeManager.mqh` already pushes to it (a "push"
  pattern via an optional `CExecutionOptimizer*` pointer) into avg/rate
  metrics for the dashboard. `TradeManager.mqh` also tracks per-position
  max favorable/adverse excursion (MFE/MAE) in R-multiples.
- **`Dashboard.mqh`** — a read-only on-chart panel (`OBJ_LABEL` /
  `OBJ_RECTANGLE_LABEL`, redrawn on the existing timer, not every tick)
  showing regime, strategy version, AI confidence, confluence score, risk,
  daily/weekly/all-time performance, best/worst regime by win rate, and
  execution quality. It owns no trading state and never influences entries.
- **`MarketMemory.mqh`** — gained a SQLite mirror (`market_memory.sqlite`)
  of the CSV/JSON logs (native MT5 `Database*` API), plus
  `rejected_setups.csv`/table (every setup that scored or was considered but
  not traded, with its reject reason) and `feature_snapshots.json`/table —
  so the AI can learn from near-misses, not just executed trades.
- **`CStatistics`** — gained Expectancy, Profit Factor, Avg Win/Loss,
  Recovery Factor, Sharpe/Sortino/Calmar ratios, and per-regime win-rate
  buckets (`RegisterTrade`'s new optional `regime` parameter), all backward
  compatible with the original `WinRatePct`/`AvgRR`/daily/weekly accessors.
- **`ai_engine/pattern_clustering.py`** — the Pattern Discovery Engine:
  groups closed trades by `TradeRecord.clusterKey` (regime+session+sweep+
  zone-type) and ranks clusters by win rate, profit factor, expectancy,
  drawdown, and average RR — a finer-grained complement to
  `pattern_discovery.py`'s single-dimension buckets.
- **`ai_engine/adaptive_weight_evolution.py`** — measures each confluence
  factor's win-rate lift (presence vs. absence in closed trades, reading
  `trades`/`features_json` from the SQLite mirror) and proposes new
  `AdaptiveWeights`, clamped to `[0, 60]` per weight with a max 15%-per-cycle
  step — mirroring `param_evolution.py`'s clamp discipline. Weights are only
  written on the same validated (compile+backtest-passing) cycle that writes
  `strategy_params.json`, so both live-reloaded files move together.
- **`ai_engine/version_manager.py`** — gained `diff_params` (field-level
  before/after diff), `build_notes` (appends modules-changed + param-diff
  to a version's notes without changing the `version_status.json` /
  `strategy_history.json` schema the EA reads), and `search_history`
  (filter the append-only history log by version/status/notes substring).

## What the AI never does

- Never calls `OrderSend` / places, modifies, or closes a trade.
- Never sets a risk-critical numeric value outside its hard-coded bounds.
- Never has its structural code changes applied without a clean compile
  *and* a passing backtest.
- Never runs against a cloud endpoint — `ai_client.py` only speaks to
  Ollama or an OpenAI-compatible local server (LM Studio, vLLM).
