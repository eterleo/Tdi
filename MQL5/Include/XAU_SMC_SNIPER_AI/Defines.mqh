//+------------------------------------------------------------------+
//|                                                    Defines.mqh   |
//|  XAU_SMC_SNIPER_AI - shared enums, structs and constants         |
//+------------------------------------------------------------------+
#ifndef __XSS_DEFINES_MQH__
#define __XSS_DEFINES_MQH__

#define XSS_PROJECT_NAME   "XAU_SMC_SNIPER_AI"
#define XSS_COMMON_SUBDIR  "XAU_SMC_SNIPER_AI"   // sub-folder inside the MT5 "Common\\Files" directory
#define XSS_MAGIC_NUMBER   885522110

//--- bias / direction -------------------------------------------------
enum ENUM_XSS_BIAS
  {
   BIAS_NONE = 0,
   BIAS_BULLISH,
   BIAS_BEARISH
  };

//--- liquidity sweep type ---------------------------------------------
enum ENUM_XSS_SWEEP
  {
   SWEEP_NONE = 0,
   SWEEP_SELL_SIDE,   // sweeps sell-side liquidity (below lows) -> bullish setup
   SWEEP_BUY_SIDE      // sweeps buy-side liquidity (above highs) -> bearish setup
  };

//--- market structure events -------------------------------------------
enum ENUM_XSS_STRUCT_EVENT
  {
   STRUCT_NONE = 0,
   STRUCT_BOS_BULL,
   STRUCT_BOS_BEAR,
   STRUCT_CHOCH_BULL,
   STRUCT_CHOCH_BEAR
  };

//--- zone type (supply/demand) ------------------------------------------
enum ENUM_XSS_ZONE
  {
   ZONE_NONE = 0,
   ZONE_DEMAND,
   ZONE_SUPPLY
  };

//--- trading session -----------------------------------------------------
enum ENUM_XSS_SESSION
  {
   SESSION_NONE = 0,
   SESSION_LONDON,
   SESSION_NEWYORK
  };

//--- swing point ----------------------------------------------------------
struct SwingPoint
  {
   datetime time;
   double   price;
   bool     isHigh;
   int      shift;
  };

//--- fair value gap --------------------------------------------------------
struct FVGZone
  {
   datetime time;
   double   top;
   double   bottom;
   double   mid;
   bool     bullish;
   bool     mitigated;
  };

//--- supply / demand zone -----------------------------------------------
struct SDZone
  {
   datetime    time;
   double      top;
   double      bottom;
   double      mid;
   ENUM_XSS_ZONE type;
   bool        mitigated;
  };

//--- confluence score breakdown ------------------------------------------
struct ConfluenceScore
  {
   int h1Bias;          // 0 or 20
   int liquiditySweep;  // 0 or 25
   int choch;           // 0 or 15
   int bos;             // 0 or 15
   int fvgZone;         // 0 or 15
   int session;         // 0 or 5
   int atr;             // 0 or 5

   int Total() const
     {
      return h1Bias + liquiditySweep + choch + bos + fvgZone + session + atr;
     }
  };

//--- complete market snapshot used for memory + AI export -----------------
struct MarketSnapshot
  {
   datetime          time;
   ENUM_XSS_SESSION  session;
   double            atrM5;
   double            spreadPoints;
   ENUM_XSS_BIAS     h1Bias;
   ENUM_XSS_STRUCT_EVENT m1Choch;
   ENUM_XSS_STRUCT_EVENT m1Bos;
   ENUM_XSS_SWEEP    sweep;
   bool              fvgPresent;
   bool              sdZonePresent;
   ENUM_XSS_ZONE     zoneType;
   ConfluenceScore   score;
  };

//--- trade record stored in market memory ---------------------------------
struct TradeRecord
  {
   ulong            ticket;
   datetime         openTime;
   datetime         closeTime;
   ENUM_XSS_SESSION session;
   double           atr;
   double           spread;
   int              scoreTotal;
   ENUM_XSS_SWEEP   sweep;
   bool             fvgPresent;
   ENUM_XSS_ZONE    zoneType;
   double           entry;
   double           sl;
   double           tp;
   double           rr;
   double           profit;
   bool             win;
   string           regime;
  };

#endif // __XSS_DEFINES_MQH__
