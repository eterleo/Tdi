"""
Orchestrates one full evolution cycle, end to end:

  evolution_trigger.json (written by CCodeEvolutionEngine.mqh every N closed
  trades) -> load market memory -> pattern discovery -> propose new
  parameters (always) and, every other cycle, a structural module rewrite
  -> compile -> backtest -> version_manager promotes or rejects.

This is the one file with an opinion about ordering; everything it calls is
a pure building block. run_cycle.py is just a CLI entrypoint around
run_cycle() below, so it can be invoked manually or from a scheduler.
"""
from __future__ import annotations

import json
import logging
from dataclasses import asdict
from typing import Optional

from . import adaptive_weight_evolution, compiler, module_evolution, pattern_clustering, version_manager
from .ai_client import LocalAIClient
from .backtest_validator import run_backtest
from .config import Config
from .data_loader import load_all
from .param_evolution import StrategyParams, propose_next_version
from .pattern_discovery import discover

log = logging.getLogger(__name__)

# every Nth approved cycle also attempts a structural .mqh rewrite; the rest
# are parameter-only, which keeps the blast radius of any one cycle small
STRUCTURAL_EVOLUTION_EVERY_N_CYCLES = 2

DEFAULT_PARAMS = dict(
    atr_threshold=2.0,
    score_threshold=90,
    risk_percent_default=0.5,
    max_bars_between_choch_bos=15,
    news_block_minutes_before=30,
    news_block_minutes_after=30,
    liquidity_lookback_bars=20,
    impulse_atr_multiplier=1.5,
)


def _read_trigger(cfg: Config) -> Optional[dict]:
    if not cfg.evolution_trigger_json.exists():
        return None
    try:
        return json.loads(cfg.evolution_trigger_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        log.warning("evolution_trigger.json is malformed - ignoring.")
        return None


def _consume_trigger(cfg: Config) -> None:
    if cfg.evolution_trigger_json.exists():
        cfg.evolution_trigger_json.unlink()


def _current_params(cfg: Config, current_version: int) -> StrategyParams:
    if cfg.strategy_params_json.exists():
        data = json.loads(cfg.strategy_params_json.read_text(encoding="utf-8"))
        return StrategyParams(**data)
    return StrategyParams(version=current_version, **DEFAULT_PARAMS)


def run_cycle(cfg: Config) -> bool:
    """Returns True if a cycle actually ran to completion (approved or
    rejected); False if there was nothing to do."""
    trigger = _read_trigger(cfg)
    if trigger is None:
        log.info("No evolution trigger pending - nothing to do.")
        return False

    current_version = int(trigger.get("current_version", 1))
    next_version = current_version + 1

    data = load_all(cfg)
    if len(data.trades) < cfg.min_trades_for_pattern_discovery:
        log.info("Only %d trades logged (need %d) - skipping this cycle, trigger left for next time.",
                 len(data.trades), cfg.min_trades_for_pattern_discovery)
        return False

    discovery = discover(data)
    cluster_report = pattern_clustering.discover(data.sqlite_trades)
    current_params = _current_params(cfg, current_version)
    ai = LocalAIClient(cfg)

    next_params = propose_next_version(discovery, current_params, ai)
    next_params.version = next_version

    do_structural = next_version % STRUCTURAL_EVOLUTION_EVERY_N_CYCLES == 0
    module_key = module_evolution.pick_target_module(discovery) if do_structural else None
    module_file = module_evolution.WHITELISTED_MODULES.get(module_key) if module_key else None

    if do_structural:
        candidate_path = module_evolution.propose_module_rewrite(cfg, module_key, discovery, ai, next_version)
        if candidate_path is None:
            log.info("Structural rewrite of %s not produced this cycle - falling back to params-only.", module_key)
            do_structural = False
            module_file = None

    notes_prefix = f"target_module={module_key}; " if do_structural else ""
    changed_modules = [module_key] if (do_structural and module_key) else []
    param_diff = version_manager.diff_params(asdict(current_params), asdict(next_params))

    compile_result = compiler.compile_version(cfg, next_version)
    if compile_result.skipped:
        version_manager.reject_candidate(cfg, next_version,
                                         notes=f"{notes_prefix}compile skipped: {compile_result.log_text}",
                                         params=next_params)
        _consume_trigger(cfg)
        return True
    if not compile_result.ok:
        version_manager.reject_candidate(cfg, next_version,
                                         notes=f"{notes_prefix}compile failed ({compile_result.error_count} errors)",
                                         params=next_params)
        _consume_trigger(cfg)
        return True

    bt_result = run_backtest(cfg, next_version)
    if bt_result.skipped:
        version_manager.reject_candidate(cfg, next_version,
                                         notes=f"{notes_prefix}backtest skipped: {bt_result.reasons}",
                                         params=next_params)
        _consume_trigger(cfg)
        return True
    if not bt_result.passed:
        version_manager.reject_candidate(cfg, next_version, notes=f"{notes_prefix}" + "; ".join(bt_result.reasons),
                                         params=next_params)
        _consume_trigger(cfg)
        return True

    cluster_note = f"; best_cluster={cluster_report.best_cluster}" if cluster_report.best_cluster else ""
    notes = (f"{notes_prefix}{discovery.overall_win_rate_pct:.1f}% WR over {discovery.total_trades} trades; "
            f"backtest PF={bt_result.report.profit_factor:.2f} DD={bt_result.report.max_drawdown_pct:.1f}%"
            f"{cluster_note}")
    notes = version_manager.build_notes(notes, changed_modules=changed_modules, param_diff=param_diff)
    version_manager.approve_candidate(cfg, next_version, notes=notes, structural_change=do_structural,
                                      params=next_params, module_file=module_file)

    # adaptive confluence weights: hot-reloaded data, no compile/backtest of
    # their own - gated behind the same approval as strategy_params.json so
    # both live-reloaded files only ever move together on a validated cycle
    current_weights = adaptive_weight_evolution.current_weights(cfg)
    next_weights = adaptive_weight_evolution.propose_next_version(data.sqlite_trades, current_weights, ai)
    adaptive_weight_evolution.write_adaptive_weights(cfg, next_weights)

    _consume_trigger(cfg)
    return True
