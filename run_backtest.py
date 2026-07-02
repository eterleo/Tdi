"""CLI entry point.

Usage:
    python run_backtest.py [path/to/ohlcv.csv]

CSV must have columns: timestamp, open, high, low, close, volume
(timestamp parseable by pandas). If no path is given, generates and uses
the synthetic sample series in data/sample_btc_4h.csv (see
data/generate_sample_data.py) — synthetic data only, for pipeline
verification, not for judging the strategy's real edge.
"""
import sys
from pathlib import Path

import pandas as pd

from config import StrategyConfig
from src.backtest import round_trip_friction_bps, run


def load_data(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, parse_dates=["timestamp"])
    required = {"timestamp", "open", "high", "low", "close", "volume"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"Input CSV is missing required columns: {missing}")
    return df.sort_values("timestamp").reset_index(drop=True)


def main() -> None:
    if len(sys.argv) > 1:
        data_path = Path(sys.argv[1])
    else:
        data_path = Path("data/sample_btc_4h.csv")
        if not data_path.exists():
            print("No data file given and no sample data found — generating synthetic sample data...")
            from data.generate_sample_data import generate
            data_path.parent.mkdir(exist_ok=True)
            generate().to_csv(data_path, index=False)

    df = load_data(data_path)
    cfg = StrategyConfig()

    print(f"Loaded {len(df)} bars from {data_path}")
    print(f"Round-trip friction budget: {round_trip_friction_bps(cfg):.1f} bps "
          f"({cfg.slippage_bps} bps slippage x2 + {cfg.commission_bps} bps commission x2)\n")

    # Pass 1: establish the historical max drawdown baseline (breaker disabled).
    baseline = run(df, cfg, historical_max_dd_pct=None)
    print("=== BASELINE BACKTEST (circuit breaker disabled — establishes baseline) ===")
    print(baseline.report)
    print(f"\nHistorical max drawdown to configure the live circuit breaker with: "
          f"{baseline.final_historical_max_dd_pct:.2%}\n")

    if baseline.final_historical_max_dd_pct <= 0:
        print("No drawdown observed in baseline run — not enough trades to size a circuit breaker yet.")
        return

    # Pass 2: re-run with the circuit breaker armed at 1.5x the baseline DD,
    # simulating how the safeguard would behave live/in paper trading.
    guarded = run(df, cfg, historical_max_dd_pct=baseline.final_historical_max_dd_pct)
    print("=== GUARDED RUN (circuit breaker armed at "
          f"{cfg.circuit_breaker_multiplier}x baseline) ===")
    print(guarded.report)
    if guarded.halted_at_bar is not None:
        print(f"\nCircuit breaker tripped at bar {guarded.halted_at_bar}.")


if __name__ == "__main__":
    main()
