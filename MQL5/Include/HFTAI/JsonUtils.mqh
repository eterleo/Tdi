//+------------------------------------------------------------------+
//| JsonUtils.mqh                                                    |
//| Minimal flat-JSON encode/decode for the AI bridge wire format.   |
//| Not a general JSON library: only handles the flat numeric/bool/  |
//| string fields the AI server contract uses (no nested objects).  |
//+------------------------------------------------------------------+
#ifndef __HFTAI_JSONUTILS_MQH__
#define __HFTAI_JSONUTILS_MQH__

//--- Append a quoted string field: "key":"value"
void JsonAddString(string &json, const string key, const string value, const bool last = false)
{
   json += "\"" + key + "\":\"" + value + "\"" + (last ? "" : ",");
}

//--- Append a numeric field: "key":123.45
void JsonAddDouble(string &json, const string key, const double value, const int digits = 6, const bool last = false)
{
   json += "\"" + key + "\":" + DoubleToString(value, digits) + (last ? "" : ",");
}

void JsonAddInt(string &json, const string key, const long value, const bool last = false)
{
   json += "\"" + key + "\":" + IntegerToString(value) + (last ? "" : ",");
}

void JsonAddBool(string &json, const string key, const bool value, const bool last = false)
{
   json += "\"" + key + "\":" + (value ? "true" : "false") + (last ? "" : ",");
}

//--- Extract a numeric value for "key" from a flat JSON string.
//--- Returns default_value if the key is not found or malformed.
double JsonGetDouble(const string json, const string key, const double default_value)
{
   string needle = "\"" + key + "\"";
   int pos = StringFind(json, needle);
   if(pos < 0) return default_value;

   int colon = StringFind(json, ":", pos + StringLen(needle));
   if(colon < 0) return default_value;

   int start = colon + 1;
   int len = StringLen(json);
   int end = start;
   while(end < len)
   {
      ushort c = StringGetCharacter(json, end);
      if(c == ',' || c == '}' || c == ' ' || c == '\n' || c == '\r' || c == '\t') break;
      end++;
   }
   string raw = StringSubstr(json, start, end - start);
   StringReplace(raw, "\"", "");
   if(StringLen(raw) == 0) return default_value;
   return StringToDouble(raw);
}

long JsonGetInt(const string json, const string key, const long default_value)
{
   return (long)JsonGetDouble(json, key, (double)default_value);
}

bool JsonGetBool(const string json, const string key, const bool default_value)
{
   string needle = "\"" + key + "\"";
   int pos = StringFind(json, needle);
   if(pos < 0) return default_value;
   int colon = StringFind(json, ":", pos + StringLen(needle));
   if(colon < 0) return default_value;
   string tail = StringSubstr(json, colon + 1, 8);
   if(StringFind(tail, "true") == 0 || StringFind(tail, " true") == 0) return true;
   if(StringFind(tail, "false") == 0 || StringFind(tail, " false") == 0) return false;
   return default_value;
}

string JsonGetString(const string json, const string key, const string default_value)
{
   string needle = "\"" + key + "\":\"";
   int pos = StringFind(json, needle);
   if(pos < 0) return default_value;
   int start = pos + StringLen(needle);
   int end = StringFind(json, "\"", start);
   if(end < 0) return default_value;
   return StringSubstr(json, start, end - start);
}

#endif // __HFTAI_JSONUTILS_MQH__
