//+------------------------------------------------------------------+
//|                                              symbol-spec.mq5     |
//|  Снимает спецификацию символа (SymbolInfo*) в JSON.             |
//|  Не торгует. В файл не попадают счёт, логин, сервер, баланс, IP.|
//+------------------------------------------------------------------+
#property strict
#property description "Symbol spec | JSON спецификации символа (не торгует)"
#property version   "1.00"
#property script_show_inputs

input string InpSymbol    = "XAUUSDm"; // Символ для ручного запуска
input bool   InpUseInputs = false;     // true — взять input, если нет файла задания

#define JOB_FILE "symbol-spec-job.txt"
#define OUT_DIR  "symbol-spec"
#define SCRIPT_VER "2"

string g_symbol;

//+------------------------------------------------------------------+
string Ascii(const string s)
  {
   string out = "";
   const int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      const int c = StringGetCharacter(s, i);
      if(c >= 32 && c < 127)
         out += CharToString((uchar)c);
      else
         out += "?";
     }
   return out;
  }

//+------------------------------------------------------------------+
bool SafeSymbol(const string s)
  {
   const int n = StringLen(s);
   if(n < 1 || n > 32)
      return false;
   const int c0 = StringGetCharacter(s, 0);
   if(!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z')))
      return false;
   for(int i = 1; i < n; i++)
     {
      const int c = StringGetCharacter(s, i);
      const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '.' || c == '_';
      if(!ok)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
string JsonString(const string s)
  {
   string out = "";
   const string src = Ascii(s);
   const int n = StringLen(src);
   for(int i = 0; i < n; i++)
     {
      const int c = StringGetCharacter(src, i);
      if(c == '\"' || c == '\\')
         out += "\\";
      out += CharToString((uchar)c);
     }
   return "\"" + out + "\"";
  }

//+------------------------------------------------------------------+
string Num(const double v)
  {
   string s = DoubleToString(v, 8);
   StringReplace(s, ",", ".");
   StringReplace(s, " ", "");
   return s;
  }

//+------------------------------------------------------------------+
string Clock(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02d", d.year, d.mon, d.day, d.hour, d.min, d.sec);
  }

//+------------------------------------------------------------------+
string HhMm(const int seconds)
  {
   int s = seconds;
   if(s < 0)
      s += 86400;
   s %= 86400;
   return StringFormat("%02d:%02d", s / 3600, (s % 3600) / 60);
  }

//+------------------------------------------------------------------+
string DayKey(const int day)
  {
   if(day == SUNDAY)    return "sunday";
   if(day == MONDAY)    return "monday";
   if(day == TUESDAY)   return "tuesday";
   if(day == WEDNESDAY) return "wednesday";
   if(day == THURSDAY)  return "thursday";
   if(day == FRIDAY)    return "friday";
   if(day == SATURDAY)  return "saturday";
   return "unknown";
  }

//+------------------------------------------------------------------+
string DayName(const int day)
  {
   if(day == SUNDAY)    return "SUNDAY";
   if(day == MONDAY)    return "MONDAY";
   if(day == TUESDAY)   return "TUESDAY";
   if(day == WEDNESDAY) return "WEDNESDAY";
   if(day == THURSDAY)  return "THURSDAY";
   if(day == FRIDAY)    return "FRIDAY";
   if(day == SATURDAY)  return "SATURDAY";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
string CalcModeName(const long mode)
  {
   if(mode == SYMBOL_CALC_MODE_FOREX)               return "SYMBOL_CALC_MODE_FOREX";
   if(mode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)   return "SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE";
   if(mode == SYMBOL_CALC_MODE_FUTURES)             return "SYMBOL_CALC_MODE_FUTURES";
   if(mode == SYMBOL_CALC_MODE_CFD)                 return "SYMBOL_CALC_MODE_CFD";
   if(mode == SYMBOL_CALC_MODE_CFDINDEX)            return "SYMBOL_CALC_MODE_CFDINDEX";
   if(mode == SYMBOL_CALC_MODE_CFDLEVERAGE)         return "SYMBOL_CALC_MODE_CFDLEVERAGE";
   if(mode == SYMBOL_CALC_MODE_EXCH_STOCKS)         return "SYMBOL_CALC_MODE_EXCH_STOCKS";
   if(mode == SYMBOL_CALC_MODE_EXCH_FUTURES)        return "SYMBOL_CALC_MODE_EXCH_FUTURES";
   if(mode == SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS)  return "SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS";
   if(mode == SYMBOL_CALC_MODE_EXCH_BONDS)          return "SYMBOL_CALC_MODE_EXCH_BONDS";
   if(mode == SYMBOL_CALC_MODE_EXCH_STOCKS_MOEX)    return "SYMBOL_CALC_MODE_EXCH_STOCKS_MOEX";
   if(mode == SYMBOL_CALC_MODE_EXCH_BONDS_MOEX)     return "SYMBOL_CALC_MODE_EXCH_BONDS_MOEX";
   if(mode == SYMBOL_CALC_MODE_SERV_COLLATERAL)     return "SYMBOL_CALC_MODE_SERV_COLLATERAL";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
string ExeModeName(const long mode)
  {
   if(mode == SYMBOL_TRADE_EXECUTION_REQUEST)  return "SYMBOL_TRADE_EXECUTION_REQUEST";
   if(mode == SYMBOL_TRADE_EXECUTION_INSTANT)  return "SYMBOL_TRADE_EXECUTION_INSTANT";
   if(mode == SYMBOL_TRADE_EXECUTION_MARKET)   return "SYMBOL_TRADE_EXECUTION_MARKET";
   if(mode == SYMBOL_TRADE_EXECUTION_EXCHANGE) return "SYMBOL_TRADE_EXECUTION_EXCHANGE";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
string SwapModeName(const long mode)
  {
   if(mode == SYMBOL_SWAP_MODE_DISABLED)         return "SYMBOL_SWAP_MODE_DISABLED";
   if(mode == SYMBOL_SWAP_MODE_POINTS)           return "SYMBOL_SWAP_MODE_POINTS";
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL)  return "SYMBOL_SWAP_MODE_CURRENCY_SYMBOL";
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_MARGIN)  return "SYMBOL_SWAP_MODE_CURRENCY_MARGIN";
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT) return "SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT";
   if(mode == SYMBOL_SWAP_MODE_CURRENCY_PROFIT)  return "SYMBOL_SWAP_MODE_CURRENCY_PROFIT";
   if(mode == SYMBOL_SWAP_MODE_INTEREST_CURRENT) return "SYMBOL_SWAP_MODE_INTEREST_CURRENT";
   if(mode == SYMBOL_SWAP_MODE_INTEREST_OPEN)    return "SYMBOL_SWAP_MODE_INTEREST_OPEN";
   if(mode == SYMBOL_SWAP_MODE_REOPEN_CURRENT)   return "SYMBOL_SWAP_MODE_REOPEN_CURRENT";
   if(mode == SYMBOL_SWAP_MODE_REOPEN_BID)       return "SYMBOL_SWAP_MODE_REOPEN_BID";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
string Named(const long value, const string name)
  {
   return "{\"value\": " + IntegerToString((int)value) + ", \"name\": " + JsonString(name) + "}";
  }

//+------------------------------------------------------------------+
string FlagList(const int mask, const int &bits[], const string &names[], const int n)
  {
   string out = "[";
   int count = 0;
   int known = 0;
   for(int i = 0; i < n; i++)
     {
      known |= bits[i];
      if((mask & bits[i]) == 0)
         continue;
      if(count > 0)
         out += ", ";
      out += JsonString(names[i]);
      count++;
     }
   int extra = mask & ~known;
   int bit = 1;
   for(int i = 0; i < 24 && extra != 0; i++)
     {
      if((extra & bit) != 0)
        {
         if(count > 0)
            out += ", ";
         out += JsonString("bit_" + IntegerToString(bit));
         count++;
        }
      bit *= 2;
     }
   out += "]";
   return "{\"value\": " + IntegerToString(mask) + ", \"flags\": " + out + "}";
  }

//+------------------------------------------------------------------+
string WeekdaySwaps(const string sym)
  {
   const int id[7] =
     {
      SYMBOL_SWAP_SUNDAY, SYMBOL_SWAP_MONDAY, SYMBOL_SWAP_TUESDAY, SYMBOL_SWAP_WEDNESDAY,
      SYMBOL_SWAP_THURSDAY, SYMBOL_SWAP_FRIDAY, SYMBOL_SWAP_SATURDAY
     };
   string out = "{";
   for(int i = 0; i < 7; i++)
     {
      if(i > 0)
         out += ", ";
      ResetLastError();
      const double v = SymbolInfoDouble(sym, (ENUM_SYMBOL_INFO_DOUBLE)id[i]);
      const int err = GetLastError();
      out += JsonString(DayKey(i)) + ": ";
      if(err != 0)
         out += "null";
      else
         out += Num(v);
     }
   out += "}";
   return out;
  }

//+------------------------------------------------------------------+
string MarginRate(const string sym, const ENUM_ORDER_TYPE kind)
  {
   double initial = 0.0;
   double maintenance = 0.0;
   ResetLastError();
   if(!SymbolInfoMarginRate(sym, kind, initial, maintenance) || GetLastError() != 0)
      return "null";
   return "{\"initial\": " + Num(initial) + ", \"maintenance\": " + Num(maintenance) + "}";
  }

//+------------------------------------------------------------------+
string OneSideSessions(const string sym, const bool trade)
  {
   string out = "{";
   for(int day = 0; day < 7; day++)
     {
      if(day > 0)
         out += ", ";
      out += JsonString(DayKey(day)) + ": [";
      int count = 0;
      for(uint session = 0; session < 16; session++)
        {
         datetime from_dt = 0;
         datetime to_dt = 0;
         const bool ok = trade
                         ? SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)day, session, from_dt, to_dt)
                         : SymbolInfoSessionQuote(sym, (ENUM_DAY_OF_WEEK)day, session, from_dt, to_dt);
         if(!ok)
            break;
         int from_s = (int)((long)from_dt % 86400);
         int to_s = (int)((long)to_dt % 86400);
         if(from_s < 0)
            from_s += 86400;
         if(to_s < 0)
            to_s += 86400;
         if(count > 0)
            out += ", ";
         out += "{\"from\": " + JsonString(HhMm(from_s)) + ", \"to\": " + JsonString(HhMm(to_s))
                + ", \"from_seconds\": " + IntegerToString(from_s)
                + ", \"to_seconds\": " + IntegerToString(to_s) + "}";
         count++;
        }
      out += "]";
     }
   out += "}";
   return out;
  }

//+------------------------------------------------------------------+
bool ReadJob()
  {
   g_symbol = "";
   const int h = FileOpen(JOB_FILE, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line, "\r", "");
      StringReplace(line, "\n", "");
      // BOM UTF-8, если файл записан не чистым ASCII.
      StringReplace(line, CharToString((uchar)0xEF) + CharToString((uchar)0xBB) + CharToString((uchar)0xBF), "");
      StringReplace(line, ShortToString((ushort)0xFEFF), "");
      const int at = StringFind(line, "symbol=");
      if(at < 0)
         continue;
      string val = StringSubstr(line, at + 7);
      StringTrimLeft(val);
      StringTrimRight(val);
      if(SafeSymbol(val))
         g_symbol = val;
     }
   FileClose(h);
   return (g_symbol != "");
  }

//+------------------------------------------------------------------+
bool WaitConnected()
  {
   for(int i = 0; i < 90; i++)
     {
      if(TerminalInfoInteger(TERMINAL_CONNECTED) && AccountInfoInteger(ACCOUNT_LOGIN) != 0)
         return true;
      Sleep(1000);
     }
   return false;
  }

//+------------------------------------------------------------------+
bool SymbolBasicsReady()
  {
   if(!SymbolSelect(g_symbol, true))
      return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_SELECT) == 0)
      return false;
   const long digits = SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (digits >= 0 && digits <= 8 && point > 0.0);
  }

//+------------------------------------------------------------------+
// Сначала цифры и пункт, как в съёме тиков. Размер контракта догружается
// вместе со спецификацией: ждём его, но всё равно снимаем, что есть.
bool SelectSymbol()
  {
   bool ready = false;
   for(int i = 0; i < 90 && !ready; i++)
     {
      ready = SymbolBasicsReady();
      if(!ready)
         Sleep(1000);
     }
   if(!ready)
      return false;
   for(int i = 0; i < 60; i++)
     {
      MqlTick wake;
      SymbolInfoTick(g_symbol, wake);
      const double contract = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      const double vol = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
      if(contract > 0.0 && vol > 0.0)
         return true;
      Sleep(1000);
     }
   return true;
  }

//+------------------------------------------------------------------+
// FILE_BIN: текстовый режим превращает \n в \r\n, и число байт
// перестаёт совпадать с StringLen. Ненулевая запись — успех.
bool WriteSpec(const string body)
  {
   if(StringLen(body) < 2)
      return false;
   FolderCreate(OUT_DIR, FILE_COMMON);
   const string path = OUT_DIR + "\\" + g_symbol + ".json";
   const int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   const uint n = FileWriteString(h, body);
   FileFlush(h);
   FileClose(h);
   return (n > 0);
  }

//+------------------------------------------------------------------+
void Finish(const string err)
  {
   const datetime gmt = TimeGMT();
   MqlDateTime gd;
   TimeToStruct(gmt, gd);
   string body = "";
   body += "{\n";
   body += "  \"ok\": false,\n";
   body += "  \"error\": " + JsonString(err) + ",\n";
   body += "  \"script_version\": " + JsonString(SCRIPT_VER) + ",\n";
   body += "  \"symbol\": " + JsonString(Ascii(g_symbol)) + ",\n";
   body += "  \"captured_at\": " + JsonString(Clock(gmt) + "Z") + ",\n";
   body += "  \"captured_date\": " + JsonString(StringFormat("%04d-%02d-%02d", gd.year, gd.mon, gd.day)) + "\n";
   body += "}\n";
   WriteSpec(body);
   Sleep(500);
   TerminalClose(1);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   g_symbol = "";
   if(!ReadJob())
     {
      // Файл задания общий (FILE_COMMON). Если его не прочитали,
      // берём символ графика из ini, а не пустой дамп.
      string chart = "";
      for(int i = 0; i < 30; i++)
        {
         chart = Symbol();
         if(SafeSymbol(chart))
            break;
         Sleep(1000);
        }
      if(SafeSymbol(chart))
         g_symbol = chart;
      else if(InpUseInputs && SafeSymbol(InpSymbol))
         g_symbol = InpSymbol;
      else
        {
         g_symbol = "XAUUSDm";
         Finish("job_file_missing");
         return;
        }
     }
   if(!SafeSymbol(g_symbol))
     {
      g_symbol = "XAUUSDm";
      Finish("bad_job");
      return;
     }
   if(!WaitConnected())
     {
      Finish("not_connected");
      return;
     }
   if(!SelectSymbol())
     {
      Finish("symbol_not_selected");
      return;
     }

   const datetime gmt = TimeGMT();
   const datetime srv = TimeTradeServer();
   const int offset = (int)(srv - gmt);
   MqlDateTime gd;
   TimeToStruct(gmt, gd);

   int fill_bits[3];
   string fill_names[3];
   fill_bits[0] = SYMBOL_FILLING_FOK;
   fill_names[0] = "SYMBOL_FILLING_FOK";
   fill_bits[1] = SYMBOL_FILLING_IOC;
   fill_names[1] = "SYMBOL_FILLING_IOC";
   fill_bits[2] = SYMBOL_FILLING_BOC;
   fill_names[2] = "SYMBOL_FILLING_BOC";

   int order_bits[7];
   string order_names[7];
   order_bits[0] = SYMBOL_ORDER_MARKET;
   order_names[0] = "SYMBOL_ORDER_MARKET";
   order_bits[1] = SYMBOL_ORDER_LIMIT;
   order_names[1] = "SYMBOL_ORDER_LIMIT";
   order_bits[2] = SYMBOL_ORDER_STOP;
   order_names[2] = "SYMBOL_ORDER_STOP";
   order_bits[3] = SYMBOL_ORDER_STOP_LIMIT;
   order_names[3] = "SYMBOL_ORDER_STOP_LIMIT";
   order_bits[4] = SYMBOL_ORDER_SL;
   order_names[4] = "SYMBOL_ORDER_SL";
   order_bits[5] = SYMBOL_ORDER_TP;
   order_names[5] = "SYMBOL_ORDER_TP";
   order_bits[6] = SYMBOL_ORDER_CLOSEBY;
   order_names[6] = "SYMBOL_ORDER_CLOSEBY";

   int exp_bits[4];
   string exp_names[4];
   exp_bits[0] = SYMBOL_EXPIRATION_GTC;
   exp_names[0] = "SYMBOL_EXPIRATION_GTC";
   exp_bits[1] = SYMBOL_EXPIRATION_DAY;
   exp_names[1] = "SYMBOL_EXPIRATION_DAY";
   exp_bits[2] = SYMBOL_EXPIRATION_SPECIFIED;
   exp_names[2] = "SYMBOL_EXPIRATION_SPECIFIED";
   exp_bits[3] = SYMBOL_EXPIRATION_SPECIFIED_DAY;
   exp_names[3] = "SYMBOL_EXPIRATION_SPECIFIED_DAY";

   const long fill_mode = SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   const long order_mode = SymbolInfoInteger(g_symbol, SYMBOL_ORDER_MODE);
   const long exp_mode = SymbolInfoInteger(g_symbol, SYMBOL_EXPIRATION_MODE);
   const long rollover = SymbolInfoInteger(g_symbol, SYMBOL_SWAP_ROLLOVER3DAYS);

   string body = "";
   body += "{\n";
   body += "  \"ok\": true,\n";
   body += "  \"error\": \"\",\n";
   body += "  \"script_version\": " + JsonString(SCRIPT_VER) + ",\n";
   body += "  \"symbol\": " + JsonString(g_symbol) + ",\n";
   body += "  \"captured_at\": " + JsonString(Clock(gmt) + "Z") + ",\n";
   body += "  \"captured_date\": " + JsonString(StringFormat("%04d-%02d-%02d", gd.year, gd.mon, gd.day)) + ",\n";
   body += "  \"terminal_build\": " + IntegerToString((int)TerminalInfoInteger(TERMINAL_BUILD)) + ",\n";
   body += "  \"terminal_name\": " + JsonString(Ascii(TerminalInfoString(TERMINAL_NAME))) + ",\n";
   body += "  \"server_utc_offset_seconds\": " + IntegerToString(offset) + ",\n";
   body += "  \"time_gmt\": " + JsonString(Clock(gmt) + "Z") + ",\n";
   body += "  \"time_trade_server\": " + JsonString(Clock(srv)) + ",\n";
   body += "  \"digits\": " + IntegerToString((int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)) + ",\n";
   body += "  \"point\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_POINT)) + ",\n";
   body += "  \"trade_contract_size\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE)) + ",\n";
   body += "  \"trade_tick_size\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE)) + ",\n";
   body += "  \"trade_tick_value\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE)) + ",\n";
   body += "  \"trade_tick_value_profit\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT)) + ",\n";
   body += "  \"trade_tick_value_loss\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS)) + ",\n";
   body += "  \"volume_min\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN)) + ",\n";
   body += "  \"volume_max\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX)) + ",\n";
   body += "  \"volume_step\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP)) + ",\n";
   body += "  \"volume_limit\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_LIMIT)) + ",\n";
   body += "  \"trade_stops_level\": " + IntegerToString((int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL)) + ",\n";
   body += "  \"trade_freeze_level\": " + IntegerToString((int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL)) + ",\n";
   body += "  \"trade_calc_mode\": " + Named(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_CALC_MODE), CalcModeName(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_CALC_MODE))) + ",\n";
   body += "  \"trade_exemode\": " + Named(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_EXEMODE), ExeModeName(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_EXEMODE))) + ",\n";
   body += "  \"filling_mode\": " + FlagList((int)fill_mode, fill_bits, fill_names, 3) + ",\n";
   body += "  \"order_mode\": " + FlagList((int)order_mode, order_bits, order_names, 7) + ",\n";
   body += "  \"expiration_mode\": " + FlagList((int)exp_mode, exp_bits, exp_names, 4) + ",\n";
   body += "  \"swap_mode\": " + Named(SymbolInfoInteger(g_symbol, SYMBOL_SWAP_MODE), SwapModeName(SymbolInfoInteger(g_symbol, SYMBOL_SWAP_MODE))) + ",\n";
   body += "  \"swap_long\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_SWAP_LONG)) + ",\n";
   body += "  \"swap_short\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_SWAP_SHORT)) + ",\n";
   body += "  \"swap_rollover3days\": " + Named(rollover, DayName((int)rollover)) + ",\n";
   body += "  \"swap_weekday\": " + WeekdaySwaps(g_symbol) + ",\n";
   body += "  \"margin_initial\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_MARGIN_INITIAL)) + ",\n";
   body += "  \"margin_maintenance\": " + Num(SymbolInfoDouble(g_symbol, SYMBOL_MARGIN_MAINTENANCE)) + ",\n";
   body += "  \"margin_rate_buy\": " + MarginRate(g_symbol, ORDER_TYPE_BUY) + ",\n";
   body += "  \"margin_rate_sell\": " + MarginRate(g_symbol, ORDER_TYPE_SELL) + ",\n";
   body += "  \"currency_base\": " + JsonString(Ascii(SymbolInfoString(g_symbol, SYMBOL_CURRENCY_BASE))) + ",\n";
   body += "  \"currency_profit\": " + JsonString(Ascii(SymbolInfoString(g_symbol, SYMBOL_CURRENCY_PROFIT))) + ",\n";
   body += "  \"currency_margin\": " + JsonString(Ascii(SymbolInfoString(g_symbol, SYMBOL_CURRENCY_MARGIN))) + ",\n";
   body += "  \"spread_float\": " + (SymbolInfoInteger(g_symbol, SYMBOL_SPREAD_FLOAT) != 0 ? "true" : "false") + ",\n";
   body += "  \"sessions\": {\n";
   body += "    \"trade\": " + OneSideSessions(g_symbol, true) + ",\n";
   body += "    \"quote\": " + OneSideSessions(g_symbol, false) + "\n";
   body += "  }\n";
   body += "}\n";

   if(!WriteSpec(body))
     {
      Finish("write_failed");
      return;
     }
   PrintFormat("symbol-spec: wrote %s", g_symbol);
   Sleep(500);
   TerminalClose(0);
  }
//+------------------------------------------------------------------+
