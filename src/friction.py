"""Execution friction model (Step 3 — the anti-fail safeguard).

Every simulated fill goes through here. Slippage always moves the fill
*against* the trader (worse than the theoretical price); commission is
deducted in both directions of a round trip. If a strategy's edge can't
survive this, it has no business going live.
"""
from dataclasses import dataclass
from enum import Enum


class Side(Enum):
    LONG = "long"
    SHORT = "short"


@dataclass
class FillResult:
    fill_price: float
    commission: float  # in quote currency, always >= 0


def apply_slippage(theoretical_price: float, side: Side, is_entry: bool, slippage_bps: float) -> float:
    """Adverse slippage: fills are always worse than the theoretical price.

    Entering long or exiting short = buying -> price moves up against us.
    Entering short or exiting long = selling -> price moves down against us.
    """
    is_buy = (side is Side.LONG and is_entry) or (side is Side.SHORT and not is_entry)
    slip_factor = slippage_bps / 10_000.0
    return theoretical_price * (1 + slip_factor) if is_buy else theoretical_price * (1 - slip_factor)


def apply_commission(notional: float, commission_bps: float) -> float:
    return notional * (commission_bps / 10_000.0)


def simulate_fill(theoretical_price: float, quantity: float, side: Side, is_entry: bool,
                   slippage_bps: float, commission_bps: float) -> FillResult:
    fill_price = apply_slippage(theoretical_price, side, is_entry, slippage_bps)
    commission = apply_commission(fill_price * quantity, commission_bps)
    return FillResult(fill_price=fill_price, commission=commission)


def round_trip_cost_bps(slippage_bps: float, commission_bps: float) -> float:
    """Total drag (bps of notional) from one entry + one exit."""
    return 2 * slippage_bps + 2 * commission_bps
