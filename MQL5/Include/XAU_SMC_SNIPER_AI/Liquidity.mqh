//+------------------------------------------------------------------+
//|                                                  Liquidity.mqh   |
//|  Liquidity sweep detection: identifies the most recent           |
//|  buy-side / sell-side liquidity pool (prior swing extreme) and   |
//|  flags a sweep when price pierces it and closes back inside the  |
//|  prior range (a "stop hunt" / inducement pattern).               |
//+------------------------------------------------------------------+
#ifndef __XSS_LIQUIDITY_MQH__
#define __XSS_LIQUIDITY_MQH__

#include "Defines.mqh"

class CLiquidity
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_lookbackBars;   // window used to find the liquidity level
   int             m_recencyBars;    // how many recent closed bars may register a sweep

   ENUM_XSS_SWEEP  m_lastSweep;
   double          m_sweepLevel;     // the prior liquidity level that was taken
   double          m_sweepExtreme;   // the actual wick extreme of the sweeping bar
   datetime        m_sweepTime;

public:
                     CLiquidity()
     {
      m_lastSweep    = SWEEP_NONE;
      m_sweepLevel   = 0.0;
      m_sweepExtreme = 0.0;
      m_sweepTime    = 0;
     }

   void Init(const string symbol, const ENUM_TIMEFRAMES tf,
             const int lookbackBars = 20, const int recencyBars = 3)
     {
      m_symbol       = symbol;
      m_tf           = tf;
      m_lookbackBars = lookbackBars;
      m_recencyBars  = recencyBars;
     }

   //--- scans the most recent closed bars for a sweep+reclaim pattern ---
   bool Update()
     {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int needed = m_lookbackBars + m_recencyBars + 5;
      int copied = CopyRates(m_symbol, m_tf, 0, needed, rates);
      if(copied < needed)
         return false;

      for(int s = 1; s <= m_recencyBars; s++)
        {
         // liquidity level = extreme of the window BEFORE bar s (excludes bar s itself)
         double levelLow  = rates[s+1].low;
         double levelHigh = rates[s+1].high;
         for(int w = s + 2; w < s + 1 + m_lookbackBars; w++)
           {
            if(rates[w].low  < levelLow)  levelLow  = rates[w].low;
            if(rates[w].high > levelHigh) levelHigh = rates[w].high;
           }

         //--- sell-side liquidity swept: wick below levelLow, close back above it ---
         if(rates[s].low < levelLow && rates[s].close > levelLow)
           {
            if(m_sweepTime != rates[s].time || m_lastSweep != SWEEP_SELL_SIDE)
              {
               m_lastSweep    = SWEEP_SELL_SIDE;
               m_sweepLevel   = levelLow;
               m_sweepExtreme = rates[s].low;
               m_sweepTime    = rates[s].time;
               return true;
              }
           }

         //--- buy-side liquidity swept: wick above levelHigh, close back below it ---
         if(rates[s].high > levelHigh && rates[s].close < levelHigh)
           {
            if(m_sweepTime != rates[s].time || m_lastSweep != SWEEP_BUY_SIDE)
              {
               m_lastSweep    = SWEEP_BUY_SIDE;
               m_sweepLevel   = levelHigh;
               m_sweepExtreme = rates[s].high;
               m_sweepTime    = rates[s].time;
               return true;
              }
           }
        }

      return false;
     }

   void SetLookbackBars(const int lookbackBars) { m_lookbackBars = lookbackBars; }

   ENUM_XSS_SWEEP LastSweep()      const { return m_lastSweep;    }
   double         SweepLevel()     const { return m_sweepLevel;   }
   double         SweepExtreme()   const { return m_sweepExtreme; }
   datetime       SweepTime()      const { return m_sweepTime;    }

   //--- true if the last detected sweep is still "fresh" (within N bars of now) ---
   bool IsFresh(const int maxBarsAge) const
     {
      if(m_lastSweep == SWEEP_NONE || m_sweepTime == 0)
         return false;
      long age = (long)((TimeCurrent() - m_sweepTime) / PeriodSeconds(m_tf));
      return age <= maxBarsAge;
     }

   //--- a sell-side sweep supports a bullish (buy) setup, buy-side a bearish (sell) setup ---
   bool MatchesDirection(const ENUM_XSS_BIAS dir) const
     {
      if(dir == BIAS_BULLISH)
         return m_lastSweep == SWEEP_SELL_SIDE;
      if(dir == BIAS_BEARISH)
         return m_lastSweep == SWEEP_BUY_SIDE;
      return false;
     }
  };

#endif // __XSS_LIQUIDITY_MQH__
