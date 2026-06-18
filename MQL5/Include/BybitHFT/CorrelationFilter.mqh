//+------------------------------------------------------------------+
//| CorrelationFilter.mqh                                             |
//| Module 4/10 - Cross-pair correlation filter.                      |
//| Maintains rolling close-price series for a fixed set of symbols   |
//| and computes pairwise Pearson correlation so exposure on highly   |
//| correlated pairs can be cut to avoid synchronized blowups.        |
//| Wire-in point: call Update() once per bar for each tracked        |
//| symbol, then GetExposureScale() before sizing a new entry.        |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_CORRELATIONFILTER_MQH__
#define __BYBITHFT_CORRELATIONFILTER_MQH__

#include <BybitHFT\RollingSeries.mqh>

#define BYBITHFT_MAX_SYMBOLS 16

class CCorrelationFilter
{
private:
   string         m_symbols[BYBITHFT_MAX_SYMBOLS];
   CRollingSeries m_series[BYBITHFT_MAX_SYMBOLS];
   int            m_symbol_count;
   double         m_high_corr_threshold; // e.g. 0.75

   int FindIndex(const string symbol) const
   {
      for(int i = 0; i < m_symbol_count; i++)
         if(m_symbols[i] == symbol) return i;
      return -1;
   }

public:
   void Init(const double high_corr_threshold)
   {
      m_symbol_count = 0;
      m_high_corr_threshold = high_corr_threshold;
   }

   bool AddSymbol(const string symbol, const int lookback)
   {
      if(m_symbol_count >= BYBITHFT_MAX_SYMBOLS) return false;
      if(FindIndex(symbol) >= 0) return true;
      m_symbols[m_symbol_count] = symbol;
      m_series[m_symbol_count].Init(lookback);
      m_symbol_count++;
      return true;
   }

   //--- Call once per bar close for `symbol` with its latest close price.
   void Update(const string symbol, const double close_price)
   {
      int idx = FindIndex(symbol);
      if(idx < 0) return;
      m_series[idx].Push(close_price);
   }

   double Correlation(const string symbol_a, const string symbol_b) const
   {
      int ia = FindIndex(symbol_a);
      int ib = FindIndex(symbol_b);
      if(ia < 0 || ib < 0) return 0.0;
      return RollingCorrelation(m_series[ia], m_series[ib]);
   }

   //--- Highest absolute correlation between `symbol` and any other symbol
   //--- that currently has an open position (per open_symbols[]/open_count).
   double MaxCorrelationToOpenPositions(const string symbol, const string &open_symbols[], const int open_count) const
   {
      double max_abs_corr = 0.0;
      for(int i = 0; i < open_count; i++)
      {
         if(open_symbols[i] == symbol) continue;
         double c = MathAbs(Correlation(symbol, open_symbols[i]));
         if(c > max_abs_corr) max_abs_corr = c;
      }
      return max_abs_corr;
   }

   //--- 1.0 = no reduction, scales down to ~0.2 as correlation approaches 1.0
   //--- once it crosses the high-correlation threshold; 1.0 below the threshold.
   double GetExposureScale(const string symbol, const string &open_symbols[], const int open_count) const
   {
      double corr = MaxCorrelationToOpenPositions(symbol, open_symbols, open_count);
      if(corr < m_high_corr_threshold) return 1.0;
      double over = (corr - m_high_corr_threshold) / (1.0 - m_high_corr_threshold);
      return MathMax(0.2, 1.0 - 0.8 * over);
   }
};

#endif // __BYBITHFT_CORRELATIONFILTER_MQH__
