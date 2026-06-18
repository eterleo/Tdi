//+------------------------------------------------------------------+
//| CorrelationWeightedSizer.mqh                                      |
//| Module 9/10 - Correlation-weighted position sizer.                |
//| Combines per-symbol volatility-based sizing (module 2) with the   |
//| cross-pair correlation filter (module 4): a new entry's size is   |
//| scaled down further the more correlated it is to currently open   |
//| positions, and the full pairwise matrix can be logged for later   |
//| portfolio optimization analysis.                                  |
//| Wire-in point: call ComputeLots() instead of calling               |
//| CVolatilitySizing::ComputeLots() directly when other positions     |
//| are open.                                                          |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_CORRELATIONWEIGHTEDSIZER_MQH__
#define __BYBITHFT_CORRELATIONWEIGHTEDSIZER_MQH__

#include <BybitHFT\CorrelationFilter.mqh>
#include <BybitHFT\VolatilitySizing.mqh>

typedef void (*CorrelationMatrixLogFunc)(const string symbol_a, const string symbol_b, const double correlation);

class CCorrelationWeightedSizer
{
private:
   CCorrelationFilter       *m_corr_filter; // not owned
   CorrelationMatrixLogFunc  m_log_func;

public:
   void Init(CCorrelationFilter *corr_filter, CorrelationMatrixLogFunc log_func = NULL)
   {
      m_corr_filter = corr_filter;
      m_log_func = log_func;
   }

   //--- base_lots: output of CVolatilitySizing::ComputeLots() for `symbol`.
   //--- open_symbols/open_count: symbols with currently open positions (exclude `symbol` itself).
   double ComputeLots(const string symbol, const double base_lots, const string &open_symbols[], const int open_count) const
   {
      if(m_corr_filter == NULL || open_count == 0) return base_lots;
      double scale = m_corr_filter.GetExposureScale(symbol, open_symbols, open_count);
      return base_lots * scale;
   }

   //--- Dump the full pairwise correlation matrix for the tracked symbols via the
   //--- logging callback, e.g. on a timer, for storage in TradeLogger.mqh's PostgreSQL sink.
   void LogMatrix(const string &symbols[], const int symbol_count) const
   {
      if(m_corr_filter == NULL || m_log_func == NULL) return;
      for(int i = 0; i < symbol_count; i++)
         for(int j = i + 1; j < symbol_count; j++)
         {
            double c = m_corr_filter.Correlation(symbols[i], symbols[j]);
            m_log_func(symbols[i], symbols[j], c);
         }
   }
};

#endif // __BYBITHFT_CORRELATIONWEIGHTEDSIZER_MQH__
