"""Institutional risk controls (Step 4).

Two independent safeguards:
1. `position_size` — dynamic sizing so every trade risks a fixed % of
   *current* equity, regardless of stop distance.
2. `CircuitBreaker` — a hard kill switch that halts trading the moment
   live drawdown exceeds 1.5x the worst drawdown seen in backtest.
"""
from dataclasses import dataclass, field


class CircuitBreakerTripped(Exception):
    """Raised when live drawdown breaches the 1.5x historical-max-DD threshold."""


def position_size(equity: float, risk_per_trade_pct: float, entry_price: float, stop_price: float) -> float:
    """Return position size (in units of the underlying) so that a stop-out
    loses exactly `risk_per_trade_pct` of `equity`.

    size = (equity * risk_pct) / |entry - stop|
    """
    risk_amount = equity * risk_per_trade_pct
    per_unit_risk = abs(entry_price - stop_price)
    if per_unit_risk <= 0:
        raise ValueError("Stop price must differ from entry price")
    return risk_amount / per_unit_risk


@dataclass
class CircuitBreaker:
    """Tracks running drawdown against a pre-established historical ceiling.

    `historical_max_dd_pct` must come from an out-of-sample/backtest run
    BEFORE the strategy goes live — it is the ceiling this breaker measures
    live behavior against, not something it discovers on the fly.
    """
    historical_max_dd_pct: float           # e.g. 0.18 for an 18% backtested max drawdown
    multiplier: float = 1.5
    peak_equity: float = field(default=0.0)
    halted: bool = field(default=False)

    def __post_init__(self):
        if self.historical_max_dd_pct <= 0:
            raise ValueError("historical_max_dd_pct must be a positive fraction, e.g. 0.18")

    @property
    def threshold_pct(self) -> float:
        return self.historical_max_dd_pct * self.multiplier

    def update(self, current_equity: float) -> float:
        """Feed the latest equity mark. Returns current drawdown fraction.

        Raises CircuitBreakerTripped if the live drawdown reaches the
        threshold. Once halted, stays halted (a human must reset it).
        """
        if self.halted:
            raise CircuitBreakerTripped("CRITICAL FAILSAFE TRIPPED: HALT ALL TRADING.")

        self.peak_equity = max(self.peak_equity, current_equity)
        if self.peak_equity <= 0:
            return 0.0

        drawdown_pct = (self.peak_equity - current_equity) / self.peak_equity

        if drawdown_pct >= self.threshold_pct:
            self.halted = True
            raise CircuitBreakerTripped(
                f"CRITICAL FAILSAFE TRIPPED: HALT ALL TRADING. "
                f"Live drawdown {drawdown_pct:.2%} >= {self.multiplier}x historical max "
                f"({self.historical_max_dd_pct:.2%} -> threshold {self.threshold_pct:.2%})."
            )
        return drawdown_pct

    def reset(self) -> None:
        """Explicit, deliberate re-arm after human review. Never called automatically."""
        self.halted = False
        self.peak_equity = 0.0
