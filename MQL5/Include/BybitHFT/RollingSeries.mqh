//+------------------------------------------------------------------+
//| RollingSeries.mqh                                                 |
//| Fixed-size circular buffer with running stats, shared by the      |
//| volatility, drawdown, correlation and latency modules so each     |
//| doesn't reimplement its own ring buffer.                          |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_ROLLINGSERIES_MQH__
#define __BYBITHFT_ROLLINGSERIES_MQH__

class CRollingSeries
{
private:
   double   m_buf[];
   int      m_capacity;
   int      m_count;
   int      m_head; // index where the next value will be written

public:
   void Init(const int capacity)
   {
      m_capacity = MathMax(capacity, 1);
      ArrayResize(m_buf, m_capacity);
      ArrayInitialize(m_buf, 0.0);
      m_count = 0;
      m_head  = 0;
   }

   void Push(const double value)
   {
      m_buf[m_head] = value;
      m_head = (m_head + 1) % m_capacity;
      if(m_count < m_capacity) m_count++;
   }

   int Count() const { return m_count; }
   bool IsFull() const { return m_count >= m_capacity; }

   //--- value at `back` steps before the most recently pushed value (0 = latest)
   double At(const int back) const
   {
      if(m_count == 0 || back < 0 || back >= m_count) return 0.0;
      int idx = (m_head - 1 - back);
      idx = ((idx % m_capacity) + m_capacity) % m_capacity;
      return m_buf[idx];
   }

   double Mean() const
   {
      if(m_count == 0) return 0.0;
      double sum = 0.0;
      for(int i = 0; i < m_count; i++) sum += At(i);
      return sum / m_count;
   }

   double StdDev() const
   {
      if(m_count < 2) return 0.0;
      double mean = Mean();
      double sum_sq = 0.0;
      for(int i = 0; i < m_count; i++)
      {
         double d = At(i) - mean;
         sum_sq += d * d;
      }
      return MathSqrt(sum_sq / (m_count - 1));
   }

   double Max() const
   {
      if(m_count == 0) return 0.0;
      double m = At(0);
      for(int i = 1; i < m_count; i++) m = MathMax(m, At(i));
      return m;
   }

   double Min() const
   {
      if(m_count == 0) return 0.0;
      double m = At(0);
      for(int i = 1; i < m_count; i++) m = MathMin(m, At(i));
      return m;
   }
};

//--- Pearson correlation between two equal-length rolling series.
double RollingCorrelation(const CRollingSeries &a, const CRollingSeries &b)
{
   int n = MathMin(a.Count(), b.Count());
   if(n < 2) return 0.0;

   double mean_a = a.Mean();
   double mean_b = b.Mean();
   double cov = 0.0, var_a = 0.0, var_b = 0.0;

   for(int i = 0; i < n; i++)
   {
      double da = a.At(i) - mean_a;
      double db = b.At(i) - mean_b;
      cov   += da * db;
      var_a += da * da;
      var_b += db * db;
   }

   double denom = MathSqrt(var_a * var_b);
   if(denom <= 0.0) return 0.0;
   return cov / denom;
}

#endif // __BYBITHFT_ROLLINGSERIES_MQH__
