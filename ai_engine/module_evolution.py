"""
Structural module evolution: the AI proposes a full rewrite of ONE
whitelisted .mqh module per cycle, targeted at whichever confluence
component is currently underperforming. The candidate is written into an
isolated versions/vN/Include workspace - it NEVER touches the live,
checked-in source tree directly. Only compiler.py + backtest_validator.py
passing promotes a candidate to live (see version_manager.py).

This keeps "self-modifying code" honest: the system can rewrite its own
detection logic, but every rewrite is validated before it ever reaches a
running EA, and every prior version stays on disk for rollback.
"""
from __future__ import annotations

import logging
import re
import shutil
from pathlib import Path
from typing import Optional

from .ai_client import LocalAIClient
from .config import Config
from .pattern_discovery import DiscoveryReport

log = logging.getLogger(__name__)

# Only these modules may be structurally rewritten by the AI. Each entry's
# public class interface (class name + public method signatures) MUST be
# preserved by any candidate rewrite, since TrendEngine.mqh / the main .mq5
# call into these classes by name.
WHITELISTED_MODULES = {
    "liquidity": "Liquidity.mqh",
    "market_structure": "MarketStructure.mqh",
    "fair_value_gap": "FairValueGap.mqh",
    "supply_demand": "SupplyDemand.mqh",
}


def pick_target_module(discovery: DiscoveryReport) -> str:
    """Heuristically choose which module most needs structural attention."""
    sweep_stats = discovery.by_sweep
    no_sweep = sweep_stats.get("NONE")
    if no_sweep and no_sweep.get("trades", 0) >= 10 and no_sweep["win_rate_pct"] < discovery.overall_win_rate_pct - 10:
        return "liquidity"

    zone_stats = discovery.by_zone_type
    no_zone = zone_stats.get("NONE")
    if no_zone and no_zone.get("trades", 0) >= 10 and no_zone["win_rate_pct"] < discovery.overall_win_rate_pct - 10:
        return "fair_value_gap"

    if discovery.overall_win_rate_pct < 40 and discovery.total_trades >= 30:
        return "market_structure"

    return "supply_demand"


def _build_prompt(module_file: str, current_source: str, discovery: DiscoveryReport) -> str:
    return f"""You are improving one MQL5 include module of a Smart Money Concepts
XAUUSD trading EA. You must preserve the exact public class name and all
public method names/signatures, since other modules call them by name.
Only improve internal detection logic (e.g. swing/sweep/gap/zone
identification quality) - do not change the file's role in the system.

Performance context that motivated this rewrite request:
{discovery.to_dict()}

Current content of {module_file}:
```mql5
{current_source}
```

Respond with ONLY the complete new file content in a single mql5 code
block. No explanation before or after.
"""


def propose_module_rewrite(cfg: Config, module_key: str, discovery: DiscoveryReport,
                           ai: LocalAIClient, version: int) -> Optional[Path]:
    if module_key not in WHITELISTED_MODULES:
        raise ValueError(f"module '{module_key}' is not whitelisted for structural evolution")

    module_file = WHITELISTED_MODULES[module_key]
    live_include_dir = Path(__file__).resolve().parent.parent / "MQL5" / "Include" / "XAU_SMC_SNIPER_AI"
    source_path = live_include_dir / module_file
    if not source_path.exists():
        log.error("Source module not found: %s", source_path)
        return None
    current_source = source_path.read_text(encoding="utf-8")

    resp = ai.generate(_build_prompt(module_file, current_source, discovery),
                       system="You write production MQL5. Output only the code block, nothing else.")
    if not resp.ok:
        log.warning("Module evolution AI call failed for %s: %s", module_file, resp.error)
        return None

    candidate_code = _extract_code_block(resp.text)
    if not candidate_code or len(candidate_code) < 50:
        log.warning("Module evolution returned no usable code for %s", module_file)
        return None

    if not _preserves_public_interface(current_source, candidate_code):
        log.warning("Candidate rewrite of %s changed the public interface - rejecting before compile.", module_file)
        return None

    # nested to mirror the live MQL5/Include/<project>/ layout so MetaEditor's
    # /inc switch can resolve `#include <XAU_SMC_SNIPER_AI/X.mqh>` unchanged
    version_dir = cfg.versions_dir / f"v{version}" / "Include" / "XAU_SMC_SNIPER_AI"
    version_dir.mkdir(parents=True, exist_ok=True)

    # seed the candidate workspace with the full current include set, then
    # overwrite just the one module being evolved
    for f in live_include_dir.glob("*.mqh"):
        shutil.copy2(f, version_dir / f.name)
    candidate_path = version_dir / module_file
    candidate_path.write_text(candidate_code, encoding="utf-8")

    return candidate_path


def _extract_code_block(text: str) -> str:
    match = re.search(r"```(?:mql5|cpp|c\+\+)?\s*(.*?)```", text, re.DOTALL)
    return match.group(1).strip() if match else text.strip()


def _preserves_public_interface(original: str, candidate: str) -> bool:
    class_match = re.search(r"class\s+(\w+)", original)
    if not class_match:
        return True  # nothing to check against
    class_name = class_match.group(1)
    if f"class {class_name}" not in candidate:
        return False

    original_methods = set(re.findall(r"^\s{3}(?:bool|void|int|double|datetime|string|ENUM_\w+|static\s+\w+)\s+(\w+)\s*\(",
                                       original, re.MULTILINE))
    candidate_methods = set(re.findall(r"^\s{3}(?:bool|void|int|double|datetime|string|ENUM_\w+|static\s+\w+)\s+(\w+)\s*\(",
                                        candidate, re.MULTILINE))
    missing = original_methods - candidate_methods
    return len(missing) == 0
