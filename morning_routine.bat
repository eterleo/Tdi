@echo off
setlocal
title Morning Trading Routine

set "TV_EXE=C:\Program Files\WindowsApps\TradingView.Desktop_3.1.0.7818_x64__n534cwy3pjxzj\TradingView.exe"
set "MCP_DIR=C:\Users\Dell\tradingview-mcp"

:: ── Window 1: TradingView with remote debugging ──────────────────────────
start "" "%TV_EXE%" --remote-debugging-port=9222

timeout /t 5 /nobreak > nul

:: ── Window 2: MCP proxy server (npm start → node proxy.js) ───────────────
start "MCP Server" cmd /k "cd /d "%MCP_DIR%" && npm start"

timeout /t 3 /nobreak > nul

:: ── Window 3: Claude Code ─────────────────────────────────────────────────
start "Claude Code" cmd /k "cd /d "%MCP_DIR%" && claude"
