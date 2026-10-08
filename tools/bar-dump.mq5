//+------------------------------------------------------------------+
//|                                                 bar-dump.mq5     |
//|  Служебный: в конце прогона тестера записывает бары символов в   |
//|  CSV (общая папка терминала, Common\Files) для анализа в Python: |
//|  проверки на случайных входах, вычитание дрейфа цены и т. п.     |
//|  Не торгует.                                                     |
//+------------------------------------------------------------------+
#property strict
#property description "Bar dump | бары символов в CSV для анализа (не торгует)"

input string          Symbols   = "";            // Символы через запятую (пусто — символ теста)
input ENUM_TIMEFRAMES Timeframe = PERIOD_M5;
input datetime        DumpFrom  = D'1970.01.01'; // С какой даты (по умолчанию — вся история теста)

bool DumpSymbol(const string sym)
  {
   MqlRates r[];
   const int n = CopyRates(sym, Timeframe, DumpFrom, TimeCurrent(), r);
   if(n <= 0)
     {
      PrintFormat("❌ %s: нет баров (%d)", sym, GetLastError());
      return false;
     }
   const string tf   = StringSubstr(EnumToString(Timeframe), 7);
   const string name = StringFormat("bars_%s_%s.csv", sym, tf);
   const int h = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("❌ %s: файл не открыт (%d)", name, GetLastError());
      return false;
     }
   const int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   FileWriteString(h, StringFormat("time,open,high,low,close,tick_volume,spread,point=%s\r\n",
                                   DoubleToString(SymbolInfoDouble(sym, SYMBOL_POINT), dg)));
   for(int i = 0; i < n; i++)
      FileWriteString(h, StringFormat("%s,%s,%s,%s,%s,%I64d,%d\r\n", TimeToString(r[i].time, TIME_DATE | TIME_MINUTES),
                                      DoubleToString(r[i].open, dg), DoubleToString(r[i].high, dg),
                                      DoubleToString(r[i].low, dg), DoubleToString(r[i].close, dg),
                                      r[i].tick_volume, r[i].spread));
   FileClose(h);
   PrintFormat("📁 %s: %d баров %s … %s", name, n, TimeToString(r[0].time), TimeToString(r[n - 1].time));
   return true;
  }

int OnInit()
  {
   // Другие символы: включаем и запрашиваем историю заранее, чтобы к концу прогона она была загружена.
   string list[];
   const int k = StringSplit(Symbols, ',', list);
   for(int i = 0; i < k; i++)
     {
      string s = list[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      MqlRates r[];
      if(s != "" && SymbolSelect(s, true))
         CopyRates(s, Timeframe, 0, 1, r);
     }
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
  }

void OnDeinit(const int reason)
  {
   string list[];
   const string src = (Symbols == "") ? _Symbol : Symbols;
   const int k = StringSplit(src, ',', list);
   for(int i = 0; i < k; i++)
     {
      string s = list[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s != "")
         DumpSymbol(s);
     }
  }
//+------------------------------------------------------------------+
