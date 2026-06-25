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
   string m_rejectedFile;     // rejected-setup CSV (v2.0)
   string m_featuresFile;     // feature-snapshot JSON-Lines (v2.0)
   string m_dbFile;           // SQLite database, structured store (v2.0)
   int    m_db;

   void EnsureDir()
     {
      if(!FileIsExist(m_dir, FILE_COMMON))
         FolderCreate(m_dir, FILE_COMMON);
     }

   //--- additive structured store: same data as the CSV/JSON logs, queryable relationally (v2.0) ---
   bool OpenDatabase()
     {
      m_db = DatabaseOpen(m_dbFile, DATABASE_OPEN_READWRITE | DATABASE_OPEN_CREATE | DATABASE_OPEN_COMMON);
      if(m_db == INVALID_HANDLE)
        {
         PrintFormat("[MarketMemory] DatabaseOpen failed for %s, error=%d", m_dbFile, GetLastError());
         return false;
        }
      CreateTables();
      return true;
     }

   void CreateTables()
     {
      DatabaseExecute(m_db,
         "CREATE TABLE IF NOT EXISTS trades ("
         "ticket INTEGER, open_time INTEGER, close_time INTEGER, session TEXT, atr REAL, spread REAL, "
         "score_total INTEGER, sweep TEXT, fvg_present INTEGER, zone_type TEXT, entry REAL, sl REAL, "
         "tp REAL, rr REAL, profit REAL, win INTEGER, regime TEXT, mfe REAL, mae REAL, "
         "slippage_points REAL, latency_ms REAL, cluster_key TEXT, features_json TEXT)");

      DatabaseExecute(m_db,
         "CREATE TABLE IF NOT EXISTS rejected_setups ("
         "time INTEGER, dir TEXT, score_total INTEGER, score_threshold INTEGER, "
         "reject_reason TEXT, regime TEXT, session TEXT, features_json TEXT)");

      DatabaseExecute(m_db,
         "CREATE TABLE IF NOT EXISTS feature_snapshots ("
         "time INTEGER, context TEXT, features_json TEXT)");
     }

public:
                     CMarketMemory() { m_db = INVALID_HANDLE; }

                    ~CMarketMemory()
     {
      if(m_db != INVALID_HANDLE)
         DatabaseClose(m_db);
     }

   void Init(const string subdir = XSS_COMMON_SUBDIR)
     {
      m_dir          = subdir;
      m_tradesFile   = m_dir + "\\trades.csv";
      m_statesFile   = m_dir + "\\market_states.json";
      m_perfFile     = m_dir + "\\performance.csv";
      m_historyFile  = m_dir + "\\strategy_history.json";
      m_rejectedFile = m_dir + "\\rejected_setups.csv";
      m_featuresFile = m_dir + "\\feature_snapshots.json";
      m_dbFile       = m_dir + "\\market_memory.sqlite";
      EnsureDir();
      OpenDatabase();
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
                   "sweep", "fvg_present", "zone_type", "entry", "sl", "tp", "rr", "profit", "win", "regime",
                   "mfe", "mae", "slippage_points", "latency_ms", "cluster_key", "features_json");
      FileWrite(h, (long)tr.ticket, TimeToString(tr.openTime, TIME_DATE | TIME_MINUTES),
                TimeToString(tr.closeTime, TIME_DATE | TIME_MINUTES), XSS_SessionToStr(tr.session),
                tr.atr, tr.spread, tr.scoreTotal, XSS_SweepToStr(tr.sweep), (tr.fvgPresent ? 1 : 0),
                XSS_ZoneToStr(tr.zoneType), tr.entry, tr.sl, tr.tp, tr.rr, tr.profit, (tr.win ? 1 : 0), tr.regime,
                tr.mfe, tr.mae, tr.slippagePoints, tr.latencyMs, tr.clusterKey, tr.featuresJson);
      FileClose(h);

      LogTradeSqlite(tr);
      return true;
     }

   //--- structured-store mirror of LogTrade(), so the trades table can be queried relationally (v2.0) ---
   bool LogTradeSqlite(const TradeRecord &tr)
     {
      if(m_db == INVALID_HANDLE)
         return false;

      int req = DatabasePrepare(m_db,
         "INSERT INTO trades (ticket, open_time, close_time, session, atr, spread, score_total, sweep, "
         "fvg_present, zone_type, entry, sl, tp, rr, profit, win, regime, mfe, mae, slippage_points, "
         "latency_ms, cluster_key, features_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
      if(req == INVALID_HANDLE)
         return false;

      int p = 0;
      DatabaseBind(req, p++, (long)tr.ticket);
      DatabaseBind(req, p++, (long)tr.openTime);
      DatabaseBind(req, p++, (long)tr.closeTime);
      DatabaseBind(req, p++, XSS_SessionToStr(tr.session));
      DatabaseBind(req, p++, tr.atr);
      DatabaseBind(req, p++, tr.spread);
      DatabaseBind(req, p++, tr.scoreTotal);
      DatabaseBind(req, p++, XSS_SweepToStr(tr.sweep));
      DatabaseBind(req, p++, tr.fvgPresent ? 1 : 0);
      DatabaseBind(req, p++, XSS_ZoneToStr(tr.zoneType));
      DatabaseBind(req, p++, tr.entry);
      DatabaseBind(req, p++, tr.sl);
      DatabaseBind(req, p++, tr.tp);
      DatabaseBind(req, p++, tr.rr);
      DatabaseBind(req, p++, tr.profit);
      DatabaseBind(req, p++, tr.win ? 1 : 0);
      DatabaseBind(req, p++, tr.regime);
      DatabaseBind(req, p++, tr.mfe);
      DatabaseBind(req, p++, tr.mae);
      DatabaseBind(req, p++, tr.slippagePoints);
      DatabaseBind(req, p++, tr.latencyMs);
      DatabaseBind(req, p++, tr.clusterKey);
      DatabaseBind(req, p++, tr.featuresJson);

      DatabaseRead(req); // INSERT yields no result rows; execution happens on this step regardless
      DatabaseFinalize(req);
      return true;
     }

   //--- logs a setup that was scored/considered but NOT traded - the AI learns from near-misses too (v2.0) ---
   bool LogRejectedSetup(const RejectedSetup &rs, const string featuresJson)
     {
      bool existed = FileIsExist(m_rejectedFile, FILE_COMMON);
      int h = FileOpen(m_rejectedFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
      if(h == INVALID_HANDLE)
         return false;
      FileSeek(h, 0, SEEK_END);
      if(!existed)
         FileWrite(h, "time", "dir", "score_total", "score_threshold", "reject_reason", "regime", "session");
      FileWrite(h, TimeToString(rs.time, TIME_DATE | TIME_SECONDS), XSS_BiasToStr(rs.dir), rs.scoreTotal,
                rs.scoreThreshold, rs.rejectReason, (int)rs.regime, XSS_SessionToStr(rs.session));
      FileClose(h);

      if(m_db != INVALID_HANDLE)
        {
         int req = DatabasePrepare(m_db,
            "INSERT INTO rejected_setups (time, dir, score_total, score_threshold, reject_reason, regime, session, features_json) "
            "VALUES (?,?,?,?,?,?,?,?)");
         if(req != INVALID_HANDLE)
           {
            int p = 0;
            DatabaseBind(req, p++, (long)rs.time);
            DatabaseBind(req, p++, XSS_BiasToStr(rs.dir));
            DatabaseBind(req, p++, rs.scoreTotal);
            DatabaseBind(req, p++, rs.scoreThreshold);
            DatabaseBind(req, p++, rs.rejectReason);
            DatabaseBind(req, p++, (int)rs.regime);
            DatabaseBind(req, p++, XSS_SessionToStr(rs.session));
            DatabaseBind(req, p++, featuresJson);
            DatabaseRead(req);
            DatabaseFinalize(req);
           }
        }
      return true;
     }

   //--- generic engineered-feature snapshot logger - used for trades, rejections, and plain scans (v2.0) ---
   bool LogFeatureSnapshot(const datetime t, const string context, const string featuresJson)
     {
      int h = FileOpen(m_featuresFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;
      FileSeek(h, 0, SEEK_END);

      CJsonWriter w;
      w.Str("time", TimeToString(t, TIME_DATE | TIME_SECONDS));
      w.Str("context", context);
      w.RawValue("features", featuresJson);
      w.Close();
      FileWriteString(h, w.ToString() + "\n");
      FileClose(h);

      if(m_db != INVALID_HANDLE)
        {
         int req = DatabasePrepare(m_db, "INSERT INTO feature_snapshots (time, context, features_json) VALUES (?,?,?)");
         if(req != INVALID_HANDLE)
           {
            DatabaseBind(req, 0, (long)t);
            DatabaseBind(req, 1, context);
            DatabaseBind(req, 2, featuresJson);
            DatabaseRead(req);
            DatabaseFinalize(req);
           }
        }
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

   string TradesFilePath()   const { return m_tradesFile;   }
   string StatesFilePath()   const { return m_statesFile;   }
   string PerfFilePath()     const { return m_perfFile;     }
   string HistoryFilePath()  const { return m_historyFile;  }
   string RejectedFilePath() const { return m_rejectedFile; }
   string FeaturesFilePath() const { return m_featuresFile; }
   string DbFilePath()       const { return m_dbFile;       }
   int    DbHandle()         const { return m_db;            }
   string Directory()        const { return m_dir; }
  };

#endif // __XSS_MARKETMEMORY_MQH__
