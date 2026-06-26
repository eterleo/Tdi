"""
External half of the "pending restart" handshake described in
CodeEvolutionEngine.mqh: when a structural version is approved, the EA sets
pending_restart=true in evolution_state.json and keeps trading on its
current (already-running) binary - it cannot swap its own .ex5. This
watchdog polls that flag, waits until the account has zero open positions
for this EA's magic number, swaps the compiled candidate .ex5 into the live
Experts folder, and clears the flag.

It NEVER touches a position and NEVER swaps while one is open - that check
is the entire reason this is a separate, slow-polling process instead of
something the EA does to itself.

Requires the optional `MetaTrader5` package (Windows only, talks to a
running terminal). Degrades to a no-op "skipped" result everywhere else.
"""
from __future__ import annotations

import json
import logging
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .config import Config

log = logging.getLogger(__name__)

LIVE_EXPERTS_DIR = Path(__file__).resolve().parent.parent / "MQL5" / "Experts" / "XAU_SMC_SNIPER_AI"
EXPERT_EX5_NAME = "XAU_SMC_SNIPER_AI.ex5"
XSS_MAGIC_NUMBER = 885522110  # must match Defines.mqh


@dataclass
class DeployResult:
    deployed: bool
    skipped: bool
    reason: str


def _read_state(cfg: Config) -> dict:
    if not cfg.evolution_state_json.exists():
        return {}
    try:
        return json.loads(cfg.evolution_state_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def _write_state(cfg: Config, state: dict) -> None:
    cfg.evolution_state_json.write_text(json.dumps(state, indent=2), encoding="utf-8")


def _open_positions_count() -> Optional[int]:
    """Returns None (meaning 'unknown, do not deploy') unless the optional
    MetaTrader5 package is installed and connected to a running terminal."""
    try:
        import MetaTrader5 as mt5
    except ImportError:
        return None

    if not mt5.initialize():
        log.warning("MetaTrader5.initialize() failed: %s", mt5.last_error())
        return None
    try:
        positions = mt5.positions_get()
        if positions is None:
            return 0
        return sum(1 for p in positions if p.magic == XSS_MAGIC_NUMBER)
    finally:
        mt5.shutdown()


def check_and_deploy(cfg: Config) -> DeployResult:
    state = _read_state(cfg)
    if not state.get("pending_restart"):
        return DeployResult(deployed=False, skipped=True, reason="no pending_restart flag set")

    version = int(state.get("current_version", 0))
    candidate_ex5 = cfg.versions_dir / f"v{version}" / "Experts" / "XAU_SMC_SNIPER_AI" / EXPERT_EX5_NAME
    if not candidate_ex5.exists():
        return DeployResult(deployed=False, skipped=True,
                            reason=f"no compiled candidate at {candidate_ex5} - was it compiled on this host?")

    open_count = _open_positions_count()
    if open_count is None:
        return DeployResult(deployed=False, skipped=True,
                            reason="MetaTrader5 package unavailable/not connected - cannot safely confirm flat")
    if open_count > 0:
        return DeployResult(deployed=False, skipped=True,
                            reason=f"{open_count} open position(s) for this EA - waiting for flat")

    live_ex5 = LIVE_EXPERTS_DIR / EXPERT_EX5_NAME
    live_ex5.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(candidate_ex5, live_ex5)

    state["pending_restart"] = False
    _write_state(cfg, state)
    log.info("Deployed v%d .ex5 to %s while flat.", version, live_ex5)
    return DeployResult(deployed=True, skipped=False, reason=f"deployed v{version}")


def run_forever(cfg: Config, poll_seconds: int = 60) -> None:
    """Simple polling loop for running this as a standalone background
    process alongside the terminal. One check per call keeps check_and_deploy
    independently testable; this just wraps it in a sleep loop."""
    log.info("Deploy watchdog started, polling every %ds.", poll_seconds)
    while True:
        result = check_and_deploy(cfg)
        if result.deployed:
            log.info("Deploy watchdog: %s", result.reason)
        else:
            log.debug("Deploy watchdog: %s", result.reason)
        time.sleep(poll_seconds)
