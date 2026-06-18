//+------------------------------------------------------------------+
//|                                            Gold_HFT_AI_EA.mq5     |
//| HFT-style Expert Advisor for XAUUSD that bridges live tick/order- |
//| book data plus periodic fundamental/NLP scores to an external    |
//| Python AI server over WebRequest (REST/JSON), and executes        |
//| signals asynchronously via OrderSendAsync with spread/deviation   |
//| guardrails tuned for violent gold moves around news releases.     |
//|                                                                     |
//| EXTERNAL DEPENDENCIES (must be configured before running):         |
//|  1. Tools > Options > Expert Advisors > "Allow WebRequest for      |
//|     listed URL" must include both InpAiServerUrl and               |
//|     InpNewsServerUrl (exact scheme+host+port, e.g.                  |
//|     http://127.0.0.1:8000).                                         |
//|  2. "Allow Algo Trading" must be enabled (toolbar + terminal        |
//|     options) for OrderSendAsync to be accepted.                     |
//|  3. The AI server must implement POST <InpAiServerUrl> accepting   |
//|     the JSON built in AIBridge.mqh::BuildInferencePayload and       |
//|     returning {"signal":-1|0|1,"confidence":0..1,                  |
//|     "sl_points":n,"tp_points":n}.                                   |
//|  4. The news/NLP server must implement POST <InpNewsServerUrl>      |
//|     returning {"news_score":-1..1,"high_impact":true|false}.       |
//|  5. MQL5's WebRequest() is synchronous/blocking by design -- there  |
//|     is no native async HTTP call in MQL5. This EA mitigates that    |
//|     by throttling inference calls (InpMinRequestIntervalMs) and     |
//|     caching the last signal between calls, rather than calling      |
//|     out on every tick. For sub-millisecond latency you would need   |
//|     a native ONNX model (Option B) or a custom DLL (Option C)       |
//|     instead of this REST bridge.                                    |
//+------------------------------------------------------------------+
#property copyright "HFTAI"
#property version   "1.00"
#property strict

#include <HFTAI\AIBridge.mqh>
#include <HFTAI\RiskGuard.mqh>

//================================== Inputs ==================================
input string InpAiServerUrl          = "http://127.0.0.1:8000/infer";   // AI inference endpoint
input string InpNewsServerUrl        = "http://127.0.0.1:8000/news";   // Fundamental/NLP endpoint
input int    InpRequestTimeoutMs     = 300;     // WebRequest timeout (ms) - keep short, this blocks OnTick
input int    InpMinRequestIntervalMs = 250;     // Min ms between AI inference calls (throttle)
input int    InpNewsPollIntervalMs   = 15000;   // Poll the news server every N ms (timer-driven)

input double InpMaxSpreadPoints      = 35;      // Skip trading if spread exceeds this (points)
input int    InpMaxDeviationPoints   = 30;      // Max allowed slippage/deviation on market orders
input double InpMinConfidence        = 0.60;    // Minimum AI confidence to act on a signal
input bool   InpBlockOnHighImpactNews= true;    // Block new entries during high-impact news
input int    InpNewsMaxAgeSec        = 120;     // Ignore/expire news data older than this

input int    InpTradeCooldownMs      = 500;     // Minimum ms between order submissions
input int    InpAtrPeriod            = 14;      // ATR period for momentum/SL-TP fallback
input double InpDefaultSlPoints      = 300;     // Fallback SL distance (points) if AI omits it
input double InpDefaultTpPoints      = 450;     // Fallback TP distance (points) if AI omits it

input bool   InpUseFixedLot          = false;   // Use fixed lot size instead of risk-based sizing
input double InpFixedLot             = 0.10;    // Fixed lot size (if InpUseFixedLot)
input double InpRiskPercent          = 0.50;    // Risk % of equity per trade (if not fixed lot)

input long   InpMagicNumber          = 990177;  // EA magic number
input int    InpMomentumLookback     = 20;      // Ticks used to compute short-term momentum
input int    InpMaxConsecutiveErrors = 5;       // Pause trading after this many AI/news errors in a row
input int    InpErrorBackoffMs       = 5000;    // Pause duration (ms) after hitting the error threshold

//================================== Globals ==================================
int            g_atr_handle = INVALID_HANDLE;

double         g_tick_prices[];
int            g_tick_count = 0;

double         g_ob_imbalance = 0.0;            // updated in OnBookEvent

SFundamentalData g_fundamentals;
ulong          g_last_news_poll_msc = 0;

ulong          g_last_inference_msc = 0;
SAiSignal      g_last_signal;

ulong          g_last_trade_msc = 0;
int            g_consecutive_errors = 0;
ulong          g_error_backoff_until_msc = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(_Symbol, "XAU") < 0)
      PrintFormat("HFTAI: WARNING - chart symbol %s does not look like Gold; EA features were tuned for XAUUSD.", _Symbol);

   g_atr_handle = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("HFTAI: failed to create ATR handle, error ", GetLastError());
      return INIT_FAILED;
   }

   if(!MarketBookAdd(_Symbol))
      Print("HFTAI: MarketBookAdd failed (order-book imbalance feature will stay at 0), error ", GetLastError());

   ArrayResize(g_tick_prices, MathMax(InpMomentumLookback, 1));
   ArrayInitialize(g_tick_prices, 0.0);
   g_tick_count = 0;

   ZeroMemory(g_fundamentals);
   ZeroMemory(g_last_signal);

   EventSetMillisecondTimer(MathMax(InpNewsPollIntervalMs, 1000));

   PrintFormat("HFTAI: initialized. AI=%s News=%s Magic=%I64d", InpAiServerUrl, InpNewsServerUrl, InpMagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   MarketBookRelease(_Symbol);
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
}

//+------------------------------------------------------------------+
//| Live order-book event -- ultra-low-latency depth-of-market hook.  |
//| Keeps a lightweight top-of-book imbalance feature fresh between   |
//| AI calls; does not itself call the AI (too high-frequency for a   |
//| blocking HTTP round trip).                                        |
//+------------------------------------------------------------------+
void OnBookEvent(const string &symbol)
{
   if(symbol != _Symbol) return;

   MqlBookInfo book[];
   if(!MarketBookGet(_Symbol, book)) return;

   double bid_vol = 0.0, ask_vol = 0.0;
   for(int i = 0; i < ArraySize(book); i++)
   {
      if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET)
         bid_vol += (double)book[i].volume;
      else if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET)
         ask_vol += (double)book[i].volume;
   }

   double total = bid_vol + ask_vol;
   g_ob_imbalance = (total > 0.0) ? (bid_vol - ask_vol) / total : 0.0;
}

//+------------------------------------------------------------------+
//| Timer-driven fundamental/NLP poll. Deliberately decoupled from    |
//| OnTick so a slow news-server response never stalls tick handling. |
//+------------------------------------------------------------------+
void OnTimer()
{
   SFundamentalData fresh;
   if(RequestFundamentalData(InpNewsServerUrl, InpRequestTimeoutMs, _Symbol, fresh))
   {
      g_fundamentals = fresh;
      g_consecutive_errors = 0;
   }
   else
   {
      RegisterError("news-poll");
   }
}

//+------------------------------------------------------------------+
void PushTickPrice(const double mid)
{
   int n = ArraySize(g_tick_prices);
   for(int i = n - 1; i > 0; i--)
      g_tick_prices[i] = g_tick_prices[i - 1];
   g_tick_prices[0] = mid;
   if(g_tick_count < n) g_tick_count++;
}

double ComputeMomentum()
{
   int n = ArraySize(g_tick_prices);
   if(g_tick_count < n || g_tick_prices[n - 1] == 0.0) return 0.0;
   return (g_tick_prices[0] - g_tick_prices[n - 1]) / g_tick_prices[n - 1];
}

double ComputeAtrPoints()
{
   double buf[];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, buf) != 1) return 0.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return 0.0;
   return buf[0] / point;
}

//+------------------------------------------------------------------+
void RegisterError(const string context)
{
   g_consecutive_errors++;
   PrintFormat("HFTAI: error in %s (consecutive=%d)", context, g_consecutive_errors);
   if(g_consecutive_errors >= InpMaxConsecutiveErrors)
   {
      g_error_backoff_until_msc = GetTickCount64() + (ulong)InpErrorBackoffMs;
      PrintFormat("HFTAI: %d consecutive errors, pausing trading for %d ms", g_consecutive_errors, InpErrorBackoffMs);
      g_consecutive_errors = 0;
   }
}

bool IsTradingPaused()
{
   return GetTickCount64() < g_error_backoff_until_msc;
}

//+------------------------------------------------------------------+
//| Build SL/TP absolute prices from a points distance.               |
//+------------------------------------------------------------------+
void ComputeStops(const int direction, const double entry_price, const double sl_points, const double tp_points,
                   double &sl_price, double &tp_price)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl_dist = (sl_points > 0.0 ? sl_points : InpDefaultSlPoints) * point;
   double tp_dist = (tp_points > 0.0 ? tp_points : InpDefaultTpPoints) * point;

   if(direction > 0)
   {
      sl_price = entry_price - sl_dist;
      tp_price = entry_price + tp_dist;
   }
   else
   {
      sl_price = entry_price + sl_dist;
      tp_price = entry_price - tp_dist;
   }
}

//+------------------------------------------------------------------+
//| Strict async execution: builds the request, runs OrderCheck for   |
//| pre-validation, then submits via OrderSendAsync (non-blocking).   |
//| Final fill/rejection is confirmed later in OnTradeTransaction.    |
//+------------------------------------------------------------------+
bool OpenPositionAsync(const int direction, const double lots, const double sl_points, const double tp_points)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;

   double entry = (direction > 0) ? tick.ask : tick.bid;
   double sl_price, tp_price;
   ComputeStops(direction, entry, sl_points, tp_points, sl_price, tp_price);

   MqlTradeRequest request;
   MqlTradeResult  result;
   MqlTradeCheckResult check;
   ZeroMemory(request);
   ZeroMemory(result);
   ZeroMemory(check);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol        = _Symbol;
   request.volume         = lots;
   request.type           = (direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price          = entry;
   request.sl             = sl_price;
   request.tp             = tp_price;
   request.deviation      = InpMaxDeviationPoints;   // strict slippage protection
   request.magic          = InpMagicNumber;
   request.type_filling   = ORDER_FILLING_FOK;
   request.type_time      = ORDER_TIME_GTC;
   request.comment        = "HFTAI";

   if(!OrderCheck(request, check))
   {
      PrintFormat("HFTAI: OrderCheck rejected order (retcode=%d, comment=%s)", check.retcode, check.comment);
      return false;
   }

   if(!OrderSendAsync(request, result))
   {
      PrintFormat("HFTAI: OrderSendAsync failed immediately (retcode=%d, comment=%s)", result.retcode, result.comment);
      RegisterError("order-send");
      return false;
   }

   PrintFormat("HFTAI: order queued (dir=%d lots=%.2f sl=%.2f tp=%.2f request_id=%d)", direction, lots, sl_price, tp_price, result.request_id);
   g_last_trade_msc = GetTickCount64();
   return true;
}

bool ClosePositionAsync(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;

   string symbol      = PositionGetString(POSITION_SYMBOL);
   double volume       = PositionGetDouble(POSITION_VOLUME);
   long   pos_type     = PositionGetInteger(POSITION_TYPE);

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action      = TRADE_ACTION_DEAL;
   request.symbol       = symbol;
   request.volume        = volume;
   request.position      = ticket;
   request.type           = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price           = (pos_type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
   request.deviation       = InpMaxDeviationPoints;
   request.magic            = InpMagicNumber;
   request.type_filling      = ORDER_FILLING_FOK;
   request.comment            = "HFTAI-close";

   if(!OrderSendAsync(request, result))
   {
      PrintFormat("HFTAI: close OrderSendAsync failed (retcode=%d, comment=%s)", result.retcode, result.comment);
      RegisterError("order-close");
      return false;
   }
   g_last_trade_msc = GetTickCount64();
   return true;
}

//+------------------------------------------------------------------+
//| Decide what to do with a fresh/cached AI signal under guardrails. |
//+------------------------------------------------------------------+
void ActOnSignal(const SAiSignal &sig)
{
   if(!sig.valid) return;
   if(sig.signal == 0) return;
   if(sig.confidence < InpMinConfidence) return;
   if(IsTradingPaused()) return;
   if(!IsSpreadAcceptable(_Symbol, InpMaxSpreadPoints)) return;
   if(ShouldBlockForNews(g_fundamentals, InpBlockOnHighImpactNews, InpNewsMaxAgeSec)) return;
   if(!IsCooldownElapsed(g_last_trade_msc, InpTradeCooldownMs)) return;

   bool has_position = false;
   long  open_type = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         has_position = true;
         open_type = PositionGetInteger(POSITION_TYPE);
         if((open_type == POSITION_TYPE_BUY && sig.signal < 0) ||
            (open_type == POSITION_TYPE_SELL && sig.signal > 0))
         {
            ClosePositionAsync(ticket); // signal flipped: flatten now, re-enter on a later tick
         }
         break;
      }
   }

   if(has_position) return; // either aligned already, or just queued a close

   double lots = CalcLotSize(_Symbol, InpRiskPercent, (sig.sl_points > 0.0 ? sig.sl_points : InpDefaultSlPoints),
                              InpUseFixedLot, InpFixedLot);
   if(lots <= 0.0) return;

   OpenPositionAsync(sig.signal, lots, sig.sl_points, sig.tp_points);
}

//+------------------------------------------------------------------+
//| Main tick handler: ultra-low-latency local checks every tick,    |
//| throttled AI inference calls, async execution.                   |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   PushTickPrice((tick.bid + tick.ask) / 2.0);

   if(!IsSpreadAcceptable(_Symbol, InpMaxSpreadPoints)) return; // skip everything on excessive spread
   if(IsTradingPaused()) return;

   ulong now_msc = GetTickCount64();
   if(now_msc - g_last_inference_msc < (ulong)InpMinRequestIntervalMs)
   {
      // Too soon to call the AI again -- act on the cached signal only if it is still fresh.
      ActOnSignal(g_last_signal);
      return;
   }

   double momentum   = ComputeMomentum();
   double atr_points  = ComputeAtrPoints();
   string payload      = BuildInferencePayload(_Symbol, tick, g_ob_imbalance, momentum, atr_points, g_fundamentals);

   SAiSignal sig;
   if(RequestAiSignal(InpAiServerUrl, InpRequestTimeoutMs, payload, sig))
   {
      g_consecutive_errors = 0;
      g_last_signal = sig;
   }
   else
   {
      PrintFormat("HFTAI: inference call failed: %s", sig.error);
      RegisterError("inference");
      g_last_signal.valid = false;
   }
   g_last_inference_msc = now_msc;

   ActOnSignal(g_last_signal);
}

//+------------------------------------------------------------------+
//| Confirms/rejects async order outcomes once the trade server       |
//| responds. This is where real order-rejection error handling       |
//| lives, since OrderSendAsync only validates locally before queuing.|
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(request.magic != InpMagicNumber) return;

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      PrintFormat("HFTAI: deal confirmed - ticket=%I64u symbol=%s volume=%.2f price=%.5f", trans.deal, trans.symbol, trans.volume, trans.price);
      g_consecutive_errors = 0;
   }
   else if(trans.type == TRADE_TRANSACTION_REQUEST)
   {
      // Final outcome of an async OrderSendAsync request once the trade server replies.
      if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
      {
         PrintFormat("HFTAI: async order rejected - retcode=%d comment=%s", result.retcode, result.comment);
         RegisterError("order-rejected");
      }
   }
}
