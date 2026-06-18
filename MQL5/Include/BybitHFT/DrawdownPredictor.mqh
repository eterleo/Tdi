//+------------------------------------------------------------------+
//| DrawdownPredictor.mqh                                             |
//| Module 3/10 - Equity curve drawdown predictor.                    |
//| Tracks running peak equity and the day's starting equity, derives |
//| live drawdown %, and flags when it approaches the daily loss      |
//| limit so the caller can pause trading or cut size pre-emptively.  |
//| Wire-in point: call Update() every tick/bar, check ShouldPause()  |
//| before allowing new entries.                                      |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_DRAWDOWNPREDICTOR_MQH__
#define __BYBITHFT_DRAWDOWNPREDICTOR_MQH__

class CDrawdownPredictor
{
private:
   double   m_daily_loss_limit_percent; // e.g. 6.0 = stop at -6% day equity
   double   m_warn_ratio;               // e.g. 0.8 = warn at 80% of the limit
   double   m_day_start_equity;
   double   m_peak_equity;
   datetime m_day_anchor;

   bool IsNewTradingDay() const
   {
      MqlDateTime now, anchor;
      TimeToStruct(TimeCurrent(), now);
      TimeToStruct(m_day_anchor, anchor);
      return (now.day != anchor.day || now.mon != anchor.mon || now.year != anchor.year);
   }

public:
   void Init(const double daily_loss_limit_percent, const double warn_ratio = 0.8)
   {
      m_daily_loss_limit_percent = daily_loss_limit_percent;
      m_warn_ratio = warn_ratio;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      m_day_start_equity = eq;
      m_peak_equity = eq;
      m_day_anchor = TimeCurrent();
   }

   //--- Call every tick; resets the daily anchor automatically at day rollover.
   void Update()
   {
      if(IsNewTradingDay())
      {
         m_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_peak_equity = m_day_start_equity;
         m_day_anchor = TimeCurrent();
      }
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > m_peak_equity) m_peak_equity = eq;
   }

   //--- Drawdown from the session/day peak, in percent (0 = at/above peak).
   double DrawdownFromPeakPercent() const
   {
      if(m_peak_equity <= 0.0) return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return MathMax(0.0, (m_peak_equity - eq) / m_peak_equity * 100.0);
   }

   //--- Loss from the day's starting equity, in percent (what the daily limit measures against).
   double DailyLossPercent() const
   {
      if(m_day_start_equity <= 0.0) return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return MathMax(0.0, (m_day_start_equity - eq) / m_day_start_equity * 100.0);
   }

   bool IsAtWarnThreshold() const
   {
      return DailyLossPercent() >= (m_daily_loss_limit_percent * m_warn_ratio);
   }

   bool ShouldHaltTrading() const
   {
      return DailyLossPercent() >= m_daily_loss_limit_percent;
   }

   //--- Suggested size multiplier as the daily loss approaches the limit:
   //--- 1.0 below the warn threshold, linearly down to 0.0 at the hard limit.
   double SizeMultiplier() const
   {
      double loss = DailyLossPercent();
      double warn_at = m_daily_loss_limit_percent * m_warn_ratio;
      if(loss <= warn_at) return 1.0;
      if(loss >= m_daily_loss_limit_percent) return 0.0;
      return 1.0 - (loss - warn_at) / (m_daily_loss_limit_percent - warn_at);
   }
};

#endif // __BYBITHFT_DRAWDOWNPREDICTOR_MQH__
