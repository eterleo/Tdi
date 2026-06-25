"""
CLI entrypoint for the evolution engine. Run this from Task Scheduler / cron
/ a terminal next to MT5, pointed at the same Common\\Files directory the EA
writes to (set XSS_COMMON_FILES_DIR if it's not auto-detected).

Usage:
    python -m ai_engine.run_cycle              # check once, run a cycle if triggered, exit
    python -m ai_engine.run_cycle --watch       # poll forever (cycle + deploy watchdog)
    python -m ai_engine.run_cycle --interval 30 --watch
"""
from __future__ import annotations

import argparse
import logging
import time

from .config import DEFAULT_CONFIG, Config
from .deploy_watchdog import check_and_deploy
from .evolution_engine import run_cycle

log = logging.getLogger("ai_engine")


def main() -> None:
    parser = argparse.ArgumentParser(description="XAU_SMC_SNIPER_AI local evolution engine")
    parser.add_argument("--watch", action="store_true", help="poll forever instead of running once")
    parser.add_argument("--interval", type=int, default=60, help="seconds between polls in --watch mode")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    cfg: Config = DEFAULT_CONFIG
    log.info("Watching %s", cfg.project_dir)

    if not args.watch:
        _tick(cfg)
        return

    log.info("Polling every %ds. Ctrl+C to stop.", args.interval)
    while True:
        _tick(cfg)
        time.sleep(args.interval)


def _tick(cfg: Config) -> None:
    try:
        ran = run_cycle(cfg)
        if ran:
            log.info("Evolution cycle completed.")
    except Exception:
        log.exception("Evolution cycle raised an unhandled exception - leaving trigger in place for next poll.")

    try:
        deploy = check_and_deploy(cfg)
        if deploy.deployed:
            log.info("Deploy watchdog: %s", deploy.reason)
    except Exception:
        log.exception("Deploy watchdog raised an unhandled exception.")


if __name__ == "__main__":
    main()
