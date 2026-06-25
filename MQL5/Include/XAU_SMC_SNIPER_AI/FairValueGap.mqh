//+------------------------------------------------------------------+
//|                                               FairValueGap.mqh   |
//|  3-candle Fair Value Gap (imbalance) detection, with 50%         |
//|  midpoint calculation used as the limit-order entry trigger.    |
//+------------------------------------------------------------------+
#ifndef __XSS_FAIRVALUEGAP_MQH__
#define __XSS_FAIRVALUEGAP_MQH__

#include "Defines.mqh"

#define XSS_MAX_FVG 60

class CFairValueGap
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_scanBars;

   FVGZone         m_zones[];
   int             m_count;
   datetime        m_lastProcessedTime;

   void PushZone(const FVGZone &z)
     {
      if(m_count < XSS_MAX_FVG)
        {
         m_zones[m_count] = z;
         m_count++;
        }
      else
        {
         for(int i = 1; i < XSS_MAX_FVG; i++)
            m_zones[i-1] = m_zones[i];
         m_zones[XSS_MAX_FVG-1] = z;
        }
     }

public:
                     CFairValueGap()
     {
      m_count = 0;
      m_lastProcessedTime = 0;
      ArrayResize(m_zones, XSS_MAX_FVG);
     }

   void Init(const string symbol, const ENUM_TIMEFRAMES tf, const int scanBars = 40)
     {
      m_symbol   = symbol;
      m_tf       = tf;
      m_scanBars = scanBars;
     }

   bool Update()
     {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int needed = m_scanBars + 5;
      int copied = CopyRates(m_symbol, m_tf, 0, needed, rates);
      if(copied < needed)
         return false;

      datetime newest = rates[1].time;
      bool foundNew = false;

      if(newest != m_lastProcessedTime)
        {
         m_lastProcessedTime = newest;
         // candle3=s (recent), candle2=s+1, candle1=s+2 ; start at s=1 (first closed bar)
         for(int s = 1; s <= m_scanBars; s++)
           {
            // bullish FVG: low(candle3) > high(candle1)
            if(rates[s].low > rates[s+2].high)
              {
               FVGZone z;
               z.time      = rates[s+1].time;
               z.bottom    = rates[s+2].high;
               z.top       = rates[s].low;
               z.mid       = (z.top + z.bottom) / 2.0;
               z.bullish   = true;
               z.mitigated = false;
               if(m_count == 0 || z.time > m_zones[m_count-1].time)
                  PushZone(z);
               foundNew = true;
              }
            // bearish FVG: high(candle3) < low(candle1)
            else if(rates[s].high < rates[s+2].low)
              {
               FVGZone z;
               z.time      = rates[s+1].time;
               z.top       = rates[s+2].low;
               z.bottom    = rates[s].high;
               z.mid       = (z.top + z.bottom) / 2.0;
               z.bullish   = false;
               z.mitigated = false;
               if(m_count == 0 || z.time > m_zones[m_count-1].time)
                  PushZone(z);
               foundNew = true;
              }
           }
        }

      //--- mitigation pass: a zone is fully mitigated once price closes through it ---
      double lastClose = rates[1].close;
      for(int i = 0; i < m_count; i++)
        {
         if(m_zones[i].mitigated)
            continue;
         if(m_zones[i].bullish && lastClose < m_zones[i].bottom)
            m_zones[i].mitigated = true;
         else if(!m_zones[i].bullish && lastClose > m_zones[i].top)
            m_zones[i].mitigated = true;
        }

      return foundNew;
     }

   //--- most recent unmitigated zone matching the requested direction ---
   bool GetNearestZone(const ENUM_XSS_BIAS dir, FVGZone &out) const
     {
      for(int i = m_count - 1; i >= 0; i--)
        {
         if(m_zones[i].mitigated)
            continue;
         if(dir == BIAS_BULLISH && m_zones[i].bullish)
           {
            out = m_zones[i];
            return true;
           }
         if(dir == BIAS_BEARISH && !m_zones[i].bullish)
           {
            out = m_zones[i];
            return true;
           }
        }
      return false;
     }

   static bool IsPriceAtMidpoint(const FVGZone &z, const double price, const double tolerance)
     {
      return (MathAbs(price - z.mid) <= tolerance);
     }

   int Count() const { return m_count; }
  };

#endif // __XSS_FAIRVALUEGAP_MQH__
