//+------------------------------------------------------------------+
//|                                                  Statistics.mqh  |
//|  Running performance statistics (win rate, RR, daily/weekly      |
//|  aggregates) and simple market-regime classification used for    |
//|  market-memory tagging and AI pattern discovery.                 |
//+------------------------------------------------------------------+
#ifndef __XSS_STATISTICS_MQH__
#define __XSS_STATISTICS_MQH__

#include "Defines.mqh"

#define XSS_MAX_REGIME_BUCKETS 32

class CStatistics
  {
private:
   int      m_totalTrades;
   int      m_totalWins;
   int      m_totalLosses;
   double   m_totalProfit;
   double   m_sumRR;

   int      m_dayTrades, m_dayWins, m_dayLosses;
   double   m_dayProfit;
   int      m_currentDayOfYear;

   int      m_weekTrades, m_weekWins, m_weekLosses;
   double   m_weekProfit;
   int      m_currentWeekBucket;

   //--- enhanced performance tracking (v2.0) ---
   double   m_sumWinProfit;          // sum of winning trades' profit (positive)
   double   m_sumLossProfit;         // sum of losing trades' |profit| (positive magnitude)
   double   m_equity;                // running cumulative profit, used as a simple equity proxy
   double   m_peakEquity;
   double   m_maxDrawdown;           // peak-to-trough drawdown of m_equity, in account-currency units
   double   m_sumReturn;             // sum of per-trade RR, used as the "return" series for Sharpe/Sortino
   double   m_sumSquaredReturn;
   double   m_sumSquaredDownside;    // sum of squared RR for trades with RR < 0
   int      m_downsideCount;
   datetime m_firstTradeTime;

   //--- regime-segmented performance, parallel arrays since MQL5 has no native map (v2.0) ---
   string   m_regimeNames[];
   int      m_regimeTrades[];
   int      m_regimeWins[];
   double   m_regimeProfit[];
   double   m_regimeSumRR[];
   int      m_regimeCount;

   int FindOrAddRegime(const string name)
     {
      for(int i = 0; i < m_regimeCount; i++)
         if(m_regimeNames[i] == name)
            return i;
      if(m_regimeCount >= XSS_MAX_REGIME_BUCKETS)
         return -1;
      m_regimeNames[m_regimeCount]   = name;
      m_regimeTrades[m_regimeCount]  = 0;
      m_regimeWins[m_regimeCount]    = 0;
      m_regimeProfit[m_regimeCount]  = 0.0;
      m_regimeSumRR[m_regimeCount]   = 0.0;
      m_regimeCount++;
      return m_regimeCount - 1;
     }

   void RollCalendar()
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_year != m_currentDayOfYear)
        {
         m_currentDayOfYear = dt.day_of_year;
         m_dayTrades = 0; m_dayWins = 0; m_dayLosses = 0; m_dayProfit = 0.0;
        }
      int weekBucket = dt.day_of_year / 7;
      if(weekBucket != m_currentWeekBucket)
        {
         m_currentWeekBucket = weekBucket;
         m_weekTrades = 0; m_weekWins = 0; m_weekLosses = 0; m_weekProfit = 0.0;
        }
     }

public:
                     CStatistics()
     {
      m_totalTrades = 0; m_totalWins = 0; m_totalLosses = 0; m_totalProfit = 0.0; m_sumRR = 0.0;
      m_dayTrades = 0; m_dayWins = 0; m_dayLosses = 0; m_dayProfit = 0.0;
      m_weekTrades = 0; m_weekWins = 0; m_weekLosses = 0; m_weekProfit = 0.0;
      m_currentDayOfYear = -1;
      m_currentWeekBucket = -1;

      m_sumWinProfit = 0.0; m_sumLossProfit = 0.0;
      m_equity = 0.0; m_peakEquity = 0.0; m_maxDrawdown = 0.0;
      m_sumReturn = 0.0; m_sumSquaredReturn = 0.0; m_sumSquaredDownside = 0.0; m_downsideCount = 0;
      m_firstTradeTime = 0;
      m_regimeCount = 0;
      ArrayResize(m_regimeNames,  XSS_MAX_REGIME_BUCKETS);
      ArrayResize(m_regimeTrades, XSS_MAX_REGIME_BUCKETS);
      ArrayResize(m_regimeWins,   XSS_MAX_REGIME_BUCKETS);
      ArrayResize(m_regimeProfit, XSS_MAX_REGIME_BUCKETS);
      ArrayResize(m_regimeSumRR,  XSS_MAX_REGIME_BUCKETS);
     }

   //--- regime is an optional free-form label (e.g. CMarketRegime::ToString()) for segmented stats (v2.0) ---
   void RegisterTrade(const double profit, const double rr, const bool win, const string regime = "")
     {
      RollCalendar();

      if(m_firstTradeTime == 0)
         m_firstTradeTime = TimeCurrent();

      m_totalTrades++;
      m_totalProfit += profit;
      m_sumRR += rr;
      if(win) { m_totalWins++; m_sumWinProfit += profit; }
      else    { m_totalLosses++; m_sumLossProfit += MathAbs(profit); }

      //--- equity / drawdown ---
      m_equity += profit;
      if(m_equity > m_peakEquity)
         m_peakEquity = m_equity;
      double dd = m_peakEquity - m_equity;
      if(dd > m_maxDrawdown)
         m_maxDrawdown = dd;

      //--- return-series accumulators for Sharpe/Sortino (RR used as the per-trade "return") ---
      m_sumReturn += rr;
      m_sumSquaredReturn += rr * rr;
      if(rr < 0.0)
        {
         m_sumSquaredDownside += rr * rr;
         m_downsideCount++;
        }

      //--- regime bucket ---
      if(regime != "")
        {
         int idx = FindOrAddRegime(regime);
         if(idx >= 0)
           {
            m_regimeTrades[idx]++;
            m_regimeProfit[idx] += profit;
            m_regimeSumRR[idx]  += rr;
            if(win) m_regimeWins[idx]++;
           }
        }

      m_dayTrades++;
      m_dayProfit += profit;
      if(win) m_dayWins++; else m_dayLosses++;

      m_weekTrades++;
      m_weekProfit += profit;
      if(win) m_weekWins++; else m_weekLosses++;
     }

   double WinRatePct() const
     {
      if(m_totalTrades == 0) return 0.0;
      return (double)m_totalWins / (double)m_totalTrades * 100.0;
     }

   double AvgRR() const
     {
      if(m_totalTrades == 0) return 0.0;
      return m_sumRR / m_totalTrades;
     }

   int    TotalTrades() const { return m_totalTrades; }
   double TotalProfit() const { return m_totalProfit; }

   void DailyStats(int &trades, int &wins, int &losses, double &profit)
     {
      RollCalendar();
      trades = m_dayTrades; wins = m_dayWins; losses = m_dayLosses; profit = m_dayProfit;
     }

   void WeeklyStats(int &trades, int &wins, int &losses, double &profit)
     {
      RollCalendar();
      trades = m_weekTrades; wins = m_weekWins; losses = m_weekLosses; profit = m_weekProfit;
     }

   double DailyWinRatePct()
     {
      RollCalendar();
      if(m_dayTrades == 0) return 0.0;
      return (double)m_dayWins / (double)m_dayTrades * 100.0;
     }

   double WeeklyWinRatePct()
     {
      RollCalendar();
      if(m_weekTrades == 0) return 0.0;
      return (double)m_weekWins / (double)m_weekTrades * 100.0;
     }

   //--- coarse regime tag used to bucket trades for the AI pattern-discovery export ---
   static string ClassifyRegime(const double atr, const double atrThreshold, const ENUM_XSS_SESSION session)
     {
      string vol = (atr >= atrThreshold * 1.5) ? "high_vol" : (atr >= atrThreshold ? "normal_vol" : "low_vol");
      string sess = (session == SESSION_LONDON) ? "london" : (session == SESSION_NEWYORK) ? "newyork" : "off_session";
      return vol + "_" + sess;
     }

   //--- enhanced statistics (v2.0) ---------------------------------------------------------------

   double AvgWin() const  { return (m_totalWins   > 0) ? m_sumWinProfit  / m_totalWins   : 0.0; }
   double AvgLoss() const { return (m_totalLosses > 0) ? m_sumLossProfit / m_totalLosses : 0.0; }

   //--- classic expectancy: (winRate*avgWin) - (lossRate*avgLoss), in account-currency units ---
   double Expectancy() const
     {
      if(m_totalTrades == 0)
         return 0.0;
      double winRate  = (double)m_totalWins   / m_totalTrades;
      double lossRate = (double)m_totalLosses / m_totalTrades;
      return winRate * AvgWin() - lossRate * AvgLoss();
     }

   //--- gross win / gross loss; 0.0 when there is not yet a losing trade to divide by ---
   double ProfitFactor() const
     {
      if(m_totalTrades == 0 || m_sumLossProfit <= 0.0)
         return 0.0;
      return m_sumWinProfit / m_sumLossProfit;
     }

   double MaxDrawdown() const { return m_maxDrawdown; }

   double RecoveryFactor() const
     {
      if(m_maxDrawdown <= 0.0)
         return 0.0;
      return m_totalProfit / m_maxDrawdown;
     }

   //--- non-annualized Sharpe ratio over the per-trade RR return series ---
   double SharpeRatio() const
     {
      if(m_totalTrades < 2)
         return 0.0;
      double mean     = m_sumReturn / m_totalTrades;
      double variance = (m_sumSquaredReturn / m_totalTrades) - (mean * mean);
      if(variance <= 0.0)
         return 0.0;
      return mean / MathSqrt(variance);
     }

   //--- Sortino ratio: mean RR over downside deviation (only losing trades contribute to the denominator) ---
   double SortinoRatio() const
     {
      if(m_totalTrades < 2 || m_downsideCount == 0)
         return 0.0;
      double mean = m_sumReturn / m_totalTrades;
      double downsideVariance = m_sumSquaredDownside / m_totalTrades;
      double downsideDev = MathSqrt(downsideVariance);
      if(downsideDev <= 0.0)
         return 0.0;
      return mean / downsideDev;
     }

   //--- Calmar ratio: profit annualized by elapsed trading time, over max drawdown ---
   double CalmarRatio() const
     {
      if(m_maxDrawdown <= 0.0 || m_firstTradeTime <= 0)
         return 0.0;
      double elapsedYears = MathMax(1.0 / 365.25, (double)(TimeCurrent() - m_firstTradeTime) / (365.25 * 86400.0));
      double annualizedProfit = m_totalProfit / elapsedYears;
      return annualizedProfit / m_maxDrawdown;
     }

   int RegimeCount() const { return m_regimeCount; }

   bool GetRegimeStats(const int idx, string &name, int &trades, int &wins, double &profit, double &avgRR) const
     {
      if(idx < 0 || idx >= m_regimeCount)
         return false;
      name   = m_regimeNames[idx];
      trades = m_regimeTrades[idx];
      wins   = m_regimeWins[idx];
      profit = m_regimeProfit[idx];
      avgRR  = (trades > 0) ? m_regimeSumRR[idx] / trades : 0.0;
      return true;
     }

   double RegimeWinRatePct(const int idx) const
     {
      if(idx < 0 || idx >= m_regimeCount || m_regimeTrades[idx] == 0)
         return 0.0;
      return 100.0 * m_regimeWins[idx] / m_regimeTrades[idx];
     }
  };

#endif // __XSS_STATISTICS_MQH__
