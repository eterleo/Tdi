"""
Parameter evolution: asks the local AI model to propose new tunable
parameters given the pattern-discovery report, then clamps the result to
safe bounds regardless of what the model said. A deterministic heuristic
fallback kicks in if the AI is unreachable or returns unusable output -
the loop must never stall just because Ollama isn't running.

Only NUMERIC, ALREADY-PARAMETERIZED knobs are evolved here (matches
AIStrategyParams in MQL5/Include/XAU_SMC_SNIPER_AI/AIGateway.mqh). This is
deliberately conservative: never let a local LLM directly set risk-critical
values without a hard clamp.
"""
from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass

from .ai_client import LocalAIClient
from .pattern_discovery import DiscoveryReport

log = logging.getLogger(__name__)

# (min, max) safety clamps - the AI can move a parameter within this range,
# never outside it, no matter what it returns.
BOUNDS = {
    "atr_threshold": (1.0, 5.0),
    "score_threshold": (80, 100),
    "risk_percent_default": (0.1, 1.0),  # hard cap matches RiskManager InpRiskPercentMax
    "max_bars_between_choch_bos": (5, 30),
    "news_block_minutes_before": (15, 60),
    "news_block_minutes_after": (15, 60),
    "liquidity_lookback_bars": (10, 50),
    "impulse_atr_multiplier": (1.0, 3.0),
}

# max fractional change allowed per evolution cycle, regardless of source
MAX_STEP_PCT = 0.20


@dataclass
class StrategyParams:
    version: int
    atr_threshold: float
    score_threshold: int
    risk_percent_default: float
    max_bars_between_choch_bos: int
    news_block_minutes_before: int
    news_block_minutes_after: int
    liquidity_lookback_bars: int
    impulse_atr_multiplier: float

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)


def _clamp_step(name: str, old: float, new: float) -> float:
    lo, hi = BOUNDS[name]
    max_delta = abs(old) * MAX_STEP_PCT if old != 0 else (hi - lo) * MAX_STEP_PCT
    new = max(old - max_delta, min(old + max_delta, new))
    return max(lo, min(hi, new))


def _build_prompt(discovery: DiscoveryReport, current: StrategyParams) -> str:
    return f"""You are a quantitative trading-strategy tuner for a Smart Money Concepts
XAUUSD scalping system. You DO NOT place trades - you only suggest numeric
parameter adjustments based on historical performance data.

Current parameters:
{current.to_json()}

Performance breakdown (last cycle):
{json.dumps(discovery.to_dict(), indent=2)}

Respond with ONLY a JSON object containing the SAME keys as "Current
parameters", with values you recommend adjusting (omit keys you want to
leave unchanged). Keep changes incremental - this runs every ~50 trades.
Do not include any explanation, only the JSON object.
"""


def _heuristic_fallback(discovery: DiscoveryReport, current: StrategyParams) -> dict:
    """Small, explainable nudges used when the local AI is unavailable."""
    updates: dict = {}

    score_buckets = discovery.by_score_bucket
    high = score_buckets.get("95-100")
    mid = score_buckets.get("90-94")
    if high and mid and high.get("trades", 0) >= 5 and mid.get("trades", 0) >= 5:
        if high["win_rate_pct"] - mid["win_rate_pct"] >= 15:
            updates["score_threshold"] = current.score_threshold + 2  # tighten - quality gap is real
        elif mid["win_rate_pct"] >= high["win_rate_pct"] and mid["trades"] >= 10:
            updates["score_threshold"] = current.score_threshold - 1  # loosen slightly, no quality gap

    if discovery.total_trades >= 20:
        if discovery.overall_win_rate_pct < 35:
            updates["risk_percent_default"] = current.risk_percent_default * 0.8
        elif discovery.overall_win_rate_pct > 55 and discovery.overall_avg_rr > 0:
            updates["risk_percent_default"] = current.risk_percent_default * 1.1

    regimes = discovery.by_regime
    low_vol = {k: v for k, v in regimes.items() if k.startswith("low_vol")}
    if low_vol:
        worst = min(low_vol.values(), key=lambda v: v["win_rate_pct"])
        if worst.get("trades", 0) >= 5 and worst["win_rate_pct"] < 30:
            updates["atr_threshold"] = current.atr_threshold * 1.1  # demand more volatility

    return updates


def propose_next_version(discovery: DiscoveryReport, current: StrategyParams, ai: LocalAIClient) -> StrategyParams:
    raw_updates: dict = {}

    resp = ai.generate(_build_prompt(discovery, current),
                       system="You output only valid JSON. No prose, no markdown fences.")
    if resp.ok:
        parsed = LocalAIClient.extract_json(resp.text)
        if isinstance(parsed, dict):
            raw_updates = parsed
        else:
            log.warning("AI response was not valid JSON, falling back to heuristic.")
    if not raw_updates:
        raw_updates = _heuristic_fallback(discovery, current)

    next_params = StrategyParams(**asdict(current))
    next_params.version = current.version + 1

    for name in BOUNDS:
        if name not in raw_updates:
            continue
        try:
            new_val = float(raw_updates[name])
        except (TypeError, ValueError):
            continue
        old_val = float(getattr(current, name))
        clamped = _clamp_step(name, old_val, new_val)
        if name in ("score_threshold", "max_bars_between_choch_bos", "news_block_minutes_before",
                    "news_block_minutes_after", "liquidity_lookback_bars"):
            clamped = int(round(clamped))
        setattr(next_params, name, clamped)

    return next_params
