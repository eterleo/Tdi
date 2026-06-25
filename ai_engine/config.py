"""
Central configuration for the XAU_SMC_SNIPER_AI evolution engine.

All paths default to the standard MT5 "Common\\Files" location so the
EA (writing from inside the MQL5 sandbox with FILE_COMMON) and this
Python process (reading/writing directly on disk) always agree on
where files live, without needing any IPC between MT5 and Python.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _default_common_files_dir() -> Path:
    env = os.environ.get("XSS_COMMON_FILES_DIR")
    if env:
        return Path(env)

    appdata = os.environ.get("APPDATA")
    if appdata:
        candidate = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"
        if candidate.exists():
            return candidate

    # Non-Windows dev/test fallback - keeps the engine runnable for unit tests
    # and local experimentation without a real MT5 installation.
    return Path(__file__).resolve().parent.parent / "MQL5" / "Files"


@dataclass
class Config:
    project_subdir: str = "XAU_SMC_SNIPER_AI"
    common_files_dir: Path = field(default_factory=_default_common_files_dir)

    # --- local AI endpoint (Ollama / LM Studio / vLLM, all OpenAI- or Ollama-compatible) ---
    ai_provider: str = os.environ.get("XSS_AI_PROVIDER", "ollama")        # "ollama" | "openai_compatible"
    ai_base_url: str = os.environ.get("XSS_AI_BASE_URL", "http://127.0.0.1:11434")
    ai_model: str = os.environ.get("XSS_AI_MODEL", "qwen2.5-coder")
    ai_timeout_seconds: int = 120

    # --- evolution cadence / safety ---
    trades_per_cycle: int = 50
    min_trades_for_pattern_discovery: int = 20

    # --- backtest validation gates (a candidate version must clear ALL of these) ---
    min_profit_factor: float = 1.2
    max_drawdown_pct: float = 10.0
    min_win_rate_pct: float = 35.0
    min_trades_in_backtest: int = 30

    # --- external MT5 tools (Windows only; compilation/backtest steps degrade gracefully
    #     to "skipped" when these are not available, e.g. on a Linux dev box) ---
    metaeditor_path: str = os.environ.get("XSS_METAEDITOR_PATH", r"C:\Program Files\MetaTrader 5\MetaEditor64.exe")
    terminal_path: str = os.environ.get("XSS_TERMINAL_PATH", r"C:\Program Files\MetaTrader 5\terminal64.exe")
    mt5_data_dir: str = os.environ.get("XSS_MT5_DATA_DIR", "")  # passed to terminal64 /config for tester runs

    @property
    def project_dir(self) -> Path:
        d = self.common_files_dir / self.project_subdir
        d.mkdir(parents=True, exist_ok=True)
        return d

    @property
    def trades_csv(self) -> Path:
        return self.project_dir / "trades.csv"

    @property
    def market_states_json(self) -> Path:
        return self.project_dir / "market_states.json"

    @property
    def performance_csv(self) -> Path:
        return self.project_dir / "performance.csv"

    @property
    def strategy_history_json(self) -> Path:
        return self.project_dir / "strategy_history.json"

    @property
    def strategy_params_json(self) -> Path:
        return self.project_dir / "strategy_params.json"

    @property
    def module_flags_json(self) -> Path:
        return self.project_dir / "module_flags.json"

    @property
    def evolution_trigger_json(self) -> Path:
        return self.project_dir / "evolution_trigger.json"

    @property
    def evolution_state_json(self) -> Path:
        return self.project_dir / "evolution_state.json"

    @property
    def version_status_json(self) -> Path:
        return self.project_dir / "version_status.json"

    @property
    def versions_dir(self) -> Path:
        d = self.project_dir / "versions"
        d.mkdir(parents=True, exist_ok=True)
        return d

    # --- v2.0 market memory additions (CMarketMemory in MarketMemory.mqh) ---

    @property
    def market_memory_sqlite(self) -> Path:
        return self.project_dir / "market_memory.sqlite"

    @property
    def rejected_setups_csv(self) -> Path:
        return self.project_dir / "rejected_setups.csv"

    @property
    def feature_snapshots_json(self) -> Path:
        return self.project_dir / "feature_snapshots.json"

    @property
    def adaptive_weights_json(self) -> Path:
        return self.project_dir / "adaptive_weights.json"


DEFAULT_CONFIG = Config()
