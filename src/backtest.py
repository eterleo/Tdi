"""Event-driven backtest engine.

Wires together: strategy signals -> friction-adjusted fills -> dynamic
position sizing -> per-bar circuit-breaker check. Single position at a
time (no pyramiding, no averaging) to keep the R-multiple accounting exact
and match the strategy rules in STRATEGY.md.

Two ways to run this:
  1. `historical_max_dd_pct=None` (default): the circuit breaker is
     disabled. Use this for the initial in-sample/out-of-sample backtest
     that *establishes* the historical max drawdown baseline.
  2. `historical_max_dd_pct=<value from run #1>`: the circuit breaker is
     live. Use this for walk-forward and paper-trading simulation, where
     the breaker must halt trading if live DD hits 1.5x that baseline.
"""
from dataclasses import dataclass
from typing import Optional

import pandas as pd

from config import StrategyConfig
from src.friction import Side, round_trip_cost_bps, simulate_fill
from src.metrics import PerformanceReport, build_report
from src.risk import CircuitBreaker, CircuitBreakerTripped, position_size
from src.strategy import Signal, generate_signals


@dataclass
class OpenPosition:
    direction: str
    entry_bar: int
    entry_fill: float
    stop_price: float
    target_price: float
    quantity: float
    entry_commission: float
    risk_amount: float  # cash risked at entry (equity * risk_pct), the "1R" in cash terms


@dataclass
class BacktestResult:
    trades: pd.DataFrame
    equity_curve: pd.Series
    report: PerformanceReport
    final_historical_max_dd_pct: float
    halted_at_bar: Optional[int]


def run(df: pd.DataFrame, cfg: StrategyConfig, historical_max_dd_pct: Optional[float] = None) -> BacktestResult:
    signals_by_bar = {s.index: s for s in generate_signals(df, cfg)}

    equity = cfg.starting_equity
    equity_curve = []
    trades: list[dict] = []
    position: Optional[OpenPosition] = None

    breaker: Optional[CircuitBreaker] = None
    if historical_max_dd_pct is not None:
        breaker = CircuitBreaker(historical_max_dd_pct, cfg.circuit_breaker_multiplier)

    halted_at_bar: Optional[int] = None

    for i in range(len(df)):
        bar = df.iloc[i]

        # --- Manage an open position first: check stop/target/time-stop ---
        if position is not None:
            exit_price_theo = None
            exit_reason = None

            if position.direction == "long":
                if bar["low"] <= position.stop_price:
                    exit_price_theo, exit_reason = position.stop_price, "stop"
                elif bar["high"] >= position.target_price:
                    exit_price_theo, exit_reason = position.target_price, "target"
            else:
                if bar["high"] >= position.stop_price:
                    exit_price_theo, exit_reason = position.stop_price, "stop"
                elif bar["low"] <= position.target_price:
                    exit_price_theo, exit_reason = position.target_price, "target"

            if exit_price_theo is None and (i - position.entry_bar) >= cfg.max_holding_bars:
                exit_price_theo, exit_reason = bar["close"], "time_stop"

            if exit_price_theo is not None:
                side = Side.LONG if position.direction == "long" else Side.SHORT
                fill = simulate_fill(
                    exit_price_theo, position.quantity, side, is_entry=False,
                    slippage_bps=cfg.slippage_bps, commission_bps=cfg.commission_bps,
                )
                if position.direction == "long":
                    gross_pnl = (fill.fill_price - position.entry_fill) * position.quantity
                else:
                    gross_pnl = (position.entry_fill - fill.fill_price) * position.quantity

                friction_cost = position.entry_commission + fill.commission
                net_pnl = gross_pnl - friction_cost
                pnl_r = net_pnl / position.risk_amount if position.risk_amount > 0 else 0.0

                equity += net_pnl
                trades.append({
                    "entry_bar": position.entry_bar, "exit_bar": i, "direction": position.direction,
                    "entry_price": position.entry_fill, "exit_price": fill.fill_price,
                    "quantity": position.quantity, "exit_reason": exit_reason,
                    "pnl_cash": net_pnl, "pnl_r": pnl_r, "friction_cost": friction_cost,
                })
                position = None

        # --- Circuit breaker: mark-to-market equity check (flat here since position just closed/none open) ---
        if breaker is not None:
            try:
                breaker.update(equity)
            except CircuitBreakerTripped as e:
                halted_at_bar = i
                equity_curve.append(equity)
                print(str(e))
                break

        # --- New entry (only if flat and not halted) ---
        if position is None and i in signals_by_bar:
            sig: Signal = signals_by_bar[i]
            side = Side.LONG if sig.direction == "long" else Side.SHORT
            qty = position_size(equity, cfg.risk_per_trade_pct, sig.entry_price, sig.stop_price)
            fill = simulate_fill(
                sig.entry_price, qty, side, is_entry=True,
                slippage_bps=cfg.slippage_bps, commission_bps=cfg.commission_bps,
            )
            risk_amount = equity * cfg.risk_per_trade_pct
            equity -= fill.commission
            position = OpenPosition(
                direction=sig.direction, entry_bar=i, entry_fill=fill.fill_price,
                stop_price=sig.stop_price, target_price=sig.target_price,
                quantity=qty, entry_commission=fill.commission, risk_amount=risk_amount,
            )

        equity_curve.append(equity)

    trades_df = pd.DataFrame(trades)
    equity_series = pd.Series(equity_curve, name="equity")
    report = build_report(trades_df, equity_series)

    return BacktestResult(
        trades=trades_df,
        equity_curve=equity_series,
        report=report,
        final_historical_max_dd_pct=report.max_drawdown_pct,
        halted_at_bar=halted_at_bar,
    )


def round_trip_friction_bps(cfg: StrategyConfig) -> float:
    return round_trip_cost_bps(cfg.slippage_bps, cfg.commission_bps)
