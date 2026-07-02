"""Performance metrics computed from a closed-trade log and an equity curve.

Deliberately reports R-multiples (not just cash P&L) since the strategy's
edge is defined in R (see STRATEGY.md) — a strategy with negative cash P&L
after friction but positive R would still be a friction failure, and this
module makes that visible rather than papering over it with a single number.
"""
from dataclasses import dataclass

import numpy as np
import pandas as pd


@dataclass
class PerformanceReport:
    total_trades: int
    win_rate: float
    avg_win_r: float
    avg_loss_r: float
    expectancy_r: float
    profit_factor: float
    max_drawdown_pct: float
    sharpe_ratio: float
    net_pnl: float
    total_friction_cost: float
    survives_friction: bool

    def __str__(self) -> str:
        verdict = "PASS" if self.survives_friction else "FAIL — FRICTION KILLS THE EDGE"
        return (
            f"Trades: {self.total_trades} | Win rate: {self.win_rate:.1%}\n"
            f"Avg win: {self.avg_win_r:.2f}R | Avg loss: {self.avg_loss_r:.2f}R | "
            f"Expectancy: {self.expectancy_r:+.3f}R/trade\n"
            f"Profit factor: {self.profit_factor:.2f} | Max drawdown: {self.max_drawdown_pct:.2%} | "
            f"Sharpe (per-trade): {self.sharpe_ratio:.2f}\n"
            f"Net P&L: {self.net_pnl:,.2f} | Total friction cost: {self.total_friction_cost:,.2f}\n"
            f"Verdict: {verdict}"
        )


def max_drawdown(equity_curve: pd.Series) -> float:
    running_peak = equity_curve.cummax()
    drawdown = (running_peak - equity_curve) / running_peak
    return float(drawdown.max()) if len(drawdown) else 0.0


def build_report(trades: pd.DataFrame, equity_curve: pd.Series) -> PerformanceReport:
    """`trades` must have columns: pnl_r, pnl_cash, friction_cost."""
    if trades.empty:
        return PerformanceReport(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, False)

    wins = trades[trades["pnl_r"] > 0]
    losses = trades[trades["pnl_r"] <= 0]

    win_rate = len(wins) / len(trades)
    avg_win_r = float(wins["pnl_r"].mean()) if len(wins) else 0.0
    avg_loss_r = float(losses["pnl_r"].mean()) if len(losses) else 0.0  # negative
    expectancy_r = float(trades["pnl_r"].mean())

    gross_profit = wins["pnl_cash"].sum()
    gross_loss = -losses["pnl_cash"].sum()
    profit_factor = float(gross_profit / gross_loss) if gross_loss > 0 else float("inf")

    r_std = trades["pnl_r"].std(ddof=1) if len(trades) > 1 else 0.0
    sharpe = float(expectancy_r / r_std) if r_std > 0 else 0.0

    net_pnl = float(trades["pnl_cash"].sum())
    total_friction = float(trades["friction_cost"].sum())

    return PerformanceReport(
        total_trades=len(trades),
        win_rate=win_rate,
        avg_win_r=avg_win_r,
        avg_loss_r=avg_loss_r,
        expectancy_r=expectancy_r,
        profit_factor=profit_factor,
        max_drawdown_pct=max_drawdown(equity_curve),
        sharpe_ratio=sharpe,
        net_pnl=net_pnl,
        total_friction_cost=total_friction,
        # A strategy "fails friction" if it's only profitable because friction
        # is being ignored: i.e. expectancy is positive but net P&L is not.
        survives_friction=expectancy_r > 0 and net_pnl > 0,
    )
