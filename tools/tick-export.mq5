//+------------------------------------------------------------------+
//|                                              tick-export.mq5     |
//|  Служебный скрипт: снимает реальные тики брокера через           |
//|  CopyTicksRange(COPY_TICKS_ALL) и пишет CSV по месяцам.          |
//|  Запускается из .github/workflows/export-ticks.yml, не из        |
//|  тестера: в тестере CopyTicks отдаёт тики модели прогона,        |
//|  а здесь — тиковую базу терминала после логина на Exness.        |
//|  Не торгует. В файл не попадают счёт, сервер, пароль и IP.       |
//+------------------------------------------------------------------+
#property strict
#property description "Tick export | реальные тики в CSV по месяцам (не торгует)"
#property version   "1.00"
#property script_show_inputs

input string   InpSymbol    = "XAUUSDm";     // Символ для ручного запуска
input datetime InpFrom      = D'2024.01.01'; // Первый день, включительно
input datetime InpTo        = D'1970.01.01'; // Последний день, включительно (1970 — по сейчас)
input bool     InpUseInputs = false;         // true — взять inputs, если нет файла задания

#define JOB_FILE     "tick-export-job.txt"
#define OUT_DIR      "tick-export"
#define INFO_FILE    "tick-export\\export_info.txt"
#define PROGRESS     "tick-export\\progress.txt"
#define SCRIPT_VER   "1"
#define COLUMNS      "time_msc,bid,ask,last,volume,volume_real,flags"

string g_symbol;
datetime g_from;
datetime g_to_excl;
int    g_digits;
string g_month_lines;
long   g_rows;
ulong  g_first_msc;
ulong  g_last_msc;
int    g_errors;
int    g_empty;
int    g_splits;
int    g_handle;
bool   g_history_ended;
string g_history_ended_at;

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
      const bool ok = ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                       (c >= '0' && c <= '9') || c == '.' || c == '_');
      if(!ok)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
string PriceText(const double v)
  {
   string s = DoubleToString(v, g_digits);
   StringReplace(s, ",", ".");
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
string RealText(const double v)
  {
   string s = DoubleToString(v, 8);
   StringReplace(s, ",", ".");
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
void WriteProgress(const string month, const ulong cursor)
  {
   const int h = FileOpen(PROGRESS, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, StringFormat("month=%s rows=%I64d cursor=%I64u\n", month, g_rows, cursor));
   FileClose(h);
  }

//+------------------------------------------------------------------+
void WriteInfo(const bool ok, const string err)
  {
   string point = DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_POINT), 8);
   StringReplace(point, ",", ".");
   string body = "";
   body += "complete=" + (ok ? "1" : "0") + "\n";
   body += "error=" + Ascii(err) + "\n";
   body += "script_version=" + SCRIPT_VER + "\n";
   body += "symbol=" + Ascii(g_symbol) + "\n";
   body += "from=" + TimeToString(g_from, TIME_DATE) + "\n";
   body += "to_exclusive=" + TimeToString(g_to_excl, TIME_DATE) + "\n";
   body += "exported_at=" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + "\n";
   body += "terminal_build=" + IntegerToString((int)TerminalInfoInteger(TERMINAL_BUILD)) + "\n";
   body += "terminal_name=" + Ascii(TerminalInfoString(TERMINAL_NAME)) + "\n";
   body += "terminal_company=" + Ascii(TerminalInfoString(TERMINAL_COMPANY)) + "\n";
   body += "broker_company=" + Ascii(AccountInfoString(ACCOUNT_COMPANY)) + "\n";
   body += "digits=" + IntegerToString(g_digits) + "\n";
   body += "point=" + point + "\n";
   body += "columns=" + COLUMNS + "\n";
   body += "history_ended_at=" + g_history_ended_at + "\n";
   body += g_month_lines;
   const int h = FileOpen(INFO_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      Print("tick-export: export_info open failed");
      return;
     }
   FileWriteString(h, body);
   FileClose(h);
  }

//+------------------------------------------------------------------+
void Finish(const bool ok, const string err)
  {
   WriteInfo(ok, err);
   Sleep(500);
   TerminalClose(ok ? 0 : 1);
  }

//+------------------------------------------------------------------+
bool ReadJob()
  {
   g_symbol = "";
   g_from = 0;
   g_to_excl = 0;
   const int h = FileOpen(JOB_FILE, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return false;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line, "\r", "");
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "" || StringGetCharacter(line, 0) == '#')
         continue;
      const int p = StringFind(line, "=");
      if(p <= 0)
         continue;
      const string key = StringSubstr(line, 0, p);
      const string val = StringSubstr(line, p + 1);
      if(key == "symbol")
         g_symbol = val;
      else if(key == "from")
         g_from = StringToTime(val);
      else if(key == "to_exclusive")
         g_to_excl = StringToTime(val);
     }
   FileClose(h);
   return (g_symbol != "" && g_from > 0 && g_to_excl > g_from);
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
bool SelectSymbol()
  {
   for(int i = 0; i < 30; i++)
     {
      if(SymbolSelect(g_symbol, true) && SymbolInfoInteger(g_symbol, SYMBOL_SELECT))
        {
         const long digits = SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
         const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
         if(digits >= 0 && digits <= 8 && point > 0.0)
           {
            g_digits = (int)digits;
            return true;
           }
        }
      Sleep(1000);
     }
   return false;
  }

//+------------------------------------------------------------------+
// Два одинаковых ответа подряд с нулевой ошибкой — окно докачано.
// -2: мало памяти, вызывающий делит окно. -1: так и не стабилизировалось.
int CopyStable(const string sym, const ulong from_msc, const ulong to_msc,
               MqlTick &ticks[], int &copied)
  {
   copied = 0;
   int prev_n = -1;
   ulong prev_last = 0;
   bool have_prev = false;
   for(int i = 0; i < 6; i++)
     {
      ArrayFree(ticks);
      ResetLastError();
      const int n = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, from_msc, to_msc);
      const int err = GetLastError();
      if(n < 0)
        {
         if(err == 4004 || err == 4407)
            return -2;
         Sleep(2000);
         continue;
        }
      if(err != 0)
        {
         Sleep(2000);
         continue;
        }
      ulong last = 0;
      if(n > 0)
         last = (ulong)ticks[n - 1].time_msc;
      if(have_prev && n == prev_n && last == prev_last)
        {
         copied = n;
         return 1;
        }
      prev_n = n;
      prev_last = last;
      have_prev = true;
      Sleep(1000);
     }
   return -1;
  }

//+------------------------------------------------------------------+
// Первый тик с from_msc до конца истории брокера. 0 — тиков дальше нет.
int ProbeFirst(const string sym, const ulong from_msc, ulong &found_msc)
  {
   found_msc = 0;
   int prev_n = -1;
   ulong prev_ms = 0;
   bool have_prev = false;
   MqlTick ticks[];
   for(int i = 0; i < 6; i++)
     {
      ArrayFree(ticks);
      ResetLastError();
      const int n = CopyTicks(sym, ticks, COPY_TICKS_ALL, from_msc, 1);
      const int err = GetLastError();
      if(n < 0 || err != 0)
        {
         Sleep(2000);
         continue;
        }
      ulong ms = 0;
      if(n > 0)
         ms = (ulong)ticks[0].time_msc;
      if(n > 0 && ms < from_msc)
        {
         Sleep(1000);
         continue;
        }
      if(have_prev && n == prev_n && ms == prev_ms)
        {
         found_msc = ms;
         return n;
        }
      prev_n = n;
      prev_ms = ms;
      have_prev = true;
      Sleep(1500);
     }
   return -1;
  }

//+------------------------------------------------------------------+
void WriteTick(const MqlTick &tick)
  {
   const string line = StringFormat("%I64u,%s,%s,%s,%I64u,%s,%u\r\n",
                                    (ulong)tick.time_msc,
                                    PriceText(tick.bid),
                                    PriceText(tick.ask),
                                    PriceText(tick.last),
                                    tick.volume,
                                    RealText(tick.volume_real),
                                    (uint)tick.flags);
   if(FileWriteString(g_handle, line) == 0)
     {
      g_errors++;
      return;
     }
   g_rows++;
   if(g_rows == 1)
      g_first_msc = (ulong)tick.time_msc;
   g_last_msc = (ulong)tick.time_msc;
   if((g_rows % 50000) == 0)
      FileFlush(g_handle);
  }

//+------------------------------------------------------------------+
void WriteRange(const string sym, const ulong from_msc, const ulong to_msc, const int depth)
  {
   if(from_msc > to_msc || g_errors > 48)
      return;
   if(depth > 12)
     {
      g_errors++;
      return;
     }
   MqlTick ticks[];
   int copied = 0;
   const int rc = CopyStable(sym, from_msc, to_msc, ticks, copied);
   if(rc == -2)
     {
      const ulong span = to_msc - from_msc;
      if(span <= (ulong)900000)
        {
         g_errors++;
         return;
        }
      g_splits++;
      const ulong mid = from_msc + span / 2;
      WriteRange(sym, from_msc, mid, depth + 1);
      if(mid < to_msc)
         WriteRange(sym, mid + 1, to_msc, depth + 1);
      return;
     }
   if(rc < 0)
     {
      g_errors++;
      return;
     }
   if(copied <= 0)
     {
      g_empty++;
      return;
     }
   for(int i = 0; i < copied; i++)
     {
      const ulong ms = (ulong)ticks[i].time_msc;
      if(ms < from_msc || ms > to_msc)
         continue;
      WriteTick(ticks[i]);
     }
  }

//+------------------------------------------------------------------+
ulong DayStart(const ulong msc)
  {
   MqlDateTime dt;
   TimeToStruct((datetime)(msc / 1000), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return (ulong)StructToTime(dt) * 1000;
  }

//+------------------------------------------------------------------+
void RememberMonth(const string month, const string file)
  {
   const string prefix = "month." + month + ".";
   g_month_lines += prefix + "rows=" + IntegerToString(g_rows) + "\n";
   if(g_rows > 0)
     {
      g_month_lines += prefix + "first_time_msc=" + IntegerToString((long)g_first_msc) + "\n";
      g_month_lines += prefix + "last_time_msc=" + IntegerToString((long)g_last_msc) + "\n";
     }
   else
     {
      g_month_lines += prefix + "first_time_msc=\n";
      g_month_lines += prefix + "last_time_msc=\n";
     }
   g_month_lines += prefix + "copy_errors=" + IntegerToString(g_errors) + "\n";
   g_month_lines += prefix + "empty_chunks=" + IntegerToString(g_empty) + "\n";
   g_month_lines += prefix + "splits=" + IntegerToString(g_splits) + "\n";
   g_month_lines += prefix + "file=" + file + "\n";
  }

//+------------------------------------------------------------------+
bool OpenMonth(const string file)
  {
   g_handle = FileOpen(OUT_DIR + "\\" + file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(g_handle == INVALID_HANDLE)
      return false;
   const string header = COLUMNS + "\r\n";
   if(FileWriteString(g_handle, header) == 0)
     {
      FileClose(g_handle);
      g_handle = INVALID_HANDLE;
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void ExportMonth(const datetime range_from, const datetime range_to_excl, const string month)
  {
   g_rows = 0;
   g_first_msc = 0;
   g_last_msc = 0;
   g_errors = 0;
   g_empty = 0;
   g_splits = 0;
   const string file = "ticks_" + g_symbol + "_" + month + ".csv";
   if(!OpenMonth(file))
     {
      g_errors++;
      RememberMonth(month, file);
      return;
     }
   const ulong from_msc = (ulong)range_from * 1000;
   const ulong to_msc = (ulong)range_to_excl * 1000 - 1;
   ulong cursor = from_msc;
   if(g_history_ended)
     {
      g_empty++;
     }
   else
     {
      ulong found = 0;
      const int probe = ProbeFirst(g_symbol, from_msc, found);
      if(probe == 0 || (probe == 1 && found > to_msc))
        {
         g_empty++;
         if(probe == 0)
           {
            g_history_ended = true;
            g_history_ended_at = month;
           }
        }
      else
        {
         if(probe == 1 && found > from_msc)
           {
            const ulong day = DayStart(found);
            if(day > from_msc && day <= to_msc)
               cursor = day;
           }
         while(cursor <= to_msc && g_errors <= 48)
           {
            ulong chunk_to = cursor + (ulong)86400000 - 1;
            if(chunk_to < cursor || chunk_to > to_msc)
               chunk_to = to_msc;
            WriteRange(g_symbol, cursor, chunk_to, 0);
            WriteProgress(month, cursor);
            if(chunk_to >= to_msc)
               break;
            cursor = chunk_to + 1;
           }
        }
     }
   FileFlush(g_handle);
   FileClose(g_handle);
   g_handle = INVALID_HANDLE;
   RememberMonth(month, file);
   PrintFormat("tick-export: %s rows=%I64d errors=%d", month, g_rows, g_errors);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   g_month_lines = "";
   g_history_ended = false;
   g_history_ended_at = "";
   g_digits = 0;
   g_handle = INVALID_HANDLE;
   FolderCreate(OUT_DIR, FILE_COMMON);
   if(!ReadJob())
     {
      if(FileIsExist(JOB_FILE, FILE_COMMON))
        {
         g_symbol = InpSymbol;
         Finish(false, "bad_job");
         return;
        }
      if(!InpUseInputs)
        {
         g_symbol = InpSymbol;
         Finish(false, "job_file_missing");
         return;
        }
      g_symbol = InpSymbol;
      g_from = InpFrom;
      MqlDateTime edge;
      if(InpTo <= D'1970.01.02')
         TimeToStruct(TimeCurrent(), edge);
      else
         TimeToStruct(InpTo, edge);
      edge.hour = 0;
      edge.min = 0;
      edge.sec = 0;
      edge.day += 1;
      g_to_excl = StructToTime(edge);
     }
   if(!SafeSymbol(g_symbol) || g_from < D'2000.01.01' || g_to_excl <= g_from || g_to_excl > D'2100.01.01')
     {
      Finish(false, "bad_job");
      return;
     }
   if(!WaitConnected())
     {
      Finish(false, "not_connected");
      return;
     }
   if(!SelectSymbol())
     {
      Finish(false, "symbol_not_selected");
      return;
     }
   datetime cur = g_from;
   int guard = 0;
   while(cur < g_to_excl && guard < 120)
     {
      MqlDateTime st;
      TimeToStruct(cur, st);
      st.day = 1;
      st.hour = 0;
      st.min = 0;
      st.sec = 0;
      const datetime month_start = StructToTime(st);
      const string month = StringFormat("%04d-%02d", st.year, st.mon);
      st.mon += 1;
      if(st.mon > 12)
        {
         st.mon = 1;
         st.year += 1;
        }
      const datetime month_next = StructToTime(st);
      const datetime range_from = (cur > month_start ? cur : month_start);
      const datetime range_to = (g_to_excl < month_next ? g_to_excl : month_next);
      if(range_to <= range_from)
         break;
      ExportMonth(range_from, range_to, month);
      cur = month_next;
      guard++;
     }
   if(guard >= 120)
     {
      Finish(false, "range_too_long");
      return;
     }
   Finish(true, "");
  }
//+------------------------------------------------------------------+
