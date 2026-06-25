"""
Adaptive confluence weight evolution: proposes new weights for the eight
factors CAdaptiveConfluence.mqh scores (trend/sweep/choch/bos/fvg_zone/
session/atr/spread), asks the local AI for adjustments given measured
factor-presence win-rate lift, then clamps the result exactly the way
param_evolution.py clamps strategy parameters - small, bounded steps per
cycle, hard floor/ceiling regardless of what the model proposes.

Mirrors CAdaptiveConfluence's own ClampWeight(0, 60) bound and writes
adaptive_weights.json with the exact keys CAdaptiveConfluence::
FetchWeightUpdate reads (version, w_trend, w_sweep, w_choch, w_bos,
w_fvg_zone, w_session, w_atr, w_spread) - hot-reloaded by the EA on its
next timer tick, no restart required, same pattern as strategy_params.json.
"""
from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from statistics import median
from typing import Any, Callable, Dict, List, Optional

from .ai_client import LocalAIClient
from .config import Config

log = logging.getLogger(__name__)

# (min, max) safety clamps - matches CAdaptiveConfluence::ClampWeight(0, 60)
BOUNDS = {
    "w_trend": (0.0, 60.0),
    "w_sweep": (0.0, 60.0),
    "w_choch": (0.0, 60.0),
    "w_bos": (0.0, 60.0),
    "w_fvg_zone": (0.0, 60.0),
    "w_session": (0.0, 60.0),
    "w_atr": (0.0, 60.0),
    "w_spread": (0.0, 60.0),
}

# max fractional change allowed per evolution cycle, regardless of source -
# tighter than param_evolution's 0.20 since these eight weights interact
# multiplicatively across the whole adaptive confluence gate
MAX_STEP_PCT = 0.15

# a factor's presence/absence win-rate groups need at least this many trades
# each before its lift is trusted enough to move a weight
MIN_SAMPLES_PER_GROUP = 5

# 1 percentage-point of measured win-rate lift nudges the weight by this much
LIFT_TO_WEIGHT_SCALE = 0.3


@dataclass
class AdaptiveWeights:
    version: int
    w_trend: float
    w_sweep: float
    w_choch: float
    w_bos: float
    w_fvg_zone: float
    w_session: float
    w_atr: float
    w_spread: float

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)


DEFAULT_WEIGHTS = dict(
    w_trend=20.0,
    w_sweep=25.0,
    w_choch=15.0,
    w_bos=15.0,
    w_fvg_zone=15.0,
    w_session=5.0,
    w_atr=5.0,
    w_spread=0.0,
)


def _clamp_step(name: str, old: float, new: float) -> float:
    lo, hi = BOUNDS[name]
    max_delta = abs(old) * MAX_STEP_PCT if old != 0 else (hi - lo) * MAX_STEP_PCT
    new = max(old - max_delta, min(old + max_delta, new))
    return max(lo, min(hi, new))


def _trade_win(t: Dict[str, Any]) -> bool:
    return bool(int(t.get("win") or 0))


def _trade_features(t: Dict[str, Any]) -> Dict[str, Any]:
    raw = t.get("features_json")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}


def _win_rate(trades: List[Dict[str, Any]]) -> float:
    if not trades:
        return 0.0
    wins = sum(1 for t in trades if _trade_win(t))
    return 100.0 * wins / len(trades)


def _lift(trades: List[Dict[str, Any]], predicate: Callable[[Dict[str, Any]], bool]) -> Optional[float]:
    """Win-rate percentage-point delta between trades where predicate is True
    vs False. None if either group is too small to trust."""
    present = [t for t in trades if predicate(t)]
    absent = [t for t in trades if not predicate(t)]
    if len(present) < MIN_SAMPLES_PER_GROUP or len(absent) < MIN_SAMPLES_PER_GROUP:
        return None
    return _win_rate(present) - _win_rate(absent)


def measure_factor_lifts(trades: List[Dict[str, Any]]) -> Dict[str, Optional[float]]:
    """Measures each adaptive-confluence factor's win-rate lift directly from
    the trades table (CSV or SQLite mirror - same columns either way)."""
    spreads = [float(t.get("spread") or 0.0) for t in trades if t.get("spread") not in (None, "")]
    median_spread = median(spreads) if spreads else 0.0

    return {
        "w_trend": _lift(trades, lambda t: (t.get("regime") or "") in ("STRONG_TREND", "WEAK_TREND")),
        "w_sweep": _lift(trades, lambda t: (t.get("sweep") or "NONE") != "NONE"),
        "w_choch": _lift(trades, lambda t: _trade_features(t).get("chochStrength", 0) > 0),
        "w_bos": _lift(trades, lambda t: _trade_features(t).get("bosStrength", 0) > 0),
        "w_fvg_zone": _lift(trades, lambda t: bool(int(t.get("fvg_present") or 0))
                             or (t.get("zone_type") or "NONE") != "NONE"),
        "w_session": _lift(trades, lambda t: (t.get("session") or "NONE") in ("LONDON", "NEWYORK")),
        "w_atr": _lift(trades, lambda t: (t.get("regime") or "") in ("HIGH_VOLATILITY", "EXPANSION")),
        "w_spread": _lift(trades, lambda t: float(t.get("spread") or 0.0) <= median_spread),
    }


def _build_prompt(lifts: Dict[str, Optional[float]], current: AdaptiveWeights) -> str:
    return f"""You are tuning the adaptive confluence weights for a Smart Money
Concepts XAUUSD scalping system. You DO NOT place trades - you only suggest
numeric weight adjustments based on measured historical performance.

Current weights (each scored when its factor is present in a setup):
{current.to_json()}

Measured win-rate lift (percentage points) when each factor is present vs
absent in closed trades (null = not enough samples yet to trust):
{json.dumps(lifts, indent=2)}

A positive lift means that factor's presence correlates with more wins and
its weight should increase; a negative or near-zero lift means it should
decrease. Respond with ONLY a JSON object containing the SAME keys as
"Current weights" (omit "version"), with the weight values you recommend.
Omit keys you want to leave unchanged. Keep changes incremental - this runs
every ~50 trades. Do not include any explanation, only the JSON object.
"""


def _heuristic_fallback(lifts: Dict[str, Optional[float]], current: AdaptiveWeights) -> dict:
    """Deterministic nudge used when the local AI is unavailable: move each
    weight in the direction of its measured lift, scaled and step-capped."""
    updates: dict = {}
    for name, lift in lifts.items():
        if lift is None:
            continue
        old_val = float(getattr(current, name))
        updates[name] = old_val + lift * LIFT_TO_WEIGHT_SCALE
    return updates


def propose_next_version(trades: List[Dict[str, Any]], current: AdaptiveWeights, ai: LocalAIClient) -> AdaptiveWeights:
    lifts = measure_factor_lifts(trades)
    raw_updates: dict = {}

    resp = ai.generate(_build_prompt(lifts, current),
                       system="You output only valid JSON. No prose, no markdown fences.")
    if resp.ok:
        parsed = LocalAIClient.extract_json(resp.text)
        if isinstance(parsed, dict):
            raw_updates = parsed
        else:
            log.warning("AI response was not valid JSON, falling back to heuristic.")
    if not raw_updates:
        raw_updates = _heuristic_fallback(lifts, current)

    next_weights = AdaptiveWeights(**asdict(current))
    next_weights.version = current.version + 1

    for name in BOUNDS:
        if name not in raw_updates:
            continue
        try:
            new_val = float(raw_updates[name])
        except (TypeError, ValueError):
            continue
        old_val = float(getattr(current, name))
        setattr(next_weights, name, _clamp_step(name, old_val, new_val))

    return next_weights


def current_weights(cfg: Config, current_version: int = 0) -> AdaptiveWeights:
    if cfg.adaptive_weights_json.exists():
        data = json.loads(cfg.adaptive_weights_json.read_text(encoding="utf-8"))
        return AdaptiveWeights(**data)
    return AdaptiveWeights(version=current_version, **DEFAULT_WEIGHTS)


def write_adaptive_weights(cfg: Config, weights: AdaptiveWeights) -> None:
    """Drop the new weights where CAdaptiveConfluence::FetchWeightUpdate
    expects them - picked up live on the EA's next timer tick."""
    cfg.adaptive_weights_json.write_text(weights.to_json(), encoding="utf-8")
