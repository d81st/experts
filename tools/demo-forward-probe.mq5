//+------------------------------------------------------------------+
//|                                         demo-forward-probe.mq5   |
//|  Одноразовый скрипт. Не торгует и не ставит советник на график. |
//|  В файл: DEMO/REAL/CONTEST, валюта, «баланс около 10k», кнопка  |
//|  автоторговли. Без логина, сервера, имени, баланса и IP.        |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property description "Account mode probe | не торгует"
#property version   "1.00"

string ModeName()
  {
   const long mode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(mode == ACCOUNT_TRADE_MODE_DEMO)
      return "DEMO";
   if(mode == ACCOUNT_TRADE_MODE_REAL)
      return "REAL";
   if(mode == ACCOUNT_TRADE_MODE_CONTEST)
      return "CONTEST";
   return "UNKNOWN";
  }

string Currency3()
  {
   const string raw = AccountInfoString(ACCOUNT_CURRENCY);
   if(StringLen(raw) != 3)
      return "OTHER";
   for(int i = 0; i < 3; i++)
     {
      const int c = StringGetCharacter(raw, i);
      if(c < 'A' || c > 'Z')
         return "OTHER";
     }
   return raw;
  }

void OnStart()
  {
   const string mode = ModeName();
   const string currency = Currency3();
   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   const bool about10k = (balance >= 8000.0 && balance <= 12000.0);
   const bool autotrading = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);
   const string body = "{\"trade_mode\":\"" + mode +
                       "\",\"currency\":\"" + currency +
                       "\",\"balance_about_10k\":" + (about10k ? "true" : "false") +
                       ",\"autotrading\":" + (autotrading ? "true" : "false") + "}\n";
   uchar data[];
   const int chars = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   int bytes = chars;
   if(bytes > 0 && data[bytes - 1] == 0)
      bytes--;
   const int handle = FileOpen("demo-forward-probe.json", FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   FileWriteArray(handle, data, 0, bytes);
   FileClose(handle);
  }
//+------------------------------------------------------------------+
