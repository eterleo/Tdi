@echo off
setlocal EnableDelayedExpansion
title Peter's Morning Trading Routine

:: ================================================================
::  CONFIGURATION
::  Edit these if your paths ever change.
:: ================================================================
set "TV_EXE=%LOCALAPPDATA%\Programs\TradingView\TradingView.exe"
set "MCP_DIR=C:\Users\Dell\tradingview-mcp"
set "NGROK_DOMAIN=clump-stunned-stank.ngrok-free.dev"

:: ================================================================
::  STEP 1 — Launch TradingView with CDP debugging enabled
:: ================================================================
echo.
echo [1/4] Launching TradingView Desktop...
if not exist "%TV_EXE%" (
    echo.
    echo  ERROR: TradingView not found at:
    echo    %TV_EXE%
    echo.
    echo  Update the TV_EXE line at the top of this file.
    pause
    exit /b 1
)
start "" "%TV_EXE%" ^
    --remote-debugging-port=9222 ^
    --remote-allow-origins=https://%NGROK_DOMAIN%

echo        Waiting 5s for TradingView to load...
timeout /t 5 /nobreak > nul

:: ================================================================
::  STEP 2 — Start the local CDP proxy (rewrites Host header)
:: ================================================================
echo [2/4] Starting CDP proxy on port 3001...
start "TradingView CDP Proxy" cmd /k ^
    "title CDP Proxy ^& cd /d ""%MCP_DIR%"" ^& node proxy.js"
timeout /t 2 /nobreak > nul

:: ================================================================
::  STEP 3 — Start ngrok tunnel pointing at the proxy
:: ================================================================
echo [3/4] Starting ngrok tunnel...
start "ngrok ^> %NGROK_DOMAIN%" cmd /k ^
    "title ngrok ^& ngrok http 3001 --log stdout"
echo        Waiting 4s for tunnel to come up...
timeout /t 4 /nobreak > nul

:: ================================================================
::  STEP 4 — Launch Claude Code with the morning analysis prompt
:: ================================================================
echo [4/4] Starting Claude Code morning analysis...
echo.

:: Write the prompt to a temp file so special characters don't break SET
set "PROMPT_FILE=%TEMP%\tv_morning_prompt.txt"

(
echo Connect to TradingView Desktop via the CDP proxy.
echo.
echo Run node connect.js in C:\Users\Dell\tradingview-mcp to confirm the CDP
echo connection is working, then run the full morning SMC+TDI v4 analysis:
echo.
echo For each symbol in this order: XAUUSD, USDJPY, EURUSD
echo   1. Switch TradingView to that symbol
echo   2. Confirm the chart symbol and current timeframe
echo   3. Execute the backtest script:
echo      C:\Users\Dell\tradingview-mcp\scripts\backtest_smc_tdi_v4.js
echo   4. Capture and report the backtest results
echo.
echo After all three symbols are done, provide a structured morning briefing:
echo   - XAUUSD: SMC structure, TDI signal, key levels, trade bias
echo   - USDJPY: SMC structure, TDI signal, key levels, trade bias
echo   - EURUSD: SMC structure, TDI signal, key levels, trade bias
echo   - Top setup of the morning with entry, SL, and TP levels
echo   - Any pairs to avoid today and why
echo.
echo Flag the single highest-probability setup for immediate attention.
echo Prioritise XAUUSD as Peter's primary instrument.
) > "%PROMPT_FILE%"

:: Open Claude Code in a maximised window and pipe the prompt in
start "Claude — Morning Analysis" cmd /k ^
    "title Claude Morning Analysis ^& cd /d ""%MCP_DIR%"" ^& claude < ""%PROMPT_FILE%"""

:: ================================================================
::  Done
:: ================================================================
echo.
echo  ============================================================
echo   Morning routine is running. Four windows have opened:
echo     1. TradingView Desktop  (chart + CDP on port 9222)
echo     2. CDP Proxy            (port 3001, rewrites Host header)
echo     3. ngrok                (tunnel to %NGROK_DOMAIN%)
echo     4. Claude Code          (running the analysis now)
echo  ============================================================
echo.
echo  You can close this launcher window.
echo.
pause
