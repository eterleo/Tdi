"""Generates a SYNTHETIC 4H OHLCV series for local pipeline testing only.

This is NOT real market data and must never be used to draw conclusions
about the strategy's live viability — it exists purely so `run_backtest.py`
has something to execute end-to-end without a network dependency. Point
the strategy at real BTC/USD 4H OHLCV (e.g. exported from your exchange or
data vendor) for any real analysis.
"""
import numpy as np
import pandas as pd


def generate(n_bars: int = 2000, seed: int = 7, start_price: float = 40_000.0) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    timestamps = pd.date_range("2023-01-01", periods=n_bars, freq="4h", tz="UTC")

    returns = rng.normal(loc=0.0, scale=0.01, size=n_bars)
    close = start_price * np.exp(np.cumsum(returns))

    open_ = np.empty(n_bars)
    open_[0] = start_price
    open_[1:] = close[:-1]

    intrabar_range = np.abs(rng.normal(loc=0.006, scale=0.004, size=n_bars)) * close
    high = np.maximum(open_, close) + intrabar_range * rng.uniform(0.2, 1.0, n_bars)
    low = np.minimum(open_, close) - intrabar_range * rng.uniform(0.2, 1.0, n_bars)

    volume = rng.lognormal(mean=6.5, sigma=0.5, size=n_bars)

    # Inject occasional liquidity-sweep wicks with a volume spike so the
    # sample data actually exercises the strategy's signal path.
    for i in range(30, n_bars, 47):
        if rng.random() < 0.5:
            low[i] = min(low[i], low[max(0, i - 20):i].min() * 0.985)
            close[i] = max(close[i], low[i] * 1.01)
        else:
            high[i] = max(high[i], high[max(0, i - 20):i].max() * 1.015)
            close[i] = min(close[i], high[i] * 0.99)
        volume[i] *= 2.5

    df = pd.DataFrame({
        "timestamp": timestamps, "open": open_, "high": high,
        "low": low, "close": close, "volume": volume,
    })
    return df


if __name__ == "__main__":
    out = generate()
    out.to_csv("data/sample_btc_4h.csv", index=False)
    print(f"Wrote {len(out)} synthetic 4H bars to data/sample_btc_4h.csv")
