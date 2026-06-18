//+------------------------------------------------------------------+
//| EquityGovernance.mqh                                              |
//| Module 5/10 - Equity governance state machine.                   |
//| Combines drawdown pressure + session windows into a single state  |
//| (NORMAL/CAUTION/RESTRICTED/HALTED) that gates position caps, and  |
//| logs every state transition via a pluggable callback so it can    |
//| feed an existing TradeLogger.mqh/PostgreSQL pipeline.             |
//| Wire-in point: call Update() every tick, then use GetMaxPositions |
//| and IsTradingAllowed() before opening new trades.                 |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_EQUITYGOVERNANCE_MQH__
#define __BYBITHFT_EQUITYGOVERNANCE_MQH__

#include <BybitHFT\DrawdownPredictor.mqh>

enum ENUM_GOVERNANCE_STATE
{
   GOV_STATE_NORMAL,     // full size, full session
   GOV_STATE_CAUTION,    // reduced size, still trading
   GOV_STATE_RESTRICTED, // minimal size, entries only in favor of reducing exposure
   GOV_STATE_HALTED      // no new entries
};

//--- Implement this and pass a function pointer to Init() to route governance
//--- decisions into your own logging/DB pipeline (e.g. TradeLogger.mqh).
typedef void (*GovernanceLogFunc)(const string event, const string detail);

class CEquityGovernance
{
private:
   CDrawdownPredictor    m_drawdown;
   ENUM_GOVERNANCE_STATE m_state;
   int                   m_session_start_hour; // broker-server time
   int                   m_session_end_hour;
   int                   m_max_positions_normal;
   GovernanceLogFunc     m_log_func;

   void Log(const string event, const string detail)
   {
      if(m_log_func != NULL) m_log_func(event, detail);
      PrintFormat("HFTAI: [EquityGovernance] %s: %s", event, detail);
   }

   bool IsWithinSession() const
   {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      if(m_session_start_hour <= m_session_end_hour)
         return (t.hour >= m_session_start_hour && t.hour < m_session_end_hour);
      return (t.hour >= m_session_start_hour || t.hour < m_session_end_hour); // wraps past midnight
   }

public:
   void Init(const double daily_loss_limit_percent, const int session_start_hour, const int session_end_hour,
             const int max_positions_normal, GovernanceLogFunc log_func = NULL)
   {
      m_drawdown.Init(daily_loss_limit_percent, 0.8);
      m_state = GOV_STATE_NORMAL;
      m_session_start_hour = session_start_hour;
      m_session_end_hour = session_end_hour;
      m_max_positions_normal = max_positions_normal;
      m_log_func = log_func;
   }

   void Update()
   {
      m_drawdown.Update();
      ENUM_GOVERNANCE_STATE prev = m_state;

      if(!IsWithinSession())
         m_state = GOV_STATE_HALTED;
      else if(m_drawdown.ShouldHaltTrading())
         m_state = GOV_STATE_HALTED;
      else if(m_drawdown.IsAtWarnThreshold())
         m_state = GOV_STATE_RESTRICTED;
      else if(m_drawdown.SizeMultiplier() < 1.0)
         m_state = GOV_STATE_CAUTION;
      else
         m_state = GOV_STATE_NORMAL;

      if(m_state != prev)
         Log("state_transition", StringFormat("%d -> %d (daily_loss=%.2f%%)", prev, m_state, m_drawdown.DailyLossPercent()));
   }

   ENUM_GOVERNANCE_STATE State() const { return m_state; }
   bool IsTradingAllowed() const { return m_state != GOV_STATE_HALTED; }

   int GetMaxPositions() const
   {
      switch(m_state)
      {
         case GOV_STATE_NORMAL:     return m_max_positions_normal;
         case GOV_STATE_CAUTION:    return MathMax(1, m_max_positions_normal / 2);
         case GOV_STATE_RESTRICTED: return 1;
         default:                   return 0;
      }
   }

   double GetSizeMultiplier() const { return m_drawdown.SizeMultiplier(); }
};

#endif // __BYBITHFT_EQUITYGOVERNANCE_MQH__
