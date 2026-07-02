import pandas as pd

from config import StrategyConfig
from src.strategy import generate_signals


def _ranging_bars(n: int, low: float, high: float, close: float, volume: float,
                   start: str = "2024-01-01") -> pd.DataFrame:
    """n bars oscillating inside a [low, high] range so swing_low/swing_high
    settle at distinct, realistic levels (unlike a fully flat series, where
    swing_low == swing_high and no reward is possible)."""
    idx = pd.date_range(start, periods=n, freq="4h", tz="UTC")
    return pd.DataFrame({
        "timestamp": idx,
        "open": [close] * n, "high": [high] * n, "low": [low] * n,
        "close": [close] * n, "volume": [volume] * n,
    })


def test_long_sweep_signal_has_correct_entry_stop_target():
    cfg = StrategyConfig(lookback=5, atr_period=5, sweep_buffer_atr=0.0,
                          volume_spike_multiplier=1.2, min_risk_reward=1.0)
    df = _ranging_bars(10, low=100.0, high=110.0, close=105.0, volume=10.0)
    # Sweep bar: wicks below the 100 support, closes back inside the range
    # (above 100, below the 110 resistance target), with a volume spike.
    df.loc[9, ["low", "high", "close", "volume"]] = [95.0, 102.0, 102.0, 50.0]

    signals = generate_signals(df, cfg)

    assert len(signals) == 1
    sig = signals[0]
    assert sig.direction == "long"
    assert sig.index == 9
    assert sig.entry_price == 102.0
    assert sig.stop_price == 95.0  # buffer is 0 in this config
    assert sig.target_price == 110.0  # prior swing high
    assert sig.risk_reward >= cfg.min_risk_reward


def test_signal_rejected_when_below_min_risk_reward():
    # Same sweep shape, but demand an R:R the setup can't offer.
    cfg = StrategyConfig(lookback=5, atr_period=5, sweep_buffer_atr=0.0,
                          volume_spike_multiplier=1.2, min_risk_reward=10.0)
    df = _ranging_bars(10, low=100.0, high=110.0, close=105.0, volume=10.0)
    df.loc[9, ["low", "high", "close", "volume"]] = [95.0, 102.0, 102.0, 50.0]

    signals = generate_signals(df, cfg)
    assert signals == []


def test_no_signal_without_volume_confirmation():
    cfg = StrategyConfig(lookback=5, atr_period=5, sweep_buffer_atr=0.0,
                          volume_spike_multiplier=1.2, min_risk_reward=1.0)
    df = _ranging_bars(10, low=100.0, high=110.0, close=105.0, volume=10.0)
    # Wick sweep + reclaim, but no volume spike (same as baseline volume).
    df.loc[9, ["low", "high", "close"]] = [95.0, 102.0, 102.0]

    signals = generate_signals(df, cfg)
    assert signals == []


def test_no_signal_without_wick_beyond_structure():
    cfg = StrategyConfig(lookback=5, atr_period=5, sweep_buffer_atr=0.0,
                          volume_spike_multiplier=1.2, min_risk_reward=1.0)
    df = _ranging_bars(10, low=100.0, high=110.0, close=105.0, volume=10.0)
    # Volume spikes but price never actually sweeps below the swing low.
    df.loc[9, "volume"] = 50.0

    signals = generate_signals(df, cfg)
    assert signals == []
