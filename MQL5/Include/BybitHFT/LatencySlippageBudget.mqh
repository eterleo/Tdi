//+------------------------------------------------------------------+
//| LatencySlippageBudget.mqh                                         |
//| Module 10/10 - Broker-side latency and slippage budget.           |
//| Measures elapsed time between signal generation and order         |
//| placement, flags orders that blow the latency budget, and widens  |
//| the stop-loss distance by the latency-implied slippage so a slow  |
//| fill doesn't get stopped out by an adverse tick that arrived      |
//| during the round trip.                                            |
//| Wire-in point: call MarkSignal() the instant your signal fires,   |
//| then AdjustedSlPoints() right before building the trade request.  |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_LATENCYSLIPPAGEBUDGET_MQH__
#define __BYBITHFT_LATENCYSLIPPAGEBUDGET_MQH__

#include <BybitHFT\RollingSeries.mqh>

class CLatencySlippageBudget
{
private:
   ulong          m_signal_msc;
   int            m_max_latency_ms;
   double         m_points_per_ms_drift; // assumed adverse drift rate while in flight, in points/ms
   CRollingSeries m_latency_history_ms;

public:
   void Init(const int max_latency_ms = 50, const double points_per_ms_drift = 0.05, const int history_size = 200)
   {
      m_max_latency_ms = max_latency_ms;
      m_points_per_ms_drift = points_per_ms_drift;
      m_latency_history_ms.Init(history_size);
      m_signal_msc = 0;
   }

   //--- Call the instant the trade signal is generated (before any AI/REST calls or order building).
   void MarkSignal()
   {
      m_signal_msc = GetTickCount64();
   }

   //--- Call right before/at order submission. Returns elapsed ms and logs if it blew the budget.
   int ElapsedSinceSignalMs()
   {
      if(m_signal_msc == 0) return 0;
      int elapsed = (int)(GetTickCount64() - m_signal_msc);
      m_latency_history_ms.Push((double)elapsed);
      if(elapsed > m_max_latency_ms)
         PrintFormat("HFTAI: [LatencyBudget] signal-to-order latency %d ms exceeds budget of %d ms", elapsed, m_max_latency_ms);
      return elapsed;
   }

   double AverageLatencyMs() const { return m_latency_history_ms.Mean(); }

   //--- Widen the intended SL distance (in points) by the adverse drift implied by
   //--- the elapsed latency, so a slow fill isn't immediately stopped out.
   double AdjustedSlPoints(const double base_sl_points)
   {
      int elapsed = ElapsedSinceSignalMs();
      double widen = MathMax(0.0, (double)(elapsed - m_max_latency_ms)) * m_points_per_ms_drift;
      return base_sl_points + widen;
   }
};

#endif // __BYBITHFT_LATENCYSLIPPAGEBUDGET_MQH__
