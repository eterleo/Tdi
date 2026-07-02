"""Central configuration for the liquidity-sweep mean-reversion strategy.

Every "magic number" the strategy, friction model, and risk engine use lives
here so a walk-forward run can swap parameters without touching logic.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class StrategyConfig:
    # --- Market ---
    symbol: str = "BTC/USD"
    timeframe: str = "4h"

    # --- Signal (Step 1/2) ---
    lookback: int = 20                 # bars used to define the swing high/low "liquidity pool"
    atr_period: int = 14
    sweep_buffer_atr: float = 0.25     # stop = wick low/high +/- this many ATRs
    volume_spike_multiplier: float = 1.5  # sweep bar volume must exceed lookback-avg volume * this
    min_risk_reward: float = 2.0       # trades offering less than this R:R are skipped, not taken
    max_holding_bars: int = 12         # time stop: 12 * 4h = 48h

    # --- Friction (Step 3) ---
    slippage_bps: float = 5.0          # 0.05% adverse slippage applied to every fill (entry & exit)
    commission_bps: float = 5.0        # 0.05% taker commission applied to every fill (entry & exit)

    # --- Risk & circuit breakers (Step 4) ---
    starting_equity: float = 100_000.0
    risk_per_trade_pct: float = 0.01   # 1% of current equity risked per trade
    circuit_breaker_multiplier: float = 1.5  # halt when live DD >= 1.5x historical backtest max DD
