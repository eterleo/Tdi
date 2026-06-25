"""
Strategy Tester backtest gate. Runs a compiled candidate .ex5 through MT5's
headless tester (terminal64.exe /config:<ini>) and checks the resulting
report against the hard performance gates in Config (min_profit_factor,
max_drawdown_pct, min_win_rate_pct, min_trades_in_backtest).

A candidate only ever reaches version_manager.promote() if BOTH compiler.py
and this module say yes. Like compiler.py, this degrades to a "skipped"
result on non-Windows hosts rather than faking a pass.
"""
from __future__ import annotations

import logging
import platform
import re
import subprocess
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Optional

from .config import Config

log = logging.getLogger(__name__)

BACKTEST_TIMEOUT_SECONDS = 1800
DEFAULT_BACKTEST_DAYS = 90


@dataclass
class BacktestReport:
    trades: int
    profit_factor: float
    max_drawdown_pct: float
    win_rate_pct: float
    net_profit: float


@dataclass
class ValidationResult:
    passed: bool
    skipped: bool
    reasons: list[str]
    report: Optional[BacktestReport]


def _ini_path(cfg: Config, version: int) -> Path:
    return cfg.versions_dir / f"v{version}" / "tester.ini"


def _report_path(cfg: Config, version: int) -> Path:
    return cfg.versions_dir / f"v{version}" / "tester_report.xml"


def _build_ini(cfg: Config, version: int, symbol: str, period: str) -> Path:
    expert_rel = f"{cfg.project_subdir}\\{cfg.project_subdir}_v{version}"
    report_path = _report_path(cfg, version)
    end = date.today()
    start = end - timedelta(days=DEFAULT_BACKTEST_DAYS)

    ini_text = f"""[Tester]
Expert={expert_rel}
Symbol={symbol}
Period={period}
FromDate={start.strftime('%Y.%m.%d')}
ToDate={end.strftime('%Y.%m.%d')}
Model=1
Optimization=0
Report={report_path.with_suffix('')}
ReplaceReport=1
ShutdownTerminal=1
"""
    ini_path = _ini_path(cfg, version)
    ini_path.write_text(ini_text, encoding="utf-8")
    return ini_path


def run_backtest(cfg: Config, version: int, symbol: str = "XAUUSD", period: str = "M1") -> ValidationResult:
    if platform.system() != "Windows":
        log.info("Backtest skipped: Strategy Tester only runs on Windows.")
        return ValidationResult(passed=False, skipped=True, reasons=["skipped: non-Windows host"], report=None)

    terminal = Path(cfg.terminal_path)
    if not terminal.exists():
        log.info("Backtest skipped: terminal64.exe not found at %s", terminal)
        return ValidationResult(passed=False, skipped=True,
                                reasons=[f"skipped: terminal not found at {terminal}"], report=None)

    ini_path = _build_ini(cfg, version, symbol, period)
    cmd = [str(terminal), f"/config:{ini_path}"]
    if cfg.mt5_data_dir:
        cmd.append(f"/datapath:{cfg.mt5_data_dir}")

    try:
        subprocess.run(cmd, timeout=BACKTEST_TIMEOUT_SECONDS, check=False)
    except subprocess.SubprocessError as exc:
        log.error("Strategy Tester invocation failed: %s", exc)
        return ValidationResult(passed=False, skipped=False, reasons=[str(exc)], report=None)

    report_xml = _report_path(cfg, version)
    if not report_xml.exists():
        return ValidationResult(passed=False, skipped=False,
                                reasons=["Strategy Tester produced no report"], report=None)

    report = _parse_report(report_xml)
    if report is None:
        return ValidationResult(passed=False, skipped=False,
                                reasons=["could not parse tester report"], report=None)

    return _evaluate(cfg, report)


def _parse_report(report_xml: Path) -> Optional[BacktestReport]:
    try:
        text = report_xml.read_text(encoding="utf-16", errors="replace")
    except (UnicodeError, OSError):
        try:
            text = report_xml.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            log.error("Could not read tester report %s: %s", report_xml, exc)
            return None

    def _find(pattern: str) -> Optional[float]:
        m = re.search(pattern, text, re.IGNORECASE)
        return float(m.group(1).replace(" ", "").replace(",", "")) if m else None

    trades = _find(r"Total Trades[^0-9\-]*(-?[\d,. ]+)")
    profit_factor = _find(r"Profit Factor[^0-9\-]*(-?[\d,. ]+)")
    drawdown = _find(r"Equity Drawdown Maximal[^0-9\-]*\(?(-?[\d,. ]+)%?\)?")
    net_profit = _find(r"Total Net Profit[^0-9\-]*(-?[\d,. ]+)")
    won = _find(r"Profit Trades[^0-9\-]*\(?(-?[\d,. ]+)%?\)?")

    if trades is None:
        return None

    win_rate_pct = won if won is not None and won <= 100 else (won / trades * 100 if won else 0.0)
    return BacktestReport(
        trades=int(trades),
        profit_factor=profit_factor or 0.0,
        max_drawdown_pct=drawdown or 0.0,
        win_rate_pct=win_rate_pct or 0.0,
        net_profit=net_profit or 0.0,
    )


def _evaluate(cfg: Config, report: BacktestReport) -> ValidationResult:
    reasons = []
    if report.trades < cfg.min_trades_in_backtest:
        reasons.append(f"trades {report.trades} < min {cfg.min_trades_in_backtest}")
    if report.profit_factor < cfg.min_profit_factor:
        reasons.append(f"profit_factor {report.profit_factor:.2f} < min {cfg.min_profit_factor}")
    if report.max_drawdown_pct > cfg.max_drawdown_pct:
        reasons.append(f"max_drawdown_pct {report.max_drawdown_pct:.2f} > max {cfg.max_drawdown_pct}")
    if report.win_rate_pct < cfg.min_win_rate_pct:
        reasons.append(f"win_rate_pct {report.win_rate_pct:.2f} < min {cfg.min_win_rate_pct}")

    passed = len(reasons) == 0
    if not passed:
        log.warning("Backtest validation failed: %s", "; ".join(reasons))
    return ValidationResult(passed=passed, skipped=False, reasons=reasons, report=report)
