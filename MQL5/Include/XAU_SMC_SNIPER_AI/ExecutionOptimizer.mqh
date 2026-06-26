//+------------------------------------------------------------------+
//|                                            ExecutionOptimizer.mqh |
//|  Aggregates ExecutionQuality samples (slippage, fill latency,    |
//|  requotes, missed fills) pushed by CTradeManager into running    |
//|  statistics used for execution-timing analysis / dashboard.      |
//+------------------------------------------------------------------+
#ifndef __XSS_EXECUTIONOPTIMIZER_MQH__
#define __XSS_EXECUTIONOPTIMIZER_MQH__

#include "Defines.mqh"

#define XSS_MAX_EXEC_SAMPLES 1000

class CExecutionOptimizer
  {
private:
   ExecutionQuality m_samples[];
   int              m_count;
   int              m_capacity;

   void Push(const ExecutionQuality &eq)
     {
      if(m_count < m_capacity)
        {
         m_samples[m_count] = eq;
         m_count++;
        }
      else
        {
         for(int i = 1; i < m_capacity; i++)
            m_samples[i-1] = m_samples[i];
         m_samples[m_capacity-1] = eq;
        }
     }

public:
                     CExecutionOptimizer()
     {
      m_count    = 0;
      m_capacity = XSS_MAX_EXEC_SAMPLES;
      ArrayResize(m_samples, m_capacity);
     }

   void Init(const int capacity = XSS_MAX_EXEC_SAMPLES)
     {
      m_capacity = capacity;
      m_count    = 0;
      ArrayResize(m_samples, m_capacity);
     }

   //--- called by CTradeManager whenever a new execution-quality sample is produced ---
   void Record(const ExecutionQuality &eq) { Push(eq); }

   int Count() const { return m_count; }

   double AvgSlippagePoints() const
     {
      double sum = 0.0;
      int    n   = 0;
      for(int i = 0; i < m_count; i++)
        {
         if(m_samples[i].missedFill || m_samples[i].requoted)
            continue;
         sum += m_samples[i].slippagePoints;
         n++;
        }
      return (n > 0) ? sum / n : 0.0;
     }

   double AvgLatencyMs() const
     {
      double sum = 0.0;
      int    n   = 0;
      for(int i = 0; i < m_count; i++)
        {
         if(m_samples[i].missedFill || m_samples[i].requoted)
            continue;
         sum += m_samples[i].latencyMs;
         n++;
        }
      return (n > 0) ? sum / n : 0.0;
     }

   double RequoteRatePct() const
     {
      if(m_count == 0)
         return 0.0;
      int n = 0;
      for(int i = 0; i < m_count; i++)
         if(m_samples[i].requoted)
            n++;
      return 100.0 * n / m_count;
     }

   double MissedFillRatePct() const
     {
      if(m_count == 0)
         return 0.0;
      int n = 0;
      for(int i = 0; i < m_count; i++)
         if(m_samples[i].missedFill)
            n++;
      return 100.0 * n / m_count;
     }

   string Summary() const
     {
      return StringFormat("fills/attempts=%d avgSlippage=%.1fpts avgLatency=%.0fms requoteRate=%.1f%% missedFillRate=%.1f%%",
                           m_count, AvgSlippagePoints(), AvgLatencyMs(), RequoteRatePct(), MissedFillRatePct());
     }
  };

#endif // __XSS_EXECUTIONOPTIMIZER_MQH__
