@echo off
setlocal
title Morning Trading Routine

set "TV_EXE=C:\Program Files\WindowsApps\TradingView.Desktop_3.1.0.7818_x64__n534cwy3pjxzj\TradingView.exe"
set "MCP_DIR=C:\Users\Dell\tradingview-mcp"

:: Kill any leftover ngrok sessions so the new one always wins
taskkill /f /im ngrok.exe > nul 2>&1

:: ── Window 1: TradingView with remote debugging ──────────────────────────
start "" "%TV_EXE%" --remote-debugging-port=9222

timeout /t 5 /nobreak > nul

:: ── Window 2: MCP proxy server + ngrok in one window ─────────────────────
::    proxy.js rewrites Host: localhost:9222 before Chrome sees the request.
::    ngrok must point at the proxy (port 3001), NOT directly at Chrome (9222).
start "MCP Server" cmd /k "cd /d "%MCP_DIR%" && npm start & ngrok http 3001"

timeout /t 4 /nobreak > nul

:: ── Window 3: Claude Code ─────────────────────────────────────────────────
start "Claude Code" cmd /k "cd /d "%MCP_DIR%" && claude"
