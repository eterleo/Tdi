//+------------------------------------------------------------------+
//|                                Bybit_HFT_Modules_Example.mq5      |
//| Integration scaffold showing how the 10 BybitHFT modules wire     |
//| together. This is NOT a complete trading strategy: the actual     |
//| entry signal (step 7 below) is a placeholder TODO meant to be     |
//| replaced by your existing TDI_CLEAN_EA / RSI AutoTrader / EMA     |
//| crossover / AI signal logic once that code is merged in. Treat    |
//| this file as the harness that the other 10 modules plug into.    |
//+------------------------------------------------------------------+
#property copyright "HFTAI"
#property version   "1.00"
#property strict

#include <BybitHFT\SpreadSlippageAnalyzer.mqh>
#include <BybitHFT\VolatilitySizing.mqh>
#include <BybitHFT\EquityGovernance.mqh>
#include <BybitHFT\CorrelationFilter.mqh>
#include <BybitHFT\CorrelationWeightedSizer.mqh>
#include <BybitHFT\SlippageAwareExecution.mqh>
#include <BybitHFT\LiquiditySweepDetector.mqh>
#include <BybitHFT\DrawdownRecoveryProtocol.mqh>
#include <BybitHFT\LatencySlippageBudget.mqh>

//================================== Inputs ==================================
input long   InpMagicNumber          = 770421;
input double InpDailyLossLimitPercent= 6.0;      // module 3/5: daily equity loss limit
input int    InpSessionStartHour     = 0;        // module 5: broker-server hour, 0-23
input int    InpSessionEndHour       = 24;       // 24 = no session restriction
input int    InpMaxPositionsNormal   = 3;

input double InpMaxSpreadPoints      = 50;       // module 1
input double InpMinBookVolume        = 1.0;      // module 1

input int    InpAtrPeriod            = 14;       // module 2
input int    InpVolRollingLookback   = 50;       // module 2
input double InpRiskPercent          = 0.5;      // module 2
input double InpDefaultSlPoints      = 300;
input double InpDefaultTpPoints      = 450;

input string InpCorrelatedSymbols    = "XAUUSD,BTCUSD,ETHUSD"; // module 4/9, CSV
input double InpHighCorrThreshold    = 0.75;

input int    InpLossStreakCooldown   = 3;        // module 8
input int    InpWinStreakRecover     = 5;
input int    InpCooldownSeconds      = 900;
input int    InpRecoveryResetSeconds = 3600;

input int    InpMaxLatencyMs         = 50;       // module 10
input double InpLatencyDriftPerMs    = 0.05;

input bool   InpUseLiquiditySweepFilter = true;  // module 7

//================================== Globals ==================================
CSpreadSlippageAnalyzer    g_spread;
CVolatilitySizing          g_vol;
CEquityGovernance          g_gov;
CCorrelationFilter         g_corr;
CCorrelationWeightedSizer  g_corr_sizer;
CSlippageAwareExecution    g_exec;
CLiquiditySweepDetector    g_sweep;
CDrawdownRecoveryProtocol  g_recovery;
CLatencySlippageBudget     g_latency;

string g_tracked_symbols[];

//+------------------------------------------------------------------+
void GovernanceLogger(const string event, const string detail)
{
   // TODO: route to TradeLogger.mqh / PostgreSQL once that module is available.
   PrintFormat("HFTAI: governance-log event=%s detail=%s", event, detail);
}

void CorrelationMatrixLogger(const string symbol_a, const string symbol_b, const double correlation)
{
   // TODO: route to TradeLogger.mqh / PostgreSQL once that module is available.
   PrintFormat("HFTAI: corr-log %s/%s=%.3f", symbol_a, symbol_b, correlation);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_spread.Init(_Symbol, 100, InpMaxSpreadPoints, InpMinBookVolume);
   if(!g_vol.Init(_Symbol, PERIOD_M1, InpAtrPeriod, InpVolRollingLookback)) return INIT_FAILED;
   g_gov.Init(InpDailyLossLimitPercent, InpSessionStartHour, InpSessionEndHour, InpMaxPositionsNormal, GovernanceLogger);

   g_corr.Init(InpHighCorrThreshold);
   StringSplit(InpCorrelatedSymbols, ',', g_tracked_symbols);
   for(int i = 0; i < ArraySize(g_tracked_symbols); i++)
      g_corr.AddSymbol(g_tracked_symbols[i], InpVolRollingLookback);
   g_corr_sizer.Init(GetPointer(g_corr), CorrelationMatrixLogger);

   g_exec.Init(_Symbol, InpMagicNumber, GetPointer(g_spread));
   g_sweep.Init(_Symbol);
   g_recovery.Init(InpLossStreakCooldown, InpWinStreakRecover, InpCooldownSeconds, InpRecoveryResetSeconds);
   g_latency.Init(InpMaxLatencyMs, InpLatencyDriftPerMs);

   if(!MarketBookAdd(_Symbol))
      PrintFormat("HFTAI: MarketBookAdd failed, error %d", GetLastError());

   EventSetTimer(60); // module 9: periodic correlation-matrix logging
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_vol.Deinit();
   MarketBookRelease(_Symbol);
   EventKillTimer();
}

void OnTimer()
{
   g_corr_sizer.LogMatrix(g_tracked_symbols, ArraySize(g_tracked_symbols));
}

//+------------------------------------------------------------------+
//| Returns the symbols of currently open positions under our magic,  |
//| excluding `_Symbol` itself, for the correlation-weighted sizer.   |
//+------------------------------------------------------------------+
int CollectOpenSymbols(string &out_symbols[])
{
   int count = 0;
   ArrayResize(out_symbols, PositionsTotal());
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym == _Symbol) continue;
      out_symbols[count++] = sym;
   }
   ArrayResize(out_symbols, count);
   return count;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // --- Step 1 (module 1): keep spread history fresh, gate on spread/depth.
   g_spread.OnTickUpdate();

   // --- Step 2 (module 3/5): update equity governance state.
   g_gov.Update();
   if(!g_gov.IsTradingAllowed()) return;

   // --- Step 3 (module 1): spread/liquidity gate.
   if(!g_spread.IsEntryAllowed()) return;

   // --- Step 4 (module 8): recovery-protocol cooldown gate.
   if(g_recovery.IsInCooldown()) return;

   // --- Step 5 (module 2): refresh volatility baseline (cheap; fine every tick).
   g_vol.UpdateAndGetAtr();
   double volatility_ratio = g_vol.VolatilityRatio();

   // --- Step 6: feed module 4's rolling close series once per bar close.
   //     Updates every tracked symbol (not just _Symbol) since iClose() can read
   //     any symbol in Market Watch regardless of which chart the EA is attached to.
   static datetime last_bar_time = 0;
   datetime cur_bar_time = iTime(_Symbol, PERIOD_M15, 0);
   if(cur_bar_time != last_bar_time)
   {
      last_bar_time = cur_bar_time;
      for(int i = 0; i < ArraySize(g_tracked_symbols); i++)
         g_corr.Update(g_tracked_symbols[i], iClose(g_tracked_symbols[i], PERIOD_M15, 1));
   }

   // --- Step 7: TODO - replace with your real signal source (TDI/RSI/EMA/AI).
   //     direction: -1 sell, 0 hold, 1 buy.
   int direction = 0;
   if(direction == 0) return;

   g_latency.MarkSignal(); // module 10: start the latency clock the instant the signal fires

   // --- Step 8 (module 7): optional liquidity-sweep confirmation filter.
   if(InpUseLiquiditySweepFilter && !g_sweep.IsSweepConfirmed(direction)) return;

   // --- Step 9: position cap from governance.
   if(PositionsTotal() >= g_gov.GetMaxPositions()) return;

   // --- Step 10 (modules 2, 5, 8, 9): compose all the size multipliers.
   double base_lots = g_vol.ComputeLots(InpRiskPercent, InpDefaultSlPoints);
   string open_symbols[];
   int open_count = CollectOpenSymbols(open_symbols);
   double lots = g_corr_sizer.ComputeLots(_Symbol, base_lots, open_symbols, open_count);
   lots *= g_gov.GetSizeMultiplier();
   lots *= g_recovery.GetSizeMultiplier();
   if(lots <= 0.0) return;

   // --- Step 11 (module 10): widen SL by latency-implied drift before building the order.
   double sl_points = g_latency.AdjustedSlPoints(InpDefaultSlPoints);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entry = (direction > 0) ? tick.ask : tick.bid;
   double sl_price = (direction > 0) ? entry - sl_points * point : entry + sl_points * point;
   double tp_price = (direction > 0) ? entry + InpDefaultTpPoints * point : entry - InpDefaultTpPoints * point;

   // --- Step 12 (modules 6, 1): slippage-aware async execution.
   g_exec.Execute(direction, lots, sl_price, tp_price, volatility_ratio);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(request.magic != InpMagicNumber) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   // module 8: feed win/loss streak tracking from the realized profit of the closing deal.
   if(HistoryDealSelect(trans.deal))
   {
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_OUT)
         g_recovery.RecordTradeResult(profit >= 0.0);
   }
}
