"""
Reads the market-memory files the EA writes (trades.csv, market_states.json
JSON-Lines, performance.csv, strategy_history.json JSON-Lines) directly off
disk from the MT5 Common\\Files folder.

v2.0 additionally reads CMarketMemory's SQLite mirror (market_memory.sqlite)
for the trades/rejected_setups/feature_snapshots tables - the structured
store the same data lands in alongside the CSV/JSON logs above. SQLite gives
native column types (no to_numeric() coercion needed) and lets future engines
query relationally instead of re-parsing CSV.
"""
from __future__ import annotations

import csv
import json
import sqlite3
from dataclasses import dataclass, field
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


def _read_sqlite_table(db_path: Path, table: str) -> List[Dict[str, Any]]:
    if not db_path.exists():
        return []
    conn = sqlite3.connect(str(db_path))
    try:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(f"SELECT * FROM {table}")
        return [dict(row) for row in cur.fetchall()]
    except sqlite3.OperationalError:
        # table not created yet (e.g. EA never opened the DB) - treat as empty
        return []
    finally:
        conn.close()


def load_sqlite_trades(cfg: Config) -> List[Dict[str, Any]]:
    return _read_sqlite_table(cfg.market_memory_sqlite, "trades")


def load_sqlite_rejected_setups(cfg: Config) -> List[Dict[str, Any]]:
    return _read_sqlite_table(cfg.market_memory_sqlite, "rejected_setups")


def load_sqlite_feature_snapshots(cfg: Config) -> List[Dict[str, Any]]:
    return _read_sqlite_table(cfg.market_memory_sqlite, "feature_snapshots")


@dataclass
class MarketMemoryData:
    trades: List[Dict[str, str]]
    market_states: List[Dict[str, Any]]
    performance: List[Dict[str, str]]
    strategy_history: List[Dict[str, Any]]
    sqlite_trades: List[Dict[str, Any]] = field(default_factory=list)
    rejected_setups: List[Dict[str, Any]] = field(default_factory=list)
    feature_snapshots: List[Dict[str, Any]] = field(default_factory=list)


def load_all(cfg: Config) -> MarketMemoryData:
    return MarketMemoryData(
        trades=_read_csv(cfg.trades_csv),
        market_states=_read_jsonl(cfg.market_states_json),
        performance=_read_csv(cfg.performance_csv),
        strategy_history=_read_jsonl(cfg.strategy_history_json),
        sqlite_trades=load_sqlite_trades(cfg),
        rejected_setups=load_sqlite_rejected_setups(cfg),
        feature_snapshots=load_sqlite_feature_snapshots(cfg),
    )


def to_numeric(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default
