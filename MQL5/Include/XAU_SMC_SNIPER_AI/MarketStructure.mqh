//+------------------------------------------------------------------+
//|                                              MarketStructure.mqh |
//|  Swing-point fractal detection + BOS / CHOCH state machine.      |
//|  One instance is bound to a single symbol+timeframe.             |
//+------------------------------------------------------------------+
#ifndef __XSS_MARKETSTRUCTURE_MQH__
#define __XSS_MARKETSTRUCTURE_MQH__

#include "Defines.mqh"

#define XSS_MAX_EVENT_LOG 64
#define XSS_MAX_SWING_LOG 64

class CMarketStructure
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_leftBars;
   int               m_rightBars;
   int               m_copyCount;

   SwingPoint        m_swingHighs[];
   SwingPoint        m_swingLows[];
   int               m_swingHighCount;
   int               m_swingLowCount;

   ENUM_XSS_STRUCT_EVENT m_eventLog[];
   datetime              m_eventTimeLog[];
   double                 m_eventStrengthLog[];  // |breaking close - broken swing level|, in price units (v2.0)
   int                    m_eventCount;

   ENUM_XSS_BIAS     m_trend;          // internal structural trend
   datetime          m_lastProcessedBarTime;

   void PushEvent(const ENUM_XSS_STRUCT_EVENT ev, const datetime t, const double strength = 0.0)
     {
      if(m_eventCount < XSS_MAX_EVENT_LOG)
        {
         m_eventLog[m_eventCount] = ev;
         m_eventTimeLog[m_eventCount] = t;
         m_eventStrengthLog[m_eventCount] = strength;
         m_eventCount++;
        }
      else
        {
         for(int i = 1; i < XSS_MAX_EVENT_LOG; i++)
           {
            m_eventLog[i-1] = m_eventLog[i];
            m_eventTimeLog[i-1] = m_eventTimeLog[i];
            m_eventStrengthLog[i-1] = m_eventStrengthLog[i];
           }
         m_eventLog[XSS_MAX_EVENT_LOG-1] = ev;
         m_eventTimeLog[XSS_MAX_EVENT_LOG-1] = t;
         m_eventStrengthLog[XSS_MAX_EVENT_LOG-1] = strength;
        }
     }

   void PushSwingHigh(const SwingPoint &sp)
     {
      if(m_swingHighCount < XSS_MAX_SWING_LOG)
        {
         m_swingHighs[m_swingHighCount] = sp;
         m_swingHighCount++;
        }
      else
        {
         for(int i = 1; i < XSS_MAX_SWING_LOG; i++)
            m_swingHighs[i-1] = m_swingHighs[i];
         m_swingHighs[XSS_MAX_SWING_LOG-1] = sp;
        }
     }

   void PushSwingLow(const SwingPoint &sp)
     {
      if(m_swingLowCount < XSS_MAX_SWING_LOG)
        {
         m_swingLows[m_swingLowCount] = sp;
         m_swingLowCount++;
        }
      else
        {
         for(int i = 1; i < XSS_MAX_SWING_LOG; i++)
            m_swingLows[i-1] = m_swingLows[i];
         m_swingLows[XSS_MAX_SWING_LOG-1] = sp;
        }
     }

public:
                     CMarketStructure()
     {
      m_swingHighCount = 0;
      m_swingLowCount  = 0;
      m_eventCount     = 0;
      m_trend          = BIAS_NONE;
      m_lastProcessedBarTime = 0;
      ArrayResize(m_swingHighs, XSS_MAX_SWING_LOG);
      ArrayResize(m_swingLows,  XSS_MAX_SWING_LOG);
      ArrayResize(m_eventLog,     XSS_MAX_EVENT_LOG);
      ArrayResize(m_eventTimeLog, XSS_MAX_EVENT_LOG);
      ArrayResize(m_eventStrengthLog, XSS_MAX_EVENT_LOG);
     }

   void Init(const string symbol, const ENUM_TIMEFRAMES tf, const int leftBars = 2,
             const int rightBars = 2, const int copyCount = 300)
     {
      m_symbol    = symbol;
      m_tf        = tf;
      m_leftBars  = leftBars;
      m_rightBars = rightBars;
      m_copyCount = copyCount;
     }

   ENUM_XSS_BIAS Trend() const { return m_trend; }

   bool HasSwingHigh() const { return m_swingHighCount > 0; }
   bool HasSwingLow()  const { return m_swingLowCount  > 0; }

   SwingPoint LastSwingHigh() const { return m_swingHighs[m_swingHighCount-1]; }
   SwingPoint LastSwingLow()  const { return m_swingLows[m_swingLowCount-1]; }

   //--- main update, call once per bar (after a new bar opens / closes) ---
   bool Update()
     {
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(m_symbol, m_tf, 0, m_copyCount, rates);
      if(copied < (m_leftBars + m_rightBars + 5))
         return false;

      datetime newestClosedBarTime = rates[1].time; // index 0 is the still-forming bar
      if(newestClosedBarTime == m_lastProcessedBarTime)
         return false; // nothing new to process
      m_lastProcessedBarTime = newestClosedBarTime;

      //--- scan for confirmed fractal swing points (skip the forming bar at shift 0) ---
      int scanStart = m_rightBars + 1;
      int scanEnd   = copied - m_leftBars - 1;
      bool newEvent = false;

      for(int s = scanEnd; s >= scanStart; s--)
        {
         // already-known swing? skip if older than/equal to last recorded swing of that type
         bool isHigh = true;
         bool isLow  = true;
         for(int k = 1; k <= m_rightBars; k++)
           {
            if(rates[s].high <= rates[s-k].high) isHigh = false;
            if(rates[s].low  >= rates[s-k].low)  isLow  = false;
           }
         for(int k = 1; k <= m_leftBars; k++)
           {
            if(rates[s].high <= rates[s+k].high) isHigh = false;
            if(rates[s].low  >= rates[s+k].low)  isLow  = false;
           }

         if(isHigh)
           {
            if(m_swingHighCount == 0 || rates[s].time > m_swingHighs[m_swingHighCount-1].time)
              {
               SwingPoint sp;
               sp.time  = rates[s].time;
               sp.price = rates[s].high;
               sp.isHigh = true;
               sp.shift = s;
               PushSwingHigh(sp);
              }
           }
         if(isLow)
           {
            if(m_swingLowCount == 0 || rates[s].time > m_swingLows[m_swingLowCount-1].time)
              {
               SwingPoint sp;
               sp.time  = rates[s].time;
               sp.price = rates[s].low;
               sp.isHigh = false;
               sp.shift = s;
               PushSwingLow(sp);
              }
           }
        }

      //--- BOS / CHOCH evaluation against the latest confirmed close ---
      double lastClose = rates[1].close;
      datetime lastTime = rates[1].time;

      if(m_swingHighCount > 0 && lastClose > m_swingHighs[m_swingHighCount-1].price)
        {
         ENUM_XSS_STRUCT_EVENT ev = (m_trend == BIAS_BEARISH || m_trend == BIAS_NONE) ? STRUCT_CHOCH_BULL : STRUCT_BOS_BULL;
         PushEvent(ev, lastTime, MathAbs(lastClose - m_swingHighs[m_swingHighCount-1].price));
         m_trend = BIAS_BULLISH;
         newEvent = true;
        }
      else if(m_swingLowCount > 0 && lastClose < m_swingLows[m_swingLowCount-1].price)
        {
         ENUM_XSS_STRUCT_EVENT ev = (m_trend == BIAS_BULLISH || m_trend == BIAS_NONE) ? STRUCT_CHOCH_BEAR : STRUCT_BOS_BEAR;
         PushEvent(ev, lastTime, MathAbs(lastClose - m_swingLows[m_swingLowCount-1].price));
         m_trend = BIAS_BEARISH;
         newEvent = true;
        }

      return newEvent;
     }

   //--- |breaking close - broken swing level| of the most recent BOS/CHOCH, in price units (v2.0) ---
   double LastEventStrength() const
     {
      if(m_eventCount == 0)
         return 0.0;
      return m_eventStrengthLog[m_eventCount-1];
     }

   //--- timestamps of the two most recent BOS events (either direction), for "time between BOS" (v2.0) ---
   bool LastTwoBosEvents(datetime &recent, datetime &prior) const
     {
      int found = 0;
      recent = 0; prior = 0;
      for(int i = m_eventCount - 1; i >= 0 && found < 2; i--)
        {
         if(m_eventLog[i] == STRUCT_BOS_BULL || m_eventLog[i] == STRUCT_BOS_BEAR)
           {
            if(found == 0) recent = m_eventTimeLog[i];
            else            prior  = m_eventTimeLog[i];
            found++;
           }
        }
      return found >= 2;
     }

   //--- count of confirmed swing points (highs+lows) within the last N bars - a liquidity-density proxy (v2.0) ---
   int CountSwingsWithinBars(const int bars) const
     {
      datetime cutoff = TimeCurrent() - (datetime)((long)bars * PeriodSeconds(m_tf));
      int count = 0;
      for(int i = 0; i < m_swingHighCount; i++)
         if(m_swingHighs[i].time >= cutoff)
            count++;
      for(int i = 0; i < m_swingLowCount; i++)
         if(m_swingLows[i].time >= cutoff)
            count++;
      return count;
     }

   ENUM_XSS_STRUCT_EVENT LastEventOfTypes(const ENUM_XSS_STRUCT_EVENT typeA, const ENUM_XSS_STRUCT_EVENT typeB) const
     {
      for(int i = m_eventCount - 1; i >= 0; i--)
         if(m_eventLog[i] == typeA || m_eventLog[i] == typeB)
            return m_eventLog[i];
      return STRUCT_NONE;
     }

   ENUM_XSS_STRUCT_EVENT LastChochEvent() const { return LastEventOfTypes(STRUCT_CHOCH_BULL, STRUCT_CHOCH_BEAR); }
   ENUM_XSS_STRUCT_EVENT LastBosEvent()   const { return LastEventOfTypes(STRUCT_BOS_BULL,   STRUCT_BOS_BEAR);   }

   ENUM_XSS_STRUCT_EVENT LastEvent() const
     {
      if(m_eventCount == 0)
         return STRUCT_NONE;
      return m_eventLog[m_eventCount-1];
     }

   datetime LastEventTime() const
     {
      if(m_eventCount == 0)
         return 0;
      return m_eventTimeLog[m_eventCount-1];
     }

   //--- looks for: CHOCH(dir) followed later by BOS(dir), with no opposing
   //--- CHOCH in between, and the BOS occurring within maxBarsBetween bars.
   bool GetChochThenBos(const ENUM_XSS_BIAS dir, const int maxBarsBetween,
                        datetime &chochTime, datetime &bosTime) const
     {
      if(m_eventCount < 2)
         return false;

      ENUM_XSS_STRUCT_EVENT wantChoch = (dir == BIAS_BULLISH) ? STRUCT_CHOCH_BULL : STRUCT_CHOCH_BEAR;
      ENUM_XSS_STRUCT_EVENT wantBos   = (dir == BIAS_BULLISH) ? STRUCT_BOS_BULL   : STRUCT_BOS_BEAR;
      ENUM_XSS_STRUCT_EVENT oppChoch  = (dir == BIAS_BULLISH) ? STRUCT_CHOCH_BEAR : STRUCT_CHOCH_BULL;

      int bosIdx = -1;
      for(int i = m_eventCount - 1; i >= 0; i--)
        {
         if(m_eventLog[i] == wantBos) { bosIdx = i; break; }
         if(m_eventLog[i] == oppChoch) return false; // structure invalidated before any BOS found
        }
      if(bosIdx < 0)
         return false;

      int chochIdx = -1;
      for(int i = bosIdx - 1; i >= 0; i--)
        {
         if(m_eventLog[i] == wantChoch) { chochIdx = i; break; }
         if(m_eventLog[i] == oppChoch) return false;
        }
      if(chochIdx < 0)
         return false;

      chochTime = m_eventTimeLog[chochIdx];
      bosTime   = m_eventTimeLog[bosIdx];

      long barsBetween = (long)((bosTime - chochTime) / PeriodSeconds(m_tf));
      if(barsBetween > maxBarsBetween)
         return false;

      return true;
     }
  };

#endif // __XSS_MARKETSTRUCTURE_MQH__
