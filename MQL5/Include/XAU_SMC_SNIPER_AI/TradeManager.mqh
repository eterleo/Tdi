//+------------------------------------------------------------------+
//|                                                  TradeManager.mqh|
//|  Limit-order execution + trade lifecycle management:             |
//|  break-even at 1R, partial close (50%) at 2R, final target at    |
//|  3R-5R. No market chasing - entries are limit orders only.       |
//+------------------------------------------------------------------+
#ifndef __XSS_TRADEMANAGER_MQH__
#define __XSS_TRADEMANAGER_MQH__

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include "Defines.mqh"
#include "Telegram.mqh"

#define XSS_MAX_TRACKED_POS 100

struct ManagedPosition
  {
   ulong         ticket;
   double        openPrice;
   double        initialSL;
   double        rDistance;     // price distance representing 1R
   bool          beDone;
   bool          partialDone;
   ENUM_XSS_BIAS dir;
   double        initialLots;
  };

class CTradeManager
  {
private:
   CTrade           m_trade;
   string           m_symbol;
   ulong            m_magic;
   ManagedPosition  m_tracked[];
   int              m_trackedCount;
   CTelegram       *m_telegram;

   int FindTracked(const ulong ticket) const
     {
      for(int i = 0; i < m_trackedCount; i++)
         if(m_tracked[i].ticket == ticket)
            return i;
      return -1;
     }

   void RemoveTracked(const int idx)
     {
      for(int i = idx; i < m_trackedCount - 1; i++)
         m_tracked[i] = m_tracked[i+1];
      m_trackedCount--;
     }

public:
                     CTradeManager()
     {
      m_trackedCount = 0;
      m_telegram = NULL;
      ArrayResize(m_tracked, XSS_MAX_TRACKED_POS);
     }

   void Init(const string symbol, const ulong magic, CTelegram *telegram = NULL, const int slippagePoints = 30)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_telegram = telegram;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(slippagePoints);

      long fillingMask = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      if((fillingMask & SYMBOL_FILLING_FOK) != 0)
         m_trade.SetTypeFilling(ORDER_FILLING_FOK);
      else if((fillingMask & SYMBOL_FILLING_IOC) != 0)
         m_trade.SetTypeFilling(ORDER_FILLING_IOC);
      else
         m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
     }

   //--- places a pending limit order, returns the order ticket (0 on failure) ---
   ulong PlaceLimitOrder(const ENUM_XSS_BIAS dir, const double entryPrice, const double sl,
                         const double tp, const double lots, const datetime expiration, const string comment = "")
     {
      if(lots <= 0)
         return 0;

      bool ok;
      if(dir == BIAS_BULLISH)
         ok = m_trade.BuyLimit(lots, entryPrice, m_symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comment);
      else if(dir == BIAS_BEARISH)
         ok = m_trade.SellLimit(lots, entryPrice, m_symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, comment);
      else
         return 0;

      if(!ok)
        {
         PrintFormat("[TradeManager] limit order failed: retcode=%d desc=%s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         return 0;
        }
      return m_trade.ResultOrder();
     }

   void RegisterFilledPosition(const ulong positionTicket, const double openPrice, const double sl,
                               const ENUM_XSS_BIAS dir, const double lots)
     {
      if(m_trackedCount >= XSS_MAX_TRACKED_POS)
         return;
      ManagedPosition mp;
      mp.ticket      = positionTicket;
      mp.openPrice   = openPrice;
      mp.initialSL   = sl;
      mp.rDistance   = MathAbs(openPrice - sl);
      mp.beDone      = false;
      mp.partialDone = false;
      mp.dir         = dir;
      mp.initialLots = lots;
      m_tracked[m_trackedCount] = mp;
      m_trackedCount++;
     }

   //--- call every tick: applies break-even at 1R and partial close at 2R ---
   void ManageOpenPositions()
     {
      for(int i = m_trackedCount - 1; i >= 0; i--)
        {
         ulong ticket = m_tracked[i].ticket;
         if(!PositionSelectByTicket(ticket))
           {
            RemoveTracked(i);
            continue;
           }

         double currentPrice = (m_tracked[i].dir == BIAS_BULLISH)
                                  ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                                  : SymbolInfoDouble(m_symbol, SYMBOL_ASK);

         if(m_tracked[i].rDistance <= 0)
            continue;

         double rMultiple = (m_tracked[i].dir == BIAS_BULLISH)
                              ? (currentPrice - m_tracked[i].openPrice) / m_tracked[i].rDistance
                              : (m_tracked[i].openPrice - currentPrice) / m_tracked[i].rDistance;

         //--- break-even at 1R ---
         if(!m_tracked[i].beDone && rMultiple >= 1.0)
           {
            double currentTP = PositionGetDouble(POSITION_TP);
            if(m_trade.PositionModify(ticket, m_tracked[i].openPrice, currentTP))
              {
               m_tracked[i].beDone = true;
               if(m_telegram != NULL)
                  m_telegram.SendBreakEven(ticket, m_tracked[i].openPrice);
              }
           }

         //--- partial close 50% at 2R ---
         if(!m_tracked[i].partialDone && rMultiple >= 2.0)
           {
            double volume = PositionGetDouble(POSITION_VOLUME);
            double volStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
            double volMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
            double closeVol = volume * 0.5;
            if(volStep > 0)
               closeVol = MathFloor(closeVol / volStep) * volStep;

            if(closeVol >= volMin && (volume - closeVol) >= volMin)
              {
               double profitBefore = PositionGetDouble(POSITION_PROFIT);
               if(m_trade.PositionClosePartial(ticket, closeVol))
                 {
                  m_tracked[i].partialDone = true;
                  if(m_telegram != NULL)
                     m_telegram.SendPartialClose(ticket, closeVol, volume - closeVol, profitBefore);
                 }
              }
            else
              {
               // can't split further under broker volume step - mark done to avoid retry spam
               m_tracked[i].partialDone = true;
              }
           }
        }
     }

   void Untrack(const ulong ticket)
     {
      int idx = FindTracked(ticket);
      if(idx >= 0)
         RemoveTracked(idx);
     }

   bool IsTracked(const ulong ticket) const { return FindTracked(ticket) >= 0; }

   //--- removes pending limit orders that were never filled within their validity window ---
   void CancelStaleOrders(const datetime now)
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;
         if(OrderGetString(ORDER_SYMBOL) != m_symbol)
            continue;
         if(OrderGetInteger(ORDER_MAGIC) != (long)m_magic)
            continue;

         datetime expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         if(expiration > 0 && now >= expiration)
            m_trade.OrderDelete(ticket);
        }
     }

   CTrade *Trade() { return GetPointer(m_trade); }
  };

#endif // __XSS_TRADEMANAGER_MQH__
