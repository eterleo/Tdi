//+------------------------------------------------------------------+
//|                                                  TrendEngine.mqh |
//|  H1 directional bias: EMA20 vs EMA50 alignment confirmed by a    |
//|  H1 break-of-structure in the same direction.                    |
//+------------------------------------------------------------------+
#ifndef __XSS_TRENDENGINE_MQH__
#define __XSS_TRENDENGINE_MQH__

#include "Defines.mqh"
#include "MarketStructure.mqh"

class CTrendEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_emaFastHandle;
   int               m_emaSlowHandle;
   CMarketStructure  m_structure;
   ENUM_XSS_BIAS     m_bias;

public:
                     CTrendEngine()
     {
      m_emaFastHandle = INVALID_HANDLE;
      m_emaSlowHandle = INVALID_HANDLE;
      m_bias          = BIAS_NONE;
     }

   ~CTrendEngine()
     {
      if(m_emaFastHandle != INVALID_HANDLE) IndicatorRelease(m_emaFastHandle);
      if(m_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(m_emaSlowHandle);
     }

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf = PERIOD_H1,
             const int emaFast = 20, const int emaSlow = 50)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_emaFastHandle = iMA(symbol, tf, emaFast, 0, MODE_EMA, PRICE_CLOSE);
      m_emaSlowHandle = iMA(symbol, tf, emaSlow, 0, MODE_EMA, PRICE_CLOSE);
      m_structure.Init(symbol, tf, 2, 2, 300);
      return (m_emaFastHandle != INVALID_HANDLE && m_emaSlowHandle != INVALID_HANDLE);
     }

   void Update()
     {
      m_structure.Update();

      double fastBuf[], slowBuf[];
      ArraySetAsSeries(fastBuf, true);
      ArraySetAsSeries(slowBuf, true);
      if(CopyBuffer(m_emaFastHandle, 0, 0, 2, fastBuf) < 2) return;
      if(CopyBuffer(m_emaSlowHandle, 0, 0, 2, slowBuf) < 2) return;

      ENUM_XSS_BIAS emaBias = BIAS_NONE;
      if(fastBuf[1] > slowBuf[1]) emaBias = BIAS_BULLISH;
      else if(fastBuf[1] < slowBuf[1]) emaBias = BIAS_BEARISH;

      ENUM_XSS_BIAS structTrend = m_structure.Trend();

      if(emaBias == BIAS_BULLISH && structTrend == BIAS_BULLISH)
         m_bias = BIAS_BULLISH;
      else if(emaBias == BIAS_BEARISH && structTrend == BIAS_BEARISH)
         m_bias = BIAS_BEARISH;
      else
         m_bias = BIAS_NONE;
     }

   ENUM_XSS_BIAS Bias() const { return m_bias; }
   CMarketStructure *Structure() { return GetPointer(m_structure); }
  };

#endif // __XSS_TRENDENGINE_MQH__
