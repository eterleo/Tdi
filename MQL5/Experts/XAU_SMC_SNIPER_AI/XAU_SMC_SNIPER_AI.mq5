//+------------------------------------------------------------------+
//|                                          XAU_SMC_SNIPER_AI.mq5    |
//|  Gold-only (XAUUSD) M1/M5 Smart Money Concepts sniper EA with a   |
//|  locally-hosted, self-evolving AI strategy layer.                 |
//|                                                                     |
//|  Timeframe roles:                                                  |
//|    H1  - directional bias (EMA20/EMA50 + confirmed BOS)            |
//|    M15 - soft structural context filter                            |
//|    M5  - liquidity sweep + FVG / supply-demand setup zone          |
//|    M1  - CHOCH -> BOS execution trigger, limit-order entry         |
//|                                                                     |
//|  See docs/ARCHITECTURE.md for the full self-evolution design and  |
//|  its (honest) constraints around live code hot-swap.              |
//+------------------------------------------------------------------+
#property copyright "XAU_SMC_SNIPER_AI"
#property version   "1.00"
#property strict
#property description "Self-evolving XAUUSD SMC sniper EA (M1/M5) with local-AI driven parameter & module evolution."

#include <XAU_SMC_SNIPER_AI/Defines.mqh>
#include <XAU_SMC_SNIPER_AI/MarketStructure.mqh>
#include <XAU_SMC_SNIPER_AI/Liquidity.mqh>
#include <XAU_SMC_SNIPER_AI/FairValueGap.mqh>
#include <XAU_SMC_SNIPER_AI/SupplyDemand.mqh>
#include <XAU_SMC_SNIPER_AI/TrendEngine.mqh>
#include <XAU_SMC_SNIPER_AI/RiskManager.mqh>
#include <XAU_SMC_SNIPER_AI/TradeManager.mqh>
#include <XAU_SMC_SNIPER_AI/SessionFilter.mqh>
#include <XAU_SMC_SNIPER_AI/NewsFilter.mqh>
#include <XAU_SMC_SNIPER_AI/Telegram.mqh>
#include <XAU_SMC_SNIPER_AI/Statistics.mqh>
#include <XAU_SMC_SNIPER_AI/MarketMemory.mqh>
#include <XAU_SMC_SNIPER_AI/AIGateway.mqh>
#include <XAU_SMC_SNIPER_AI/CodeEvolutionEngine.mqh>

//================================== INPUTS ==========================================
input group "=== Risk Management ==="
input double InpRiskPercentDefault   = 0.5;   // default risk % per trade
input double InpRiskPercentMax       = 1.0;   // hard cap risk % per trade
input int    InpMaxConsecutiveLosses = 3;     // stop trading after N consecutive losses
input double InpDailyDrawdownLimitPct  = 3.0; // stop trading at -X% daily drawdown
input double InpWeeklyDrawdownLimitPct = 6.0; // stop trading at -X% weekly drawdown

input group "=== Confluence Scoring ==="
input int    InpScoreThreshold = 90;  // minimum confluence score (0-100) required to trade

input group "=== Volatility / Spread ==="
input int    InpAtrPeriod        = 14;
input double InpAtrThresholdM5   = 2.0;   // ATR(14) M5 must exceed this (USD) to trade
input int    InpMaxSpreadPoints  = 50;    // max allowed spread, in points

input group "=== Session Filter (Qatar time, GMT+3) ==="
input int  InpBrokerGmtOffsetHours = 0;   // broker server time minus GMT, set for your broker
input int  InpLondonStartHour      = 13;
input int  InpLondonEndHour        = 16;
input int  InpNewYorkStartHour     = 18;
input int  InpNewYorkEndHour       = 22;

input group "=== News Filter ==="
input int  InpNewsBlockMinutesBefore = 30;
input int  InpNewsBlockMinutesAfter  = 30;
input bool InpUseCalendarApi         = true;

input group "=== Market Structure ==="
input int InpStructLeftBars       = 2;
input int InpStructRightBars      = 2;
input int InpMaxBarsChochToBos    = 15;   // M1 bars allowed between CHOCH and confirming BOS

input group "=== Liquidity ==="
input int InpLiquidityLookbackBars = 20;
input int InpLiquidityRecencyBars  = 3;
input int InpSweepFreshnessBars    = 6;   // M5 bars - how "fresh" a sweep must be to count

input group "=== Fair Value Gap / Supply-Demand ==="
input int    InpFvgScanBars            = 40;
input int    InpSdScanBars             = 60;
input double InpSdImpulseAtrMultiplier = 1.5;
input int    InpSdBaseBars             = 2;
input double InpEntryToleranceUSD      = 0.50; // limit price tolerance around the 50% zone

input group "=== Trade Execution ==="
input double InpSlBufferUSD        = 0.30;  // extra buffer beyond the sweep extreme for SL
input double InpTakeProfitRR       = 4.0;   // target R-multiple (clamped to 3-5)
input int    InpPendingExpiryMinutes = 120;  // limit order validity window

input group "=== Telegram ==="
input bool   InpTelegramEnabled  = false;
input string InpTelegramBotToken = "";
input string InpTelegramChatId   = "";

input group "=== Local AI Engine ==="
input string InpAiEndpointUrl         = "http://127.0.0.1:11434/api/generate"; // Ollama-style endpoint
input string InpAiModel               = "qwen2.5-coder";
input int    InpEvolutionTradesPerCycle = 50;

input group "=== General ==="
input ulong  InpMagicNumber = XSS_MAGIC_NUMBER;

//================================== GLOBALS =========================================
CTrendEngine          g_trend;          // H1
CMarketStructure      g_m15Structure;   // M15 context
CMarketStructure      g_m1Structure;    // M1 execution
CLiquidity            g_liquidity;      // M5
CFairValueGap         g_fvg;            // M5
CSupplyDemand         g_supplyDemand;   // M5
CSessionFilter        g_session;
CNewsFilter           g_news;
CRiskManager          g_risk;
CTradeManager         g_tradeMgr;
CTelegram             g_telegram;
CStatistics           g_stats;
CMarketMemory         g_memory;
CAIGateway            g_ai;
CCodeEvolutionEngine  g_evolution;

int      g_atrM5Handle = INVALID_HANDLE;
datetime g_lastM1BarTime = 0;
double   g_liveAtrThreshold;
int      g_liveScoreThreshold;
double   g_liveRiskPercent;
int      g_liveMaxBarsChochBos;

int      g_lastDailyReportDay  = -1;
int      g_lastWeeklyReportBucket = -1;

//--- context kept between "signal" and "fill" so a full trade record can be logged ---
struct PendingCtx
  {
   ulong            orderTicket;
   ENUM_XSS_BIAS    dir;
   int              score;
   ENUM_XSS_SWEEP   sweep;
   bool             fvgPresent;
   ENUM_XSS_ZONE    zoneType;
   double           atr;
   double           spread;
   double           riskDistance;
   ENUM_XSS_SESSION session;
  };
PendingCtx g_pending[];

struct PositionCtx
  {
   ulong            ticket;
   datetime         openTime;
   double           entryPrice;
   double           riskDistance;
   double           initialLots;
   ENUM_XSS_BIAS    dir;
   int              score;
   ENUM_XSS_SWEEP   sweep;
   bool             fvgPresent;
   ENUM_XSS_ZONE    zoneType;
   double           atr;
   double           spread;
   ENUM_XSS_SESSION session;
  };
PositionCtx g_positions[];

//+------------------------------------------------------------------+
int FindPendingByOrder(const ulong orderTicket)
  {
   for(int i = 0; i < ArraySize(g_pending); i++)
      if(g_pending[i].orderTicket == orderTicket)
         return i;
   return -1;
  }

void RemovePending(const int idx)
  {
   int n = ArraySize(g_pending);
   for(int i = idx; i < n - 1; i++)
      g_pending[i] = g_pending[i+1];
   ArrayResize(g_pending, n - 1);
  }

int FindPositionCtx(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_positions); i++)
      if(g_positions[i].ticket == ticket)
         return i;
   return -1;
  }

void RemovePositionCtx(const int idx)
  {
   int n = ArraySize(g_positions);
   for(int i = idx; i < n - 1; i++)
      g_positions[i] = g_positions[i+1];
   ArrayResize(g_positions, n - 1);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringFind(_Symbol, "XAU") < 0)
      PrintFormat("[XAU_SMC_SNIPER_AI] WARNING: chart symbol '%s' does not look like XAUUSD - this EA is gold-only.", _Symbol);

   g_liveAtrThreshold    = InpAtrThresholdM5;
   g_liveScoreThreshold  = InpScoreThreshold;
   g_liveRiskPercent     = InpRiskPercentDefault;
   g_liveMaxBarsChochBos = InpMaxBarsChochToBos;

   g_trend.Init(_Symbol, PERIOD_H1, 20, 50);
   g_m15Structure.Init(_Symbol, PERIOD_M15, InpStructLeftBars, InpStructRightBars, 300);
   g_m1Structure.Init(_Symbol, PERIOD_M1, InpStructLeftBars, InpStructRightBars, 300);
   g_liquidity.Init(_Symbol, PERIOD_M5, InpLiquidityLookbackBars, InpLiquidityRecencyBars);
   g_fvg.Init(_Symbol, PERIOD_M5, InpFvgScanBars);
   g_supplyDemand.Init(_Symbol, PERIOD_M5, InpSdScanBars, InpAtrPeriod, InpSdImpulseAtrMultiplier, InpSdBaseBars);

   g_session.Init(InpBrokerGmtOffsetHours, InpLondonStartHour, InpLondonEndHour, InpNewYorkStartHour, InpNewYorkEndHour);
   g_news.Init(InpNewsBlockMinutesBefore, InpNewsBlockMinutesAfter, InpUseCalendarApi);
   g_risk.Init(_Symbol, InpRiskPercentDefault, InpRiskPercentMax, InpMaxConsecutiveLosses,
               InpDailyDrawdownLimitPct, InpWeeklyDrawdownLimitPct);

   g_telegram.Init(InpTelegramBotToken, InpTelegramChatId, InpTelegramEnabled);
   g_tradeMgr.Init(_Symbol, InpMagicNumber, GetPointer(g_telegram), 30);
   g_memory.Init();
   g_ai.Init(InpAiEndpointUrl, InpAiModel);
   g_evolution.Init(GetPointer(g_memory), GetPointer(g_telegram), InpEvolutionTradesPerCycle);

   g_atrM5Handle = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   if(g_atrM5Handle == INVALID_HANDLE)
     {
      Print("[XAU_SMC_SNIPER_AI] Failed to create ATR handle.");
      return INIT_FAILED;
     }

   EventSetTimer(30);
   PrintFormat("[XAU_SMC_SNIPER_AI] Initialized. version=%d", g_evolution.CurrentVersion());
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrM5Handle != INVALID_HANDLE)
      IndicatorRelease(g_atrM5Handle);
  }

//+------------------------------------------------------------------+
bool IsNewM1Bar()
  {
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t != g_lastM1BarTime)
     {
      g_lastM1BarTime = t;
      return true;
     }
   return false;
  }

double GetAtrM5()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrM5Handle, 0, 1, 1, buf) < 1)
      return 0.0;
   return buf[0];
  }

bool HasOpenExposure()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         return true;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
ConfluenceScore BuildScore(const ENUM_XSS_BIAS dir, const double atrM5, const bool chochThenBos,
                           const bool zoneFound, const bool sessionValid)
  {
   ConfluenceScore sc;
   sc.h1Bias         = (dir != BIAS_NONE) ? 20 : 0;
   sc.liquiditySweep = (g_liquidity.IsFresh(InpSweepFreshnessBars) && g_liquidity.MatchesDirection(dir)) ? 25 : 0;
   sc.choch          = chochThenBos ? 15 : 0;
   sc.bos            = chochThenBos ? 15 : 0;
   sc.fvgZone        = zoneFound ? 15 : 0;
   sc.session        = sessionValid ? 5 : 0;
   sc.atr            = (atrM5 > g_liveAtrThreshold) ? 5 : 0;
   return sc;
  }

//+------------------------------------------------------------------+
void TryEnter(const ENUM_XSS_BIAS dir)
  {
   if(HasOpenExposure())
      return;

   //--- M15 soft context: don't fight a clear opposing higher-context structure ---
   ENUM_XSS_BIAS m15Trend = g_m15Structure.Trend();
   if((dir == BIAS_BULLISH && m15Trend == BIAS_BEARISH) || (dir == BIAS_BEARISH && m15Trend == BIAS_BULLISH))
      return;

   datetime chochT, bosT;
   bool chochThenBos = g_m1Structure.GetChochThenBos(dir, g_liveMaxBarsChochBos, chochT, bosT);

   FVGZone fvgZone;
   SDZone  sdZone;
   bool haveFvg = g_fvg.GetNearestZone(dir, fvgZone);
   bool haveSd  = g_supplyDemand.GetNearestZone(dir, sdZone);
   bool zoneFound = haveFvg || haveSd;

   double atrM5 = GetAtrM5();
   ENUM_XSS_SESSION session = g_session.CurrentSession();
   bool sessionValid = (session != SESSION_NONE);

   ConfluenceScore score = BuildScore(dir, atrM5, chochThenBos, zoneFound, sessionValid);
   int total = score.Total();

   //--- log the snapshot regardless of outcome - the AI engine learns from near-misses too ---
   MarketSnapshot snap;
   snap.time           = TimeCurrent();
   snap.session        = session;
   snap.atrM5          = atrM5;
   snap.spreadPoints    = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   snap.h1Bias         = dir;
   snap.m1Choch        = g_m1Structure.LastChochEvent();
   snap.m1Bos          = g_m1Structure.LastBosEvent();
   snap.sweep          = g_liquidity.LastSweep();
   snap.fvgPresent     = haveFvg;
   snap.sdZonePresent  = haveSd;
   snap.zoneType       = haveSd ? sdZone.type : (haveFvg ? (fvgZone.bullish ? ZONE_DEMAND : ZONE_SUPPLY) : ZONE_NONE);
   snap.score          = score;
   g_memory.LogMarketState(snap);

   if(total < g_liveScoreThreshold)
      return;

   //--- hard gates not part of the 0-100 score ---
   if(snap.spreadPoints > InpMaxSpreadPoints)
      return;
   if(g_news.IsBlackout(TimeCurrent()))
      return;

   string reason;
   if(!g_risk.CanTrade(reason))
     {
      Print("[XAU_SMC_SNIPER_AI] Trading halted: ", reason);
      return;
     }

   //--- entry price: 50% of FVG if present, else zone midpoint ---
   double entryPrice = haveFvg ? fvgZone.mid : sdZone.mid;

   //--- stop loss: beyond the liquidity sweep extreme ---
   double sweepExtreme = g_liquidity.SweepExtreme();
   double sl = (dir == BIAS_BULLISH) ? (sweepExtreme - InpSlBufferUSD) : (sweepExtreme + InpSlBufferUSD);

   double riskDistance = MathAbs(entryPrice - sl);
   if(riskDistance <= 0)
      return;

   double rr = MathMin(MathMax(InpTakeProfitRR, 3.0), 5.0);
   double tp = (dir == BIAS_BULLISH) ? (entryPrice + rr * riskDistance) : (entryPrice - rr * riskDistance);

   double lots = g_risk.CalcLotSize(g_liveRiskPercent, riskDistance);
   if(lots <= 0)
      return;

   datetime expiry = TimeCurrent() + InpPendingExpiryMinutes * 60;
   ulong orderTicket = g_tradeMgr.PlaceLimitOrder(dir, entryPrice, sl, tp, lots, expiry, "XSS_SNIPER");
   if(orderTicket == 0)
      return;

   PendingCtx ctx;
   ctx.orderTicket  = orderTicket;
   ctx.dir          = dir;
   ctx.score        = total;
   ctx.sweep        = g_liquidity.LastSweep();
   ctx.fvgPresent   = haveFvg;
   ctx.zoneType     = snap.zoneType;
   ctx.atr          = atrM5;
   ctx.spread       = snap.spreadPoints;
   ctx.riskDistance = riskDistance;
   ctx.session      = session;
   int n = ArraySize(g_pending);
   ArrayResize(g_pending, n + 1);
   g_pending[n] = ctx;

   g_telegram.SendEntrySignal(_Symbol, (dir == BIAS_BULLISH ? "BUY LIMIT" : "SELL LIMIT"), entryPrice, sl, tp, lots, total);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_risk.Update();
   g_tradeMgr.ManageOpenPositions();
   g_tradeMgr.CancelStaleOrders(TimeCurrent());

   if(!IsNewM1Bar())
      return;

   g_trend.Update();
   g_m15Structure.Update();
   g_m1Structure.Update();
   g_liquidity.Update();
   g_fvg.Update();
   g_supplyDemand.Update();

   ENUM_XSS_BIAS bias = g_trend.Bias();
   if(bias == BIAS_NONE)
      return;

   TryEnter(bias);
  }

//+------------------------------------------------------------------+
void ApplyAiParamUpdate()
  {
   AIStrategyParams p;
   if(!g_ai.FetchParamUpdate(p))
      return;

   g_liveAtrThreshold    = p.atrThreshold;
   g_liveScoreThreshold  = p.scoreThreshold;
   g_liveRiskPercent     = p.riskPercentDefault;
   g_liveMaxBarsChochBos = p.maxBarsBetweenChochBos;
   g_risk.SetDefaultRiskPercent(p.riskPercentDefault);
   g_liquidity.SetLookbackBars((int)p.liquidityLookbackBars);
   g_supplyDemand.SetImpulseMultiplier(p.impulseAtrMultiplier);

   PrintFormat("[XAU_SMC_SNIPER_AI] Applied AI parameter update v%d: atrThreshold=%.2f scoreThreshold=%d riskPct=%.2f maxBarsChochBos=%d",
               p.version, g_liveAtrThreshold, g_liveScoreThreshold, g_liveRiskPercent, g_liveMaxBarsChochBos);
   g_telegram.SendEvolutionNotice(StringFormat("Live parameters updated to v%d.", p.version));
  }

void SendScheduledReports()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour == 23 && dt.min >= 55 && dt.day_of_year != g_lastDailyReportDay)
     {
      int trades, wins, losses;
      double profit;
      g_stats.DailyStats(trades, wins, losses, profit);
      g_telegram.SendDailyReport(trades, wins, losses, profit, g_stats.DailyWinRatePct());
      g_memory.LogPerformance("daily", trades, wins, losses, profit, g_stats.DailyWinRatePct(), g_risk.GetDailyDrawdownPct());
      g_lastDailyReportDay = dt.day_of_year;
     }

   int weekBucket = dt.day_of_year / 7;
   if(dt.day_of_week == 5 && dt.hour == 23 && dt.min >= 55 && weekBucket != g_lastWeeklyReportBucket)
     {
      int trades, wins, losses;
      double profit;
      g_stats.WeeklyStats(trades, wins, losses, profit);
      g_telegram.SendWeeklyReport(trades, wins, losses, profit, g_stats.WeeklyWinRatePct());
      g_memory.LogPerformance("weekly", trades, wins, losses, profit, g_stats.WeeklyWinRatePct(), g_risk.GetWeeklyDrawdownPct());
      g_lastWeeklyReportBucket = weekBucket;
     }
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ApplyAiParamUpdate();
   g_evolution.PollVersionStatus();
   SendScheduledReports();
  }

//+------------------------------------------------------------------+
double SumClosedProfit(const ulong positionTicket)
  {
   double sum = 0.0;
   if(!HistorySelectByPosition(positionTicket))
      return sum;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         sum += HistoryDealGetDouble(dealTicket, DEAL_PROFIT) + HistoryDealGetDouble(dealTicket, DEAL_SWAP) + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
     }
   return sum;
  }

void HandlePositionOpened(const ulong dealTicket)
  {
   ulong orderTicket   = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   ulong positionTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   int pendingIdx = FindPendingByOrder(orderTicket);
   if(pendingIdx < 0)
      return; // not ours / not tracked

   double entryPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double lots       = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double sl = 0.0;
   if(PositionSelectByTicket(positionTicket))
      sl = PositionGetDouble(POSITION_SL);

   PositionCtx pc;
   pc.ticket       = positionTicket;
   pc.openTime     = TimeCurrent();
   pc.entryPrice   = entryPrice;
   pc.riskDistance = g_pending[pendingIdx].riskDistance;
   pc.initialLots  = lots;
   pc.dir          = g_pending[pendingIdx].dir;
   pc.score        = g_pending[pendingIdx].score;
   pc.sweep        = g_pending[pendingIdx].sweep;
   pc.fvgPresent   = g_pending[pendingIdx].fvgPresent;
   pc.zoneType     = g_pending[pendingIdx].zoneType;
   pc.atr          = g_pending[pendingIdx].atr;
   pc.spread       = g_pending[pendingIdx].spread;
   pc.session      = g_pending[pendingIdx].session;

   int n = ArraySize(g_positions);
   ArrayResize(g_positions, n + 1);
   g_positions[n] = pc;

   g_tradeMgr.RegisterFilledPosition(positionTicket, entryPrice, sl, pc.dir, lots);
   RemovePending(pendingIdx);
  }

void HandlePositionClosed(const ulong positionTicket)
  {
   int idx = FindPositionCtx(positionTicket);
   if(idx < 0)
      return;
   if(PositionSelectByTicket(positionTicket))
      return; // still open (was a partial close, not final)

   double totalProfit = SumClosedProfit(positionTicket);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double riskMoney = (tickSize > 0) ? (g_positions[idx].riskDistance / tickSize) * tickValue * g_positions[idx].initialLots : 0.0;
   double rr = (riskMoney > 0) ? (totalProfit / riskMoney) : 0.0;
   bool win = totalProfit > 0;

   TradeRecord tr;
   tr.ticket      = positionTicket;
   tr.openTime    = g_positions[idx].openTime;
   tr.closeTime   = TimeCurrent();
   tr.session     = g_positions[idx].session;
   tr.atr         = g_positions[idx].atr;
   tr.spread      = g_positions[idx].spread;
   tr.scoreTotal  = g_positions[idx].score;
   tr.sweep       = g_positions[idx].sweep;
   tr.fvgPresent  = g_positions[idx].fvgPresent;
   tr.zoneType    = g_positions[idx].zoneType;
   tr.entry       = g_positions[idx].entryPrice;
   tr.sl          = 0.0;
   tr.tp          = 0.0;
   tr.rr          = rr;
   tr.profit      = totalProfit;
   tr.win         = win;
   tr.regime      = CStatistics::ClassifyRegime(tr.atr, g_liveAtrThreshold, tr.session);

   g_memory.LogTrade(tr);
   g_stats.RegisterTrade(totalProfit, rr, win);
   g_risk.RegisterTradeResult(win);
   g_evolution.OnTradeClosed();
   g_telegram.SendTradeClosed(positionTicket, totalProfit, rr, win);

   g_tradeMgr.Untrack(positionTicket);
   RemovePositionCtx(idx);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagicNumber)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ulong positionTicket  = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   if(entry == DEAL_ENTRY_IN)
      HandlePositionOpened(trans.deal);
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      HandlePositionClosed(positionTicket);
  }
//+------------------------------------------------------------------+
