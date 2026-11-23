//+------------------------------------------------------------------+
//|                                                    tick-warm.mq5 |
//|  Докачивает тики XAUUSDm в кэш терминала и ничего не пишет,      |
//|  кроме счётчика. Окно зашито: 2026.01.01 включительно,           |
//|  2026.10.16 не входит. Цены в файл не попадают.                  |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property description "Warm XAUUSDm ticks through 2026.10.15 | цены не пишет"
#property version   "1.00"

const string   WARM_SYMBOL  = "XAUUSDm";
const datetime WARM_FROM    = D'2026.01.01 00:00:00';
const datetime WARM_TO_EXCL = D'2026.10.16 00:00:00';

ulong g_ticks  = 0;
int   g_errors = 0;
int   g_empty  = 0;

int CopyStable(const ulong from_msc, const ulong to_msc, MqlTick &ticks[], int &copied)
  {
   copied = 0;
   int prev_n = -1;
   ulong prev_last = 0;
   bool have_prev = false;
   for(int i = 0; i < 6; i++)
     {
      ArrayFree(ticks);
      ResetLastError();
      const int n = CopyTicksRange(WARM_SYMBOL, ticks, COPY_TICKS_ALL, from_msc, to_msc);
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

void CountRange(const ulong from_msc, const ulong to_msc, const int depth)
  {
   if(from_msc > to_msc || g_errors > 48 || depth > 12)
     {
      if(depth > 12)
         g_errors++;
      return;
     }
   const ulong holdout = (ulong)WARM_TO_EXCL * 1000;
   if(from_msc >= holdout)
      return;
   ulong end = to_msc;
   if(end >= holdout)
      end = holdout - 1;
   MqlTick ticks[];
   int copied = 0;
   const int rc = CopyStable(from_msc, end, ticks, copied);
   if(rc == -2)
     {
      const ulong span = end - from_msc;
      if(span <= 900000)
        {
         g_errors++;
         return;
        }
      const ulong mid = from_msc + span / 2;
      CountRange(from_msc, mid, depth + 1);
      if(mid < end)
         CountRange(mid + 1, end, depth + 1);
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
      if(ms < from_msc || ms > end || ms >= holdout)
         continue;
      g_ticks++;
     }
  }

bool SelectSymbol()
  {
   for(int i = 0; i < 60; i++)
     {
      if(SymbolSelect(WARM_SYMBOL, true) && SymbolInfoInteger(WARM_SYMBOL, SYMBOL_SELECT))
         return true;
      Sleep(1000);
     }
   return false;
  }

void WriteInfo(const int complete)
  {
   const int handle = FileOpen("tick-warm\\warm_info.txt",
                                FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   FileWriteString(handle, StringFormat("complete=%d\r\nticks=%I64u\r\nerrors=%d\r\nempty=%d\r\n",
                                         complete, g_ticks, g_errors, g_empty));
   FileClose(handle);
  }

void OnStart()
  {
   FolderCreate("tick-warm", FILE_COMMON);
   if(!SelectSymbol())
     {
      WriteInfo(0);
      return;
     }
   const ulong holdout = (ulong)WARM_TO_EXCL * 1000;
   for(datetime day = WARM_FROM; day < WARM_TO_EXCL; day += 86400)
     {
      const ulong from_msc = (ulong)day * 1000;
      ulong to_msc = (ulong)(day + 86400) * 1000 - 1;
      if(to_msc >= holdout)
         to_msc = holdout - 1;
      CountRange(from_msc, to_msc, 0);
      const int progress = FileOpen("tick-warm\\progress.txt",
                                     FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(progress != INVALID_HANDLE)
        {
         FileWriteString(progress, StringFormat("day=%s ticks=%I64u\r\n",
                                                 TimeToString(day, TIME_DATE), g_ticks));
         FileClose(progress);
        }
      if(g_errors > 48)
         break;
     }
   WriteInfo(g_ticks > 0 && g_errors <= 48 ? 1 : 0);
  }
