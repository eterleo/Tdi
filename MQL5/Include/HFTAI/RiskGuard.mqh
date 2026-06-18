//+------------------------------------------------------------------+
//| RiskGuard.mqh                                                     |
//| Pre-trade guardrails for the HFT Gold EA: spread/deviation        |
//| filters, cooldown throttle, news blackout, and position sizing.   |
//+------------------------------------------------------------------+
#ifndef __HFTAI_RISKGUARD_MQH__
#define __HFTAI_RISKGUARD_MQH__

#include <HFTAI\AIBridge.mqh>

//--- Current spread (points) must not exceed max_spread_points.
//--- Gold can gap violently on news; this is the first line of defense.
bool IsSpreadAcceptable(const string symbol, const double max_spread_points)
{
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) return false;

   double spread_points = (ask - bid) / point;
   return spread_points <= max_spread_points;
}

//--- Enforce a minimum gap between trades so the EA can't fire faster
//--- than the broker/venue tolerates or the AI server can keep up with.
bool IsCooldownElapsed(const ulong last_trade_msc, const int cooldown_ms)
{
   return (GetTickCount64() - last_trade_msc) >= (ulong)cooldown_ms;
}

//--- Block new entries around high-impact fundamental releases unless
//--- the caller explicitly disabled the blackout.
bool ShouldBlockForNews(const SFundamentalData &fundamentals, const bool block_on_high_impact, const int max_age_sec)
{
   if(!fundamentals.valid) return false; // no data yet -> don't block on missing info
   if(block_on_high_impact && fundamentals.high_impact)
   {
      int age = (int)(TimeCurrent() - fundamentals.fetched_at);
      if(age <= max_age_sec) return true;
   }
   return false;
}

//--- True if the EA already has an open position on this symbol/magic.
bool HasOpenPosition(const string symbol, const long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
   }
   return false;
}

//--- Position size from risk percent of equity and the SL distance,
//--- normalized to the symbol's volume step/min/max.
double CalcLotSize(const string symbol, const double risk_percent, const double sl_points,
                    const bool use_fixed_lot, const double fixed_lot)
{
   if(use_fixed_lot) return fixed_lot;

   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double vol_min    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vol_max    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double vol_step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(sl_points <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0)
      return vol_min;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * (risk_percent / 100.0);
   double loss_per_lot = sl_points * point / tick_size * tick_value;
   if(loss_per_lot <= 0.0) return vol_min;

   double lots = risk_money / loss_per_lot;
   lots = MathFloor(lots / vol_step) * vol_step;
   lots = MathMax(vol_min, MathMin(vol_max, lots));
   return lots;
}

#endif // __HFTAI_RISKGUARD_MQH__
