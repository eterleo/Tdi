"""
Pattern discovery: slices the closed-trade history by session, volatility
regime, sweep type and zone type to find which conditions actually produce
edge. This summary is what gets handed to the local AI (and used as a
deterministic fallback if the AI is unavailable) for parameter evolution.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Dict, List

from .data_loader import MarketMemoryData, to_numeric


@dataclass
class BucketStats:
    trades: int = 0
    wins: int = 0
    profit: float = 0.0
    rr_sum: float = 0.0

    @property
    def win_rate_pct(self) -> float:
        return 100.0 * self.wins / self.trades if self.trades else 0.0

    @property
    def avg_rr(self) -> float:
        return self.rr_sum / self.trades if self.trades else 0.0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "trades": self.trades,
            "wins": self.wins,
            "win_rate_pct": round(self.win_rate_pct, 1),
            "avg_rr": round(self.avg_rr, 2),
            "profit": round(self.profit, 2),
        }


@dataclass
class DiscoveryReport:
    total_trades: int
    overall_win_rate_pct: float
    overall_avg_rr: float
    by_session: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    by_regime: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    by_sweep: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    by_zone_type: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    by_score_bucket: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    best_session: str = ""
    best_regime: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "total_trades": self.total_trades,
            "overall_win_rate_pct": round(self.overall_win_rate_pct, 1),
            "overall_avg_rr": round(self.overall_avg_rr, 2),
            "by_session": self.by_session,
            "by_regime": self.by_regime,
            "by_sweep": self.by_sweep,
            "by_zone_type": self.by_zone_type,
            "by_score_bucket": self.by_score_bucket,
            "best_session": self.best_session,
            "best_regime": self.best_regime,
        }


def _bucket_key_for_score(score: float) -> str:
    if score >= 95:
        return "95-100"
    if score >= 90:
        return "90-94"
    if score >= 80:
        return "80-89"
    return "<80"


def discover(data: MarketMemoryData) -> DiscoveryReport:
    trades = data.trades
    total = len(trades)

    session_buckets: Dict[str, BucketStats] = defaultdict(BucketStats)
    regime_buckets: Dict[str, BucketStats] = defaultdict(BucketStats)
    sweep_buckets: Dict[str, BucketStats] = defaultdict(BucketStats)
    zone_buckets: Dict[str, BucketStats] = defaultdict(BucketStats)
    score_buckets: Dict[str, BucketStats] = defaultdict(BucketStats)

    overall_wins = 0
    overall_rr_sum = 0.0

    for t in trades:
        win = to_numeric(t.get("win", "0")) >= 1
        profit = to_numeric(t.get("profit"))
        rr = to_numeric(t.get("rr"))
        score = to_numeric(t.get("score"))
        session = t.get("session", "NONE") or "NONE"
        regime = t.get("regime", "unknown") or "unknown"
        sweep = t.get("sweep", "NONE") or "NONE"
        zone = t.get("zone_type", "NONE") or "NONE"

        for bucket_map, key in (
            (session_buckets, session),
            (regime_buckets, regime),
            (sweep_buckets, sweep),
            (zone_buckets, zone),
            (score_buckets, _bucket_key_for_score(score)),
        ):
            b = bucket_map[key]
            b.trades += 1
            b.wins += 1 if win else 0
            b.profit += profit
            b.rr_sum += rr

        overall_wins += 1 if win else 0
        overall_rr_sum += rr

    report = DiscoveryReport(
        total_trades=total,
        overall_win_rate_pct=(100.0 * overall_wins / total) if total else 0.0,
        overall_avg_rr=(overall_rr_sum / total) if total else 0.0,
    )

    report.by_session = {k: v.to_dict() for k, v in session_buckets.items()}
    report.by_regime = {k: v.to_dict() for k, v in regime_buckets.items()}
    report.by_sweep = {k: v.to_dict() for k, v in sweep_buckets.items()}
    report.by_zone_type = {k: v.to_dict() for k, v in zone_buckets.items()}
    report.by_score_bucket = {k: v.to_dict() for k, v in score_buckets.items()}

    if session_buckets:
        report.best_session = max(session_buckets.items(), key=lambda kv: (kv[1].trades >= 5, kv[1].win_rate_pct))[0]
    if regime_buckets:
        report.best_regime = max(regime_buckets.items(), key=lambda kv: (kv[1].trades >= 5, kv[1].win_rate_pct))[0]

    return report
