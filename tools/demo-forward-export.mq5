//+------------------------------------------------------------------+
//|                                      demo-forward-export.mq5     |
//|  Одноразовый скрипт. Не торгует и не ставит советник на график. |
//|  Пишет сделки и позиции XAUUSDm с магиком 71012. Без логина,    |
//|  сервера, имени счёта, баланса и IP. Не DEMO — только режим.    |
//+------------------------------------------------------------------+
#property strict
#property description "Demo forward export | не торгует"
#property version   "1.00"

#define EXPORT_MAGIC 71012
#define EXPORT_SYMBOL "XAUUSDm"

struct DealRow
  {
   datetime when;
   ulong    position_id;
   long     entry;
   long     deal_type;
   long     reason;
   double   volume;
   double   price;
   double   commission;
   double   swap;
   double   profit;
   double   sl;
   string   comment;
  };

DealRow g_deals[];
int     g_count = 0;

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

bool WriteCommon(const string name, const string body)
  {
   uchar data[];
   const int chars = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   int bytes = chars;
   if(bytes > 0 && data[bytes - 1] == 0)
      bytes--;
   const int handle = FileOpen(name, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false;
   if(bytes > 0)
      FileWriteArray(handle, data, 0, bytes);
   FileClose(handle);
   return true;
  }

string WhenText(const datetime when)
  {
   return TimeToString(when, TIME_DATE | TIME_MINUTES | TIME_SECONDS);
  }

string DirName(const long entry)
  {
   if(entry == DEAL_ENTRY_IN)
      return "in";
   if(entry == DEAL_ENTRY_OUT)
      return "out";
   if(entry == DEAL_ENTRY_INOUT)
      return "inout";
   if(entry == DEAL_ENTRY_OUT_BY)
      return "out_by";
   return "";
  }

string TypeName(const long kind)
  {
   if(kind == DEAL_TYPE_BUY)
      return "buy";
   if(kind == DEAL_TYPE_SELL)
      return "sell";
   return "";
  }

string ReasonName(const long reason)
  {
   if(reason == DEAL_REASON_SL)
      return "sl";
   if(reason == DEAL_REASON_TP)
      return "tp";
   if(reason == DEAL_REASON_EXPERT)
      return "expert";
   if(reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB)
      return "client";
   return "other";
  }

string SafeComment(const string raw)
  {
   const int n = StringLen(raw);
   if(n <= 0 || n > 40)
      return "";
   for(int i = 0; i < n; i++)
     {
      const int c = StringGetCharacter(raw, i);
      const bool ok = ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                       (c >= '0' && c <= '9') || c == ' ' || c == '.' ||
                       c == '_' || c == '#' || c == '-');
      if(!ok)
         return "";
     }
   return raw;
  }

void RememberDeal(const ulong ticket)
  {
   const string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
   if(symbol != EXPORT_SYMBOL)
      return;
   if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != EXPORT_MAGIC)
      return;
   const long kind = (long)HistoryDealGetInteger(ticket, DEAL_TYPE);
   const long entry = (long)HistoryDealGetInteger(ticket, DEAL_ENTRY);
   if(TypeName(kind) == "" || DirName(entry) == "")
      return;
   const int n = g_count;
   ArrayResize(g_deals, n + 1);
   g_deals[n].when = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
   g_deals[n].position_id = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
   g_deals[n].entry = entry;
   g_deals[n].deal_type = kind;
   g_deals[n].reason = (long)HistoryDealGetInteger(ticket, DEAL_REASON);
   g_deals[n].volume = HistoryDealGetDouble(ticket, DEAL_VOLUME);
   g_deals[n].price = HistoryDealGetDouble(ticket, DEAL_PRICE);
   g_deals[n].commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   g_deals[n].swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
   g_deals[n].profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
   g_deals[n].sl = HistoryDealGetDouble(ticket, DEAL_SL);
   g_deals[n].comment = SafeComment(HistoryDealGetString(ticket, DEAL_COMMENT));
   g_count = n + 1;
  }

int g_order[];

void SortDeals()
  {
   ArrayResize(g_order, g_count);
   for(int i = 0; i < g_count; i++)
      g_order[i] = i;
   for(int i = 0; i < g_count; i++)
     {
      for(int j = i + 1; j < g_count; j++)
        {
         const int left = g_order[i];
         const int right = g_order[j];
         const bool earlier = (g_deals[right].position_id < g_deals[left].position_id) ||
                              (g_deals[right].position_id == g_deals[left].position_id &&
                               g_deals[right].when < g_deals[left].when);
         if(earlier)
           {
            const int tmp = g_order[i];
            g_order[i] = g_order[j];
            g_order[j] = tmp;
           }
        }
     }
  }

string DealsCsv()
  {
   string body = "time,symbol,type,direction,volume,price,commission,swap,profit,magic,position\n";
   for(int n = 0; n < g_count; n++)
     {
      const int i = g_order[n];
      body += WhenText(g_deals[i].when) + "," + EXPORT_SYMBOL + "," +
              TypeName(g_deals[i].deal_type) + "," + DirName(g_deals[i].entry) + "," +
              DoubleToString(g_deals[i].volume, 2) + "," +
              DoubleToString(g_deals[i].price, 3) + "," +
              DoubleToString(g_deals[i].commission, 2) + "," +
              DoubleToString(g_deals[i].swap, 2) + "," +
              DoubleToString(g_deals[i].profit, 2) + "," +
              IntegerToString(EXPORT_MAGIC) + "," +
              IntegerToString((long)g_deals[i].position_id) + "\n";
     }
   return body;
  }

string PositionsCsv()
  {
   string body = "time_open,symbol,type,volume,price_open,sl,tp,swap,profit,magic\n";
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != EXPORT_SYMBOL)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != EXPORT_MAGIC)
         continue;
      const long kind = (long)PositionGetInteger(POSITION_TYPE);
      const string type = (kind == POSITION_TYPE_BUY ? "buy" : (kind == POSITION_TYPE_SELL ? "sell" : ""));
      if(type == "")
         continue;
      body += WhenText((datetime)PositionGetInteger(POSITION_TIME)) + "," + EXPORT_SYMBOL + "," +
              type + "," +
              DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "," +
              DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 3) + "," +
              DoubleToString(PositionGetDouble(POSITION_SL), 3) + "," +
              DoubleToString(PositionGetDouble(POSITION_TP), 3) + "," +
              DoubleToString(PositionGetDouble(POSITION_SWAP), 2) + "," +
              DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "," +
              IntegerToString(EXPORT_MAGIC) + "\n";
     }
   return body;
  }

string TradesCsv()
  {
   string body = "entry_time,exit_time,side,volume,entry_price,exit_price,sl,net_pnl,exit_reason,comment\n";
   int i = 0;
   while(i < g_count)
     {
      const int i0 = g_order[i];
      const ulong pid = g_deals[i0].position_id;
      int j = i + 1;
      while(j < g_count && g_deals[g_order[j]].position_id == pid)
         j++;
      double in_vol = 0.0, out_vol = 0.0, in_px = 0.0, out_px = 0.0, net = 0.0, sl = 0.0;
      datetime entry_time = 0, exit_time = 0;
      long side_type = -1;
      long exit_reason = -1;
      string comment = "";
      bool mixed = false;
      for(int n = i; n < j; n++)
        {
         const int k = g_order[n];
         net += g_deals[k].profit + g_deals[k].commission + g_deals[k].swap;
         if(g_deals[k].entry == DEAL_ENTRY_IN)
           {
            if(side_type >= 0 && side_type != g_deals[k].deal_type)
               mixed = true;
            side_type = g_deals[k].deal_type;
            if(entry_time == 0 || g_deals[k].when < entry_time)
               entry_time = g_deals[k].when;
            in_px += g_deals[k].price * g_deals[k].volume;
            in_vol += g_deals[k].volume;
            if(sl <= 0.0 && g_deals[k].sl > 0.0)
               sl = g_deals[k].sl;
            if(comment == "")
               comment = g_deals[k].comment;
           }
         else if(g_deals[k].entry == DEAL_ENTRY_OUT)
           {
            if(exit_time == 0 || g_deals[k].when >= exit_time)
              {
               exit_time = g_deals[k].when;
               exit_reason = g_deals[k].reason;
              }
            out_px += g_deals[k].price * g_deals[k].volume;
            out_vol += g_deals[k].volume;
           }
         else
            mixed = true;
        }
      const bool closed = (!mixed && in_vol > 0.0 && out_vol > 0.0 &&
                           MathAbs(in_vol - out_vol) <= 0.001 && side_type >= 0);
      if(closed)
        {
         const string side = (side_type == DEAL_TYPE_BUY ? "long" : "short");
         body += WhenText(entry_time) + "," + WhenText(exit_time) + "," + side + "," +
                 DoubleToString(in_vol, 2) + "," +
                 DoubleToString(in_px / in_vol, 3) + "," +
                 DoubleToString(out_px / out_vol, 3) + "," +
                 DoubleToString(sl, 3) + "," +
                 DoubleToString(net, 2) + "," +
                 ReasonName(exit_reason) + "," +
                 comment + "\n";
        }
      i = j;
     }
   return body;
  }

void OnStart()
  {
   const string mode = ModeName();
   if(mode != "DEMO")
     {
      WriteCommon("demo-forward-mode.txt", mode + "\n");
      return;
     }
   if(!HistorySelect(0, TimeCurrent() + 86400))
     {
      WriteCommon("demo-forward-mode.txt", "UNKNOWN\n");
      return;
     }
   g_count = 0;
   ArrayResize(g_deals, 0);
   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket != 0)
         RememberDeal(ticket);
     }
   SortDeals();
   if(!WriteCommon("demo-forward-deals.csv", DealsCsv()))
      return;
   if(!WriteCommon("demo-forward-positions.csv", PositionsCsv()))
      return;
   if(!WriteCommon("demo-forward-trades.csv", TradesCsv()))
      return;
   WriteCommon("demo-forward-mode.txt", "DEMO\n");
  }
//+------------------------------------------------------------------+
