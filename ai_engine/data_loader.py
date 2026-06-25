"""
Reads the market-memory files the EA writes (trades.csv, market_states.json
JSON-Lines, performance.csv, strategy_history.json JSON-Lines) directly off
disk from the MT5 Common\\Files folder.
"""
from __future__ import annotations

import csv
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List

from .config import Config


def _read_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", newline="", encoding="utf-8", errors="replace") as f:
        return list(csv.DictReader(f))


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


@dataclass
class MarketMemoryData:
    trades: List[Dict[str, str]]
    market_states: List[Dict[str, Any]]
    performance: List[Dict[str, str]]
    strategy_history: List[Dict[str, Any]]


def load_all(cfg: Config) -> MarketMemoryData:
    return MarketMemoryData(
        trades=_read_csv(cfg.trades_csv),
        market_states=_read_jsonl(cfg.market_states_json),
        performance=_read_csv(cfg.performance_csv),
        strategy_history=_read_jsonl(cfg.strategy_history_json),
    )


def to_numeric(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default
