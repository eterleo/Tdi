//+------------------------------------------------------------------+
//|                                            CodeEvolutionEngine.mqh|
//|  EA-side half of the self-evolving loop.                          |
//|                                                                     |
//|  What this class actually does (and does NOT do) is important:    |
//|   - MQL5 cannot recompile or hot-swap its own running binary.      |
//|     "Self-modifying code" here means: an external, locally-hosted |
//|     AI process (ai_engine/, outside MT5) analyses trades.csv /     |
//|     market_states.json, edits the .mqh module sources, recompiles  |
//|     them with MetaEditor, validates the candidate in the Strategy  |
//|     Tester, and only then marks a version "approved".              |
//|   - This class triggers that cycle every N closed trades, polls    |
//|     for the engine's verdict, and:                                 |
//|       (a) applies everything that CAN change live - numeric        |
//|           parameters and module on/off flags - with zero downtime |
//|           via CAIGateway's JSON hot-reload, and                    |
//|       (b) when the approved version also changed structural .mqh   |
//|           code (so a recompiled .ex5 exists), raises a             |
//|           "pending restart" flag that an external watchdog script  |
//|           (ai_engine/deploy_watchdog.py) uses to swap the .ex5 and |
//|           reload the chart automatically the next time there are   |
//|           zero open positions - never killing a live trade.        |
//|   - Every version transition (applied or rejected) is logged to    |
//|     strategy_history.json via CMarketMemory so it is reversible:   |
//|     rolling back means redeploying any prior logged version.       |
//+------------------------------------------------------------------+
#ifndef __XSS_CODEEVOLUTIONENGINE_MQH__
#define __XSS_CODEEVOLUTIONENGINE_MQH__

#include "Defines.mqh"
#include "JsonLite.mqh"
#include "MarketMemory.mqh"
#include "Telegram.mqh"

struct ModuleFlags
  {
   bool useFairValueGap;
   bool useSupplyDemand;
   bool requireBothFvgAndZone;
  };

class CCodeEvolutionEngine
  {
private:
   int           m_tradesPerCycle;
   int           m_tradesSinceLastCycle;
   int           m_currentVersion;
   string        m_dir;
   string        m_triggerFile;
   string        m_statusFile;
   string        m_stateFile;
   string        m_moduleFlagsFile;
   bool          m_pendingRestart;

   CMarketMemory *m_memory;
   CTelegram     *m_telegram;

   void LoadState()
     {
      m_currentVersion = 1;
      m_tradesSinceLastCycle = 0;
      if(!FileIsExist(m_stateFile, FILE_COMMON))
         return;
      int h = FileOpen(m_stateFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return;
      string content = "";
      while(!FileIsEnding(h))
         content += FileReadString(h) + "\n";
      FileClose(h);
      m_currentVersion       = (int)JsonGetInt(content, "current_version", 1);
      m_tradesSinceLastCycle = (int)JsonGetInt(content, "trades_since_last_cycle", 0);
     }

   void SaveState()
     {
      int h = FileOpen(m_stateFile, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return;
      CJsonWriter w;
      w.Int("current_version", m_currentVersion);
      w.Int("trades_since_last_cycle", m_tradesSinceLastCycle);
      w.Bool("pending_restart", m_pendingRestart);
      w.Close();
      FileWriteString(h, w.ToString());
      FileClose(h);
     }

public:
                     CCodeEvolutionEngine()
     {
      m_currentVersion = 1;
      m_tradesSinceLastCycle = 0;
      m_pendingRestart = false;
      m_memory = NULL;
      m_telegram = NULL;
     }

   void Init(CMarketMemory *memory, CTelegram *telegram, const int tradesPerCycle = 50,
             const string subdir = XSS_COMMON_SUBDIR)
     {
      m_memory          = memory;
      m_telegram        = telegram;
      m_tradesPerCycle  = tradesPerCycle;
      m_dir             = subdir;
      m_triggerFile     = m_dir + "\\evolution_trigger.json";
      m_statusFile      = m_dir + "\\version_status.json";
      m_stateFile       = m_dir + "\\evolution_state.json";
      m_moduleFlagsFile = m_dir + "\\module_flags.json";
      LoadState();
     }

   int  CurrentVersion()       const { return m_currentVersion; }
   bool HasPendingRestart()    const { return m_pendingRestart; }
   int  TradesUntilNextCycle() const { return MathMax(0, m_tradesPerCycle - m_tradesSinceLastCycle); }

   //--- call once per closed trade ---
   void OnTradeClosed()
     {
      m_tradesSinceLastCycle++;
      if(m_tradesSinceLastCycle >= m_tradesPerCycle)
        {
         WriteEvolutionTrigger();
         m_tradesSinceLastCycle = 0;
        }
      SaveState();
     }

   //--- nudges the external AI evolution engine to run its analysis cycle now ---
   void WriteEvolutionTrigger()
     {
      if(m_memory == NULL)
         return;

      int h = FileOpen(m_triggerFile, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return;

      CJsonWriter w;
      w.Str("requested_at", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
      w.Int("current_version", m_currentVersion);
      w.Int("trades_in_cycle", m_tradesPerCycle);
      w.Str("trades_csv", m_memory.TradesFilePath());
      w.Str("market_states_json", m_memory.StatesFilePath());
      w.Close();
      FileWriteString(h, w.ToString());
      FileClose(h);

      if(m_telegram != NULL)
         m_telegram.SendEvolutionNotice(StringFormat("Cycle complete (%d trades). Evolution analysis requested for v%d -> v%d.",
                                                      m_tradesPerCycle, m_currentVersion, m_currentVersion + 1));
     }

   //--- polls version_status.json written by ai_engine/compiler.py + backtest_validator.py ---
   //--- returns true if a new, already-applied-or-flagged version was found ---
   bool PollVersionStatus()
     {
      if(!FileIsExist(m_statusFile, FILE_COMMON))
         return false;

      int h = FileOpen(m_statusFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;
      string content = "";
      while(!FileIsEnding(h))
         content += FileReadString(h) + "\n";
      FileClose(h);

      int version   = (int)JsonGetInt(content, "version", 0);
      string status = JsonGetString(content, "status", "");
      string notes  = JsonGetString(content, "notes", "");
      bool structuralChange = JsonGetBool(content, "structural_change", false);
      string paramsRaw = JsonFindRawValue(content, "params");
      if(paramsRaw == "")
         paramsRaw = "{}";

      if(version <= m_currentVersion)
         return false; // already processed

      if(status == "approved")
        {
         m_currentVersion = version;
         if(structuralChange)
           {
            m_pendingRestart = true;
            if(m_telegram != NULL)
               m_telegram.SendEvolutionNotice(StringFormat(
                  "v%d APPROVED (structural module changes). Live params applied now; .ex5 swap queued for next flat period.\n%s",
                  version, notes));
           }
         else
           {
            if(m_telegram != NULL)
               m_telegram.SendEvolutionNotice(StringFormat("v%d APPROVED (parameter-only). Applied live.\n%s", version, notes));
           }

         if(m_memory != NULL)
            m_memory.LogStrategyVersion(version, paramsRaw, notes, "approved");
        }
      else if(status == "rejected")
        {
         if(m_telegram != NULL)
            m_telegram.SendEvolutionNotice(StringFormat("v%d REJECTED by backtest validation, staying on v%d.\n%s",
                                                         version, m_currentVersion, notes));
         if(m_memory != NULL)
            m_memory.LogStrategyVersion(version, paramsRaw, notes, "rejected");
        }

      SaveState();
      return true;
     }

   //--- a watchdog (ai_engine/deploy_watchdog.py) clears this once the .ex5 has been swapped ---
   void AcknowledgeRestartHandled()
     {
      m_pendingRestart = false;
      SaveState();
     }

   bool FetchModuleFlags(ModuleFlags &out)
     {
      if(!FileIsExist(m_moduleFlagsFile, FILE_COMMON))
        {
         out.useFairValueGap = true;
         out.useSupplyDemand = true;
         out.requireBothFvgAndZone = false;
         return false;
        }
      int h = FileOpen(m_moduleFlagsFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;
      string content = "";
      while(!FileIsEnding(h))
         content += FileReadString(h) + "\n";
      FileClose(h);

      out.useFairValueGap       = JsonGetBool(content, "use_fvg", true);
      out.useSupplyDemand       = JsonGetBool(content, "use_supply_demand", true);
      out.requireBothFvgAndZone = JsonGetBool(content, "require_both_fvg_and_zone", false);
      return true;
     }
  };

#endif // __XSS_CODEEVOLUTIONENGINE_MQH__
