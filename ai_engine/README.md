# ai_engine

Local-only AI evolution engine for **XAU_SMC_SNIPER_AI**. This process never
places trades and never talks to a cloud endpoint - it only reads the
market-memory files the EA writes to `Common\Files\XAU_SMC_SNIPER_AI\`,
proposes parameter and module changes, and validates every candidate
(compile + backtest) before anything reaches the live EA.

See `docs/ARCHITECTURE.md` at the repo root for the full design rationale,
in particular why "self-modifying code" is split into a live-tunable
parameter tier and a separately-validated structural-code tier.

## Install

```
pip install -r ai_engine/requirements.txt
```

`MetaTrader5` is optional and Windows-only; only `deploy_watchdog.py`'s
flat-check needs it. Everything else runs fine on Linux/macOS for
development - `compiler.py` and `backtest_validator.py` simply return a
`skipped=True` result (never a silent pass) when MetaEditor/terminal64
aren't available.

## Configuration

Everything lives in `ai_engine/config.py` and is overridable via
environment variables, e.g.:

| Env var | Purpose |
|---|---|
| `XSS_COMMON_FILES_DIR` | Where the EA's `Common\Files` actually is |
| `XSS_AI_PROVIDER` | `ollama` (default) or `openai_compatible` (LM Studio/vLLM) |
| `XSS_AI_BASE_URL` | e.g. `http://127.0.0.1:11434` |
| `XSS_AI_MODEL` | e.g. `qwen2.5-coder`, `deepseek-coder`, `llama3` |
| `XSS_METAEDITOR_PATH` | path to `MetaEditor64.exe` |
| `XSS_TERMINAL_PATH` | path to `terminal64.exe` |

## Running

```
python -m ai_engine.run_cycle              # check once, exit
python -m ai_engine.run_cycle --watch       # poll forever
```

Each poll: if the EA has written `evolution_trigger.json` (every
`InpEvolutionTradesPerCycle` closed trades) and enough trades are logged,
runs one full cycle:

1. `data_loader.load_all` + `pattern_discovery.discover` - bucket recent
   trades by session / regime / sweep / zone / score.
2. `param_evolution.propose_next_version` - ask the local AI for numeric
   tweaks (or fall back to a deterministic heuristic), then hard-clamp
   every value to `BOUNDS` and a max 20%-per-cycle step regardless of what
   the model said.
3. Every other cycle, `module_evolution.propose_module_rewrite` - ask the
   AI to rewrite one whitelisted `.mqh` (`Liquidity`, `MarketStructure`,
   `FairValueGap`, `SupplyDemand`), reject it outright if the public class
   interface changed, and stage it in an isolated
   `versions/vN/Include/XAU_SMC_SNIPER_AI/` workspace - never the live tree.
4. `compiler.compile_version` - MetaEditor compiles the staged candidate.
   Any failure (or being unable to compile at all) rejects the version.
5. `backtest_validator.run_backtest` - Strategy Tester run against the
   compiled candidate, checked against `min_profit_factor`,
   `max_drawdown_pct`, `min_win_rate_pct`, `min_trades_in_backtest`.
6. `version_manager.approve_candidate` / `reject_candidate` - only on a full
   pass does this write `strategy_params.json` (picked up live by
   `AIGateway`, no restart) and promote the candidate module into the live
   `MQL5/Include/XAU_SMC_SNIPER_AI/` tree, recording `structural_change` in
   `version_status.json` so the EA knows whether a restart-and-swap is
   needed.

`deploy_watchdog.check_and_deploy` runs alongside: when
`evolution_state.json` has `pending_restart: true`, it waits until this
EA's magic number has zero open positions, copies the compiled `.ex5` into
the live `Experts/` folder, and clears the flag - it never touches a
position to do so.

## Rollback

Every promoted version's full source tree stays on disk under
`versions/vN/`. `version_manager.rollback_to_version(cfg, version,
module_file)` re-promotes an older version's copy of one module using the
exact same promotion path - there is no destructive history.
