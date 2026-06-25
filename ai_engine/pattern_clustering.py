"""
Pattern Discovery Engine (v2.0): groups closed trades by their cluster_key -
the categorical signature CMarketRegime+session+sweep+zone-type that
TradeManager/MarketMemory.mqh attaches to every TradeRecord
(StringFormat("%s_%s_%s_%s", regime, session, sweep, zone_type)).

This goes deeper than pattern_discovery.py's single-dimension buckets: each
cluster here represents one specific combination of market structure
conditions, ranked by win rate, profit factor, expectancy, drawdown and
average RR so the evolution engine (and the dashboard) can surface which
*combinations* of conditions actually produce edge, not just which single
factor correlates with it.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List

from .config import Config
from .data_loader import load_sqlite_trades


@dataclass
class ClusterStats:
    cluster_key: str
    trades: int = 0
    wins: int = 0
    profit: float = 0.0
    rr_sum: float = 0.0
    win_profit_sum: float = 0.0
    loss_profit_sum: float = 0.0
    peak_equity: float = 0.0
    max_drawdown: float = 0.0
    equity: float = 0.0  # running cumulative profit within this cluster only

    @property
    def win_rate_pct(self) -> float:
        return 100.0 * self.wins / self.trades if self.trades else 0.0

    @property
    def avg_rr(self) -> float:
        return self.rr_sum / self.trades if self.trades else 0.0

    @property
    def profit_factor(self) -> float:
        return self.win_profit_sum / self.loss_profit_sum if self.loss_profit_sum > 0.0 else 0.0

    @property
    def expectancy(self) -> float:
        if self.trades == 0:
            return 0.0
        losses = self.trades - self.wins
        win_rate = self.wins / self.trades
        loss_rate = losses / self.trades
        avg_win = self.win_profit_sum / self.wins if self.wins else 0.0
        avg_loss = self.loss_profit_sum / losses if losses else 0.0
        return win_rate * avg_win - loss_rate * avg_loss

    @property
    def recovery_factor(self) -> float:
        return self.profit / self.max_drawdown if self.max_drawdown > 0.0 else 0.0

    def record(self, profit: float, rr: float, win: bool) -> None:
        self.trades += 1
        self.profit += profit
        self.rr_sum += rr
        if win:
            self.wins += 1
            self.win_profit_sum += profit
        else:
            self.loss_profit_sum += abs(profit)

        self.equity += profit
        if self.equity > self.peak_equity:
            self.peak_equity = self.equity
        dd = self.peak_equity - self.equity
        if dd > self.max_drawdown:
            self.max_drawdown = dd

    def to_dict(self) -> Dict[str, Any]:
        return {
            "cluster_key": self.cluster_key,
            "trades": self.trades,
            "wins": self.wins,
            "win_rate_pct": round(self.win_rate_pct, 1),
            "profit_factor": round(self.profit_factor, 2),
            "expectancy": round(self.expectancy, 2),
            "avg_rr": round(self.avg_rr, 2),
            "max_drawdown": round(self.max_drawdown, 2),
            "recovery_factor": round(self.recovery_factor, 2),
            "profit": round(self.profit, 2),
        }


@dataclass
class ClusterDiscoveryReport:
    total_clusters: int = 0
    min_trades_per_cluster: int = 5
    clusters: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    ranked_by_win_rate: List[str] = field(default_factory=list)
    ranked_by_profit_factor: List[str] = field(default_factory=list)
    ranked_by_expectancy: List[str] = field(default_factory=list)
    ranked_by_avg_rr: List[str] = field(default_factory=list)
    ranked_by_drawdown: List[str] = field(default_factory=list)  # ascending - lowest (best) drawdown first
    best_cluster: str = ""
    worst_cluster: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "total_clusters": self.total_clusters,
            "min_trades_per_cluster": self.min_trades_per_cluster,
            "clusters": self.clusters,
            "ranked_by_win_rate": self.ranked_by_win_rate,
            "ranked_by_profit_factor": self.ranked_by_profit_factor,
            "ranked_by_expectancy": self.ranked_by_expectancy,
            "ranked_by_avg_rr": self.ranked_by_avg_rr,
            "ranked_by_drawdown": self.ranked_by_drawdown,
            "best_cluster": self.best_cluster,
            "worst_cluster": self.worst_cluster,
        }


def build_clusters(trades: List[Dict[str, Any]]) -> Dict[str, ClusterStats]:
    clusters: Dict[str, ClusterStats] = {}
    for t in trades:
        key = (t.get("cluster_key") or "").strip()
        if not key:
            continue
        stats = clusters.setdefault(key, ClusterStats(cluster_key=key))
        profit = float(t.get("profit") or 0.0)
        rr = float(t.get("rr") or 0.0)
        win = bool(int(t.get("win") or 0))
        stats.record(profit, rr, win)
    return clusters


def discover(trades: List[Dict[str, Any]], min_trades_per_cluster: int = 5) -> ClusterDiscoveryReport:
    """Ranks clusters by Win Rate / Profit Factor / Expectancy / Drawdown / Avg RR.
    Clusters with fewer than min_trades_per_cluster samples are excluded from
    ranking - too few trades to trust the statistics, but they still
    accumulate in the underlying store for when they cross the threshold."""
    clusters = build_clusters(trades)
    eligible = {k: v for k, v in clusters.items() if v.trades >= min_trades_per_cluster}

    report = ClusterDiscoveryReport(total_clusters=len(eligible), min_trades_per_cluster=min_trades_per_cluster)
    report.clusters = {k: v.to_dict() for k, v in eligible.items()}

    if eligible:
        report.ranked_by_win_rate = [k for k, _ in
                                      sorted(eligible.items(), key=lambda kv: kv[1].win_rate_pct, reverse=True)]
        report.ranked_by_profit_factor = [k for k, _ in
                                           sorted(eligible.items(), key=lambda kv: kv[1].profit_factor, reverse=True)]
        report.ranked_by_expectancy = [k for k, _ in
                                        sorted(eligible.items(), key=lambda kv: kv[1].expectancy, reverse=True)]
        report.ranked_by_avg_rr = [k for k, _ in
                                    sorted(eligible.items(), key=lambda kv: kv[1].avg_rr, reverse=True)]
        report.ranked_by_drawdown = [k for k, _ in sorted(eligible.items(), key=lambda kv: kv[1].max_drawdown)]
        report.best_cluster = report.ranked_by_expectancy[0]
        report.worst_cluster = report.ranked_by_expectancy[-1]

    return report


def load_and_discover(cfg: Config, min_trades_per_cluster: int = 5) -> ClusterDiscoveryReport:
    trades = load_sqlite_trades(cfg)
    return discover(trades, min_trades_per_cluster=min_trades_per_cluster)
