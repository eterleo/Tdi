//+------------------------------------------------------------------+
//| SlippageAwareExecution.mqh                                        |
//| Module 6/10 - Slippage-aware order execution.                     |
//| Picks market vs limit execution based on recent spread/volatility,|
//| computes an acceptable deviation from spread history, and records |
//| intended-vs-filled price so SpreadSlippageAnalyzer's slippage     |
//| history stays current. Async-only (OrderSendAsync), matching the  |
//| HFT EA's non-blocking execution path.                              |
//| Wire-in point: call Execute() instead of building a raw            |
//| MqlTradeRequest by hand in your signal-handling code.              |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_SLIPPAGEAWAREEXECUTION_MQH__
#define __BYBITHFT_SLIPPAGEAWAREEXECUTION_MQH__

#include <BybitHFT\SpreadSlippageAnalyzer.mqh>

class CSlippageAwareExecution
{
private:
   string                     m_symbol;
   long                       m_magic;
   double                     m_high_vol_ratio_threshold; // above this, prefer limit orders
   CSpreadSlippageAnalyzer   *m_analyzer; // not owned; just read for deviation sizing

public:
   void Init(const string symbol, const long magic, CSpreadSlippageAnalyzer *analyzer,
             const double high_vol_ratio_threshold = 1.5)
   {
      m_symbol = symbol;
      m_magic = magic;
      m_analyzer = analyzer;
      m_high_vol_ratio_threshold = high_vol_ratio_threshold;
   }

   //--- Deviation budget derived from recent spread, with a floor so it's never zero on a quiet market.
   int ComputeDeviationPoints() const
   {
      double avg_spread = (m_analyzer != NULL) ? m_analyzer.AverageSpreadPoints() : 0.0;
      double avg_slip   = (m_analyzer != NULL) ? m_analyzer.AverageSlippagePoints() : 0.0;
      return (int)MathMax(10.0, avg_spread * 1.5 + MathMax(0.0, avg_slip));
   }

   //--- direction: +1 buy, -1 sell. volatility_ratio: from CVolatilitySizing::VolatilityRatio().
   //--- use_limit_in_high_vol: if true and volatility_ratio exceeds the threshold, places a
   //--- resting limit order slightly inside the spread instead of crossing the spread with a market order.
   bool Execute(const int direction, const double lots, const double sl_price, const double tp_price,
                const double volatility_ratio, const bool use_limit_in_high_vol = true)
   {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick)) return false;

      MqlTradeRequest request;
      MqlTradeResult  result;
      MqlTradeCheckResult check;
      ZeroMemory(request);
      ZeroMemory(result);
      ZeroMemory(check);

      bool prefer_limit = use_limit_in_high_vol && (volatility_ratio >= m_high_vol_ratio_threshold);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);

      if(prefer_limit)
      {
         // Rest slightly inside the current spread instead of paying the full market cross.
         double offset = point * MathMax(1.0, ComputeDeviationPoints() * 0.25);
         request.action = TRADE_ACTION_PENDING;
         request.type    = (direction > 0) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
         request.price     = (direction > 0) ? (tick.ask - offset) : (tick.bid + offset);
         request.type_time   = ORDER_TIME_GTC;
      }
      else
      {
         request.action = TRADE_ACTION_DEAL;
         request.type    = (direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         request.price     = (direction > 0) ? tick.ask : tick.bid;
         request.type_filling = ORDER_FILLING_FOK;
         request.deviation     = ComputeDeviationPoints();
      }

      request.symbol = m_symbol;
      request.volume  = lots;
      request.sl       = sl_price;
      request.tp        = tp_price;
      request.magic       = m_magic;
      request.comment       = "HFTAI-slip-aware";

      if(!OrderCheck(request, check))
      {
         PrintFormat("HFTAI: [SlippageAwareExecution] OrderCheck rejected (retcode=%d, %s)", check.retcode, check.comment);
         return false;
      }
      if(!OrderSendAsync(request, result))
      {
         PrintFormat("HFTAI: [SlippageAwareExecution] OrderSendAsync failed (retcode=%d, %s)", result.retcode, result.comment);
         return false;
      }

      if(m_analyzer != NULL && request.action == TRADE_ACTION_DEAL)
         m_analyzer.RecordFill(direction, request.price, request.price); // refined with the real fill in OnTradeTransaction

      return true;
   }
};

#endif // __BYBITHFT_SLIPPAGEAWAREEXECUTION_MQH__
