//+------------------------------------------------------------------+
//| VolatilitySizing.mqh                                              |
//| Module 2/10 - Volatility-adaptive position sizing.                |
//| Reads current ATR vs its own rolling average and scales lot size  |
//| down in high volatility, up in low volatility, around a fixed     |
//| risk-percent target. Wire-in point: call ComputeLots() at signal  |
//| time instead of a static lot size.                                |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_VOLATILITYSIZING_MQH__
#define __BYBITHFT_VOLATILITYSIZING_MQH__

#include <BybitHFT\RollingSeries.mqh>

class CVolatilitySizing
{
private:
   string         m_symbol;
   int            m_atr_handle;
   CRollingSeries m_atr_history; // rolling average of ATR itself (volatility-of-volatility baseline)
   double         m_min_scale;
   double         m_max_scale;

public:
   bool Init(const string symbol, const ENUM_TIMEFRAMES timeframe, const int atr_period,
             const int rolling_lookback, const double min_scale = 0.25, const double max_scale = 2.0)
   {
      m_symbol = symbol;
      m_atr_handle = iATR(symbol, timeframe, atr_period);
      m_atr_history.Init(rolling_lookback);
      m_min_scale = min_scale;
      m_max_scale = max_scale;
      return (m_atr_handle != INVALID_HANDLE);
   }

   void Deinit()
   {
      if(m_atr_handle != INVALID_HANDLE) IndicatorRelease(m_atr_handle);
   }

   //--- Call once per bar (or per tick, it's cheap) to keep the ATR baseline fresh.
   double UpdateAndGetAtr()
   {
      double buf[];
      if(CopyBuffer(m_atr_handle, 0, 0, 1, buf) != 1) return 0.0;
      m_atr_history.Push(buf[0]);
      return buf[0];
   }

   //--- Ratio of current ATR to its own rolling average: >1 = more volatile than usual.
   double VolatilityRatio() const
   {
      double avg = m_atr_history.Mean();
      if(avg <= 0.0 || m_atr_history.Count() == 0) return 1.0;
      return m_atr_history.At(0) / avg;
   }

   //--- Inverse scaling: lots shrink as volatility ratio rises above 1, grow as it falls below 1.
   double SizeScaleFactor() const
   {
      double ratio = VolatilityRatio();
      if(ratio <= 0.0) return 1.0;
      double scale = 1.0 / ratio;
      return MathMax(m_min_scale, MathMin(m_max_scale, scale));
   }

   //--- Risk-percent based lot size, adjusted by the volatility scale factor and
   //--- normalized to the symbol's volume step/min/max.
   double ComputeLots(const double risk_percent, const double sl_points) const
   {
      double point      = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double tick_value = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double vol_min    = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double vol_max    = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double vol_step   = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

      if(sl_points <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0) return vol_min;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double risk_money = equity * (risk_percent / 100.0) * SizeScaleFactor();
      double loss_per_lot = sl_points * point / tick_size * tick_value;
      if(loss_per_lot <= 0.0) return vol_min;

      double lots = risk_money / loss_per_lot;
      lots = MathFloor(lots / vol_step) * vol_step;
      lots = MathMax(vol_min, MathMin(vol_max, lots));
      return lots;
   }
};

#endif // __BYBITHFT_VOLATILITYSIZING_MQH__
