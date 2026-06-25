//+------------------------------------------------------------------+
//|                                                  MarketMemory.mqh|
//|  Persists every trade and market snapshot to the MT5 "Common"    |
//|  files folder so the external, locally-hosted AI evolution       |
//|  engine (running outside the sandboxed MQL5 file system) can     |
//|  read the same files directly from disk.                         |
//|                                                                    |
//|  Files written under Common\Files\XAU_SMC_SNIPER_AI\:            |
//|    trades.csv             - one row per closed trade              |
//|    market_states.json     - JSON-Lines, one snapshot per signal   |
//|    performance.csv        - daily/weekly aggregate rows           |
//|    strategy_history.json  - JSON-Lines, one entry per version     |
//+------------------------------------------------------------------+
#ifndef __XSS_MARKETMEMORY_MQH__
#define __XSS_MARKETMEMORY_MQH__

#include "Defines.mqh"
#include "JsonLite.mqh"

string XSS_SessionToStr(const ENUM_XSS_SESSION s)
  {
   switch(s)
     {
      case SESSION_LONDON:  return "LONDON";
      case SESSION_NEWYORK: return "NEWYORK";
      default:              return "NONE";
     }
  }

string XSS_SweepToStr(const ENUM_XSS_SWEEP s)
  {
   switch(s)
     {
      case SWEEP_SELL_SIDE: return "SELL_SIDE";
      case SWEEP_BUY_SIDE:  return "BUY_SIDE";
      default:              return "NONE";
     }
  }

string XSS_ZoneToStr(const ENUM_XSS_ZONE z)
  {
   switch(z)
     {
      case ZONE_DEMAND: return "DEMAND";
      case ZONE_SUPPLY: return "SUPPLY";
      default:          return "NONE";
     }
  }

string XSS_BiasToStr(const ENUM_XSS_BIAS b)
  {
   switch(b)
     {
      case BIAS_BULLISH: return "BULLISH";
      case BIAS_BEARISH: return "BEARISH";
      default:           return "NONE";
     }
  }

string XSS_StructEventToStr(const ENUM_XSS_STRUCT_EVENT e)
  {
   switch(e)
     {
      case STRUCT_BOS_BULL:   return "BOS_BULL";
      case STRUCT_BOS_BEAR:   return "BOS_BEAR";
      case STRUCT_CHOCH_BULL: return "CHOCH_BULL";
      case STRUCT_CHOCH_BEAR: return "CHOCH_BEAR";
      default:                return "NONE";
     }
  }

class CMarketMemory
  {
private:
   string m_dir;
   string m_tradesFile;
   string m_statesFile;
   string m_perfFile;
   string m_historyFile;

   void EnsureDir()
     {
      if(!FileIsExist(m_dir, FILE_COMMON))
         FolderCreate(m_dir, FILE_COMMON);
     }

public:
   void Init(const string subdir = XSS_COMMON_SUBDIR)
     {
      m_dir         = subdir;
      m_tradesFile  = m_dir + "\\trades.csv";
      m_statesFile  = m_dir + "\\market_states.json";
      m_perfFile    = m_dir + "\\performance.csv";
      m_historyFile = m_dir + "\\strategy_history.json";
      EnsureDir();
     }

   bool LogTrade(const TradeRecord &tr)
     {
      bool existed = FileIsExist(m_tradesFile, FILE_COMMON);
      int h = FileOpen(m_tradesFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
      if(h == INVALID_HANDLE)
         return false;
      FileSeek(h, 0, SEEK_END);
      if(!existed)
         FileWrite(h, "ticket", "open_time", "close_time", "session", "atr", "spread", "score",
                   "sweep", "fvg_present", "zone_type", "entry", "sl", "tp", "rr", "profit", "win", "regime");
      FileWrite(h, (long)tr.ticket, TimeToString(tr.openTime, TIME_DATE | TIME_MINUTES),
                TimeToString(tr.closeTime, TIME_DATE | TIME_MINUTES), XSS_SessionToStr(tr.session),
                tr.atr, tr.spread, tr.scoreTotal, XSS_SweepToStr(tr.sweep), (tr.fvgPresent ? 1 : 0),
                XSS_ZoneToStr(tr.zoneType), tr.entry, tr.sl, tr.tp, tr.rr, tr.profit, (tr.win ? 1 : 0), tr.regime);
      FileClose(h);
      return true;
     }

   bool LogMarketState(const MarketSnapshot &snap)
     {
      int h = FileOpen(m_statesFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;
      FileSeek(h, 0, SEEK_END);

      CJsonWriter w;
      w.Str("time", TimeToString(snap.time, TIME_DATE | TIME_SECONDS));
      w.Str("session", XSS_SessionToStr(snap.session));
      w.Num("atr_m5", snap.atrM5);
      w.Num("spread_points", snap.spreadPoints);
      w.Str("h1_bias", XSS_BiasToStr(snap.h1Bias));
      w.Str("m1_choch", XSS_StructEventToStr(snap.m1Choch));
      w.Str("m1_bos", XSS_StructEventToStr(snap.m1Bos));
      w.Str("sweep", XSS_SweepToStr(snap.sweep));
      w.Bool("fvg_present", snap.fvgPresent);
      w.Bool("sd_zone_present", snap.sdZonePresent);
      w.Str("zone_type", XSS_ZoneToStr(snap.zoneType));
      w.Int("score_total", snap.score.Total());
      w.Close();

      FileWriteString(h, w.ToString() + "\n");
      FileClose(h);
      return true;
     }

   bool LogPerformance(const string periodLabel, const int trades, const int wins, const int losses,
                       const double profit, const double winRatePct, const double drawdownPct)
     {
      bool existed = FileIsExist(m_perfFile, FILE_COMMON);
      int h = FileOpen(m_perfFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
      if(h == INVALID_HANDLE)
         return false;
      FileSeek(h, 0, SEEK_END);
      if(!existed)
         FileWrite(h, "timestamp", "period", "trades", "wins", "losses", "profit", "win_rate_pct", "drawdown_pct");
      FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), periodLabel, trades, wins, losses,
                profit, winRatePct, drawdownPct);
      FileClose(h);
      return true;
     }

   bool LogStrategyVersion(const int version, const string paramsJson, const string notes, const string status)
     {
      int h = FileOpen(m_historyFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;
      FileSeek(h, 0, SEEK_END);

      CJsonWriter w;
      w.Int("version", version);
      w.Str("timestamp", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
      w.Str("status", status);
      w.Str("notes", notes);
      w.RawValue("params", paramsJson);
      w.Close();

      FileWriteString(h, w.ToString() + "\n");
      FileClose(h);
      return true;
     }

   string TradesFilePath()  const { return m_tradesFile;  }
   string StatesFilePath()  const { return m_statesFile;  }
   string PerfFilePath()    const { return m_perfFile;    }
   string HistoryFilePath() const { return m_historyFile; }
   string Directory()       const { return m_dir; }
  };

#endif // __XSS_MARKETMEMORY_MQH__
