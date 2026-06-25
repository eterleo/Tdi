//+------------------------------------------------------------------+
//|                                                  MarketRegime.mqh |
//|  Classifies the current market into one of the v2.0 regime tags  |
//|  (ENUM_XSS_REGIME) from relative ATR, H1 trend slope, BOS         |
//|  frequency and news proximity. This is a separate, additional    |
//|  classification - it does NOT replace CStatistics::ClassifyRegime|
//|  which remains unchanged and continues to tag TradeRecord.regime.|
//+------------------------------------------------------------------+
#ifndef __XSS_MARKETREGIME_MQH__
#define __XSS_MARKETREGIME_MQH__

#include "Defines.mqh"
#include "MarketStructure.mqh"
#include "NewsFilter.mqh"

class CMarketRegime
  {
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_atrHandle;
   ENUM_XSS_REGIME m_current;

   double RelativeAtr() const
     {
      if(m_atrHandle == INVALID_HANDLE)
         return 1.0;
      double buf[];
      ArraySetAsSeries(buf, true);
      int lookback = 20;
      if(CopyBuffer(m_atrHandle, 0, 1, lookback, buf) < lookback)
         return 1.0;
      double sum = 0.0;
      for(int i = 0; i < lookback; i++)
         sum += buf[i];
      double avg = sum / lookback;
      return (avg > 0.0) ? buf[0] / avg : 1.0;
     }

public:
                     CMarketRegime()
     {
      m_atrHandle = INVALID_HANDLE;
      m_current   = REGIME_UNKNOWN;
     }

                    ~CMarketRegime()
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

   //--- classify current regime; trendSlope/pointSize come from CTrendEngine::Slope() and _Point ---
   ENUM_XSS_REGIME Classify(const double trendSlope, const double pointSize,
                             CMarketStructure &structure, CNewsFilter &newsFilter,
                             const datetime nowBroker)
     {
      if(newsFilter.IsBlackout(nowBroker))
        {
         m_current = REGIME_NEWS_DRIVEN;
         return m_current;
        }

      double relAtr = RelativeAtr();

      if(relAtr >= 1.6)
        {
         m_current = REGIME_HIGH_VOLATILITY;
         return m_current;
        }
      if(relAtr <= 0.6)
        {
         m_current = REGIME_LOW_VOLATILITY;
         return m_current;
        }

      datetime recentBos, priorBos;
      bool hasTwoBos = structure.LastTwoBosEvents(recentBos, priorBos);
      double minsBetweenBos = (hasTwoBos && recentBos > 0 && priorBos > 0)
                               ? (double)(recentBos - priorBos) / 60.0 : -1.0;

      if(relAtr >= 1.25 && minsBetweenBos >= 0.0 && minsBetweenBos < 60.0)
        {
         m_current = REGIME_EXPANSION;
         return m_current;
        }
      if(relAtr <= 0.85 && (minsBetweenBos < 0.0 || minsBetweenBos > 240.0))
        {
         m_current = REGIME_COMPRESSION;
         return m_current;
        }

      double slopeAbsPts = MathAbs(trendSlope) / (pointSize > 0.0 ? pointSize : 1.0);
      if(slopeAbsPts >= 3.0)
        {
         m_current = REGIME_STRONG_TREND;
         return m_current;
        }
      if(slopeAbsPts >= 1.0)
        {
         m_current = REGIME_WEAK_TREND;
         return m_current;
        }

      m_current = REGIME_RANGE;
      return m_current;
     }

   ENUM_XSS_REGIME Current() const { return m_current; }

   static string ToString(const ENUM_XSS_REGIME r)
     {
      switch(r)
        {
         case REGIME_STRONG_TREND:     return "strong_trend";
         case REGIME_WEAK_TREND:       return "weak_trend";
         case REGIME_RANGE:            return "range";
         case REGIME_EXPANSION:        return "expansion";
         case REGIME_COMPRESSION:      return "compression";
         case REGIME_HIGH_VOLATILITY:  return "high_volatility";
         case REGIME_LOW_VOLATILITY:   return "low_volatility";
         case REGIME_NEWS_DRIVEN:      return "news_driven";
         default:                      return "unknown";
        }
     }
  };

#endif // __XSS_MARKETREGIME_MQH__
