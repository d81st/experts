//+------------------------------------------------------------------+
//|                                                 TradeJournal.mqh |
//|                                                                  |
//|  Журнал сделок в CSV: MQL5/Files/TradeJournal_<символ>.csv.      |
//|  Нужен, чтобы сравнивать реальную торговлю с тестером сделка-    |
//|  в-сделку: запрошенная/фактическая цена, спред, задержка,        |
//|  проскальзывание на входе и на стопе/тейке.                      |
//|                                                                  |
//|  Входы, отказы и пропуски пишет TradeExecutorSend; выходы —      |
//|  TradeJournalOnTransaction из OnTradeTransaction бота.           |
//|  В тестере журнал выключен (g_tradeJournalInTester = false).     |
//+------------------------------------------------------------------+
#ifndef TRADEJOURNAL_MQH
#define TRADEJOURNAL_MQH

bool g_tradeJournalInTester = false;

#define TRADE_JOURNAL_HEADER "server_time;event;magic;ticket;type;lot;requested;fill;slippage;spread;sl;tp;latency_ms;attempts;profit;retcode;info"

//+------------------------------------------------------------------+
//| TradeJournal_Enabled — писать ли журнал в текущем режиме.        |
//+------------------------------------------------------------------+
bool TradeJournal_Enabled()
  {
   return !MQLInfoInteger(MQL_TESTER) || g_tradeJournalInTester;
  }

//+------------------------------------------------------------------+
//| TradeJournalWrite — дописать строку (поля через ';').            |
//+------------------------------------------------------------------+
void TradeJournalWrite(const string row)
  {
   if(!TradeJournal_Enabled())
      return;
   const string name = "TradeJournal_" + _Symbol + ".csv";
   const bool   isNew = !FileIsExist(name);
   const int    h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("TradeJournal: не удалось открыть %s, ошибка %d", name, GetLastError());
      return;
     }
   FileSeek(h, 0, SEEK_END);
   if(isNew)
      FileWriteString(h, TRADE_JOURNAL_HEADER + "\r\n");
   FileWriteString(h, TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS) + ";" + row + "\r\n");
   FileClose(h);
  }

string TradeJournal_D(const double v) { return DoubleToString(v, _Digits); }

//+------------------------------------------------------------------+
//| TradeJournalOnTransaction — записать выход из позиции.            |
//| Вызывать из OnTradeTransaction бота с его magic.                  |
//| slippage: > 0 — выход хуже уровня SL/TP, по которому закрылись.   |
//+------------------------------------------------------------------+
void TradeJournalOnTransaction(const MqlTradeTransaction &trans, const long magic)
  {
   if(!TradeJournal_Enabled() || trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol ||
      HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != magic ||
      HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   const double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   const double sl     = HistoryDealGetDouble(trans.deal, DEAL_SL);
   const double tp     = HistoryDealGetDouble(trans.deal, DEAL_TP);
   const double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                       + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
                       + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   // Закрывающая сделка BUY закрывает SELL-позицию и наоборот.
   const bool   closesSell = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY);

   double level = 0.0;
   string why   = EnumToString(reason);
   if(reason == DEAL_REASON_SL) level = sl;
   if(reason == DEAL_REASON_TP) level = tp;
   const double slip = (level > 0.0) ? (closesSell ? price - level : level - price) : 0.0;

   TradeJournalWrite(StringFormat("EXIT;%I64d;%I64d;%s;%.2f;%s;%s;%s;%s;%s;%s;;;%.2f;;%s",
                                  magic, HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID),
                                  closesSell ? "SELL" : "BUY",
                                  HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
                                  TradeJournal_D(level), TradeJournal_D(price), TradeJournal_D(slip),
                                  TradeJournal_D(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)),
                                  TradeJournal_D(sl), TradeJournal_D(tp), profit, why));
  }

#endif // TRADEJOURNAL_MQH
//+------------------------------------------------------------------+
