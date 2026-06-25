"""
Owns the "promote to live" / "reject" decision and every filesystem side
effect that follows it. This is the only module that writes to the live,
checked-in MQL5/Include tree or to strategy_params.json / version_status.json
- the files the running EA (via AIGateway / CodeEvolutionEngine) actually
reads. It does not itself validate anything; callers must have already
gotten a pass from both compiler.py and backtest_validator.py.

Every promoted version's full source snapshot stays on disk under
versions/vN/, so "rollback" is just re-promoting an older version's module
file - never a destructive git operation, and reversible at runtime.
"""
from __future__ import annotations

import json
import logging
import shutil
from dataclasses import asdict
from pathlib import Path
from typing import Optional

from .config import Config
from .param_evolution import StrategyParams

log = logging.getLogger(__name__)

LIVE_INCLUDE_DIR = Path(__file__).resolve().parent.parent / "MQL5" / "Include" / "XAU_SMC_SNIPER_AI"


def write_strategy_params(cfg: Config, params: StrategyParams) -> None:
    """Drop the new params where AIGateway.FetchParamUpdate expects them -
    picked up live on the EA's next timer tick, no restart required."""
    cfg.strategy_params_json.write_text(json.dumps(asdict(params), indent=2), encoding="utf-8")


def write_version_status(cfg: Config, version: int, status: str, notes: str,
                         structural_change: bool, params: Optional[StrategyParams]) -> None:
    """Schema must match CCodeEvolutionEngine::PollVersionStatus in
    CodeEvolutionEngine.mqh exactly - the EA reads this file directly."""
    payload = {
        "version": version,
        "status": status,
        "notes": notes,
        "structural_change": structural_change,
        "params": asdict(params) if params is not None else {},
    }
    cfg.version_status_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def promote_structural_candidate(cfg: Config, version: int, module_file: str) -> Path:
    """Copy a validated candidate module out of its isolated
    versions/vN/Include/XAU_SMC_SNIPER_AI/ workspace and into the live,
    checked-in include tree. Only call this after compiler.py AND
    backtest_validator.py have both passed - this function does not
    re-validate anything itself."""
    candidate = cfg.versions_dir / f"v{version}" / "Include" / "XAU_SMC_SNIPER_AI" / module_file
    if not candidate.exists():
        raise FileNotFoundError(f"promoted candidate missing on disk: {candidate}")
    dest = LIVE_INCLUDE_DIR / module_file
    shutil.copy2(candidate, dest)
    log.info("Promoted %s to live source (v%d).", module_file, version)
    return dest


def rollback_to_version(cfg: Config, version: int, module_file: str) -> Path:
    """Re-promote an older version's copy of one module - same mechanism as
    promotion, since every version's full source snapshot stays on disk
    under versions/vN/. Caller is responsible for also rewriting
    version_status.json / strategy_params.json to match."""
    return promote_structural_candidate(cfg, version, module_file)


def reject_candidate(cfg: Config, version: int, notes: str, params: Optional[StrategyParams] = None) -> None:
    write_version_status(cfg, version, status="rejected", notes=notes,
                         structural_change=False, params=params)
    log.info("Version %d rejected: %s", version, notes)


def approve_candidate(cfg: Config, version: int, notes: str, structural_change: bool,
                      params: StrategyParams, module_file: Optional[str] = None) -> None:
    if structural_change:
        if module_file is None:
            raise ValueError("structural_change=True requires module_file")
        promote_structural_candidate(cfg, version, module_file)
    write_strategy_params(cfg, params)
    write_version_status(cfg, version, status="approved", notes=notes,
                         structural_change=structural_change, params=params)
    log.info("Version %d approved (structural_change=%s).", version, structural_change)
