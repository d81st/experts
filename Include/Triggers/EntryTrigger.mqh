//+------------------------------------------------------------------+
//|                                                 EntryTrigger.mqh |
//|                                                                  |
//|  Проверка условия входа для сигнала, ожидающего уровня:          |
//|  режимы MARKET (касание), SWEEP+RECLAIM (снятие → возврат) и      |
//|  CLOSE_CONFIRM (снятие → закрытие бара за уровнем).              |
//|  Ордера модуль не отправляет — это делает бот.                   |
//+------------------------------------------------------------------+
#ifndef ENTRYTRIGGER_MQH
#define ENTRYTRIGGER_MQH

//+------------------------------------------------------------------+
//| Режим входа (входной параметр EntryMode).                        |
//+------------------------------------------------------------------+
enum ENUM_ENTRY_MODE
  {
   ENTRY_SWEEP_RECLAIM = 0,  // Sweep + Reclaim   (двухфазное подтверждение)
   ENTRY_MARKET        = 1,  // Рыночный вход      (касание уровня → сразу открыть)
   ENTRY_LIMIT         = 2,  // Лимитный ордер     (BUY/SELL LIMIT на уровне)
   ENTRY_CLOSE_CONFIRM = 3   // Снятие + закрытие бара за уровнем → вход на следующем баре
  };

//+------------------------------------------------------------------+
//| EntryTriggerPoll — пора ли входить по текущим Bid/Ask.            |
//|                                                                  |
//|   dir   — направление сделки: +1 BUY, -1 SELL.                   |
//|   level — уровень входа.                                         |
//|   swept — состояние «уровень снят» (SWEEP_RECLAIM); хранит бот,  |
//|           модуль выставляет его при снятии.                      |
//|   label — подпись сигнала для журнала.                           |
//|   price — цена входа: Ask для BUY, Bid для SELL.                 |
//|                                                                  |
//|   MARKET:        BUY — Ask ≤ level; SELL — Bid ≥ level.          |
//|   SWEEP_RECLAIM: BUY — сначала Bid < level (снятие), затем       |
//|                  Ask > level (возврат); SELL — зеркально.        |
//|   LIMIT:         всегда false — вход делает лимитный ордер.      |
//+------------------------------------------------------------------+
bool EntryTriggerPoll(const ENUM_ENTRY_MODE mode,
                      const int             dir,
                      const double          level,
                      bool                 &swept,
                      const string          label,
                      double               &price)
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const bool   buy = (dir == 1);
   price = buy ? ask : bid;

   if(mode == ENTRY_MARKET)
     {
      const bool hit = buy ? (ask <= level) : (bid >= level);
      if(hit)
         PrintFormat("✅ MARKET %s: %s=%.5f %s Level=%.5f → открываем [%s]",
                     buy ? "BUY" : "SELL", buy ? "Ask" : "Bid", price,
                     buy ? "≤" : "≥", level, label);
      return hit;
     }

   if(mode != ENTRY_SWEEP_RECLAIM)
      return false;

   if(!swept)
     {
      if(buy ? (bid < level) : (ask > level))
        {
         swept = true;
         PrintFormat("%s Sweep (%s): %s=%.5f %s Level=%.5f [%s]",
                     buy ? "📉" : "📈", buy ? "BUY" : "SELL",
                     buy ? "Bid" : "Ask", buy ? bid : ask, buy ? "<" : ">", level, label);
        }
      return false;
     }

   const bool reclaim = buy ? (ask > level) : (bid < level);
   if(reclaim)
      PrintFormat("✅ Reclaim (%s): %s=%.5f %s Level=%.5f → открываем [%s]",
                  buy ? "BUY" : "SELL", buy ? "Ask" : "Bid", price,
                  buy ? ">" : "<", level, label);
   return reclaim;
  }

//+------------------------------------------------------------------+
//| EntryTriggerBeyondSL — цена до входа уже дошла до стопа сигнала. |
//|                                                                  |
//|   Вход по рынку дал бы стоп с неверной стороны (отказ брокера    |
//|   «invalid stops»), а сам сигнал уже сломан — его надо отменить. |
//|   BUY — Bid ≤ sl; SELL — Ask ≥ sl (там, где сработал бы стоп).   |
//+------------------------------------------------------------------+
bool EntryTriggerBeyondSL(const int dir, const double sl)
  {
   if(sl <= 0.0)
      return false;
   return (dir == 1) ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) <= sl)
                     : (SymbolInfoDouble(_Symbol, SYMBOL_ASK) >= sl);
  }

//+------------------------------------------------------------------+
//| EntryTriggerOnClose — снятие и возврат по ЗАКРЫТЫМ барам tf      |
//| (режим ENTRY_CLOSE_CONFIRM). Не зависит от пути цены внутри бара |
//| и одинаково срабатывает в тестере и в реале.                     |
//|                                                                  |
//|   Учитываются бары, открывшиеся в [firstBar, lastBar]            |
//|   (lastBar = 0 — без ограничения).                               |
//|   BUY:  low бара < level — снятие; close бара > level после      |
//|         снятия (можно в том же баре) — вход по Ask.              |
//|   SELL: high > level — снятие; close < level — вход по Bid.      |
//|   До исполнения возвращает true на каждом тике бара, следующего  |
//|   за подтверждением (повтор, если вход отсёк фильтр).            |
//|   loggedBar — бар, уже записанный в журнал (без повторов).       |
//+------------------------------------------------------------------+
bool EntryTriggerOnClose(const ENUM_TIMEFRAMES tf,
                         const int             dir,
                         const double          level,
                         const datetime        firstBar,
                         const datetime        lastBar,
                         bool                 &swept,
                         datetime             &loggedBar,
                         const string          label,
                         double               &price)
  {
   const datetime t = iTime(_Symbol, tf, 1);
   if(t <= 0 || t < firstBar || (lastBar > 0 && t > lastBar))
      return false;

   const bool   buy = (dir == 1);
   const double lo  = iLow(_Symbol, tf, 1);
   const double hi  = iHigh(_Symbol, tf, 1);
   const double cl  = iClose(_Symbol, tf, 1);
   const bool   log = (t != loggedBar);
   loggedBar = t;

   if(!swept && (buy ? (lo < level) : (hi > level)))
     {
      swept = true;
      if(log)
         PrintFormat("%s Sweep по бару (%s): %s=%.5f %s Level=%.5f [%s]",
                     buy ? "📉" : "📈", buy ? "BUY" : "SELL",
                     buy ? "Low" : "High", buy ? lo : hi, buy ? "<" : ">", level, label);
     }
   if(!swept)
      return false;

   const bool reclaim = buy ? (cl > level) : (cl < level);
   if(!reclaim)
      return false;

   price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(log)
      PrintFormat("✅ Закрытие за уровнем (%s): Close=%.5f %s Level=%.5f → открываем [%s]",
                  buy ? "BUY" : "SELL", cl, buy ? ">" : "<", level, label);
   return true;
  }

#endif // ENTRYTRIGGER_MQH
//+------------------------------------------------------------------+
