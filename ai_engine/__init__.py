"""Local-only AI evolution engine for XAU_SMC_SNIPER_AI.

Never places trades and never contacts a cloud endpoint - it only reads
market-memory files the EA writes, proposes parameter/module changes, and
validates them (compile + backtest) before anything reaches the live EA.
"""
