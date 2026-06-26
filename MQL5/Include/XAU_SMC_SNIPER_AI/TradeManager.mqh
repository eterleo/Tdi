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
#include "ExecutionOptimizer.mqh"

#define XSS_MAX_TRACKED_POS 100
#define XSS_MAX_EXEC_LOG 200
#define XSS_MAX_PENDING_ORDERS 50

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
   double        mfeR;          // max favorable excursion seen so far, R multiples (v2.0)
   double        maeR;          // max adverse excursion seen so far, R multiples (v2.0)
  };

//--- limit order awaiting fill, tracked only to compute slippage/latency once filled (v2.0) ---
struct PendingOrderInfo
  {
   ulong    orderTicket;
   datetime orderTime;
   double   requestedPrice;
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

   ExecutionQuality      m_execLog[];
   int                   m_execLogCount;
   PendingOrderInfo      m_pendingOrders[];
   int                   m_pendingOrderCount;
   CExecutionOptimizer  *m_optimizer;

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

   int FindPendingOrder(const ulong orderTicket) const
     {
      for(int i = 0; i < m_pendingOrderCount; i++)
         if(m_pendingOrders[i].orderTicket == orderTicket)
            return i;
      return -1;
     }

   void RemovePendingOrder(const int idx)
     {
      for(int i = idx; i < m_pendingOrderCount - 1; i++)
         m_pendingOrders[i] = m_pendingOrders[i+1];
      m_pendingOrderCount--;
     }

   void PushExecLog(const ExecutionQuality &eq)
     {
      if(m_execLogCount < XSS_MAX_EXEC_LOG)
        {
         m_execLog[m_execLogCount] = eq;
         m_execLogCount++;
        }
      else
        {
         for(int i = 1; i < XSS_MAX_EXEC_LOG; i++)
            m_execLog[i-1] = m_execLog[i];
         m_execLog[XSS_MAX_EXEC_LOG-1] = eq;
        }
      if(m_optimizer != NULL)
         m_optimizer.Record(eq);
     }

public:
                     CTradeManager()
     {
      m_trackedCount      = 0;
      m_telegram          = NULL;
      m_execLogCount      = 0;
      m_pendingOrderCount = 0;
      m_optimizer         = NULL;
      ArrayResize(m_tracked, XSS_MAX_TRACKED_POS);
      ArrayResize(m_execLog, XSS_MAX_EXEC_LOG);
      ArrayResize(m_pendingOrders, XSS_MAX_PENDING_ORDERS);
     }

   void Init(const string symbol, const ulong magic, CTelegram *telegram = NULL, const int slippagePoints = 30,
             CExecutionOptimizer *optimizer = NULL)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_telegram = telegram;
      m_optimizer = optimizer;
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
         uint retcode = m_trade.ResultRetcode();
         PrintFormat("[TradeManager] limit order failed: retcode=%d desc=%s", retcode, m_trade.ResultRetcodeDescription());

         //--- track requotes as an execution-quality signal (v2.0) ---
         if(retcode == TRADE_RETCODE_REQUOTE || retcode == TRADE_RETCODE_PRICE_CHANGED)
           {
            ExecutionQuality eq;
            eq.ticket = 0;
            eq.orderTime = TimeCurrent();
            eq.fillTime = 0;
            eq.requestedPrice = entryPrice;
            eq.filledPrice = 0.0;
            eq.slippagePoints = 0.0;
            eq.latencyMs = 0.0;
            eq.requoted = true;
            eq.missedFill = false;
            PushExecLog(eq);
           }
         return 0;
        }

      ulong orderTicket = m_trade.ResultOrder();

      //--- remember the request so a later fill/expiry can be measured (v2.0) ---
      if(m_pendingOrderCount < XSS_MAX_PENDING_ORDERS)
        {
         PendingOrderInfo info;
         info.orderTicket    = orderTicket;
         info.orderTime      = TimeCurrent();
         info.requestedPrice = entryPrice;
         m_pendingOrders[m_pendingOrderCount] = info;
         m_pendingOrderCount++;
        }

      return orderTicket;
     }

   void RegisterFilledPosition(const ulong positionTicket, const double openPrice, const double sl,
                               const ENUM_XSS_BIAS dir, const double lots, const ulong orderTicket = 0)
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
      mp.mfeR        = 0.0;
      mp.maeR        = 0.0;
      m_tracked[m_trackedCount] = mp;
      m_trackedCount++;

      //--- execution-quality sample: slippage/latency between the limit request and the fill (v2.0) ---
      int pidx = FindPendingOrder(orderTicket);
      if(orderTicket != 0 && pidx >= 0)
        {
         ExecutionQuality eq;
         eq.ticket         = positionTicket;
         eq.orderTime      = m_pendingOrders[pidx].orderTime;
         eq.fillTime       = TimeCurrent();
         eq.requestedPrice = m_pendingOrders[pidx].requestedPrice;
         eq.filledPrice    = openPrice;
         double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         eq.slippagePoints = (point > 0.0) ? MathAbs(openPrice - eq.requestedPrice) / point : 0.0;
         eq.latencyMs      = (double)(eq.fillTime - eq.orderTime) * 1000.0;
         eq.requoted       = false;
         eq.missedFill     = false;
         PushExecLog(eq);
         RemovePendingOrder(pidx);
        }
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

         //--- track max favorable / adverse excursion in R multiples (v2.0) ---
         if(rMultiple > m_tracked[i].mfeR) m_tracked[i].mfeR = rMultiple;
         if(rMultiple < m_tracked[i].maeR) m_tracked[i].maeR = rMultiple;

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

   //--- max favorable / adverse excursion observed so far for a still-tracked position, in R multiples (v2.0) ---
   bool GetMfeMae(const ulong ticket, double &mfeR, double &maeR) const
     {
      int idx = FindTracked(ticket);
      if(idx < 0)
         return false;
      mfeR = m_tracked[idx].mfeR;
      maeR = m_tracked[idx].maeR;
      return true;
     }

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
           {
            double requestedPrice = OrderGetDouble(ORDER_PRICE_OPEN);
            datetime orderTime    = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
            m_trade.OrderDelete(ticket);

            //--- a limit order that expired unfilled is a "missed fill" execution-quality signal (v2.0) ---
            ExecutionQuality eq;
            eq.ticket         = ticket;
            eq.orderTime      = orderTime;
            eq.fillTime       = 0;
            eq.requestedPrice = requestedPrice;
            eq.filledPrice    = 0.0;
            eq.slippagePoints = 0.0;
            eq.latencyMs      = 0.0;
            eq.requoted       = false;
            eq.missedFill     = true;
            PushExecLog(eq);

            int pidx = FindPendingOrder(ticket);
            if(pidx >= 0)
               RemovePendingOrder(pidx);
           }
        }
     }

   int ExecutionQualityCount() const { return m_execLogCount; }

   bool GetExecutionQuality(const int idx, ExecutionQuality &out) const
     {
      if(idx < 0 || idx >= m_execLogCount)
         return false;
      out = m_execLog[idx];
      return true;
     }

   CTrade *Trade() { return GetPointer(m_trade); }
  };

#endif // __XSS_TRADEMANAGER_MQH__
