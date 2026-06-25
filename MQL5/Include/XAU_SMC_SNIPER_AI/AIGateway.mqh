//+------------------------------------------------------------------+
//|                                                    AIGateway.mqh |
//|  Bridge between the EA and the locally-hosted AI engine.         |
//|                                                                    |
//|  Two responsibilities:                                            |
//|   1) Live parameter hot-reload: reads strategy_params.json        |
//|      (written by the external Python evolution engine, see        |
//|      ai_engine/) and exposes new values without restarting MT5.   |
//|   2) Optional direct query of a local OpenAI-compatible / Ollama  |
//|      endpoint for diagnostic / advisory text only. The AI never   |
//|      places trades directly - see CodeEvolutionEngine.mqh and the |
//|      ai_engine/ for where AI output actually changes behaviour.   |
//|                                                                    |
//|  Requires (only if QueryLocalAI is used): the endpoint host       |
//|  (e.g. http://127.0.0.1:11434) added under Tools > Options >      |
//|  Expert Advisors > "Allow WebRequest for listed URL".             |
//+------------------------------------------------------------------+
#ifndef __XSS_AIGATEWAY_MQH__
#define __XSS_AIGATEWAY_MQH__

#include "Defines.mqh"
#include "JsonLite.mqh"

struct AIStrategyParams
  {
   int    version;
   double atrThreshold;
   int    scoreThreshold;
   double riskPercentDefault;
   int    maxBarsBetweenChochBos;
   int    newsBlockMinutesBefore;
   int    newsBlockMinutesAfter;
   double liquidityLookbackBars;
   double impulseAtrMultiplier;
  };

class CAIGateway
  {
private:
   string m_endpointUrl;     // e.g. http://127.0.0.1:11434/api/generate (Ollama) or LM Studio /v1/chat/completions
   string m_model;
   string m_paramsFile;      // e.g. XAU_SMC_SNIPER_AI\\strategy_params.json (Common\\Files)
   int    m_lastAppliedVersion;

public:
                     CAIGateway() { m_lastAppliedVersion = 0; }

   void Init(const string endpointUrl, const string model,
             const string paramsFile = "XAU_SMC_SNIPER_AI\\strategy_params.json")
     {
      m_endpointUrl = endpointUrl;
      m_model       = model;
      m_paramsFile  = paramsFile;
     }

   //--- returns true and fills 'out' only when the on-disk file has a newer version ---
   bool FetchParamUpdate(AIStrategyParams &out)
     {
      if(!FileIsExist(m_paramsFile, FILE_COMMON))
         return false;

      int h = FileOpen(m_paramsFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;

      string content = "";
      while(!FileIsEnding(h))
         content += FileReadString(h) + "\n";
      FileClose(h);

      int fileVersion = (int)JsonGetInt(content, "version", 0);
      if(fileVersion <= m_lastAppliedVersion)
         return false;

      out.version                 = fileVersion;
      out.atrThreshold             = JsonGetDouble(content, "atr_threshold", 2.0);
      out.scoreThreshold           = (int)JsonGetInt(content, "score_threshold", 90);
      out.riskPercentDefault       = JsonGetDouble(content, "risk_percent_default", 0.5);
      out.maxBarsBetweenChochBos   = (int)JsonGetInt(content, "max_bars_between_choch_bos", 15);
      out.newsBlockMinutesBefore   = (int)JsonGetInt(content, "news_block_minutes_before", 30);
      out.newsBlockMinutesAfter    = (int)JsonGetInt(content, "news_block_minutes_after", 30);
      out.liquidityLookbackBars    = JsonGetDouble(content, "liquidity_lookback_bars", 20);
      out.impulseAtrMultiplier     = JsonGetDouble(content, "impulse_atr_multiplier", 1.5);

      m_lastAppliedVersion = fileVersion;
      return true;
     }

   int LastAppliedVersion() const { return m_lastAppliedVersion; }

   //--- generic, synchronous call to a local OpenAI-compatible / Ollama endpoint ---
   //--- advisory/diagnostic use only - never wired into the trade-decision path ---
   bool QueryLocalAI(const string prompt, string &responseText)
     {
      if(m_endpointUrl == "")
         return false;

      CJsonWriter w;
      w.Str("model", m_model);
      w.Str("prompt", prompt);
      w.Bool("stream", false);
      w.Close();
      string body = w.ToString();

      char postData[];
      StringToCharArray(body, postData, 0, StringLen(body));

      char result[];
      string resultHeaders;
      string headers = "Content-Type: application/json\r\n";

      ResetLastError();
      int code = WebRequest("POST", m_endpointUrl, headers, 15000, postData, result, resultHeaders);
      if(code == -1)
        {
         PrintFormat("[AIGateway] WebRequest failed, error=%d. Add %s to allowed URLs.", GetLastError(), m_endpointUrl);
         return false;
        }
      if(code != 200)
         return false;

      string raw = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      responseText = JsonGetString(raw, "response", raw); // Ollama uses "response"; fall back to raw body
      return true;
     }
  };

#endif // __XSS_AIGATEWAY_MQH__
