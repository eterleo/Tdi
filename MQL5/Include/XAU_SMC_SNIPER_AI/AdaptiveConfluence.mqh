//+------------------------------------------------------------------+
//|                                            AdaptiveConfluence.mqh |
//|  Weighted confluence scoring computed ALONGSIDE the legacy       |
//|  static ConfluenceScore/BuildScore path (which remains fully     |
//|  intact). Weights are hot-reloaded from adaptive_weights.json,   |
//|  written by the external AI evolution engine, mirroring the      |
//|  version-gated reload pattern used by CAIGateway::FetchParamUpdate|
//|  for strategy_params.json.                                       |
//+------------------------------------------------------------------+
#ifndef __XSS_ADAPTIVECONFLUENCE_MQH__
#define __XSS_ADAPTIVECONFLUENCE_MQH__

#include "Defines.mqh"
#include "JsonLite.mqh"

class CAdaptiveConfluence
  {
private:
   AdaptiveWeights m_weights;
   string          m_weightsFile;
   int             m_lastAppliedVersion;

   static double ClampWeight(const double w) { return MathMax(0.0, MathMin(60.0, w)); }

public:
                     CAdaptiveConfluence()
     {
      m_lastAppliedVersion = 0;
      //--- defaults mirror the legacy ConfluenceScore proportions (sums to 100),
      //--- so behaviour is identical to v1.0 until the AI starts adapting weights ---
      m_weights.version  = 0;
      m_weights.wTrend   = 20.0;
      m_weights.wSweep   = 25.0;
      m_weights.wChoch   = 15.0;
      m_weights.wBos     = 15.0;
      m_weights.wFvgZone = 15.0;
      m_weights.wSession = 5.0;
      m_weights.wAtr     = 5.0;
      m_weights.wSpread  = 0.0;
     }

   void Init(const string weightsFile = "XAU_SMC_SNIPER_AI\\adaptive_weights.json")
     {
      m_weightsFile = weightsFile;
     }

   //--- returns true and applies new weights only when the on-disk file has a newer version ---
   bool FetchWeightUpdate(AdaptiveWeights &out)
     {
      if(!FileIsExist(m_weightsFile, FILE_COMMON))
         return false;

      int h = FileOpen(m_weightsFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return false;

      string content = "";
      while(!FileIsEnding(h))
         content += FileReadString(h) + "\n";
      FileClose(h);

      int fileVersion = (int)JsonGetInt(content, "version", 0);
      if(fileVersion <= m_lastAppliedVersion)
         return false;

      AdaptiveWeights w;
      w.version  = fileVersion;
      w.wTrend   = ClampWeight(JsonGetDouble(content, "w_trend",    m_weights.wTrend));
      w.wSweep   = ClampWeight(JsonGetDouble(content, "w_sweep",    m_weights.wSweep));
      w.wChoch   = ClampWeight(JsonGetDouble(content, "w_choch",    m_weights.wChoch));
      w.wBos     = ClampWeight(JsonGetDouble(content, "w_bos",      m_weights.wBos));
      w.wFvgZone = ClampWeight(JsonGetDouble(content, "w_fvg_zone", m_weights.wFvgZone));
      w.wSession = ClampWeight(JsonGetDouble(content, "w_session",  m_weights.wSession));
      w.wAtr     = ClampWeight(JsonGetDouble(content, "w_atr",      m_weights.wAtr));
      w.wSpread  = ClampWeight(JsonGetDouble(content, "w_spread",   m_weights.wSpread));

      m_weights = w;
      m_lastAppliedVersion = fileVersion;
      out = w;
      return true;
     }

   AdaptiveWeights Weights() const { return m_weights; }
   int             LastAppliedVersion() const { return m_lastAppliedVersion; }

   //--- weighted score from the same boolean confluence inputs as the legacy BuildScore() ---
   double Score(const bool h1BiasAligned, const bool sweepPresent, const bool chochPresent,
                const bool bosPresent, const bool fvgOrZonePresent, const bool sessionValid,
                const bool atrOk, const double spreadPoints, const double maxAcceptableSpreadPoints) const
     {
      double score = 0.0;
      if(h1BiasAligned)     score += m_weights.wTrend;
      if(sweepPresent)      score += m_weights.wSweep;
      if(chochPresent)      score += m_weights.wChoch;
      if(bosPresent)        score += m_weights.wBos;
      if(fvgOrZonePresent)  score += m_weights.wFvgZone;
      if(sessionValid)      score += m_weights.wSession;
      if(atrOk)             score += m_weights.wAtr;

      if(m_weights.wSpread > 0.0 && maxAcceptableSpreadPoints > 0.0)
        {
         double spreadQuality = MathMax(0.0, 1.0 - (spreadPoints / maxAcceptableSpreadPoints));
         score += m_weights.wSpread * spreadQuality;
        }

      return score;
     }

   double MaxPossibleScore() const { return m_weights.Total(); }

   double NormalizedPct(const double rawScore) const
     {
      double total = m_weights.Total();
      if(total <= 0.0)
         return 0.0;
      return MathMax(0.0, MathMin(100.0, 100.0 * rawScore / total));
     }
  };

#endif // __XSS_ADAPTIVECONFLUENCE_MQH__
