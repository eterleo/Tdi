//+------------------------------------------------------------------+
//|                                                 FeatureEngine.mqh |
//|  Assembles the engineered FeatureSnapshot (v2.0) from the        |
//|  existing SMC modules' accessors. Purely additive: reads state   |
//|  already exposed by CLiquidity / CMarketStructure / CTrendEngine |
//|  / CSessionFilter / FVGZone / SDZone, never mutates them.        |
//+------------------------------------------------------------------+
#ifndef __XSS_FEATUREENGINE_MQH__
#define __XSS_FEATUREENGINE_MQH__

#include "Defines.mqh"
#include "JsonLite.mqh"
#include "Liquidity.mqh"
#include "MarketStructure.mqh"
#include "TrendEngine.mqh"
#include "SessionFilter.mqh"

class CFeatureEngine
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_atrHandle;

public:
                     CFeatureEngine() { m_atrHandle = INVALID_HANDLE; }

                    ~CFeatureEngine()
     {
      if(m_atrHandle != INVALID_HANDLE)
         IndicatorRelease(m_atrHandle);
     }

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf, const int atrPeriod = 14)
     {
      m_symbol    = symbol;
      m_tf        = tf;
      m_atrHandle = iATR(symbol, tf, atrPeriod);
      return (m_atrHandle != INVALID_HANDLE);
     }

   //--- builds a FeatureSnapshot for the setup currently being scored/traded ---
   FeatureSnapshot Compute(const ENUM_XSS_BIAS dir,
                            const CLiquidity &liquidity,
                            CMarketStructure &entryStructure,
                            CMarketStructure &htfStructure,
                            const CTrendEngine &trend,
                            const CSessionFilter &session,
                            const FVGZone &fvg, const bool fvgValid,
                            const SDZone &zone, const bool zoneValid)
     {
      FeatureSnapshot f;
      f.timeSinceLastSweepMin    = 0.0;
      f.distanceToHtfLiquidity   = 0.0;
      f.fvgSizeUsd               = 0.0;
      f.fvgFillPct               = 0.0;
      f.zoneAgeBars              = 0;
      f.zoneTouchCount           = 0;
      f.bosStrength              = 0.0;
      f.chochStrength            = 0.0;
      f.trendSlope               = 0.0;
      f.bodyWickRatio            = 0.0;
      f.relativeAtr              = 1.0;
      f.sessionProgressionPct    = 0.0;
      f.tickVolume               = 0.0;
      f.swingDistanceUsd         = 0.0;
      f.liquidityDensity         = 0.0;
      f.timeBetweenBosEventsMin  = -1.0;

      //--- time since last liquidity sweep ---
      datetime sweepTime = liquidity.SweepTime();
      if(sweepTime > 0)
         f.timeSinceLastSweepMin = (double)(TimeCurrent() - sweepTime) / 60.0;

      //--- distance to the nearest opposing HTF liquidity pool ---
      double price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(dir == BIAS_BULLISH && htfStructure.HasSwingHigh())
         f.distanceToHtfLiquidity = MathAbs(price - htfStructure.LastSwingHigh().price);
      else if(dir == BIAS_BEARISH && htfStructure.HasSwingLow())
         f.distanceToHtfLiquidity = MathAbs(price - htfStructure.LastSwingLow().price);

      //--- FVG size / fill ---
      if(fvgValid)
        {
         f.fvgSizeUsd = fvg.top - fvg.bottom;
         f.fvgFillPct = fvg.filledPct;
        }

      //--- supply/demand zone age (in bars of m_tf) and touch count ---
      if(zoneValid)
        {
         f.zoneAgeBars    = (int)((TimeCurrent() - zone.time) / PeriodSeconds(m_tf));
         f.zoneTouchCount = zone.touchCount;
        }

      //--- BOS/CHOCH strength of the most recent structural event ---
      ENUM_XSS_STRUCT_EVENT lastEv = entryStructure.LastEvent();
      double lastStrength = entryStructure.LastEventStrength();
      if(lastEv == STRUCT_BOS_BULL || lastEv == STRUCT_BOS_BEAR)
         f.bosStrength = lastStrength;
      else if(lastEv == STRUCT_CHOCH_BULL || lastEv == STRUCT_CHOCH_BEAR)
         f.chochStrength = lastStrength;

      //--- trend slope (H1 fast EMA) ---
      f.trendSlope = trend.Slope();

      //--- body/wick ratio + tick volume, from the most recent closed bar ---
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(m_symbol, m_tf, 0, 2, rates) >= 2)
        {
         double body  = MathAbs(rates[1].close - rates[1].open);
         double range = rates[1].high - rates[1].low;
         double wick  = range - body;
         f.bodyWickRatio = (wick > 0.0) ? body / wick : (body > 0.0 ? 100.0 : 0.0);
         f.tickVolume    = (double)rates[1].tick_volume;
        }

      //--- relative ATR: current ATR vs its own 20-bar average ---
      if(m_atrHandle != INVALID_HANDLE)
        {
         double atrBuf[];
         ArraySetAsSeries(atrBuf, true);
         int lookback = 20;
         if(CopyBuffer(m_atrHandle, 0, 1, lookback, atrBuf) >= lookback)
           {
            double sum = 0.0;
            for(int i = 0; i < lookback; i++)
               sum += atrBuf[i];
            double avg = sum / lookback;
            if(avg > 0.0)
               f.relativeAtr = atrBuf[0] / avg;
           }
        }

      //--- session progression ---
      f.sessionProgressionPct = session.SessionProgressionPct();

      //--- swing distance: span between the most recent confirmed high and low ---
      if(entryStructure.HasSwingHigh() && entryStructure.HasSwingLow())
         f.swingDistanceUsd = MathAbs(entryStructure.LastSwingHigh().price - entryStructure.LastSwingLow().price);

      //--- liquidity density: confirmed swing count in the recent window ---
      f.liquidityDensity = (double)entryStructure.CountSwingsWithinBars(50);

      //--- time between the two most recent BOS events ---
      datetime recentBos, priorBos;
      if(entryStructure.LastTwoBosEvents(recentBos, priorBos) && recentBos > 0 && priorBos > 0)
         f.timeBetweenBosEventsMin = (double)(recentBos - priorBos) / 60.0;

      return f;
     }

   //--- flat JSON serialization for persistence in TradeRecord.featuresJson / rejected-setup logs ---
   static string ToJson(const FeatureSnapshot &f)
     {
      CJsonWriter w;
      w.Num("time_since_last_sweep_min",   f.timeSinceLastSweepMin);
      w.Num("distance_to_htf_liquidity",   f.distanceToHtfLiquidity);
      w.Num("fvg_size_usd",                f.fvgSizeUsd);
      w.Num("fvg_fill_pct",                f.fvgFillPct);
      w.Int("zone_age_bars",               f.zoneAgeBars);
      w.Int("zone_touch_count",            f.zoneTouchCount);
      w.Num("bos_strength",                f.bosStrength);
      w.Num("choch_strength",              f.chochStrength);
      w.Num("trend_slope",                 f.trendSlope);
      w.Num("body_wick_ratio",             f.bodyWickRatio);
      w.Num("relative_atr",                f.relativeAtr);
      w.Num("session_progression_pct",     f.sessionProgressionPct);
      w.Num("tick_volume",                 f.tickVolume);
      w.Num("swing_distance_usd",          f.swingDistanceUsd);
      w.Num("liquidity_density",           f.liquidityDensity);
      w.Num("time_between_bos_events_min", f.timeBetweenBosEventsMin);
      w.Close();
      return w.ToString();
     }
  };

#endif // __XSS_FEATUREENGINE_MQH__
