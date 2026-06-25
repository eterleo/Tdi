//+------------------------------------------------------------------+
//|                                                    JsonLite.mqh  |
//|  Minimal JSON writer / reader. MQL5 has no native JSON support,  |
//|  this implements just enough to (a) emit flat/nested objects     |
//|  for log + AI export files and (b) read back flat key:value      |
//|  pairs from AI responses / hot-reload parameter files.           |
//|  It intentionally does NOT aim to be a general purpose parser.   |
//+------------------------------------------------------------------+
#ifndef __XSS_JSONLITE_MQH__
#define __XSS_JSONLITE_MQH__

//+------------------------------------------------------------------+
//| CJsonWriter - builds a JSON string incrementally                 |
//+------------------------------------------------------------------+
class CJsonWriter
  {
private:
   string m_buf;
   bool   m_needComma;

   void AppendRaw(const string s)
     {
      if(m_needComma)
         m_buf += ",";
      m_buf  += s;
      m_needComma = true;
     }

   string Esc(const string s)
     {
      string r = s;
      StringReplace(r, "\\", "\\\\");
      StringReplace(r, "\"", "\\\"");
      StringReplace(r, "\n", "\\n");
      return r;
     }

public:
            CJsonWriter() { m_buf = "{"; m_needComma = false; }

   void     BeginObject() { m_buf += "{"; m_needComma = false; }
   void     EndObject()   { m_buf += "}"; m_needComma = true;  }
   void     BeginArray()  { m_buf += "[";  m_needComma = false; }
   void     EndArray()    { m_buf += "]"; m_needComma = true;  }

   void     Key(const string key)
     {
      if(m_needComma)
         m_buf += ",";
      m_buf += "\"" + Esc(key) + "\":";
      m_needComma = false;
     }

   void     Str(const string key,  const string val)  { Key(key); m_buf += "\"" + Esc(val) + "\""; m_needComma = true; }
   void     Num(const string key,  const double val)  { Key(key); m_buf += DoubleToString(val, 8); m_needComma = true; }
   void     Int(const string key,  const long   val)  { Key(key); m_buf += IntegerToString(val);    m_needComma = true; }
   void     Bool(const string key, const bool   val)  { Key(key); m_buf += (val ? "true" : "false"); m_needComma = true; }
   void     RawValue(const string key, const string rawJson) { Key(key); m_buf += rawJson; m_needComma = true; }

   void     ArrayItemRaw(const string rawJson)
     {
      if(m_needComma)
         m_buf += ",";
      m_buf += rawJson;
      m_needComma = true;
     }

   string   ToString() { return m_buf; }
   void     Close()    { m_buf += "}"; }
   void     Reset()    { m_buf = "{"; m_needComma = false; }
  };

//+------------------------------------------------------------------+
//| Flat-key lookup helpers - searches a JSON-ish blob for           |
//| "key":value pairs at any nesting depth. Sufficient for reading   |
//| AI-suggested parameter updates and hot-reload config files which |
//| this project controls the schema of on both ends.                |
//+------------------------------------------------------------------+
string JsonFindRawValue(const string json, const string key)
  {
   string needle = "\"" + key + "\"";
   int pos = StringFind(json, needle);
   if(pos < 0)
      return "";
   int colon = StringFind(json, ":", pos + StringLen(needle));
   if(colon < 0)
      return "";
   int i = colon + 1;
   int len = StringLen(json);
   // skip whitespace
   while(i < len && (StringGetCharacter(json, i) == ' ' || StringGetCharacter(json, i) == '\t' ||
                      StringGetCharacter(json, i) == '\n' || StringGetCharacter(json, i) == '\r'))
      i++;
   if(i >= len)
      return "";

   ushort c = StringGetCharacter(json, i);
   int start = i;
   if(c == '"') // string value
     {
      i++;
      int vstart = i;
      while(i < len && StringGetCharacter(json, i) != '"')
        {
         if(StringGetCharacter(json, i) == '\\')
            i++;
         i++;
        }
      return StringSubstr(json, vstart, i - vstart);
     }
   if(c == '{' || c == '[') // nested object/array - return raw bracketed text
     {
      ushort openCh = c;
      ushort closeCh = (c == '{') ? '}' : ']';
      int depth = 0;
      while(i < len)
        {
         ushort cc = StringGetCharacter(json, i);
         if(cc == openCh)
            depth++;
         else if(cc == closeCh)
           {
            depth--;
            if(depth == 0)
              {
               i++;
               break;
              }
           }
         i++;
        }
      return StringSubstr(json, start, i - start);
     }
   // number / bool / null - read until , } ] or whitespace
   while(i < len)
     {
      ushort cc = StringGetCharacter(json, i);
      if(cc == ',' || cc == '}' || cc == ']' || cc == '\n' || cc == '\r')
         break;
      i++;
     }
   string v = StringSubstr(json, start, i - start);
   StringTrimLeft(v);
   StringTrimRight(v);
   return v;
  }

double JsonGetDouble(const string json, const string key, const double def)
  {
   string v = JsonFindRawValue(json, key);
   if(v == "")
      return def;
   return StringToDouble(v);
  }

long JsonGetInt(const string json, const string key, const long def)
  {
   string v = JsonFindRawValue(json, key);
   if(v == "")
      return def;
   return StringToInteger(v);
  }

string JsonGetString(const string json, const string key, const string def)
  {
   string v = JsonFindRawValue(json, key);
   if(v == "")
      return def;
   return v;
  }

bool JsonGetBool(const string json, const string key, const bool def)
  {
   string v = JsonFindRawValue(json, key);
   if(v == "")
      return def;
   return (v == "true" || v == "1");
  }

#endif // __XSS_JSONLITE_MQH__
