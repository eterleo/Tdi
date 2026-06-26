"""
Thin wrapper around MetaEditor64.exe's command-line compiler. Compiles a
staged candidate version (versions/vN/ - an isolated copy of the Experts +
Include tree, with whichever .mqh module_evolution.py rewrote already
dropped in by the caller) and reports back pass/fail plus the raw compiler
log.

Deliberately a dumb pass/fail gate, not a place to "fix" candidate code.
Degrades to a clearly-marked "skipped" result on non-Windows hosts or when
metaeditor_path doesn't exist, so the evolution loop stays runnable (and
testable) on a dev box without ever pretending a compile happened.
"""
from __future__ import annotations

import logging
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import Config

log = logging.getLogger(__name__)

EXPERT_MAIN_FILE = "XAU_SMC_SNIPER_AI.mq5"
LIVE_EXPERTS_DIR = Path(__file__).resolve().parent.parent / "MQL5" / "Experts" / "XAU_SMC_SNIPER_AI"
LIVE_INCLUDE_DIR = Path(__file__).resolve().parent.parent / "MQL5" / "Include" / "XAU_SMC_SNIPER_AI"

COMPILE_TIMEOUT_SECONDS = 180


@dataclass
class CompileResult:
    ok: bool
    skipped: bool
    log_text: str
    error_count: int
    warning_count: int


def _version_root(cfg: Config, version: int) -> Path:
    return cfg.versions_dir / f"v{version}"


def _stage_expert_main(cfg: Config, version: int) -> Path:
    """The .mq5 itself is never AI-modified, so just make sure a copy exists
    in the version workspace for MetaEditor to compile against."""
    experts_dir = _version_root(cfg, version) / "Experts" / "XAU_SMC_SNIPER_AI"
    experts_dir.mkdir(parents=True, exist_ok=True)
    dest = experts_dir / EXPERT_MAIN_FILE
    if not dest.exists():
        shutil.copy2(LIVE_EXPERTS_DIR / EXPERT_MAIN_FILE, dest)
    return dest


def _include_root_for(cfg: Config, version: int) -> Path:
    """Directory to pass via /inc so `#include <XAU_SMC_SNIPER_AI/X.mqh>`
    resolves to the candidate module where module_evolution.py already
    staged one, and falls back to an unmodified copy of every other module."""
    include_dir = _version_root(cfg, version) / "Include" / "XAU_SMC_SNIPER_AI"
    include_dir.mkdir(parents=True, exist_ok=True)
    for f in LIVE_INCLUDE_DIR.glob("*.mqh"):
        dest = include_dir / f.name
        if not dest.exists():
            shutil.copy2(f, dest)
    return _version_root(cfg, version) / "Include"


def compile_version(cfg: Config, version: int) -> CompileResult:
    if platform.system() != "Windows":
        log.info("Compiler skipped: MetaEditor only runs on Windows.")
        return CompileResult(ok=False, skipped=True, log_text="skipped: non-Windows host",
                             error_count=0, warning_count=0)

    metaeditor = Path(cfg.metaeditor_path)
    if not metaeditor.exists():
        log.info("Compiler skipped: MetaEditor not found at %s", metaeditor)
        return CompileResult(ok=False, skipped=True, log_text=f"skipped: metaeditor not found at {metaeditor}",
                             error_count=0, warning_count=0)

    mq5_path = _stage_expert_main(cfg, version)
    include_root = _include_root_for(cfg, version)
    log_path = mq5_path.with_suffix(".log")
    if log_path.exists():
        log_path.unlink()

    cmd = [str(metaeditor), f"/compile:{mq5_path}", f"/inc:{include_root}", f"/log:{log_path}"]
    try:
        subprocess.run(cmd, timeout=COMPILE_TIMEOUT_SECONDS, check=False)
    except subprocess.SubprocessError as exc:
        log.error("MetaEditor invocation failed: %s", exc)
        return CompileResult(ok=False, skipped=False, log_text=str(exc), error_count=1, warning_count=0)

    if not log_path.exists():
        return CompileResult(ok=False, skipped=False, log_text="MetaEditor produced no log file",
                             error_count=1, warning_count=0)

    log_text = _read_metaeditor_log(log_path)
    errors, warnings = _parse_counts(log_text)
    ok = errors == 0
    if not ok:
        log.warning("Compile of version %d failed (%d errors).", version, errors)
    return CompileResult(ok=ok, skipped=False, log_text=log_text, error_count=errors, warning_count=warnings)


def _read_metaeditor_log(log_path: Path) -> str:
    # MetaEditor writes compile logs as UTF-16LE with a BOM
    for encoding in ("utf-16", "utf-8"):
        try:
            return log_path.read_text(encoding=encoding)
        except (UnicodeError, UnicodeDecodeError):
            continue
    return log_path.read_text(encoding="utf-8", errors="replace")


def _parse_counts(log_text: str) -> tuple[int, int]:
    match = re.search(r"(\d+)\s+errors?,\s*(\d+)\s+warnings?", log_text, re.IGNORECASE)
    if match:
        return int(match.group(1)), int(match.group(2))
    # summary line missing (unexpected log format) - fall back to counting
    # lines that look like compiler errors so we never silently treat an
    # unparseable log as a clean pass
    error_lines = [ln for ln in log_text.splitlines() if re.search(r"\berror\b", ln, re.IGNORECASE)]
    return (len(error_lines), 0) if error_lines else (0, 0)
