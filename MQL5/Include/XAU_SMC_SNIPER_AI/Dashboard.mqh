//+------------------------------------------------------------------+
//|                                                    Dashboard.mqh |
//|  On-chart analytics panel (v2.0). Read-only visualisation layer  |
//|  built on OBJ_RECTANGLE_LABEL / OBJ_LABEL chart objects. Pulls   |
//|  from the existing engines (CMarketRegime, CAdaptiveConfluence,  |
//|  CExecutionOptimizer, CStatistics, CRiskManager) - it does not   |
//|  own any trading state and never influences trade decisions.    |
//+------------------------------------------------------------------+
#ifndef __XSS_DASHBOARD_MQH__
#define __XSS_DASHBOARD_MQH__

#include "Defines.mqh"
#include "MarketRegime.mqh"
#include "AdaptiveConfluence.mqh"
#include "ExecutionOptimizer.mqh"
#include "Statistics.mqh"
#include "RiskManager.mqh"

class CDashboard
  {
private:
   string   m_prefix;
   int      m_x, m_y;
   int      m_fontSize;
   int      m_lineHeight;
   int      m_panelWidth;
   bool     m_created;
   int      m_lineCursor;

   void EnsureBackground(const int totalLines)
     {
      string bgName = m_prefix + "BG";
      int height = 24 + totalLines * m_lineHeight;
      if(ObjectFind(0, bgName) < 0)
        {
         ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
         ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, C'18,18,18');
         ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
         ObjectSetInteger(0, bgName, OBJPROP_COLOR, clrDimGray);
        }
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, m_x - 6);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, m_y - 6);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, m_panelWidth);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, height);
     }

   void SetLine(const string text, const color clr = clrWhiteSmoke, const bool header = false)
     {
      string name = m_prefix + "L" + IntegerToString(m_lineCursor);
      int y = m_y + m_lineCursor * m_lineHeight;
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetString(0, name, OBJPROP_FONT, header ? "Consolas Bold" : "Consolas");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        }
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, header ? m_fontSize + 1 : m_fontSize);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      m_lineCursor++;
     }

   //--- sum of (volume * |open-SL| converted to money) across this symbol/magic's open positions ---
   double CalcOpenRiskPct(const string symbol, const ulong magic) const
     {
      double riskMoney = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)magic)
            continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl         = PositionGetDouble(POSITION_SL);
         double volume      = PositionGetDouble(POSITION_VOLUME);
         if(sl <= 0.0)
            continue;

         double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickValue <= 0.0 || tickSize <= 0.0)
            continue;

         double distance = MathAbs(openPrice - sl);
         riskMoney += (distance / tickSize) * tickValue * volume;
        }

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return (equity > 0.0) ? 100.0 * riskMoney / equity : 0.0;
     }

   string FindBestRegime(CStatistics &stats, double &winRateOut) const
     {
      string best = "n/a";
      double bestWr = -1.0;
      for(int i = 0; i < stats.RegimeCount(); i++)
        {
         string name; int trades, wins; double profit, avgRR;
         if(!stats.GetRegimeStats(i, name, trades, wins, profit, avgRR) || trades <= 0)
            continue;
         double wr = stats.RegimeWinRatePct(i);
         if(wr > bestWr)
           {
            bestWr = wr;
            best   = name;
           }
        }
      winRateOut = (bestWr >= 0.0) ? bestWr : 0.0;
      return best;
     }

   string FindWorstRegime(CStatistics &stats, double &winRateOut) const
     {
      string worst = "n/a";
      double worstWr = 101.0;
      for(int i = 0; i < stats.RegimeCount(); i++)
        {
         string name; int trades, wins; double profit, avgRR;
         if(!stats.GetRegimeStats(i, name, trades, wins, profit, avgRR) || trades <= 0)
            continue;
         double wr = stats.RegimeWinRatePct(i);
         if(wr < worstWr)
           {
            worstWr = wr;
            worst   = name;
           }
        }
      winRateOut = (worstWr <= 100.0) ? worstWr : 0.0;
      return worst;
     }

public:
                     CDashboard()
     {
      m_prefix     = "XSS_DASH_";
      m_x          = 12;
      m_y          = 20;
      m_fontSize   = 8;
      m_lineHeight = 14;
      m_panelWidth = 320;
      m_created    = false;
      m_lineCursor = 0;
     }

   void Init(const int x = 12, const int y = 20, const int fontSize = 8, const int panelWidth = 320)
     {
      m_x = x; m_y = y; m_fontSize = fontSize; m_panelWidth = panelWidth;
      m_created = true;
     }

   //--- redraws the whole panel; call from OnTick/OnTimer, not on every price tick if perf matters ---
   void Render(const string symbol, const ulong magic, const int strategyVersion,
               const double aiConfidencePct, const double lastConfluenceScore, const double lastConfluenceMaxScore,
               const double currentSpreadPoints, const double currentAtr,
               CMarketRegime &regime, CAdaptiveConfluence &adaptive, CExecutionOptimizer &execOpt,
               CStatistics &stats, CRiskManager &risk)
     {
      m_lineCursor = 0;

      SetLine("XAU_SMC_SNIPER_AI  v2.0", clrGold, true);
      SetLine(StringFormat("Strategy v%d   AI Confidence: %.1f%%", strategyVersion, aiConfidencePct), clrLightGray);
      SetLine(StringFormat("Regime: %s", CMarketRegime::ToString(regime.Current())), clrAqua);
      SetLine(StringFormat("Confluence: %.1f / %.1f  (adaptive weights v%d)",
                            lastConfluenceScore, lastConfluenceMaxScore, adaptive.LastAppliedVersion()), clrWhite);
      SetLine(StringFormat("Spread: %.1f pts   ATR(M5): %.5f", currentSpreadPoints, currentAtr), clrSilver);

      SetLine("---- Risk ----", clrOrange, true);
      string reason;
      bool canTrade = risk.CanTrade(reason);
      SetLine(StringFormat("Open risk: %.2f%%   Consec. losses: %d", CalcOpenRiskPct(symbol, magic), risk.ConsecutiveLosses()),
              clrWhite);
      SetLine(StringFormat("Daily DD: %.2f%%   Weekly DD: %.2f%%", risk.GetDailyDrawdownPct(), risk.GetWeeklyDrawdownPct()),
              clrWhite);
      SetLine(canTrade ? "Trading: ENABLED" : ("Trading: BLOCKED (" + reason + ")"), canTrade ? clrLimeGreen : clrTomato);

      SetLine("---- Performance ----", clrOrange, true);
      int dTrades, dWins, dLosses; double dProfit;
      stats.DailyStats(dTrades, dWins, dLosses, dProfit);
      int wTrades, wWins, wLosses; double wProfit;
      stats.WeeklyStats(wTrades, wWins, wLosses, wProfit);
      SetLine(StringFormat("Today: %d trades  WR %.1f%%  P/L %.2f", dTrades, stats.DailyWinRatePct(), dProfit), clrWhite);
      SetLine(StringFormat("Week:  %d trades  WR %.1f%%  P/L %.2f", wTrades, stats.WeeklyWinRatePct(), wProfit), clrWhite);
      SetLine(StringFormat("All-time: %d trades  WR %.1f%%  AvgRR %.2f  P/L %.2f",
                            stats.TotalTrades(), stats.WinRatePct(), stats.AvgRR(), stats.TotalProfit()), clrWhite);
      SetLine(StringFormat("Expectancy %.2f   ProfitFactor %.2f   RecoveryFactor %.2f",
                            stats.Expectancy(), stats.ProfitFactor(), stats.RecoveryFactor()), clrWhite);
      SetLine(StringFormat("MaxDD %.2f   Sharpe %.2f   Sortino %.2f   Calmar %.2f",
                            stats.MaxDrawdown(), stats.SharpeRatio(), stats.SortinoRatio(), stats.CalmarRatio()), clrWhite);

      SetLine("---- Patterns ----", clrOrange, true);
      double bestWr, worstWr;
      string bestRegime  = FindBestRegime(stats, bestWr);
      string worstRegime = FindWorstRegime(stats, worstWr);
      SetLine(StringFormat("Best:  %s  (WR %.1f%%)", bestRegime, bestWr), clrLimeGreen);
      SetLine(StringFormat("Worst: %s  (WR %.1f%%)", worstRegime, worstWr), clrTomato);

      SetLine("---- Execution Quality ----", clrOrange, true);
      SetLine(StringFormat("Samples: %d   AvgSlippage %.1fpts   AvgLatency %.0fms",
                            execOpt.Count(), execOpt.AvgSlippagePoints(), execOpt.AvgLatencyMs()), clrWhite);
      SetLine(StringFormat("Requote rate %.1f%%   Missed fill rate %.1f%%",
                            execOpt.RequoteRatePct(), execOpt.MissedFillRatePct()), clrWhite);

      EnsureBackground(m_lineCursor);
      ChartRedraw(0);
     }

   void Remove()
     {
      ObjectsDeleteAll(0, m_prefix);
     }
  };

#endif // __XSS_DASHBOARD_MQH__
