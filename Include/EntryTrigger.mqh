//+------------------------------------------------------------------+
//|                                                 EntryTrigger.mqh |
//|                                                                  |
//|  Проверка условия входа для сигнала, ожидающего уровня:          |
//|  режимы MARKET (касание) и SWEEP+RECLAIM (снятие → возврат).     |
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
   ENTRY_LIMIT         = 2   // Лимитный ордер     (BUY/SELL LIMIT на уровне)
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

#endif // ENTRYTRIGGER_MQH
//+------------------------------------------------------------------+
