//+------------------------------------------------------------------+
//|                                                  NewsFilter.mqh  |
//|  Blocks trading around high-impact USD news (CPI, NFP, FOMC,    |
//|  rate decisions, Core PCE). Uses the built-in MT5 economic       |
//|  calendar when available, with a CSV fallback                   |
//|  (Common\Files\XAU_SMC_SNIPER_AI\news_events.csv) since the      |
//|  calendar API is not reliably populated inside the Strategy      |
//|  Tester or on every broker/server.                                |
//|                                                                    |
//|  CSV format (one event per line):                                |
//|  YYYY.MM.DD HH:MI,USD,HIGH,Non-Farm Payrolls                     |
//+------------------------------------------------------------------+
#ifndef __XSS_NEWSFILTER_MQH__
#define __XSS_NEWSFILTER_MQH__

#include "Defines.mqh"

struct NewsEvent
  {
   datetime time;
   string   currency;
   string   impact;
   string   title;
  };

class CNewsFilter
  {
private:
   int        m_blockMinutesBefore;
   int        m_blockMinutesAfter;
   bool       m_useCalendarApi;
   string     m_csvFile;
   NewsEvent  m_events[];
   int        m_eventCount;
   datetime   m_lastCsvLoad;

   bool KeywordMatch(const string title) const
     {
      string t = title;
      StringToUpper(t);
      return (StringFind(t, "CPI") >= 0 || StringFind(t, "NON-FARM") >= 0 ||
              StringFind(t, "NONFARM") >= 0 || StringFind(t, "NFP") >= 0 ||
              StringFind(t, "FOMC") >= 0 || StringFind(t, "RATE DECISION") >= 0 ||
              StringFind(t, "INTEREST RATE") >= 0 || StringFind(t, "PCE") >= 0 ||
              StringFind(t, "FEDERAL FUNDS") >= 0 || StringFind(t, "NONFARM PAYROLLS") >= 0);
     }

   void LoadCsv()
     {
      ArrayResize(m_events, 0);
      m_eventCount = 0;

      int fh = FileOpen(m_csvFile, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(fh == INVALID_HANDLE)
         return;

      while(!FileIsEnding(fh))
        {
         string sTime  = FileReadString(fh);
         if(sTime == "")
            break;
         string sCcy   = FileReadString(fh);
         string sImp   = FileReadString(fh);
         string sTitle = FileReadString(fh);

         datetime t = StringToTime(sTime);
         if(t <= 0)
            continue;

         NewsEvent ev;
         ev.time     = t;
         ev.currency = sCcy;
         ev.impact   = sImp;
         ev.title    = sTitle;

         int n = ArraySize(m_events);
         ArrayResize(m_events, n + 1);
         m_events[n] = ev;
         m_eventCount++;
        }
      FileClose(fh);
     }

   bool CheckCalendarApi(const datetime nowBroker, const datetime fromT, const datetime toT) const
     {
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, fromT, toT, NULL, "USD"))
         return false;

      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         if(!KeywordMatch(ev.name))
            continue;

         datetime evTime = values[i].time;
         long diffMin = (long)MathAbs((double)(nowBroker - evTime)) / 60;
         if(nowBroker <= evTime && diffMin <= m_blockMinutesBefore)
            return true;
         if(nowBroker > evTime && diffMin <= m_blockMinutesAfter)
            return true;
        }
      return false;
     }

public:
                     CNewsFilter()
     {
      m_eventCount  = 0;
      m_lastCsvLoad = 0;
     }

   void Init(const int blockMinutesBefore = 30, const int blockMinutesAfter = 30,
             const bool useCalendarApi = true,
             const string csvFile = "XAU_SMC_SNIPER_AI\\news_events.csv")
     {
      m_blockMinutesBefore = blockMinutesBefore;
      m_blockMinutesAfter  = blockMinutesAfter;
      m_useCalendarApi     = useCalendarApi;
      m_csvFile            = csvFile;
      LoadCsv();
     }

   //--- reload CSV at most once every 15 minutes (it may be refreshed by the AI engine) ---
   void RefreshIfNeeded()
     {
      if(TimeCurrent() - m_lastCsvLoad >= 15 * 60)
        {
         LoadCsv();
         m_lastCsvLoad = TimeCurrent();
        }
     }

   bool IsBlackout(const datetime nowBroker)
     {
      RefreshIfNeeded();

      for(int i = 0; i < ArraySize(m_events); i++)
        {
         if(StringFind(m_events[i].currency, "USD") < 0)
            continue;
         string imp = m_events[i].impact;
         StringToUpper(imp);
         if(StringFind(imp, "HIGH") < 0)
            continue;

         long diffSec = (long)MathAbs((double)(nowBroker - m_events[i].time));
         long diffMin = diffSec / 60;
         if(nowBroker <= m_events[i].time && diffMin <= m_blockMinutesBefore)
            return true;
         if(nowBroker > m_events[i].time && diffMin <= m_blockMinutesAfter)
            return true;
        }

      if(m_useCalendarApi)
        {
         datetime fromT = nowBroker - (datetime)(m_blockMinutesAfter * 60 + 86400);
         datetime toT   = nowBroker + (datetime)(m_blockMinutesBefore * 60 + 86400);
         if(CheckCalendarApi(nowBroker, fromT, toT))
            return true;
        }

      return false;
     }
  };

#endif // __XSS_NEWSFILTER_MQH__
