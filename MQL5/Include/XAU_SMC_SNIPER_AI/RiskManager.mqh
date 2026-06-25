//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  Position sizing + capital protection: per-trade risk %, daily / |
//|  weekly drawdown circuit breakers, consecutive-loss lockout.     |
//+------------------------------------------------------------------+
#ifndef __XSS_RISKMANAGER_MQH__
#define __XSS_RISKMANAGER_MQH__

#include "Defines.mqh"

class CRiskManager
  {
private:
   string   m_symbol;
   double   m_riskPercentDefault;
   double   m_riskPercentMax;
   int      m_maxConsecutiveLosses;
   double   m_dailyDrawdownLimitPct;
   double   m_weeklyDrawdownLimitPct;

   double   m_dayStartEquity;
   double   m_weekStartEquity;
   int      m_currentDayOfYear;
   int      m_currentWeekOfYear;
   int      m_consecutiveLosses;
   bool     m_lockedDaily;
   bool     m_lockedWeekly;
   bool     m_lockedLosses;

   void RefreshCalendarBaselines()
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);

      if(dt.day_of_year != m_currentDayOfYear)
        {
         m_currentDayOfYear = dt.day_of_year;
         m_dayStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
         m_lockedDaily      = false;
        }

      // ISO-ish week bucket: day_of_year/7 is sufficient as a rolling weekly boundary
      int weekBucket = dt.day_of_year / 7;
      if(weekBucket != m_currentWeekOfYear)
        {
         m_currentWeekOfYear = weekBucket;
         m_weekStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
         m_lockedWeekly      = false;
        }
     }

public:
                     CRiskManager()
     {
      m_dayStartEquity     = 0.0;
      m_weekStartEquity    = 0.0;
      m_currentDayOfYear   = -1;
      m_currentWeekOfYear  = -1;
      m_consecutiveLosses  = 0;
      m_lockedDaily        = false;
      m_lockedWeekly       = false;
      m_lockedLosses       = false;
     }

   void Init(const string symbol, const double riskPercentDefault = 0.5,
             const double riskPercentMax = 1.0, const int maxConsecutiveLosses = 3,
             const double dailyDrawdownLimitPct = 3.0, const double weeklyDrawdownLimitPct = 6.0)
     {
      m_symbol                 = symbol;
      m_riskPercentDefault     = riskPercentDefault;
      m_riskPercentMax         = riskPercentMax;
      m_maxConsecutiveLosses   = maxConsecutiveLosses;
      m_dailyDrawdownLimitPct  = dailyDrawdownLimitPct;
      m_weeklyDrawdownLimitPct = weeklyDrawdownLimitPct;
      RefreshCalendarBaselines();
      m_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      m_weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }

   //--- call once per tick / bar before evaluating any new setup ---
   void Update()
     {
      RefreshCalendarBaselines();

      if(m_dayStartEquity > 0 && GetDailyDrawdownPct() >= m_dailyDrawdownLimitPct)
         m_lockedDaily = true;
      if(m_weekStartEquity > 0 && GetWeeklyDrawdownPct() >= m_weeklyDrawdownLimitPct)
         m_lockedWeekly = true;
      m_lockedLosses = (m_consecutiveLosses >= m_maxConsecutiveLosses);
     }

   double GetDailyDrawdownPct() const
     {
      if(m_dayStartEquity <= 0)
         return 0.0;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return (m_dayStartEquity - equity) / m_dayStartEquity * 100.0;
     }

   double GetWeeklyDrawdownPct() const
     {
      if(m_weekStartEquity <= 0)
         return 0.0;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return (m_weekStartEquity - equity) / m_weekStartEquity * 100.0;
     }

   void RegisterTradeResult(const bool win)
     {
      if(win)
         m_consecutiveLosses = 0;
      else
         m_consecutiveLosses++;
     }

   void ResetConsecutiveLosses() { m_consecutiveLosses = 0; }
   int  ConsecutiveLosses() const { return m_consecutiveLosses; }

   bool CanTrade(string &reasonOut) const
     {
      if(m_lockedDaily)
        {
         reasonOut = StringFormat("Daily drawdown limit hit (%.2f%% >= %.2f%%)", GetDailyDrawdownPct(), m_dailyDrawdownLimitPct);
         return false;
        }
      if(m_lockedWeekly)
        {
         reasonOut = StringFormat("Weekly drawdown limit hit (%.2f%% >= %.2f%%)", GetWeeklyDrawdownPct(), m_weeklyDrawdownLimitPct);
         return false;
        }
      if(m_lockedLosses)
        {
         reasonOut = StringFormat("Consecutive loss limit hit (%d >= %d)", m_consecutiveLosses, m_maxConsecutiveLosses);
         return false;
        }
      reasonOut = "";
      return true;
     }

   //--- position size from risk percent and stop distance (in price units) ---
   double CalcLotSize(const double riskPercent, const double slDistancePrice) const
     {
      double riskPct = MathMin(MathMax(riskPercent, 0.0), m_riskPercentMax);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = equity * riskPct / 100.0;

      double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0 || tickSize <= 0 || slDistancePrice <= 0)
         return 0.0;

      double lossPerLot = (slDistancePrice / tickSize) * tickValue;
      if(lossPerLot <= 0)
         return 0.0;

      double lots = riskMoney / lossPerLot;

      double volMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double volMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double volStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

      if(volStep > 0)
         lots = MathFloor(lots / volStep) * volStep;
      lots = MathMax(lots, volMin);
      lots = MathMin(lots, volMax);

      return NormalizeDouble(lots, 2);
     }

   double DefaultRiskPercent() const { return m_riskPercentDefault; }
   void   SetDefaultRiskPercent(const double v) { m_riskPercentDefault = MathMin(MathMax(v, 0.0), m_riskPercentMax); }
  };

#endif // __XSS_RISKMANAGER_MQH__
