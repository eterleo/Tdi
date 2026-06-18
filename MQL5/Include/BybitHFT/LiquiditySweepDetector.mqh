//+------------------------------------------------------------------+
//| LiquiditySweepDetector.mqh                                        |
//| Module 7/10 - Multi-timeframe liquidity sweep detector.           |
//| Finds swing-high/low zones on D1/H4, confirms a signal only when  |
//| price has swept and reclaimed one of those zones on M15, and      |
//| rejects the trade if M1 volume looks too thin to absorb size.     |
//| Wire-in point: call IsSweepConfirmed() as an additional filter    |
//| alongside your existing entry signal (TDI/RSI/EMA/AI).            |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_LIQUIDITYSWEEPDETECTOR_MQH__
#define __BYBITHFT_LIQUIDITYSWEEPDETECTOR_MQH__

class CLiquiditySweepDetector
{
private:
   string m_symbol;
   int    m_zone_lookback_bars; // bars scanned on D1/H4 to find swing extremes
   int    m_volume_lookback;    // M1 bars used for the volume-sufficiency check
   double m_min_volume_ratio;   // required M1 volume vs its own rolling average

   //--- Highest high / lowest low over the lookback on a given timeframe (the "zone").
   bool GetZone(const ENUM_TIMEFRAMES tf, double &zone_high, double &zone_low) const
   {
      int idx_high = iHighest(m_symbol, tf, MODE_HIGH, m_zone_lookback_bars, 1);
      int idx_low  = iLowest(m_symbol, tf, MODE_LOW, m_zone_lookback_bars, 1);
      if(idx_high < 0 || idx_low < 0) return false;
      zone_high = iHigh(m_symbol, tf, idx_high);
      zone_low  = iLow(m_symbol, tf, idx_low);
      return true;
   }

public:
   void Init(const string symbol, const int zone_lookback_bars = 20, const int volume_lookback = 20,
             const double min_volume_ratio = 0.7)
   {
      m_symbol = symbol;
      m_zone_lookback_bars = zone_lookback_bars;
      m_volume_lookback = volume_lookback;
      m_min_volume_ratio = min_volume_ratio;
   }

   //--- True once recent M1 volume looks adequate to absorb a position of this size
   //--- (proxy: current bar's tick volume vs its own rolling average isn't collapsing).
   bool HasSufficientM1Volume() const
   {
      long vols[];
      if(CopyTickVolume(m_symbol, PERIOD_M1, 0, m_volume_lookback, vols) < m_volume_lookback) return true;

      double sum = 0.0;
      for(int i = 1; i < m_volume_lookback; i++) sum += (double)vols[i]; // exclude the forming bar [0]
      double avg = sum / (m_volume_lookback - 1);
      if(avg <= 0.0) return true;

      return ((double)vols[0] / avg) >= m_min_volume_ratio;
   }

   //--- direction: +1 for a long setup (sweep of the lower zone, reclaim back above it),
   //--- -1 for a short setup (sweep of the upper zone, reclaim back below it).
   //--- Confirmation logic: D1/H4 zone defines the level; M15 must show a wick that
   //--- pierced the zone and a close back on the correct side (the "reclaim").
   bool IsSweepConfirmed(const int direction) const
   {
      double d1_high, d1_low, h4_high, h4_low;
      if(!GetZone(PERIOD_D1, d1_high, d1_low)) return false;
      if(!GetZone(PERIOD_H4, h4_high, h4_low)) return false;

      double zone_high = MathMax(d1_high, h4_high);
      double zone_low  = MathMin(d1_low, h4_low);

      double m15_open  = iOpen(m_symbol, PERIOD_M15, 1);
      double m15_high   = iHigh(m_symbol, PERIOD_M15, 1);
      double m15_low      = iLow(m_symbol, PERIOD_M15, 1);
      double m15_close      = iClose(m_symbol, PERIOD_M15, 1);

      bool swept_and_reclaimed;
      if(direction > 0)
         swept_and_reclaimed = (m15_low <= zone_low) && (m15_close > zone_low);
      else
         swept_and_reclaimed = (m15_high >= zone_high) && (m15_close < zone_high);

      if(!swept_and_reclaimed) return false;
      if(!HasSufficientM1Volume()) return false;

      return true;
   }
};

#endif // __BYBITHFT_LIQUIDITYSWEEPDETECTOR_MQH__
