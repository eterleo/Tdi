//+------------------------------------------------------------------+
//|                                                    Telegram.mqh  |
//|  Real-time Telegram alerts for entries, SL/TP changes, break-    |
//|  even moves, partial closes, trade closures and performance      |
//|  reports.                                                         |
//|                                                                    |
//|  Requires: Tools > Options > Expert Advisors > "Allow WebRequest |
//|  for listed URL" with https://api.telegram.org added.            |
//+------------------------------------------------------------------+
#ifndef __XSS_TELEGRAM_MQH__
#define __XSS_TELEGRAM_MQH__

#include "Defines.mqh"

class CTelegram
  {
private:
   string m_botToken;
   string m_chatId;
   bool   m_enabled;

   string UrlEncode(const string text) const
     {
      string result = "";
      int len = StringLen(text);
      for(int i = 0; i < len; i++)
        {
         ushort c = StringGetCharacter(text, i);
         if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~')
            result += ShortToString(c);
         else if(c == ' ')
            result += "+";
         else if(c == '\n')
            result += "%0A";
         else
            result += StringFormat("%%%02X", c);
        }
      return result;
     }

public:
   void Init(const string botToken, const string chatId, const bool enabled)
     {
      m_botToken = botToken;
      m_chatId   = chatId;
      m_enabled  = enabled;
     }

   bool Send(const string text)
     {
      if(!m_enabled || m_botToken == "" || m_chatId == "")
         return false;

      string url  = "https://api.telegram.org/bot" + m_botToken + "/sendMessage";
      string body = "chat_id=" + UrlEncode(m_chatId) + "&parse_mode=HTML&text=" + UrlEncode(text);

      char postData[];
      StringToCharArray(body, postData, 0, StringLen(body));

      char result[];
      string resultHeaders;
      string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

      ResetLastError();
      int code = WebRequest("POST", url, headers, 5000, postData, result, resultHeaders);
      if(code == -1)
        {
         PrintFormat("[Telegram] WebRequest failed, error=%d. Add api.telegram.org to allowed URLs.", GetLastError());
         return false;
        }
      return (code == 200);
     }

   bool SendEntrySignal(const string symbol, const string direction, const double entry,
                        const double sl, const double tp, const double lots, const int score)
     {
      string msg = StringFormat("🎯 <b>ENTRY SIGNAL</b>\n%s %s\nEntry: %.2f\nSL: %.2f\nTP: %.2f\nLots: %.2f\nConfluence: %d/100",
                                 symbol, direction, entry, sl, tp, lots, score);
      return Send(msg);
     }

   bool SendSLTPUpdate(const ulong ticket, const double sl, const double tp)
     {
      string msg = StringFormat("🔧 <b>SL/TP UPDATED</b>\nTicket: %I64u\nSL: %.2f\nTP: %.2f", ticket, sl, tp);
      return Send(msg);
     }

   bool SendBreakEven(const ulong ticket, const double price)
     {
      string msg = StringFormat("⚖️ <b>BREAK-EVEN</b>\nTicket: %I64u\nMoved to: %.2f", ticket, price);
      return Send(msg);
     }

   bool SendPartialClose(const ulong ticket, const double closedLots, const double remainingLots, const double profit)
     {
      string msg = StringFormat("✂️ <b>PARTIAL CLOSE (2R)</b>\nTicket: %I64u\nClosed: %.2f lots\nRemaining: %.2f lots\nProfit: %.2f",
                                 ticket, closedLots, remainingLots, profit);
      return Send(msg);
     }

   bool SendTradeClosed(const ulong ticket, const double profit, const double rr, const bool win)
     {
      string msg = StringFormat("%s <b>TRADE CLOSED</b>\nTicket: %I64u\nResult: %s\nProfit: %.2f\nRR: %.2f",
                                 (win ? "✅" : "❌"), ticket, (win ? "WIN" : "LOSS"), profit, rr);
      return Send(msg);
     }

   bool SendDailyReport(const int trades, const int wins, const int losses,
                        const double profit, const double winRatePct)
     {
      string msg = StringFormat("📊 <b>DAILY REPORT</b>\nTrades: %d | Wins: %d | Losses: %d\nWin rate: %.1f%%\nNet P/L: %.2f",
                                 trades, wins, losses, winRatePct, profit);
      return Send(msg);
     }

   bool SendWeeklyReport(const int trades, const int wins, const int losses,
                        const double profit, const double winRatePct)
     {
      string msg = StringFormat("📈 <b>WEEKLY REPORT</b>\nTrades: %d | Wins: %d | Losses: %d\nWin rate: %.1f%%\nNet P/L: %.2f",
                                 trades, wins, losses, winRatePct, profit);
      return Send(msg);
     }

   bool SendEvolutionNotice(const string text)
     {
      return Send("🧬 <b>STRATEGY EVOLUTION</b>\n" + text);
     }
  };

#endif // __XSS_TELEGRAM_MQH__
