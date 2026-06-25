//+------------------------------------------------------------------+
//|                                               SupplyDemand.mqh   |
//|  Supply / Demand zone detection: a small consolidation "base"    |
//|  immediately followed by a strong displacement candle (body      |
//|  size well above ATR) marks the base as a demand (bullish        |
//|  displacement) or supply (bearish displacement) zone.            |
//+------------------------------------------------------------------+
#ifndef __XSS_SUPPLYDEMAND_MQH__
#define __XSS_SUPPLYDEMAND_MQH__

#include "Defines.mqh"

#define XSS_MAX_SD_ZONES 40

class CSupplyDemand
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_scanBars;
   int             m_atrPeriod;
   double          m_impulseMultiplier;
   int             m_baseBars;
   int             m_atrHandle;

   SDZone          m_zones[];
   bool            m_zoneWasInside[];   // previous-bar "price inside zone" state, for touch counting (v2.0)
   int             m_count;
   datetime        m_lastProcessedTime;

   void PushZone(const SDZone &z)
     {
      if(m_count < XSS_MAX_SD_ZONES)
        {
         m_zones[m_count] = z;
         m_zoneWasInside[m_count] = false;
         m_count++;
        }
      else
        {
         for(int i = 1; i < XSS_MAX_SD_ZONES; i++)
           {
            m_zones[i-1] = m_zones[i];
            m_zoneWasInside[i-1] = m_zoneWasInside[i];
           }
         m_zones[XSS_MAX_SD_ZONES-1] = z;
         m_zoneWasInside[XSS_MAX_SD_ZONES-1] = false;
        }
     }

public:
                     CSupplyDemand()
     {
      m_count = 0;
      m_lastProcessedTime = 0;
      m_atrHandle = INVALID_HANDLE;
      ArrayResize(m_zones, XSS_MAX_SD_ZONES);
      ArrayResize(m_zoneWasInside, XSS_MAX_SD_ZONES);
     }

   void Init(const string symbol, const ENUM_TIMEFRAMES tf, const int scanBars = 60,
             const int atrPeriod = 14, const double impulseMultiplier = 1.5, const int baseBars = 2)
     {
      m_symbol            = symbol;
      m_tf                = tf;
      m_scanBars          = scanBars;
      m_atrPeriod         = atrPeriod;
      m_impulseMultiplier = impulseMultiplier;
      m_baseBars          = baseBars;
      m_atrHandle         = iATR(m_symbol, m_tf, m_atrPeriod);
     }

   ~CSupplyDemand()
     {
      if(m_atrHandle != INVALID_HANDLE)
         IndicatorRelease(m_atrHandle);
     }

   bool Update()
     {
      if(m_atrHandle == INVALID_HANDLE)
         return false;

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int needed = m_scanBars + m_baseBars + 5;
      int copied = CopyRates(m_symbol, m_tf, 0, needed, rates);
      if(copied < needed)
         return false;

      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(m_atrHandle, 0, 0, needed, atrBuf) < needed)
         return false;

      datetime newest = rates[1].time;
      if(newest == m_lastProcessedTime)
         return MitigationPass(rates[1].close);
      m_lastProcessedTime = newest;

      bool foundNew = false;
      // s = impulse candle shift, base candles are s+1..s+m_baseBars (older)
      for(int s = 1; s <= m_scanBars; s++)
        {
         double body = MathAbs(rates[s].close - rates[s].open);
         double atrAtBar = atrBuf[s];
         if(atrAtBar <= 0)
            continue;
         if(body < m_impulseMultiplier * atrAtBar)
            continue;

         bool bullishImpulse = rates[s].close > rates[s].open;

         double baseHigh = rates[s+1].high;
         double baseLow  = rates[s+1].low;
         for(int b = s+2; b <= s+m_baseBars; b++)
           {
            if(rates[b].high > baseHigh) baseHigh = rates[b].high;
            if(rates[b].low  < baseLow)  baseLow  = rates[b].low;
           }

         SDZone z;
         z.time      = rates[s+1].time;
         z.top       = baseHigh;
         z.bottom    = baseLow;
         z.mid       = (baseHigh + baseLow) / 2.0;
         z.type      = bullishImpulse ? ZONE_DEMAND : ZONE_SUPPLY;
         z.mitigated = false;
         z.touchCount = 0;

         if(m_count == 0 || z.time > m_zones[m_count-1].time)
           {
            PushZone(z);
            foundNew = true;
           }
        }

      MitigationPass(rates[1].close);
      return foundNew;
     }

   bool GetNearestZone(const ENUM_XSS_BIAS dir, SDZone &out) const
     {
      ENUM_XSS_ZONE want = (dir == BIAS_BULLISH) ? ZONE_DEMAND : ZONE_SUPPLY;
      for(int i = m_count - 1; i >= 0; i--)
        {
         if(m_zones[i].mitigated)
            continue;
         if(m_zones[i].type == want)
           {
            out = m_zones[i];
            return true;
           }
        }
      return false;
     }

   int Count() const { return m_count; }

   void SetImpulseMultiplier(const double m) { m_impulseMultiplier = m; }

private:
   bool MitigationPass(const double lastClose)
     {
      bool any = false;
      for(int i = 0; i < m_count; i++)
        {
         if(m_zones[i].mitigated)
            continue;

         //--- touch counting: count a transition from outside -> inside the zone (v2.0) ---
         bool inside = (lastClose >= m_zones[i].bottom && lastClose <= m_zones[i].top);
         if(inside && !m_zoneWasInside[i])
            m_zones[i].touchCount++;
         m_zoneWasInside[i] = inside;

         if(m_zones[i].type == ZONE_DEMAND && lastClose < m_zones[i].bottom)
           {
            m_zones[i].mitigated = true;
            any = true;
           }
         else if(m_zones[i].type == ZONE_SUPPLY && lastClose > m_zones[i].top)
           {
            m_zones[i].mitigated = true;
            any = true;
           }
        }
      return any;
     }
  };

#endif // __XSS_SUPPLYDEMAND_MQH__
