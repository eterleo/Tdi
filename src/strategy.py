"""Liquidity Sweep Mean Reversion — signal generation.

Pure price/volume structure, no lagging indicator stacks (see STRATEGY.md
Step 1/2). Given OHLCV bars, this module tags each bar with the swing
structure, the ATR-based invalidation buffer, and — where the setup
clears the minimum R:R filter — a trade signal with pre-computed
entry/stop/target.
"""
from dataclasses import dataclass
from typing import Literal, Optional

import numpy as np
import pandas as pd

from config import StrategyConfig

Direction = Literal["long", "short"]


@dataclass
class Signal:
    index: int
    timestamp: pd.Timestamp
    direction: Direction
    entry_price: float
    stop_price: float
    target_price: float
    risk_reward: float


def _true_range(df: pd.DataFrame) -> pd.Series:
    prev_close = df["close"].shift(1)
    return pd.concat(
        [
            df["high"] - df["low"],
            (df["high"] - prev_close).abs(),
            (df["low"] - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)


def add_structure_columns(df: pd.DataFrame, cfg: StrategyConfig) -> pd.DataFrame:
    """Adds swing_low, swing_high, atr, avg_volume — all computed on data
    STRICTLY prior to the current bar (shift(1)) to avoid lookahead bias.
    """
    out = df.copy()
    out["swing_low"] = out["low"].shift(1).rolling(cfg.lookback).min()
    out["swing_high"] = out["high"].shift(1).rolling(cfg.lookback).max()
    out["atr"] = _true_range(out).rolling(cfg.atr_period).mean().shift(1)
    out["avg_volume"] = out["volume"].shift(1).rolling(cfg.lookback).mean()
    return out


def generate_signals(df: pd.DataFrame, cfg: StrategyConfig) -> list[Signal]:
    """Scan a DataFrame of OHLCV bars (indexed 0..n-1, with a 'timestamp'
    column) and return every bar that produces a valid, R:R-filtered
    liquidity-sweep signal. Does not manage open positions — that is the
    backtest engine's job (a signal here is a candidate, not a guaranteed fill).
    """
    structured = add_structure_columns(df, cfg)
    signals: list[Signal] = []

    for i in range(len(structured)):
        row = structured.iloc[i]
        if np.isnan(row["swing_low"]) or np.isnan(row["atr"]) or np.isnan(row["avg_volume"]):
            continue  # not enough history yet
        if row["avg_volume"] <= 0:
            continue

        volume_confirmed = row["volume"] > row["avg_volume"] * cfg.volume_spike_multiplier

        # --- Long: sweep of the swing low, close reclaims back above it ---
        swept_low = row["low"] < row["swing_low"] and row["close"] > row["swing_low"]
        if swept_low and volume_confirmed:
            entry = row["close"]
            stop = row["low"] - row["atr"] * cfg.sweep_buffer_atr
            target = row["swing_high"]
            risk = entry - stop
            reward = target - entry
            if risk > 0 and reward / risk >= cfg.min_risk_reward:
                signals.append(Signal(i, row["timestamp"], "long", entry, stop, target, reward / risk))
                continue  # one signal per bar

        # --- Short: sweep of the swing high, close reclaims back below it ---
        swept_high = row["high"] > row["swing_high"] and row["close"] < row["swing_high"]
        if swept_high and volume_confirmed:
            entry = row["close"]
            stop = row["high"] + row["atr"] * cfg.sweep_buffer_atr
            target = row["swing_low"]
            risk = stop - entry
            reward = entry - target
            if risk > 0 and reward / risk >= cfg.min_risk_reward:
                signals.append(Signal(i, row["timestamp"], "short", entry, stop, target, reward / risk))

    return signals
