//+------------------------------------------------------------------+
//| SpreadSlippageAnalyzer.mqh                                        |
//| Module 1/10 - Real-time spread + slippage analyzer.               |
//| Tracks bid/ask spread and per-trade slippage (intended vs filled  |
//| price), and checks order-book depth before allowing entries.      |
//| Wire-in point: call IsEntryAllowed() before submitting an order,   |
//| and RecordFill() from OnTradeTransaction once a deal confirms.     |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_SPREADSLIPPAGEANALYZER_MQH__
#define __BYBITHFT_SPREADSLIPPAGEANALYZER_MQH__

#include <BybitHFT\RollingSeries.mqh>

class CSpreadSlippageAnalyzer
{
private:
   string         m_symbol;
   CRollingSeries m_spread_points;   // rolling spread history
   CRollingSeries m_slippage_points; // rolling per-trade slippage history
   double         m_max_spread_points;
   double         m_min_book_volume;

public:
   void Init(const string symbol, const int history_size, const double max_spread_points, const double min_book_volume)
   {
      m_symbol = symbol;
      m_spread_points.Init(history_size);
      m_slippage_points.Init(history_size);
      m_max_spread_points = max_spread_points;
      m_min_book_volume   = min_book_volume;
   }

   //--- Call every tick (or on a throttle) to keep the spread history fresh.
   void OnTickUpdate()
   {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0) return;
      m_spread_points.Push((ask - bid) / point);
   }

   double CurrentSpreadPoints() const
   {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0) return 0.0;
      return (ask - bid) / point;
   }

   double AverageSpreadPoints() const { return m_spread_points.Mean(); }
   double AverageSlippagePoints() const { return m_slippage_points.Mean(); }

   //--- Top-of-book depth check: sum of visible volume on each side must
   //--- clear m_min_book_volume, otherwise the market is too thin to absorb size.
   bool HasSufficientDepth() const
   {
      MqlBookInfo book[];
      if(!MarketBookGet(m_symbol, book)) return true; // book unavailable -> don't block on missing data
      double bid_vol = 0.0, ask_vol = 0.0;
      for(int i = 0; i < ArraySize(book); i++)
      {
         if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET)  bid_vol += (double)book[i].volume;
         if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET) ask_vol += (double)book[i].volume;
      }
      return (bid_vol >= m_min_book_volume) && (ask_vol >= m_min_book_volume);
   }

   //--- Pre-trade gate: reject entries on excessive spread or thin liquidity.
   bool IsEntryAllowed() const
   {
      if(CurrentSpreadPoints() > m_max_spread_points) return false;
      if(!HasSufficientDepth()) return false;
      return true;
   }

   //--- Call from OnTradeTransaction (DEAL_ADD) once the actual fill price is known.
   void RecordFill(const int direction, const double intended_price, const double filled_price)
   {
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0.0) return;
      double slip_points = (direction > 0)
                            ? (filled_price - intended_price) / point   // buy: positive = paid more
                            : (intended_price - filled_price) / point;  // sell: positive = received less
      m_slippage_points.Push(slip_points);
      if(slip_points > m_max_spread_points)
         PrintFormat("HFTAI: [SpreadSlippageAnalyzer] high slippage on %s: %.1f points", m_symbol, slip_points);
   }
};

#endif // __BYBITHFT_SPREADSLIPPAGEANALYZER_MQH__
