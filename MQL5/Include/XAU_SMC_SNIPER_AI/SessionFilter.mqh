//+------------------------------------------------------------------+
//|                                                SessionFilter.mqh |
//|  Restricts trading to the London / New York windows expressed   |
//|  in Qatar local time (GMT+3, no DST).                            |
//|                                                                    |
//|  NOTE: MQL5 has no reliable built-in way to know the broker's    |
//|  server GMT offset (it varies by broker and DST policy), so it   |
//|  is supplied as an EA input (BrokerGMTOffsetHours) which the     |
//|  user must set once for their broker.                            |
//+------------------------------------------------------------------+
#ifndef __XSS_SESSIONFILTER_MQH__
#define __XSS_SESSIONFILTER_MQH__

#include "Defines.mqh"

class CSessionFilter
  {
private:
   int m_brokerGmtOffsetHours;  // broker server time minus GMT, in hours
   int m_londonStartHour;
   int m_londonEndHour;
   int m_nyStartHour;
   int m_nyEndHour;

public:
   void Init(const int brokerGmtOffsetHours,
             const int londonStartHour = 13, const int londonEndHour = 16,
             const int nyStartHour = 18, const int nyEndHour = 22)
     {
      m_brokerGmtOffsetHours = brokerGmtOffsetHours;
      m_londonStartHour = londonStartHour;
      m_londonEndHour   = londonEndHour;
      m_nyStartHour     = nyStartHour;
      m_nyEndHour       = nyEndHour;
     }

   datetime BrokerTimeToQatarTime(const datetime brokerTime) const
     {
      long gmt = (long)brokerTime - (long)m_brokerGmtOffsetHours * 3600;
      long qatar = gmt + 3 * 3600; // Qatar is fixed GMT+3, no DST
      return (datetime)qatar;
     }

   int QatarHourNow() const
     {
      datetime qt = BrokerTimeToQatarTime(TimeCurrent());
      MqlDateTime dt;
      TimeToStruct(qt, dt);
      return dt.hour;
     }

   ENUM_XSS_SESSION CurrentSession() const
     {
      int h = QatarHourNow();
      if(h >= m_londonStartHour && h < m_londonEndHour)
         return SESSION_LONDON;
      if(h >= m_nyStartHour && h < m_nyEndHour)
         return SESSION_NEWYORK;
      return SESSION_NONE;
     }

   bool IsSessionValid() const
     {
      return CurrentSession() != SESSION_NONE;
     }

   //--- 0-100, how far through the active session we are; 0 if no session is active (v2.0) ---
   double SessionProgressionPct() const
     {
      datetime qt = BrokerTimeToQatarTime(TimeCurrent());
      MqlDateTime dt;
      TimeToStruct(qt, dt);
      double minuteOfDay = dt.hour * 60.0 + dt.min;

      ENUM_XSS_SESSION sess = CurrentSession();
      double startH, endH;
      if(sess == SESSION_LONDON)      { startH = m_londonStartHour; endH = m_londonEndHour; }
      else if(sess == SESSION_NEWYORK) { startH = m_nyStartHour;     endH = m_nyEndHour;     }
      else                             return 0.0;

      double span = (endH - startH) * 60.0;
      if(span <= 0)
         return 0.0;
      double elapsed = minuteOfDay - startH * 60.0;
      return MathMax(0.0, MathMin(100.0, 100.0 * elapsed / span));
     }
  };

#endif // __XSS_SESSIONFILTER_MQH__
