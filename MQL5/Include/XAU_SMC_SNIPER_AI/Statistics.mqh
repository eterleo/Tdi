//+------------------------------------------------------------------+
//|                                                  Statistics.mqh  |
//|  Running performance statistics (win rate, RR, daily/weekly      |
//|  aggregates) and simple market-regime classification used for    |
//|  market-memory tagging and AI pattern discovery.                 |
//+------------------------------------------------------------------+
#ifndef __XSS_STATISTICS_MQH__
#define __XSS_STATISTICS_MQH__

#include "Defines.mqh"

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
     }

   void RegisterTrade(const double profit, const double rr, const bool win)
     {
      RollCalendar();

      m_totalTrades++;
      m_totalProfit += profit;
      m_sumRR += rr;
      if(win) m_totalWins++; else m_totalLosses++;

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
  };

#endif // __XSS_STATISTICS_MQH__
