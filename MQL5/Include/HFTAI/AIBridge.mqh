//+------------------------------------------------------------------+
//| AIBridge.mqh                                                      |
//| REST/WebRequest bridge between the EA and the external Python    |
//| AI inference server (technical signal) and NLP/news server       |
//| (fundamental score). MQL5's WebRequest() is synchronous, so the   |
//| EA must throttle calls (see InpMinRequestIntervalMs in the EA)    |
//| rather than calling it on every tick.                             |
//+------------------------------------------------------------------+
#ifndef __HFTAI_AIBRIDGE_MQH__
#define __HFTAI_AIBRIDGE_MQH__

#include <HFTAI\JsonUtils.mqh>

//--- Trade signal returned by the AI inference server
struct SAiSignal
{
   int      signal;       // -1 = Sell, 0 = Hold, 1 = Buy
   double   confidence;   // 0.0 .. 1.0
   double   sl_points;    // suggested stop-loss distance in points (0 = use EA default)
   double   tp_points;    // suggested take-profit distance in points (0 = use EA default)
   bool     valid;        // false if request failed / response malformed
   string   error;        // diagnostic text when valid == false
};

//--- Fundamental/NLP snapshot returned by the news server
struct SFundamentalData
{
   double   news_score;   // signed sentiment/impact score, e.g. -1.0 .. 1.0
   bool     high_impact;  // true if a high-impact release is imminent/active
   datetime fetched_at;   // local time the data was fetched
   bool     valid;
};

//--- Shared low-level POST helper. Returns the HTTP status code, or
//--- a negative value if WebRequest itself failed (no connection,
//--- URL not whitelisted, timeout, etc). Response body is written to out_body.
int HttpPostJson(const string url, const string json_body, const int timeout_ms, string &out_body)
{
   char   data[];
   char   result[];
   string result_headers;

   int body_len = StringToCharArray(json_body, data, 0, WHOLE_ARRAY, CP_UTF8) - 1; // drop trailing null
   if(body_len < 0) body_len = 0;
   ArrayResize(data, body_len);

   string headers = "Content-Type: application/json\r\n";

   ResetLastError();
   int status = WebRequest("POST", url, headers, timeout_ms, data, result, result_headers);

   if(status == -1)
   {
      int err = GetLastError();
      out_body = "";
      PrintFormat("HFTAI: WebRequest to %s failed, error %d (check 'Allow WebRequest for listed URL' and that the URL is whitelisted in Tools->Options->Expert Advisors)", url, err);
      return -err;
   }

   out_body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return status;
}

//--- Build the feature payload sent to the AI inference server.
//--- Combines live tick/order-flow features with the last cached
//--- fundamental snapshot so the model sees both data sources per call.
string BuildInferencePayload(const string symbol,
                              const MqlTick &tick,
                              const double order_book_imbalance,
                              const double momentum,
                              const double atr,
                              const SFundamentalData &fundamentals)
{
   string j = "{";
   JsonAddString(j, "symbol", symbol);
   JsonAddInt(j,    "time", (long)tick.time);
   JsonAddDouble(j, "bid", tick.bid, 5);
   JsonAddDouble(j, "ask", tick.ask, 5);
   JsonAddDouble(j, "spread_points", (tick.ask - tick.bid) / SymbolInfoDouble(symbol, SYMBOL_POINT), 1);
   JsonAddDouble(j, "last_volume", (double)tick.volume, 2);
   JsonAddDouble(j, "order_book_imbalance", order_book_imbalance, 6);
   JsonAddDouble(j, "momentum", momentum, 6);
   JsonAddDouble(j, "atr", atr, 6);
   JsonAddDouble(j, "news_score", fundamentals.valid ? fundamentals.news_score : 0.0, 6);
   JsonAddBool(j,   "news_high_impact", fundamentals.valid ? fundamentals.high_impact : false);
   JsonAddInt(j,    "news_age_sec", fundamentals.valid ? (long)(TimeCurrent() - fundamentals.fetched_at) : -1, true);
   j += "}";
   return j;
}

//--- Call the AI inference server with the given pre-built feature payload.
bool RequestAiSignal(const string url, const int timeout_ms, const string payload_json, SAiSignal &out)
{
   out.signal = 0;
   out.confidence = 0.0;
   out.sl_points = 0.0;
   out.tp_points = 0.0;
   out.valid = false;
   out.error = "";

   string body;
   int status = HttpPostJson(url, payload_json, timeout_ms, body);

   if(status < 0)
   {
      out.error = StringFormat("WebRequest error %d", -status);
      return false;
   }
   if(status != 200)
   {
      out.error = StringFormat("HTTP %d: %s", status, body);
      return false;
   }

   out.signal     = (int)JsonGetInt(body, "signal", 0);
   out.confidence = JsonGetDouble(body, "confidence", 0.0);
   out.sl_points  = JsonGetDouble(body, "sl_points", 0.0);
   out.tp_points  = JsonGetDouble(body, "tp_points", 0.0);

   if(out.signal < -1 || out.signal > 1)
   {
      out.error = "signal out of range [-1,1]: " + body;
      out.signal = 0;
      return false;
   }

   out.valid = true;
   return true;
}

//--- Poll the NLP/fundamental news server. Called on a slower timer,
//--- never from the tick-critical path.
bool RequestFundamentalData(const string url, const int timeout_ms, const string symbol, SFundamentalData &out)
{
   out.news_score = 0.0;
   out.high_impact = false;
   out.fetched_at = TimeCurrent();
   out.valid = false;

   string payload = "{\"symbol\":\"" + symbol + "\"}";
   string body;
   int status = HttpPostJson(url, payload, timeout_ms, body);

   if(status != 200)
   {
      PrintFormat("HFTAI: fundamental data request failed (status=%d)", status);
      return false;
   }

   out.news_score  = JsonGetDouble(body, "news_score", 0.0);
   out.high_impact = JsonGetBool(body, "high_impact", false);
   out.fetched_at  = TimeCurrent();
   out.valid = true;
   return true;
}

#endif // __HFTAI_AIBRIDGE_MQH__
