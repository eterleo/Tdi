//+------------------------------------------------------------------+
//| DrawdownRecoveryProtocol.mqh                                      |
//| Module 8/10 - Drawdown recovery / revenge-trading guard.          |
//| Tracks consecutive losing trades, imposes a cooldown after a loss |
//| streak, halves size during recovery mode, and only restores full  |
//| size after enough consecutive wins or a reset timer elapses.      |
//| Wire-in point: call RecordTradeResult(won) from OnTradeTransaction|
//| on each closed deal, and gate new entries with IsInCooldown() /   |
//| scale size with GetSizeMultiplier().                               |
//+------------------------------------------------------------------+
#ifndef __BYBITHFT_DRAWDOWNRECOVERYPROTOCOL_MQH__
#define __BYBITHFT_DRAWDOWNRECOVERYPROTOCOL_MQH__

class CDrawdownRecoveryProtocol
{
private:
   int      m_loss_streak_for_cooldown; // e.g. 3
   int      m_win_streak_to_recover;    // e.g. 5
   int      m_cooldown_seconds;
   int      m_reset_timer_seconds;      // alternative path back to full size

   int      m_consecutive_losses;
   int      m_consecutive_wins;
   bool     m_in_recovery;
   datetime m_cooldown_until;
   datetime m_recovery_entered_at;

public:
   void Init(const int loss_streak_for_cooldown = 3, const int win_streak_to_recover = 5,
             const int cooldown_seconds = 900, const int reset_timer_seconds = 3600)
   {
      m_loss_streak_for_cooldown = loss_streak_for_cooldown;
      m_win_streak_to_recover = win_streak_to_recover;
      m_cooldown_seconds = cooldown_seconds;
      m_reset_timer_seconds = reset_timer_seconds;

      m_consecutive_losses = 0;
      m_consecutive_wins = 0;
      m_in_recovery = false;
      m_cooldown_until = 0;
      m_recovery_entered_at = 0;
   }

   //--- Call once per closed trade with whether it was a net winner.
   void RecordTradeResult(const bool won)
   {
      if(won)
      {
         m_consecutive_wins++;
         m_consecutive_losses = 0;
         if(m_in_recovery && m_consecutive_wins >= m_win_streak_to_recover)
         {
            m_in_recovery = false;
            PrintFormat("HFTAI: [DrawdownRecovery] full size restored after %d consecutive wins", m_consecutive_wins);
         }
      }
      else
      {
         m_consecutive_losses++;
         m_consecutive_wins = 0;
         if(m_consecutive_losses >= m_loss_streak_for_cooldown)
         {
            m_cooldown_until = TimeCurrent() + m_cooldown_seconds;
            m_in_recovery = true;
            m_recovery_entered_at = TimeCurrent();
            PrintFormat("HFTAI: [DrawdownRecovery] %d consecutive losses -> cooldown until %s, half size until recovery",
                        m_consecutive_losses, TimeToString(m_cooldown_until));
         }
      }
   }

   bool IsInCooldown() const { return TimeCurrent() < m_cooldown_until; }

   bool IsInRecovery() const
   {
      if(!m_in_recovery) return false;
      if(m_reset_timer_seconds > 0 && (TimeCurrent() - m_recovery_entered_at) >= m_reset_timer_seconds)
         return false; // reset timer path back to full size, even without a win streak
      return true;
   }

   //--- 0.0 while in cooldown (no new entries), 0.5 while recovering, 1.0 normal.
   double GetSizeMultiplier() const
   {
      if(IsInCooldown()) return 0.0;
      if(IsInRecovery()) return 0.5;
      return 1.0;
   }
};

#endif // __BYBITHFT_DRAWDOWNRECOVERYPROTOCOL_MQH__
